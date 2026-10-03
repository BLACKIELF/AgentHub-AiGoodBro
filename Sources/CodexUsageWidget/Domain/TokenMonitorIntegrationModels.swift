import Foundation
import Security

enum TokenMonitorHubCredentialStatus: String, Sendable {
    case missing
    case stored
}

enum TokenMonitorHubConnectionState: String, Sendable {
    case disabled
    case idle
    case connecting
    case connected
    case stale
    case failed

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .disabled: language.text("已关闭", "Off")
        case .idle: language.text("待连接", "Not connected")
        case .connecting: language.text("正在连接", "Connecting")
        case .connected: language.text("已连接", "Connected")
        case .stale: language.text("显示上次数据", "Showing last successful data")
        case .failed: language.text("连接失败", "Connection failed")
        }
    }
}

struct TokenMonitorHubPeriod: Decodable, Equatable, Sendable {
    let totalTokens: Int64?
    let costUSD: Double?
    let clients: [String: Int64]?
    let clientCosts: [String: Double]?
    let models: [String: Int64]?
    let modelCosts: [String: Double]?

    enum CodingKeys: String, CodingKey {
        // swift-format-ignore: AlwaysUseLowerCamelCase
        case totalTokens, total_tokens, costUsd, costUSD, cost, clients, clientCosts, models, modelCosts
    }

    init(
        totalTokens: Int64?, costUSD: Double?, clients: [String: Int64]? = nil,
        clientCosts: [String: Double]? = nil, models: [String: Int64]? = nil,
        modelCosts: [String: Double]? = nil
    ) {
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.clients = clients
        self.clientCosts = clientCosts
        self.models = models
        self.modelCosts = modelCosts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens =
            try c.decodeIfPresent(Int64.self, forKey: .totalTokens)
            ?? c.decodeIfPresent(Int64.self, forKey: .total_tokens)
        costUSD =
            try c.decodeIfPresent(Double.self, forKey: .costUsd)
            ?? c.decodeIfPresent(Double.self, forKey: .costUSD)
            ?? c.decodeIfPresent(Double.self, forKey: .cost)
        clients = try c.decodeIfPresent([String: Int64].self, forKey: .clients)
        clientCosts = try c.decodeIfPresent([String: Double].self, forKey: .clientCosts)
        models = try c.decodeIfPresent([String: Int64].self, forKey: .models)
        modelCosts = try c.decodeIfPresent([String: Double].self, forKey: .modelCosts)
    }
}

struct TokenMonitorHubPeriods: Decodable, Equatable, Sendable {
    let today: TokenMonitorHubPeriod?
    let month: TokenMonitorHubPeriod?
    let allTime: TokenMonitorHubPeriod?

    enum CodingKeys: String, CodingKey { case today, month, allTime }
}

