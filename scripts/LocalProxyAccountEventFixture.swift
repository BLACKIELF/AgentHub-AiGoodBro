import Combine
import Foundation

private struct AccountEventFixtureFailure: Error { let check: String }

extension LocalProxyHostFixtures {
    @MainActor static func accountEventPressureFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw AccountEventFixtureFailure(check: label) }
            checks += 1
        }
        let now = Date()
        let window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(3600))
        let profile = CodexProfile(id: "event-fixture", lastSnapshot: .init(fetchedAt: now, fiveHour: window, sevenDay: window))
        let store = LocalProxyQueueStore(usageStore: UsageStore([profile]))
        let run = UUID().uuidString
        store.runID = run
        store.activeIDs = [profile.id]
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        defer { observation.cancel(); store.displayPublishTask?.cancel() }
        func event(_ state: String, until: Double? = nil, id: String? = nil) throws -> Data {
            var payload: [String: Any] = ["event": "account", "profileID": id ?? profile.id, "state": state]
            if let until { payload["cooldownUntil"] = until }
            return try JSONSerialization.data(withJSONObject: payload)
        }
        let busy = try event("busy")
        store.consume(busy, run: run)
        try expect(store.accountStates[profile.id] == "busy" && store.rows.first?.state == "busy", "first busy event reaches current control rows")
        let initialPublications = publications
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10_000 { store.consume(busy, run: run) }
        try expect(publications == initialPublications, "10000 identical busy events cause no extra UI invalidations")
        print("ACCOUNT_EVENT_PRESSURE: duplicate batch seconds=\(ProcessInfo.processInfo.systemUptime - start), extra publications=\(publications - initialPublications)")

        for index in 0..<100 {
            let state = index.isMultiple(of: 2) ? "credentials_busy" : "busy"
            store.consume(try event(state), run: run)
            try expect(store.accountStates[profile.id] == state && store.rows.first?.state == state, "real state transitions remain immediately visible to control")
        }
        try expect(publications == initialPublications, "unchanged recovery candidates cannot bypass display throttling during real transitions")
        let deadline = now.addingTimeInterval(600).timeIntervalSince1970
        store.consume(try event("busy", until: deadline), run: run)
        try expect(store.cooldowns[profile.id] == Date(timeIntervalSince1970: deadline), "changed cooldown is retained even when state matches")
        store.consume(try event("busy", until: deadline + 1), run: run)
        try expect(store.rows.first?.cooldownUntil == Date(timeIntervalSince1970: deadline + 1), "cooldown extension reaches rows")
        store.consume(try event("busy", until: now.addingTimeInterval(-1).timeIntervalSince1970), run: run)
        try expect(store.cooldowns[profile.id] == nil && store.rows.first?.cooldownUntil == nil, "expired cooldown clears old projection")
        store.accountStates.removeValue(forKey: profile.id)
        store.rebuildRows()
        store.consume(busy, run: run)
        try expect(store.accountStates[profile.id] == "busy", "state cleared by refresh accepts a repeated event again")
        store.consume(try event("ready"), run: UUID().uuidString)
        store.consume(try event("ready", id: "removed-fixture"), run: run)
        store.consume(try event("invalid"), run: run)
        try expect(store.accountStates[profile.id] == "busy", "stale runs and invalid members or states remain ignored")
        store.flushDisplayRows()
        try expect(store.displayRows.first?.state == "busy", "manual publication shows latest state")
        let afterFlush = publications
        for _ in 0..<100 { store.rebuildRows() }
        try expect(publications == afterFlush, "unchanged explicit rebuilds do not invalidate SwiftUI")
        print("PASS: \(checks) production Store account-event checks; no live accounts or UI launched")
    }
}
