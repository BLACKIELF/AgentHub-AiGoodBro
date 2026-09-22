import SwiftUI

/// Presentation-only labels for the validated announcement DTO. These helpers
/// preserve source and reset type without inferring delivery to this account.
enum PublicResetAnnouncementPresentation {
    static func title(_ language: WidgetLanguage) -> String {
        language.text("历史重置记录", "Historical reset record")
    }

    static func typeTitle(_ kind: PublicResetAnnouncement.Kind, language: WidgetLanguage) -> String {
        switch kind {
        case .regular: return language.text("常规额度重置公告", "Regular quota reset announcement")
        case .banked: return language.text("重置卡公告", "Reset-card announcement")
        }
    }

    static func interpretation(_ kind: PublicResetAnnouncement.Kind, language: WidgetLanguage) -> String {
        switch kind {
        case .regular:
            return language.text(
                "类型说明：公开常规重置公告，不代表个人额度已刷新，也不是重置卡。请在账号页核对官方窗口。",
                "Type explanation: a public regular-quota reset notice, not a reset-card notice or confirmation that your account refreshed. Verify official windows on the Accounts page."
            )
        case .banked:
            return language.text(
                "类型说明：公开重置卡公告，不代表个人已到账。请在账号页核对可用重置卡；未知不等于零。",
                "Type explanation: a public reset-card notice, not confirmation that your account received one. Verify your reset-card balance on the Accounts page; unknown is not zero."
            )
        }
    }

    static func eventTime(_ date: Date, language: WidgetLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date) + language.text(" 北京时间 (UTC+08:00)", " Beijing time (UTC+08:00)")
    }

    static func compactEventTime(_ date: Date, language: WidgetLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date) + language.text(" · 北京时间", " · Beijing time")
    }

    static func forecastTime(_ date: Date, language: WidgetLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = language.text("yyyy年M月d日 EEEE HH:mm", "EEEE, MMM d, yyyy HH:mm")
        return formatter.string(from: date) + language.text(" · 北京时间", " · Beijing time")
    }

    static func forecastCountdown(_ forecast: PublicResetForecast, now: Date, language: WidgetLanguage) -> String {
        ResetCountdownPresentation.label(deadline: forecast.latestBy, now: now, kind: .publicForecast, language: language)
    }

    /// A homepage notice is current only when its validated source is inside
    /// the past 30 days. The feed's five-minute clock-skew allowance is not a
    /// permission to present a future item as today's message.
    static func recentVerifiableAnnouncement(
        _ announcements: [PublicResetAnnouncement], now: Date, window: TimeInterval = 30 * 24 * 60 * 60
    ) -> PublicResetAnnouncement? {
        let lowerBound = now.addingTimeInterval(-window)
        return
            announcements
            .filter { $0.announcedAt >= lowerBound && $0.announcedAt <= now && $0.isValid(now: now) }
            .max {
                $0.announcedAt == $1.announcedAt ? $0.id < $1.id : $0.announcedAt < $1.announcedAt
            }
    }

    static func relativeEventTime(_ date: Date, now: Date, language: WidgetLanguage) -> String {
        guard date < now.addingTimeInterval(-60) else { return language.text("刚刚", "Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Both channels can report independently; preserve their exact current text.
    static func visibleStatuses(local: String?, general: String?) -> [String] {
        var result: [String] = []
        for status in [local, general].compactMap({ $0 }) {
            if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !result.contains(status) {
                result.append(status)
            }
        }
        return result
    }

    static func originalLabel(_ language: WidgetLanguage) -> String {
        language.text("来源原文", "Original source text")
    }

    /// Hide bare web addresses in presentation; retain the exact source bytes in the DTO.
    static func readableText(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: #"https?://[^\s<>]+|www\.[^\s<>]+"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
        return stripped.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sourceLabel(_ source: PublicResetAnnouncement.Source, language: WidgetLanguage) -> String {
        switch source.type {
        case "x_post":
            if let author = source.author, !author.isEmpty {
                return language.text("X · @\(author)", "X · @\(author)")
            }
            return "X"
        case "observed":
            return language.text("公开观察记录", "Publicly observed record")
        default:
            return language.text("来源类型：\(source.type)", "Source type: \(source.type)")
        }
    }

    static func sourceLinkTitle(_ source: PublicResetAnnouncement.Source, language: WidgetLanguage) -> String {
        if source.url?.host?.lowercased() == "x.com" {
            return language.text("查看 X 来源", "Open X source")
        }
        return language.text("打开来源", "Open source")
    }
}

struct AnnouncementOriginalText: View {
    static let collapsedLineLimit = 2

    let text: String
    let language: WidgetLanguage
    let compact: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(PublicResetAnnouncementPresentation.originalLabel(language))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if compact && !isExpanded {
                Text(verbatim: PublicResetAnnouncementPresentation.readableText(text))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(Self.collapsedLineLimit)
                    .textSelection(.enabled)
            } else {
                Text(verbatim: PublicResetAnnouncementPresentation.readableText(text))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if compact {
                Button(isExpanded ? language.text("收起原文", "Show less") : language.text("更多原文", "Show more")) {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityValue(
                    isExpanded ? language.text("已展开", "Expanded") : language.text("已折叠", "Collapsed")
                )
            }
        }
    }
}

struct PublicResetAnnouncementLinks: View {
    let source: PublicResetAnnouncement.Source
    let language: WidgetLanguage
    var showsOriginalSource = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { links }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) { links }
        }
        .font(.caption2)
    }

    @ViewBuilder
    private var links: some View {
        if showsOriginalSource, let sourceURL = source.url, sourceURL != PublicResetClient.siteURL {
            Link(
                PublicResetAnnouncementPresentation.sourceLinkTitle(source, language: language),
                destination: sourceURL
            )
        }
        Link(language.text("查看完整记录", "Browse full history"), destination: PublicResetClient.siteURL)
    }
}

