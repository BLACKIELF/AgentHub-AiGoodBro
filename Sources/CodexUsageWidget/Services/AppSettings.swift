import Cocoa
import Combine
import SwiftUI

enum WidgetLanguage: String, CaseIterable, Equatable {
    case zh
    case en

    static let storageKey = "CodexManagerNext.interfaceLanguage"

    static var automatic: WidgetLanguage {
        let identifier = TimeZone.current.identifier
        let chineseTimeZones: Set<String> = [
            "Asia/Shanghai",
            "Asia/Chongqing",
            "Asia/Harbin",
            "Asia/Urumqi",
            "Asia/Hong_Kong",
            "Asia/Macau",
            "Asia/Taipei",
        ]
        return chineseTimeZones.contains(identifier) ? .zh : .en
    }

    var isChinese: Bool { self == .zh }

    var locale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_US") }

    func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }

    func tokens(_ value: Int64?) -> String {
        isChinese ? TokenFormatter.formatChineseTotal(value) : TokenFormatter.format(value)
    }

    static func storedOrAutomatic(defaults: UserDefaults = .standard) -> WidgetLanguage {
        guard let rawValue = defaults.string(forKey: storageKey),
            let language = WidgetLanguage(rawValue: rawValue)
        else { return .zh }
        return language
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    func text(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}

private struct WidgetLanguageEnvironmentKey: EnvironmentKey {
    static var defaultValue: WidgetLanguage { .storedOrAutomatic() }
}

extension EnvironmentValues {
    var widgetLanguage: WidgetLanguage {
        get { self[WidgetLanguageEnvironmentKey.self] }
        set { self[WidgetLanguageEnvironmentKey.self] = newValue }
    }
}

enum WidgetThemeMode: String, CaseIterable, Equatable {
    case system
    case light
    case dark

    static let storageKey = "CodexManagerNext.interfaceThemeMode"

    static func storedOrDefault(defaults: UserDefaults = .standard) -> WidgetThemeMode {
        guard let rawValue = defaults.string(forKey: storageKey),
            let mode = WidgetThemeMode(rawValue: rawValue)
        else { return .dark }
        return mode
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    func applyAppearance() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum ParticleAnimationMode: String, CaseIterable, Equatable {
    case standard = "default"
    case powerSaving = "powerSaving"

    static let storageKey = "CodexManagerNext.particleAnimationMode"

    static func storedOrDefault(defaults: UserDefaults = .standard) -> ParticleAnimationMode {
        guard let rawValue = defaults.string(forKey: storageKey),
            let mode = ParticleAnimationMode(rawValue: rawValue)
        else { return .standard }
        return mode
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

enum AccountMenuTransparency: String, CaseIterable, Equatable {
    case clear
    case standard
    case frosted

    static let storageKey = "CodexManagerNext.accountMenuTransparency"

    static func storedOrDefault(defaults: UserDefaults = .standard) -> AccountMenuTransparency {
        guard let rawValue = defaults.string(forKey: storageKey),
            let value = AccountMenuTransparency(rawValue: rawValue)
        else { return .standard }
        return value
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

enum PaletteSelectionResult: Equatable {
    case selected
    case unavailable
}

enum AccountWorkspaceLayout: String, CaseIterable {
    case rows
    case cards

    static let storageKey = "CodexManagerNext.accountWorkspaceLayout"

    static func storedOrDefault(defaults: UserDefaults) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .rows
    }
}

enum WorkspaceDisplayMode: String, CaseIterable, Equatable {
    case professional
    case simple

    static let storageKey = "CodexManagerNext.workspaceDisplayMode"

    static func storedOrDefault(defaults: UserDefaults) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .professional
    }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .professional: language.text("专业", "Professional")
        case .simple: language.text("极简", "Simple")
        }
    }
}

enum SimpleWorkspacePreset: String, CaseIterable, Equatable {
    case overview
    case accountCards
    case custom

    static let storageKey = "CodexManagerNext.simpleWorkspacePreset"

    static func storedOrDefault(defaults: UserDefaults) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .overview
    }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .overview: language.text("总览", "Overview")
        case .accountCards: language.text("账号卡片", "Account cards")
        case .custom: language.text("自定义", "Custom")
        }
    }
}

