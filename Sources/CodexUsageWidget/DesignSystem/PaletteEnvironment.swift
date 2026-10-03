import SwiftUI

/// Only text/icons use this shade; filled controls keep the saturated tint so
/// their white checkmarks and labels retain contrast.
struct PaletteControlForeground: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.visualTokens.controlForeground.color
    }
}

enum WorkspaceStatusForeground: ShapeStyle {
    case warning, danger
    func resolve(in environment: EnvironmentValues) -> Color {
        switch self {
        case .warning: return FixedVisualPalette.statusWarningForeground(environment.colorScheme)
        case .danger: return FixedVisualPalette.statusDangerForeground(environment.colorScheme)
        }
    }
}

private struct VisualTokensEnvironmentKey: EnvironmentKey {
    static let defaultValue = ResolvedVisualTokens.safeDefault(.light)
}

extension EnvironmentValues {
    var visualTokens: ResolvedVisualTokens {
        get { self[VisualTokensEnvironmentKey.self] }
        set { self[VisualTokensEnvironmentKey.self] = newValue }
    }
}

extension View {
    func appVisualEnvironment(catalog: PaletteCatalog, paletteID: String, appearance: PaletteAppearance) -> some View {
        environment(\.visualTokens, catalog.resolve(id: paletteID, appearance: appearance))
            .disclosureGroupStyle(FullRowDisclosureGroupStyle())
    }
}

/// Native panels resolve tokens from their own appearance, including a system
/// appearance change that does not publish a new account snapshot.
struct NativePaletteRoot<Content: View>: View {
    let content: Content
    let catalog: PaletteCatalog
    let paletteID: String
    let preferredColorScheme: ColorScheme?
    let glass: WorkspaceGlassPreferences
    @Environment(\.colorScheme) private var colorScheme

    private var tokens: ResolvedVisualTokens {
        catalog.resolve(id: paletteID, appearance: PaletteAppearance(preferredColorScheme ?? colorScheme))
    }

    var body: some View {
        content
            .environment(\.visualTokens, tokens)
            .environment(\.workspaceGlass, glass)
            .tint(tokens.identity.paletteID == PaletteCatalog.defaultPaletteID ? nil : tokens.accent.primary.color)
            .preferredColorScheme(preferredColorScheme)
    }
}
