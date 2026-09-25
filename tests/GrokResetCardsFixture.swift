import Foundation

// Offline synthetic fixture for the Grok reset-card presentation and sorting rules.
// Every card below is SYNTHETIC: the official Grok billing response carries no
// reset-card fields (review-inputs/grok-reset-schema-0911v1.json,
// resetCardFieldsPresent=false), so these values never come from a live API.
// The fixture compiles the real Domain and reader sources with a stub language type.

enum WidgetLanguage {
    case zh
    case en
    var locale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_US") }
    var isChinese: Bool { self == .zh }
    static func storedOrAutomatic() -> Self { .zh }
    func text(_ zh: String, _ en: String) -> String { zh }
}

private enum FixtureFailure: Error { case assertion(String) }

private func expect(_ condition: Bool, _ label: String) throws {
    guard condition else { throw FixtureFailure.assertion(label) }
}

private func require<T>(_ value: T?, _ label: String) throws -> T {
    guard let value else { throw FixtureFailure.assertion(label) }
    return value
}

@main
struct GrokResetCardsFixture {
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)  // fixed synthetic clock
        try testUnknownAndEmpty(now: now)
        try testExpiringBoundaries(now: now)
        try testMultipleCards(now: now)
        try testStaleEvidence(now: now)
        try testTimeZoneDisplay()
        try testSorting()
        try testFreshnessAndGlobalPins(now: now)
        try testOfficialObservationBoundaries(now: now)
        try testObservationImporterAndIdentityMerge(now: now)
        try testCardEvidenceMerge(now: now)
        try testProductionParseKeepsNil(now: now)
        print("PASS grok-reset-cards fixture")
    }

    private static func card(_ id: String, expiresIn: TimeInterval?, from now: Date) -> LocalCLIResetCard {
        LocalCLIResetCard(id: id, expiresAt: expiresIn.map { now.addingTimeInterval($0) })
    }

    // nil = unknown (production today); empty = known zero. Neither may show a count.
    private static func testUnknownAndEmpty(now: Date) throws {
        try expect(!ResetCardPresentation.isExpiringSoon(nil, now: now), "nil cards never expire")
        try expect(ResetCardPresentation.earliestValidExpiry(nil, now: now) == nil, "nil cards have no expiry")
        try expect(
            ResetCardPresentation.summaryText(nil, now: now, timeZone: .current, language: .zh)
                == "重置卡信息暂不可用",
            "nil cards show unavailable text")
        try expect(!ResetCardPresentation.isExpiringSoon([], now: now), "empty cards never expire")
        try expect(
            ResetCardPresentation.summaryText([], now: now, timeZone: .current, language: .zh) == nil,
            "known empty cards hide the summary instead of showing 0")
    }

    // 72h rule: 0 < remaining <= 72h, expired never counts.
    private static func testExpiringBoundaries(now: Date) throws {
        try expect(ResetCardPresentation.isExpiringSoon([card("a", expiresIn: 72 * 3600, from: now)], now: now), "exact 72h boundary is expiring")
        try expect(!ResetCardPresentation.isExpiringSoon([card("a", expiresIn: 72 * 3600 + 1, from: now)], now: now), "72h+1s is not expiring")
        try expect(ResetCardPresentation.isExpiringSoon([card("a", expiresIn: 3600, from: now)], now: now), "1h is expiring")
        try expect(!ResetCardPresentation.isExpiringSoon([card("a", expiresIn: -3600, from: now)], now: now), "expired card is not expiring")
        try expect(ResetCardPresentation.earliestValidExpiry([card("a", expiresIn: -3600, from: now)], now: now) == nil, "expired card has no valid expiry")
        try expect(!ResetCardPresentation.isExpiringSoon([card("a", expiresIn: nil, from: now)], now: now), "unknown card expiry is not expiring")
    }

    // Earliest valid expiry wins; a later or expired card must not mask it.
    private static func testMultipleCards(now: Date) throws {
        let cards = [card("late", expiresIn: 48 * 3600, from: now), card("early", expiresIn: 10 * 3600, from: now)]
        try expect(ResetCardPresentation.isExpiringSoon(cards, now: now), "multi-card set is expiring")
        try expect(ResetCardPresentation.earliestValidExpiry(cards, now: now) == now.addingTimeInterval(10 * 3600), "earliest card expiry wins")
        let mixed = [card("expired", expiresIn: -3600, from: now), card("valid", expiresIn: 5 * 3600, from: now)]
        try expect(ResetCardPresentation.earliestValidExpiry(mixed, now: now) == now.addingTimeInterval(5 * 3600), "expired card does not mask valid one")
        let summary = try require(
            ResetCardPresentation.summaryText(cards, now: now, timeZone: .current, language: .zh),
            "multi-card summary exists")
        try expect(summary.contains("2 张重置卡"), "multi-card count shown")
    }

    // Stale evidence (previous snapshot after a failed refresh) never reads as expiring.
    private static func testStaleEvidence(now: Date) throws {
        let cards = [card("a", expiresIn: 3600, from: now)]
        try expect(!ResetCardPresentation.isExpiringSoon(cards, now: now, evidenceFresh: false), "stale evidence is not expiring")
        try expect(ResetCardPresentation.isExpiringSoon(cards, now: now, evidenceFresh: true), "fresh evidence is expiring")
    }

    private static func testFreshnessAndGlobalPins(now: Date) throws {
        for (age, fresh) in [(0.0, true), (300.0, true), (301.0, false), (-1.0, false)] {
            try expect(ResetCardPresentation.isFresh(now.addingTimeInterval(-age), now: now) == fresh, "freshness boundary")
        }
        let pin = ResetCardPresentation.codexKey("fixture-pro")
        let grok = ResetCardPresentation.localKey(kind: "grok", profileID: "fixture-grok")
        let other = ResetCardPresentation.codexKey("fixture-other")
        try expect(
            ResetCardPresentation.savedOrder([other, pin, grok], pinnedAccountID: pin) == [pin, other, grok],
            "cross-provider pin stays first without expiry reordering")
        let valid = now.addingTimeInterval(3600)
        try expect(ResetCardPresentation.codexIsExpiring(available: 1, expiries: [valid], fetchedAt: now, readSucceeded: true, now: now), "fresh Codex card expires")
        try expect(
            !ResetCardPresentation.codexIsExpiring(available: 1, expiries: [valid], fetchedAt: now, readSucceeded: false, now: now), "failed read cannot prioritize a Codex card")
        let unknown = ResetCardPresentation.summaryText([card("unknown", expiresIn: nil, from: now)], now: now, timeZone: .current, language: .zh)
        try expect(unknown?.contains("到期待确认") == true, "known card with unknown expiry retains count")
        let mixed = ResetCardPresentation.summaryText(
            [card("old", expiresIn: -1, from: now), card("future", expiresIn: 1, from: now)], now: now, timeZone: .current, language: .zh)
        try expect(mixed?.contains("1 张重置卡") == true, "expired cards are not counted as available")
    }

    private static func observation(
        fingerprint: String,
        strings: [String] = GrokResetStatusObservation.officialAvailableStrings,
        observedAt: Date,
        sourceURL: String = "https://grok.com/settings"
    ) -> GrokResetStatusObservation {
        GrokResetStatusObservation(
            accountFingerprint: fingerprint,
            visibleStrings: strings,
            observedAt: observedAt,
            sourceURL: sourceURL)
    }

    private static func quota(
        fingerprint: String?,
        fetchedAt: Date,
        cards: [LocalCLIResetCard]? = nil,
        cardsObservedAt: Date? = nil,
        observation: GrokResetStatusObservation? = nil
    ) -> LocalCLIQuotaResult {
        LocalCLIQuotaResult(
            state: .available,
            fetchedAt: fetchedAt,
            maskedIdentity: nil,
            identityFingerprint: fingerprint,
            planLabel: "synthetic",
            windows: [],
            balance: nil,
            balanceCurrency: nil,
            sourceLabel: "Grok CLI billing",
            messageCode: nil,
            resetCards: cards,
            resetCardsObservedAt: cardsObservedAt,
            grokResetObservation: observation)
    }

    private static func testOfficialObservationBoundaries(now: Date) throws {
        let fingerprint = String(repeating: "a", count: 64)
        let exact = observation(fingerprint: fingerprint, observedAt: now)
        try expect(exact.isStructurallyValid(), "official observation shape is valid")
        try expect(exact.evidence == .availableUnknownCountAndExactExpiry, "available status keeps count and exact expiry unknown")
        try expect(exact.displayTitle == "Usage Limit Reset", "official title is retained exactly")
        try expect(exact.displayDetail == "Reset Available · Expires in 1 day", "official detail is retained exactly")
        try expect(exact.relativeExpiryText == "Expires in 1 day", "relative expiry stays separate from status")
        try expect(
            exact.availableCount == nil && exact.exactExpiry == nil
                && exact.mayAffectPriority(at: now) && !exact.mayAuthorizeRedemption,
            "fresh exact status can prioritize without inventing count, expiry, or redemption authority")
        try expect(exact.isFresh(at: now), "observation at the clock is fresh")
        try expect(exact.isFresh(at: now.addingTimeInterval(300)), "exact 300-second observation is fresh")
        try expect(!exact.isFresh(at: now.addingTimeInterval(301)), "301-second observation is stale")
        try expect(
            exact.currentStatus(at: now.addingTimeInterval(301)) == nil
                && !exact.mayAffectPriority(at: now.addingTimeInterval(301)),
            "stale available observation is history, not a current status or priority signal")
        try expect(
            exact.datedDisplayDetail?.contains("Observed") == true,
            "stale-capable detail keeps an observation date")

        let future = observation(fingerprint: fingerprint, observedAt: now.addingTimeInterval(1))
        try expect(!future.isValid(at: now), "future observation is rejected")
        try expect(!future.isFresh(at: now), "future observation is never fresh")

        let punctuationAndWhitespace = observation(
            fingerprint: fingerprint,
            strings: ["  Usage   Limit Reset. ", "\tReset Available:\t", "Expires   in  2  days!"],
            observedAt: now)
        try expect(
            punctuationAndWhitespace.isStructurallyValid()
                && punctuationAndWhitespace.evidence == .availableUnknownCountAndExactExpiry,
            "bounded punctuation and horizontal whitespace variants remain importable")
        try expect(
            punctuationAndWhitespace.displayTitle?.hasPrefix("  Usage") == true
                && punctuationAndWhitespace.displayDetail?.contains("Expires   in  2  days!") == true,
            "original visible strings are retained for display")
        try expect(
            punctuationAndWhitespace.relativeExpiryText == "Expires   in  2  days!",
            "other official relative dates stay text-only")

        for relative in ["Expires in 3 hours", "Expires in 2 weeks", "Expires in 1 month"] {
            let variant = observation(fingerprint: fingerprint, strings: ["Usage Limit Reset", "Reset Available", relative], observedAt: now)
            try expect(variant.evidence == .availableUnknownCountAndExactExpiry, "bounded relative date is available: \(relative)")
        }
        let malformedRelative = observation(
            fingerprint: fingerprint,
            strings: ["Usage Limit Reset", "Reset Available", "Expires in tomorrow"],
            observedAt: now)
        try expect(malformedRelative.evidence == .unknown, "unbounded relative text remains unknown")

        for unclear in [
            ["Usage Limit Reset", "Reset Available", "Reset Unavailable"],
            ["Usage Limit Reset", "Reset Available", "Reset Card Available"],
        ] {
            let observation = observation(fingerprint: fingerprint, strings: unclear, observedAt: now)
            try expect(
                observation.evidence == .unknown && !observation.mayAffectPriority(at: now),
                "contradictory or duplicate status lines cannot trigger priority")
        }

        let unavailable = observation(
            fingerprint: fingerprint,
            strings: ["Usage Limit Reset", "No reset cards available"],
            observedAt: now)
        try expect(unavailable.status == .unavailable && !unavailable.mayAffectPriority(at: now), "explicit no-card status is unavailable")

        let expired = observation(
            fingerprint: fingerprint,
            strings: ["Usage Limit Reset", "Expired"],
            observedAt: now)
        try expect(expired.status == .expired && !expired.mayAffectPriority(at: now), "explicit expired status is historical only")

        let ambiguous = observation(
            fingerprint: fingerprint,
            strings: ["Usage Limit Reset", "Reset Available"],
            observedAt: now)
        try expect(
            ambiguous.isStructurallyValid() && ambiguous.evidence == .availableUnknownCountAndExactExpiry,
            "known available status does not require a relative date")
        try expect(
            ambiguous.displayTitle == "Usage Limit Reset" && ambiguous.isFresh(at: now),
            "available status stays actionable without an expiry sentence")

        let unknown = observation(
            fingerprint: fingerprint,
            strings: ["Usage Limit Reset", "Status changed"],
            observedAt: now)
        try expect(
            unknown.evidence == .unknown && unknown.displayTitle == "Usage Limit Reset" && !unknown.isFresh(at: now),
            "unknown status is dated display only")

        let noTitle = observation(
            fingerprint: fingerprint,
            strings: ["No reset cards available"],
            observedAt: now)
        try expect(
            noTitle.evidence == .ambiguous && noTitle.displayTitle == nil,
            "unavailable wording without the official title is rejected")

        try expect(
            !GrokResetStatusObservation.validFingerprint(String(repeating: "A", count: 64)),
            "uppercase fingerprint is rejected")
        try expect(
            !GrokResetStatusObservation.validFingerprint(String(repeating: "a", count: 63)),
            "short fingerprint is rejected")
        try expect(
            !GrokResetStatusObservation.validSourceURL("http://grok.com/settings"),
            "non-HTTPS source is rejected")
        try expect(
            !GrokResetStatusObservation.validSourceURL("https://grok.com.example/settings"),
            "look-alike source host is rejected")
        try expect(
            GrokResetStatusObservation.validSourceURL("https://accounts.x.ai/usage"),
            "allowlisted official source is accepted")
    }

    private static func testObservationImporterAndIdentityMerge(now: Date) throws {
        let fingerprint = String(repeating: "b", count: 64)
        let bytes = try JSONEncoder().encode(observation(fingerprint: fingerprint, observedAt: now))
        let reader = GrokResetStatusObservationReader(fileReader: { _, maximumBytes, allowMissing in
            try expect(
                maximumBytes == GrokResetStatusObservationReader.maximumBytes,
                "observation reader uses its bounded maximum")
            try expect(allowMissing, "observation reader allows a missing optional import")
            return bytes
        })
        let loaded = reader.load(from: URL(fileURLWithPath: "/synthetic/support", isDirectory: true), now: now)
        try expect(
            loaded == observation(fingerprint: fingerprint, observedAt: now),
            "bounded importer decodes the four-field observation")

        let whitespaceObservation = observation(
            fingerprint: fingerprint,
            strings: ["  Usage   Limit Reset. ", "\tReset Available:\t", "Expires   in  2  days!"],
            observedAt: now)
        let whitespaceBytes = try JSONEncoder().encode(whitespaceObservation)
        let whitespaceReader = GrokResetStatusObservationReader(fileReader: { _, _, _ in
            whitespaceBytes
        })
        try expect(
            whitespaceReader.load(
                from: URL(fileURLWithPath: "/synthetic/support", isDirectory: true),
                now: now) == whitespaceObservation,
            "reasonable punctuation and horizontal whitespace survive bounded import")

        let extraFieldBytes = Data(
            """
            {"accountFingerprint":"\(fingerprint)","visibleStrings":["Usage Limit Reset","Reset Available","Expires in 1 day"],"observedAt":\(now.timeIntervalSince1970),"sourceURL":"https://grok.com/settings","accountName":"forbidden"}
            """.utf8)
        let extraFieldReader = GrokResetStatusObservationReader(fileReader: { _, _, _ in
            extraFieldBytes
        })
        try expect(
            extraFieldReader.load(
                from: URL(fileURLWithPath: "/synthetic/support", isDirectory: true),
                now: now) == nil,
            "import rejects fields outside the anonymous four-field contract")

        let futureBytes = try JSONEncoder().encode(
            observation(
                fingerprint: fingerprint,
                observedAt: now.addingTimeInterval(1)))
        let futureReader = GrokResetStatusObservationReader(fileReader: { _, _, _ in futureBytes })
        try expect(
            futureReader.load(
                from: URL(fileURLWithPath: "/synthetic/support", isDirectory: true),
                now: now) == nil,
            "import rejects a future observation timestamp")

        let incoming = quota(fingerprint: fingerprint, fetchedAt: now)
        let merged = GrokResetStatusMerger.merge(
            previous: nil,
            incoming: incoming,
            profileKind: .grok,
            observation: loaded,
            now: now)
        try expect(merged.grokResetObservation == loaded, "matching Grok identity receives observation")
        try expect(
            merged.officialGrokResetTitle == "Usage Limit Reset",
            "read-only title property is exposed")
        try expect(
            merged.officialGrokResetDetail?.contains("Expires in 1 day") == true,
            "read-only detail property is exposed")
        try expect(merged.officialGrokResetIsFresh(at: now), "matching observation exposes fresh eligibility")
        try expect(
            merged.officialGrokResetMayAffectPriority(at: now)
                && !merged.officialGrokResetMayAuthorizeRedemption,
            "fresh exact status can prioritize but cannot authorize redemption")

        let mismatch = observation(fingerprint: String(repeating: "c", count: 64), observedAt: now)
        let mismatched = GrokResetStatusMerger.merge(
            previous: nil,
            incoming: incoming,
            profileKind: .grok,
            observation: mismatch,
            now: now)
        try expect(mismatched.grokResetObservation == nil, "mismatched identity is not merged")

        let stale = observation(fingerprint: fingerprint, observedAt: now.addingTimeInterval(-301))
        let staleResult = GrokResetStatusMerger.merge(
            previous: nil,
            incoming: incoming,
            profileKind: .grok,
            observation: stale,
            now: now)
        try expect(
            staleResult.officialGrokResetTitle == "Usage Limit Reset",
            "stale official text remains displayable")
        try expect(
            staleResult.officialGrokResetDetail?.contains("Observed") == true,
            "stale official text remains dated")
        try expect(!staleResult.officialGrokResetIsFresh(at: now), "stale official text cannot be eligible")
        try expect(
            !staleResult.officialGrokResetMayAffectPriority(at: now)
                && !staleResult.officialGrokResetMayAuthorizeRedemption,
            "stale official text cannot trigger priority or redemption")

        let oldAvailable = observation(
            fingerprint: fingerprint,
            observedAt: now.addingTimeInterval(-90))
        let previous = quota(
            fingerprint: fingerprint,
            fetchedAt: now.addingTimeInterval(-90),
            observation: oldAvailable)
        let newerUnavailable = observation(
            fingerprint: fingerprint,
            strings: ["Usage Limit Reset", "No reset cards available"],
            observedAt: now.addingTimeInterval(-60))
        let unavailableResult = GrokResetStatusMerger.merge(
            previous: previous,
            incoming: incoming,
            profileKind: .grok,
            observation: newerUnavailable,
            now: now)
        try expect(
            unavailableResult.officialGrokResetStatus == .unavailable
                && unavailableResult.officialGrokResetCurrentStatus(at: now) == .unavailable
                && !unavailableResult.officialGrokResetMayAffectPriority(at: now),
            "newer unavailable evidence overrides old available status")

        let newerUnknown = observation(
            fingerprint: fingerprint,
            strings: ["Usage Limit Reset", "Status changed"],
            observedAt: now.addingTimeInterval(-30))
        let unknownResult = GrokResetStatusMerger.merge(
            previous: previous,
            incoming: incoming,
            profileKind: .grok,
            observation: newerUnknown,
            now: now)
        try expect(
            unknownResult.officialGrokResetStatus == .unknown
                && unknownResult.officialGrokResetCurrentStatus(at: now) == nil
                && !unknownResult.officialGrokResetMayAffectPriority(at: now)
                && unknownResult.officialGrokResetDetail?.contains("Observed") == true,
            "newer unknown evidence overrides old available as dated history")

        let olderAvailable = observation(
            fingerprint: fingerprint,
            observedAt: now.addingTimeInterval(-120))
        let retainedUnavailable = GrokResetStatusMerger.merge(
            previous: unavailableResult,
            incoming: incoming,
            profileKind: .grok,
            observation: olderAvailable,
            now: now)
        try expect(
            retainedUnavailable.officialGrokResetStatus == .unavailable,
            "older available evidence cannot overwrite newer unavailable status")

        let newerExpired = observation(
            fingerprint: fingerprint,
            strings: ["Usage Limit Reset", "Expired"],
            observedAt: now.addingTimeInterval(-10))
        let expiredResult = GrokResetStatusMerger.merge(
            previous: unavailableResult,
            incoming: incoming,
            profileKind: .grok,
            observation: newerExpired,
            now: now)
        try expect(
            expiredResult.officialGrokResetStatus == .expired
                && expiredResult.officialGrokResetCurrentStatus(at: now) == nil
                && !expiredResult.officialGrokResetMayAffectPriority(at: now)
                && expiredResult.officialGrokResetDetail?.contains("Observed") == true,
            "newer expired evidence is historical only")
    }

    private static func testCardEvidenceMerge(now: Date) throws {
        let fingerprint = String(repeating: "d", count: 64)
        let known = [card("known", expiresIn: 24 * 3600, from: now)]
        let previous = quota(
            fingerprint: fingerprint,
            fetchedAt: now.addingTimeInterval(-120),
            cards: known,
            cardsObservedAt: now.addingTimeInterval(-120))

        // The current billing response omits resetCards. Omission is unknown,
        // so the known exact card data is retained for the matching identity.
        let omitted = GrokResetStatusMerger.merge(
            previous: previous,
            incoming: quota(fingerprint: fingerprint, fetchedAt: now),
            profileKind: .grok,
            observation: nil,
            now: now)
        try expect(omitted.resetCards == known, "omitted card field preserves known cards")
        try expect(
            omitted.resetCardsObservedAt == previous.resetCardsObservedAt,
            "omitted card field preserves the original evidence time")

        // A newer explicit empty list is the only no-card assertion and clears
        // the older exact set. Availability text alone never does this.
        let noCards = GrokResetStatusMerger.merge(
            previous: previous,
            incoming: quota(fingerprint: fingerprint, fetchedAt: now, cards: [], cardsObservedAt: now),
            profileKind: .grok,
            observation: observation(fingerprint: fingerprint, observedAt: now),
            now: now)
        try expect(noCards.resetCards?.isEmpty == true, "newer explicit no-card evidence clears old cards")

        let ambiguousNewer = GrokResetStatusMerger.merge(
            previous: previous,
            incoming: quota(fingerprint: fingerprint, fetchedAt: now),
            profileKind: .grok,
            observation: observation(
                fingerprint: fingerprint,
                strings: ["Usage Limit Reset", "Reset Available"],
                observedAt: now),
            now: now)
        try expect(
            ambiguousNewer.resetCards == known,
            "ambiguous newer observation does not clear exact cards")

        let olderNoCards = GrokResetStatusMerger.merge(
            previous: previous,
            incoming: quota(
                fingerprint: fingerprint,
                fetchedAt: now.addingTimeInterval(-180),
                cards: [],
                cardsObservedAt: now.addingTimeInterval(-180)),
            profileKind: .grok,
            observation: nil,
            now: now)
        try expect(
            olderNoCards.resetCards == known,
            "older no-card evidence cannot erase newer exact cards")

        let switched = GrokResetStatusMerger.merge(
            previous: previous,
            incoming: quota(fingerprint: String(repeating: "e", count: 64), fetchedAt: now),
            profileKind: .grok,
            observation: nil,
            now: now)
        try expect(switched.resetCards == nil, "identity change does not carry card data")
    }

    // The same instant must render in the requested zone and stay deterministic.
    // 1970-01-01T00:00:00Z is 19:00 on Dec 31, 1969 in New York and 08:00 on
    // Jan 1, 1970 in Shanghai — a date-line crossing, so the two differ.
    private static func testTimeZoneDisplay() throws {
        let epoch = Date(timeIntervalSince1970: 0)
        let shanghai = ResetCardPresentation.expiryText(epoch, timeZone: TimeZone(identifier: "Asia/Shanghai")!, language: .zh)
        let newYork = ResetCardPresentation.expiryText(epoch, timeZone: TimeZone(identifier: "America/New_York")!, language: .en)
        try expect(shanghai != newYork, "date-line crossing renders differently per zone")
        try expect(
            shanghai == ResetCardPresentation.expiryText(epoch, timeZone: TimeZone(identifier: "Asia/Shanghai")!, language: .zh),
            "zone rendering is deterministic")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents([.day, .hour], from: epoch)
        try expect(components.day == 1, "epoch is Jan 1 in Shanghai")
        try expect(components.hour == 8, "epoch is 08:00 in Shanghai")
    }

    // Sorting contract: only the explicit pin overrides saved order.
    private static func testSorting() throws {
        try expect(
            ResetCardPresentation.savedOrder(["p1", "g1", "p2", "g2"], pinnedAccountID: "p1")
                == ["p1", "g1", "p2", "g2"],
            "pinned first, saved order unchanged")
        try expect(
            ResetCardPresentation.savedOrder(["g1", "p1", "p2"], pinnedAccountID: "p1")
                == ["p1", "g1", "p2"],
            "explicit pin moves first")
        try expect(
            ResetCardPresentation.savedOrder(["a", "b", "c"], pinnedAccountID: nil)
                == ["a", "b", "c"],
            "without pinned, accounts stay in their saved order")
        try expect(
            ResetCardPresentation.savedOrder(["a", "b"], pinnedAccountID: "missing")
                == ["a", "b"],
            "unknown pinned id is ignored")
        try expect(
            ResetCardPresentation.savedOrder(["a", "b"], pinnedAccountID: nil)
                == ["a", "b"],
            "unknown expiring id changes nothing")
    }

    // The official-shaped billing response (synthetic values) must keep resetCards
    // nil, and its quota reset value must stay a quota window reset only.
    private static func testProductionParseKeepsNil(now: Date) throws {
        let synthetic =
            #"{"config":{"creditUsagePercent":12.5,"currentPeriod":{"end":"2026-09-15T09:55:31Z"},"billingPeriodEnd":"2026-10-01T00:00:00Z","subscriptionTier":"super"}}"#
        let parsed = try LocalCLIQuotaReader.parseGrok(Data(synthetic.utf8))
        try expect(parsed.resetCards == nil, "official response shape keeps reset cards nil")
        try expect(parsed.windows.count == 1, "quota window still parsed")
        let quotaReset = try require(parsed.windows.first?.resetsAt, "quota reset parsed from currentPeriod.end")
        try expect(quotaReset.timeIntervalSince(now) > 0, "quota reset stays a future quota value")
        try expect(!ResetCardPresentation.isExpiringSoon(parsed.resetCards, now: now), "quota reset never triggers the card expiry rule")

    }
}
