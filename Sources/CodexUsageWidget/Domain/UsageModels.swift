import Foundation

struct RateWindow: Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct CreditsInfo: Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
    let resetCredits: Int?
    let resetCreditDetails: [ResetCreditDetail]?
}

struct ResetCreditDetail: Identifiable, Equatable {
    let id: String
    let expiresAt: Date?
}

struct ResetCreditDisclosure: Equatable {
    static let inlineDetailLimit = 2

    let totalCount: Int
    let details: [ResetCreditDetail]

    var fullDetails: [ResetCreditDetail] {
        Array(details.prefix(max(0, totalCount)))
    }

    var inlineDetails: [ResetCreditDetail] {
        Array(fullDetails.prefix(Self.inlineDetailLimit))
    }

    var hiddenCount: Int {
        max(0, totalCount - inlineDetails.count)
    }

    var missingDetailCount: Int {
        max(0, totalCount - fullDetails.count)
    }

    var showsHoverTooltip: Bool {
        !inlineDetails.isEmpty
    }
}

struct AccountInfo: Equatable {
    let type: String
    let planType: String?
    let emailPresent: Bool
    let email: String?

    init(type: String, planType: String?, emailPresent: Bool, email: String? = nil) {
        self.type = type
        self.planType = planType
        self.emailPresent = emailPresent
        self.email = email
    }
}

struct LocalThread: Identifiable, Equatable {
    let id: String
    let title: String
    let tokens: Int64
    let updatedAt: Date?
    let model: String?
    let cwd: String
    let archived: Bool
}

struct DailyTokenBucket: Identifiable, Equatable {
    let id: String
    let label: String
    let tokens: Int64
}

enum UsageSourceQuality: String, Equatable, Codable {
    case detailed
    case approximate
}

struct TokenBreakdown: Equatable, Codable {
    var inputTokens: Int64
    var cachedInputTokens: Int64
    var cacheWriteInputTokens: Int64
    var outputTokens: Int64
    var reasoningOutputTokens: Int64
    var totalTokens: Int64

    init(
        inputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteInputTokens: Int64 = 0,
        outputTokens: Int64,
        reasoningOutputTokens: Int64,
        totalTokens: Int64
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    static let zero = TokenBreakdown(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    var billableCachedInputTokens: Int64 {
        min(max(cachedInputTokens, 0), max(inputTokens, 0))
    }

    var uncachedInputTokens: Int64 {
        max(0, inputTokens - billableCachedInputTokens)
    }

    var billableCacheWriteInputTokens: Int64 {
        min(max(cacheWriteInputTokens, 0), uncachedInputTokens)
    }

    var ordinaryUncachedInputTokens: Int64 {
        max(0, uncachedInputTokens - billableCacheWriteInputTokens)
    }

    var visibleTotalTokens: Int64 {
        max(totalTokens, inputTokens + outputTokens)
    }

    var splitTotalTokens: Int64 {
        max(uncachedInputTokens + billableCachedInputTokens + max(outputTokens, 0), 0)
    }

    var isZero: Bool {
        inputTokens == 0
            && cachedInputTokens == 0
            && cacheWriteInputTokens == 0
            && outputTokens == 0
            && reasoningOutputTokens == 0
            && totalTokens == 0
    }

    mutating func add(_ other: TokenBreakdown) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        cacheWriteInputTokens += other.cacheWriteInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
    }

    func delta(from previous: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: inputTokens - previous.inputTokens,
            cachedInputTokens: cachedInputTokens - previous.cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens - previous.cacheWriteInputTokens,
            outputTokens: outputTokens - previous.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens - previous.reasoningOutputTokens,
            totalTokens: totalTokens - previous.totalTokens
        )
    }
}

struct PricedTokenUsage: Equatable, Codable {
    var tokens: TokenBreakdown
    var estimatedCostUSD: Double
    var usesReferencePricing: Bool

    init(tokens: TokenBreakdown, estimatedCostUSD: Double, usesReferencePricing: Bool = false) {
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
        self.usesReferencePricing = usesReferencePricing
    }

    static let zero = PricedTokenUsage(tokens: .zero, estimatedCostUSD: 0, usesReferencePricing: false)

