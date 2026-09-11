import SwiftUI

/// Read-only home/workspace strip for the three Codex reset concepts.
/// Window times, public announcements and banked reset cards stay separate.
struct ResetUpdatesBanner: View {
    let language: WidgetLanguage
    let fiveHourResetsAt: Date?
    let sevenDayResetsAt: Date?
    let announcement: PublicResetAnnouncement?
    let checkedAt: Date?
    let accountsWithResetCards: Int
    let onOpenAnnouncements: () -> Void
    let onOpenAccounts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeledRow(
                systemImage: "clock",
                title: language.text("窗口重置时间", "Window reset time"),
                detail: windowDetail,
                action: nil
            )
            labeledRow(
                systemImage: "megaphone",
                title: language.text("公开重置公告", "Public reset announcement"),
                detail: announcementDetail,
                action: onOpenAnnouncements
            )
            labeledRow(
                systemImage: "arrow.counterclockwise.circle",
                title: language.text("可用重置卡", "Available reset cards"),
                detail: resetCardDetail,
                action: accountsWithResetCards > 0 ? onOpenAccounts : nil
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("额度窗口与重置消息", "Limit windows and reset updates"))
    }

    private var windowDetail: String {
        let five = fiveHourResetsAt.map { language.text("5h \(language.dateTime($0))", "5h \(language.dateTime($0))") }
        let seven = sevenDayResetsAt.map { language.text("7d \(language.dateTime($0))", "7d \(language.dateTime($0))") }
        switch (five, seven) {
        case (let five?, let seven?):
            return "\(five) · \(seven)"
        case (let five?, nil):
            return five + language.text(" · 7d 暂无", " · 7d unavailable")
        case (nil, let seven?):
            return language.text("5h 暂无 · ", "5h unavailable · ") + seven
        case (nil, nil):
            return language.text("暂无窗口重置时间", "No window reset time")
        }
    }

    private var announcementDetail: String {
        if let announcement {
            let when = language.dateTime(announcement.announcedAt)
            return "\(announcement.title(language)) · \(when)"
        }
        if let checkedAt {
            let clock = checkedAt.formatted(.dateTime.hour().minute().locale(language.locale))
            return language.text("暂无公告 · 检查于 \(clock)", "No announcement · checked \(clock)")
        }
        return language.text("暂无公告", "No announcement")
    }

    private var resetCardDetail: String {
        if accountsWithResetCards == 1 {
            return language.text("1 个账号有可用重置卡", "1 account has reset cards")
        }
        if accountsWithResetCards > 1 {
            return language.text(
                "\(accountsWithResetCards) 个账号有可用重置卡",
                "\(accountsWithResetCards) accounts have reset cards"
            )
        }
        return language.text("无可用重置卡", "No reset cards available")
    }

    @ViewBuilder
    private func labeledRow(
        systemImage: String,
        title: String,
        detail: String,
        action: (() -> Void)?
    ) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityHint(language.text("打开对应详情", "Open related details"))
        } else {
            content
        }
    }
}
