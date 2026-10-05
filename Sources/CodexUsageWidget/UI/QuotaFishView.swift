import SwiftUI

/// A native, static projection of the same remaining-quota value as the ring.
/// No animation clock or network work is owned by the presentation.
struct QuotaFishView: View {
    let percentRemaining: Double?
    let tint: Color
    let language: WidgetLanguage
    var compact = false

    private var percent: Double? {
        guard let value = percentRemaining, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(spacing: compact ? 1 : 3) {
            GeometryReader { geometry in
                let fishWidth: CGFloat = compact ? 17 : 23
                let travel = max(0, geometry.size.width - fishWidth)
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.16)).frame(height: 3)
                    if let percent {
                        Image(systemName: "fish.fill")
                            .font(.system(size: compact ? 13 : 17))
                            .foregroundStyle(tint)
                            .frame(width: fishWidth)
                            .offset(x: travel * CGFloat((100 - percent) / 100))
                    } else {
                        Image(systemName: "questionmark")
                            .font(.system(size: compact ? 10 : 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: geometry.size.height)
            }
            .frame(height: compact ? 18 : 24)
            Text(percent.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.system(size: compact ? 10 : 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("剩余额度", "Remaining quota"))
        .accessibilityValue(percent.map { String(format: "%.0f%%", $0) } ?? language.text("未知", "Unknown"))
        .help(language.text("小鱼随已用额度向右移动；数字为剩余额度。", "Fish move right as quota is used; the number shows remaining quota."))
    }
}
