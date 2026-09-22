import SwiftUI

/// Calendar dates refer only to historical public announcement times in Beijing.
/// Scheduled forecasts are displayed separately and never become calendar events
/// until the authoritative history feed records them.
enum PublicResetCalendarModel {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 2
        return value
    }

    static func monthStart(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }

    static func days(in month: Date) -> [Date?] {
        let first = monthStart(month)
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        let count = calendar.range(of: .day, in: .month, for: first)!.count
        let total = ((offset + count + 6) / 7) * 7
        return (0..<total).map { index in
            guard index >= offset, index < offset + count else { return nil }
            return calendar.date(byAdding: .day, value: index - offset, to: first)
        }
    }

    static func normalized(_ events: [PublicResetAnnouncement]) -> [PublicResetAnnouncement] {
        var seen = Set<String>()
        return events.sorted {
            $0.announcedAt == $1.announcedAt ? $0.id < $1.id : $0.announcedAt > $1.announcedAt
        }.filter { seen.insert($0.id).inserted }
    }

    static func events(on day: Date, from events: [PublicResetAnnouncement]) -> [PublicResetAnnouncement] {
        normalized(events).filter { calendar.isDate($0.announcedAt, inSameDayAs: day) }
    }
}

struct PublicResetCalendarView: View {
    let announcements: [PublicResetAnnouncement]
    let language: WidgetLanguage
    let hasMore: Bool?
    @Binding var selectedDay: Date?
    @State private var month = PublicResetCalendarModel.monthStart(Date())

