import SwiftUI

/// Statistics colors follow the source and the five activity levels rather
/// than the app accent, so a model keeps the same bar color after reordering.
enum TokenMonitorChartColors {
    static let codex = Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
    static let claude = Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
    static let other = Color(red: 106 / 255, green: 180 / 255, blue: 240 / 255)
    static let trend = Color(red: 150 / 255, green: 210 / 255, blue: 255 / 255)

    static func category(_ label: String) -> Color {
        let normalized = label.lowercased()
        if ["claude", "sonnet", "opus", "haiku"].contains(where: normalized.contains) { return claude }
        if ["codex", "gpt", "openai"].contains(where: normalized.contains) { return codex }
        return other
    }

    static func heatmapLevel(_ level: Int) -> Color {
        switch level {
        case 0: Color.primary.opacity(0.03)
        case 1: Color(red: 90 / 255, green: 170 / 255, blue: 255 / 255).opacity(0.18)
        case 2: Color(red: 120 / 255, green: 190 / 255, blue: 255 / 255).opacity(0.45)
        case 3: Color(red: 150 / 255, green: 210 / 255, blue: 255 / 255).opacity(0.80)
        default: Color(red: 180 / 255, green: 230 / 255, blue: 255 / 255)
        }
    }
}

/// Native, data-backed dashboard shared by the workspace and menu-bar popover.
/// The caller owns the glass host; this view keeps its cards translucent.
struct TokenMonitorDashboardView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case overview
        case trends
        var id: String { rawValue }
    }

    let snapshot: TokenMonitorDashboardSnapshot
    let language: WidgetLanguage
    let onRefresh: () -> Void
    var isRefreshing = false

    @State private var section: Section = .overview
    @State private var metric: TokenMonitorMetric = .tokens
    @State private var trendRange: TokenMonitorTrendRange = .month

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardHeader
            Picker(language.text("视图", "View"), selection: $section) {
                Text(language.text("总览", "Overview")).tag(Section.overview)
                Text(language.text("趋势", "Trends")).tag(Section.trends)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            kpiGrid
            Text(
                language.text(
                    "成本按当前价格配置估算，不代表实际账单。",
                    "Costs use the current pricing configuration and are not an actual bill."
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            if section == .overview {
                TokenMonitorHeatmapCard(snapshot: snapshot, metric: $metric, dayCount: 365, language: language)
                breakdowns
            } else {
                trendPanel
                TokenMonitorHeatmapCard(snapshot: snapshot, metric: $metric, dayCount: 180, language: language)
                breakdowns
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("token-monitor-dashboard")
    }

    private var dashboardHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("用量统计", "Usage Dashboard"))
                    .font(.system(size: 19, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(snapshot.isHubSource ? Color.accentColor : FixedVisualPalette.statusSuccess).frame(width: 6, height: 6)
                    Text(snapshot.isHubSource ? language.text("所有设备", "All devices") : language.text("本机", "This device"))
                    if let collectedAt = snapshot.collectedAt { Text("· \(TokenMonitorFormatting.time(collectedAt, language: language))") }
                    if let status = snapshot.localizedStatusText(language) { Text("· \(status)").lineLimit(1) }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onRefresh) {
                Group {
                    if isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)) }
                }
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help(language.text("刷新 Token 用量", "Refresh token usage"))
            .accessibilityLabel(language.text("刷新 Token 用量", "Refresh token usage"))
        }
        .padding(.bottom, 4)
    }

    private var kpiGrid: some View {
        ViewThatFits(in: .horizontal) {
            kpiMetrics(columns: 8).frame(minWidth: 1080)
            kpiMetrics(columns: 4).frame(minWidth: 540)
            kpiMetrics(columns: 2)
        }
        .sectionBackground()
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func kpiMetrics(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 1), count: columns), spacing: 1) {
            metricCard(language.text("总 Token", "Total tokens"), TokenMonitorFormatting.count(snapshot.summary.totalTokens, compact: true, language: language))
            metricCard(language.text("总估算成本 · USD", "Est. cost · USD"), TokenMonitorFormatting.cost(snapshot.summary.totalCost, compact: true, language: language))
            metricCard(language.text("活跃天数", "Active days"), TokenMonitorFormatting.count(snapshot.summary.activeDays, language: language))
            metricCard(language.text("连续活跃天数", "Current active streak"), snapshot.summary.currentStreak.map { TokenMonitorFormatting.count($0, language: language) } ?? "—")
            metricCard(language.text("活跃时长", "Active time"), TokenMonitorFormatting.duration(milliseconds: snapshot.summary.activeTimeMs, language: language))
            metricCard(language.text("单日峰值", "Peak day"), TokenMonitorFormatting.count(snapshot.summary.peakDayTokens, compact: true, language: language))
            metricCard(language.text("常用模型", "Top model"), snapshot.summary.favoriteModel ?? "—")
            metricCard(language.text("消息数", "Messages"), TokenMonitorFormatting.count(snapshot.summary.messages, language: language))
        }
    }

    private var kpiRowHeight: CGFloat { 70 }

    private func metricCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(value)
                .font(.system(size: 19, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: kpiRowHeight, alignment: .leading)
        .background(Color.primary.opacity(0.012))
    }

    private var trendPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("用量趋势", "Usage trend")).font(.headline)
                    Text(snapshot.localizedStatusText(language) ?? language.text("按天汇总", "Daily totals"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(language.text("时间范围", "Range"), selection: $trendRange) {
                    ForEach(TokenMonitorTrendRange.allCases) { range in Text(range.title(language)).tag(range) }
                }
                .pickerStyle(.menu).labelsHidden()
                metricPicker
            }
            TokenMonitorTrendPlot(days: snapshot.trendDays(range: trendRange), metric: metric, language: language)
                .frame(height: 190)
            HStack {
                Text(snapshot.trendDays(range: trendRange).first.map { TokenMonitorFormatting.shortDate($0.date, timezone: snapshot.timezone, language: language) } ?? "—")
                Spacer()
                Text(snapshot.trendDays(range: trendRange).last.map { TokenMonitorFormatting.shortDate($0.date, timezone: snapshot.timezone, language: language) } ?? "—")
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(15)
    }

    private var metricPicker: some View {
        Picker(language.text("指标", "Metric"), selection: $metric) {
            ForEach(TokenMonitorMetric.allCases) { item in
                Text(item.compactTitle(language)).accessibilityLabel(item.title(language)).tag(item)
            }
        }
        .pickerStyle(.segmented).labelsHidden()
        .frame(maxWidth: 160)
    }

    private var breakdowns: some View {
        HStack(alignment: .top, spacing: 12) {
            TokenMonitorBreakdownCard(
                title: language.text("按模型", "By model"),
                rows: snapshot.breakdown(byModel: true, metric: metric, period: .total),
                metric: metric, denominator: snapshot.value(for: .total, metric: metric), language: language
            )
            TokenMonitorBreakdownCard(
                title: language.text("按工具", "By tool"),
                rows: snapshot.breakdown(byModel: false, metric: metric, period: .total),
                metric: metric, denominator: snapshot.value(for: .total, metric: metric), language: language
            )
        }
    }
}

