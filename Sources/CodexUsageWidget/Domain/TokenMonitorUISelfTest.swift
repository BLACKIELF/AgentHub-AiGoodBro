import AppKit
import Foundation
import WebKit

@MainActor
enum TokenMonitorUISelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        reproduceFloatingBubble(expect: expect)
        expect(TokenMonitorEdgeDockNativeGeometrySelfTest.run(), "native Edge Dock keeps the rail and detail card inside right, left, dragged and short multi-display work areas")
        expect(TokenMonitorEdgeDockSelfTest.run(), "edge dock composition, exact data and sampled rate")
        let dock = TokenMonitorEdgeDockController()
        let dockCells = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.limit("codex"), .limit("grok"), .proxy()]),
            quotaSources: [], usage: TokenMonitorDashboardSnapshot(response: nil), language: .en)
        var usageOpens = 0
        var proxyOpens = 0
        var dashboardOpens = 0
        // Disabled preferences exercise the actual click routing without
        // creating windows, collecting data or starting the desktop runtime.
        dock.configure(
            preferences: .init(), cells: dockCells, language: .en,
            onPreferencesChange: { _ in }, onOpenDashboard: { dashboardOpens += 1 },
            onOpenUsageOverview: { usageOpens += 1 }, onOpenProxy: { proxyOpens += 1 })
        dock.activateCell(at: 0)
        dock.activateCell(at: 1)
        dock.activateCell(at: 2)
        dock.activateCell(at: 99)
        expect(
            usageOpens == 1 && proxyOpens == 1 && dashboardOpens == 0,
            "Codex click opens the existing usage overview; Grok, proxy and invalid indexes keep their own routes")
        dock.shutdown()
        expect(TokenMonitorEdgeDockController.navigationSelfTest(), "GPT and both proxy-settings entries dismiss the hover card until pointer re-entry")
        expect(TokenMonitorHostSelfTest.run(), "embedded desktop IPC and account identity boundaries")
        reproduceNavigation(expect: expect)
        reproduceAvatars(expect: expect)
        reproduceIcons(expect: expect)
        reproduceMenuAndModel(expect: expect)
        reproduceResponsiveTokenAndAccountLayouts(expect: expect)
        reproduceTokenCalendarSemantics(expect: expect)
        reproduceLocalUsageCoverage(expect: expect)
        reproduceTrendRendererBoundaries(expect: expect)
        reproduceResetAnnouncementPresentation(expect: expect)
        reproduceResetCountdown(expect: expect)
        reproduceCodexResetExpiryDisclosure(expect: expect)
        reproduceLocalCLIQuotaPresentation(expect: expect)
        expect(
            TokenMonitorNativePreviewRenderer.fixtureSelfTest(),
            "native Token Monitor preview fixtures preserve normal, empty and Int64-max snapshots without account data"
        )
        expect(PublicResetForecastSelfTest.persistenceSelfTest(), "forecast withdrawal commits atomically and survives restart; failed writes preserve explicitly cached state")
        let collecting = TokenMonitorDashboardSnapshot(state: .init(phase: .loading))
        let collectionFailed = TokenMonitorDashboardSnapshot(state: .init(phase: .failed))
        expect(collecting.localizedStatusText(.zh)?.contains("历史用量") == true && collecting.response == nil, "first baseline is loading, not zero usage")
        expect(collectionFailed.localizedStatusText(.en)?.contains("retry") == true && collectionFailed.response == nil, "failed baseline prompts retry without inventing usage")
        let quotaNow = Date()
        let expiresIn48Hours = quotaNow.addingTimeInterval(48 * 3600)
        func expiring(_ expiry: Date, fetchedAt: Date = quotaNow, succeeded: Bool = true) -> Bool {
            ResetCardPresentation.codexIsExpiring(available: 1, expiries: [expiry], fetchedAt: fetchedAt, readSucceeded: succeeded, now: quotaNow)
        }
        expect(expiring(expiresIn48Hours), "48-hour boundary is highlighted")
        expect(!expiring(expiresIn48Hours.addingTimeInterval(1)), "more than 48 hours is not highlighted")
        expect(!expiring(quotaNow), "already expired is not an upcoming expiry")
        expect(!expiring(expiresIn48Hours, fetchedAt: quotaNow.addingTimeInterval(-301)), "stale reset evidence does not highlight")
        expect(!expiring(expiresIn48Hours, succeeded: false), "failed reset evidence does not highlight")
        let laterExpiry = quotaNow.addingTimeInterval(72 * 3600)
        expect(
            ResetCardPresentation.orderedExpiries([laterExpiry, quotaNow, expiresIn48Hours, expiresIn48Hours], now: quotaNow)
                == [expiresIn48Hours, expiresIn48Hours, laterExpiry, quotaNow], "expiry list preserves separate cards, puts nearest upcoming first and expired records last")
        var quotaProfile = CodexProfile(
            id: "quota-fixture", name: "Fixture", codexHomePath: "", isSystemProfile: false,
            createdAt: quotaNow,
            lastSnapshot: CodexAccountSnapshot(
                accountType: "chatgpt", planType: "plus", email: nil,
                limitId: nil, limitName: nil, fiveHour: nil, sevenDay: nil, monthly: nil,
                fetchedAt: quotaNow, appServerVersion: nil))
        let activeWindow = CodexQuotaWindowSnapshot(RateWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: quotaNow.addingTimeInterval(3600)))
        let expiredWindow = CodexQuotaWindowSnapshot(RateWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: quotaNow.addingTimeInterval(-1)))
        expect(AccountInformationView.shouldShowQuota(activeWindow, profile: quotaProfile, now: quotaNow), "fresh exhausted allowance is still an accurate zero")
        expect(!AccountInformationView.shouldShowQuota(expiredWindow, profile: quotaProfile, now: quotaNow), "expired exhausted allowance is not displayed as a current zero")
        expect(!AccountInformationView.shouldShowQuota(activeWindow, profile: quotaProfile, now: quotaNow.addingTimeInterval(901)), "stale allowance loses actionable percentages")
        quotaProfile.lastQuotaReadFailureAt = quotaNow.addingTimeInterval(1)
        expect(!AccountInformationView.shouldShowQuota(activeWindow, profile: quotaProfile, now: quotaNow), "a failed newer read does not make the old quota current")
        reproducePublicResetHistory(expect: expect)
        reproduceResetCreditSummary(expect: expect)
        reproduceResetDashboardLayout(expect: expect)
        let quotaPair = LocalCLIQuotaWindowDetails.percentages(usedPercent: 23.5, language: .en)
        expect(quotaPair.used == "23.5%" && quotaPair.remaining == "76.5%", "used and remaining quota preserve precision and total 100 percent")
        let emptyQuota = LocalCLIQuotaWindowDetails.percentages(usedPercent: .nan, language: .en)
        expect(emptyQuota.used == "—" && emptyQuota.remaining == "—", "invalid quota is not presented as zero or full availability")
        expect(LocalCLIQuotaWindowDetails.percentages(usedPercent: 100, language: .zh).remaining == "0%", "exhausted quota remains zero")
        expect(ResetCardPresentation.savedOrder(["a", "b", "c"], pinnedAccountID: nil) == ["a", "b", "c"], "account order remains saved without a pin")
        expect(ResetCardPresentation.savedOrder(["a", "b", "c"], pinnedAccountID: "c") == ["c", "a", "b"], "only an explicit pin changes presentation order")
        expect(HomeMessageInboxStore.visibleAnnouncementLimit == 3, "homepage shows only three reset messages")
        expect(PublisherMessageSelfTest.run(), "publisher announcements respect delivery and URL boundaries")
        expect(PublisherMessagePublishingSelfTest.run(), "only the verified owner publishes; conflicts and retries preserve messages")
        expect(OnboardingModesSelfTest.run(), "onboarding modes, 3pt track and skip/back fixtures")

        if failures.isEmpty {
            print("token-monitor UI self-test passed: floating geometry, navigation, avatars, icons, menu/model, responsive totals, reset history, chart states, announcements")
            return true
        }
        failures.forEach { print("token-monitor UI self-test failed: \($0)") }
        return false
    }

    private static func reproduceCodexResetExpiryDisclosure(expect: (Bool, String) -> Void) {
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-12-31T15:00:00Z")!
        let first = now.addingTimeInterval(3_600)
        let second = now.addingTimeInterval(86_400)
        let third = now.addingTimeInterval(172_800)
        let past = now.addingTimeInterval(-3_600)
        func disclosure(
            _ count: Int?, _ dates: [Date], fetchedAt: Date? = nil,
            succeeded: Bool = true, language: WidgetLanguage = .zh
        ) -> ResetCardPresentation.ExpiryDisclosure {
            ResetCardPresentation.expiryDisclosure(
                count: count, expiries: dates, fetchedAt: fetchedAt ?? now,
                readSucceeded: succeeded, now: now, language: language)
        }
        func dateLines(_ text: String) -> [String] {
            text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("2026-") || $0.hasPrefix("2027-") }
        }
        let empty = disclosure(0, [])
        expect(empty.inlineText == nil && empty.tooltip.contains("没有可用重置卡"), "confirmed zero reset cards keeps count and has no fabricated expiry")
        let one = disclosure(1, [first])
        expect(one.inlineText == "2027-01-01 00:00 北京时间" && dateLines(one.tooltip) == ["2027-01-01 00:00"], "one card crosses year in explicitly Beijing time with full year in hover")
        let two = disclosure(2, [second, first])
        expect(two.inlineText == "2027-01-01 00:00 · 2027-01-01 23:00 北京时间", "two unsorted cards render both nearest dates and times")
        let three = disclosure(3, [third, first, second])
        expect(three.inlineText == two.inlineText && dateLines(three.tooltip) == ["2027-01-01 00:00", "2027-01-01 23:00", "2027-01-02 23:00"], "three cards show exactly two inline dates and all three ordered hover dates")
        expect(three.tooltip.contains("UTC+8") && !three.inlineText!.contains("2027-01-02"), "third future expiry is not accidentally appended inline")
        let duplicate = disclosure(3, [second, first, first])
        expect(duplicate.inlineText == "2027-01-01 00:00 · 2027-01-01 00:00 北京时间" && dateLines(duplicate.tooltip).count == 3,
            "separate cards with identical expiry keep duplicate inline and hover entries")
        let missing = disclosure(3, [first])
        expect(missing.inlineText == one.inlineText && missing.tooltip.contains("另 2 张未提供到期时间"), "partial expiry evidence does not repeat one date to fill count")
        expect(disclosure(2, []).inlineText == nil && disclosure(2, []).tooltip.contains("另 2 张未提供到期时间"), "known positive count with no dates stays explicitly unknown")
        let mixed = disclosure(3, [past, third, first])
        expect(mixed.inlineText == "2027-01-01 00:00 · 2027-01-02 23:00 北京时间" && dateLines(mixed.tooltip).last == "2026-12-31 22:00（已过记录日期）",
            "expired record remains labeled in hover but never displaces future inline entries")
        expect(disclosure(1, [now]).inlineText == nil && disclosure(1, [now]).tooltip.contains("已过记录日期"), "expiry equal to now is expired, not upcoming")
        let invalid = disclosure(3, [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), first])
        expect(invalid == missing, "nonfinite date values are ignored without inventing two missing card expiries")
        let unknown = disclosure(nil, [first])
        expect(unknown.inlineText?.hasPrefix("记录 ") == true && unknown.tooltip.contains("可用数量未确认"), "unknown count does not promote record dates to available cards")
        expect(disclosure(-1, []).tooltip.contains("可用数量未确认"), "negative count is explicitly unconfirmed")
        let mismatch = disclosure(1, [second, first])
        expect(mismatch.inlineText?.hasPrefix("记录 ") == true && mismatch.tooltip.contains("数量与日期记录不一致"), "extra recorded dates disclose count mismatch")
        expect(disclosure(0, [first]).tooltip.contains("数量与日期记录不一致"), "zero count with a recorded future expiry is disclosed as inconsistent")
        let stale = disclosure(3, [third, second, first], fetchedAt: now.addingTimeInterval(-301))
        expect(stale.inlineText?.hasPrefix("记录 ") == true && stale.tooltip.contains("待刷新") && dateLines(stale.tooltip).count == 3, "stale snapshot keeps historical dates and visible refresh caveat")
        expect(disclosure(3, [third, second, first], fetchedAt: now.addingTimeInterval(-300)) == three, "exact five-minute freshness boundary stays current")
        let failed = disclosure(3, [third, second, first], succeeded: false)
        expect(failed.inlineText?.hasPrefix("记录 ") == true && failed.tooltip.contains("读取未成功") && dateLines(failed.tooltip).count == 3, "failed read retains known records with failure caveat")
        expect(disclosure(1, [first], fetchedAt: now.addingTimeInterval(1)).tooltip.contains("待刷新"), "future fetchedAt is not accepted as fresh")
        let noFetchedAt = ResetCardPresentation.expiryDisclosure(count: 1, expiries: [first], fetchedAt: nil, readSucceeded: true, now: now, language: .zh)
        expect(noFetchedAt.tooltip.contains("待刷新"), "missing fetch evidence stays stale")
        let sameYear = ResetCardPresentation.expiryDisclosure(count: 1, expiries: [second], fetchedAt: first, readSucceeded: true, now: first, language: .zh)
        expect(sameYear.inlineText == "01-01 23:00 北京时间", "same-year inline dates omit redundant year while hover preserves it")
        let english = disclosure(3, [third, first, second], language: .en)
        expect(english.inlineText == "2027-01-01 00:00 · 2027-01-01 23:00 UTC+8" && english.tooltip.contains("Beijing time (UTC+8)"), "English uses the same explicit timezone and full hover dates")
        // System timezone changes cannot change disclosure; no global timezone is mutated.
        let utcHour = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: first).hour
        let pacificHour = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "America/Los_Angeles")!, from: first).hour
        expect(utcHour != 0 && pacificHour != 0 && one.inlineText == "2027-01-01 00:00 北京时间", "expiry projection uses Beijing rather than UTC or Pacific local hour")
    }

    private static func reproduceLocalCLIQuotaPresentation(expect: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func result(balance: Double?, currency: String? = nil, code: String? = nil) -> LocalCLIQuotaResult {
            LocalCLIQuotaResult(
                state: .unsupported, fetchedAt: now, maskedIdentity: nil, identityFingerprint: nil,
                planLabel: nil, windows: [], balance: balance, balanceCurrency: currency,
                sourceLabel: "Fixture", messageCode: code, periodResetsAt: now.addingTimeInterval(3_600))
        }
        let zero = result(balance: 0, code: "local_cli_usage_not_reported")
        expect(LocalCLIAccountPresentation.balanceTitle(kind: .grok, language: .zh) == "购入余额", "Grok credits are identified as purchased balance, not points")
        expect(LocalCLIAccountPresentation.balanceText(kind: .grok, result: zero, language: .en) == "0 USD", "a confirmed zero purchased balance stays visible with its currency")
        expect(LocalCLIAccountPresentation.balanceText(kind: .grok, result: result(balance: nil), language: .en) == nil, "missing balance is never replaced with zero")
        expect(LocalCLIAccountPresentation.balanceText(kind: .grok, result: result(balance: .nan), language: .en) == nil, "invalid balance is never displayed as a number")
        expect(
            LocalCLIAccountPresentation.balanceText(kind: .kimi, result: result(balance: 12.5, currency: "CNY"), language: .en) == "12.5 CNY",
            "known provider currency is preserved")
        expect(zero.windows.isEmpty && zero.periodResetsAt != nil, "a reset boundary does not require a fabricated quota window")
        expect(LocalCLIReadiness.resolve(installed: true, result: zero) != .available, "balance and reset metadata do not promote unsupported quota to available")
        let missingUsage = LocalCLIAccountPresentation.quotaExplanation(kind: .grok, result: zero, language: .zh)
        expect(missingUsage?.contains("官方未提供") == true && missingUsage?.contains("登录") == false, "missing percentages do not become a login failure")
        let goCodes = ["local_cli_opencode_go_not_connected", "local_cli_upstream_provider_missing", "local_cli_upstream_unsupported_go_plan"]
        let explanations = goCodes.compactMap {
            LocalCLIAccountPresentation.quotaExplanation(kind: .openCode, result: result(balance: nil, code: $0), language: .zh)
        }
        expect(explanations.count == goCodes.count && Set(explanations).count == 1, "native and upstream OpenCode Go missing-provider states have one explanation")
        expect(explanations.first?.contains("其他服务商") == true, "OpenCode Go availability never stands in for every provider's login or balance")
    }

    private static func reproduceResetCountdown(expect: (Bool, String) -> Void) {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func countdown(_ seconds: TimeInterval, now: Date? = nil, kind: ResetCountdownPresentation.Kind = .publicForecast, language: WidgetLanguage = .zh) -> String {
            ResetCountdownPresentation.label(deadline: start.addingTimeInterval(seconds), now: now ?? start, kind: kind, language: language)
        }
        expect(countdown(90_061) == "预计重置还有 1 天 01:01:01", "countdown includes days, hours, minutes and seconds")
        expect(countdown(90_061, language: .en) == "Expected reset in 1d 01:01:01", "English countdown retains day precision")
        expect(countdown(60.1) == "预计重置还有 00:01:01", "fractional seconds do not report zero early")
        expect(countdown(0.1) == "预计重置还有 00:00:01", "last fraction of a second is still pending")
        expect(countdown(0).contains("等待来源确认"), "deadline never claims public delivery")
        expect(countdown(-10, kind: .accountWindow).contains("等待额度更新"), "expired account window never implies restored quota")
        expect(countdown(3_661, now: start.addingTimeInterval(3_600)) == "预计重置还有 00:01:01", "sleep or missed ticks cannot accumulate drift")
        expect(countdown(60, now: start.addingTimeInterval(-60)) == "预计重置还有 00:02:00", "clock corrections rederive the remaining duration")
        expect(countdown(.infinity).contains("待公开来源公布"), "invalid timestamps do not trap or create a fake timer")
        expect(ResetCountdownPresentation.label(deadline: nil, now: start, kind: .accountWindow, language: .zh) == "重置时间未知", "missing reset time stays unknown")
    }

    private static func reproduceResetDashboardLayout(expect: (Bool, String) -> Void) {
        // Regression: the production dashboard has two children after calendar removal.
        // A mismatched count previously returned no frames and a zero height.
        for width: CGFloat in [1, 320, 619, 620, 820, 939, 940, 1600] {
            for count in 0...4 {
                let frames = ResetDashboardLayout.frames(width: width, count: count) { index, proposedWidth in
                    CGFloat(index + 1) * 80 + (proposedWidth < 300 ? 140 : 0)
                }
                expect(frames.count == count, "every reset dashboard child gets a frame")
                for (index, frame) in frames.enumerated() {
                    expect(frame.height > 0 && frame.width > 0, "reset dashboard never collapses visible content to zero")
                    expect(frame.minX >= 0 && frame.maxX <= width + 0.01, "reset dashboard stays within its proposed width")
                    for other in frames.dropFirst(index + 1) {
                        expect(!frame.intersects(other), "announcement and account windows never overlap")
                    }
                }
            }
        }
        expect(Set(HomeSection.allCases.map(\.storageKey)).count == HomeSection.allCases.count, "home section preferences are independent")
    }

    private static func reproduceResetCreditSummary(expect: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func profile(
            _ id: String, account: String?, count: Int?, age: TimeInterval = 0, credit: String? = nil, unlimited: Bool? = nil,
            plan: String? = "plus", multiplier: Int? = nil, verified: Bool? = true
        ) -> CodexProfile {
            CodexProfile(
                id: id, name: "Fixture", codexHomePath: "", isSystemProfile: false, createdAt: now,
                lastSnapshot: CodexAccountSnapshot(
                    accountType: "chatgpt", planType: plan, email: nil,
                    accountID: account, limitId: "codex", limitName: nil, fiveHour: nil, sevenDay: nil, monthly: nil,
                    availableResetCredits: count, creditBalance: credit, creditBalanceUnlimited: unlimited,
                    fetchedAt: now.addingTimeInterval(-age), appServerVersion: nil, quotaReadSucceeded: verified),
                proTierMultiplier: multiplier)
        }
        let first = profile("one", account: "a", count: 2, age: 30)
        let mirror = profile("mirror", account: "a", count: 3)
        let second = profile("two", account: "b", count: 1, age: 60)
        let summary = ResetCreditLocalSummary(profiles: [first, mirror, second], now: now)
        expect(summary.availableCards == 4 && summary.accountsWithCards == 2, "mirrors count once while distinct verified account IDs remain separate")
        expect(summary.checkedAt == now.addingTimeInterval(-60), "combined balance freshness uses the oldest included account")
        expect(summary.latestIncrease == nil, "existing balances never invent receipt history")
        expect(summary.availableCardsByPlan == ["PLUS": 4], "mirrored reset-card balances contribute to their newest plan once")
        let planProfiles = [
            profile("pro", account: "pro", count: 1, plan: "pro", multiplier: 20),
            profile("plus-one", account: "plus-one", count: 20),
            profile("plus-two", account: "plus-two", count: 4),
            profile("zero", account: "zero", count: 0, plan: "free"),
        ]
        let planSummary = ResetCreditLocalSummary(profiles: planProfiles, now: now)
        expect(
            planSummary.availableCards == 25 && planSummary.availableCardsByPlan == ["PRO 20x": 1, "PLUS": 24],
            "plan breakdown sums reset cards across distinct accounts and omits confirmed zero buckets")
        expect(planSummary.planBreakdown(.zh) == "Pro 20倍 ×1、Plus ×24", "Chinese plan breakdown identifies the Pro tier and actual card counts")
        expect(planSummary.planBreakdown(.en) == "Pro 20x ×1 · Plus ×24", "English plan breakdown preserves plan tiers and actual card counts")
        expect(
            ResetCreditLocalSummary(profiles: Array(planProfiles.reversed()), now: now).planBreakdown(.zh) == planSummary.planBreakdown(.zh),
            "plan breakdown ordering is independent of profile order")
        let upgraded = ResetCreditLocalSummary(
            profiles: [profile("old-plan", account: "mirror-plan", count: 99, age: 30, plan: "pro", multiplier: 20), profile("new-plan", account: "mirror-plan", count: 2)],
            now: now)
        expect(upgraded.availableCardsByPlan == ["PLUS": 2], "the plan and card balance come from the same newest verified snapshot")
        let unknownPlan = ResetCreditLocalSummary(
            profiles: [profile("old-plan", account: "unknown-plan", count: 99, age: 30), profile("new-plan", account: "unknown-plan", count: 3, plan: nil)], now: now)
        expect(
            unknownPlan.availableCards == 3 && unknownPlan.availableCardsByPlan == ["": 3] && !unknownPlan.hasUnknownAccounts,
            "verified cards with unknown plans stay in the total without making their account balance unknown")
        expect(unknownPlan.planBreakdown(.zh) == "套餐未知 ×3" && unknownPlan.planBreakdown(.en) == "Unknown plan ×3", "a missing newest plan never borrows an older mirror's plan")
        let fiveTimes = ResetCreditLocalSummary(profiles: [profile("lite", account: "lite", count: 2, plan: "prolite")], now: now)
        expect(fiveTimes.planBreakdown(.zh) == "Pro 5倍 ×2", "Pro Lite uses the existing verified five-times tier label")
        let zeroCards = ResetCreditLocalSummary(profiles: [profile("zero", account: "zero", count: 0)], now: now)
        expect(
            zeroCards.availableCards == 0 && zeroCards.availableCardsByPlan.isEmpty && zeroCards.planBreakdown(.zh) == nil,
            "confirmed zero cards remain a known total without empty plan rows")
        let unknown = ResetCreditLocalSummary(profiles: [first, profile("mirror", account: "a", count: nil)], now: now)
        expect(unknown.availableCards == nil && unknown.hasUnknownAccounts, "newer unknown balances supersede older known balances")
        let partial = ResetCreditLocalSummary(profiles: [first, profile("unverified", account: nil, count: 99)], now: now)
        expect(partial.availableCards == 2 && partial.hasUnknownAccounts, "unverified identity is excluded without presenting a full total")
        expect(partial.availableCardsByPlan == ["PLUS": 2], "unknown account identities cannot contribute card plan buckets")
        expect(
            ResetCreditLocalSummary(profiles: [profile("old", account: "a", count: 2, age: 901)], now: now).isStale,
            "stale balances do not claim current verification")
        let future = ResetCreditLocalSummary(profiles: [profile("future", account: "a", count: 4, age: -60)], now: now)
        expect(future.availableCards == nil, "future observations are not shown as verified")
        let overflow = ResetCreditLocalSummary(profiles: [profile("max", account: "a", count: Int.max), second], now: now)
        expect(overflow.availableCards == nil && overflow.hasUnknownAccounts, "malformed totals fail closed without overflow")
        expect(overflow.availableCardsByPlan.isEmpty && overflow.planBreakdown(.zh) == nil, "an overflow cannot display an inconsistent plan breakdown")
        let invalidNewest = ResetCreditLocalSummary(
            profiles: [first, profile("invalid-newest", account: "a", count: 100, verified: false)], now: now)
        expect(invalidNewest.availableCards == nil && invalidNewest.availableCardsByPlan.isEmpty, "a newer unverified snapshot cannot contribute cards or plan counts")
        var received = mirror
        received.resetCreditHistory = [
            .init(
                id: UUID(), previousObservedAt: now.addingTimeInterval(-30), observedAt: now,
                previousAvailable: 1, available: 3)
        ]
        expect(
            ResetCreditLocalSummary(profiles: [received], now: now).latestIncrease?.added == 2,
            "verified receipt history appears independently of forecasts")
        let creditTotal = ResetCreditPointSummary(
            profiles: [
                profile("old", account: "a", count: nil, age: 30, credit: "9,999"),
                profile("new", account: "a", count: nil, credit: "1,250.25"),
                profile("other", account: "b", count: nil, credit: "70.30"),
            ], now: now)
        expect(
            creditTotal.points == Decimal(string: "1320.55") && !creditTotal.hasUnknownAccounts, "all distinct account balances sum exactly, independent of reset-card availability"
        )
        expect(creditTotal.dollarText == "$52.82", "remaining credits convert at 25 points per dollar")
        expect(
            creditTotal.pointText == "1,320.55" && creditTotal.pointSummaryText(.zh) == "点数总额 1,320.55",
            "the green reset-card section displays raw decimal points without converting card counts")
        let decimalPoints = ResetCreditPointSummary(
            profiles: [profile("decimal-one", account: "decimal-one", count: 1, credit: "76,700.28"), profile("decimal-two", account: "decimal-two", count: 24, credit: "92.30")],
            now: now)
        expect(
            decimalPoints.pointSummaryText(.zh) == "点数总额 76,792.58" && decimalPoints.pointSummaryText(.en) == "Total points 76,792.58",
            "decimal point totals retain exact sums and grouping in both languages")
        let fractionalPoints = ResetCreditPointSummary(profiles: [profile("fractional", account: "fractional", count: 1, credit: "0.001")], now: now)
        expect(fractionalPoints.pointText == "0.001", "raw points preserve reported fractional precision beyond currency rounding")
        let precisePoints = ResetCreditPointSummary(profiles: [profile("precise", account: "precise", count: nil, credit: "12345678901234567890.123456789012345678")], now: now)
        expect(
            precisePoints.pointText == "12,345,678,901,234,567,890.123456789012345678", "raw Decimal point text does not lose significant digits through floating-point formatting")
        let zeroCredit = ResetCreditPointSummary(profiles: [profile("zero", account: "a", count: nil, credit: "0")], now: now)
        expect(zeroCredit.dollarText == "$0.00", "verified zero is a real dollar balance")
        expect(zeroCredit.pointText == "0" && zeroCredit.pointSummaryText(.zh) == "点数总额 0", "verified zero points remain an explicit zero")
        let missingCredit = ResetCreditPointSummary(profiles: [profile("missing", account: "a", count: 1)], now: now)
        expect(missingCredit.points == nil && missingCredit.dollarText == "$—", "missing credit balances never become zero")
        expect(missingCredit.pointText == "—" && missingCredit.pointSummaryText(.zh) == "点数总额尚未核实", "unknown point balances cannot be presented as a zero total")
        let partialCredit = ResetCreditPointSummary(profiles: [profile("known", account: "a", count: nil, credit: "25"), profile("unknown", account: "b", count: nil)], now: now)
        expect(partialCredit.dollarText == "$1.00" && partialCredit.hasUnknownAccounts, "partial totals retain the known amount and the missing-account flag")
        expect(
            partialCredit.pointSummaryText(.zh) == "已核实点数 25 · 部分账号尚未确认" && partialCredit.pointSummaryText(.en) == "Known points 25 · Some accounts unverified",
            "partial point text labels the known subtotal instead of claiming a complete total")
        let newerMissing = ResetCreditPointSummary(profiles: [profile("old", account: "a", count: nil, age: 30, credit: "25"), profile("new", account: "a", count: nil)], now: now)
        expect(newerMissing.points == nil && newerMissing.hasUnknownAccounts, "a newer missing balance supersedes an old mirrored balance")
        expect(
            ResetCreditPointSummary(profiles: [profile("stale", account: "a", count: nil, age: 901, credit: "25")], now: now).isStale,
            "old credit totals are marked as previous records")
        let stalePoints = ResetCreditPointSummary(profiles: [profile("stale", account: "a", count: nil, age: 901, credit: "25")], now: now)
        expect(stalePoints.pointSummaryText(.zh) == "上次记录点数 25", "stale point balances never claim a current total")
        let stalePartial = ResetCreditPointSummary(
            profiles: [profile("stale", account: "a", count: nil, age: 901, credit: "25"), profile("unknown", account: "b", count: nil)], now: now)
        expect(stalePartial.pointSummaryText(.zh) == "上次记录的已知点数 25 · 部分账号尚未确认", "stale partial balances preserve both qualifications")
        expect(
            ResetCreditPointSummary(profiles: [profile("future", account: "a", count: nil, age: -60, credit: "25")], now: now).points == nil,
            "future credit observations are excluded")
        expect(
            ResetCreditPointSummary(profiles: [profile("unverified", account: nil, count: nil, credit: "25")], now: now).points == nil,
            "unverified identities cannot contribute a credit balance")
        expect(ResetCreditPointSummary(profiles: [profile("invalid", account: "a", count: nil, credit: "NaN")], now: now).points == nil, "malformed balances stay unknown")
        expect(
            ResetCreditPointSummary(profiles: [profile("unlimited", account: "a", count: nil, unlimited: true)], now: now).dollarText == "$∞",
            "unlimited credit is never invented as a finite balance")
        let unlimitedPoints = ResetCreditPointSummary(profiles: [profile("unlimited", account: "a", count: nil, unlimited: true)], now: now)
        expect(unlimitedPoints.pointText == "∞" && unlimitedPoints.pointSummaryText(.zh) == "点数总额 无限", "unlimited points never become a finite zero")
        let partialUnlimited = ResetCreditPointSummary(
            profiles: [profile("unlimited", account: "a", count: nil, unlimited: true), profile("unknown", account: "b", count: nil)], now: now)
        expect(partialUnlimited.pointSummaryText(.zh) == "已核实点数 无限 · 部分账号尚未确认", "unlimited balance text retains unknown-account coverage")
    }

    private static func reproducePublicResetHistory(expect: (Bool, String) -> Void) {
        let parser = ISO8601DateFormatter()
        let date = parser.date(from: "2026-09-03T23:12:00Z")!
        let event = PublicResetAnnouncement(
            id: "fixture-reset-history", resetType: .banked, announcedAt: date,
            text: "A public reset announcement", source: .init(type: "observed", author: nil, url: nil))
        let older = PublicResetAnnouncement(
            id: "fixture-reset-history-older", resetType: .regular, announcedAt: date.addingTimeInterval(-60),
            text: "An earlier announcement", source: .init(type: "observed", author: nil, url: nil))
        expect(
            PublicResetAnnouncementPresentation.normalized([older, event, event]).map(\.id) == [event.id, older.id],
            "history stays newest-first and does not duplicate the latest announcement")
        let orderNow = parser.date(from: "2026-10-03T00:00:00Z")!
        let latestRegular = PublicResetAnnouncement(
            id: "observed-latest-regular", resetType: .regular,
            announcedAt: parser.date(from: "2026-10-02T21:18:00Z")!, text: "Latest regular reset announcement",
            source: .init(type: "observed", author: nil, url: nil))
        let earlierBanked = PublicResetAnnouncement(
            id: "observed-earlier-banked", resetType: .banked,
            announcedAt: parser.date(from: "2026-09-30T00:00:00Z")!, text: "Earlier reset-card announcement",
            source: .init(type: "observed", author: nil, url: nil))
        expect(
            PublicResetAnnouncementPresentation.compactAnnouncementTypeOrder([earlierBanked, latestRegular], now: orderNow)
                == [.regular, .banked],
            "compact quota announcements show the newest type before an older announcement")
        expect(
            PublicResetAnnouncementPresentation.compactAnnouncementTypeOrder([latestRegular], now: orderNow)
                == [.regular, .banked],
            "a missing compact announcement type follows a recent announcement")
        expect(
            PublicResetAnnouncementPresentation.compactEventTime(date, language: .zh).contains("2026-09-04 07:12"),
            "history timestamps preserve Beijing time across UTC date boundaries")
        expect(PublicResetAnnouncementPresentation.normalized([]).isEmpty, "missing history is not invented")
    }

    private static func reproduceFloatingBubble(expect: (Bool, String) -> Void) {
        // Assertions copied from vendor/token-monitor/tests/electron/floatingBubble.test.js
        let workArea = TokenMonitorFloatingBubbleGeometry.Rect(x: 0, y: 24, width: 1440, height: 876)
        let windowsDisplay = TokenMonitorFloatingBubbleGeometry.Display(
            bounds: .init(x: 0, y: 0, width: 1920, height: 1080),
            workArea: .init(x: 0, y: 0, width: 1840, height: 1040)
        )
        expect(
            TokenMonitorFloatingBubbleGeometry.canUseFloatingBubble(
                .init(floatingBubbleEnabled: true, trayMode: false, windowBehavior: "floating")),
            "floating bubble is available in movable window modes")
        expect(
            !TokenMonitorFloatingBubbleGeometry.canUseFloatingBubble(
                .init(floatingBubbleEnabled: true, trayMode: false, windowBehavior: "desktop")),
            "desktop window behavior disables the bubble")
        expect(
            !TokenMonitorFloatingBubbleGeometry.canUseFloatingBubble(
                .init(floatingBubbleEnabled: true, trayMode: true, windowBehavior: "floating")),
            "tray mode disables the bubble")
        expect(TokenMonitorFloatingBubbleGeometry.nativeGlassEnabled(.init(systemGlass: true)), "native glass follows systemGlass")
        expect(!TokenMonitorFloatingBubbleGeometry.nativeGlassEnabled(.init(systemGlass: false)), "systemGlass false disables glass")
        expect(TokenMonitorFloatingBubbleGeometry.collapsedArea(windowsDisplay, platform: .windows) == windowsDisplay.bounds, "Windows uses physical bounds")
        expect(TokenMonitorFloatingBubbleGeometry.collapsedArea(windowsDisplay, platform: .macOS) == windowsDisplay.workArea, "macOS uses work area")
        expect(TokenMonitorFloatingBubbleGeometry.collapsedMargin(platform: .windows) == .init(x: 0, y: 0), "Windows collapsed margin")
        expect(TokenMonitorFloatingBubbleGeometry.collapsedMargin(platform: .macOS) == .init(x: 0, y: 8), "macOS collapsed margin")
        let collapsedLeft = TokenMonitorFloatingBubbleGeometry.collapsedBounds(
            .init(x: 120, y: 80, width: 360, height: 520), workArea: workArea)
        expect(collapsedLeft == .init(x: 120, y: 323, width: 18, height: 34), "left collapsed handle matches upstream")
        let collapsedRight = TokenMonitorFloatingBubbleGeometry.collapsedBounds(
            .init(x: 1000, y: 80, width: 360, height: 520), workArea: workArea)
        expect(collapsedRight == .init(x: 1342, y: 323, width: 18, height: 34), "right collapsed handle matches upstream")
        let plan = TokenMonitorFloatingBubbleGeometry.collapsePlan(
            bounds: .init(x: 120, y: 120, width: 360, height: 520),
            workArea: workArea,
            settings: .init(floatingBubbleEnabled: true, windowBehavior: "floating")
        )
        expect(plan?.side == "left", "collapse plan side is left")
        expect(plan?.collapsedBounds == .init(x: 120, y: 363, width: 18, height: 34), "collapse plan bounds match upstream")
        expect(
            TokenMonitorFloatingBubbleGeometry.collapsePlan(
                bounds: .init(x: 120, y: 120, width: 360, height: 520),
                workArea: workArea,
                settings: .init(floatingBubbleEnabled: true, windowBehavior: "floating"),
                suppressNextCollapse: true
            ) == nil,
            "suppressNextCollapse returns nil"
        )
        let reused = TokenMonitorFloatingBubbleGeometry.collapsePlan(
            bounds: .init(x: 120, y: 120, width: 360, height: 520),
            workArea: workArea,
            settings: .init(floatingBubbleEnabled: true, windowBehavior: "normal"),
            previousCollapsed: .init(x: 640, y: 220, width: 18, height: 34)
        )
        expect(reused?.collapsedBounds == .init(x: 640, y: 220, width: 18, height: 34), "last dragged mini-window is reused")
        let expanded = TokenMonitorFloatingBubbleGeometry.expandedBounds(
            collapsed: .init(x: 1100, y: 500, width: 18, height: 34),
            workArea: workArea,
            previousExpanded: .init(x: 0, y: 0, width: 360, height: 520)
        )
        expect(expanded == .init(x: 758, y: 257, width: 360, height: 520), "expand from right handle")
        let expandedClamped = TokenMonitorFloatingBubbleGeometry.expandedBounds(
            collapsed: .init(x: 8, y: 8, width: 18, height: 34),
            workArea: workArea,
            previousExpanded: .init(x: 0, y: 0, width: 360, height: 520)
        )
        expect(expandedClamped == .init(x: 8, y: 32, width: 360, height: 520), "expand clamps into the work area")
        expect(
            TokenMonitorFloatingBubbleGeometry.moveBounds(
                .init(x: 8, y: 30, width: 18, height: 34), workArea: workArea, dx: -80, dy: -80)
                == .init(x: 0, y: 32, width: 18, height: 34),
            "drag clamps to the work area"
        )
        let query = TokenMonitorFloatingBubbleGeometry.initialRendererQuery(
            collapsed: true, side: "right", collapsedWindow: true)
        expect(query["period"] == "today" && query["breakdown"] == "tool" && query["floatingBubbleSide"] == "right", "renderer query carries view state")
    }

    private static func reproduceNavigation(expect: (Bool, String) -> Void) {
        var state = AgentNavigationState()
        expect(!state.initialized, "fresh navigation is uninitialized")
        state.bootstrapIfNeeded(existingUser: false, currentVisible: ["codex", "grok"])
        expect(state.initialized && state.customized && state.orderedVisibleProviderIDs.isEmpty, "new users start with no Agent tabs")
        expect(state.add("codex"), "Codex can be added")
        expect(!state.add("codex"), "duplicate add is rejected")
        expect(state.add("grok") && state.add("claudeCode"), "workspace agents can be added")
        expect(!state.add("cursor"), "unsupported catalog items cannot be added")
        expect(state.remove("codex") == "codex", "Codex can be hidden without deleting accounts")
        expect(state.renderableIDs() == ["grok", "claudeCode"], "remove only hides the tab")
        state.move("claudeCode", by: -1)
        expect(state.orderedVisibleProviderIDs == ["claudeCode", "grok"], "keyboard reorder swaps neighbors")
        var draft = state
        _ = draft.remove("grok")
        expect(state.orderedVisibleProviderIDs.contains("grok"), "cancel keeps the pre-edit snapshot")
        state.orderedVisibleProviderIDs = ["grok", "unknown-future", "claudeCode"]
        expect(state.renderableIDs() == ["grok", "claudeCode"], "unknown IDs stay stored but are not rendered")
        expect(state.unknownIDs() == ["unknown-future"], "unknown IDs remain for later recovery")
        let empty = AgentNavigationState(initialized: true, customized: true, orderedVisibleProviderIDs: [])
        expect(empty.renderableIDs().isEmpty, "an explicit empty list is not missing config")
        let overflow = AgentNavigationOverflow.layout(
            orderedIDs: AgentNavCatalog.workspaceProviders.map(\.id),
            availableWidth: 820,
            homeWidth: 88,
            trailingChromeWidth: 196,
            moreWidth: 92,
            itemWidth: { _ in 110 }
        )
        expect(
            overflow.showsMore && !overflow.overflowIDs.isEmpty && overflow.visibleIDs.count < AgentNavCatalog.workspaceProviders.count,
            "narrow windows keep Home/Add/Manage and overflow the rest")
        let wide = AgentNavigationOverflow.layout(
            orderedIDs: ["codex"],
            availableWidth: 1280,
            itemWidth: { _ in 90 }
        )
        expect(!wide.showsMore && wide.visibleIDs == ["codex"], "a single tab does not need More")
        let none = AgentNavigationOverflow.layout(orderedIDs: [], availableWidth: 820)
        expect(!none.showsMore && none.visibleIDs.isEmpty, "zero agent tabs is legal")
        var many = AgentNavigationState(initialized: true, customized: true, orderedVisibleProviderIDs: (0..<40).map { "p\($0)" })
        many.orderedVisibleProviderIDs.insert("codex", at: 0)
        expect(many.orderedVisibleProviderIDs.count >= 35, "35+ stored IDs remain addressable")
        expect(AgentNavCatalog.workspaceProviders.contains { $0.id == "codex" }, "Codex is part of the workspace catalog")
    }

    private static func reproduceAvatars(expect: (Bool, String) -> Void) {
        expect(AccountAvatarEmoji.isolatedCluster("😀") == "😀", "single emoji is stored as one cluster")
        expect(AccountAvatarEmoji.isolatedCluster("👨‍👩‍👧‍👦") == "👨‍👩‍👧‍👦", "ZWJ family stays one cluster")
        expect(AccountAvatarEmoji.isolatedCluster("🇺🇸") == "🇺🇸", "flag sequences stay one cluster")
        expect(AccountAvatarEmoji.isolatedCluster("😀😀") == nil, "multiple emoji are rejected")
        expect(AccountAvatarEmoji.isolatedCluster("Codex") == nil, "plain text is rejected")
        expect(AccountAvatarEmoji.isolatedCluster("") == nil, "empty emoji is rejected")
        expect(ProviderIconSlot.list.container == 24 && ProviderIconSlot.card.container == 32, "list/card avatar sizes")
        expect(ProviderIconSlot.detail.container == 48 && ProviderIconSlot.editor.container == 80, "detail/editor avatar sizes")
        expect(
            ProviderIconSlot.card.hitTarget >= 32 && ProviderIconSlot.detail.hitTarget >= 32 && ProviderIconSlot.editor.hitTarget >= 32,
            "card/detail/editor avatars keep a 32pt hit target")
        expect(
            ProviderIconSlot.compactRow.container == 20 && ProviderIconSlot.compactRow.glyph == 20,
            "compact-row avatars keep the original 20pt footprint")
        var table = AccountAvatarTable()
        table.set(.init(mode: .emoji, emoji: "😀"), for: "a")
        table.set(.init(mode: .image, assetID: "avatar-a-1"), for: "b")
        expect(table.record(for: "a").emoji == "😀", "emoji is keyed by profile ID")
        expect(table.record(for: "b").assetID == "avatar-a-1", "image asset is keyed by profile ID")
        expect(table.record(for: "a").assetID == nil, "two accounts cannot share by accident")
        table.restoreDefault(for: "a")
        expect(table.record(for: "a").mode == .platformDefault, "restore default does not delete the account")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-self-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AccountAvatarAssetStore(root: tmp)
        let png = solidPNG(color: .systemOrange)
        let assetID = try? store.savePNG(png, profileID: "profile/one")
        expect(assetID != nil && store.load(assetID: assetID ?? "") != nil, "managed PNG is readable")
        expect(!(assetID ?? "").contains("/"), "asset IDs do not embed paths")
        store.remove(assetID: assetID ?? "")
        expect(store.load(assetID: assetID ?? "") == nil, "missing files fall back")
        let svg = tmp.appendingPathComponent("x.svg")
        try? "<svg xmlns='http://www.w3.org/2000/svg'></svg>".write(to: svg, atomically: true, encoding: .utf8)
        if case .failure(let reason) = AccountAvatarImageProcessor.inspect(url: svg) {
            expect(reason == .vector, "SVG is rejected")
        } else {
            expect(false, "SVG inspection should fail")
        }
    }

    private static func reproduceIcons(expect: (Bool, String) -> Void) {
        expect(ProviderIconSlot.navigation.container == 20, "navigation container is 20pt")
        expect((16...18).contains(Int(ProviderIconSlot.navigation.glyph.rounded())), "navigation glyph is 16-18pt")
        expect(ProviderIconSlot.menu.container == 16, "menu icons are 16pt")
        expect(ProviderIconSlot.detail.container == 48, "detail avatars are 48pt")
        let optical = ProviderIconMetrics.opticalLayout(sourceWidth: 24, sourceHeight: 12, size: 20)
        expect(abs(optical.width - 15.6) < 0.01 && abs(optical.height - 7.8) < 0.01, "optical 0.78 matches upstream tray layout")
        expect(abs(optical.midX - 10) < 0.01, "marks stay centered in the container")
        for kind in LocalCLIKind.allCases {
            expect(AgentNavCatalog.localKind(kind.rawValue) == kind, "every local CLI has a catalog mark")
        }
    }

    private static func reproduceMenuAndModel(expect: (Bool, String) -> Void) {
        let claude = AnchoredMenuRequest(
            ownerID: "claude-default",
            actions: [
                AnchoredMenuAction(id: "pin", title: "固定第一位"),
                AnchoredMenuAction(id: "rename", title: "重命名"),
            ]
        )
        let grok = AnchoredMenuRequest(
            ownerID: "grok-default",
            actions: [
                AnchoredMenuAction(id: "pin", title: "固定第一位"),
                AnchoredMenuAction(id: "rename", title: "重命名"),
            ]
        )
        expect(claude.ownerID != grok.ownerID, "repro: each ellipsis is bound to one profile")
        expect(claude.action(id: "pin") != nil, "repro: Claude more-menu owns pin/rename")
        var mutated = ""
        func apply(_ request: AnchoredMenuRequest, action: String) {
            mutated = request.ownerID + ":" + action
        }
        apply(claude, action: "pin")
        expect(mutated == "claude-default:pin", "a Claude menu cannot mutate the Grok row")
        apply(grok, action: "rename")
        expect(mutated == "grok-default:rename", "a Grok menu only mutates Grok")

        let summary = "5.6 Sol · High · 子：5.6 Luna · High · 标准速度"
        expect(
            !ExecutionPreferenceCompactCopy.showsDuplicateModelName(modelName: "5.6 Sol", visibleLine: summary),
            "compact model label must not print the model name twice"
        )
        expect(
            ExecutionPreferenceCompactCopy.showsDuplicateModelName(
                modelName: "5.6 Sol",
                visibleLine: "5.6 Sol 5.6 Sol · High · 子：5.6 Luna"
            ),
            "repro: the reported compact control concatenated the model name with a summary that already started with it"
        )
        expect(
            ExecutionPreferenceCompactCopy.compactSummary(modelName: "5.6 Sol", summary: summary) == summary,
            "compact copy keeps one summary line"
        )
        expect(AgentNavCatalog.localKind("grok") == .grok, "non-Codex model UI is keyed by provider ID, not Codex")
        expect(AgentNavCatalog.localKind("codex") == nil, "Codex execution presets stay on Codex rows only")
    }

    private static func reproduceResponsiveTokenAndAccountLayouts(expect: (Bool, String) -> Void) {
        expect(
            TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: 786),
            "822pt window content stacks totals and announcement columns"
        )
        expect(
            !TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: 1_064),
            "1100pt window content keeps the two modules side by side"
        )
        expect(
            !TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: 1_404),
            "1440pt window content keeps the two modules side by side"
        )
        expect(TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: 320), "narrow bounds stack safely")
        expect(TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: .infinity), "nonfinite responsive widths are safe")
        expect(
            TokenTotalsHeaderResponsiveLayout.shouldStack(
                containerWidth: TokenTotalsHeaderResponsiveLayout.minimumHorizontalWidth.nextDown
            ),
            "totals stack immediately below the exact three-child HStack boundary"
        )
        expect(
            !TokenTotalsHeaderResponsiveLayout.shouldStack(
                containerWidth: TokenTotalsHeaderResponsiveLayout.minimumHorizontalWidth
            ),
            "totals fit at the exact three-child HStack boundary"
        )

        expect(AccountCardGridLayout.columnCount(width: 784, itemCount: 9) == 2, "account cards keep natural width at 822pt")
        expect(AccountCardGridLayout.columnCount(width: 1_064, itemCount: 9) == 3, "account cards add a third column at 1100pt")
        expect(AccountCardGridLayout.columnCount(width: 1_404, itemCount: 9) == 4, "account cards add a fourth column at 1440pt")
    }

    private static func reproduceTokenCalendarSemantics(expect: (Bool, String) -> Void) {
        let utc = StatisticsContext(
            preference: StatisticsTimeZonePreference(selection: .utc, fixedIdentifier: "UTC"),
            now: Date(timeIntervalSince1970: 0)
        )
        let shanghai = StatisticsContext(
            preference: StatisticsTimeZonePreference(selection: .fixed, fixedIdentifier: "Asia/Shanghai"),
            now: Date(timeIntervalSince1970: 0)
        )
        let event = ISO8601DateFormatter().date(from: "2026-09-04T17:30:00Z")!
        expect(utc.dayKey(for: event) == "2026-09-04", "calendar fixture uses UTC day bucket")
        expect(shanghai.dayKey(for: event) == "2026-09-05", "calendar fixture uses selected Shanghai day bucket")

        let losAngeles = StatisticsContext(
            preference: StatisticsTimeZonePreference(selection: .fixed, fixedIdentifier: "America/Los_Angeles"),
            now: Date(timeIntervalSince1970: 0)
        )
        let historicalDSTInstant = ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z")!
        let nextDay = losAngeles.calendar.date(
            byAdding: .day,
            value: 1,
            to: losAngeles.startOfDay(for: historicalDSTInstant)
        )!
        expect(
            Int(nextDay.timeIntervalSince(losAngeles.startOfDay(for: historicalDSTInstant))) == 23 * 3_600,
            "DST fixture uses a real UTC instant rather than nonexistent local 02:30"
        )

        let points = [
            UpstreamTrendView.Point(date: "2026-09-05", tokens: 0),
            UpstreamTrendView.Point(date: "invalid", tokens: .nan),
            UpstreamTrendView.Point(date: "huge", tokens: .infinity),
            UpstreamTrendView.Point(date: "too-large", tokens: Double.greatestFiniteMagnitude),
        ]
        let values = TokenTotalsHeader.normalizedDailyValues(points)
        expect(values["2026-09-05"] == 0, "a true zero remains a recorded zero")
        expect(values["missing"] == nil, "an absent day remains missing")
        expect(TokenTotalsHeader.safeTokenCount(.nan) == nil, "NaN token data is rejected safely")
        expect(TokenTotalsHeader.safeTokenCount(.infinity) == nil, "infinite token data is rejected safely")
        expect(TokenTotalsHeader.safeTokenCount(Double.greatestFiniteMagnitude) == nil, "huge token data is rejected safely")
    }

    private static func reproduceLocalUsageCoverage(expect: (Bool, String) -> Void) {
        expect(LocalUsageTotalsContract.combined(official: 0, local: 0) == 0, "complete true zero totals stay numeric")
        expect(LocalUsageTotalsContract.combined(official: nil, local: 17) == nil, "missing official source cannot produce a complete total")
        expect(LocalUsageTotalsContract.combined(official: 17, local: nil) == nil, "missing local source cannot produce a complete total")
        expect(LocalUsageTotalsContract.combined(official: Int64.max, local: 1) == nil, "combined total overflow is unavailable")
        expect(
            LocalUsageTotalsContract.confirmed(0, hasCompleteTotals: true) == 0,
            "a complete true zero remains a confirmed aggregate"
        )
        expect(
            LocalUsageTotalsContract.confirmed(0, hasCompleteTotals: false) == nil,
            "daily-only placeholder zero is never presented as an aggregate"
        )
        expect(
            TokenTotalsHeader.totalText(0, language: .zh) != "暂不可确认",
            "a complete true zero has a numeric display contract"
        )
        expect(
            TokenTotalsHeader.totalText(nil, language: .zh) == "暂不可确认",
            "a missing aggregate uses the explicit unavailable display contract"
        )
        let historical = LocalUsageTotalsContract.lifetime(nil, historicalHighWater: 42)
        expect(
            historical == .init(value: 42, isHistorical: true),
            "a saved high-water mark remains visible only as historical lifetime usage"
        )
        expect(
            LocalUsageTotalsContract.lifetime(nil, historicalHighWater: 0).value == nil,
            "an unconfirmed zero high-water mark cannot stand in for a missing source"
        )
        let dailyOnlyBuckets = [UpstreamTrendView.Point(date: "2026-09-12", tokens: 17)]
        expect(
            TokenTotalsHeader.normalizedDailyValues(dailyOnlyBuckets)["2026-09-12"] == 17,
            "daily records remain independently renderable when aggregate coverage is unavailable"
        )
    }

    private static func reproduceTrendRendererBoundaries(expect: (Bool, String) -> Void) {
        let valid = UpstreamTrendView.Point(date: "2026-09-05", tokens: 1)
        let sanitized = UpstreamTrendView.Renderer.sanitizedPoints([
            valid,
            UpstreamTrendView.Point(date: "", tokens: 2),
            UpstreamTrendView.Point(date: "bad", tokens: .nan),
            UpstreamTrendView.Point(date: "negative", tokens: -1),
        ])
        expect(sanitized == [valid], "chart payload keeps only finite nonnegative dated points")
        expect(UpstreamTrendView.Renderer.sanitizedPoints([]).isEmpty, "empty chart payload stays distinct")
        expect(UpstreamTrendView.Renderer.renderResultIsValid("<svg></svg>"), "chart success requires nonempty SVG output")
        expect(!UpstreamTrendView.Renderer.renderResultIsValid(nil), "missing chart result is a failure")
        expect(!UpstreamTrendView.Renderer.renderResultIsValid("  \n"), "blank chart result is a failure")
        expect(!UpstreamTrendView.Renderer.renderResultIsValid("not SVG"), "non-SVG chart result is a failure")
        expect(!UpstreamTrendView.Renderer.renderResultIsValid(["unexpected"]), "invalid chart result is a failure")
        expect(UpstreamTrendView.Renderer.rendererFunctionIsAvailable(true), "JavaScript boolean renderer result is accepted")
        expect(UpstreamTrendView.Renderer.rendererFunctionIsAvailable("true"), "string renderer probe remains compatible")
        expect(!UpstreamTrendView.Renderer.rendererFunctionIsAvailable(false), "missing renderer function is rejected")

        let initiallyInvalid = UpstreamTrendView.Renderer()
        initiallyInvalid.update(
            points: [UpstreamTrendView.Point(date: "invalid", tokens: .nan)],
            height: 40
        )
        expect(initiallyInvalid.state == .failed(.invalidData), "initial all-invalid input cannot early-return as loading")
        let currentWeb = WKWebView(frame: .zero)
        let previousWeb = WKWebView(frame: .zero)
        initiallyInvalid.attach(currentWeb)
        initiallyInvalid.attach(currentWeb)
        expect(initiallyInvalid.state == .failed(.invalidData), "representable attachment preserves invalid input instead of feeding filtered empty data back")
        initiallyInvalid.didFinishLoading(previousWeb, navigation: nil)
        expect(initiallyInvalid.isAttached(to: currentWeb), "a stale WebView finish cannot replace the current attachment")
        initiallyInvalid.didFailNavigation(previousWeb, navigation: nil)
        expect(initiallyInvalid.isAttached(to: currentWeb), "a stale WebView failure cannot replace the current attachment")
        expect(initiallyInvalid.state == .failed(.invalidData), "stale WebView callbacks cannot change the current input state")
        initiallyInvalid.update(points: [], height: 40)
        expect(initiallyInvalid.state == .empty, "invalid input can transition to true empty")
        initiallyInvalid.update(points: [valid], height: 40)
        expect(initiallyInvalid.state == .loading, "invalid to empty to valid returns to loading")

        var emptyToValid = UpstreamTrendView.Renderer.Lifecycle()
        emptyToValid.updateInput(.empty)
        let emptyLoad = emptyToValid.beginLoad()
        expect(!emptyToValid.finishNavigation(loadID: emptyLoad), "empty navigation finishes without rendering")
        emptyToValid.updateInput(.valid)
        expect(emptyToValid.canProbeRenderer, "empty to valid probes the already loaded renderer")
        let emptyProbe = emptyToValid.beginRendererProbe()
        expect(emptyProbe == emptyLoad, "renderer probe belongs to the current navigation")
        expect(
            emptyToValid.completeRendererProbe(loadID: emptyLoad, available: true),
            "available renderer requests a render for valid data"
        )
        let firstRender = emptyToValid.beginRender()
        expect(firstRender != nil, "valid data begins a production render")
        if let firstRender {
            expect(emptyToValid.completeRender(firstRender, failure: nil), "current render completion is accepted")
        }
        expect(emptyToValid.state == .ready, "empty to valid reaches ready")

        emptyToValid.updateInput(.empty)
        expect(emptyToValid.state == .empty, "ready to empty clears the chart state")
        emptyToValid.updateInput(.valid)
        expect(emptyToValid.canRender, "ready to empty to valid reuses the confirmed renderer")
        let restoredRender = emptyToValid.beginRender()
        if let restoredRender {
            _ = emptyToValid.completeRender(restoredRender, failure: nil)
        }
        expect(emptyToValid.state == .ready, "ready to empty to valid renders again")

        emptyToValid.updateInput(.invalid)
        expect(emptyToValid.state == .failed(.invalidData), "ready to invalid exposes invalid data")
        emptyToValid.updateInput(.empty)
        emptyToValid.updateInput(.valid)
        expect(emptyToValid.canRender, "invalid to empty to valid reuses a healthy renderer")

        var retriedNavigation = UpstreamTrendView.Renderer.Lifecycle()
        retriedNavigation.updateInput(.valid)
        let oldLoad = retriedNavigation.beginLoad()
        let currentLoad = retriedNavigation.beginLoad()
        expect(
            !retriedNavigation.failNavigation(loadID: oldLoad),
            "an old navigation failure cannot overwrite a retry"
        )
        expect(retriedNavigation.state == .loading, "the retry remains loading after an old failure")
        expect(retriedNavigation.finishNavigation(loadID: currentLoad), "the current retry navigation can finish")

        let currentProbe = retriedNavigation.beginRendererProbe()
        expect(currentProbe == currentLoad, "retry probes only the current load")
        _ = retriedNavigation.completeRendererProbe(loadID: currentLoad, available: true)
        let oldSizeRender = retriedNavigation.beginRender()
        let currentSizeRender = retriedNavigation.beginRender()
        if let oldSizeRender {
            expect(
                !retriedNavigation.completeRender(oldSizeRender, failure: .scriptFailed),
                "a stale pre-resize completion cannot replace the current render"
            )
        }
        if let currentSizeRender {
            expect(
                retriedNavigation.completeRender(currentSizeRender, failure: nil),
                "the latest resize render completion is accepted"
            )
        }
        expect(retriedNavigation.state == .ready, "resize lifecycle ends ready")

        var failures = UpstreamTrendView.Renderer.Lifecycle()
        failures.updateInput(.valid)
        failures.failWithoutNavigation(.resourceUnavailable)
        expect(failures.state == .failed(.resourceUnavailable), "missing resources keep a visible retry state")
        let failedNavigation = failures.beginLoad()
        expect(failures.failNavigation(loadID: failedNavigation), "current navigation failures are accepted")
        expect(failures.state == .failed(.navigationFailed), "navigation failure keeps a visible retry state")

        let rendererLoad = failures.beginLoad()
        _ = failures.finishNavigation(loadID: rendererLoad)
        _ = failures.beginRendererProbe()
        _ = failures.completeRendererProbe(loadID: rendererLoad, available: false)
        expect(failures.state == .failed(.rendererUnavailable), "missing JS function keeps a visible retry state")

        let scriptLoad = failures.beginLoad()
        _ = failures.finishNavigation(loadID: scriptLoad)
        _ = failures.beginRendererProbe()
        _ = failures.completeRendererProbe(loadID: scriptLoad, available: true)
        if let scriptRender = failures.beginRender() {
            _ = failures.completeRender(scriptRender, failure: .scriptFailed)
        }
        expect(failures.state == .failed(.scriptFailed), "script errors keep a visible retry state")
        if let emptyOutputRender = failures.beginRender() {
            _ = failures.completeRender(emptyOutputRender, failure: .rendererReturnedNoOutput)
        }
        expect(failures.state == .failed(.rendererReturnedNoOutput), "missing SVG output keeps a visible retry state")

        failures.contentProcessTerminated()
        expect(failures.state == .failed(.processTerminated), "content process termination keeps a visible retry state")
    }

    private static func reproduceResetAnnouncementPresentation(expect: (Bool, String) -> Void) {
        let xSource = PublicResetAnnouncement.Source(
            type: "x_post",
            author: "thsottiaux",
            url: URL(string: "https://x.com/thsottiaux/status/123")
        )
        let observedSource = PublicResetAnnouncement.Source(type: "observed", author: nil, url: PublicResetClient.siteURL)
        let xLabel = PublicResetAnnouncementPresentation.sourceLabel(xSource, language: .zh)
        let observedLabel = PublicResetAnnouncementPresentation.sourceLabel(observedSource, language: .zh)
        expect(xLabel.contains("X") && xLabel.contains("thsottiaux"), "X source keeps its author visible")
        expect(!xLabel.contains("网友观察"), "X source is not mislabeled as generic user observation")
        expect(observedLabel.contains("观察记录") && !observedLabel.contains(".com"), "observed source keeps its meaning without showing a bare domain")
        expect(
            PublicResetAnnouncementPresentation.readableText("Reset complete. https://t.co/example") == "Reset complete.",
            "announcement presentation removes trailing web addresses"
        )
        expect(
            PublicResetAnnouncementPresentation.readableText("第一行\nHTTPS://example.com/reset\n确认完成") == "第一行\n\n确认完成",
            "URL filtering preserves surrounding multilingual content and paragraph boundaries"
        )
        expect(
            PublicResetAnnouncementPresentation.sourceLinkTitle(observedSource, language: .zh).contains("来源"),
            "an aggregator URL is labeled as its source"
        )
        expect(PublicResetAnnouncementPresentation.title(.zh) == "历史重置记录", "completed history stays distinct from pending forecasts")
        expect(
            PublicResetAnnouncementPresentation.typeTitle(.regular, language: .zh).contains("常规额度"),
            "regular quota announcements stay distinct from reset cards"
        )
        expect(
            PublicResetAnnouncementPresentation.typeTitle(.banked, language: .zh).contains("重置卡"),
            "banked announcements are labeled as reset-card announcements"
        )
        let regularMeaning = PublicResetAnnouncementPresentation.interpretation(.regular, language: .zh)
        expect(!regularMeaning.contains("有人额度") && regularMeaning.contains("不代表个人额度已刷新"), "regular copy does not invent personal delivery")
        expect(AnnouncementOriginalText.collapsedLineLimit == 2, "home announcement defaults to two lines with a full-text expansion")
        expect(
            PublicResetAnnouncementPresentation.eventTime(Date(timeIntervalSince1970: 1_789_000_000), language: .zh).contains(":"),
            "announcement event time keeps an exact clock value"
        )
        let event = ISO8601DateFormatter().date(from: "2026-09-12T08:09:17Z")!
        let compactTime = PublicResetAnnouncementPresentation.compactEventTime(event, language: .zh)
        expect(compactTime.contains("2026-09-12 16:09"), "home announcement keeps the full Beijing year and clock")
        expect(
            PublicResetAnnouncementPresentation.relativeEventTime(event, now: event.addingTimeInterval(7 * 3600), language: .zh).contains("7"),
            "home announcement age uses its event time")
        expect(
            PublicResetAnnouncementPresentation.relativeEventTime(event, now: event.addingTimeInterval(-30), language: .zh) == "刚刚",
            "allowed source clock skew does not create a future reset claim")
        let now = ISO8601DateFormatter().date(from: "2026-09-19T00:00:00Z")!
        let recent = PublicResetAnnouncement(
            id: "456", resetType: .regular, announcedAt: now.addingTimeInterval(-86_400), text: "recent",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/456")))
        let old = PublicResetAnnouncement(
            id: "457", resetType: .regular, announcedAt: now.addingTimeInterval(-31 * 86_400), text: "old",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/457")))
        let future = PublicResetAnnouncement(
            id: "458", resetType: .regular, announcedAt: now.addingTimeInterval(60), text: "future",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/458")))
        expect(
            PublicResetAnnouncementPresentation.recentVerifiableAnnouncement([old, future, recent], now: now)?.id == "456",
            "homepage announcements use only verifiable, non-future items from the last 30 days"
        )
        expect(
            PublicResetAnnouncementPresentation.recentVerifiableAnnouncement([old, future], now: now) == nil,
            "old and future announcements stay out of the homepage current-message slot"
        )

        let iso = ISO8601DateFormatter()
        let todaysForecastPost = iso.date(from: "2026-09-26T00:07:13Z")!
        let beijingNoon = iso.date(from: "2026-09-26T04:00:00Z")!
        let yesterdayInBeijing = iso.date(from: "2026-09-25T15:00:00Z")!
        let tomorrowInBeijing = iso.date(from: "2026-09-26T16:00:00Z")!
        let laterTodayInBeijing = iso.date(from: "2026-09-26T05:00:00Z")!
        expect(
            PublicResetAnnouncementPresentation.wasAnnouncedToday(todaysForecastPost, now: beijingNoon),
            "the site's forecast post is marked new from announcedAt in Beijing time"
        )
        expect(
            !PublicResetAnnouncementPresentation.wasAnnouncedToday(yesterdayInBeijing, now: beijingNoon),
            "yesterday's Beijing announcement is not highlighted today"
        )
        expect(
            !PublicResetAnnouncementPresentation.wasAnnouncedToday(tomorrowInBeijing, now: beijingNoon),
            "a future Beijing date is not highlighted as today's message"
        )
        expect(
            !PublicResetAnnouncementPresentation.wasAnnouncedToday(laterTodayInBeijing, now: beijingNoon),
            "a future post within today's Beijing date is not highlighted early"
        )
        let minuteBeforeBeijingMidnight = iso.date(from: "2026-09-26T15:59:59Z")!
        let beijingMidnight = iso.date(from: "2026-09-26T16:00:00Z")!
        expect(
            PublicResetAnnouncementPresentation.wasAnnouncedToday(minuteBeforeBeijingMidnight, now: minuteBeforeBeijingMidnight)
                && !PublicResetAnnouncementPresentation.wasAnnouncedToday(minuteBeforeBeijingMidnight, now: beijingMidnight),
            "a message highlight rolls off at Beijing midnight without relying on the local timezone"
        )
    }

    private static func solidPNG(color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }
}
