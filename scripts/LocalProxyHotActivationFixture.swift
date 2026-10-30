import Darwin
import Foundation

private struct HotActivationFixtureFailure: Error { let checks: [String] }
private final class HotCredentialGateFixture: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let ended = DispatchSemaphore(value: 0)
    init() {
        let entered = DispatchSemaphore(value: 0)
        Thread { [self] in
            CodexCredentialAccessGate.lock.lock()
            entered.signal()
            _ = release.wait(timeout: .now() + 8)
            CodexCredentialAccessGate.lock.unlock()
            ended.signal()
        }.start()
        precondition(entered.wait(timeout: .now() + 1) == .success)
    }
    func unlock() { release.signal() }
    func finish() { unlock(); precondition(ended.wait(timeout: .now() + 1) == .success) }
}

extension LocalProxyHostFixtures {
    @MainActor static func hotActivationFixtures() async throws {
        var checks = 0
        var failures: [String] = []
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            let passed = value()
            print("HOT_ACTIVATION_CHECK \(checks): \(passed ? "PASS" : "FAIL") \(label)")
            if !passed { failures.append(label) }
        }
        let root = DispatchParticipationPaths.supportDirectory()
        expect(root.path.contains("aigoodbro-proxy-host-fixture-"), "synthetic support directory only")
        let now = Date()
        func profile(_ id: String) -> CodexProfile {
            .init(id: id, lastSnapshot: .init(planType: "plus", creditBalance: "5000", creditBalanceUnlimited: false,
                accountID: id + "-account", email: id + "@example.invalid", fetchedAt: now,
                fiveHour: .init(usedPercent: 10, resetsAt: now.addingTimeInterval(3600)),
                sevenDay: .init(usedPercent: 10, resetsAt: now.addingTimeInterval(3600))))
        }
        func writeCredentials(_ candidate: CodexProfile, wrong: Bool = false, expired: Bool = false, issuedAt: Double? = nil) throws {
            func jwt(_ claims: [String: Any]) throws -> String {
                let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return "fixture.\(encoded).fixture"
            }
            try FileManager.default.createDirectory(at: candidate.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let account = wrong ? "changed-account" : candidate.lastSnapshot!.accountID!
            let access = try jwt(["exp": now.timeIntervalSince1970 + (expired ? -60 : 3600), "iat": issuedAt ?? now.timeIntervalSince1970 - 300, "account_id": account])
            let identity = try jwt(["email": candidate.lastSnapshot!.email!, "account_id": account])
            let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "id_token": identity, "account_id": account]])
            let file = candidate.codexHomeURL.appendingPathComponent("auth.json")
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func requestID() -> String {
            let time = String(format: "%012llx", UInt64(Date().timeIntervalSince1970 * 1000))
            let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return "\(time.prefix(8))-\(time.suffix(4))-7\(random.prefix(3))-a\(random.dropFirst(3).prefix(3))-\(random.dropFirst(6).prefix(12))"
        }
        func readCommand(_ pipe: Pipe) async throws -> [String: String]? {
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var bytes = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<200 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 { return try JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: String] }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["90"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            HubConsoleModel.fixtureAvailability = .unavailable
            LocalProxyFixtureRuntime.failPreferenceRename = false
            DispatchCodeCatalog.fixtureMissing = []
        }
        HubConsoleModel.fixtureAvailability = .idle
        for scenario in ["success", "cancel", "identity", "save", "stop", "timeout", "rejected", "pipe_full", "pending_changed", "run_changed", "malformed_ack",
            "credentials_busy_then_ready", "credentials_busy_timeout", "credentials_busy_cancel", "credentials_busy_run_changed", "login_expired", "post_ack_busy"] {
            let old = profile("hot-old-" + scenario)
            var central = profile("hot-central-" + scenario); central.isSystemProfile = true
            let added = profile("hot-new-" + scenario)
            for candidate in [old, central, added] { try writeCredentials(candidate) }
            let usage = UsageStore([old, central]); usage.isPreview = false
            let store = LocalProxyQueueStore(usageStore: usage)
            let run = UUID().uuidString
            let key = "synthetic-hot-activation"
            let pipe = Pipe()
            store.process = child; store.phase = .running; store.runID = run; store.controlKey = key
            store.input = pipe.fileHandleForWriting
            store.registeredPool = [old.id: .init(home: old.codexHomeURL, account: old.recordedAccountKey, accountID: old.lastSnapshot!.accountID!)]
            store.activeIDs = [old.id]
            store.runProfiles = LocalProxyRunProfiles([old.id])
            usage.profiles.append(added)
            store.rebuildRows()
            let credentialGate = scenario.hasPrefix("credentials_busy") ? HotCredentialGateFixture() : nil
            defer { credentialGate?.finish() }
            if scenario == "credentials_busy_then_ready" {
                // A normal quota reader can rotate the same identity's token
                // before releasing its gate. The retry must use the new snapshot.
                Task { @MainActor in
                    try await Task.sleep(nanoseconds: 250_000_000)
                    let observed = Date()
                    usage.profiles[2].lastSnapshot?.fetchedAt = observed
                    try writeCredentials(usage.profiles[2], issuedAt: observed.timeIntervalSince1970 - 0.01)
                    credentialGate?.unlock()
                }
            }
            if scenario == "login_expired" { try writeCredentials(added, expired: true) }
            func request(_ command: String, _ id: String, profile: String? = nil, lease: String? = nil) -> LocalProxyRequest {
                .init(schemaVersion: 1, runID: run, key: key, command: command, requestID: id, profileID: profile ?? old.id, leaseID: lease)
            }
            func acknowledge(_ pending: LocalProxyQueueStore.HotRegistration, _ changes: [String: String] = [:]) throws {
                var body = ["event": "account_registered", "runID": run, "requestID": pending.requestID,
                    "profileID": added.id, "identityHash": DispatchActivityStore.hash(added.lastSnapshot!.accountID!), "state": "registered"]
                body.merge(changes) { _, new in new }
                store.consume(try JSONSerialization.data(withJSONObject: body), run: run)
            }
            if scenario == "success" {
                usage.profiles[2].dispatchRegistrationPending = true
                expect(!store.canHotActivateAccount(id: added.id), "pending catalog transaction cannot activate")
                usage.profiles[2].dispatchRegistrationPending = nil
                DispatchCodeCatalog.fixtureMissing = [added.id]
                expect(!store.canHotActivateAccount(id: added.id), "missing alias cannot activate")
                DispatchCodeCatalog.fixtureMissing = []
                let permissions = store.runProfiles
                store.runProfiles = nil
                expect(!store.canHotActivateAccount(id: added.id), "missing lease permission set fails closed")
                store.runProfiles = permissions
            }
            expect(store.canHotActivateAccount(id: added.id), "\(scenario): verified newly registered row offers activation")
            let oldRequest = requestID()
            let before = await store.handle(request("order", oldRequest))
            var oldLease: LocalProxyReply?
            if scenario == "success" { oldLease = await store.handle(request("acquire", oldRequest)) }
            if scenario == "pipe_full" {
                let fd = pipe.fileHandleForWriting.fileDescriptor
                let flags = fcntl(fd, F_GETFL)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let bytes = [UInt8](repeating: 70, count: 4096)
                for _ in 0..<256 { if Darwin.write(fd, bytes, bytes.count) < 0 { break } }
                _ = fcntl(fd, F_SETFL, flags)
                let started = ProcessInfo.processInfo.systemUptime
                await store.hotActivateAccount(id: added.id)
                expect(ProcessInfo.processInfo.systemUptime - started < 1 && store.hotActivationErrors[added.id] == "unavailable", "full inherited pipe fails promptly without blocking UI")
                expect(store.registeredPool[added.id] == nil && !store.activeIDs.contains(added.id), "full pipe never commits membership")
                store.process = nil; store.input = nil; store.phase = .stopped
                try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close()
                continue
            }
            let task = Task { @MainActor in await store.hotActivateAccount(id: added.id) }
            if ["credentials_busy_timeout", "credentials_busy_cancel", "credentials_busy_run_changed", "login_expired"].contains(scenario) {
                let began = ProcessInfo.processInfo.systemUptime
                if scenario == "credentials_busy_cancel" || scenario == "credentials_busy_run_changed" {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    if scenario == "credentials_busy_cancel" { store.cancelHotActivation(id: added.id) }
                    else { store.runID = UUID().uuidString }
                }
                await task.value
                let expected = scenario == "credentials_busy_timeout" ? "credentials_busy" : scenario == "login_expired" ? "login_expired" : nil
                expect(store.hotActivationErrors[added.id] == expected, "\(scenario): exact preflight failure or cancellation is retained")
                expect(ProcessInfo.processInfo.systemUptime - began < 2.5, "\(scenario): bounded busy wait stays responsive")
                var readable = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                expect(Darwin.poll(&readable, 1, 0) == 0, "\(scenario): no register command before verification")
                expect(store.registeredPool[added.id] == nil && !store.activeIDs.contains(added.id), "\(scenario): no membership on failed verification")
                store.process = nil; store.input = nil; store.phase = .stopped
                try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close()
                continue
            }
            let received = try await readCommand(pipe)
            expect(received != nil, "\(scenario): locally verified control command emitted")
            guard let command = received, let pending = store.hotRegistrations[added.id] else { task.cancel(); await task.value; continue }
            expect(Set(command.keys) == ["command", "runID", "requestID", "profileID", "identityHash"] && command["command"] == "register_account" && command["runID"] == run && command["requestID"] == pending.requestID,
                "\(scenario): control envelope is correlated and has no credential fields")
            expect(store.registeredPool[added.id] == nil && !store.activeIDs.contains(added.id) && !store.runProfiles!.snapshot().contains(added.id),
                "\(scenario): no host membership or lease permissions before ACK")
            if scenario == "success" {
                for changes in [["runID": UUID().uuidString], ["requestID": UUID().uuidString], ["identityHash": String(repeating: "f", count: 64)]] {
                    try acknowledge(pending, changes)
                    expect(store.hotRegistrations[added.id]?.acknowledged == false, "wrong run/request/identity ACK ignored")
                }
                try acknowledge(pending)
            } else if scenario == "cancel" {
                store.cancelHotActivation(id: added.id)
                try acknowledge(pending)
            } else if scenario == "identity" {
                try acknowledge(pending)
                try writeCredentials(added, wrong: true)
            } else if scenario == "save" {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("local-proxy-queue-v1.json.blocked"), withIntermediateDirectories: true)
                LocalProxyFixtureRuntime.failPreferenceRename = true
                try acknowledge(pending)
            } else if scenario == "stop" {
                store.phase = .stopping
                try acknowledge(pending)
            } else if scenario == "rejected" {
                try acknowledge(pending, ["state": "rejected", "errorCode": "cooldown_pending"])
            } else if scenario == "malformed_ack" {
                try acknowledge(pending, ["errorCode": "identity"])
            } else if scenario == "pending_changed" {
                try acknowledge(pending)
                usage.profiles[2].dispatchRegistrationPending = true
            } else if scenario == "run_changed" {
                try acknowledge(pending)
                store.runID = UUID().uuidString
            } else if scenario == "credentials_busy_then_ready" {
                try acknowledge(pending)
            } else if scenario == "post_ack_busy" {
                let gate = HotCredentialGateFixture()
                try acknowledge(pending)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { gate.unlock() }
                await task.value
                gate.finish()
            }
            await task.value
            LocalProxyFixtureRuntime.failPreferenceRename = false
            if scenario == "save" { try FileManager.default.removeItem(at: root.appendingPathComponent("local-proxy-queue-v1.json.blocked")) }
            if ["credentials_busy_then_ready", "post_ack_busy"].contains(scenario) {
                expect(store.activeIDs.contains(added.id), "\(scenario): temporary reader contention resolves without another activation")
                var readable = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                expect(Darwin.poll(&readable, 1, 0) == 0, "\(scenario): verification retry never resends registration")
            } else if scenario == "success" {
                expect(store.activeIDs.contains(added.id) && store.registeredPool[added.id] != nil && store.preferences.enabledIDs.contains(added.id), "matching ACK plus second identity check commits participation")
                expect(store.runProfiles!.snapshot() == [old.id, added.id], "new lease permissions append without removing old account")
                let frozen = await store.handle(request("order", oldRequest))
                expect(frozen.order == before.order && !(frozen.order ?? []).contains(added.id), "old request order remains frozen after activation")
                let forbidden = await store.handle(request("acquire", oldRequest, profile: added.id))
                expect(!forbidden.ok && forbidden.accessToken == nil, "new member cannot enter an existing request snapshot")
                let freshID = requestID()
                let freshOrder = await store.handle(request("order", freshID))
                expect(freshOrder.order?.contains(added.id) == true, "new request order includes activated account")
                let lease = await store.handle(request("acquire", freshID, profile: added.id))
                expect(lease.ok && lease.leaseID != nil && lease.accessToken != nil, "new account passes normal admission and credential gates")
                for (id, profileID, value) in [(oldRequest, old.id, oldLease), (freshID, added.id, Optional(lease))] {
                    guard let leaseID = value?.leaseID else { expect(false, "expected fixture lease"); continue }
                    let heartbeat = LocalProxyQueueStore.maintainLease(request("heartbeat", id, profile: profileID, lease: leaseID), run: run, key: key, permittedProfiles: store.runProfiles!.snapshot())
                    let released = LocalProxyQueueStore.maintainLease(request("release", id, profile: profileID, lease: leaseID), run: run, key: key, permittedProfiles: store.runProfiles!.snapshot())
                    expect(heartbeat.ok && released.ok, "\(profileID): original maintenance path keeps heartbeat and release rights")
                    store.completeLeaseRelease(request("release", id, profile: profileID, lease: leaseID))
                }
                _ = await store.handle(request("order_end", freshID, profile: ""))
            } else {
                expect(store.registeredPool[added.id] == nil && !store.activeIDs.contains(added.id) && !store.runProfiles!.snapshot().contains(added.id), "\(scenario): failure never commits runtime membership")
                try acknowledge(pending)
                expect(store.hotRegistrations[added.id] == nil && !store.activeIDs.contains(added.id), "\(scenario): late ACK cannot revive activation")
                if scenario == "cancel" {
                    expect(store.canHotActivateAccount(id: added.id), "same identity remains retryable after cancellation")
                    usage.profiles[2].lastSnapshot?.accountID = "different-account"
                    expect(!store.canHotActivateAccount(id: added.id), "attempted helper ID cannot be reused with a changed identity")
                    usage.profiles[2] = added
                    let retry = Task { @MainActor in await store.hotActivateAccount(id: added.id) }
                    let retryCommand = try await readCommand(pipe)
                    if retryCommand != nil, let retryPending = store.hotRegistrations[added.id] {
                        try acknowledge(pending)
                        expect(store.hotRegistrations[added.id]?.acknowledged == false, "old cancelled ACK cannot satisfy a new retry")
                        try acknowledge(retryPending)
                    } else { expect(false, "retry command emitted"); retry.cancel() }
                    await retry.value
                    expect(store.activeIDs.contains(added.id), "same identity cancellation retry completes without restart")
                }
                if scenario == "timeout" { expect(store.hotActivationErrors[added.id] == "timeout", "lost ACK times out and allows a bounded retry") }
                if scenario == "rejected" { expect(store.hotActivationErrors[added.id] == "cooldown_pending", "cooldown rejection is retained for display") }
            }
            _ = await store.handle(request("order_end", oldRequest, profile: ""))
            expect(child.isRunning, "\(scenario): activation leaves existing helper alive")
            store.process = nil; store.input = nil; store.phase = .stopped
            try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close()
        }
        LocalProxyQueueStore.issueQueue.sync {}
        let issues = try String(contentsOf: root.appendingPathComponent("operations-issues-v1.jsonl"), encoding: .utf8)
        expect(issues.contains("hot_activation_credentials_busy") && issues.contains("hot_activation_login_expired"), "fixed failure categories are traceable")
        expect(!issues.contains("@example.invalid") && !issues.contains("hot-new-") && !issues.contains("access_token"), "hot activation issues contain no account or credential data")
        // Run the production startup builder against an isolated, token-free
        // helper; inspect its actual stdin instead of copying the filter here.
        do {
            let first = profile("startup-bound")
            let disabled = profile("startup-disabled")
            let complete = profile("startup-pending")
            var pending = complete; pending.lastSnapshot?.accountID = nil
            var system = profile("startup-central"); system.isSystemProfile = true
            for candidate in [first, disabled, complete, system] { try writeCredentials(candidate) }
            let usage = UsageStore([system, first, disabled, pending]); usage.isPreview = false
            let store = LocalProxyQueueStore(usageStore: usage)
            store.preferences.knownIDs.insert(pending.id)
            store.rebuildRows()
            store.setAccountEnabled(id: first.id, enabled: true)
            store.setAccountEnabled(id: disabled.id, enabled: false)
            store.setOptIn(true)
            let python = ProcessInfo.processInfo.environment["PROXY_FIXTURE_PYTHON"]!
            let helper = "#!\(python)\n" + #"""
import json, sys
from pathlib import Path
s = json.loads(sys.stdin.readline())
Path("startup.json").write_text(json.dumps(s))
print(json.dumps({"event":"ready", "port":s["port"] or 54876}), flush=True)
for line in sys.stdin:
    c = json.loads(line)
    if c.get("command") == "stop": break
    if c.get("command") == "register_account":
        print(json.dumps({"event":"account_registered", "state":"registered", **{k:c[k] for k in ("runID","requestID","profileID","identityHash")}}), flush=True)
"""#
            try Data(helper.utf8).write(to: LocalProxyFixtureRuntime.helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: LocalProxyFixtureRuntime.helper.path)
            await store.start()
            if store.phase != .running { print("HOT_STARTUP_DIAGNOSTIC phase=\(store.phase.rawValue) issue=\(store.issue ?? "none") canStart=\(store.canStart)") }
            expect(store.phase == .running, "startup regression uses real startup control flow")
            if let folder = store.runDirectory {
                let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("startup.json"))) as! [String: Any]
                let accounts = (configuration["accounts"] as! [[String: String]]).compactMap { $0["id"] }
                let identityKeys = Set((configuration["accountIdentityHashes"] as! [String: String]).keys)
                expect(accounts == store.rows.filter { store.registeredPool[$0.id] != nil }.map(\.id), "startup sends bound accounts in saved row order")
                expect(Set(accounts) == identityKeys && identityKeys == store.runProfiles!.snapshot(), "startup helper, identity map and lease permissions have the same members")
                expect(!accounts.contains(pending.id) && accounts.contains(disabled.id) && !store.activeIDs.contains(disabled.id), "unverified row excluded while disabled verified member stays registered")
                usage.profiles[3] = complete
                store.rebuildRows()
                expect(store.canHotActivateAccount(id: complete.id), "later verified pending row can explicitly activate")
                await store.hotActivateAccount(id: complete.id)
                expect(store.activeIDs.contains(complete.id), "later verification joins through normal ACK and save gates")
            } else { expect(false, "synthetic startup receipt is available") }
            await store.stop()
            expect(store.canFinishTermination, "synthetic helper exits and owns no remaining lease")
        }
        // Exercise the exact shared permission holder used by off-main control callbacks.
        let permissions = LocalProxyRunProfiles(["old"])
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            if index.isMultiple(of: 2) { permissions.insert("new-\(index)") }
            precondition(permissions.snapshot().contains("old"))
        }
        expect(permissions.snapshot().count == 251, "concurrent permission reads/additions preserve every existing identity")
        print("HOT_ACTIVATION_RESULT checks=\(checks) failures=\(failures.count)")
        if !failures.isEmpty { throw HotActivationFixtureFailure(checks: failures) }
    }
}
