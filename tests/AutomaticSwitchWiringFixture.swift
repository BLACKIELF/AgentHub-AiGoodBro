// Offline harness. The runner inserts production methods verbatim (visibility only
// changes from private to fileprivate). No AppKit, credentials, network or GUI.
import Foundation
import Darwin

// In-memory replacement: even production preference accesses cannot reach disk.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    init() {}
    convenience init?(suiteName: String) { self.init() }
    func object(forKey key: String) -> Any? { values[key] }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func synchronize() -> Bool { true }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func removePersistentDomain(forName name: String) { values.removeAll() }
}

struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ zh: String, _ en: String) -> String { en }
}
struct RateWindow { let usedPercent: Double }
struct AccountInfo { let email: String?; var planType: String? = "plus" }
struct UsageSnapshot {
    var account: AccountInfo? = .init(email: "fixture-source")
    var refreshedAt = Date()
    var quotaReadSucceeded = true
    var fiveHourQuota: RateWindow? = .init(usedPercent: 82)
    var sevenDayQuota: RateWindow? = .init(usedPercent: 20)
    var taskBoard: Int? = nil
}
enum TaskConnectionMode { case disconnected, sharedDaemon }
enum TaskRuntimeState { case running, waitingInput, recorded, disconnected, idle, failed, completed, interrupted }
struct TaskLiveRecord {
    var threadID = "synthetic"
    var name: String? = nil
    let state: TaskRuntimeState
    var updatedAt: Date? = nil
    var turnID: String? = nil
    var connectionMode = TaskConnectionMode.sharedDaemon
}
struct CodexTaskLiveSnapshot {
    var connectionMode = TaskConnectionMode.sharedDaemon
    var records: [String: TaskLiveRecord] = [:]
    var refreshedAt = Date()
    static var disconnected: Self { Self(connectionMode: .disconnected) }
}
struct CodexAccountSnapshot {
    var accountID: String? = "source-id"
    var email: String? = "fixture-source"
    var planType: String? = "plus"
    var fiveHour: RateWindow? = .init(usedPercent: 20)
    var sevenDay: RateWindow? = .init(usedPercent: 20)
    var quotaReadSucceeded: Bool? = true
    var fetchedAt = Date()
}
struct CodexProfile {
    var id: String
    var isSystemProfile = false
    var recordedAccountKey = "fixture-source"
    var displayedProTierMultiplier: Int? = nil
    var lastSnapshot: CodexAccountSnapshot? = .init()
    var lastQuotaReadFailureAt: Date? = nil
    var codexHomeURL: URL
    var codexHomePath: String { codexHomeURL.path }
    func matchesRecordedCredential(_ identity: CodexCredentialIdentity) -> Bool {
        recordedAccountKey == identity.email && lastSnapshot?.accountID == identity.accountID
    }
}
struct FeishuMaskedAccount { var value = "masked" }
struct CodexCredentialIdentity { let email: String; let accountID: String }
enum FeishuSwitchNotification { enum FailureReason { case unknown, validationFailed } }
enum Event { case lowQuotaDetected, switchSucceeded, switchFailed(FeishuSwitchNotification.FailureReason) }
enum Level { case warning, success, failure }
enum Scope { case codex }
enum AccountDisplay {
    static func profileName(_ profile: CodexProfile, allProfiles: [CodexProfile] = []) -> String { profile.id }
}
enum NSRunningApplication {
    static var desktopRunning = false
    static func runningApplications(withBundleIdentifier id: String) -> [Int] {
        id == "com.openai.codex" && desktopRunning ? [1] : []
    }
}
final class FakeActions {
    var fails = false
    func currentSystemAuthFingerprint(expectedEmail: String, expectedAccountID: String) throws -> Data {
        if fails { throw NSError(domain: "fixture", code: 1) }
        return Data([0]) // Synthetic evidence only; never reads a file.
    }
}
final class FakeTaskClient: @unchecked Sendable {
    var result: CodexTaskLiveSnapshot? = .init()
    var reads = 0
    func awaitSnapshot(timeout: TimeInterval) -> CodexTaskLiveSnapshot? { reads += 1; return result }
    enum Reason { case startup }
    func start(reason: Reason) {}
    func stop() {}
    func refreshThreads() {}
    func desktopPauseRequest(_ method: String, params: [String: Any]) async -> [String: Any]? { nil }
}
struct CodexPausedDesktopTurn { let threadID: String; let turnID: String }
enum CodexThreadHistoryProbe {
    enum Failure: Error { case unavailable }
    static func capture(threadID: String) -> Result<Int, Failure> { .failure(.unavailable) }
}
enum CodexDesktopQuotaPause {
    @MainActor static var pauseAttempts = 0
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
    static func activeTurnID(_ result: [String: Any]) -> String? { nil }
    @MainActor static func pause(
        client: FakeTaskClient, requiredThreadID: String?,
        onLoadedThreads: (@MainActor (Set<String>) -> Void)?,
        preflightHistory: @escaping @MainActor ([CodexPausedDesktopTurn]) async -> Bool,
        prepareInterrupts: @escaping @MainActor ([CodexPausedDesktopTurn]) -> Bool,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async -> Bool {
        pauseAttempts += 1
        return false // No IPC in the fixture: an unavailable pause must block switching.
    }
}
enum CodexOfficialProfileReader {
    static var identitiesByPath: [String: CodexCredentialIdentity] = [:]
    static var unreadablePaths: Set<String> = []
    static func credentialIdentity(codexHomeURL: URL) -> CodexCredentialIdentity? {
        if unreadablePaths.contains(codexHomeURL.path) { return nil }
        return identitiesByPath[codexHomeURL.path]
            ?? .init(email: "fixture-target", accountID: "target-id")
    }
}
enum TokenMonitorHostIdentity {
    static func accountKey(email: String?, accountID: String?) -> String? {
        guard let email, let accountID else { return nil }
        return email + ":" + accountID
    }
    static func uniqueProfile(for key: String, profiles: [CodexProfile]) -> CodexProfile? {
        let matches = profiles.filter { accountKey(email: $0.lastSnapshot?.email, accountID: $0.lastSnapshot?.accountID) == key }
        return matches.count == 1 ? matches[0] : nil
    }
}
struct TokenMonitorManagedCodexAccount {
    let id: String; let accountKey: String; let workspaceAccountId: String
    let homePath: String; let alias: String; let enabled: Bool
}
final class FakeProfileStore {
    func effectiveCredentialHome(for profileID: String) -> URL? { nil }
}
final class FakeQuotaResume {
    var isReady = false
    var expectedAccountKey: String?
    var expectedBatchID: String?
    var oneShotQuotaPolicy: CodexOneShotSwitchIntent.QuotaPolicy?
    func canBeginAutomaticSwitch() -> Bool { true }
    func stage(_ turns: [CodexPausedDesktopTurn], targetAccountKey: String,
               oneShotQuotaPolicy: CodexOneShotSwitchIntent.QuotaPolicy?) -> Bool { false }
}
enum CodexSessionOpener {
    static var visible: String?
    static func visibleThreadID(in board: Int?) -> String? { visible }
}
final class TokenMonitorCancellation {
    var isCancelled = false
    func cancel() { isCancelled = true }
}
struct HubAccountTaskStatus {
    var isBusy = false
    func blockingReason(_ language: WidgetLanguage) -> String? { isBusy ? "occupied" : nil }
}
enum CodexSwitchSnapshotProjection {
    static func snapshot(saved: CodexAccountSnapshot?, identity: CodexCredentialIdentity?) -> UsageSnapshot {
        UsageSnapshot(account: identity.map { AccountInfo(email: $0.email, planType: saved?.planType) },
            refreshedAt: saved?.fetchedAt ?? .distantPast,
            quotaReadSucceeded: saved?.quotaReadSucceeded == true,
            fiveHourQuota: saved?.fiveHour, sevenDayQuota: saved?.sevenDay)
    }
}
final class UsageStore {
    // PRODUCTION_METHODS
    var refreshGeneration: UInt64 = 0
    var fullRefreshCancellation: TokenMonitorCancellation?
    var identityRefreshCancellation: TokenMonitorCancellation?
    var engineQuotaCancellation: TokenMonitorCancellation?
    var refreshingProfileIDs: Set<String> = []
    var warmUpRefreshStartedAt: Date?
    var hasPendingRefresh = false
    var authRefreshWorkItem: DispatchWorkItem?
    var automaticCandidateRefreshAttemptAt: Date?
    var refreshedCandidates: Set<String> = []
    var restorableThreadID: String?
    var codexHistoryConfirmationSuccess: (() -> Void)?
    var codexHistoryConfirmationFailure: ((String) -> Void)?
    var isAwaitingCodexHistoryConfirmation = false
    var codexHistoryConfirmationTimeout: DispatchWorkItem?
    func dismissAccountSwitchAlert() {}
    func presentAccountSwitchBlock(_ message: String, isAutomatic: Bool) { accountManagerMessage = message }
    func refreshWarmUpProfilesThenSchedule(performWarmUpAfterRefresh: Bool, profileIDs: Set<String>, quotaOnly: Bool, refreshMembershipDates: Bool, completion: @escaping (Bool) -> Void) {
        precondition(!performWarmUpAfterRefresh && quotaOnly && !refreshMembershipDates)
        refreshedCandidates = profileIDs
    }
    var hasStarted = true
    var automaticAccountSwitchEnabled = true
    var automaticSwitchContext: AutomaticSwitchContext?
    var automaticSwitchTargetID: String?
    var isAccountSwitchTransactionActive = false
    var desktopSwitchMaintenanceLeases: [Int] = []
    var isLoggingIn = false
    var isLaunchingCodex = false
    var isRefreshing = false
    var isRefreshingWarmUpProfiles = false
    var warmingProfileID: String?
    var selectedMonitorProfileID = "source"
    var profiles: [CodexProfile] = []
    var selectedMonitorProfile: CodexProfile? { profiles.first { $0.id == selectedMonitorProfileID } }
    var snapshot = UsageSnapshot()
    var codexLiveTasks = CodexTaskLiveSnapshot()
    var codexInactiveSince: Date? = Date().addingTimeInterval(-180)
    var lowQuotaAlertThresholds = LowQuotaAlertThresholds(fiveHour: 20, sevenDay: 10)
    var desktopSwitchSucceeded = false
    var desktopSwitchTargetID: String?
    var canCancelDesktopSwitch = false
    var accountManagerMessage: String?
    var desktopSwitchPreparationTask: Task<Void, Never>?
    var quotaResumeTask: Task<Void, Never>?
    let quotaResume = FakeQuotaResume()
    let profileStore = FakeProfileStore()
    var pauseDesktopTasksAtOnePercent = false
    var pausedAutomationFeatures: Set<PausedAutomationFeature> = []
    var resumeDesktopTasksAfterSwitch = false
    var oneShotResumeAuthorization: (accountKey: String, policy: CodexOneShotSwitchIntent.QuotaPolicy)?
    let accountActions = FakeActions()
    let taskClient = FakeTaskClient()
    var reserved = true
    var transactions = 0
    var manualEntries = 0
    var forcedManualEntries = 0
    var transactionFails = false
    var excluded: Set<String> = []
    var events: [Event] = []
    func runtimeSnapshot(for scope: Scope) -> (snapshot: UsageSnapshot, ignored: Int)? { (snapshot, 0) }
    func automaticSwitchParticipation(for profile: CodexProfile) -> Bool { !excluded.contains(profile.id) }
    func automaticSwitchParticipation(for id: String) -> Bool { !excluded.contains(id) }
    func maskedAccount(for profile: CodexProfile) -> FeishuMaskedAccount? { .init() }
    func sendLocalLowQuotaNotification(_ quota: AutomaticSwitchQuotaState) {}
    func sendFeishuNotification(event: Event, source: FeishuMaskedAccount, target: FeishuMaskedAccount?, quota: AutomaticSwitchQuotaState, factsSnapshot: UsageSnapshot? = nil, eventID: UUID, switchOrigin: Origin? = nil) { events.append(event) }
    enum Origin { case lowQuota }
    func recordAutomationEvent(level: Level, title: String, detail: String) {}
    func reserveDesktopSwitchMaintenance(for profileID: String) async -> Bool {
        if reserved { desktopSwitchMaintenanceLeases = [1] }
        return reserved
    }
    func finishDesktopSwitchMaintenance() { desktopSwitchMaintenanceLeases.removeAll() }
    func resumePausedDesktopTasks(automatically: Bool) {}
    static func confirmReadyQuotaResume(_ resume: FakeQuotaResume, switchSucceeded: Bool,
        pausedTasksConfirmed: Bool, historyConfirmed: Bool,
        accountKey: String, batchID: String?) {}
    func finishDesktopSwitchPreparation() { desktopSwitchPreparationTask = nil; canCancelDesktopSwitch = false }
    func finalAutomaticGate() -> Bool {
        let profile = profiles[2]
        let systemProfile = profiles[1]
        let profileID = profile.id
        let currentSystemSnapshot = snapshot
        let threadIDToRestore = restorableThreadID
        var verifiedSnapshot = UsageSnapshot()
        verifiedSnapshot.account = .init(email: profile.lastSnapshot?.email, planType: profile.lastSnapshot?.planType)
        verifiedSnapshot.fiveHourQuota = profile.lastSnapshot?.fiveHour
        verifiedSnapshot.sevenDayQuota = profile.lastSnapshot?.sevenDay
        verifiedSnapshot.refreshedAt = profile.lastSnapshot?.fetchedAt ?? .distantPast
        verifiedSnapshot.quotaReadSucceeded = profile.lastSnapshot?.quotaReadSucceeded == true
        let currentSystemCredentialIdentity = CodexCredentialIdentity(email: "fixture-source", accountID: "source-id")
        let targetCredentialIdentity = CodexCredentialIdentity(email: "fixture-target", accountID: "target-id")
        // PRODUCTION_FINAL_GATE
    }
    // Injected transaction boundary: no credentials or process actions.
    func beginCodexSwitch(with profileID: String, forceWithoutSessionRestore: Bool, visibleThreadID: String?) {
        defer { finishDesktopSwitchMaintenance() }
        if automaticSwitchTargetID != profileID {
            manualEntries += 1
            if forceWithoutSessionRestore { forcedManualEntries += 1 }
            isLaunchingCodex = false
            return
        }
        let complete = automaticSwitchContext?.completeTasks
        guard let complete, finalAutomaticGate(),
            CodexAutomaticSwitchPolicy.hasSafeTaskState(complete, codexInactiveSince: codexInactiveSince, legacyManagerRunning: false)
        else {
            isLaunchingCodex = false
            finishAutomaticSwitchAttempt(for: profileID, succeeded: false, detail: "fixture blocked")
            return
        }
        transactions += 1
        isLaunchingCodex = false
        finishAutomaticSwitchAttempt(for: profileID, succeeded: !transactionFails, detail: "fixture completion")
    }
}

// Synthetic credential state for the extracted pre-write guard; no auth files are read.
enum CodexCredentialTransaction {
    enum Failure: Error { case superseded }
    static var targetChanged = false
    static func read(_ url: URL) throws -> Data { Data([targetChanged ? 1 : 0]) }
}

final class AtomicProbeFixture {
    static var processIDs: [Int] = []
    static var unknown = false
    static var sourceChanged = false
    var writes = 0
    static func authState(at url: URL) throws -> Data { Data([sourceChanged ? 1 : 0]) }
    static func codexProcessIDs(appURL: URL) throws -> [Int] {
        if unknown { throw NSError(domain: "fixture", code: 1) }
        return processIDs
    }
    static func switchError(_ message: String) -> Error { NSError(domain: "fixture", code: 2) }
    func write() throws {
        let appURL = URL(fileURLWithPath: "fixture-desktop")
        let systemAuthURL = URL(fileURLWithPath: "fixture-source")
        let targetAuthURL = URL(fileURLWithPath: "fixture-target")
        let currentSourceAuth = Data([0])
        let targetAuth = Data([0])
        // PRODUCTION_ATOMIC_PROBE
        writes += 1 // Injected write: no credential or file operation.
    }
}

@main struct AutomaticSwitchWiringFixture {
    @MainActor static func main() async throws {
        // Redirect production .standard references in extraction to this isolated suite.
        let root = URL(fileURLWithPath: "task-test-outputs/revision-0912v2/fixture-data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("auth.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ label: String, _ condition: Bool) {
            checks += 1
            guard condition else { print("FAIL \(label)"); exit(1) }
            print("PASS \(label)")
        }
        func store() -> UsageStore {
            fixtureDefaults.removePersistentDomain(forName: fixtureSuite)
            NSRunningApplication.desktopRunning = false
            CodexSessionOpener.visible = nil
            CodexOfficialProfileReader.identitiesByPath = [:]
            CodexOfficialProfileReader.unreadablePaths = []
            let s = UsageStore()
            s.profiles = [.init(id: "source", codexHomeURL: root), .init(id: "system", isSystemProfile: true, codexHomeURL: root), .init(id: "target", codexHomeURL: root)]
            s.profiles[0].lastSnapshot?.fiveHour = .init(usedPercent: 82)
            s.profiles[1].lastSnapshot?.fiveHour = .init(usedPercent: 82)
            s.profiles[2].lastSnapshot?.accountID = "target-id"
            s.profiles[2].lastSnapshot?.email = "fixture-target"
            s.profiles[2].recordedAccountKey = "fixture-target"
            return s
        }
        func settle(_ s: UsageStore) async {
            let pending = s.desktopSwitchPreparationTask
            await pending?.value
        }
        let valid = store()
        valid.evaluateAutomaticAccountSwitch()
        valid.evaluateAutomaticAccountSwitch()
        await settle(valid)
        check("shared entry once under duplicate evaluation", valid.transactions == 1 && valid.taskClient.reads == 1)
        check("successful context completion", valid.automaticSwitchContext == nil && valid.automaticSwitchTargetID == nil)
        let mismatchedHome = root.appendingPathComponent("misbound", isDirectory: true)
        try FileManager.default.createDirectory(at: mismatchedHome, withIntermediateDirectories: true)
        try Data().write(to: mismatchedHome.appendingPathComponent("auth.json"))
        let misbound = store()
        var highScore = CodexProfile(id: "misbound", codexHomeURL: mismatchedHome)
        highScore.lastSnapshot?.accountID = "old-id"
        highScore.lastSnapshot?.email = "old@example.invalid"
        highScore.lastSnapshot?.fiveHour = .init(usedPercent: 1)
        highScore.recordedAccountKey = "old@example.invalid"
        misbound.profiles.append(highScore)
        CodexOfficialProfileReader.identitiesByPath[mismatchedHome.path] = .init(
            email: "other@example.invalid", accountID: "other-id")
        misbound.evaluateAutomaticAccountSwitch()
        check(
            "misbound high-score candidate does not displace valid backup",
            misbound.automaticSwitchTargetID == "target")
        await settle(misbound)
        check(
            "valid backup completes after misbound candidate is skipped",
            misbound.transactions == 1
                && fixtureDefaults.object(forKey: CodexAutomaticSwitchPolicy.lastSuccessDefaultsKey) != nil)
        let unreadable = store()
        CodexOfficialProfileReader.unreadablePaths.insert(root.path)
        unreadable.evaluateAutomaticAccountSwitch()
        check(
            "unreadable-only pool does not switch or record success",
            unreadable.automaticSwitchTargetID == nil
                && fixtureDefaults.object(forKey: CodexAutomaticSwitchPolicy.lastSuccessDefaultsKey) == nil)
        let proWeeklySource = store()
        proWeeklySource.profiles[0].lastSnapshot?.planType = "pro"
        proWeeklySource.profiles[1].lastSnapshot?.planType = "pro"
        proWeeklySource.profiles[0].lastSnapshot?.fiveHour = nil
        proWeeklySource.profiles[1].lastSnapshot?.fiveHour = nil
        proWeeklySource.profiles[0].lastSnapshot?.sevenDay = .init(usedPercent: 95)
        proWeeklySource.profiles[1].lastSnapshot?.sevenDay = .init(usedPercent: 95)
        proWeeklySource.snapshot.account?.planType = "pro"
        proWeeklySource.snapshot.fiveHourQuota = nil
        proWeeklySource.snapshot.sevenDayQuota = .init(usedPercent: 95)
        proWeeklySource.evaluateAutomaticAccountSwitch(); await settle(proWeeklySource)
        check("Pro source with applicable weekly window can switch", proWeeklySource.transactions == 1)
        let criticalPause = store()
        criticalPause.pauseDesktopTasksAtOnePercent = true
        criticalPause.profiles[0].lastSnapshot?.fiveHour = .init(usedPercent: 99.5)
        criticalPause.profiles[1].lastSnapshot?.fiveHour = .init(usedPercent: 99.5)
        criticalPause.snapshot.fiveHourQuota = .init(usedPercent: 99.5)
        CodexDesktopQuotaPause.pauseAttempts = 0
        criticalPause.evaluateAutomaticAccountSwitch(); await settle(criticalPause)
        check("critical quota enters pause branch and fails closed without IPC",
              CodexDesktopQuotaPause.pauseAttempts == 1 && criticalPause.transactions == 0
                && criticalPause.automaticSwitchContext == nil && criticalPause.desktopSwitchMaintenanceLeases.isEmpty)
        func weeklyFinalGate(
            sourcePlan: String, policy: CodexOneShotSwitchIntent.QuotaPolicy?,
            targetMultiplier: Int? = 20, targetHasWeek: Bool = true
        ) -> Bool {
            let s = store()
            s.snapshot.account?.planType = sourcePlan
            s.snapshot.fiveHourQuota = nil
            s.snapshot.sevenDayQuota = .init(usedPercent: policy == nil ? 95 : 20)
            s.profiles[2].lastSnapshot?.planType = "pro"
            s.profiles[2].lastSnapshot?.fiveHour = nil
            s.profiles[2].lastSnapshot?.sevenDay = targetHasWeek ? .init(usedPercent: 20) : nil
            s.profiles[2].displayedProTierMultiplier = targetMultiplier
            s.automaticSwitchContext = .init(
                sourceProfileID: "source", sourceIdentityKey: "fixture-source",
                sourceAccountID: "source-id", sourceAuthFingerprint: Data([0]),
                sourceAccount: .init(), targetAccount: .init(),
                sourceQuota: .init(snapshot: s.snapshot), eventID: UUID(),
                thresholds: s.lowQuotaAlertThresholds, pauseAtOnePercent: false,
                completeTasks: s.codexLiveTasks)
            if let policy {
                s.automaticSwitchContext?.oneShotIntent = .init(
                    profileID: "target", quotaPolicy: policy,
                    operationID: UUID(), simulateLowQuota: false)
            }
            s.automaticSwitchTargetID = "target"
            return s.finalAutomaticGate()
        }
        check("ordinary Plus missing 5h remains incomplete at final gate",
              !weeklyFinalGate(sourcePlan: "plus", policy: nil))
        check("ordinary Pro weekly-only source passes final applicable-window gate",
              weeklyFinalGate(sourcePlan: "pro", policy: nil))
        check("one-shot reported-week accepts fresh Pro weekly-only windows",
              weeklyFinalGate(sourcePlan: "pro", policy: .reportedWeek))
        check("one-shot complete still requires the 5h window",
              !weeklyFinalGate(sourcePlan: "pro", policy: .complete))
        check("one-shot weekly-only rejects Plus and mismatched Pro tier",
              !weeklyFinalGate(sourcePlan: "plus", policy: .reportedWeek)
                && !weeklyFinalGate(sourcePlan: "pro", policy: .reportedWeek, targetMultiplier: 5))
        check("one-shot weekly-only still requires the reported week",
              !weeklyFinalGate(sourcePlan: "pro", policy: .reportedWeek, targetHasWeek: false))
        for name in ["disabled", "expired", "future", "read-failed", "failed-after", "partial-source", "plus-missing-five", "exhausted-target", "partial-target", "tasks-nil", "active-task", "desktop", "busy", "cooldown", "identity", "reservation"] {
            let s = store()
            switch name {
            case "disabled": s.automaticAccountSwitchEnabled = false
            case "expired": s.profiles[2].lastSnapshot?.fetchedAt = Date().addingTimeInterval(-46)
            case "future": s.profiles[2].lastSnapshot?.fetchedAt = Date().addingTimeInterval(6)
            case "read-failed": s.profiles[2].lastSnapshot?.quotaReadSucceeded = false
            case "failed-after": s.profiles[2].lastQuotaReadFailureAt = Date().addingTimeInterval(1)
            case "partial-source": s.snapshot.sevenDayQuota = nil; s.profiles[1].lastSnapshot?.sevenDay = nil
            case "plus-missing-five":
                s.profiles[0].lastSnapshot?.fiveHour = nil; s.profiles[1].lastSnapshot?.fiveHour = nil
                s.profiles[0].lastSnapshot?.sevenDay = .init(usedPercent: 95)
                s.profiles[1].lastSnapshot?.sevenDay = .init(usedPercent: 95)
                s.snapshot.fiveHourQuota = nil; s.snapshot.sevenDayQuota = .init(usedPercent: 95)
            case "exhausted-target": s.profiles[2].lastSnapshot?.sevenDay = .init(usedPercent: 100)
            case "partial-target": s.profiles[2].lastSnapshot?.sevenDay = nil
            case "tasks-nil": s.taskClient.result = nil
            case "active-task": s.taskClient.result?.records = ["synthetic": .init(state: .running)]
            case "desktop": NSRunningApplication.desktopRunning = true
            case "busy": s.isAccountSwitchTransactionActive = true
            case "cooldown": fixtureDefaults.set(Date(), forKey: CodexAutomaticSwitchPolicy.lastSuccessDefaultsKey)
            case "identity": s.accountActions.fails = true
            case "reservation": s.reserved = false
            default: break
            }
            s.evaluateAutomaticAccountSwitch()
            await settle(s)
            check(name, s.transactions == 0 && s.automaticSwitchContext == nil && s.automaticSwitchTargetID == nil)
            if name == "tasks-nil" { check("nil invalidates formerly fresh display", s.codexLiveTasks.connectionMode == .disconnected) }
        }
        let failed = store(); failed.transactionFails = true
        failed.evaluateAutomaticAccountSwitch(); await settle(failed)
        check("injected transaction failure completes context", failed.transactions == 1 && failed.automaticSwitchContext == nil)
        let restart = store(); restart.evaluateAutomaticAccountSwitch()
        NSRunningApplication.desktopRunning = true
        await settle(restart)
        check("injected desktop restart blocks transaction boundary", restart.transactions == 0 && restart.automaticSwitchContext == nil)
        let cancelled = store(); cancelled.evaluateAutomaticAccountSwitch()
        cancelled.desktopSwitchPreparationTask?.cancel()
        await settle(cancelled)
        check("cancellation completes context", cancelled.transactions == 0 && cancelled.automaticSwitchContext == nil)
        for mode in ["disabled-final", "partial-source-final", "stale-target-final", "task-stale-final", "threshold-changed"] {
            let s = store()
            s.evaluateAutomaticAccountSwitch()
            switch mode {
            case "disabled-final": s.automaticAccountSwitchEnabled = false
            case "partial-source-final": s.snapshot.sevenDayQuota = nil
            case "stale-target-final": s.profiles[2].lastSnapshot?.fetchedAt = Date().addingTimeInterval(-46)
            case "task-stale-final": s.taskClient.result?.refreshedAt = Date().addingTimeInterval(-46)
            case "threshold-changed": s.lowQuotaAlertThresholds = .standard
            default: break
            }
            await settle(s)
            check(mode, s.transactions == 0 && s.automaticSwitchContext == nil)
        }
        for mode in ["safe", "restarted", "unknown", "application", "source-changed", "target-changed"] {
            AtomicProbeFixture.processIDs = mode == "restarted" ? [1] : []
            AtomicProbeFixture.unknown = mode == "unknown"
            AtomicProbeFixture.sourceChanged = mode == "source-changed"
            CodexCredentialTransaction.targetChanged = mode == "target-changed"
            NSRunningApplication.desktopRunning = mode == "application"
            let writer = AtomicProbeFixture()
            do { try writer.write() } catch {}
            check("actual prewrite probe \(mode)", writer.writes == (mode == "safe" ? 1 : 0))
        }
        let refreshingManual = store()
        refreshingManual.isRefreshing = true
        refreshingManual.isRefreshingWarmUpProfiles = true
        let full = TokenMonitorCancellation(), pool = TokenMonitorCancellation(), identity = TokenMonitorCancellation()
        refreshingManual.fullRefreshCancellation = full
        refreshingManual.engineQuotaCancellation = pool
        refreshingManual.identityRefreshCancellation = identity
        let started = Date()
        refreshingManual.launchCodex(with: "target")
        await settle(refreshingManual)
        check("manual switch skips quota waiting", refreshingManual.manualEntries == 1 && Date().timeIntervalSince(started) < 1)
        check("manual switch cancels owned quota readers", full.isCancelled && pool.isCancelled && identity.isCancelled && refreshingManual.refreshGeneration == 1)
        let busyClick = store()
        busyClick.requestDesktopSwitch(with: "target", status: .init(isBusy: true))
        await settle(busyClick)
        check("busy account click explains block", busyClick.manualEntries == 0 && busyClick.accountManagerMessage == "occupied")
        let differentMonitor = store(); differentMonitor.selectedMonitorProfileID = "target"
        differentMonitor.evaluateAutomaticAccountSwitch(); await settle(differentMonitor)
        check("automatic source is desktop, independent of monitoring selection", differentMonitor.transactions == 1)
        let openIdle = store(); NSRunningApplication.desktopRunning = true
        CodexSessionOpener.visible = "synthetic"
        openIdle.restorableThreadID = "synthetic"
        openIdle.evaluateAutomaticAccountSwitch(); await settle(openIdle)
        check("open idle desktop with restorable conversation can switch", openIdle.transactions == 1)
        let staleCandidate = store()
        staleCandidate.profiles[2].lastSnapshot?.fetchedAt = Date().addingTimeInterval(-90)
        staleCandidate.evaluateAutomaticAccountSwitch(); await settle(staleCandidate)
        check("stale candidates trigger quota-only refresh before choosing", staleCandidate.transactions == 0 && staleCandidate.refreshedCandidates == ["source", "system", "target"])
        check("candidate refresh does not consume attempt cooldown", fixtureDefaults.object(forKey: CodexAutomaticSwitchPolicy.lastAttemptDefaultsKey) == nil)
        let completion = store()
        var committed = 0
        completion.beginCodexHistoryConfirmation(isAutomaticSwitch: true, onSuccess: { committed += 1 }, onFailure: { _ in })
        check("automatic verified restore commits without human timeout", committed == 1 && !completion.isAwaitingCodexHistoryConfirmation && completion.codexHistoryConfirmationTimeout == nil)
        completion.beginCodexHistoryConfirmation(isAutomaticSwitch: false, onSuccess: { committed += 1 }, onFailure: { _ in })
        check("manual history confirmation remains required", committed == 1 && completion.isAwaitingCodexHistoryConfirmation)
        completion.confirmRestoredCodexHistory()
        check("manual confirmation completes exactly once", committed == 2 && !completion.isAwaitingCodexHistoryConfirmation)
        let firstManual = store(); firstManual.taskClient.result = nil
        firstManual.launchCodex(with: "target")
        await settle(firstManual)
        check("missing task snapshot reaches unconfirmed manual boundary", firstManual.manualEntries == 1 && firstManual.forcedManualEntries == 0 && firstManual.transactions == 0)
        check("manual missing snapshot invalidates cached task display", firstManual.codexLiveTasks.connectionMode == .disconnected)
        let occupiedManual = store(); occupiedManual.taskClient.result = nil; occupiedManual.reserved = false
        occupiedManual.launchCodex(with: "target")
        await settle(occupiedManual)
        check("manual missing snapshot still respects maintenance reservation", occupiedManual.manualEntries == 0 && !occupiedManual.isLaunchingCodex)
        let manual = store(); manual.taskClient.result = nil
        manual.launchCodex(with: "target", forceWithoutSessionRestore: true)
        await settle(manual)
        check("explicit manual force preserved at preparation boundary", manual.forcedManualEntries == 1)
        fixtureDefaults.removePersistentDomain(forName: fixtureSuite)
        print("PASS \(checks) checks; injected transaction boundary, not production transaction execution")
    }
}
let fixtureSuite = "CodexManagerNext.fixture.automatic-switch-wiring"
let fixtureDefaults = UserDefaults.standard