struct PaletteFallbackNotice: Equatable {
    let unavailableID: String
}

final class AppSettings: ObservableObject {
    @Published var statisticsEngine: StatisticsEngineChoice = .stored() {
        didSet { defaults.set(statisticsEngine.rawValue, forKey: StatisticsEngineChoice.storageKey) }
    }

    private static let keepMainWindowOnTopKey = "CodexManagerNext.keepMainWindowOnTop"
    private static let keepRunningWhenMainWindowClosedKey = "CodexManagerNext.keepRunningWhenMainWindowClosed"
    private static let visibleRuntimeScopesKey = "CodexManagerNext.visibleRuntimeScopes"
    private static let automaticUpdateChecksEnabledKey = "CodexManagerNext.update.autoCheckEnabled"
    private static let skippedUpdateVersionKey = "CodexManagerNext.update.skippedVersion"
    private static let paletteIDKey = "CodexManagerNext.paletteID"
    private static let simpleCustomShowPlatformOverviewKey = "CodexManagerNext.simpleCustomShowPlatformOverview"
    private static let simpleCustomShowMonitoredQuotaKey = "CodexManagerNext.simpleCustomShowMonitoredQuota"
    private static let simpleCustomShowCodexAccountsKey = "CodexManagerNext.simpleCustomShowCodexAccounts"
    private static let simpleCustomShowUsageAutomationKey = "CodexManagerNext.simpleCustomShowUsageAutomation"

    private let defaults: UserDefaults
    let paletteCatalog: PaletteCatalog

    @Published var language: WidgetLanguage {
        didSet {
            language.persist(defaults: defaults)
        }
    }

    @Published var themeMode: WidgetThemeMode {
        didSet {
            themeMode.persist(defaults: defaults)
            themeMode.applyAppearance()
        }
    }

    @Published var particleAnimationMode: ParticleAnimationMode {
        didSet {
            particleAnimationMode.persist(defaults: defaults)
        }
    }

    @Published var usageTrendWindow: UsageTrendWindow {
        didSet {
            usageTrendWindow.persist(defaults: defaults)
        }
    }

    @Published var tokenUsageHomeRange: TokenUsageHomeRange {
        didSet { defaults.set(tokenUsageHomeRange.rawValue, forKey: TokenUsageHomeRange.storageKey) }
    }

    @Published var tokenUsageHomeCustomStart: Date {
        didSet { defaults.set(tokenUsageHomeCustomStart, forKey: TokenUsageHomeRange.customStartKey) }
    }

    @Published var accountMenuTransparency: AccountMenuTransparency {
        didSet {
            accountMenuTransparency.persist(defaults: defaults)
        }
    }

    @Published var homeModuleArrangement: WorkspaceModuleArrangement {
        didSet { defaults.set(try? JSONEncoder().encode(homeModuleArrangement), forKey: WorkspaceModuleArrangement.storageKey) }
    }

    @Published var agentNavigation: AgentNavigationState {
        didSet { defaults.set(agentNavigation.encoded(), forKey: AgentNavigationState.storageKey) }
    }

    @Published var accountAvatars: AccountAvatarTable {
        didSet { defaults.set(try? JSONEncoder().encode(accountAvatars), forKey: AccountAvatarTable.storageKey) }
    }

    @Published var floatingBubble: TokenMonitorFloatingBubblePreferences {
        didSet { defaults.set(try? JSONEncoder().encode(floatingBubble), forKey: TokenMonitorFloatingBubblePreferences.storageKey) }
    }

    @Published var onboarding: WorkspaceOnboardingState {
        didSet { defaults.set(onboarding.encoded(), forKey: WorkspaceOnboardingState.storageKey) }
    }