struct TokenMonitorHubDevice: Decodable, Equatable, Identifiable, Sendable {
    var id: String { deviceId }
    let deviceId: String
    let hostname: String
    let platform: String
    let osName: String?
    let osVersion: String?
    let agentVersion: String
    let agentRuntime: String
    let updatedAt: String?
    let receivedAt: String?
    let ageMs: Int64?
    let stale: Bool?
    let trackedClients: [String]?
    let periods: TokenMonitorHubPeriods
    var isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case deviceId, hostname, platform, osName, osVersion, agentVersion, agentRuntime
        case updatedAt, receivedAt, ageMs, stale, trackedClients, periods
    }

    init(
        deviceId: String, hostname: String, platform: String, osName: String? = nil,
        osVersion: String? = nil, agentVersion: String, agentRuntime: String,
        updatedAt: String? = nil, receivedAt: String? = nil, ageMs: Int64? = nil,
        stale: Bool? = nil, trackedClients: [String]? = nil,
        periods: TokenMonitorHubPeriods, isCurrent: Bool = false
    ) {
        self.deviceId = Self.safeLabel(deviceId, maximum: 128)
        self.hostname = Self.safeLabel(hostname, maximum: 128)
        self.platform = Self.safeLabel(platform, maximum: 32)
        self.osName = Self.optionalLabel(osName, maximum: 64)
        self.osVersion = Self.optionalLabel(osVersion, maximum: 64)
        self.agentVersion = Self.safeLabel(agentVersion, maximum: 64)
        self.agentRuntime = Self.safeLabel(agentRuntime, maximum: 64)
        self.updatedAt = Self.optionalLabel(updatedAt, maximum: 64)
        self.receivedAt = Self.optionalLabel(receivedAt, maximum: 64)
        self.ageMs = ageMs
        self.stale = stale
        self.trackedClients = trackedClients?.prefix(64).map { Self.safeLabel($0, maximum: 64) }
        self.periods = periods
        self.isCurrent = isCurrent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try c.decode(String.self, forKey: .deviceId)
        guard TokenMonitorSource.safeID(rawID), rawID.utf8.count <= 128 else {
            throw TokenMonitorIntegrationFailure.invalidResponse
        }
        deviceId = rawID
        hostname = Self.safeLabel(try c.decodeIfPresent(String.self, forKey: .hostname) ?? "", maximum: 128)
        platform = Self.safeLabel(try c.decodeIfPresent(String.self, forKey: .platform) ?? "", maximum: 32)
        osName = Self.optionalLabel(try c.decodeIfPresent(String.self, forKey: .osName), maximum: 64)
        osVersion = Self.optionalLabel(try c.decodeIfPresent(String.self, forKey: .osVersion), maximum: 64)
        agentVersion = Self.safeLabel(try c.decodeIfPresent(String.self, forKey: .agentVersion) ?? "", maximum: 64)
        agentRuntime = Self.safeLabel(try c.decodeIfPresent(String.self, forKey: .agentRuntime) ?? "", maximum: 64)
        updatedAt = Self.optionalLabel(try c.decodeIfPresent(String.self, forKey: .updatedAt), maximum: 64)
        receivedAt = Self.optionalLabel(try c.decodeIfPresent(String.self, forKey: .receivedAt), maximum: 64)
        ageMs = try c.decodeIfPresent(Int64.self, forKey: .ageMs)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
        trackedClients = try c.decodeIfPresent([String].self, forKey: .trackedClients)?.prefix(64).map {
            Self.safeLabel($0, maximum: 64)
        }
        periods =
            try c.decodeIfPresent(TokenMonitorHubPeriods.self, forKey: .periods)
            ?? TokenMonitorHubPeriods(today: nil, month: nil, allTime: nil)
        isCurrent = false  // Derived only after matching this record to our saved device ID.
    }

    static func safeLabel(_ value: String, maximum: Int) -> String {
        String(value.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(maximum))
    }

    static func optionalLabel(_ value: String?, maximum: Int) -> String? {
        value.map { safeLabel($0, maximum: maximum) }
    }
}

struct TokenMonitorHubHistoryMetric: Decodable, Equatable, Sendable {
    let tokens: Int64?
    let cost: Double?

    enum CodingKeys: String, CodingKey { case tokens, totalTokens, cost, costUsd }
    init(tokens: Int64?, cost: Double?) {
        self.tokens = tokens
        self.cost = cost
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens =
            try c.decodeIfPresent(Int64.self, forKey: .tokens)
            ?? c.decodeIfPresent(Int64.self, forKey: .totalTokens)
        cost =
            try c.decodeIfPresent(Double.self, forKey: .cost)
            ?? c.decodeIfPresent(Double.self, forKey: .costUsd)
    }
}

struct TokenMonitorHubHistoryDay: Decodable, Equatable, Identifiable, Sendable {
    var id: String { date }
    let date: String
    let tokens: Int64?
    let cost: Double?
    let messages: Int64?
    let activeTimeMs: Int64?
    let perClient: [String: TokenMonitorHubHistoryMetric]?
    let perModel: [String: TokenMonitorHubHistoryMetric]?

    enum CodingKeys: String, CodingKey { case date, tokens, cost, messages, activeTimeMs, perClient, perModel }
    init(
        date: String, tokens: Int64? = nil, cost: Double? = nil, messages: Int64? = nil,
        activeTimeMs: Int64? = nil, perClient: [String: TokenMonitorHubHistoryMetric]? = nil,
        perModel: [String: TokenMonitorHubHistoryMetric]? = nil
    ) {
        self.date = date
        self.tokens = tokens
        self.cost = cost
        self.messages = messages
        self.activeTimeMs = activeTimeMs
        self.perClient = perClient
        self.perModel = perModel
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawDate = try c.decode(String.self, forKey: .date)
        guard TokenMonitorResponse.validDate(rawDate) else { throw TokenMonitorIntegrationFailure.invalidResponse }
        date = rawDate
        tokens = try c.decodeIfPresent(Int64.self, forKey: .tokens)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        messages = try c.decodeIfPresent(Int64.self, forKey: .messages)
        activeTimeMs = try c.decodeIfPresent(Int64.self, forKey: .activeTimeMs)
        perClient = try c.decodeIfPresent([String: TokenMonitorHubHistoryMetric].self, forKey: .perClient)
        perModel = try c.decodeIfPresent([String: TokenMonitorHubHistoryMetric].self, forKey: .perModel)
    }
}

