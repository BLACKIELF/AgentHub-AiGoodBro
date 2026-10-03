// Offline orchestration test. Production policy, pause protocol, resume journal,
// and UsageStore's final resume gates are compiled in by the Python runner.
// Desktop RPC, account replacement, and quota evidence stay synthetic.
import Foundation

final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    convenience init?(suiteName: String) { self.init() }
    func object(forKey key: String) -> Any? { values[key] }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removePersistentDomain(forName name: String) { values.removeAll() }
    func synchronize() -> Bool { true }
}

struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ zh: String, _ en: String) -> String { en }
}
struct RateWindow { let usedPercent: Double }
struct AccountInfo { var planType: String? }
struct UsageSnapshot {
    var refreshedAt = Date()
    var account: AccountInfo? = .init(planType: "pro")
    var quotaReadSucceeded = true
    var fiveHourQuota: RateWindow? = .init(usedPercent: 99.5)
    var sevenDayQuota: RateWindow? = .init(usedPercent: 20)
}
struct CodexAccountSnapshot {
    var planType: String? = "pro"
    var quotaReadSucceeded: Bool? = true
    var fiveHour: RateWindow? = .init(usedPercent: 20)
    var sevenDay: RateWindow? = .init(usedPercent: 20)
}
enum TaskConnectionMode { case sharedDaemon, disconnected }
enum TaskRuntimeState { case running, waitingInput, recorded, disconnected, idle, failed, completed, interrupted }
struct TaskLiveRecord {
    let threadID: String
    let state: TaskRuntimeState
    var turnID: String? = nil
}
struct CodexTaskLiveSnapshot {
    var connectionMode = TaskConnectionMode.sharedDaemon
    var records: [String: TaskLiveRecord] = [:]
    var refreshedAt = Date()
    static var disconnected: Self { Self(connectionMode: .disconnected) }
}
enum TaskThreadVisibility {
    static func isSubagent(_ thread: [String: Any]) -> Bool { thread["parentThreadId"] != nil }
}
final class CodexAppServerTaskClient {
    func desktopPauseRequest(_ method: String, params: [String: Any]) async -> [String: Any]? { nil }
    func desktopResumeRequest(_ method: String, params: [String: Any]) async -> [String: Any]? { nil }
}
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL { fatalError("The fixture must supply a temporary support root") }
}

@MainActor
final class ScriptedDesktop {
    var loadedIDs = ["root-1", "worker-1"]
    var interrupted = false
    var incompleteState = false
    var startCount = 0
    var interruptCount = 0
    var startedThreadIDs: [String] = []

    func reply(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
        switch method {
        case "thread/loaded/list":
            return ["data": loadedIDs]
        case "thread/read":
            guard let id = params["threadId"] as? String, loadedIDs.contains(id) else { return nil }
            var thread: [String: Any] = [
                "id": id,
                "status": ["type": incompleteState ? "unknown" : (interrupted ? "idle" : "active")],
            ]
            if id == "worker-1" { thread["parentThreadId"] = "root-1" }
            return ["thread": thread]
        case "thread/turns/list":
            guard params["threadId"] as? String == "root-1" else { return nil }
            return ["data": [[
                "id": startCount == 0 ? "turn-1" : "next-1",
                "status": startCount == 0 ? (interrupted ? "interrupted" : "inProgress") : "inProgress",
            ]]]
        case "turn/interrupt":
            guard params["threadId"] as? String == "root-1",
                params["turnId"] as? String == "turn-1" else { return nil }
            interruptCount += 1
            interrupted = true
            return [:]
        case "thread/resume":
            guard interrupted, params["threadId"] as? String == "root-1" else { return nil }
            return ["thread": ["id": "root-1", "status": ["type": "idle"]]]
        case "turn/start":
            guard interrupted, params["threadId"] as? String == "root-1",
                let input = params["input"] as? [[String: Any]],
                input.count == 1, input[0]["type"] as? String == "text"
            else { return nil }
            startCount += 1
            startedThreadIDs.append("root-1")
            return ["turn": ["id": "next-1"]]
        default:
            return nil
        }
    }
}

@main
struct AutomaticSwitchContinuationFlowFixture {
    enum Scenario: String {
        case success, switchFailed, loadedChanged, incompleteState, missingHistory, unexpectedBeforeStart
    }
    struct Outcome {
        let paused: Bool
        let confirmed: Bool
        let switched: Bool
        let ready: Bool
        let pending: [CodexPausedDesktopTurn]
        let batchID: String?
        let desktop: ScriptedDesktop
        let store: CodexQuotaResumeStore
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aigoodbro-continuation-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "sha256:" + String(repeating: "a", count: 64)
        let turn = CodexPausedDesktopTurn(threadID: "root-1", turnID: "turn-1")
        var checks = 0
        func check(_ label: String, _ passed: Bool) {
            checks += 1
            guard passed else { print("FAIL \(label)"); exit(1) }
            print("PASS \(label)")
        }

