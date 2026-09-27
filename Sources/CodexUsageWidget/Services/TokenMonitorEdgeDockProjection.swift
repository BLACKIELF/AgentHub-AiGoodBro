import Foundation

/// Pure projection of already-approved local quota aliases and collected usage.
/// It performs no account switch, network request, or background collection.
enum TokenMonitorEdgeDockProjection {
    private static let providerOrder = [
        "claude", "codex", "opencode", "cursor", "antigravity", "cline", "factory", "kimi",
        "grok", "copilot", "zed", "commandcode", "mimo", "zai", "zaiteam", "kiro",
        "workbuddy", "qoder", "deepseek", "devin", "typesafe", "openrouter", "minimax",
        "volcengine", "ollama", "trae", "alibaba", "thirdparty",
    ]
    private static let clientProviderOverrides = [
        "droid": "factory", "zcode": "zai", "qodercn": "qoder", "dsh": "deepseek",
    ]

    static func make(
        preferences: TokenMonitorEdgeDockPreferences,
        quotaSources: [TokenMonitorFloatingBubbleAccount],
        usage: TokenMonitorDashboardSnapshot,
        language: WidgetLanguage,
        now: Date = Date(),
        activeCodexAccountID: String? = nil,
        liveRateSample: TokenMonitorEdgeDockRateSample? = nil
    ) -> [TokenMonitorEdgeDockCell] {
        let items = preferences.normalized().items ?? automaticItems(quotaSources)
        return items.map { item in
            switch item.type {
            case .limit:
                return providerCell(
                    item, sources: quotaSources, usage: usage, language: language,
                    activeCodexAccountID: activeCodexAccountID
                )
            case .stat:
                return statCell(item, usage: usage, language: language, now: now, liveRateSample: liveRateSample)
            }
        }
    }

    static func automaticItems(_ sources: [TokenMonitorFloatingBubbleAccount]) -> [TokenMonitorEdgeDockItem] {
        let connected = Set(
            sources.filter { account in
                account.isLoggedIn
                    && account.metrics.contains { metric in
                        metric.isAvailable && !metric.sourceID.isEmpty && knownValue(metric.value)
                    }
            }.map(\.providerID))
        let ordered =
            providerOrder.filter(connected.contains)
            + connected.subtracting(providerOrder).sorted()
        return [.stat(.today)]
            + Array(ordered.prefix(3)).map(TokenMonitorEdgeDockItem.limit)
            + [.stat(.liveRate)]
    }