    @Published var appIconStyle: AppIconStyle {
        didSet {
            appIconStyle.persist(defaults: defaults)
            _ = appIconStyle.applyToRunningApp()
        }
    }

    let avatarAssetStore: AccountAvatarAssetStore

    @Published var accountWorkspaceLayout: AccountWorkspaceLayout {
        didSet { defaults.set(accountWorkspaceLayout.rawValue, forKey: AccountWorkspaceLayout.storageKey) }
    }

    @Published var pinnedAccountKey: String? {
        didSet { defaults.set(pinnedAccountKey, forKey: "CodexManagerNext.pinnedAccountKey") }
    }

    @Published var workspaceDisplayMode: WorkspaceDisplayMode {
        didSet { defaults.set(workspaceDisplayMode.rawValue, forKey: WorkspaceDisplayMode.storageKey) }
    }

    @Published var simpleWorkspacePreset: SimpleWorkspacePreset {
        didSet { defaults.set(simpleWorkspacePreset.rawValue, forKey: SimpleWorkspacePreset.storageKey) }
    }

    @Published var simpleCustomShowPlatformOverview: Bool {
        didSet { defaults.set(simpleCustomShowPlatformOverview, forKey: Self.simpleCustomShowPlatformOverviewKey) }
    }

    @Published var simpleCustomShowMonitoredQuota: Bool {
        didSet { defaults.set(simpleCustomShowMonitoredQuota, forKey: Self.simpleCustomShowMonitoredQuotaKey) }
    }

    @Published var simpleCustomShowCodexAccounts: Bool {
        didSet { defaults.set(simpleCustomShowCodexAccounts, forKey: Self.simpleCustomShowCodexAccountsKey) }
    }

    @Published var simpleCustomShowUsageAutomation: Bool {
        didSet { defaults.set(simpleCustomShowUsageAutomation, forKey: Self.simpleCustomShowUsageAutomationKey) }
    }

    var hasSimpleCustomModules: Bool {
        simpleCustomShowPlatformOverview
            || simpleCustomShowMonitoredQuota
            || simpleCustomShowCodexAccounts
            || simpleCustomShowUsageAutomation
    }

    func restoreSimpleCustomModules() {
        simpleCustomShowPlatformOverview = true
        simpleCustomShowMonitoredQuota = true
        simpleCustomShowCodexAccounts = true
        simpleCustomShowUsageAutomation = true
    }

    @Published private(set) var paletteID: String
    @Published private(set) var paletteFallbackNotice: PaletteFallbackNotice?

    @Published var setupProgress: NextSetupProgress {
        didSet { setupProgress.save(to: defaults) }
    }

    @Published var keepMainWindowOnTop: Bool {
        didSet {
            defaults.set(keepMainWindowOnTop, forKey: Self.keepMainWindowOnTopKey)
        }
    }

    @Published var keepRunningWhenMainWindowClosed: Bool {
        didSet {
            defaults.set(keepRunningWhenMainWindowClosed, forKey: Self.keepRunningWhenMainWindowClosedKey)
        }
    }

    @Published var automaticUpdateChecksEnabled: Bool {
        didSet {
            defaults.set(automaticUpdateChecksEnabled, forKey: Self.automaticUpdateChecksEnabledKey)
        }
    }

    @Published private(set) var skippedUpdateVersion: String? {
        didSet {
            if let skippedUpdateVersion {
                defaults.set(skippedUpdateVersion, forKey: Self.skippedUpdateVersionKey)
            } else {
                defaults.removeObject(forKey: Self.skippedUpdateVersionKey)
            }
        }
    }

    @Published private(set) var visibleRuntimeScopes: [RuntimeScope] {
        didSet {
            defaults.set(visibleRuntimeScopes.map(\.runtimeId), forKey: Self.visibleRuntimeScopesKey)
        }
    }

