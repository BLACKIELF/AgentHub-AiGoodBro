import Foundation

// Only external collectors and unrelated snapshot fields are doubled. The
// full production finishingLoad method, LocalUsage, share merge and checked
// addition are compiled below, along with the real missing-ZCode detector.
typealias DailyTokenBucket = String
typealias LocalThread = String
typealias DetailedUsage = String
typealias UsageTrend = String
typealias ModelInferencePerformanceHistory = String
typealias ProjectBoard = String
typealias ToolUsage = String
typealias SkillUsage = String

// ACTUAL_PRODUCTION_TYPES

enum WidgetLanguage {
    case en
    static func storedOrAutomatic() -> Self { .en }
    func text(_ zh: String, _ en: String) -> String { en }
}

struct RuntimeLoadContext {
    let now: Date
    var statistics = Statistics()
    struct Statistics { var calendar = Calendar(identifier: .gregorian) }
}
enum StatisticsEngineChoice {
    case upstream, custom, nativeLegacy
    static func stored() -> Self { .nativeLegacy }
}
struct AppServerSnapshot {
    var account: Int?
    var limitId: Int?
    var limitName: Int?
    var quotaReadSucceeded: Bool?
    var fiveHourQuota: Int?
    var sevenDayQuota: Int?
    var monthlyQuota: Int?
    var credits: Int?
    var cloudLifetimeTokens: Int?
}
struct UsageSnapshot {
    let refreshedAt: Date
    let account: Int?
    let limitId: Int?
    let limitName: Int?
    let quotaReadSucceeded: Bool?
    let fiveHourQuota: Int?
    let sevenDayQuota: Int?
    let monthlyQuota: Int?
    let credits: Int?
    let cloudLifetimeTokens: Int?
    let local: LocalUsage?
    let taskBoard: Int?
    let messages: [String]
}
enum CustomTokenSourceStore {
    static func load() -> [AgentTokenShare] { [] }
}
struct CCSwitchUsageReader {
    struct Summary { let localUsage: LocalUsage }
    enum Failure: Error { case unavailable }
    static var sample: LocalUsage?
    static var daily: [DailyTokenBucket]?
    func load(context: RuntimeLoadContext) -> Result<Summary, Failure> {
        Self.sample.map { .success(Summary(localUsage: $0)) } ?? .failure(.unavailable)
    }
    func loadDailyHistory(context: RuntimeLoadContext) -> Result<[DailyTokenBucket], Failure> {
        Self.daily.map { .success($0) } ?? .failure(.unavailable)
    }
}
enum ZCodeUsageReader {
    typealias Usage = ActualZCodeUsageReader.Usage
    static var sample: Usage?
    static var reads = 0
    static func usage(todayStart: Date) -> Usage? {
        reads += 1
        return sample
    }
}
enum GrokUsageReader {
    static var sample: Int64?
    static func lifetimeTokens() -> Int64? { sample }
}
enum LocalSQLiteQuery {
    static func rows(executable: URL, database: URL, sql: String) throws -> [[String: Any]] {
        fatalError("Missing synthetic ZCode database must never invoke SQLite")
    }
}
struct CodexUsageReader {
    // ACTUAL_FINISHING_LOAD
}

var checks = 0
var failures = 0
func expect(_ result: Bool, _ label: String) {
    checks += 1
    if !result {
        failures += 1
        print("FAIL: \(label)")
    }
}
func base(_ shares: [AgentTokenShare], today: Int64?, coverage: LocalUsageCoverage = .complete) -> LocalUsage {
    LocalUsage(
        lifetimeTokens: 100, todayTokens: 10, sevenDayTokens: 50, threadCount: 1,
        lastUpdatedAt: nil, dailyBuckets: ["synthetic-day"], recentThreads: [], detailedUsage: nil,
        usageTrend: nil, inferencePerformance: nil, projectBoard: nil, toolUsages: [], skillUsages: [],
        allAgentsLifetimeTokens: summedTokenCounts(shares.map(\.tokens)), allAgentsTodayTokens: today,
        allAgentsShares: shares, coverage: coverage)
}
func finish(_ choice: StatisticsEngineChoice = .nativeLegacy) -> UsageSnapshot {
    CodexUsageReader().finishingLoad(
        appServer: AppServerSnapshot(), messages: [], context: RuntimeLoadContext(now: Date(timeIntervalSince1970: 1_790_000_000)),
        quotaOnly: false, statisticsEngine: choice)
}