    mutating func add(
        tokens addedTokens: TokenBreakdown,
        costUSD: Double,
        usesReferencePricing addedUsesReferencePricing: Bool = false
    ) {
        tokens.add(addedTokens)
        estimatedCostUSD += costUSD
        usesReferencePricing = usesReferencePricing || addedUsesReferencePricing
    }
}

struct UsageDayBucket: Identifiable, Equatable, Codable {
    let id: String
    let date: Date
    let usage: PricedTokenUsage
    let sourceQuality: UsageSourceQuality

    var tokens: Int64 {
        usage.tokens.visibleTotalTokens
    }
}

struct UsageHeatmapDay: Identifiable, Equatable, Codable {
    let id: String
    let date: Date
    let usage: PricedTokenUsage?
    let isFuture: Bool

    var tokens: Int64 {
        usage?.tokens.visibleTotalTokens ?? 0
    }
}

struct UsageTrendSummary: Equatable, Codable {
    let sevenDay: PricedTokenUsage
    let dailyAverageTokens: Int64
    let peakDay: UsageDayBucket?
    let changePercent: Double?
    let isNewActivity: Bool
}

struct ModelUsageTrend: Identifiable, Equatable, Codable {
    let id: String
    let model: String?
    let dayBuckets: [UsageDayBucket]
    let summary: UsageTrendSummary
    let activeDayCount: Int
}

struct UsageTrend: Equatable, Codable {
    let dayBuckets: [UsageDayBucket]
    let heatmapWeeks: [[UsageHeatmapDay]]
    let heatmapThresholds: [Int64]
    let summary: UsageTrendSummary
    // `nil` means this runtime does not support model attribution; an empty
    // array means attribution is supported but no model record was found.
    let modelTrends: [ModelUsageTrend]?
    let month: PricedTokenUsage
    let projectedMonthCostUSD: Double?
    let activeDayCount: Int
    let sourceQuality: UsageSourceQuality
}

struct DetailedUsage: Equatable, Codable {
    let today: PricedTokenUsage
    let sevenDay: PricedTokenUsage
    let month: PricedTokenUsage
    let lifetime: PricedTokenUsage
    let parsedFileCount: Int
    let tokenEventCount: Int
}

struct ProjectUsage: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let fullPath: String
    let tokens: Int64
    let estimatedCostUSD: Double?
    let threadCount: Int
    let lastActiveAt: Date?
    let sourceQuality: UsageSourceQuality
}

struct ProjectBoard: Equatable {
    let recentProjects: [ProjectUsage]
    let allProjects: [ProjectUsage]
}

struct ToolUsage: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let category: String
    let callCount: Int
    let estimatedTokens: Int64?
    let estimatedCostUSD: Double?
}

struct SkillUsage: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let path: String
    let sourceLabel: String
    let loadCount: Int
    let threadCount: Int
    let staticTokenEstimate: Int64?
    let staticByteCount: Int64?
    let lastLoadedAt: Date?
}

enum LocalUsageCoverage: Equatable {
    case complete
    case dailyOnly
}

struct LocalUsage: Equatable {
    let lifetimeTokens: Int64
    let todayTokens: Int64
    let sevenDayTokens: Int64
    let threadCount: Int
    let lastUpdatedAt: Date?
    let dailyBuckets: [DailyTokenBucket]
    let recentThreads: [LocalThread]
    let detailedUsage: DetailedUsage?
    let usageTrend: UsageTrend?
    let inferencePerformance: ModelInferencePerformanceHistory?
    let projectBoard: ProjectBoard?
    let toolUsages: [ToolUsage]
    let skillUsages: [SkillUsage]
    var allAgentsLifetimeTokens: Int64? = nil
    var allAgentsTodayTokens: Int64? = nil
    var allAgentsShares: [AgentTokenShare]? = nil
    var coverage: LocalUsageCoverage = .complete

    var hasCompleteTotals: Bool { coverage == .complete }
}

enum TaskColumnKind: String, Equatable {
    case active
    case pending
    case scheduled
    case done
}

