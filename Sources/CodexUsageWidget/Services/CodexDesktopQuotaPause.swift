import Foundation

/// Uses the official app-server protocol; account replacement remains in the
/// existing native switch transaction. No kill signals or new prompts are sent.
enum CodexDesktopQuotaPause {
    static let enabledDefaultsKey = "AiGoodBro.quotaPauseAtOnePercent.enabled"
    static let thresholds = LowQuotaAlertThresholds(fiveHour: 1, sevenDay: 1)

    static func isCritical(_ quota: AutomaticSwitchQuotaState) -> Bool {
        guard quota.hasCompleteApplicableWindows, let week = quota.sevenDayRemaining else { return false }
        if quota.fiveHourNotApplicable { return week <= 1 }
        guard let five = quota.fiveHourRemaining else { return false }
        return min(five, week) <= 1
    }

    static func canPrepare(_ snapshot: CodexTaskLiveSnapshot, legacyManagerRunning: Bool, now: Date) -> Bool {
        let age = now.timeIntervalSince(snapshot.refreshedAt)
        return !legacyManagerRunning && snapshot.connectionMode == .sharedDaemon && age >= -5 && age <= 45
            && !snapshot.records.values.contains { $0.state == .recorded || $0.state == .disconnected }
    }

    struct ThreadState: Equatable {
        let id: String
        let active: Bool
        let parentID: String?
        let subagent: Bool
    }

    static func loadedIDs(_ result: [String: Any]) -> Set<String>? {
        guard let ids = result["data"] as? [String], ids.count <= 128,
            ids.allSatisfy(validID), Set(ids).count == ids.count,
            result["nextCursor"] == nil || result["nextCursor"] is NSNull
        else { return nil }
        return Set(ids)
    }

    static func threadState(_ result: [String: Any], expectedID: String) -> ThreadState? {
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == expectedID,
            let type = (thread["status"] as? [String: Any])?["type"] as? String,
            ["active", "idle"].contains(type)
        else { return nil }
        let parent = thread["parentThreadId"] as? String
        if let parent, !validID(parent) { return nil }
        return ThreadState(
            id: expectedID, active: type == "active", parentID: parent,
            subagent: parent != nil || TaskThreadVisibility.isSubagent(thread))
    }

