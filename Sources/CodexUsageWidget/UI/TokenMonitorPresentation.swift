import AppKit
import Foundation

enum TokenMonitorViewRoute: String, CaseIterable, Identifiable {
    case home
    case status
    case totalsByTool
    case totalsByModel

    var id: String { rawValue }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .home: return language.text("首页", "Home")
        case .status: return language.text("服务状态", "Status")
        case .totalsByTool: return language.text("按工具汇总", "Totals by Tool")
        case .totalsByModel: return language.text("按模型汇总", "Totals by Model")
        }
    }
}

enum TokenMonitorMetric: String, CaseIterable, Identifiable {
    case tokens
    case cost

    var id: String { rawValue }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .tokens: return language.text("Token", "Tokens")
        case .cost: return language.text("估算成本 · USD", "Est. cost · USD")
        }
    }

    func compactTitle(_ language: WidgetLanguage) -> String {
        switch self {
        case .tokens: return "Token"
        case .cost: return language.text("成本", "Cost")
        }
    }
}

enum TokenMonitorTrendRange: String, CaseIterable, Identifiable {
    case week
    case month
    case quarter
    case year
    case all

    var id: String { rawValue }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .week: return language.text("7天", "7D")
        case .month: return language.text("30天", "30D")
        case .quarter: return language.text("90天", "90D")
        case .year: return language.text("一年", "1Y")
        case .all: return language.text("全部", "All")
        }
    }
}

enum TokenMonitorPeriod: String, CaseIterable, Identifiable {
    case day
    case month
    case total

    var id: String { rawValue }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .day: return language.text("今天", "Day")
        case .month: return language.text("本月", "Month")
        case .total: return language.text("总计", "Total")
        }
    }
}

struct TokenMonitorDashboardSnapshot {
    struct Day: Identifiable, Equatable {
        let date: String
        let tokens: Int64?
        let cost: Double?
        let messages: Int64?
        let activeTimeMs: Int64?
        let perClient: [String: Int64]
        let perModel: [String: Int64]
        let coverage: TokenMonitorCoverageStatus
        let costCoverage: TokenMonitorCoverageStatus

        var id: String { date }
        func dayValue(_ metric: TokenMonitorMetric) -> Double? {
            switch metric {
            case .tokens: return tokens.map(Double.init)
            case .cost: return cost
            }
        }

        func coverage(for metric: TokenMonitorMetric) -> TokenMonitorCoverageStatus {
            metric == .tokens ? coverage : costCoverage
        }
    }

    struct Summary: Equatable {
        let totalTokens: Int64?
        let totalCost: Double?
        let activeDays: Int64?
        let currentStreak: Int64?
        let peakDayTokens: Int64?
        let favoriteModel: String?
        let messages: Int64?
        let activeTimeMs: Int64?
    }

    struct Breakdown: Identifiable, Equatable {
        let id: String
        let value: Double
        let isCost: Bool
    }

    let response: TokenMonitorResponse?
    let summary: Summary
    let days: [Day]
    let statusText: String?
    private var collectionPhase: TokenMonitorEngineState.Phase? = nil
    let collectedAt: Date?
    let timezone: TimeZone
    let isHubSource: Bool
    let hubIsStale: Bool
    let isStale: Bool
    let hubDevices: [TokenMonitorDevicePresentation]
    private let hubHistory: TokenMonitorHubHistory?
    private let hubRecords: [TokenMonitorHubDevice]
    private let coverageIndex: TokenMonitorResponse.CoverageIndex?
    private let coverageSourceIDs: [String]

    init(state: TokenMonitorEngineState) {
        self.init(response: state.lastGood, isStale: state.isStale)
        collectionPhase = state.phase
    }

    @MainActor
    init(state: TokenMonitorEngineState, hub: TokenMonitorHubSyncStore?) {
        if let hub, hub.isEnabled {
            self.init(hub: hub)
        } else {
            self.init(response: state.lastGood, isStale: state.isStale)
            collectionPhase = state.phase
        }
    }