struct TaskItem: Identifiable, Equatable {
    let id: String
    let code: String
    let title: String
    let detail: String
    let chip: String
    let updatedAt: Date?
    let tokens: Int64?
    let kind: TaskColumnKind
    let threadID: String?
    let runtimeState: TaskRuntimeState
    let isRealtime: Bool
    let sourceKind: TaskSourceKind
    let displayState: TaskDisplayState
    let stateBasis: TaskStateBasis
    let rawStatus: String?
    let nextRunAt: Date?
    let projectPath: String?

    init(
        id: String,
        code: String,
        title: String,
        detail: String,
        chip: String,
        updatedAt: Date?,
        tokens: Int64?,
        kind: TaskColumnKind,
        threadID: String? = nil,
        runtimeState: TaskRuntimeState = .recorded,
        isRealtime: Bool = false,
        sourceKind: TaskSourceKind,
        displayState: TaskDisplayState,
        stateBasis: TaskStateBasis,
        rawStatus: String? = nil,
        nextRunAt: Date? = nil,
        projectPath: String? = nil
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.detail = detail
        self.chip = chip
        self.updatedAt = updatedAt
        self.tokens = tokens
        self.kind = kind
        self.threadID = threadID
        self.runtimeState = runtimeState
        self.isRealtime = isRealtime
        self.sourceKind = sourceKind
        self.displayState = displayState
        self.stateBasis = stateBasis
        self.rawStatus = rawStatus
        self.nextRunAt = nextRunAt
        self.projectPath = projectPath
    }
}

struct TaskColumn: Identifiable, Equatable {
    let id: TaskColumnKind
    let title: String
    let count: Int
    let items: [TaskItem]
}

struct TaskBoard: Equatable {
    let refreshedAt: Date
    let columns: [TaskColumn]

    var totalCount: Int {
        columns.reduce(0) { $0 + $1.count }
    }
}

struct UsageSnapshot: Equatable {
    let refreshedAt: Date
    let account: AccountInfo?
    let limitId: String?
    let limitName: String?
    let quotaReadSucceeded: Bool
    let fiveHourQuota: RateWindow?
    let sevenDayQuota: RateWindow?
    let monthlyQuota: RateWindow?
    let credits: CreditsInfo?
    let cloudLifetimeTokens: Int64?
    let local: LocalUsage?
    let taskBoard: TaskBoard?
    let messages: [String]

    static let empty = UsageSnapshot(
        refreshedAt: Date(),
        account: nil,
        limitId: nil,
        limitName: nil,
        quotaReadSucceeded: false,
        fiveHourQuota: nil,
        sevenDayQuota: nil,
        monthlyQuota: nil,
        credits: nil,
        cloudLifetimeTokens: nil,
        local: nil,
        taskBoard: nil,
        messages: ["正在读取账号数据"]
    )

    func replacingTaskBoard(_ taskBoard: TaskBoard?) -> UsageSnapshot {
        UsageSnapshot(
            refreshedAt: refreshedAt,
            account: account,
            limitId: limitId,
            limitName: limitName,
            quotaReadSucceeded: quotaReadSucceeded,
            fiveHourQuota: fiveHourQuota,
            sevenDayQuota: sevenDayQuota,
            monthlyQuota: monthlyQuota,
            credits: credits,
            cloudLifetimeTokens: cloudLifetimeTokens,
            local: local,
            taskBoard: taskBoard,
            messages: messages
        )
    }

    func replacingQuotaWindows(
        fiveHourQuota: RateWindow?,
        sevenDayQuota: RateWindow?,
        monthlyQuota: RateWindow?,
        credits: CreditsInfo?,
        quotaReadSucceeded: Bool
    ) -> UsageSnapshot {
        UsageSnapshot(
            refreshedAt: refreshedAt,
            account: account,
            limitId: limitId,
            limitName: limitName,
            quotaReadSucceeded: quotaReadSucceeded,
            fiveHourQuota: fiveHourQuota,
            sevenDayQuota: sevenDayQuota,
            monthlyQuota: monthlyQuota,
            credits: credits,
            cloudLifetimeTokens: cloudLifetimeTokens,
            local: local,
            taskBoard: taskBoard,
            messages: messages
        )
    }
}
