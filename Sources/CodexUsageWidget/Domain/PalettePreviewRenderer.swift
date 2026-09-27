import AppKit
import SwiftUI

enum PalettePreviewRenderer {
    @MainActor
    static func renderSettingsCatalog(to directory: URL) -> Bool {
        let suiteName = "CodexManagerNext.settings-catalog.\(UUID().uuidString)"
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("next-settings-catalog-\(UUID().uuidString)")
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(defaults: defaults, paletteCatalog: catalog)
            let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 0, root: fixtureRoot)
            let updateStore = AppUpdateStore(settings: settings)
            for language in WidgetLanguage.allCases {
                settings.language = language
                for scheme in [ColorScheme.dark, .light] {
                    settings.themeMode = scheme == .dark ? .dark : .light
                    let appearance = scheme == .dark ? "dark" : "light"
                    for page in SettingsPage.allCases {
                        let view = CodexAccountMenuView(
                            store: store, settings: settings, updateStore: updateStore, paletteCatalog: catalog,
                            initialScreen: .settings, initialSettingsPage: page,
                            openFullWindow: {}, openPaletteLibrary: {}, quit: {}
                        )
                        try WorkspacePreviewRenderer.renderView(
                            view, size: CodexAccountMenuView.preferredSize, scheme: scheme,
                            to: directory.appendingPathComponent("settings-\(page.rawValue)-\(language.rawValue)-\(appearance)@2x.png")
                        )
                    }
                    try WorkspacePreviewRenderer.renderView(
                        AccountAutomationCenterView(store: store)
                            .environment(\.widgetLanguage, language)
                            .environment(\.locale, language.locale)
                            .environment(\.colorScheme, scheme)
                            .preferredColorScheme(scheme)
                            .background(FixedVisualPalette.windowScrim(scheme, reduceTransparency: true)),
                        size: NSSize(width: 600, height: 680), scheme: scheme,
                        to: directory.appendingPathComponent("automation-center-\(language.rawValue)-\(appearance)@2x.png")
                    )
                }
            }
            return true
        } catch {
            print("settings catalog render failed")
            return false
        }
    }

    static func renderBuiltIns(to outputDirectory: URL) -> Bool {
        let catalog = PaletteCatalog.loadFromMainBundle()
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            for paletteID in [PaletteCatalog.defaultPaletteID, "codexu.blue-white-porcelain"] {
                for appearance in PaletteAppearance.allCases {
                    let tokens = catalog.resolve(id: paletteID, appearance: appearance)
                    let scheme: ColorScheme = appearance == .dark ? .dark : .light
                    let root = PalettePreviewCanvas()
                        .environment(\.visualTokens, tokens)
                        .environment(\.colorScheme, scheme)
                        .frame(width: 360, height: 230)
                    let host = NSHostingView(rootView: root)
                    host.frame = NSRect(x: 0, y: 0, width: 360, height: 230)
                    host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
                    let name = "\(paletteID)-\(appearance.rawValue).png"
                    try png.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
                }
            }
            return true
        } catch {
            print("palette preview render failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    static func renderDocumentationSettings(to outputURL: URL) -> Bool {
        let suiteName = "CodexManagerNext.documentation-screenshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalog = PaletteCatalog.loadFromMainBundle()
        let settings = AppSettings(defaults: defaults, paletteCatalog: catalog)
        settings.language = .zh
        settings.themeMode = .dark
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("next-settings-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 0, root: fixtureRoot)
        let updateStore = AppUpdateStore(settings: settings)
        let root = CodexAccountMenuView(
            store: store,
            settings: settings,
            updateStore: updateStore,
            paletteCatalog: catalog,
            initialScreen: .settings,
            openFullWindow: {},
            openPaletteLibrary: {},
            quit: {}
        )
        .frame(width: CodexAccountMenuView.preferredSize.width, height: CodexAccountMenuView.preferredSize.height)

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: CodexAccountMenuView.preferredSize)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: outputURL, options: .atomic)
            return true
        } catch {
            print("documentation screenshot render failed: \(error.localizedDescription)")
            return false
        }
    }
}

private struct PalettePreviewCanvas: View {
    @Environment(\.visualTokens) private var tokens
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                QuotaRingSegment(
                    percent: 93,
                    lineWidth: 16
                )
                .frame(width: 145, height: 145)
                QuotaRingSegment(
                    percent: 73,
                    lineWidth: 16
                )
                .frame(width: 107, height: 107)
                VStack(spacing: 2) {
                    Text("5h  93%")
                    Text("7d  73%")
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 16) {
                Text(tokens.identity.paletteID == PaletteCatalog.defaultPaletteID ? "Default" : "青花瓷")
                    .font(.system(size: 16, weight: .semibold))
                QuotaValueProgressBar(currentValue: 5_300, maxValue: 46_500)
                    .frame(width: 150, height: 18)
                HStack(spacing: 5) {
                    ForEach(Array(tokens.data.series.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color.color).frame(width: 14, height: 14)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color.primary)
        .background(colorScheme == .dark ? Color(red: 0.08, green: 0.09, blue: 0.11) : Color(red: 0.96, green: 0.97, blue: 0.98))
    }
}
