import Foundation

/// Native preferences for the independent upstream edge dock. `items == nil`
/// follows connected providers; `items == []` is an explicitly empty rail.
struct TokenMonitorEdgeDockPreferences: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case autoHide, always }
    enum Side: String, Codable, CaseIterable { case right, left }

    static let storageKey = "AiGoodBro.edgeDock.v1"

    var enabled = false
    var mode: Mode = .autoHide
    var side: Side = .right
    var offset = 0.3
    var displayID: String?
    var items: [TokenMonitorEdgeDockItem]?
    var hapticEnabled = true
    var warnColors = false

    init(
        enabled: Bool = false,
        mode: Mode = .autoHide,
        side: Side = .right,
        offset: Double = 0.3,
        displayID: String? = nil,
        items: [TokenMonitorEdgeDockItem]? = nil,
        hapticEnabled: Bool = true,
        warnColors: Bool = false
    ) {
        self.enabled = enabled
        self.mode = mode
        self.side = side
        self.offset = offset
        self.displayID = displayID
        self.items = items
        self.hapticEnabled = hapticEnabled
        self.warnColors = warnColors
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, side, offset, displayID, items, hapticEnabled, warnColors
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? values.decode(Bool.self, forKey: .enabled)) ?? false
        mode = (try? values.decode(Mode.self, forKey: .mode)) ?? .autoHide
        side = (try? values.decode(Side.self, forKey: .side)) ?? .right
        offset = (try? values.decode(Double.self, forKey: .offset)) ?? 0.3
        displayID = try? values.decodeIfPresent(String.self, forKey: .displayID)
        items = try? values.decodeIfPresent([TokenMonitorEdgeDockItem].self, forKey: .items)
        hapticEnabled = (try? values.decode(Bool.self, forKey: .hapticEnabled)) ?? true
        warnColors = (try? values.decode(Bool.self, forKey: .warnColors)) ?? false
        self = normalized()
    }

    func normalized() -> Self {
        var result = self
        result.offset = offset.isFinite ? min(1, max(0, offset)) : 0.3
        result.displayID = displayID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.displayID?.isEmpty == true { result.displayID = nil }
        result.items = items.map(TokenMonitorEdgeDockItem.normalizedList)
        return result
    }

    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.normalized()
    }
}

struct TokenMonitorEdgeDockItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case limit, stat }
    enum Metric: String, Codable, CaseIterable, Identifiable {
        case today, week, last7, last30, month, allTime, liveRate, sessions
        var id: String { rawValue }

        func title(_ language: WidgetLanguage) -> String {
            switch self {
            case .today: return language.text("今天", "Today")
            case .week: return language.text("本周", "This week")
            case .last7: return language.text("近 7 天", "Last 7 days")
            case .last30: return language.text("近 30 天", "Last 30 days")
            case .month: return language.text("本月", "This month")
            case .allTime: return language.text("总计", "Total")
            case .liveRate: return language.text("实时速率", "Live rate")
            case .sessions: return language.text("会话", "Sessions")
            }
        }
    }
    enum AccountMode: String, Codable { case active, lowest }
    enum SessionGroup: String, Codable { case none, client }
    enum SessionDetail: String, Codable { case clients, rate }

    var type: Kind
    var providerID: String?
    var metric: Metric?
    var hiddenAccountIDs: [String] = []
    var showUsage = true
    var showSessions = true
    var accountMode: AccountMode = .lowest
    var runningOnly = false
    var groupBy: SessionGroup = .none
    var cellDetail: SessionDetail = .clients

    var id: String {
        switch type {
        case .limit: return "limit:\(providerID ?? "")"
        case .stat: return "stat:\(metric?.rawValue ?? "")"
        }
    }

    static func limit(_ providerID: String) -> Self {
        Self(type: .limit, providerID: providerID, accountMode: providerID == "codex" ? .active : .lowest)
    }

    static func stat(_ metric: Metric) -> Self {
        Self(type: .stat, metric: metric)
    }

    private enum CodingKeys: String, CodingKey {
        case type, providerID, provider, metric, hiddenAccountIDs, hiddenAccounts
        case showUsage, showSessions, accountMode, runningOnly, groupBy, cellDetail
    }

    init(
        type: Kind,
        providerID: String? = nil,
        metric: Metric? = nil,
        hiddenAccountIDs: [String] = [],
        showUsage: Bool = true,
        showSessions: Bool = true,
        accountMode: AccountMode = .lowest,
        runningOnly: Bool = false,
        groupBy: SessionGroup = .none,
        cellDetail: SessionDetail = .clients
    ) {
        self.type = type
        self.providerID = providerID
        self.metric = metric
        self.hiddenAccountIDs = hiddenAccountIDs
        self.showUsage = showUsage
        self.showSessions = showSessions
        self.accountMode = accountMode
        self.runningOnly = runningOnly
        self.groupBy = groupBy
        self.cellDetail = cellDetail
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(Kind.self, forKey: .type)
        providerID =
            (try? values.decode(String.self, forKey: .providerID))
            ?? (try? values.decode(String.self, forKey: .provider))
        metric = try? values.decode(Metric.self, forKey: .metric)
        hiddenAccountIDs =
            (try? values.decode([String].self, forKey: .hiddenAccountIDs))
            ?? (try? values.decode([String].self, forKey: .hiddenAccounts)) ?? []
        showUsage = (try? values.decode(Bool.self, forKey: .showUsage)) ?? true
        showSessions = (try? values.decode(Bool.self, forKey: .showSessions)) ?? true
        accountMode =
            (try? values.decode(AccountMode.self, forKey: .accountMode))
            ?? (providerID == "codex" ? .active : .lowest)
        runningOnly = (try? values.decode(Bool.self, forKey: .runningOnly)) ?? false
        groupBy = (try? values.decode(SessionGroup.self, forKey: .groupBy)) ?? .none
        cellDetail = (try? values.decode(SessionDetail.self, forKey: .cellDetail)) ?? .clients
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        switch type {
        case .limit:
            try values.encode(providerID, forKey: .providerID)
            try values.encode(hiddenAccountIDs, forKey: .hiddenAccountIDs)
            try values.encode(showUsage, forKey: .showUsage)
            try values.encode(showSessions, forKey: .showSessions)
            try values.encode(accountMode, forKey: .accountMode)
        case .stat:
            try values.encode(metric, forKey: .metric)
            if metric == .sessions {
                try values.encode(runningOnly, forKey: .runningOnly)
                try values.encode(groupBy, forKey: .groupBy)
                try values.encode(cellDetail, forKey: .cellDetail)
            }
        }
    }

    func normalized() -> Self? {
        var result = self
        switch type {
        case .limit:
            guard let id = providerID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                TokenMonitorSource.safeID(id)
            else { return nil }
            result.providerID = id
            result.metric = nil
            result.hiddenAccountIDs = Array(
                Set(
                    hiddenAccountIDs
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && $0.utf8.count <= 200 })
            ).sorted().prefix(32).map { $0 }
            if id != "codex" { result.accountMode = .lowest }
        case .stat:
            guard metric != nil else { return nil }
            result.providerID = nil
            result.hiddenAccountIDs = []
        }
        return result
    }

    static func normalizedList(_ items: [Self]) -> [Self] {
        var ids = Set<String>()
        var result: [Self] = []
        for item in items {
            guard let value = item.normalized(), ids.insert(value.id).inserted else { continue }
            result.append(value)
            if result.count == 24 { break }
        }
        return result
    }
}

