import Foundation

/// A reviewed display-only preset. Never derive this from a machine's defaults
/// domain: account data, endpoints, permissions and window placement stay local.
enum PortableFirstRunPreferences {
    static let appliedKey = "AiGoodBro.portableFirstRunPreferences.v1"
    static let inProgressKey = "AiGoodBro.portableFirstRunPreferences.inProgress.v1"

    static let values: [String: Any] = [
        "CodexManagerNext.interfaceLanguage": "zh",
        "CodexManagerNext.interfaceThemeMode": "system",
        "CodexManagerNext.accountWorkspaceLayout": "cards",
        "CodexManagerNext.workspaceDisplayMode": "simple",
        "CodexManagerNext.simpleWorkspacePreset": "accountCards",
        "CodexManagerNext.accountMenuTransparency": "clear",
        "AiGoodBro.workspace.glass": Data(#"{"systemGlass":true,"opacity":74,"depth":84}"#.utf8),
        "AiGoodBro.edgeDock.v1": Data(#"{"enabled":true,"mode":"autoHide","side":"right","warnColors":true}"#.utf8),
        "AiGoodBro.home.dashboard.preferences": Data(#"{"range":"all","mode":"kline","height":260,"splitRatio":0.28}"#.utf8),
        "CodexManagerNext.statusItem.displayMode": "classic",
        "CodexManagerNext.statusItem.quotaMode": "remaining",
        "CodexManagerNext.statusItem.visibleMetrics": ["sevenDayQuota"],
        "CodexManagerNext.statusItem.showsResetCountdown": true,
        "CodexManagerNext.statusItem.metricsSchemaVersion": 3,
        "CodexManagerNext.globalShortcut.enabled": true,
        "CodexManagerNext.globalShortcut.keyCode": 32,
        "CodexManagerNext.globalShortcut.modifiers": 256,
        "CodexManagerNext.globalShortcut.keyLabel": "U",
    ]

    /// Capture this before services create their first cache/profile snapshot.
    /// Presence matters, including false, zero, empty and unreadable values.
    static func hasExistingUser(
        defaults: UserDefaults, supportDirectory: URL? = nil, persistentDomainName: String? = nil, fileManager: FileManager = .default
    ) -> Bool {
        // This marker was persisted while the domain was empty. Later service
        // caches or a partial seed are our interrupted first launch, not a user.
        if isInProgress(defaults: defaults) { return false }
        let domainName = persistentDomainName ?? (defaults === UserDefaults.standard ? Bundle.main.bundleIdentifier : nil)
        let domainKeys = domainName.flatMap { defaults.persistentDomain(forName: $0) }.map { Array($0.keys) } ?? []
        let namespacedKeys = defaults.dictionaryRepresentation().keys.filter { key in
            ["CodexManagerNext.", "AiGoodBro.", "CodexAccountManagerNext."].contains(where: key.hasPrefix)
        }
        if (domainKeys + namespacedKeys).contains(where: { $0 != "CodexManagerNext.installationOnboarding.v1" }) {
            return true
        }
        guard let supportDirectory else { return false }
        return ["account-manager-next-v1.json", "local-cli-accounts-v1.json", "claude-subscriptions"].contains { name in
            fileManager.fileExists(atPath: supportDirectory.appendingPathComponent(name).path)
        }
    }

    /// Establish recovery provenance before UsageStore creates any state. Do not
    /// infer first-run recovery from cache names or from installation receipts.
    static func prepareForStartup(
        defaults: UserDefaults, supportDirectory: URL? = nil, persistentDomainName: String? = nil, fileManager: FileManager = .default
    ) -> Bool {
        let existingUser = hasExistingUser(
            defaults: defaults, supportDirectory: supportDirectory, persistentDomainName: persistentDomainName, fileManager: fileManager)
        if !existingUser, !isInProgress(defaults: defaults) {
            defaults.set(true, forKey: inProgressKey)
            defaults.synchronize()
        }
        return existingUser
    }

    private static func isInProgress(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: appliedKey) == nil && defaults.bool(forKey: inProgressKey)
    }

    @discardableResult
    static func seedIfNeeded(defaults: UserDefaults, existingUser: Bool) -> Bool {
        guard defaults.object(forKey: appliedKey) == nil, !existingUser || isInProgress(defaults: defaults) else { return false }
        // AppSettings can also be constructed without the application owner.
        // Persist this before the first display value so interruption can resume.
        if !isInProgress(defaults: defaults) {
            defaults.set(true, forKey: inProgressKey)
            defaults.synchronize()
        }
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: appliedKey)
        defaults.synchronize()
        defaults.removeObject(forKey: inProgressKey)
        return true
    }
}
