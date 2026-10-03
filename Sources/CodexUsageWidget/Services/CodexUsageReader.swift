import CoreFoundation
import CryptoKit
import Darwin
import Foundation

private struct ModelTokenPrice {
    let model: String
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let cacheWriteInputPerMillion: Double
    let outputPerMillion: Double
    let fastModeMultiplier: Double?
    let longContextInputMultiplier: Double?
    let longContextOutputMultiplier: Double?
    let usesReferencePricing: Bool

    init(
        model: String,
        inputPerMillion: Double,
        cachedInputPerMillion: Double,
        outputPerMillion: Double,
        cacheWriteInputPerMillion: Double? = nil,
        fastModeMultiplier: Double? = nil,
        longContextInputMultiplier: Double? = nil,
        longContextOutputMultiplier: Double? = nil,
        usesReferencePricing: Bool
    ) {
        self.model = model
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.cacheWriteInputPerMillion = cacheWriteInputPerMillion ?? inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.fastModeMultiplier = fastModeMultiplier
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
        self.usesReferencePricing = usesReferencePricing
    }
}

private struct SessionUsageSource {
    let threadId: String
    let rolloutPath: String
    let model: String?
    let cwd: String
    let updatedAt: Date?
}

private struct SessionUsageDelta: Codable {
    let date: Date
    let tokens: TokenBreakdown
    let model: String?
    let serviceTier: String?
    let eventIdentity: CodexTokenEventIdentity
}

private struct SkillLoadEvent: Codable {
    let path: String
    let date: Date?
}

private struct SessionUsageCacheEntry: Codable {
    let fileSize: Int64
    let modificationDate: Date?
    let forkedFromId: String?
    let hasTokenEvents: Bool
    let tokenEventCount: Int
    let deltas: [SessionUsageDelta]
    let inferenceSamples: [ModelInferenceSample]?
    let inferenceSchemaVersion: Int?
    let toolCalls: [String: Int]
    let skillLoads: [SkillLoadEvent]

    var resolvedInferenceSamples: [ModelInferenceSample] {
        inferenceSamples ?? []
    }
}

private struct SessionUsageDiskCache: Codable {
    let version: Int
    let entries: [String: SessionUsageCacheEntry]
}

private let inferenceBoundaryPayloadTypes: Set<String> = [
    "function_call_output",
    "custom_tool_call_output",
    "tool_search_output",
    "mcp_tool_call_end",
    "web_search_end",
    "patch_apply_end",
    "image_generation_end",
]

private let modelOutputPayloadTypes: Set<String> = [
    "reasoning",
    "agent_reasoning",
    "agent_message",
    "function_call",
    "custom_tool_call",
    "tool_search_call",
    "web_search_call",
]

private struct DetailedUsageAccumulator {
    var today = PricedTokenUsage.zero
    var sevenDay = PricedTokenUsage.zero
    var month = PricedTokenUsage.zero
    var lifetime = PricedTokenUsage.zero
    var parsedFileCount = 0
    var tokenEventCount = 0

    mutating func add(
        _ tokens: TokenBreakdown,
        at date: Date,
        price: ModelTokenPrice,
        serviceTier: String?,
        dayStart: Date,
        sevenDayStart: Date,
        monthStart: Date
    ) {
        let cost = estimatedCostUSD(tokens: tokens, price: price, serviceTier: serviceTier)
        lifetime.add(tokens: tokens, costUSD: cost, usesReferencePricing: price.usesReferencePricing)
        if date >= monthStart {
            month.add(tokens: tokens, costUSD: cost, usesReferencePricing: price.usesReferencePricing)
        }
        if date >= sevenDayStart {
            sevenDay.add(tokens: tokens, costUSD: cost, usesReferencePricing: price.usesReferencePricing)
        }
        if date >= dayStart {
            today.add(tokens: tokens, costUSD: cost, usesReferencePricing: price.usesReferencePricing)
        }
    }

    func makeUsage() -> DetailedUsage {
        DetailedUsage(
            today: today,
            sevenDay: sevenDay,
            month: month,
            lifetime: lifetime,
            parsedFileCount: parsedFileCount,
            tokenEventCount: tokenEventCount
        )
    }
}

private struct ProjectUsageAccumulator {
    let name: String
    let fullPath: String
    var tokens = TokenBreakdown.zero
    var estimatedCostUSD: Double = 0
    var threadIds = Set<String>()
    var lastActiveAt: Date?
    var sourceQuality: UsageSourceQuality = .detailed

    mutating func add(threadId: String, tokens addedTokens: TokenBreakdown, costUSD: Double, at date: Date) {
        tokens.add(addedTokens)
        estimatedCostUSD += costUSD
        threadIds.insert(threadId)
        if lastActiveAt == nil || date > (lastActiveAt ?? .distantPast) {
            lastActiveAt = date
        }
    }

    func makeUsage() -> ProjectUsage {
        ProjectUsage(
            id: fullPath.isEmpty ? name : fullPath,
            name: name,
            fullPath: fullPath,
            tokens: tokens.visibleTotalTokens,
            estimatedCostUSD: estimatedCostUSD,
            threadCount: max(threadIds.count, 1),
            lastActiveAt: lastActiveAt,
            sourceQuality: sourceQuality
        )
    }
}

private struct ToolUsageAccumulator {
    let name: String
    var callCount: Int = 0
    var estimatedTokens: Int64 = 0
    var estimatedCostUSD: Double = 0

    mutating func addCalls(_ calls: Int, estimatedTokens tokens: Int64, estimatedCostUSD cost: Double) {
        callCount += calls
        estimatedTokens += tokens
        estimatedCostUSD += cost
    }

    func makeUsage() -> ToolUsage {
        ToolUsage(
            id: name,
            name: name,
            category: toolCategory(for: name),
            callCount: callCount,
            estimatedTokens: estimatedTokens > 0 ? estimatedTokens : nil,
            estimatedCostUSD: estimatedCostUSD > 0 ? estimatedCostUSD : nil
        )
    }
}

private struct SkillStaticInfo {
    let tokenEstimate: Int64?
    let byteCount: Int64?
}

private struct SkillUsageAccumulator {
    let path: String
    var loadCount: Int = 0
    var threadIds = Set<String>()
    var lastLoadedAt: Date?

    mutating func addLoad(threadId: String, at date: Date?) {
        loadCount += 1
        threadIds.insert(threadId)
        guard let date else { return }
        if lastLoadedAt == nil || date > (lastLoadedAt ?? .distantPast) {
            lastLoadedAt = date
        }
    }

    func makeUsage(staticInfo: SkillStaticInfo) -> SkillUsage {
        return SkillUsage(
            id: path,
            name: skillName(from: path),
            path: path,
            sourceLabel: skillSourceLabel(from: path),
            loadCount: loadCount,
            threadCount: max(threadIds.count, 1),
            staticTokenEstimate: staticInfo.tokenEstimate,
            staticByteCount: staticInfo.byteCount,
            lastLoadedAt: lastLoadedAt
        )
    }
}

private struct LocalAnalytics: Equatable, Codable {
    let detailedUsage: DetailedUsage?
    let usageTrend: UsageTrend?
    let inferencePerformance: ModelInferencePerformanceHistory?
    let recentProjects: [ProjectUsage]
    let toolUsages: [ToolUsage]
    let skillUsages: [SkillUsage]
    let forkBaselineTokensByThreadId: [String: Int64]
}

private struct LocalAnalyticsCacheEntry: Codable {
    let version: Int
    let dayKey: String
    let timeZoneIdentifier: String
    let sourceFingerprint: String
    let analytics: LocalAnalytics
}

private final class AppServerPendingResponses {
    let group = DispatchGroup()
    private let lock = NSLock()
    private let expected: Set<Int>
    private var completed = Set<Int>()

    init(_ ids: [Int]) {
        expected = Set(ids)
        ids.forEach { _ in group.enter() }
    }

    func complete(_ id: Int) {
        lock.lock()
        let shouldLeave = expected.contains(id) && completed.insert(id).inserted
        lock.unlock()
        if shouldLeave { group.leave() }
    }

    /// Returns true only for the first termination that finds requested responses pending.
    func completeRemaining() -> Bool {
        lock.lock()
        let pending = expected.subtracting(completed)
        completed.formUnion(pending)
        lock.unlock()
        pending.forEach { _ in group.leave() }
        return !pending.isEmpty
    }
}

private enum AppServerFailureClassifier {
    private static let permanentCodes: Set<String> = [
        "refresh_token_expired",
        "refresh_token_reused",
        "refresh_token_invalidated",
        "invalid_grant",
    ]

    static func failureReason(from error: [String: Any]) -> String? {
        var inputs = [error["message"] as? String ?? ""]
        collectPermanentCodes(in: error, depth: 0, into: &inputs)
        return CodexProfileStore.quotaFailureReason(from: inputs)
    }

    private static func collectPermanentCodes(in value: Any, depth: Int, into inputs: inout [String]) {
        guard depth <= 4 else { return }
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key == "code" || key == "reason",
                    let code = child as? String,
                    permanentCodes.contains(code.lowercased())
                {
                    // Add only an allowlisted classification marker, never arbitrary server data.
                    inputs.append("refresh error code: \(code.lowercased())")
                } else if child is [String: Any] || child is [Any] {
                    collectPermanentCodes(in: child, depth: depth + 1, into: &inputs)
                }
            }
        } else if let array = value as? [Any] {
            for child in array { collectPermanentCodes(in: child, depth: depth + 1, into: &inputs) }
        }
    }
}

final class CodexUsageReader {
    private let fileManager = FileManager.default
    private let localAnalyticsCacheVersion = 17
    private let sessionUsageCacheVersion = 10
    private let inferenceSampleSchemaVersion = 2
    private static let memorySessionUsageCacheLimit = 64
    private static let persistentSessionUsageCacheLimit = 1_024
    private static let maximumPersistentCacheBytes: Int64 = 128 * 1_024 * 1_024
    private static let persistentSessionUsageCacheWriteInterval: TimeInterval = 15 * 60
    private static var sessionUsageCache: [String: SessionUsageCacheEntry] = [:]
    private static var sessionUsageCacheOrder: [String] = []
    private static var persistentSessionUsageCache: [String: SessionUsageCacheEntry]?
    private static var persistentSessionUsageCacheIsDirty = false
    private static var lastPersistentSessionUsageCacheWriteAt: Date?
    private static var localAnalyticsCache: LocalAnalyticsCacheEntry?
    private static let localAnalyticsLock = NSLock()

    func load(
        context: RuntimeLoadContext, quotaOnly: Bool = false, requestTimeout: TimeInterval? = nil,
        managedProfile: CodexProfile? = nil,
        cancellation: TokenMonitorCancellation = TokenMonitorCancellation(),
        selectLimitsProvider: ((TokenMonitorResponse, String) -> TokenMonitorJSON?)? = nil
    ) -> UsageSnapshot {
        var messages: [String] = []
        let appServer = readQuotaSnapshot(
            context: context,
            quotaOnly: quotaOnly,
            messages: &messages,
            requestTimeout: requestTimeout,
            managedProfile: managedProfile,
            cancellation: cancellation,
            selectLimitsProvider: selectLimitsProvider
        )
        return finishingLoad(
            appServer: appServer,
            messages: messages,
            context: context,
            quotaOnly: quotaOnly
        )
    }

    /// Membership and callers without managed context retain same-home RPC.
    /// Managed reads use the confirmed source-bound HTTP target before optional RPC.
    func readQuotaSnapshot(
        context: RuntimeLoadContext,
        quotaOnly: Bool,
        messages: inout [String],
        refreshingMembershipFor profile: CodexProfile? = nil,
        requestTimeout: TimeInterval? = nil,
        managedProfile: CodexProfile? = nil,
        engine: TokenMonitorEngine = TokenMonitorEngine(),
        cancellation: TokenMonitorCancellation = TokenMonitorCancellation(),
        selectLimitsProvider: ((TokenMonitorResponse, String) -> TokenMonitorJSON?)? = nil
    ) -> AppServerSnapshot {
        let quotaCancellation = context.quotaCancellation ?? cancellation
        if profile != nil || managedProfile == nil || managedProfile?.isSystemProfile == true {
            if profile == nil, let managedProfile, managedProfile.isSystemProfile {
                let systemHome = context.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL
                guard context.codexHomeDirectory.resolvingSymlinksInPath().standardizedFileURL == systemHome,
                    managedProfile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL == systemHome
                else {
                    messages.append(TokenMonitorFailure.invalidSource.rawValue)
                    return AppServerSnapshot()
                }
            }
            return readAppServer(
                context: context, messages: &messages, quotaOnly: quotaOnly,
                refreshingMembershipFor: profile, requestTimeout: requestTimeout,
                cancellation: quotaCancellation)
        }
        guard !quotaCancellation.isCancelled else {
            messages.append(TokenMonitorFailure.cancelled.rawValue)
            return AppServerSnapshot()
        }
        let budget = requestTimeout ?? 15
        guard budget.isFinite, budget > 0 else {
            messages.append(TokenMonitorFailure.invalidRequest.rawValue)
            return AppServerSnapshot()
        }
        let started = ProcessInfo.processInfo.systemUptime
        let home = context.codexHomeDirectory.resolvingSymlinksInPath().standardizedFileURL
        let gate = CodexCredentialAccessGate.homeLock(forHomePath: home.path)
        while !gate.try() {
            guard !quotaCancellation.isCancelled, ProcessInfo.processInfo.systemUptime - started < min(budget, 60) else {
                messages.append(quotaCancellation.isCancelled ? TokenMonitorFailure.cancelled.rawValue : TokenMonitorFailure.timedOut.rawValue)
                return AppServerSnapshot()
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { gate.unlock() }
        guard !quotaCancellation.isCancelled else {
            messages.append(TokenMonitorFailure.cancelled.rawValue)
            return AppServerSnapshot()
        }
        guard let managedProfile, !managedProfile.isSystemProfile,
            managedProfile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL == home,
            home != context.homeDirectory.appendingPathComponent(".codex").resolvingSymlinksInPath().standardizedFileURL,
            let before = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: home),
            managedProfile.matchesRecordedCredential(before)
        else {
            messages.append(TokenMonitorFailure.invalidSource.rawValue)
            return AppServerSnapshot()
        }
        let stableAuth: Data
        do {
            guard
                let data = try DispatchParticipationSync.readBoundedRegularFile(
                    home.appendingPathComponent("auth.json"), maximumBytes: 1_048_576)
            else {
                throw TokenMonitorFailure.invalidSource
            }
            stableAuth = data
        } catch {
            messages.append(TokenMonitorFailure.invalidSource.rawValue)
            return AppServerSnapshot()
        }
        func isStable() -> Bool {
            guard !quotaCancellation.isCancelled,
                ProcessInfo.processInfo.systemUptime - started < min(budget, 60),
                let data = try? DispatchParticipationSync.readBoundedRegularFile(
                    home.appendingPathComponent("auth.json"), maximumBytes: 1_048_576), data == stableAuth,
                let after = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: home)
            else { return false }
            return before.accountID == after.accountID && before.email == after.email
                && managedProfile.matchesRecordedCredential(after)
        }
        var request = TokenMonitorRequest(
            operation: .collectLimits,
            timezone: context.statistics.resolvedIdentifier,
            cacheDirectory: context.cacheDirectory.appendingPathComponent("TokenMonitorEngine").path,
            sources: [
                TokenMonitorSource(
                    id: managedProfile.id, providerId: "codex", kind: .managedAccount,
                    canonicalPath: home.path, pathRole: .codexHome, accountId: managedProfile.id, toolId: "codex")
            ])
        do {
            let remaining = min(budget, 60) - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { throw TokenMonitorFailure.timedOut }
            // Reserve a bounded portion for a meaningful same-home fallback.
            request.options.timeoutMs = max(1, Int(min(remaining * 0.7, 12) * 1000))
            let response = try engine.collect(request: request, cancellation: quotaCancellation)
            guard !quotaCancellation.isCancelled else { throw TokenMonitorFailure.cancelled }
            guard isStable() else { throw TokenMonitorFailure.invalidSource }
            guard response.status != .error,
                let bound = TokenMonitorCodexLimits.select(response, sourceID: managedProfile.id),
                selectLimitsProvider.map({ $0(response, managedProfile.id) == bound }) ?? true
            else {
                throw TokenMonitorFailure.limitsMappingUnavailable
            }
            let limits = try TokenMonitorCodexLimits(
                provider: bound, sourceID: managedProfile.id,
                accountID: managedProfile.id, response: response)
            var result = AppServerSnapshot().replacingEngineQuota(limits, response: response)
            result.quotaProvenance = "engine"
            result.account = AccountInfo(
                type: "chatgpt", planType: nil,
                emailPresent: !before.email.isEmpty, email: before.email)
            if result.auxiliaryReadStatus == .unavailable || !quotaOnly {
                let remaining = min(budget, 60) - (ProcessInfo.processInfo.systemUptime - started)
                if remaining > 2 {
                    let auxiliary = readAppServer(
                        context: context, messages: &messages, quotaOnly: quotaOnly,
                        requestTimeout: min(3, remaining - 1.5), cancellation: quotaCancellation)
                    guard !quotaCancellation.isCancelled else { throw TokenMonitorFailure.cancelled }
                    guard isStable() else { throw TokenMonitorFailure.invalidSource }
                    if managedProfile.matchesRecordedAccount(email: auxiliary.account?.email) {
                        result.account = auxiliary.account
                        result.cloudLifetimeTokens = auxiliary.cloudLifetimeTokens
                        if result.auxiliaryReadStatus == .unavailable, let credits = auxiliary.credits {
                            result.credits = credits
                            result.auxiliaryReadStatus = .legacyRPC
                        }
                    }
                }
            }
            if result.auxiliaryReadStatus == .unavailable || (!quotaOnly && result.cloudLifetimeTokens == nil) {
                messages.append("auxiliary_unavailable")
            }
            guard !quotaCancellation.isCancelled else { throw TokenMonitorFailure.cancelled }
            guard isStable() else { throw TokenMonitorFailure.invalidSource }
            return result
        } catch {
            let reason: TokenMonitorFailure
            if quotaCancellation.isCancelled {
                reason = .cancelled
            } else {
                reason = (error as? TokenMonitorFailure) ?? .invalidResponse
            }
            messages.append(reason.rawValue)
            guard reason != .cancelled else { return AppServerSnapshot() }
            guard isStable() else { return AppServerSnapshot() }
            let remaining = min(budget, 60) - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 1.5 else { return AppServerSnapshot() }
            var fallback = readAppServer(
                context: context, messages: &messages, quotaOnly: quotaOnly,
                requestTimeout: remaining - 1, cancellation: quotaCancellation)
            guard !quotaCancellation.isCancelled else {
                messages.append(TokenMonitorFailure.cancelled.rawValue)
                return AppServerSnapshot()
            }
            guard isStable(), managedProfile.matchesRecordedAccount(email: fallback.account?.email) else {
                messages.append(TokenMonitorFailure.invalidSource.rawValue)
                return AppServerSnapshot()
            }
            fallback.quotaProvenance = "same_home_rpc_fallback"
            fallback.engineFailureCode = reason
            return fallback
        }
    }