struct TokenMonitorHubHistoryMonth: Decodable, Equatable, Identifiable, Sendable {
    var id: String { month }
    let month: String
    let tokens: Int64?
    let cost: Double?
    let activeTimeMs: Int64?
    let perClient: [String: TokenMonitorHubHistoryMetric]?
    let perModel: [String: TokenMonitorHubHistoryMetric]?

    enum CodingKeys: String, CodingKey { case month, tokens, cost, activeTimeMs, perClient, perModel }
    init(
        month: String, tokens: Int64? = nil, cost: Double? = nil, activeTimeMs: Int64? = nil,
        perClient: [String: TokenMonitorHubHistoryMetric]? = nil,
        perModel: [String: TokenMonitorHubHistoryMetric]? = nil
    ) {
        self.month = month
        self.tokens = tokens
        self.cost = cost
        self.activeTimeMs = activeTimeMs
        self.perClient = perClient
        self.perModel = perModel
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawMonth = try c.decode(String.self, forKey: .month)
        guard rawMonth.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil else {
            throw TokenMonitorIntegrationFailure.invalidResponse
        }
        month = rawMonth
        tokens = try c.decodeIfPresent(Int64.self, forKey: .tokens)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        activeTimeMs = try c.decodeIfPresent(Int64.self, forKey: .activeTimeMs)
        perClient = try c.decodeIfPresent([String: TokenMonitorHubHistoryMetric].self, forKey: .perClient)
        perModel = try c.decodeIfPresent([String: TokenMonitorHubHistoryMetric].self, forKey: .perModel)
    }
}

struct TokenMonitorHubHistorySummary: Decodable, Equatable, Sendable {
    let totalTokens: Int64?
    let totalCost: Double?
    let activeDays: Int?
    let currentStreak: Int?
    let longestStreak: Int?
    let peakDayTokens: Int64?
    let favoriteModel: String?
    let messages: Int64?
    let activeTimeMs: Int64?

    init(
        totalTokens: Int64?, totalCost: Double?, activeDays: Int?, currentStreak: Int?,
        longestStreak: Int?, peakDayTokens: Int64?, favoriteModel: String?, messages: Int64?, activeTimeMs: Int64?
    ) {
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.activeDays = activeDays
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.peakDayTokens = peakDayTokens
        self.favoriteModel = favoriteModel
        self.messages = messages
        self.activeTimeMs = activeTimeMs
    }

    enum CodingKeys: String, CodingKey {
        case totalTokens, totalCost, totalCostUsd, activeDays, currentStreak, longestStreak
        case peakDayTokens, favoriteModel, messages, activeTimeMs
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try c.decodeIfPresent(Int64.self, forKey: .totalTokens)
        totalCost =
            try c.decodeIfPresent(Double.self, forKey: .totalCost)
            ?? c.decodeIfPresent(Double.self, forKey: .totalCostUsd)
        activeDays = try c.decodeIfPresent(Int.self, forKey: .activeDays)
        currentStreak = try c.decodeIfPresent(Int.self, forKey: .currentStreak)
        longestStreak = try c.decodeIfPresent(Int.self, forKey: .longestStreak)
        peakDayTokens = try c.decodeIfPresent(Int64.self, forKey: .peakDayTokens)
        favoriteModel = TokenMonitorHubDevice.optionalLabel(try c.decodeIfPresent(String.self, forKey: .favoriteModel), maximum: 128)
        messages = try c.decodeIfPresent(Int64.self, forKey: .messages)
        activeTimeMs = try c.decodeIfPresent(Int64.self, forKey: .activeTimeMs)
    }
}

extension TokenMonitorServiceHealth {
    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .operational: language.text("正常", "Operational")
        case .degraded: language.text("性能下降", "Degraded")
        case .outage: language.text("服务中断", "Outage")
        case .unknown: language.text("未知", "Unknown")
        }
    }
}