        func idleSnapshot(unexpected: Bool = false) -> CodexTaskLiveSnapshot {
            var records: [String: TaskLiveRecord] = [
                "root-1": .init(threadID: "root-1", state: .idle),
                "worker-1": .init(threadID: "worker-1", state: .idle),
            ]
            if unexpected { records["new-task"] = .init(threadID: "new-task", state: .running, turnID: "new-turn") }
            return .init(records: records)
        }

        func run(_ scenario: Scenario) async -> Outcome {
            let support = root.appendingPathComponent(scenario.rawValue, isDirectory: true)
            let store = CodexQuotaResumeStore(supportDirectory: support)
            let desktop = ScriptedDesktop()
            let now = Date()
            let sourceQuota = AutomaticSwitchQuotaState(fiveHourRemaining: 0.5, sevenDayRemaining: 80)
            let targetQuota = AutomaticSwitchQuotaState(fiveHourRemaining: 75, sevenDayRemaining: 70)
            let running = CodexTaskLiveSnapshot(records: [
                "root-1": .init(threadID: "root-1", state: .running, turnID: "turn-1"),
                "worker-1": .init(threadID: "worker-1", state: .running),
            ], refreshedAt: now)
            let eligible = CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true, sourceQuota: sourceQuota, sourceRefreshedAt: now,
                taskSnapshot: running, codexInactiveSince: nil, legacyManagerRunning: false,
                lastAttemptAt: nil, lastSucceededAt: nil,
                thresholds: .init(fiveHour: 20, sevenDay: 10), pauseAtOnePercent: true, now: now)
                && CodexAutomaticSwitchPolicy.preferredCandidate(
                    [.init(profileID: "target", quota: targetQuota)],
                    for: sourceQuota.triggeredWindows(thresholds: .init(fiveHour: 20, sevenDay: 10)))?.profileID == "target"
            guard eligible else { return Outcome(paused: false, confirmed: false, switched: false,
                                                  ready: false, pending: [], batchID: nil,
                                                  desktop: desktop, store: store) }
            var capturedLoadedIDs: Set<String>?
            let paused = await CodexDesktopQuotaPause.pause(
                request: { method, params in await desktop.reply(method, params) },
                requiredThreadID: "root-1",
                onLoadedThreads: { capturedLoadedIDs = $0 },
                preflightHistory: { turns in turns == [turn] },
                prepareInterrupts: { turns in store.stage(turns, targetAccountKey: key) },
                shouldContinue: { true })
            let stagedBatchID = store.expectedBatchID
            if scenario == .loadedChanged { desktop.loadedIDs.append("new-task") }
            if scenario == .incompleteState { desktop.incompleteState = true }
            let confirmed: Bool
            if paused, let capturedLoadedIDs {
                confirmed = await CodexDesktopQuotaPause.confirmStopped(
                    request: { method, params in await desktop.reply(method, params) },
                    allowedIDs: capturedLoadedIDs, shouldContinue: { true })
            } else {
                confirmed = false
            }
            // The real account writer is replaced by this explicit synthetic result.
            let switched = confirmed && scenario != .switchFailed
            let historyConfirmed = switched && scenario != .missingHistory
            UsageStore.confirmReadyQuotaResume(
                store, switchSucceeded: switched, pausedTasksConfirmed: confirmed,
                historyConfirmed: historyConfirmed, accountKey: key, batchID: stagedBatchID)
            let authenticatedKey = switched ? key : nil
            await UsageStore.runReadyQuotaResume(
                store,
                request: { method, params in await desktop.reply(method, params) },
                beforeStart: { startedTurns in
                    CodexAutomaticSwitchPolicy.hasNoUnexpectedActiveTasks(
                        idleSnapshot(unexpected: scenario == .unexpectedBeforeStart),
                        startedTurns: startedTurns, legacyManagerRunning: false)
                },
                shouldContinue: { authenticatedKey == store.expectedAccountKey && targetQuota.hasPositiveApplicableWindows })
            return Outcome(paused: paused, confirmed: confirmed, switched: switched,
                           ready: store.isReady, pending: store.pending, batchID: stagedBatchID,
                           desktop: desktop, store: store)
        }

        let success = await run(.success)
        check("low quota pauses the exact root and confirms unchanged root and worker",
              success.paused && success.confirmed && success.desktop.interruptCount == 1)
        check("confirmed synthetic switch resumes only the interrupted root once",
              success.switched && success.desktop.startCount == 1
                && success.desktop.startedThreadIDs == ["root-1"] && success.pending.isEmpty)
        UsageStore.confirmReadyQuotaResume(
            success.store, switchSucceeded: true, pausedTasksConfirmed: true,
            historyConfirmed: true, accountKey: key, batchID: success.batchID)
        await UsageStore.runReadyQuotaResume(
            success.store, request: { method, params in await success.desktop.reply(method, params) },
            beforeStart: { _ in true }, shouldContinue: { true })
        let restarted = CodexQuotaResumeStore(supportDirectory: root.appendingPathComponent(Scenario.success.rawValue))
        await UsageStore.runReadyQuotaResume(
            restarted, request: { method, params in await success.desktop.reply(method, params) },
            beforeStart: { _ in true }, shouldContinue: { true })
        check("duplicate confirmation and restart never submit a second turn",
              success.desktop.startCount == 1 && restarted.pending.isEmpty)

