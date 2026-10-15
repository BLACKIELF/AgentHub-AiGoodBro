import Foundation

/// Also exercised by the isolated native fixture without starting the app.
enum PortableFirstRunPreferencesSelfTest {
    static func run() -> Bool {
        var assertions = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            assertions += 1
            if !condition { failures.append(message) }
        }
        func isolated(_ body: (UserDefaults, String) -> Void) {
            let suite = "AiGoodBro.portable-first-run-self-test.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                failures.append("isolated defaults unavailable")
                return
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            body(defaults, suite)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-first-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func settings(_ defaults: UserDefaults, existingUser: Bool? = nil) -> AppSettings {
            AppSettings(defaults: defaults, previewAvatarRoot: root.appendingPathComponent("avatars"), hasExistingUser: existingUser)
        }
        let allowedKeys: Set<String> = [
            "CodexManagerNext.interfaceLanguage", "CodexManagerNext.interfaceThemeMode", "CodexManagerNext.accountWorkspaceLayout",
            "CodexManagerNext.workspaceDisplayMode", "CodexManagerNext.simpleWorkspacePreset", "CodexManagerNext.accountMenuTransparency",
            "AiGoodBro.workspace.glass", "AiGoodBro.edgeDock.v1", "AiGoodBro.home.dashboard.preferences",
            "CodexManagerNext.statusItem.displayMode", "CodexManagerNext.statusItem.quotaMode", "CodexManagerNext.statusItem.visibleMetrics",
            "CodexManagerNext.statusItem.showsResetCountdown", "CodexManagerNext.statusItem.metricsSchemaVersion",
            "CodexManagerNext.globalShortcut.enabled", "CodexManagerNext.globalShortcut.keyCode", "CodexManagerNext.globalShortcut.modifiers",
            "CodexManagerNext.globalShortcut.keyLabel",
        ]
        expect(Set(PortableFirstRunPreferences.values.keys) == allowedKeys, "preset contains only the reviewed display whitelist")
        for (key, fields) in [
            (WorkspaceGlassPreferences.storageKey, Set(["systemGlass", "opacity", "depth"])),
            (TokenMonitorEdgeDockPreferences.storageKey, Set(["enabled", "mode", "side", "warnColors"])),
            (HomeDashboardPreferences.storageKey, Set(["range", "mode", "height", "splitRatio"])),
        ] {
            let data = PortableFirstRunPreferences.values[key] as? Data ?? Data()
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            expect(Set(payload.keys) == fields, "display JSON omits identities, paths, positions, history and permissions")
        }

        isolated { defaults, suite in
            expect(!PortableFirstRunPreferences.hasExistingUser(defaults: defaults), "empty configuration is new before seeding")
            let fresh = settings(defaults)
            expect(fresh.themeMode == .system && fresh.language == .zh, "new user uses system theme and Chinese")
            expect(
                fresh.accountWorkspaceLayout == .cards && fresh.workspaceDisplayMode == .simple && fresh.simpleWorkspacePreset == .accountCards,
                "new user starts with simple account cards")
            expect(fresh.workspaceGlass == .init(opacity: 74, depth: 84) && fresh.accountMenuTransparency == .clear, "new user glass uses reviewed values")
            expect(
                fresh.edgeDock.enabled && fresh.edgeDock.mode == .autoHide && fresh.edgeDock.side == .right && fresh.edgeDock.warnColors,
                "new user has the right auto-hide rail")
            expect(fresh.edgeDock.displayID == nil && fresh.edgeDock.items == nil, "rail follows local displays and connected accounts")
            expect(
                fresh.homeDashboardPreferences.range == "all" && fresh.homeDashboardPreferences.mode == "kline"
                    && fresh.homeDashboardPreferences.height == 260 && fresh.homeDashboardPreferences.splitRatio == 0.28, "new dashboard uses all-time K-line layout")
            expect(
                fresh.statusItemPreferences.displayMode == .classic && fresh.statusItemPreferences.quotaMode == .remaining
                    && fresh.statusItemPreferences.visibleMetrics == [.sevenDayQuota] && fresh.statusItemPreferences.showsResetCountdown,
                "new menu shows weekly remaining quota and countdown")
            expect(
                fresh.globalShortcut == .default && GlobalShortcut.default.displayName == "⌘U" && GlobalShortcut.edgeDock.displayName == "⌘I",
                "new user keeps the native main-window and rail shortcuts")
            expect(
                fresh.onboarding.status == .notStarted && fresh.onboarding.shouldPresent && !fresh.onboarding.existingUserMigrated
                    && fresh.setupProgress.shouldPresentAutomatically, "seeding never completes first-run onboarding")
            expect(fresh.resetCreditAutoPreferences.authorizedAccounts.isEmpty, "display preset grants no automatic consumption permission")
            let before = (defaults.persistentDomain(forName: suite) ?? [:]).filter { PortableFirstRunPreferences.values[$0.key] != nil }
            let reopened = settings(defaults)
            expect(
                reopened.onboarding.status == .notStarted && reopened.onboarding.shouldPresent && !reopened.onboarding.existingUserMigrated,
                "restarting a newly seeded app continues first-run onboarding")
            expect(reopened.themeMode == .system && reopened.workspaceDisplayMode == .simple, "second launch keeps the seeded choices")
            expect(!PortableFirstRunPreferences.seedIfNeeded(defaults: defaults, existingUser: true), "second launch never seeds again")
            let after = (defaults.persistentDomain(forName: suite) ?? [:]).filter { PortableFirstRunPreferences.values[$0.key] != nil }
            expect(NSDictionary(dictionary: before).isEqual(to: after), "second launch preserves every portable preference")
            fresh.onboarding.begin()
            let inProgress = settings(defaults)
            expect(inProgress.onboarding.status == .inProgress && inProgress.onboarding.shouldPresent, "unfinished first-run progress survives reopen")
            fresh.onboarding.finish(.completed)
            expect(!settings(defaults).onboarding.shouldPresent, "completed first-run remains complete")
            WidgetThemeMode.light.persist(defaults: defaults)
            fresh.edgeDock.enabled = false
            fresh.workspaceGlass = .init(systemGlass: false, opacity: 0, depth: 0)
            GlobalShortcut.clear(defaults: defaults)
            let overwritten = settings(defaults)
            expect(
                overwritten.themeMode == .light && !overwritten.edgeDock.enabled && overwritten.workspaceGlass.opacity == 0
                    && overwritten.workspaceGlass.depth == 0 && overwritten.globalShortcut == nil, "reinstall preserves choices and explicit opt-outs")
        }

        for (key, value) in [
            ("CodexManagerNext.keepRunningWhenMainWindowClosed", false as Any),
            ("CodexManagerNext.someSavedZero", 0 as Any),
            ("CodexManagerNext.someSavedEmpty", "" as Any),
            ("AiGoodBro.someSavedEmptyList", [] as [String]),
            ("AiGoodBro.someSavedEmptyData", Data()),
            ("CodexAccountManagerNext.accountFloatingPanel.v1", "" as Any),
            (PortableFirstRunPreferences.inProgressKey, false as Any),
            (PortableFirstRunPreferences.appliedKey, false as Any),
        ] {
            isolated { defaults, _ in
                defaults.set(value, forKey: key)
                expect(PortableFirstRunPreferences.hasExistingUser(defaults: defaults), "presence detects saved false/zero/empty configuration")
                expect(PortableFirstRunPreferences.prepareForStartup(defaults: defaults), "returning user is not marked as an interrupted first run")
                let restored = settings(defaults)
                expect(
                    (key == PortableFirstRunPreferences.appliedKey || defaults.object(forKey: PortableFirstRunPreferences.appliedKey) == nil)
                        && defaults.object(forKey: WorkspaceGlassPreferences.storageKey) == nil && !restored.edgeDock.enabled,
                    "any saved configuration prevents the new preset")
                expect(NSDictionary(dictionary: [key: value]).isEqual(to: [key: defaults.object(forKey: key)!]), "saved false/zero/empty value survives initialization")
                expect(restored.onboarding.existingUserMigrated, "preexisting configuration uses returning-user migration")
            }
        }

        for name in ["account-manager-next-v1.json", "local-cli-accounts-v1.json", "claude-subscriptions"] {
            isolated { defaults, _ in
                let support = root.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let file = support.appendingPathComponent(name)
                try? Data().write(to: file)
                let existingUser = PortableFirstRunPreferences.hasExistingUser(defaults: defaults, supportDirectory: support)
                expect(existingUser, "account storage presence is sufficient even if empty or unreadable")
                let restored = settings(defaults, existingUser: existingUser)
                expect(
                    defaults.object(forKey: PortableFirstRunPreferences.appliedKey) == nil && !restored.edgeDock.enabled,
                    "account-only user is never seeded")
                expect((try? Data(contentsOf: file)) == Data(), "detection does not read or modify account storage")
            }
        }
        for key in ["NSWindow Frame Synthetic", "custom.importedPreference"] {
            isolated { defaults, suite in
                defaults.set("", forKey: key)
                let existingUser = PortableFirstRunPreferences.hasExistingUser(defaults: defaults, persistentDomainName: suite)
                expect(existingUser, "any key in the app's persistent domain counts as existing configuration")
                _ = settings(defaults, existingUser: existingUser)
                expect(
                    defaults.object(forKey: PortableFirstRunPreferences.appliedKey) == nil && defaults.string(forKey: key) == "",
                    "window-only or unknown imported preferences prevent seeding and survive")
            }
        }
        isolated { defaults, _ in
            let support = root.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? Data("synthetic installation metadata".utf8).write(to: support.appendingPathComponent("install-receipt-v1.json"))
            defaults.set(Data(), forKey: InstallationOnboardingState.storageKey)
            expect(!PortableFirstRunPreferences.hasExistingUser(defaults: defaults, supportDirectory: support), "receipt and install event alone never imply an existing user")
            _ = settings(defaults)
            expect(defaults.bool(forKey: PortableFirstRunPreferences.appliedKey), "installation metadata alone still permits new-user defaults")
        }
        isolated { defaults, _ in
            let existedBeforeServices = PortableFirstRunPreferences.prepareForStartup(defaults: defaults)
            defaults.set(0, forKey: "AiGoodBro.syntheticStartupCache")
            let fresh = settings(defaults, existingUser: existedBeforeServices)
            expect(
                fresh.themeMode == .system && fresh.edgeDock.enabled && fresh.onboarding.shouldPresent,
                "startup snapshot is captured before generated service state")
        }
        for stage in ["service-cache-only", "partial-preset"] {
            isolated { defaults, suite in
                let support = root.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                expect(
                    !PortableFirstRunPreferences.prepareForStartup(defaults: defaults, supportDirectory: support, persistentDomainName: suite),
                    "\(stage): empty startup establishes new-user provenance")
                expect(
                    defaults.persistentDomain(forName: suite)?[PortableFirstRunPreferences.inProgressKey] as? Bool == true
                        && defaults.object(forKey: PortableFirstRunPreferences.appliedKey) == nil,
                    "\(stage): first-run marker is persisted before service writes")
                defaults.set(7, forKey: "CodexManagerNext.tokens.officialLifetimeHighWater")
                let snapshot = support.appendingPathComponent("account-manager-next-v1.json")
                let snapshotBytes = Data("synthetic startup profile snapshot".utf8)
                try? snapshotBytes.write(to: snapshot)
                if stage == "partial-preset" {
                    defaults.set("system", forKey: WidgetThemeMode.storageKey)
                    defaults.set("zh", forKey: WidgetLanguage.storageKey)
                    defaults.set("simple", forKey: WorkspaceDisplayMode.storageKey)
                    defaults.set(false, forKey: GlobalShortcut.enabledStorageKey)
                    defaults.set(false, forKey: "CodexManagerNext.keepRunningWhenMainWindowClosed")
                }
                defaults.synchronize()
                guard let restarted = UserDefaults(suiteName: suite) else {
                    failures.append("\(stage): restart suite unavailable")
                    return
                }
                let existingUser = PortableFirstRunPreferences.prepareForStartup(
                    defaults: restarted, supportDirectory: support, persistentDomainName: suite)
                expect(!existingUser, "\(stage): generated service state does not turn the first launch into a returning user")
                let recovered = settings(restarted, existingUser: existingUser)
                expect(
                    recovered.themeMode == .system && recovered.language == .zh && recovered.accountWorkspaceLayout == .cards
                        && recovered.workspaceDisplayMode == .simple && recovered.simpleWorkspacePreset == .accountCards,
                    "\(stage): missing display defaults resume after restart")
                expect(
                    recovered.edgeDock.enabled && recovered.edgeDock.mode == .autoHide && recovered.edgeDock.side == .right
                        && recovered.workspaceGlass == .init(opacity: 74, depth: 84)
                        && recovered.homeDashboardPreferences.range == "all" && recovered.homeDashboardPreferences.mode == "kline"
                        && recovered.homeDashboardPreferences.height == 260 && recovered.homeDashboardPreferences.splitRatio == 0.28,
                    "\(stage): resumed preset uses production display decoders")
                expect(
                    recovered.onboarding.shouldPresent && recovered.onboarding.status == .notStarted && !recovered.onboarding.existingUserMigrated,
                    "\(stage): recovery keeps the first-run guide")
                expect(
                    restarted.bool(forKey: PortableFirstRunPreferences.appliedKey) && restarted.object(forKey: PortableFirstRunPreferences.inProgressKey) == nil,
                    "\(stage): completion is persisted before pending provenance is cleared")
                expect(
                    restarted.integer(forKey: "CodexManagerNext.tokens.officialLifetimeHighWater") == 7 && (try? Data(contentsOf: snapshot)) == snapshotBytes,
                    "\(stage): recovery preserves service caches and the account snapshot")
                if stage == "partial-preset" {
                    expect(recovered.globalShortcut == nil && !recovered.keepRunningWhenMainWindowClosed, "partial-preset: present false values are never overwritten")
                }
                let saved = (restarted.persistentDomain(forName: suite) ?? [:]).filter { PortableFirstRunPreferences.values[$0.key] != nil }
                expect(
                    PortableFirstRunPreferences.prepareForStartup(defaults: restarted, supportDirectory: support, persistentDomainName: suite),
                    "\(stage): completed recovery is now an existing user")
                _ = settings(restarted)
                let reopened = (restarted.persistentDomain(forName: suite) ?? [:]).filter { PortableFirstRunPreferences.values[$0.key] != nil }
                expect(NSDictionary(dictionary: saved).isEqual(to: reopened), "\(stage): recovered defaults are not seeded a second time")
            }
        }
        for schema in [0, 1, 2, 3] {
            isolated { defaults, _ in
                defaults.set("rich", forKey: StatusItemPreferencesStore.displayModeKey)
                defaults.set("used", forKey: StatusItemPreferencesStore.quotaModeKey)
                defaults.set(["todayTokens", "fiveHourQuota"], forKey: StatusItemPreferencesStore.visibleMetricsKey)
                defaults.set(false, forKey: StatusItemPreferencesStore.showsResetCountdownKey)
                if schema > 0 { defaults.set(schema, forKey: StatusItemPreferencesStore.metricsSchemaVersionKey) }
                let loaded = StatusItemPreferencesStore.load(defaults: defaults)
                expect(
                    loaded.displayMode == .rich && loaded.quotaMode == .used && loaded.visibleMetrics == [.fiveHourQuota, .todayTokens]
                        && !loaded.showsResetCountdown, "all legacy schemas preserve each valid menu choice")
                expect(defaults.integer(forKey: StatusItemPreferencesStore.metricsSchemaVersionKey) == 3, "menu schema upgrades without resetting choices")
                expect(defaults.stringArray(forKey: StatusItemPreferencesStore.visibleMetricsKey) == ["todayTokens", "fiveHourQuota"], "valid stored options are left untouched")
                expect(StatusItemPreferencesStore.load(defaults: defaults) == loaded, "menu migration is idempotent")
            }
        }
        isolated { defaults, _ in
            defaults.set(false, forKey: StatusItemPreferencesStore.showsResetCountdownKey)
            let loaded = StatusItemPreferencesStore.load(defaults: defaults)
            expect(loaded == .accountRing, "partial legacy options fill missing fields and preserve countdown false")
            expect(defaults.string(forKey: StatusItemPreferencesStore.displayModeKey) == "classic", "partial migration persists missing fields")
        }
        if failures.isEmpty {
            print("portable first-run preferences self-test passed: \(assertions) assertions")
            return true
        }
        failures.forEach { print("portable first-run preferences self-test failed: \($0)") }
        return false
    }
}