struct TokenMonitorHubHistory: Decodable, Equatable, Sendable {
    let daily: [TokenMonitorHubHistoryDay]
    let monthly: [TokenMonitorHubHistoryMonth]
    let summary: TokenMonitorHubHistorySummary

    enum CodingKeys: String, CodingKey { case daily, monthly, summary }
    init(daily: [TokenMonitorHubHistoryDay], monthly: [TokenMonitorHubHistoryMonth], summary: TokenMonitorHubHistorySummary) {
        self.daily = Array(daily.suffix(400))
        self.monthly = Array(monthly.suffix(120))
        self.summary = summary
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daily = Array(try c.decodeIfPresent([TokenMonitorHubHistoryDay].self, forKey: .daily) ?? []).suffix(400)
        monthly = Array(try c.decodeIfPresent([TokenMonitorHubHistoryMonth].self, forKey: .monthly) ?? []).suffix(120)
        summary =
            try c.decodeIfPresent(TokenMonitorHubHistorySummary.self, forKey: .summary)
            ?? TokenMonitorHubHistorySummary(
                totalTokens: nil, totalCost: nil, activeDays: nil, currentStreak: nil, longestStreak: nil, peakDayTokens: nil, favoriteModel: nil, messages: nil, activeTimeMs: nil)
    }
}

enum TokenMonitorIntegrationFailure: Error, Equatable, Sendable {
    case invalidConfiguration
    case missingCredential
    case keychain(OSStatus)
    case unsafeTransport
    case responseTooLarge
    case invalidResponse
    case httpStatus(Int)
    case transport

    var displayMessage: String {
        switch self {
        case .invalidConfiguration: return "Enter a valid HTTPS Hub URL. Local HTTP is allowed only for localhost."
        case .missingCredential: return "A Hub bearer key is required."
        case .keychain: return "The Hub key could not be accessed in Keychain."
        case .unsafeTransport: return "The Hub connection was blocked because its transport was not secure."
        case .responseTooLarge: return "The Hub returned a response larger than the allowed limit."
        case .invalidResponse: return "The Hub returned data this version cannot read."
        case .httpStatus(let status): return "The Hub request failed (HTTP \(status))."
        case .transport: return "The Hub could not be reached. Check its address and network."
        }
    }

    func localizedMessage(_ language: WidgetLanguage) -> String {
        switch self {
        case .invalidConfiguration:
            language.text("请输入有效的 HTTPS Hub 地址。本机 HTTP 仅允许 localhost。", "Enter a valid HTTPS Hub URL. Local HTTP is allowed only for localhost.")
        case .missingCredential:
            language.text("需要 Hub bearer key。", "A Hub bearer key is required.")
        case .keychain:
            language.text("无法从钥匙串读取 Hub key。", "The Hub key could not be accessed in Keychain.")
        case .unsafeTransport:
            language.text("连接已拦截：Hub 地址未使用安全传输。", "The Hub connection was blocked because its transport was not secure.")
        case .responseTooLarge:
            language.text("Hub 返回的数据超过大小限制。", "The Hub returned a response larger than the allowed limit.")
        case .invalidResponse:
            language.text("无法读取此版本返回的 Hub 数据。", "The Hub returned data this version cannot read.")
        case .httpStatus(let status):
            language.text("Hub 请求失败（HTTP \(status)）。", "The Hub request failed (HTTP \(status)).")
        case .transport:
            language.text("无法连接 Hub，请检查地址和网络。", "The Hub could not be reached. Check its address and network.")
        }
    }

    static func localizedMessage(_ rawMessage: String, language: WidgetLanguage) -> String {
        if rawMessage == "Enable Hub sync and confirm the data scope before publishing this device." {
            return language.text("请先启用 Hub 同步，并确认数据范围后再发布本机用量。", "Enable Hub sync and confirm the data scope before publishing this device.")
        }
        for failure in [
            Self.invalidConfiguration, .missingCredential, .keychain(errSecSuccess), .unsafeTransport,
            .responseTooLarge, .invalidResponse, .transport,
        ] where rawMessage == failure.displayMessage {
            return failure.localizedMessage(language)
        }
        if rawMessage.hasPrefix("The Hub request failed (HTTP "),
            let status = Int(rawMessage.dropFirst("The Hub request failed (HTTP ".count).prefix(while: \.isNumber))
        {
            return Self.httpStatus(status).localizedMessage(language)
        }
        return language.text("Hub 同步暂时不可用。", "Hub sync is temporarily unavailable.")
    }
}
