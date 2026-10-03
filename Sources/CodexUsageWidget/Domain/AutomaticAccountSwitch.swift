import Foundation

struct LowQuotaAlertThresholds: Equatable {
    static let choices = [1, 5, 10, 15, 20, 25]
    static let standard = LowQuotaAlertThresholds(fiveHour: 5, sevenDay: 10)
    static let fiveHourKey = "CodexManagerNext.lowQuotaAlerts.fiveHourThreshold"
    static let sevenDayKey = "CodexManagerNext.lowQuotaAlerts.sevenDayThreshold"

    let fiveHour: Int
    let sevenDay: Int

    init(fiveHour: Int, sevenDay: Int) {
        self.fiveHour = Self.choices.contains(fiveHour) ? fiveHour : 5
        self.sevenDay = Self.choices.contains(sevenDay) ? sevenDay : 10
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        func value(_ key: String, fallback: Int) -> Int {
            guard let number = defaults.object(forKey: key) as? NSNumber,
                number.doubleValue == Double(number.intValue), choices.contains(number.intValue)
            else { return fallback }
            return number.intValue
        }
        return Self(fiveHour: value(fiveHourKey, fallback: 5), sevenDay: value(sevenDayKey, fallback: 10))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(fiveHour, forKey: Self.fiveHourKey)
        defaults.set(sevenDay, forKey: Self.sevenDayKey)
    }
}

enum PausedAutomationFeature: String, CaseIterable {
    case fiveHour = "CodexManagerNext.automaticWarmUp.fiveHour"
    case sevenDay = "CodexManagerNext.automaticWarmUp.sevenDay"
    case lowQuota = "CodexManagerNext.automaticAccountSwitch.enabled"
    case feishu = "CodexManagerNext.feishuNotifications.enabled"
    case localNotification = "CodexManagerNext.localNotifications.enabled"

