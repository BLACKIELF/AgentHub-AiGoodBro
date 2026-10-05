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
                    for step in NextSetupGuideScope.full.steps {
                        settings.setupProgress = NextSetupProgress(step: step)
                        let view = NextSetupGuideView(store: store, settings: settings, openAutomation: {}, runtime: NextRuntimeSetupModel(preview: true))
                            .transaction { $0.disablesAnimations = true }
                            .preferredColorScheme(scheme)
                        let name = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-step\(step.rawValue + 1).png"
                        try WorkspacePreviewRenderer.renderView(view, size: CGSize(width: 900, height: 680), scheme: scheme, to: directory.appendingPathComponent(name))
                        count += 1
                    }
                    let choice = InstallationAudienceChoiceView(language: language, onSelect: { _ in }, onDefer: {})
                        .transaction { $0.disablesAnimations = true }
                        .preferredColorScheme(scheme)
                    let choiceName = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-audience.png"
                    try WorkspacePreviewRenderer.renderView(
                        choice, size: InstallationAudienceChoiceView.preferredSize, scheme: scheme, to: directory.appendingPathComponent(choiceName))
                    count += 1
                    let previewEventID = "preview-returning-\(UUID().uuidString)"
                    settings.installationOnboarding = InstallationOnboardingState(
                        installationID: previewEventID, scope: .returning, audience: .returningUser, eventGeneration: previewEventID)
                    for step in NextSetupGuideScope.returning.steps {
                        _ = settings.installationOnboarding.setConnectionStep(step, eventID: previewEventID)
                        let view = NextSetupGuideView(
                            store: store, settings: settings, scope: .returning, installationEventID: previewEventID, openAutomation: {},
                            runtime: NextRuntimeSetupModel(preview: true)
                        )
                        .transaction { $0.disablesAnimations = true }
                        .preferredColorScheme(scheme)
                        let name = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-returning-step\(step.rawValue).png"
                        try WorkspacePreviewRenderer.renderView(view, size: CGSize(width: 900, height: 680), scheme: scheme, to: directory.appendingPathComponent(name))
                        count += 1
                    }
                    for step in NextSetupGuideScope.connections.steps {
                        let view = NextSetupGuideView(
                            store: store, settings: settings, scope: .connections, previewStep: step, openAutomation: {}, runtime: NextRuntimeSetupModel(preview: true)
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
