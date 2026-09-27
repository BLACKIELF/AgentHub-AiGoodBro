import Foundation

/// All protocol replies are in memory. No real daemon, account or prompt is used.
enum CodexQuotaResumeSelfTest {
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
        let box = ResultBox()
        let task = Task { @MainActor in
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appendingPathComponent("quota-resume-self-test-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: root) }
            let account = "sha256:" + String(repeating: "a", count: 64)
            let otherAccount = "sha256:" + String(repeating: "b", count: 64)
            let turn = CodexPausedDesktopTurn(threadID: "thread-1", turnID: "turn-1")
            var passed = true

            for scenario in 0...6 {
                let support = root.appendingPathComponent("case-\(scenario)")
                let store = CodexQuotaResumeStore(supportDirectory: support)
                var calls: [String] = []
                var startCount = 0
                passed =
                    passed && store.stage([turn], targetAccountKey: account)
                    && store.expectedAccountKey == account && store.pending == [turn]
                if scenario != 0 { store.markSwitchSucceeded(accountKey: scenario == 1 ? otherAccount : account) }
                let allowed = scenario != 2
                await store.resume(
                    request: { method, params in
                        calls.append(method)
                        switch method {
                        case "thread/read":
                            if scenario == 6 {
                                store.abandonStaged()
                                passed = passed && store.pending == [turn]
                            }
                            let readNumber = calls.filter { $0 == "thread/read" }.count
                            return ["thread": ["id": "thread-1", "status": ["type": scenario == 3 ? "active" : (readNumber == 1 ? "notLoaded" : "idle")]]]
                        case "thread/turns/list":
                            return ["data": [["id": scenario == 4 ? "new-turn" : "turn-1", "status": "interrupted"]]]
                        case "thread/resume":
                            return ["thread": ["id": "thread-1"]]
                        case "turn/start":
                            startCount += 1
                            let followup = (params["input"] as? [[String: Any]])?.first?["text"] as? String
                            passed =
                                passed && params["threadId"] as? String == "thread-1"
                                && followup?.isEmpty == false && (followup?.count ?? 0) <= 256
                                && (params["input"] as? [[String: Any]])?.first?["text_elements"] as? [String] == []
                                && CodexQuotaResumeStore(supportDirectory: support).pending.isEmpty
                            return scenario == 5 ? nil : ["turn": ["id": "new-turn"]]
                        default: return nil
                        }
                    }, shouldContinue: { allowed })
                let shouldStart = scenario == 5 || scenario == 6
                passed =
                    passed && startCount == (shouldStart ? 1 : 0)
                    && (scenario <= 2 ? calls.isEmpty : !calls.isEmpty)
                if shouldStart {
                    await store.resume(
                        request: { _, _ in
                            startCount += 1
                            return nil
                        }, shouldContinue: { true })
                    passed =
                        passed && startCount == 1 && store.pending.isEmpty
                        && CodexQuotaResumeStore(supportDirectory: support).pending.isEmpty
                } else if scenario == 4 {
                    passed = passed && store.pending.isEmpty
                } else {
                    passed = passed && store.pending == [turn]
                }
            }

            // A completed turn is skipped while another interrupted turn in
            // the same batch still receives exactly one new start request.
            let mixedRoot = root.appendingPathComponent("mixed")
            let mixed = CodexQuotaResumeStore(supportDirectory: mixedRoot)
            let second = CodexPausedDesktopTurn(threadID: "thread-2", turnID: "turn-2")
            var mixedStarts = 0
            passed = passed && mixed.stage([turn, second], targetAccountKey: account)
            mixed.markSwitchSucceeded(accountKey: account)
            await mixed.resume(
                request: { method, params in
                    let id = params["threadId"] as? String ?? ""
                    switch method {
                    case "thread/read", "thread/resume": return ["thread": ["id": id, "status": ["type": "idle"]]]
                    case "thread/turns/list":
                        return [
                            "data": [
                                [
                                    "id": id == "thread-1" ? "turn-1" : "turn-2",
                                    "status": id == "thread-1" ? "completed" : "interrupted",
                                ]
                            ]
                        ]
                    case "turn/start":
                        mixedStarts += 1
                        return ["turn": ["id": "next-2"]]
                    default: return nil
                    }
                }, shouldContinue: { true })
            passed =
                passed && mixedStarts == 1 && mixed.pending.isEmpty
                && CodexQuotaResumeStore(supportDirectory: mixedRoot).pending.isEmpty

            // Exercise UsageStore's actual admission path. A staged record
            // survives restart, but it cannot send an RPC until the switch and
            // history-confirmed success path has persisted ready.
            let admissionRoot = root.appendingPathComponent("usage-admission")
            let admission = CodexQuotaResumeStore(supportDirectory: admissionRoot)
            passed = passed && admission.stage([turn], targetAccountKey: account)
            let restartedUnready = CodexQuotaResumeStore(supportDirectory: admissionRoot)
            var admissionCalls = 0
            func admittedRequest(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
                admissionCalls += 1
                switch method {
                case "thread/read", "thread/resume":
                    return ["thread": ["id": "thread-1", "status": ["type": "idle"]]]
                case "thread/turns/list": return ["data": [["id": "turn-1", "status": "interrupted"]]]
                case "turn/start": return ["turn": ["id": "next-1"]]
                default: return nil
                }
            }
            await UsageStore.runReadyQuotaResume(
                restartedUnready, request: admittedRequest,
                beforeStart: { _ in true }, shouldContinue: { true })
            passed = passed && admissionCalls == 0 && restartedUnready.pending == [turn]
            restartedUnready.markSwitchSucceeded(accountKey: account)
            let restartedReady = CodexQuotaResumeStore(supportDirectory: admissionRoot)
            await UsageStore.runReadyQuotaResume(
                restartedReady, request: admittedRequest,
                beforeStart: { _ in true }, shouldContinue: { true })
            passed = passed && admissionCalls > 0 && restartedReady.pending.isEmpty

            // A successful credential switch without a captured history
            // baseline must leave the interrupted batch unready.
            let historyRoot = root.appendingPathComponent("no-history-baseline")
            let historyGate = CodexQuotaResumeStore(supportDirectory: historyRoot)
            passed = passed && historyGate.stage([turn], targetAccountKey: account)
            UsageStore.confirmReadyQuotaResume(
                historyGate, switchSucceeded: true,
                pausedTasksConfirmed: true, historyConfirmed: false, accountKey: account)
            passed =
                passed && !historyGate.isReady
                && !CodexQuotaResumeStore(supportDirectory: historyRoot).isReady
            UsageStore.confirmReadyQuotaResume(
                historyGate, switchSucceeded: true,
                pausedTasksConfirmed: true, historyConfirmed: true, accountKey: account)
            passed = passed && historyGate.isReady

            // The one-shot weekly policy survives an app restart, but a ready
            // batch still requires the exact target credential and fresh quota.
            let oneShotRoot = root.appendingPathComponent("one-shot-admission")
            let oneShotIdentity = CodexCredentialIdentity(email: "pro@example.invalid", accountID: "pro-20x")
            let wrongIdentity = CodexCredentialIdentity(email: "pro@example.invalid", accountID: "other")
            guard
                let oneShotKey = TokenMonitorHostIdentity.accountKey(
                    email: oneShotIdentity.email, accountID: oneShotIdentity.accountID)
            else {
                box.set(false)
                return
            }
            let oneShot = CodexQuotaResumeStore(supportDirectory: oneShotRoot)
            passed =
                passed
                && oneShot.stage(
                    [turn], targetAccountKey: oneShotKey,
                    oneShotQuotaPolicy: .reportedWeek)
            oneShot.markSwitchSucceeded(accountKey: oneShotKey)
            let restartedOneShot = CodexQuotaResumeStore(supportDirectory: oneShotRoot)
            let quotaTime = Date()
            func quota(
                plan: String = "pro", fiveUsed: Double? = nil, weekUsed: Double = 8,
                balance: String? = "0.00", fetchedAt: Date = quotaTime
            ) -> CodexAccountSnapshot {
                CodexAccountSnapshot(
                    accountType: "chatgpt", planType: plan,
                    email: oneShotIdentity.email, accountID: oneShotIdentity.accountID,
                    limitId: nil, limitName: nil,
                    fiveHour: fiveUsed.map {
                        CodexQuotaWindowSnapshot(
                            RateWindow(
                                usedPercent: $0, windowDurationMins: 300, resetsAt: nil))
                    },
                    sevenDay: CodexQuotaWindowSnapshot(
                        RateWindow(
                            usedPercent: weekUsed, windowDurationMins: 10_080, resetsAt: nil)),
                    monthly: nil, creditBalance: balance, creditBalanceUnlimited: false,
                    fetchedAt: fetchedAt, appServerVersion: nil)
            }
            let policy = CodexOneShotSwitchIntent.QuotaPolicy.reportedWeek
            passed =
                passed && restartedOneShot.isReady && restartedOneShot.oneShotQuotaPolicy == policy
                && UsageStore.oneShotQuotaResumeIsEligible(
                    quota: quota(), identity: oneShotIdentity,
                    expectedAccountKey: oneShotKey, policy: policy, failedAt: nil, now: quotaTime)
                && UsageStore.oneShotQuotaResumeIsEligible(
                    quota: quota(plan: "prolite"), identity: oneShotIdentity,
                    expectedAccountKey: oneShotKey, policy: policy, failedAt: nil, now: quotaTime)
                && !UsageStore.oneShotQuotaResumeIsEligible(
                    quota: quota(plan: "plus"), identity: oneShotIdentity,
                    expectedAccountKey: oneShotKey, policy: policy, failedAt: nil, now: quotaTime)
                && UsageStore.oneShotQuotaResumeIsEligible(
                    quota: quota(balance: "2.50"),
                    identity: oneShotIdentity, expectedAccountKey: oneShotKey,
                    policy: policy, failedAt: nil, now: quotaTime)
                && UsageStore.oneShotQuotaResumeIsEligible(
                    quota: quota(balance: nil),
                    identity: oneShotIdentity, expectedAccountKey: oneShotKey,
                    policy: policy, failedAt: nil, now: quotaTime)
                && !UsageStore.oneShotQuotaResumeIsEligible(
                    quota: quota(), identity: wrongIdentity,
                    expectedAccountKey: oneShotKey, policy: policy, failedAt: nil, now: quotaTime)
                && !UsageStore.oneShotQuotaResumeIsEligible(
                    quota: quota(fiveUsed: 100),
                    identity: oneShotIdentity, expectedAccountKey: oneShotKey,
                    policy: policy, failedAt: nil, now: quotaTime)
                && !UsageStore.oneShotQuotaResumeIsEligible(
                    quota: quota(weekUsed: 75),
                    identity: oneShotIdentity, expectedAccountKey: oneShotKey,
                    policy: policy, failedAt: nil, now: quotaTime)
                && !UsageStore.oneShotQuotaResumeIsEligible(
                    quota: quota(fetchedAt: quotaTime.addingTimeInterval(-46)),
                    identity: oneShotIdentity, expectedAccountKey: oneShotKey,
                    policy: policy, failedAt: nil, now: quotaTime)
            var oneShotStarts = 0
            await UsageStore.runReadyQuotaResume(
                restartedOneShot,
                request: { method, params in
                    switch method {
                    case "thread/read", "thread/resume":
                        return ["thread": ["id": "thread-1", "status": ["type": "idle"]]]
                    case "thread/turns/list": return ["data": [["id": "turn-1", "status": "interrupted"]]]
                    case "turn/start":
                        oneShotStarts += 1
                        return ["turn": ["id": "next-1"]]
                    default: return nil
                    }
                }, beforeStart: { _ in true },
                shouldContinue: {
                    UsageStore.oneShotQuotaResumeIsEligible(
                        quota: quota(), identity: wrongIdentity,
                        expectedAccountKey: oneShotKey, policy: policy, failedAt: nil, now: quotaTime)
                })
            passed = passed && oneShotStarts == 0 && restartedOneShot.pending == [turn]
            await UsageStore.runReadyQuotaResume(
                restartedOneShot,
                request: { method, _ in
                    switch method {
                    case "thread/read", "thread/resume":
                        return ["thread": ["id": "thread-1", "status": ["type": "idle"]]]
                    case "thread/turns/list": return ["data": [["id": "turn-1", "status": "interrupted"]]]
                    case "turn/start":
                        oneShotStarts += 1
                        return ["turn": ["id": "next-1"]]
                    default: return nil
                    }
                }, beforeStart: { _ in true },
                shouldContinue: {
                    UsageStore.oneShotQuotaResumeIsEligible(
                        quota: quota(plan: "prolite"), identity: oneShotIdentity,
                        expectedAccountKey: oneShotKey, policy: policy, failedAt: nil, now: quotaTime)
                })
            passed = passed && oneShotStarts == 1 && restartedOneShot.pending.isEmpty

            // A fresh complete task read may allow the turn this batch just
            // started, but a new external turn blocks the next submission.
            let liveNow = Date()
            func running(_ id: String, turnID: String) -> TaskLiveRecord {
                TaskLiveRecord(
                    threadID: id, name: nil, state: .running, updatedAt: liveNow,
                    turnID: turnID, connectionMode: .sharedDaemon)
            }
            let ownSnapshot = CodexTaskLiveSnapshot(
                connectionMode: .sharedDaemon,
                records: ["thread-1": running("thread-1", turnID: "next-1")], refreshedAt: liveNow)
            let foreignSnapshot = CodexTaskLiveSnapshot(
                connectionMode: .sharedDaemon,
                records: [
                    "thread-1": running("thread-1", turnID: "next-1"),
                    "external": running("external", turnID: "external-turn"),
                ], refreshedAt: liveNow)
            passed =
                passed
                && CodexAutomaticSwitchPolicy.hasNoUnexpectedActiveTasks(
                    ownSnapshot,
                    startedTurns: ["thread-1": "next-1"], legacyManagerRunning: false, now: liveNow)
                && !CodexAutomaticSwitchPolicy.hasNoUnexpectedActiveTasks(
                    ownSnapshot,
                    startedTurns: ["thread-1": "older-turn"], legacyManagerRunning: false, now: liveNow)
                && !CodexAutomaticSwitchPolicy.hasNoUnexpectedActiveTasks(
                    foreignSnapshot,
                    startedTurns: ["thread-1": "next-1"], legacyManagerRunning: false, now: liveNow)
            let raceRoot = root.appendingPathComponent("new-external-task")
            let raceStore = CodexQuotaResumeStore(supportDirectory: raceRoot)
            passed = passed && raceStore.stage([turn, second], targetAccountKey: account)
            raceStore.markSwitchSucceeded(accountKey: account)
            var raceStarts = 0
            await UsageStore.runReadyQuotaResume(
                raceStore,
                request: { method, params in
                    let id = params["threadId"] as? String ?? ""
                    switch method {
                    case "thread/read", "thread/resume":
                        return ["thread": ["id": id, "status": ["type": "idle"]]]
                    case "thread/turns/list":
                        return [
                            "data": [
                                [
                                    "id": id == "thread-1" ? "turn-1" : "turn-2",
                                    "status": "interrupted",
                                ]
                            ]
                        ]
                    case "turn/start":
                        raceStarts += 1
                        return ["turn": ["id": "next-1"]]
                    default: return nil
                    }
                },
                beforeStart: { started in
                    CodexAutomaticSwitchPolicy.hasNoUnexpectedActiveTasks(
                        started.isEmpty
                            ? .init(connectionMode: .sharedDaemon, records: [:], refreshedAt: liveNow)
                            : foreignSnapshot,
                        startedTurns: started, legacyManagerRunning: false, now: liveNow)
                }, shouldContinue: { true })
            passed =
                passed && raceStarts == 1 && raceStore.pending == [second]
                && CodexQuotaResumeStore(supportDirectory: raceRoot).pending == [second]

            // A newer active turn in the same thread is a live race, not a
            // completed continuation that permits the next task to start.
            let newerRoot = root.appendingPathComponent("newer-active-turn")
            let newer = CodexQuotaResumeStore(supportDirectory: newerRoot)
            passed = passed && newer.stage([turn, second], targetAccountKey: account)
            newer.markSwitchSucceeded(accountKey: account)
            var newerStarts = 0
            await UsageStore.runReadyQuotaResume(
                newer,
                request: { method, params in
                    let id = params["threadId"] as? String ?? ""
                    switch method {
                    case "thread/read":
                        return ["thread": ["id": id, "status": ["type": "idle"]]]
                    case "thread/turns/list":
                        return [
                            "data": [
                                [
                                    "id": id == "thread-1" ? "new-turn" : "turn-2",
                                    "status": "inProgress",
                                ]
                            ]
                        ]
                    case "turn/start":
                        newerStarts += 1
                        return ["turn": ["id": "extra"]]
                    default: return nil
                    }
                }, beforeStart: { _ in true }, shouldContinue: { true })
            passed = passed && newerStarts == 0 && newer.pending == [turn, second]

            // If the task changes while the full snapshot preflight is in
            // flight, the final turn read must catch it before turn/start.
            let lateRoot = root.appendingPathComponent("changed-during-preflight")
            let late = CodexQuotaResumeStore(supportDirectory: lateRoot)
            passed = passed && late.stage([turn], targetAccountKey: account)
            late.markSwitchSucceeded(accountKey: account)
            var lateChanged = false
            var lateStarts = 0
            await UsageStore.runReadyQuotaResume(
                late,
                request: { method, _ in
                    switch method {
                    case "thread/read", "thread/resume":
                        return ["thread": ["id": "thread-1", "status": ["type": "idle"]]]
                    case "thread/turns/list":
                        return [
                            "data": [
                                [
                                    "id": lateChanged ? "new-turn" : "turn-1",
                                    "status": lateChanged ? "completed" : "interrupted",
                                ]
                            ]
                        ]
                    case "turn/start":
                        lateStarts += 1
                        return ["turn": ["id": "unwanted"]]
                    default: return nil
                    }
                },
                beforeStart: { _ in
                    lateChanged = true
                    return true
                }, shouldContinue: { true })
            passed = passed && lateStarts == 0 && late.pending == [turn]

            let abandonedRoot = root.appendingPathComponent("abandoned")
            let abandoned = CodexQuotaResumeStore(supportDirectory: abandonedRoot)
            passed =
                passed && abandoned.canBeginAutomaticSwitch()
                && abandoned.stage([turn], targetAccountKey: account)
                && !abandoned.canBeginAutomaticSwitch()
            abandoned.markSwitchSucceeded(accountKey: account)
            abandoned.abandonStaged()
            passed =
                passed && abandoned.pending.isEmpty && !abandoned.isReady
                && abandoned.canBeginAutomaticSwitch()

            // Existing unsent work must not be overwritten by a new switch plan.
            let overlapRoot = root.appendingPathComponent("overlap")
            let overlap = CodexQuotaResumeStore(supportDirectory: overlapRoot)
            passed =
                passed && overlap.stage([turn], targetAccountKey: account)
                && !overlap.stage([CodexPausedDesktopTurn(threadID: "thread-2", turnID: "turn-2")], targetAccountKey: account)
                && overlap.pending == [turn]

            // A non-directory support path is a deterministic persistence error.
            let blocked = root.appendingPathComponent("blocked")
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try? Data("blocked".utf8).write(to: blocked)
            let unavailable = CodexQuotaResumeStore(supportDirectory: blocked)
            passed =
                passed && !unavailable.stage([turn], targetAccountKey: account)
                && unavailable.pending.isEmpty && !unavailable.canBeginAutomaticSwitch()

            box.set(passed)
        }
        let deadline = Date().addingTimeInterval(8)
        while box.get() == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        task.cancel()
        let result = box.get() == true
        print(
            result
                ? "Desktop quota resume self-test passed (18 simulated flows)"
                : "Desktop quota resume self-test failed")
        return result
    }
}
