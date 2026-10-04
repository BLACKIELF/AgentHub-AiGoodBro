import AppKit
import SwiftUI

/// Production cards and the real proxy window, using disposable profiles only.
@MainActor
enum ThemeReadabilityPreview {
    static func render(to directory: URL) -> Bool {
        if CommandLine.arguments.contains("--preview-proxy-layout-only") {
            return renderProxyLayout(to: directory)
        }
        let suite = "AiGoodBro.theme-audit.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(defaults: defaults, paletteCatalog: catalog, previewAvatarRoot: root.appendingPathComponent("avatars"))
            settings.language = .zh
            let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 4, root: root, includeQuotaEdgeCases: true, includeExpiryEdgeCases: true)
            let proxy = LocalProxyQueueStore(usageStore: store, previewPreferences: .init())
            let controller = LocalProxyQueueWindowController()
            var captures = 0
            // Return to default after the custom palettes to catch retained
            // material/opacity state, including reopening the same window.
            let ids = catalog.descriptors(language: "zh-Hans").map(\.id)
            for scheme in [ColorScheme.dark, .light] {
                settings.themeMode = scheme == .dark ? .dark : .light
                for id in ids + [PaletteCatalog.defaultPaletteID] {
                    _ = settings.selectPalette(id)
                    controller.show(model: proxy, settings: settings, paletteCatalog: catalog)
                    guard let window = NSApp.windows.first(where: { $0.title == "反代模式" }),
                        let content = window.contentView,
                        !content.isHidden, content.bounds.width >= 680, content.bounds.height >= 500,
                        content.subviews.last?.isHidden == false
                    else { throw CocoaError(.coderInvalidValue) }
                    window.layoutIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                    content.layoutSubtreeIfNeeded()
                    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw CocoaError(.fileWriteUnknown) }
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    let name = "\(id)-\(scheme == .dark ? "dark" : "light")"
                    try png.write(to: directory.appendingPathComponent("proxy-\(captures)-\(name).png"))
                    window.orderOut(nil)
                    let accounts = CodexAccountManagerView(
                        store: store, settings: settings, paletteCatalog: catalog, previewOpenCodexWorkspace: true
                    )
                    .defaultAppStorage(defaults)
                    for layout in [AccountWorkspaceLayout.cards, .rows] {
                        settings.accountWorkspaceLayout = layout
                        try WorkspacePreviewRenderer.renderView(
                            accounts, size: CGSize(width: 1100, height: 720), scheme: scheme,
                            to: directory.appendingPathComponent("accounts-\(layout.rawValue)-\(name).png"))
                    }
                    if let profile = store.profiles.first {
                        let detail = ScrollView {
                            AccountInformationView(profile: profile, accountNumber: 1)
                                .padding(16)
                        }.environment(\.widgetLanguage, WidgetLanguage.zh)
                        try WorkspacePreviewRenderer.renderView(
                            detail, size: CGSize(width: 430, height: 880), scheme: scheme,
                            to: directory.appendingPathComponent("details-\(name).png"))
                    }
                    captures += 1
                }
            }
            print("Theme audit: \(captures) real proxy-window captures; custom-to-default transitions and production account views")
            return true
        } catch {
            print("Theme audit failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Focused production proxy layout, with the model's real preview disable states.
    /// Expanded editors are presentation fixtures; no controls or saves are invoked.
    private static func renderProxyLayout(to directory: URL) -> Bool {
        let suite = "AiGoodBro.proxy-layout-preview.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(defaults: defaults, paletteCatalog: catalog, previewAvatarRoot: root.appendingPathComponent("avatars"))
            settings.language = .zh
            let reference = ISO8601DateFormatter().date(from: "2026-12-31T15:00:00Z")!
            let store = WorkspacePreviewRenderer.fixtureStore(
                accountCount: 4, root: root, includeQuotaEdgeCases: true,
                includeResetExpiryDisclosureFixtures: true, referenceDate: reference)
            let proxy = LocalProxyQueueStore(usageStore: store, previewPreferences: .init())
            var images: [[String: Any]] = []
            for (theme, scheme, palette) in [
                ("default-light", ColorScheme.light, PaletteCatalog.defaultPaletteID),
                ("keycap-dark", ColorScheme.dark, "codexu.liquid-keycap"),
            ] {
                guard settings.selectPalette(palette) == .selected else { throw CocoaError(.fileReadCorruptFile) }
                settings.themeMode = scheme == .dark ? .dark : .light
                for width in [CGFloat(680), CGFloat(1100)] {
                    for expanded in [false, true] {
                        let view = LocalProxyQueueView(model: proxy, language: .zh, previewExpandedRules: expanded)
                            .defaultAppStorage(defaults)
                            .environment(\.workspacePreviewDate, reference)
                            .environment(\.workspacePreviewOpaqueSurface, true)
                            .environment(\.workspaceGlass, settings.workspaceGlass)
                            .environment(\.visualTokens, catalog.resolve(id: palette, appearance: scheme == .dark ? .dark : .light))
                        let filename = "proxy-layout-\(Int(width))-\(expanded ? "expanded" : "summary")-\(theme).png"
                        try WorkspacePreviewRenderer.renderView(
                            view, size: CGSize(width: width, height: 880), scheme: scheme,
                            to: directory.appendingPathComponent(filename))
                        images.append(["file": filename, "width": Int(width), "expandedRules": expanded])
                    }
                }
            }
            let manifest: [String: Any] = [
                "syntheticOnly": true, "images": images,
                "scope": "Production proxy UI with actual preview-disabled controls; collapsed and expanded policy editors; no live process, endpoint, clicks or save operations",
            ]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("proxy-layout-manifest.json"), options: .atomic)
            print("Proxy layout preview: eight isolated production UI images; no proxy or account actions")
            return true
        } catch {
            print("Proxy layout preview failed: \(error.localizedDescription)")
            return false
        }
    }

}
