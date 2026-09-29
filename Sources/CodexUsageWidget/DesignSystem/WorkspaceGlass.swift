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

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if reduceTransparency || previewOpaque || contrast == .increased {
                    Color(nsColor: .windowBackgroundColor)
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
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        shape
            // The containing AppKit visual effect view (or system NSPopover) owns
            // the single backdrop blur. A second SwiftUI material turns the
            // glass into a flat grey sheet, especially in Dark Mode.
            .fill(opaque ? Color(nsColor: .controlBackgroundColor) : .clear)
            .overlay {
                if !opaque {
                    shape.fill(
                        colorScheme == .dark
                            ? Color.white.opacity(glass.controlOpacity * 0.4)
                            : Color.white.opacity(glass.controlOpacity * 1.4))
                    shape.fill(tokens.surfaceTint.color.color.opacity(tokens.surfaceTint.maximumOpacity * 0.22))
                    shape.fill(
                        LinearGradient(
                            colors: [Color.white.opacity(colorScheme == .dark ? 0.055 : 0.14), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                shape.strokeBorder(
                    selected
                        ? tokens.selection.stroke.color
                        : Color.primary.opacity(contrast == .increased ? 0.35 : glass.lineOpacity * (colorScheme == .dark ? 0.78 : 0.47)),
                    lineWidth: selected ? 1 : 0.6)
            }
            .shadow(color: .black.opacity(opaque ? 0 : colorScheme == .dark ? 0.05 : 0.025), radius: 6, y: 2)
            .allowsHitTesting(false)
    }
}