struct TokenMonitorHeatmapCard: View {
    let snapshot: TokenMonitorDashboardSnapshot
    @Binding var metric: TokenMonitorMetric
    let dayCount: Int
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(language.text("Token 活跃度", "Token Activity")).font(.headline)
                Spacer()
                Picker(language.text("指标", "Metric"), selection: $metric) {
                    ForEach(TokenMonitorMetric.allCases) { item in
                        Text(item.compactTitle(language)).accessibilityLabel(item.title(language)).tag(item)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 156)
            }
            ViewThatFits(in: .horizontal) {
                heatmap.frame(minWidth: 1080).frame(height: 180)
                heatmap.frame(minWidth: 540).frame(height: 140)
                heatmap.frame(height: 90)
            }
            HStack {
                Text(dayCount > 200 ? language.text("过去 12 个月", "Past 12 months") : language.text("过去 6 个月", "Past 6 months"))
                Spacer()
                HStack(spacing: 4) {
                    Text(language.text("少", "Less"))
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2).fill(TokenMonitorChartColors.heatmapLevel(level)).frame(width: 10, height: 10)
                    }
                    Text(language.text("多", "More"))
                    Text(language.text("· 未采集", "· Not collected")).padding(.leading, 6)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(15)
        // Keep the activity grid on the dashboard's continuous glass plane.
    }

    private var heatmap: some View {
        TokenMonitorHeatmap(
            days: snapshot.heatmapDays(count: dayCount), metric: metric,
            timezone: snapshot.timezone, language: language
        )
    }
}

struct TokenMonitorHeatmap: View {
    let days: [TokenMonitorDashboardSnapshot.Day?]
    let metric: TokenMonitorMetric
    let timezone: TimeZone
    var language: WidgetLanguage = .zh
    var now: Date = Date()

