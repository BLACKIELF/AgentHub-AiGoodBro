import Foundation

struct CodexQuotaWindowSnapshot: Codable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?

    init(_ window: RateWindow) {
        usedPercent = window.usedPercent
        windowDurationMins = window.windowDurationMins
        resetsAt = window.resetsAt
    }
}

struct CodexAccountSnapshot: Codable, Equatable {
    let accountType: String?
    let planType: String?
    let email: String?
    let accountID: String?
    let limitId: String?
    let limitName: String?
    let fiveHour: CodexQuotaWindowSnapshot?
    let sevenDay: CodexQuotaWindowSnapshot?
    let monthly: CodexQuotaWindowSnapshot?
    let availableResetCredits: Int?
    let resetCreditExpiries: [Date]?
    let creditBalance: String?
    let creditBalanceUnlimited: Bool?
    let fetchedAt: Date
    let appServerVersion: String?
    let quotaReadSucceeded: Bool?

    init(
        accountType: String?,
        planType: String?,
        email: String?,
        accountID: String? = nil,
        limitId: String?,
        limitName: String?,
        fiveHour: CodexQuotaWindowSnapshot?,
        sevenDay: CodexQuotaWindowSnapshot?,
        monthly: CodexQuotaWindowSnapshot?,
        availableResetCredits: Int? = nil,
        resetCreditExpiries: [Date]? = nil,
        creditBalance: String? = nil,
        creditBalanceUnlimited: Bool? = nil,
        fetchedAt: Date,
        appServerVersion: String?,
        quotaReadSucceeded: Bool? = true
    ) {
        self.accountType = accountType
        self.planType = planType
        self.email = email
        self.accountID = accountID
        self.limitId = limitId
        self.limitName = limitName
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.monthly = monthly
        self.availableResetCredits = availableResetCredits
        self.resetCreditExpiries = resetCreditExpiries
        self.creditBalance = creditBalance
        self.creditBalanceUnlimited = creditBalanceUnlimited
        self.fetchedAt = fetchedAt
        self.appServerVersion = appServerVersion
        self.quotaReadSucceeded = quotaReadSucceeded
    }
}

struct CodexCredentialIdentity: Equatable {
    let email: String
    let accountID: String
}

struct ChromeProfileBinding: Codable, Equatable, Hashable, Identifiable {
    let directoryName: String
    let displayName: String

    var id: String { directoryName }

    init?(directoryName: String, displayName: String) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeDirectoryName(directoryName), !name.isEmpty else { return nil }
        self.directoryName = directoryName
        self.displayName = String(name.prefix(60))
    }

    var isValid: Bool {
        Self.isSafeDirectoryName(directoryName)
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName.count <= 60
    }

    private static func isSafeDirectoryName(_ value: String) -> Bool {
        if value == "Default" { return true }
        guard value.hasPrefix("Profile ") else { return false }
        let suffix = value.dropFirst("Profile ".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}

struct CodexOfficialProfileSnapshot: Codable, Equatable {
    let accountEmail: String?
    let displayName: String?
    let username: String?
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let planType: String?
    let subscriptionActiveUntil: Date?
    let statsAsOf: Date?
    let fetchedAt: Date
}

struct CodexExecutionPreference: Codable, Equatable {
    enum Model: String, Codable, CaseIterable {
        case astra = "gpt-6-astra"
        case sol = "gpt-5.6-sol"
        case terra = "gpt-5.6-terra"
        case luna = "gpt-5.6-luna"
        case gpt55 = "gpt-5.5"
        case gpt52 = "gpt-5.2"

        var displayName: String {
            switch self {
            case .astra: return "GPT-6 Astra"
            case .sol: return "5.6 Sol"
            case .terra: return "5.6 Terra"
            case .luna: return "5.6 Luna"
            case .gpt55: return "GPT-5.5"
            case .gpt52: return "GPT-5.2"
            }
        }

        var supportedReasoningEfforts: [ReasoningEffort] {
            switch self {
            case .astra, .sol, .terra:
                return ReasoningEffort.allCases
            case .luna:
                return [.low, .medium, .high, .xhigh, .max]
            case .gpt55, .gpt52:
                return [.low, .medium, .high, .xhigh]
            }
        }

        var supportsFast: Bool { self != .gpt52 }
    }

    enum ReasoningEffort: String, Codable, CaseIterable {
        case low
        case medium
        case high
        case xhigh
        case max
        case ultra

        var displayName: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .xhigh: return "XHigh"
            case .max: return "Max"
            case .ultra: return "Ultra"
            }
        }

        var localizedTitle: String {
            switch self {
            case .low: return "低"
            case .medium: return "中"
            case .high: return "高"
            case .xhigh: return "特高"
            case .max: return "最高"
            case .ultra: return "Ultra"
            }
        }
    }

    enum ServiceTier: String, Codable, CaseIterable {
        case standard = "default"
        case fast

        var displayName: String {
            switch self {
            case .standard: return "Standard"
            case .fast: return "Fast"
            }
        }
    }

    struct SubagentMode: RawRepresentable, Codable, Hashable, CaseIterable {
        let rawValue: String
        static let standard = Self(rawValue: "standard")
        static let solLuna = Self(rawValue: "sol_luna")
        static let lunaDirect = Self(rawValue: "luna_direct")
        static let allCases: [Self] = [.standard, .solLuna, .lunaDirect]

        init(rawValue: String) { self.rawValue = rawValue }
        init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    struct EffectiveStrategy: Equatable {
        let mainModel: Model
        let mainReasoningEffort: ReasoningEffort
        let subagentModel: Model?
        let subagentReasoningEffort: ReasoningEffort?
        let maximumConcurrentSubagents: Int
    }

    struct CustomPreset: Codable, Equatable {
        var name: String?
        var useSavedModel: Bool
        var model: Model
        var reasoningEffort: ReasoningEffort
        var subagentsEnabled: Bool
        var subagentModel: Model
        var subagentReasoningEffort: ReasoningEffort
    }

    var model: Model
    var reasoningEffort: ReasoningEffort
    var serviceTier: ServiceTier
    var subagentMode: SubagentMode = .standard
    var customPresets: [String: CustomPreset] = [:]

    static let defaultValue = CodexExecutionPreference(
        model: .astra,
        reasoningEffort: .low,
        serviceTier: .standard,
        subagentMode: .standard
    )

    static func defaultPreset(for mode: SubagentMode) -> CustomPreset? {
        switch mode {
        case .standard:
            return CustomPreset(
                name: nil,
                useSavedModel: true,
                model: .astra,
                reasoningEffort: .low,
                subagentsEnabled: false,
                subagentModel: .luna,
                subagentReasoningEffort: .max
            )
        case .solLuna:
            return CustomPreset(
                name: nil,
                useSavedModel: false,
                model: .sol,
                reasoningEffort: .high,
                subagentsEnabled: true,
                subagentModel: .luna,
                subagentReasoningEffort: .max
            )
        case .lunaDirect:
            return CustomPreset(
                name: nil,
                useSavedModel: false,
                model: .luna,
                reasoningEffort: .max,
                subagentsEnabled: false,
                subagentModel: .luna,
                subagentReasoningEffort: .max
            )
        default:
            return nil
        }
    }

    func preset(for mode: SubagentMode) -> CustomPreset? {
        guard let builtIn = Self.defaultPreset(for: mode) else { return nil }
        return customPresets[mode.rawValue] ?? builtIn
    }

    func customName(for mode: SubagentMode) -> String? {
        preset(for: mode)?.name
    }

    func restoringDefault(for mode: SubagentMode) -> CodexExecutionPreference {
        var restored = self
        restored.customPresets.removeValue(forKey: mode.rawValue)
        return restored
    }

    var isValid: Bool { (try? validated()) != nil }
    var savedModelSettingsAreValid: Bool {
        do {
            try validateStoredSettings()
            guard SubagentMode.allCases.contains(subagentMode) else { return true }
            _ = try validated()
            return true
        } catch {
            return false
        }
    }

    var effectiveStrategy: EffectiveStrategy {
        effectiveStrategy(for: subagentMode)
            ?? EffectiveStrategy(
                mainModel: model,
                mainReasoningEffort: reasoningEffort,
                subagentModel: nil,
                subagentReasoningEffort: nil,
                maximumConcurrentSubagents: 0
            )
    }

    func effectiveStrategy(for mode: SubagentMode) -> EffectiveStrategy? {
        guard let preset = preset(for: mode) else {
            return nil
        }
        let mainModel = preset.useSavedModel ? model : preset.model
        let mainEffort = preset.useSavedModel ? reasoningEffort : preset.reasoningEffort
        return EffectiveStrategy(
            mainModel: mainModel,
            mainReasoningEffort: mainEffort,
            subagentModel: preset.subagentsEnabled ? preset.subagentModel : nil,
            subagentReasoningEffort: preset.subagentsEnabled ? preset.subagentReasoningEffort : nil,
            maximumConcurrentSubagents: preset.subagentsEnabled ? 1 : 0
        )
    }

    func validated() throws -> CodexExecutionPreference {
        try validateStoredSettings()
        guard SubagentMode.allCases.contains(subagentMode) else {
            throw CodexExecutionPreferenceError.unsupportedExecutionMode
        }
        let strategy = effectiveStrategy
        guard strategy.mainModel.supportedReasoningEfforts.contains(strategy.mainReasoningEffort) else {
            throw CodexExecutionPreferenceError.unsupportedReasoningEffort(
                model: strategy.mainModel.rawValue,
                reasoningEffort: strategy.mainReasoningEffort.rawValue
            )
        }
        if serviceTier == .fast {
            guard strategy.mainModel.supportsFast else {
                throw CodexExecutionPreferenceError.fastUnavailable(model: strategy.mainModel.rawValue)
            }
            if let subagentModel = strategy.subagentModel, !subagentModel.supportsFast {
                throw CodexExecutionPreferenceError.fastUnavailable(model: subagentModel.rawValue)
            }
        }
        return self
    }

    private func validateStoredSettings() throws {
        guard model.supportedReasoningEfforts.contains(reasoningEffort) else {
            throw CodexExecutionPreferenceError.unsupportedReasoningEffort(
                model: model.rawValue,
                reasoningEffort: reasoningEffort.rawValue
            )
        }
        let supportedKeys = Set(SubagentMode.allCases.map(\.rawValue))
        guard customPresets.count <= supportedKeys.count,
            customPresets.keys.allSatisfy(supportedKeys.contains)
        else {
            throw CodexExecutionPreferenceError.unsupportedCustomPreset
        }
        for preset in customPresets.values {
            if let name = preset.name {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name == trimmed, name.utf8.count <= 64,
                    !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else {
                    throw CodexExecutionPreferenceError.invalidPresetName
                }
            }
            guard preset.model.supportedReasoningEfforts.contains(preset.reasoningEffort) else {
                throw CodexExecutionPreferenceError.unsupportedReasoningEffort(
                    model: preset.model.rawValue,
                    reasoningEffort: preset.reasoningEffort.rawValue
                )
            }
            guard preset.subagentModel.supportedReasoningEfforts.contains(preset.subagentReasoningEffort) else {
                throw CodexExecutionPreferenceError.unsupportedReasoningEffort(
                    model: preset.subagentModel.rawValue,
                    reasoningEffort: preset.subagentReasoningEffort.rawValue
                )
            }
        }
    }
}

extension CodexExecutionPreference {
    private enum CodingKeys: String, CodingKey {
        case model
        case reasoningEffort
        case serviceTier
        case subagentMode
        case customPresets
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decode(Model.self, forKey: .model)
        reasoningEffort = try values.decode(ReasoningEffort.self, forKey: .reasoningEffort)
        serviceTier = try values.decode(ServiceTier.self, forKey: .serviceTier)
        subagentMode = try values.decodeIfPresent(SubagentMode.self, forKey: .subagentMode) ?? .standard
        customPresets = try values.decodeIfPresent([String: CustomPreset].self, forKey: .customPresets) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(model, forKey: .model)
        try values.encode(reasoningEffort, forKey: .reasoningEffort)
        try values.encode(serviceTier, forKey: .serviceTier)
        try values.encode(subagentMode, forKey: .subagentMode)
        if !customPresets.isEmpty {
            try values.encode(customPresets, forKey: .customPresets)
        }
    }
}

/// Shared save boundary: validate every action (including apply-to-all), and
/// only publish a new draft after persistence has acknowledged success.
enum ExecutionPreferenceSave {
    static func save(
        _ preference: CodexExecutionPreference, applyToAll: Bool,
        persist: (CodexExecutionPreference, Bool) -> Result<Void, Error>
    ) -> Result<CodexExecutionPreference, Error> {
        Result {
            let validated = try preference.validated()
            try persist(validated, applyToAll).get()
            return validated
        }
    }
}

enum CodexExecutionPreferenceError: LocalizedError, Equatable {
    case unsupportedExecutionMode
    case unsupportedReasoningEffort(model: String, reasoningEffort: String)
    case fastUnavailable(model: String)
    case unsupportedCustomPreset
    case invalidPresetName
    case systemProfileUnsupported
    case profileMissing

    var errorDescription: String? {
        switch self {
        case .unsupportedExecutionMode:
            return WidgetLanguage.storedOrAutomatic().text("保存的执行档位无法识别，请重新选择后再启动", "Choose a supported execution style before starting this account.")
        case .unsupportedReasoningEffort(let model, let reasoningEffort):
            return WidgetLanguage.storedOrAutomatic().text("模型 \(model) 不支持推理强度 \(reasoningEffort)", "\(model) does not support the \(reasoningEffort) reasoning level.")
        case .fastUnavailable(let model):
            return WidgetLanguage.storedOrAutomatic().text("模型 \(model) 不支持 Fast 模式", "\(model) does not support Fast mode.")
        case .unsupportedCustomPreset:
            return WidgetLanguage.storedOrAutomatic().text("自定义档位包含不支持的槽位", "The custom presets contain an unsupported slot.")
        case .invalidPresetName:
            return WidgetLanguage.storedOrAutomatic().text(
                "档位名称需为 1–64 个 UTF-8 字节，且不能含首尾空白或控制字符", "Preset names must be 1–64 UTF-8 bytes with no surrounding whitespace or control characters.")
        case .systemProfileUnsupported:
            return WidgetLanguage.storedOrAutomatic().text("系统账号不保存执行偏好", "Execution preferences cannot be saved for the system account.")
        case .profileMissing:
            return WidgetLanguage.storedOrAutomatic().text("账号已不存在，请关闭设置后重新选择账号", "This profile no longer exists. Close settings and select a profile again.")
        }
    }
}

struct CodexWarmUpAttempt: Codable, Equatable {
    let at: Date
    let succeeded: Bool
    let failureReason: String?
    var attemptID: String? = nil
    var source: String? = nil
}

/// Saved before sending; an interrupted process must not erase an ambiguous request.
struct CodexWarmUpRequest: Codable, Equatable {
    let id: String
    let accountID: String
    let startedAt: Date
    let limitID: String?
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
    let source: String
}

struct CodexProfile: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var remark: String? = nil
    let codexHomePath: String
    let isSystemProfile: Bool
    let createdAt: Date
    var lastSnapshot: CodexAccountSnapshot?
    var officialResetHistory: OfficialResetHistory? = nil
    var officialProfile: CodexOfficialProfileSnapshot? = nil
    var lastMembershipRefreshAt: Date? = nil
    var lastMembershipRefreshSucceeded: Bool? = nil
    var lastWarmUpAt: Date? = nil
    var lastWarmUpSucceeded: Bool? = nil
    var lastWarmUpFailureReason: String? = nil
    var warmUpHistory: [CodexWarmUpAttempt]? = nil
    var warmUpRequest: CodexWarmUpRequest? = nil
    var lastQuotaReadFailureAt: Date? = nil
    var lastQuotaReadFailureReason: String? = nil
    var chromeProfile: ChromeProfileBinding? = nil
    var automaticSwitchParticipation: Bool? = nil
    var prioritizeDispatch: Bool? = nil
    var proTierMultiplier: Int? = nil
    var executionPreference: CodexExecutionPreference? = nil
    var dispatchParticipationWindow: DispatchParticipationWindow? = nil

    var participatesInAutomaticSwitch: Bool {
        automaticSwitchParticipation != false
    }

    var isDispatchPriorityEnabled: Bool {
        prioritizeDispatch == true
    }

    var displayedProTierMultiplier: Int? {
        guard let proTierMultiplier, proTierMultiplier == 5 || proTierMultiplier == 20 else { return nil }
        return proTierMultiplier
    }

    var effectiveExecutionPreference: CodexExecutionPreference {
        executionPreference ?? .defaultValue
    }

    func validatedExecutionPreference() throws -> CodexExecutionPreference {
        guard !isSystemProfile else {
            throw CodexExecutionPreferenceError.systemProfileUnsupported
        }
        return try effectiveExecutionPreference.validated()
    }

    var codexHomeURL: URL {
        URL(fileURLWithPath: codexHomePath, isDirectory: true)
    }

    func matchesRecordedAccount(email: String?) -> Bool {
        guard let expected = Self.normalizedEmail(lastSnapshot?.email) else { return true }
        return Self.normalizedEmail(email) == expected
    }

    func matchesRecordedCredential(_ identity: CodexCredentialIdentity?) -> Bool {
        guard let identity, !identity.email.isEmpty, !identity.accountID.isEmpty,
            matchesRecordedAccount(email: identity.email)
        else { return false }
        guard let expectedAccountID = lastSnapshot?.accountID else { return true }
        return identity.accountID == expectedAccountID
    }

    var recordedAccountKey: String {
        Self.normalizedEmail(lastSnapshot?.email) ?? "profile:\(id)"
    }

    static func groupsByRecordedAccount(_ profiles: [CodexProfile]) -> [[CodexProfile]] {
        Array(Dictionary(grouping: profiles, by: \.recordedAccountKey).values)
    }

    static func participatesInAutomaticSwitch(_ profileID: String, among profiles: [CodexProfile]) -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return false }
        return
            profiles
            .filter { $0.recordedAccountKey == profile.recordedAccountKey }
            .allSatisfy(\.participatesInAutomaticSwitch)
    }

    static func prioritizesDispatch(_ profileID: String, among profiles: [CodexProfile]) -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return false }
        return
            profiles
            .filter { $0.recordedAccountKey == profile.recordedAccountKey }
            .allSatisfy(\.isDispatchPriorityEnabled)
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}

enum SevenDayResetReminder {
    static let threshold: TimeInterval = 72 * 60 * 60

    static func remainingDays(resetsAt: Date?, now: Date = Date()) -> Int? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= threshold else { return nil }
        return max(1, Int(ceil(remaining / (24 * 60 * 60))))
    }

    static func message(resetsAt: Date?, now: Date = Date(), language: WidgetLanguage = .zh) -> String? {
        remainingDays(resetsAt: resetsAt, now: now).map {
            language.text("7 天窗口 \($0) 天后重置", "Weekly window resets in \($0) \($0 == 1 ? "day" : "days")")
        }
    }
}

struct CodexWarmUpSelection: Equatable {
    var fiveHour: Bool
    var sevenDay: Bool

    var isEnabled: Bool { fiveHour || sevenDay }

    static let none = CodexWarmUpSelection(fiveHour: false, sevenDay: false)
    static let all = CodexWarmUpSelection(fiveHour: true, sevenDay: true)

    private static let fiveHourKey = "CodexManagerNext.automaticWarmUp.fiveHour"
    private static let sevenDayKey = "CodexManagerNext.automaticWarmUp.sevenDay"
    private static let legacyKey = "CodexManagerNext.automaticWarmUp"

    static func load(
        from defaults: UserDefaults = .standard,
        hasExistingInstallation _: Bool = false,
        persistentDomainName: String? = Bundle.main.bundleIdentifier
    ) -> CodexWarmUpSelection {
        // Registration/global/argument domains are not durable user consent.
        let persisted = persistentDomainName.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        func bool(_ value: Any?) -> Bool {
            if let number = value as? NSNumber { return number.boolValue }
            return (value as? NSString)?.boolValue ?? false
        }
        let hasNewKeys = persisted[fiveHourKey] != nil || persisted[sevenDayKey] != nil
        var selection = CodexWarmUpSelection(
            fiveHour: bool(persisted[fiveHourKey]),
            sevenDay: bool(persisted[hasNewKeys ? sevenDayKey : legacyKey]))
        if !hasNewKeys, persistentDomainName != nil {
            defaults.set(selection.fiveHour, forKey: fiveHourKey)
            defaults.set(selection.sevenDay, forKey: sevenDayKey)
            defaults.removeObject(forKey: legacyKey)
        }
        // Apply temporary launch controls only AFTER persisting the real migration.
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if let value = arguments[fiveHourKey] { selection.fiveHour = bool(value) }
        if let value = arguments[sevenDayKey] { selection.sevenDay = bool(value) } else if !hasNewKeys, let value = arguments[legacyKey] { selection.sevenDay = bool(value) }
        return selection
    }

    func save(to defaults: UserDefaults = .standard) {
        let launchOverrides = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if launchOverrides[Self.fiveHourKey] == nil { defaults.set(fiveHour, forKey: Self.fiveHourKey) }
        if launchOverrides[Self.sevenDayKey] == nil && launchOverrides[Self.legacyKey] == nil { defaults.set(sevenDay, forKey: Self.sevenDayKey) }
        if launchOverrides[Self.legacyKey] == nil { defaults.removeObject(forKey: Self.legacyKey) }
    }
}

enum CodexWarmUpWindowKind: String, Equatable {
    case fiveHour
    case sevenDay
}

/// A successful request acknowledges the reset event it actually handled even
/// when quota usage still rounds to zero. A later reset keeps its own ticket.
struct CodexWarmUpResetTracker {
    typealias Ticket = [CodexWarmUpWindowKind: UUID]
    private var events: [String: Ticket] = [:]

    func ticket(for account: String) -> Ticket { events[account] ?? [:] }
    func kinds(for account: String) -> Set<CodexWarmUpWindowKind> { Set(ticket(for: account).keys) }

    mutating func note(_ kinds: Set<CodexWarmUpWindowKind>, for account: String) {
        for kind in kinds { events[account, default: [:]][kind] = UUID() }
    }

    mutating func acknowledge(_ handled: Ticket, for account: String) {
        for (kind, id) in handled where events[account]?[kind] == id {
            events[account]?.removeValue(forKey: kind)
        }
        if events[account]?.isEmpty == true { events.removeValue(forKey: account) }
    }

    mutating func removeAll() { events.removeAll() }
}

enum CodexWarmUpPolicy {
    static let resetGrace: TimeInterval = 8
    static let fiveHourSuccessInterval: TimeInterval = 5 * 60 * 60
    static let sevenDaySuccessInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maximumQuotaAge: TimeInterval = 15 * 60
    static let idleUsedPercentThreshold = 0.5
    static let unexpectedResetDrop = 8.0
    static let minimumWeeklyRemaining = 0.0
    static let resetStartTolerance: TimeInterval = 10 * 60

    static func maintenanceRefreshInterval(warmUpEnabled: Bool, quotaNotificationsEnabled: Bool = false) -> TimeInterval {
        quotaNotificationsEnabled ? 60 : (warmUpEnabled ? 10 * 60 : 30 * 60)
    }

    static func maintenanceTimerNeedsReplacement(
        currentInterval: TimeInterval?,
        requestedInterval: TimeInterval
    ) -> Bool {
        currentInterval != requestedInterval
    }

    /// Reading a reset is independent of permission to send a warm-up request.
    /// A failed read keeps the deadline pending, with bounded retry frequency.
    static func nextQuotaResetRefreshDate(
        for profile: CodexProfile,
        lastAttemptAt: Date? = nil,
        now: Date = Date()
    ) -> Date? {
        guard let snapshot = profile.lastSnapshot else { return nil }
        return [snapshot.fiveHour, snapshot.sevenDay, snapshot.monthly].compactMap { window -> Date? in
            guard let window, let resetsAt = window.resetsAt else { return nil }
            let deadline = resetsAt.addingTimeInterval(resetGrace)
            guard snapshot.fetchedAt < deadline || window.usedPercent >= 100 else { return nil }
            let observedAt = max(snapshot.fetchedAt, profile.lastQuotaReadFailureAt ?? .distantPast, lastAttemptAt ?? .distantPast)
            if observedAt >= deadline {
                return max(now, observedAt.addingTimeInterval(60))
            }
            return max(now, deadline)
        }.min()
    }

    static func effectiveSelection(
        _ selection: CodexWarmUpSelection,
        participatesInAutomaticSwitch _: Bool,
        unexpected _: Set<CodexWarmUpWindowKind> = []
    ) -> CodexWarmUpSelection {
        // Dispatch participation controls task assignment, not quota-window maintenance.
        selection
    }

    static func isWindowIdle(_ window: CodexQuotaWindowSnapshot?, now: Date = Date()) -> Bool {
        guard let window else { return true }
        // A cold account can report a sliding future reset with no usage.
        // Its own successful warm-up interval must remain the scheduling anchor.
        return window.usedPercent < idleUsedPercentThreshold
    }

    static func didResetUnexpectedly(
        previous: CodexQuotaWindowSnapshot?,
        current: CodexQuotaWindowSnapshot?,
        now: Date = Date()
    ) -> Bool {
        guard let previous, let current, !isWindowIdle(previous, now: now) else { return false }
        if isWindowIdle(current, now: now) { return true }
        if current.usedPercent + unexpectedResetDrop <= previous.usedPercent {
            return true
        }
        if let previousReset = previous.resetsAt,
            let currentReset = current.resetsAt,
            abs(currentReset.timeIntervalSince(previousReset)) > 120,
            current.usedPercent + 3 <= previous.usedPercent
        {
            return true
        }
        return false
    }

    /// 重置卡口径：区分「官方提前/人工重置」与「窗口自然滚动」。
    /// 同一窗口内额度回落超过阈值计一次（官方随机恢复额度）；
    /// 出现新窗口时，新窗口起点（resetsAt - 时长）明显偏离原窗口终点计一次。
    static func didConsumeReset(
        previous: CodexQuotaWindowSnapshot?,
        current: CodexQuotaWindowSnapshot?,
        now: Date = Date()
    ) -> Bool {
        guard let previous, previous.usedPercent >= 1, let current else { return false }
        guard let previousReset = previous.resetsAt, let currentReset = current.resetsAt else {
            return false
        }
        if abs(currentReset.timeIntervalSince(previousReset)) <= 120 {
            return current.usedPercent + unexpectedResetDrop <= previous.usedPercent
        }
        guard let duration = current.windowDurationMins.map({ TimeInterval($0) * 60 }), duration > 0 else {
            return false
        }
        let impliedStart = currentReset.addingTimeInterval(-duration)
        return abs(impliedStart.timeIntervalSince(previousReset)) > resetStartTolerance
    }

    static func shouldSkipFiveHourToProtectWeekly(_ profile: CodexProfile, now: Date = Date()) -> Bool {
        guard let weekly = profile.lastSnapshot?.sevenDay, !isWindowIdle(weekly, now: now) else {
            return false
        }
        return 100 - weekly.usedPercent <= minimumWeeklyRemaining
    }

    /// A balance never grants permission to fall back from subscription quota to paid credits.
    static func hasExhaustedSubscriptionWindow(_ profile: CodexProfile) -> Bool {
        guard let snapshot = profile.lastSnapshot else { return false }
        return [snapshot.fiveHour, snapshot.sevenDay, snapshot.monthly]
            .compactMap { $0 }.contains { $0.usedPercent >= 100 }
    }

    static func canSendWarmUpRequest(_ profile: CodexProfile, now: Date = Date()) -> Bool {
        guard hasFreshQuotaEvidence(profile, now: now), let snapshot = profile.lastSnapshot,
            snapshot.fiveHour != nil || snapshot.sevenDay != nil || snapshot.monthly != nil
        else { return false }
        return !hasExhaustedSubscriptionWindow(profile)
    }

    /// Re-check mutable lifecycle state after an asynchronous availability lookup.
    /// In particular, a late result must not start a request after the service stopped.
    static func canContinueAfterAsyncCheck(
        serviceIsRunning: Bool,
        requestIsCurrent: Bool,
        warmUpIsEnabled: Bool,
        accountOperationIsIdle: Bool
    ) -> Bool {
        serviceIsRunning && requestIsCurrent && warmUpIsEnabled && accountOperationIsIdle
    }

