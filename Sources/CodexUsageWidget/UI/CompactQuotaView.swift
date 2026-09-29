import SwiftUI

/// Shared allowance presentation for Home and the proxy queue. Unknown windows
/// remain unknown; the track keeps the existing quota palette and semantics.
struct CompactQuotaView: View {
    let title: String
    let remaining: Double?
    let reset: Date?
    var paletteRole: QuotaPaletteRole = .primary
    var constrainedByWeekly = false
    var isExpiry = false
    @Environment(\.widgetLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Text(QuotaAvailabilityPresentation.percentText(remaining))
                    .fontWeight(.semibold).monospacedDigit()
                if remaining != nil {
                    QuotaProgressTrack(percent: remaining, paletteRole: paletteRole, thickness: 3)
                        .frame(width: 52, height: 3)
                        .accessibilityHidden(true)
                }
            }
            if let reset {
                Text((isExpiry ? language.text("到期 ", "Expires ") : "") + resetTime(reset))
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.system(size: 8)).accessibilityHidden(true)
                    ResetCountdownText(deadline: reset, kind: .accountWindow, language: language, compact: true)
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
            } else if remaining != nil {
                Text(language.text("重置 —", "Reset —"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if constrainedByWeekly {
                Text(language.text("受周额度限制", "Weekly limit reached"))
                    .foregroundStyle(FixedVisualPalette.statusWarning)
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .help(reset.map { language.dateTime($0) } ?? language.text("官方未提供重置时间", "Official reset time unavailable"))
    }

    private func resetTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