    static func activeTurnID(_ result: [String: Any]) -> String? {
        guard let turns = result["data"] as? [[String: Any]], turns.count == 1,
            turns[0]["status"] as? String == "inProgress",
            let id = turns[0]["id"] as? String, validID(id)
        else { return nil }
        return id
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// The caller checks opt-in, quota freshness, account identity and its held
    /// maintenance leases again before each operation that could interrupt work.
    @MainActor
    static func pause(
        client: CodexAppServerTaskClient,
        requiredThreadID: String? = nil,
        onLoadedThreads: (@MainActor (Set<String>) -> Void)? = nil,
        preflightHistory: @escaping @MainActor ([CodexPausedDesktopTurn]) async -> Bool = { _ in true },
        prepareInterrupts: @escaping @MainActor ([CodexPausedDesktopTurn]) -> Bool,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async -> Bool {
        await pause(
            request: { method, params in await client.desktopPauseRequest(method, params: params) },
            requiredThreadID: requiredThreadID,
            onLoadedThreads: onLoadedThreads, preflightHistory: preflightHistory,
            prepareInterrupts: prepareInterrupts, shouldContinue: shouldContinue)
    }

    @MainActor
    static func confirmStopped(
        client: CodexAppServerTaskClient, allowedIDs: Set<String>,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async -> Bool {
        await confirmStopped(
            request: { method, params in await client.desktopPauseRequest(method, params: params) },
            allowedIDs: allowedIDs, shouldContinue: shouldContinue)
    }

    @MainActor
    static func confirmStopped(
        request: @escaping (String, [String: Any]) async -> [String: Any]?,
        allowedIDs: Set<String>, shouldContinue: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard !Task.isCancelled, shouldContinue(),
            let response = await request("thread/loaded/list", ["limit": 128]),
            let ids = loadedIDs(response), ids == allowedIDs
        else { return false }
        for id in ids.sorted() {
            guard !Task.isCancelled, shouldContinue(),
                let response = await request("thread/read", ["threadId": id, "includeTurns": false]),
                let state = threadState(response, expectedID: id), !state.active
            else { return false }
        }
        return !Task.isCancelled && shouldContinue()
    }

    @MainActor
    static func pause(
        request: @escaping (String, [String: Any]) async -> [String: Any]?,
        requiredThreadID: String? = nil,
        onLoadedThreads: (@MainActor (Set<String>) -> Void)? = nil,
        preflightHistory: @escaping @MainActor ([CodexPausedDesktopTurn]) async -> Bool = { _ in true },
        prepareInterrupts: @escaping @MainActor ([CodexPausedDesktopTurn]) -> Bool,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(25)
        func allowed() -> Bool { !Task.isCancelled && Date() < deadline && shouldContinue() }
        guard allowed(), let response = await request("thread/loaded/list", ["limit": 128]),
            let ids = loadedIDs(response), requiredThreadID.map(ids.contains) != false
        else { return false }
        onLoadedThreads?(ids)
        var states: [String: ThreadState] = [:]
        for id in ids.sorted() {
            guard allowed(), let response = await request("thread/read", ["threadId": id, "includeTurns": false]),
                let state = threadState(response, expectedID: id)
            else { return false }
            states[id] = state
        }
        // A live internal worker is stopped through its active top-level owner.
        // Missing parents or cycles are unknown ownership, never permission.
        for state in states.values where state.active && state.subagent {
            var cursor = state
            var seen: Set<String> = [state.id]
            while cursor.subagent {
                guard let parent = cursor.parentID, seen.insert(parent).inserted,
                    let owner = states[parent]
                else { return false }
                cursor = owner
            }
            guard cursor.active else { return false }
        }
        var interruptedTurns: [CodexPausedDesktopTurn] = []
        for state in states.values.sorted(by: { $0.id < $1.id }) where state.active && !state.subagent {
            guard allowed(),
                let turns = await request(
                    "thread/turns/list",
                    [
                        "threadId": state.id, "limit": 1,
                        "sortDirection": "desc", "itemsView": "notLoaded",
                    ]),
                let turnID = activeTurnID(turns)
            else { return false }
            interruptedTurns.append(.init(threadID: state.id, turnID: turnID))
        }
        // The explicit one-shot path requires complete history evidence for
        // every root before any interruption or recovery plan is written.
        guard allowed(), await preflightHistory(interruptedTurns), allowed() else { return false }
        // Persist the exact resume plan before the first interruption. Failure
        // leaves every task untouched; a partial pause retains the same plan.
        guard allowed(), interruptedTurns.isEmpty || prepareInterrupts(interruptedTurns) else { return false }
        for turn in interruptedTurns {
            guard allowed(),
                await request("turn/interrupt", ["threadId": turn.threadID, "turnId": turn.turnID]) != nil
            else { return false }
        }
        // An interrupt acknowledgement only confirms receipt. Every original
        // root and worker must still be observable and idle; a missing or newly
        // loaded thread is unknown state, not proof that it stopped.
        while allowed() {
            guard let response = await request("thread/loaded/list", ["limit": 128]),
                let current = loadedIDs(response), current == ids
            else { return false }
            var active = false
            for id in current.sorted() {
                guard allowed(), let response = await request("thread/read", ["threadId": id, "includeTurns": false]),
                    let state = threadState(response, expectedID: id)
                else { return false }
                active = active || state.active
            }
            if !active { return allowed() }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return false }
        }
        return false
    }

    static func selfTest() -> Bool {
        let now = Date()
        let idle = CodexTaskLiveSnapshot(connectionMode: .sharedDaemon, records: [:], refreshedAt: now)
        return isCritical(.init(fiveHourRemaining: 1, sevenDayRemaining: 90))
            && isCritical(.init(fiveHourRemaining: 90, sevenDayRemaining: 1))
            && isCritical(.init(fiveHourRemaining: 0, sevenDayRemaining: 90))
            && !isCritical(.init(fiveHourRemaining: 1.001, sevenDayRemaining: 2))
            && !isCritical(.init(fiveHourRemaining: 0, sevenDayRemaining: nil))
            && !isCritical(.init(fiveHourRemaining: nil, sevenDayRemaining: 0))
            && !isCritical(.init(fiveHourRemaining: .nan, sevenDayRemaining: 0))
            && canPrepare(idle, legacyManagerRunning: false, now: now)
            && !canPrepare(idle, legacyManagerRunning: true, now: now)
            && !canPrepare(idle, legacyManagerRunning: false, now: now.addingTimeInterval(46))
            && !canPrepare(.disconnected, legacyManagerRunning: false, now: now)
            && loadedIDs(["data": ["a", "a"]]) == nil
            && loadedIDs(["data": ["a"], "nextCursor": "more"]) == nil
            && threadState(["thread": ["id": "a", "status": ["type": "unknown"]]], expectedID: "a") == nil
            && threadState(["thread": ["id": "a", "status": ["type": "systemError"]]], expectedID: "a") == nil
            && threadState(["thread": ["id": "a", "status": ["type": "notLoaded"]]], expectedID: "a") == nil
            && threadState(["thread": ["id": "b", "status": ["type": "idle"]]], expectedID: "a") == nil
            && activeTurnID(["data": [["id": "turn-1", "status": "inProgress"]]]) == "turn-1"
            && activeTurnID(["data": [["id": "turn-1", "status": "completed"]]]) == nil
    }
}