    init(response: TokenMonitorResponse?, isStale: Bool = false) {
        self.response = response
        self.isHubSource = false
        self.hubIsStale = false
        self.isStale = isStale
        self.hubHistory = nil
        self.hubDevices = []
        self.hubRecords = []
        let coverageIndex = response.map(TokenMonitorResponse.CoverageIndex.init(response:))
        let coverageSourceIDs = response?.sources.filter { $0.status != .excluded }.map(\.id) ?? []
        self.coverageIndex = coverageIndex
        self.coverageSourceIDs = coverageSourceIDs
        let timezone = response.flatMap { TimeZone(identifier: $0.timezone) } ?? TimeZone.current
        self.timezone = timezone
        self.collectedAt = response.flatMap { TokenMonitorResponse.timestamp($0.collectedAt) }
        if let response, response.status == .partial {
            self.statusText = WidgetLanguage.zh.text("部分来源有数据缺口", "Some sources have gaps")
        } else if let response, response.status == .error {
            self.statusText = WidgetLanguage.zh.text("数据读取失败", "Usage data could not be read")
        } else {
            self.statusText = nil
        }

        let history = Self.history(in: response?.payload)
        let summaryJSON = history?["summary"]
        let summary = Summary(
            totalTokens: Self.integer(summaryJSON?["totalTokens"]),
            totalCost: Self.decimal(summaryJSON?["totalCost"]),
            activeDays: Self.integer(summaryJSON?["activeDays"]),
            currentStreak: Self.integer(summaryJSON?["currentStreak"]),
            peakDayTokens: Self.integer(summaryJSON?["peakDayTokens"]),
            favoriteModel: summaryJSON?["favoriteModel"]?.string,
            messages: Self.positiveInteger(summaryJSON?["messages"]),
            activeTimeMs: Self.positiveInteger(summaryJSON?["activeTimeMs"])
        )
        self.summary = summary
        self.days = (history?["daily"]?.array ?? []).compactMap { row in
            guard let date = row["date"]?.string, TokenMonitorResponse.validDate(date) else { return nil }
            return Day(
                date: date,
                tokens: Self.integer(row["tokens"]),
                cost: Self.decimal(row["cost"]),
                messages: Self.positiveInteger(row["messages"]),
                activeTimeMs: Self.positiveInteger(row["activeTimeMs"]),
                perClient: Self.countMap(row["perClient"]),
                perModel: Self.countMap(row["perModel"]),
                coverage: response?.status == .error
                    ? .unknown
                    : coverageIndex?.metricCoverage(sourceIDs: coverageSourceIDs, date: date, metric: "tokens") ?? .unknown,
                costCoverage: response?.status == .error
                    ? .unknown
                    : coverageIndex?.metricCoverage(sourceIDs: coverageSourceIDs, date: date, metric: "cost") ?? .unknown
            )
        }.sorted { $0.date < $1.date }
    }