/// Read-only home/workspace strip for the three Codex reset concepts.
/// Window times, public announcements and banked reset cards stay separate.
enum ResetCardAccountSummary: Equatable {
    case unknown
    case none
    case accounts(Int)
}

struct ResetUpdatesBanner: View {
    let language: WidgetLanguage
    let fiveHourResetsAt: Date?
    let sevenDayResetsAt: Date?
    let announcement: PublicResetAnnouncement?
    let checkedAt: Date?
    let isRefreshing: Bool
    let refreshStatus: String?
    let resetCards: ResetCardAccountSummary
    let onOpenAnnouncements: () -> Void
    let onOpenAccounts: () -> Void
    var onRefresh: () -> Void = {}
    var embedded = false
    var announcements: [PublicResetAnnouncement] = []
    var announcementsHasMore: Bool?
    var showsHistory = false
    var compactSummary = false
    @ObservedObject var inbox: HomeMessageInboxStore = .shared
    @ObservedObject private var forecastStore = PublicResetForecastStore.shared
    @AppStorage(HomeSection.reset.storageKey) private var sectionExpanded = true
    @State private var summaryExpanded = false
    @State private var historyExpanded = false
    @State private var selectedCalendarDay: Date?
    @State private var showsExplanation = false

    private var calendarAnnouncements: [PublicResetAnnouncement] {
        PublicResetCalendarModel.normalized(announcements + (announcement.map { [$0] } ?? []))
    }

    private var recentAnnouncement: PublicResetAnnouncement? {
        PublicResetAnnouncementPresentation.recentVerifiableAnnouncement(calendarAnnouncements, now: Date())
    }

