import Foundation

/// Protocol simulations never connect to a Desktop daemon or interrupt live work.
enum CodexDesktopQuotaPauseSelfTest {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        func set(_ value: Bool) {
            lock.lock()
            result = value
            lock.unlock()
        }
        func get() -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    static func run() -> Bool {
        let now = Date()
        let running = CodexTaskLiveSnapshot(
            connectionMode: .sharedDaemon,
            records: [
                "r":
                    TaskLiveRecord(threadID: "r", name: nil, state: .running, updatedAt: now, turnID: "t", connectionMode: .sharedDaemon)
            ], refreshedAt: now)
        func evaluate(_ quota: AutomaticSwitchQuotaState, enabled: Bool = true, age: TimeInterval = 0) -> Bool {
            CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true, sourceQuota: quota,
                sourceRefreshedAt: now.addingTimeInterval(-age), taskSnapshot: running,
                codexInactiveSince: nil, legacyManagerRunning: false, lastAttemptAt: nil, lastSucceededAt: nil,
                thresholds: CodexDesktopQuotaPause.thresholds, pauseAtOnePercent: enabled, now: now)
        }
        func officialState(
            plan: String, fiveUsed: Double? = nil, weekUsed: Double? = 8,
            succeeded: Bool = true
        ) -> AutomaticSwitchQuotaState {
            let snapshot = UsageSnapshot(
                refreshedAt: now,
                account: AccountInfo(
                    type: "chatgpt", planType: plan, emailPresent: true,
                    email: "fixture@example.invalid"), limitId: nil, limitName: nil,
                quotaReadSucceeded: succeeded,
                fiveHourQuota: fiveUsed.map { RateWindow(usedPercent: $0, windowDurationMins: 300, resetsAt: nil) },
                sevenDayQuota: weekUsed.map { RateWindow(usedPercent: $0, windowDurationMins: 10_080, resetsAt: nil) },
                monthlyQuota: nil, credits: nil, cloudLifetimeTokens: nil, local: nil, taskBoard: nil, messages: [])
            return AutomaticSwitchQuotaState(snapshot: snapshot)
        }
        let weeklyBelow = officialState(plan: "prolite", weekUsed: 99.01)
        let weeklyAt = officialState(plan: "pro", weekUsed: 99)
        let weeklyAbove = officialState(plan: "prolite", weekUsed: 98.99)
        let target = CodexAutomaticSwitchPolicy.preferredCandidate(
            [
                .init(profileID: "eligible", quota: officialState(plan: "prolite", weekUsed: 23)),
                .init(profileID: "empty", quota: officialState(plan: "prolite", weekUsed: 100)),
                .init(profileID: "failed", quota: officialState(plan: "prolite", weekUsed: 23, succeeded: false)),
            ], for: weeklyBelow.triggeredWindows(thresholds: CodexDesktopQuotaPause.thresholds))
        let fiveHourTriggered = officialState(plan: "plus", fiveUsed: 99.01, weekUsed: 8)
        let weeklyOnlyCandidate = CodexAutomaticSwitchPolicy.preferredCandidate(
            [
                .init(profileID: "eligible", quota: officialState(plan: "prolite", weekUsed: 23)),
                .init(profileID: "below-minimum", quota: officialState(plan: "pro", weekUsed: 71)),
            ], for: fiveHourTriggered.triggeredWindows(thresholds: CodexDesktopQuotaPause.thresholds))
        guard evaluate(.init(fiveHourRemaining: 1, sevenDayRemaining: 90)),
            evaluate(.init(fiveHourRemaining: 90, sevenDayRemaining: 1)),
            weeklyBelow.fiveHourNotApplicable && evaluate(weeklyBelow) && CodexDesktopQuotaPause.isCritical(weeklyBelow),
            weeklyAt.fiveHourNotApplicable && evaluate(weeklyAt),
            !evaluate(weeklyAbove),
            !evaluate(officialState(plan: "prolite", weekUsed: nil)),
            !evaluate(officialState(plan: "plus", weekUsed: 99)),
            !evaluate(officialState(plan: "prolite", weekUsed: 99, succeeded: false)),
            !evaluate(officialState(plan: "prolite", fiveUsed: .nan, weekUsed: 99)),
            target?.profileID == "eligible",
            fiveHourTriggered.triggeredWindows(thresholds: CodexDesktopQuotaPause.thresholds) == [.fiveHour],
            weeklyOnlyCandidate?.profileID == "eligible",
            officialState(plan: "prolite", weekUsed: 8).simulatingLowQuota()?.sevenDayRemaining == 0.99,
            !evaluate(.init(fiveHourRemaining: 1.01, sevenDayRemaining: 2)),
            !evaluate(.init(fiveHourRemaining: 1, sevenDayRemaining: 90), enabled: false),
            !evaluate(.init(fiveHourRemaining: 1, sevenDayRemaining: nil)),
            !evaluate(.init(fiveHourRemaining: nil, sevenDayRemaining: 1)),
            !evaluate(.init(fiveHourRemaining: 1, sevenDayRemaining: 90), age: 46),
            !CodexAutomaticSwitchPolicy.hasSafeTaskState(
                running, codexInactiveSince: nil,
                legacyManagerRunning: false, allowForeground: true, now: now)
        else { return false }
        let box = ResultBox()
        let task = Task { @MainActor in
            var allPassed = true
            // 0=successful pause, 1=unsupported RPC, 2=ack without stop,
            // 3=new task, 4=opt-in revoked, 5=worker without known owner,
            // 6=resume-plan persistence failed, 7=history preflight failed,
            // 8=empty loaded list, 9=visible thread absent from loaded list.
            for scenario in 0...9 {
                var interrupts = 0
                var staged = false
                var reads = 0
                var lists = 0
                var allowed = true
                let result = await CodexDesktopQuotaPause.pause(
                    request: { method, params in
                        switch method {
                        case "thread/loaded/list":
                            lists += 1
                            return [
                                "data": scenario == 8
                                    ? []
                                    : (scenario == 9
                                        ? ["different"]
                                        : (scenario == 3 && lists > 1 ? ["root", "new"] : ["root"]))
                            ]
                        case "thread/read":
                            reads += 1
                            if scenario == 2 && reads > 1 { allowed = false }
                            var thread: [String: Any] = ["id": "root", "status": ["type": interrupts > 0 && scenario != 2 ? "idle" : "active"]]
                            if scenario == 5 { thread["parentThreadId"] = "missing-owner" }
                            return ["thread": thread]
                        case "thread/turns/list":
                            if scenario == 4 { allowed = false }
                            return ["data": [["id": "turn-1", "status": "inProgress"]]]
                        case "turn/interrupt":
                            guard staged, params["threadId"] as? String == "root", params["turnId"] as? String == "turn-1" else { return nil }
                            interrupts += 1
                            return scenario == 1 ? nil : [:]
                        default: return nil
                        }
                    }, requiredThreadID: "root",
                    preflightHistory: { turns in
                        scenario != 7 && turns == [.init(threadID: "root", turnID: "turn-1")]
                    },
                    prepareInterrupts: { turns in
                        staged = scenario != 6 && turns == [.init(threadID: "root", turnID: "turn-1")]
                        return staged
                    }, shouldContinue: { allowed })
                allPassed =
                    allPassed && result == (scenario == 0)
                    && interrupts == ([0, 1, 2, 3].contains(scenario) ? 1 : 0)
            }
            box.set(allPassed)
        }
        let deadline = Date().addingTimeInterval(5)
        while box.get() == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        task.cancel()
        let result = box.get() == true
        print(result ? "Desktop quota pause protocol self-test passed (10 simulated flows)" : "Desktop quota pause protocol self-test failed")
        return result
    }
}