    @MainActor
    private init(hub: TokenMonitorHubSyncStore) {
        self.response = nil
        self.isHubSource = true
        self.hubIsStale = hub.connectionState == .stale || hub.connectionState == .failed
        self.isStale = self.hubIsStale
        self.hubHistory = hub.history
        self.hubRecords = hub.devices
        self.hubDevices = hub.devices.map(TokenMonitorDevicePresentation.init(device:))
        self.coverageIndex = nil
        self.coverageSourceIDs = []
        self.timezone = .current
        self.collectedAt = hub.lastRefresh
        if let error = hub.error {
            self.statusText = error
        } else if hub.history == nil {
            self.statusText = WidgetLanguage.zh.text("等待可用的 Hub 快照", "Waiting for a Hub snapshot")
        } else if hub.connectionState == .stale || hub.connectionState == .failed {
            self.statusText = WidgetLanguage.zh.text("显示上次成功同步的数据", "Showing the last successful Hub snapshot")
        } else {
            self.statusText = nil
        }
        let source = hub.history
        self.summary = Summary(
            totalTokens: source?.summary.totalTokens,
            totalCost: source?.summary.totalCost,
            activeDays: source?.summary.activeDays.map(Int64.init),
            currentStreak: source?.summary.currentStreak.map(Int64.init),
            peakDayTokens: source?.summary.peakDayTokens,
            favoriteModel: source?.summary.favoriteModel,
            messages: Self.positive(source?.summary.messages),
            activeTimeMs: Self.positive(source?.summary.activeTimeMs)
        )
        self.days = (source?.daily ?? []).map { row in
            Day(
                date: row.date,
                tokens: row.tokens,
                cost: row.cost,
                messages: Self.positive(row.messages),
                activeTimeMs: Self.positive(row.activeTimeMs),
                perClient: Self.hubMetricMap(row.perClient, metric: .tokens),
                perModel: Self.hubMetricMap(row.perModel, metric: .tokens),
                coverage: row.tokens == nil ? .unknown : .known,
                costCoverage: row.cost == nil ? .unknown : .known
            )
        }
    }

    func localizedStatusText(_ language: WidgetLanguage) -> String? {
        if isHubSource {
            if hubHistory == nil {
                return language.text("Hub 同步尚不可用", "Hub sync is not available yet")
            }
            if hubIsStale {
                return language.text("同步中断 · 显示上次成功数据", "Sync interrupted · showing the last successful snapshot")
            }
            if statusText != nil {
                return language.text("Hub 同步暂不可用", "Hub sync is temporarily unavailable")
            }
            return nil
        }
        guard response != nil else {
            switch collectionPhase {
            case .loading: return language.text("正在读取历史用量；记录较多时可能需要几分钟，额度会独立刷新", "Initializing usage history; large archives can take a few minutes. Quotas refresh independently.")
            case .failed: return language.text("用量暂不可用，请重试", "Usage is temporarily unavailable; retry collection.")
            case .stopped: return language.text("采集已暂停", "Collection paused")
            default: return language.text("尚无已采集的用量数据", "No usage data has been collected yet")
            }
        }
        switch response?.status {
        case .partial:
            return language.text("部分来源有数据缺口", "Some sources have gaps")
        case .error:
            return language.text("用量数据读取失败", "Usage data could not be read")
        default:
            return isStale ? language.text("显示上次成功采集的数据", "Showing the last successful collection") : nil
        }
    }