    static func nextEligibleDate(
        for profile: CodexProfile,
        selection: CodexWarmUpSelection,
        unexpected: Set<CodexWarmUpWindowKind> = [],
        now: Date = Date()
    ) -> Date? {
        guard selection.isEnabled, !hasExhaustedSubscriptionWindow(profile) else { return nil }
        guard
            let email = profile.lastSnapshot?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
            !email.isEmpty
        else { return nil }
        guard !hasUnresolvedFailure(profile, selection: selection, now: now) else { return nil }

        var dates: [Date] = []
        if selection.fiveHour, !shouldSkipFiveHourToProtectWeekly(profile, now: now) {
            if let date = nextDate(
                for: profile.lastSnapshot?.fiveHour,
                lastWarmUpAt: profile.lastWarmUpAt,
                lastWarmUpSucceeded: profile.lastWarmUpSucceeded,
                successfulInterval: fiveHourSuccessInterval,
                unexpected: unexpected.contains(.fiveHour),
                now: now
            ) {
                dates.append(date)
            }
        }
        if selection.sevenDay {
            if let date = nextDate(
                for: profile.lastSnapshot?.sevenDay,
                lastWarmUpAt: profile.lastWarmUpAt,
                lastWarmUpSucceeded: profile.lastWarmUpSucceeded,
                successfulInterval: sevenDaySuccessInterval,
                unexpected: unexpected.contains(.sevenDay),
                now: now
            ) {
                dates.append(date)
            }
        }
        return dates.min()
    }

    static func hasUnresolvedFailure(
        _ profile: CodexProfile,
        selection: CodexWarmUpSelection,
        now: Date = Date()
    ) -> Bool {
        guard selection.isEnabled, profile.lastWarmUpSucceeded == false, profile.lastWarmUpAt != nil else { return false }
        // Legacy failures have no trustworthy generation baseline: manual recovery only.
        guard selection.isEnabled, let request = profile.warmUpRequest,
            let snapshot = profile.lastSnapshot,
            snapshot.accountID == request.accountID, snapshot.limitId == request.limitID,
            hasFreshQuotaEvidence(profile, now: now)
        else { return true }
        func advanced(_ window: CodexQuotaWindowSnapshot?, _ oldReset: Date?, _ duration: TimeInterval) -> Bool {
            guard let window, let reset = window.resetsAt, let oldReset,
                oldReset > request.startedAt, now >= oldReset.addingTimeInterval(resetGrace),
                snapshot.fetchedAt >= oldReset.addingTimeInterval(resetGrace), reset > oldReset,
                window.windowDurationMins.map({ TimeInterval($0) * 60 == duration }) == true
            else { return false }
            return reset.addingTimeInterval(-duration) >= oldReset.addingTimeInterval(-60)
        }
        // Every selected window must advance; percentage changes/reset tickets alone
        // cannot prove that an ambiguous request did not already consume this window.
        return (selection.fiveHour && !advanced(snapshot.fiveHour, request.fiveHourResetAt, fiveHourSuccessInterval))
            || (selection.sevenDay && !advanced(snapshot.sevenDay, request.sevenDayResetAt, sevenDaySuccessInterval))
    }

    static func isDue(
        _ profile: CodexProfile,
        selection: CodexWarmUpSelection,
        unexpected: Set<CodexWarmUpWindowKind> = [],
        now: Date = Date()
    ) -> Bool {
        guard canSendWarmUpRequest(profile, now: now) else { return false }
        return nextEligibleDate(for: profile, selection: selection, unexpected: unexpected, now: now)
            .map { $0 <= now } ?? false
    }

    static func hasFreshQuotaEvidence(_ profile: CodexProfile, now: Date = Date()) -> Bool {
        guard
            let snapshot = profile.lastSnapshot,
            let email = snapshot.email?.trimmingCharacters(in: .whitespacesAndNewlines),
            !email.isEmpty,
            snapshot.quotaReadSucceeded == true,
            (profile.lastQuotaReadFailureAt ?? .distantPast) < snapshot.fetchedAt
        else { return false }
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        return age >= -60 && age <= maximumQuotaAge
    }

    static func nextScheduledResetDate(
        for profile: CodexProfile,
        selection: CodexWarmUpSelection,
        now: Date = Date()
    ) -> Date? {
        guard selection.isEnabled,
            profile.lastSnapshot?.email?.isEmpty == false
        else { return nil }

        var dates: [Date] = []
        if selection.fiveHour {
            if shouldSkipFiveHourToProtectWeekly(profile, now: now) {
                if let resetsAt = profile.lastSnapshot?.sevenDay?.resetsAt, resetsAt > now {
                    dates.append(resetsAt.addingTimeInterval(resetGrace))
                }
            } else if let resetsAt = profile.lastSnapshot?.fiveHour?.resetsAt, resetsAt > now {
                dates.append(resetsAt.addingTimeInterval(resetGrace))
            }
        }
        if selection.sevenDay,
            let resetsAt = profile.lastSnapshot?.sevenDay?.resetsAt,
            resetsAt > now
        {
            dates.append(resetsAt.addingTimeInterval(resetGrace))
        }
        return dates.min()
    }

    private static func nextDate(
        for window: CodexQuotaWindowSnapshot?,
        lastWarmUpAt: Date?,
        lastWarmUpSucceeded: Bool?,
        successfulInterval: TimeInterval,
        unexpected: Bool,
        now: Date
    ) -> Date? {
        // A different reported window is not evidence that this selected window
        // is idle. Missing selected-window data stays fail closed.
        guard let window else { return nil }
        if unexpected {
            if lastWarmUpSucceeded == true, let lastWarmUpAt {
                return max(now, lastWarmUpAt.addingTimeInterval(successfulInterval + resetGrace))
            }
            return now
        }
        if isWindowIdle(window, now: now) {
            if lastWarmUpSucceeded == true, let lastWarmUpAt {
                let retryAt = lastWarmUpAt.addingTimeInterval(successfulInterval + resetGrace)
                if retryAt > now { return retryAt }
            }
            return now
        }
        if let resetsAt = window.resetsAt, resetsAt > now {
            return resetsAt.addingTimeInterval(resetGrace)
        }
        return nil
    }
}

enum CodexOfficialProfileReader {
    private static let profileURL = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!

    static func needsMembershipRefresh(_ profile: CodexProfile, systemAccountKey: String?, now: Date = Date()) -> Bool {
        guard !profile.isSystemProfile,
            let systemAccountKey, profile.recordedAccountKey != systemAccountKey,
            let activeUntil = profile.officialProfile?.subscriptionActiveUntil, activeUntil <= now,
            let snapshot = profile.lastSnapshot, snapshot.quotaReadSucceeded == true,
            (0...5 * 60).contains(now.timeIntervalSince(snapshot.fetchedAt)),
            (profile.lastQuotaReadFailureAt ?? .distantPast) <= snapshot.fetchedAt
        else { return false }
        guard let attemptedAt = profile.lastMembershipRefreshAt else { return true }
        let retryInterval: TimeInterval = profile.lastMembershipRefreshSucceeded == true ? 6 * 60 * 60 : 15 * 60
        return now.timeIntervalSince(attemptedAt) >= retryInterval
    }

    static func load(codexHomeURL: URL, now: Date = Date()) -> CodexOfficialProfileSnapshot? {
        let authURL = codexHomeURL.appendingPathComponent("auth.json")
        guard let authData = try? Data(contentsOf: authURL),
            let auth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
            let tokens = auth["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String,
            !accessToken.isEmpty,
            let identity = credentialIdentity(fromAuthData: authData)
        else { return nil }

        let idToken = tokens["id_token"] as? String
        let subscription = subscription(fromIDToken: idToken)
        var request = URLRequest(url: profileURL, timeoutInterval: 12)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(identity.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode: Int?
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, _ in
            responseData = data
            statusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 13) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            return nil
        }
        session.finishTasksAndInvalidate()

        guard let responseData,
            let statusCode,
            (200..<300).contains(statusCode),
            let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let profile = response["profile"] as? [String: Any],
            let stats = response["stats"] as? [String: Any]
        else { return nil }

        let metadata = response["metadata"] as? [String: Any]
        return CodexOfficialProfileSnapshot(
            accountEmail: email(fromIDToken: idToken),
            displayName: nonEmpty(profile["display_name"] as? String),
            username: nonEmpty(profile["username"] as? String),
            lifetimeTokens: (stats["lifetime_tokens"] as? NSNumber)?.int64Value,
            peakDailyTokens: (stats["peak_daily_tokens"] as? NSNumber)?.int64Value,
            planType: subscription?.planType,
            subscriptionActiveUntil: subscription?.activeUntil,
            statsAsOf: parseDate(metadata?["stats_as_of"] as? String),
            fetchedAt: now
        )
    }

    static func subscription(fromIDToken idToken: String?) -> (planType: String?, activeUntil: Date?)? {
        guard let claims = claims(fromToken: idToken),
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return (
            nonEmpty(auth["chatgpt_plan_type"] as? String),
            parseDate(auth["chatgpt_subscription_active_until"] as? String)
        )
    }

    static func email(fromIDToken idToken: String?) -> String? {
        nonEmpty(claims(fromToken: idToken)?["email"] as? String)
    }

    static func credentialIdentity(codexHomeURL: URL) -> CodexCredentialIdentity? {
        guard let data = try? Data(contentsOf: codexHomeURL.appendingPathComponent("auth.json")) else {
            return nil
        }
        return credentialIdentity(fromAuthData: data)
    }

    static func credentialIdentity(fromAuthData data: Data) -> CodexCredentialIdentity? {
        guard let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = auth["tokens"] as? [String: Any],
            let accessToken = nonEmpty(tokens["access_token"] as? String),
            let idToken = nonEmpty(tokens["id_token"] as? String),
            let idClaims = claims(fromToken: idToken),
            let email = normalizedEmail(idClaims["email"] as? String)
        else { return nil }

        let accessClaims = claims(fromToken: accessToken)
        let storedAccountID = nonEmpty(tokens["account_id"] as? String)
        let idTokenAccountID = accountID(in: idClaims)
        let accessTokenAccountID = accessClaims.flatMap(accountID(in:))
        guard let accountID = storedAccountID ?? idTokenAccountID ?? accessTokenAccountID,
            [storedAccountID, idTokenAccountID, accessTokenAccountID]
                .compactMap({ $0 })
                .allSatisfy({ $0 == accountID })
        else { return nil }
        if let accessEmail = normalizedEmail(accessClaims?["email"] as? String), accessEmail != email {
            return nil
        }
        return CodexCredentialIdentity(email: email, accountID: accountID)
    }

    private static func claims(fromToken token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func accountID(in claims: [String: Any]) -> String? {
        let namespaced = claims["https://api.openai.com/auth"] as? [String: Any]
        return nonEmpty(namespaced?["chatgpt_account_id"] as? String)
            ?? nonEmpty(namespaced?["account_id"] as? String)
            ?? nonEmpty(claims["chatgpt_account_id"] as? String)
            ?? nonEmpty(claims["account_id"] as? String)
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        nonEmpty(value)?.lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if value.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: value)
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }
}

struct CodexAccountResetCounter: Codable, Equatable {
    var automaticCount: Int = 0
    var manualOffset: Int = 0
    var lastCountedResetAt: Date? = nil
    var cardExpiresAt: Date? = nil

    var total: Int { automaticCount + manualOffset }
}

final class CodexProfileStore {
    private struct State: Codable, Equatable {
        let schemaVersion: Int
        var profiles: [CodexProfile]
        var selectedMonitorProfileID: String
        var selectedLaunchProfileID: String
        var resetCounters: [String: CodexAccountResetCounter]? = nil
        var resetBackfillCheckedAt: Date? = nil
    }

    private let fileManager: FileManager
    private let stateURL: URL
    private let managedRootURL: URL
    private let persistenceBlocked: Bool
    let hadSavedStateOnLoad: Bool
    private var hasObservedPersistedState: Bool
    private var state: State

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        managedRootURL = home.appendingPathComponent(".codex-account-manager-next/profiles", isDirectory: true)
        let support =
            applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        stateURL =
            support
            .appendingPathComponent(DispatchParticipationPaths.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(DispatchParticipationPaths.snapshotFileName)
        hadSavedStateOnLoad = fileManager.fileExists(atPath: stateURL.path)
        hasObservedPersistedState = hadSavedStateOnLoad

        let systemProfile = CodexProfile(
            id: "system",
            name: "当前 Codex",
            codexHomePath: home.appendingPathComponent(".codex", isDirectory: true).path,
            isSystemProfile: true,
            createdAt: Date(),
            lastSnapshot: nil
        )
        let fallback = State(
            schemaVersion: 1,
            profiles: [systemProfile],
            selectedMonitorProfileID: systemProfile.id,
            selectedLaunchProfileID: systemProfile.id
        )
        if !hadSavedStateOnLoad {
            state = fallback
            persistenceBlocked = false
        } else if let data = try? Data(contentsOf: stateURL),
            let decoded = try? JSONDecoder().decode(State.self, from: data),
            Self.isValid(decoded, systemPath: systemProfile.codexHomePath, managedRoot: managedRootURL)
        {
            state = decoded
            persistenceBlocked = false
        } else {
            state = fallback
            persistenceBlocked = true
        }
        guard !persistenceBlocked else { return }
        try? applyStartupBackfill()
    }

    /// 一次性回填：用账号组内存量快照还原部署计数功能之前的历史重置。
    /// 已产生过计数（含自动检测）的账号组跳过，避免重复累计。
    func backfillResetCountersFromHistory() {
        try? mutateState {
            Self.backfillResetCountersFromHistory(in: &self.state)
        }
    }

    @discardableResult
    private static func backfillResetCountersFromHistory(in state: inout State) -> Bool {
        var additions: [(key: String, count: Int, lastCountedAt: Date, newestWindowEnd: Date?)] = []
        for group in CodexProfile.groupsByRecordedAccount(state.profiles) {
            let windows =
                group
                .compactMap { profile -> (fetchedAt: Date, window: CodexQuotaWindowSnapshot)? in
                    guard let snapshot = profile.lastSnapshot else { return nil }
                    guard let window = snapshot.sevenDay else { return nil }
                    return (snapshot.fetchedAt, window)
                }
                .sorted { $0.fetchedAt < $1.fetchedAt }
            guard windows.count >= 2,
                let key = group.first?.recordedAccountKey,
                state.resetCounters?[key]?.lastCountedResetAt == nil
            else { continue }
            var count = 0
            for (previous, current) in zip(windows, windows.dropFirst()) {
                if CodexWarmUpPolicy.didConsumeReset(
                    previous: previous.window,
                    current: current.window,
                    now: current.fetchedAt
                ) {
                    count += 1
                }
            }
            additions.append(
                (
                    key,
                    count,
                    windows.map(\.fetchedAt).max() ?? Date(),
                    windows.compactMap { $0.window.resetsAt }.max()
                ))
        }
        guard !additions.isEmpty else { return false }
        var counters = state.resetCounters ?? [:]
        var changed = false
        for addition in additions where addition.count > 0 {
            var counter = counters[addition.key] ?? CodexAccountResetCounter()
            counter.automaticCount += addition.count
            counter.lastCountedResetAt = addition.lastCountedAt
            if let newestWindowEnd = addition.newestWindowEnd {
                counter.cardExpiresAt = newestWindowEnd
            }
            counters[addition.key] = counter
            changed = true
        }
        guard changed else { return false }
        state.resetCounters = counters
        return true
    }

    var profiles: [CodexProfile] { state.profiles }
    var selectedMonitorProfileID: String { state.selectedMonitorProfileID }
    var selectedLaunchProfileID: String { state.selectedLaunchProfileID }

    var selectedMonitorProfile: CodexProfile {
        state.profiles.first { $0.id == state.selectedMonitorProfileID } ?? state.profiles[0]
    }