    @Published private(set) var statusItemPreferences: StatusItemPreferences
    @Published private(set) var globalShortcut: GlobalShortcut?
    @Published private(set) var globalShortcutError: GlobalShortcutError?
    var globalShortcutRegistration: ((GlobalShortcut) -> Result<Void, GlobalShortcutRegistrationFailure>)?
    var globalShortcutUnregistration: (() -> Result<Void, GlobalShortcutRegistrationFailure>)?

    init(
        defaults: UserDefaults = .standard,
        paletteCatalog: PaletteCatalog = .loadFromMainBundle(),
        previewAvatarRoot: URL? = nil
    ) {
        self.defaults = defaults
        statisticsEngine = .stored(defaults: defaults)
        self.paletteCatalog = paletteCatalog
        setupProgress = .load(from: defaults)
        let storedPaletteID = defaults.string(forKey: Self.paletteIDKey)
        let initialPaletteID = paletteCatalog.contains(PaletteCatalog.initialPaletteID)
            ? PaletteCatalog.initialPaletteID : PaletteCatalog.defaultPaletteID
        if let storedPaletteID, paletteCatalog.contains(storedPaletteID) {
            paletteID = storedPaletteID
            paletteFallbackNotice = nil
        } else if let storedPaletteID {
            paletteID = PaletteCatalog.defaultPaletteID
            paletteFallbackNotice = PaletteFallbackNotice(unavailableID: storedPaletteID)
            defaults.set(PaletteCatalog.defaultPaletteID, forKey: Self.paletteIDKey)
        } else {
            paletteID = initialPaletteID
            paletteFallbackNotice = nil
            defaults.set(initialPaletteID, forKey: Self.paletteIDKey)
        }
        language = WidgetLanguage.storedOrAutomatic(defaults: defaults)
        themeMode = WidgetThemeMode.storedOrDefault(defaults: defaults)
        particleAnimationMode = ParticleAnimationMode.storedOrDefault(defaults: defaults)
        usageTrendWindow = UsageTrendWindow.storedOrDefault(defaults: defaults)
        tokenUsageHomeRange = TokenUsageHomeRange.storedOrDefault(defaults: defaults)
        tokenUsageHomeCustomStart =
            (defaults.object(forKey: TokenUsageHomeRange.customStartKey) as? Date)
            ?? Calendar.current.date(byAdding: .day, value: -29, to: Date())
            ?? Date()
        accountMenuTransparency = AccountMenuTransparency.storedOrDefault(defaults: defaults)
        homeModuleArrangement = WorkspaceModuleArrangement.load(defaults.data(forKey: WorkspaceModuleArrangement.storageKey))
        var navigationBackup: Data?
        agentNavigation = AgentNavigationState.load(defaults.data(forKey: AgentNavigationState.storageKey), backupRaw: &navigationBackup)
        if let navigationBackup {
            defaults.set(navigationBackup, forKey: AgentNavigationState.backupKey)
        }
        accountAvatars = AccountAvatarTable.load(defaults.data(forKey: AccountAvatarTable.storageKey))
        floatingBubble = TokenMonitorFloatingBubblePreferences.load(defaults.data(forKey: TokenMonitorFloatingBubblePreferences.storageKey))
        var onboardingBackup: Data?
        onboarding = WorkspaceOnboardingState.load(defaults.data(forKey: WorkspaceOnboardingState.storageKey), backupRaw: &onboardingBackup)
        if let onboardingBackup {
            defaults.set(onboardingBackup, forKey: WorkspaceOnboardingState.backupKey)
        }
        appIconStyle = AppIconStyle.storedOrDefault(defaults: defaults)
        let avatarRoot = previewAvatarRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("AiGoodBro/avatars", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("AiGoodBro-avatars")
        avatarAssetStore = AccountAvatarAssetStore(root: avatarRoot)
        accountWorkspaceLayout = AccountWorkspaceLayout.storedOrDefault(defaults: defaults)
        let storedPinnedAccountKey = defaults.string(forKey: "CodexManagerNext.pinnedAccountKey")
        pinnedAccountKey = storedPinnedAccountKey
        let existingUser =
            defaults.object(forKey: WorkspaceDisplayMode.storageKey) != nil
            || defaults.bool(forKey: "CodexManagerNext.setup.dismissed")
            || defaults.bool(forKey: "CodexManagerNext.setup.completed")
            || storedPinnedAccountKey != nil
        workspaceDisplayMode =
            defaults.string(forKey: WorkspaceDisplayMode.storageKey).flatMap(WorkspaceDisplayMode.init(rawValue:))
            ?? (existingUser ? .professional : .simple)
        simpleWorkspacePreset = SimpleWorkspacePreset.storedOrDefault(defaults: defaults)
        simpleCustomShowPlatformOverview = Self.storedFlag(
            defaults: defaults, key: Self.simpleCustomShowPlatformOverviewKey, defaultValue: true)
        simpleCustomShowMonitoredQuota = Self.storedFlag(
            defaults: defaults, key: Self.simpleCustomShowMonitoredQuotaKey, defaultValue: true)
        simpleCustomShowCodexAccounts = Self.storedFlag(
            defaults: defaults, key: Self.simpleCustomShowCodexAccountsKey, defaultValue: true)
        simpleCustomShowUsageAutomation = Self.storedFlag(
            defaults: defaults, key: Self.simpleCustomShowUsageAutomationKey, defaultValue: true)
        keepMainWindowOnTop = defaults.bool(forKey: Self.keepMainWindowOnTopKey)
        if defaults.object(forKey: Self.keepRunningWhenMainWindowClosedKey) == nil {
            keepRunningWhenMainWindowClosed = true
        } else {
            keepRunningWhenMainWindowClosed = defaults.bool(forKey: Self.keepRunningWhenMainWindowClosedKey)
        }
        if defaults.object(forKey: Self.automaticUpdateChecksEnabledKey) == nil {
            automaticUpdateChecksEnabled = true
        } else {
            automaticUpdateChecksEnabled = defaults.bool(forKey: Self.automaticUpdateChecksEnabledKey)
        }
        skippedUpdateVersion = defaults.string(forKey: Self.skippedUpdateVersionKey)
        visibleRuntimeScopes = Self.storedVisibleRuntimeScopes(defaults: defaults)
        statusItemPreferences = StatusItemPreferencesStore.load(defaults: defaults)
        let storedShortcut = GlobalShortcut.load(defaults: defaults)
        if let storedShortcut, storedShortcut.validationError != nil {
            globalShortcut = .default
            GlobalShortcut.default.save(defaults: defaults)
        } else {
            globalShortcut = storedShortcut
        }
        globalShortcutError = nil
        onboarding.bootstrapIfNeeded(existingUser: existingUser)
        defaults.set(onboarding.encoded(), forKey: WorkspaceOnboardingState.storageKey)
        _ = appIconStyle.applyToRunningApp()
    }

    func avatarImage(for profileID: String) -> NSImage? {
        guard let assetID = accountAvatars.record(for: profileID).assetID else { return nil }
        return avatarAssetStore.load(assetID: assetID)
    }

    func setAvatar(_ record: AccountAvatarRecord, for profileID: String) {
        var table = accountAvatars
        table.set(record, for: profileID)
        accountAvatars = table
    }

    @discardableResult
    func selectPalette(_ id: String) -> PaletteSelectionResult {
        guard paletteCatalog.contains(id) else {
            paletteFallbackNotice = PaletteFallbackNotice(unavailableID: id)
            return .unavailable
        }
        paletteID = id
        paletteFallbackNotice = nil
        defaults.set(id, forKey: Self.paletteIDKey)
        return .selected
    }

    func resetPalette() {
        _ = selectPalette(paletteCatalog.contains(PaletteCatalog.initialPaletteID)
            ? PaletteCatalog.initialPaletteID : PaletteCatalog.defaultPaletteID)
    }

    func isRuntimeVisible(_ scope: RuntimeScope) -> Bool {
        visibleRuntimeScopes.contains(scope)
    }

    @discardableResult
    func setRuntime(_ scope: RuntimeScope, visible: Bool) -> Bool {
        if visible {
            visibleRuntimeScopes = Self.orderedRuntimeScopes(Set(visibleRuntimeScopes + [scope]))
            return true
        }
        guard visibleRuntimeScopes.count > 1 else {
            return false
        }
        visibleRuntimeScopes = visibleRuntimeScopes.filter { $0 != scope }
        return true
    }

    private static func storedFlag(defaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    private static func storedVisibleRuntimeScopes(defaults: UserDefaults) -> [RuntimeScope] {
        guard let identifiers = defaults.array(forKey: visibleRuntimeScopesKey) as? [String] else {
            return RuntimeScope.allCases
        }
        let scopes = identifiers.compactMap(RuntimeScope.storedIdentifier)
        let ordered = orderedRuntimeScopes(Set(scopes))
        return ordered.isEmpty ? RuntimeScope.allCases : ordered
    }

    private static func orderedRuntimeScopes(_ scopes: Set<RuntimeScope>) -> [RuntimeScope] {
        RuntimeScope.allCases.filter { scopes.contains($0) }
    }

    @discardableResult
    func updateStatusItemPreferences(
        _ mutation: (inout StatusItemPreferences) -> Void
    ) -> Result<Void, StatusItemPreferenceError> {
        var candidate = statusItemPreferences
        mutation(&candidate)
        if let error = candidate.validationError() {
            return .failure(error)
        }
        candidate = candidate.normalized()
        guard candidate != statusItemPreferences else {
            return .success(())
        }
        statusItemPreferences = candidate
        StatusItemPreferencesStore.save(candidate, defaults: defaults)
        return .success(())
    }

    func resetStatusItemPreferences() {
        StatusItemPreferencesStore.reset(defaults: defaults)
        statusItemPreferences = .accountRing
    }

    @discardableResult
    func requestGlobalShortcut(_ shortcut: GlobalShortcut) -> Bool {
        if let current = globalShortcut, shortcut.matchesRegistration(of: current) {
            globalShortcut = shortcut
            shortcut.save(defaults: defaults)
            globalShortcutError = nil
            return true
        }
        if let error = shortcut.validationError {
            globalShortcutError = .invalid(error)
            return false
        }
        guard let result = globalShortcutRegistration?(shortcut) else {
            globalShortcutError = .registrationFailed
            return false
        }
        switch result {
        case .success:
            break
        case .failure(.occupied):
            globalShortcutError = .occupied
            return false
        case .failure(.failed):
            globalShortcutError = .registrationFailed
            return false
        }
        globalShortcut = shortcut
        shortcut.save(defaults: defaults)
        globalShortcutError = nil
        return true
    }

    func resetGlobalShortcut() {
        requestGlobalShortcut(.default)
    }

    func clearGlobalShortcut() {
        guard let globalShortcutUnregistration else {
            globalShortcutError = .unregistrationFailed
            return
        }
        guard case .success = globalShortcutUnregistration() else {
            globalShortcutError = .unregistrationFailed
            return
        }
        globalShortcut = nil
        GlobalShortcut.clear(defaults: defaults)
        globalShortcutError = nil
    }

    func handleInitialGlobalShortcutFailure(defaultRegistered: Bool) {
        if defaultRegistered {
            globalShortcut = .default
            globalShortcutError = .savedShortcutUnavailableUsingDefault
        } else {
            globalShortcut = nil
            globalShortcutError = .noShortcutAvailable
        }
    }

    func skipUpdateVersion(_ version: String) {
        skippedUpdateVersion = version
    }

    func clearSkippedUpdateVersion() {
        skippedUpdateVersion = nil
    }
}