    func value(for period: TokenMonitorPeriod, metric: TokenMonitorMetric, now: Date = Date()) -> Double? {
        if isHubSource {
            switch period {
            case .total:
                switch metric {
                case .tokens: return summary.totalTokens.map(Double.init)
                case .cost: return summary.totalCost
                }
            case .day:
                let formatter = Self.dateFormatter(timezone: timezone)
                guard let day = days.first(where: { $0.date == formatter.string(from: now) }),
                    day.coverage(for: metric) != .unknown
                else { return nil }
                return day.dayValue(metric)
            case .month:
                let formatter = Self.dateFormatter(timezone: timezone)
                let month = String(formatter.string(from: now).prefix(7))
                guard let row = hubHistory?.monthly.first(where: { $0.month == month }) else { return nil }
                switch metric {
                case .tokens: return row.tokens.map(Double.init)
                case .cost: return row.cost
                }
            }
        }
        if period == .total {
            switch metric {
            case .tokens:
                guard Self.coverage(response, date: nil, metric: "tokens") != .unknown else { return nil }
                return Self.integer(response?.payload["aggregate"]?["allTime"]?["totalTokens"]).map(Double.init)
                    ?? summary.totalTokens.map(Double.init)
            case .cost:
                guard response?.coverage.cost != .unknown, response?.coverage.cost != nil else { return nil }
                return Self.aggregateDecimal(response?.payload["aggregate"]?["allTime"], keys: ["costUsd", "costUSD", "totalCost", "cost"])
                    ?? summary.totalCost
            }
        }
        let aggregatePeriod = period == .day ? "today" : "month"
        let coverage: TokenMonitorCoverageStatus
        if period == .day {
            let date = Self.dateFormatter(timezone: timezone).string(from: now)
            let metricName = metric == .tokens ? "tokens" : "cost"
            coverage =
                response?.status == .error
                ? .unknown
                : coverageIndex?.metricCoverage(sourceIDs: coverageSourceIDs, date: date, metric: metricName) ?? .unknown
        } else {
            coverage = Self.coverage(response, date: nil, metric: metric == .tokens ? "tokens" : "cost")
        }
        guard coverage != .unknown else { return nil }
        let aggregate = response?.payload["aggregate"]?[aggregatePeriod]
        if metric == .tokens, let value = Self.integer(aggregate?["totalTokens"]) { return Double(value) }
        if metric == .cost, let value = Self.aggregateDecimal(aggregate, keys: ["costUsd", "costUSD", "totalCost", "cost"]) {
            return value
        }
        let calendar = Self.calendar(timezone: timezone)
        let end = calendar.startOfDay(for: now)
        let start: Date
        if period == .day {
            start = end
        } else {
            start = calendar.dateInterval(of: .month, for: end)?.start ?? end
        }
        let formatter = Self.dateFormatter(timezone: timezone)
        let rows = days.filter { $0.date >= formatter.string(from: start) && $0.date <= formatter.string(from: end) }
        guard !rows.isEmpty else { return nil }
        let selected: [Double?] = rows.map { day in
            guard day.coverage(for: metric) != .unknown else { return nil }
            switch metric {
            case .tokens: return day.tokens.map(Double.init)
            case .cost: return day.cost
            }
        }
        guard selected.allSatisfy({ $0 != nil }) else { return nil }
        return selected.compactMap { $0 }.reduce(0, +)
    }

