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

extension EnvironmentValues {
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
                (colorScheme == .dark
                    ? Color(red: 0.082, green: 0.090, blue: 0.118)
                    : Color(red: 0.914, green: 0.925, blue: 0.949))
                if !reduceTransparency && !previewOpaque && contrast != .increased {
                    RadialGradient(
                        colors: [tokens.accent.primary.color.opacity(colorScheme == .dark ? 0.17 : 0.12), .clear],
                        center: .topLeading, startRadius: 0,
                        endRadius: max(geometry.size.width * 0.8, 1))
                    RadialGradient(
                        colors: [tokens.accent.secondary.color.opacity(colorScheme == .dark ? 0.09 : 0.07), .clear],
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

    private var opaque: Bool { reduceTransparency || previewOpaque || contrast == .increased }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        shape
            .fill(opaque ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial))
            .overlay {
                if !opaque {
                    shape.fill(colorScheme == .dark
                        ? Color(red: 0.12, green: 0.14, blue: 0.18).opacity(0.48)
                        : Color.white.opacity(0.24))
                    shape.fill(tokens.surfaceTint.color.color.opacity(tokens.surfaceTint.maximumOpacity * 0.45))
                    shape.fill(LinearGradient(
                        colors: [Color.white.opacity(colorScheme == .dark ? 0.045 : 0.28), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                shape.strokeBorder(selected ? tokens.selection.stroke.color
                    : Color.primary.opacity(contrast == .increased ? 0.35 : colorScheme == .dark ? 0.12 : 0.10),
                    lineWidth: selected ? 1 : 0.7)
            }
            .shadow(color: .black.opacity(opaque ? 0 : colorScheme == .dark ? 0.08 : 0.035), radius: 7, y: 3)
            .allowsHitTesting(false)
    }
}