    func addManagedProfile(
        copyingRemarkFrom sourceProfileID: String? = nil,
        chromeProfile: ChromeProfileBinding? = nil
    ) throws -> CodexProfile {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let home = managedRootURL.appendingPathComponent(id, isDirectory: true)
        var createdHome = false
        var added: CodexProfile?
        do {
            try mutateState {
                guard !self.fileManager.fileExists(atPath: home.path) else { throw CocoaError(.fileWriteFileExists) }
                try self.fileManager.createDirectory(
                    at: home,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                createdHome = true
                try self.fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
                let profile = CodexProfile(
                    id: id,
                    name: "账号 \(self.state.profiles.count + 1)",
                    remark: sourceProfileID.flatMap { sourceID in
                        self.state.profiles.first(where: { $0.id == sourceID })?.remark
                    },
                    codexHomePath: home.path,
                    isSystemProfile: false,
                    createdAt: Date(),
                    lastSnapshot: nil,
                    chromeProfile: chromeProfile
                )
                if let sourceProfileID,
                    let sourceIndex = self.state.profiles.firstIndex(where: { $0.id == sourceProfileID })
                {
                    self.state.profiles.insert(profile, at: sourceIndex)
                } else {
                    self.state.profiles.append(profile)
                }
                added = profile
                return true
            }
        } catch {
            if createdHome { discardNewHomeAfterFailedMutation(home, error: error) }
            throw error
        }
        guard let added else { throw CocoaError(.fileWriteUnknown) }
        return added
    }

    @discardableResult
    func preserveSystemLogin(
        expectedEmail: String? = nil,
        expectedAccountID: String? = nil
    ) throws -> CodexProfile {
        CodexCredentialAccessGate.lock.lock()
        defer { CodexCredentialAccessGate.lock.unlock() }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let home = managedRootURL.appendingPathComponent(id, isDirectory: true)
        var createdHome = false
        var preservationSource: (home: URL, data: Data)?
        var preservedProfile: CodexProfile?
        do {
            try mutateState {
                guard let systemIndex = self.state.profiles.firstIndex(where: \.isSystemProfile) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let system = self.state.profiles[systemIndex]
                guard system.lastSnapshot?.email?.isEmpty == false else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let sourceAuth = system.codexHomeURL.appendingPathComponent("auth.json")
                let authData: Data
                do {
                    authData = try Data(contentsOf: sourceAuth)
                } catch {
                    throw NSError(
                        domain: "CodexAccountManagerNext.ProfileStore",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text("无法安全读取当前 Codex 凭据", "Could not safely read the current Codex credentials.")]
                    )
                }
                let boundEmail = (expectedEmail ?? system.lastSnapshot?.email)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: authData)
                let boundAccountID = expectedAccountID ?? system.lastSnapshot?.accountID ?? identity?.accountID
                guard let boundEmail,
                    !boundEmail.isEmpty,
                    let boundAccountID,
                    identity?.email == boundEmail,
                    identity?.accountID == boundAccountID
                else {
                    throw NSError(
                        domain: "CodexAccountManagerNext.ProfileStore",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text(
                                "当前 Codex 凭据身份与系统账号记录不一致", "The current Codex identity does not match the saved system account.")
                        ]
                    )
                }
                if let existing = self.state.profiles.first(where: {
                    !$0.isSystemProfile
                        && $0.recordedAccountKey == system.recordedAccountKey
                        && $0.lastSnapshot?.accountID == boundAccountID
                }) {
                    try self.writeAuth(authData, from: system.codexHomeURL, to: existing.codexHomeURL)
                    preservedProfile = existing
                    return false
                }
                try self.fileManager.createDirectory(
                    at: home,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                createdHome = true
                try self.fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
                let preserved = CodexProfile(
                    id: id,
                    name: system.name,
                    remark: system.remark,
                    codexHomePath: home.path,
                    isSystemProfile: false,
                    createdAt: Date(),
                    lastSnapshot: system.lastSnapshot.map {
                        Self.snapshotByReplacingAccountID($0, accountID: boundAccountID)
                    },
                    officialProfile: system.officialProfile,
                    lastWarmUpAt: system.lastWarmUpAt,
                    lastWarmUpSucceeded: system.lastWarmUpSucceeded,
                    lastWarmUpFailureReason: system.lastWarmUpFailureReason,
                    warmUpHistory: system.warmUpHistory,
                    warmUpRequest: system.warmUpRequest,
                    chromeProfile: system.chromeProfile,
                    automaticSwitchParticipation: system.automaticSwitchParticipation,
                    prioritizeDispatch: system.prioritizeDispatch,
                    proTierMultiplier: system.proTierMultiplier,
                    executionPreference: system.executionPreference,
                    dispatchParticipationWindow: system.dispatchParticipationWindow
                )
                preservationSource = (system.codexHomeURL, authData)
                try self.writeAuth(authData, from: system.codexHomeURL, to: home)
                self.state.profiles.insert(preserved, at: systemIndex + 1)
                preservedProfile = preserved
                return true
            }
        } catch {
            if createdHome, let source = preservationSource {
                // A failed profile-state commit must not delete credentials another writer advanced.
                CodexCredentialTransaction.withGates([source.home, home]) {
                    guard let sourceNow = try? CodexCredentialTransaction.read(source.home.appendingPathComponent("auth.json")),
                        let targetNow = try? CodexCredentialTransaction.read(home.appendingPathComponent("auth.json")),
                        sourceNow == source.data, targetNow == source.data,
                        (try? fileManager.contentsOfDirectory(atPath: home.path)) == ["auth.json"]
                    else { return }
                    discardNewHomeAfterFailedMutation(home, error: error)
                }
            }
            throw error
        }
        guard let preservedProfile else { throw CocoaError(.fileWriteUnknown) }
        return preservedProfile
    }

    private func discardNewHomeAfterFailedMutation(_ home: URL, error: Error) {
        // An incomplete atomic-swap rollback may leave the new record on disk.
        // Preserve its directory until recovery can establish which state won.
        if let syncError = error as? DispatchParticipationError, case .rollbackFailed = syncError { return }
        try? fileManager.removeItem(at: home)
    }

    func selectMonitor(_ id: String) throws {
        try mutateState {
            guard self.state.profiles.contains(where: { $0.id == id }) else { return false }
            self.state.selectedMonitorProfileID = id
            return true
        }
    }

    @discardableResult
    func selectMonitorForSystemAccount() throws -> String {
        var selectedID: String?
        try mutateState {
            guard let system = self.state.profiles.first(where: \.isSystemProfile) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let target =
                self.state.profiles.first {
                    !$0.isSystemProfile
                        && $0.matchesRecordedAccount(email: system.lastSnapshot?.email)
                        && $0.lastSnapshot?.accountID == system.lastSnapshot?.accountID
                } ?? system
            selectedID = target.id
            guard self.state.selectedMonitorProfileID != target.id else { return false }
            self.state.selectedMonitorProfileID = target.id
            return true
        }
        guard let selectedID else { throw CocoaError(.fileReadCorruptFile) }
        return selectedID
    }

    func selectLaunch(_ id: String) throws {
        try mutateState {
            guard self.state.profiles.contains(where: { $0.id == id }) else { return false }
            self.state.selectedLaunchProfileID = id
            return true
        }
    }

    func setRemark(_ remark: String, for id: String) throws {
        let trimmed = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutateState {
            guard let index = self.state.profiles.firstIndex(where: { $0.id == id }) else { throw CodexExecutionPreferenceError.profileMissing }
            let next = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
            guard self.state.profiles[index].remark != next else { return false }
            self.state.profiles[index].remark = next
            return true
        }
    }

    func setChromeProfile(_ binding: ChromeProfileBinding?, for id: String) throws {
        guard binding?.isValid != false else { throw CocoaError(.validationMissingMandatoryProperty) }
        try mutateState {
            guard let index = self.state.profiles.firstIndex(where: { $0.id == id }) else { return false }
            guard self.state.profiles[index].chromeProfile != binding else { return false }
            self.state.profiles[index].chromeProfile = binding
            return true
        }
    }

    func setAutomaticSwitchParticipation(_ enabled: Bool, for id: String) throws {
        try mutateState {
            guard let profile = self.state.profiles.first(where: { $0.id == id }) else { return false }
            let accountKey = profile.recordedAccountKey
            var changed = false
            for index in self.state.profiles.indices
            where self.state.profiles[index].recordedAccountKey == accountKey {
                if self.state.profiles[index].automaticSwitchParticipation != enabled {
                    self.state.profiles[index].automaticSwitchParticipation = enabled
                    changed = true
                }
            }
            return changed
        }
    }

    /// External synchronization is an explicit UI action; ordinary persistence,
    /// startup backfills and snapshot reads never enter this path.
    func setDispatchParticipationFromUI(_ enabled: Bool, for id: String) throws {
        try setDispatchSettingsFromUI(.participation(enabled), for: id)
    }

    func setDispatchPriorityFromUI(_ enabled: Bool, for id: String) throws {
        try setDispatchSettingsFromUI(.priority(enabled), for: id)
    }

    func setDispatchParticipationWindow(_ window: DispatchParticipationWindow, for id: String) throws {
        try mutateState {
            guard let profile = self.state.profiles.first(where: { $0.id == id }), window.isValid else {
                throw DispatchParticipationError.invalidSnapshot
            }
            for index in self.state.profiles.indices where self.state.profiles[index].recordedAccountKey == profile.recordedAccountKey {
                self.state.profiles[index].dispatchParticipationWindow = window
            }
            return true
        }
    }

    private func setDispatchSettingsFromUI(_ change: DispatchParticipationSync.Change, for id: String) throws {
        guard !persistenceBlocked,
            let profile = state.profiles.first(where: { $0.id == id }),
            let system = state.profiles.first(where: \.isSystemProfile)
        else { throw DispatchParticipationError.invalidSnapshot }
        let validationNow = Date()
        let credentialIdentity = CodexOfficialProfileReader.credentialIdentity(
            codexHomeURL: profile.codexHomeURL
        )
        let identity = try Self.validatedDispatchIdentity(
            for: profile,
            credentialIdentity: credentialIdentity,
            now: validationNow
        )
        let sync = DispatchParticipationSync(paths: try DispatchParticipationPaths.live(snapshot: stateURL))
        var updatedState = state
        _ = try sync.apply(
            change,
            identity: identity
        ) { data in
            guard let decoded = try? JSONDecoder().decode(State.self, from: data),
                Self.isValid(decoded, systemPath: system.codexHomePath, managedRoot: self.managedRootURL)
            else { throw DispatchParticipationError.invalidSnapshot }
            try Self.validateDispatchMirrorCredentials(
                for: identity,
                in: decoded.profiles,
                now: validationNow,
                credentialReader: { CodexOfficialProfileReader.credentialIdentity(codexHomeURL: $0) }
            )
            updatedState = decoded
        }
        // The transaction returns only after all three files verify successfully.
        state = updatedState
    }

    static func validatedDispatchIdentity(
        for profile: CodexProfile,
        credentialIdentity: CodexCredentialIdentity?,
        now: Date = Date()
    ) throws -> DispatchParticipationSync.Identity {
        guard CodexWarmUpPolicy.hasFreshQuotaEvidence(profile, now: now),
            let snapshot = profile.lastSnapshot,
            snapshot.quotaReadSucceeded == true,
            snapshot.fiveHour != nil || snapshot.sevenDay != nil || snapshot.monthly != nil,
            profile.lastQuotaReadFailureAt.map({ $0 < snapshot.fetchedAt }) ?? true,
            let accountID = snapshot.accountID,
            !accountID.isEmpty,
            let credentialIdentity,
            profile.matchesRecordedCredential(credentialIdentity),
            credentialIdentity.accountID == accountID
        else { throw DispatchParticipationError.identityMismatch }
        return .init(
            profileID: profile.id,
            homePath: profile.codexHomePath,
            email: credentialIdentity.email,
            accountID: credentialIdentity.accountID
        )
    }

    static func validateDispatchMirrorCredentials(
        for clickedIdentity: DispatchParticipationSync.Identity,
        in profiles: [CodexProfile],
        now: Date = Date(),
        credentialReader: (URL) -> CodexCredentialIdentity?
    ) throws {
        guard let clicked = profiles.first(where: { $0.id == clickedIdentity.profileID }),
            clicked.codexHomeURL.standardizedFileURL.path
                == URL(fileURLWithPath: clickedIdentity.homePath).standardizedFileURL.path,
            let expectedEmail = clickedIdentity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !expectedEmail.isEmpty
        else { throw DispatchParticipationError.identityMismatch }
        let mirrors = profiles.filter { $0.recordedAccountKey == clicked.recordedAccountKey }
        guard !mirrors.isEmpty else { throw DispatchParticipationError.identityMismatch }
        for mirror in mirrors {
            let current = try validatedDispatchIdentity(
                for: mirror,
                credentialIdentity: credentialReader(mirror.codexHomeURL),
                now: now
            )
            guard current.accountID == clickedIdentity.accountID,
                current.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedEmail
            else { throw DispatchParticipationError.identityMismatch }
        }
    }

    func setPrioritizeDispatch(_ enabled: Bool, for id: String) throws {
        try mutateState {
            guard let profile = self.state.profiles.first(where: { $0.id == id }) else { return false }
            let accountKey = profile.recordedAccountKey
            var changed = false
            for index in self.state.profiles.indices
            where self.state.profiles[index].recordedAccountKey == accountKey {
                if self.state.profiles[index].prioritizeDispatch != enabled {
                    self.state.profiles[index].prioritizeDispatch = enabled
                    changed = true
                }
            }
            return changed
        }
    }

    func setProTierMultiplier(_ multiplier: Int?, for id: String) throws {
        guard multiplier == nil || multiplier == 5 || multiplier == 20 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        try mutateState {
            guard let profile = self.state.profiles.first(where: { $0.id == id }) else { return false }
            let accountKey = profile.recordedAccountKey
            var changed = false
            for index in self.state.profiles.indices
            where self.state.profiles[index].recordedAccountKey == accountKey {
                if self.state.profiles[index].proTierMultiplier != multiplier {
                    self.state.profiles[index].proTierMultiplier = multiplier
                    changed = true
                }
            }
            return changed
        }
    }

    func setExecutionPreference(
        _ preference: CodexExecutionPreference,
        for id: String,
        applyToAll: Bool = false
    ) throws {
        let validated = try preference.validated()
        try mutateState {
            guard let profile = self.state.profiles.first(where: { $0.id == id }) else {
                throw CodexExecutionPreferenceError.profileMissing
            }
            guard !profile.isSystemProfile else {
                throw CodexExecutionPreferenceError.systemProfileUnsupported
            }
            let accountKey = profile.recordedAccountKey
            var changed = false
            for index in self.state.profiles.indices
            where !self.state.profiles[index].isSystemProfile
                && (applyToAll || self.state.profiles[index].recordedAccountKey == accountKey)
            {
                if self.state.profiles[index].executionPreference != validated {
                    self.state.profiles[index].executionPreference = validated
                    changed = true
                }
            }
            return changed
        }
    }

    func effectiveCredentialHome(for profileID: String) -> URL? {
        guard let profile = state.profiles.first(where: { $0.id == profileID }) else { return nil }
        guard !profile.isSystemProfile,
            let system = state.profiles.first(where: \.isSystemProfile),
            let identity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: system.codexHomeURL),
            profile.matchesRecordedCredential(identity)
        else { return profile.codexHomeURL }
        return system.codexHomeURL
    }

    /// Commit one complete order only while the caller's observed order is current.
    /// The caller supplies hidden slots; profile fields and dispatch preferences stay intact.
    func reorderProfiles(_ orderedIDs: [String], expectedCurrentOrder: [String]) throws {
        try mutateState {
            let currentIDs = self.state.profiles.map(\.id)
            guard currentIDs == expectedCurrentOrder else { throw DispatchParticipationError.concurrentChange }
            guard orderedIDs.count == currentIDs.count,
                Set(orderedIDs).count == orderedIDs.count,
                Set(orderedIDs) == Set(currentIDs)
            else { throw DispatchParticipationError.invalidSnapshot }
            guard orderedIDs != currentIDs else { return false }
            let byID = Dictionary(uniqueKeysWithValues: self.state.profiles.map { ($0.id, $0) })
            self.state.profiles = orderedIDs.compactMap { byID[$0] }
            return true
        }
    }

    func moveProfile(_ id: String, relativeTo targetID: String, before: Bool) throws {
        try mutateState {
            guard id != targetID,
                let sourceIndex = self.state.profiles.firstIndex(where: { $0.id == id }),
                self.state.profiles.contains(where: { $0.id == targetID })
            else { return false }
            let profile = self.state.profiles.remove(at: sourceIndex)
            guard let targetIndex = self.state.profiles.firstIndex(where: { $0.id == targetID }) else {
                return false
            }
            self.state.profiles.insert(profile, at: before ? targetIndex : targetIndex + 1)
            return true
        }
    }

    func record(
        _ snapshot: UsageSnapshot,
        for profileID: String,
        allowAccountOnly: Bool = false,
        allowSystemAccountChange: Bool = false
    ) throws {
        let hasVerifiedAccount = snapshot.account?.email?.isEmpty == false
        let appServerVersion =
            snapshot.quotaReadSucceeded || (allowAccountOnly && hasVerifiedAccount)
            ? CodexExecutable.version() : nil
        try mutateState {
            guard let index = self.state.profiles.firstIndex(where: { $0.id == profileID })
            else { return false }
            let credentialIdentity = CodexOfficialProfileReader.credentialIdentity(
                codexHomeURL: self.state.profiles[index].codexHomeURL
            )
            let snapshotEmail = snapshot.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let identityMatchesSnapshot = credentialIdentity?.email == snapshotEmail
            let verifiedAccountID = identityMatchesSnapshot ? credentialIdentity?.accountID : nil
            let previousAccountID = self.state.profiles[index].lastSnapshot?.accountID
            let accountChanged =
                !self.state.profiles[index].matchesRecordedAccount(email: snapshot.account?.email)
                || (previousAccountID != nil && verifiedAccountID != nil && previousAccountID != verifiedAccountID)
            let verifiedSystemChange =
                allowSystemAccountChange && self.state.profiles[index].isSystemProfile
                && accountChanged && identityMatchesSnapshot && verifiedAccountID != nil
            if allowSystemAccountChange, self.state.profiles[index].isSystemProfile,
                credentialIdentity != nil, snapshotEmail != nil, !identityMatchesSnapshot
            {
                return false
            }
            // Pool and selected-profile reads can finish out of order. Keep both
            // success and failure observations monotonic, while allowing equal-time
            // records to enrich account data or recover a failed read. A verified
            // Desktop identity change starts a new account's observation sequence.
            let newestObservationAt = max(
                self.state.profiles[index].lastSnapshot?.fetchedAt ?? .distantPast,
                self.state.profiles[index].lastQuotaReadFailureAt ?? .distantPast
            )
            guard snapshot.refreshedAt >= newestObservationAt || verifiedSystemChange else { return false }
            guard snapshot.quotaReadSucceeded || (allowAccountOnly && hasVerifiedAccount) else {
                let previous = self.state.profiles[index].lastSnapshot
                let successfulSnapshotAtSameTime =
                    previous?.fetchedAt == snapshot.refreshedAt
                    && previous?.quotaReadSucceeded != false
                guard !successfulSnapshotAtSameTime else { return false }
                // 额度读取失败时保留旧数据，但必须留下可见的失败痕迹，
                // 避免账号凭证失效后快照无限期静默过期。
                // 失败原因只保留分类标记，不落盘原始服务端消息，避免写入账号标识。
                let failureReason = Self.quotaFailureReason(from: snapshot.messages)
                let changed =
                    self.state.profiles[index].lastQuotaReadFailureAt != snapshot.refreshedAt
                    || self.state.profiles[index].lastQuotaReadFailureReason != failureReason
                if changed {
                    self.state.profiles[index].lastQuotaReadFailureAt = snapshot.refreshedAt
                    self.state.profiles[index].lastQuotaReadFailureReason = failureReason
                }
                return changed
            }
            guard !accountChanged || (allowSystemAccountChange && self.state.profiles[index].isSystemProfile) else { return false }
            if accountChanged {
                self.state.profiles[index].officialResetHistory = nil
                self.state.profiles[index].officialProfile = nil
                self.state.profiles[index].lastWarmUpAt = nil
                self.state.profiles[index].lastWarmUpSucceeded = nil
                self.state.profiles[index].lastWarmUpFailureReason = nil
                self.state.profiles[index].warmUpHistory = nil
                self.state.profiles[index].warmUpRequest = nil
                self.state.profiles[index].dispatchParticipationWindow = nil
                self.state.profiles[index].proTierMultiplier = nil
                if self.state.profiles[index].isSystemProfile {
                    self.state.profiles[index].remark = nil
                    let matchingManagedProfile = self.state.profiles.first {
                        !$0.isSystemProfile
                            && $0.matchesRecordedAccount(email: snapshot.account?.email)
                            && ($0.lastSnapshot?.accountID == nil || $0.lastSnapshot?.accountID == verifiedAccountID)
                    }
                    self.state.profiles[index].chromeProfile = matchingManagedProfile?.chromeProfile
                    self.state.profiles[index].automaticSwitchParticipation =
                        matchingManagedProfile?.automaticSwitchParticipation
                    self.state.profiles[index].prioritizeDispatch = matchingManagedProfile?.prioritizeDispatch
                    self.state.profiles[index].proTierMultiplier = matchingManagedProfile?.proTierMultiplier
                    self.state.profiles[index].dispatchParticipationWindow = matchingManagedProfile?.dispatchParticipationWindow
                }
            }
            let previousSnapshot = self.state.profiles[index].lastSnapshot
            let mergesEqualObservation = !accountChanged && previousSnapshot?.fetchedAt == snapshot.refreshedAt
            let record = CodexAccountSnapshot(
                accountType: mergesEqualObservation ? previousSnapshot?.accountType ?? snapshot.account?.type : snapshot.account?.type,
                planType: mergesEqualObservation ? previousSnapshot?.planType ?? snapshot.account?.planType : snapshot.account?.planType,
                email: mergesEqualObservation ? previousSnapshot?.email ?? snapshot.account?.email : snapshot.account?.email,
                accountID: verifiedAccountID ?? (accountChanged ? nil : previousAccountID),
                limitId: mergesEqualObservation ? previousSnapshot?.limitId ?? snapshot.limitId : snapshot.limitId,
                limitName: mergesEqualObservation ? previousSnapshot?.limitName ?? snapshot.limitName : snapshot.limitName,
                fiveHour: mergesEqualObservation
                    ? previousSnapshot?.fiveHour ?? snapshot.fiveHourQuota.map(CodexQuotaWindowSnapshot.init)
                    : snapshot.fiveHourQuota.map(CodexQuotaWindowSnapshot.init),
                sevenDay: mergesEqualObservation
                    ? previousSnapshot?.sevenDay ?? snapshot.sevenDayQuota.map(CodexQuotaWindowSnapshot.init)
                    : snapshot.sevenDayQuota.map(CodexQuotaWindowSnapshot.init),
                monthly: mergesEqualObservation
                    ? previousSnapshot?.monthly ?? snapshot.monthlyQuota.map(CodexQuotaWindowSnapshot.init)
                    : snapshot.monthlyQuota.map(CodexQuotaWindowSnapshot.init),
                availableResetCredits: mergesEqualObservation
                    ? previousSnapshot?.availableResetCredits ?? snapshot.credits?.resetCredits
                    : snapshot.credits?.resetCredits,
                resetCreditExpiries: mergesEqualObservation
                    ? previousSnapshot?.resetCreditExpiries ?? snapshot.credits?.resetCreditDetails?.compactMap(\.expiresAt).sorted()
                    : snapshot.credits?.resetCreditDetails?.compactMap(\.expiresAt).sorted(),
                creditBalance: mergesEqualObservation
                    ? previousSnapshot?.creditBalance ?? CreditBalancePresentation.normalizedBalance(snapshot.credits?.balance)
                    : CreditBalancePresentation.normalizedBalance(snapshot.credits?.balance),
                creditBalanceUnlimited: mergesEqualObservation
                    ? previousSnapshot?.creditBalanceUnlimited ?? snapshot.credits.map(\.unlimited)
                    : snapshot.credits.map(\.unlimited),
                fetchedAt: snapshot.refreshedAt,
                appServerVersion: mergesEqualObservation
                    ? previousSnapshot?.appServerVersion ?? appServerVersion
                    : appServerVersion,
                quotaReadSucceeded: snapshot.quotaReadSucceeded
                    || (mergesEqualObservation && (previousSnapshot?.quotaReadSucceeded ?? true))
            )
            let previousSevenDay = self.state.profiles[index].lastSnapshot?.sevenDay
            self.state.profiles[index].lastSnapshot = record
            if snapshot.quotaReadSucceeded {
                self.state.profiles[index].lastQuotaReadFailureAt = nil
                self.state.profiles[index].lastQuotaReadFailureReason = nil
            }
            if !accountChanged,
                CodexWarmUpPolicy.didConsumeReset(
                    previous: previousSevenDay,
                    current: record.sevenDay,
                    now: snapshot.refreshedAt
                ),
                !self.resetAlreadyObservedInGroup(
                    previous: previousSevenDay,
                    current: record.sevenDay,
                    excludingIndex: index
                )
            {
                let key = self.state.profiles[index].recordedAccountKey
                var counters = self.state.resetCounters ?? [:]
                var counter = counters[key] ?? CodexAccountResetCounter()
                counter.automaticCount += 1
                counter.lastCountedResetAt = record.sevenDay?.resetsAt ?? record.fetchedAt
                if let newWindowEnd = record.sevenDay?.resetsAt {
                    counter.cardExpiresAt = newWindowEnd
                }
                counters[key] = counter
                self.state.resetCounters = counters
            }
            if let email = record.email, !email.isEmpty {
                self.state.profiles[index].name = email
            }
            return true
        }
    }

    func recordOfficialProfile(_ snapshot: CodexOfficialProfileSnapshot, for profileID: String) throws {
        try mutateState {
            guard let index = self.state.profiles.firstIndex(where: { $0.id == profileID }),
                self.state.profiles[index].matchesRecordedAccount(email: snapshot.accountEmail),
                snapshot.fetchedAt >= (self.state.profiles[index].officialProfile?.fetchedAt ?? .distantPast)
            else { return false }
            self.state.profiles[index].officialProfile = snapshot
            return true
        }
    }

    func recordMembershipRefresh(at date: Date, succeeded: Bool, for profileID: String) throws {
        try mutateState {
            guard let index = self.state.profiles.firstIndex(where: { $0.id == profileID }),
                !self.state.profiles[index].isSystemProfile,
                date >= (self.state.profiles[index].lastMembershipRefreshAt ?? .distantPast)
            else { return false }
            self.state.profiles[index].lastMembershipRefreshAt = date
            self.state.profiles[index].lastMembershipRefreshSucceeded = succeeded
            return true
        }
    }

    enum WarmUpStateError: Error { case unverifiedIdentityOrState }

    /// Re-read the shared state under its lock, then persist BEFORE starting HTTP.
    func beginWarmUp(
        requestID: String, for profileID: String, expectedAccountID: String,
        selection: CodexWarmUpSelection, unexpected: Set<CodexWarmUpWindowKind>,
        manual: Bool, at date: Date = Date()
    ) throws {
        try mutateState {
            guard let profile = self.state.profiles.first(where: { $0.id == profileID }),
                let snapshot = profile.lastSnapshot, snapshot.accountID == expectedAccountID,
                !expectedAccountID.isEmpty,
                let identity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: profile.codexHomeURL),
                profile.matchesRecordedCredential(identity),
                CodexWarmUpPolicy.canSendWarmUpRequest(profile, now: date)
            else { throw WarmUpStateError.unverifiedIdentityOrState }
            let indices = self.state.profiles.indices.filter {
                self.state.profiles[$0].recordedAccountKey == profile.recordedAccountKey
            }
            guard
                manual
                    || indices.allSatisfy({
                        CodexWarmUpPolicy.isDue(self.state.profiles[$0], selection: selection, unexpected: unexpected, now: date)
                    })
            else { throw WarmUpStateError.unverifiedIdentityOrState }
            let request = CodexWarmUpRequest(
                id: requestID, accountID: expectedAccountID, startedAt: date, limitID: snapshot.limitId,
                fiveHourResetAt: snapshot.fiveHour?.resetsAt, sevenDayResetAt: snapshot.sevenDay?.resetsAt,
                source: manual ? "manual" : "automatic")
            for index in indices where self.state.profiles[index].lastSnapshot?.accountID == expectedAccountID {
                let previous = self.state.profiles[index]
                if (previous.warmUpHistory ?? []).isEmpty,
                    let at = previous.lastWarmUpAt, let succeeded = previous.lastWarmUpSucceeded
                {
                    self.state.profiles[index].warmUpHistory = [
                        .init(
                            at: at, succeeded: succeeded,
                            failureReason: Self.safeWarmUpFailureCode(previous.lastWarmUpFailureReason))
                    ]
                }
                self.state.profiles[index].warmUpRequest = request
                self.state.profiles[index].lastWarmUpAt = date
                self.state.profiles[index].lastWarmUpSucceeded = false
                self.state.profiles[index].lastWarmUpFailureReason = "pending"
            }
            return true
        }
    }

    static func safeWarmUpFailureCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed: Set<String> = [
            "pending", "credentials-unavailable", "identity-mismatch", "invalid-request", "redirected", "timeout", "network", "http-5xx", "stream-failed", "stream-incomplete",
            "stream-oversized", "unknown",
        ]
        if allowed.contains(value) || value.range(of: #"^http-[1-5][0-9]{2}$"#, options: .regularExpression) != nil { return value }
        return "unknown"
    }

    func recordWarmUp(
        at date: Date,
        succeeded: Bool,
        failureReason: String? = nil,
        for profileID: String,
        requestID: String? = nil,
        expectedAccountID: String? = nil
    ) throws {
        try mutateState {
            guard let index = self.state.profiles.firstIndex(where: { $0.id == profileID }) else { return false }
            let current = self.state.profiles[index]
            if let requestID {
                guard let expectedAccountID,
                    current.lastSnapshot?.accountID == expectedAccountID,
                    current.warmUpRequest?.id == requestID,
                    current.warmUpRequest?.accountID == expectedAccountID,
                    current.matchesRecordedCredential(CodexOfficialProfileReader.credentialIdentity(codexHomeURL: current.codexHomeURL))
                else { throw WarmUpStateError.unverifiedIdentityOrState }
            }
            let indices =
                requestID == nil
                ? [index]
                : self.state.profiles.indices.filter {
                    self.state.profiles[$0].warmUpRequest?.id == requestID
                        && self.state.profiles[$0].lastSnapshot?.accountID == expectedAccountID
                }
            for target in indices {
                let previous = self.state.profiles[target]
                guard date >= (previous.lastWarmUpAt ?? .distantPast) else { continue }
                // A duplicate/late callback cannot downgrade a completed request.
                if previous.lastWarmUpSucceeded == true && (requestID != nil || date == previous.lastWarmUpAt) { continue }
                var history = previous.warmUpHistory ?? []
                if history.isEmpty, previous.lastWarmUpFailureReason != "pending",
                    let at = previous.lastWarmUpAt, let succeeded = previous.lastWarmUpSucceeded
                {
                    history.append(.init(at: at, succeeded: succeeded, failureReason: Self.safeWarmUpFailureCode(previous.lastWarmUpFailureReason)))
                }
                let reason = succeeded ? nil : Self.safeWarmUpFailureCode(failureReason)
                let attempt = CodexWarmUpAttempt(
                    at: date, succeeded: succeeded, failureReason: reason,
                    attemptID: requestID, source: requestID == nil ? nil : previous.warmUpRequest?.source)
                if let requestID { history.removeAll { $0.attemptID == requestID } }
                if history.last != attempt { history.append(attempt) }
                self.state.profiles[target].warmUpHistory = Array(history.suffix(20))
                self.state.profiles[target].lastWarmUpAt = date
                self.state.profiles[target].lastWarmUpSucceeded = succeeded
                self.state.profiles[target].lastWarmUpFailureReason = reason
            }
            return true
        }
    }

    /// 从额度读取的诊断消息中提取可展示的失败分类；只保留标记，不保留原始消息。
    static func quotaFailureReason(from messages: [String]) -> String? {
        let joined = messages.joined(separator: "\n").lowercased()
        let tokens = Set(joined.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
        let officialPermanentMessage =
            joined.contains("refresh token has expired")
            || joined.contains("refresh token was already used")
            || joined.contains("refresh token was revoked")
        let officialPermanentCode =
            tokens.contains("refresh_token_expired")
            || tokens.contains("refresh_token_reused")
            || tokens.contains("refresh_token_invalidated")
            || (tokens.contains("invalid_grant") && joined.contains("refresh"))
        if joined.contains("oauth-invalidated") || joined.contains("invalidated oauth token")
            || officialPermanentMessage || officialPermanentCode
        {
            return "oauth-invalidated"
        }
        return nil
    }

    func resetCounter(accountKey: String) -> CodexAccountResetCounter {
        state.resetCounters?[accountKey] ?? CodexAccountResetCounter()
    }

    /// Managed homes may have CLI refresh writers. Copy only an evidenced newer session bundle.
    func syncSystemAuthToMatchingManagedProfiles() throws {
        CodexCredentialAccessGate.lock.lock()
        defer { CodexCredentialAccessGate.lock.unlock() }
        guard let system = state.profiles.first(where: \.isSystemProfile),
            let authData = try CodexCredentialTransaction.read(system.codexHomeURL.appendingPathComponent("auth.json")),
            let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: authData),
            identity.email == system.recordedAccountKey,
            system.lastSnapshot?.accountID == identity.accountID
        else { return }
        var visited = Set<String>()
        for profile in state.profiles
        where !profile.isSystemProfile
            && profile.recordedAccountKey == system.recordedAccountKey
            && profile.lastSnapshot?.accountID == identity.accountID
        {
            guard visited.insert(CodexCredentialTransaction.canonical(profile.codexHomeURL).path).inserted else { continue }
            try writeAuth(authData, from: system.codexHomeURL, to: profile.codexHomeURL)
        }
    }

    /// 同一账号组内其他卡是否已记录过这轮窗口状态；避免同一次重置被多张卡重复计数。
    private func resetAlreadyObservedInGroup(
        previous: CodexQuotaWindowSnapshot?,
        current: CodexQuotaWindowSnapshot?,
        excludingIndex index: Int
    ) -> Bool {
        guard let current,
            let currentReset = current.resetsAt,
            let previousReset = previous?.resetsAt
        else { return false }
        let key = state.profiles[index].recordedAccountKey
        let isNewWindow = abs(currentReset.timeIntervalSince(previousReset)) > 120
        for (otherIndex, other) in state.profiles.enumerated() where otherIndex != index {
            guard other.recordedAccountKey == key,
                let otherReset = other.lastSnapshot?.sevenDay?.resetsAt,
                abs(otherReset.timeIntervalSince(currentReset)) <= 120
            else { continue }
            if isNewWindow { return true }
            if let otherUsed = other.lastSnapshot?.sevenDay?.usedPercent,
                abs(otherUsed - current.usedPercent) <= 0.5
            {
                return true
            }
        }
        return false
    }

    func adjustResetManualOffset(accountKey: String, delta: Int, fallbackExpiry: Date? = nil) throws {
        try mutateState {
            var counters = self.state.resetCounters ?? [:]
            var counter = counters[accountKey] ?? CodexAccountResetCounter()
            counter.manualOffset = max(-counter.automaticCount, counter.manualOffset + delta)
            if delta > 0, let fallbackExpiry {
                if let current = counter.cardExpiresAt {
                    if fallbackExpiry > current {
                        counter.cardExpiresAt = fallbackExpiry
                    }
                } else {
                    counter.cardExpiresAt = fallbackExpiry
                }
            }
            counters[accountKey] = counter
            guard self.state.resetCounters != counters else { return false }
            self.state.resetCounters = counters
            return true
        }
    }

    func setResetCardExpiry(accountKey: String, date: Date?) throws {
        try mutateState {
            var counters = self.state.resetCounters ?? [:]
            var counter = counters[accountKey] ?? CodexAccountResetCounter()
            guard counter.cardExpiresAt != date else { return false }
            counter.cardExpiresAt = date
            counters[accountKey] = counter
            self.state.resetCounters = counters
            return true
        }
    }

    func discardUnverifiedManagedProfiles() throws {
        var discarded: [CodexProfile] = []
        try mutateState {
            discarded = self.state.profiles.filter { !$0.isSystemProfile && $0.lastSnapshot == nil }
            guard !discarded.isEmpty else { return false }
            let discardedIDs = Set(discarded.map(\.id))
            self.state.profiles.removeAll { discardedIDs.contains($0.id) }
            let fallbackID = self.state.profiles.first(where: \.isSystemProfile)?.id ?? self.state.profiles[0].id
            if discardedIDs.contains(self.state.selectedMonitorProfileID) {
                self.state.selectedMonitorProfileID = fallbackID
            }
            if discardedIDs.contains(self.state.selectedLaunchProfileID) {
                self.state.selectedLaunchProfileID = fallbackID
            }
            return true
        }
        for profile in discarded {
            let authURL = profile.codexHomeURL.appendingPathComponent("auth.json")
            if !fileManager.fileExists(atPath: authURL.path) {
                try? fileManager.removeItem(at: profile.codexHomeURL)
            }
        }
    }

    func discardManagedProfile(_ id: String, removingHomeWithCredentials: Bool = false) throws {
        guard let profile = try removeManagedProfileRecord(id) else { return }
        let authURL = profile.codexHomeURL.appendingPathComponent("auth.json")
        if removingHomeWithCredentials || !fileManager.fileExists(atPath: authURL.path) {
            try? fileManager.removeItem(at: profile.codexHomeURL)
        }
    }

    func removeManagedProfile(_ id: String) throws {
        _ = try removeManagedProfileRecord(id, movingToTrash: true)
    }

    private func removeManagedProfileRecord(_ id: String, movingToTrash: Bool = false) throws -> CodexProfile? {
        var removed: CodexProfile?
        var trashedURL: NSURL?
        do {
            try mutateState {
                guard let index = self.state.profiles.firstIndex(where: { $0.id == id && !$0.isSystemProfile }) else {
                    return false
                }
                let profile = self.state.profiles[index]
                removed = profile
                if movingToTrash, self.fileManager.fileExists(atPath: profile.codexHomePath) {
                    try self.fileManager.trashItem(at: profile.codexHomeURL, resultingItemURL: &trashedURL)
                }
                self.state.profiles.remove(at: index)
                let fallbackID = self.state.profiles.first(where: \.isSystemProfile)?.id ?? self.state.profiles[0].id
                if self.state.selectedMonitorProfileID == id { self.state.selectedMonitorProfileID = fallbackID }
                if self.state.selectedLaunchProfileID == id { self.state.selectedLaunchProfileID = fallbackID }
                return true
            }
        } catch {
            if let trashedURL, let profile = removed {
                try? fileManager.moveItem(at: trashedURL as URL, to: profile.codexHomeURL)
            }
            throw error
        }
        return removed
    }

    private func applyStartupBackfill() throws {
        try mutateState {
            var changed = self.backfillCredentialAccountIDs()
            if self.state.resetBackfillCheckedAt == nil {
                changed = Self.backfillResetCountersFromHistory(in: &self.state) || changed
                self.state.resetBackfillCheckedAt = Date()
                changed = true
            }
            return changed
        }
    }

    /// Every state change starts from the bytes currently on disk while holding
    /// the same cross-process lock as DispatchParticipationSync. Atomic writes
    /// alone prevent torn JSON, but cannot prevent a second Next process from
    /// replacing a newer whole snapshot with its startup-era cache.
    private func mutateState(_ mutation: () throws -> Bool) throws {
        guard !persistenceBlocked else {
            throw NSError(
                domain: "CodexAccountManagerNext.ProfileStore",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text(
                        "账号状态文件无法安全读取；已阻止覆盖，请先备份并恢复该文件", "The account state file cannot be read safely. Writing is blocked; back up and restore the file first.")
                ]
            )
        }
        let previousState = state
        let directory = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try DispatchParticipationSync.withSnapshotLock(at: stateURL) {
                let original = try DispatchParticipationSync.readSnapshot(at: stateURL)
                if let original {
                    guard let decoded = try? JSONDecoder().decode(State.self, from: original),
                        Self.isValid(
                            decoded,
                            systemPath: previousState.profiles.first(where: \.isSystemProfile)?.codexHomePath ?? "",
                            managedRoot: self.managedRootURL
                        )
                    else {
                        throw NSError(
                            domain: "CodexAccountManagerNext.ProfileStore",
                            code: 4,
                            userInfo: [
                                NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text(
                                    "账号状态文件已被其他实例改为无效内容，已阻止覆盖",
                                    "The account state was made invalid by another instance. Writing was blocked."
                                )
                            ]
                        )
                    }
                    self.state = decoded
                    self.hasObservedPersistedState = true
                } else {
                    guard !self.hasObservedPersistedState else {
                        throw NSError(
                            domain: "CodexAccountManagerNext.ProfileStore",
                            code: 5,
                            userInfo: [
                                NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text(
                                    "账号状态文件在运行期间丢失，已阻止覆盖",
                                    "The account state disappeared while Next was running. Writing was blocked."
                                )
                            ]
                        )
                    }
                    self.state = previousState
                }
                guard try mutation() else { return }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let encoded = try encoder.encode(self.state)
                try DispatchParticipationSync.writeSnapshot(encoded, at: self.stateURL, replacing: original)
                self.hasObservedPersistedState = true
            }
        } catch {
            state = previousState
            throw error
        }
    }

    @discardableResult
    private func backfillCredentialAccountIDs() -> Bool {
        var changed = false
        for index in state.profiles.indices {
            guard let current = state.profiles[index].lastSnapshot,
                let identity = CodexOfficialProfileReader.credentialIdentity(
                    codexHomeURL: state.profiles[index].codexHomeURL
                ),
                state.profiles[index].matchesRecordedAccount(email: identity.email),
                current.accountID == nil
            else { continue }
            state.profiles[index].lastSnapshot = Self.snapshotByReplacingAccountID(
                current,
                accountID: identity.accountID,
                invalidateQuota: true
            )
            changed = true
        }
        return changed
    }

    static func snapshotByReplacingAccountID(
        _ snapshot: CodexAccountSnapshot,
        accountID: String?,
        invalidateQuota: Bool = false
    ) -> CodexAccountSnapshot {
        CodexAccountSnapshot(
            accountType: snapshot.accountType,
            planType: snapshot.planType,
            email: snapshot.email,
            accountID: accountID,
            limitId: snapshot.limitId,
            limitName: snapshot.limitName,
            fiveHour: snapshot.fiveHour,
            sevenDay: snapshot.sevenDay,
            monthly: snapshot.monthly,
            availableResetCredits: snapshot.availableResetCredits,
            resetCreditExpiries: snapshot.resetCreditExpiries,
            creditBalance: snapshot.creditBalance,
            creditBalanceUnlimited: snapshot.creditBalanceUnlimited,
            fetchedAt: snapshot.fetchedAt,
            appServerVersion: snapshot.appServerVersion,
            quotaReadSucceeded: invalidateQuota ? false : snapshot.quotaReadSucceeded
        )
    }

    private func writeAuth(_ data: Data, from source: URL, to home: URL) throws {
        guard let system = state.profiles.first(where: \.isSystemProfile),
            CodexCredentialTransaction.canonical(source) == CodexCredentialTransaction.canonical(system.codexHomeURL),
            let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data)
        else { throw CodexCredentialTransaction.Failure.invalidIdentity }
        try CodexCredentialTransaction.copy(
            from: source, to: home, managedRoot: managedRootURL,
            expectedSource: data, identity: identity
        )
    }

    private static func isValid(_ state: State, systemPath: String, managedRoot: URL) -> Bool {
        guard state.schemaVersion == 1,
            !state.profiles.isEmpty,
            Set(state.profiles.map(\.id)).count == state.profiles.count,
            state.profiles.contains(where: { $0.id == state.selectedMonitorProfileID }),
            state.profiles.contains(where: { $0.id == state.selectedLaunchProfileID })
        else { return false }

        let root = managedRoot.standardizedFileURL.path + "/"
        return state.profiles.allSatisfy { profile in
            let path = profile.codexHomeURL.standardizedFileURL.path
            let homeIsValid = profile.isSystemProfile ? path == systemPath : path.hasPrefix(root)
            let preferenceIsValid =
                profile.isSystemProfile
                ? profile.executionPreference == nil
                : profile.executionPreference?.savedModelSettingsAreValid != false
            return homeIsValid && profile.chromeProfile?.isValid != false && preferenceIsValid
        }
    }
}

