import SwiftUI

/// Subscription windows are independent facts. Missing or expired observations
/// never become a full allowance merely because another window was reported.
enum ClaudeSubscriptionQuotaPresentation {
    static let primaryIDs = ["five_hour", "seven_day"]
    static let gridColumnCount = 3

    struct WindowItem: Identifiable {
        let id: String
        let title: String
        let usedPercent: Double?
        let resetsAt: Date?
    }

    static func primaryWindow(_ id: String, in result: LocalCLIQuotaResult?) -> LocalCLIQuotaWindow? {
        result?.windows.first { $0.id == id && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
    }

    static func additionalWindows(in result: LocalCLIQuotaResult?) -> [LocalCLIQuotaWindow] {
        result?.windows.filter {
            !primaryIDs.contains($0.id) && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
        } ?? []
    }

    static func windows(in result: LocalCLIQuotaResult?, language: WidgetLanguage) -> [WindowItem] {
        let primary = primaryIDs.map { id in
            let value = primaryWindow(id, in: result)
            return WindowItem(id: id, title: title(id, language: language), usedPercent: value?.usedPercent, resetsAt: value?.resetsAt)
        }
        let additional = additionalWindows(in: result).map {
            WindowItem(id: $0.id, title: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
        }
        return primary + additional
    }

    static func title(_ id: String, language: WidgetLanguage) -> String {
        id == "five_hour" ? language.text("5 小时", "5 hours") : language.text("7 天", "7 days")
    }
}

struct ClaudeSubscriptionQuotaView: View {
    let result: LocalCLIQuotaResult?
    let isStale: Bool
    let language: WidgetLanguage
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: compact ? 8 : 10) {
                ForEach(windows) { item in
                    window(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let result {
                HStack(spacing: 6) {
                    Label(
                        isStale ? language.text("上次快照", "Previous snapshot") : language.text("已更新", "Updated"),
                        systemImage: isStale ? "clock.badge.exclamationmark" : "clock"
                    )
                    .foregroundStyle(isStale ? FixedVisualPalette.statusWarningForeground(colorScheme) : Color.secondary)
                    Spacer(minLength: 4)
                    Text(language.dateTime(result.fetchedAt))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: compact ? 9 : 10))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: compact ? 13 : 14)
                .help((isStale ? language.text("旧额度仅供参考 · ", "Previous quota for reference · ") : "") + result.sourceLabel)
            } else {
                Color.clear.frame(height: compact ? 13 : 14).accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("claude-subscription-quota")
    }

    private var windows: [ClaudeSubscriptionQuotaPresentation.WindowItem] {
        ClaudeSubscriptionQuotaPresentation.windows(in: result, language: language)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: compact ? 6 : 8, alignment: .top), count: ClaudeSubscriptionQuotaPresentation.gridColumnCount)
    }

    @ViewBuilder private func window(_ item: ClaudeSubscriptionQuotaPresentation.WindowItem) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            QuotaPercentageRing(
                percent: item.usedPercent.map { 100 - $0 }, diameter: compact ? 32 : 38,
                accessibilityTitle: item.title + " " + language.text("剩余额度", "remaining quota")
            )
            .fixedSize()
            Text(item.title)
                .font(.system(size: compact ? 9 : 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(item.title)
            if let reset = item.resetsAt {
                Text(
                    language.text("重置 ", "Reset ")
                        + reset.formatted(
                            .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().locale(language.locale))
                )
                .font(.system(size: compact ? 8 : 9))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.secondary)
                .help(language.dateTime(reset))
                ResetCountdownText(deadline: reset, kind: .accountWindow, language: language, compact: true)
                    .font(.system(size: compact ? 8 : 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if item.usedPercent != nil {
                Text(language.text("重置时间未知", "Reset time unknown"))
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(missingWindowLabel)
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(item.title)
    }

    private var missingWindowLabel: String {
        if result?.state == .available { return language.text("官方未提供", "Not reported") }
        if result == nil { return language.text("尚未读取", "Not loaded") }
        return language.text("暂不可用", "Unavailable")
    }
}
