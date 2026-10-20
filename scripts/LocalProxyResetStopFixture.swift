import Darwin
import Foundation

extension LocalProxyHostFixtures {
    @MainActor static func resetStopFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
            let passed = try value()
            precondition(passed, label)
            checks += 1
            print("RESET_STOP_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        precondition(root.path.contains("aigoodbro-proxy-host-fixture-"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date()
        let window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(3600))
        func profile(_ id: String) -> CodexProfile {
            .init(id: id, lastSnapshot: .init(planType: "plus", accountID: id + "-account", email: id + "@example.invalid",
                fetchedAt: now, fiveHour: window, sevenDay: window))
        }
        let member = profile("reset-member"), peer = profile("reset-peer")
        func writeCredentials(_ candidate: CodexProfile) throws {
            func jwt(_ claims: [String: Any]) throws -> String {
                let body = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return "fixture.\(body).fixture"
            }
            try FileManager.default.createDirectory(at: candidate.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let id = candidate.lastSnapshot!.accountID!, email = candidate.lastSnapshot!.email!
            let access = try jwt(["exp": now.timeIntervalSince1970 + 3600, "account_id": id])
            let identity = try jwt(["email": email, "account_id": id])
            let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "id_token": identity, "account_id": id]])
            let file = candidate.codexHomeURL.appendingPathComponent("auth.json")
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        for candidate in [member, peer] { try writeCredentials(candidate) }
        let usage = UsageStore([member, peer]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage)
        expect(!usage.proxyQuotaResetObservationEnabled && store.preferences.resetStopRules == nil,
            "existing settings keep quota-reset automation off by default")
        store.setResetStop(id: member.id, enabled: true)
        expect(usage.proxyQuotaResetObservationEnabled && store.preferences.resetStopRules?[member.id]?.isValid == true,
            "explicit opt-in persists an account-bound valid rule")
        let armedAt = store.preferences.resetStopRules![member.id]!.armedAt
        let ruleData = try Data(contentsOf: root.appendingPathComponent("local-proxy-queue-v1.json"))
        let saved = try JSONDecoder().decode(LocalProxyPreferences.self, from: ruleData)
        expect(saved.validResetStopRules && saved.resetStopRules == store.preferences.resetStopRules,
            "reset rule survives schema1 encoding without changing previous choices")
        expect(!String(decoding: ruleData, as: UTF8.self).contains("@"), "rule stores no email or credential")
        func signal(_ id: String = member.id, _ account: String? = nil, _ at: Date = Date()) {
            usage.onProxyOfficialQuotaReset?(id, account ?? member.lastSnapshot!.accountID!, at)
        }
        signal(member.id, nil, armedAt.addingTimeInterval(-1))
        signal(peer.id, nil)
        signal(member.id, "foreign-account")
        signal(member.id, nil, Date().addingTimeInterval(-61))
        signal(member.id, nil, Date().addingTimeInterval(60))
        expect(store.preferences.enabledIDs.contains(member.id), "old, stale, future and foreign account signals do not pause")
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["90"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; LocalProxyFixtureRuntime.failPreferenceRename = false }
        store.process = child; store.phase = .running; store.runID = UUID().uuidString; store.controlKey = "reset-fixture-key"
        store.registeredPool = Dictionary(uniqueKeysWithValues: [member, peer].map {
            ($0.id, LocalProxyQueueStore.PoolBinding(home: $0.codexHomeURL, account: $0.recordedAccountKey, accountID: $0.lastSnapshot!.accountID!))
        })
        store.activeIDs = [member.id, peer.id]
        HubConsoleModel.fixtureAvailability = .idle
        defer { HubConsoleModel.fixtureAvailability = .unavailable }
        func requestID() -> String {
            let time = String(format: "%012llx", UInt64(Date().timeIntervalSince1970 * 1000))
            let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return "\(time.prefix(8))-\(time.suffix(4))-7\(random.prefix(3))-a\(random.dropFirst(3).prefix(3))-\(random.dropFirst(6).prefix(12))"
        }
        func request(_ command: String, id: String, target: String = member.id, lease: String? = nil) -> LocalProxyRequest {
            .init(schemaVersion: 1, runID: store.runID!, key: "reset-fixture-key", command: command,
                requestID: id, profileID: target, leaseID: lease)
        }
        let heldID = requestID(), waitingID = requestID()
        _ = await store.handle(request("order", id: heldID))
        let held = await store.handle(request("acquire", id: heldID))
        expect(held.ok && held.leaseID != nil, "synthetic production host admits the current response before reset")
        _ = await store.handle(request("order", id: waitingID))
        let leaseBytes = try Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))
        let resetAt = Date(); signal(member.id, nil, resetAt)
        store.flushDisplayRows()
        expect(!store.preferences.enabledIDs.contains(member.id) && !store.activeIDs.contains(member.id), "verified reset immediately stops new assignments")
        expect(store.preferences.enabledIDs.contains(peer.id) && store.activeIDs.contains(peer.id), "unselected peer keeps participation")
        expect(store.preferences.resetStopRules?[member.id]?.pausedAt == resetAt
            && store.displayRows.first(where: { $0.id == member.id })?.resetPausedAt == resetAt,
            "paused state is durable and visible on the same account")
        try expect(Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName)) == leaseBytes
            && child.isRunning && store.leases[held.leaseID!]?.isAdmitted == true,
            "pause leaves the helper and admitted response lease untouched")
        let refused = await store.handle(request("acquire", id: waitingID))
        expect(refused.error == "not_participating" && refused.accessToken == nil, "old waiting request cannot admit after reset")
        let newOrder = await store.handle(request("order", id: requestID()))
        expect(newOrder.ok && newOrder.order == [peer.id], "new orders exclude the paused account")
        let release = await store.handle(request("release", id: heldID, lease: held.leaseID))
        expect(release.ok, "current response still completes its normal release")
        store.setAccountEnabled(id: member.id, enabled: true)
        let resumedAt = store.preferences.resetStopRules![member.id]!.armedAt
        signal(member.id, nil, resetAt)
        expect(store.preferences.enabledIDs.contains(member.id) && resumedAt > resetAt
            && store.preferences.resetStopRules?[member.id]?.pausedAt == nil,
            "manual resume rearms and ignores the old reset callback")
        let oldRetry = await store.handle(request("acquire", id: waitingID))
        expect(oldRetry.error == "not_participating", "resume does not revive old waiting requests")
        store.setResetStop(id: member.id, enabled: false)
        signal()
        expect(!usage.proxyQuotaResetObservationEnabled && store.preferences.enabledIDs.contains(member.id), "opt-out does not change participation or pause on later events")
        store.setResetStop(id: member.id, enabled: true)
        LocalProxyFixtureRuntime.failPreferenceRename = true
        signal()
        expect(store.preferencesFailure == .save && store.preferences.enabledIDs.contains(member.id),
            "failed save preserves previous preference and publishes its error")
        expect(store.preferencesBlocked, "failed pause persistence blocks unsafe new admissions")
        print("PASS: \(checks) reset-stop host checks; synthetic identities and registry only")
    }
}
