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
        let settings = AppSettings(defaults: defaults, paletteCatalog: catalog)
        settings.onboarding.skip()
        settings.themeMode = .dark
        let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 3, root: root)
        store.publicResetAnnouncements.seedPreviewLatest(
            PublicResetAnnouncement(
                id: "observed-synthetic-home-review", resetType: .regular,
                announcedAt: Date().addingTimeInterval(-7200),
                text: "Synthetic public announcement for calendar layout verification.",
                source: .init(type: "observed", author: nil, url: nil)), checkedAt: Date())
        let localProfiles = LocalCLIKind.allCases.map { kind in
            LocalCLIProfile(
                id: "synthetic-\(kind.rawValue)", kind: kind, displayName: "演示 · \(kind.displayName)",
                configDirectory: root.appendingPathComponent(kind.rawValue).path, isDefault: true)
        }
        let supported: Set<LocalCLIKind> = [.claudeCode, .grok, .kimi, .gemini, .openCode]
        let quotas = Dictionary(
            uniqueKeysWithValues: localProfiles.map { profile in
                (
                    profile.id,
                    LocalCLIQuotaResult(
                        state: supported.contains(profile.kind) ? .available : .unsupported,
                        fetchedAt: Date(), maskedIdentity: nil, identityFingerprint: "synthetic-\(profile.kind.rawValue)", planLabel: "演示套餐",
                        windows: supported.contains(profile.kind)
                            ? [
                                LocalCLIQuotaWindow(id: "daily", label: "每日额度", usedPercent: 23.5, resetsAt: Date().addingTimeInterval(7200)),
                                LocalCLIQuotaWindow(id: "weekly", label: "每周额度", usedPercent: 0, resetsAt: nil),
                            ] : [], balance: nil, balanceCurrency: nil, sourceLabel: "合成数据", messageCode: nil)
                )
            })
        let local = LocalCLIAccountStore.preview(profiles: localProfiles, quotas: quotas, root: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 850),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AiGoodBro · 首页与引导 · 合成验收"
        window.minSize = CGSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: HomeReviewFixture(
                store: store, settings: settings, catalog: catalog, local: local, window: window
            )
            .defaultAppStorage(defaults))
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
    private let guide = PassthroughSubject<Void, Never>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("合成验收 · 不连接真实账号").font(.caption)
                Button("窄窗") { window.setContentSize(CGSize(width: 820, height: 760)) }
                Button("宽窗") { window.setContentSize(CGSize(width: 1440, height: 900)) }
                Button("切换明暗") { settings.themeMode = settings.themeMode == .dark ? .light : .dark }
                Button("切换语言") { settings.language = settings.language == .zh ? .en : .zh }
                Button("重建测试界面") { generation += 1 }
                Button("检查使用引导") { guide.send(()) }
                Spacer()
            }.padding(8)
            Divider()
            CodexAccountManagerView(
                store: store, settings: settings, paletteCatalog: catalog,
                guideRequests: guide.eraseToAnyPublisher(), localCLIAccounts: local
            )
            .id(generation)
        }
    }
}