    private static func providerCell(
        _ item: TokenMonitorEdgeDockItem,
        sources: [TokenMonitorFloatingBubbleAccount],
        usage: TokenMonitorDashboardSnapshot,
        language: WidgetLanguage,
        activeCodexAccountID: String?
    ) -> TokenMonitorEdgeDockCell {
        let providerID = item.providerID ?? ""
        let hidden = Set(item.hiddenAccountIDs)
        let matches = sources.filter { $0.providerID == providerID && !hidden.contains($0.accountID) }
        let accounts = matches.map { account in
            let rows = account.metrics.map { metric in
                let available = account.isLoggedIn && metric.isAvailable && !metric.sourceID.isEmpty
                let percent: Double?
                let valueLabel: String?
                switch metric.value {
                case .percentRemaining(let value) where value.isFinite && (0...100).contains(value):
                    percent = available ? value : nil
                    valueLabel = nil
                case .unlimitedCredits:
                    percent = nil
                    valueLabel = available ? "∞" : nil
                case .text(let value):
                    percent = nil
                    valueLabel = available && !value.isEmpty ? value : nil
                default:
                    percent = nil
                    valueLabel = nil
                }
                return TokenMonitorEdgeDockQuotaRow(
                    id: metric.id, title: metric.name, percentRemaining: percent,
                    valueLabel: valueLabel, resetLabel: metric.resetLabel,
                    fetchedAt: metric.fetchedAt, isStale: metric.isStale,
                    isAvailable: available && (percent != nil || valueLabel != nil)
                )
            }
            return TokenMonitorEdgeDockAccountRow(
                id: account.accountID, name: account.accountName,
                isStale: rows.contains { $0.isStale },
                isAvailable: rows.contains { $0.isAvailable }, quotaRows: rows
            )
        }
        // The account headline follows its primary (first reportable) window,
        // except that any known exhausted quota must show 0 rather than a
        // misleading healthy primary percentage. Severity still uses the
        // tightest known window, independently of the headline.
        // "active" is only resolved from a separately verified local account ID.
        let candidates: [(TokenMonitorEdgeDockAccountRow, TokenMonitorEdgeDockQuotaRow)] = accounts.compactMap { account in
            let visible = account.quotaRows.filter { $0.isAvailable && !$0.isStale }
            guard let row = visible.first(where: { $0.percentRemaining == 0 }) ?? visible.first else { return nil }
            return (account, row)
        }
        let selected: (TokenMonitorEdgeDockAccountRow, TokenMonitorEdgeDockQuotaRow)?
        if providerID == "codex" && item.accountMode == .active {
            selected = candidates.first { $0.0.id == activeCodexAccountID }
        } else {
            selected = candidates.min { lhs, rhs in
                // A percentage is comparable only with another percentage;
                // credits remain a separate literal balance, never 0% or 100%.
                switch (lhs.1.percentRemaining, rhs.1.percentRemaining) {
                case (let left?, let right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
        }
        let severity = selected?.0.quotaRows
            .filter { $0.isAvailable && !$0.isStale }
            .compactMap(\.percentRemaining).min()
        let period = usageByProvider(usage, providerID: providerID)
        let sessions = item.showSessions ? recentSessions(usage, providerID: providerID, maximum: 3) : []
        return TokenMonitorEdgeDockCell(
            id: item.id, kind: .provider,
            title: matches.first?.providerName ?? providerID,
            providerID: providerID, iconID: providerID,
            headlineAccountID: selected?.0.id, headlineValueLabel: selected?.1.valueLabel,
            metric: nil, percentRemaining: selected?.1.percentRemaining,
            severityRemainingPercent: severity,
            isStale: accounts.contains { $0.isStale } || usage.isStale,
            isAvailable: selected != nil,
            tokenCount: item.showUsage ? period.today.tokens : nil,
            costUSD: item.showUsage ? period.today.cost : nil,
            byTool: [], byModel: [], liveRate: nil, accounts: accounts,
            sessions: sessions, sessionCount: item.showSessions ? sessions.count : nil,
            lastCollectedAt: usage.collectedAt,
            usageTodayTokens: item.showUsage ? period.today.tokens : nil,
            usageMonthTokens: item.showUsage ? period.month.tokens : nil,
            usageTodayCostUSD: item.showUsage ? period.today.cost : nil,
            usageMonthCostUSD: item.showUsage ? period.month.cost : nil,
            supportsLiveSessions: false
        )
    }

    private static func statCell(
        _ item: TokenMonitorEdgeDockItem,
        usage: TokenMonitorDashboardSnapshot,
        language: WidgetLanguage,
        now: Date,
        liveRateSample: TokenMonitorEdgeDockRateSample?
    ) -> TokenMonitorEdgeDockCell {
        let metric = item.metric ?? .allTime
        let result = periodResult(metric, usage: usage, language: language, now: now)
        let sessions =
            metric == .sessions
            ? recentSessions(usage, providerID: nil, maximum: 6, runningOnly: item.runningOnly)
            : []
        let hasSessionSource = usage.response?.payload["aggregate"]?["month"]?["sessions"]?.object != nil
        let available =
            metric == .sessions
            ? hasSessionSource
            : metric == .liveRate
                ? liveRateSample != nil
                : (result.tokens != nil || result.cost != nil)
        return TokenMonitorEdgeDockCell(
            id: item.id, kind: .stat, title: metric.title(language),
            providerID: nil, iconID: nil, headlineAccountID: nil,
            headlineValueLabel: nil, metric: metric, percentRemaining: nil,
            severityRemainingPercent: nil,
            isStale: usage.isStale, isAvailable: available,
            tokenCount: result.tokens, costUSD: result.cost,
            byTool: result.byTool, byModel: result.byModel,
            liveRate: metric == .liveRate ? liveRateSample : nil, accounts: [],
            sessions: sessions, sessionCount: metric == .sessions && hasSessionSource ? sessions.count : nil,
            lastCollectedAt: usage.collectedAt,
            usageTodayTokens: nil, usageMonthTokens: nil,
            usageTodayCostUSD: nil, usageMonthCostUSD: nil,
            supportsLiveSessions: false
        )
    }

    private struct PeriodResult {
        var tokens: Int64?
        var cost: Double?
        var byTool: [TokenMonitorEdgeDockRank] = []
        var byModel: [TokenMonitorEdgeDockRank] = []
    }

    private static func periodResult(
        _ metric: TokenMonitorEdgeDockItem.Metric,
        usage: TokenMonitorDashboardSnapshot,
        language: WidgetLanguage,
        now: Date
    ) -> PeriodResult {
        let nativePeriod: TokenMonitorPeriod
        let key: String
        switch metric {
        case .today:
            nativePeriod = .day
            key = "today"
        case .month:
            nativePeriod = .month
            key = "month"
        case .allTime:
            nativePeriod = .total
            key = "allTime"
        case .week, .last7, .last30:
            return derivedPeriod(metric, usage: usage, language: language, now: now)
        case .liveRate, .sessions:
            // Rate and sessions have their own sampled/history projection;
            // neither is a usage period total.
            return PeriodResult()
        }
        let tokens = usage.tokenCount(for: nativePeriod, now: now)
        let cost = usage.value(for: nativePeriod, metric: .cost, now: now)
        let aggregate = usage.response?.payload["aggregate"]?[key]
        return PeriodResult(
            tokens: tokens, cost: cost,
            byTool: tokens == nil ? [] : ranks(aggregate, byModel: false, total: tokens),
            byModel: tokens == nil ? [] : ranks(aggregate, byModel: true, total: tokens)
        )
    }

    private static func derivedPeriod(
        _ metric: TokenMonitorEdgeDockItem.Metric,
        usage: TokenMonitorDashboardSnapshot,
        language: WidgetLanguage,
        now: Date
    ) -> PeriodResult {
        // The local engine exposes the upstream History availability signal.
        // Hub snapshots have no equivalent proof; only their explicit days can
        // be counted, so absent Hub days remain unknown rather than zero.
        let historyAvailable: Bool
        if case .some(.bool(true)) = usage.response?.payload["usage"]?["historyAvailable"] {
            historyAvailable = true
        } else {
            historyAvailable = false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.locale
        calendar.timeZone = usage.timezone
        let today = calendar.startOfDay(for: now)
        let start: Date
        switch metric {
        case .week: start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        case .last7: start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .last30: start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        default: return PeriodResult()
        }
        let byDate = Dictionary(usage.days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        var tokens: Int64 = 0
        var cost = 0.0
        var knownTokens = true
        var knownCost = true
        var tools: [String: Int64] = [:]
        var models: [String: Int64] = [:]
        var date = start
        while date <= today {
            let row = byDate[dateKey(date, timezone: usage.timezone)]
            if let row {
                if row.coverage != .known || row.tokens == nil {
                    knownTokens = false
                } else if let count = row.tokens {
                    let (sum, overflow) = tokens.addingReportingOverflow(count)
                    if overflow { knownTokens = false } else { tokens = sum }
                    knownTokens = add(row.perClient, into: &tools) && knownTokens
                    knownTokens = add(row.perModel, into: &models) && knownTokens
                }
                if row.costCoverage != .known || row.cost == nil {
                    knownCost = false
                } else if let amount = row.cost, amount.isFinite, amount >= 0 {
                    cost += amount
                    if !cost.isFinite { knownCost = false }
                } else {
                    knownCost = false
                }
            } else if !historyAvailable {
                knownTokens = false
                knownCost = false
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        let total = knownTokens ? tokens : nil
        return PeriodResult(
            tokens: total, cost: knownCost ? cost : nil,
            byTool: total.map { ranks(tools, total: $0) } ?? [],
            byModel: total.map { ranks(models, total: $0) } ?? []
        )
    }

    private static func usageByProvider(
        _ usage: TokenMonitorDashboardSnapshot, providerID: String
    ) -> (today: (tokens: Int64?, cost: Double?), month: (tokens: Int64?, cost: Double?)) {
        func read(_ key: String) -> (tokens: Int64?, cost: Double?) {
            let period = usage.response?.payload["aggregate"]?[key]
            let clients = countMap(period?["clients"])
            let costs = costMap(period?["clientCosts"])
            let chosen = clients.filter { provider(forClient: $0.key) == providerID }
            let chosenCosts = costs.filter { provider(forClient: $0.key) == providerID }
            var total: Int64 = 0
            for value in chosen.values {
                let (sum, overflow) = total.addingReportingOverflow(value)
                if overflow { return (nil, nil) }
                total = sum
            }
            let amount = chosenCosts.values.reduce(0, +)
            return (
                chosen.isEmpty ? nil : total,
                chosenCosts.isEmpty || !amount.isFinite ? nil : amount
            )
        }
        return (read("today"), read("month"))
    }

    private static func provider(forClient client: String) -> String? {
        let id = client.lowercased()
        let provider = clientProviderOverrides[id] ?? id
        return providerOrder.contains(provider) ? provider : nil
    }

    private static func ranks(
        _ aggregate: TokenMonitorJSON?, byModel: Bool, total: Int64?
    ) -> [TokenMonitorEdgeDockRank] {
        let counts = countMap(aggregate?[byModel ? "models" : "clients"])
        let costs = costMap(aggregate?[byModel ? "modelCosts" : "clientCosts"])
        return ranks(counts, costs: costs, total: total)
    }

    private static func ranks(
        _ counts: [String: Int64], costs: [String: Double] = [:], total: Int64?
    ) -> [TokenMonitorEdgeDockRank] {
        var result = counts.map { key, value in
            TokenMonitorEdgeDockRank(
                id: key, tokens: value, costUSD: costs[key],
                share: total.flatMap { $0 > 0 ? Double(value) / Double($0) : nil }
            )
        }
        if let total {
            var attributed: Int64 = 0
            var overflow = false
            for count in counts.values {
                let (next, exceeded) = attributed.addingReportingOverflow(count)
                if exceeded {
                    overflow = true
                    break
                }
                attributed = next
            }
            if !overflow && attributed < total {
                let residual = total - attributed
                result.append(
                    TokenMonitorEdgeDockRank(
                        id: "unattributed", tokens: residual, costUSD: nil,
                        share: total > 0 ? Double(residual) / Double(total) : nil
                    ))
            }
        }
        return result.sorted {
            if $0.tokens != $1.tokens { return ($0.tokens ?? 0) > ($1.tokens ?? 0) }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    private static func countMap(_ node: TokenMonitorJSON?) -> [String: Int64] {
        (node?.object ?? [:]).compactMapValues { value in
            TokenMonitorDashboardSnapshot.integer(value)
                ?? TokenMonitorDashboardSnapshot.integer(value["tokens"])
                ?? TokenMonitorDashboardSnapshot.integer(value["count"])
        }
    }

    private static func costMap(_ node: TokenMonitorJSON?) -> [String: Double] {
        (node?.object ?? [:]).compactMapValues { value in
            let result = value.double ?? value["cost"]?.double
            guard let result, result.isFinite, result >= 0 else { return nil }
            return result
        }
    }

    private static func add(_ values: [String: Int64], into totals: inout [String: Int64]) -> Bool {
        for (key, value) in values {
            let (sum, overflow) = (totals[key] ?? 0).addingReportingOverflow(value)
            if overflow { return false }
            totals[key] = sum
        }
        return true
    }

    private static func dateKey(_ date: Date, timezone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func knownValue(_ value: TokenMonitorFloatingBubbleMetric.Value) -> Bool {
        switch value {
        case .percentRemaining(let amount): return amount.isFinite && (0...100).contains(amount)
        case .unlimitedCredits: return true
        case .text(let text): return !text.isEmpty
        case .unknown: return false
        }
    }

    private static func recentSessions(
        _ usage: TokenMonitorDashboardSnapshot,
        providerID: String?, maximum: Int,
        runningOnly: Bool = false
    ) -> [TokenMonitorEdgeDockSessionRow] {
        guard let response = usage.response else { return [] }
        var source: [String: TokenMonitorJSON] = [:]
        for period in ["month", "today"] {
            for (key, value) in response.payload["aggregate"]?[period]?["sessions"]?.object ?? [:]
            where source[key] == nil {
                source[key] = value
            }
        }
        let collectedAt = usage.collectedAt ?? .distantPast
        return source.compactMap { key, value -> TokenMonitorEdgeDockSessionRow? in
            guard value["sessionKind"]?.string != "background-review",
                let lastUsed = (value["lastUsedAt"]?.string ?? value["startedAt"]?.string)
                    .flatMap(TokenMonitorResponse.timestamp),
                let client = value["client"]?.string, !client.isEmpty,
                providerID == nil || provider(forClient: client) == providerID
            else { return nil }
            let ended: Bool
            if case .some(.bool(true)) = value["turnEnded"] { ended = true } else { ended = false }
            let archived = ["archived", "deleted", "sourceDeleted"].contains { field in
                if case .some(.bool(true)) = value[field] { return true }
                return false
            }
            if runningOnly && (archived || ended || collectedAt.timeIntervalSince(lastUsed) > 600) {
                return nil
            }
            let models = countMap(value["models"])
            let model = models.max { $0.value < $1.value }?.key
            let amount = value["costUsd"]?.double
            return TokenMonitorEdgeDockSessionRow(
                id: key, clientID: client, modelID: model,
                tokenCount: TokenMonitorDashboardSnapshot.integer(value["totalTokens"]),
                costUSD: amount.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                lastUsedAt: lastUsed, turnEnded: ended
            )
        }
        .sorted { $0.lastUsedAt > $1.lastUsedAt }
        .prefix(maximum).map { $0 }
    }
}
