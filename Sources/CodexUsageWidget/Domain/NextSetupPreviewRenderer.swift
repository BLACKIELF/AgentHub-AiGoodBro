import SwiftUI

@MainActor
enum NextSetupPreviewRenderer {
    static func render(to directory: URL) -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-setup-preview-\(UUID().uuidString)", isDirectory: true)
        let suite = "CodexManagerNext.setup-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settings = AppSettings(defaults: defaults)
            let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 3, root: root)
            store.enableAllSetupFeatures()
            var count = 0
            for language in WidgetLanguage.allCases {
                settings.language = language
                for scheme in [ColorScheme.light, .dark] {
                    settings.themeMode = scheme == .dark ? .dark : .light
                    for step in NextSetupStep.allCases {
                        settings.setupProgress = NextSetupProgress(step: step)
                        let view = NextSetupGuideView(store: store, settings: settings, openAutomation: {}, runtime: NextRuntimeSetupModel(preview: true))
                            .transaction { $0.disablesAnimations = true }
                            .preferredColorScheme(scheme)
                        let name = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-step\(step.rawValue + 1).png"
                        try WorkspacePreviewRenderer.renderView(view, size: CGSize(width: 900, height: 680), scheme: scheme, to: directory.appendingPathComponent(name))
                        count += 1
                    }
                    for step in NextSetupGuideScope.connections.steps {
                        settings.installationOnboarding.connectionStep = step
                        let view = NextSetupGuideView(
                            store: store, settings: settings, scope: .connections, openAutomation: {}, runtime: NextRuntimeSetupModel(preview: true)
                        )
                        .transaction { $0.disablesAnimations = true }
                        .preferredColorScheme(scheme)
                        let name = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-connections-step\(step.rawValue).png"
                        try WorkspacePreviewRenderer.renderView(view, size: CGSize(width: 900, height: 680), scheme: scheme, to: directory.appendingPathComponent(name))
                        count += 1
                    }
                }
            }
            print("Rendered \(count) setup views with synthetic accounts; no account or notification actions performed")
            return true
        } catch {
            print("Setup preview render failed")
            return false
        }
    }
}
