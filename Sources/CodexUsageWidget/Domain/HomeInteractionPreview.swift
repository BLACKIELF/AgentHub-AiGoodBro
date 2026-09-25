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
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 980),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AiGoodBro · 0923v8 设计验收 · 合成数据"
        window.minSize = CGSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: HomeReviewFixture(
                store: store, settings: settings, catalog: catalog, local: local, window: window
            )
            .defaultAppStorage(defaults)
            .environment(\.workspacePreviewDate, DesignHomePreviewFixture.referenceDate)
            .environment(
                \.workspacePreviewForecastDeadline,
                DesignHomePreviewFixture.referenceDate.addingTimeInterval(12 * 3_600)))
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
    let window: NSWindow
    @State private var generation = 0
    @State private var showingPalettes = false
    private let guide = PassthroughSubject<Void, Never>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("0923v8 · 合成验收 · 2026-09-23 03:00 北京时间 · 不连接真实账号")
                    .font(.caption)
                Button("窄窗") { window.setContentSize(CGSize(width: 820, height: 760)) }
                Button("宽窗") { window.setContentSize(CGSize(width: 1440, height: 980)) }
                Picker("账号布局", selection: $settings.accountWorkspaceLayout) {
                    Text("卡片").tag(AccountWorkspaceLayout.cards)
                    Text("列表").tag(AccountWorkspaceLayout.rows)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 116)
                Button("切换明暗") { settings.themeMode = settings.themeMode == .dark ? .light : .dark }
                Button("选择主题配色") { showingPalettes = true }
                Button("切换语言") { settings.language = settings.language == .zh ? .en : .zh }
                Button("重建测试界面") { generation += 1 }
                Button("检查使用引导") { guide.send(()) }
                Spacer()
            }.padding(8)
            Divider()
            CodexAccountManagerView(
                store: store, settings: settings, paletteCatalog: catalog,
                guideRequests: guide.eraseToAnyPublisher(), localCLIAccounts: local,
                previewReferenceDate: DesignHomePreviewFixture.referenceDate,
                previewForecastBy: DesignHomePreviewFixture.referenceDate.addingTimeInterval(12 * 3_600)
            )
            .id(generation)
        }
        .sheet(isPresented: $showingPalettes) {
            PaletteLibraryView(settings: settings)
                .frame(width: 760, height: 560)
        }
    }
}
