import Darwin
import Foundation

private struct DynamicHTTPFailure: Error {
    let label: String
    let detail: String
}

/// Compiled only by test-local-proxy-host.py with an isolated support directory.
/// Requests traverse the real native store/Unix bridge, Go router and local mock.
@MainActor private final class LocalProxyDynamicHTTPHarness {
    private(set) var store: LocalProxyQueueStore?
    private var usage: UsageStore?
    private let upstream: URL
    private let session: URLSession
    private(set) var checks: [[String: Any]] = []
    private(set) var requests: [[String: Any]] = []
    private var originalPID: pid_t?
    private let members = ["A", "B", "C"]

    init() throws {
        guard let raw = ProcessInfo.processInfo.environment["PROXY_DYNAMIC_UPSTREAM"],
            let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1", url.port != nil
        else { throw DynamicHTTPFailure(label: "fixture-boundary", detail: "loopback upstream required") }
        upstream = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    private func check(_ value: Bool, _ label: String, detail: String = "") throws {
        checks.append(["label": label, "ok": value, "detail": detail])
        print("DYNAMIC_HTTP_CHECK \(checks.count): \(label): \(value ? "pass" : "FAIL")\(detail.isEmpty ? "" : "; " + detail)")
        if !value { throw DynamicHTTPFailure(label: label, detail: detail) }
    }

    private func control(_ command: String, scenario: String = "", root: String? = nil) async throws {
        var request = URLRequest(url: upstream.appendingPathComponent("fixture/control"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var object = ["command": command, "case": scenario]
        if let root { object["root"] = root }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DynamicHTTPFailure(label: "mock-control", detail: "control request failed")
        }
    }

    private func status() async throws -> [String: Any] {
        let (data, response) = try await session.data(from: upstream.appendingPathComponent("fixture/status"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw DynamicHTTPFailure(label: "mock-status", detail: "status unavailable") }
        return result
    }

    private func waitForUpstream(_ scenario: String, account: String) async throws {
        for _ in 0..<150 {
            let value = try await status()
            let calls = value["calls"] as? [[String: Any]] ?? []
            if calls.contains(where: { $0["case"] as? String == scenario && $0["account"] as? String == account }) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw DynamicHTTPFailure(label: "upstream-barrier", detail: "mock did not receive expected account")
    }

    private func waitForCleanup() async throws {
        guard let store else { return }
        for _ in 0..<150 {
            if store.leases.isEmpty && store.membershipSnapshots.isEmpty { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw DynamicHTTPFailure(label: "request-cleanup", detail: "request ownership did not retire")
    }

    private func post(_ scenario: String, expecting account: String?, status wantedStatus: Int = 200) async throws -> String {
        guard let store, let endpoint = store.endpoint, let key = store.clientKey,
            let url = URL(string: endpoint + "/responses")
        else { throw DynamicHTTPFailure(label: "proxy-endpoint", detail: "running endpoint missing") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Identical session hints across fresh HTTP requests expose sticky reuse.
        request.setValue("dynamic-fixture-session", forHTTPHeaderField: "Session_id")
        request.setValue("dynamic-fixture-conversation", forHTTPHeaderField: "Conversation_id")
        request.setValue("dynamic-fixture-request", forHTTPHeaderField: "X-Request-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "fixture-model", "input": "dynamic:" + scenario, "stream": false,
            "prompt_cache_key": "dynamic-fixture-cache",
        ])
        let (data, response) = try await session.data(for: request)
        let responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseBody = String(decoding: data, as: UTF8.self)
        let actual = members.first { responseBody.contains("done-" + $0) }
        requests.append(["case": scenario, "status": responseStatus, "expected": account ?? "none", "actual": actual ?? "none"])
        try check(responseStatus == wantedStatus, "http-status-" + scenario, detail: "expected \(wantedStatus), got \(responseStatus)")
        if let account {
            try check(actual == account, "http-route-" + scenario, detail: "expected \(account), got \(actual ?? "none")")
        } else {
            try check(actual == nil, "http-zero-route-" + scenario)
        }
        try check(store.process?.processIdentifier == originalPID && store.phase == .running, "same-runtime-" + scenario)
        return actual ?? "none"
    }

    private func savedPreferences() throws -> LocalProxyPreferences {
        let url = DispatchParticipationPaths.supportDirectory().appendingPathComponent("local-proxy-queue-v1.json")
        return try JSONDecoder().decode(LocalProxyPreferences.self, from: Data(contentsOf: url))
    }

    private func membership(_ enabled: Set<String>, _ label: String) throws {
        guard let store else { return }
        let saved = try savedPreferences()
        let displayed = Set(store.displayRows.filter(\.isEnabled).map(\.id))
        try check(saved.enabledIDs == enabled, "persisted-" + label)
        try check(displayed == enabled, "displayed-" + label)
        try check(store.activeIDs == enabled, "runtime-membership-" + label,
            detail: "expected " + enabled.sorted().joined(separator: ",") + "; got " + store.activeIDs.sorted().joined(separator: ","))
    }

    private func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard let store else { return }
        try check(store.canToggleAccount(id: id), "editable-member-" + id)
        store.setAccountEnabled(id: id, enabled: enabled)
        store.flushDisplayRows()
    }

    private func restoreOrder() throws {
        guard let store, let usage else { return }
        for id in members {
            try setEnabled(id, true)
            store.setAccountPriority(id: id, priority: false)
            store.setAccountLast(id: id, last: false)
        }
        for (target, id) in members.enumerated() {
            while let position = store.rows.firstIndex(where: { $0.id == id }), position > target {
                guard store.canMoveAccount(id: id, by: -1) else {
                    throw DynamicHTTPFailure(label: "restore-order", detail: "fixture account move rejected")
                }
                store.moveAccount(id: id, by: -1)
            }
        }
        for index in usage.profiles.indices { usage.profiles[index].lastSnapshot?.fetchedAt = Date() }
        store.rebuildRows()
        store.flushDisplayRows()
        try membership(Set(members), "restored")
        try check(store.rows.map(\.id) == members, "restore-order")
    }

    func run() async throws {
        let root = DispatchParticipationPaths.supportDirectory()
        try check(root.path.contains("aigoodbro-proxy-host-fixture-"), "synthetic-support-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date()
        let five = CodexQuotaWindowSnapshot(usedPercent: 10, resetsAt: now.addingTimeInterval(18000))
        let seven = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(604800))
        func profile(_ id: String) -> CodexProfile {
            CodexProfile(id: id, lastSnapshot: CodexAccountSnapshot(planType: "plus", creditBalance: "3000", creditBalanceUnlimited: false,
                accountID: "account-" + id, email: id.lowercased() + "@example.invalid", fetchedAt: now, fiveHour: five, sevenDay: seven))
        }
        var system = profile("central"); system.isSystemProfile = true
        let profiles = members.map(profile) + [system]
        func jwt(_ claims: [String: Any]) throws -> String {
            let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "fixture.\(encoded).fixture"
        }
        for profile in profiles {
            try FileManager.default.createDirectory(at: profile.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let access = try jwt(["exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970 - 300, "account_id": profile.lastSnapshot!.accountID!])
            let idToken = try jwt(["email": profile.lastSnapshot!.email!, "account_id": profile.lastSnapshot!.accountID!])
            let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "id_token": idToken, "account_id": profile.lastSnapshot!.accountID!]])
            let auth = profile.codexHomeURL.appendingPathComponent("auth.json")
            try data.write(to: auth)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        }
        let usage = UsageStore(profiles); usage.isPreview = false
        self.usage = usage
        HubConsoleModel.fixtureAvailability = .idle
        let store = LocalProxyQueueStore(usageStore: usage)
        self.store = store
        for id in members { store.setAccountEnabled(id: id, enabled: true) }
        store.setOptIn(true)
        store.flushDisplayRows()
        try await control("register", root: root.path)
        await store.start()
        originalPID = store.process?.processIdentifier
        if store.phase != .running {
            let issues = root.appendingPathComponent("operations-issues-v1.jsonl")
            if let text = try? String(contentsOf: issues) { print("DYNAMIC_HTTP_START_DIAGNOSTIC: " + text) }
        }
        try check(store.phase == .running && originalPID != nil, "actual-native-host-start",
            detail: "phase=\(store.phase.rawValue); opt-in=\(store.isEnabled); preference-failure=\(store.preferencesFailure != nil); issue=\(store.issue ?? "none")")
        try membership(Set(members), "baseline")
        _ = try await post("baseline", expecting: "A")
        try await waitForCleanup()

        try setEnabled("A", false)
        try membership(["B", "C"], "disable-A")
        _ = try await post("disable-A", expecting: "B")
        try await waitForCleanup()

        store.setAccountPriority(id: "C", priority: true); store.flushDisplayRows()
        try check(try savedPreferences().priorityIDs.contains("C") && store.displayRows.first?.id == "C", "persisted-displayed-priority-C")
        _ = try await post("priority-C", expecting: "C")
        try await waitForCleanup()

        store.setAccountLast(id: "C", last: true); store.flushDisplayRows()
        let last = try savedPreferences()
        try check(last.lastOverrides?["C"] == true && !last.priorityIDs.contains("C") && store.displayRows.last?.id == "C", "persisted-displayed-last-C")
        _ = try await post("last-C", expecting: "B")
        try await waitForCleanup()

        try check(store.canMoveAccount(id: "C", by: -1), "cross-group-move-C-available")
        store.moveAccount(id: "C", by: -1); store.flushDisplayRows()
        let moved = try savedPreferences()
        try check(moved.order == ["A", "C", "B"] && moved.lastOverrides?["C"] == false, "persisted-cross-group-move-C")
        _ = try await post("move-C", expecting: "C")
        try await waitForCleanup()

        for id in members { try setEnabled(id, false) }
        try membership([], "all-off")
        let beforeEmpty = (try await status()["calls"] as? [[String: Any]] ?? []).count
        _ = try await post("all-off", expecting: nil, status: 503)
        try await waitForCleanup()
        let afterEmpty = (try await status()["calls"] as? [[String: Any]] ?? []).count
        try check(beforeEmpty == afterEmpty, "all-off-zero-upstream")

        try restoreOrder()
        let held = Task { try await self.post("overlap", expecting: "A") }
        try await waitForUpstream("overlap", account: "A")
        try check(store.leases.values.contains { $0.profileID == "A" && $0.isAdmitted }, "overlap-A-admitted-before-toggle")
        try setEnabled("A", false)
        try membership(["B", "C"], "overlap-disable-A")
        _ = try await post("overlap-next", expecting: "B")
        let overlapState = try await status()
        try check((overlapState["released"] as? [String] ?? []).contains("overlap") == false, "old-A-still-held-during-new-B")
        try await control("release", scenario: "overlap")
        _ = try await held.value
        try await waitForCleanup()
        try check(store.rows.first(where: { $0.id == "A" })?.isCurrent == false, "old-A-retired-after-completion")

        // The old request has A/B/C frozen; B is removed before any B dispatch.
        try restoreOrder()
        let retry = Task { try await self.post("revoked-retry", expecting: "C") }
        try await waitForUpstream("revoked-retry", account: "A")
        try check(store.membershipSnapshots.values.contains { $0.order == members }, "retry-captured-old-A-B-C-order")
        try setEnabled("B", false)
        try membership(["A", "C"], "retry-disable-B")
        try await control("release", scenario: "revoked-retry")
        _ = try await retry.value
        try await waitForCleanup()
        let finalStatus = try await status()
        let retryCalls = (finalStatus["calls"] as? [[String: Any]] ?? [])
            .filter { $0["case"] as? String == "revoked-retry" }.compactMap { $0["account"] as? String }
        try check(retryCalls == ["A", "C"], "old-retry-skips-disabled-B-upstream", detail: "expected A,C; got " + retryCalls.joined(separator: ","))
        try check((finalStatus["failures"] as? [String] ?? []).isEmpty, "upstream-validates-credential-and-native-lease")
        let reopened = LocalProxyQueueStore(usageStore: usage)
        try check(reopened.rows.first(where: { $0.id == "B" })?.isEnabled == false, "disabled-B-persists-on-reopen")
        try check(usage.profiles.allSatisfy { !$0.isDispatchPriorityEnabled }, "controls-preserve-independent-dispatch-flags")
    }

    func finish() async {
        try? await control("release", scenario: "overlap")
        try? await control("release", scenario: "revoked-retry")
        session.invalidateAndCancel()
        if let store { await store.stop() }
    }

    func writeResult(failure: DynamicHTTPFailure?) throws {
        guard let evidence = ProcessInfo.processInfo.environment["PROXY_DYNAMIC_HTTP_EVIDENCE"] else { return }
        let object: [String: Any] = [
            "schemaVersion": 1, "ok": failure == nil, "checks": checks, "requests": requests,
            "failure": failure.map { ["label": $0.label, "detail": $0.detail] } ?? [:],
            "mutation": ProcessInfo.processInfo.environment["PROXY_DYNAMIC_HTTP_MUTATION"] ?? "",
            "runtimeStopped": store?.canFinishTermination == true,
            "realAccountsOrProviders": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: evidence).appendingPathComponent("result.json"))
    }
}

@main struct LocalProxyDynamicHTTPFixture {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        var harness: LocalProxyDynamicHTTPHarness?
        var failure: DynamicHTTPFailure?
        do {
            harness = try LocalProxyDynamicHTTPHarness()
            try await harness!.run()
        } catch let error as DynamicHTTPFailure {
            failure = error
        } catch {
            failure = DynamicHTTPFailure(label: "fixture-operation", detail: String(describing: type(of: error)))
        }
        await harness?.finish()
        do { try harness?.writeResult(failure: failure) } catch {
            failure = DynamicHTTPFailure(label: "evidence-write", detail: "result could not be saved")
        }
        if let failure {
            print("DYNAMIC_HTTP_FAILURE: \(failure.label); \(failure.detail)")
            exit(1)
        }
        print("PASS: actual native controls, persisted queue, Unix bridge, Go runtime and loopback HTTP routes")
    }
}