    /// 用已取回的 app-server 快照补齐本地统计，组装完整 UsageSnapshot。
    func finishingLoad(
        appServer: AppServerSnapshot,
        messages: [String],
        context: RuntimeLoadContext,
        quotaOnly: Bool,
        statisticsEngine: StatisticsEngineChoice = StatisticsEngineChoice.stored()
    ) -> UsageSnapshot {
        var messages = messages
        func snapshot(local: LocalUsage?) -> UsageSnapshot {
            UsageSnapshot(
                refreshedAt: context.now,
                account: appServer.account,
                limitId: appServer.limitId,
                limitName: appServer.limitName,
                quotaReadSucceeded: appServer.quotaReadSucceeded,
                fiveHourQuota: appServer.fiveHourQuota,
                sevenDayQuota: appServer.sevenDayQuota,
                monthlyQuota: appServer.monthlyQuota,
                credits: appServer.credits,
                cloudLifetimeTokens: appServer.cloudLifetimeTokens,
                local: local,
                taskBoard: nil,
                messages: messages
            )
        }
        if quotaOnly { return snapshot(local: nil) }
        switch statisticsEngine {
        case .upstream:
            // Full multidimensional statistics are owned by UsageStore.engineState.
            // Never present the native collector as a successful engine fallback.
            return snapshot(local: nil)
        case .custom:
            let entries = CustomTokenSourceStore.load().filter { $0.tokens >= 0 }
            let shares = entries.map { AgentTokenShare(name: $0.name, tokens: $0.tokens, manual: true) }
            let total = summedTokenCounts(shares.map(\.tokens))
            return snapshot(
                local: LocalUsage(
                    lifetimeTokens: 0, todayTokens: 0, sevenDayTokens: 0, threadCount: 0,
                    lastUpdatedAt: nil, dailyBuckets: [], recentThreads: [], detailedUsage: nil,
                    usageTrend: nil, inferencePerformance: nil, projectBoard: nil, toolUsages: [], skillUsages: [],
                    allAgentsLifetimeTokens: total, allAgentsTodayTokens: nil, allAgentsShares: shares,
                    coverage: .dailyOnly))
        case .nativeLegacy: break
        }

        var local: LocalUsage?
        let ccSwitchReader = CCSwitchUsageReader()
        switch ccSwitchReader.load(context: context) {
        case .success(let summary):
            local = summary.localUsage
        case .failure(let error):
            messages.append(error.localizedDescription)
            switch ccSwitchReader.loadDailyHistory(context: context) {
            case .success(let dailyBuckets):
                local = LocalUsage(
                    lifetimeTokens: 0,
                    todayTokens: 0,
                    sevenDayTokens: 0,
                    threadCount: 0,
                    lastUpdatedAt: nil,
                    dailyBuckets: dailyBuckets,
                    recentThreads: [],
                    detailedUsage: nil,
                    usageTrend: nil,
                    inferencePerformance: nil,
                    projectBoard: nil,
                    toolUsages: [],
                    skillUsages: [],
                    allAgentsLifetimeTokens: nil,
                    allAgentsTodayTokens: nil,
                    allAgentsShares: nil,
                    coverage: .dailyOnly
                )
                messages.append(
                    WidgetLanguage.storedOrAutomatic().text(
                        "只显示已核对的最近 35 天每日记录；累计统计暂不可确认。历史汇总仅有日期键，按所选统计日展示，未推断原时区。",
                        "Only verified daily records from the latest 35 days are shown; cumulative totals cannot currently be confirmed. Historical rollups contain date keys only, so they follow the selected statistics day without inferring their original timezone."
                    ))
            case .failure(let dailyError):
                local = nil
                if dailyError != error {
                    messages.append(dailyError.localizedDescription)
                }
            }
        }
        // Other CLI/manual sources are partial additions. Without a verified
        // cc-switch summary they must not manufacture complete all-source totals.
        guard local?.hasCompleteTotals == true else { return snapshot(local: local) }
        var mergedShares = local?.allAgentsShares ?? []
        let todayStart = context.statistics.calendar.startOfDay(for: context.now)
        let zcodeUsage = ZCodeUsageReader.usage(todayStart: todayStart)
        if let zcode = zcodeUsage, zcode.lifetimeTokens > 0 {
            mergedShares.append(AgentTokenShare(name: "ZCode", tokens: zcode.lifetimeTokens))
        }
        mergedShares = replacingGrokSessionShare(in: mergedShares, with: GrokUsageReader.lifetimeTokens())
        mergedShares.sort { $0.tokens > $1.tokens }
        guard let baseToday = local?.allAgentsTodayTokens,
            let zcodeToday = zcodeUsage?.todayTokens,
            let mergedLifetime = summedTokenCounts(mergedShares.map(\.tokens)),
            let mergedToday = summedTokenCounts([baseToday, zcodeToday])
        else {
            local?.coverage = .dailyOnly
            local?.allAgentsLifetimeTokens = nil
            local?.allAgentsTodayTokens = nil
            local?.allAgentsShares = []
            messages.append(
                WidgetLanguage.storedOrAutomatic().text(
                    "跨 CLI 统计包含超出范围的数量，合计暂不可用。", "Cross-CLI counts exceed the supported range; totals are unavailable."
                ))
            return snapshot(local: local)
        }
        if mergedLifetime > 0 || mergedToday > 0 {
            local!.allAgentsLifetimeTokens = mergedLifetime
            local!.allAgentsTodayTokens = mergedToday
            local!.allAgentsShares = mergedShares
        }
        return snapshot(local: local)
    }

    func loadTaskBoard(context: RuntimeLoadContext) -> TaskBoard? {
        var messages: [String] = []
        return readTaskBoard(context: context, messages: &messages)
    }

    func latestThreadActivityAt() -> Date? {
        guard
            let dbPath = firstExistingPath([
                NSHomeDirectory() + "/.codex/state_5.sqlite",
                NSHomeDirectory() + "/.codex/sqlite/state_5.sqlite",
            ]),
            let sqlitePath = firstExistingPath([
                "/usr/bin/sqlite3",
                "/opt/homebrew/bin/sqlite3",
            ])
        else { return nil }
        let rows = runSQLiteJSON(
            sqlitePath: sqlitePath,
            dbPath: dbPath,
            query: "SELECT MAX(updated_at) AS updatedAt FROM threads;"
        )
        return dateFromEpoch(rows.first?["updatedAt"])
    }

    struct AppServerSnapshot {
        enum AuxiliaryReadStatus { case legacyRPC, upstreamResetCredits, unavailable }
        // legacyRPC preserves old caller semantics; upstreamResetCredits covers only reset evidence,
        // not membership/cloud or consumable card IDs. No historical auxiliary timestamp is advanced here.
        var auxiliaryReadStatus: AuxiliaryReadStatus = .legacyRPC
        var quotaProvenance: String? = nil
        var engineFailureCode: TokenMonitorFailure? = nil
        var engineLimits: TokenMonitorResponse?
        var account: AccountInfo?
        var membershipRefreshSucceeded = false
        var limitId: String?
        var limitName: String?
        var quotaReadSucceeded = false
        var fiveHourQuota: RateWindow?
        var sevenDayQuota: RateWindow?
        var monthlyQuota: RateWindow?
        var rateLimitDiagnostics: [String] = []
        var credits: CreditsInfo?
        var cloudLifetimeTokens: Int64?

