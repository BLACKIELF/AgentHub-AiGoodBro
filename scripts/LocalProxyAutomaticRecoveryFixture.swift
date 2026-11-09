import Darwin
import Foundation

// Offline regression fixture, never a product example. The helper does not
// listen on TCP, contact a provider, or read any profile outside this test root.
private enum AutomaticRecoveryFixtureFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let label): return label }
    }
}

@MainActor private final class AutomaticRecoveryHarness {
    let root = DispatchParticipationPaths.supportDirectory()
    let activity = DispatchActivityStore.live
    let port = 54027
    var labels: [String] = []
    var stores: [LocalProxyQueueStore] = []
    var children: [Process] = []
    var journal: URL { root.appendingPathComponent("helper-journal.jsonl") }
    var state: URL { root.appendingPathComponent(DispatchActivityStore.stateName) }

    func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw AutomaticRecoveryFixtureFailure.assertion(label) }
        labels.append(label)
        print("AUTOMATIC_RECOVERY_CHECK \(labels.count): \(label)")
    }

    func wait(_ label: String, timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(condition(), label)
    }

    func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func entries() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        return try Data(contentsOf: journal).split(separator: 10).map {
            guard let value = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else {
                throw AutomaticRecoveryFixtureFailure.assertion("synthetic helper journal is valid JSON")
            }
            return value
        }
    }

    func starts() throws -> [[String: Any]] {
        try entries().filter { $0["event"] as? String == "started" }
    }

    func installHelper() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let python = ProcessInfo.processInfo.environment["PROXY_FIXTURE_PYTHON"]!
        let quoted = "'" + python.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\nexec " + quoted + " -u \"$0.py\"\n"
        try Data(script.utf8).write(to: LocalProxyFixtureRuntime.helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: LocalProxyFixtureRuntime.helper.path)
        let helper = #"""
import hashlib, json, os, pathlib, select, sys
root = pathlib.Path(__file__).resolve().parent
def record(value):
    with (root / 'helper-journal.jsonl').open('a') as output:
        output.write(json.dumps(value, sort_keys=True) + '\n')
        output.flush()
        os.fsync(output.fileno())
configuration = json.loads(sys.stdin.readline())
registry = json.loads((root / 'dispatch-activity-v1.json').read_text())
active = {'preparing', 'starting', 'running', 'cancel_requested', 'uncertain'}
record({'event': 'started', 'runID': configuration['runID'], 'port': configuration['port'],
        'clientKeyHash': hashlib.sha256(configuration['clientKey'].encode()).hexdigest(),
        'accounts': configuration['accounts'], 'pid': os.getpid(),
        'activeRuns': sorted({row.get('proxyRunID', '') for row in registry['leases']
                              if row.get('route') == 'proxy' and row['state'] in active})})
if (root / 'fail-start').exists():
    print(json.dumps({'event': 'error', 'errorCode': 'listen_port_occupied'}), flush=True)
    sys.exit(31)
while (root / 'hold-ready').exists():
    readable, _, _ = select.select([sys.stdin], [], [], 0.02)
    if readable:
        message = json.loads(sys.stdin.readline())
        command = message.get('command', '')
        record({'event': 'command', 'runID': configuration['runID'], 'command': command})
        if command == 'stop':
            sys.exit(0)
record({'event': 'ready-sent', 'runID': configuration['runID']})
print(json.dumps({'event': 'ready', 'port': configuration['port'] or 54027}), flush=True)
for line in sys.stdin:
    message = json.loads(line)
    command = message.get('command', '')
    record({'event': 'command', 'runID': configuration['runID'], 'command': command})
    if command == 'stop':
        sys.exit(0)
