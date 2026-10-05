import Foundation

/// Stable screen selection in the existing displayID preference field. Numeric
/// values are accepted only to migrate older settings; new choices use the
/// built-in screen semantic or a CoreGraphics display UUID.
enum TokenMonitorEdgeDockScreenTarget {
    static let builtInID = "builtin"

    struct Identity: Equatable {
        let numericID: UInt32?
        let uuid: UUID?
        let isBuiltIn: Bool
    }

    static func stableID(for screen: Identity) -> String? {
        if screen.isBuiltIn { return builtInID }
        return screen.uuid.map { "uuid:\($0.uuidString.lowercased())" }
    }

    static func normalizedID(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.lowercased() == builtInID { return builtInID }
        if raw.lowercased().hasPrefix("uuid:"),
            let uuid = UUID(uuidString: String(raw.dropFirst(5)))
        {
            return "uuid:\(uuid.uuidString.lowercased())"
        }
        // Preserve unknown and disconnected legacy selections instead of
        // silently moving the rail to a different screen.
        return raw
    }

    static func index(for selection: String?, in screens: [Identity], preferredIndex: Int?) -> Int? {
        guard !screens.isEmpty else { return nil }
        guard let selection = normalizedID(selection) else {
            if let preferredIndex, screens.indices.contains(preferredIndex) { return preferredIndex }
            return screens.startIndex
        }
        if selection == builtInID { return screens.firstIndex(where: \.isBuiltIn) }
        if selection.hasPrefix("uuid:"),
            let uuid = UUID(uuidString: String(selection.dropFirst(5)))
        {
            return screens.firstIndex { $0.uuid == uuid }
        }
        if let legacy = UInt32(selection) {
            return screens.firstIndex { $0.numericID == legacy }
        }
        return nil
    }

    static func migratedID(_ selection: String?, screens: [Identity]) -> String? {
        guard let selection = normalizedID(selection), UInt32(selection) != nil,
            let index = index(for: selection, in: screens, preferredIndex: nil)
        else { return selection }
        return stableID(for: screens[index]) ?? selection
    }

    /// A fixed choice cannot be changed by dropping onto another display.
    /// A following rail remains following for an in-screen move; crossing to
    /// another identified screen is an intentional new fixed placement.
    static func targetAfterDrag(
        _ selection: String?, originIndex: Int, destinationIndex: Int,
        screens: [Identity]
    ) -> String? {
        guard let selection = normalizedID(selection) else {
            guard originIndex != destinationIndex, screens.indices.contains(destinationIndex) else { return nil }
            return stableID(for: screens[destinationIndex])
        }
        return selection
    }
}

/// Native preferences for the independent upstream edge dock. `items == nil`
/// follows connected providers; `items == []` is an explicitly empty rail.
struct TokenMonitorEdgeDockPreferences: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case autoHide, always }
    enum Side: String, Codable, CaseIterable { case right, left }
    enum QuotaStyle: String, Codable, CaseIterable { case ring, fish }

    static let storageKey = "AiGoodBro.edgeDock.v1"

    var enabled = false
    var mode: Mode = .autoHide
    var side: Side = .right
    var offset = 0.3
    var displayID: String?
    var items: [TokenMonitorEdgeDockItem]?
    var hapticEnabled = true
    var warnColors = false
    var quotaStyle: QuotaStyle = .ring

    init(
        enabled: Bool = false,
        mode: Mode = .autoHide,
        side: Side = .right,
        offset: Double = 0.3,
        displayID: String? = nil,
        items: [TokenMonitorEdgeDockItem]? = nil,
        hapticEnabled: Bool = true,
        warnColors: Bool = false,
        quotaStyle: QuotaStyle = .ring
    ) {
        self.enabled = enabled
        self.mode = mode
        self.side = side
        self.offset = offset
        self.displayID = displayID
        self.items = items
        self.hapticEnabled = hapticEnabled
        self.warnColors = warnColors
        self.quotaStyle = quotaStyle
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, side, offset, displayID, items, hapticEnabled, warnColors, quotaStyle
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
        quotaStyle = (try? values.decode(QuotaStyle.self, forKey: .quotaStyle)) ?? .ring
        self = normalized()
    }

    func normalized() -> Self {
        var result = self
        result.offset = offset.isFinite ? min(1, max(0, offset)) : 0.3
        result.displayID = TokenMonitorEdgeDockScreenTarget.normalizedID(displayID)
        result.items = items.map(TokenMonitorEdgeDockItem.normalizedList)
        return result
    }

    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.normalized()
    }

    /// Read only the previous dock preferences; keep an explicitly empty rail
    /// and the user's visibility choice when its owner becomes the native host.
    static func migratedEmbeddedSettings(_ data: Data) -> Self? {
        struct Embedded: Decodable {
            var edgeDockEnabled: Bool?
            var edgeDockMode: Mode?
            var edgeDockSide: Side?
            var edgeDockOffset: Double?
            var edgeDockDisplayId: String?
            var edgeDockItems: [TokenMonitorEdgeDockItem]?
            var edgeDockHaptic: Bool?
            var edgeDockWarnColors: Bool?
        }
        guard let old = try? JSONDecoder().decode(Embedded.self, from: data), let enabled = old.edgeDockEnabled else { return nil }
        return Self(
            enabled: enabled, mode: old.edgeDockMode ?? .autoHide, side: old.edgeDockSide ?? .right,
            offset: old.edgeDockOffset ?? 0.3, displayID: old.edgeDockDisplayId, items: old.edgeDockItems,
            hapticEnabled: old.edgeDockHaptic ?? true, warnColors: old.edgeDockWarnColors ?? false
        ).normalized()
    }
}

struct TokenMonitorEdgeDockItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case limit, stat, proxy }
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
            case .liveRate: return language.text("采样速率", "Sampled rate")
            case .sessions: return language.text("会话", "Sessions")
            }
        }
    }
    enum AccountMode: String, Codable { case active, lowest }
    enum SessionGroup: String, Codable { case none, client }
    enum SessionDetail: String, Codable { case clients, rate }

    var type: Kind
    var providerID: String?
    var accountID: String?
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
        case .limit:
            let provider = "limit:\(providerID ?? "")"
            return accountID.map { provider + ":account:" + $0 } ?? provider
        case .stat: return "stat:\(metric?.rawValue ?? "")"
        case .proxy: return "proxy"
        }
    }

    static func limit(_ providerID: String) -> Self {
        let id = canonicalProviderID(providerID)
        return Self(type: .limit, providerID: id, accountMode: id == "codex" ? .active : .lowest)
    }

    static func account(_ providerID: String, _ accountID: String) -> Self {
        Self(type: .limit, providerID: canonicalProviderID(providerID), accountID: accountID, showUsage: false, showSessions: false)
    }

    static func stat(_ metric: Metric) -> Self {
        Self(type: .stat, metric: metric)
    }

    static func proxy() -> Self { Self(type: .proxy, showUsage: false, showSessions: false) }

    static func canonicalProviderID(_ value: String) -> String {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id == "claudecode" || id == "claude-code" ? "claude" : id
    }

    private enum CodingKeys: String, CodingKey {
        case type, providerID, provider, accountID, metric, hiddenAccountIDs, hiddenAccounts
        case showUsage, showSessions, accountMode, runningOnly, groupBy, cellDetail
    }

    init(
        type: Kind,
        providerID: String? = nil,
        accountID: String? = nil,
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
        self.accountID = accountID
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
        accountID = try values.decodeIfPresent(String.self, forKey: .accountID)
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
            try values.encodeIfPresent(accountID, forKey: .accountID)
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
        case .proxy: break
        }
    }

    func normalized() -> Self? {
        var result = self
        switch type {
        case .limit:
            guard let id = providerID.map(Self.canonicalProviderID),
                TokenMonitorSource.safeID(id)
            else { return nil }
            result.providerID = id
            result.metric = nil
            if let accountID {
                let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !account.isEmpty, account.utf8.count <= 200,
                    !account.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else { return nil }
                result.accountID = account
                result.hiddenAccountIDs = []
                result.accountMode = .lowest
                result.showUsage = false
                result.showSessions = false
                return result
            }
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
            result.accountID = nil
            result.hiddenAccountIDs = []
        case .proxy:
            return .proxy()
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
    enum Kind: Equatable { case provider, stat, proxy }

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
    var accountLabel: String? = nil
    var accountBindingMissing = false
    /// Timestamp of the selected quota metric, never the UI/usage refresh time.
    var snapshotFetchedAt: Date? = nil
    /// Historical display identity only; never evidence of the current login.
    var isHistoricalAccount = false
    /// Exact selected quota metric; distinguishes a weekly-only short limit from credits.
    var headlineMetricID: String? = nil
    /// Label and reset information from the same row as the headline percentage.
    var headlineMetricName: String? = nil
    var headlineResetLabel: String? = nil

    func snapshotDescription(_ language: WidgetLanguage, now: Date = Date()) -> String {
        guard isAvailable else {
            return accountBindingMissing
                ? language.text("所选账号未匹配，无法显示快照", "Selected account unmatched; no snapshot")
                : language.text("暂无可核对的快照，请刷新或检查账号登录", "No verified snapshot; refresh or check account sign-in")
        }
        let prefix =
            isHistoricalAccount
            ? language.text("上次已核对账号，当前身份待核对 · ", "Last verified account; current identity unverified · ") : ""
        let timestamp = kind == .provider ? snapshotFetchedAt : (liveRate?.sampledAt ?? lastCollectedAt)
        guard let timestamp, timestamp.timeIntervalSince1970.isFinite else {
            return prefix + language.text("快照时间未知", "Snapshot time unknown")
        }
        let age = max(0, now.timeIntervalSince(timestamp))
        guard age.isFinite else { return prefix + language.text("快照时间未知", "Snapshot time unknown") }
        if age < 60 { return prefix + language.text("快照更新于不到 1 分钟前", "Snapshot updated less than 1 min ago") }
        // Bounded conversion also protects presentation from corrupt timestamps.
        let minutes = Int(min(age / 60, 99_999_999))
        if minutes < 60 { return prefix + language.text("快照更新于 \(minutes) 分钟前", "Snapshot updated \(minutes) min ago") }
        if minutes < 1440 { return prefix + language.text("快照更新于 \(minutes / 60) 小时前", "Snapshot updated \(minutes / 60) hr ago") }
        return prefix + language.text("快照更新于 \(minutes / 1440) 天前", "Snapshot updated \(minutes / 1440) days ago")
    }
    var proxyPhase: LocalProxyPhase? = nil
    /// Already admitted, still-owned requests; never inferred from quota or history.
    var proxyAccounts: [LocalProxyQueueRow] = []

    var proxyRequestCount: Int { proxyAccounts.reduce(0) { $0 + $1.activeRequestCount } }

    var accountBadge: String? {
        guard let label = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !label.isEmpty, !["—", "–", "-", "--", "…"].contains(label)
        else { return nil }
        return String(label.prefix(2))
    }

    func proxyStatusTitle(_ language: WidgetLanguage) -> String {
        switch proxyPhase {
        case .stopped: return language.text("已停止", "Stopped")
        case .starting: return language.text("正在启动", "Starting")
        case .running: return proxyAccounts.isEmpty ? language.text("空闲", "Idle") : language.text("运行中", "Running")
        case .stopping: return language.text("正在停止", "Stopping")
        case .failed: return language.text("需要处理", "Needs attention")
        case nil: return language.text("状态待确认", "Status pending")
        }
    }
}

/// Shared by the input observer and native panel configuration. Equal evidence
/// must not start another projection or replace an unchanged hosting view.
struct TokenMonitorEdgeDockChangeGate<Value: Equatable> {
    private var previous: Value?

    mutating func accept(_ value: Value) -> Bool {
        guard previous != value else { return false }
        previous = value
        return true
    }

    mutating func reset() { previous = nil }
}

enum TokenMonitorEdgeDockIdlePolicy {
    static func shouldClearOutside(
        hasCard: Bool, railVisible: Bool, mode: TokenMonitorEdgeDockPreferences.Mode, pinned: Bool,
        cardPinned: Bool = false
    ) -> Bool {
        !cardPinned && (hasCard || (railVisible && mode == .autoHide && !pinned))
    }

    static func tickInterval(nearEdge: Bool, hasCard: Bool, dragging: Bool, waitingOutside: Bool) -> TimeInterval {
        nearEdge || hasCard || dragging || waitingOutside ? 0.05 : 0.2
    }
}

/// Keep every configured cell reachable on small displays without clipped hit targets.
struct TokenMonitorEdgeDockPage {
    let indices: Range<Int>
    let index: Int
    let count: Int

    static func make(cellCount: Int, availableHeight: Double, index: Int) -> Self {
        let capacity = max(1, Int(max(0, availableHeight - 64) / 56))
        let count = max(1, (cellCount + capacity - 1) / capacity)
        let page = max(0, min(count - 1, index))
        let start = min(cellCount, page * capacity)
        return Self(indices: start..<min(cellCount, start + capacity), index: page, count: count)
    }
}
