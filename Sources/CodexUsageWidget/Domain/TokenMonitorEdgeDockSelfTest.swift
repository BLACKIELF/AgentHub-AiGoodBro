import Foundation

enum TokenMonitorEdgeDockSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let defaults = TokenMonitorEdgeDockPreferences()
        expect(
            !defaults.enabled && defaults.mode == .autoHide && defaults.side == .right
                && defaults.offset == 0.3 && defaults.items == nil
                && defaults.hapticEnabled && !defaults.warnColors,
            "edge dock defaults match opt-in right-side auto-hide behavior"
        )
        var explicit = defaults
        expect(defaults.quotaStyle == .ring, "existing users retain the ring style")
        let oldStyle = TokenMonitorEdgeDockPreferences.load(Data(#"{"enabled":true,"quotaStyle":"future-style"}"#.utf8))
        expect(oldStyle.enabled && oldStyle.quotaStyle == .ring, "unknown quota style preserves other settings and falls back to rings")
        var fishStyle = defaults
        fishStyle.quotaStyle = .fish
        expect((try? JSONEncoder().encode(fishStyle)).map { TokenMonitorEdgeDockPreferences.load($0).quotaStyle } == .fish, "fish style survives persistence")
        explicit.items = []
        let restored = (try? JSONEncoder().encode(explicit)).map { TokenMonitorEdgeDockPreferences.load($0) }
        expect(restored?.items == [], "explicitly empty items survive persistence")
        expect(TokenMonitorEdgeDockPreferences(offset: .infinity).normalized().offset == 0.3, "invalid offset restores the upstream default")
        expect(TokenMonitorEdgeDockPreferences(offset: -1).normalized().offset == 0, "offset clamps to screen travel")
        expect(
            TokenMonitorEdgeDockItem.normalizedList([
                .limit("Codex"), .limit("codex"), .stat(.today), .stat(.today), .stat(.allTime),
            ]).map(\.id) == ["limit:codex", "stat:today", "stat:allTime"],
            "configured cells normalize and de-duplicate in order"
        )

        let builtInUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let externalUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let builtIn = TokenMonitorEdgeDockScreenTarget.Identity(
            numericID: 1, uuid: builtInUUID, isBuiltIn: true
        )
        let external = TokenMonitorEdgeDockScreenTarget.Identity(
            numericID: 2, uuid: externalUUID, isBuiltIn: false
        )
        let externalID = TokenMonitorEdgeDockScreenTarget.stableID(for: external)!
        let legacyScreen = TokenMonitorEdgeDockPreferences.load(
            Data(#"{"enabled":true,"displayID":"1"}"#.utf8)
        )
        expect(
            legacyScreen.enabled && legacyScreen.displayID == "1"
                && TokenMonitorEdgeDockScreenTarget.migratedID(legacyScreen.displayID, screens: [builtIn, external]) == "builtin",
            "numeric display ID migrates to the built-in screen semantic when that display is present")
        expect(
            TokenMonitorEdgeDockScreenTarget.migratedID("1", screens: [external]) == "1"
                && TokenMonitorEdgeDockScreenTarget.index(for: "1", in: [external], preferredIndex: 0) == nil,
            "disconnected numeric choice stays selected and does not fall back to another display")
        expect(
            TokenMonitorEdgeDockScreenTarget.migratedID("2", screens: [builtIn, external]) == externalID,
            "a legacy external numeric ID migrates to its stable UUID")
        let reattachedExternal = TokenMonitorEdgeDockScreenTarget.Identity(
            numericID: 87, uuid: externalUUID, isBuiltIn: false
        )
        let reattachedBuiltIn = TokenMonitorEdgeDockScreenTarget.Identity(
            numericID: 55, uuid: builtInUUID, isBuiltIn: true
        )
        expect(
            TokenMonitorEdgeDockScreenTarget.index(for: externalID, in: [builtIn], preferredIndex: 0) == nil
                && TokenMonitorEdgeDockScreenTarget.index(for: externalID, in: [reattachedExternal], preferredIndex: 0) == 0,
            "fixed external target hides when disconnected and returns after numeric ID changes")
        expect(
            TokenMonitorEdgeDockScreenTarget.index(for: "builtin", in: [external], preferredIndex: 0) == nil
                && TokenMonitorEdgeDockScreenTarget.index(for: "builtin", in: [reattachedBuiltIn, external], preferredIndex: 1) == 0,
            "built-in target does not follow the main external screen and recovers after reconnect")
        expect(
            TokenMonitorEdgeDockScreenTarget.index(for: nil, in: [builtIn, external], preferredIndex: 1) == 1
                && TokenMonitorEdgeDockScreenTarget.targetAfterDrag(nil, originIndex: 0, destinationIndex: 0, screens: [builtIn, external]) == nil
                && TokenMonitorEdgeDockScreenTarget.targetAfterDrag(nil, originIndex: 0, destinationIndex: 1, screens: [builtIn, external]) == externalID,
            "follow mode honors the current screen and intentional cross-screen drops")
        expect(
            TokenMonitorEdgeDockScreenTarget.targetAfterDrag("builtin", originIndex: 0, destinationIndex: 1, screens: [builtIn, external]) == "builtin"
                && TokenMonitorEdgeDockScreenTarget.targetAfterDrag(externalID, originIndex: 1, destinationIndex: 0, screens: [builtIn, external]) == externalID,
            "dragging a fixed rail cannot silently change its target screen")

        let now = Date(timeIntervalSince1970: 1_790_380_800)
        let primary = TokenMonitorFloatingBubbleMetric(
            id: "five-hour", name: "5-hour", sourceID: "codex:a:five-hour",
            fetchedAt: now, value: .percentRemaining(100)
        )
        let exhausted = TokenMonitorFloatingBubbleMetric(
            id: "seven-day", name: "Weekly", sourceID: "codex:a:seven-day",
            fetchedAt: now, value: .percentRemaining(0)
        )
        let codex = TokenMonitorFloatingBubbleAccount(
            providerID: "codex", providerName: "Codex", accountID: "a",
            accountName: "Safe alias", metrics: [primary, exhausted]
        )
        let claude = TokenMonitorFloatingBubbleAccount(
            providerID: "claude", providerName: "Claude", accountID: "c",
            accountName: "Claude alias", metrics: [primary]
        )
        let usage = TokenMonitorDashboardSnapshot(response: response(now: now, tokens: Int64.max))
        // Bind the headline using official plan evidence, never aliases or metric order.
        expect(
            ["pro", " PRO ", "prolite", "pro-lite", "pro_lite"].allSatisfy {
                TokenMonitorEdgeDockProjection.codexPrimaryMetricID(plan: $0, readSucceeded: true) == "seven-day"
            }, "verified Pro variants select the weekly headline")
        expect(
            TokenMonitorEdgeDockProjection.codexPrimaryMetricID(plan: "Plus", readSucceeded: true) == "five-hour"
                && TokenMonitorEdgeDockProjection.codexPrimaryMetricID(plan: "pro", readSucceeded: false) == nil
                && TokenMonitorEdgeDockProjection.codexPrimaryMetricID(plan: nil, readSucceeded: true) == nil
                && TokenMonitorEdgeDockProjection.codexPrimaryMetricID(plan: "business", readSucceeded: true) == nil,
            "only a verified supported plan overrides the default window")
        var planAccount = codex
        planAccount.edgeDockPrimaryMetricID = "seven-day"
        planAccount.metrics = [
            .init(id: "five-hour", name: "5-hour", sourceID: "codex:a:five-hour", fetchedAt: now, value: .text("∞")),
            .init(id: "seven-day", name: "Weekly", sourceID: "codex:a:seven-day", fetchedAt: now, value: .percentRemaining(73), resetLabel: "weekly-reset"),
        ]
        func planCell(_ account: TokenMonitorFloatingBubbleAccount) -> TokenMonitorEdgeDockCell {
            TokenMonitorEdgeDockProjection.make(
                preferences: .init(items: [.account("codex", "a")]), quotaSources: [account], usage: usage, language: .en, now: now)[0]
        }
        let weeklyHeadline = planCell(planAccount)
        expect(
            weeklyHeadline.percentRemaining == 73 && weeklyHeadline.headlineValueLabel == nil
                && weeklyHeadline.headlineMetricID == "seven-day" && weeklyHeadline.headlineMetricName == "Weekly"
                && weeklyHeadline.headlineResetLabel == "weekly-reset" && weeklyHeadline.snapshotFetchedAt == now
                && weeklyHeadline.accounts[0].quotaRows[0].valueLabel == "∞",
            "Pro ring, percentage, window label and reset share weekly evidence while details preserve short-window infinity")
        planAccount.metrics[0].value = .percentRemaining(0)
        expect(
            planCell(planAccount).percentRemaining == 73,
            "an exhausted sibling window cannot replace the plan-selected weekly headline")
        planAccount.metrics[0].isStale = true
        expect(!planCell(planAccount).isStale, "a stale sibling cannot mark the selected fresh weekly headline stale")
        planAccount.metrics[0].isStale = false
        expect(
            [Double.nan, .infinity, -1, 101].allSatisfy { value in
                var invalid = planAccount
                invalid.metrics[1].value = .percentRemaining(value)
                let cell = planCell(invalid)
                return !cell.isAvailable && cell.percentRemaining == nil && cell.headlineValueLabel == nil
            }, "invalid weekly percentages remain unknown and never become infinity")
        var unavailable = planAccount
        unavailable.metrics[1].isAvailable = false
        expect(
            !planCell(unavailable).isAvailable && planCell(unavailable).headlineValueLabel == nil,
            "unavailable weekly evidence cannot substitute the short-window infinity")
        planAccount.metrics[1].value = .unknown
        let unknownWeekly = planCell(planAccount)
        expect(
            !unknownWeekly.isAvailable && unknownWeekly.percentRemaining == nil
                && unknownWeekly.headlineValueLabel == nil && unknownWeekly.headlineMetricID == "seven-day",
            "unknown weekly evidence cannot fall back to the short window")
        planAccount.metrics.removeLast()
        expect(
            !planCell(planAccount).isAvailable && planCell(planAccount).headlineMetricID == "seven-day",
            "a missing weekly window remains explicitly unknown")
        planAccount.metrics.append(
            .init(
                id: "seven-day", name: "Weekly", sourceID: "codex:a:seven-day", fetchedAt: now,
                isStale: true, value: .percentRemaining(73), resetLabel: "weekly-reset"))
        let staleWeekly = planCell(planAccount)
        expect(
            staleWeekly.percentRemaining == 73 && staleWeekly.isStale && staleWeekly.headlineMetricID == "seven-day",
            "stale weekly values retain their historical label and selected window")
        planAccount.edgeDockPrimaryMetricID = "five-hour"
        planAccount.metrics[0].value = .percentRemaining(82)
        planAccount.metrics[1].value = .percentRemaining(0)
        let plusHeadline = planCell(planAccount)
        expect(
            plusHeadline.percentRemaining == 82 && plusHeadline.headlineMetricID == "five-hour",
            "Plus always displays its five-hour window even when the weekly sibling is exhausted")
        planAccount.edgeDockPrimaryMetricID = nil
        planAccount.accountName = "🟢 PRO 20x"
        expect(
            planCell(planAccount).headlineMetricID == "seven-day" && planCell(planAccount).percentRemaining == 0,
            "an account alias does not select a plan; unknown plans retain the existing zero-window policy")
        let automatic = TokenMonitorEdgeDockProjection.make(
            preferences: defaults, quotaSources: [codex, claude], usage: usage,
            language: .en, now: now
        )
        expect(
            automatic.map(\.id) == ["proxy", "stat:today", "limit:claude", "limit:codex", "stat:liveRate"],
            "automatic rail exposes proxy settings ahead of usage and quota items"
        )
        expect(
            TokenMonitorEdgeDockProjection.make(
                preferences: explicit, quotaSources: [codex], usage: usage, language: .en, now: now
            ).isEmpty,
            "explicit empty composition stays empty"
        )

        var configured = defaults
        configured.items = [.limit("codex"), .stat(.allTime), .stat(.week), .stat(.liveRate)]
        let cells = TokenMonitorEdgeDockProjection.make(
            preferences: configured, quotaSources: [codex], usage: usage,
            language: .en, now: now
        )
        expect(cells[0].percentRemaining == nil && !cells[0].isAvailable, "active mode never guesses the local login")
        let active = TokenMonitorEdgeDockProjection.make(
            preferences: configured, quotaSources: [codex], usage: usage,
            language: .en, now: now, activeCodexAccountID: "a"
        )
        expect(active[0].percentRemaining == 0 && active[0].severityRemainingPercent == 0, "known exhausted window overrides a healthy primary")
        expect(active[0].accounts.first?.name == "Safe alias", "account row uses the owner-supplied safe alias")
        expect(active[1].tokenCount == Int64.max, "all-time total stays Int64 exact")
        expect(active[1].byTool.first?.tokens == Int64.max, "tool ranking stays Int64 exact above 2^53")
        expect(active[1].costUSD == nil, "missing cost remains unknown")
        expect(active[2].tokenCount == nil, "derived week with missing history coverage remains unknown")
        expect(active[3].liveRate == nil && !active[3].isAvailable, "live rate has no fabricated initial value")

        let grokWindow = TokenMonitorFloatingBubbleMetric(
            id: "credits", name: "Monthly", sourceID: "grok:g:credits", fetchedAt: now,
            value: .percentRemaining(63)
        )
        let grokBalance = TokenMonitorFloatingBubbleMetric(
            id: "balance", name: "Balance", sourceID: "grok:g:balance", fetchedAt: now,
            value: .text("7.50 USD")
        )
        let grok = TokenMonitorFloatingBubbleAccount(
            providerID: "grok", providerName: "Grok", accountID: "g",
            accountName: "Grok alias", metrics: [grokBalance, grokWindow]
        )
        let grokCell = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.account("grok", "g")]), quotaSources: [grok],
            usage: usage, language: .en, now: now
        )[0]
        expect(
            grokCell.percentRemaining == 63 && grokCell.headlineValueLabel == nil,
            "Grok subscription percentage wins over prepaid USD in the headline")
        expect(
            grokCell.accounts[0].quotaRows.first?.valueLabel == "7.50 USD",
            "Grok prepaid balance stays visible in details")
        var cachedWindow = grokWindow
        cachedWindow.fetchedAt = now.addingTimeInterval(-360)
        cachedWindow.isStale = true
        let cachedGrok = TokenMonitorFloatingBubbleAccount(
            providerID: "grok", providerName: "Grok", accountID: "g",
            accountName: "Grok alias", metrics: [cachedWindow, grokBalance]
        )
        let cachedCell = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.account("grok", "g")]), quotaSources: [cachedGrok],
            usage: usage, language: .en, now: now
        )[0]
        expect(
            cachedCell.isAvailable && cachedCell.isStale && cachedCell.percentRemaining == 63
                && cachedCell.severityRemainingPercent == nil,
            "cached Grok percentage remains visible as last recorded without a current severity signal")
        for providerID in ["codex", "kimi"] {
            var lastGood = primary
            lastGood.fetchedAt = now.addingTimeInterval(-601)
            lastGood.isStale = true
            lastGood.value = .percentRemaining(42)
            var account = TokenMonitorFloatingBubbleAccount(
                providerID: providerID, providerName: providerID, accountID: "cached",
                accountName: "Safe cached alias", metrics: [lastGood])
            func projected() -> TokenMonitorEdgeDockCell {
                TokenMonitorEdgeDockProjection.make(
                    preferences: .init(items: [.account(providerID, "cached")]), quotaSources: [account],
                    usage: usage, language: .en, now: now)[0]
            }
            let retained = projected()
            expect(
                retained.percentRemaining == 42 && retained.isStale && retained.severityRemainingPercent == nil,
                "\(providerID) retains a stale verified number without an actionable severity")
            expect(
                retained.snapshotFetchedAt == lastGood.fetchedAt && retained.snapshotFetchedAt != usage.collectedAt,
                "quota age comes from the selected metric, never usage collection")
            expect(
                retained.snapshotDescription(.en, now: now) == "Snapshot updated 10 min ago"
                    && retained.snapshotDescription(.zh, now: now) == "快照更新于 10 分钟前",
                "snapshot age is bilingual and uses the original read time")
            account.metrics[0].value = .percentRemaining(0)
            expect(projected().percentRemaining == 0, "real cached zero remains zero")
            account.metrics[0].value = .unknown
            expect(
                projected().percentRemaining == nil && !projected().isAvailable,
                "unknown quota never becomes zero")
            account.metrics[0].value = .percentRemaining(42)
            account.isLoggedIn = false
            expect(
                !projected().isAvailable && projected().snapshotFetchedAt == nil,
                "stale display cannot bypass a lost identity/login gate")
        }
        let historicalActive = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.limit("codex")]), quotaSources: [codex], usage: usage,
            language: .en, now: now, historicalCodexAccountID: "a")[0]
        expect(
            historicalActive.percentRemaining == 0 && historicalActive.isHistoricalAccount
                && historicalActive.title == "Codex · Last" && historicalActive.severityRemainingPercent == nil,
            "default active mode retains only explicitly marked non-actionable account history")
        expect(
            historicalActive.snapshotDescription(.en, now: now).contains("current identity unverified"),
            "historical account cannot be presented as the current identity")
        let restoredActive = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.limit("codex")]), quotaSources: [codex], usage: usage,
            language: .en, now: now, activeCodexAccountID: "a", historicalCodexAccountID: "other")[0]
        expect(
            !restoredActive.isHistoricalAccount && restoredActive.headlineAccountID == "a",
            "verified current identity replaces historical display")
        expect(
            TokenMonitorEdgeDockProjection.refreshTargets(
                preferences: .init(enabled: true, items: [.limit("codex")]), sources: [codex],
                codexDisplayAccountID: "a", codexSystemAccountID: "system") == ["codex": ["a", "system"]],
            "active manual and scheduled refresh include system identity verification despite display de-duplication")
        expect(
            TokenMonitorEdgeDockProjection.refreshTargets(
                preferences: .init(enabled: true, items: [.account("codex", "a")]), sources: [codex],
                codexDisplayAccountID: "a", codexSystemAccountID: "system") == ["codex": ["a"]],
            "fixed account refresh does not add an unrelated system read")
        let selectedTargets = TokenMonitorEdgeDockProjection.refreshTargets(
            preferences: .init(enabled: true, items: [.account("grok", "g"), .limit("grok")]),
            sources: [codex, grok], codexDisplayAccountID: "a")
        expect(selectedTargets == ["grok": ["g"]], "selected account/provider share one refresh target")
        expect(
            TokenMonitorEdgeDockProjection.refreshTargets(
                preferences: .init(enabled: true, items: []), sources: [codex, grok], codexDisplayAccountID: "a"
            ).isEmpty,
            "explicitly empty dock never starts account reads")
        var hiddenRefresh = TokenMonitorEdgeDockItem.limit("grok")
        hiddenRefresh.hiddenAccountIDs = ["g"]
        expect(
            TokenMonitorEdgeDockProjection.refreshTargets(
                preferences: .init(enabled: true, items: [hiddenRefresh]), sources: [grok], codexDisplayAccountID: nil
            ).isEmpty,
            "hidden dock account is excluded from scheduled refresh")
        var refreshedGrok = grok
        refreshedGrok.metrics[1].value = .percentRemaining(99)
        let refreshedCell = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.account("grok", "g")]), quotaSources: [refreshedGrok],
            usage: usage, language: .en, now: now
        )[0]
        expect(
            refreshedCell.percentRemaining == 99 && !refreshedCell.isStale,
            "a completed quota read replaces the cached headline and clears its stale marker")
        var loggedOutGrok = cachedGrok
        loggedOutGrok.isLoggedIn = false
        let loggedOutCell = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.account("grok", "g")]), quotaSources: [loggedOutGrok],
            usage: usage, language: .en, now: now
        )[0]
        expect(
            !loggedOutCell.isAvailable && loggedOutCell.percentRemaining == nil,
            "cached quota never bypasses the login or identity gate")
        let balanceOnlyGrok = TokenMonitorFloatingBubbleAccount(
            providerID: "grok", providerName: "Grok", accountID: "g",
            accountName: "Grok alias", metrics: [grokBalance]
        )
        let unknownGrok = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.account("grok", "g")]), quotaSources: [balanceOnlyGrok],
            usage: usage, language: .en, now: now
        )[0]
        expect(
            !unknownGrok.isAvailable && unknownGrok.percentRemaining == nil && unknownGrok.headlineValueLabel == nil,
            "Grok balance alone never becomes a subscription percentage")
        var expiredWindow = grokWindow
        expiredWindow.isStale = true
        expiredWindow.isAvailable = false
        let expiredGrok = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.account("grok", "g")]),
            quotaSources: [
                .init(
                    providerID: "grok", providerName: "Grok", accountID: "g",
                    accountName: "Grok alias", metrics: [expiredWindow, grokBalance])
            ],
            usage: usage, language: .en, now: now
        )[0]
        expect(
            !expiredGrok.isAvailable && expiredGrok.isStale,
            "expired Grok subscription is stale even when prepaid balance remains known")
        let claudeBalance = TokenMonitorFloatingBubbleMetric(
            id: "balance", name: "Balance", sourceID: "claude:c:balance", fetchedAt: now,
            value: .text("12.34 USD")
        )
        let claudeWithBalance = TokenMonitorFloatingBubbleAccount(
            providerID: "claude", providerName: "Claude", accountID: "c",
            accountName: "Claude alias", metrics: [primary, claudeBalance]
        )
        let claudeCell = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.account("claude", "c")]), quotaSources: [claudeWithBalance],
            usage: usage, language: .en, now: now
        )[0]
        expect(
            claudeCell.headlineValueLabel == "12.34 USD" && claudeCell.percentRemaining == nil
                && claudeCell.severityRemainingPercent == nil,
            "Claude headline uses the observed balance and currency, never a percent")
        let unknownClaude = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.account("claude", "c")]), quotaSources: [claude],
            usage: usage, language: .en, now: now
        )[0]
        expect(
            !unknownClaude.isAvailable && unknownClaude.headlineValueLabel == nil,
            "Claude without an observed balance remains unknown")

        // A shared session index must use current JSON even when requestId is
        // reused. Provider detail is Codex-only; generic history covers all clients.
        func session(_ client: String, at date: Date, ended: Bool = false) -> TokenMonitorJSON {
            .object([
                "client": .string(client),
                "lastUsedAt": .string(ISO8601DateFormatter().string(from: date)),
                "turnEnded": .bool(ended), "totalTokens": .number(10),
            ])
        }
        var sessionResult = response(now: now, tokens: 10)
        let older = now.addingTimeInterval(-100)
        let newer = now.addingTimeInterval(-40)
        func sessionPayload(_ month: [String: TokenMonitorJSON], today: [String: TokenMonitorJSON]) -> TokenMonitorJSON {
            .object([
                "aggregate": .object([
                    "month": .object(["sessions": .object(month)]),
                    "today": .object(["sessions": .object(today)]),
                ])
            ])
        }
        sessionResult.payload = sessionPayload(
            [
                "c1": session("codex", at: older), "c2": session("codex", at: newer),
                "g1": session("grok", at: now), "k1": session("kimi", at: now),
                "x1": session("custom-cli", at: now.addingTimeInterval(-10)),
            ],
            today: ["c1": session("grok", at: now), "c3": session("codex", at: now.addingTimeInterval(-20))]
        )
        let kimi = TokenMonitorFloatingBubbleAccount(
            providerID: "kimi", providerName: "Kimi", accountID: "k",
            accountName: "Kimi alias",
            metrics: [
                .init(
                    id: "credits", name: "Credits", sourceID: "kimi:k:credits", fetchedAt: now,
                    value: .text("5 credits"))
            ]
        )
        let sessionPreferences = TokenMonitorEdgeDockPreferences(items: [
            .limit("codex"), .limit("grok"), .limit("kimi"), .stat(.sessions),
        ])
        func sessionCells(_ result: TokenMonitorResponse, preferences: TokenMonitorEdgeDockPreferences = sessionPreferences) -> [TokenMonitorEdgeDockCell] {
            TokenMonitorEdgeDockProjection.make(
                preferences: preferences, quotaSources: [codex, grok, kimi],
                usage: TokenMonitorDashboardSnapshot(response: result), language: .en, now: now
            )
        }
        let firstSessions = sessionCells(sessionResult)
        expect(
            firstSessions[0].sessions.map(\.id) == ["c3", "c2", "c1"],
            "Codex provider keeps only its sessions; month wins duplicate IDs")
        expect(
            Set(firstSessions[3].sessions.prefix(2).map(\.id)) == Set(["g1", "k1"])
                && firstSessions[3].sessions.dropFirst(2).first?.id == "x1"
                && firstSessions[3].sessions.suffix(3).map(\.id) == ["c3", "c2", "c1"]
                && firstSessions[3].sessionCount == 6,
            "generic session history retains all valid clients in descending date order")
        expect(
            firstSessions[1].sessions.isEmpty && firstSessions[1].sessionCount == nil
                && firstSessions[2].sessions.isEmpty && firstSessions[2].sessionCount == nil
                && firstSessions[1].isAvailable && firstSessions[2].isAvailable
                && firstSessions[2].headlineValueLabel == "5 credits",
            "Grok and Kimi keep account and quota cards without session detail monitoring")
        sessionResult.payload = sessionPayload(
            ["c1": session("grok", at: older), "c2": session("codex", at: newer, ended: true)],
            today: ["c3": session("codex", at: now.addingTimeInterval(-20))]
        )
        let changedSessions = sessionCells(sessionResult)
        expect(
            changedSessions[0].sessions.map(\.id) == ["c3", "c2"]
                && changedSessions[0].sessions.first(where: { $0.id == "c2" })?.turnEnded == true
                && changedSessions[3].sessions.map(\.id) == ["c3", "c2", "c1"]
                && changedSessions[3].sessions.last?.clientID == "grok",
            "same-request client and status changes invalidate both index views")
        var runningOnly = sessionPreferences
        var runningSessionItem = TokenMonitorEdgeDockItem.stat(.sessions)
        runningSessionItem.runningOnly = true
        runningOnly.items = [runningSessionItem]
        expect(
            sessionCells(sessionResult, preferences: runningOnly)[0].sessions.map(\.id) == ["c3", "c1"],
            "generic running history keeps other clients but omits ended rows")
        sessionResult.collectedAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(700))
        expect(
            sessionCells(sessionResult, preferences: runningOnly)[0].sessions.isEmpty,
            "a changed collection time invalidates running-session freshness")

        var inputGate = TokenMonitorEdgeDockChangeGate<Int>()
        expect(inputGate.accept(0), "initial Edge Dock evidence draws immediately")
        var redundantSyncs = 0
        for _ in 0..<100 {
            if inputGate.accept(0) { redundantSyncs += 1 }
        }
        expect(
            redundantSyncs == 0 && inputGate.accept(1) && !inputGate.accept(1),
            "100 unrelated publications are ignored; one changed input passes once")
        var outputGate = TokenMonitorEdgeDockChangeGate<[TokenMonitorEdgeDockCell]>()
        let identicalConfigures = [cells, cells].filter { outputGate.accept($0) }.count
        expect(identicalConfigures == 1, "identical final cells configure native surfaces once")
        expect(
            !TokenMonitorEdgeDockIdlePolicy.shouldClearOutside(
                hasCard: false, railVisible: true, mode: .always, pinned: false),
            "moving away from an already empty always-visible rail does not redraw")
        expect(
            TokenMonitorEdgeDockIdlePolicy.shouldClearOutside(
                hasCard: true, railVisible: true, mode: .always, pinned: false)
                && TokenMonitorEdgeDockIdlePolicy.shouldClearOutside(
                    hasCard: false, railVisible: true, mode: .autoHide, pinned: false),
            "an open card closes and an unpinned auto-hide rail retracts")
        expect(
            TokenMonitorEdgeDockIdlePolicy.tickInterval(
                nearEdge: false, hasCard: false, dragging: false, waitingOutside: false) == 0.2
                && TokenMonitorEdgeDockIdlePolicy.tickInterval(
                    nearEdge: true, hasCard: false, dragging: false, waitingOutside: false) == 0.05
                && TokenMonitorEdgeDockIdlePolicy.tickInterval(
                    nearEdge: false, hasCard: false, dragging: true, waitingOutside: false) == 0.05,
            "idle polling is low frequency while near-edge and drag polling stays responsive")

        let secondAccount = TokenMonitorFloatingBubbleAccount(
            providerID: "codex", providerName: "Codex", accountID: "b",
            accountName: "02 Second", metrics: [primary]
        )
        let pinnedItems: [TokenMonitorEdgeDockItem] = [.account("codex", "b"), .account("codex", "a"), .account("codex", "removed")]
        var pinned = defaults
        pinned.mode = .always
        pinned.items = pinnedItems + [.account("codex", "a")]
        let restoredPinned = TokenMonitorEdgeDockPreferences.load(try? JSONEncoder().encode(pinned))
        expect(restoredPinned.items == pinnedItems && restoredPinned.mode == .always, "account selection, order and always-visible mode persist without duplicates")
        let pinnedCells = TokenMonitorEdgeDockProjection.make(
            preferences: restoredPinned, quotaSources: [codex, secondAccount], usage: usage,
            language: .en, now: now, activeCodexAccountID: "a"
        )
        expect(pinnedCells.map(\.percentRemaining) == [100, 0, nil], "multiple selected accounts retain separate quotas regardless of the Desktop login")
        expect(pinnedCells[0].accountLabel == "02 Second" && pinnedCells[0].accounts.map(\.id) == ["b"], "pinned account shows its numbered alias and only its own details")
        expect(!pinnedCells[2].isAvailable && pinnedCells[2].accounts.isEmpty, "removed selected account stays unavailable instead of switching to another identity")
        expect(
            pinnedCells[2].accountLabel == nil && pinnedCells[2].accountBadge == nil && pinnedCells[2].accountBindingMissing
                && pinnedCells[2].headlineValueLabel == "Unmatched", "missing account binding never becomes a minus-shaped badge or another account’s quota")
        expect(pinnedCells[0].accountBadge == "02", "verified account shorthand stays visible")
        var placeholder = pinnedCells[0]
        placeholder.accountLabel = " — "
        expect(placeholder.accountBadge == nil, "placeholder account names do not render a false button")
        let localClaude = TokenMonitorFloatingBubbleAccount(
            providerID: "claudeCode", providerName: "Claude Code", accountID: "local-claude",
            accountName: "Local login",
            metrics: [
                .init(
                    id: "balance", name: "Balance", sourceID: "fixture:claude:balance",
                    fetchedAt: now, value: .text("12.34 USD"))
            ])
        let oldClaudePreference = TokenMonitorEdgeDockPreferences.load(
            Data(
                #"{"enabled":true,"items":[{"type":"limit","providerID":"claudecode","accountID":"local-claude"}]}"#.utf8))
        let migratedClaude = TokenMonitorEdgeDockProjection.make(
            preferences: oldClaudePreference,
            quotaSources: [localClaude], usage: usage, language: .en, now: now)
        expect(
            oldClaudePreference.items?.first?.providerID == "claude"
                && oldClaudePreference.items?.first?.accountID == "local-claude"
                && migratedClaude.first?.headlineValueLabel == "12.34 USD"
                && migratedClaude.first?.accountBindingMissing == false,
            "existing Claude Code account selections match native provider aliases without changing identity")
        expect(
            TokenMonitorEdgeDockItem.account("claudeCode", "local-claude").id == oldClaudePreference.items?.first?.id,
            "the account checkbox and persisted item use the same canonical identity")
        expect(
            TokenMonitorEdgeDockProjection.automaticItems([localClaude]).contains { $0.providerID == "claude" },
            "automatic provider discovery canonicalizes native IDs too")
        expect(pinnedCells[0].tokenCount == nil && pinnedCells[0].sessions.isEmpty, "provider-wide token usage is not attributed to a pinned account")
        let embeddedSettings = Data(
            #"{"edgeDockEnabled":true,"edgeDockMode":"always","edgeDockSide":"left","edgeDockOffset":0.7,"edgeDockItems":[{"type":"limit","provider":"codex","hiddenAccounts":["hidden"],"accountMode":"active"},{"type":"stat","metric":"sessions","runningOnly":true}]}"#
                .utf8)
        let migrated = TokenMonitorEdgeDockPreferences.migratedEmbeddedSettings(embeddedSettings)
        expect(migrated?.enabled == true && migrated?.mode == .always && migrated?.side == .left && migrated?.offset == 0.7, "embedded dock retains visibility and placement")
        expect(migrated?.items?.first?.hiddenAccountIDs == ["hidden"] && migrated?.items?.last?.runningOnly == true, "embedded dock retains account filtering and session options")
        let emptyMigrated = TokenMonitorEdgeDockPreferences.migratedEmbeddedSettings(Data(#"{"edgeDockEnabled":false,"edgeDockItems":[]}"#.utf8))
        expect(emptyMigrated?.enabled == false && emptyMigrated?.items == [], "migration never enables a disabled dock or fills an explicit empty list")
        expect(TokenMonitorEdgeDockPreferences.migratedEmbeddedSettings(Data("invalid".utf8)) == nil, "invalid embedded settings do not become a preference write")
        let oldItem = try? JSONDecoder().decode(TokenMonitorEdgeDockItem.self, from: Data(#"{"type":"limit","providerID":"codex"}"#.utf8))
        expect(oldItem?.id == "limit:codex" && oldItem?.accountID == nil, "previous provider summary settings retain their meaning")
        expect(TokenMonitorEdgeDockItem.account("codex", "  ").normalized() == nil, "blank account binding cannot become a provider summary")
        let pages = (0..<8).map { TokenMonitorEdgeDockPage.make(cellCount: 24, availableHeight: 250, index: $0) }
        expect(pages.flatMap { Array($0.indices) } == Array(0..<24), "all 24 selected accounts remain reachable on a short display")
        expect(TokenMonitorEdgeDockPage.make(cellCount: 2, availableHeight: 250, index: 7).indices == 0..<2, "shrinking the list clamps the current page")

        var proxyPreferences = TokenMonitorEdgeDockPreferences(items: [.account("codex", "b"), .proxy(), .proxy(), .stat(.today)])
        let proxyRestored = TokenMonitorEdgeDockPreferences.load(try? JSONEncoder().encode(proxyPreferences))
        expect(proxyRestored.items?.map(\.id) == ["limit:codex:account:b", "proxy", "stat:today"], "proxy shortcut persists once at the chosen position")
        for phase in [LocalProxyPhase.stopped, .starting, .running, .stopping, .failed] {
            let projected = TokenMonitorEdgeDockProjection.make(
                preferences: proxyRestored, quotaSources: [], usage: usage, language: .en,
                now: now, proxyPhase: phase
            )[1]
            expect(projected.kind == .proxy && projected.proxyPhase == phase && projected.isAvailable, "proxy settings remain reachable in every lifecycle state")
            expect(
                projected.accounts.isEmpty && projected.headlineAccountID == nil && projected.percentRemaining == nil, "proxy shortcut does not expose or impersonate an account")
        }
        func proxyRow(_ id: String, number: Int, current: Bool, requests: Int, stale: Bool = false) -> LocalProxyQueueRow {
            LocalProxyQueueRow(
                id: id, label: "Safe \(id)", accountNumber: number,
                windows: [.init(id: "5h", remaining: nil, resetsAt: nil)], snapshotStale: stale,
                isEnabled: true, isPriority: false, isCurrent: current, quotaText: nil,
                state: current ? "current" : "ready", cooldownUntil: nil, activeRequestCount: requests)
        }
        let liveRows = [
            proxyRow("b", number: 11, current: true, requests: 2, stale: true),
            proxyRow("idle", number: 1, current: false, requests: 0),
            proxyRow("a", number: 3, current: true, requests: 1),
            proxyRow("late", number: 4, current: true, requests: 0),
        ]
        func liveProxy(_ phase: LocalProxyPhase, rows: [LocalProxyQueueRow]) -> TokenMonitorEdgeDockCell {
            TokenMonitorEdgeDockProjection.make(
                preferences: .init(items: [.proxy()]), quotaSources: [codex], usage: usage,
                language: .en, now: now, activeCodexAccountID: "idle", proxyPhase: phase, proxyRows: rows)[0]
        }
        let liveProxyCell = liveProxy(.running, rows: liveRows)
        expect(
            liveProxyCell.proxyAccounts.map(\.id) == ["a", "b"] && liveProxyCell.proxyRequestCount == 3,
            "proxy hover shows all admitted accounts in panel-number order, not the Desktop login or enabled queue")
        expect(
            liveProxyCell.proxyAccounts.last?.snapshotStale == true && liveProxyCell.proxyAccounts.first?.windows.first?.remaining == nil,
            "stale and unknown quota remain distinct from real running requests")
        expect(liveProxy(.running, rows: []).proxyStatusTitle(.en) == "Idle", "running service without requests is explicitly idle")
        expect(liveProxy(.stopping, rows: liveRows).proxyRequestCount == 3, "draining requests remain visible until release")
        for phase in [LocalProxyPhase.stopped, .starting, .failed] {
            expect(liveProxy(phase, rows: liveRows).proxyAccounts.isEmpty, "inactive service cannot expose leftover running rows")
        }
        expect(
            liveProxy(.running, rows: Array(liveRows.dropFirst())).proxyAccounts.map(\.id) == ["a"],
            "released requests disappear from the next projection without changing the selected icon")
        proxyPreferences.items = [.stat(.today), .proxy(), .account("codex", "b")]
        let reorderedProxy = TokenMonitorEdgeDockPreferences.load(try? JSONEncoder().encode(proxyPreferences))
        expect(reorderedProxy.items?.map(\.id) == ["stat:today", "proxy", "limit:codex:account:b"], "proxy shortcut can be reordered alongside accounts and statistics")
        proxyPreferences.items?.removeAll { $0.type == .proxy }
        let removedProxy = TokenMonitorEdgeDockPreferences.load(try? JSONEncoder().encode(proxyPreferences))
        expect(
            !TokenMonitorEdgeDockProjection.make(
                preferences: removedProxy, quotaSources: [], usage: usage, language: .en, proxyPhase: .running
            ).contains { $0.kind == .proxy }, "running proxy never re-adds an explicitly removed shortcut")

        let tracker = TokenMonitorEdgeDockRateTracker()
        expect(tracker.observe(response: rateResponse(now: now, tokens: 100, output: 40, duration: 1_000), now: now) == nil, "first counters establish a baseline")
        let second = now.addingTimeInterval(1)
        let rate = tracker.observe(response: rateResponse(now: second, tokens: 220, output: 90, duration: 2_000), now: second)
        expect(rate?.speed == 50 && rate?.burn == 7_200 && rate?.isIdle == false, "rate divides measured token increments by measured model duration")
        let zeroOutput = tracker.observe(response: rateResponse(now: second, tokens: 230, output: 90, duration: 2_500), now: second)
        expect(zeroOutput?.speed == 0 && zeroOutput?.burn == 1_200, "a measured zero output rate remains a real zero")
        let equal = tracker.observe(response: rateResponse(now: second, tokens: 230, output: 90, duration: 2_500), now: second)
        expect(equal?.speed == 0, "equal snapshots retain the most recent measured sample")
        expect(tracker.current(now: second.addingTimeInterval(7.99))?.isIdle == false, "sample remains active before eight seconds")
        expect(tracker.current(now: second.addingTimeInterval(8))?.isIdle == true, "sample becomes idle at eight seconds")
        expect(tracker.current(now: second.addingTimeInterval(180)) == nil, "retained sample clears at three minutes")
        expect(tracker.observe(response: rateResponse(now: second, tokens: 1, output: 1, duration: 1), now: second) == nil, "regressed counters reset the sample")
        expect(tracker.observe(response: rateResponse(now: second, tokens: 2, output: 2, duration: 1), now: second) == nil, "zero duration increment does not manufacture a rate")
        expect(
            tracker.observe(response: rateResponse(now: second, tokens: 3, output: 3, duration: 2, throughput: false), now: second) == nil,
            "unsupported throughput clears the sample")
        let newDay = now.addingTimeInterval(86_400)
        expect(tracker.observe(response: rateResponse(now: newDay, tokens: 10, output: 5, duration: 10), now: newDay) == nil, "midnight starts a new counter baseline")
        expect(
            tracker.observe(
                response: rateResponse(now: newDay.addingTimeInterval(1), tokens: 11, output: 6, duration: 11, sourceID: "new-source"), now: newDay.addingTimeInterval(1)) == nil,
            "source changes reset the baseline")
        let huge = TokenMonitorEdgeDockRateTracker()
        let large = Int64.max - 5
        _ = huge.observe(response: rateResponse(now: now, tokens: large, output: large, duration: large), now: now)
        let hugeSample = huge.observe(response: rateResponse(now: second, tokens: large + 4, output: large + 2, duration: large + 1), now: second)
        expect(hugeSample?.speed == 2_000 && hugeSample?.burn == 240_000, "Int64 counter deltas remain exact above 2^53")

        if failures.isEmpty {
            print("token-monitor edge dock self-test passed: composition, quota, display, de-duplication, idle, timed rate")
            return true
        }
        failures.forEach { print("token-monitor edge dock self-test failed: \($0)") }
        return false
    }

    private static func response(now: Date, tokens: Int64) -> TokenMonitorResponse {
        let day = ISO8601DateFormatter().string(from: now)
        let allTime: TokenMonitorJSON = .object([
            "totalTokens": .number(Decimal(tokens)),
            "clients": .object(["codex": .number(Decimal(tokens))]),
        ])
        return TokenMonitorResponse(
            schemaVersion: 1, requestId: "edge-dock-fixture", operation: .collectUsage,
            engine: .init(repository: "Javis603/token-monitor", commit: TokenMonitorResponse.commit, version: "fixture"),
            collectedAt: day, timezone: "UTC", status: .ok, sources: [],
            payload: .object([
                "aggregate": .object(["allTime": allTime, "today": .object([:])]),
                "history": .object(["summary": .object(["totalTokens": .number(Decimal(tokens))]), "daily": .array([])]),
            ]),
            coverage: .init(entries: [], days: [], cost: .unknown), errors: []
        )
    }

    private static func rateResponse(
        now: Date, tokens: Int64, output: Int64, duration: Int64,
        throughput: Bool = true, sourceID: String = "source"
    ) -> TokenMonitorResponse {
        var value = response(now: now, tokens: tokens)
        value.sources = [.init(id: sourceID, providerId: "codex", status: .ok, coverage: .known, reasonCode: nil)]
        value.payload = .object([
            "aggregate": .object([
                "today": .object([
                    "timedTokens": .number(Decimal(tokens)),
                    "timedOutputTokens": .number(Decimal(output)),
                    "timedDurationMs": .number(Decimal(duration)),
                    "capabilities": .object(["throughput": .bool(throughput)]),
                ])
            ])
        ])
        return value
    }
}
