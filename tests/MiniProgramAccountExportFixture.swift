import Foundation

@main
enum MiniProgramAccountExportFixture {
    typealias Exporter = MiniProgramAccountExport
    static let now = Date(timeIntervalSince1970: 1_791_800_000)
    static var checks = 0
    static func expect(_ condition: Bool, _ name: String) {
        checks += 1
        precondition(condition, name)
    }

    static func input(
        _ id: String = "synthetic-account-a", count: Int? = 2, balance: String? = "0.1",
        unlimited: Bool = false, age: Double = 0, succeeded: Bool = true,
        identity: Bool = true, origin: Exporter.Origin = .official,
        failure: Date? = nil, scope: String? = "synthetic-limit", cards: [ResetCreditDetail]? = nil,
        used: Double = 10
    ) -> Exporter.Observation {
        .init(
            accountID: id,
            snapshot: .init(
                refreshedAt: now.addingTimeInterval(-age),
                account: .init(type: "chatgpt", planType: "plus", emailPresent: true, email: "never-export@example.invalid"),
                limitId: scope, limitName: "never-export-name", quotaReadSucceeded: succeeded,
                fiveHourQuota: .init(usedPercent: used, windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600)),
                sevenDayQuota: .init(usedPercent: 20, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(86400)),
                monthlyQuota: nil,
                credits: .init(
                    hasCredits: true, unlimited: unlimited, balance: balance,
                    resetCredits: count, resetCreditDetails: cards),
                cloudLifetimeTokens: 999, local: nil, taskBoard: nil, messages: ["never-export-message"]),
            origin: origin, identityVerified: identity, lastFailureAt: failure)
    }

    static func card(_ id: String, seconds: Double? = 300) -> ResetCreditDetail {
        .init(id: id, expiresAt: seconds.map { now.addingTimeInterval($0) })
    }

    static func build(_ inputs: [Exporter.Observation], tokens: Exporter.TokenObservation? = nil) throws -> Exporter.Export {
        try Exporter.build(observations: inputs, tokens: tokens, now: now)
    }

    static func main() throws {
        let same = input(cards: [card("real-format-card-a"), card("real-format-card-b", seconds: 600)])
        let one = try build([same, same])
        expect(one.overview.accounts.count == 1, "same identity deduplicated")
        expect(one.overview.resetCredits.value == 2, "mirror count not doubled")
        expect(one.overview.points.value == "0.1", "mirror points not doubled")
        expect(one.overview.resetCredits.completeness == .complete, "all known complete")
        expect(one.overview.accounts[0].resetCardsPartial == false, "complete actual details")
        expect(one.resetSnapshots.count == 1, "one V1 snapshot")
        let reversed = try build([input("account-b", balance: "0.2"), same])
        expect(reversed == (try build([same, input("account-b", balance: "0.2")])), "deterministic order")
        expect(reversed.overview.accounts.count == 2, "same email different identity distinct")
        expect(reversed.overview.points.value == "0.3", "decimal sum exact")
        expect(reversed.overview.resetCredits.value == 4, "distinct counts add")
        expect(reversed.overview.accounts.allSatisfy { $0.fiveHour?.remainingPercent == 90 }, "quota kept per account")
        expect(reversed.overview.tokenUsage.totalTokens == nil, "account lifetime tokens not summed")

        let zero = try build([input(count: 0, balance: "0")])
        expect(zero.overview.resetCredits.value == 0 && zero.overview.points.value == "0", "real zero retained")
        let missing = try build([input(count: nil, balance: nil)])
        expect(missing.overview.resetCredits.value == nil && missing.overview.points.value == nil, "missing not zero")
        expect(missing.overview.points.completeness == .unknown, "unknown coverage")
        let partial = try build([same, input("b", count: nil, balance: nil)])
        expect(partial.overview.resetCredits.value == 2 && partial.overview.resetCredits.completeness == .partial, "known card subtotal")
        expect(partial.overview.points.value == "0.1" && partial.overview.points.completeness == .partial, "known points subtotal")
        let negative = try build([input(balance: "-2.05"), input("b", balance: "1,000.10")])
        expect(negative.overview.points.value == "998.05", "grouped and negative balance")
        expect(negative.overview.accounts.contains { $0.points == "1,000.10" }, "raw balance precision preserved")
        let infinite = try build([input(unlimited: true), input("b", balance: "1.23")])
        expect(infinite.overview.points.value == "1.23" && infinite.overview.points.completeness == .partial, "unlimited not finite zero")
        let enormous = String(repeating: "9", count: 39)
        let big = try build([input(balance: enormous)])
        expect(big.overview.accounts[0].points == enormous, "large raw balance retained")
        expect(big.overview.points.value == nil && big.overview.points.completeness == .unknown, "unsafe sum not rounded")
        expect((try build([input(balance: "NaN")])).overview.accounts[0].points == nil, "invalid balance unknown")

        let atBoundary = try build([input(age: 300)])
        expect(atBoundary.overview.accounts[0].status == .ok, "300 second freshness inclusive")
        let stale = try build([input(age: 301)])
        expect(stale.overview.accounts[0].status == .stale && stale.overview.accounts[0].availableResetCredits == 2, "stale history labeled")
        expect(stale.overview.resetCredits.value == nil && stale.resetSnapshots.isEmpty, "stale not current total or upload")
        expect(stale.overview.accounts[0].observedAt != stale.overview.generatedAt, "source time not refreshed")
        let cached = try build([input(origin: .persisted, cards: [card("saved-0")])])
        expect(cached.overview.accounts[0].status == .stale, "persisted not fresh official")
        expect(cached.overview.accounts[0].resetCards.isEmpty && cached.resetSnapshots.isEmpty, "cached dates not card IDs")
        let failed = try build([input(age: 10), input(age: 0, succeeded: false)])
        expect(failed.overview.accounts[0].status == .failed && failed.overview.resetCredits.value == nil, "latest failure wins")
        expect(failed.resetSnapshots.first?.status == .failed && failed.resetSnapshots.first?.availableResetCredits == nil, "failure invalidates V1 baseline")
        let failedWithoutScope = try build([input(age: 10), input(succeeded: false, scope: nil)])
        expect(failedWithoutScope.resetSnapshots.first?.status == .failed, "failed read missing scope invalidates prior scope")
        expect(failedWithoutScope.resetSnapshots.first?.availableResetCredits == nil, "scope recovery never borrows old values")
        expect((try build([input(succeeded: false, scope: nil)])).resetSnapshots.isEmpty, "no prior scope is invented")
        expect(
            (try build([input(age: 10, scope: "a"), input(age: 10, scope: "b"), input(succeeded: false, scope: nil)])).resetSnapshots.isEmpty, "ambiguous prior scope not selected")
        let watermark = try build([input(age: 60, failure: now.addingTimeInterval(-5))])
        expect(watermark.resetSnapshots.first?.observedAt != watermark.overview.accounts[0].observedAt, "failure watermark remains distinct")
        expect((try build([input(age: 30, succeeded: false), same])).overview.accounts[0].status == .ok, "new success supersedes old failure")
        let conflict = try build([input(count: 2), input(count: 3)])
        expect(conflict.overview.accounts[0].status == .failed && conflict.resetSnapshots.first?.status == .failed, "same-time conflict fails closed")
        expect((try build([input(scope: "a"), input(scope: "b")])).overview.accounts[0].status == .failed, "same-time scope conflict")
        expect((try build([input(identity: false)])).overview.accounts[0].status == .failed, "unverified current binding blocked")
        expect((try build([input(age: -1)])).resetSnapshots.isEmpty, "future source not sent")
        let noScope = try build([input(scope: " ")])
        expect(noScope.overview.accounts[0].scope == nil && noScope.resetSnapshots.isEmpty, "missing scope not fabricated")
        expect(noScope.overview.accounts[0].points == "0.1" && noScope.overview.accounts[0].fiveHour?.remainingPercent == 90, "missing limit scope preserves independent facts")
        let invalidID = try build([same, input("")])
        expect(invalidID.overview.excludedIdentityInputs == 1 && invalidID.overview.resetCredits.completeness == .partial, "unknown identity not hidden")

        let mixedCards = try build([input(count: 4, cards: [card("used", seconds: -1), card("unknown", seconds: nil), card("available")])])
        expect(mixedCards.overview.accounts[0].resetCards.count == 1 && mixedCards.overview.accounts[0].resetCardsPartial, "unknown expired card details omitted")
        let duplicate = try build([input(cards: [card("same"), card("same")])])
        expect(duplicate.overview.accounts[0].status == .failed, "duplicate card ID not double counted")
        let contradiction = try build([input(count: 1, cards: [card("a"), card("b")])])
        expect(contradiction.overview.accounts[0].status == .failed, "count contradiction not hidden")
        let many = (0..<101).map { card("many-\($0)", seconds: Double(300 + $0)) }
        let limited = try build([input(count: 101, cards: many)])
        expect(limited.resetSnapshots[0].resetCards.count == 100, "V1 details bounded")
        expect(limited.overview.accounts[0].resetCardsPartial && limited.overview.resetCredits.value == 101, "bounded details not total")
        expect((try build([input(used: 101)])).overview.accounts[0].fiveHour == nil, "invalid quota not clamped into fact")

        let token = Exporter.TokenObservation(
            totalTokens: 9_007_199_254_740_991, source: .desktop,
            observedAt: nil, sourceSucceeded: true, isPartial: nil)
        let tokens = try build([same, input("b")], tokens: token)
        expect(tokens.overview.tokenUsage.totalTokens == "9007199254740991", "safe token count exact string")
        expect(tokens.overview.tokenUsage.observedAt == nil && tokens.overview.tokenUsage.status == .unknown, "no source timestamp invented")
        expect(tokens.overview.tokenUsage.isPartial == nil, "unknown token coverage not complete")
        let overflow = Exporter.TokenObservation(
            totalTokens: 9_007_199_254_740_992, source: .desktop,
            observedAt: now, sourceSucceeded: true, isPartial: false)
        expect((try build([], tokens: overflow)).overview.tokenUsage.totalTokens == nil, "JS rounded integer rejected")
        let hub = Exporter.TokenObservation(totalTokens: 7, source: .hub, observedAt: now, sourceSucceeded: true, isPartial: true)
        let hubResult = try build([same, input("b")], tokens: hub)
        expect(hubResult.overview.tokenUsage.totalTokens == "7" && hubResult.overview.tokenUsage.source == .hub, "one source not added to accounts")
        expect(hubResult.overview.tokenUsage.isPartial == true, "partial token source retained")
        let unavailable = Exporter.TokenObservation(totalTokens: 12, source: .local, observedAt: now, sourceSucceeded: false, isPartial: nil)
        expect((try build([], tokens: unavailable)).overview.tokenUsage.totalTokens == nil, "failed token source hidden")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(one)
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["never-export", "synthetic-account-a", "real-format-card-a", "synthetic-limit", "email", "tokenCredential", "USD"] {
            expect(!text.contains(forbidden), "allowlist excludes " + forbidden)
        }
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(missing.resetSnapshots[0])) as! [String: Any]
        expect(Set(raw.keys) == Set(["accountRef", "label", "scope", "observedAt", "status", "availableResetCredits", "resetCards"]), "exact V1 keys")
        expect(raw["availableResetCredits"] is NSNull, "V1 unknown explicit null")
        let unknownJSON = try JSONSerialization.jsonObject(with: encoder.encode(missing.overview)) as! [String: Any]
        expect((unknownJSON["points"] as! [String: Any])["value"] is NSNull, "overview total unknown explicit null")
        let accountJSON = (unknownJSON["accounts"] as! [[String: Any]])[0]
        expect(accountJSON["points"] is NSNull && accountJSON["availableResetCredits"] is NSNull, "account unknown explicit null")
        let tokenJSON = unknownJSON["tokenUsage"] as! [String: Any]
        expect(tokenJSON["totalTokens"] is NSNull && tokenJSON["observedAt"] is NSNull && tokenJSON["isPartial"] is NSNull, "token unknown explicit null")
        expect(one.resetSnapshots[0].accountRef.allSatisfy { ("a"..."p").contains(String($0)) }, "reference alphabet cannot look like phone")
        if CommandLine.arguments.count == 2 {
            // Synthetic fixture output for the real Node validator; never user data.
            try encoder.encode([one.resetSnapshots[0], missing.resetSnapshots[0], failed.resetSnapshots[0], limited.resetSnapshots[0]])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
        print("PASS mini-program desktop export: \(checks) assertions; no account I/O or network")
    }
}
