import SwiftUI

/// Shared compact quota row. Unknown never paints 0%.
struct QuotaRow: View {
    let window: QuotaWindowModel
    var compact = false
    @Environment(\.widgetLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.xxs) {
            HStack(alignment: .center, spacing: WorkspaceVisualMetrics.Space.xs) {
                Text(window.label)
                    .font(compact ? WorkspaceVisualMetrics.metaFont().weight(.semibold) : WorkspaceVisualMetrics.bodyFont().weight(.semibold))
                    .lineLimit(1)
                QuotaPercentageRing(percent: window.state.fillFraction.map { Double($0 * 100) }, diameter: compact ? 36 : 42)
                Spacer(minLength: 0)
            }
            if !window.footnote.isEmpty {
                Text(window.footnote)
                    .font(WorkspaceVisualMetrics.metaFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(window.label)
        .accessibilityValue(window.state.accessibilityValue(language) + ". " + window.footnote)
    }
}

struct QuotaTrack: View {
    let state: QuotaRowState
    var thickness: CGFloat = WorkspaceVisualMetrics.trackThickness
    @Environment(\.widgetLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(trackBackground)
                if let fraction = state.fillFraction {
                    Capsule()
                        .fill(LinearGradient(colors: fillColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * max(0, min(1, fraction)))
                } else if state == .loading, !reduceMotion {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: proxy.size.width * 0.28)
                        .offset(x: proxy.size.width * 0.08)
                }
            }
        }
        .frame(height: thickness)
        .accessibilityHidden(true)
    }

    private var trackBackground: Color {
        switch state {
        case .error, .expired: return FixedVisualPalette.statusDanger.opacity(0.18)
        default: return FixedVisualPalette.surfaceTrack
        }
    }

    private var fillColors: [Color] {
        let colors = RemainingQuotaHealth.classify(state.fillFraction.map { Double($0 * 100) }).colors
        return [Color(nsColor: colors.start), Color(nsColor: colors.end)]
    }
}

/// Pre-fix 8pt track that treated nil as 0%. Kept only for A21 before/after probes.
struct LegacyQuotaProgressTrack: View {
    let percent: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(FixedVisualPalette.surfaceTrack)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * CGFloat(max(0, min(100, percent ?? 0)) / 100))
            }
        }
        .frame(height: WorkspaceVisualMetrics.legacyTrackThickness)
    }
}