let originalShares = [AgentTokenShare(name: "Claude", tokens: 100), AgentTokenShare(name: "Grok", tokens: 20)]
CCSwitchUsageReader.sample = base(originalShares, today: 12)
let emptyHome = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
expect(ActualZCodeUsageReader.usage(todayStart: Date(), homeDirectory: emptyHome) == nil, "uninstalled ZCode is absent")
let absent = finish()
expect(absent.local?.coverage == .complete, "absent optional source keeps verified coverage")
expect(absent.local?.allAgentsLifetimeTokens == 120, "absent ZCode keeps base lifetime")
expect(absent.local?.allAgentsTodayTokens == 12, "absent ZCode keeps base today")
expect(absent.local?.allAgentsShares == originalShares, "absent ZCode keeps verified shares")
expect(absent.messages.isEmpty, "absent optional source is not an overflow")
GrokUsageReader.sample = 30
let grokOnly = finish()
expect(grokOnly.local?.allAgentsLifetimeTokens == 130, "known Grok addition survives absent ZCode")
expect(grokOnly.local?.allAgentsTodayTokens == 12, "Grok lifetime does not invent today")
expect(grokOnly.local?.allAgentsShares?.count == 2, "Grok replaces its existing share")
GrokUsageReader.sample = nil
ZCodeUsageReader.sample = .init(lifetimeTokens: 0, todayTokens: 0)
expect(finish().local == CCSwitchUsageReader.sample, "explicit ZCode zero preserves base")
ZCodeUsageReader.sample = .init(lifetimeTokens: 50, todayTokens: 5)
let added = finish()
expect(added.local?.allAgentsLifetimeTokens == 170 && added.local?.allAgentsTodayTokens == 17, "known ZCode adds both counts")
expect(added.local?.allAgentsShares?.last?.name == "Grok" && added.local?.allAgentsShares?.count == 3, "all known shares remain sorted")
ZCodeUsageReader.sample = .init(lifetimeTokens: Int64.max, todayTokens: 1)
expect(finish().local?.coverage == .dailyOnly, "overflowing lifetime stays rejected")
ZCodeUsageReader.sample = .init(lifetimeTokens: 1, todayTokens: Int64.max)
expect(finish().local?.allAgentsTodayTokens == nil, "overflowing today stays rejected")
ZCodeUsageReader.sample = .init(lifetimeTokens: 1, todayTokens: -1)
expect(finish().local?.allAgentsLifetimeTokens == nil, "invalid negative addition stays rejected")
ZCodeUsageReader.sample = nil
CCSwitchUsageReader.sample = base(originalShares, today: nil)
expect(finish().local?.coverage == .dailyOnly, "unknown base total is never manufactured")
CCSwitchUsageReader.sample = base([], today: 0)
expect(finish().local == CCSwitchUsageReader.sample, "verified all-zero base remains complete")
CCSwitchUsageReader.sample = base(originalShares, today: 12, coverage: .dailyOnly)
let reads = ZCodeUsageReader.reads
expect(finish().local == CCSwitchUsageReader.sample && ZCodeUsageReader.reads == reads, "incomplete base bypasses optional additions")
CCSwitchUsageReader.sample = nil
CCSwitchUsageReader.daily = ["synthetic-day"]
let daily = finish()
expect(daily.local?.coverage == .dailyOnly && daily.local?.allAgentsLifetimeTokens == nil, "daily-only fallback does not create totals")
expect(ZCodeUsageReader.reads == reads, "daily-only fallback never reads optional sources")
expect(finish(.upstream).local == nil, "upstream mode never enters legacy merge")
expect(finish(.custom).local?.coverage == .dailyOnly, "custom mode preserves its own coverage")
print("CCSWITCH OPTIONAL: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