        let failed = await run(.switchFailed)
        check("failed synthetic account switch leaves staged turn unready",
              failed.paused && failed.confirmed && !failed.switched && !failed.ready
                && failed.pending == [turn] && failed.desktop.startCount == 0)
        let changed = await run(.loadedChanged)
        check("changed loaded task set blocks switch and continuation",
              changed.paused && !changed.confirmed && !changed.switched
                && changed.desktop.startCount == 0)
        let incomplete = await run(.incompleteState)
        check("incomplete paused task state blocks switch and continuation",
              incomplete.paused && !incomplete.confirmed && !incomplete.switched
                && incomplete.desktop.startCount == 0)
        let noHistory = await run(.missingHistory)
        check("missing history confirmation leaves original task unready",
              noHistory.switched && !noHistory.ready && noHistory.pending == [turn]
                && noHistory.desktop.startCount == 0)
        let unexpected = await run(.unexpectedBeforeStart)
        check("new active work before turn/start keeps ready task pending",
              unexpected.switched && unexpected.ready && unexpected.pending == [turn]
                && unexpected.desktop.startCount == 0)

        // A stale owner must not confirm a newer batch for the same account.
        let staleRoot = root.appendingPathComponent("stale-batch", isDirectory: true)
        let oldOwner = CodexQuotaResumeStore(supportDirectory: staleRoot)
        let newOwner = CodexQuotaResumeStore(supportDirectory: staleRoot)
        let newerTurn = CodexPausedDesktopTurn(threadID: "root-2", turnID: "turn-2")
        check("old batch staged in temporary journal", oldOwner.stage([turn], targetAccountKey: key))
        let oldBatchID = oldOwner.expectedBatchID
        newOwner.abandonStaged()
        check("new batch staged for same synthetic account", newOwner.stage([newerTurn], targetAccountKey: key))
        let newBatchID = newOwner.expectedBatchID
        let journalURL = staleRoot.appendingPathComponent("quota-resume/desktop-turns-v1.json")
        let newerJournal = try Data(contentsOf: journalURL)
        UsageStore.confirmReadyQuotaResume(
            oldOwner, switchSucceeded: true, pausedTasksConfirmed: true,
            historyConfirmed: true, accountKey: key, batchID: oldBatchID)
        let observed = CodexQuotaResumeStore(supportDirectory: staleRoot)
        let journalAfterStaleConfirmation = try Data(contentsOf: journalURL)
        check("stale owner cannot change or confirm newer same-account batch",
              !observed.isReady && observed.pending == [newerTurn]
                && !oldOwner.isReady && journalAfterStaleConfirmation == newerJournal)
        UsageStore.confirmReadyQuotaResume(
            observed, switchSucceeded: true, pausedTasksConfirmed: true,
            historyConfirmed: true, accountKey: key, batchID: newBatchID)
        let confirmedFresh = CodexQuotaResumeStore(supportDirectory: staleRoot)
        check("fresh owner can confirm newer same-account batch",
              confirmedFresh.isReady && confirmedFresh.pending == [newerTurn])

        // A late callback on the same store also carries its original batch,
        // instead of reading the newer one at callback time.
        let sameRoot = root.appendingPathComponent("same-store-batch", isDirectory: true)
        let sameStore = CodexQuotaResumeStore(supportDirectory: sameRoot)
        check("same store stages original batch", sameStore.stage([turn], targetAccountKey: key))
        let sameOldBatchID = sameStore.expectedBatchID
        sameStore.abandonStaged()
        check("same store stages replacement batch", sameStore.stage([newerTurn], targetAccountKey: key))
        let sameNewBatchID = sameStore.expectedBatchID
        UsageStore.confirmReadyQuotaResume(
            sameStore, switchSucceeded: true, pausedTasksConfirmed: true,
            historyConfirmed: true, accountKey: key, batchID: sameOldBatchID)
        let sameAfterOld = CodexQuotaResumeStore(supportDirectory: sameRoot)
        check("late old batch callback cannot confirm same-store replacement",
              sameOldBatchID != sameNewBatchID && !sameStore.isReady
                && !sameAfterOld.isReady && sameAfterOld.pending == [newerTurn])
        UsageStore.confirmReadyQuotaResume(
            sameStore, switchSucceeded: true, pausedTasksConfirmed: true,
            historyConfirmed: true, accountKey: key, batchID: sameNewBatchID)
        let sameAfterNew = CodexQuotaResumeStore(supportDirectory: sameRoot)
        check("current batch callback confirms same-store replacement",
              sameStore.isReady && sameAfterNew.isReady && sameAfterNew.pending == [newerTurn])
        print("PASS \(checks) isolated continuation-flow checks; no live IPC or account writes")
    }
}
