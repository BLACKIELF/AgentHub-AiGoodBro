import SwiftUI

private struct WorkspacePreviewDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

private struct WorkspacePreviewForecastDeadlineKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

private struct WorkspacePreviewOpaqueSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct WorkspaceGlassPreferencesKey: EnvironmentKey {
    static let defaultValue = WorkspaceGlassPreferences()
}

extension EnvironmentValues {
    var workspaceGlass: WorkspaceGlassPreferences {
        get { self[WorkspaceGlassPreferencesKey.self] }
        set { self[WorkspaceGlassPreferencesKey.self] = newValue }
    }
    /// The screenshot harness may freeze presentation time; live accounts always use the clock.
    var workspacePreviewDate: Date? {
        get { self[WorkspacePreviewDateKey.self] }
        set { self[WorkspacePreviewDateKey.self] = newValue }
    }
    var workspacePreviewForecastDeadline: Date? {
        get { self[WorkspacePreviewForecastDeadlineKey.self] }
        set { self[WorkspacePreviewForecastDeadlineKey.self] = newValue }
    }
    /// Test-only fallback override; system Reduce Transparency remains read-only.
    var workspacePreviewOpaqueSurface: Bool {
        get { self[WorkspacePreviewOpaqueSurfaceKey.self] }
        set { self[WorkspacePreviewOpaqueSurfaceKey.self] = newValue }
    }
}

/// A restrained, palette-aware backdrop shared by the window and screenshot export.
struct WorkspaceGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.visualTokens) private var tokens
    @Environment(\.workspacePreviewOpaqueSurface) private var previewOpaque
    @Environment(\.workspaceGlass) private var glass

    private var themed: Bool { tokens.identity.paletteID != "codexu.default" }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if reduceTransparency || previewOpaque || contrast == .increased {
                    Color(nsColor: .windowBackgroundColor)
                } else if themed {
                    themedBackdrop(size: geometry.size)
                } else {
                    Color.clear
                    RadialGradient(
                        colors: [tokens.accent.primary.color.opacity(colorScheme == .dark ? 0.14 : 0.10), .clear],
                        center: .topLeading, startRadius: 0,
                        endRadius: max(geometry.size.width * 0.8, 1))
                    RadialGradient(
                        colors: [tokens.accent.secondary.color.opacity(colorScheme == .dark ? 0.075 : 0.055), .clear],
                        center: .bottomTrailing, startRadius: 0,
                        endRadius: max(geometry.size.width * 0.65, 1))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Color lives above the container's single system blur, so every window size
    /// retains the theme without introducing a second material or animated fog.
    private func themedBackdrop(size: CGSize) -> some View {
        let dark = colorScheme == .dark
        let span = max(size.width, size.height, 1)
        let strength = 0.7 + glass.tintOpacity * 0.3
        return ZStack {
            LinearGradient(
                colors: [
                    tokens.accent.primary.color.opacity((dark ? 0.20 : 0.12) * strength),
                    tokens.accent.secondary.color.opacity((dark ? 0.13 : 0.08) * strength),
                    tokens.accent.highlight.color.opacity((dark ? 0.10 : 0.07) * strength),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                stops: [
                    .init(color: tokens.accent.primary.color.opacity((dark ? 0.45 : 0.34) * strength), location: 0),
                    .init(color: tokens.accent.primaryLight.color.opacity((dark ? 0.23 : 0.16) * strength), location: 0.47),
                    .init(color: .clear, location: 1),
                ],
                center: UnitPoint(x: 0.08, y: 0.08), startRadius: 0, endRadius: span * 0.88)
            RadialGradient(
                colors: [tokens.accent.secondary.color.opacity((dark ? 0.38 : 0.25) * strength), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: span * 0.76)
            RadialGradient(
                colors: [tokens.accent.highlight.color.opacity((dark ? 0.22 : 0.17) * strength), .clear],
                center: UnitPoint(x: 0.88, y: 0.12), startRadius: 0, endRadius: span * 0.54)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(dark ? 0.08 : 0.20), location: 0),
                    .init(color: .clear, location: 0.42),
                    .init(color: .white.opacity(dark ? 0.015 : 0.055), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// The material is ornamental. Text and controls retain their own semantic contrast.
struct WorkspaceGlassSurface: View {
    var cornerRadius: CGFloat = 10
    var selected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.visualTokens) private var tokens
    @Environment(\.workspacePreviewOpaqueSurface) private var previewOpaque
    @Environment(\.workspaceGlass) private var glass

    private var opaque: Bool { reduceTransparency || previewOpaque || contrast == .increased }
    private var themed: Bool { tokens.identity.paletteID != "codexu.default" }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        shape
            // The containing AppKit visual effect view (or system NSPopover) owns
            // the single backdrop blur. A second SwiftUI material turns the
            // glass into a flat grey sheet, especially in Dark Mode.
            .fill(
                opaque
                    ? Color(nsColor: .controlBackgroundColor)
                    : themed ? Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.24 : 0.36) : .clear
            )
            .overlay {
                if !opaque {
                    shape.fill(
                        colorScheme == .dark
                            ? Color.white.opacity(glass.controlOpacity * 0.4)
                            : Color.white.opacity(glass.controlOpacity * 1.4))
                    if themed {
                        shape.fill(tokens.surfaceTint.color.color.opacity(tokens.surfaceTint.maximumOpacity * 0.75))
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.13 : 0.36),
                                    tokens.accent.primaryLight.color.opacity(colorScheme == .dark ? 0.065 : 0.035),
                                    .clear,
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        shape.fill(tokens.surfaceTint.color.color.opacity(tokens.surfaceTint.maximumOpacity * 0.22))
                        shape.fill(
                            LinearGradient(
                                colors: [Color.white.opacity(colorScheme == .dark ? 0.055 : 0.14), .clear],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
            }
            .overlay {
                if themed && !opaque {
                    shape.strokeBorder(
                        selected
                            ? AnyShapeStyle(tokens.selection.stroke.color)
                            : AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.38 : 0.78),
                                        tokens.accent.primaryLight.color.opacity(glass.lineOpacity * 1.8),
                                        Color.primary.opacity(glass.lineOpacity * 0.6),
                                    ],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)),
                        lineWidth: selected ? 1 : 0.7)
                } else {
                    shape.strokeBorder(
                        selected
                            ? tokens.selection.stroke.color
                            : Color.primary.opacity(contrast == .increased ? 0.35 : glass.lineOpacity * (colorScheme == .dark ? 0.78 : 0.47)),
                        lineWidth: selected ? 1 : 0.6)
                }
            }
            .shadow(color: .black.opacity(opaque ? 0 : colorScheme == .dark ? 0.05 : 0.025), radius: 6, y: 2)
            .allowsHitTesting(false)
    }
}
