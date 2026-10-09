import AppKit
import SwiftUI

/// The production card and row views rendered with isolated, synthetic accounts.
enum ClaudeSubscriptionPreviewRenderer {
    @MainActor static func render(to directory: URL) -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigoodbro-claude-preview-" + UUID().uuidString)
        let suite = "AiGoodBro.ClaudePreview." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date()
            let names = ["订阅账号"]
            let profiles = names.enumerated().map { index, name in
                LocalCLIProfile(
                    id: "claude-preview-\(index)", kind: .claudeCode, displayName: name,
                    configDirectory: root.appendingPathComponent("profile-\(index)").path, isDefault: false,
                    claudeSubscription: .init(source: .native, slot: UUID().uuidString.lowercased(), identityFingerprint: String(repeating: String(index), count: 64)))
            }
            let quotas = Dictionary(
                uniqueKeysWithValues: profiles.enumerated().compactMap { index, profile -> (String, LocalCLIQuotaResult)? in
                    let windows: [LocalCLIQuotaWindow] = [
                        .init(id: "five_hour", label: "5-hour", usedPercent: 18, resetsAt: now.addingTimeInterval(10_800)),
                        .init(id: "seven_day", label: "7-day", usedPercent: 37, resetsAt: now.addingTimeInterval(345_600)),
                        .init(id: "limit-0", label: "Fable", usedPercent: 28, resetsAt: now.addingTimeInterval(345_600)),
                    ]
                    return (
                        profile.id,
                        .init(
                            state: .available, fetchedAt: now,
                            maskedIdentity: "a***\(index)@example.invalid", identityFingerprint: String(repeating: String(index), count: 64),
                            planLabel: "PRO",
                            windows: windows,
                            balance: nil, balanceCurrency: nil,
                            sourceLabel: "Anthropic OAuth usage", messageCode: nil)
                    )
                })
            let model = LocalCLIAccountStore.preview(profiles: profiles, quotas: quotas, root: root, activeClaudeProfileID: profiles[0].id)
            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(defaults: defaults, paletteCatalog: catalog, previewAvatarRoot: root.appendingPathComponent("avatars"))
            settings.language = .zh
            var images: [[String: Any]] = []
            for (theme, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                for (layout, width) in [(AccountWorkspaceLayout.cards, CGFloat(1280)), (.rows, CGFloat(1280)), (.cards, CGFloat(820))] {
                    settings.accountWorkspaceLayout = layout
                    let view = LocalCLIWorkspaceView(model: model, settings: settings, kind: .claudeCode, language: .zh)
                        .padding(18)
                        .environment(\.widgetLanguage, WidgetLanguage.zh)
                        .environment(\.workspacePreviewOpaqueSurface, true)
                        .defaultAppStorage(defaults)
                    let capture = try WorkspaceScreenshotExporter.render(view, width: width, scheme: scheme)
                    let filename = "claude-\(layout.rawValue)-\(Int(width))-\(theme).png"
                    try capture.png.write(to: directory.appendingPathComponent(filename), options: .atomic)
                    images.append(["file": filename, "width": capture.plan.pixelsWide, "height": capture.plan.pixelsHigh])
                }
                for (index, profile) in profiles.enumerated() {
                    for homeLayout in [AccountWorkspaceLayout.cards, .rows] {
                        let homeView = LocalCLIWorkspaceView(
                            model: model, settings: settings, kind: .claudeCode, language: .zh,
                            onlyProfileID: profile.id, embeddedLayout: homeLayout, compactHomeSummary: true,
                            homeDisplayNumber: String(index + 1)
                        )
                        .padding(12)
                        .environment(\.widgetLanguage, WidgetLanguage.zh)
                        .environment(\.workspacePreviewOpaqueSurface, true)
                        .defaultAppStorage(defaults)
                        let width: CGFloat = homeLayout == .cards ? 420 : 760
                        let capture = try WorkspaceScreenshotExporter.render(homeView, width: width, scheme: scheme)
                        let filename = "claude-home-\(homeLayout.rawValue)-compact-\(index + 1)-\(theme).png"
                        try capture.png.write(to: directory.appendingPathComponent(filename), options: .atomic)
                        images.append(["file": filename, "width": capture.plan.pixelsWide, "height": capture.plan.pixelsHigh])
                    }
                }
            }
            let receipt: [String: Any] = [
                "syntheticOnly": true, "productionUI": "LocalCLIWorkspaceView", "images": images,
                "fixtures": ["Requested 5-hour, 7-day and Fable windows only; illustrative values for layout"],
                "runtimeActions": "Disabled by previewOnly; no provider, Keychain, login, switch or normal app launch",
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("preview-manifest-1007v1.json"), options: .atomic)
            print("Claude production card/list previews rendered with synthetic data only")
            return true
        } catch {
            print("Claude preview failed: " + String(describing: type(of: error)))
            return false
        }
    }
}