struct TokenMonitorEdgeDockQuotaRow: Equatable, Identifiable {
    let id: String
    let title: String
    let percentRemaining: Double?
    let valueLabel: String?
    let resetLabel: String
    let fetchedAt: Date?
    let isStale: Bool
    let isAvailable: Bool
}

struct TokenMonitorEdgeDockAccountRow: Equatable, Identifiable {
    let id: String
    let name: String
    let isStale: Bool
    let isAvailable: Bool
    let quotaRows: [TokenMonitorEdgeDockQuotaRow]
}

/// `tokens` remains Int64. Floating point is only for costs and proportions.
struct TokenMonitorEdgeDockRank: Equatable, Identifiable {
    let id: String
    let tokens: Int64?
    let costUSD: Double?
    let share: Double?
}

struct TokenMonitorEdgeDockRateSample: Equatable {
    let speed: Double
    let burn: Double
    let sampledAt: Date
    let expiresAt: Date
    let isIdle: Bool
}

/// A sanitized history row from the last collection, not a live activity feed.
struct TokenMonitorEdgeDockSessionRow: Equatable, Identifiable {
    let id: String
    let clientID: String
    let modelID: String?
    let tokenCount: Int64?
    let costUSD: Double?
    let lastUsedAt: Date
    let turnEnded: Bool
}

struct TokenMonitorEdgeDockCell: Equatable, Identifiable {
    enum Kind: Equatable { case provider, stat }

    let id: String
    let kind: Kind
    let title: String
    let providerID: String?
    let iconID: String?
    let headlineAccountID: String?
    let headlineValueLabel: String?
    let metric: TokenMonitorEdgeDockItem.Metric?
    let percentRemaining: Double?
    let severityRemainingPercent: Double?
    let isStale: Bool
    let isAvailable: Bool
    let tokenCount: Int64?
    let costUSD: Double?
    let byTool: [TokenMonitorEdgeDockRank]
    let byModel: [TokenMonitorEdgeDockRank]
    let liveRate: TokenMonitorEdgeDockRateSample?
    let accounts: [TokenMonitorEdgeDockAccountRow]
    let sessions: [TokenMonitorEdgeDockSessionRow]
    let sessionCount: Int?
    let lastCollectedAt: Date?
    let usageTodayTokens: Int64?
    let usageMonthTokens: Int64?
    let usageTodayCostUSD: Double?
    let usageMonthCostUSD: Double?
    let supportsLiveSessions: Bool
}