    private struct MonthMarker {
        let week: Int
        let title: String
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = max(1, Int(ceil(Double(days.count + weekdayOffset) / 7.0)))
            let gap: CGFloat = 3
            let widthCell = (proxy.size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let heightCell = (proxy.size.height - 14 - 6 * gap) / 7
            let cell = max(1, min(widthCell, heightCell))
            VStack(alignment: .leading, spacing: 3) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap), count: columns), alignment: .leading, spacing: gap) {
                    ForEach(0..<(columns * 7), id: \.self) { slot in
                        let row = slot / columns
                        let column = slot % columns
                        let index = column * 7 + row - weekdayOffset
                        let day = days.indices.contains(index) ? days[index] : nil
                        let cellColor = day.map { color(for: $0) } ?? FixedVisualPalette.surfaceTrack.opacity(0.6)
                        let cellView = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(cellColor)
                            .frame(width: cell, height: cell)
                        if days.indices.contains(index) {
                            cellView
                                .help(dayDescription(index: index, day: day))
                                .accessibilityLabel(dayDescription(index: index, day: day))
                        } else {
                            cellView
                        }
                    }
                }
                ZStack(alignment: .topLeading) {
                    ForEach(Array(monthMarkers.enumerated()), id: \.offset) { _, marker in
                        Text(marker.title)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: CGFloat(marker.week) * (cell + gap))
                    }
                }
                .frame(height: 11)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var weekdayOffset: Int {
        max(0, calendar.component(.weekday, from: firstDate) - calendar.firstWeekday + 7) % 7
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.locale
        calendar.timeZone = timezone
        return calendar
    }

    private var firstDate: Date {
        let end = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(max(1, days.count) - 1), to: end) ?? end
    }

    private var monthMarkers: [MonthMarker] {
        var result: [MonthMarker] = []
        var lastKey: String?
        for index in days.indices {
            guard let date = calendar.date(byAdding: .day, value: index, to: firstDate) else { continue }
            let components = calendar.dateComponents([.year, .month], from: date)
            let key = "\(components.year ?? 0)-\(components.month ?? 0)"
            guard key != lastKey else { continue }
            let week = (index + weekdayOffset) / 7
            let marker = MonthMarker(week: week, title: TokenMonitorFormatting.month(date, timezone: timezone, language: language))
            if result.last?.week == week { result[result.count - 1] = marker } else { result.append(marker) }
            lastKey = key
        }
        return result
    }

    private func dayDescription(index: Int, day: TokenMonitorDashboardSnapshot.Day?) -> String {
        guard let date = calendar.date(byAdding: .day, value: index, to: firstDate) else {
            return language.text("日期不可用", "Date unavailable")
        }
        let label = TokenMonitorFormatting.shortDate(TokenMonitorFormatting.dateKey(date, timezone: timezone), timezone: timezone, language: language)
        guard let day, day.coverage(for: metric) != .unknown, day.dayValue(metric) != nil else {
            return language.text("\(label) · 未采集", "\(label) · Not collected")
        }
        let formatted =
            metric == .tokens
            ? TokenMonitorFormatting.count(day.tokens, language: language)
            : TokenMonitorFormatting.cost(day.cost, language: language)
        return "\(label) · \(metric.title(language)): \(formatted)"
    }

    private func color(for day: TokenMonitorDashboardSnapshot.Day) -> Color {
        guard day.coverage(for: metric) != .unknown, let value = day.dayValue(metric) else {
            return FixedVisualPalette.surfaceTrack.opacity(0.55)
        }
        guard value > 0 else { return TokenMonitorChartColors.heatmapLevel(0) }
        let values = days.compactMap { $0 }.filter { $0.coverage(for: metric) != .unknown }.compactMap { $0.dayValue(metric) }
        let peak = max(values.max() ?? value, 1)
        let strength = min(1, max(0, value / peak))
        let level = strength < 0.16 ? 1 : strength < 0.36 ? 2 : strength < 0.66 ? 3 : 4
        return TokenMonitorChartColors.heatmapLevel(level)
    }
}

struct TokenMonitorTrendPlot: View {
    let days: [TokenMonitorDashboardSnapshot.Day]
    let metric: TokenMonitorMetric
    let language: WidgetLanguage

    static func datePosition(for dateKey: String, between firstDateKey: String, and lastDateKey: String) -> Double? {
        guard let date = calendarDate(dateKey),
            let firstDate = calendarDate(firstDateKey),
            let lastDate = calendarDate(lastDateKey),
            date >= firstDate, date <= lastDate
        else { return nil }
        let duration = lastDate.timeIntervalSince(firstDate)
        guard duration > 0 else { return date == firstDate ? 0.5 : nil }
        return date.timeIntervalSince(firstDate) / duration
    }