        func replacingEngineQuota(_ limits: TokenMonitorCodexLimits, response: TokenMonitorResponse) -> Self {
            func map(_ window: TokenMonitorCodexLimits.Window?) -> RateWindow? {
                window.map { RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.minutes, resetsAt: $0.resetsAt) }
            }
            var result = self
            result.engineLimits = response
            result.quotaReadSucceeded = true
            if let reset = limits.original["resetCredits"],
                let count = reset["availableCount"]?.double, count.isFinite, count >= 0,
                let integer = Int(exactly: count)
            {
                let balance = limits.original["credits"]
                result.credits = CreditsInfo(
                    hasCredits: balance?["hasCredits"] == .bool(true),
                    unlimited: balance?["unlimited"] == .bool(true), balance: balance?["balance"]?.string,
                    resetCredits: integer, resetCreditDetails: nil)
                result.auxiliaryReadStatus = .upstreamResetCredits
            } else if result.credits == nil {
                result.auxiliaryReadStatus = .unavailable
            }
            result.fiveHourQuota = map(limits.fiveHour)
            result.sevenDayQuota = map(limits.sevenDay)
            result.monthlyQuota = map(limits.monthly)
            result.limitId = limits.limitID
            result.membershipRefreshSucceeded = false
            return result
        }
    }

    /// Reads a specifically identifiable, supported reset card. This is intentionally
    /// separate from ordinary balance credits and never falls back to an unspecified card.
    func readResetCreditReview(
        context: RuntimeLoadContext,
        profile: CodexProfile,
        expectedAccountID: String,
        accountRemark: String,
        now: Date = Date()
    ) -> Result<CodexResetCreditReview, CodexResetCreditFailure> {
        switch runResetCreditRPC(
            context: context,
            profile: profile,
            expectedAccountID: expectedAccountID,
            selectedCard: nil,
            idempotencyKey: nil,
            reviewObservedAt: nil,
            clock: { now }
        ) {
        case .success(let response):
            guard let card = response.card else { return .failure(.creditAvailabilityUnavailable) }
            return .success(
                CodexResetCreditReview(
                    profileID: profile.id,
                    accountID: expectedAccountID,
                    accountRemark: accountRemark,
                    card: card,
                    observedAt: now
                ))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// The same app-server conversation first re-reads identity and the exact card,
    /// then—and only then—sends the single consume RPC.
    func consumeResetCredit(
        context: RuntimeLoadContext,
        profile: CodexProfile,
        review: CodexResetCreditReview,
        idempotencyKey: String,
        clock: @escaping () -> Date = Date.init
    ) -> Result<CodexResetCreditConsumeOutcome, CodexResetCreditFailure> {
        guard !idempotencyKey.isEmpty else { return .failure(.requestNotSent) }
        switch runResetCreditRPC(
            context: context,
            profile: profile,
            expectedAccountID: review.accountID,
            selectedCard: review.card,
            idempotencyKey: idempotencyKey,
            reviewObservedAt: review.observedAt,
            clock: clock
        ) {
        case .success(let response):
            guard let outcome = response.outcome else { return .failure(.outcomeUnknown) }
            return .success(outcome)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private struct ResetCreditRPCResponse {
        let card: CodexResetCreditCard?
        let outcome: CodexResetCreditConsumeOutcome?
    }

    private func runResetCreditRPC(
        context: RuntimeLoadContext,
        profile: CodexProfile,
        expectedAccountID: String,
        selectedCard: CodexResetCreditCard?,
        idempotencyKey: String?,
        reviewObservedAt: Date?,
        clock: @escaping () -> Date
    ) -> Result<ResetCreditRPCResponse, CodexResetCreditFailure> {
        guard resetValidField(expectedAccountID, maximumBytes: 256),
            profile.lastSnapshot?.accountID == expectedAccountID,
            profile.lastSnapshot?.quotaReadSucceeded != false
        else { return .failure(.identityUnavailable) }

        let resolvedHome = context.codexHomeDirectory.resolvingSymlinksInPath().standardizedFileURL
        let systemHome = context.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let managedRoot = context.homeDirectory
            .appendingPathComponent(".codex-account-manager-next/profiles", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let profileHome = profile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
        let validHome =
            profileHome == resolvedHome
            && (profile.isSystemProfile
                ? resolvedHome == systemHome
                : resolvedHome.deletingLastPathComponent() == managedRoot)
        guard validHome else { return .failure(.invalidProfile) }

        let homePath = resolvedHome.path
        let gate: NSRecursiveLock =
            resolvedHome == systemHome
            ? CodexCredentialAccessGate.lock
            : CodexCredentialAccessGate.homeLock(forHomePath: homePath)
        gate.lock()
        defer { gate.unlock() }

        guard let codexPath = resolveCodexExecutablePath() else { return .failure(.unsupportedCLI) }
        guard
            let versionData = try? BoundedLocalProcess.run(
                executable: URL(fileURLWithPath: codexPath),
                arguments: ["--version"],
                maximumOutputBytes: 4 * 1_024,
                timeout: 2
            ), CodexResetCreditVersion.supports(String(data: versionData, encoding: .utf8))
        else { return .failure(.unsupportedCLI) }

        // Managed accounts have a separate home and an account-scoped maintenance
        // reservation in the controller. Unrelated CLI/Desktop processes do not
        // block their reset; the shared system home retains the conservative gate.
        if selectedCard != nil, profile.isSystemProfile {
            guard
                let processData = try? BoundedLocalProcess.run(
                    executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
                    arguments: ["-x", "codex"],
                    maximumOutputBytes: 16 * 1_024,
                    timeout: 2,
                    allowedExitCodes: [0, 1]
                )
            else { return .failure(.ambiguousProcessState) }
            guard processData.isEmpty else { return .failure(.ambiguousProcessState) }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = [
            "app-server", "--disable", "apps", "--disable", "plugins",
            "--disable", "remote_plugin", "--disable", "recommended_plugins",
            "--disable", "skill_search",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homePath
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(.requestNotSent) }

        enum RPCStage {
            case awaitingInitialize
            case awaitingRateLimits
            case awaitingConsume
            case terminal
        }

        let stateLock = NSLock()
        let completed = DispatchSemaphore(value: 0)
        var stage = RPCStage.awaitingInitialize
        var acceptsWrites = true
        var terminalResult: Result<ResetCreditRPCResponse, CodexResetCreditFailure>?
        var consumeMayHaveBeenSent = false
        var buffer = Data()
        let inputHandle = input.fileHandleForWriting
        let outputHandle = output.fileHandleForReading

        func finishLocked(_ result: Result<ResetCreditRPCResponse, CodexResetCreditFailure>) {
            guard terminalResult == nil else { return }
            acceptsWrites = false
            stage = .terminal
            terminalResult = result
            completed.signal()
        }

        func finishForShutdown() {
            stateLock.lock()
            finishLocked(.failure(consumeMayHaveBeenSent ? .outcomeUnknown : .requestNotSent))
            stateLock.unlock()
        }

        /// Called only with stateLock held. The state lock is the sole ordering
        /// boundary for stage transitions, terminal completion and stdin writes.
        func writeMessageLocked(_ message: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
            guard acceptsWrites, terminalResult == nil, stage != .terminal else { return false }
            do {
                try inputHandle.write(contentsOf: data)
                try inputHandle.write(contentsOf: Data("\n".utf8))
                return true
            } catch {
                acceptsWrites = false
                return false
            }
        }

        func verifiedCard(
            from result: [String: Any],
            verificationDate: Date
        ) -> Result<CodexResetCreditCard, CodexResetCreditFailure> {
            guard let accountID = result["accountId"] as? String,
                resetValidField(accountID, maximumBytes: 256)
            else { return .failure(.identityUnavailable) }
            guard accountID == expectedAccountID else { return .failure(.identityChanged) }
            guard let summary = result["rateLimitResetCredits"] as? [String: Any],
                let availableCount = resetExactInt64(summary["availableCount"]),
                (0...1_000_000).contains(availableCount)
            else { return .failure(.creditAvailabilityUnavailable) }
            guard let rows = summary["credits"] as? [[String: Any]], rows.count <= 1_024 else {
                return .failure(.creditAvailabilityUnavailable)
            }
            var seenIDs = Set<String>()
            var cards: [CodexResetCreditCard] = []
            for row in rows {
                guard let id = row["id"] as? String,
                    resetValidField(id, maximumBytes: 512),
                    seenIDs.insert(id).inserted,
                    let resetType = row["resetType"] as? String,
                    let status = row["status"] as? String,
                    let expiry = resetExpiry(in: row)
                else { return .failure(.creditAvailabilityUnavailable) }
                guard resetType == "codexRateLimits", status == "available" else { continue }
                guard expiry == nil || expiry! > verificationDate else { continue }
                cards.append(CodexResetCreditCard(creditID: id, expiresAt: expiry))
            }
            cards.sort {
                switch ($0.expiresAt, $1.expiresAt) {
                case (let lhs?, let rhs?): return lhs == rhs ? $0.creditID < $1.creditID : lhs < rhs
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return $0.creditID < $1.creditID
                }
            }
            guard availableCount > 0 else { return .failure(.noAvailableCredit) }
            guard let selectedCard else {
                guard let first = cards.first else { return .failure(.creditAvailabilityUnavailable) }
                return .success(first)
            }
            guard let exact = cards.first(where: { $0.creditID == selectedCard.creditID }),
                exact.expiresAt == selectedCard.expiresAt
            else { return .failure(.creditChanged) }
            return .success(exact)
        }

        func parseLine(_ line: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let rawID = resetExactInt64(object["id"]),
                let id = Int(exactly: rawID)
            else { return }
            stateLock.lock()
            defer { stateLock.unlock() }
            guard terminalResult == nil else { return }
            let expectedID: Int
            switch stage {
            case .awaitingInitialize: expectedID = 1
            case .awaitingRateLimits: expectedID = 2
            case .awaitingConsume: expectedID = 3
            case .terminal: return
            }
            guard id == expectedID else { return }
            if object["error"] != nil {
                finishLocked(.failure(consumeMayHaveBeenSent ? .outcomeUnknown : .requestNotSent))
                return
            }
            if id == 1 {
                guard writeMessageLocked(["method": "initialized"]),
                    writeMessageLocked(["id": 2, "method": "account/rateLimits/read"])
                else {
                    finishLocked(.failure(.requestNotSent))
                    return
                }
                stage = .awaitingRateLimits
            } else if id == 2 {
                guard let result = object["result"] as? [String: Any] else {
                    finishLocked(.failure(.requestNotSent))
                    return
                }
                let verificationDate = clock()
                switch verifiedCard(from: result, verificationDate: verificationDate) {
                case .failure(let failure):
                    finishLocked(.failure(failure))
                case .success(let card):
                    guard let idempotencyKey, let selectedCard else {
                        finishLocked(.success(ResetCreditRPCResponse(card: card, outcome: nil)))
                        return
                    }
                    guard card.creditID == selectedCard.creditID,
                        resetValidField(idempotencyKey, maximumBytes: 128),
                        UUID(uuidString: idempotencyKey) != nil
                    else {
                        finishLocked(.failure(.creditChanged))
                        return
                    }
                    let sendDate = clock()
                    guard card.expiresAt == nil || card.expiresAt! > sendDate else {
                        finishLocked(.failure(.creditChanged))
                        return
                    }
                    if let reviewObservedAt {
                        let age = sendDate.timeIntervalSince(reviewObservedAt)
                        guard age >= 0, age <= 2 * 60 else {
                            finishLocked(.failure(.expiredChallenge))
                            return
                        }
                    }
                    stage = .awaitingConsume
                    // A throwing/partial pipe write is indistinguishable from a
                    // delivered request, so classify it as uncertain before I/O.
                    consumeMayHaveBeenSent = true
                    guard
                        writeMessageLocked([
                            "id": 3,
                            "method": "account/rateLimitResetCredit/consume",
                            "params": ["idempotencyKey": idempotencyKey, "creditId": card.creditID],
                        ])
                    else {
                        finishLocked(.failure(.outcomeUnknown))
                        return
                    }
                }
            } else if id == 3 {
                guard let result = object["result"] as? [String: Any],
                    let rawOutcome = result["outcome"] as? String,
                    let outcome = CodexResetCreditConsumeOutcome(rawValue: rawOutcome)
                else {
                    finishLocked(.failure(.outcomeUnknown))
                    return
                }
                finishLocked(.success(ResetCreditRPCResponse(card: selectedCard, outcome: outcome)))
            }
        }

        guard let descriptor = try? POSIXPipeReader.duplicateDescriptor(for: outputHandle) else {
            stateLock.lock()
            finishLocked(.failure(.requestNotSent))
            try? inputHandle.close()
            stateLock.unlock()
            terminate(process)
            return .failure(.requestNotSent)
        }
        let readFlags = fcntl(descriptor, F_GETFL)
        guard readFlags >= 0, fcntl(descriptor, F_SETFL, readFlags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            finishForShutdown()
            try? inputHandle.close()
            terminate(process)
            return .failure(.requestNotSent)
        }
        let readDeadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        let readerGroup = DispatchGroup()
        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                Darwin.close(descriptor)
                readerGroup.leave()
            }
            var totalOutputBytes = 0
            while DispatchTime.now().uptimeNanoseconds < readDeadline {
                stateLock.lock()
                let isTerminal = terminalResult != nil
                stateLock.unlock()
                if isTerminal { break }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let readiness = Darwin.poll(&pollDescriptor, 1, 100)
                if readiness == 0 { continue }
                if readiness < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let data: Data
                do {
                    guard
                        let next = try POSIXPipeReader.readChunk(
                            from: descriptor, maximumBytes: 64 * 1_024
                        )
                    else { break }
                    data = next
                } catch POSIXPipeReaderError.readFailed(let code) where code == EAGAIN || code == EWOULDBLOCK {
                    continue
                } catch {
                    break
                }
                totalOutputBytes += data.count
                guard totalOutputBytes <= 1 * 1_024 * 1_024 else {
                    finishForShutdown()
                    break
                }
                buffer.append(data)
                if buffer.count > 1 * 1_024 * 1_024 {
                    finishForShutdown()
                    break
                }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { parseLine(line) }
                }
            }
            finishForShutdown()
        }

        stateLock.lock()
        let initialized = writeMessageLocked([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-account-manager-next",
                    "title": "Codex Account Manager Next",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1",
                ],
                "capabilities": ["experimentalApi": true, "optOutNotificationMethods": []],
            ],
        ])
        if !initialized { finishLocked(.failure(.requestNotSent)) }
        stateLock.unlock()

        if initialized, completed.wait(timeout: .now() + 15) == .timedOut {
            finishForShutdown()
        }
        stateLock.lock()
        acceptsWrites = false
        try? inputHandle.close()
        stateLock.unlock()
        terminate(process)
        try? outputHandle.close()
        _ = readerGroup.wait(timeout: .now() + 1)
        stateLock.lock()
        let result = terminalResult
        let uncertain = consumeMayHaveBeenSent
        stateLock.unlock()
        return result ?? .failure(uncertain ? .outcomeUnknown : .requestNotSent)
    }

    private func readAppServer(
        context: RuntimeLoadContext,
        messages: inout [String],
        quotaOnly: Bool,
        refreshingMembershipFor profile: CodexProfile? = nil,
        requestTimeout: TimeInterval? = nil,
        cancellation: TokenMonitorCancellation? = nil
    ) -> AppServerSnapshot {
        let cancellation = cancellation ?? context.quotaCancellation
        let responseTimeout = requestTimeout.map { min(30, max(0, $0)) } ?? (quotaOnly ? 30 : 12)
        guard responseTimeout.isFinite, responseTimeout > 0 else {
            messages.append(TokenMonitorFailure.invalidRequest.rawValue)
            return AppServerSnapshot()
        }
        let responseDeadline = ProcessInfo.processInfo.systemUptime + responseTimeout
        func stopReason() -> TokenMonitorFailure? {
            if cancellation?.isCancelled == true { return .cancelled }
            if ProcessInfo.processInfo.systemUptime >= responseDeadline { return .timedOut }
            return nil
        }
        if let reason = stopReason() {
            messages.append(reason.rawValue)
            return AppServerSnapshot()
        }
        // 系统默认 home 是官方 Codex 正在使用的登录，保持原有全局门禁不变；
        // 其他账号 home 只涉及自身凭据，按 home 互斥即可允许跨账号并行读取。
        let homePath = context.codexHomeDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let systemHomePath = context.homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        if profile != nil {
            while !CodexCredentialAccessGate.lock.try() {
                if let reason = stopReason() {
                    messages.append(reason.rawValue)
                    return AppServerSnapshot()
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        defer { if profile != nil { CodexCredentialAccessGate.lock.unlock() } }
        let gate: NSRecursiveLock =
            homePath == systemHomePath
            ? CodexCredentialAccessGate.lock
            : CodexCredentialAccessGate.homeLock(forHomePath: homePath)
        while !gate.try() {
            if let reason = stopReason() {
                messages.append(reason.rawValue)
                return AppServerSnapshot()
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { gate.unlock() }
        if let reason = stopReason() {
            messages.append(reason.rawValue)
            return AppServerSnapshot()
        }
        if let profile {
            let systemHome = context.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            let managedRoot = context.homeDirectory.appendingPathComponent(".codex-account-manager-next/profiles", isDirectory: true)
            let resolvedHome = context.codexHomeDirectory.resolvingSymlinksInPath().standardizedFileURL
            guard !profile.isSystemProfile,
                profile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL == resolvedHome,
                resolvedHome.deletingLastPathComponent() == managedRoot.resolvingSymlinksInPath().standardizedFileURL,
                let systemIdentity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: systemHome),
                let identity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: resolvedHome),
                identity.accountID != systemIdentity.accountID,
                profile.matchesRecordedCredential(identity)
            else { return AppServerSnapshot() }
        }
        let performanceSpan = PerformanceMonitor.shared.begin(.appServerQuota)
        defer { PerformanceMonitor.shared.end(performanceSpan) }
        if let reason = stopReason() {
            messages.append(reason.rawValue)
            return AppServerSnapshot()
        }
        guard let codexPath = resolveCodexExecutablePath() else {
            messages.append(WidgetLanguage.storedOrAutomatic().text("未找到 codex 可执行文件", "The Codex executable was not found."))
            return AppServerSnapshot()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server"]
        if profile != nil {
            process.arguments?.append(contentsOf: ["-c", "cli_auth_credentials_store=\"file\""])
        }
        if quotaOnly {
            process.arguments?.append(contentsOf: [
                "--disable", "apps",
                "--disable", "plugins",
                "--disable", "remote_plugin",
                "--disable", "recommended_plugins",
                "--disable", "skill_search",
            ])
        }
        var environment = ProcessInfo.processInfo.environment
        if profile != nil {
            for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] {
                environment.removeValue(forKey: key)
            }
        }
        environment["CODEX_HOME"] = context.codexHomeDirectory.path
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        if let reason = stopReason() {
            messages.append(reason.rawValue)
            return AppServerSnapshot()
        }
        do {
            try process.run()
        } catch {
            messages.append(WidgetLanguage.storedOrAutomatic().text("app-server 启动失败", "Could not start app-server."))
            return AppServerSnapshot()
        }

        let writeLock = NSLock()
        let inputHandle = input.fileHandleForWriting
        var acceptsWrites = true
        func writeMessage(_ request: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
            writeLock.lock()
            defer { writeLock.unlock() }
            guard acceptsWrites else { return }
            do {
                try inputHandle.write(contentsOf: data)
                try inputHandle.write(contentsOf: Data("\n".utf8))
            } catch {
                acceptsWrites = false
            }
        }

        let requestedResponseIDs = quotaOnly ? [2, 3] : [2, 3, 4]
        let pendingResponses = AppServerPendingResponses(requestedResponseIDs)

        let lock = NSLock()
        var buffer = Data()
        var snapshot = AppServerSnapshot()
        var sentAccountRequests = false
        var appServerMessages: [String] = []

        func writeUsageRequests() {
            writeMessage(["id": 3, "method": "account/rateLimits/read"])
            if !quotaOnly { writeMessage(["id": 4, "method": "account/usage/read"]) }
        }

        func failPendingResponses(_ message: String) {
            guard pendingResponses.completeRemaining() else { return }
            lock.lock()
            appServerMessages.append(message)
            lock.unlock()
        }

        func parseLine(_ lineData: Data) {
            guard
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let id = object["id"] as? Int
            else { return }

            if id == 1 {
                if let error = object["error"] as? [String: Any] {
                    failPendingResponses(Self.appServerFailureMessage(requestID: id, error: error))
                    return
                }
                guard object["result"] is [String: Any] else {
                    failPendingResponses(
                        WidgetLanguage.storedOrAutomatic().text(
                            "app-server 1: 初始化失败",
                            "app-server 1: initialization failed."
                        ))
                    return
                }
                lock.lock()
                let shouldSend = !sentAccountRequests
                sentAccountRequests = true
                lock.unlock()

                if shouldSend {
                    writeMessage(["method": "initialized"])
                    writeMessage(["id": 2, "method": "account/read", "params": ["refreshToken": profile != nil]])
                    if profile == nil { writeUsageRequests() }
                }
                return
            }

            guard requestedResponseIDs.contains(id) else { return }

            // A proactive refresh must finish before the quota request uses its credentials.
            if id == 2, profile != nil { writeUsageRequests() }

            if let error = object["error"] as? [String: Any] {
                lock.lock()
                appServerMessages.append(Self.appServerFailureMessage(requestID: id, error: error))
                lock.unlock()
                pendingResponses.complete(id)
                return
            }

            guard let result = object["result"] as? [String: Any] else {
                lock.lock()
                appServerMessages.append(
                    WidgetLanguage.storedOrAutomatic().text(
                        "app-server \(id): 响应无效",
                        "app-server \(id): invalid response."
                    ))
                lock.unlock()
                pendingResponses.complete(id)
                return
            }

            lock.lock()
            switch id {
            case 2:
                snapshot.account = parseAccount(result)
                snapshot.membershipRefreshSucceeded = profile?.matchesRecordedAccount(email: snapshot.account?.email) == true
            case 3:
                parseRateLimits(result, into: &snapshot)
            case 4:
                snapshot.cloudLifetimeTokens = parseCloudLifetimeTokens(result)
            default:
                break
            }
            lock.unlock()

            pendingResponses.complete(id)
        }

        let outputHandle = output.fileHandleForReading
        guard let outputDescriptor = try? POSIXPipeReader.duplicateDescriptor(for: outputHandle) else {
            writeLock.lock()
            acceptsWrites = false
            try? inputHandle.close()
            writeLock.unlock()
            terminate(process)
            try? outputHandle.close()
            messages.append(WidgetLanguage.storedOrAutomatic().text("app-server 输出读取失败", "Could not read app-server output."))
            return AppServerSnapshot()
        }
        let readerGroup = DispatchGroup()
        let maximumOutputBufferBytes = 1 * 1_024 * 1_024
        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                failPendingResponses(
                    WidgetLanguage.storedOrAutomatic().text(
                        "app-server 在完成响应前已退出",
                        "app-server exited before completing its responses."
                    ))
                Darwin.close(outputDescriptor)
                readerGroup.leave()
            }
            while true {
                let data: Data
                do {
                    guard
                        let next = try POSIXPipeReader.readChunk(
                            from: outputDescriptor,
                            maximumBytes: 64 * 1_024
                        )
                    else { break }
                    data = next
                } catch {
                    break
                }

                buffer.append(data)
                if buffer.count > maximumOutputBufferBytes {
                    failPendingResponses(
                        WidgetLanguage.storedOrAutomatic().text(
                            "app-server 输出超过安全上限",
                            "app-server output exceeded the safety limit."
                        ))
                    break
                }

                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty {
                        parseLine(line)
                    }
                }
            }
        }

        writeMessage([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-account-manager-next",
                    "title": "Codex Account Manager Next",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1",
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "optOutNotificationMethods": [],
                ],
            ],
        ])

        var responseCompleted = false
        while cancellation?.isCancelled != true {
            let remaining = responseDeadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            if pendingResponses.group.wait(timeout: .now() + min(0.05, remaining)) == .success {
                responseCompleted = true
                break
            }
        }
        if !responseCompleted {
            let pendingMessage: String
            if cancellation?.isCancelled == true {
                pendingMessage = TokenMonitorFailure.cancelled.rawValue
            } else {
                pendingMessage = WidgetLanguage.storedOrAutomatic().text(
                    "app-server 响应超时",
                    "app-server response timed out."
                )
            }
            failPendingResponses(pendingMessage)
        }

        writeLock.lock()
        acceptsWrites = false
        try? inputHandle.close()
        writeLock.unlock()
        if process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
        try? outputHandle.close()
        let cleanupWait = max(0, min(1, responseDeadline - ProcessInfo.processInfo.systemUptime))
        _ = readerGroup.wait(timeout: .now() + cleanupWait)

        lock.lock()
        let finalSnapshot = snapshot
        let finalAppServerMessages = appServerMessages
        lock.unlock()

        if cancellation?.isCancelled == true {
            messages.append(TokenMonitorFailure.cancelled.rawValue)
            return AppServerSnapshot()
        }
        messages.append(contentsOf: finalAppServerMessages)
        messages.append(contentsOf: finalSnapshot.rateLimitDiagnostics)

        return finalSnapshot
    }

    static func appServerFailureMessage(requestID: Int, error: [String: Any]) -> String {
        // Classify in memory; never retain the server message, which may contain credentials or identifiers.
        if let reason = AppServerFailureClassifier.failureReason(from: error) {
            return "app-server \(requestID): \(reason)"
        }
        return WidgetLanguage.storedOrAutomatic().text("app-server \(requestID): 请求失败", "app-server \(requestID): request failed.")
    }

    private func parseAccount(_ result: [String: Any]) -> AccountInfo? {
        guard let account = result["account"] as? [String: Any],
            let type = account["type"] as? String
        else { return nil }

        return AccountInfo(
            type: type,
            planType: account["planType"] as? String,
            emailPresent: account["email"] != nil && !(account["email"] is NSNull),
            email: account["email"] as? String
        )
    }

    private func parseRateLimits(_ result: [String: Any], into snapshot: inout AppServerSnapshot) {
        let selected: [String: Any]?
        if let byId = result["rateLimitsByLimitId"] as? [String: Any],
            let codex = byId["codex"] as? [String: Any]
        {
            selected = codex
        } else {
            selected = result["rateLimits"] as? [String: Any]
        }

        guard let limits = selected else { return }
        snapshot.limitId = limits["limitId"] as? String
        snapshot.limitName = limits["limitName"] as? String
        let rawWindows = [limits["primary"], limits["secondary"]]
        let parsedWindows = rawWindows.map(parseRateWindow)
        let normalized = CodexRateLimitNormalizer.normalize(parsedWindows)
        let hasWindowFields = limits.keys.contains("primary") || limits.keys.contains("secondary")
        let hasMalformedWindow = zip(rawWindows, parsedWindows).contains { raw, parsed in
            guard let raw, !(raw is NSNull) else { return false }
            return parsed == nil
        }
        let quotaReadSucceeded = CodexRateLimitNormalizer.isAuthoritative(
            hasWindowFields: hasWindowFields,
            hasMalformedWindow: hasMalformedWindow,
            normalized: normalized
        )
        snapshot.quotaReadSucceeded = quotaReadSucceeded
        // Quota topology is committed atomically. A partly understood payload must
        // never make a confirmed dual-window layout collapse into a misleading
        // single-window layout; continuity will keep the last confirmed topology.
        snapshot.fiveHourQuota = quotaReadSucceeded ? normalized.fiveHour : nil
        snapshot.sevenDayQuota = quotaReadSucceeded ? normalized.sevenDay : nil
        snapshot.monthlyQuota = quotaReadSucceeded ? normalized.monthly : nil
        var diagnostics = rateLimitDiagnostics(for: normalized)
        if !hasWindowFields {
            diagnostics.append(
                WidgetLanguage.storedOrAutomatic().text("Codex 额度响应缺少窗口字段，未将其视为当前无限制", "The Codex limit response is missing window fields. It is not treated as unlimited."))
        }
        if hasMalformedWindow {
            diagnostics.append(
                WidgetLanguage.storedOrAutomatic().text("Codex 额度窗口格式无法解析，未将其视为当前无限制", "Codex limit windows could not be parsed. They are not treated as unlimited."))
        }
        snapshot.rateLimitDiagnostics = diagnostics

        var resetCredits: Int?
        var resetCreditDetails: [ResetCreditDetail]?
        if let reset = result["rateLimitResetCredits"] as? [String: Any] {
            if let count64 = resetExactInt64(reset["availableCount"]),
                (0...1_000_000).contains(count64),
                let count = Int(exactly: count64)
            {
                var detailsAreValid = true
                var parsedDetails: [ResetCreditDetail]?
                if let raw = reset["credits"], !(raw is NSNull) {
                    if let rows = raw as? [[String: Any]], rows.count <= 1_024 {
                        var seenIDs = Set<String>()
                        var available: [ResetCreditDetail] = []
                        for row in rows {
                            guard let id = row["id"] as? String,
                                resetValidField(id, maximumBytes: 512),
                                seenIDs.insert(id).inserted,
                                let status = row["status"] as? String,
                                let resetType = row["resetType"] as? String,
                                let expiry = resetExpiry(in: row)
                            else {
                                detailsAreValid = false
                                break
                            }
                            if status == "available", resetType == "codexRateLimits" {
                                available.append(ResetCreditDetail(id: id, expiresAt: expiry))
                            }
                        }
                        parsedDetails = available.sorted { lhs, rhs in
                            switch (lhs.expiresAt, rhs.expiresAt) {
                            case (let left?, let right?):
                                return left == right ? lhs.id < rhs.id : left < right
                            case (.some, .none):
                                return true
                            case (.none, .some):
                                return false
                            case (.none, .none):
                                return lhs.id < rhs.id
                            }
                        }
                    } else {
                        detailsAreValid = false
                    }
                }
                if detailsAreValid {
                    resetCredits = CodexResetCreditNormalizer.normalizeAvailableCount(count)
                    resetCreditDetails = parsedDetails
                }
            }
        }

        if let credits = limits["credits"] as? [String: Any] {
            snapshot.credits = CreditsInfo(
                hasCredits: credits["hasCredits"] as? Bool ?? false,
                unlimited: credits["unlimited"] as? Bool ?? false,
                balance: stringValue(credits["balance"]),
                resetCredits: resetCredits,
                resetCreditDetails: resetCreditDetails
            )
        } else if resetCredits != nil {
            snapshot.credits = CreditsInfo(
                hasCredits: false,
                unlimited: false,
                balance: nil,
                resetCredits: resetCredits,
                resetCreditDetails: resetCreditDetails
            )
        }
    }

    private func parseRateWindow(_ value: Any?) -> RateWindow? {
        guard let object = value as? [String: Any],
            let used = doubleValue(object["usedPercent"])
        else { return nil }

        let resetDate: Date?
        if let timestamp = doubleValue(object["resetsAt"]) {
            resetDate = Date(timeIntervalSince1970: timestamp)
        } else {
            resetDate = nil
        }

        return RateWindow(
            usedPercent: used,
            windowDurationMins: intValue(object["windowDurationMins"]),
            resetsAt: resetDate
        )
    }

    private func rateLimitDiagnostics(for windows: CodexNormalizedRateWindows) -> [String] {
        var messages: [String] = []

        if windows.fiveHourMatchCount > 1 {
            messages.append(WidgetLanguage.storedOrAutomatic().text("Codex 返回了重复的 5 小时额度窗口，已停止显示该窗口", "Codex returned duplicate 5-hour windows. That window is hidden."))
        }
        if windows.sevenDayMatchCount > 1 {
            messages.append(WidgetLanguage.storedOrAutomatic().text("Codex 返回了重复的 7 天额度窗口，已停止显示该窗口", "Codex returned duplicate 7-day windows. That window is hidden."))
        }
        if windows.monthlyMatchCount > 1 {
            messages.append(WidgetLanguage.storedOrAutomatic().text("Codex 返回了重复的月额度窗口，已停止显示该窗口", "Codex returned duplicate monthly windows. That window is hidden."))
        }
        let missingDurationCount = windows.unclassified.filter {
            $0.windowDurationMins == nil
        }.count
        if missingDurationCount > 0 {
            messages.append(
                WidgetLanguage.storedOrAutomatic().text(
                    "Codex 返回了缺少时长的额度窗口，未将其标注为 5 小时、7 天或月额度", "A Codex limit window has no duration. It is not labeled as 5-hour, 7-day or monthly."))
        }

        let unknownDurations = Set(windows.unclassified.compactMap(\.windowDurationMins)).sorted()
        if !unknownDurations.isEmpty {
            let values = unknownDurations.map(String.init).joined(separator: "、")
            messages.append(
                WidgetLanguage.storedOrAutomatic().text(
                    "Codex 返回了未识别的额度窗口（\(values) 分钟），未将其标注为 5 小时、7 天或月额度",
                    "Codex returned an unrecognized window (\(values) minutes). It is not labeled as 5-hour, 7-day or monthly."))
        }

        return messages
    }

    private func parseCloudLifetimeTokens(_ result: [String: Any]) -> Int64? {
        guard let summary = result["summary"] as? [String: Any] else { return nil }
        return int64Value(summary["lifetimeTokens"])
    }

    private func readLocalUsage(context: RuntimeLoadContext, messages: inout [String]) -> LocalUsage? {
        guard
            let dbPath = firstExistingPath([
                NSHomeDirectory() + "/.codex/state_5.sqlite",
                NSHomeDirectory() + "/.codex/sqlite/state_5.sqlite",
            ])
        else {
            messages.append(WidgetLanguage.storedOrAutomatic().text("未找到 Codex state_5.sqlite", "The Codex history database was not found."))
            return nil
        }

        guard
            let sqlitePath = firstExistingPath([
                "/usr/bin/sqlite3",
                "/opt/homebrew/bin/sqlite3",
                "/opt/homebrew/share/android-commandlinetools/platform-tools/sqlite3",
            ])
        else {
            messages.append(WidgetLanguage.storedOrAutomatic().text("未找到 sqlite3", "sqlite3 was not found."))
            return nil
        }

        let calendar = context.statistics.calendar
        let now = context.now
        let dayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let labelFormatter = DateFormatter()
        labelFormatter.calendar = calendar
        labelFormatter.locale = Locale(identifier: "zh_CN")
        labelFormatter.dateFormat = "M/d"

        let usageQuery = """
            SELECT id, tokens_used AS tokens, updated_at AS updatedAt
            FROM threads;
            """

        let recentQuery = """
            SELECT id, title, tokens_used AS tokens, updated_at AS updatedAt, model, cwd, archived
            FROM threads
            ORDER BY updated_at DESC
            LIMIT 5;
            """

        guard
            let usageObjects = Optional(runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: usageQuery)),
            let recentObjects = Optional(runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: recentQuery))
        else {
            messages.append(WidgetLanguage.storedOrAutomatic().text("SQLite 查询失败", "The SQLite query failed."))
            return nil
        }

        let rawAnalytics = readLocalAnalytics(
            sqlitePath: sqlitePath,
            dbPath: dbPath,
            dayStart: dayStart,
            sevenDayStart: sevenDayStart,
            statistics: context.statistics,
            messages: &messages
        )
        let forkBaselines = rawAnalytics.forkBaselineTokensByThreadId
        func adjustedTokens(_ object: [String: Any]) -> Int64 {
            let rawTokens = int64Value(object["tokens"]) ?? 0
            guard let threadId = object["id"] as? String else { return rawTokens }
            return max(rawTokens - (forkBaselines[threadId] ?? 0), 0)
        }

        let recent = recentObjects.map { object in
            LocalThread(
                id: object["id"] as? String ?? UUID().uuidString,
                title: object["title"] as? String ?? "Untitled",
                tokens: adjustedTokens(object),
                updatedAt: dateFromEpoch(object["updatedAt"]),
                model: object["model"] as? String,
                cwd: object["cwd"] as? String ?? "",
                archived: (intValue(object["archived"]) ?? 0) != 0
            )
        }

        var tokensByDay: [String: Int64] = [:]
        var lifetimeTokens: Int64 = 0
        var todayTokens: Int64 = 0
        var sevenDayTokens: Int64 = 0
        var lastUpdatedAt: Date?
        for object in usageObjects {
            guard let updatedAt = dateFromEpoch(object["updatedAt"]) else { continue }
            let tokens = adjustedTokens(object)
            lifetimeTokens += tokens
            if updatedAt >= sevenDayStart {
                sevenDayTokens += tokens
            }
            if updatedAt >= dayStart {
                todayTokens += tokens
            }
            if lastUpdatedAt == nil || updatedAt > (lastUpdatedAt ?? .distantPast) {
                lastUpdatedAt = updatedAt
            }
            let key = context.statistics.dayKey(for: updatedAt)
            tokensByDay[key, default: 0] += tokens
        }

        let dailyBuckets = (0..<7).compactMap { index -> DailyTokenBucket? in
            guard let date = calendar.date(byAdding: .day, value: index - 6, to: dayStart) else { return nil }
            let key = dayFormatter.string(from: date)
            return DailyTokenBucket(
                id: key,
                label: index == 6 ? WidgetLanguage.storedOrAutomatic().text("今天", "Today") : labelFormatter.string(from: date),
                tokens: tokensByDay[key] ?? 0
            )
        }

        let analytics = validatedLocalAnalytics(
            rawAnalytics,
            approximateTodayTokens: todayTokens,
            approximateSevenDayTokens: sevenDayTokens,
            messages: &messages
        )
        let allProjects = readAllTimeProjects(
            sqlitePath: sqlitePath,
            dbPath: dbPath,
            forkBaselines: forkBaselines
        )
        let projectBoard = ProjectBoard(
            recentProjects: analytics.recentProjects.isEmpty
                ? readApproximateRecentProjects(
                    sqlitePath: sqlitePath,
                    dbPath: dbPath,
                    sevenDayStart: sevenDayStart,
                    forkBaselines: forkBaselines
                )
                : analytics.recentProjects,
            allProjects: allProjects
        )

        return LocalUsage(
            lifetimeTokens: lifetimeTokens,
            todayTokens: todayTokens,
            sevenDayTokens: sevenDayTokens,
            threadCount: usageObjects.count,
            lastUpdatedAt: lastUpdatedAt,
            dailyBuckets: dailyBuckets,
            recentThreads: recent,
            detailedUsage: analytics.detailedUsage,
            usageTrend: analytics.usageTrend
                ?? readApproximateUsageTrend(
                    sqlitePath: sqlitePath,
                    dbPath: dbPath,
                    dayStart: dayStart,
                    sevenDayStart: sevenDayStart,
                    calendar: calendar,
                    forkBaselines: forkBaselines
                ),
            inferencePerformance: analytics.inferencePerformance,
            projectBoard: projectBoard,
            toolUsages: analytics.toolUsages,
            skillUsages: analytics.skillUsages
        )
    }

    private func validatedLocalAnalytics(
        _ analytics: LocalAnalytics,
        approximateTodayTokens: Int64,
        approximateSevenDayTokens: Int64,
        messages: inout [String]
    ) -> LocalAnalytics {
        guard let detailed = analytics.detailedUsage else { return analytics }

        let suspiciousToday = CodexDetailedUsageSanity.isSuspicious(
            detailed.today.tokens.visibleTotalTokens,
            comparedWith: approximateTodayTokens
        )
        let suspiciousSevenDay = CodexDetailedUsageSanity.isSuspicious(
            detailed.sevenDay.tokens.visibleTotalTokens,
            comparedWith: approximateSevenDayTokens
        )
        guard suspiciousToday || suspiciousSevenDay else { return analytics }

        messages.append(
            WidgetLanguage.storedOrAutomatic().text(
                "Codex token_count 精细统计与本机线程统计差异异常，已回退到线程口径", "Detailed token counts differ unexpectedly from local thread totals. Thread totals are used instead."))
        return LocalAnalytics(
            detailedUsage: nil,
            usageTrend: nil,
            inferencePerformance: analytics.inferencePerformance,
            recentProjects: [],
            toolUsages: analytics.toolUsages.map { usage in
                ToolUsage(
                    id: usage.id,
                    name: usage.name,
                    category: usage.category,
                    callCount: usage.callCount,
                    estimatedTokens: nil,
                    estimatedCostUSD: nil
                )
            },
            skillUsages: analytics.skillUsages,
            forkBaselineTokensByThreadId: analytics.forkBaselineTokensByThreadId
        )
    }

    private func readLocalAnalytics(
        sqlitePath: String,
        dbPath: String,
        dayStart: Date,
        sevenDayStart: Date,
        statistics: StatisticsContext,
        messages: inout [String]
    ) -> LocalAnalytics {
        Self.localAnalyticsLock.lock()
        defer { Self.localAnalyticsLock.unlock() }

        let calendar = statistics.calendar
        let trendStart = calendar.date(byAdding: .day, value: -190, to: dayStart) ?? sevenDayStart
        let inferenceHistoryStart = calendar.date(byAdding: .day, value: -27, to: dayStart) ?? dayStart
        let inferenceRetentionStart =
            calendar.date(byAdding: .day, value: -34, to: dayStart)
            ?? inferenceHistoryStart
        var inferenceArchive = ModelInferenceHistoryStore.load(fileManager: fileManager, now: dayStart)
        let loadedInferenceArchive = inferenceArchive
        inferenceArchive.compact(
            retainingSince: inferenceRetentionStart,
            maximumSampleCount: ModelInferenceHistoryStore.maximumSampleCount
        )
        if inferenceArchive != loadedInferenceArchive,
            !ModelInferenceHistoryStore.save(inferenceArchive, fileManager: fileManager)
        {
            messages.append(WidgetLanguage.storedOrAutomatic().text("推理表现历史清理后暂时无法写入本机", "Inference history could not be saved after cleanup."))
        }
        let inferenceArchiveBeforeCollection = inferenceArchive

        func makeInferenceHistory() -> ModelInferencePerformanceHistory? {
            ModelInferencePerformanceBuilder.makeHistory(
                samples: inferenceArchive.samples,
                recordingStartedAt: inferenceArchive.recordingStartedAt,
                dayStart: dayStart,
                calendar: calendar
            )
        }

        func shouldCollectInference(for source: SessionUsageSource) -> Bool {
            source.updatedAt.map { $0 >= inferenceHistoryStart } ?? true
        }
        let sourceQuery = """
            SELECT id, rollout_path AS rolloutPath, model, cwd, updated_at AS updatedAt
            FROM threads
            WHERE rollout_path IS NOT NULL
              AND rollout_path <> ''
              AND tokens_used > 0
            ORDER BY updated_at ASC;
            """

        var seenPaths = Set<String>()
        let sources = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: sourceQuery).compactMap { object -> SessionUsageSource? in
            guard let path = object["rolloutPath"] as? String, !path.isEmpty, seenPaths.insert(path).inserted else {
                return nil
            }
            return SessionUsageSource(
                threadId: ModelInferenceHistoryStore.sourceIdentifier(
                    threadID: object["id"] as? String,
                    rolloutPath: path
                ),
                rolloutPath: path,
                model: object["model"] as? String,
                cwd: object["cwd"] as? String ?? "",
                updatedAt: dateFromEpoch(object["updatedAt"])
            )
        }

        guard !sources.isEmpty else {
            messages.append(WidgetLanguage.storedOrAutomatic().text("未找到 Codex session 日志", "Codex session logs were not found."))
            return LocalAnalytics(
                detailedUsage: nil,
                usageTrend: nil,
                inferencePerformance: makeInferenceHistory(),
                recentProjects: [],
                toolUsages: [],
                skillUsages: [],
                forkBaselineTokensByThreadId: [:]
            )
        }

        let dayKey = statistics.dayKey(for: dayStart)
        let sourceFingerprint = sessionSourcesFingerprint(sources)

        if let cached = Self.localAnalyticsCache,
            cached.version == localAnalyticsCacheVersion,
            cached.dayKey == dayKey,
            cached.timeZoneIdentifier == statistics.resolvedIdentifier,
            cached.sourceFingerprint == sourceFingerprint
        {
            writePersistentSessionUsageCache()
            return cached.analytics
        }

        let persistentAnalyticsCache = readPersistentLocalAnalyticsCache()
        if let cached = persistentAnalyticsCache,
            cached.version == localAnalyticsCacheVersion,
            cached.dayKey == dayKey,
            cached.timeZoneIdentifier == statistics.resolvedIdentifier,
            cached.sourceFingerprint == sourceFingerprint
        {
            Self.localAnalyticsCache = cached
            writePersistentSessionUsageCache()
            return cached.analytics
        }

        defer { releaseSessionUsageWorkingSet() }

        var reusableSkillStaticInfo: [String: SkillStaticInfo] = [:]
        for skill in persistentAnalyticsCache?.analytics.skillUsages ?? [] {
            reusableSkillStaticInfo[skill.path] = SkillStaticInfo(
                tokenEstimate: skill.staticTokenEstimate,
                byteCount: skill.staticByteCount
            )
        }
        for skill in Self.localAnalyticsCache?.analytics.skillUsages ?? [] {
            reusableSkillStaticInfo[skill.path] = SkillStaticInfo(
                tokenEstimate: skill.staticTokenEstimate,
                byteCount: skill.staticByteCount
            )
        }

        var monthComponents = calendar.dateComponents([.year, .month], from: dayStart)
        monthComponents.day = 1
        monthComponents.hour = 0
        monthComponents.minute = 0
        monthComponents.second = 0
        let monthStart = calendar.date(from: monthComponents) ?? dayStart

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        var accumulator = DetailedUsageAccumulator()
        var dailyUsage: [String: PricedTokenUsage] = [:]
        var dailyUsageByModel: [String: [String: PricedTokenUsage]] = [:]
        var modelNamesByID: [String: String] = [:]
        var recentProjectUsage: [String: ProjectUsageAccumulator] = [:]
        var toolUsage: [String: ToolUsageAccumulator] = [:]
        var skillUsage: [String: SkillUsageAccumulator] = [:]

        let sourceByThreadId = Dictionary(
            uniqueKeysWithValues: sources.map { ($0.threadId, $0) }
        )
        var inheritedPrefixLengthByThreadId: [String: Int] = [:]
        var inheritedInferencePrefixLengthByThreadId: [String: Int] = [:]
        var forkBaselineTokensByThreadId: [String: Int64] = [:]

        for source in sources {
            let collectSourceInference = shouldCollectInference(for: source)
            guard
                let entry = cachedSessionUsage(
                    source: source,
                    inferenceStart: collectSourceInference ? inferenceHistoryStart : nil,
                    fractionalFormatter: fractionalFormatter,
                    plainFormatter: plainFormatter
                ),
                let parentId = entry.forkedFromId,
                let parentSource = sourceByThreadId[parentId],
                let parentEntry = cachedSessionUsage(
                    source: parentSource,
                    inferenceStart: (collectSourceInference || shouldCollectInference(for: parentSource))
                        ? inferenceHistoryStart
                        : nil,
                    fractionalFormatter: fractionalFormatter,
                    plainFormatter: plainFormatter
                )
            else { continue }

            let inheritedPrefixLength = CodexForkUsageDeduplicator.inheritedPrefixLength(
                child: entry.deltas.map(\.eventIdentity),
                parent: parentEntry.deltas.map(\.eventIdentity)
            )
            if inheritedPrefixLength > 0 {
                inheritedPrefixLengthByThreadId[source.threadId] = inheritedPrefixLength
                forkBaselineTokensByThreadId[source.threadId] = entry.deltas
                    .prefix(inheritedPrefixLength)
                    .reduce(0) { $0 + $1.tokens.totalTokens }
            }
            let inheritedInferencePrefixLength = CodexForkUsageDeduplicator.inheritedPrefixLength(
                child: entry.resolvedInferenceSamples.map(\.eventIdentity),
                parent: parentEntry.resolvedInferenceSamples.map(\.eventIdentity)
            )
            if inheritedInferencePrefixLength > 0 {
                inheritedInferencePrefixLengthByThreadId[source.threadId] = inheritedInferencePrefixLength
            }
        }

        for source in sources {
            let collectInference = shouldCollectInference(for: source)
            guard
                let entry = cachedSessionUsage(
                    source: source,
                    inferenceStart: collectInference ? inferenceHistoryStart : nil,
                    fractionalFormatter: fractionalFormatter,
                    plainFormatter: plainFormatter
                )
            else { continue }
            let inheritedPrefixLength = inheritedPrefixLengthByThreadId[source.threadId] ?? 0
            let effectiveDeltas = entry.deltas.dropFirst(inheritedPrefixLength)
            let inheritedInferencePrefixLength = inheritedInferencePrefixLengthByThreadId[source.threadId] ?? 0
            if collectInference {
                inferenceArchive.replaceSamples(
                    for: source.threadId,
                    with: Array(entry.resolvedInferenceSamples.dropFirst(inheritedInferencePrefixLength)),
                    retainingSince: inferenceRetentionStart
                )
            }

            if entry.hasTokenEvents {
                accumulator.parsedFileCount += 1
                accumulator.tokenEventCount += max(entry.tokenEventCount - inheritedPrefixLength, 0)
            }

            var sessionUsage = PricedTokenUsage.zero
            for delta in effectiveDeltas {
                let model = resolvedModelUsageName(turnContextModel: delta.model, threadModel: source.model)
                let price = modelTokenPrice(for: model)
                let cost = estimatedCostUSD(tokens: delta.tokens, price: price, serviceTier: delta.serviceTier)
                sessionUsage.add(
                    tokens: delta.tokens,
                    costUSD: cost,
                    usesReferencePricing: price.usesReferencePricing
                )
                accumulator.add(
                    delta.tokens,
                    at: delta.date,
                    price: price,
                    serviceTier: delta.serviceTier,
                    dayStart: dayStart,
                    sevenDayStart: sevenDayStart,
                    monthStart: monthStart
                )

                if delta.date >= trendStart {
                    let key = statistics.dayKey(for: delta.date)
                    var usage = dailyUsage[key] ?? .zero
                    usage.add(
                        tokens: delta.tokens,
                        costUSD: cost,
                        usesReferencePricing: price.usesReferencePricing
                    )
                    dailyUsage[key] = usage

                    let modelID = modelUsageIdentifier(for: model)
                    var modelUsage = dailyUsageByModel[modelID] ?? [:]
                    var modelDayUsage = modelUsage[key] ?? .zero
                    modelDayUsage.add(
                        tokens: delta.tokens,
                        costUSD: cost,
                        usesReferencePricing: price.usesReferencePricing
                    )
                    modelUsage[key] = modelDayUsage
                    dailyUsageByModel[modelID] = modelUsage
                    if let model {
                        modelNamesByID[modelID] = model
                    }
                }

                if delta.date >= sevenDayStart {
                    let projectKey = source.cwd.isEmpty ? "未归类" : source.cwd
                    let projectName = source.cwd.isEmpty ? WidgetLanguage.storedOrAutomatic().text("未归类", "Uncategorized") : shortWorkspaceName(source.cwd)
                    var project =
                        recentProjectUsage[projectKey]
                        ?? ProjectUsageAccumulator(
                            name: projectName,
                            fullPath: source.cwd
                        )
                    project.add(threadId: source.threadId, tokens: delta.tokens, costUSD: cost, at: delta.date)
                    recentProjectUsage[projectKey] = project
                }
            }

            let totalToolCalls = entry.toolCalls.values.reduce(0, +)
            if totalToolCalls > 0, sessionUsage.tokens.visibleTotalTokens > 0 {
                for (name, count) in entry.toolCalls {
                    let share = Double(count) / Double(totalToolCalls)
                    let estimatedTokens = Int64((Double(sessionUsage.tokens.visibleTotalTokens) * share).rounded())
                    let estimatedCost = sessionUsage.estimatedCostUSD * share
                    var usage = toolUsage[name] ?? ToolUsageAccumulator(name: name)
                    usage.addCalls(count, estimatedTokens: estimatedTokens, estimatedCostUSD: estimatedCost)
                    toolUsage[name] = usage
                }
            } else {
                for (name, count) in entry.toolCalls {
                    var usage = toolUsage[name] ?? ToolUsageAccumulator(name: name)
                    usage.addCalls(count, estimatedTokens: 0, estimatedCostUSD: 0)
                    toolUsage[name] = usage
                }
            }

            for event in entry.skillLoads {
                var usage = skillUsage[event.path] ?? SkillUsageAccumulator(path: event.path)
                usage.addLoad(threadId: source.threadId, at: event.date ?? source.updatedAt)
                skillUsage[event.path] = usage
            }
        }

        inferenceArchive.compact(
            retainingSince: inferenceRetentionStart,
            maximumSampleCount: ModelInferenceHistoryStore.maximumSampleCount
        )
        if inferenceArchive != inferenceArchiveBeforeCollection,
            !ModelInferenceHistoryStore.save(inferenceArchive, fileManager: fileManager)
        {
            messages.append(WidgetLanguage.storedOrAutomatic().text("推理表现历史暂时无法写入本机", "Inference history could not be saved locally."))
        }

        writePersistentSessionUsageCache()
        let skillUsages = makeSkillUsages(
            from: skillUsage,
            reusableStaticInfo: reusableSkillStaticInfo
        )

        guard accumulator.parsedFileCount > 0, accumulator.tokenEventCount > 0 else {
            messages.append(WidgetLanguage.storedOrAutomatic().text("未找到 Codex token_count 事件", "No Codex token_count events were found."))
            let analytics = LocalAnalytics(
                detailedUsage: nil,
                usageTrend: nil,
                inferencePerformance: makeInferenceHistory(),
                recentProjects: [],
                toolUsages: toolUsage.values
                    .map { $0.makeUsage() }
                    .sorted { $0.callCount == $1.callCount ? $0.name < $1.name : $0.callCount > $1.callCount },
                skillUsages: skillUsages,
                forkBaselineTokensByThreadId: forkBaselineTokensByThreadId
            )
            Self.localAnalyticsCache = LocalAnalyticsCacheEntry(
                version: localAnalyticsCacheVersion,
                dayKey: dayKey,
                timeZoneIdentifier: statistics.resolvedIdentifier,
                sourceFingerprint: sourceFingerprint,
                analytics: analytics
            )
            writePersistentLocalAnalyticsCache(Self.localAnalyticsCache)
            return analytics
        }

        let analytics = LocalAnalytics(
            detailedUsage: accumulator.makeUsage(),
            usageTrend: makeUsageTrend(
                dailyUsage: dailyUsage,
                dayStart: dayStart,
                sevenDayStart: sevenDayStart,
                trendStart: trendStart,
                monthStart: monthStart,
                sourceQuality: .detailed,
                modelDailyUsage: dailyUsageByModel,
                modelNamesByID: modelNamesByID
            ),
            inferencePerformance: makeInferenceHistory(),
            recentProjects: recentProjectUsage.values
                .map { $0.makeUsage() }
                .filter { $0.tokens > 0 }
                .sorted { $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens },
            toolUsages: toolUsage.values
                .map { $0.makeUsage() }
                .sorted { $0.callCount == $1.callCount ? $0.name < $1.name : $0.callCount > $1.callCount },
            skillUsages: skillUsages,
            forkBaselineTokensByThreadId: forkBaselineTokensByThreadId
        )
        Self.localAnalyticsCache = LocalAnalyticsCacheEntry(
            version: localAnalyticsCacheVersion,
            dayKey: dayKey,
            timeZoneIdentifier: statistics.resolvedIdentifier,
            sourceFingerprint: sourceFingerprint,
            analytics: analytics
        )
        writePersistentLocalAnalyticsCache(Self.localAnalyticsCache)
        return analytics
    }

    private func makeUsageTrend(
        dailyUsage: [String: PricedTokenUsage],
        dayStart: Date,
        sevenDayStart: Date,
        trendStart: Date,
        monthStart: Date,
        sourceQuality: UsageSourceQuality,
        modelDailyUsage: [String: [String: PricedTokenUsage]] = [:],
        modelNamesByID: [String: String] = [:]
    ) -> UsageTrend {
        let calendar = Calendar.current
        var buckets: [UsageDayBucket] = []
        var cursor = calendar.startOfDay(for: trendStart)
        let end = calendar.startOfDay(for: dayStart)

        while cursor <= end {
            let key = localDayKey(cursor, calendar: calendar)
            buckets.append(
                UsageDayBucket(
                    id: key,
                    date: cursor,
                    usage: dailyUsage[key] ?? .zero,
                    sourceQuality: sourceQuality
                ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var sevenDay = PricedTokenUsage.zero
        var previousSevenDayTokens: Int64 = 0
        var month = PricedTokenUsage.zero
        let previousSevenDayStart = calendar.date(byAdding: .day, value: -7, to: sevenDayStart) ?? sevenDayStart

        for bucket in buckets {
            if bucket.date >= sevenDayStart {
                sevenDay.add(
                    tokens: bucket.usage.tokens,
                    costUSD: bucket.usage.estimatedCostUSD,
                    usesReferencePricing: bucket.usage.usesReferencePricing
                )
            } else if bucket.date >= previousSevenDayStart {
                previousSevenDayTokens += bucket.tokens
            }

            if bucket.date >= monthStart {
                month.add(
                    tokens: bucket.usage.tokens,
                    costUSD: bucket.usage.estimatedCostUSD,
                    usesReferencePricing: bucket.usage.usesReferencePricing
                )
            }
        }

        let peakDay =
            buckets
            .filter { $0.date >= sevenDayStart }
            .max { $0.tokens < $1.tokens }
        let changePercent: Double?
        let isNewActivity: Bool
        if previousSevenDayTokens > 0 {
            changePercent = (Double(sevenDay.tokens.visibleTotalTokens) - Double(previousSevenDayTokens)) / Double(previousSevenDayTokens) * 100
            isNewActivity = false
        } else {
            changePercent = nil
            isNewActivity = sevenDay.tokens.visibleTotalTokens > 0
        }

        let dayOfMonth = max(calendar.component(.day, from: Date()), 1)
        let daysInMonth = calendar.range(of: .day, in: .month, for: Date())?.count ?? dayOfMonth
        let projectedMonthCostUSD: Double?
        if dayOfMonth >= 2, month.estimatedCostUSD > 0 {
            projectedMonthCostUSD = month.estimatedCostUSD / Double(dayOfMonth) * Double(daysInMonth)
        } else {
            projectedMonthCostUSD = nil
        }

        let heatmapData = makeHeatmapData(
            buckets: buckets,
            endDate: dayStart,
            weekCount: 26,
            calendar: calendar
        )
        let modelTrends = modelDailyUsage.compactMap { modelID, usage -> ModelUsageTrend? in
            let modelTrend = makeUsageTrend(
                dailyUsage: usage,
                dayStart: dayStart,
                sevenDayStart: sevenDayStart,
                trendStart: trendStart,
                monthStart: monthStart,
                sourceQuality: sourceQuality
            )
            guard modelTrend.activeDayCount > 0 else { return nil }
            return ModelUsageTrend(
                id: modelID,
                model: modelNamesByID[modelID],
                dayBuckets: modelTrend.dayBuckets,
                summary: modelTrend.summary,
                activeDayCount: modelTrend.activeDayCount
            )
        }
        .sorted { lhs, rhs in
            let lhsRecent = lhs.summary.sevenDay.tokens.visibleTotalTokens
            let rhsRecent = rhs.summary.sevenDay.tokens.visibleTotalTokens
            if lhsRecent != rhsRecent { return lhsRecent > rhsRecent }
            let lhsTotal = lhs.dayBuckets.reduce(Int64(0)) { $0 + $1.tokens }
            let rhsTotal = rhs.dayBuckets.reduce(Int64(0)) { $0 + $1.tokens }
            if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
            return (lhs.model ?? "") < (rhs.model ?? "")
        }

        return UsageTrend(
            dayBuckets: buckets,
            heatmapWeeks: heatmapData.weeks,
            heatmapThresholds: heatmapData.thresholds,
            summary: UsageTrendSummary(
                sevenDay: sevenDay,
                dailyAverageTokens: sevenDay.tokens.visibleTotalTokens / 7,
                peakDay: peakDay?.tokens ?? 0 > 0 ? peakDay : nil,
                changePercent: changePercent,
                isNewActivity: isNewActivity
            ),
            modelTrends: modelTrends,
            month: month,
            projectedMonthCostUSD: projectedMonthCostUSD,
            activeDayCount: buckets.filter { $0.tokens > 0 }.count,
            sourceQuality: sourceQuality
        )
    }

    private func makeHeatmapData(
        buckets: [UsageDayBucket],
        endDate: Date,
        weekCount: Int,
        calendar: Calendar
    ) -> (weeks: [[UsageHeatmapDay]], thresholds: [Int64]) {
        let latestDate = calendar.startOfDay(for: endDate)
        let currentWeekStart = weekStart(for: latestDate, calendar: calendar)
        let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: currentWeekStart) ?? currentWeekStart
        let bucketByDay = Dictionary(uniqueKeysWithValues: buckets.map { ($0.id, $0) })

        let weeks: [[UsageHeatmapDay]] = (0..<weekCount).map { weekIndex in
            (0..<7).compactMap { weekdayIndex in
                guard let date = calendar.date(byAdding: .day, value: weekIndex * 7 + weekdayIndex, to: firstWeekStart) else {
                    return nil
                }
                let key = localDayKey(date, calendar: calendar)
                let isFuture = date > latestDate
                return UsageHeatmapDay(
                    id: key,
                    date: date,
                    usage: isFuture ? nil : bucketByDay[key]?.usage,
                    isFuture: isFuture
                )
            }
        }

        let values =
            weeks
            .flatMap { $0 }
            .filter { !$0.isFuture }
            .map(\.tokens)
            .filter { $0 > 0 }
            .sorted()
        return (weeks, heatmapThresholds(values))
    }

    private func heatmapThresholds(_ values: [Int64]) -> [Int64] {
        guard values.count >= 5 else {
            let maxValue = max(values.max() ?? 0, 1)
            return [maxValue / 5, maxValue * 2 / 5, maxValue * 3 / 5, maxValue * 4 / 5]
                .map { max($0, 1) }
        }
        return [
            quantile(values, fraction: 0.25),
            quantile(values, fraction: 0.50),
            quantile(values, fraction: 0.75),
            quantile(values, fraction: 0.90),
        ]
    }

    private func quantile(_ values: [Int64], fraction: Double) -> Int64 {
        guard !values.isEmpty else { return 1 }
        let index = min(values.count - 1, max(0, Int((Double(values.count - 1) * fraction).rounded())))
        return max(values[index], 1)
    }

    private func weekStart(for date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let mondayOffset = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -mondayOffset, to: calendar.startOfDay(for: date)) ?? date
    }

    private func readApproximateUsageTrend(
        sqlitePath: String,
        dbPath: String,
        dayStart: Date,
        sevenDayStart: Date,
        calendar: Calendar,
        forkBaselines: [String: Int64]
    ) -> UsageTrend? {
        let trendStart = calendar.date(byAdding: .day, value: -190, to: dayStart) ?? sevenDayStart
        var monthComponents = calendar.dateComponents([.year, .month], from: Date())
        monthComponents.day = 1
        monthComponents.hour = 0
        monthComponents.minute = 0
        monthComponents.second = 0
        let monthStart = calendar.date(from: monthComponents) ?? dayStart

        let query = """
            SELECT id, updated_at AS updatedAt, tokens_used AS tokens, model
            FROM threads
            WHERE updated_at >= \(Int(trendStart.timeIntervalSince1970))
            ORDER BY updated_at ASC;
            """

        let rows = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: query)
        guard !rows.isEmpty else { return nil }

        var dailyUsage: [String: PricedTokenUsage] = [:]
        var dailyUsageByModel: [String: [String: PricedTokenUsage]] = [:]
        var modelNamesByID: [String: String] = [:]
        for row in rows {
            guard let updatedAt = dateFromEpoch(row["updatedAt"]) else { continue }
            let key = localDayKey(updatedAt, calendar: calendar)
            let rawTokens = int64Value(row["tokens"]) ?? 0
            let threadId = row["id"] as? String ?? ""
            let tokens = max(rawTokens - (forkBaselines[threadId] ?? 0), 0)
            let tokenBreakdown = TokenBreakdown(
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: tokens
            )
            var usage = dailyUsage[key] ?? .zero
            usage.add(tokens: tokenBreakdown, costUSD: 0)
            dailyUsage[key] = usage

            let model = normalizedModelUsageName(row["model"] as? String)
            let modelID = modelUsageIdentifier(for: model)
            var modelUsage = dailyUsageByModel[modelID] ?? [:]
            var modelDayUsage = modelUsage[key] ?? .zero
            modelDayUsage.add(tokens: tokenBreakdown, costUSD: 0)
            modelUsage[key] = modelDayUsage
            dailyUsageByModel[modelID] = modelUsage
            if let model {
                modelNamesByID[modelID] = model
            }
        }

        return makeUsageTrend(
            dailyUsage: dailyUsage,
            dayStart: dayStart,
            sevenDayStart: sevenDayStart,
            trendStart: trendStart,
            monthStart: monthStart,
            sourceQuality: .approximate,
            modelDailyUsage: dailyUsageByModel,
            modelNamesByID: modelNamesByID
        )
    }

    private func readAllTimeProjects(
        sqlitePath: String,
        dbPath: String,
        forkBaselines: [String: Int64]
    ) -> [ProjectUsage] {
        readApproximateProjects(
            sqlitePath: sqlitePath,
            dbPath: dbPath,
            updatedSince: nil,
            forkBaselines: forkBaselines
        )
    }

    private func readApproximateRecentProjects(
        sqlitePath: String,
        dbPath: String,
        sevenDayStart: Date,
        forkBaselines: [String: Int64]
    ) -> [ProjectUsage] {
        readApproximateProjects(
            sqlitePath: sqlitePath,
            dbPath: dbPath,
            updatedSince: sevenDayStart,
            forkBaselines: forkBaselines
        )
    }

    private func readApproximateProjects(
        sqlitePath: String,
        dbPath: String,
        updatedSince: Date?,
        forkBaselines: [String: Int64]
    ) -> [ProjectUsage] {
        let dateFilter = updatedSince.map { "AND updated_at >= \(Int($0.timeIntervalSince1970))" } ?? ""
        let query = """
            SELECT id, cwd, tokens_used AS tokens, CASE WHEN recency_at > 0 THEN recency_at ELSE updated_at END AS lastActiveAt
            FROM threads
            WHERE tokens_used > 0
              \(dateFilter)
            """

        var totals: [String: (tokens: Int64, threadCount: Int, lastActiveAt: Date?)] = [:]
        for row in runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: query) {
            let path = row["cwd"] as? String ?? ""
            let threadId = row["id"] as? String ?? ""
            let rawTokens = int64Value(row["tokens"]) ?? 0
            let tokens = max(rawTokens - (forkBaselines[threadId] ?? 0), 0)
            let lastActiveAt = dateFromEpoch(row["lastActiveAt"])
            var total = totals[path] ?? (tokens: 0, threadCount: 0, lastActiveAt: nil)
            total.tokens += tokens
            total.threadCount += 1
            if let lastActiveAt,
                total.lastActiveAt == nil || lastActiveAt > (total.lastActiveAt ?? .distantPast)
            {
                total.lastActiveAt = lastActiveAt
            }
            totals[path] = total
        }

        var projects: [ProjectUsage] = []
        for (path, total) in totals {
            guard total.tokens > 0 else { continue }
            projects.append(
                ProjectUsage(
                    id: path.isEmpty ? "uncategorized" : path,
                    name: path.isEmpty ? WidgetLanguage.storedOrAutomatic().text("未归类", "Uncategorized") : shortWorkspaceName(path),
                    fullPath: path,
                    tokens: total.tokens,
                    estimatedCostUSD: nil,
                    threadCount: total.threadCount,
                    lastActiveAt: total.lastActiveAt,
                    sourceQuality: .approximate
                ))
        }
        projects.sort { $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens }
        return Array(projects.prefix(24))
    }

    private func makeSkillUsages(
        from accumulators: [String: SkillUsageAccumulator],
        reusableStaticInfo: [String: SkillStaticInfo]
    ) -> [SkillUsage] {
        accumulators.values
            .map { accumulator in
                accumulator.makeUsage(
                    staticInfo: reusableStaticInfo[accumulator.path] ?? skillStaticInfo(for: accumulator.path)
                )
            }
            .sorted {
                if $0.loadCount != $1.loadCount { return $0.loadCount > $1.loadCount }
                if ($0.staticTokenEstimate ?? -1) != ($1.staticTokenEstimate ?? -1) {
                    return ($0.staticTokenEstimate ?? -1) > ($1.staticTokenEstimate ?? -1)
                }
                return $0.name < $1.name
            }
    }

    private func skillStaticInfo(for path: String) -> SkillStaticInfo {
        // Skill discovery legitimately permits symlinks. Resolve that source to
        // its target first, then apply the same bounded regular-file reader.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard
            let data = try? DispatchParticipationSync.readBoundedRegularFile(
                url,
                maximumBytes: 4 * 1_024 * 1_024
            )
        else {
            return SkillStaticInfo(tokenEstimate: nil, byteCount: nil)
        }

        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return SkillStaticInfo(
            tokenEstimate: estimateStaticTokens(text),
            byteCount: Int64(data.count)
        )
    }

    private func cachedSessionUsage(
        source: SessionUsageSource,
        inferenceStart: Date?,
        fractionalFormatter: ISO8601DateFormatter,
        plainFormatter: ISO8601DateFormatter
    ) -> SessionUsageCacheEntry? {
        let collectInference = inferenceStart != nil
        func retainedInferenceSamples(_ samples: [ModelInferenceSample]) -> [ModelInferenceSample] {
            guard let inferenceStart else { return [] }
            return samples.filter { $0.completedAt >= inferenceStart }
        }

        let url = URL(fileURLWithPath: source.rolloutPath)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }

        let modificationDate = attributes[.modificationDate] as? Date
        if let cached = memorySessionUsageCacheEntry(for: source.rolloutPath),
            sameSessionFileIdentity(cached, fileSize: fileSize, modificationDate: modificationDate),
            !collectInference || cached.inferenceSchemaVersion == inferenceSampleSchemaVersion
        {
            return cached
        }

        if let cached = persistentSessionUsageCache()[source.rolloutPath],
            sameSessionFileIdentity(cached, fileSize: fileSize, modificationDate: modificationDate),
            !collectInference || cached.inferenceSchemaVersion == inferenceSampleSchemaVersion
        {
            storeSessionUsageCacheEntry(cached, for: source.rolloutPath, markDirty: false)
            return cached
        }

        let baseEventPattern = #""type":"(session_meta|turn_context|thread_settings_applied|token_count|function_call|custom_tool_call)""#
        let inferenceEventPattern =
            #""type":"(session_meta|turn_context|thread_settings_applied|token_count|function_call|custom_tool_call|function_call_output|custom_tool_call_output|tool_search_call|tool_search_output|web_search_call|mcp_tool_call_end|web_search_end|patch_apply_end|image_generation_end|reasoning|agent_message|agent_reasoning)"|"role":"assistant""#
        let eventPattern = collectInference ? inferenceEventPattern : baseEventPattern
        let sessionMetaNeedle = Data(#""type":"session_meta""#.utf8)
        let turnContextNeedle = Data(#""type":"turn_context""#.utf8)
        let threadSettingsNeedle = Data(#""type":"thread_settings_applied""#.utf8)
        let tokenCountNeedle = Data(#""type":"token_count""#.utf8)
        let functionCallNeedle = Data(#""type":"function_call""#.utf8)
        let customToolCallNeedle = Data(#""type":"custom_tool_call""#.utf8)
        let inferenceBoundaryNeedles = [
            Data(#""type":"function_call_output""#.utf8),
            Data(#""type":"custom_tool_call_output""#.utf8),
            Data(#""type":"tool_search_output""#.utf8),
            Data(#""type":"mcp_tool_call_end""#.utf8),
            Data(#""type":"web_search_end""#.utf8),
            Data(#""type":"patch_apply_end""#.utf8),
            Data(#""type":"image_generation_end""#.utf8),
        ]
        let modelOutputNeedles = [
            Data(#""type":"reasoning""#.utf8),
            Data(#""type":"agent_reasoning""#.utf8),
            Data(#""type":"agent_message""#.utf8),
            Data(#""role":"assistant""#.utf8),
            functionCallNeedle,
            customToolCallNeedle,
            Data(#""type":"tool_search_call""#.utf8),
            Data(#""type":"web_search_call""#.utf8),
        ]
        if let parsed = parseSessionUsageWithGrep(
            url: url,
            eventPattern: eventPattern,
            sessionMetaNeedle: sessionMetaNeedle,
            turnContextNeedle: turnContextNeedle,
            threadSettingsNeedle: threadSettingsNeedle,
            tokenCountNeedle: tokenCountNeedle,
            functionCallNeedle: functionCallNeedle,
            customToolCallNeedle: customToolCallNeedle,
            inferenceBoundaryNeedles: inferenceBoundaryNeedles,
            modelOutputNeedles: modelOutputNeedles,
            fractionalFormatter: fractionalFormatter,
            plainFormatter: plainFormatter
        ) {
            let entry = SessionUsageCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                forkedFromId: parsed.forkedFromId,
                hasTokenEvents: parsed.hasTokenEvents,
                tokenEventCount: parsed.tokenEventCount,
                deltas: parsed.deltas,
                inferenceSamples: retainedInferenceSamples(parsed.inferenceSamples),
                inferenceSchemaVersion: collectInference ? inferenceSampleSchemaVersion : nil,
                toolCalls: parsed.toolCalls,
                skillLoads: parsed.skillLoads
            )
            storeSessionUsageCacheEntry(entry, for: source.rolloutPath)
            return entry
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var forkedFromId: String?
        var activeModel: String?
        var activeServiceTier: String?
        var inferenceTracker = ModelInferenceCallTracker()
        var counterState = CodexTokenCounterState()
        var sawTokenEvent = false
        var tokenEventCount = 0
        var deltas: [SessionUsageDelta] = []
        var inferenceSamples: [ModelInferenceSample] = []
        var toolCalls: [String: Int] = [:]
        var skillLoads: [SkillLoadEvent] = []
        let maximumSessionLineBytes = 4 * 1_024 * 1_024
        var droppingOversizedLine = false

        while true {
            let chunk = try? handle.read(upToCount: 64 * 1024)
            guard let chunk, !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 10) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !droppingOversizedLine, lineData.count <= maximumSessionLineBytes {
                    processSessionLine(
                        lineData,
                        sessionMetaNeedle: sessionMetaNeedle,
                        turnContextNeedle: turnContextNeedle,
                        threadSettingsNeedle: threadSettingsNeedle,
                        tokenCountNeedle: tokenCountNeedle,
                        functionCallNeedle: functionCallNeedle,
                        customToolCallNeedle: customToolCallNeedle,
                        inferenceBoundaryNeedles: inferenceBoundaryNeedles,
                        modelOutputNeedles: modelOutputNeedles,
                        fractionalFormatter: fractionalFormatter,
                        plainFormatter: plainFormatter,
                        forkedFromId: &forkedFromId,
                        activeModel: &activeModel,
                        activeServiceTier: &activeServiceTier,
                        inferenceTracker: &inferenceTracker,
                        counterState: &counterState,
                        sawTokenEvent: &sawTokenEvent,
                        tokenEventCount: &tokenEventCount,
                        deltas: &deltas,
                        inferenceSamples: &inferenceSamples,
                        toolCalls: &toolCalls,
                        skillLoads: &skillLoads
                    )
                }
                droppingOversizedLine = false
            }
            if buffer.count > maximumSessionLineBytes {
                buffer.removeAll(keepingCapacity: false)
                droppingOversizedLine = true
            }
        }

        if !droppingOversizedLine, !buffer.isEmpty {
            processSessionLine(
                buffer,
                sessionMetaNeedle: sessionMetaNeedle,
                turnContextNeedle: turnContextNeedle,
                threadSettingsNeedle: threadSettingsNeedle,
                tokenCountNeedle: tokenCountNeedle,
                functionCallNeedle: functionCallNeedle,
                customToolCallNeedle: customToolCallNeedle,
                inferenceBoundaryNeedles: inferenceBoundaryNeedles,
                modelOutputNeedles: modelOutputNeedles,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter,
                forkedFromId: &forkedFromId,
                activeModel: &activeModel,
                activeServiceTier: &activeServiceTier,
                inferenceTracker: &inferenceTracker,
                counterState: &counterState,
                sawTokenEvent: &sawTokenEvent,
                tokenEventCount: &tokenEventCount,
                deltas: &deltas,
                inferenceSamples: &inferenceSamples,
                toolCalls: &toolCalls,
                skillLoads: &skillLoads
            )
        }

        let entry = SessionUsageCacheEntry(
            fileSize: fileSize,
            modificationDate: modificationDate,
            forkedFromId: forkedFromId,
            hasTokenEvents: sawTokenEvent,
            tokenEventCount: tokenEventCount,
            deltas: deltas,
            inferenceSamples: retainedInferenceSamples(inferenceSamples),
            inferenceSchemaVersion: collectInference ? inferenceSampleSchemaVersion : nil,
            toolCalls: toolCalls,
            skillLoads: skillLoads
        )
        storeSessionUsageCacheEntry(entry, for: source.rolloutPath)
        return entry
    }

    private func memorySessionUsageCacheEntry(for key: String) -> SessionUsageCacheEntry? {
        guard let entry = Self.sessionUsageCache[key] else { return nil }
        Self.sessionUsageCacheOrder.removeAll { $0 == key }
        Self.sessionUsageCacheOrder.append(key)
        return entry
    }

    private func storeSessionUsageCacheEntry(
        _ entry: SessionUsageCacheEntry,
        for key: String,
        markDirty: Bool = true
    ) {
        Self.sessionUsageCache[key] = entry
        if markDirty {
            if Self.persistentSessionUsageCache == nil {
                _ = persistentSessionUsageCache()
            }
            Self.persistentSessionUsageCache?[key] = entry
            Self.persistentSessionUsageCacheIsDirty = true
        }
        Self.sessionUsageCacheOrder.removeAll { $0 == key }
        Self.sessionUsageCacheOrder.append(key)
        while Self.sessionUsageCacheOrder.count > Self.memorySessionUsageCacheLimit {
            let evicted = Self.sessionUsageCacheOrder.removeFirst()
            Self.sessionUsageCache.removeValue(forKey: evicted)
        }
    }

    private func parseSessionUsageWithGrep(
        url: URL,
        eventPattern: String,
        sessionMetaNeedle: Data,
        turnContextNeedle: Data,
        threadSettingsNeedle: Data,
        tokenCountNeedle: Data,
        functionCallNeedle: Data,
        customToolCallNeedle: Data,
        inferenceBoundaryNeedles: [Data],
        modelOutputNeedles: [Data],
        fractionalFormatter: ISO8601DateFormatter,
        plainFormatter: ISO8601DateFormatter
    ) -> (
        forkedFromId: String?, hasTokenEvents: Bool, tokenEventCount: Int, deltas: [SessionUsageDelta], inferenceSamples: [ModelInferenceSample], toolCalls: [String: Int],
        skillLoads: [SkillLoadEvent]
    )? {
        let grepPath = "/usr/bin/grep"
        guard fileManager.isExecutableFile(atPath: grepPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: grepPath)
        process.arguments = ["-a", "-E", eventPattern, url.path]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        guard
            let data = readBoundedProcessOutput(
                output.fileHandleForReading,
                process: process,
                maximumBytes: 32 * 1_024 * 1_024
            )
        else {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return nil
        }

        var buffer = data
        var forkedFromId: String?
        var activeModel: String?
        var activeServiceTier: String?
        var inferenceTracker = ModelInferenceCallTracker()
        var counterState = CodexTokenCounterState()
        var sawTokenEvent = false
        var tokenEventCount = 0
        var deltas: [SessionUsageDelta] = []
        var inferenceSamples: [ModelInferenceSample] = []
        var toolCalls: [String: Int] = [:]
        var skillLoads: [SkillLoadEvent] = []

        while let newline = buffer.firstIndex(of: 10) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            processSessionLine(
                lineData,
                sessionMetaNeedle: sessionMetaNeedle,
                turnContextNeedle: turnContextNeedle,
                threadSettingsNeedle: threadSettingsNeedle,
                tokenCountNeedle: tokenCountNeedle,
                functionCallNeedle: functionCallNeedle,
                customToolCallNeedle: customToolCallNeedle,
                inferenceBoundaryNeedles: inferenceBoundaryNeedles,
                modelOutputNeedles: modelOutputNeedles,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter,
                forkedFromId: &forkedFromId,
                activeModel: &activeModel,
                activeServiceTier: &activeServiceTier,
                inferenceTracker: &inferenceTracker,
                counterState: &counterState,
                sawTokenEvent: &sawTokenEvent,
                tokenEventCount: &tokenEventCount,
                deltas: &deltas,
                inferenceSamples: &inferenceSamples,
                toolCalls: &toolCalls,
                skillLoads: &skillLoads
            )
        }

        if !buffer.isEmpty {
            processSessionLine(
                buffer,
                sessionMetaNeedle: sessionMetaNeedle,
                turnContextNeedle: turnContextNeedle,
                threadSettingsNeedle: threadSettingsNeedle,
                tokenCountNeedle: tokenCountNeedle,
                functionCallNeedle: functionCallNeedle,
                customToolCallNeedle: customToolCallNeedle,
                inferenceBoundaryNeedles: inferenceBoundaryNeedles,
                modelOutputNeedles: modelOutputNeedles,
                fractionalFormatter: fractionalFormatter,
                plainFormatter: plainFormatter,
                forkedFromId: &forkedFromId,
                activeModel: &activeModel,
                activeServiceTier: &activeServiceTier,
                inferenceTracker: &inferenceTracker,
                counterState: &counterState,
                sawTokenEvent: &sawTokenEvent,
                tokenEventCount: &tokenEventCount,
                deltas: &deltas,
                inferenceSamples: &inferenceSamples,
                toolCalls: &toolCalls,
                skillLoads: &skillLoads
            )
        }

        return (forkedFromId, sawTokenEvent, tokenEventCount, deltas, inferenceSamples, toolCalls, skillLoads)
    }

    private func processSessionLine(
        _ lineData: Data,
        sessionMetaNeedle: Data,
        turnContextNeedle: Data,
        threadSettingsNeedle: Data,
        tokenCountNeedle: Data,
        functionCallNeedle: Data,
        customToolCallNeedle: Data,
        inferenceBoundaryNeedles: [Data],
        modelOutputNeedles: [Data],
        fractionalFormatter: ISO8601DateFormatter,
        plainFormatter: ISO8601DateFormatter,
        forkedFromId: inout String?,
        activeModel: inout String?,
        activeServiceTier: inout String?,
        inferenceTracker: inout ModelInferenceCallTracker,
        counterState: inout CodexTokenCounterState,
        sawTokenEvent: inout Bool,
        tokenEventCount: inout Int,
        deltas: inout [SessionUsageDelta],
        inferenceSamples: inout [ModelInferenceSample],
        toolCalls: inout [String: Int],
        skillLoads: inout [SkillLoadEvent]
    ) {
        let isSessionMeta = lineData.range(of: sessionMetaNeedle) != nil
        let isTurnContext = lineData.range(of: turnContextNeedle) != nil
        let isThreadSettings = lineData.range(of: threadSettingsNeedle) != nil
        let isTokenEvent = lineData.range(of: tokenCountNeedle) != nil
        let isToolEvent = lineData.range(of: functionCallNeedle) != nil || lineData.range(of: customToolCallNeedle) != nil
        let mightBeInferenceBoundary = inferenceBoundaryNeedles.contains { lineData.range(of: $0) != nil }
        let mightBeModelOutput = modelOutputNeedles.contains { lineData.range(of: $0) != nil }
        guard isSessionMeta || isTurnContext || isThreadSettings || isTokenEvent || isToolEvent || mightBeInferenceBoundary || mightBeModelOutput else {
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
            let payload = object["payload"] as? [String: Any]
        else { return }

        if object["type"] as? String == "session_meta" {
            if let parentId = payload["forked_from_id"] as? String, !parentId.isEmpty {
                forkedFromId = parentId
            }
            return
        }

        if payload["type"] as? String == "thread_settings_applied",
            let settings = payload["thread_settings"] as? [String: Any]
        {
            activeServiceTier = normalizedServiceTier(settings["service_tier"] as? String)
            return
        }

        if object["type"] as? String == "turn_context" {
            applyTurnContextModel(payload["model"] as? String, to: &activeModel)
            if let timestamp = object["timestamp"] as? String,
                let date = fractionalFormatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp)
            {
                inferenceTracker.applyTurnContext(
                    model: payload["model"] as? String,
                    effort: payload["effort"] as? String,
                    at: date
                )
            }
            return
        }

        guard let payloadType = payload["type"] as? String else { return }

        if modelOutputPayloadTypes.contains(payloadType) || payload["role"] as? String == "assistant" {
            inferenceTracker.observeModelOutput()
        }

        if inferenceBoundaryPayloadTypes.contains(payloadType),
            let timestamp = object["timestamp"] as? String,
            let date = fractionalFormatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp)
        {
            inferenceTracker.applyInputBoundary(at: date)
            return
        }

        if payloadType == "function_call" || payloadType == "custom_tool_call" {
            if let name = payload["name"] as? String, !name.isEmpty {
                toolCalls[name, default: 0] += 1
            }
            let eventDate = (object["timestamp"] as? String).flatMap {
                fractionalFormatter.date(from: $0) ?? plainFormatter.date(from: $0)
            }
            for path in skillLoadPaths(in: payload) {
                skillLoads.append(SkillLoadEvent(path: path, date: eventDate))
            }
            return
        }

        guard payloadType == "token_count",
            let timestamp = object["timestamp"] as? String,
            let info = payload["info"] as? [String: Any],
            let date = fractionalFormatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp)
        else { return }

        let cumulativeSample = (info["total_token_usage"] as? [String: Any]).map { usage in
            tokenCounterSample(from: usage)
        }
        let lastUsageSample = (info["last_token_usage"] as? [String: Any]).map { usage in
            tokenCounterSample(from: usage)
        }
        guard cumulativeSample != nil || lastUsageSample != nil else { return }

        sawTokenEvent = true
        tokenEventCount += 1

        let eventIdentity = CodexTokenEventIdentity(
            cumulative: cumulativeSample,
            lastUsage: lastUsageSample
        )
        if let inferenceSample = inferenceTracker.consumeTokenEvent(
            at: date,
            lastUsage: lastUsageSample,
            eventIdentity: eventIdentity
        ) {
            inferenceSamples.append(inferenceSample)
        }

        guard
            let delta = CodexTokenCounterNormalizer.consume(
                cumulative: cumulativeSample,
                lastUsage: lastUsageSample,
                state: &counterState
            )
        else { return }
        deltas.append(
            SessionUsageDelta(
                date: date,
                tokens: delta,
                model: activeModel,
                serviceTier: activeServiceTier,
                eventIdentity: eventIdentity
            )
        )
    }

    private func readTaskBoard(context: RuntimeLoadContext, messages: inout [String]) -> TaskBoard? {
        let calendar = context.statistics.calendar
        let now = context.now
        let dayStart = calendar.startOfDay(for: now)
        var activeItems: [TaskItem] = []
        var pendingItems: [TaskItem] = []
        var doneItems: [TaskItem] = []

        if let dbPath = firstExistingPath([
            NSHomeDirectory() + "/.codex/state_5.sqlite",
            NSHomeDirectory() + "/.codex/sqlite/state_5.sqlite",
        ]),
            let sqlitePath = firstExistingPath([
                "/usr/bin/sqlite3",
                "/opt/homebrew/bin/sqlite3",
                "/opt/homebrew/share/android-commandlinetools/platform-tools/sqlite3",
            ])
        {
            let todayThreadsQuery = """
                SELECT id, name, title, preview, cwd, tokens_used AS tokens, updated_at AS updatedAt, recency_at AS recencyAt, model
                FROM threads
                WHERE archived = 0
                  AND COALESCE(thread_source, '') <> 'subagent'
                  AND preview <> ''
                  AND (
                    updated_at >= \(Int(dayStart.timeIntervalSince1970))
                    OR recency_at >= \(Int(dayStart.timeIntervalSince1970))
                    OR created_at >= \(Int(dayStart.timeIntervalSince1970))
                  )
                ORDER BY recency_at DESC, updated_at DESC;
                """

            let archivedTodayQuery = """
                SELECT id, title, preview, cwd, tokens_used AS tokens, COALESCE(archived_at, updated_at) AS updatedAt, model
                FROM threads
                WHERE archived = 1
                  AND COALESCE(thread_source, '') <> 'subagent'
                  AND COALESCE(archived_at, updated_at) >= \(Int(dayStart.timeIntervalSince1970))
                ORDER BY COALESCE(archived_at, updated_at) DESC;
                """

            let todayThreads = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: todayThreadsQuery)
            for object in todayThreads {
                let updatedAt = [dateFromEpoch(object["recencyAt"]), dateFromEpoch(object["updatedAt"])]
                    .compactMap { $0 }
                    .max()
                let classification = TaskSourceClassifier.codexThread(updatedAt: updatedAt, now: now)
                let item = makeThreadTaskItem(
                    object: object,
                    updatedAt: updatedAt,
                    kind: classification.columnKind,
                    displayState: classification.displayState
                )
                if classification.columnKind == .active {
                    activeItems.append(item)
                } else {
                    pendingItems.append(item)
                }
            }

            doneItems = runSQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: archivedTodayQuery).map { object in
                makeThreadTaskItem(
                    object: object,
                    updatedAt: dateFromEpoch(object["updatedAt"]),
                    kind: .done,
                    displayState: .archived
                )
            }
        } else {
            messages.append(WidgetLanguage.storedOrAutomatic().text("任务看板未找到 SQLite 数据源", "The task board's SQLite source was not found."))
        }

        activeItems = sortedTaskItems(activeItems)
        pendingItems = sortedTaskItems(pendingItems)
        doneItems = sortedTaskItems(doneItems)
        let scheduledItems = readAutomationTasks(now: now)

        return TaskBoard(
            refreshedAt: now,
            columns: [
                TaskColumn(id: .active, title: WidgetLanguage.storedOrAutomatic().text("最近活跃", "Recently active"), count: activeItems.count, items: activeItems),
                TaskColumn(id: .pending, title: WidgetLanguage.storedOrAutomatic().text("待继续", "To continue"), count: pendingItems.count, items: pendingItems),
                TaskColumn(id: .scheduled, title: WidgetLanguage.storedOrAutomatic().text("定时", "Scheduled"), count: scheduledItems.count, items: scheduledItems),
                TaskColumn(id: .done, title: WidgetLanguage.storedOrAutomatic().text("今日归档", "Archived today"), count: doneItems.count, items: doneItems),
            ])
    }

    private func makeThreadTaskItem(
        object: [String: Any],
        updatedAt: Date?,
        kind: TaskColumnKind,
        displayState: TaskDisplayState
    ) -> TaskItem {
        let rawId = object["id"] as? String ?? UUID().uuidString
        let title = normalizedTitle(
            object["name"] as? String,
            fallback: object["title"] as? String ?? object["preview"] as? String
        )
        let cwd = object["cwd"] as? String ?? ""
        let tokens = int64Value(object["tokens"]).flatMap { $0 > 0 ? $0 : nil }
        let compactId = rawId.replacingOccurrences(of: "-", with: "")
        let code = "COD-" + compactId.suffix(4).uppercased()
        let chip = displayState.rawValue

        return TaskItem(
            id: rawId + kind.rawValue,
            code: String(code),
            title: title,
            detail: shortWorkspaceName(cwd),
            chip: chip,
            updatedAt: updatedAt,
            tokens: tokens,
            kind: kind,
            threadID: rawId,
            sourceKind: .codexThread,
            displayState: displayState,
            stateBasis: kind == .done ? .archive : .activityWindow,
            projectPath: cwd.isEmpty ? nil : cwd
        )
    }

    private func readAutomationTasks(now: Date) -> [TaskItem] {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/automations")
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        var items: [TaskItem] = []
        for case let url as URL in enumerator where url.lastPathComponent == "automation.toml" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fields = parseSimpleTOML(text)
            guard (fields["status"] ?? "").uppercased() == "ACTIVE" else { continue }

            let id = fields["id"] ?? url.deletingLastPathComponent().lastPathComponent
            let name = fields["name"] ?? id
            let kind = fields["kind"] ?? "cron"
            let schedule = TaskScheduleParser.presentation(rrule: fields["rrule"], now: now)

            items.append(
                TaskItem(
                    id: "automation-" + id,
                    code: "AUTO-" + id.prefix(4).uppercased(),
                    title: name,
                    detail: schedule.summary,
                    chip: kind == "heartbeat" ? "Wake" : "Cron",
                    updatedAt: nil,
                    tokens: nil,
                    kind: .scheduled,
                    sourceKind: .codexAutomation,
                    displayState: .scheduled,
                    stateBasis: .scheduleConfig,
                    nextRunAt: schedule.nextRunAt
                ))
        }

        return items.sorted { lhs, rhs in
            switch (lhs.nextRunAt, rhs.nextRunAt) {
            case (let left?, let right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.id < rhs.id
            }
        }
    }

    private func sortedTaskItems(_ items: [TaskItem]) -> [TaskItem] {
        items.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case (let left?, let right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    private func runSQLiteJSON(sqlitePath: String, dbPath: String, query: String) -> [[String: Any]] {
        let performanceSpan = PerformanceMonitor.shared.begin(.sqliteRead)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = ["-readonly", "-json", dbPath, query]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            PerformanceMonitor.shared.end(performanceSpan, success: false)
            return []
        }

        guard
            let data = readBoundedProcessOutput(
                output.fileHandleForReading,
                process: process,
                maximumBytes: 32 * 1_024 * 1_024
            )
        else {
            PerformanceMonitor.shared.end(performanceSpan, success: false)
            return []
        }
        process.waitUntilExit()

        guard
            process.terminationStatus == 0,
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            PerformanceMonitor.shared.end(performanceSpan, success: false)
            return []
        }

        PerformanceMonitor.shared.end(performanceSpan)
        return json
    }

    private func readBoundedProcessOutput(
        _ handle: FileHandle,
        process: Process,
        maximumBytes: Int
    ) -> Data? {
        defer { try? handle.close() }
        var result = Data()
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 64 * 1_024),
                    !next.isEmpty
                else { break }
                chunk = next
            } catch {
                terminate(process)
                return nil
            }
            guard chunk.count <= maximumBytes,
                result.count <= maximumBytes - chunk.count
            else {
                terminate(process)
                return nil
            }
            result.append(chunk)
        }
        return result
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    private func resolveCodexExecutablePath() -> String? {
        CodexExecutable.path(fileManager: fileManager)
    }

    private func firstExistingPath(_ paths: [String]) -> String? {
        paths.first { fileManager.isExecutableFile(atPath: $0) || fileManager.fileExists(atPath: $0) }
    }

    private func localAnalyticsCacheURL() -> URL? {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return
            caches
            .appendingPathComponent("CodexAccountManagerNext", isDirectory: true)
            .appendingPathComponent("local-analytics-v2.json")
    }

    private func sessionUsageCacheURL() -> URL? {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return
            caches
            .appendingPathComponent("CodexAccountManagerNext", isDirectory: true)
            .appendingPathComponent("session-usage-v1.json")
    }

    private func readPersistentLocalAnalyticsCache() -> LocalAnalyticsCacheEntry? {
        guard let url = localAnalyticsCacheURL(),
            let data = try? DispatchParticipationSync.readBoundedRegularFile(
                url,
                maximumBytes: Int(Self.maximumPersistentCacheBytes)
            )
        else { return nil }
        return try? JSONDecoder().decode(LocalAnalyticsCacheEntry.self, from: data)
    }

    private func persistentSessionUsageCache() -> [String: SessionUsageCacheEntry] {
        if let cache = Self.persistentSessionUsageCache {
            return cache
        }

        guard let url = sessionUsageCacheURL(),
            let data = try? DispatchParticipationSync.readBoundedRegularFile(
                url,
                maximumBytes: Int(Self.maximumPersistentCacheBytes)
            ),
            let diskCache = try? JSONDecoder().decode(SessionUsageDiskCache.self, from: data),
            diskCache.version == sessionUsageCacheVersion
        else {
            Self.persistentSessionUsageCache = [:]
            return [:]
        }

        let entries = limitedSessionUsageCache(diskCache.entries)
        Self.persistentSessionUsageCache = entries
        return entries
    }

    private func writePersistentLocalAnalyticsCache(_ entry: LocalAnalyticsCacheEntry?) {
        guard let entry, let url = localAnalyticsCacheURL() else { return }
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(entry)
            guard Int64(data.count) <= Self.maximumPersistentCacheBytes else { return }
            try PrivateLocalFileStore.write(data, to: url, fileManager: fileManager)
        } catch {
            debugLog("failed to write local analytics cache")
        }
    }

    private func writePersistentSessionUsageCache() {
        guard Self.persistentSessionUsageCacheIsDirty else { return }
        let now = Date()
        if let lastWrite = Self.lastPersistentSessionUsageCacheWriteAt,
            now.timeIntervalSince(lastWrite) < Self.persistentSessionUsageCacheWriteInterval
        {
            return
        }
        guard let url = sessionUsageCacheURL() else { return }
        let mergedEntries = limitedSessionUsageCache(
            persistentSessionUsageCache().merging(Self.sessionUsageCache) { _, new in new }
        )
        Self.persistentSessionUsageCache = mergedEntries

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(SessionUsageDiskCache(version: sessionUsageCacheVersion, entries: mergedEntries))
            guard Int64(data.count) <= Self.maximumPersistentCacheBytes else { return }
            try PrivateLocalFileStore.write(data, to: url, fileManager: fileManager)
            Self.persistentSessionUsageCacheIsDirty = false
            Self.lastPersistentSessionUsageCacheWriteAt = now
        } catch {
            debugLog("failed to write session usage cache")
        }
    }

    private func limitedSessionUsageCache(
        _ entries: [String: SessionUsageCacheEntry]
    ) -> [String: SessionUsageCacheEntry] {
        guard entries.count > Self.persistentSessionUsageCacheLimit else { return entries }
        let retained = entries.sorted { lhs, rhs in
            let lhsDate = lhs.value.modificationDate ?? .distantPast
            let rhsDate = rhs.value.modificationDate ?? .distantPast
            return lhsDate == rhsDate ? lhs.key < rhs.key : lhsDate > rhsDate
        }.prefix(Self.persistentSessionUsageCacheLimit)
        return Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    }

    private func releaseSessionUsageWorkingSet() {
        Self.sessionUsageCache.removeAll(keepingCapacity: false)
        Self.sessionUsageCacheOrder.removeAll(keepingCapacity: false)
        Self.persistentSessionUsageCache = nil
    }

    private func sameSessionFileIdentity(
        _ cached: SessionUsageCacheEntry,
        fileSize: Int64,
        modificationDate: Date?
    ) -> Bool {
        guard cached.fileSize == fileSize else { return false }
        let cachedMs = Int64((cached.modificationDate?.timeIntervalSince1970 ?? -1) * 1000)
        let currentMs = Int64((modificationDate?.timeIntervalSince1970 ?? -1) * 1000)
        return cachedMs == currentMs
    }

    private func sessionSourcesFingerprint(_ sources: [SessionUsageSource]) -> String {
        var hasher = SHA256()
        func append(_ value: String) {
            let data = Data(value.utf8)
            var byteCount = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &byteCount) { bytes in
                hasher.update(data: Data(bytes))
            }
            hasher.update(data: data)
        }

        append("fork-prefix-v2")
        append(String(sources.count))
        for source in sources {
            append(source.threadId)
            append(source.rolloutPath)
            append(source.model ?? "")
            append(source.cwd)
            let updatedMs = Int64((source.updatedAt?.timeIntervalSince1970 ?? -1) * 1_000)
            append(String(updatedMs))
            guard let attributes = try? fileManager.attributesOfItem(atPath: source.rolloutPath) else {
                append("missing")
                continue
            }
            append(String((attributes[.size] as? NSNumber)?.int64Value ?? -1))
            let modifiedMs = Int64(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1) * 1000)
            append(String(modifiedMs))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func cacheFingerprintSelfTest() -> Bool {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("camnext-cache-fingerprint-\(UUID().uuidString)", isDirectory: true)
        let rolloutURL = directory.appendingPathComponent("rollout.jsonl")
        defer { try? fileManager.removeItem(at: directory) }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("first".utf8).write(to: rolloutURL)
        } catch {
            return false
        }

        let source = SessionUsageSource(
            threadId: "private-thread-id",
            rolloutPath: rolloutURL.path,
            model: "gpt-5.6-sol",
            cwd: "/private/project/path",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reader = CodexUsageReader()
        let first = reader.sessionSourcesFingerprint([source])
        let repeated = reader.sessionSourcesFingerprint([source])
        try? Data("second-and-longer".utf8).write(to: rolloutURL, options: .atomic)
        let changedFile = reader.sessionSourcesFingerprint([source])

        return first.count == 64
            && first == repeated
            && first != changedFile
            && !first.contains(source.threadId)
            && !first.contains(source.rolloutPath)
            && !first.contains(source.cwd)
    }
}
private func tokenCounterSample(from usage: [String: Any]) -> CodexTokenCounterSample {
    CodexTokenCounterSample(
        inputTokens: int64Value(usage["input_tokens"]),
        cachedInputTokens: int64Value(usage["cached_input_tokens"]),
        cacheWriteInputTokens: int64Value(usage["cache_write_input_tokens"]),
        outputTokens: int64Value(usage["output_tokens"]),
        reasoningOutputTokens: int64Value(usage["reasoning_output_tokens"]),
        totalTokens: int64Value(usage["total_tokens"])
    )
}

private func skillLoadPaths(in payload: [String: Any]) -> [String] {
    var candidates: [String] = []
    for key in ["arguments", "input", "cmd", "command"] {
        if let text = serializedStringValue(payload[key]) {
            candidates.append(text)
        }
    }

    var paths: [String] = []
    var seen = Set<String>()
    for candidate in candidates {
        for path in extractSkillPaths(from: candidate) where seen.insert(path).inserted {
            paths.append(path)
        }
    }
    return paths
}

private func serializedStringValue(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let string = value as? String {
        return string
    }
    guard JSONSerialization.isValidJSONObject(value),
        let data = try? JSONSerialization.data(withJSONObject: value),
        let string = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return string
}

private func extractSkillPaths(from text: String) -> [String] {
    let pattern = "(?:(?:~|/)[^\\s\\\"'`<>,;)]*SKILL\\.md)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    var paths: [String] = []
    var seen = Set<String>()
    regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
        guard let match, let range = Range(match.range, in: text) else { return }
        let rawPath = String(text[range])
        guard let path = canonicalSkillPath(rawPath), seen.insert(path).inserted else { return }
        paths.append(path)
    }
    return paths
}

private func canonicalSkillPath(_ rawPath: String) -> String? {
    let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\"'`;,.)]"))
    guard trimmed.hasSuffix("/SKILL.md") || trimmed == "SKILL.md" else { return nil }

    let home = NSHomeDirectory()
    let expanded: String
    if trimmed == "~" {
        expanded = home
    } else if trimmed.hasPrefix("~/") {
        expanded = home + String(trimmed.dropFirst())
    } else {
        expanded = trimmed
    }

    guard expanded.hasPrefix("/") else { return nil }
    let standardized = (expanded as NSString).standardizingPath
    if FileManager.default.fileExists(atPath: standardized) {
        return standardized
    }
    if let equivalentPath = equivalentCachedSkillPath(for: standardized) {
        return equivalentPath
    }
    if standardized.hasPrefix(home + "/") {
        return standardized
    }
    return nil
}

private func equivalentCachedSkillPath(for path: String) -> String? {
    let components = path.split(separator: "/").map(String.init)
    guard let cacheIndex = components.firstIndex(of: "cache"),
        components.count > cacheIndex + 5,
        components[cacheIndex + 1].hasPrefix("openai-"),
        let skillsIndex = components.lastIndex(of: "skills"),
        components.count > skillsIndex + 2,
        components.last == "SKILL.md"
    else {
        return nil
    }

    let family = components[cacheIndex + 1]
    let plugin = components[cacheIndex + 2]
    let skill = components[skillsIndex + 1]
    let cacheRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/plugins/cache")
        .appendingPathComponent(family)
        .appendingPathComponent(plugin)

    guard
        let versions = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return nil
    }

    let candidates =
        versions
        .map { versionURL in
            versionURL
                .appendingPathComponent("skills")
                .appendingPathComponent(skill)
                .appendingPathComponent("SKILL.md")
        }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
        .sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }

    return candidates.first?.path
}

private func skillName(from path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
}

private func skillSourceLabel(from path: String) -> String {
    let displayPath = displayHomePath(path)
    let components = path.split(separator: "/").map(String.init)

    if let cacheIndex = components.firstIndex(of: "cache"), components.count > cacheIndex + 2 {
        let family = components[cacheIndex + 1]
        let plugin = components[cacheIndex + 2]
        return "\(family)/\(plugin)"
    }
    if displayPath.contains("/ai-infra/skills/") {
        return "ai-infra"
    }
    if displayPath.contains("/.agents/skills/") {
        return "agents"
    }
    if displayPath.contains("/.codex/skills/.system/") {
        return "system"
    }
    if displayPath.contains("/.codex/skills/") {
        return "personal"
    }
    return "local"
}

private func displayHomePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home {
        return "~"
    }
    if path.hasPrefix(home + "/") {
        return "~" + String(path.dropFirst(home.count))
    }
    return path
}