"""#
        try Data(helper.utf8).write(to: root.appendingPathComponent("fixture-helper.py"))
    }

    func profile(_ id: String, system: Bool = false) -> CodexProfile {
        let now = Date()
        let window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(3600))
        var result = CodexProfile(id: id, lastSnapshot: .init(
            planType: "plus", accountID: id + "-account", email: id + "@example.invalid",
            fetchedAt: now, fiveHour: window, sevenDay: window))
        result.isSystemProfile = system
        return result
    }

    func writeCredentials(_ profile: CodexProfile) throws {
        // Deliberately unsigned fixture claims, accepted only by the offline
        // parser. No live token or private account is present in this fixture.
        func claims(_ value: [String: Any]) throws -> String {
            let encoded = try JSONSerialization.data(withJSONObject: value).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "fixture.\(encoded).fixture"
        }
        let snapshot = profile.lastSnapshot!
        let access = try claims(["exp": Date().timeIntervalSince1970 + 3600,
                                 "iat": snapshot.fetchedAt.timeIntervalSince1970 - 300,
                                 "account_id": snapshot.accountID!])
        let identity = try claims(["email": snapshot.email!, "account_id": snapshot.accountID!])
        try FileManager.default.createDirectory(at: profile.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = profile.codexHomeURL.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "id_token": identity, "account_id": snapshot.accountID!]]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func makeStore(automatic: Bool = true, listenPort: Int? = nil, mode: LocalProxyClientKeyMode = .persistent) throws -> (LocalProxyQueueStore, UsageStore) {
        let profiles = [profile("recovery-member"), profile("recovery-peer"), profile("recovery-system", system: true)]
        for item in profiles { try writeCredentials(item) }
        let usage = UsageStore(profiles)
        usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage)
        stores.append(store)
        try expect(store.setNetworkSettings(port: listenPort ?? port, mode: mode, egress: .init()), "fixture uses an isolated synthetic endpoint configuration")
        store.setOptIn(true)
        store.setAccountEnabled(id: profiles[0].id, enabled: true)
        store.setAccountEnabled(id: profiles[1].id, enabled: false)
        try expect(store.setAutomaticRecovery(automatic), "automatic recovery preference saves through the production setter")
        return (store, usage)
    }

    func start(_ store: LocalProxyQueueStore) async throws {
        await store.start()
        if let child = store.process { children.append(child) }
        try expect(store.phase == .running && store.process?.isRunning == true && store.runID != nil,
                   "production start reaches ready with a real synthetic child")
        try expect(store.desktopAvailable && store.desktopConnection != nil,
                   "ready creates the isolated desktop connection without launching Desktop")
    }

    func error(_ store: LocalProxyQueueStore, code: String = "lease_release_unknown", detail: String = "registry_unavailable", resolution: String? = nil, run: String? = nil) throws {
        var object = ["event": "error", "errorCode": code, "errorDetail": detail]
        if let resolution { object["resolutionDetail"] = resolution }
        store.consume(try JSONSerialization.data(withJSONObject: object), run: run ?? store.runID!)
    }

    func backoff(_ store: LocalProxyQueueStore) async throws {
        try await wait("safe stop completes before the automatic recovery backoff") {
            store.process == nil && store.runID == nil && store.exitCleanupID == nil
                && store.automaticRecoveryTask != nil && store.automaticRecoveryPlan != nil
        }
        try expect(store.leases.isEmpty && store.isAutomaticallyRecovering && !store.canStart && store.canStop && !store.canFinishTermination,
                   "backoff retains its cancellation and termination gates")
    }

    func recovered(_ store: LocalProxyQueueStore, from run: String, timeout: TimeInterval = 6) async throws {
        try await wait("automatic recovery starts a different run and receives ready", timeout: timeout) {
            store.phase == .running && store.runID != nil && store.runID != run
                && store.process?.isRunning == true && !store.isAutomaticallyRecovering
        }
        if let child = store.process { children.append(child) }
        try expect(store.automaticRecoveryPlan == nil && store.automaticRecoveryTask == nil,
                   "ready retires only the completed recovery plan")
    }

    func stopped(_ store: LocalProxyQueueStore) async throws {
        try await wait("the failed run stops without an automatic replacement") {
            store.process == nil && store.runID == nil && !store.isAutomaticallyRecovering
        }
    }

    func reserve(_ store: LocalProxyQueueStore, profile: CodexProfile, request: String? = nil, mirror: Bool = true) throws -> String {
        let request = request ?? UUID().uuidString
        let run = store.runID!
        let id = try activity.reserveProxy(account: profile.recordedAccountKey, alias: "fixture-alias", runID: run,
                                           requestID: request, profileID: profile.id, childPID: store.process!.processIdentifier)
        try activity.updateProxy(id, runID: run, requestID: request, profileID: profile.id, state: "running")
        if mirror {
            store.leases[id] = LocalProxyQueueStore.Lease(id: id, profileID: profile.id, requestID: request, runID: run, isAdmitted: true)
        }
        return id
    }

    func rules(_ store: LocalProxyQueueStore) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.preferences)) as! [String: Any]
        object.removeValue(forKey: "secretsReference")
        object.removeValue(forKey: "persistentClientKey")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func cleanup() async {
        for store in stores { await store.finishForTermination() }
        for child in children where child.isRunning { child.terminate() }
        for _ in 0..<50 {
            if children.allSatisfy({ !$0.isRunning }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        for child in children where child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
    }

    func run(_ scenario: String) async throws {
        try installHelper()
        switch scenario {
        case "defaults": try await defaults()
        case "success": try await success()
        case "cancel-stop", "cancel-disable", "cancel-quit": try await cancel(scenario)
        case "cancel-disable-starting": try await cancelDisableStarting()
        case "preflight-membership-change": try await preflightMembershipChange()
        case "late-stop": try await lateStop()
        case "snapshot-identity-change", "home-change", "disabled-binding-change", "system-identity-change", "managed-auth-change", "system-auth-change":
            try await identityChange(scenario)
        case "system-email-missing": try await systemEmailMissing()
        case "port-zero", "per-run": try await unsupportedEndpoint(scenario)
        case "ineligible-failures": try await ineligibleFailures()
        case "corrupt-registry": try await corruptRegistry()
        case "registry-cleanup-gate": try await registryCleanupGate()
        case "budget": try await budget()
        case "startup-failure": try await startupFailure()
        case "termination-resume": try await terminationResume()
        default: throw AutomaticRecoveryFixtureFailure.assertion("unknown scenario")
        }
    }

    func defaults() async throws {
        let usage = UsageStore([profile("recovery-member")])
        usage.isPreview = false
        let fresh = LocalProxyQueueStore(usageStore: usage)
        stores.append(fresh)
        try expect(LocalProxyPreferences().automaticRecoveryEnabled == nil && !fresh.automaticRecoveryEnabled,
                   "new preferences leave automatic recovery explicitly opt-in")
        let legacy = #"{"schemaVersion":1,"isEnabled":true,"order":["recovery-member"],"enabledIDs":["recovery-member"],"knownIDs":["recovery-member"],"priorityIDs":[]}"#
        let decoded = try JSONDecoder().decode(LocalProxyPreferences.self, from: Data(legacy.utf8))
        try expect(decoded.automaticRecoveryEnabled == nil, "old schema1 preferences decode with recovery off")
        try Data(legacy.utf8).write(to: root.appendingPathComponent("local-proxy-queue-v1.json"))
        let old = LocalProxyQueueStore(usageStore: usage)
        stores.append(old)
        try expect(old.isEnabled && !old.automaticRecoveryEnabled && old.phase == .stopped && old.process == nil,
                   "loading an enabled legacy queue never starts a helper or enables recovery")
        try expect(old.setAutomaticRecovery(true), "explicit opt-in persists for an existing installation")
        let reloaded = LocalProxyQueueStore(usageStore: usage)
        stores.append(reloaded)
        try expect(reloaded.automaticRecoveryEnabled && reloaded.process == nil && reloaded.phase == .stopped,
                   "saved recovery opt-in reloads without starting the proxy on launch")
        let (store, _) = try makeStore(automatic: false)
        try await start(store)
        let child = store.process
        let run = store.runID
        try expect(store.setAutomaticRecovery(true) && store.setAutomaticRecovery(false),
                   "the recovery switch can be changed while the proxy is running")
        try expect(store.process === child && store.runID == run && store.phase == .running,
                   "changing the recovery switch preserves the current helper and requests")
        try error(store)
        try await stopped(store)
        try await pause(2.2)
        try expect(try starts().count == 1 && store.automaticRecoveryAttempts.isEmpty,
                   "an opted-out control failure safely stops without scheduling recovery")
    }

    func success() async throws {
        let (store, usage) = try makeStore()
        let member = usage.profiles[0]
        store.setAccountPriority(id: member.id, priority: true)
        store.setAccountLast(id: usage.profiles[1].id, last: true)
        store.setResetStop(id: member.id, enabled: true)
        store.setCreditFallback(true)
        try expect(store.setCreditFloors(primary: 2600, secondary: 1800)
                   && store.setAccountPolicy(id: member.id, policy: .init(fiveHourUsedLimit: 65, allowsCredits: false)),
                   "fixture preserves nondefault participation, credit and account rules")
        try await start(store)
        let oldRun = store.runID!, oldControl = store.controlKey!, oldClient = store.clientKey!
        let endpoint = store.endpoint
        let bindings = store.registeredPool
        let savedRules = try rules(store)
        let request = UUID().uuidString
        let order = await store.handle(.init(schemaVersion: 1, runID: oldRun, key: oldControl, command: "order", requestID: request, profileID: member.id, leaseID: nil))
        try expect(order.ok && store.membershipSnapshots[request] != nil, "an interrupted request has a production order snapshot")
        let lease = try reserve(store, profile: member, request: request)
        try expect(try activity.read().leases.first(where: { $0.leaseId == lease })?.occupied == true,
                   "an interrupted response owns a real registry lease")
        try error(store)
        try error(store)
        try expect(store.automaticRecoveryAttempts.count == 1, "duplicate error events consume one recovery attempt for the same run")
        try await backoff(store)
        try expect(try activity.read().leases.first(where: { $0.leaseId == lease })?.state == "cancelled",
                   "the exact interrupted lease is terminal before recovery starts")
        let began = ProcessInfo.processInfo.systemUptime
        try await pause(0.15)
        try expect(try starts().count == 1, "the backoff never launches a helper immediately")
        try await recovered(store, from: oldRun)
        try expect(ProcessInfo.processInfo.systemUptime - began >= 1.8, "the first automatic restart observes its two-second backoff")
        try expect(store.endpoint == endpoint && store.clientKey == oldClient && store.listenPort == port,
                   "automatic recovery keeps the desktop endpoint and persistent client key")
        try expect(store.registeredPool == bindings && (try rules(store)) == savedRules,
                   "automatic recovery preserves account bindings and all existing queue rules")
        let connection = try JSONSerialization.jsonObject(with: Data(contentsOf: store.desktopConnection!)) as! [String: Any]
        try expect(connection["endpoint"] as? String == endpoint && connection["clientKey"] as? String == oldClient,
                   "the replacement desktop connection uses the same endpoint and client key")
        let launches = try starts()
        try expect(launches.count == 2 && launches.allSatisfy { $0["port"] as? Int == port && $0["clientKeyHash"] as? String == DispatchActivityStore.hash(oldClient) },
                   "both real helper startups receive the same port and masked key identity")
        try expect(store.leases.isEmpty && store.membershipSnapshots.isEmpty
                   && !(try activity.read().leases.contains(where: { $0.proxyRunID == store.runID }))
                   && (try activity.read().proxyAcquireKeys ?? []).isEmpty,
                   "recovery creates no new lease, acquire marker or request snapshot")
        let stale = await store.handle(.init(schemaVersion: 1, runID: oldRun, key: oldControl, command: "acquire", requestID: request, profileID: member.id, leaseID: nil))
        try expect(stale.error == "identity" && stale.accessToken == nil, "the interrupted request cannot replay against the replacement run")
        try expect(try entries().filter { $0["event"] as? String == "command" }.allSatisfy { $0["command"] as? String == "stop" },
                   "the helper receives no replay, request payload, retry or upstream command")
        try expect(store.automaticRecoveryMessage?.lowercased().contains("retry any interrupted request") == true,
                   "ready reports recovery while requiring a caller retry for the interrupted request")
    }

    func cancel(_ scenario: String) async throws {
        let (store, _) = try makeStore()
        try await start(store)
        try error(store)
        try await backoff(store)
        switch scenario {
        case "cancel-stop": await store.stop()
        case "cancel-disable": try expect(store.setAutomaticRecovery(false), "turning off recovery persists during backoff")
        default: await store.finishForTermination()
        }
        try expect(!store.isAutomaticallyRecovering && store.automaticRecoveryPlan == nil && store.automaticRecoveryTask == nil,
                   "the user action revokes the pending automatic recovery generation")
        try await pause(2.25)
        try expect(try starts().count == 1 && store.process == nil && store.runID == nil,
                   "a cancelled backoff cannot launch a helper after its old sleep completes")
        try expect(store.canFinishTermination, "a cancelled backoff releases the quit gate")
        if scenario == "cancel-disable" {
            try expect(!store.automaticRecoveryEnabled && store.preferences.automaticRecoveryEnabled == false,
                       "recovery remains opted out after cancellation")
        }
        if scenario == "cancel-quit" {
            try expect(store.finishing && !store.canStart, "termination prevents a later pending restart")
        }
    }

    func cancelDisableStarting() async throws {
        let (store, _) = try makeStore()
        try await start(store)
        try error(store)
        try await backoff(store)
        let hold = root.appendingPathComponent("hold-ready")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: hold) }
        try await wait("the replacement child is waiting before ready", timeout: 5) {
            (try? self.starts().count) == 2 && store.phase == .starting && store.process?.isRunning == true
        }
        let replacement = store.process!
        let replacementRun = store.runID!
        children.append(replacement)
        try expect(store.setAutomaticRecovery(false), "turning off recovery persists while its child is starting")
        let lateReady = try JSONSerialization.data(withJSONObject: ["event": "ready", "port": port])
        store.consume(lateReady, run: replacementRun)
        try expect(store.phase != .running, "a ready event queued before cancellation cannot revive the cancelled run")
        try await wait("disabling recovery stops the unready replacement child", timeout: 7) {
            !replacement.isRunning && store.process == nil && store.runID == nil && !store.isAutomaticallyRecovering
        }
        try FileManager.default.removeItem(at: hold)
        try await pause(0.3)
        let events = try entries().filter { $0["runID"] as? String == replacementRun }
        try expect(events.contains { $0["event"] as? String == "command" && $0["command"] as? String == "stop" }
                   && !events.contains { $0["event"] as? String == "ready-sent" },
                   "the cancelled child receives stop without reaching ready")
        try expect(try starts().count == 2 && store.automaticRecoveryPlan == nil && !store.automaticRecoveryEnabled,
                   "a late ready cannot revive the disabled recovery or create a third helper")
    }

    func preflightMembershipChange() async throws {
        let (store, usage) = try makeStore()
        try await start(store)
        let entered = root.appendingPathComponent("preflight-entered")
        let release = DispatchSemaphore(value: 0)
        LocalProxyFixtureRuntime.afterAutomaticRecoveryPreflight = {
            try? Data().write(to: entered)
            _ = release.wait(timeout: .now() + 8)
        }
        defer {
            release.signal()
            LocalProxyFixtureRuntime.afterAutomaticRecoveryPreflight = nil
        }
        try error(store)
        try await wait("credential preflight is paused after validating the original members", timeout: 5) {
            FileManager.default.fileExists(atPath: entered.path)
        }
        let peer = usage.profiles[1]
        store.setAccountEnabled(id: peer.id, enabled: true)
        try expect(store.preferences.enabledIDs.contains(peer.id) && store.rows.contains { $0.id == peer.id && $0.isEnabled },
                   "a second registered account was enabled during preflight")
        try expect(store.automaticRecoveryPlan.map(store.automaticRecoveryInputsMatch) == true,
                   "the new member matches the original registered bindings but was not validated")
        release.signal()
        try await wait("the changed membership rejects the stale preflight", timeout: 5) { !store.isAutomaticallyRecovering }
        try await pause(0.3)
        try expect(try starts().count == 1 && store.process == nil && store.runID == nil && store.automaticRecoveryPlan == nil,
                   "an account added during preflight cannot reach a replacement helper without validation")
        try expect(store.automaticRecoveryMessage?.contains("did not complete") == true,
                   "the changed membership asks for manual recovery")
    }

    func lateStop() async throws {
        let (store, _) = try makeStore()
        try await start(store)
        let old = store.runID!
        try error(store)
        try await recovered(store, from: old)
        let replacement = store.runID, child = store.process
        await store.stop(reason: .controlFailure, expectedRun: old)
        await store.stop(reason: .startupFailure, expectedRun: old)
        try error(store, run: old)
        try await pause(0.2)
        try expect(store.runID == replacement && store.process === child && child?.isRunning == true && store.phase == .running,
                   "late control and startup stops from the old run leave the replacement untouched")
        try expect(try starts().count == 2 && store.automaticRecoveryAttempts.count == 1 && !store.isAutomaticallyRecovering,
                   "late old-run events neither restart nor spend the replacement's recovery budget")
    }

    func identityChange(_ scenario: String) async throws {
        let (store, usage) = try makeStore()
        try await start(store)
        try error(store)
        try await backoff(store)
        if scenario == "snapshot-identity-change" {
            usage.profiles[0].lastSnapshot?.accountID = "changed-member-account"
            usage.profiles[0].lastSnapshot?.email = "changed-member@example.invalid"
        } else if scenario == "home-change" {
            usage.profiles[0].fixtureHomeURL = root.appendingPathComponent("changed-home")
        } else if scenario == "disabled-binding-change" {
            usage.profiles[1].lastSnapshot?.accountID = "changed-peer-account"
            usage.profiles[1].lastSnapshot?.email = "changed-peer@example.invalid"
        } else if scenario == "system-identity-change" {
            usage.profiles[2].lastSnapshot?.accountID = "changed-system-account"
            usage.profiles[2].lastSnapshot?.email = "changed-system@example.invalid"
        } else {
            let index = scenario == "managed-auth-change" ? 0 : 2
            var changed = usage.profiles[index]
            changed.lastSnapshot?.accountID = "changed-auth-account"
            changed.lastSnapshot?.email = "changed-auth@example.invalid"
            try writeCredentials(changed)
        }
        store.rebuildRows()
        try await wait("changed identity or home cancels recovery before a replacement is launched", timeout: 4) { !store.isAutomaticallyRecovering }
        try expect(try starts().count == 1 && store.process == nil && store.runID == nil && store.automaticRecoveryPlan == nil,
                   "snapshot and actual credential identity must both match the failed run")
        try expect(store.automaticRecoveryMessage?.contains("did not complete") == true,
                   "identity rejection remains visible for manual correction")
    }

    func systemEmailMissing() async throws {
        let (store, usage) = try makeStore()
        let original = usage.profiles[2].lastSnapshot?.email
        let values: [String?] = [nil, "  \t  "]
        for value in values {
            try await start(store)
            usage.profiles[2].lastSnapshot?.email = value
            try error(store)
            try expect(store.automaticRecoveryPlan == nil && store.automaticRecoveryAttempts.isEmpty,
                       "missing or blank system identity cannot schedule automatic recovery")
            try await stopped(store)
            usage.profiles[2].lastSnapshot?.email = original
        }
        try await pause(2.2)
        try expect(try starts().count == 2 && store.process == nil,
                   "missing system identity cannot produce a delayed replacement helper")
    }

    func unsupportedEndpoint(_ scenario: String) async throws {
        let (store, _) = try makeStore(listenPort: scenario == "port-zero" ? 0 : port,
                                       mode: scenario == "per-run" ? .perRun : .persistent)
        try await start(store)
        try error(store)
        try expect(store.automaticRecoveryPlan == nil && store.automaticRecoveryAttempts.isEmpty,
                   "automatic recovery requires a fixed port and persistent key")
        try await stopped(store)
        try await pause(2.2)
        try expect(try starts().count == 1 && store.process == nil, "unsupported endpoint mode never silently replaces the desktop endpoint")
    }

    func ineligibleFailures() async throws {
        let (store, _) = try makeStore()
        let failures: [(String, String, String?)] = [
            ("lease_release_unknown", "registry_state_invalid", nil),
            ("lease_release_unknown", "identity", nil),
            ("lease_release_unknown", "missing_lease", nil),
            ("lease_acquire_unknown", "timeout", nil),
            ("lease_acquire_unknown", "timeout", "unrecognized_resolution"),
        ]
        for (index, value) in failures.enumerated() {
            try await start(store)
            try error(store, code: value.0, detail: value.1, resolution: value.2)
            try expect(store.automaticRecoveryPlan == nil && store.automaticRecoveryAttempts.isEmpty,
                       "nontransient or unconfirmed failure \(index + 1) never schedules recovery")
            try await stopped(store)
            try await pause(0.15)
        }
        try await pause(2.2)
        try expect(try starts().count == failures.count && store.process == nil,
                   "unconfirmed and identity failures do not create a delayed restart loop")
    }

    func corruptRegistry() async throws {
        let (store, usage) = try makeStore()
        try await start(store)
        let lease = try reserve(store, profile: usage.profiles[0])
        let original = try Data(contentsOf: state)
        let corrupt = Data("{invalid-registry".utf8)
        defer { try? original.write(to: state, options: .atomic) }
        try corrupt.write(to: state, options: .atomic)
        try error(store)
        try await stopped(store)
        try await pause(2.2)
        try expect(store.phase == .failed && store.exitCleanupID != nil && store.leases[lease] != nil && !store.canStart,
                   "damaged registry retains the uncertain lease and blocks a replacement")
        try expect(try starts().count == 1 && Data(contentsOf: state) == corrupt,
                   "recovery never repairs or overwrites a corrupt registry by guessing")
        try original.write(to: state, options: .atomic)
        await store.stop()
        try expect(store.exitCleanupID == nil && store.leases.isEmpty && store.canFinishTermination,
                   "restoring the fixture registry permits the normal explicit cleanup path")
    }

    func registryCleanupGate() async throws {
        let (store, usage) = try makeStore()
        try await start(store)
        let oldRun = store.runID!, oldChild = store.process!
        // A disk-only reservation models an acquire completed off-main before
        // its UI mirror arrives. Recovery still has to retire the real row.
        let lease = try reserve(store, profile: usage.profiles[0], mirror: false)
        let lockURL = root.appendingPathComponent(DispatchActivityStore.lockName)
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        try expect(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0,
                   "the fixture holds only its isolated real registry lock")
        var locked = true
        defer {
            if locked { _ = flock(descriptor, LOCK_UN) }
            Darwin.close(descriptor)
        }
        try error(store)
        try await wait("registry contention retains the cleanup gate after the old child exits") {
            store.process == nil && !oldChild.isRunning && store.exitCleanupID != nil && store.exitCleanupTask != nil
        }
        try expect(store.automaticRecoveryTask == nil && store.automaticRecoveryPlan != nil && store.isAutomaticallyRecovering
                   && !store.canStart && !store.canFinishTermination,
                   "automatic backoff cannot begin while real registry retirement is unconfirmed")
        try expect(try activity.read().leases.first(where: { $0.leaseId == lease })?.occupied == true && starts().count == 1,
                   "a disk-only lease remains occupied and no replacement launches under contention")
        _ = flock(descriptor, LOCK_UN)
        locked = false
        try await backoff(store)
        try expect(try activity.read().leases.first(where: { $0.leaseId == lease })?.state == "cancelled",
                   "successful registry retry cancels the disk-only lease before backoff")
        try await recovered(store, from: oldRun)
        let launches = try starts()
        try expect(launches.count == 2 && !(launches[1]["activeRuns"] as! [String]).contains(oldRun),
                   "the replacement helper observes no active lease from the failed run at startup")
    }

    func budget() async throws {
        let (store, _) = try makeStore()
        try await start(store)
        let delays: [UInt64] = [2, 5, 10]
        for attempt in 1...3 {
            let old = store.runID!
            let began = ProcessInfo.processInfo.systemUptime
            try error(store)
            try expect(store.automaticRecoveryAttempts.count == attempt && store.automaticRecoveryPlan?.delay == delays[attempt - 1],
                       "attempt \(attempt) retains its bounded two-five-ten-second backoff")
            try await recovered(store, from: old, timeout: 14)
            try expect(ProcessInfo.processInfo.systemUptime - began >= Double(delays[attempt - 1]) - 0.15,
                       "attempt \(attempt) actually waits its configured backoff before reaching ready")
            try expect(store.automaticRecoveryAttempts.count == attempt,
                       "ready \(attempt) does not reset the ten-minute recovery budget")
        }
        try expect(try starts().count == 4, "three recovery attempts produce exactly three replacement helpers")
        try error(store)
        try expect(store.automaticRecoveryAttempts.count == 3 && store.automaticRecoveryPlan == nil,
                   "a fourth control failure cannot exceed three automatic attempts in ten minutes")
        try await stopped(store)
        try await pause(2.2)
        try expect(try starts().count == 4 && store.automaticRecoveryMessage?.contains("3 attempts in 10 minutes") == true,
                   "exhaustion remains visible and never begins another backoff")
        let issues = try String(contentsOf: root.appendingPathComponent(DispatchActivityStore.issueName), encoding: .utf8)
        try expect(issues.contains("recovery_exhausted"), "budget exhaustion records its terminal diagnostic")
        try await start(store)
        try expect(store.automaticRecoveryAttempts.count == 3 && (try starts().count) == 5,
                   "an explicit manual start remains available but retains the rolling recovery budget")
        await store.stop()
        try expect(store.automaticRecoveryAttempts.count == 3,
                   "a manual stop does not reset the rolling recovery budget")
        try await start(store)
        try expect(store.automaticRecoveryAttempts.count == 3 && (try starts().count) == 6,
                   "another manual start remains available without resetting the budget")
        try error(store)
        try await stopped(store)
        try await pause(2.2)
        try expect(store.automaticRecoveryAttempts.count == 3 && (try starts().count) == 6,
                   "manual restarts cannot circumvent the three-attempt rolling limit")
    }

    func startupFailure() async throws {
        let (store, _) = try makeStore()
        try await start(store)
        try error(store)
        try await backoff(store)
        try Data().write(to: root.appendingPathComponent("fail-start"))
        try await wait("a replacement helper startup failure ends automatic recovery", timeout: 6) {
            !store.isAutomaticallyRecovering && store.process == nil && store.runID == nil
        }
        try expect(try starts().count == 2 && store.automaticRecoveryPlan == nil && store.automaticRecoveryAttempts.count == 1,
                   "a failed startup consumes one attempt and never schedules itself recursively")
        try await pause(3)
        try expect(try starts().count == 2 && store.automaticRecoveryMessage?.contains("did not complete") == true,
                   "startup failure remains stopped with a manual recovery message")
    }

    func terminationResume() async throws {
        let (store, usage) = try makeStore()
        try await start(store)
        _ = try reserve(store, profile: usage.profiles[0])
        let original = try Data(contentsOf: state)
        defer { try? original.write(to: state, options: .atomic) }
        try Data("{invalid-registry".utf8).write(to: state, options: .atomic)
        await store.finishForTermination()
        try expect(store.finishing && !store.canFinishTermination && store.exitCleanupID != nil && !store.canStart,
                   "unconfirmed termination retains ownership while the quit request is rejected")
        store.resumeAfterCancelledTermination()
        try expect(!store.finishing && store.automaticRecoveryPlan == nil && !store.isAutomaticallyRecovering,
                   "cancelled termination reopens normal user controls without resurrecting automatic recovery")
        try original.write(to: state, options: .atomic)
        await store.stop()
        try expect(store.canStart && store.canFinishTermination && store.leases.isEmpty,
                   "normal explicit cleanup succeeds after registry repair on the same store")
        try await start(store)
        try expect(try starts().count == 2 && store.phase == .running,
                   "the same desktop store can manually restart after a rejected quit")
    }
}

@main struct LocalProxyAutomaticRecoveryFixture {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        let scenario = ProcessInfo.processInfo.environment["PROXY_AUTOMATIC_RECOVERY_SCENARIO"] ?? "success"
        let harness = AutomaticRecoveryHarness()
        do {
            try await harness.run(scenario)
            await harness.cleanup()
            try harness.expect(harness.children.allSatisfy { !$0.isRunning }, "all synthetic fixture children are stopped at completion")
            let result: [String: Any] = ["scenario": scenario, "checks": harness.labels.count, "labels": harness.labels,
                                         "helperStarts": try harness.starts().count, "passed": true]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: harness.root.appendingPathComponent("result.json"))
            print("PASS_AUTOMATIC_RECOVERY: \(scenario); \(harness.labels.count) checks")
        } catch {
            await harness.cleanup()
            print("FAIL_AUTOMATIC_RECOVERY: \(scenario): \(error)")
            exit(1)
        }
    }
}
