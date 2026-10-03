import AppKit
import SwiftUI

/// Production cards and the real proxy window, using disposable profiles only.
@MainActor
enum ThemeReadabilityPreview {
    static func render(to directory: URL) -> Bool {
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
}