    private var calendar: Calendar { PublicResetCalendarModel.calendar }
    private var monthEvents: [PublicResetAnnouncement] {
        announcements.filter { calendar.isDate($0.announcedAt, equalTo: month, toGranularity: .month) }
    }
    private var earliestMonth: Date {
        PublicResetCalendarModel.monthStart(announcements.last?.announcedAt ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(language.text("历史重置日历", "Historical reset calendar"), systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(language.text("北京时间", "Beijing time"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    shiftMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(month <= earliestMonth)
                .accessibilityLabel(language.text("上个月", "Previous month"))
                Spacer()
                Text(monthTitle).font(.callout.weight(.semibold)).monospacedDigit()
                Spacer()
                Button {
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(month >= PublicResetCalendarModel.monthStart(Date()))
                .accessibilityLabel(language.text("下个月", "Next month"))
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(0..<7) { index in
                    Text(language.text(["一", "二", "三", "四", "五", "六", "日"][index], ["M", "T", "W", "T", "F", "S", "S"][index]))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                let days = PublicResetCalendarModel.days(in: month)
                ForEach(days.indices, id: \.self) { index in
                    if let day = days[index] { dayButton(day) } else { Color.clear.frame(height: 25).accessibilityHidden(true) }
                }
            }
            HStack(spacing: 10) {
                legend(language.text("常规公告", "Regular"), color: .blue)
                legend(language.text("重置卡公告", "Reset cards"), color: .purple)
                Spacer(minLength: 0)
                Text(language.text("本月 \(monthEvents.count) 条", "\(monthEvents.count) this month"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(
                language.text(
                    "仅标记历史公告发布日期；不包含未确认预告，也不表示账号已到账。",
                    "Marks historical announcement dates only; excludes unconfirmed forecasts and does not indicate receipt by your account.")
            )
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if hasMore == true {
                Link(language.text("更早记录见来源网站", "Earlier history on the source site"), destination: PublicResetClient.siteURL)
                    .font(.caption2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("历史重置公告日历", "Historical reset announcement calendar"))
        .onAppear {
            if let selectedDay { month = PublicResetCalendarModel.monthStart(selectedDay) }
        }
        .onChange(of: selectedDay) { day in
            if let day { month = PublicResetCalendarModel.monthStart(day) }
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = language.text("yyyy 年 M 月", "MMMM yyyy")
        return formatter.string(from: month)
    }

    private func shiftMonth(_ direction: Int) {
        guard let target = calendar.date(byAdding: .month, value: direction, to: month),
            target >= earliestMonth, target <= PublicResetCalendarModel.monthStart(Date())
        else { return }
        month = target
        selectedDay = target
    }

    private func dayButton(_ day: Date) -> some View {
        let events = PublicResetCalendarModel.events(on: day, from: announcements)
        let selected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let today = calendar.isDate(day, inSameDayAs: Date())
        let dateLabel = day.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: language.locale, calendar: calendar, timeZone: calendar.timeZone))
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption.weight(selected || today ? .bold : .regular))
                    .monospacedDigit()
                HStack(spacing: 3) {
                    if events.contains(where: { $0.resetType == .regular }) { Circle().fill(Color.blue).frame(width: 4, height: 4) }
                    if events.contains(where: { $0.resetType == .banked }) { Circle().fill(Color.purple).frame(width: 4, height: 4) }
                }.frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 25)
            .background(selected ? Color.accentColor.opacity(0.2) : today ? Color.secondary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(day > calendar.startOfDay(for: Date()))
        .accessibilityLabel(dateLabel + language.text("，\(events.count) 条已记录公告", ", \(events.count) recorded announcements"))
        .accessibilityValue(selected ? language.text("已选择", "Selected") : "")
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct PublicResetRecentView: View {
    let announcements: [PublicResetAnnouncement]
    let language: WidgetLanguage
    var featuredID: String? = nil
    var integratedInCalendar = false
    @Binding var selectedDay: Date?
    @State private var selectedAnnouncement: PublicResetAnnouncement?

    private var visibleEvents: [PublicResetAnnouncement] {
        let day = selectedDay ?? (integratedInCalendar ? Date() : nil)
        return day.map { PublicResetCalendarModel.events(on: $0, from: announcements) }
            ?? Array(announcements.filter { $0.id != featuredID }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedDay == nil && !integratedInCalendar ? language.text("更多动态", "More updates") : language.text("所选日期的公告", "Announcements on this date"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if selectedDay != nil {
                    Button(integratedInCalendar ? language.text("今天", "Today") : language.text("最近", "Recent")) {
                        selectedDay = integratedInCalendar ? PublicResetCalendarModel.calendar.startOfDay(for: Date()) : nil
                    }
                    .font(.caption).buttonStyle(.borderless)
                }
            }
            if visibleEvents.isEmpty {
                Text(
                    selectedDay == nil && !integratedInCalendar
                        ? language.text("暂无已载入的公告。", "No announcements loaded yet.") : language.text("这一天没有已记录的公告。", "No recorded announcements on this date.")
                )
                .font(.callout).foregroundStyle(.secondary)
                .padding(.vertical, 2)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .topLeading)], alignment: .leading, spacing: 10) {
                    ForEach(visibleEvents.prefix(3)) { event in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                selectedAnnouncement = event
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        Circle().fill(event.resetType == .banked ? Color.purple : Color.blue).frame(width: 5, height: 5)
                                        Text(PublicResetAnnouncementPresentation.compactEventTime(event.announcedAt, language: language))
                                            .font(.caption.weight(.medium))
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.caption2)
                                    }
                                    Text(verbatim: PublicResetAnnouncementPresentation.readableText(event.text))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
            if visibleEvents.count > 3 {
                Text(language.text("另有 \(visibleEvents.count - 3) 条，见完整历史。", "\(visibleEvents.count - 3) more on the full history page."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text(language.text("已载入 \(announcements.count) 条公告", "\(announcements.count) announcements loaded"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Link(language.text("完整历史", "Full history"), destination: PublicResetClient.siteURL)
                    .font(.caption2)
            }
        }
        .sheet(item: $selectedAnnouncement) { event in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(event.title(language)).font(.title3.weight(.semibold))
                    Spacer()
                    Button(language.text("关闭", "Close")) { selectedAnnouncement = nil }
                        .keyboardShortcut(.cancelAction)
                }
                Text(PublicResetAnnouncementPresentation.typeTitle(event.resetType, language: language))
                    .font(.callout.weight(.medium))
                Text(PublicResetAnnouncementPresentation.eventTime(event.announcedAt, language: language))
                    .font(.caption).foregroundStyle(.secondary)
                PublicResetTranslatedText(eventID: event.id, original: event.text, language: language, compact: false)
                Text(event.meaning(language)).font(.caption).foregroundStyle(.secondary)
                PublicResetAnnouncementLinks(source: event.source, language: language)
            }
            .padding(24)
            .frame(width: 560)
        }
    }
}
