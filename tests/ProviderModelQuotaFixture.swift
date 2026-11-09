import Foundation

@main
struct ProviderModelQuotaFixture {
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
    }

    static func account(provider: String = "antigravity", models: [String] = [], details: [[String: Any]]? = nil,
                        windows: [[String: Any]]? = nil, observed: Int64? = Int64(now.timeIntervalSince1970), enabled: Bool = true) throws -> AntigravityProxyAccount {
        var value: [String: Any] = [
            "id": (provider == "antigravity" ? "ag" : provider) + "-" + String(repeating: "a", count: 32),
            "provider": provider, "maskedIdentity": "synthetic***", "generation": "synthetic-generation-0001",
            "enabled": enabled, "concurrencyLimit": 1, "inFlight": 0, "state": "ready", "models": models,
        ]
        if let details { value["modelDetails"] = details }
        if let windows { value["sharedWindows"] = windows }
        if let observed { value["modelDetailsUpdatedAt"] = observed }
        return try JSONDecoder().decode(AntigravityProxyAccount.self, from: JSONSerialization.data(withJSONObject: value))
    }

    static func model(_ id: String, _ remaining: Double? = nil, name: String? = nil, reset: Int64? = nil, disabled: Bool? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "displayName": name ?? id]
        if let remaining { value["remainingFraction"] = remaining }
        if let reset { value["resetAt"] = reset }
        if let disabled { value["disabled"] = disabled }
        return value
    }

    static func window(_ id: String, pool: String = "Gemini", seconds: Int64, members: [String]? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "pool": pool, "label": seconds == 18000 ? "5 hours" : "7 days", "remainingFraction": 0.4, "windowSeconds": seconds]
        if let members { value["modelIDs"] = members }
        return value
    }

    static func rows(_ account: AntigravityProxyAccount, running: Bool = true) -> [ProviderQuotaDisplayRow] {
        ProviderModelQuotaPresentation.models(account: account, isRunning: running, now: now)
    }

    static func main() throws {
        let future = Int64(now.timeIntervalSince1970) + 3600
        let reported = try account(models: ["gemini-live", "gemini-disabled", "catalog-only"], details: [
            model("gemini-empty", 0, name: "Gemini empty", reset: future),
            model("gemini-live", 0.8, name: "Gemini Live (High)", reset: future),
            model("gemini-unknown"), model("gemini-disabled", 0.7, disabled: true),
            model("chat_internal", 1), model("tab_internal", 1),
        ])
        let shown = rows(reported)
        check(shown.map(\.id) == ["gemini-empty", "gemini-live", "gemini-unknown", "catalog-only"], "real catalog order and exhausted models are retained")
        check(shown[0].remainingPercent == 0, "zero is a measured empty ring")
        check(shown[1].title == "Gemini Live (High)" && shown[1].modelID == "gemini-live", "friendly names keep the launch ID")
        check(shown[1].remainingPercent == 80, "remaining fraction is not inverted twice")
        check(shown[2].remainingPercent == nil && shown[2].status == .unknown, "missing allowance is unknown")
        check(shown[3].remainingPercent == nil, "catalog-only ID has no invented allowance")
        check(!reported.models.contains("gemini-empty"), "displaying exhausted models does not widen admission")
        check(shown.allSatisfy { !$0.id.hasPrefix("family:") }, "picker retains exact variants")

        let legacy = try account(models: ["legacy-model"], observed: nil)
        check(rows(legacy).map(\.id) == ["legacy-model"], "legacy helper still supplies model names")
        check(rows(legacy)[0].remainingPercent == nil, "legacy helper never supplies a fake percentage")
        let withoutDate = try account(details: [model("gemini-live", 1)], observed: nil)
        check(rows(withoutDate)[0].status == .unknown, "undated observation is not fresh")
        let stale = try account(details: [model("gemini-live", 1)], observed: Int64(now.timeIntervalSince1970) - 901)
        check(rows(stale)[0].status == .stale && rows(stale)[0].remainingPercent == nil, "stale reading has an empty unknown ring")
        let futureDated = try account(details: [model("gemini-live", 1)], observed: Int64(now.timeIntervalSince1970) + 6)
        check(rows(futureDated)[0].status == .stale, "future observation cannot pass freshness")
        let expired = try account(details: [model("gemini-live", 0, reset: Int64(now.timeIntervalSince1970) - 1)])
        check(rows(expired)[0].status == .expired && rows(expired)[0].remainingPercent == nil, "past reset does not refill the allowance")
        check(rows(reported, running: false)[0].status == .stopped && rows(reported, running: false)[0].remainingPercent == nil, "stopped helper cannot show a fresh percent")
        let disabledAccount = try account(details: [model("gemini-live", 0.8)], enabled: false)
        check(rows(disabledAccount)[0].status == .stopped, "disabled account does not imply refresh")

        let other = try account(details: [model("gemini-live", 0.1)])
        check(rows(other)[0].remainingPercent == 10 && shown[1].remainingPercent == 80, "same model on two accounts stays separate")
        check(rows(other).count == 1, "one account never borrows the other's catalog")

        let familyAccount = try account(details: [
            model("gpt-oss-20", 0.6), model("claude-one", 0.4),
            model("gemini-one", 0.8, reset: future), model("gemini-two", 0.2, reset: future),
            model("gemini-three", 0.2, reset: future - 60),
        ])
        let families = ProviderModelQuotaPresentation.families(rows(familyAccount))
        check(families.map(\.title) == ["Gemini", "claude-one", "gpt-oss-20"], "Gemini and Claude precede other families")
        check(families[0].remainingPercent == 20, "family uses the tightest reading, not sum or average")
        check(families[0].resetsAt == Date(timeIntervalSince1970: TimeInterval(future - 60)), "tied readings use the first reset")
        check(families[0].members.count == 3 && families[0].isFamily, "family keeps every real variant")
        let unknownFamily = ProviderModelQuotaPresentation.families(Array(shown.prefix(3)))
        check(unknownFamily[0].remainingPercent == 0 && unknownFamily[0].unknownCount == 1, "mixed family keeps tightest known share and reports unknown members")
        let allUnknown = ProviderModelQuotaPresentation.families([
            .init(id: "gemini-a", title: "Gemini A", modelID: "gemini-a"),
            .init(id: "gemini-b", title: "Gemini B", modelID: "gemini-b"),
        ])
        check(allUnknown[0].remainingPercent == nil && allUnknown[0].unknownCount == 2, "all unknown family stays empty")

        let week = try account(details: [model("gemini-live", 0.8)], windows: [window("week", seconds: 604800, members: ["gemini-live"])])
        let weekRows = rows(week)
        let weekShared = ProviderModelQuotaPresentation.shared(account: week, isRunning: true, now: now)
        let weekSummary = ProviderModelQuotaPresentation.summary(account: week, models: weekRows, shared: weekShared)
        check(weekSummary.count == 2 && weekSummary.contains { $0.modelID == "gemini-live" }, "weekly-only pool retains per-model five-hour reading")
        check(weekSummary.first?.modelID == "gemini-live", "models' five hours precede the shared week")
        let five = try account(details: [model("gemini-live", 0.8), model("claude-one", 0.7)], windows: [window("five", seconds: 18000, members: ["gemini-live"])])
        let fiveSummary = ProviderModelQuotaPresentation.summary(account: five, models: rows(five), shared: ProviderModelQuotaPresentation.shared(account: five, isRunning: true, now: now))
        check(fiveSummary.count == 2 && !fiveSummary.contains { $0.modelID == "gemini-live" }, "confirmed same-span pool replaces only its member")
        check(fiveSummary.contains { $0.modelID == "claude-one" }, "unrelated model remains")
        var familyWindow = window("family", seconds: 18000, members: ["gemini-main"])
        familyWindow["remainingFraction"] = 0.8
        let separate = try account(details: [
            model("gemini-main", 0.8, name: "Gemini Main", reset: future),
            model("gemini-argon-high", 0.3, name: "Gemini Argon (High)", reset: future + 86400),
            model("gemini-argon-low", 0.3, name: "Gemini Argon (Low)", reset: future + 86400),
        ], windows: [familyWindow])
        let separateOverview = ProviderModelQuotaPresentation.summary(account: separate, models: rows(separate), shared: ProviderModelQuotaPresentation.shared(account: separate, isRunning: true, now: now))
        check(separateOverview.contains { $0.title == "Gemini Argon (High)" && $0.remainingPercent == 30 }, "independent known model keeps its name beside a family pool")
        check(separateOverview.contains { $0.modelID == "gemini-argon-low" } && !separateOverview.contains { $0.id == "family:Gemini" }, "independent variants are not folded back into the shared family")
        let unknownMembership = try account(details: [model("gemini-live", 0.8)], windows: [window("five", seconds: 18000)])
        check(ProviderModelQuotaPresentation.summary(account: unknownMembership, models: rows(unknownMembership), shared: ProviderModelQuotaPresentation.shared(account: unknownMembership, isRunning: true, now: now)).count == 2, "unknown membership is never inferred from a family name")

        let ordered = try account(windows: [
            window("own", pool: "Gemini 4 Argon", seconds: 604800),
            window("claude", pool: "Claude & GPT", seconds: 18000),
            window("gemini-week", seconds: 604800), window("gemini-five", seconds: 18000),
        ])
        let orderedRows = ProviderModelQuotaPresentation.shared(account: ordered, isRunning: true, now: now)
        check(orderedRows.map(\.id) == ["shared:gemini-five", "shared:gemini-week", "shared:claude", "shared:own"], "shared families then independent model pools, shorter windows first")
        check(orderedRows.allSatisfy(\.isShared), "shared allowances are explicitly distinct from model allowances")
        let orderedOverview = ProviderModelQuotaPresentation.overview(models: rows(familyAccount), shared: Array(orderedRows.reversed()))
        check(orderedOverview.last?.id == "shared:own", "independent model pools follow remaining family readings")
        check(orderedOverview.first?.id == "shared:gemini-five", "generic local and pool overview uses the same pool order")

        var countedWindow = window("plan", pool: "Kimi", seconds: 18000)
        countedWindow["remainingAmount"] = 40.0
        countedWindow["totalAmount"] = 100.0
        for provider in ["kimi", "xai", "claude"] {
            let account = try account(provider: provider, models: ["catalog-model"], windows: [countedWindow])
            let shared = ProviderModelQuotaPresentation.shared(account: account, isRunning: true, now: now)
            check(rows(account)[0].remainingPercent == nil, "shared allowance is not copied into a model's percentage")
            check(ProviderModelQuotaPresentation.summary(account: account, models: rows(account), shared: shared) == shared, "all supported providers use shared windows unchanged")
            check(shared[0].remainingAmount == 40 && shared[0].totalAmount == 100 && shared[0].unit == nil, "counts remain counts without fabricated units")
        }
        for invalid in [Double.nan, .infinity, -0.1, 1.1] {
            let row = ProviderQuotaDisplayRow(id: "invalid", title: "Synthetic", remainingFraction: invalid, status: .current)
            check(row.remainingPercent == nil, "invalid generic reading cannot paint a percent")
        }
        print("provider-model-quota-fixture: \(checks) checks passed")
    }
}