    static func read(from argumentDomain: [String: Any]) -> [Self] {
        allCases.filter { feature in
            if let string = argumentDomain[feature.rawValue] as? String {
                return ["no", "false", "0"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            return (argumentDomain[feature.rawValue] as? NSNumber)?.doubleValue == 0
        }
    }

    func name(_ language: WidgetLanguage) -> String {
        switch self {
        case .fiveHour: return language.text("5 小时暖号", "5h warm-up")
        case .sevenDay: return language.text("7 天暖号", "Weekly warm-up")
        case .lowQuota: return language.text("低额度提醒", "Low-limit alerts")
        case .feishu: return language.text("飞书通知", "Feishu notifications")
        case .localNotification: return language.text("系统通知", "System notifications")
        }
    }
}

enum AutomaticQuotaWindow: String, CaseIterable, Equatable {
    case fiveHour
    case sevenDay

    var displayName: String {
        switch self {
        case .fiveHour: return "5 小时"
        case .sevenDay: return "7 天"
        }
    }
}

struct AutomaticSwitchQuotaState: Equatable {
    let fiveHourRemaining: Double?
    let sevenDayRemaining: Double?
    /// Proven only by a successful official Pro/Prolite response with no 5h field.
    let fiveHourNotApplicable: Bool

    init(fiveHourRemaining: Double?, sevenDayRemaining: Double?, fiveHourNotApplicable: Bool = false) {
        self.fiveHourRemaining = Self.valid(fiveHourRemaining)
        self.sevenDayRemaining = Self.valid(sevenDayRemaining)
        self.fiveHourNotApplicable = fiveHourRemaining == nil && fiveHourNotApplicable
    }

    init(snapshot: UsageSnapshot) {
        self.init(
            // Validate raw values before the presentation layer clamps them.
            fiveHourRemaining: snapshot.fiveHourQuota.map { 100 - $0.usedPercent },
            sevenDayRemaining: snapshot.sevenDayQuota.map { 100 - $0.usedPercent },
            fiveHourNotApplicable: snapshot.quotaReadSucceeded && snapshot.fiveHourQuota == nil
                && Self.isSupportedPlan(snapshot.account?.planType)
        )
    }

    init(savedSnapshot: CodexAccountSnapshot) {
        self.init(
            fiveHourRemaining: savedSnapshot.fiveHour.map { 100 - $0.usedPercent },
            sevenDayRemaining: savedSnapshot.sevenDay.map { 100 - $0.usedPercent },
            fiveHourNotApplicable: savedSnapshot.quotaReadSucceeded == true && savedSnapshot.fiveHour == nil
                && Self.isSupportedPlan(savedSnapshot.planType)
        )
    }

    var hasCompleteApplicableWindows: Bool {
        sevenDayRemaining != nil && (fiveHourRemaining != nil || fiveHourNotApplicable)
    }

    var hasPositiveApplicableWindows: Bool {
        guard let week = sevenDayRemaining, week > 0 else { return false }
        return fiveHourNotApplicable || (fiveHourRemaining.map { $0 > 0 } ?? false)
    }

    func simulatingLowQuota() -> Self? {
        guard hasPositiveApplicableWindows else { return nil }
        if fiveHourRemaining != nil {
            return .init(fiveHourRemaining: 0.99, sevenDayRemaining: sevenDayRemaining)
        }
        return .init(fiveHourRemaining: nil, sevenDayRemaining: 0.99, fiveHourNotApplicable: true)
    }

    func candidateRemaining(for window: AutomaticQuotaWindow) -> Double? {
        window == .fiveHour && fiveHourNotApplicable ? sevenDayRemaining : remaining(for: window)
    }

    private static func isSupportedPlan(_ planType: String?) -> Bool {
        guard let plan = planType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return plan == "pro" || plan == "prolite"
    }

    func remaining(for window: AutomaticQuotaWindow) -> Double? {
        switch window {
        case .fiveHour: return fiveHourRemaining
        case .sevenDay: return sevenDayRemaining
        }
    }

    func triggeredWindows(thresholds: LowQuotaAlertThresholds = .standard) -> [AutomaticQuotaWindow] {
        AutomaticQuotaWindow.allCases.filter { window in
            guard let remaining = remaining(for: window) else { return false }
            switch window {
            case .fiveHour:
                return remaining <= Double(thresholds.fiveHour)
            case .sevenDay:
                return thresholds.sevenDay == 1 ? remaining <= 1 : remaining < Double(thresholds.sevenDay)
            }
        }
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

enum CodexAutomaticSwitchPolicy {
    struct Candidate: Equatable {
        let profileID: String
        let quota: AutomaticSwitchQuotaState
    }

    static let enabledDefaultsKey = "CodexManagerNext.automaticAccountSwitch.enabled"
    static let lastAttemptDefaultsKey = "CodexManagerNext.automaticAccountSwitch.lastAttemptAt"
    static let lastSuccessDefaultsKey = "CodexManagerNext.automaticAccountSwitch.lastSucceededAt"
    static let fiveHourTriggerRemainingPercent = 5.0
    static let sevenDayTriggerRemainingPercent = 10.0
    static let minimumCandidateRemainingPercent = 30.0
    static let failureRetryInterval: TimeInterval = 60 * 60
    static let successCooldown: TimeInterval = 30 * 60
    static let quotaSnapshotMaximumAge: TimeInterval = 45
    static let taskSnapshotMaximumAge: TimeInterval = 45
    static let codexInactivePeriod: TimeInterval = 2 * 60

    static func hasNoActiveTasks(
        _ snapshot: CodexTaskLiveSnapshot,
        legacyManagerRunning: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !legacyManagerRunning,
            snapshot.connectionMode != .disconnected
        else { return false }
        let snapshotAge = now.timeIntervalSince(snapshot.refreshedAt)
        guard snapshotAge >= -5, snapshotAge <= taskSnapshotMaximumAge else { return false }
        return !snapshot.records.values.contains {
            switch $0.state {
            case .running, .waitingInput, .recorded, .disconnected:
                return true
            case .idle, .failed, .completed, .interrupted:
                return false
            }
        }
    }

    /// A continuation may have started earlier turns in its own batch. Fresh
    /// task evidence must still reject any other active or uncertain work.
    static func hasNoUnexpectedActiveTasks(
        _ snapshot: CodexTaskLiveSnapshot,
        startedTurns: [String: String],
        legacyManagerRunning: Bool,
        now: Date = Date()
    ) -> Bool {
        guard
            CodexDesktopQuotaPause.canPrepare(
                snapshot,
                legacyManagerRunning: legacyManagerRunning, now: now)
        else { return false }
        return snapshot.records.values.allSatisfy { record in
            switch record.state {
            case .running, .waitingInput:
                return record.turnID != nil && startedTurns[record.threadID] == record.turnID
            case .recorded, .disconnected:
                return false
            case .idle, .failed, .completed, .interrupted:
                return true
            }
        }
    }

    static func hasSafeTaskState(
        _ snapshot: CodexTaskLiveSnapshot,
        codexInactiveSince: Date?,
        legacyManagerRunning: Bool,
        allowForeground: Bool = false,
        now: Date = Date()
    ) -> Bool {
        if !allowForeground {
            guard let codexInactiveSince,
                now.timeIntervalSince(codexInactiveSince) >= codexInactivePeriod
            else { return false }
        }
        return hasNoActiveTasks(
            snapshot,
            legacyManagerRunning: legacyManagerRunning,
            now: now
        )
    }

    static func shouldEvaluate(
        enabled: Bool,
        sourceQuota: AutomaticSwitchQuotaState,
        sourceRefreshedAt: Date,
        taskSnapshot: CodexTaskLiveSnapshot,
        codexInactiveSince: Date?,
        legacyManagerRunning: Bool,
        lastAttemptAt: Date?,
        lastSucceededAt: Date?,
        thresholds: LowQuotaAlertThresholds = .standard,
        pauseAtOnePercent: Bool = false,
        now: Date = Date()
    ) -> Bool {
        let quotaAge = now.timeIntervalSince(sourceRefreshedAt)
        guard enabled,
            quotaAge >= -5,
            quotaAge <= quotaSnapshotMaximumAge,
            sourceQuota.hasCompleteApplicableWindows,
            !sourceQuota.triggeredWindows(thresholds: thresholds).isEmpty,
            pauseAtOnePercent && CodexDesktopQuotaPause.isCritical(sourceQuota)
                ? CodexDesktopQuotaPause.canPrepare(taskSnapshot, legacyManagerRunning: legacyManagerRunning, now: now)
                : hasSafeTaskState(
                    taskSnapshot, codexInactiveSince: codexInactiveSince,
                    legacyManagerRunning: legacyManagerRunning, now: now)
        else { return false }
        if let lastSucceededAt,
            now.timeIntervalSince(lastSucceededAt) < successCooldown
        {
            return false
        }
        if let lastAttemptAt,
            now.timeIntervalSince(lastAttemptAt) < failureRetryInterval
        {
            return false
        }
        return true
    }

    static func preferredCandidate(
        _ candidates: [Candidate],
        for triggeredWindows: [AutomaticQuotaWindow]
    ) -> Candidate? {
        guard !triggeredWindows.isEmpty else { return nil }
        return candidates.compactMap { candidate -> (Candidate, Double)? in
            // A healthy triggered window cannot compensate for an exhausted
            // or unknown other window. Keep ranking on the triggered windows.
            guard candidate.quota.hasPositiveApplicableWindows else { return nil }
            let remaining = triggeredWindows.compactMap(candidate.quota.candidateRemaining(for:))
            guard remaining.count == triggeredWindows.count,
                let score = remaining.min(),
                score >= minimumCandidateRemainingPercent
            else { return nil }
            return (candidate, score)
        }.max { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.profileID > rhs.0.profileID : lhs.1 < rhs.1
        }?.0
    }

    static func lowestTrigger(
        in sourceQuota: AutomaticSwitchQuotaState
    ) -> (window: AutomaticQuotaWindow, remaining: Double)? {
        sourceQuota.triggeredWindows().compactMap { window in
            sourceQuota.remaining(for: window).map { (window, $0) }
        }.min { $0.1 < $1.1 }
    }
}

/// Explicit, process-local permission for one Desktop pause/switch/resume.
/// It never changes the scheduled low-quota automation settings.
struct CodexOneShotSwitchIntent: Equatable {
    enum QuotaPolicy: String, Codable {
        case complete = "complete"
        case reportedWeek = "reported-week"

        func accepts(_ snapshot: UsageSnapshot, target: Bool, now: Date = Date()) -> Bool {
            let age = now.timeIntervalSince(snapshot.refreshedAt)
            guard snapshot.quotaReadSucceeded, age >= -5,
                age <= CodexAutomaticSwitchPolicy.quotaSnapshotMaximumAge,
                CodexOneShotSwitchIntent.targetMultiplier(for: snapshot.account?.planType) != nil,
                let week = AutomaticSwitchQuotaState(snapshot: snapshot).sevenDayRemaining,
                week > 0,
                !target || week >= CodexAutomaticSwitchPolicy.minimumCandidateRemainingPercent
            else { return false }
            let five = AutomaticSwitchQuotaState(snapshot: snapshot).fiveHourRemaining
            if self == .reportedWeek {
                guard snapshot.fiveHourQuota != nil else { return true }
                guard let five else { return false }
                return target ? five >= CodexAutomaticSwitchPolicy.minimumCandidateRemainingPercent : five > 0
            }
            guard let five else { return false }
            return !target || five >= CodexAutomaticSwitchPolicy.minimumCandidateRemainingPercent
        }
    }

    let profileID: String
    let quotaPolicy: QuotaPolicy
    let operationID: UUID
    let simulateLowQuota: Bool

    static func targetMultiplier(for planType: String?) -> Int? {
        guard let plan = planType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        switch plan {
        case "prolite": return 5
        case "pro": return 20
        default: return nil
        }
    }

    static func targetPlanMatches(_ planType: String?, displayedMultiplier: Int?) -> Bool {
        guard let expected = targetMultiplier(for: planType) else { return false }
        return displayedMultiplier == expected
    }

    private static let consumedOperationsKey = "AiGoodBro.oneShotDesktopSwitch.consumedOperationIDs"

    /// Claim before Desktop work begins; a restart with the same launch intent
    /// cannot interrupt the same task a second time.
    func claim(defaults: UserDefaults = .standard) -> Bool {
        let value = operationID.uuidString.lowercased()
        guard
            defaults.object(forKey: Self.consumedOperationsKey) == nil
                || defaults.stringArray(forKey: Self.consumedOperationsKey) != nil
        else { return false }
        var consumed = defaults.stringArray(forKey: Self.consumedOperationsKey) ?? []
        guard !consumed.contains(value) else { return false }
        consumed.append(value)
        defaults.set(consumed, forKey: Self.consumedOperationsKey)
        return defaults.synchronize() && defaults.stringArray(forKey: Self.consumedOperationsKey)?.contains(value) == true
    }

    static func parse(_ arguments: [String]) -> Self? {
        let profileFlag = "--pause-switch-profile-id"
        let policyFlag = "--pause-switch-quota-policy"
        let operationFlag = "--pause-switch-operation-id"
        let simulationFlag = "--simulate-low-quota"
        guard arguments.filter({ $0 == profileFlag }).count == 1,
            arguments.filter({ $0 == policyFlag }).count == 1,
            arguments.filter({ $0 == operationFlag }).count == 1,
            arguments.filter({ $0 == simulationFlag }).count <= 1,
            !arguments.contains("--switch-profile-id"),
            let profileIndex = arguments.firstIndex(of: profileFlag),
            let policyIndex = arguments.firstIndex(of: policyFlag),
            let operationIndex = arguments.firstIndex(of: operationFlag),
            arguments.indices.contains(profileIndex + 1),
            arguments.indices.contains(policyIndex + 1),
            arguments.indices.contains(operationIndex + 1),
            let policy = QuotaPolicy(rawValue: arguments[policyIndex + 1]),
            let operationID = UUID(uuidString: arguments[operationIndex + 1]),
            ![profileIndex + 1, policyIndex + 1, operationIndex + 1].contains(profileIndex),
            ![profileIndex + 1, policyIndex + 1, operationIndex + 1].contains(policyIndex),
            ![profileIndex + 1, policyIndex + 1, operationIndex + 1].contains(operationIndex)
        else { return nil }
        let id = arguments[profileIndex + 1]
        guard !id.isEmpty, id.utf8.count <= 128,
            id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        else { return nil }
        return .init(
            profileID: id, quotaPolicy: policy, operationID: operationID,
            simulateLowQuota: arguments.contains(simulationFlag))
    }
}

enum CodexAutomaticSwitchPolicySelfTest {
    private static func oneShotSelfTest() -> Bool {
        let operation = UUID(uuidString: "56EFD677-35B5-4A33-8A85-46F810B5639B")!
        let arguments = [
            "AiGoodBro", "--pause-switch-profile-id", "fixture-20x",
            "--pause-switch-quota-policy", "reported-week", "--pause-switch-operation-id", operation.uuidString,
        ]
        guard let intent = CodexOneShotSwitchIntent.parse(arguments),
            intent.profileID == "fixture-20x", intent.quotaPolicy == .reportedWeek,
            intent.operationID == operation, !intent.simulateLowQuota,
            CodexOneShotSwitchIntent.parse(arguments + ["--simulate-low-quota"])?.simulateLowQuota == true,
            CodexOneShotSwitchIntent.parse(arguments + ["--simulate-low-quota", "--simulate-low-quota"]) == nil,
            CodexOneShotSwitchIntent.parse(Array(arguments.dropLast())) == nil,
            CodexOneShotSwitchIntent.parse(arguments + ["--pause-switch-profile-id", "other"]) == nil,
            CodexOneShotSwitchIntent.parse(arguments + ["--switch-profile-id", "other"]) == nil
        else { return false }
        let suite = "CodexManagerNext.one-shot-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        guard intent.claim(defaults: defaults), !intent.claim(defaults: defaults) else { return false }

        let now = Date()
        func snapshot(
            plan: String = "pro", weekUsed: Double = 8, fiveUsed: Double? = nil,
            balance: String? = "0.00", unlimited: Bool = false,
            age: TimeInterval = 0
        ) -> UsageSnapshot {
            UsageSnapshot(
                refreshedAt: now.addingTimeInterval(-age),
                account: AccountInfo(
                    type: "chatgpt", planType: plan, emailPresent: true,
                    email: "fixture@example.invalid"), limitId: nil, limitName: nil,
                quotaReadSucceeded: true,
                fiveHourQuota: fiveUsed.map {
                    RateWindow(
                        usedPercent: $0,
                        windowDurationMins: 300, resetsAt: nil)
                },
                sevenDayQuota: RateWindow(
                    usedPercent: weekUsed,
                    windowDurationMins: 10_080, resetsAt: nil), monthlyQuota: nil,
                credits: balance.map {
                    CreditsInfo(
                        hasCredits: true, unlimited: unlimited,
                        balance: $0, resetCredits: nil, resetCreditDetails: nil)
                },
                cloudLifetimeTokens: nil, local: nil, taskBoard: nil, messages: [])
        }
        let policy = CodexOneShotSwitchIntent.QuotaPolicy.reportedWeek
        return policy.accepts(snapshot(), target: true, now: now)
            && CodexOneShotSwitchIntent.targetPlanMatches("prolite", displayedMultiplier: 5)
            && CodexOneShotSwitchIntent.targetPlanMatches(" Pro ", displayedMultiplier: 20)
            && !CodexOneShotSwitchIntent.targetPlanMatches("prolite", displayedMultiplier: 20)
            && !CodexOneShotSwitchIntent.targetPlanMatches("pro", displayedMultiplier: 5)
            && !CodexOneShotSwitchIntent.targetPlanMatches("plus", displayedMultiplier: 5)
            && !CodexOneShotSwitchIntent.targetPlanMatches("prolite", displayedMultiplier: nil)
            && policy.accepts(snapshot(plan: "prolite", weekUsed: 14), target: true, now: now)
            && policy.accepts(snapshot(plan: "prolite", weekUsed: 14), target: false, now: now)
            && !policy.accepts(snapshot(weekUsed: 75), target: true, now: now)
            && !policy.accepts(snapshot(fiveUsed: 100), target: true, now: now)
            && !policy.accepts(snapshot(fiveUsed: 75), target: true, now: now)
            && !policy.accepts(snapshot(fiveUsed: .nan), target: true, now: now)
            && policy.accepts(snapshot(balance: "1.00"), target: true, now: now)
            && policy.accepts(snapshot(balance: nil), target: true, now: now)
            && policy.accepts(snapshot(unlimited: true), target: true, now: now)
            && !policy.accepts(snapshot(age: 46), target: true, now: now)
            && !policy.accepts(snapshot(plan: "plus"), target: true, now: now)
            && !CodexOneShotSwitchIntent.QuotaPolicy.complete.accepts(snapshot(), target: true, now: now)
    }

    private static func settingsSelfTest() -> Bool {
        let suite = "CodexManagerNext.alert-settings-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        guard LowQuotaAlertThresholds.load(from: defaults) == .standard else { return false }
        let custom = LowQuotaAlertThresholds(fiveHour: 20, sevenDay: 15)
        custom.save(to: defaults)
        guard LowQuotaAlertThresholds.load(from: defaults) == custom,
            AutomaticSwitchQuotaState(fiveHourRemaining: 20, sevenDayRemaining: 15)
                .triggeredWindows(thresholds: custom) == [.fiveHour],
            AutomaticSwitchQuotaState(fiveHourRemaining: 20.01, sevenDayRemaining: 14.99)
                .triggeredWindows(thresholds: custom) == [.sevenDay],
            AutomaticSwitchQuotaState(fiveHourRemaining: nil, sevenDayRemaining: .nan)
                .triggeredWindows(thresholds: custom).isEmpty
        else { return false }
        let now = Date(timeIntervalSince1970: 100_000)
        func evaluates(_ thresholds: LowQuotaAlertThresholds, age: TimeInterval = 0) -> Bool {
            CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: .init(fiveHourRemaining: 18, sevenDayRemaining: 80),
                sourceRefreshedAt: now.addingTimeInterval(-age),
                taskSnapshot: .init(connectionMode: .sharedDaemon, records: [:], refreshedAt: now),
                codexInactiveSince: now.addingTimeInterval(-300), legacyManagerRunning: false,
                lastAttemptAt: nil, lastSucceededAt: nil, thresholds: thresholds, now: now
            )
        }
        guard evaluates(custom), !evaluates(.standard), !evaluates(custom, age: 46) else { return false }
        defaults.set(5.5, forKey: LowQuotaAlertThresholds.fiveHourKey)
        defaults.set(100, forKey: LowQuotaAlertThresholds.sevenDayKey)
        guard LowQuotaAlertThresholds.load(from: defaults) == .standard,
            LowQuotaAlertThresholds(fiveHour: -1, sevenDay: 100) == .standard,
            CodexAutomaticSwitchPolicy.minimumCandidateRemainingPercent == 30,
            CodexAutomaticSwitchPolicy.quotaSnapshotMaximumAge == 45,
            CodexAutomaticSwitchPolicy.failureRetryInterval == 3600,
            PausedAutomationFeature.read(from: [:]).isEmpty,
            PausedAutomationFeature.read(from: [PausedAutomationFeature.fiveHour.rawValue: "YES"]).isEmpty,
            PausedAutomationFeature.read(from: [
                PausedAutomationFeature.fiveHour.rawValue: "NO",
                PausedAutomationFeature.sevenDay.rawValue: false,
            ]) == [.fiveHour, .sevenDay]
        else { return false }
        print("Alert settings self-test passed: thresholds, persistence, unchanged safety gates and maintenance overrides")
        return true
    }

    static func run() -> Bool {
        guard oneShotSelfTest(), settingsSelfTest(), CodexDesktopQuotaPause.selfTest(), CodexDesktopQuotaPauseSelfTest.run(),
            CodexQuotaResumeSelfTest.run()
        else { return false }
        let now = Date(timeIntervalSince1970: 100_000)
        let idle = CodexTaskLiveSnapshot(connectionMode: .sharedDaemon, records: [:], refreshedAt: now)
        let active = CodexTaskLiveSnapshot(
            connectionMode: .sharedDaemon,
            records: [
                "task": TaskLiveRecord(
                    threadID: "task",
                    name: nil,
                    state: .running,
                    updatedAt: now,
                    turnID: nil,
                    connectionMode: .sharedDaemon
                )
            ],
            refreshedAt: now
        )
        let low = AutomaticSwitchQuotaState(fiveHourRemaining: 5, sevenDayRemaining: 55)
        let aboveFiveHourThreshold = AutomaticSwitchQuotaState(fiveHourRemaining: 5.01, sevenDayRemaining: 55)
        let lowSevenDay = AutomaticSwitchQuotaState(fiveHourRemaining: 90, sevenDayRemaining: 9)
        let exactSevenDayThreshold = AutomaticSwitchQuotaState(fiveHourRemaining: 90, sevenDayRemaining: 10)
        let safeSince = now.addingTimeInterval(-CodexAutomaticSwitchPolicy.codexInactivePeriod)
        let selected = CodexAutomaticSwitchPolicy.preferredCandidate(
            [
                .init(profileID: "first", quota: .init(fiveHourRemaining: 65, sevenDayRemaining: 80)),
                .init(profileID: "second", quota: .init(fiveHourRemaining: 90, sevenDayRemaining: 45)),
                .init(profileID: "third", quota: .init(fiveHourRemaining: 20, sevenDayRemaining: 99)),
            ], for: [.fiveHour])

        guard
            CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                idle,
                legacyManagerRunning: false,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                active,
                legacyManagerRunning: false,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                .disconnected,
                legacyManagerRunning: false,
                now: now
            ),
            CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: aboveFiveHourThreshold,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: lowSevenDay,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: exactSevenDayThreshold,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: active,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: .disconnected,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: true,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: now.addingTimeInterval(-300),
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now.addingTimeInterval(-46),
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            selected?.profileID == "second",
            CodexAutomaticSwitchPolicy.preferredCandidate(
                [
                    .init(profileID: "missing", quota: .init(fiveHourRemaining: 99, sevenDayRemaining: nil))
                ], for: [.fiveHour, .sevenDay]) == nil
        else {
            print("Codex automatic account switch policy self-test failed")
            return false
        }
        print("Codex automatic account switch policy self-test passed")
        return true
    }
}