    private var resetCalendar: some View {
        VStack(alignment: .leading, spacing: 8) {
            calendarGrid
            Divider()
            selectedDayAnnouncements
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var calendarGrid: some View {
        PublicResetCalendarView(announcements: calendarAnnouncements, language: language, hasMore: nil, selectedDay: $selectedCalendarDay)
            .onAppear {
                if selectedCalendarDay == nil { selectedCalendarDay = PublicResetCalendarModel.calendar.startOfDay(for: Date()) }
            }
    }

    private var selectedDayAnnouncements: some View {
        PublicResetRecentView(
            announcements: calendarAnnouncements, language: language, featuredID: recentAnnouncement?.id,
            integratedInCalendar: true, selectedDay: $selectedCalendarDay)
    }

    /// Keep the selected date and its information together instead of putting
    /// all detail below the calendar and leaving the neighboring columns empty.
    private var homeCalendarDetails: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                calendarGrid.frame(width: 300)
                calendarContext.frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 14) {
                calendarGrid
                calendarContext
            }
        }
        .padding(.top, 6)
    }

    private var calendarContext: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectedDayAnnouncements
            accountSummary
        }
    }

    private var recentAnnouncements: some View {
        PublicResetRecentView(announcements: calendarAnnouncements, language: language, featuredID: recentAnnouncement?.id, selectedDay: $selectedCalendarDay)
    }

    @MainActor
    private var announcementDashboard: some View {
        ResetDashboardLayout {
            announcementCard
            resetCalendar
            accountSummary
        }
    }

    private var hasAttention: Bool {
        forecastStore.forecast != nil || recentAnnouncement != nil || confirmedResetCardAccounts > 0
    }

    private var refreshingAnything: Bool { isRefreshing || forecastStore.checking }

    private func refreshAll() {
        forecastStore.check()
        onRefresh()
    }

    private var confirmedResetCardAccounts: Int {
        if case .accounts(let count) = resetCards { return count }
        return 0
    }

    @MainActor
    @ViewBuilder
    private var announcementCard: some View {
        let current = recentAnnouncement
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onOpenAnnouncements) {
                    HStack(spacing: 8) {
                        Image(systemName: "megaphone.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(current == nil ? Color.secondary : FixedVisualPalette.statusInfo)
                        Text(
                            current.map {
                                $0.title(language)
                            } ?? PublicResetAnnouncementPresentation.title(language)
                        )
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(language.text("打开公告详情", "Open announcement details"))
                Spacer(minLength: 0)
                Button(action: refreshAll) {
                    Label(
                        refreshingAnything ? language.text("更新中…", "Checking…") : language.text("刷新", "Refresh"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(refreshingAnything)
                .fixedSize(horizontal: true, vertical: true)
            }
            if let ann = current {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(
                        language.text("最近历史记录 · ", "Latest historical record · ")
                            + PublicResetAnnouncementPresentation.relativeEventTime(ann.announcedAt, now: context.date, language: language)
                    )
                    .font(.headline)
                }
                Text(PublicResetAnnouncementPresentation.compactEventTime(ann.announcedAt, language: language))
                    .font(.subheadline.weight(.medium))
                    .help(PublicResetAnnouncementPresentation.eventTime(ann.announcedAt, language: language))
                PublicResetTranslatedText(eventID: ann.id, original: ann.text, language: language, compact: true)
                Text(PublicResetAnnouncementPresentation.sourceLabel(ann.source, language: language))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(announcementDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let checkedAt {
                Text(language.text("历史上次检查：", "History last checked: ") + PublicResetAnnouncementPresentation.compactEventTime(checkedAt, language: language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var forecastSection: some View {
        if let forecast = forecastStore.forecast {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "clock.badge.exclamationmark.fill")
                        .foregroundStyle(FixedVisualPalette.statusWarning)
                    Text(language.text("重置预告 · 待确认", "Reset forecast · unconfirmed"))
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    if forecastStore.isShowingCache {
                        Text(language.text("缓存", "Cached"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let deadline = forecast.latestBy {
                    Text(language.text("预计最晚 ", "Expected by ") + PublicResetAnnouncementPresentation.forecastTime(deadline, language: language))
                        .font(.headline)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    ResetCountdownText(deadline: deadline, kind: .publicForecast, language: language)
                        .font(.callout.weight(.semibold))
                } else {
                    Text(PublicResetAnnouncementPresentation.forecastCountdown(forecast, now: Date(), language: language))
                        .font(.callout.weight(.medium))
                }
                Text(
                    language.text(
                        "实际到账以账号额度为准。",
                        "Check your account quota to confirm delivery.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Link(language.text("来源公告", "Source announcement"), destination: forecast.sourceURL)
                    Link("Codex Resets", destination: PublicResetForecastClient.endpoint)
                    Spacer(minLength: 0)
                    Text(
                        language.text("预告检查：", "Forecast checked: ")
                            + PublicResetAnnouncementPresentation.compactEventTime(
                                forecastStore.checkedAt ?? forecast.fetchedAt, language: language)
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.caption2)
                if let status = forecastStore.status, !status.isEmpty {
                    Text(PublicResetAnnouncementPresentation.readableText(status))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FixedVisualPalette.statusWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(FixedVisualPalette.statusWarning.opacity(0.28), lineWidth: 0.8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(language.text("公开重置预告，尚未确认完成", "Public reset forecast, completion unconfirmed"))
        } else if let status = forecastStore.status, !status.isEmpty {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text(PublicResetAnnouncementPresentation.readableText(status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if compactSummary {
                    HomeSectionToggle(
                        title: language.text("重置消息", "Reset updates"), systemImage: "arrow.counterclockwise.circle.fill",
                        language: language, isExpanded: $sectionExpanded
                    )
                    .font(.system(size: 12.5, weight: .semibold))
                } else {
                    Label(language.text("重置消息", "Reset updates"), systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 4)
                }
                Button {
                    showsExplanation.toggle()
                } label: {
                    Image(systemName: "info.circle").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(language.text("公告与个人额度说明", "Announcement and account limit details"))
                .popover(isPresented: $showsExplanation) { explanation }
            }
            if !compactSummary || sectionExpanded {
                forecastSection
                if compactSummary {
                    let current = recentAnnouncement
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(current?.title(language) ?? language.text("重置消息", "Reset updates"))
                                .font(.callout.weight(.medium)).lineLimit(1)
                            Text(
                                current.map { PublicResetAnnouncementPresentation.readableText($0.text) }
                                    ?? language.text("暂无近期可验证的新公告", "No recent verifiable notices")
                            )
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if let current {
                            Text(PublicResetAnnouncementPresentation.compactEventTime(current.announcedAt, language: language))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button(action: refreshAll) {
                            Label(refreshingAnything ? language.text("检查中…", "Checking…") : language.text("刷新", "Refresh"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.plain).disabled(refreshingAnything)
                        .accessibilityLabel(language.text("分别刷新公开预告与历史记录", "Refresh public forecast and history independently"))
                    }
                    if let refreshStatus, !refreshStatus.isEmpty {
                        Text(isRefreshing ? language.text("正在检查历史记录…", "Checking historical records…") : PublicResetAnnouncementPresentation.readableText(refreshStatus))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(
                                refreshStatus
                                    + (checkedAt.map {
                                        "\n" + language.text("上次成功检查：", "Last successful check: ") + PublicResetAnnouncementPresentation.compactEventTime($0, language: language)
                                    } ?? ""))
                    }
                    HStack(spacing: 12) {
                        Text(resetCardDetail).foregroundStyle(.secondary)
                        Spacer()
                        Button(
                            language.text(historyExpanded ? "收起历史消息" : "最近 3 条历史", historyExpanded ? "Collapse history" : "Latest 3 historical records")
                        ) {
                            historyExpanded.toggle()
                            summaryExpanded = false
                        }
                        Button(language.text(summaryExpanded ? "收起日历与详情" : "展开日历与详情", summaryExpanded ? "Collapse calendar and details" : "Calendar and details")) {
                            summaryExpanded.toggle()
                            historyExpanded = false
                        }
                    }
                    .font(.caption2).buttonStyle(.plain)
                    if historyExpanded { inlineHistory }
                    if summaryExpanded { homeCalendarDetails }
                } else if showsHistory {
                    announcementDashboard
                    inlineHistory
                } else {
                    announcementCard
                    accountSummary
                }
                if compactSummary && (summaryExpanded || historyExpanded) {
                    Button(language.text("收起，仅显示概要", "Collapse to summary")) {
                        summaryExpanded = false
                        historyExpanded = false
                    }
                    .font(.caption).buttonStyle(.plain)
                }
            }
        }
        .padding(embedded ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !embedded { RoundedRectangle(cornerRadius: 12).fill(FixedVisualPalette.surfaceMutedFill) }
        }
        .overlay(alignment: .leading) {
            if hasAttention && !embedded {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FixedVisualPalette.statusInfo)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("额度窗口与重置消息", "Limit windows and reset updates"))
    }

    private var accountSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(language.text("当前账号的窗口重置", "Monitored account reset windows"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                windowSummary("5h", date: fiveHourResetsAt)
                windowSummary("7d", date: sevenDayResetsAt)
            }
            labeledRow(
                systemImage: "arrow.counterclockwise.circle",
                title: language.text("可用重置卡", "Available reset cards"),
                detail: resetCardDetail,
                emphasized: confirmedResetCardAccounts > 0,
                action: confirmedResetCardAccounts > 0 ? onOpenAccounts : nil
            )
        }
    }

    private func windowSummary(_ title: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(
                date.map { PublicResetAnnouncementPresentation.compactEventTime($0, language: language) }
                    ?? language.text("时间未知", "Time unknown")
            )
            .font(.caption.weight(.medium)).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            if let date {
                ResetCountdownText(deadline: date, kind: .accountWindow, language: language)
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("公告与个人额度", "Announcements and account limits")).font(.headline)
            Text(
                language.text(
                    "顶部预告来自公开网站横幅，与历史公告分别获取；预告到期仍不算完成。日历只标记历史公告发布日期，个人窗口和重置卡以账号读取结果为准。",
                    "The top forecast is fetched separately from the public site banner and remains unconfirmed after its deadline. The calendar marks only historical announcement dates. Account readings determine personal windows and reset cards."
                ))
            if let forecast = forecastStore.forecast {
                Text(
                    language.text("预告最晚时间：", "Forecast latest time: ")
                        + (forecast.latestBy.map {
                            PublicResetAnnouncementPresentation.forecastTime($0, language: language)
                        } ?? language.text("待公布", "To be announced")))
            }
            if let recentAnnouncement { Text(recentAnnouncement.meaning(language)) }
            if let status = forecastStore.status, !status.isEmpty {
                Text(PublicResetAnnouncementPresentation.readableText(status)).foregroundStyle(.secondary)
            }
            if let refreshStatus, !refreshStatus.isEmpty {
                Text(PublicResetAnnouncementPresentation.readableText(refreshStatus)).foregroundStyle(.secondary)
            }
            Button(language.text("查看公告详情", "View announcement details")) {
                showsExplanation = false
                onOpenAnnouncements()
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
        .frame(width: 330)
    }

    private var windowDetail: String {
        let five = fiveHourResetsAt.map {
            language.text(
                "5h \(PublicResetAnnouncementPresentation.eventTime($0, language: language))", "5h \(PublicResetAnnouncementPresentation.eventTime($0, language: language))")
        }
        let seven = sevenDayResetsAt.map {
            language.text(
                "7d \(PublicResetAnnouncementPresentation.eventTime($0, language: language))", "7d \(PublicResetAnnouncementPresentation.eventTime($0, language: language))")
        }
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
        if let recentAnnouncement {
            let when = PublicResetAnnouncementPresentation.eventTime(recentAnnouncement.announcedAt, language: language)
            return "\(when) · \(PublicResetAnnouncementPresentation.sourceLabel(recentAnnouncement.source, language: language))"
        }
        if let checkedAt {
            let clock = PublicResetAnnouncementPresentation.eventTime(checkedAt, language: language)
            return language.text("暂无近期可验证的新公告 · 检查于 \(clock)", "No recent verifiable notice · checked \(clock)")
        }
        return language.text("暂无近期可验证的新公告", "No recent verifiable notice")
    }

    private var inlineHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.text("最近 3 条历史记录", "Latest 3 historical records"))
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text(language.text("由新到旧", "Newest first"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if calendarAnnouncements.isEmpty {
                Text(language.text("暂无已载入的公告。", "No announcements loaded yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(calendarAnnouncements.prefix(HomeMessageInboxStore.visibleAnnouncementLimit)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(item.resetType == .banked ? Color.purple : Color.blue)
                                    .frame(width: 5, height: 5)
                                Text(PublicResetAnnouncementPresentation.compactEventTime(item.announcedAt, language: language))
                                    .font(.caption2.weight(.medium))
                                Spacer(minLength: 0)
                                Text(PublicResetAnnouncementPresentation.sourceLabel(item.source, language: language))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(verbatim: PublicResetAnnouncementPresentation.readableText(item.text))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = HomeMessageLinkPolicy.allowedURL(item.source.url) {
                                Link(PublicResetAnnouncementPresentation.sourceLinkTitle(item.source, language: language), destination: url)
                                    .font(.caption2)
                            }
                        }
                        .padding(.vertical, 6)
                        .onAppear { inbox.markSeen([item]) }
                        Divider()
                    }
                }
            }
            if announcementsHasMore == true || calendarAnnouncements.count > HomeMessageInboxStore.visibleAnnouncementLimit {
                Link(language.text("查看完整记录", "Browse full history"), destination: PublicResetClient.siteURL)
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resetCardDetail: String {
        switch resetCards {
        case .unknown:
            return language.text("重置卡次数未知", "Reset card count unknown")
        case .none:
            return language.text("无可用重置卡", "No reset cards available")
        case .accounts(1):
            return language.text("1 个账号有可用重置卡", "1 account has reset cards")
        case .accounts(let count):
            return language.text("\(count) 个账号有可用重置卡", "\(count) accounts have reset cards")
        }
    }

    @ViewBuilder
    private func labeledRow(
        systemImage: String,
        title: String,
        detail: String,
        emphasized: Bool,
        action: (() -> Void)?
    ) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(emphasized ? FixedVisualPalette.statusInfo : Color.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.system(size: 11.5, weight: emphasized ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
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

/// Respect the parent's proposed width even when an announcement's ideal text
/// width is large. No measured-state feedback can expand a narrow workspace.
struct ResetDashboardLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = resolvedWidth(proposal.width)
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func resolvedWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else { return 960 }
        return max(1, proposed)
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        Self.frames(width: width, count: subviews.count) { index, proposedWidth in
            subviews[index].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil)).height
        }
    }

    /// The dashboard contains announcement, calendar/history and account windows.
    /// Always place unexpected child counts instead of reporting a zero-height dashboard.
    static func frames(width: CGFloat, count: Int, measure: (Int, CGFloat) -> CGFloat) -> [CGRect] {
        let width = max(1, width.isFinite ? width : 960)
        func box(_ index: Int, x: CGFloat, y: CGFloat, width: CGFloat) -> CGRect {
            CGRect(x: x, y: y, width: width, height: max(1, measure(index, width)))
        }
        guard count == 3 else {
            var y: CGFloat = 0
            return (0..<max(0, count)).map { index in
                let frame = box(index, x: 0, y: y, width: width)
                y = frame.maxY + 12
                return frame
            }
        }
        if width >= 940 {
            let accountWidth = min(400, max(260, width * 0.3))
            let latestWidth = width - 348 - accountWidth
            return [
                box(0, x: 0, y: 0, width: latestWidth),
                box(1, x: latestWidth + 24, y: 0, width: 300),
                box(2, x: latestWidth + 348, y: 0, width: accountWidth),
            ]
        }
        if width >= 620 {
            let left = width - 324
            let latest = box(0, x: 0, y: 0, width: left)
            return [
                latest, box(1, x: left + 24, y: 0, width: 300),
                box(2, x: 0, y: latest.maxY + 12, width: left),
            ]
        }
        let latest = box(0, x: 0, y: 0, width: width)
        let account = box(2, x: 0, y: latest.maxY + 12, width: width)
        return [latest, box(1, x: 0, y: account.maxY + 20, width: min(300, width)), account]
    }
}
