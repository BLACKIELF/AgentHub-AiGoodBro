import AppKit
import Combine
import SwiftUI

/// Exercises production views with isolated preferences and synthetic accounts.
@MainActor
enum HomeInteractionPreview {
    static func show() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigoodbro-home-review-\(UUID().uuidString)")
        let suite = "AiGoodBro.home-review.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let catalog = PaletteCatalog.loadFromMainBundle()
        let settings = AppSettings(
            defaults: defaults, paletteCatalog: catalog,
            previewAvatarRoot: root.appendingPathComponent("avatars"))
        DesignHomePreviewFixture.configure(settings)
        let store = DesignHomePreviewFixture.makeStore(root: root)
        let local = DesignHomePreviewFixture.makeLocalCLIStore(root: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AiGoodBro · 界面预览（示例数据）"
        window.minSize = CGSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = GlassHostingContainer(
            rootView: HomeReviewFixture(
                store: store, settings: settings, catalog: catalog, local: local,
                updateStore: AppUpdateStore(settings: settings)
            )
            .defaultAppStorage(defaults)
            .environment(\.workspacePreviewDate, DesignHomePreviewFixture.referenceDate)
            .environment(
                \.workspacePreviewForecastDeadline,
                DesignHomePreviewFixture.referenceDate.addingTimeInterval(12 * 3_600)),
            cornerRadius: 12, allowsWindowDragging: false, settings: settings)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

private struct HomeReviewFixture: View {
    let store: UsageStore
    @ObservedObject var settings: AppSettings
    let catalog: PaletteCatalog
    let local: LocalCLIAccountStore
    let updateStore: AppUpdateStore
    @State private var showingSettings = false
    @State private var showingPalettes = false

    var body: some View {
        CodexAccountManagerView(
            store: store, settings: settings, paletteCatalog: catalog,
            localCLIAccounts: local,
            previewReferenceDate: DesignHomePreviewFixture.referenceDate,
            previewForecastBy: DesignHomePreviewFixture.referenceDate.addingTimeInterval(12 * 3_600),
            onOpenWorkspaceSettings: { showingSettings = true }
        )
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text(settings.language.text("设置", "Settings")).font(.headline)
                    Spacer()
                    Button(settings.language.text("完成", "Done")) { showingSettings = false }
                }.padding(12)
                SettingsPanelView(
                    settings: settings, store: store, updateStore: updateStore,
                    onOpenPaletteLibrary: { showingPalettes = true }
                )
                .sheet(isPresented: $showingPalettes) {
                    PaletteLibraryView(settings: settings).frame(width: 760, height: 560)
                }
            }
            .frame(width: 780, height: 640)
            .environment(\.widgetLanguage, settings.language)
            .environment(\.locale, settings.language.locale)
            .preferredColorScheme(settings.themeMode.preferredColorScheme)
        }
    }
}
