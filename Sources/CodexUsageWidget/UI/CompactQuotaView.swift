import SwiftUI

/// Shared allowance presentation for Home and the proxy queue. Unknown windows
/// remain unknown; the ring keeps the existing quota palette and semantics.
struct CompactQuotaView: View {
    let title: String
    let remaining: Double?
    let reset: Date?
    var paletteRole: QuotaPaletteRole = .primary
    var constrainedByWeekly = false
    var isExpiry = false
    var horizontalDetails = false
    var isWeeklyOnlyPro = false
    @Environment(\.widgetLanguage) private var language

    var body: some View {
        Group {
            if horizontalDetails {
                horizontalContent
            } else {
                stackedContent
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .help(
            isWeeklyOnlyPro
                ? QuotaAvailabilityPresentation.weeklyOnlyProHelp(language) : (reset.map { language.dateTime($0) } ?? language.text("官方未提供重置时间", "Official reset time unavailable"))
        )
    }

    private var horizontalContent: some View {
        HStack(alignment: .center, spacing: 6) {
            QuotaPercentageRing(percent: remaining, diameter: 36, isWeeklyOnlyPro: isWeeklyOnlyPro)
                .fixedSize()
            VStack(alignment: .leading, spacing: 3) {
                Text(windowTitle).foregroundStyle(.secondary)
                if let reset {
                    HStack(spacing: 3) {
                        Text(isExpiry ? language.text("到期", "Expires") : language.text("重置", "Resets"))
                        ResetCountdownText(deadline: reset, kind: .accountWindow, language: language, compact: true)
                    }
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(isExpiry ? language.text("到期时间未知", "Expiry unknown") : language.text("重置时间未知", "Reset unknown"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if constrainedByWeekly {
                    Text(language.text("受周额度限制", "Weekly limit reached"))
                        .foregroundStyle(WorkspaceStatusForeground.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var windowTitle: String {
        switch title {
        case "5h", "5-hour": language.text("5 小时额度", "5-hour limit")
        case "7d", "7-day": language.text("7 天额度", "7-day limit")
        default: title
        }
    }

    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                QuotaPercentageRing(percent: remaining, diameter: 36, isWeeklyOnlyPro: isWeeklyOnlyPro)
                Text(title).foregroundStyle(.secondary)
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
                    .foregroundStyle(WorkspaceStatusForeground.warning)
            }
        }
    }

    private func resetTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
