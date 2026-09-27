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
        let automatic = TokenMonitorEdgeDockProjection.make(
            preferences: defaults, quotaSources: [codex, claude], usage: usage,
            language: .en, now: now
        )
        expect(
            automatic.map(\.id) == ["stat:today", "limit:claude", "limit:codex", "stat:liveRate"],
            "automatic rail places Today, connected providers and rate in upstream display order"
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
            print("token-monitor edge dock self-test passed: composition, quota, exact ranks, unknowns, timed rate")
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