func estimateStaticTokens(_ text: String) -> Int64 {
    let scalars = Array(text.unicodeScalars)
    guard !scalars.isEmpty else { return 0 }

    let whitespaceCount = scalars.filter { CharacterSet.whitespacesAndNewlines.contains($0) }.count
    let cjkCount = scalars.filter { scalar in
        (0x4E00...0x9FFF).contains(Int(scalar.value))
            || (0x3400...0x4DBF).contains(Int(scalar.value))
            || (0x3040...0x30FF).contains(Int(scalar.value))
            || (0xAC00...0xD7AF).contains(Int(scalar.value))
    }.count
    let nonWhitespaceCount = max(0, scalars.count - whitespaceCount)
    let nonCJKCount = max(0, nonWhitespaceCount - cjkCount)
    let estimate = (Double(nonCJKCount) / 3.8) + Double(cjkCount)
    return max(1, Int64(estimate.rounded(.up)))
}

private func modelTokenPrice(for model: String?) -> ModelTokenPrice {
    let normalized = (model ?? "").lowercased()

    if normalized.contains("gpt-6-astra") {
        return ModelTokenPrice(
            model: "gpt-6-astra",
            inputPerMillion: 10,
            cachedInputPerMillion: 1,
            outputPerMillion: 50,
            cacheWriteInputPerMillion: 12.5,
            fastModeMultiplier: 2,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.6-sol") || normalized == "gpt-5.6" {
        return ModelTokenPrice(
            model: "gpt-5.6-sol",
            inputPerMillion: 5,
            cachedInputPerMillion: 0.5,
            outputPerMillion: 30,
            cacheWriteInputPerMillion: 6.25,
            fastModeMultiplier: 2,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.6-terra") {
        return ModelTokenPrice(
            model: "gpt-5.6-terra",
            inputPerMillion: 2,
            cachedInputPerMillion: 0.2,
            outputPerMillion: 12,
            cacheWriteInputPerMillion: 2.5,
            fastModeMultiplier: 2,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.6-luna") {
        return ModelTokenPrice(
            model: "gpt-5.6-luna",
            inputPerMillion: 0.2,
            cachedInputPerMillion: 0.02,
            outputPerMillion: 1.2,
            cacheWriteInputPerMillion: 0.25,
            fastModeMultiplier: 2,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.5-pro") {
        return ModelTokenPrice(
            model: "gpt-5.5-pro",
            inputPerMillion: 30,
            cachedInputPerMillion: 30,
            outputPerMillion: 180,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.5") || normalized == "chat-latest" {
        return ModelTokenPrice(
            model: "gpt-5.5",
            inputPerMillion: 5,
            cachedInputPerMillion: 0.5,
            outputPerMillion: 30,
            fastModeMultiplier: 2.5,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.4-mini") {
        return ModelTokenPrice(
            model: "gpt-5.4-mini",
            inputPerMillion: 0.75,
            cachedInputPerMillion: 0.075,
            outputPerMillion: 4.5,
            fastModeMultiplier: 2,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.4-nano") {
        return ModelTokenPrice(model: "gpt-5.4-nano", inputPerMillion: 0.2, cachedInputPerMillion: 0.02, outputPerMillion: 1.25, usesReferencePricing: false)
    }
    if normalized.contains("gpt-5.4-pro") {
        return ModelTokenPrice(
            model: "gpt-5.4-pro",
            inputPerMillion: 30,
            cachedInputPerMillion: 30,
            outputPerMillion: 180,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.4") {
        return ModelTokenPrice(
            model: "gpt-5.4",
            inputPerMillion: 2.5,
            cachedInputPerMillion: 0.25,
            outputPerMillion: 15,
            fastModeMultiplier: 2,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.3-codex-spark") {
        return ModelTokenPrice(
            model: "gpt-5.3-codex-spark",
            inputPerMillion: 5,
            cachedInputPerMillion: 0.5,
            outputPerMillion: 30,
            usesReferencePricing: true
        )
    }
    if normalized.contains("gpt-5.3-codex") {
        return ModelTokenPrice(
            model: "gpt-5.3-codex",
            inputPerMillion: 1.75,
            cachedInputPerMillion: 0.175,
            outputPerMillion: 14,
            fastModeMultiplier: 2,
            usesReferencePricing: false
        )
    }
    if normalized.contains("gpt-5.2-codex")
        || normalized.contains("gpt-5.3-chat")
        || normalized.contains("gpt-5.2")
    {
        return ModelTokenPrice(model: "gpt-5.2-codex", inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14, usesReferencePricing: false)
    }
    if normalized.contains("gpt-5-codex") || normalized == "gpt-5" {
        return ModelTokenPrice(model: "gpt-5", inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10, usesReferencePricing: false)
    }

    return ModelTokenPrice(model: "gpt-5.5", inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30, usesReferencePricing: true)
}

func modelUsageUsesReferencePricing(_ model: String?) -> Bool {
    modelTokenPrice(for: model).usesReferencePricing
}

func normalizedModelUsageName(_ model: String?) -> String? {
    guard let model else { return nil }
    let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}

func applyTurnContextModel(_ turnContextModel: String?, to activeModel: inout String?) {
    activeModel = normalizedModelUsageName(turnContextModel)
}

func modelUsageIdentifier(for model: String?) -> String {
    normalizedModelUsageName(model)?.lowercased() ?? "unrecorded-model"
}

func resolvedModelUsageName(turnContextModel: String?, threadModel: String?) -> String? {
    normalizedModelUsageName(turnContextModel) ?? normalizedModelUsageName(threadModel)
}

private func normalizedServiceTier(_ serviceTier: String?) -> String? {
    guard let serviceTier else { return nil }
    let normalized = serviceTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
}

private func isFastServiceTier(_ serviceTier: String?) -> Bool {
    let normalized = normalizedServiceTier(serviceTier)
    return normalized == "priority" || normalized == "fast"
}

private func estimatedCostUSD(
    tokens: TokenBreakdown,
    price: ModelTokenPrice,
    serviceTier: String? = nil
) -> Double {
    let usesLongContextPricing =
        tokens.inputTokens > 272_000
        && price.longContextInputMultiplier != nil
        && price.longContextOutputMultiplier != nil
    let inputMultiplier: Double
    let outputMultiplier: Double
    if usesLongContextPricing {
        // Fast mode does not support long-context requests, so the published
        // long-context rates are the only applicable API-equivalent basis.
        inputMultiplier = price.longContextInputMultiplier ?? 1
        outputMultiplier = price.longContextOutputMultiplier ?? 1
    } else if isFastServiceTier(serviceTier), let fastModeMultiplier = price.fastModeMultiplier {
        inputMultiplier = fastModeMultiplier
        outputMultiplier = fastModeMultiplier
    } else {
        inputMultiplier = 1
        outputMultiplier = 1
    }

    let uncachedInputCost =
        Double(tokens.ordinaryUncachedInputTokens) / 1_000_000
        * price.inputPerMillion * inputMultiplier
    let cachedInputCost =
        Double(tokens.billableCachedInputTokens) / 1_000_000
        * price.cachedInputPerMillion * inputMultiplier
    let cacheWriteInputCost =
        Double(tokens.billableCacheWriteInputTokens) / 1_000_000
        * price.cacheWriteInputPerMillion * inputMultiplier
    let outputCost =
        Double(max(tokens.outputTokens, 0)) / 1_000_000
        * price.outputPerMillion * outputMultiplier
    return uncachedInputCost + cachedInputCost + cacheWriteInputCost + outputCost
}

func estimatedSolProEquivalentCostUSD(
    officialTotalTokens: Int64,
    localTokens: TokenBreakdown
) -> Double? {
    let localTotal = localTokens.splitTotalTokens
    guard officialTotalTokens > 0, localTotal > 0 else { return nil }
    let price = modelTokenPrice(for: "gpt-5.6-sol")
    // Lifetime totals span many requests, so per-request long-context multipliers do not apply.
    let localCost =
        Double(localTokens.ordinaryUncachedInputTokens) / 1_000_000 * price.inputPerMillion
        + Double(localTokens.billableCachedInputTokens) / 1_000_000 * price.cachedInputPerMillion
        + Double(localTokens.billableCacheWriteInputTokens) / 1_000_000 * price.cacheWriteInputPerMillion
        + Double(max(localTokens.outputTokens, 0)) / 1_000_000 * price.outputPerMillion
    return localCost * Double(officialTotalTokens) / Double(localTotal) * 1.5
}

enum ModelPricingSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func nearlyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
            abs(lhs - rhs) < 0.000_001
        }

        let sampleTokens = TokenBreakdown(
            inputTokens: 100_000,
            cachedInputTokens: 40_000,
            outputTokens: 10_000,
            reasoningOutputTokens: 0,
            totalTokens: 110_000
        )
        let astra = modelTokenPrice(for: "GPT-6-ASTRA")
        let sol = modelTokenPrice(for: "gpt-5.6")
        let terra = modelTokenPrice(for: "gpt-5.6-terra-2026-02-16")
        let luna = modelTokenPrice(for: "GPT-5.6-LUNA")
        let gpt55 = modelTokenPrice(for: "gpt-5.5")
        let gpt54 = modelTokenPrice(for: "gpt-5.4")
        let gpt54Mini = modelTokenPrice(for: "gpt-5.4-mini")
        let gpt53Codex = modelTokenPrice(for: "gpt-5.3-codex")
        let spark = modelTokenPrice(for: "gpt-5.3-codex-spark")

        expect(astra.model == "gpt-6-astra" && !astra.usesReferencePricing, "Astra should use its explicit price, case-insensitively")
        expect(nearlyEqual(estimatedCostUSD(tokens: sampleTokens, price: astra), 1.14), "Astra should use its own cached input and output rates")
        expect(sol.model == "gpt-5.6-sol", "gpt-5.6 should resolve to gpt-5.6-sol")
        expect(!sol.usesReferencePricing, "gpt-5.6 should use an explicit price")
        expect(terra.model == "gpt-5.6-terra", "terra snapshots should preserve the terra price")
        expect(luna.model == "gpt-5.6-luna", "luna matching should be case-insensitive")
        expect(nearlyEqual(estimatedCostUSD(tokens: sampleTokens, price: sol), 0.62), "Sol cached input estimate should use the split rates")
        expect(nearlyEqual(estimatedCostUSD(tokens: sampleTokens, price: terra), 0.248), "Terra should use the official standard API rates")
        expect(nearlyEqual(estimatedCostUSD(tokens: sampleTokens, price: luna), 0.0248), "Luna should use the official standard API rates")
        expect(
            nearlyEqual(
                estimatedSolProEquivalentCostUSD(officialTotalTokens: 220_000, localTokens: sampleTokens) ?? -1,
                1.86
            ),
            "Sol Pro lifetime estimate should scale the observed token mix and apply the requested 1.5x factor"
        )
        let aggregatedTokens = TokenBreakdown(
            inputTokens: 1_000_000,
            cachedInputTokens: 800_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 0,
            totalTokens: 1_100_000
        )
        expect(
            nearlyEqual(
                estimatedSolProEquivalentCostUSD(officialTotalTokens: 1_100_000, localTokens: aggregatedTokens) ?? -1,
                6.6
            ),
            "Lifetime estimate must not apply per-request long-context pricing"
        )
        expect(
            nearlyEqual(gpt55.inputPerMillion, 5) && nearlyEqual(gpt55.cachedInputPerMillion, 0.5) && nearlyEqual(gpt55.outputPerMillion, 30),
            "GPT-5.5 should use the official standard API rates")
        expect(
            nearlyEqual(gpt54.inputPerMillion, 2.5) && nearlyEqual(gpt54.cachedInputPerMillion, 0.25) && nearlyEqual(gpt54.outputPerMillion, 15),
            "GPT-5.4 should use the official standard API rates")
        expect(
            nearlyEqual(gpt54Mini.inputPerMillion, 0.75) && nearlyEqual(gpt54Mini.cachedInputPerMillion, 0.075) && nearlyEqual(gpt54Mini.outputPerMillion, 4.5),
            "GPT-5.4 mini should use the official standard API rates")
        expect(
            nearlyEqual(gpt53Codex.inputPerMillion, 1.75) && nearlyEqual(gpt53Codex.cachedInputPerMillion, 0.175) && nearlyEqual(gpt53Codex.outputPerMillion, 14),
            "GPT-5.3 Codex should use its explicit API rates")
        expect(spark.model == "gpt-5.3-codex-spark" && spark.usesReferencePricing, "Codex Spark should remain reference-priced until official rates are final")
        expect(CodexUsageReader.cacheFingerprintSelfTest(), "local analytics cache fingerprints should be private and deterministic")

        let cacheWriteTokens = TokenBreakdown(
            inputTokens: 100_000,
            cachedInputTokens: 40_000,
            cacheWriteInputTokens: 10_000,
            outputTokens: 10_000,
            reasoningOutputTokens: 0,
            totalTokens: 110_000
        )
        expect(nearlyEqual(estimatedCostUSD(tokens: cacheWriteTokens, price: sol), 0.6325), "GPT-5.6 cache writes should use the 1.25x write rate")
        expect(nearlyEqual(estimatedCostUSD(tokens: cacheWriteTokens, price: sol, serviceTier: "priority"), 1.265), "GPT-5.6 Fast mode should use the published 2x API rates")
        expect(nearlyEqual(estimatedCostUSD(tokens: cacheWriteTokens, price: gpt55, serviceTier: "fast"), 1.55), "GPT-5.5 Fast mode should use the published 2.5x API rates")

        let longContextTokens = TokenBreakdown(
            inputTokens: 300_000,
            cachedInputTokens: 100_000,
            cacheWriteInputTokens: 100_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 0,
            totalTokens: 400_000
        )
        expect(nearlyEqual(estimatedCostUSD(tokens: longContextTokens, price: sol), 6.85), "GPT-5.6 long context should use 2x input and 1.5x output rates")
        expect(nearlyEqual(estimatedCostUSD(tokens: cacheWriteTokens, price: astra), 1.165), "Astra should use the published cache write rate")
        expect(nearlyEqual(estimatedCostUSD(tokens: cacheWriteTokens, price: astra, serviceTier: "priority"), 2.33), "Astra Fast should apply the 2x rate")
        expect(nearlyEqual(estimatedCostUSD(tokens: longContextTokens, price: astra), 12.2), "Astra long context should apply input and output multipliers separately")
        expect(isFastServiceTier("priority") && isFastServiceTier("FAST") && !isFastServiceTier("default"), "service tier normalization should distinguish Fast mode")
        expect(!modelUsageUsesReferencePricing("gpt-5.6-luna"), "known GPT-5.6 models should not use reference pricing")
        expect(modelUsageUsesReferencePricing("gpt-5.3-codex-spark"), "Codex Spark should not inherit GPT-5.3 Codex pricing")
        expect(modelUsageUsesReferencePricing("future-model"), "unknown models should retain reference pricing")

        if failures.isEmpty {
            print("model pricing self-test passed")
            return true
        }
        failures.forEach { print("model pricing self-test failed: \($0)") }
        return false
    }
}

private func parseSimpleTOML(_ text: String) -> [String: String] {
    var fields: [String: String] = [:]

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
            continue
        }

        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        fields[key] =
            value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    return fields
}

private func normalizedTitle(_ title: String?, fallback: String?) -> String {
    let raw =
        [title, fallback]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "Untitled"

    let singleLine =
        raw
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

    if singleLine.count <= 48 { return singleLine }
    return String(singleLine.prefix(45)) + "..."
}

private func shortWorkspaceName(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    if !name.isEmpty { return name }
    return path
}

private func summedTokenCounts(_ values: [Int64]) -> Int64? {
    var total: Int64 = 0
    for value in values {
        guard value >= 0 else { return nil }
        let next = total.addingReportingOverflow(value)
        guard !next.overflow else { return nil }
        total = next.partialValue
    }
    return total
}

private func intValue(_ value: Any?) -> Int? {
    if let string = value as? String { return Int(string) }
    guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    if CFNumberIsFloatType(number) { return Int(exactly: number.doubleValue) }
    return Int(number.stringValue)
}

/// Strict parsing for reset-credit protocol integers. JSON booleans are
/// NSNumbers too, and floating-point conversion must never reach a trapping cast.
private func resetExactInt64(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    if CFNumberIsFloatType(number) {
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return Int64(exactly: value)
    }
    return Int64(number.stringValue)
}

private func resetValidField(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty
        && value.utf8.count <= maximumBytes
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}

/// The outer optional reports parse validity; the inner optional preserves the
/// official absent/null meaning of a card with no expiry.
private func resetExpiry(in object: [String: Any]) -> Date?? {
    guard let raw = object["expiresAt"] else { return .some(nil) }
    if raw is NSNull { return .some(nil) }
    guard let seconds = resetExactInt64(raw) else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(seconds))
    guard date >= Date.distantPast, date <= Date.distantFuture else { return nil }
    return .some(date)
}

private func int64Value(_ value: Any?) -> Int64? {
    if let string = value as? String { return Int64(string) }
    guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    if CFNumberIsFloatType(number) { return Int64(exactly: number.doubleValue) }
    return Int64(number.stringValue)
}

private func doubleValue(_ value: Any?) -> Double? {
    let result: Double?
    if let string = value as? String {
        result = Double(string)
    } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        result = number.doubleValue
    } else {
        result = nil
    }
    guard let result, result.isFinite else { return nil }
    return result
}

private func stringValue(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

private func dateFromEpoch(_ value: Any?) -> Date? {
    guard var seconds = doubleValue(value), seconds > 0 else { return nil }
    if seconds > 10_000_000_000 {
        seconds /= 1000
    }
    guard seconds <= Date.distantFuture.timeIntervalSince1970 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

private func localDayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func toolCategory(for name: String) -> String {
    let normalized = name.lowercased()
    if normalized.contains("exec") || normalized.contains("shell") || normalized.contains("stdin") {
        return "terminal"
    }
    if normalized.contains("patch") || normalized.contains("edit") {
        return "edit"
    }
    if normalized.contains("web") || normalized.contains("browser") || normalized.contains("page") || normalized.contains("click") || normalized.contains("screenshot")
        || normalized.contains("snapshot")
    {
        return "browser"
    }
    if normalized.contains("image") || normalized.contains("figma") {
        return "visual"
    }
    if normalized.contains("docs") || normalized.contains("library") || normalized.contains("mcp") || normalized.contains("resource") {
        return "docs"
    }
    if normalized.contains("plan") || normalized.contains("goal") {
        return "planning"
    }
    return "tool"
}