    private static func calendarDate(_ key: String) -> Date? {
        guard TokenMonitorResponse.validDate(key) else { return nil }
        let components = key.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2]))
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let timeline = days.sorted { $0.date < $1.date }
                guard let firstDateKey = timeline.first?.date, let lastDateKey = timeline.last?.date else { return }
                let points = timeline.compactMap { day -> (position: Double, value: Double)? in
                    guard day.coverage(for: metric) != .unknown,
                        let value = day.dayValue(metric), value.isFinite, value >= 0,
                        let position = Self.datePosition(for: day.date, between: firstDateKey, and: lastDateKey)
                    else { return nil }
                    return (position, value)
                }
                guard !points.isEmpty, let peak = points.map(\.value).max() else { return }
                let maximum = max(peak, 1)
                let chart = CGRect(x: 2, y: 6, width: max(1, size.width - 4), height: max(1, size.height - 12))
                for level in 0...3 {
                    let y = chart.minY + chart.height * CGFloat(level) / 3
                    var grid = Path()
                    grid.move(to: CGPoint(x: chart.minX, y: y))
                    grid.addLine(to: CGPoint(x: chart.maxX, y: y))
                    context.stroke(grid, with: .color(FixedVisualPalette.surfaceTrack), lineWidth: 1)
                }
                let plotted = points.map { item in
                    CGPoint(
                        x: chart.minX + chart.width * CGFloat(item.position),
                        y: chart.maxY - chart.height * CGFloat(item.value / maximum)
                    )
                }
                if plotted.count == 1, let point = plotted.first {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(TokenMonitorChartColors.trend))
                } else {
                    var line = Path()
                    for (index, point) in plotted.enumerated() {
                        if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                    }
                    var area = line
                    area.addLine(to: CGPoint(x: plotted[plotted.count - 1].x, y: chart.maxY))
                    area.addLine(to: CGPoint(x: plotted[0].x, y: chart.maxY))
                    area.closeSubpath()
                    context.fill(
                        area,
                        with: .linearGradient(
                            Gradient(colors: [TokenMonitorChartColors.trend.opacity(0.22), TokenMonitorChartColors.trend.opacity(0.01)]),
                            startPoint: CGPoint(x: 0, y: chart.minY), endPoint: CGPoint(x: 0, y: chart.maxY)))
                    context.stroke(line, with: .color(TokenMonitorChartColors.trend), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            if !days.contains(where: { $0.coverage(for: metric) != .unknown && $0.dayValue(metric) != nil }) {
                Text(language.text("暂无已采集的趋势数据", "No collected trend data"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TokenMonitorBreakdownCard: View {
    let title: String
    let rows: [TokenMonitorDashboardSnapshot.Breakdown]
    let metric: TokenMonitorMetric
    var denominator: Double? = nil
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(language.text("暂无已采集的明细", "No collected breakdown data"))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
            } else {
                let top = Array(rows.prefix(5))
                let peak = max(top.first?.value ?? 1, 1)
                ForEach(top) { item in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Text(item.id).lineLimit(1).frame(width: 130, alignment: .leading)
                            bar(for: item, peak: peak).frame(height: 5)
                            valueText(for: item).frame(width: 82, alignment: .trailing)
                            percentageText(for: item).frame(width: 46, alignment: .trailing)
                        }
                        .frame(minWidth: 430)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(item.id).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                valueText(for: item)
                                percentageText(for: item).frame(width: 46, alignment: .trailing)
                            }
                            bar(for: item, peak: peak).frame(height: 5)
                        }
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        // Keep the ranked bars on the dashboard's continuous glass plane.
    }

    private func valueText(for item: TokenMonitorDashboardSnapshot.Breakdown) -> some View {
        Text(
            metric == .tokens
                ? TokenMonitorFormatting.count(item.value, compact: true, language: language)
                : TokenMonitorFormatting.cost(item.value, compact: true, language: language)
        )
        .monospacedDigit().fontWeight(.semibold)
    }

    private func percentageText(for item: TokenMonitorDashboardSnapshot.Breakdown) -> some View {
        Text(TokenMonitorFormatting.percentage(item.value, of: denominator, language: language))
            .monospacedDigit().foregroundStyle(.secondary)
    }

    private func bar(for item: TokenMonitorDashboardSnapshot.Breakdown, peak: Double) -> some View {
        GeometryReader { proxy in
            Capsule().fill(FixedVisualPalette.surfaceTrack)
                .overlay(alignment: .leading) {
                    Capsule().fill(TokenMonitorChartColors.category(item.id))
                        .frame(width: max(2, proxy.size.width * item.value / peak))
                }
        }
    }
}