enum CodexProfileStoreSelfTest {
    static func run() -> Bool {
        let failureMessage = CodexUsageReader.appServerFailureMessage(
            requestID: 3,
            error: ["message": "HTTP 401 Unauthorized: Invalidated OAuth Token; private-response-marker"]
        )
        let unknownFailure = CodexUsageReader.appServerFailureMessage(
            requestID: 3,
            error: ["message": "unknown private-response-marker"]
        )
        let genericUnauthorizedFailure = CodexUsageReader.appServerFailureMessage(
            requestID: 3,
            error: ["message": "HTTP 401 Unauthorized; private-response-marker"]
        )
        guard failureMessage == "app-server 3: oauth-invalidated",
            CodexProfileStore.quotaFailureReason(from: [failureMessage]) == "oauth-invalidated",
            !unknownFailure.contains("private-response-marker"),
            CodexProfileStore.quotaFailureReason(from: [unknownFailure]) == nil,
            !genericUnauthorizedFailure.contains("private-response-marker"),
            CodexProfileStore.quotaFailureReason(from: ["401 Unauthorized"]) == nil,
            CodexProfileStore.quotaFailureReason(from: [genericUnauthorizedFailure]) == nil
        else {
            print("Codex profile store self-test failed: safe quota failure classification")
            return false
        }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codex-profile-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        do {
            guard try testQuotaObservationOrdering(root: root, fileManager: fileManager) else { return false }
            guard try testSystemSwitchObservationOrdering(root: root, fileManager: fileManager) else { return false }
            guard try testCrossInstanceStateTransactions(root: root, fileManager: fileManager) else { return false }
            guard try testProfileOrderTransactions(root: root, fileManager: fileManager) else { return false }
            guard try testStateTransactionFailures(root: root, fileManager: fileManager) else { return false }
            guard try testIndependentMonitorSelection(root: root, fileManager: fileManager) else { return false }
            let home = root.appendingPathComponent("home", isDirectory: true)
            let support = root.appendingPathComponent("support", isDirectory: true)
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
            let corruptSupport = root.appendingPathComponent("corrupt-support", isDirectory: true)
            let corruptStateURL =
                corruptSupport
                .appendingPathComponent("CodexAccountManagerNext", isDirectory: true)
                .appendingPathComponent("account-manager-next-v1.json")
            try fileManager.createDirectory(
                at: corruptStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let corruptState = Data("{not-valid-json".utf8)
            try corruptState.write(to: corruptStateURL)
            let blocked = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: home,
                applicationSupportDirectory: corruptSupport
            )
            do {
                try blocked.setRemark("must not persist", for: "system")
                print("Codex profile store self-test failed: corrupt state mutation was accepted")
                return false
            } catch {}
            do {
                try blocked.discardManagedProfile("system", removingHomeWithCredentials: true)
                print("Codex profile store self-test failed: corrupt state discard was accepted")
                return false
            } catch let error as NSError {
                guard error.domain == "CodexAccountManagerNext.ProfileStore", error.code == 3 else {
                    print("Codex profile store self-test failed: discard error is not the blocked-write failure")
                    return false
                }
            }
            guard try Data(contentsOf: corruptStateURL) == corruptState else {
                print("Codex profile store self-test failed: corrupt state was overwritten")
                return false
            }
            let first = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: home,
                applicationSupportDirectory: support
            )
            guard !first.hadSavedStateOnLoad, blocked.hadSavedStateOnLoad,
                CodexProfileStore(fileManager: fileManager, homeDirectory: home, applicationSupportDirectory: support).hadSavedStateOnLoad
            else {
                print("Codex profile store self-test failed: installation history detection")
                return false
            }
            _ = try first.addManagedProfile()
            try first.discardUnverifiedManagedProfiles()
            guard first.profiles.count == 1 else {
                print("Codex profile store self-test failed: unverified cleanup")
                return false
            }
            try first.setRemark("🍃", for: "system")
            let detached = try first.addManagedProfile(copyingRemarkFrom: "system")
            guard first.profiles.first?.id == detached.id, detached.remark == "🍃" else {
                print("Codex profile store self-test failed: independent login placeholder")
                return false
            }
            try first.discardManagedProfile(detached.id)
            try first.setRemark("", for: "system")
            let added = try first.addManagedProfile()
            try first.selectMonitor(added.id)
            try first.selectLaunch(added.id)
            let firstSnapshot = testSnapshot(
                email: "first@example.com",
                usedPercent: 11,
                at: Date(timeIntervalSince1970: 100),
                resetCredits: 2,
                balance: "12.50",
                unlimited: false
            )
            let secondSnapshot = testSnapshot(email: "second@example.com", usedPercent: 22, at: Date(timeIntervalSince1970: 200))
            let managedSnapshot = testSnapshot(
                email: "managed@example.com",
                usedPercent: 33,
                at: Date(timeIntervalSince1970: 300),
                resetCredits: 2,
                balance: "0",
                unlimited: false
            )
            guard added.effectiveExecutionPreference == .defaultValue else {
                print("Codex profile store self-test failed: legacy execution preference default")
                return false
            }
            let appleEpochWindow = try JSONDecoder().decode(
                CodexQuotaWindowSnapshot.self,
                from: Data(#"{"usedPercent":0,"resetsAt":259200}"#.utf8)
            )
            let reminderNow = Date(timeIntervalSince1970: 1_000_000)
            guard
                appleEpochWindow.resetsAt
                    == Date(timeIntervalSince1970: 978_307_200 + 259_200),
                SevenDayResetReminder.remainingDays(
                    resetsAt: reminderNow.addingTimeInterval(72 * 60 * 60),
                    now: reminderNow
                ) == 3,
                SevenDayResetReminder.message(
                    resetsAt: reminderNow.addingTimeInterval(1),
                    now: reminderNow
                ) == "7 天窗口 1 天后重置",
                SevenDayResetReminder.remainingDays(
                    resetsAt: reminderNow.addingTimeInterval(72 * 60 * 60 + 1),
                    now: reminderNow
                ) == nil,
                SevenDayResetReminder.remainingDays(resetsAt: reminderNow, now: reminderNow) == nil
            else {
                print("Codex profile store self-test failed: seven-day reset reminder boundary")
                return false
            }
            let invalidPreference = CodexExecutionPreference(
                model: .gpt52,
                reasoningEffort: .ultra,
                serviceTier: .fast
            )
            let legacyPreference = try JSONDecoder().decode(
                CodexExecutionPreference.self,
                from: Data(#"{"model":"gpt-6-astra","reasoningEffort":"low","serviceTier":"default"}"#.utf8)
            )
            guard legacyPreference == .defaultValue else {
                print("Codex profile store self-test failed: legacy subagent mode default")
                return false
            }
            let allCustomPresets: [String: CodexExecutionPreference.CustomPreset] = [
                CodexExecutionPreference.SubagentMode.standard.rawValue: .init(
                    name: String(repeating: "a", count: 64),
                    useSavedModel: false,
                    model: .terra,
                    reasoningEffort: .xhigh,
                    subagentsEnabled: true,
                    subagentModel: .gpt55,
                    subagentReasoningEffort: .high
                ),
                CodexExecutionPreference.SubagentMode.solLuna.rawValue: .init(
                    name: "Builder",
                    useSavedModel: true,
                    model: .sol,
                    reasoningEffort: .medium,
                    subagentsEnabled: false,
                    subagentModel: .luna,
                    subagentReasoningEffort: .max
                ),
                CodexExecutionPreference.SubagentMode.lunaDirect.rawValue: .init(
                    name: nil,
                    useSavedModel: false,
                    model: .luna,
                    reasoningEffort: .high,
                    subagentsEnabled: true,
                    subagentModel: .astra,
                    subagentReasoningEffort: .ultra
                ),
            ]
            let customizedPreference = CodexExecutionPreference(
                model: .astra,
                reasoningEffort: .low,
                serviceTier: .fast,
                subagentMode: .standard,
                customPresets: allCustomPresets
            )
            let customizedData = try JSONEncoder().encode(customizedPreference.validated())
            guard try JSONDecoder().decode(CodexExecutionPreference.self, from: customizedData) == customizedPreference,
                customizedPreference.effectiveStrategy
                    == .init(
                        mainModel: .terra,
                        mainReasoningEffort: .xhigh,
                        subagentModel: .gpt55,
                        subagentReasoningEffort: .high,
                        maximumConcurrentSubagents: 1
                    )
            else {
                print("Codex profile store self-test failed: three custom presets round trip")
                return false
            }
            var followsSavedModel = customizedPreference
            followsSavedModel.subagentMode = .solLuna
            guard
                try followsSavedModel.validated().effectiveStrategy
                    == .init(
                        mainModel: .astra,
                        mainReasoningEffort: .low,
                        subagentModel: nil,
                        subagentReasoningEffort: nil,
                        maximumConcurrentSubagents: 0
                    )
            else {
                print("Codex profile store self-test failed: custom preset did not follow saved model")
                return false
            }
            var singleOverride = CodexExecutionPreference.defaultValue
            singleOverride.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue] = .init(
                name: "Solo",
                useSavedModel: false,
                model: .terra,
                reasoningEffort: .medium,
                subagentsEnabled: false,
                subagentModel: .gpt52,
                subagentReasoningEffort: .xhigh
            )
            singleOverride.subagentMode = .solLuna
            guard
                try singleOverride.validated().effectiveStrategy
                    == .init(
                        mainModel: .terra,
                        mainReasoningEffort: .medium,
                        subagentModel: nil,
                        subagentReasoningEffort: nil,
                        maximumConcurrentSubagents: 0
                    ), singleOverride.preset(for: .standard) == CodexExecutionPreference.defaultPreset(for: .standard),
                singleOverride.restoringDefault(for: .solLuna).customPresets.isEmpty,
                CodexExecutionPreference.defaultValue.customPresets.isEmpty
            else {
                print("Codex profile store self-test failed: single preset override or restore")
                return false
            }
            let incompletePresetJSON = Data(
                #"{"model":"gpt-6-astra","reasoningEffort":"low","serviceTier":"default","subagentMode":"standard","customPresets":{"standard":{"useSavedModel":true}}}"#.utf8
            )
            do {
                _ = try JSONDecoder().decode(CodexExecutionPreference.self, from: incompletePresetJSON)
                print("Codex profile store self-test failed: incomplete custom preset accepted")
                return false
            } catch DecodingError.keyNotFound {} catch {
                print("Codex profile store self-test failed: incomplete preset wrong error")
                return false
            }
            func expectsInvalid(_ preference: CodexExecutionPreference) -> Bool {
                (try? preference.validated()) == nil
            }
            var invalidCustom = singleOverride
            invalidCustom.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue]?.name = String(repeating: "a", count: 65)
            guard expectsInvalid(invalidCustom) else {
                print("Codex profile store self-test failed: 65-byte preset name accepted")
                return false
            }
            for invalidName in ["", " padded", "line\nbreak", String(repeating: "界", count: 22)] {
                invalidCustom = singleOverride
                invalidCustom.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue]?.name = invalidName
                guard expectsInvalid(invalidCustom) else {
                    print("Codex profile store self-test failed: invalid preset name accepted")
                    return false
                }
            }
            invalidCustom = singleOverride
            invalidCustom.customPresets["unknown"] = allCustomPresets[CodexExecutionPreference.SubagentMode.standard.rawValue]
            guard expectsInvalid(invalidCustom) else {
                print("Codex profile store self-test failed: unknown custom preset key accepted")
                return false
            }
            invalidCustom = singleOverride
            invalidCustom.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue]?.model = .luna
            invalidCustom.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue]?.reasoningEffort = .ultra
            guard expectsInvalid(invalidCustom) else {
                print("Codex profile store self-test failed: unsupported custom main effort accepted")
                return false
            }
            invalidCustom = singleOverride
            invalidCustom.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue]?.subagentModel = .gpt55
            invalidCustom.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue]?.subagentReasoningEffort = .max
            guard expectsInvalid(invalidCustom) else {
                print("Codex profile store self-test failed: unsupported custom child effort accepted")
                return false
            }
            var invalidFastMain = singleOverride
            invalidFastMain.serviceTier = .fast
            invalidFastMain.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue]?.model = .gpt52
            guard expectsInvalid(invalidFastMain) else {
                print("Codex profile store self-test failed: Fast unsupported custom main accepted")
                return false
            }
            var fastWithDisabledChild = singleOverride
            fastWithDisabledChild.serviceTier = .fast
            guard (try? fastWithDisabledChild.validated()) != nil else {
                print("Codex profile store self-test failed: disabled child incorrectly blocked Fast")
                return false
            }
            var invalidFastChild = invalidFastMain
            invalidFastChild.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue]?.model = .terra
            invalidFastChild.customPresets[CodexExecutionPreference.SubagentMode.solLuna.rawValue]?.subagentsEnabled = true
            guard expectsInvalid(invalidFastChild) else {
                print("Codex profile store self-test failed: Fast unsupported custom child accepted")
                return false
            }
            do {
                let unsupported = try JSONDecoder().decode(
                    CodexExecutionPreference.self,
                    from: Data(#"{"model":"gpt-6-astra","reasoningEffort":"low","serviceTier":"default","subagentMode":"unknown"}"#.utf8)
                )
                let encoded = try JSONEncoder().encode(unsupported)
                guard try JSONDecoder().decode(CodexExecutionPreference.self, from: encoded) == unsupported,
                    unsupported.subagentMode.rawValue == "unknown", unsupported.savedModelSettingsAreValid
                else { return false }
                _ = try unsupported.validated()
                print("Codex profile store self-test failed: unknown subagent mode accepted")
                return false
            } catch CodexExecutionPreferenceError.unsupportedExecutionMode {}
            for mode in CodexExecutionPreference.SubagentMode.allCases {
                for effort in CodexExecutionPreference.ReasoningEffort.allCases {
                    for tier in CodexExecutionPreference.ServiceTier.allCases {
                        let astra = CodexExecutionPreference(
                            model: .astra,
                            reasoningEffort: effort,
                            serviceTier: tier,
                            subagentMode: mode
                        )
                        let encoded = try JSONEncoder().encode(astra.validated())
                        guard try JSONDecoder().decode(CodexExecutionPreference.self, from: encoded) == astra else {
                            print("Codex profile store self-test failed: execution preference round trip")
                            return false
                        }
                    }
                }
            }
            guard !invalidPreference.isValid else {
                print("Codex profile store self-test failed: invalid execution preference accepted")
                return false
            }
            // Both single-profile and bulk actions must report persistence
            // failures; a failed callback must never produce a saved draft.
            for bulk in [false, true] {
                var called = false
                let failed = ExecutionPreferenceSave.save(.defaultValue, applyToAll: bulk) { _, all in
                    called = all == bulk
                    return .failure(CodexExecutionPreferenceError.profileMissing)
                }
                guard called, case .failure(let error) = failed,
                    error as? CodexExecutionPreferenceError == .profileMissing
                else { return false }
                let saved = ExecutionPreferenceSave.save(.defaultValue, applyToAll: bulk) { _, all in
                    all == bulk ? .success(()) : .failure(CodexExecutionPreferenceError.profileMissing)
                }
                guard try saved.get() == .defaultValue else { return false }
                var invalidWasPersisted = false
                let invalid = ExecutionPreferenceSave.save(invalidPreference, applyToAll: bulk) { _, _ in
                    invalidWasPersisted = true
                    return .success(())
                }
                guard !invalidWasPersisted, case .failure = invalid else { return false }
                do {
                    try first.setExecutionPreference(.defaultValue, for: "missing-profile", applyToAll: bulk)
                    return false
                } catch CodexExecutionPreferenceError.profileMissing {}
            }
            do {
                try first.setExecutionPreference(.defaultValue, for: "system")
                print("Codex profile store self-test failed: system execution preference accepted")
                return false
            } catch CodexExecutionPreferenceError.systemProfileUnsupported {
            } catch {
                print("Codex profile store self-test failed: unexpected system preference error")
                return false
            }

            try first.record(managedSnapshot, for: added.id)
            let duplicate = try first.addManagedProfile()
            try first.record(managedSnapshot, for: duplicate.id)
            try first.setPrioritizeDispatch(true, for: added.id)
            guard
                CodexProfile.prioritizesDispatch(added.id, among: first.profiles),
                CodexProfile.prioritizesDispatch(duplicate.id, among: first.profiles)
            else {
                print("Codex profile store self-test failed: dispatch priority propagation")
                return false
            }
            let fastPreference = CodexExecutionPreference(
                model: .terra,
                reasoningEffort: .ultra,
                serviceTier: .fast,
                subagentMode: .solLuna
            )
            guard
                fastPreference.effectiveStrategy
                    == .init(
                        mainModel: .sol,
                        mainReasoningEffort: .high,
                        subagentModel: .luna,
                        subagentReasoningEffort: .max,
                        maximumConcurrentSubagents: 1
                    )
            else {
                print("Codex profile store self-test failed: Sol/Luna effective strategy")
                return false
            }
            var independentlyUpdated = fastPreference
            independentlyUpdated.model = .astra
            independentlyUpdated.reasoningEffort = .low
            independentlyUpdated.serviceTier = .standard
            guard independentlyUpdated.subagentMode == .solLuna else {
                print("Codex profile store self-test failed: independent settings lost subagent mode")
                return false
            }
            var modeUpdated = CodexExecutionPreference.defaultValue
            modeUpdated.subagentMode = .lunaDirect
            guard modeUpdated.model == .astra,
                modeUpdated.reasoningEffort == .low,
                modeUpdated.serviceTier == .standard
            else {
                print("Codex profile store self-test failed: subagent mode changed saved defaults")
                return false
            }
            try first.setExecutionPreference(fastPreference, for: added.id)
            let addedAccountKey = first.profiles.first(where: { $0.id == added.id })?.recordedAccountKey
            let matchingPreferences = first.profiles
                .filter { !$0.isSystemProfile && $0.recordedAccountKey == addedAccountKey }
                .allSatisfy { $0.effectiveExecutionPreference == fastPreference }
            guard addedAccountKey != nil,
                matchingPreferences,
                first.profiles.first(where: \.isSystemProfile)?.executionPreference == nil
            else {
                print("Codex profile store self-test failed: account execution preference propagation")
                return false
            }
            let standardPreference = CodexExecutionPreference(
                model: .gpt55,
                reasoningEffort: .medium,
                serviceTier: .standard,
                subagentMode: .lunaDirect
            )
            guard
                standardPreference.effectiveStrategy
                    == .init(
                        mainModel: .luna,
                        mainReasoningEffort: .max,
                        subagentModel: nil,
                        subagentReasoningEffort: nil,
                        maximumConcurrentSubagents: 0
                    ),
                CodexExecutionPreference.defaultValue.effectiveStrategy
                    == .init(
                        mainModel: .astra,
                        mainReasoningEffort: .low,
                        subagentModel: nil,
                        subagentReasoningEffort: nil,
                        maximumConcurrentSubagents: 0
                    )
            else {
                print("Codex profile store self-test failed: direct effective strategies")
                return false
            }
            try first.setExecutionPreference(standardPreference, for: duplicate.id, applyToAll: true)
            guard
                first.profiles.filter({ !$0.isSystemProfile }).allSatisfy({
                    $0.effectiveExecutionPreference == standardPreference
                })
            else {
                print("Codex profile store self-test failed: apply execution preference to all")
                return false
            }
            let reloadedSequential = CodexProfileStore(homeDirectory: home, applicationSupportDirectory: support)
            guard
                reloadedSequential.profiles.filter({ !$0.isSystemProfile }).allSatisfy({
                    $0.effectiveExecutionPreference == standardPreference
                })
            else {
                print("Codex profile store self-test failed: subagent mode profile round trip")
                return false
            }
            let astraPreference = CodexExecutionPreference(model: .astra, reasoningEffort: .max, serviceTier: .fast)
            try first.setExecutionPreference(astraPreference, for: added.id, applyToAll: true)
            let reloadedAstra = CodexProfileStore(homeDirectory: home, applicationSupportDirectory: support)
            guard
                reloadedAstra.profiles.filter({ !$0.isSystemProfile }).allSatisfy({
                    $0.effectiveExecutionPreference == astraPreference
                })
            else {
                print("Codex profile store self-test failed: Astra persistence and apply to all")
                return false
            }
            try first.setExecutionPreference(standardPreference, for: added.id, applyToAll: true)
            try first.discardManagedProfile(duplicate.id)

            let standardCommand = try TerminalAppLauncher.configuredCodexCommand(
                executable: "/usr/local/bin/codex",
                preference: .defaultValue
            )
            let fastCommand = try TerminalAppLauncher.configuredCodexCommand(
                executable: "/usr/local/bin/codex",
                preference: fastPreference,
                roleURL: URL(fileURLWithPath: "/fixture/next_preset_worker.toml")
            )
            guard standardCommand.contains("--model 'gpt-6-astra'"),
                standardCommand.contains("'agents.default_subagent_model=\"gpt-6-astra\"'"),
                standardCommand.contains("'agents.default_subagent_reasoning_effort=\"low\"'"),
                standardCommand.contains("'service_tier=\"default\"'"), standardCommand.contains("--disable fast_mode"),
                standardCommand.contains("'agents.enabled=false'"),
                fastCommand.contains("--model 'gpt-5.6-sol'"),
                fastCommand.contains("'model_reasoning_effort=\"high\"'"),
                fastCommand.contains("'agents.default_subagent_model=\"gpt-5.6-luna\"'"),
                fastCommand.contains("'agents.default_subagent_reasoning_effort=\"max\"'"),
                fastCommand.contains("'service_tier=\"fast\"'"), fastCommand.contains("--enable fast_mode")
            else {
                print("Codex profile store self-test failed: terminal execution preference command")
                return false
            }
            let official = CodexOfficialProfileSnapshot(
                accountEmail: "managed@example.com",
                displayName: "Managed",
                username: "managed",
                lifetimeTokens: 667_817_039,
                peakDailyTokens: 147_276_193,
                planType: "plus",
                subscriptionActiveUntil: Date(timeIntervalSince1970: 400),
                statsAsOf: Date(timeIntervalSince1970: 300),
                fetchedAt: Date(timeIntervalSince1970: 350)
            )
            try first.recordOfficialProfile(official, for: added.id)
            guard let membershipProfile = first.profiles.first(where: { $0.id == added.id }),
                testMembershipRefreshPolicy(membershipProfile)
            else { return false }
            let staleOfficial = CodexOfficialProfileSnapshot(
                accountEmail: official.accountEmail, displayName: nil, username: nil,
                lifetimeTokens: nil, peakDailyTokens: nil, planType: "plus",
                subscriptionActiveUntil: Date(timeIntervalSince1970: 1), statsAsOf: nil,
                fetchedAt: official.fetchedAt.addingTimeInterval(-1)
            )
            try first.recordOfficialProfile(staleOfficial, for: added.id)
            try first.recordMembershipRefresh(at: Date(timeIntervalSince1970: 360), succeeded: true, for: added.id)
            try first.recordMembershipRefresh(at: Date(timeIntervalSince1970: 359), succeeded: false, for: added.id)
            let membershipReload = CodexProfileStore(homeDirectory: home, applicationSupportDirectory: support)
            guard let savedMembership = membershipReload.profiles.first(where: { $0.id == added.id }),
                savedMembership.officialProfile == official,
                savedMembership.lastMembershipRefreshAt == Date(timeIntervalSince1970: 360),
                savedMembership.lastMembershipRefreshSucceeded == true
            else {
                print("Codex profile store self-test failed: membership persistence and stale result ordering")
                return false
            }
            try first.recordWarmUp(at: Date(timeIntervalSince1970: 360), succeeded: true, for: added.id)
            try first.setRemark(" 工作账号 ", for: added.id)
            guard let chromeProfile = ChromeProfileBinding(directoryName: "Profile 2", displayName: "工作") else {
                print("Codex profile store self-test failed: Chrome profile validation")
                return false
            }
            try first.setChromeProfile(chromeProfile, for: added.id)
            try first.setAutomaticSwitchParticipation(false, for: added.id)
            try first.setProTierMultiplier(20, for: added.id)
            try first.record(managedSnapshot, for: added.id)
            try first.record(firstSnapshot, for: "system")
            try first.record(secondSnapshot, for: "system")
            guard first.profiles.first(where: { $0.id == "system" })?.lastSnapshot?.email == "first@example.com" else {
                print("Codex profile store self-test failed: account identity overwrite")
                return false
            }
            let systemOfficial = CodexOfficialProfileSnapshot(
                accountEmail: "first@example.com",
                displayName: "System",
                username: "system",
                lifetimeTokens: 100,
                peakDailyTokens: 50,
                planType: "plus",
                subscriptionActiveUntil: Date(timeIntervalSince1970: 400),
                statsAsOf: Date(timeIntervalSince1970: 300),
                fetchedAt: Date(timeIntervalSince1970: 350)
            )
            try first.recordOfficialProfile(systemOfficial, for: "system")
            try first.recordWarmUp(at: Date(timeIntervalSince1970: 360), succeeded: true, for: "system")
            try first.setRemark("旧账号", for: "system")
            try first.record(secondSnapshot, for: "system", allowSystemAccountChange: true)
            guard let reboundSystem = first.profiles.first(where: { $0.id == "system" }),
                reboundSystem.lastSnapshot?.email == "second@example.com",
                reboundSystem.lastSnapshot?.creditBalance == nil,
                reboundSystem.lastSnapshot?.creditBalanceUnlimited == nil,
                reboundSystem.remark == nil,
                reboundSystem.officialProfile == nil,
                reboundSystem.lastWarmUpAt == nil,
                reboundSystem.lastWarmUpSucceeded == nil
            else {
                print("Codex profile store self-test failed: explicit system account rebind")
                return false
            }
            try first.record(managedSnapshot, for: "system", allowSystemAccountChange: true)
            guard try first.selectMonitorForSystemAccount() == added.id else {
                print("Codex profile store self-test failed: current account monitor match")
                return false
            }
            try first.record(firstSnapshot, for: "system", allowSystemAccountChange: true)
            guard first.profiles.first(where: { $0.id == "system" })?.lastSnapshot?.email == managedSnapshot.account?.email else {
                print("Codex profile store self-test failed: late system read must not rebind an older account")
                return false
            }
            // Switching back requires a fresh observation, not replaying the old login snapshot.
            try first.record(
                testSnapshot(email: "first@example.com", usedPercent: 11, at: Date(timeIntervalSince1970: 400), resetCredits: 2),
                for: "system", allowSystemAccountChange: true
            )
            guard try first.selectMonitorForSystemAccount() == "system" else {
                print("Codex profile store self-test failed: current account monitor fallback")
                return false
            }
            try first.selectMonitor(added.id)
            let permissions = (try fileManager.attributesOfItem(atPath: added.codexHomePath)[.posixPermissions] as? NSNumber)?.intValue
            guard permissions == 0o700 else {
                print("Codex profile store self-test failed: directory permissions")
                return false
            }
            let restored = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: home,
                applicationSupportDirectory: support
            )
            guard restored.profiles.count == 2,
                restored.selectedMonitorProfileID == added.id,
                restored.selectedLaunchProfileID == added.id,
                restored.profiles.first(where: { $0.id == added.id })?.remark == "工作账号",
                restored.profiles.first(where: { $0.id == added.id })?.officialProfile == official,
                restored.profiles.first(where: { $0.id == added.id })?.lastWarmUpSucceeded == true,
                restored.profiles.first(where: { $0.id == added.id })?.chromeProfile == chromeProfile,
                restored.profiles.first(where: { $0.id == added.id })?.participatesInAutomaticSwitch == false,
                restored.profiles.first(where: { $0.id == added.id })?.isDispatchPriorityEnabled == true,
                restored.profiles.first(where: { $0.id == added.id })?.displayedProTierMultiplier == 20,
                restored.profiles.first(where: { $0.id == added.id })?.effectiveExecutionPreference
                    == standardPreference,
                restored.profiles.first(where: { $0.id == added.id })?.lastSnapshot?.availableResetCredits == 2,
                restored.profiles.first(where: { $0.id == added.id })?.lastSnapshot?.resetCreditExpiries
                    == [Date(timeIntervalSince1970: 1_300)],
                restored.profiles.first(where: { $0.id == added.id })?.lastSnapshot?.creditBalance == "0",
                restored.profiles.first(where: { $0.id == added.id })?.lastSnapshot?.creditBalanceUnlimited == false,
                !CodexProfile.participatesInAutomaticSwitch(added.id, among: restored.profiles),
                restored.profiles[0].matchesRecordedAccount(email: "FIRST@example.com"),
                !restored.profiles[0].matchesRecordedAccount(email: "other@example.com"),
                CodexProfile.groupsByRecordedAccount([
                    restored.profiles[0], restored.profiles[1], restored.profiles[0],
                ]).count == 2
            else {
                print("Codex profile store self-test failed: persistence")
                return false
            }
            let stateURL =
                support
                .appendingPathComponent("CodexAccountManagerNext", isDirectory: true)
                .appendingPathComponent("account-manager-next-v1.json")
            guard
                var legacyState = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: stateURL)
                ) as? [String: Any],
                let legacyProfiles = legacyState["profiles"] as? [[String: Any]]
            else {
                print("Codex profile store self-test failed: legacy state fixture")
                return false
            }
            legacyState["profiles"] = legacyProfiles.map { profile in
                var profile = profile
                profile.removeValue(forKey: "automaticSwitchParticipation")
                profile.removeValue(forKey: "prioritizeDispatch")
                profile.removeValue(forKey: "proTierMultiplier")
                profile.removeValue(forKey: "executionPreference")
                return profile
            }
            try JSONSerialization.data(withJSONObject: legacyState).write(to: stateURL, options: .atomic)
            let legacyRestored = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: home,
                applicationSupportDirectory: support
            )
            guard legacyRestored.profiles.allSatisfy(\.participatesInAutomaticSwitch),
                legacyRestored.profiles.allSatisfy({ !$0.isDispatchPriorityEnabled }),
                legacyRestored.profiles.allSatisfy({ $0.displayedProTierMultiplier == nil }),
                legacyRestored.profiles.allSatisfy({
                    $0.effectiveExecutionPreference == .defaultValue
                })
            else {
                print("Codex profile store self-test failed: automatic-switch scope migration")
                return false
            }
            var unknownModeProfiles = legacyProfiles
            guard
                let unknownModeIndex = unknownModeProfiles.firstIndex(where: {
                    ($0["isSystemProfile"] as? Bool) == false
                })
            else {
                print("Codex profile store self-test failed: unknown mode fixture")
                return false
            }
            unknownModeProfiles[unknownModeIndex]["executionPreference"] = [
                "model": "gpt-6-astra",
                "reasoningEffort": "low",
                "serviceTier": "default",
                "subagentMode": "future_slot",
            ]
            legacyState["profiles"] = unknownModeProfiles
            try JSONSerialization.data(withJSONObject: legacyState).write(to: stateURL, options: .atomic)
            let unknownModeRestored = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: home,
                applicationSupportDirectory: support
            )
            guard unknownModeRestored.profiles.count == unknownModeProfiles.count,
                let unknownModeProfile = unknownModeRestored.profiles.first(where: {
                    $0.executionPreference?.subagentMode.rawValue == "future_slot"
                })
            else {
                print("Codex profile store self-test failed: unknown mode hid profiles")
                return false
            }
            do {
                _ = try unknownModeProfile.validatedExecutionPreference()
                print("Codex profile store self-test failed: unknown mode profile could start")
                return false
            } catch CodexExecutionPreferenceError.unsupportedExecutionMode {}
            var invalidProfiles = legacyState["profiles"] as? [[String: Any]] ?? []
            guard
                let invalidIndex = invalidProfiles.firstIndex(where: {
                    ($0["isSystemProfile"] as? Bool) == false
                })
            else {
                print("Codex profile store self-test failed: invalid execution preference fixture")
                return false
            }
            invalidProfiles[invalidIndex]["executionPreference"] = [
                "model": "gpt-5.2",
                "reasoningEffort": "ultra",
                "serviceTier": "fast",
            ]
            legacyState["profiles"] = invalidProfiles
            let invalidStateData = try JSONSerialization.data(withJSONObject: legacyState)
            try invalidStateData.write(to: stateURL, options: .atomic)
            let invalidRestored = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: home,
                applicationSupportDirectory: support
            )
            do {
                try invalidRestored.setRemark("must not persist", for: "system")
                print("Codex profile store self-test failed: invalid execution preference mutation was accepted")
                return false
            } catch {}
            guard try Data(contentsOf: stateURL) == invalidStateData else {
                print("Codex profile store self-test failed: invalid execution preference was overwritten")
                return false
            }
            // Repair the deliberately invalid fixture before using a live store
            // again. A stale instance must not be allowed to overwrite it.
            legacyState["profiles"] = legacyProfiles
            try JSONSerialization.data(withJSONObject: legacyState).write(to: stateURL, options: .atomic)
            try restored.moveProfile(added.id, relativeTo: "system", before: true)
            let reordered = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: home,
                applicationSupportDirectory: support
            )
            guard reordered.profiles.map(\.id) == [added.id, "system"] else {
                print("Codex profile store self-test failed: profile ordering")
                return false
            }
            let systemHome = home.appendingPathComponent(".codex", isDirectory: true)
            try fileManager.createDirectory(at: systemHome, withIntermediateDirectories: true)
            let systemAuthPayload = Data(#"{"email":"first@example.com","https://api.openai.com/auth":{"chatgpt_account_id":"acct-first"}}"#.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let systemAuth = Data(
                #"{"tokens":{"access_token":"test-only","refresh_token":"synthetic-refresh","account_id":"acct-first","id_token":"e30.\#(systemAuthPayload).sig"}}"#.utf8)
            try systemAuth.write(to: systemHome.appendingPathComponent("auth.json"))
            let preserved = try reordered.preserveSystemLogin()
            let preservedAuth = try Data(contentsOf: preserved.codexHomeURL.appendingPathComponent("auth.json"))
            let preservedAgain = try reordered.preserveSystemLogin()
            guard preserved.lastSnapshot?.email == "first@example.com",
                preserved.lastSnapshot?.accountID == "acct-first",
                preserved.lastSnapshot?.availableResetCredits == 2,
                preserved.lastSnapshot?.resetCreditExpiries == [Date(timeIntervalSince1970: 1_400)],
                preservedAuth == systemAuth,
                preservedAgain.id == preserved.id,
                reordered.profiles.count == 3,
                reordered.effectiveCredentialHome(for: preserved.id)?.standardizedFileURL
                    == systemHome.standardizedFileURL
            else {
                print("Codex profile store self-test failed: preserve system login")
                return false
            }
            var policyProfile = restored.profiles.first { $0.id == added.id }!
            policyProfile.officialProfile = nil
            policyProfile.lastSnapshot = CodexAccountSnapshot(
                accountType: "chatgpt",
                planType: "plus",
                email: "managed@example.com",
                limitId: "codex",
                limitName: nil,
                fiveHour: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 1,
                        windowDurationMins: 300,
                        resetsAt: Date(timeIntervalSince1970: 18_000)
                    )),
                sevenDay: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 20,
                        windowDurationMins: 10_080,
                        resetsAt: nil
                    )),
                monthly: nil,
                fetchedAt: Date(timeIntervalSince1970: 100),
                appServerVersion: nil
            )
            let now = Date(timeIntervalSince1970: 1_000)
            let fiveHourReset = Date(timeIntervalSince1970: 18_000)
            let sevenDayReset = Date(timeIntervalSince1970: 80_000)
            policyProfile.lastWarmUpAt = nil
            policyProfile.lastWarmUpSucceeded = nil
            let sevenDayOnly = CodexWarmUpSelection(fiveHour: false, sevenDay: true)
            let fiveHourOnly = CodexWarmUpSelection(fiveHour: true, sevenDay: false)
            let bothWindows = CodexWarmUpSelection(fiveHour: true, sevenDay: true)
            guard
                CodexWarmUpPolicy.effectiveSelection(
                    bothWindows,
                    participatesInAutomaticSwitch: false
                ) == bothWindows,
                CodexWarmUpPolicy.effectiveSelection(
                    bothWindows,
                    participatesInAutomaticSwitch: false,
                    unexpected: [.fiveHour]
                ) == bothWindows,
                CodexWarmUpPolicy.effectiveSelection(
                    sevenDayOnly,
                    participatesInAutomaticSwitch: false,
                    unexpected: [.fiveHour]
                ) == sevenDayOnly
            else {
                print("Codex profile store self-test failed: dispatch-independent warm-up selection")
                return false
            }
            policyProfile.lastSnapshot = CodexAccountSnapshot(
                accountType: "chatgpt",
                planType: "plus",
                email: "managed@example.com",
                limitId: "codex",
                limitName: nil,
                fiveHour: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 12,
                        windowDurationMins: 300,
                        resetsAt: fiveHourReset
                    )),
                sevenDay: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 20,
                        windowDurationMins: 10_080,
                        resetsAt: sevenDayReset
                    )),
                monthly: nil,
                fetchedAt: Date(timeIntervalSince1970: 100),
                appServerVersion: nil
            )
            guard
                CodexWarmUpPolicy.nextEligibleDate(for: policyProfile, selection: sevenDayOnly, now: now)
                    == sevenDayReset.addingTimeInterval(CodexWarmUpPolicy.resetGrace)
            else {
                print("Codex profile store self-test failed: 7-day switch waits for weekly reset")
                return false
            }
            guard
                CodexWarmUpPolicy.nextEligibleDate(for: policyProfile, selection: fiveHourOnly, now: now)
                    == fiveHourReset.addingTimeInterval(CodexWarmUpPolicy.resetGrace)
            else {
                print("Codex profile store self-test failed: 5-hour switch waits for 5-hour reset")
                return false
            }
            guard
                CodexWarmUpPolicy.nextEligibleDate(for: policyProfile, selection: bothWindows, now: now)
                    == fiveHourReset.addingTimeInterval(CodexWarmUpPolicy.resetGrace)
            else {
                print("Codex profile store self-test failed: both switches use the earliest reset")
                return false
            }
            guard
                CodexWarmUpPolicy.nextScheduledResetDate(
                    for: policyProfile,
                    selection: bothWindows,
                    now: now
                ) == fiveHourReset.addingTimeInterval(CodexWarmUpPolicy.resetGrace)
            else {
                print("Codex profile store self-test failed: one-shot schedule uses the earliest known reset")
                return false
            }
            var staleMembershipClaim = policyProfile
            staleMembershipClaim.officialProfile = official
            guard
                CodexWarmUpPolicy.nextEligibleDate(
                    for: staleMembershipClaim,
                    selection: bothWindows,
                    now: now
                ) == fiveHourReset.addingTimeInterval(CodexWarmUpPolicy.resetGrace)
            else {
                print("Codex profile store self-test failed: stale membership claim must not override live quota")
                return false
            }
            guard !CodexWarmUpPolicy.isDue(policyProfile, selection: sevenDayOnly, now: now) else {
                print("Codex profile store self-test failed: active 7-day window is not due")
                return false
            }
            var idleWeek = policyProfile
            idleWeek.lastSnapshot = CodexAccountSnapshot(
                accountType: "chatgpt",
                planType: "plus",
                email: "managed@example.com",
                limitId: "codex",
                limitName: nil,
                fiveHour: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 0,
                        windowDurationMins: 300,
                        resetsAt: Date(timeIntervalSince1970: 500)
                    )),
                sevenDay: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 0,
                        windowDurationMins: 10_080,
                        resetsAt: Date(timeIntervalSince1970: 500)
                    )),
                monthly: nil,
                fetchedAt: Date(timeIntervalSince1970: 100),
                appServerVersion: nil
            )
            guard CodexWarmUpPolicy.isDue(idleWeek, selection: sevenDayOnly, now: now) else {
                print("Codex profile store self-test failed: idle 7-day window should warm immediately")
                return false
            }
            guard CodexWarmUpPolicy.isDue(idleWeek, selection: fiveHourOnly, now: now) else {
                print("Codex profile store self-test failed: idle 5-hour window should warm immediately")
                return false
            }
            guard
                CodexWarmUpPolicy.nextScheduledResetDate(
                    for: idleWeek,
                    selection: bothWindows,
                    now: now
                ) == nil
            else {
                print("Codex profile store self-test failed: past reset must not create an automatic retry timer")
                return false
            }
            var unknownWeek = policyProfile
            unknownWeek.lastSnapshot = CodexAccountSnapshot(
                accountType: "chatgpt",
                planType: "plus",
                email: "managed@example.com",
                limitId: "codex",
                limitName: nil,
                fiveHour: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 12,
                        windowDurationMins: 300,
                        resetsAt: fiveHourReset
                    )),
                sevenDay: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 20,
                        windowDurationMins: 10_080,
                        resetsAt: nil
                    )),
                monthly: nil,
                fetchedAt: Date(timeIntervalSince1970: 100),
                appServerVersion: nil
            )
            guard CodexWarmUpPolicy.nextEligibleDate(for: unknownWeek, selection: sevenDayOnly, now: now) == nil else {
                print("Codex profile store self-test failed: unknown weekly reset should wait for a drop")
                return false
            }
            let previousWeek = unknownWeek.lastSnapshot?.sevenDay
            let droppedWeek = CodexQuotaWindowSnapshot(
                RateWindow(
                    usedPercent: 0,
                    windowDurationMins: 10_080,
                    resetsAt: nil
                ))
            guard CodexWarmUpPolicy.didResetUnexpectedly(previous: previousWeek, current: droppedWeek, now: now) else {
                print("Codex profile store self-test failed: weekly used-percent drop is an unexpected reset")
                return false
            }
            var afterDrop = unknownWeek
            afterDrop.lastSnapshot = CodexAccountSnapshot(
                accountType: "chatgpt",
                planType: "plus",
                email: "managed@example.com",
                limitId: "codex",
                limitName: nil,
                fiveHour: unknownWeek.lastSnapshot?.fiveHour,
                sevenDay: droppedWeek,
                monthly: nil,
                fetchedAt: Date(timeIntervalSince1970: 100),
                appServerVersion: nil
            )
            guard CodexWarmUpPolicy.isDue(afterDrop, selection: sevenDayOnly, now: now) else {
                print("Codex profile store self-test failed: idle 7-day window after a drop should warm immediately")
                return false
            }
            guard !CodexWarmUpPolicy.isDue(afterDrop, selection: fiveHourOnly, now: now) else {
                print("Codex profile store self-test failed: 5-hour switch must ignore a 7-day-only drop")
                return false
            }
            var lowWeekly = policyProfile
            lowWeekly.lastSnapshot = CodexAccountSnapshot(
                accountType: "chatgpt",
                planType: "plus",
                email: "managed@example.com",
                limitId: "codex",
                limitName: nil,
                fiveHour: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 0,
                        windowDurationMins: 300,
                        resetsAt: Date(timeIntervalSince1970: 500)
                    )),
                sevenDay: CodexQuotaWindowSnapshot(
                    RateWindow(
                        usedPercent: 100,
                        windowDurationMins: 10_080,
                        resetsAt: sevenDayReset
                    )),
                monthly: nil,
                fetchedAt: Date(timeIntervalSince1970: 100),
                appServerVersion: nil
            )
            guard CodexWarmUpPolicy.shouldSkipFiveHourToProtectWeekly(lowWeekly, now: now) else {
                print("Codex profile store self-test failed: 5-hour warm-up waits for exhausted weekly limits")
                return false
            }
            guard CodexWarmUpPolicy.nextEligibleDate(for: lowWeekly, selection: fiveHourOnly, now: now) == nil else {
                print("Codex profile store self-test failed: 5-hour switch waits when weekly limits are exhausted")
                return false
            }
            guard
                CodexWarmUpPolicy.nextScheduledResetDate(
                    for: lowWeekly,
                    selection: fiveHourOnly,
                    now: now
                ) == sevenDayReset.addingTimeInterval(CodexWarmUpPolicy.resetGrace)
            else {
                print("Codex profile store self-test failed: 5-hour warm-up resumes at its own weekly reset")
                return false
            }
            guard
                CodexWarmUpPolicy.nextEligibleDate(for: lowWeekly, selection: sevenDayOnly, now: now)
                    == nil,
                !CodexWarmUpPolicy.canSendWarmUpRequest(lowWeekly, now: now)
            else {
                print("Codex profile store self-test failed: exhausted weekly quota must block every warm-up request")
                return false
            }
            for balance: String? in [nil, "0", "125.75"] {
                var exhausted = idleWeek
                exhausted.lastSnapshot = CodexAccountSnapshot(
                    accountType: "chatgpt", planType: "plus", email: "managed@example.com",
                    limitId: "codex", limitName: nil,
                    fiveHour: CodexQuotaWindowSnapshot(
                        RateWindow(
                            usedPercent: 100, windowDurationMins: 300, resetsAt: now.addingTimeInterval(-10))),
                    sevenDay: idleWeek.lastSnapshot?.sevenDay, monthly: nil,
                    availableResetCredits: balance == nil ? nil : 3,
                    creditBalance: balance,
                    fetchedAt: now, appServerVersion: nil)
                guard !CodexWarmUpPolicy.canSendWarmUpRequest(exhausted, now: now),
                    !CodexWarmUpPolicy.isDue(exhausted, selection: sevenDayOnly, unexpected: [.sevenDay], now: now),
                    CodexWarmUpPolicy.nextEligibleDate(for: exhausted, selection: bothWindows, now: now) == nil,
                    CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: exhausted, now: now) != nil
                else {
                    print("Codex profile store self-test failed: a balance or elapsed reset must not unlock an exhausted 5-hour window")
                    return false
                }
            }
            guard CodexWarmUpPolicy.canSendWarmUpRequest(idleWeek, now: now),
                !CodexWarmUpPolicy.canSendWarmUpRequest(
                    idleWeek, now: now.addingTimeInterval(CodexWarmUpPolicy.maximumQuotaAge + 1))
            else {
                print("Codex profile store self-test failed: warm-up resumes only with fresh recovered quota")
                return false
            }
            guard CodexWarmUpPolicy.hasFreshQuotaEvidence(idleWeek, now: now),
                !CodexWarmUpPolicy.isDue(
                    idleWeek,
                    selection: fiveHourOnly,
                    now: now.addingTimeInterval(CodexWarmUpPolicy.maximumQuotaAge + 1)
                )
            else {
                print("Codex profile store self-test failed: stale quota evidence must block warm-up")
                return false
            }
            policyProfile.lastWarmUpAt = Date(timeIntervalSince1970: 1_000)
            policyProfile.lastWarmUpSucceeded = false
            guard !CodexWarmUpPolicy.isDue(policyProfile, selection: sevenDayOnly, now: Date(timeIntervalSince1970: 1_100)) else {
                print("Codex profile store self-test failed: warm-up retry cooldown")
                return false
            }
            idleWeek.lastWarmUpAt = Date(timeIntervalSince1970: 980)
            idleWeek.lastWarmUpSucceeded = true
            guard
                CodexWarmUpPolicy.nextEligibleDate(for: idleWeek, selection: sevenDayOnly, now: now)
                    == Date(timeIntervalSince1970: 980 + CodexWarmUpPolicy.sevenDaySuccessInterval + CodexWarmUpPolicy.resetGrace),
                CodexWarmUpPolicy.nextEligibleDate(for: idleWeek, selection: fiveHourOnly, now: now)
                    == Date(timeIntervalSince1970: 980 + CodexWarmUpPolicy.fiveHourSuccessInterval + CodexWarmUpPolicy.resetGrace),
                CodexWarmUpPolicy.nextEligibleDate(
                    for: idleWeek,
                    selection: fiveHourOnly,
                    unexpected: [.fiveHour],
                    now: now
                ) == Date(timeIntervalSince1970: 980 + CodexWarmUpPolicy.fiveHourSuccessInterval + CodexWarmUpPolicy.resetGrace)
            else {
                print("Codex profile store self-test failed: successful warm-up interval")
                return false
            }
            // Reproduce a cold account whose official reset slides on every read.
            func changedQuota(_ profile: CodexProfile, changes: (inout [String: Any]) -> Void) throws -> CodexProfile {
                var result = profile
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile.lastSnapshot!)) as! [String: Any]
                changes(&object)
                result.lastSnapshot = try JSONDecoder().decode(CodexAccountSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
                return result
            }
            var cold = try changedQuota(idleWeek) { snapshot in
                snapshot["fetchedAt"] = now.timeIntervalSinceReferenceDate
                for key in ["fiveHour", "sevenDay"] {
                    var window = snapshot[key] as! [String: Any]
                    window["resetsAt"] = now.addingTimeInterval(key == "fiveHour" ? 18_000 : 604_800).timeIntervalSinceReferenceDate
                    snapshot[key] = window
                }
            }
            cold.lastWarmUpAt = now.addingTimeInterval(-18_100)
            cold.lastWarmUpSucceeded = true
            cold.automaticSwitchParticipation = false
            guard CodexWarmUpPolicy.isDue(cold, selection: fiveHourOnly, now: now),
                !CodexWarmUpPolicy.isDue(cold, selection: sevenDayOnly, now: now)
            else {
                print("Codex profile store self-test failed: cold sliding reset must not postpone dispatch-independent warm-up")
                return false
            }
            cold = try changedQuota(cold) { snapshot in
                var window = snapshot["fiveHour"] as! [String: Any]
                window["resetsAt"] = now.addingTimeInterval(36_000).timeIntervalSinceReferenceDate
                snapshot["fiveHour"] = window
            }
            guard CodexWarmUpPolicy.isDue(cold, selection: fiveHourOnly, now: now) else {
                print("Codex profile store self-test failed: a later reported reset cannot move the cold-account deadline")
                return false
            }
            var retry = cold
            retry.lastWarmUpAt = now.addingTimeInterval(-20)
            retry.lastWarmUpSucceeded = false
            let retryAt = retry.lastWarmUpAt!.addingTimeInterval(
                CodexWarmUpPolicy.fiveHourSuccessInterval + CodexWarmUpPolicy.resetGrace)
            guard CodexWarmUpPolicy.nextEligibleDate(for: retry, selection: bothWindows, unexpected: [.fiveHour], now: now) == nil,
                !CodexWarmUpPolicy.isDue(retry, selection: bothWindows, now: now),
                !CodexWarmUpPolicy.isDue(retry, selection: bothWindows, now: retryAt)
            else {
                print("Codex profile store self-test failed: failed warm-up waits for the next selected window")
                return false
            }
            let exhaustedRetry = try changedQuota(retry) { snapshot in
                var weekly = snapshot["sevenDay"] as! [String: Any]
                weekly["usedPercent"] = 100
                snapshot["sevenDay"] = weekly
            }
            guard !CodexWarmUpPolicy.isDue(exhaustedRetry, selection: bothWindows, now: retryAt),
                CodexWarmUpPolicy.nextEligibleDate(for: exhaustedRetry, selection: bothWindows, now: retryAt)
                    == nil
            else {
                print("Codex profile store self-test failed: a failed idle window must not bypass an exhausted weekly window")
                return false
            }
            let missingReadFlag = try changedQuota(cold) { $0.removeValue(forKey: "quotaReadSucceeded") }
            var equalFailure = cold
            equalFailure.lastQuotaReadFailureAt = now
            var newerFailure = cold
            newerFailure.lastSnapshot = CodexAccountSnapshot(
                accountType: "chatgpt",
                planType: "plus",
                email: "managed@example.com",
                accountID: "acct-warm",
                limitId: "codex",
                limitName: nil,
                fiveHour: CodexQuotaWindowSnapshot(
                    RateWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: nil)),
                sevenDay: CodexQuotaWindowSnapshot(
                    RateWindow(usedPercent: 0, windowDurationMins: 10_080, resetsAt: nil)),
                monthly: nil,
                fetchedAt: now.addingTimeInterval(-1),
                appServerVersion: nil
            )
            newerFailure.lastQuotaReadFailureAt = now
            guard !CodexWarmUpPolicy.hasFreshQuotaEvidence(missingReadFlag, now: now),
                !CodexWarmUpPolicy.hasFreshQuotaEvidence(equalFailure, now: now),
                !CodexWarmUpPolicy.canSendWarmUpRequest(newerFailure, now: now)
            else {
                print("Codex profile store self-test failed: missing success evidence and a newer failed read must block a request")
                return false
            }
            let lowButAvailable = try changedQuota(cold) { snapshot in
                var weekly = snapshot["sevenDay"] as! [String: Any]
                weekly["usedPercent"] = 97
                snapshot["sevenDay"] = weekly
            }
            guard !CodexWarmUpPolicy.shouldSkipFiveHourToProtectWeekly(lowButAvailable, now: now),
                CodexWarmUpPolicy.isDue(lowButAvailable, selection: fiveHourOnly, now: now)
            else {
                print("Codex profile store self-test failed: dispatch quota reserves must not stop available warm-up")
                return false
            }
            let payload = try JSONSerialization.data(withJSONObject: [
                "https://api.openai.com/auth": [
                    "chatgpt_plan_type": "plus",
                    "chatgpt_subscription_active_until": "2026-08-18T09:29:34+00:00",
                ]
            ])
            let encoded = payload.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let subscription = CodexOfficialProfileReader.subscription(fromIDToken: "x.\(encoded).y")
            guard subscription?.planType == "plus", subscription?.activeUntil != nil else {
                print("Codex profile store self-test failed: subscription claims")
                return false
            }
            let identityClaims = try JSONSerialization.data(withJSONObject: [
                "email": "identity@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": "acct-identity"],
            ])
            let identityPayload = identityClaims.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let identityToken = "x.\(identityPayload).y"
            let validIdentityAuth = try JSONSerialization.data(withJSONObject: [
                "tokens": [
                    "access_token": identityToken,
                    "id_token": identityToken,
                    "account_id": "acct-identity",
                ]
            ])
            let mismatchedIdentityAuth = try JSONSerialization.data(withJSONObject: [
                "tokens": [
                    "access_token": identityToken,
                    "id_token": identityToken,
                    "account_id": "acct-other",
                ]
            ])
            guard
                CodexOfficialProfileReader.credentialIdentity(fromAuthData: validIdentityAuth)
                    == CodexCredentialIdentity(email: "identity@example.com", accountID: "acct-identity"),
                CodexOfficialProfileReader.credentialIdentity(fromAuthData: mismatchedIdentityAuth) == nil
            else {
                print("Codex profile store self-test failed: stable account identity binding")
                return false
            }
            // 重置卡计数：自然滚动不计；同窗口额度回落与提前开新窗口计次；手动校正后系统卡与管理卡共享
            let resetHome = root.appendingPathComponent("reset-home", isDirectory: true)
            let resetSupport = root.appendingPathComponent("reset-support", isDirectory: true)
            let resetStore = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: resetHome,
                applicationSupportDirectory: resetSupport
            )
            let resetAccount = try resetStore.addManagedProfile()
            let week: TimeInterval = 604_800
            let base = Date(timeIntervalSince1970: 1_000_000)
            try resetStore.record(
                testResetSnapshot(
                    email: "reset@example.com",
                    usedPercent: 80,
                    resetsAt: base.addingTimeInterval(week),
                    fetchedAt: base
                ), for: resetAccount.id)
            try resetStore.record(
                testResetSnapshot(
                    email: "reset@example.com",
                    usedPercent: 50,
                    resetsAt: base.addingTimeInterval(week * 2),
                    fetchedAt: base.addingTimeInterval(week + 60)
                ), for: resetAccount.id)
            func resetCounterOf(_ store: CodexProfileStore) -> CodexAccountResetCounter {
                let key = store.profiles.first { $0.id == resetAccount.id }?.recordedAccountKey ?? ""
                return store.resetCounter(accountKey: key)
            }
            guard resetCounterOf(resetStore).automaticCount == 0 else {
                print("Codex profile store self-test failed: natural rollover must not count as reset")
                return false
            }
            try resetStore.record(
                testResetSnapshot(
                    email: "reset@example.com",
                    usedPercent: 5,
                    resetsAt: base.addingTimeInterval(week * 2),
                    fetchedAt: base.addingTimeInterval(week + 120)
                ), for: resetAccount.id)
            guard resetCounterOf(resetStore).automaticCount == 1 else {
                print("Codex profile store self-test failed: same-window quota restore should count")
                return false
            }
            try resetStore.record(
                testResetSnapshot(
                    email: "reset@example.com",
                    usedPercent: 90,
                    resetsAt: base.addingTimeInterval(week * 2),
                    fetchedAt: base.addingTimeInterval(week + 180)
                ), for: resetAccount.id)
            try resetStore.record(
                testResetSnapshot(
                    email: "reset@example.com",
                    usedPercent: 3,
                    resetsAt: base.addingTimeInterval(week * 2 - 86_400 + week),
                    fetchedAt: base.addingTimeInterval(week * 2 - 86_400)
                ), for: resetAccount.id)
            guard resetCounterOf(resetStore).automaticCount == 2 else {
                print("Codex profile store self-test failed: early new window should count")
                return false
            }
            guard
                resetCounterOf(resetStore).cardExpiresAt
                    == base.addingTimeInterval(week * 2 - 86_400 + week)
            else {
                print("Codex profile store self-test failed: counted reset should capture window end as expiry")
                return false
            }
            try resetStore.record(
                testResetSnapshot(
                    email: "reset@example.com",
                    usedPercent: 70,
                    resetsAt: base.addingTimeInterval(week * 2 - 86_400 + week),
                    fetchedAt: base.addingTimeInterval(week * 2 - 86_400 + 60)
                ), for: resetAccount.id)
            let resetKey = resetStore.profiles.first { $0.id == resetAccount.id }!.recordedAccountKey
            try resetStore.adjustResetManualOffset(accountKey: resetKey, delta: 1)
            guard resetStore.resetCounter(accountKey: resetKey).total == 3 else {
                print("Codex profile store self-test failed: manual offset should add to total")
                return false
            }
            try resetStore.adjustResetManualOffset(accountKey: resetKey, delta: -1)
            try resetStore.record(
                testResetSnapshot(
                    email: "reset@example.com",
                    usedPercent: 70,
                    resetsAt: base.addingTimeInterval(week * 2 - 86_400 + week),
                    fetchedAt: base.addingTimeInterval(week * 2 - 86_400 + 120)
                ), for: "system")
            guard resetStore.resetCounter(accountKey: resetKey).total == 2 else {
                print("Codex profile store self-test failed: counter must be shared by account, not by card")
                return false
            }
            try resetStore.record(
                testResetSnapshot(
                    email: "reset@example.com",
                    usedPercent: 4,
                    resetsAt: base.addingTimeInterval(week * 2 - 86_400 + week),
                    fetchedAt: base.addingTimeInterval(week * 2 - 86_400 + 180)
                ), for: "system")
            guard resetStore.resetCounter(accountKey: resetKey).total == 3 else {
                print("Codex profile store self-test failed: reset recorded via system card must land on shared counter")
                return false
            }
            let expiry = Date(timeIntervalSince1970: 1_900_000_000)
            try resetStore.setResetCardExpiry(accountKey: resetKey, date: expiry)
            guard resetStore.resetCounter(accountKey: resetKey).cardExpiresAt == expiry else {
                print("Codex profile store self-test failed: reset card expiry roundtrip")
                return false
            }
            try resetStore.setResetCardExpiry(accountKey: resetKey, date: nil)
            guard resetStore.resetCounter(accountKey: resetKey).cardExpiresAt == nil else {
                print("Codex profile store self-test failed: reset card expiry clear")
                return false
            }
            let manualExpiry = Date(timeIntervalSince1970: 1_950_000_000)
            try resetStore.adjustResetManualOffset(
                accountKey: resetKey,
                delta: 1,
                fallbackExpiry: manualExpiry
            )
            guard resetStore.resetCounter(accountKey: resetKey).cardExpiresAt == manualExpiry else {
                print("Codex profile store self-test failed: manual adjustment should fill expiry fallback")
                return false
            }
            // 回填：还原部署计数功能之前的历史重置，幂等且不误计自然滚动
            let backfillHome = root.appendingPathComponent("backfill-home", isDirectory: true)
            let backfillSupport = root.appendingPathComponent("backfill-support", isDirectory: true)
            let backfillStore = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: backfillHome,
                applicationSupportDirectory: backfillSupport
            )
            let backfillAccount = try backfillStore.addManagedProfile()
            let backfillWeek: TimeInterval = 604_800
            let backfillBase = Date(timeIntervalSince1970: 2_000_000)
            try backfillStore.record(
                testResetSnapshot(
                    email: "backfill@example.com",
                    usedPercent: 100,
                    resetsAt: backfillBase.addingTimeInterval(backfillWeek),
                    fetchedAt: backfillBase
                ), for: backfillAccount.id)
            try backfillStore.record(
                testResetSnapshot(
                    email: "backfill@example.com",
                    usedPercent: 23,
                    resetsAt: backfillBase.addingTimeInterval(backfillWeek * 2 + 15_885),
                    fetchedAt: backfillBase.addingTimeInterval(backfillWeek + 15_885)
                ), for: "system")
            let backfillKey = backfillStore.profiles
                .first { $0.id == backfillAccount.id }!
                .recordedAccountKey
            guard backfillStore.resetCounter(accountKey: backfillKey).total == 0 else {
                print("Codex profile store self-test failed: setup snapshots must not trigger live counting")
                return false
            }
            backfillStore.backfillResetCountersFromHistory()
            guard backfillStore.resetCounter(accountKey: backfillKey).total == 1 else {
                print("Codex profile store self-test failed: backfill should restore the historical reset")
                return false
            }
            backfillStore.backfillResetCountersFromHistory()
            guard backfillStore.resetCounter(accountKey: backfillKey).total == 1 else {
                print("Codex profile store self-test failed: backfill must be idempotent")
                return false
            }
            // 同组另一张卡已观察到的新窗口，live 记录不得再计一次
            try backfillStore.record(
                testResetSnapshot(
                    email: "backfill@example.com",
                    usedPercent: 23,
                    resetsAt: backfillBase.addingTimeInterval(backfillWeek * 2 + 15_885),
                    fetchedAt: backfillBase.addingTimeInterval(backfillWeek + 16_000)
                ), for: backfillAccount.id)
            guard backfillStore.resetCounter(accountKey: backfillKey).total == 1 else {
                print("Codex profile store self-test failed: window already observed by group must not double count")
                return false
            }
            let naturalAccount = try backfillStore.addManagedProfile()
            try backfillStore.record(
                testResetSnapshot(
                    email: "natural@example.com",
                    usedPercent: 80,
                    resetsAt: backfillBase.addingTimeInterval(backfillWeek),
                    fetchedAt: backfillBase
                ), for: naturalAccount.id)
            try backfillStore.record(
                testResetSnapshot(
                    email: "natural@example.com",
                    usedPercent: 5,
                    resetsAt: backfillBase.addingTimeInterval(backfillWeek * 2),
                    fetchedAt: backfillBase.addingTimeInterval(backfillWeek + 60)
                ), for: "system", allowSystemAccountChange: true)
            backfillStore.backfillResetCountersFromHistory()
            let naturalKey = backfillStore.profiles
                .first { $0.id == naturalAccount.id }!
                .recordedAccountKey
            guard backfillStore.resetCounter(accountKey: naturalKey).total == 0 else {
                print("Codex profile store self-test failed: natural rollover must stay at zero after backfill")
                return false
            }
            // 同账号同步只接受身份匹配的系统凭据，避免登录切换竞态污染管理卡。
            let syncHome = root.appendingPathComponent("sync-home", isDirectory: true)
            let syncSupport = root.appendingPathComponent("sync-support", isDirectory: true)
            let syncStore = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: syncHome,
                applicationSupportDirectory: syncSupport
            )
            let syncManaged = try syncStore.addManagedProfile()
            let syncSnapshot = testSnapshot(
                email: "sync@example.com",
                usedPercent: 10,
                at: Date(timeIntervalSince1970: 10_000)
            )
            try syncStore.record(syncSnapshot, for: syncManaged.id)
            try syncStore.record(syncSnapshot, for: "system", allowSystemAccountChange: true)
            let syncSystemHome = syncHome.appendingPathComponent(".codex", isDirectory: true)
            try fileManager.createDirectory(at: syncSystemHome, withIntermediateDirectories: true)
            let managedAuthURL = syncManaged.codexHomeURL.appendingPathComponent("auth.json")
            let systemAuthURL = syncSystemHome.appendingPathComponent("auth.json")
            let oldManagedAuth = try testAuthData(email: "sync@example.com", accessToken: "old")
            let freshSystemAuth = try testAuthData(email: "sync@example.com", accessToken: "fresh")
            try oldManagedAuth.write(to: managedAuthURL)
            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 10_000)],
                ofItemAtPath: managedAuthURL.path
            )
            try freshSystemAuth.write(to: systemAuthURL)
            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 20_000)],
                ofItemAtPath: systemAuthURL.path
            )
            try syncStore.record(syncSnapshot, for: syncManaged.id)
            try syncStore.record(syncSnapshot, for: "system", allowSystemAccountChange: true)
            try syncStore.syncSystemAuthToMatchingManagedProfiles()
            guard try Data(contentsOf: managedAuthURL) == oldManagedAuth else {
                print("Codex profile store self-test failed: matching system auth sync")
                return false
            }
            let mismatchedSystemAuth = try testAuthData(email: "other@example.com", accessToken: "wrong")
            try mismatchedSystemAuth.write(to: systemAuthURL)
            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 30_000)],
                ofItemAtPath: systemAuthURL.path
            )
            try syncStore.syncSystemAuthToMatchingManagedProfiles()
            guard try Data(contentsOf: managedAuthURL) == oldManagedAuth else {
                print("Codex profile store self-test failed: mismatched system auth must not sync")
                return false
            }
            try restored.discardManagedProfile(added.id)
            guard Set(restored.profiles.map(\.id)) == ["system", preserved.id],
                try Data(contentsOf: preserved.codexHomeURL.appendingPathComponent("auth.json")) == systemAuth,
                restored.selectedMonitorProfileID == "system",
                restored.selectedLaunchProfileID == "system"
            else {
                print("Codex profile store self-test failed: removal")
                return false
            }
            guard WorkspacePresentation.selfTest() else { return false }
            print("Codex profile store self-test passed")
            return true
        } catch {
            print("Codex profile store self-test failed: \(error)")
            return false
        }
    }

    private static func testMembershipRefreshPolicy(_ source: CodexProfile) -> Bool {
        let now = Date(timeIntervalSince1970: 10_000)
        var profile = source
        func setSnapshot(at date: Date, succeeded: Bool = true) {
            profile.lastSnapshot = CodexAccountSnapshot(
                accountType: "chatgpt", planType: "plus", email: source.lastSnapshot?.email,
                accountID: source.lastSnapshot?.accountID, limitId: nil, limitName: nil,
                fiveHour: nil, sevenDay: nil, monthly: nil, fetchedAt: date,
                appServerVersion: nil, quotaReadSucceeded: succeeded)
        }
        func due(_ systemKey: String? = "system@example.com", at date: Date? = nil) -> Bool {
            CodexOfficialProfileReader.needsMembershipRefresh(profile, systemAccountKey: systemKey, now: date ?? now)
        }
        func expect(_ condition: Bool, _ label: String) -> Bool {
            if !condition { print("Codex profile store self-test failed: membership \(label)") }
            return condition
        }
        setSnapshot(at: now)
        profile.lastMembershipRefreshAt = nil
        profile.lastQuotaReadFailureAt = nil
        guard expect(due(), "expired date with fresh quota is checked"),
            expect(!due(profile.recordedAccountKey), "current system identity is excluded"),
            expect(!due(nil), "missing system identity blocks refresh")
        else { return false }
        profile.lastMembershipRefreshAt = now
        profile.lastMembershipRefreshSucceeded = true
        guard expect(!due(), "successful check is not repeated immediately") else { return false }
        setSnapshot(at: now.addingTimeInterval(6 * 60 * 60))
        guard expect(due(at: now.addingTimeInterval(6 * 60 * 60)), "unchanged expired date is checked later") else { return false }
        profile.lastMembershipRefreshSucceeded = false
        setSnapshot(at: now.addingTimeInterval(15 * 60 - 1))
        guard expect(!due(at: now.addingTimeInterval(15 * 60 - 1)), "failed refresh backs off"),
            expect(due(at: now.addingTimeInterval(15 * 60)), "failed refresh becomes eligible")
        else { return false }
        profile.lastMembershipRefreshAt = nil
        setSnapshot(at: now.addingTimeInterval(-301))
        guard expect(!due(), "stale quota blocks credential mutation") else { return false }
        setSnapshot(at: now, succeeded: false)
        guard expect(!due(), "failed quota blocks credential mutation") else { return false }
        setSnapshot(at: now)
        profile.lastQuotaReadFailureAt = now.addingTimeInterval(1)
        guard expect(!due(), "newer quota failure blocks credential mutation") else { return false }
        profile.lastQuotaReadFailureAt = nil
        setSnapshot(at: Date(timeIntervalSince1970: 399))
        guard expect(!due(at: Date(timeIntervalSince1970: 399)), "future membership date is not renewed") else { return false }
        profile.officialProfile = nil
        return expect(!due(), "unknown membership date is not treated as expired")
    }

    /// Recreates the real dual-window sequence: both instances start with the
    /// same cache, then one writes a setting while the other finishes a refresh.
    /// Each later writer must retain the setting committed by the earlier one.
    private static func testProfileOrderTransactions(root: URL, fileManager: FileManager) throws -> Bool {
        let home = root.appendingPathComponent("order-home", isDirectory: true)
        let support = root.appendingPathComponent("order-support", isDirectory: true)
        func reload() -> CodexProfileStore {
            CodexProfileStore(fileManager: fileManager, homeDirectory: home, applicationSupportDirectory: support)
        }
        func expect(_ condition: Bool, _ label: String) -> Bool {
            if !condition { print("Codex profile ordering self-test failed: \(label)") }
            return condition
        }
        let seed = reload()
        let first = try seed.addManagedProfile()
        let hidden = try seed.addManagedProfile()
        let last = try seed.addManagedProfile()
        try seed.setExecutionPreference(
            CodexExecutionPreference(model: .sol, reasoningEffort: .high, serviceTier: .standard), for: hidden.id
        )
        let original = seed.profiles.map(\.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalFields = try Dictionary(uniqueKeysWithValues: seed.profiles.map { ($0.id, try encoder.encode($0)) })
        let stale = reload()
        let desired = [original[0], last.id, hidden.id, first.id]
        try seed.reorderProfiles(desired, expectedCurrentOrder: original)
        let committed = reload().profiles
        guard expect(committed.map(\.id) == desired, "complete order and hidden slot"),
            expect(committed[2].id == hidden.id, "hidden slot moved"),
            expect(
                try Dictionary(uniqueKeysWithValues: committed.map { ($0.id, try encoder.encode($0)) }) == originalFields,
                "profile or dispatch preferences changed")
        else { return false }
        do {
            try stale.reorderProfiles(original, expectedCurrentOrder: original)
            return expect(false, "stale order did not report conflict")
        } catch DispatchParticipationError.concurrentChange {
        }
        guard expect(reload().profiles.map(\.id) == desired, "stale order overwrote newer order") else { return false }
        for invalid in [
            Array(desired.dropLast()), [desired[0], desired[1], desired[2], desired[2]],
            [desired[0], desired[1], desired[2], "unrecognized-profile"],
        ] {
            do {
                try seed.reorderProfiles(invalid, expectedCurrentOrder: desired)
                return expect(false, "invalid complete order accepted")
            } catch DispatchParticipationError.invalidSnapshot {
            }
            guard expect(reload().profiles.map(\.id) == desired, "invalid order changed persisted profiles") else { return false }
        }
        try seed.reorderProfiles(desired, expectedCurrentOrder: desired)
        return expect(reload().profiles.map(\.id) == desired, "identical order changed profiles")
    }

    private static func testCrossInstanceStateTransactions(root: URL, fileManager: FileManager) throws -> Bool {
        let home = root.appendingPathComponent("cross-instance-home", isDirectory: true)
        let support = root.appendingPathComponent("cross-instance-support", isDirectory: true)
        let seed = CodexProfileStore(
            fileManager: fileManager,
            homeDirectory: home,
            applicationSupportDirectory: support
        )
        let profile = try seed.addManagedProfile()
        let base = Date(timeIntervalSince1970: 3_000_000)
        try seed.record(
            testSnapshot(email: "cross-instance@example.invalid", usedPercent: 10, at: base),
            for: profile.id
        )
        func reload() -> CodexProfileStore {
            CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: home,
                applicationSupportDirectory: support
            )
        }
        func current(_ store: CodexProfileStore) -> CodexProfile? {
            store.profiles.first(where: { $0.id == profile.id })
        }
        func expect(_ condition: Bool, _ label: String) -> Bool {
            if !condition { print("Codex cross-instance self-test failed: \(label)") }
            return condition
        }

        let fast = CodexExecutionPreference(model: .terra, reasoningEffort: .high, serviceTier: .fast)
        let standard = CodexExecutionPreference(model: .sol, reasoningEffort: .max, serviceTier: .standard)
        let high = CodexExecutionPreference(model: .astra, reasoningEffort: .ultra, serviceTier: .fast)

        // A settings write must survive B's stale successful quota refresh.
        let settingWriter = reload()
        let quotaWriter = reload()
        try settingWriter.setExecutionPreference(fast, for: profile.id)
        try quotaWriter.record(
            testSnapshot(
                email: "cross-instance@example.invalid",
                usedPercent: 20,
                at: base.addingTimeInterval(1)
            ),
            for: profile.id
        )
        let afterQuota = reload()
        guard expect(current(afterQuota)?.executionPreference == fast, "quota refresh reverted execution preference"),
            expect(current(afterQuota)?.lastSnapshot?.fetchedAt == base.addingTimeInterval(1), "quota refresh was lost")
        else { return false }

        // The same must hold for the independent official-profile observer.
        let officialSettingWriter = reload()
        let officialWriter = reload()
        try officialSettingWriter.setExecutionPreference(standard, for: profile.id)
        let official = CodexOfficialProfileSnapshot(
            accountEmail: "cross-instance@example.invalid",
            displayName: "Cross instance",
            username: "cross-instance",
            lifetimeTokens: nil,
            peakDailyTokens: nil,
            planType: "plus",
            subscriptionActiveUntil: nil,
            statsAsOf: nil,
            fetchedAt: base.addingTimeInterval(2)
        )
        try officialWriter.recordOfficialProfile(official, for: profile.id)
        let afterOfficial = reload()
        guard expect(current(afterOfficial)?.executionPreference == standard, "official observer reverted execution preference"),
            expect(current(afterOfficial)?.officialProfile == official, "official observer was lost")
        else { return false }

        // Failed quota observations persist a marker without restoring stale UI state.
        let failureSettingWriter = reload()
        let failureWriter = reload()
        try failureSettingWriter.setExecutionPreference(high, for: profile.id)
        let failedSnapshot = UsageSnapshot(
            refreshedAt: base.addingTimeInterval(3),
            account: AccountInfo(
                type: "chatgpt",
                planType: "plus",
                emailPresent: true,
                email: "cross-instance@example.invalid"
            ),
            limitId: nil,
            limitName: nil,
            quotaReadSucceeded: false,
            fiveHourQuota: nil,
            sevenDayQuota: nil,
            monthlyQuota: nil,
            credits: nil,
            cloudLifetimeTokens: nil,
            local: nil,
            taskBoard: nil,
            messages: ["app-server 3: oauth-invalidated"]
        )
        try failureWriter.record(failedSnapshot, for: profile.id)
        let afterFailure = reload()
        guard expect(current(afterFailure)?.executionPreference == high, "quota failure reverted execution preference"),
            expect(
                current(afterFailure)?.lastQuotaReadFailureAt == base.addingTimeInterval(3)
                    && current(afterFailure)?.lastQuotaReadFailureReason == "oauth-invalidated",
                "quota failure marker was lost"
            )
        else { return false }

        // Reset-card corrections use the same transaction, so they preserve a
        // setting written by an instance with an equally stale startup cache.
        let resetSettingWriter = reload()
        let resetWriter = reload()
        try resetSettingWriter.setExecutionPreference(fast, for: profile.id)
        let accountKey = current(afterFailure)?.recordedAccountKey ?? ""
        try resetWriter.adjustResetManualOffset(accountKey: accountKey, delta: 1)
        let afterReset = reload()
        guard expect(current(afterReset)?.executionPreference == fast, "reset correction reverted execution preference"),
            expect(afterReset.resetCounter(accountKey: accountKey).manualOffset == 1, "reset correction was lost")
        else { return false }

        print("Codex cross-instance state transaction self-test passed")
        return true
    }

    private static func testStateTransactionFailures(root: URL, fileManager: FileManager) throws -> Bool {
        let home = root.appendingPathComponent("transaction-failures-home", isDirectory: true)
        let support = root.appendingPathComponent("transaction-failures-support", isDirectory: true)
        let store = CodexProfileStore(fileManager: fileManager, homeDirectory: home, applicationSupportDirectory: support)
        let stateURL = support.appendingPathComponent(DispatchParticipationPaths.supportDirectoryName)
            .appendingPathComponent(DispatchParticipationPaths.snapshotFileName)
        let profile = try store.addManagedProfile()
        let permissions = try fileManager.attributesOfItem(atPath: stateURL.path)[.posixPermissions] as? NSNumber
        guard !store.hadSavedStateOnLoad, permissions?.intValue == 0o600 else {
            print("Codex transaction failure self-test failed: initial commit permissions")
            return false
        }
        let persisted = try Data(contentsOf: stateURL)
        try fileManager.removeItem(at: stateURL)
        do {
            try store.setRemark("must stay missing", for: profile.id)
            print("Codex transaction failure self-test failed: missing state was recreated")
            return false
        } catch {}
        do {
            try store.selectMonitor(profile.id)
            print("Codex transaction failure self-test failed: monitor selection ignored persistence failure")
            return false
        } catch {}
        guard store.selectedMonitorProfileID == "system" else {
            print("Codex transaction failure self-test failed: monitor selection changed after persistence failure")
            return false
        }
        do {
            _ = try store.addManagedProfile()
            print("Codex transaction failure self-test failed: add accepted missing state")
            return false
        } catch {}
        guard !fileManager.fileExists(atPath: stateURL.path),
            try fileManager.contentsOfDirectory(atPath: profile.codexHomeURL.deletingLastPathComponent().path) == [profile.id]
        else {
            print("Codex transaction failure self-test failed: rejected write left files")
            return false
        }

        try persisted.write(to: stateURL)
        let stale = CodexProfileStore(fileManager: fileManager, homeDirectory: home, applicationSupportDirectory: support)
        let retained = Data("synthetic-preserved-home".utf8)
        let marker = profile.codexHomeURL.appendingPathComponent("auth.json")
        try retained.write(to: marker)
        try store.discardManagedProfile(profile.id)
        try stale.removeManagedProfile(profile.id)
        guard try Data(contentsOf: marker) == retained,
            !stale.profiles.contains(where: { $0.id == profile.id })
        else {
            print("Codex transaction failure self-test failed: stale removal moved preserved home")
            return false
        }
        print("Codex state transaction failure self-test passed")
        return true
    }

    private static func testIndependentMonitorSelection(root: URL, fileManager: FileManager) throws -> Bool {
        let home = root.appendingPathComponent("independent-monitor-home", isDirectory: true)
        let support = root.appendingPathComponent("independent-monitor-support", isDirectory: true)
        let store = CodexProfileStore(
            fileManager: fileManager,
            homeDirectory: home,
            applicationSupportDirectory: support
        )
        let independent = try store.addManagedProfile()
        let desktopMatch = try store.addManagedProfile()
        let manualSelection = try store.addManagedProfile()
        try store.record(
            testSnapshot(email: "monitor@example.invalid", usedPercent: 10, at: Date(timeIntervalSince1970: 1)),
            for: independent.id
        )
        try store.record(
            testSnapshot(email: "desktop@example.invalid", usedPercent: 20, at: Date(timeIntervalSince1970: 2)),
            for: desktopMatch.id
        )
        try store.record(
            testSnapshot(email: "manual@example.invalid", usedPercent: 30, at: Date(timeIntervalSince1970: 3)),
            for: manualSelection.id
        )
        try store.record(
            testSnapshot(email: "desktop@example.invalid", usedPercent: 20, at: Date(timeIntervalSince1970: 4)),
            for: "system",
            allowAccountOnly: true,
            allowSystemAccountChange: true
        )
        try store.selectMonitor(independent.id)

        let reloaded = CodexProfileStore(
            fileManager: fileManager,
            homeDirectory: home,
            applicationSupportDirectory: support
        )
        let existingIDs = Set(reloaded.profiles.map(\.id))
        guard reloaded.selectedMonitorProfileID == independent.id,
            !UsageStore.shouldFollowDesktopIdentity(
                selectedMonitorProfileID: reloaded.selectedMonitorProfileID,
                systemProfileID: "system",
                existingProfileIDs: existingIDs
            )
        else {
            print("Codex monitor self-test failed: saved managed selection was not preserved")
            return false
        }

        // A system selection follows the matching Desktop identity.
        try reloaded.selectMonitor("system")
        let followsDesktop = UsageStore.shouldFollowDesktopIdentity(
            selectedMonitorProfileID: reloaded.selectedMonitorProfileID,
            systemProfileID: "system",
            existingProfileIDs: existingIDs
        )
        guard followsDesktop, try reloaded.selectMonitorForSystemAccount() == desktopMatch.id else {
            print("Codex monitor self-test failed: system selection did not follow Desktop")
            return false
        }

        // The identity read starts while system is selected. A manual choice
        // made before its callback must be evaluated as the current choice.
        try reloaded.selectMonitor("system")
        let monitorWhenReadStarted = reloaded.selectedMonitorProfileID
        try reloaded.selectMonitor(manualSelection.id)
        guard monitorWhenReadStarted == "system",
            reloaded.selectedMonitorProfileID == manualSelection.id,
            !UsageStore.shouldFollowDesktopIdentity(
                selectedMonitorProfileID: reloaded.selectedMonitorProfileID,
                systemProfileID: "system",
                existingProfileIDs: existingIDs
            )
        else {
            print("Codex monitor self-test failed: explicit monitor selection was not independent")
            return false
        }
        let keepsNoIdentitySelection = !UsageStore.shouldFollowDesktopIdentity(
            selectedMonitorProfileID: manualSelection.id,
            systemProfileID: "system",
            existingProfileIDs: existingIDs
        )
        guard keepsNoIdentitySelection else {
            print("Codex monitor self-test failed: no identity response cleared manual selection")
            return false
        }
        let afterExplicitSelection = CodexProfileStore(
            fileManager: fileManager,
            homeDirectory: home,
            applicationSupportDirectory: support
        )
        guard afterExplicitSelection.selectedMonitorProfileID == manualSelection.id else {
            print("Codex monitor self-test failed: explicit monitor selection did not persist")
            return false
        }

        // A successful explicit Desktop switch uses this existing selection
        // write after identity verification; keep that behavior persistent.
        try afterExplicitSelection.selectMonitor(desktopMatch.id)
        let afterExplicitDesktopSelection = CodexProfileStore(
            fileManager: fileManager,
            homeDirectory: home,
            applicationSupportDirectory: support
        )
        guard afterExplicitDesktopSelection.selectedMonitorProfileID == desktopMatch.id else {
            print("Codex monitor self-test failed: explicit Desktop selection did not persist")
            return false
        }

        try afterExplicitDesktopSelection.selectMonitor(manualSelection.id)
        try afterExplicitDesktopSelection.discardManagedProfile(manualSelection.id)
        let afterDeletionIDs = Set(afterExplicitDesktopSelection.profiles.map(\.id))
        guard afterExplicitDesktopSelection.selectedMonitorProfileID == "system",
            UsageStore.shouldFollowDesktopIdentity(
                selectedMonitorProfileID: manualSelection.id,
                systemProfileID: "system",
                existingProfileIDs: afterDeletionIDs
            ),
            try afterExplicitDesktopSelection.selectMonitorForSystemAccount() == desktopMatch.id
        else {
            print("Codex monitor self-test failed: deleted selection did not recover")
            return false
        }
        print("Codex independent monitor selection self-test passed")
        return true
    }

    private static func testSystemSwitchObservationOrdering(root: URL, fileManager: FileManager) throws -> Bool {
        let home = root.appendingPathComponent("switch-ordering-home")
        let store = CodexProfileStore(homeDirectory: home, applicationSupportDirectory: root.appendingPathComponent("switch-ordering-support"))
        let system = store.profiles.first(where: \.isSystemProfile)!
        let authURL = system.codexHomeURL.appendingPathComponent("auth.json")
        try fileManager.createDirectory(at: system.codexHomeURL, withIntermediateDirectories: true)
        let old = testSnapshot(email: "old@example.invalid", usedPercent: 80, at: Date(timeIntervalSince1970: 200))
        let target = testSnapshot(email: "target@example.invalid", usedPercent: 20, at: Date(timeIntervalSince1970: 100))
        try testAuthData(email: "old@example.invalid", accessToken: "fixture").write(to: authURL)
        try store.record(old, for: system.id, allowSystemAccountChange: true)
        try testAuthData(email: "target@example.invalid", accessToken: "fixture").write(to: authURL)
        try store.record(target, for: system.id, allowSystemAccountChange: true)
        guard store.profiles.first(where: \.isSystemProfile)?.lastSnapshot?.email == "target@example.invalid" else {
            print("Codex switch observation self-test failed: preflight timestamp hid the new Desktop account")
            return false
        }
        let late = testSnapshot(email: "old@example.invalid", usedPercent: 90, at: Date(timeIntervalSince1970: 300))
        try store.record(late, for: system.id, allowSystemAccountChange: true)
        let stale = testSnapshot(email: "target@example.invalid", usedPercent: 70, at: Date(timeIntervalSince1970: 50))
        try store.record(stale, for: system.id, allowSystemAccountChange: true)
        guard let current = store.profiles.first(where: \.isSystemProfile)?.lastSnapshot,
            current.email == "target@example.invalid", current.sevenDay?.usedPercent == 20,
            current.fetchedAt == target.refreshedAt
        else {
            print("Codex switch observation self-test failed: late reads replaced the current account")
            return false
        }
        try testAuthData(email: "old@example.invalid", accessToken: "fixture").write(to: authURL)
        try store.record(testSnapshot(email: "old@example.invalid", usedPercent: 60, at: Date(timeIntervalSince1970: 80)), for: system.id, allowSystemAccountChange: true)
        guard store.profiles.first(where: \.isSystemProfile)?.lastSnapshot?.email == "old@example.invalid" else { return false }
        print("Codex switch observation self-test passed: verified identity changes and late-read rejection")
        return true
    }

    private static func testQuotaObservationOrdering(root: URL, fileManager: FileManager) throws -> Bool {
        let home = root.appendingPathComponent("quota-ordering-home", isDirectory: true)
        let support = root.appendingPathComponent("quota-ordering-support", isDirectory: true)
        let store = CodexProfileStore(fileManager: fileManager, homeDirectory: home, applicationSupportDirectory: support)
        let profile = try store.addManagedProfile()
        let stateURL =
            support
            .appendingPathComponent(DispatchParticipationPaths.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(DispatchParticipationPaths.snapshotFileName)
        let base = Date(timeIntervalSince1970: 2_000_000)
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if !condition {
                print("Codex quota observation self-test failed: \(label)")
                failures += 1
            }
        }
        func observation(
            _ seconds: TimeInterval,
            used: Double? = nil,
            messages: [String] = [],
            email: String? = "ordering@example.invalid",
            succeeded: Bool? = nil,
            balance: String? = nil,
            unlimited: Bool? = nil
        ) -> UsageSnapshot {
            UsageSnapshot(
                refreshedAt: base.addingTimeInterval(seconds),
                account: AccountInfo(type: "chatgpt", planType: "plus", emailPresent: email != nil, email: email),
                limitId: used == nil ? nil : "codex",
                limitName: nil,
                quotaReadSucceeded: succeeded ?? (used != nil),
                fiveHourQuota: nil,
                sevenDayQuota: used.map {
                    RateWindow(usedPercent: $0, windowDurationMins: 10_080, resetsAt: base.addingTimeInterval(604_800))
                },
                monthlyQuota: nil,
                credits: balance != nil || unlimited != nil
                    ? CreditsInfo(
                        hasCredits: true,
                        unlimited: unlimited ?? false,
                        balance: balance,
                        resetCredits: nil,
                        resetCreditDetails: nil
                    ) : nil,
                cloudLifetimeTokens: nil,
                local: nil,
                taskBoard: nil,
                messages: messages
            )
        }
        func currentProfile() -> CodexProfile { store.profiles.first { $0.id == profile.id }! }
        func resetCount() -> Int { store.resetCounter(accountKey: currentProfile().recordedAccountKey).automaticCount }

        // A(80) -> B(0) -> duplicate B -> late A(80) -> C(0) is one reset, not two.
        try store.record(observation(0, used: 80), for: profile.id)
        try store.record(observation(10, used: 0), for: profile.id)
        try store.record(observation(10, used: 0), for: profile.id)
        expect(resetCount() == 1, "duplicate success must not count a second reset")
        let afterReset = currentProfile().lastSnapshot
        let persistedAfterReset = try Data(contentsOf: stateURL)
        try store.record(observation(0, used: 80), for: profile.id)
        expect(currentProfile().lastSnapshot == afterReset, "late success must not roll back the quota snapshot")
        expect(try Data(contentsOf: stateURL) == persistedAfterReset, "late success must not rewrite persisted state")
        try store.record(observation(20, used: 0), for: profile.id)
        expect(resetCount() == 1, "late success followed by fresh success must still count one reset")

        let afterFreshSuccess = currentProfile().lastSnapshot
        let persistedAfterSuccess = try Data(contentsOf: stateURL)
        try store.record(observation(15), for: profile.id)
        expect(currentProfile().lastQuotaReadFailureAt == nil, "late failure must not replace fresh success")
        expect(try Data(contentsOf: stateURL) == persistedAfterSuccess, "late failure must not rewrite persisted state")

        try store.record(observation(40, messages: ["app-server 3: oauth-invalidated"]), for: profile.id)
        let persistedAfterFailure = try Data(contentsOf: stateURL)
        expect(
            !CodexWarmUpPolicy.canSendWarmUpRequest(currentProfile(), now: base.addingTimeInterval(40)),
            "a newer failed read must block the retained successful snapshot"
        )
        try store.record(observation(30), for: profile.id)
        expect(currentProfile().lastQuotaReadFailureAt == base.addingTimeInterval(40), "failure timestamps must not move backwards")
        expect(currentProfile().lastQuotaReadFailureReason == "oauth-invalidated", "late failure must not erase the latest failure category")
        try store.record(observation(30, used: 5), for: profile.id)
        expect(currentProfile().lastSnapshot == afterFreshSuccess, "success older than latest failure must be ignored")
        expect(currentProfile().lastQuotaReadFailureAt == base.addingTimeInterval(40), "late success must not clear newer failure")
        expect(try Data(contentsOf: stateURL) == persistedAfterFailure, "older observations must leave persisted failure unchanged")

        // Equal timestamps are intentional: one request may first fail, then gain verified data.
        try store.record(observation(40, used: 5), for: profile.id)
        expect(currentProfile().lastQuotaReadFailureAt == nil, "equal-time success must clear the failure")
        expect(currentProfile().lastSnapshot?.fetchedAt == base.addingTimeInterval(40), "equal-time success must be accepted")
        expect(
            CodexWarmUpPolicy.canSendWarmUpRequest(currentProfile(), now: base.addingTimeInterval(40)),
            "fresh official recovery may re-enable warm-up"
        )
        let afterRecovery = currentProfile().lastSnapshot
        let persistedAfterRecovery = try Data(contentsOf: stateURL)
        try store.record(observation(0), for: profile.id, allowAccountOnly: true)
        expect(currentProfile().lastSnapshot == afterRecovery, "late account-only enrichment must not erase quota data")
        expect(try Data(contentsOf: stateURL) == persistedAfterRecovery, "late account-only enrichment must not rewrite state")

        // The ordering watermark is per profile, not global or shared across account cards.
        let second = try store.addManagedProfile()
        try store.record(observation(0), for: second.id, allowAccountOnly: true)
        try store.record(observation(0, used: 80), for: second.id)
        expect(
            store.profiles.first { $0.id == second.id }?.lastSnapshot?.sevenDay?.usedPercent == 80,
            "equal-time quota data must enrich an account-only snapshot on another profile"
        )

        let third = try store.addManagedProfile()
        try store.record(observation(50, used: 80, email: nil), for: third.id)
        try store.record(observation(50), for: third.id, allowAccountOnly: true)
        expect(
            store.profiles.first { $0.id == third.id }?.lastSnapshot?.sevenDay?.usedPercent == 80,
            "equal-time account enrichment must preserve an existing quota"
        )
        expect(
            store.profiles.first { $0.id == third.id }?.lastSnapshot?.email == "ordering@example.invalid",
            "equal-time account enrichment must fill missing identity fields"
        )
        let thirdAfterEnrichment = store.profiles.first { $0.id == third.id }
        try store.record(observation(50, messages: ["app-server 3: oauth-invalidated"]), for: third.id)
        expect(
            store.profiles.first { $0.id == third.id } == thirdAfterEnrichment,
            "equal-time failure must not override a successful quota observation"
        )
        try store.record(observation(50, used: 0), for: third.id)
        expect(
            store.profiles.first { $0.id == third.id }?.lastSnapshot?.sevenDay?.usedPercent == 80,
            "conflicting equal-time success must not rewrite an established quota"
        )

        let fourth = try store.addManagedProfile()
        try store.record(observation(60, messages: ["app-server 3: oauth-invalidated"]), for: fourth.id)
        try store.record(observation(60), for: fourth.id, allowAccountOnly: true)
        expect(
            store.profiles.first { $0.id == fourth.id }?.lastQuotaReadFailureAt == base.addingTimeInterval(60),
            "equal-time account enrichment must retain the quota failure"
        )
        try store.record(observation(60, used: 20), for: fourth.id)
        expect(
            store.profiles.first { $0.id == fourth.id }?.lastQuotaReadFailureAt == nil,
            "equal-time quota success must recover a failed observation"
        )

        let fifth = try store.addManagedProfile()
        try store.record(observation(70, succeeded: true), for: fifth.id)
        let fifthAfterSuccess = store.profiles.first { $0.id == fifth.id }
        try store.record(observation(70, messages: ["app-server 3: oauth-invalidated"]), for: fifth.id)
        expect(
            store.profiles.first { $0.id == fifth.id } == fifthAfterSuccess,
            "equal-time failure must not override a successful observation without quota windows"
        )

        let balanceProfile = try store.addManagedProfile()
        try store.record(
            observation(80, succeeded: true, balance: "1,234.50", unlimited: false),
            for: balanceProfile.id
        )
        try store.record(observation(80, used: 20), for: balanceProfile.id)
        let enrichedBalance = store.profiles.first { $0.id == balanceProfile.id }?.lastSnapshot
        expect(
            enrichedBalance?.creditBalance == "1,234.50"
                && enrichedBalance?.creditBalanceUnlimited == false,
            "equal-time quota enrichment must preserve explicit balance metadata"
        )
        try store.record(
            observation(79, succeeded: true, balance: "999", unlimited: true),
            for: balanceProfile.id
        )
        expect(
            store.profiles.first { $0.id == balanceProfile.id }?.lastSnapshot == enrichedBalance,
            "stale balance observation must not replace the current account snapshot"
        )
        try store.record(
            observation(90, succeeded: true, balance: "1,2.3.4", unlimited: false),
            for: balanceProfile.id
        )
        expect(
            store.profiles.first { $0.id == balanceProfile.id }?.lastSnapshot?.creditBalance == nil,
            "malformed balance text must not be persisted"
        )
        let accountOnlySnapshot = CodexAccountSnapshot(
            accountType: "chatgpt",
            planType: "plus",
            email: "ordering@example.invalid",
            limitId: nil,
            limitName: nil,
            fiveHour: nil,
            sevenDay: nil,
            monthly: nil,
            fetchedAt: base.addingTimeInterval(80),
            appServerVersion: nil,
            quotaReadSucceeded: false
        )
        expect(
            CodexProfileStore.snapshotByReplacingAccountID(
                accountOnlySnapshot,
                accountID: "account-ordering"
            ).quotaReadSucceeded == false,
            "account ID backfill must preserve an account-only observation's failure marker"
        )

        let identityNow = base.addingTimeInterval(100)
        var identityProfile = store.profiles.first { $0.id == third.id }!
        identityProfile.lastSnapshot = CodexAccountSnapshot(
            accountType: "chatgpt",
            planType: "plus",
            email: "ordering@example.invalid",
            accountID: "account-ordering",
            limitId: "codex",
            limitName: nil,
            fiveHour: nil,
            sevenDay: CodexQuotaWindowSnapshot(
                RateWindow(
                    usedPercent: 80,
                    windowDurationMins: 10_080,
                    resetsAt: identityNow.addingTimeInterval(604_800)
                )
            ),
            monthly: nil,
            fetchedAt: identityNow,
            appServerVersion: nil
        )
        identityProfile.lastQuotaReadFailureAt = nil
        let currentIdentity = CodexCredentialIdentity(
            email: "ordering@example.invalid",
            accountID: "account-ordering"
        )
        let clickedDispatchIdentity = try CodexProfileStore.validatedDispatchIdentity(
            for: identityProfile,
            credentialIdentity: currentIdentity,
            now: identityNow
        )
        expect(
            clickedDispatchIdentity.accountID == currentIdentity.accountID,
            "fresh matching credential identity must permit dispatch synchronization"
        )
        var staleIdentityProfile = identityProfile
        staleIdentityProfile.lastSnapshot = CodexAccountSnapshot(
            accountType: "chatgpt",
            planType: "plus",
            email: "ordering@example.invalid",
            accountID: "account-ordering",
            limitId: "codex",
            limitName: nil,
            fiveHour: nil,
            sevenDay: identityProfile.lastSnapshot?.sevenDay,
            monthly: nil,
            fetchedAt: identityNow.addingTimeInterval(-CodexWarmUpPolicy.maximumQuotaAge - 1),
            appServerVersion: nil
        )
        var failedIdentityProfile = identityProfile
        failedIdentityProfile.lastSnapshot = CodexAccountSnapshot(
            accountType: "chatgpt",
            planType: "plus",
            email: "ordering@example.invalid",
            accountID: "account-ordering",
            limitId: "codex",
            limitName: nil,
            fiveHour: nil,
            sevenDay: identityProfile.lastSnapshot?.sevenDay,
            monthly: nil,
            fetchedAt: identityNow,
            appServerVersion: nil,
            quotaReadSucceeded: false
        )
        func mirror(_ id: String, snapshot: CodexAccountSnapshot?) -> CodexProfile {
            CodexProfile(
                id: id,
                name: id,
                codexHomePath: root.appendingPathComponent(id, isDirectory: true).path,
                isSystemProfile: false,
                createdAt: identityNow,
                lastSnapshot: snapshot
            )
        }
        func validateMirrors(
            _ profiles: [CodexProfile],
            credentials: [String: CodexCredentialIdentity]
        ) throws {
            try CodexProfileStore.validateDispatchMirrorCredentials(
                for: clickedDispatchIdentity,
                in: profiles,
                now: identityNow,
                credentialReader: { credentials[$0.standardizedFileURL.path] }
            )
        }
        func expectMirrorFailure(
            _ profiles: [CodexProfile],
            credentials: [String: CodexCredentialIdentity],
            _ label: String
        ) {
            do {
                try validateMirrors(profiles, credentials: credentials)
                expect(false, "\(label) must block mirror dispatch synchronization")
            } catch DispatchParticipationError.identityMismatch {
            } catch {
                expect(false, "\(label) returned the wrong mirror dispatch error")
            }
        }
        let matchingMirror = mirror("dispatch-mirror-matching", snapshot: identityProfile.lastSnapshot)
        let matchingCredentials = [
            identityProfile.codexHomeURL.standardizedFileURL.path: currentIdentity,
            matchingMirror.codexHomeURL.standardizedFileURL.path: currentIdentity,
        ]
        do {
            try validateMirrors(
                [identityProfile],
                credentials: [identityProfile.codexHomeURL.standardizedFileURL.path: currentIdentity]
            )
        } catch {
            expect(false, "fresh clicked credential must pass mirror dispatch validation")
        }
        do {
            try validateMirrors([identityProfile, matchingMirror], credentials: matchingCredentials)
        } catch {
            expect(false, "all matching mirror credentials must permit dispatch synchronization")
        }
        expectMirrorFailure(
            [identityProfile, matchingMirror],
            credentials: matchingCredentials.merging([
                matchingMirror.codexHomeURL.standardizedFileURL.path: CodexCredentialIdentity(
                    email: currentIdentity.email,
                    accountID: "account-changed"
                )
            ]) { _, changed in changed },
            "changed mirror account id"
        )
        expectMirrorFailure(
            [identityProfile, matchingMirror],
            credentials: [identityProfile.codexHomeURL.standardizedFileURL.path: currentIdentity],
            "missing mirror credential"
        )
        let staleMirror = mirror("dispatch-mirror-stale", snapshot: staleIdentityProfile.lastSnapshot)
        expectMirrorFailure(
            [identityProfile, staleMirror],
            credentials: [
                identityProfile.codexHomeURL.standardizedFileURL.path: currentIdentity,
                staleMirror.codexHomeURL.standardizedFileURL.path: currentIdentity,
            ],
            "stale mirror snapshot"
        )
        let failedMirror = mirror("dispatch-mirror-failed", snapshot: failedIdentityProfile.lastSnapshot)
        expectMirrorFailure(
            [identityProfile, failedMirror],
            credentials: [
                identityProfile.codexHomeURL.standardizedFileURL.path: currentIdentity,
                failedMirror.codexHomeURL.standardizedFileURL.path: currentIdentity,
            ],
            "failed mirror quota read"
        )
        for (candidate, credential, label) in [
            (staleIdentityProfile, currentIdentity as CodexCredentialIdentity?, "stale snapshot"),
            (failedIdentityProfile, currentIdentity as CodexCredentialIdentity?, "failed quota snapshot"),
            (identityProfile, nil, "missing credential"),
            (
                identityProfile,
                CodexCredentialIdentity(email: "ordering@example.invalid", accountID: "account-other"),
                "mismatched account id"
            ),
            (
                identityProfile,
                CodexCredentialIdentity(email: "other@example.invalid", accountID: "account-ordering"),
                "mismatched email"
            ),
        ] {
            do {
                _ = try CodexProfileStore.validatedDispatchIdentity(
                    for: candidate,
                    credentialIdentity: credential,
                    now: identityNow
                )
                expect(false, "\(label) must block dispatch synchronization")
            } catch DispatchParticipationError.identityMismatch {
            } catch {
                expect(false, "\(label) returned the wrong dispatch synchronization error")
            }
        }
        let reloaded = CodexProfileStore(fileManager: fileManager, homeDirectory: home, applicationSupportDirectory: support)
        expect(reloaded.profiles.first { $0.id == profile.id }?.lastSnapshot == afterRecovery, "accepted snapshot must survive reload")
        expect(
            reloaded.resetCounter(accountKey: currentProfile().recordedAccountKey).automaticCount == 1,
            "single reset count must survive reload"
        )
        if failures == 0 { print("Codex quota observation ordering self-test passed") }
        return failures == 0
    }

    private static func testSnapshot(
        email: String,
        usedPercent: Double,
        at date: Date,
        resetCredits: Int? = nil,
        balance: String? = nil,
        unlimited: Bool? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            refreshedAt: date,
            account: AccountInfo(type: "chatgpt", planType: "plus", emailPresent: true, email: email),
            limitId: "codex",
            limitName: nil,
            quotaReadSucceeded: true,
            fiveHourQuota: nil,
            sevenDayQuota: RateWindow(usedPercent: usedPercent, windowDurationMins: 10_080, resetsAt: nil),
            monthlyQuota: nil,
            credits: resetCredits != nil || balance != nil || unlimited != nil
                ? CreditsInfo(
                    hasCredits: balance != nil || unlimited == true,
                    unlimited: unlimited ?? false,
                    balance: balance,
                    resetCredits: resetCredits,
                    resetCreditDetails: resetCredits.map { _ in
                        [ResetCreditDetail(id: "test-reset", expiresAt: date.addingTimeInterval(1_000))]
                    }
                ) : nil,
            cloudLifetimeTokens: nil,
            local: nil,
            taskBoard: nil,
            messages: []
        )
    }

    private static func testAuthData(email: String, accessToken: String) throws -> Data {
        let accountID = "acct-" + email.lowercased()
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
        ])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": accessToken,
                "refresh_token": "synthetic-refresh",
                "id_token": "x.\(encoded).y",
                "account_id": accountID,
            ]
        ])
    }

    private static func testResetSnapshot(
        email: String,
        usedPercent: Double,
        resetsAt: Date,
        fetchedAt: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            refreshedAt: fetchedAt,
            account: AccountInfo(type: "chatgpt", planType: "plus", emailPresent: true, email: email),
            limitId: "codex",
            limitName: nil,
            quotaReadSucceeded: true,
            fiveHourQuota: nil,
            sevenDayQuota: RateWindow(usedPercent: usedPercent, windowDurationMins: 10_080, resetsAt: resetsAt),
            monthlyQuota: nil,
            credits: nil,
            cloudLifetimeTokens: nil,
            local: nil,
            taskBoard: nil,
            messages: []
        )
    }
}