    /// Keep displayed whole-token totals in Int64; Double loses units above 2^53.
    func tokenCount(for period: TokenMonitorPeriod, now: Date = Date()) -> Int64? {
        guard value(for: period, metric: .tokens, now: now) != nil else { return nil }
        if isHubSource {
            switch period {
            case .total: return summary.totalTokens
            case .day:
                let date = Self.dateFormatter(timezone: timezone).string(from: now)
                return days.first(where: { $0.date == date })?.tokens
            case .month:
                let month = String(Self.dateFormatter(timezone: timezone).string(from: now).prefix(7))
                return hubHistory?.monthly.first(where: { $0.month == month })?.tokens
            }
        }
        let aggregatePeriod = period == .day ? "today" : period == .month ? "month" : "allTime"
        if let count = Self.integer(response?.payload["aggregate"]?[aggregatePeriod]?["totalTokens"]) {
            return count
        }
        if period == .total { return summary.totalTokens }
        let calendar = Self.calendar(timezone: timezone)
        let end = calendar.startOfDay(for: now)
        let start = period == .day ? end : (calendar.dateInterval(of: .month, for: end)?.start ?? end)
        let formatter = Self.dateFormatter(timezone: timezone)
        let lower = formatter.string(from: start)
        let upper = formatter.string(from: end)
        let selected = days.filter { $0.date >= lower && $0.date <= upper }
        guard !selected.isEmpty else { return nil }
        var total: Int64 = 0
        for day in selected {
            guard day.coverage != .unknown, let count = day.tokens else { return nil }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    func trendDays(range: TokenMonitorTrendRange, now: Date = Date()) -> [Day] {
        guard range != .all else { return days }
        let calendar = Self.calendar(timezone: timezone)
        let end = calendar.startOfDay(for: now)
        let length: Int
        switch range {
        case .week: length = 7
        case .month: length = 30
        case .quarter: length = 90
        case .year: length = 365
        case .all: return days
        }
        let start = calendar.date(byAdding: .day, value: -(length - 1), to: end) ?? end
        let formatter = Self.dateFormatter(timezone: timezone)
        let lower = formatter.string(from: start)
        let upper = formatter.string(from: end)
        return days.filter { $0.date >= lower && $0.date <= upper }
    }

    func heatmapDays(count: Int = 365, now: Date = Date()) -> [Day?] {
        let calendar = Self.calendar(timezone: timezone)
        let end = calendar.startOfDay(for: now)
        let dayCount = max(1, min(365, count))
        let firstDay = calendar.date(byAdding: .day, value: -(dayCount - 1), to: end) ?? end
        let formatter = Self.dateFormatter(timezone: timezone)
        let keyed = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        return (0..<dayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return keyed[formatter.string(from: date)]
        }
    }

    func breakdown(byModel: Bool, metric: TokenMonitorMetric, period: TokenMonitorPeriod = .total) -> [Breakdown] {
        if isHubSource {
            var tokenValues: [String: Int64] = [:]
            var costValues: [String: Double] = [:]
            for device in hubRecords {
                let values: TokenMonitorHubPeriod?
                switch period {
                case .day: values = device.periods.today
                case .month: values = device.periods.month
                case .total: values = device.periods.allTime
                }
                let counts = byModel ? values?.models : values?.clients
                let amounts = byModel ? values?.modelCosts : values?.clientCosts
                for (key, count) in counts ?? [:] {
                    let (next, overflow) = (tokenValues[key] ?? 0).addingReportingOverflow(count)
                    if !overflow { tokenValues[key] = next }
                }
                for (key, cost) in amounts ?? [:] where cost.isFinite && cost >= 0 {
                    let next = (costValues[key] ?? 0) + cost
                    if next.isFinite { costValues[key] = next }
                }
            }
            return Self.makeBreakdowns(tokens: tokenValues, costs: costValues, metric: metric)
        }
        guard let response else { return [] }
        let periodKey = period == .day ? "today" : period == .month ? "month" : "allTime"
        let aggregate = response.payload["aggregate"]?[periodKey]
        let countNode = aggregate?[byModel ? "models" : "clients"]
        let costNode = aggregate?[byModel ? "modelCosts" : "clientCosts"]
        var tokenValues = Self.countMap(countNode)
        var costValues = Self.decimalMap(costNode)

        if costValues.isEmpty, metric == .cost {
            return []
        }
        return Self.makeBreakdowns(tokens: tokenValues, costs: costValues, metric: metric)
    }

    private static func makeBreakdowns(tokens: [String: Int64], costs: [String: Double], metric: TokenMonitorMetric) -> [Breakdown] {
        let keys: Set<String> = metric == .tokens ? Set(tokens.keys) : Set(costs.keys)
        return keys.compactMap { key in
            let value: Double?
            switch metric {
            case .tokens:
                value = tokens[key].map(Double.init)
            case .cost:
                value = costs[key]
            }
            guard let value, value.isFinite, value >= 0 else { return nil }
            return Breakdown(id: key, value: value, isCost: metric == .cost)
        }.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    static func integer(_ value: TokenMonitorJSON?) -> Int64? {
        guard case .number(let decimal) = value, !decimal.isNaN,
            decimal >= 0, decimal <= Decimal(Int64.max)
        else { return nil }
        let integer = NSDecimalNumber(decimal: decimal).int64Value
        return Decimal(integer) == decimal ? integer : nil
    }

    private static func positiveInteger(_ value: TokenMonitorJSON?) -> Int64? {
        guard let value = integer(value), value > 0 else { return nil }
        return value
    }

    private static func positive(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func decimal(_ value: TokenMonitorJSON?) -> Double? {
        guard case .number(let decimal) = value else { return nil }
        let result = NSDecimalNumber(decimal: decimal).doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }

    private static func aggregateDecimal(_ value: TokenMonitorJSON?, keys: [String]) -> Double? {
        for key in keys {
            if let parsed = decimal(value?[key]), parsed.isFinite { return parsed }
        }
        return nil
    }

    private static func countMap(_ value: TokenMonitorJSON?) -> [String: Int64] {
        guard case .object(let object) = value else { return [:] }
        return object.compactMapValues { value in
            integer(value) ?? integer(value["tokens"]) ?? integer(value["count"])
        }
    }

    private static func decimalMap(_ value: TokenMonitorJSON?) -> [String: Double] {
        guard case .object(let object) = value else { return [:] }
        return object.compactMapValues { value in decimal(value) ?? decimal(value["cost"]) }
    }

    private static func history(in payload: TokenMonitorJSON?) -> TokenMonitorJSON? {
        let canonical = payload?["aggregate"] ?? payload?["usage"]
        return canonical?["history"] ?? payload?["history"] ?? payload?["usage"]?["history"]
    }

    private static func hubMetricMap(_ values: [String: TokenMonitorHubHistoryMetric]?, metric: TokenMonitorMetric) -> [String: Int64] {
        guard let values else { return [:] }
        guard metric == .tokens else { return [:] }
        return values.compactMapValues(\.tokens)
    }

    private static func coverage(
        _ response: TokenMonitorResponse?,
        date: String?,
        metric: String
    ) -> TokenMonitorCoverageStatus {
        guard let response, response.status != .error else { return .unknown }
        if metric == "cost", date == nil { return response.coverage.cost }
        if let date {
            let ids = response.sources.filter { $0.status != .excluded }.map(\.id)
            return response.metricCoverage(sourceIDs: ids, date: date, metric: metric)
        }
        if response.status == .ok { return .known }
        if response.status == .partial {
            return response.sources.contains { $0.status == .ok } ? .partial : .unknown
        }
        return .unknown
    }

    private static func calendar(timezone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        return calendar
    }

    private static func dateFormatter(timezone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar(timezone: timezone)
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

struct TokenMonitorServiceProviderPresentation: Identifiable, Equatable {
    enum Condition: Equatable {
        case operational
        case degraded
        case outage
        case unknown
    }

    let id: String
    let name: String
    let condition: Condition
    let description: String?
    let pageURL: URL?
    let checkedAt: Date?
    let updatedAt: Date?
    let componentIssues: [String]
    let incidentTitle: String?
    let incidentCount: Int
    let maintenanceCount: Int
    let error: String?
    let isStale: Bool

    func localizedError(_ language: WidgetLanguage) -> String? {
        guard error != nil else { return nil }
        return isStale
            ? language.text("无法刷新；仍显示上次成功读取的状态。", "Could not refresh; showing the last successful status.")
            : language.text("暂时无法读取官方服务状态。", "Official service status is temporarily unavailable.")
    }

    func localizedComponentIssues(_ language: WidgetLanguage) -> [String] {
        componentIssues.map { issue in
            guard let separator = issue.range(of: " · ", options: .backwards) else { return issue }
            let status = String(issue[separator.upperBound...])
            let translated: String
            switch status {
            case "degraded_performance": translated = language.text("性能下降", "Degraded performance")
            case "partial_outage": translated = language.text("部分中断", "Partial outage")
            case "major_outage": translated = language.text("大范围中断", "Major outage")
            case "under_maintenance": translated = language.text("维护中", "Under maintenance")
            case "operational": translated = language.text("正常", "Operational")
            default: return issue
            }
            return String(issue[..<separator.lowerBound]) + " · " + translated
        }
    }
}

struct TokenMonitorServiceStatusPresentation: Equatable {
    let isLoading: Bool
    let checkedAt: Date?
    let error: String?
    let providers: [TokenMonitorServiceProviderPresentation]

    func localizedError(_ language: WidgetLanguage) -> String? {
        guard error != nil else { return nil }
        return language.text("部分官方服务状态暂时无法读取。", "Some official service statuses are temporarily unavailable.")
    }

    static let unavailable = Self(isLoading: false, checkedAt: nil, error: nil, providers: [])

    private init(
        isLoading: Bool,
        checkedAt: Date?,
        error: String?,
        providers: [TokenMonitorServiceProviderPresentation]
    ) {
        self.isLoading = isLoading
        self.checkedAt = checkedAt
        self.error = error
        self.providers = providers
    }

    @MainActor
    init(store: TokenMonitorServiceStatusStore) {
        self.isLoading = store.isLoading
        self.checkedAt = store.lastChecked
        self.error = store.error
        self.providers = store.providers.map { entry in
            let condition: TokenMonitorServiceProviderPresentation.Condition
            switch entry.state {
            case .operational: condition = .operational
            case .degraded: condition = .degraded
            case .outage: condition = .outage
            case .unknown: condition = .unknown
            }
            return TokenMonitorServiceProviderPresentation(
                id: entry.id,
                name: entry.label,
                condition: condition,
                description: entry.description,
                pageURL: URL(string: entry.pageURL),
                checkedAt: entry.checkedAt,
                updatedAt: entry.updatedAt,
                componentIssues: entry.componentIssues.map { $0.name + " · " + $0.status },
                incidentTitle: entry.incidentTitle,
                incidentCount: entry.incidentCount,
                maintenanceCount: entry.maintenanceCount,
                error: entry.error,
                isStale: entry.isStale
            )
        }
    }
}

struct TokenMonitorDevicePresentation: Identifiable, Equatable {
    let id: String
    let name: String
    let isCurrent: Bool
    let todayTokens: Int64?
    let todayCost: Double?
    let monthTokens: Int64?
    let monthCost: Double?
    let totalTokens: Int64?
    let totalCost: Double?
    let updatedAt: Date?
    let isStale: Bool

    init(device: TokenMonitorHubDevice) {
        self.id = device.id
        self.name = device.hostname.isEmpty ? device.platform : device.hostname
        self.isCurrent = device.isCurrent
        self.todayTokens = device.periods.today?.totalTokens
        self.todayCost = device.periods.today?.costUSD
        self.monthTokens = device.periods.month?.totalTokens
        self.monthCost = device.periods.month?.costUSD
        self.totalTokens = device.periods.allTime?.totalTokens
        self.totalCost = device.periods.allTime?.costUSD
        self.updatedAt = TokenMonitorResponse.timestamp(device.updatedAt ?? device.receivedAt ?? "")
        self.isStale = device.stale == true
    }

    func value(for period: TokenMonitorPeriod, metric: TokenMonitorMetric) -> Double? {
        switch (period, metric) {
        case (.day, .tokens): return todayTokens.map(Double.init)
        case (.day, .cost): return todayCost
        case (.month, .tokens): return monthTokens.map(Double.init)
        case (.month, .cost): return monthCost
        case (.total, .tokens): return totalTokens.map(Double.init)
        case (.total, .cost): return totalCost
        }
    }

    func tokenCount(for period: TokenMonitorPeriod) -> Int64? {
        switch period {
        case .day: return todayTokens
        case .month: return monthTokens
        case .total: return totalTokens
        }
    }
}

struct TokenMonitorHubPresentation: Equatable {
    let isEnabled: Bool
    let isLoading: Bool
    let isStale: Bool
    let error: String?
    let currentDeviceID: String?
    let history: [TokenMonitorDashboardSnapshot.Day]
    let devices: [TokenMonitorDevicePresentation]

    func localizedError(_ language: WidgetLanguage) -> String? {
        guard let error else { return nil }
        return TokenMonitorIntegrationFailure.localizedMessage(error, language: language)
    }

    private init(
        isEnabled: Bool,
        isLoading: Bool,
        isStale: Bool,
        error: String?,
        currentDeviceID: String?,
        history: [TokenMonitorDashboardSnapshot.Day],
        devices: [TokenMonitorDevicePresentation]
    ) {
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.isStale = isStale
        self.error = error
        self.currentDeviceID = currentDeviceID
        self.history = history
        self.devices = devices
    }

    static let unavailable = Self(
        isEnabled: false,
        isLoading: false,
        isStale: false,
        error: nil,
        currentDeviceID: nil,
        history: [],
        devices: []
    )

    @MainActor
    init(store: TokenMonitorHubSyncStore) {
        self.isEnabled = store.isEnabled
        self.isLoading = store.connectionState == .connecting
        self.isStale = store.connectionState == .stale || store.connectionState == .failed
        self.error = store.error
        self.currentDeviceID = store.localDeviceID
        self.history = []
        self.devices = store.devices.map(TokenMonitorDevicePresentation.init(device:))
    }
}

enum TokenMonitorFormatting {
    static func count(_ value: Int64?, compact: Bool = false, language: WidgetLanguage = .zh) -> String {
        guard let value else { return "—" }
        if compact {
            return count(Double(value), compact: true, language: language)
        }
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func count(_ value: Double?, compact: Bool = false, language: WidgetLanguage = .zh) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if compact {
            let divisor: Double
            let suffix: String
            if value >= 1_000_000_000 {
                divisor = 1_000_000_000
                suffix = "B"
            } else if value >= 1_000_000 {
                divisor = 1_000_000
                suffix = "M"
            } else if value >= 10_000 {
                divisor = 1_000
                suffix = "K"
            } else {
                divisor = 1
                suffix = ""
            }
            if divisor > 1 {
                let formatter = NumberFormatter()
                formatter.locale = language.locale
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 1
                formatter.minimumFractionDigits = 1
                return (formatter.string(from: NSNumber(value: value / divisor)) ?? "—") + suffix
            }
        }
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    static func cost(_ value: Double?, compact: Bool = false, language: WidgetLanguage = .zh) -> String {
        guard let value, value.isFinite else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = compact && abs(value) >= 1_000 ? 1 : 2
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        let divisor = compact && abs(value) >= 1_000 ? 1_000.0 : 1.0
        let formatted = formatter.string(from: NSNumber(value: value / divisor)) ?? "—"
        return divisor > 1 ? formatted + "K" : formatted
    }

    static func percentage(_ value: Double?, of denominator: Double?, language: WidgetLanguage = .zh) -> String {
        guard let value, let denominator, value.isFinite, denominator.isFinite, denominator > 0, value >= 0 else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 1
        return formatter.string(from: NSNumber(value: min(1, value / denominator))) ?? "—"
    }

    static func time(_ date: Date, language: WidgetLanguage = .zh) -> String {
        date.formatted(.dateTime.hour().minute().locale(language.locale))
    }

    static func duration(milliseconds: Int64?, language: WidgetLanguage = .zh) -> String {
        guard let milliseconds, milliseconds > 0 else { return "—" }
        let minutes = milliseconds / 60_000
        let hours = minutes / 60
        let remaining = minutes % 60
        if language == .zh {
            return hours > 0 ? "\(hours)小时\(remaining)分" : "\(remaining)分"
        }
        return hours > 0 ? "\(hours)h \(remaining)m" : "\(remaining)m"
    }

    static func shortDate(_ date: String, timezone: TimeZone, language: WidgetLanguage = .zh) -> String {
        guard TokenMonitorResponse.validDate(date) else { return date }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = timezone
        formatter.dateFormat = language == .zh ? "M月d日" : "MMM d"
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timezone
        parser.dateFormat = "yyyy-MM-dd"
        guard let value = parser.date(from: date) else { return date }
        return formatter.string(from: value)
    }

    static func dateKey(_ date: Date, timezone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func month(_ date: Date, timezone: TimeZone, language: WidgetLanguage = .zh) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = timezone
        formatter.dateFormat = language == .zh ? "M月" : "MMM"
        return formatter.string(from: date)
    }

    static func elapsed(_ date: Date?, now: Date = Date(), language: WidgetLanguage = .zh) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if language == .zh {
            if seconds < 60 { return seconds < 5 ? "刚刚" : "\(seconds) 秒前" }
            if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
            if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
            return "\(seconds / 86_400) 天前"
        }
        if seconds < 60 { return seconds < 5 ? "Just now" : "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
