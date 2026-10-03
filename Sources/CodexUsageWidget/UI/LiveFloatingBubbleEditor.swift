import SwiftUI

struct LiveFloatingBubbleEditor: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var localAccounts: LocalCLIAccountStore
    var onShowDesktop: () -> Void
    var onCancel: () -> Void
    var onDone: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let sources = FloatingBubbleEvidence.make(store: store, localAccounts: localAccounts, language: settings.language)
        TokenMonitorFloatingBubbleEditor(
            preferences: $settings.floatingBubble,
            snapshot: TokenMonitorFloatingBubbleProjection.resolve(preferences: settings.floatingBubble, sources: sources),
            language: settings.language,
            providers: AgentNavCatalog.workspaceProviders,
            previewUsesSyntheticData: false,
            sources: sources,
            onShowDesktop: onShowDesktop,
            onCancel: onCancel,
            onDone: onDone
        )
        .background {
            if settings.paletteCatalog.resolve(id: settings.paletteID, appearance: PaletteAppearance(colorScheme)).identity.paletteID != PaletteCatalog.defaultPaletteID {
                WorkspaceGlassBackdrop()
            }
        }
        .environment(\.workspaceGlass, settings.workspaceGlass)
        .appVisualEnvironment(
            catalog: settings.paletteCatalog, paletteID: settings.paletteID,
            appearance: PaletteAppearance(settings.themeMode.preferredColorScheme ?? colorScheme)
        )
        .preferredColorScheme(settings.themeMode.preferredColorScheme)
    }
}