enum CodexWarmUpPolicySelfTest {
    static func run() -> Bool {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func expect(_ condition: Bool, _ message: String) -> Bool {
            if !condition { print("Codex warm-up policy self-test failed: \(message)") }
            return condition
        }
        let suite = "CodexAccountManagerNext.warm-up-defaults-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        guard expect(CodexWarmUpSelection.load(from: defaults, persistentDomainName: suite) == .none, "first install stays off until the user opts in"),
            expect(CodexWarmUpSelection.load(from: defaults, hasExistingInstallation: true, persistentDomainName: suite) == .none, "missing controls stay off on upgrade as well")
        else { return false }
        for five in [false, true] {
            for seven in [false, true] {
                let saved = CodexWarmUpSelection(fiveHour: five, sevenDay: seven)
                saved.save(to: defaults)
                guard expect(CodexWarmUpSelection.load(from: defaults, hasExistingInstallation: true, persistentDomainName: suite) == saved, "upgrade preserves each saved switch")
                else { return false }
            }
        }
        for legacy in [false, true] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(legacy, forKey: "CodexManagerNext.automaticWarmUp")
            let expected = CodexWarmUpSelection(fiveHour: false, sevenDay: legacy)
            guard expect(CodexWarmUpSelection.load(from: defaults, persistentDomainName: suite) == expected, "legacy weekly choices persist without enabling five-hour warm-up"),
                expect(CodexWarmUpSelection.load(from: defaults, persistentDomainName: suite) == expected, "legacy migration persists")
            else { return false }
        }
        defaults.removePersistentDomain(forName: suite)
        guard
            expect(CodexWarmUpSelection.load(from: defaults, hasExistingInstallation: true, persistentDomainName: suite) == .none, "missing upgrade preferences stay off (opt-in)")
        else { return false }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "CodexManagerNext.automaticWarmUp.fiveHour")
        guard
            expect(
                CodexWarmUpSelection.load(from: defaults, persistentDomainName: suite) == .none,
                "partial preferences preserve explicit off without enabling the missing window")
        else { return false }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "CodexManagerNext.automaticWarmUp.fiveHour")
        guard
            expect(
                CodexWarmUpSelection.load(from: defaults, persistentDomainName: suite) == CodexWarmUpSelection(fiveHour: true, sevenDay: false),
                "an explicit five-hour opt-in does not enable the missing weekly window")
        else { return false }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "CodexManagerNext.automaticWarmUp.sevenDay")
        guard
            expect(
                CodexWarmUpSelection.load(from: defaults, persistentDomainName: suite) == CodexWarmUpSelection(fiveHour: false, sevenDay: true),
                "an explicit weekly opt-in does not enable the missing five-hour window")
        else { return false }
        for persistent in [false, true] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(persistent, forKey: "CodexManagerNext.automaticWarmUp")
            defaults.setVolatileDomain(["CodexManagerNext.automaticWarmUp": !persistent], forName: UserDefaults.argumentDomain)
            let temporary = CodexWarmUpSelection.load(from: defaults, persistentDomainName: suite)
            temporary.save(to: defaults)
            let durable = defaults.persistentDomain(forName: suite) ?? [:]
            guard expect(temporary.sevenDay == !persistent && !temporary.fiveHour, "legacy launch override applies only in memory"),
                expect(durable["CodexManagerNext.automaticWarmUp.sevenDay"] as? Bool == persistent, "legacy override never leaks into migration")
            else { return false }
        }
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        defaults.removePersistentDomain(forName: suite)
        defaults.register(defaults: ["CodexManagerNext.automaticWarmUp.fiveHour": true, "CodexManagerNext.automaticWarmUp.sevenDay": true])
        guard expect(CodexWarmUpSelection.load(from: defaults, persistentDomainName: suite) == .none, "registration defaults never grant inference consent") else { return false }
        CodexWarmUpSelection(fiveHour: true, sevenDay: true).save(to: defaults)
        defaults.setVolatileDomain(["CodexManagerNext.automaticWarmUp.fiveHour": "NO"], forName: UserDefaults.argumentDomain)
        let temporary = CodexWarmUpSelection.load(from: defaults, persistentDomainName: suite)
        guard expect(temporary == CodexWarmUpSelection(fiveHour: false, sevenDay: true), "maintenance override affects this launch") else { return false }
        CodexWarmUpSelection.none.save(to: defaults)
        // NSArgumentDomain can remain cached for the life of the process on macOS.
        // Inspect durable values; a normal launch has no maintenance arguments.
        let persistedWarmUp = defaults.persistentDomain(forName: suite) ?? [:]
        guard
            expect(
                persistedWarmUp["CodexManagerNext.automaticWarmUp.fiveHour"] as? Bool == true
                    && persistedWarmUp["CodexManagerNext.automaticWarmUp.sevenDay"] as? Bool == false,
                "changing another switch never persists a temporary maintenance override"
            )
        else { return false }
        guard
            expect(
                CodexWarmUpPolicy.maintenanceRefreshInterval(warmUpEnabled: true) == 10 * 60
                    && CodexWarmUpPolicy.maintenanceRefreshInterval(warmUpEnabled: false) == 30 * 60
                    && CodexWarmUpPolicy.maintenanceRefreshInterval(warmUpEnabled: false, quotaNotificationsEnabled: true) == 60
                    && CodexWarmUpPolicy.maintenanceRefreshInterval(warmUpEnabled: true, quotaNotificationsEnabled: true) == 60
                    && !CodexWarmUpPolicy.maintenanceTimerNeedsReplacement(
                        currentInterval: 10 * 60,
                        requestedInterval: 10 * 60
                    )
                    && CodexWarmUpPolicy.maintenanceTimerNeedsReplacement(
                        currentInterval: 30 * 60,
                        requestedInterval: 10 * 60
                    ),
                "quota maintenance cadence"
            )
        else { return false }
        func window(
            used: Double,
            resetsIn: TimeInterval? = nil,
            durationMins: Int? = 300
        ) -> CodexQuotaWindowSnapshot {
            CodexQuotaWindowSnapshot(
                RateWindow(
                    usedPercent: used,
                    windowDurationMins: durationMins,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) }
                ))
        }
        func snapshot(
            five: CodexQuotaWindowSnapshot? = nil,
            seven: CodexQuotaWindowSnapshot? = nil,
            at: Date = now,
            email: String = "warm@example.com"
        ) -> CodexAccountSnapshot {
            CodexAccountSnapshot(
                accountType: "chatgpt",
                planType: "plus",
                email: email,
                accountID: "acct-warm",
                limitId: nil,
                limitName: nil,
                fiveHour: five,
                sevenDay: seven,
                monthly: nil,
                fetchedAt: at,
                appServerVersion: nil
            )
        }
        func profile(_ snapshot: CodexAccountSnapshot?) -> CodexProfile {
            CodexProfile(
                id: "warm-test",
                name: "warm-test",
                codexHomePath: "/tmp/codex-warm-up-self-test",
                isSystemProfile: false,
                createdAt: now,
                lastSnapshot: snapshot
            )
        }

        guard
            expect(
                !CodexWarmUpPolicy.canContinueAfterAsyncCheck(
                    serviceIsRunning: false,
                    requestIsCurrent: true,
                    warmUpIsEnabled: true,
                    accountOperationIsIdle: true
                ),
                "late availability result cannot continue after cancellation"
            ),
            expect(
                CodexWarmUpPolicy.canContinueAfterAsyncCheck(
                    serviceIsRunning: true,
                    requestIsCurrent: true,
                    warmUpIsEnabled: true,
                    accountOperationIsIdle: true
                ),
                "current running request may continue after availability check"
            )
        else { return false }

        let missingAllWindows = profile(snapshot())
        let missingFiveHour = profile(snapshot(seven: window(used: 0)))
        let missingSevenDay = profile(snapshot(five: window(used: 0)))
        let whitespaceIdentity = profile(snapshot(five: window(used: 0), email: "   \n"))
        guard
            expect(!CodexWarmUpPolicy.canSendWarmUpRequest(missingAllWindows, now: now), "missing quota windows block requests"),
            expect(
                !CodexWarmUpPolicy.isDue(
                    missingFiveHour,
                    selection: CodexWarmUpSelection(fiveHour: true, sevenDay: false),
                    now: now
                ),
                "missing selected five-hour window blocks requests"
            ),
            expect(
                !CodexWarmUpPolicy.isDue(
                    missingSevenDay,
                    selection: CodexWarmUpSelection(fiveHour: false, sevenDay: true),
                    now: now
                ),
                "missing selected weekly window blocks requests"
            ),
            expect(!CodexWarmUpPolicy.canSendWarmUpRequest(whitespaceIdentity, now: now), "blank identity blocks requests")
        else { return false }

        func exhaustedProfile(
            fiveHour: CodexQuotaWindowSnapshot,
            sevenDay: CodexQuotaWindowSnapshot,
            monthly: CodexQuotaWindowSnapshot?
        ) -> CodexProfile {
            profile(
                CodexAccountSnapshot(
                    accountType: "chatgpt",
                    planType: "plus",
                    email: "warm@example.invalid",
                    accountID: "acct-warm",
                    limitId: "codex",
                    limitName: nil,
                    fiveHour: fiveHour,
                    sevenDay: sevenDay,
                    monthly: monthly,
                    availableResetCredits: 4,
                    creditBalance: "250",
                    fetchedAt: now,
                    appServerVersion: nil
                ))
        }
        let fiveHourExhausted = exhaustedProfile(
            fiveHour: window(used: 100, resetsIn: -10),
            sevenDay: window(used: 0, durationMins: 10_080),
            monthly: nil
        )
        let weeklyExhausted = exhaustedProfile(
            fiveHour: window(used: 0),
            sevenDay: window(used: 100, durationMins: 10_080),
            monthly: nil
        )
        let monthlyExhausted = exhaustedProfile(
            fiveHour: window(used: 0),
            sevenDay: window(used: 0, durationMins: 10_080),
            monthly: window(used: 100, durationMins: 43_800)
        )
        guard
            expect(
                !CodexWarmUpPolicy.canSendWarmUpRequest(fiveHourExhausted, now: now),
                "an elapsed reset, points, and balance cannot unlock an exhausted five-hour window"
            ),
            expect(
                !CodexWarmUpPolicy.canSendWarmUpRequest(weeklyExhausted, now: now),
                "points and balance cannot unlock an exhausted weekly window"
            ),
            expect(
                !CodexWarmUpPolicy.canSendWarmUpRequest(monthlyExhausted, now: now),
                "an exhausted monthly window blocks requests despite points and balance"
            )
        else { return false }

        // Reset reads remain due when quota is exhausted, warm-up is disabled or a previous attempt failed.
        var resetProfile = profile(snapshot(five: window(used: 100, resetsIn: 10), seven: window(used: 100, resetsIn: 100)))
        resetProfile.automaticSwitchParticipation = false
        resetProfile.lastWarmUpSucceeded = false
        resetProfile.lastWarmUpAt = now.addingTimeInterval(-60)
        let deadline = now.addingTimeInterval(10 + CodexWarmUpPolicy.resetGrace)
        guard expect(CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: resetProfile, now: now) == deadline, "exhausted excluded account retains earliest reset read"),
            expect(CodexWarmUpPolicy.nextScheduledResetDate(for: resetProfile, selection: .none, now: now) == nil, "warm-up off remains off")
        else { return false }
        let afterReset = deadline.addingTimeInterval(1)
        guard expect(CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: resetProfile, now: afterReset) == afterReset, "missed reset refreshes after wake") else { return false }
        guard
            expect(
                CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: resetProfile, lastAttemptAt: afterReset, now: afterReset) == afterReset.addingTimeInterval(60),
                "in-memory attempt prevents rapid retries if saving the result fails"
            )
        else { return false }
        resetProfile.lastQuotaReadFailureAt = afterReset
        guard
            expect(
                CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: resetProfile, now: afterReset) == afterReset.addingTimeInterval(60), "failed reset read backs off before retry"),
            expect(!CodexWarmUpPolicy.hasFreshQuotaEvidence(resetProfile, now: afterReset), "newer read failure blocks warm-up even with recent cached quota")
        else { return false }
        resetProfile.lastSnapshot = snapshot(five: window(used: 0, resetsIn: 10), at: afterReset)
        resetProfile.lastQuotaReadFailureAt = nil
        guard expect(CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: resetProfile, now: afterReset) == nil, "successful post-reset read stops replaying old deadline") else {
            return false
        }
        resetProfile.lastSnapshot = snapshot(five: window(used: 100, resetsIn: 10), at: afterReset)
        guard
            expect(
                CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: resetProfile, now: afterReset) == afterReset.addingTimeInterval(60),
                "official quota still exhausted after deadline is checked again"
            )
        else { return false }
        resetProfile.lastSnapshot = snapshot(five: window(used: 0, resetsIn: 3_600), at: afterReset)
        guard
            expect(
                CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: resetProfile, now: afterReset) == now.addingTimeInterval(3_600 + CodexWarmUpPolicy.resetGrace),
                "new official reset replaces old deadline")
        else { return false }
        guard expect(CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: profile(nil), now: now) == nil, "missing reset is not invented") else { return false }

        var weeklyOnly = profile(snapshot(seven: window(used: 100, resetsIn: 10)))
        weeklyOnly.automaticSwitchParticipation = false
        let weeklyDeadline = now.addingTimeInterval(10 + CodexWarmUpPolicy.resetGrace)
        guard expect(CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: weeklyOnly, now: now) == weeklyDeadline, "seven-day reset refresh is always scheduled"),
            expect(CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: weeklyOnly, now: afterReset) == afterReset, "expired seven-day window is checked immediately"),
            expect(!CodexWarmUpPolicy.isDue(weeklyOnly, selection: .none, now: afterReset), "automatic weekly read does not enable disabled warm-up")
        else { return false }
        weeklyOnly.lastQuotaReadFailureAt = afterReset
        guard
            expect(
                CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: weeklyOnly, now: afterReset) == afterReset.addingTimeInterval(60),
                "seven-day read failure keeps retrying with backoff"
            )
        else { return false }

        // Both warm-up windows follow their global switches, including accounts excluded from dispatch.
        let selection = CodexWarmUpSelection(fiveHour: true, sevenDay: true)
        let excluded = CodexWarmUpPolicy.effectiveSelection(selection, participatesInAutomaticSwitch: false)
        guard expect(excluded.fiveHour && excluded.sevenDay, "dispatch exclusion preserves both warm-up windows") else { return false }
        let unexpectedPass = CodexWarmUpPolicy.effectiveSelection(
            selection,
            participatesInAutomaticSwitch: false,
            unexpected: [.fiveHour]
        )
        guard expect(unexpectedPass.fiveHour, "effectiveSelection unexpected reset") else { return false }

        // isWindowIdle
        guard expect(CodexWarmUpPolicy.isWindowIdle(nil, now: now), "idle nil window") else { return false }
        guard expect(CodexWarmUpPolicy.isWindowIdle(window(used: 0.2), now: now), "idle low usage") else { return false }
        guard expect(CodexWarmUpPolicy.isWindowIdle(window(used: 0.2, resetsIn: 600), now: now), "future reset with negligible usage stays on the cold-account schedule") else {
            return false
        }
        guard expect(!CodexWarmUpPolicy.isWindowIdle(window(used: 3), now: now), "active usage") else { return false }

        // didResetUnexpectedly
        let active = window(used: 40, resetsIn: 600)
        guard
            expect(
                CodexWarmUpPolicy.didResetUnexpectedly(previous: active, current: window(used: 0.2), now: now),
                "unexpected reset to idle"
            )
        else { return false }
        guard
            expect(
                CodexWarmUpPolicy.didResetUnexpectedly(previous: active, current: window(used: 30, resetsIn: 600), now: now),
                "unexpected big drop"
            )
        else { return false }
        guard
            expect(
                !CodexWarmUpPolicy.didResetUnexpectedly(previous: active, current: window(used: 39, resetsIn: 600), now: now),
                "small change is not reset"
            )
        else { return false }
        guard
            expect(
                !CodexWarmUpPolicy.didResetUnexpectedly(previous: window(used: 0.2), current: window(used: 40), now: now),
                "idle previous is not reset evidence"
            )
        else { return false }
        guard
            expect(
                CodexWarmUpPolicy.didResetUnexpectedly(previous: active, current: window(used: 35, resetsIn: 6_000), now: now),
                "shifted reset window with drop"
            )
        else { return false }

        // didConsumeReset
        let previousWindow = CodexQuotaWindowSnapshot(
            RateWindow(
                usedPercent: 50, windowDurationMins: 300, resetsAt: now.addingTimeInterval(600)))
        let sameWindowDrop = CodexQuotaWindowSnapshot(
            RateWindow(
                usedPercent: 40, windowDurationMins: 300, resetsAt: now.addingTimeInterval(600)))
        guard
            expect(
                CodexWarmUpPolicy.didConsumeReset(previous: previousWindow, current: sameWindowDrop, now: now),
                "same-window drop consumes reset"
            )
        else { return false }
        let naturalRoll = CodexQuotaWindowSnapshot(
            RateWindow(
                usedPercent: 50, windowDurationMins: 300, resetsAt: now.addingTimeInterval(600 + 18_000)))
        guard
            expect(
                !CodexWarmUpPolicy.didConsumeReset(previous: previousWindow, current: naturalRoll, now: now),
                "natural window roll is not a reset"
            )
        else { return false }
        let shiftedWindow = CodexQuotaWindowSnapshot(
            RateWindow(
                usedPercent: 50, windowDurationMins: 300, resetsAt: now.addingTimeInterval(4_000)))
        guard
            expect(
                CodexWarmUpPolicy.didConsumeReset(previous: previousWindow, current: shiftedWindow, now: now),
                "shifted window start consumes reset"
            )
        else { return false }

        // shouldSkipFiveHourToProtectWeekly
        let scarce = profile(
            snapshot(
                five: window(used: 10, resetsIn: 600),
                seven: window(used: 95, resetsIn: 86_400)
            ))
        guard expect(!CodexWarmUpPolicy.shouldSkipFiveHourToProtectWeekly(scarce, now: now), "low but available weekly limits do not disable warm-up") else { return false }
        let plenty = profile(
            snapshot(
                five: window(used: 10, resetsIn: 600),
                seven: window(used: 60, resetsIn: 86_400)
            ))
        guard expect(!CodexWarmUpPolicy.shouldSkipFiveHourToProtectWeekly(plenty, now: now), "keep five-hour when weekly plenty") else { return false }

        // nextEligibleDate
        let fiveHourOnly = CodexWarmUpSelection(fiveHour: true, sevenDay: false)
        let idleProfile = profile(snapshot(five: window(used: 0.2)))
        var succeeded = idleProfile
        succeeded.lastWarmUpSucceeded = true
        succeeded.lastWarmUpAt = now.addingTimeInterval(-3_600)
        guard
            expect(
                CodexWarmUpPolicy.nextEligibleDate(for: succeeded, selection: fiveHourOnly, now: now)
                    == now.addingTimeInterval(4 * 3_600 + CodexWarmUpPolicy.resetGrace),
                "successful warm-up waits one interval plus grace"
            )
        else { return false }
        var failed = idleProfile
        failed.lastWarmUpSucceeded = false
        failed.lastWarmUpAt = now.addingTimeInterval(-600)
        guard
            expect(
                CodexWarmUpPolicy.nextEligibleDate(for: failed, selection: fiveHourOnly, now: now)
                    == nil,
                "legacy ambiguous failure requires evidence or manual recovery, not a timer"
            )
        else { return false }
        guard
            expect(
                !CodexWarmUpPolicy.hasUnresolvedFailure(
                    failed,
                    selection: CodexWarmUpSelection(fiveHour: false, sevenDay: false),
                    now: now
                ),
                "fresh quota evidence makes old failure display stale while warm-up is disabled"
            )
        else { return false }
        let activeProfile = profile(snapshot(five: window(used: 40, resetsIn: 600)))
        var supersededFailure = activeProfile
        supersededFailure.lastWarmUpSucceeded = false
        supersededFailure.lastWarmUpAt = now.addingTimeInterval(-600)
        guard
            expect(
                CodexWarmUpPolicy.hasUnresolvedFailure(
                    supersededFailure,
                    selection: fiveHourOnly,
                    now: now
                )
                    && CodexWarmUpPolicy.nextEligibleDate(
                        for: supersededFailure,
                        selection: fiveHourOnly,
                        now: now
                    ) == nil,
                "fresh active percentages cannot clear an ambiguous request"
            )
        else { return false }
        guard
            expect(
                CodexWarmUpPolicy.nextEligibleDate(
                    for: failed,
                    selection: fiveHourOnly,
                    unexpected: [.fiveHour],
                    now: now
                ) == nil,
                "duplicate reset observations cannot retry an ambiguous request"
            )
        else { return false }
        guard
            expect(
                CodexWarmUpPolicy.nextEligibleDate(for: idleProfile, selection: fiveHourOnly, unexpected: [.fiveHour], now: now) == now,
                "unexpected reset warms up immediately"
            )
        else { return false }
        var uncertain = profile(snapshot(five: window(used: 0, resetsIn: 18_000)))
        uncertain.lastWarmUpAt = now.addingTimeInterval(-18_020)
        uncertain.lastWarmUpSucceeded = false
        uncertain.warmUpRequest = CodexWarmUpRequest(
            id: "attempt-fixture", accountID: "acct-warm", startedAt: now.addingTimeInterval(-18_020),
            limitID: uncertain.lastSnapshot?.limitId, fiveHourResetAt: now.addingTimeInterval(-20),
            sevenDayResetAt: nil, source: "automatic")
        guard expect(CodexWarmUpPolicy.isDue(uncertain, selection: fiveHourOnly, now: now), "verified new generation permits recovery"),
            expect(!CodexWarmUpPolicy.isDue(uncertain, selection: fiveHourOnly, now: now.addingTimeInterval(901)), "expired evidence cannot recover an uncertain request"),
            expect(!CodexWarmUpPolicy.isDue(uncertain, selection: .all, now: now), "missing selected generation stays blocked"),
            expect(!CodexWarmUpPolicy.isDue(succeeded, selection: fiveHourOnly, unexpected: [.fiveHour], now: now), "duplicate reset after success respects cooldown")
        else { return false }
        var invalidDuration = uncertain
        invalidDuration.lastSnapshot = snapshot(five: window(used: 0, resetsIn: 18_000, durationMins: Int.max))
        guard expect(!CodexWarmUpPolicy.isDue(invalidDuration, selection: fiveHourOnly, now: now), "untrusted extreme duration fails closed without integer overflow") else {
            return false
        }
        guard
            expect(
                CodexWarmUpPolicy.nextEligibleDate(for: activeProfile, selection: fiveHourOnly, now: now)
                    == now.addingTimeInterval(608),
                "active window waits for reset plus grace"
            )
        else { return false }
        let anonymous = profile(snapshot(five: window(used: 0.2), email: ""))
        guard
            expect(
                CodexWarmUpPolicy.nextEligibleDate(for: anonymous, selection: fiveHourOnly, now: now) == nil,
                "missing identity blocks warm-up"
            )
        else { return false }

        // isDue：过期快照永远不触发暖号
        let stale = profile(snapshot(five: window(used: 0.2), at: now.addingTimeInterval(-16 * 60)))
        guard expect(!CodexWarmUpPolicy.isDue(stale, selection: fiveHourOnly, now: now), "stale evidence is not due") else { return false }
        let fresh = profile(snapshot(five: window(used: 0.2), at: now.addingTimeInterval(-60)))
        guard expect(CodexWarmUpPolicy.isDue(fresh, selection: fiveHourOnly, now: now), "fresh idle evidence is due") else { return false }

        // A successful minimal request can leave the displayed quota at 100%.
        // Rechecking that same reset must not keep issuing immediate requests.
        var tracker = CodexWarmUpResetTracker()
        tracker.note([.fiveHour], for: "fixture-account")
        let handled = tracker.ticket(for: "fixture-account")
        var justSucceeded = fresh
        justSucceeded.lastWarmUpAt = now
        justSucceeded.lastWarmUpSucceeded = true
        tracker.acknowledge(handled, for: "fixture-account")
        guard
            expect(
                !CodexWarmUpPolicy.isDue(
                    justSucceeded, selection: fiveHourOnly,
                    unexpected: tracker.kinds(for: "fixture-account"), now: now),
                "acknowledged reset with unchanged full quota waits for its next cycle")
        else { return false }
        tracker.note([.fiveHour], for: "fixture-account")
        let earlier = tracker.ticket(for: "fixture-account")
        tracker.note([.fiveHour, .sevenDay], for: "fixture-account")
        tracker.acknowledge(earlier, for: "fixture-account")
        guard
            expect(
                tracker.kinds(for: "fixture-account") == [.fiveHour, .sevenDay],
                "completion cannot acknowledge a newer reset received in flight")
        else { return false }
        guard
            expect(
                !CodexWarmUpPolicy.didResetUnexpectedly(previous: window(used: 30), current: nil, now: now),
                "missing official window is not proof of a reset")
        else { return false }

        // nextScheduledResetDate
        let dual = profile(
            snapshot(
                five: window(used: 40, resetsIn: 600),
                seven: window(used: 40, resetsIn: 86_400)
            ))
        guard
            expect(
                CodexWarmUpPolicy.nextScheduledResetDate(for: dual, selection: selection, now: now)
                    == now.addingTimeInterval(608),
                "scheduled reset uses earliest window"
            )
        else { return false }

        // 额度读取失败必须留下痕迹，成功后清除
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codex-warm-up-self-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        do {
            let home = root.appendingPathComponent("home", isDirectory: true)
            let support = root.appendingPathComponent("support", isDirectory: true)
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
            let store = CodexProfileStore(
                fileManager: fileManager,
                homeDirectory: home,
                applicationSupportDirectory: support
            )
            _ = try store.addManagedProfile()
            try store.discardUnverifiedManagedProfiles()
            guard let profileID = store.profiles.first?.id else {
                print("Codex warm-up policy self-test failed: missing profile")
                return false
            }
            let failedRead = UsageSnapshot(
                refreshedAt: now,
                account: AccountInfo(type: "chatgpt", planType: "plus", emailPresent: true, email: "f@example.com"),
                limitId: nil,
                limitName: nil,
                quotaReadSucceeded: false,
                fiveHourQuota: nil,
                sevenDayQuota: nil,
                monthlyQuota: nil,
                credits: nil,
                cloudLifetimeTokens: nil,
                local: nil,
                taskBoard: nil,
                messages: []
            )
            try store.record(failedRead, for: profileID)
            guard expect(store.profiles.first?.lastQuotaReadFailureAt == now, "quota failure is recorded") else { return false }
            try store.recordWarmUp(
                at: now,
                succeeded: false,
                failureReason: "timeout",
                for: profileID
            )
            guard
                expect(
                    store.profiles.first?.lastWarmUpFailureReason == "timeout",
                    "warm-up failure category is recorded"
                )
            else { return false }
            try store.recordWarmUp(at: now, succeeded: true, for: profileID)
            guard
                expect(
                    store.profiles.first?.lastWarmUpFailureReason == nil,
                    "warm-up success clears failure category"
                )
            else { return false }
            guard expect(store.profiles.first?.warmUpHistory?.count == 2, "success preserves earlier failure history"),
                expect(store.profiles.first?.warmUpHistory?.first?.failureReason == "timeout", "failure timestamp and reason remain available")
            else { return false }
            try store.record(
                testWindowSnapshot(email: "f@example.com", at: now),
                for: profileID
            )
            guard expect(store.profiles.first?.lastQuotaReadFailureAt == nil, "quota success clears failure") else { return false }
            // All credentials below are synthetic and remain under the isolated test root.
            let authURL = home.appendingPathComponent(".codex/auth.json")
            try fileManager.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            func auth(_ account: String) throws -> Data {
                let payload = try JSONSerialization.data(withJSONObject: ["email": "f@example.com"])
                    .base64EncodedString().replacingOccurrences(of: "=", with: "")
                return try JSONSerialization.data(withJSONObject: [
                    "tokens": [
                        "account_id": account, "id_token": "x.\(payload).y", "access_token": "synthetic-only",
                    ]
                ])
            }
            try auth("fixture-A").write(to: authURL, options: .atomic)
            try store.record(testWindowSnapshot(email: "f@example.com", at: now.addingTimeInterval(1)), for: profileID)
            try store.beginWarmUp(
                requestID: "request-1", for: profileID, expectedAccountID: "fixture-A",
                selection: fiveHourOnly, unexpected: [], manual: true, at: now.addingTimeInterval(2))
            let restarted = CodexProfileStore(homeDirectory: home, applicationSupportDirectory: support)
            guard let pending = restarted.profiles.first,
                expect(pending.warmUpRequest?.id == "request-1" && pending.lastWarmUpFailureReason == "pending", "in-flight request survives restart"),
                expect(
                    !CodexWarmUpPolicy.isDue(pending, selection: .all, unexpected: [.sevenDay], now: now.addingTimeInterval(3)),
                    "restart and reset ticket cannot replay pending inference")
            else { return false }
            try restarted.recordWarmUp(
                at: now.addingTimeInterval(3), succeeded: true, for: profileID,
                requestID: "request-1", expectedAccountID: "fixture-A")
            try restarted.recordWarmUp(
                at: now.addingTimeInterval(4), succeeded: false, failureReason: "timeout", for: profileID,
                requestID: "request-1", expectedAccountID: "fixture-A")
            guard expect(restarted.profiles.first?.lastWarmUpSucceeded == true, "late failure cannot downgrade request success"),
                expect(restarted.profiles.first?.warmUpHistory?.filter { $0.attemptID == "request-1" }.count == 1, "request ID deduplicates history")
            else { return false }
            try auth("fixture-B").write(to: authURL, options: .atomic)
            let changedCredentials = CodexProfileStore(homeDirectory: home, applicationSupportDirectory: support)
            guard expect(changedCredentials.profiles.first?.lastSnapshot?.accountID == "fixture-A", "startup must not relabel A quota as B") else { return false }
            do {
                try changedCredentials.recordWarmUp(
                    at: now.addingTimeInterval(5), succeeded: false, for: profileID,
                    requestID: "request-1", expectedAccountID: "fixture-A")
                return expect(false, "rebound credentials reject old completion")
            } catch CodexProfileStore.WarmUpStateError.unverifiedIdentityOrState {}
            guard expect(CodexProfileStore.safeWarmUpFailureCode("raw response with sensitive material") == "unknown", "persistence accepts only closed failure categories") else {
                return false
            }
            let stateURL = support.appendingPathComponent("CodexAccountManagerNext/account-manager-next-v1.json")
            var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            var rows = legacy["profiles"] as! [[String: Any]]
            var oldSnapshot = rows[0]["lastSnapshot"] as! [String: Any]
            oldSnapshot.removeValue(forKey: "accountID")
            rows[0]["lastSnapshot"] = oldSnapshot
            legacy["profiles"] = rows
            try JSONSerialization.data(withJSONObject: legacy).write(to: stateURL, options: .atomic)
            let migrated = CodexProfileStore(homeDirectory: home, applicationSupportDirectory: support)
            guard
                expect(
                    migrated.profiles.first?.lastSnapshot?.accountID == "fixture-B"
                        && migrated.profiles.first?.lastSnapshot?.quotaReadSucceeded == false, "missing ID backfill invalidates old quota evidence")
            else { return false }
        } catch {
            print("Codex warm-up policy self-test failed: \(error.localizedDescription)")
            return false
        }

        print("Codex warm-up policy self-test passed")
        return true
    }

    private static func testWindowSnapshot(email: String, at date: Date) -> UsageSnapshot {
        UsageSnapshot(
            refreshedAt: date,
            account: AccountInfo(type: "chatgpt", planType: "plus", emailPresent: true, email: email),
            limitId: "codex",
            limitName: nil,
            quotaReadSucceeded: true,
            fiveHourQuota: nil,
            sevenDayQuota: RateWindow(usedPercent: 12, windowDurationMins: 10_080, resetsAt: nil),
            monthlyQuota: nil,
            credits: nil,
            cloudLifetimeTokens: nil,
            local: nil,
            taskBoard: nil,
            messages: []
        )
    }
}
