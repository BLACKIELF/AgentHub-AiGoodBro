import Foundation

struct FeishuMessageOptions: Codable, Equatable {
    enum ResetExpiryDetail: String, Codable, CaseIterable {
        case nearest
        case all
        case none
    }

    enum ContentPreset: String, CaseIterable {
        case compact, detailed, custom
    }

    var includesAgentName: Bool
    var includesAccountLabel: Bool
    var includesQuotas: Bool
    var includesResetTimes: Bool
    var includesResetCredits: Bool
    var resetExpiryDetail: ResetExpiryDetail
    var notifiesFiveHourReset: Bool
    var notifiesSevenDayReset: Bool

    init(
        includesAgentName: Bool, includesAccountLabel: Bool, includesQuotas: Bool,
        includesResetTimes: Bool, includesResetCredits: Bool, resetExpiryDetail: ResetExpiryDetail,
        notifiesFiveHourReset: Bool = true, notifiesSevenDayReset: Bool = true
    ) {
        self.includesAgentName = includesAgentName
        self.includesAccountLabel = includesAccountLabel
        self.includesQuotas = includesQuotas
        self.includesResetTimes = includesResetTimes
        self.includesResetCredits = includesResetCredits
        self.resetExpiryDetail = resetExpiryDetail
        self.notifiesFiveHourReset = notifiesFiveHourReset
        self.notifiesSevenDayReset = notifiesSevenDayReset
    }

    private enum CodingKeys: String, CodingKey {
        case includesAgentName, includesAccountLabel, includesQuotas, includesResetTimes
        case includesResetCredits, resetExpiryDetail, notifiesFiveHourReset, notifiesSevenDayReset
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        includesAgentName = try values.decodeIfPresent(Bool.self, forKey: .includesAgentName) ?? false
        includesAccountLabel = try values.decodeIfPresent(Bool.self, forKey: .includesAccountLabel) ?? true
        includesQuotas = try values.decodeIfPresent(Bool.self, forKey: .includesQuotas) ?? true
        includesResetTimes = try values.decodeIfPresent(Bool.self, forKey: .includesResetTimes) ?? true
        includesResetCredits = try values.decodeIfPresent(Bool.self, forKey: .includesResetCredits) ?? true
        resetExpiryDetail = try values.decodeIfPresent(ResetExpiryDetail.self, forKey: .resetExpiryDetail) ?? .nearest
        // Existing installations keep receiving the two window types they enabled.
        notifiesFiveHourReset = try values.decodeIfPresent(Bool.self, forKey: .notifiesFiveHourReset) ?? true
        notifiesSevenDayReset = try values.decodeIfPresent(Bool.self, forKey: .notifiesSevenDayReset) ?? true
    }

    var contentPreset: ContentPreset {
        if fieldsMatch(.standard) { return .detailed }
        if fieldsMatch(.compact) { return .compact }
        return .custom
    }

    mutating func applyContentPreset(_ preset: ContentPreset) {
        guard preset != .custom else { return }
        let fields: Self = preset == .compact ? .compact : .standard
        includesAgentName = fields.includesAgentName
        includesAccountLabel = fields.includesAccountLabel
        includesQuotas = fields.includesQuotas
        includesResetTimes = fields.includesResetTimes
        includesResetCredits = fields.includesResetCredits
        resetExpiryDetail = fields.resetExpiryDetail
    }

    func selectedQuotaEvent(_ event: CodexQuotaEvent) -> CodexQuotaEvent? {
        guard case .quotaReset(let fiveHour, let sevenDay) = event else { return event }
        let five = fiveHour && notifiesFiveHourReset
        let seven = sevenDay && notifiesSevenDayReset
        return five || seven ? .quotaReset(fiveHour: five, sevenDay: seven) : nil
    }

    private func fieldsMatch(_ other: Self) -> Bool {
        includesAgentName == other.includesAgentName && includesAccountLabel == other.includesAccountLabel
            && includesQuotas == other.includesQuotas && includesResetTimes == other.includesResetTimes
            && includesResetCredits == other.includesResetCredits && resetExpiryDetail == other.resetExpiryDetail
    }

    private static let compact = FeishuMessageOptions(
        includesAgentName: false, includesAccountLabel: true, includesQuotas: false,
        includesResetTimes: false, includesResetCredits: true, resetExpiryDetail: .none)

    static let standard = FeishuMessageOptions(
        includesAgentName: false,
        includesAccountLabel: true,
        includesQuotas: true,
        includesResetTimes: true,
        includesResetCredits: true,
        resetExpiryDetail: .nearest
    )
}

