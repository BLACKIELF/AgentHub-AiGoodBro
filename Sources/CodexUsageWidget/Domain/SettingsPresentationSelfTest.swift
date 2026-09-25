import Cocoa
import SwiftUI

/// UI reorganization must keep the existing preference keys and round trips.
enum SettingsPresentationSelfTest {
    static func run() -> Bool {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        let suiteName = "CodexManagerNext.settings-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        expect(SettingsPage.allCases == [.appearance, .menuBar, .floatingBubble, .automation, .workspace, .about], "all six settings categories remain reachable")
        expect(AHBrandIdentity.displayName == "AiGoodBro", "settings chrome uses the AiGoodBro display name")
        expect(AHBrandIdentity.shortName == "AH", "settings chrome uses the AH short name")
        expect(AHBrandIdentity.workspaceName == "AgentHub", "the in-app workspace name remains AgentHub")
        for language in WidgetLanguage.allCases {
            let titles = SettingsPage.allCases.map { $0.title(language) }
            expect(Set(titles).count == titles.count, "settings pages have unique localized labels")
            expect(SettingsPage.allCases.allSatisfy { !$0.detail(language).isEmpty && !$0.symbol.isEmpty }, "settings pages have labels and descriptions")
            expect(
                SettingsPage.allCases.allSatisfy { !$0.detail(language).contains("MAKE IT YOURS") && !$0.detail(language).contains("Next") },
                "settings page copy must not keep CodexU slogans or Next as a display name"
            )
            let header = AHBrandIdentity.headerDetail(page: .menuBar, language: language)
            expect(header.contains(AHBrandIdentity.shortName), "settings header must show the AH short name")
            expect(header.contains(SettingsPage.menuBar.title(language)), "settings header must show the current page")
            expect(!header.contains("MAKE IT YOURS"), "settings header must drop the MAKE IT YOURS decoration")
            let attribution = AHBrandIdentity.aboutAttribution(language)
            expect(attribution.contains("codexU") && attribution.uppercased().contains("MIT"), "About must keep the codexU MIT attribution")
            expect(!attribution.contains("Codex Control"), "About must not use the old Codex Control display name")
        }

        let catalog = PaletteCatalog.loadFromMainBundle()
        let settings = AppSettings(defaults: defaults, paletteCatalog: catalog)
        expect(settings.language == .zh && settings.themeMode == .dark, "fresh installs use Chinese and dark appearance")
        expect(
            settings.accountWorkspaceLayout == .rows && settings.paletteID == PaletteCatalog.initialPaletteID,
            "fresh installs use the list and liquid-keycap palette")
        expect(
            settings.paletteFallbackNotice == nil
                && defaults.string(forKey: "CodexManagerNext.paletteID") == PaletteCatalog.initialPaletteID,
            "an absent palette ID becomes the new initial palette without a warning")
        expect(settings.statusItemPreferences == .accountRing && settings.globalShortcut == .default, "fresh installs show weekly remaining quota and enable Command-U")
        expect(settings.setupProgress.shouldPresentAutomatically, "general defaults must not copy another user's completed setup")
        expect(
            CodexExecutionPreference.defaultValue == .init(model: .astra, reasoningEffort: .low, serviceTier: .standard),
            "new account task defaults use Astra Low at standard speed")
        for mode in WidgetThemeMode.allCases {
            settings.themeMode = mode
            expect(WidgetThemeMode.storedOrDefault(defaults: defaults) == mode, "theme tiles preserve existing persistence")
        }
        for language in WidgetLanguage.allCases {
            settings.language = language
            expect(WidgetLanguage.storedOrAutomatic(defaults: defaults) == language, "language segments persist")
        }
        for transparency in AccountMenuTransparency.allCases {
            settings.accountMenuTransparency = transparency
            expect(AccountMenuTransparency.storedOrDefault(defaults: defaults) == transparency, "opacity segments persist")
        }
        for motion in ParticleAnimationMode.allCases {
            settings.particleAnimationMode = motion
            expect(ParticleAnimationMode.storedOrDefault(defaults: defaults) == motion, "motion segments persist")
        }
        settings.keepMainWindowOnTop = true
        settings.keepRunningWhenMainWindowClosed = false
        settings.automaticUpdateChecksEnabled = false
        GlobalShortcut.clear(defaults: defaults)
        let restored = AppSettings(defaults: defaults, paletteCatalog: catalog)
        expect(restored.keepMainWindowOnTop, "window pin setting survives reopen")
        expect(!restored.keepRunningWhenMainWindowClosed, "background setting survives reopen")
        expect(!restored.automaticUpdateChecksEnabled, "update opt-out survives reopen")
        expect(restored.themeMode == settings.themeMode && restored.language == settings.language, "appearance and language survive reopen")
        expect(restored.globalShortcut == nil, "a saved shortcut opt-out survives the new defaults")

        let existingSuite = "CodexManagerNext.settings-existing-self-test.\(UUID().uuidString)"
        if let existingDefaults = UserDefaults(suiteName: existingSuite) {
            defer { existingDefaults.removePersistentDomain(forName: existingSuite) }
            existingDefaults.set(WidgetThemeMode.system.rawValue, forKey: WidgetThemeMode.storageKey)
            existingDefaults.set(PaletteCatalog.defaultPaletteID, forKey: "CodexManagerNext.paletteID")
            let existing = AppSettings(defaults: existingDefaults, paletteCatalog: catalog)
            expect(
                existing.themeMode == .system && existing.paletteID == PaletteCatalog.defaultPaletteID
                    && existing.paletteFallbackNotice == nil,
                "explicitly saved appearance and legacy palette survive the new defaults")
        } else {
            failures.append("could not create an existing-settings UserDefaults suite")
        }

        let invalidSuite = "CodexManagerNext.settings-invalid-self-test.\(UUID().uuidString)"
        if let invalidDefaults = UserDefaults(suiteName: invalidSuite) {
            defer { invalidDefaults.removePersistentDomain(forName: invalidSuite) }
            invalidDefaults.set("missing.palette", forKey: "CodexManagerNext.paletteID")
            let invalid = AppSettings(defaults: invalidDefaults, paletteCatalog: catalog)
            expect(
                invalid.paletteID == PaletteCatalog.defaultPaletteID
                    && invalid.paletteFallbackNotice == PaletteFallbackNotice(unavailableID: "missing.palette")
                    && invalidDefaults.string(forKey: "CodexManagerNext.paletteID") == PaletteCatalog.defaultPaletteID,
                "an unavailable saved palette falls back to the legacy safe palette and shows a notice")
        } else {
            failures.append("could not create an invalid-settings UserDefaults suite")
        }

        let outputRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("review-outputs/0911v11", isDirectory: true)
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ah-settings-0911v11-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 0, root: fixtureRoot, language: .zh)
            let updateStore = AppUpdateStore(settings: settings)
            settings.language = .zh
            settings.themeMode = .dark
            AHSettingsHeaderContext.shared.currentPage = .menuBar
            for (name, page, scheme) in [
                ("synthetic-settings-header-menubar-zh-dark", SettingsPage.menuBar, ColorScheme.dark),
                ("synthetic-settings-header-appearance-zh-light", SettingsPage.appearance, ColorScheme.light),
            ] as [(String, SettingsPage, ColorScheme)] {
                let header = NextSettingsHeader(language: .zh, currentPage: page)
                    .frame(width: 420, height: 52)
                    .padding(8)
                    .overlay(alignment: .bottomLeading) {
                        Text(AHBrandIdentity.syntheticCaption(page.title(.zh)))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                            .padding(.bottom, 2)
                    }
                    .background(FixedVisualPalette.windowScrim(scheme, reduceTransparency: true))
                    .environment(\.colorScheme, scheme)
                    .preferredColorScheme(scheme)
                    .appVisualEnvironment(
                        catalog: catalog,
                        paletteID: settings.paletteID,
                        appearance: PaletteAppearance(scheme)
                    )
                try WorkspacePreviewRenderer.renderView(
                    header,
                    size: NSSize(width: 436, height: 68),
                    scheme: scheme,
                    to: outputRoot.appendingPathComponent("\(name)@2x.png")
                )
            }
            let panel = SettingsPanelView(
                settings: settings,
                store: store,
                updateStore: updateStore,
                onOpenPaletteLibrary: {},
                compact: true,
                showsHeader: true,
                initialPage: .menuBar
            )
            .overlay(alignment: .bottomLeading) {
                Text(AHBrandIdentity.syntheticCaption("菜单栏"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            try WorkspacePreviewRenderer.renderView(
                panel,
                size: NSSize(width: CodexAccountMenuView.preferredSize.width, height: 420),
                scheme: .dark,
                to: outputRoot.appendingPathComponent("synthetic-settings-menubar-zh-dark@2x.png")
            )
            // Render the complete native settings surface, including the wide
            // floating preview and source picker that used to share a popover.
            for page in SettingsPage.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let standalone = SettingsPanelView(
                        settings: settings, store: store, updateStore: updateStore,
                        onOpenPaletteLibrary: {}, initialPage: page
                    )
                    try WorkspacePreviewRenderer.renderView(
                        standalone, size: NSSize(width: 780, height: 640), scheme: scheme,
                        to: outputRoot.appendingPathComponent("synthetic-settings-0913v3-\(page.rawValue)-\(scheme)@2x.png")
                    )
                }
            }
            AHSettingsHeaderContext.shared.currentPage = nil
        } catch {
            failures.append("could not write synthetic settings captures")
        }
        try? FileManager.default.removeItem(at: fixtureRoot)

        if failures.isEmpty {
            print("settings presentation self-test passed")
            return true
        }
        failures.forEach { print("settings presentation self-test failed: \($0)") }
        return false
    }
}
