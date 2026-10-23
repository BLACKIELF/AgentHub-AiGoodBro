import Darwin
import Foundation

// Installed only into the disposable compiled transport configuration. Every
// URL is intercepted, including unexpected URLs, before any socket is opened.
final class LocalProxyProbeURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var body = Data(#"{"rate_limit":{}}"#.utf8)
        var hold = false
        var failure = false
        var redirect: URL? = nil
    }
    private static let lock = NSLock()
    private static var plans: [Response] = []
    private static var observed: [(URLRequest, TimeInterval)] = []
    private static var held: [(LocalProxyProbeURLProtocol, Response)] = []
    private let deliveryLock = NSRecursiveLock()
    private var stopped = false

    static func reset(_ responses: [Response]) {
        lock.lock(); defer { lock.unlock() }
        plans = responses; observed = []; held = []
    }
    static var requests: [(URLRequest, TimeInterval)] {
        lock.lock(); defer { lock.unlock() }; return observed
    }
    static func releaseHeld(_ count: Int = Int.max) {
        lock.lock(); let pending = Array(held.prefix(count)); held.removeFirst(pending.count); lock.unlock()
        for (transport, response) in pending { transport.deliver(response) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.observed.append((request, Date().timeIntervalSince1970))
        let response = Self.plans.isEmpty ? Response(failure: true) : Self.plans.removeFirst()
        if response.hold { Self.held.append((self, response)) }
        Self.lock.unlock()
        if !response.hold { deliver(response) }
    }
    override func stopLoading() {
        deliveryLock.lock(); stopped = true; deliveryLock.unlock()
    }
    private func deliver(_ response: Response) {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        guard !stopped else { return }
        if response.failure {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let url = request.url!
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": String(response.body.count)])!
        if let destination = response.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: http)
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct ProbeFixtureFailure: Error { let checks: [String] }
private enum ProbeFixtureGates {
    static func available(_ gates: [NSRecursiveLock]) -> Bool {
        var held: [NSRecursiveLock] = []; defer { held.reversed().forEach { $0.unlock() } }
        for gate in gates { guard gate.try() else { return false }; held.append(gate) }
        return true
    }
}

extension LocalProxyHostFixtures {
    @MainActor static func networkProbeFixtures() async throws {
        var checks = 0
        var failures: [String] = []
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
            checks += 1
            let passed = try value()
            print("PROBE_CHECK \(checks): \(passed ? "PASS" : "FAIL") \(label)")
            if !passed { failures.append(label) }
        }
        func waitForRequests(_ count: Int) async throws {
            for _ in 0..<200 {
                if LocalProxyProbeURLProtocol.requests.count >= count { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ProbeFixtureFailure(checks: ["mock HTTP request did not start"])
        }
        let root = DispatchParticipationPaths.supportDirectory()
        expect(root.path.contains("aigoodbro-proxy-host-fixture-"), "isolated synthetic support root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date()
        let exhausted = CodexQuotaWindowSnapshot(usedPercent: 100, resetsAt: now.addingTimeInterval(3600))
        func profile(_ id: String, account: String) -> CodexProfile {
            CodexProfile(id: id, lastSnapshot: .init(planType: "plus", accountID: account, email: account + "@example.invalid",
                fetchedAt: now, fiveHour: exhausted, sevenDay: exhausted))
        }
        let peer = profile("00000000-0000-4000-8000-000000000001", account: "probe-peer")
        let other = profile("00000000-0000-4000-8000-000000000002", account: "probe-other")
        let desktop = profile("00000000-0000-4000-8000-000000000003", account: "probe-desktop")
        var central = profile("probe-system", account: "probe-desktop"); central.isSystemProfile = true
        func writeCredentials(_ candidate: CodexProfile, generation: Int = 0, accountOverride: String? = nil) throws -> String {
            func jwt(_ claims: [String: Any]) throws -> String {
                let payload = try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return "fixture.\(payload).fixture"
            }
            let account = accountOverride ?? candidate.lastSnapshot!.accountID!
            let token = try jwt(["exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970 - 300,
                "account_id": account, "fixture_generation": generation])
            let identity = try jwt(["email": candidate.lastSnapshot!.email!, "account_id": account])
            let bytes = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": token, "id_token": identity, "account_id": account]])
            try FileManager.default.createDirectory(at: candidate.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = candidate.codexHomeURL.appendingPathComponent("auth.json")
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return token
        }
        let peerToken = try writeCredentials(peer)
        for candidate in [other, desktop, central] { _ = try writeCredentials(candidate) }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["90"]
        try child.run()
        defer { LocalProxyProbeURLProtocol.releaseHeld(); if child.isRunning { child.terminate() } }
        let usage = UsageStore([peer, other, desktop, central]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage)
        let run = UUID().uuidString
        let key = "synthetic-probe-control"
        store.process = child; store.phase = .running; store.runID = run; store.controlKey = key
        store.preferences.isEnabled = true
        store.preferences.enabledIDs = [peer.id, other.id, desktop.id]
        store.preferences.knownIDs = store.preferences.enabledIDs
        store.activeIDs = store.preferences.enabledIDs
        store.registeredPool = Dictionary(uniqueKeysWithValues: [peer, other, desktop].map {
            ($0.id, LocalProxyQueueStore.PoolBinding(home: $0.codexHomeURL, account: $0.recordedAccountKey, accountID: $0.lastSnapshot!.accountID!))
        })
        func request(profile: String? = nil, runID: String? = nil, controlKey: String? = nil, lease: String? = nil, id: String? = nil) -> LocalProxyRequest {
            .init(schemaVersion: 1, runID: runID ?? run, key: controlKey ?? key, command: "egress_probe",
                  requestID: id ?? UUID().uuidString, profileID: profile ?? peer.id, leaseID: lease)
        }
        func noProof(_ reply: LocalProxyReply) -> Bool {
            !reply.ok && reply.probeStatus == nil && reply.probeObservedAt == nil && reply.probeIdentityHash == nil && reply.accessToken == nil && reply.leaseID == nil
        }
        // Proof is pure, fresh and tied to the actual request start. Quota is not
        // an admission requirement for this fixed read-only usage endpoint.
        LocalProxyProbeURLProtocol.reset([.init()])
        let started = Date().timeIntervalSince1970
        let proof = await store.handle(request())
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as! [String: Any]
        expect(proof.ok && proof.probeStatus == "reachable", "quota-exhausted account can perform a read-only reachability probe")
        expect(Set(wire.keys) == ["ok", "probeStatus", "probeObservedAt", "probeIdentityHash"], "proof carries no lease, raw identity, token or quota state")
        expect(proof.probeIdentityHash == DispatchActivityStore.hash(peer.lastSnapshot!.accountID!), "proof identity hash matches the credential account")
        let observed = LocalProxyProbeURLProtocol.requests
        expect(observed.count == 1 && proof.probeObservedAt! >= started && proof.probeObservedAt! <= observed[0].1,
               "proof observation is actual current request start, before response")
        expect(observed[0].0.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage" && observed[0].0.httpMethod == "GET",
               "probe uses only fixed official GET endpoint")
        expect(observed[0].0.value(forHTTPHeaderField: "Authorization") == "Bearer " + peerToken
               && observed[0].0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == peer.lastSnapshot!.accountID,
               "official headers are built from verified credential identity")
        expect(store.leases.isEmpty && store.membershipSnapshots.isEmpty && usage.refreshCount == 0,
               "probe creates no lease, membership order or quota refresh")
        for invalid in [request(runID: UUID().uuidString), request(controlKey: "wrong"), request(lease: UUID().uuidString), request(id: "invalid"), request(profile: UUID().uuidString)] {
            LocalProxyProbeURLProtocol.reset([])
            let denied = await store.handle(invalid)
            expect(noProof(denied), "invalid bridge envelope fails without a proof")
            expect(LocalProxyProbeURLProtocol.requests.isEmpty, "invalid bridge envelope does not start HTTP")
        }
        for (status, body, wanted) in [(401, "{}", "unauthorized"), (403, "{}", "unauthorized"),
                                     (500, "{}", "unreachable"), (200, "[]", "unreachable"),
                                     (200, "{}", "unreachable"), (200, #"{"plan_type":"plus"}"#, "reachable")] {
            LocalProxyProbeURLProtocol.reset([.init(status: status, body: Data(body.utf8))])
            let reply = await store.handle(request())
            expect(reply.ok && reply.probeStatus == wanted, "HTTP \(status) shape maps to bounded \(wanted) proof")
        }
        LocalProxyProbeURLProtocol.reset([.init(failure: true)])
        let failed = await store.handle(request())
        expect(noProof(failed) && failed.error == "unavailable", "transport errors have fixed non-sensitive failure")
        LocalProxyProbeURLProtocol.reset([.init(body: Data(repeating: 65, count: 262145))])
        let oversized = await store.handle(request())
        expect(noProof(oversized), "oversized official body cannot become a proof")
        // The writer and either home gate must be rejected immediately. Locks
        // are held by a separate GCD thread, so recursive ownership cannot pass.
        for (label, gate) in [("global", CodexCredentialAccessGate.lock),
            ("managed home", CodexCredentialAccessGate.homeLock(forHomePath: peer.codexHomeURL.path)),
            ("system home", CodexCredentialAccessGate.homeLock(forHomePath: central.codexHomeURL.path))] {
            let release = DispatchSemaphore(value: 0)
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { gate.lock(); continuation.resume(); release.wait(); gate.unlock() }
            }
            LocalProxyProbeURLProtocol.reset([])
            let began = ProcessInfo.processInfo.systemUptime
            let reply = await store.handle(request())
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            release.signal()
            expect(noProof(reply) && reply.error == "credentials_busy" && elapsed < 0.75,
                   "\(label) writer contention returns promptly with credentials_busy")
            expect(LocalProxyProbeURLProtocol.requests.isEmpty, "\(label) lock contention starts no HTTP")
        }
        // Gates must be available while HTTP is held; the request cannot keep a
        // credential writer blocked during network latency.
        LocalProxyProbeURLProtocol.reset([.init(hold: true)])
        let unlockedTask = Task { await store.handle(request()) }
        try await waitForRequests(1)
        let gatesFree = await Task.detached { [central] () -> Bool in
            let gates = [CodexCredentialAccessGate.lock,
                CodexCredentialAccessGate.homeLock(forHomePath: peer.codexHomeURL.path),
                CodexCredentialAccessGate.homeLock(forHomePath: central.codexHomeURL.path)]
            return ProbeFixtureGates.available(gates)
        }.value
        expect(gatesFree, "credential gates are released for the whole HTTP wait")
        LocalProxyProbeURLProtocol.releaseHeld()
        let unlocked = await unlockedTask.value
        expect(unlocked.ok, "unchanged held HTTP response yields a proof")
        // Two accounts fit the host capacity, a duplicate and a third account do
        // not create another HTTP request or block the main actor.
        LocalProxyProbeURLProtocol.reset([.init(hold: true), .init(hold: true)])
        let first = Task { await store.handle(request()) }
        try await waitForRequests(1)
        let second = Task { await store.handle(request(profile: other.id)) }
        try await waitForRequests(2)
        let duplicate = await store.handle(request())
        let excess = await store.handle(request(profile: desktop.id))
        expect(duplicate.error == "credentials_busy" && excess.error == "credentials_busy" && LocalProxyProbeURLProtocol.requests.count == 2,
               "probe is per-account single flight with two global slots")
        LocalProxyProbeURLProtocol.releaseHeld(1)
        let firstReply = await first.value
        LocalProxyProbeURLProtocol.releaseHeld()
        let secondReply = await second.value
        expect(firstReply.ok && secondReply.ok, "both bounded concurrent probes finish")
        // A late successful HTTP response must never rehabilitate an account
        // whose participation, run, credential bytes or identity changed.
        for scenario in ["revoked", "run changed", "credential rotated", "identity changed", "cancelled"] {
            LocalProxyProbeURLProtocol.reset([.init(hold: true)])
            let task = Task { await store.handle(request()) }
            try await waitForRequests(1)
            switch scenario {
            case "revoked":
                store.setAccountEnabled(id: peer.id, enabled: false)
                store.setAccountEnabled(id: peer.id, enabled: true)
            case "run changed": store.runID = UUID().uuidString
            case "credential rotated": _ = try writeCredentials(peer, generation: 1)
            case "identity changed": _ = try writeCredentials(peer, accountOverride: "different-account")
            default: task.cancel()
            }
            LocalProxyProbeURLProtocol.releaseHeld()
            let reply = await task.value
            expect(noProof(reply), "late successful response is refused after \(scenario)")
            store.runID = run
            _ = try writeCredentials(peer)
        }
        // A pre-existing mismatch is rejected before a network request too.
        _ = try writeCredentials(peer, accountOverride: "different-account")
        LocalProxyProbeURLProtocol.reset([])
        let mismatchReply = await store.handle(request())
        expect(noProof(mismatchReply) && LocalProxyProbeURLProtocol.requests.isEmpty,
               "credential identity mismatch fails before HTTP")
        _ = try writeCredentials(peer)
        store.activeIDs.remove(peer.id)
        let removedReply = await store.handle(request())
        expect(removedReply.error == "not_participating", "removed pool member cannot probe")
        store.activeIDs.insert(peer.id)
        // Desktop proof must use the current central session, even if the saved
        // managed session is a different generation of the same identity.
        let centralToken = try writeCredentials(central, generation: 4)
        LocalProxyProbeURLProtocol.reset([.init()])
        let desktopProof = await store.handle(request(profile: desktop.id))
        expect(desktopProof.ok && LocalProxyProbeURLProtocol.requests.first?.0.value(forHTTPHeaderField: "Authorization") == "Bearer " + centralToken,
               "enrolled desktop account probes with the verified current central credential")
        // Client endpoint checks require the actual models schema and exact
        // loopback route, and discovery follows actual Selector members.
        for endpoint in ["http://example.invalid/v1", "https://127.0.0.1:18080/v1", "http://127.0.0.1:18080/other", "http://user@127.0.0.1:18080/v1"] {
            LocalProxyProbeURLProtocol.reset([])
            let ok = try await LocalProxyNetworkProbe.models(endpoint: endpoint, key: "synthetic-client")
            expect(!ok && LocalProxyProbeURLProtocol.requests.isEmpty, "models rejects an unexpected endpoint before HTTP")
        }
        for (status, body, wanted) in [(200, #"{"object":"list","data":[{"id":"fixture-model"}]}"#, true),
            (401, "{}", false), (200, #"{"object":"list","data":[]}"#, false),
            (200, #"{"object":"list","data":[{"id":""}]}"#, false), (200, "{}", false)] {
            LocalProxyProbeURLProtocol.reset([.init(status: status, body: Data(body.utf8))])
            let ok = try await LocalProxyNetworkProbe.models(endpoint: "http://127.0.0.1:18080/v1", key: "synthetic-client")
            expect(ok == wanted, "models validates status and nonempty model IDs")
            expect(LocalProxyProbeURLProtocol.requests[0].0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-client", "models verifies with current client key")
        }
        var settings = LocalProxyEgressSettings(); settings.enabled = true; settings.mihomoAPI = "http://127.0.0.1:9097"; settings.group = "fixture-group"; settings.mihomoSecret = "synthetic-controller"
        let hongKong = ["香港-01", "🇭🇰-02", "Hong Kong 03", "Hongkong-04", "HK01", "[HK] 05", "HKG-06", "港01", "港区-02"]
        for name in hongKong { expect(LocalProxyNetworkProbe.isHongKongNode(name), "Hong Kong marker is excluded") }
        for name in ["新加坡-01", "日本-02", "US-03", "Shikoku", "ShkRoute", "BHK-01", "Hokkaido"] {
            expect(!LocalProxyNetworkProbe.isHongKongNode(name), "non-Hong-Kong node is retained without substring false positives")
        }
        let singapore = "新加坡-01", japan = "日本-02", usa = "US-03", outside = "outside-group", missing = "missing-node"
        let excludedTypes = ["Direct", "Reject", "RejectDrop", "Compatible", "Pass", "PassRule", "Rematch", "Dns", "Unknown",
            "Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]
        var proxies: [String: Any] = [
            singapore: ["type": "Shadowsocks"], japan: ["type": "Trojan"], usa: ["type": "Vmess"], outside: ["type": "Socks5"],
            "untyped": [:], "empty-type": ["type": ""], "nested-group": ["type": "FutureGroup", "all": [singapore]],
            "bad\nnode": ["type": "Http"], " spaced ": ["type": "Http"],
        ]
        for type in excludedTypes { proxies["adapter-" + type] = ["type": type] }
        for name in hongKong { proxies[name] = ["type": "Shadowsocks"] }
        let members = [singapore, missing, japan, singapore, usa, "untyped", "empty-type", "nested-group", "bad\nnode", " spaced "]
            + excludedTypes.map { "adapter-" + $0 } + hongKong
        proxies[settings.group] = ["type": "Selector", "all": members]
        let catalog: [String: Any] = ["proxies": proxies]
        LocalProxyProbeURLProtocol.reset([.init(body: try JSONSerialization.data(withJSONObject: catalog))])
        let discovered = try await LocalProxyNetworkProbe.selectorNodes(settings: settings)
        expect(discovered == [singapore, japan, usa], "discovery accepts every region in current Selector order and removes duplicates")
        expect(!discovered.contains(outside) && !discovered.contains(missing), "discovery excludes missing nodes and nodes outside the chosen group")
        expect(discovered.allSatisfy { !($0.hasPrefix("adapter-") || $0.contains("\n")) },
            "discovery excludes routing adapters, all group types, untyped and unsafe members")
        let discovery = LocalProxyProbeURLProtocol.requests[0].0
        expect(discovery.httpMethod == "GET" && discovery.url?.absoluteString == "http://127.0.0.1:9097/proxies"
               && discovery.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-controller", "controller discovery is read-only authenticated loopback GET")
        for invalidGroup in [["type": "URLTest", "all": [singapore]], ["type": "Selector", "all": "invalid"]] as [[String: Any]] {
            LocalProxyProbeURLProtocol.reset([.init(body: try JSONSerialization.data(withJSONObject: ["proxies": [settings.group: invalidGroup]]))])
            do {
                _ = try await LocalProxyNetworkProbe.selectorNodes(settings: settings)
                expect(false, "invalid selector shape must be rejected")
            } catch { expect(true, "non-Selector or malformed group cannot supply candidate nodes") }
        }
        for value in [" fixture", "fixture ", "a\0b", "a\nb"] {
            var bad = settings; bad.group = value; expect(!bad.isValid, "unsafe controller group rejected")
            bad = settings; bad.whitelist = [value]; expect(!bad.isValid, "unsafe whitelist node rejected")
        }
        for address in ["http://localhost:9097", "http://example.invalid:9097", "http://127.0.0.1:9097/path", "http://user@127.0.0.1:9097", "http://127.0.0.1:9097?token=x"] {
            var bad = settings; bad.mihomoAPI = address
            expect(!bad.isValid, "unsafe controller address rejected consistently with helper")
        }
        var secret = settings; secret.mihomoSecret = "a\0b"
        expect(!secret.isValid, "NUL in controller secret rejected")
        // All five self-check results are concrete and request-correlated. The
        // runner explicitly replaces OS proxy discovery with an empty fixture.
        store.rows = [LocalProxyQueueRow(id: desktop.id, label: "synthetic desktop", isDesktopAccount: true,
            isEnabled: true, isPriority: false, isCurrent: false, quotaText: nil, state: "ready", cooldownUntil: nil),
            LocalProxyQueueRow(id: peer.id, label: "synthetic unknown", isEnabled: true, isPriority: false, isCurrent: false,
                quotaText: nil, state: "quota_unknown", cooldownUntil: nil)]
        store.endpoint = "http://127.0.0.1:18080/v1"; store.clientKey = "synthetic-client"
        store.egressSettings = settings
        LocalProxyProbeURLProtocol.reset([.init(), .init(body: Data(#"{"object":"list","data":[{"id":"fixture-model"}]}"#.utf8))])
        store.runSelfCheck()
        let checkID = store.selfCheckRequestID!
        store.consumeEgress(["state": "healthy", "requestID": UUID().uuidString, "latencyMS": 10])
        expect(store.selfCheck.steps.first { $0.id == "egress" }?.passed == nil, "unrelated self-check event cannot complete current egress result")
        store.consumeEgress(["state": "healthy", "requestID": checkID, "latencyMS": 10])
        await store.selfCheckTask?.value
        expect(store.selfCheck.steps.map(\.id) == ["system", "egress", "official", "endpoint", "pool"], "self-check contains exactly five intended items")
        expect(!store.selfCheck.isRunning && store.selfCheck.steps.allSatisfy { $0.passed != nil }, "all self-check items finish")
        expect(store.selfCheck.steps.filter { $0.passed == true }.count == 4 && store.selfCheck.steps[0].passed == false,
               "synthetic no-system-proxy result is distinct from four successful actual checks")
        expect(store.selfCheck.steps.last?.detail.contains("未确认 1") == true, "pool status includes unconfirmed accounts")
        expect(LocalProxyProbeURLProtocol.requests.allSatisfy { $0.0.httpMethod == "GET" }, "self-check only performs reads")
        store.egressSettings = LocalProxyEgressSettings()
        LocalProxyProbeURLProtocol.reset([.init(), .init(body: Data(#"{"object":"list","data":[{"id":"fixture-model"}]}"#.utf8))])
        store.runSelfCheck()
        store.consumeEgress(["state": "disabled", "requestID": store.selfCheckRequestID!])
        await store.selfCheckTask?.value
        expect(store.selfCheck.steps.first { $0.id == "egress" }?.passed == true
            && store.selfCheck.steps.first { $0.id == "egress" }?.detail == "跟随系统代理，自动切换未开启",
            "default self-check reports optional switching disabled without claiming node health")
        expect(LocalProxyProbeURLProtocol.requests.count == 2
            && LocalProxyProbeURLProtocol.requests.allSatisfy { $0.0.url?.port != 9097 },
            "default self-check verifies official backend and models without a controller connection")
        // A fixed-port mismatch must never publish a different usable endpoint.
        let mismatch = LocalProxyQueueStore(usageStore: usage)
        mismatch.phase = .starting; mismatch.runID = UUID().uuidString; mismatch.preferences.listenPort = 18080
        mismatch.consume(try JSONSerialization.data(withJSONObject: ["event": "ready", "port": 18081]), run: mismatch.runID!)
        expect(mismatch.endpoint == nil && mismatch.phase != .running, "fixed startup rejects a mismatched ready port")
        if !failures.isEmpty { throw ProbeFixtureFailure(checks: failures) }
        print("PASS: \(checks) network probe checks; production HTTP/credential/proof code, URLProtocol-only synthetic responses, no external sockets or real accounts")
    }
}