enum FeishuQuotaValue: Equatable {
    case finite(remainingPercent: Double, resetsAt: Date?)
    case unlimited
    case unknown

    static func generalFiveHour(window: RateWindow?, confirmedPlan: String?) -> FeishuQuotaValue {
        if let window {
            return .finite(remainingPercent: window.remainingPercent, resetsAt: window.resetsAt)
        }
        return .unknown
    }

    static func finiteWindow(_ window: RateWindow?) -> FeishuQuotaValue {
        window.map { .finite(remainingPercent: $0.remainingPercent, resetsAt: $0.resetsAt) } ?? .unknown
    }
}

struct FeishuAccountFacts: Equatable {
    let fiveHour: FeishuQuotaValue
    let sevenDay: FeishuQuotaValue
    let availableResetCredits: Int?
    let resetCreditExpiries: [Date]

    init(
        fiveHour: FeishuQuotaValue,
        sevenDay: FeishuQuotaValue,
        availableResetCredits: Int?,
        resetCreditExpiries: [Date]
    ) throws {
        guard availableResetCredits.map({ $0 >= 0 }) ?? true else {
            throw FeishuWebhookError.invalidNotification
        }
        for value in [fiveHour, sevenDay] {
            if case .finite(let remaining, _) = value,
                !remaining.isFinite || !(0...100).contains(remaining)
            {
                throw FeishuWebhookError.invalidNotification
            }
        }
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.availableResetCredits = availableResetCredits
        self.resetCreditExpiries = resetCreditExpiries.sorted()
    }

    static func snapshot(_ snapshot: UsageSnapshot) throws -> FeishuAccountFacts {
        try FeishuAccountFacts(
            fiveHour: .generalFiveHour(
                window: snapshot.fiveHourQuota,
                confirmedPlan: snapshot.account?.planType
            ),
            sevenDay: .finiteWindow(snapshot.sevenDayQuota),
            availableResetCredits: snapshot.credits?.resetCredits,
            resetCreditExpiries: snapshot.credits?.resetCreditDetails?.compactMap(\.expiresAt) ?? []
        )
    }

    static func quotasOnly(
        fiveHourRemaining: Double?,
        sevenDayRemaining: Double?
    ) throws -> FeishuAccountFacts {
        try FeishuAccountFacts(
            fiveHour: fiveHourRemaining.map { .finite(remainingPercent: $0, resetsAt: nil) } ?? .unknown,
            sevenDay: sevenDayRemaining.map { .finite(remainingPercent: $0, resetsAt: nil) } ?? .unknown,
            availableResetCredits: nil,
            resetCreditExpiries: []
        )
    }
}

struct CreditBalancePresentation: Equatable {
    enum Source: Equatable {
        case verifiedCurrentSnapshot
        case profileSnapshot
    }

    enum Value: Equatable {
        case unlimited
        case reported(String)
        case unavailable
    }

    let value: Value
    let source: Source
    let snapshotAt: Date?

    init(
        balance: String?,
        unlimited: Bool?,
        source: Source = .verifiedCurrentSnapshot,
        snapshotAt: Date? = nil
    ) {
        self.source = source
        self.snapshotAt = snapshotAt
        if unlimited == true {
            value = .unlimited
            return
        }
        guard let normalized = Self.normalizedBalance(balance) else {
            value = .unavailable
            return
        }
        value = .reported(normalized)
    }

    init(
        credits: CreditsInfo?,
        source: Source = .verifiedCurrentSnapshot,
        snapshotAt: Date? = nil
    ) {
        self.init(
            balance: credits?.balance,
            unlimited: credits.map(\.unlimited),
            source: source,
            snapshotAt: snapshotAt
        )
    }

    static func normalizedBalance(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.count <= 40,
            value.range(
                of: #"^-?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?$"#,
                options: .regularExpression
            ) != nil
        else { return nil }
        return value
    }

    func primaryText(_ language: WidgetLanguage) -> String {
        switch value {
        case .unlimited:
            return language.text("无限", "Unlimited")
        case .reported(let balance):
            return balance
        case .unavailable:
            return language.text("不可用", "Unavailable")
        }
    }

    func explanation(_ language: WidgetLanguage) -> String {
        language.text(
            "官方仅返回余额原始值，未提供币种或换算关系。",
            "The official source returns only a raw balance, with no currency or conversion."
        )
    }

    func sourceText(_ language: WidgetLanguage) -> String {
        switch source {
        case .verifiedCurrentSnapshot:
            return language.text("当前账号的已验证官方快照", "Verified official snapshot for this account")
        case .profileSnapshot:
            return language.text("此账号上次保存的官方快照", "Last saved official snapshot for this account")
        }
    }
}
