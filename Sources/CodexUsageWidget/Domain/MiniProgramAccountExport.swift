import Foundation

/// Internal, side-effect-free companion module. Never reads credentials, starts
/// collection, sends a message, or treats an export as permission to upload it.
enum MiniProgramAccountExport {
    enum Origin: String, Encodable { case official, persisted }
    enum Status: String, Encodable { case ok, stale, failed, unknown }
    enum Completeness: String, Encodable { case complete, partial, unknown }
    enum PointsState: String, Encodable { case reported, unlimited, unknown }
    enum TokenSource: String, Encodable { case desktop, hub, local, custom, unavailable }

    struct Observation {
        /// A previously verified account binding, never an email/profile index.
        let accountID: String
        let snapshot: UsageSnapshot
        let origin: Origin
        let identityVerified: Bool
        let lastFailureAt: Date?
    }

    struct TokenObservation {
        /// Select the SAME single source as the home screen; do not sum sources.
        let totalTokens: Int64?
        let source: TokenSource
        let observedAt: Date?
        let sourceSucceeded: Bool
        let isPartial: Bool?
    }

    struct Quota: Encodable, Equatable {
        let remainingPercent: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey { case remainingPercent, resetsAt }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(remainingPercent, forKey: .remainingPercent)
            try values.encode(resetsAt, forKey: .resetsAt)
        }
    }

    struct Card: Encodable, Equatable {
        let id: String
        let expiresAt: String
    }

    struct Account: Encodable, Equatable {
        let accountRef: String
        let label: String
        let scope: String?
        let observedAt: String?
        let lastFailureAt: String?
        let origin: Origin
        let status: Status
        let availableResetCredits: Int?
        let resetCards: [Card]
        let resetCardsPartial: Bool
        let points: String?
        let pointsState: PointsState
        let fiveHour: Quota?
        let sevenDay: Quota?

        enum CodingKeys: String, CodingKey {
            case accountRef, label, scope, observedAt, lastFailureAt, origin, status
            case availableResetCredits, resetCards, resetCardsPartial, points, pointsState, fiveHour, sevenDay
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(accountRef, forKey: .accountRef)
            try values.encode(label, forKey: .label)
            try values.encode(scope, forKey: .scope)
            try values.encode(observedAt, forKey: .observedAt)
            try values.encode(lastFailureAt, forKey: .lastFailureAt)
            try values.encode(origin, forKey: .origin)
            try values.encode(status, forKey: .status)
            try values.encode(availableResetCredits, forKey: .availableResetCredits)
            try values.encode(resetCards, forKey: .resetCards)
            try values.encode(resetCardsPartial, forKey: .resetCardsPartial)
            try values.encode(points, forKey: .points)
            try values.encode(pointsState, forKey: .pointsState)
            try values.encode(fiveHour, forKey: .fiveHour)
            try values.encode(sevenDay, forKey: .sevenDay)
        }
    }

    struct Total<Value: Encodable & Equatable>: Encodable, Equatable {
        /// Missing is NOT zero. With partial coverage this is a known subtotal.
        let value: Value?
        let completeness: Completeness
        let knownAccounts: Int
        let accountCount: Int

        enum CodingKeys: String, CodingKey { case value, completeness, knownAccounts, accountCount }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(value, forKey: .value)
            try values.encode(completeness, forKey: .completeness)
            try values.encode(knownAccounts, forKey: .knownAccounts)
            try values.encode(accountCount, forKey: .accountCount)
        }
    }

    struct Tokens: Encodable, Equatable {
        let period = "allTime"
        /// String keeps integer precision across JSON/JavaScript consumers.
        let totalTokens: String?
        let source: TokenSource
        let observedAt: String?
        let status: Status
        let isPartial: Bool?

        enum CodingKeys: String, CodingKey { case period, totalTokens, source, observedAt, status, isPartial }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(period, forKey: .period)
            try values.encode(totalTokens, forKey: .totalTokens)
            try values.encode(source, forKey: .source)
            try values.encode(observedAt, forKey: .observedAt)
            try values.encode(status, forKey: .status)
            try values.encode(isPartial, forKey: .isPartial)
        }
    }

    struct Overview: Encodable, Equatable {
        let schemaVersion = "1013v1-internal"
        /// Export time only; it must never replace a source observation time.
        let generatedAt: String
        let accounts: [Account]
        let excludedIdentityInputs: Int
        let resetCredits: Total<Int>
        let points: Total<String>
        let tokenUsage: Tokens
    }

    /// Exactly the existing /v1/desktop/snapshots allowlist. Overview is a
    /// separate internal candidate and must not be sent to this V1 endpoint.
    struct ResetSnapshotV1: Encodable, Equatable {
        let accountRef: String
        let label: String
        let scope: String
        let observedAt: String
        let status: Status
        let availableResetCredits: Int?
        let resetCards: [Card]

        enum CodingKeys: String, CodingKey {
            case accountRef, label, scope, observedAt, status, availableResetCredits, resetCards
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(accountRef, forKey: .accountRef)
            try values.encode(label, forKey: .label)
            try values.encode(scope, forKey: .scope)
            try values.encode(observedAt, forKey: .observedAt)
            try values.encode(status, forKey: .status)
            try values.encode(availableResetCredits, forKey: .availableResetCredits)
            try values.encode(resetCards, forKey: .resetCards)
        }
    }

    struct Export: Encodable, Equatable {
        let overview: Overview
        let resetSnapshots: [ResetSnapshotV1]
    }

    enum ValidationError: Error { case invalidClock, tooManyInputs }
    static let freshness: TimeInterval = 300

    static func build(
        observations: [Observation], tokens: TokenObservation? = nil, now: Date
    ) throws -> Export {
        guard validDate(now) else { throw ValidationError.invalidClock }
        guard observations.count <= 1_024 else { throw ValidationError.tooManyInputs }
        let accepted = observations.filter { CodexResetNoticeKey.validBackendID($0.accountID) }
        let groups = Dictionary(grouping: accepted, by: { reference("account", $0.accountID) })
        let accounts = groups.keys.sorted().map { project(groups[$0]!, accountRef: $0, now: now) }
        let excluded = observations.count - accepted.count
        let fresh = accounts.filter { $0.status == .ok }
        let counts = fresh.compactMap(\.availableResetCredits)
        let balances = fresh.filter { $0.pointsState == .reported }.compactMap(\.points)
        let pointSum = sumPoints(balances)
        let overview = Overview(
            generatedAt: timestamp(now), accounts: accounts, excludedIdentityInputs: excluded,
            resetCredits: Total(
                value: counts.isEmpty ? nil : counts.reduce(0, +),
                completeness: coverage(counts.count, accounts.count, excluded: excluded),
                knownAccounts: counts.count, accountCount: accounts.count),
            points: Total(
                value: pointSum,
                completeness: pointSum == nil ? .unknown : coverage(balances.count, accounts.count, excluded: excluded),
                knownAccounts: balances.count, accountCount: accounts.count),
            tokenUsage: project(tokens, now: now))
        return Export(
            overview: overview,
            resetSnapshots: accounts.compactMap { account in
                guard let scope = account.scope else { return nil }
                if account.status == .ok, account.origin == .official, let observedAt = account.observedAt {
                    return ResetSnapshotV1(
                        accountRef: account.accountRef, label: account.label, scope: scope,
                        observedAt: observedAt, status: .ok,
                        availableResetCredits: account.availableResetCredits, resetCards: account.resetCards)
                }
                // Propagate an actual fresh failure, not a synthetic "now" snapshot.
                if account.status == .failed, let failedAt = account.lastFailureAt,
                    let date = parser.date(from: failedAt), now.timeIntervalSince(date) <= freshness
                {
                    return ResetSnapshotV1(
                        accountRef: account.accountRef, label: account.label, scope: scope,
                        observedAt: failedAt, status: .failed, availableResetCredits: nil, resetCards: [])
                }
                return nil
            })
    }

    private struct Facts: Equatable {
        let scope: String?
        let count: Int?
        let points: String?
        let pointsState: PointsState
        let fiveHour: Quota?
        let sevenDay: Quota?
    }

    private static func facts(_ snapshot: UsageSnapshot) -> Facts {
        let limit = snapshot.limitId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = limit.flatMap { CodexResetNoticeKey.validBackendID($0) ? reference("scope", $0) : nil }
        let balance = snapshot.credits.flatMap { CreditBalancePresentation.normalizedBalance($0.balance) }
        let points = balance
        let unlimited = snapshot.credits?.unlimited == true
        return Facts(
            scope: scope,
            count: snapshot.credits?.resetCredits.flatMap { (0...1_000_000).contains($0) ? $0 : nil },
            points: unlimited ? nil : points,
            pointsState: unlimited ? .unlimited : points == nil ? .unknown : .reported,
            fiveHour: quota(snapshot.fiveHourQuota), sevenDay: quota(snapshot.sevenDayQuota))
    }

    private static func project(_ inputs: [Observation], accountRef: String, now: Date) -> Account {
        let valid = inputs.filter { validDate($0.snapshot.refreshedAt) && $0.snapshot.refreshedAt <= now }
        let latest = valid.map { $0.snapshot.refreshedAt }.max()
        let peers = valid.filter { $0.snapshot.refreshedAt == latest }
        let chosen = peers.first(where: { $0.origin == .official }) ?? peers.first
        let fact = chosen.map { facts($0.snapshot) }
        let failure = inputs.compactMap { item -> Date? in
            let readFailure = (!item.identityVerified || !item.snapshot.quotaReadSucceeded) ? item.snapshot.refreshedAt : nil
            return [item.lastFailureAt, readFailure].compactMap { $0 }.filter { validDate($0) && $0 <= now }.max()
        }.max()
        let conflict = peers.contains { facts($0.snapshot) != fact }
        let officialDetails = peers.filter { $0.origin == .official }.map { item in
            CodexResetNoticeObservation.official(accountID: item.accountID, snapshot: item.snapshot, identityVerified: item.identityVerified)?.canonical
        }
        let invalidCards =
            officialDetails.contains { $0?.verificationSucceeded != true }
            || (officialDetails.count > 1 && officialDetails.dropFirst().contains { $0 != officialDetails.first! })
        let invalidTime = valid.count != inputs.count || inputs.contains { $0.lastFailureAt.map { !validDate($0) || $0 > now } == true }
        let failed = invalidTime || conflict || invalidCards || (failure.map { latest == nil || $0 >= latest! } ?? false)
        let failureAt = conflict || invalidCards ? [failure, latest].compactMap { $0 }.max() : failure
        // An unsuccessful reader may omit limitId. An invalidation may retain
        // the last verified scope for this SAME identity, never success values.
        let scoped = valid.filter { $0.identityVerified && $0.snapshot.quotaReadSucceeded && facts($0.snapshot).scope != nil }
        let scopedAt = scoped.map { $0.snapshot.refreshedAt }.max()
        let priorScopes = Set(scoped.filter { $0.snapshot.refreshedAt == scopedAt }.compactMap { facts($0.snapshot).scope })
        let scope = fact?.scope ?? (failed && priorScopes.count == 1 ? priorScopes.first : nil)
        let origin = chosen?.origin ?? .persisted
        let status: Status =
            failed
            ? .failed
            : latest == nil
                ? .unknown
                : origin == .persisted || now.timeIntervalSince(latest!) > freshness ? .stale : .ok
        let visible = status == .ok || status == .stale
        let cards: [Card] =
            !visible || origin != .official
            ? []
            : (chosen?.snapshot.credits?.resetCreditDetails ?? [])
                .compactMap { card -> Card? in
                    guard let expiry = card.expiresAt, validDate(expiry), expiry > now else { return nil }
                    return Card(id: reference("card", card.id), expiresAt: timestamp(expiry))
                }
                .sorted { $0.expiresAt == $1.expiresAt ? $0.id < $1.id : $0.expiresAt < $1.expiresAt }
        return Account(
            accountRef: accountRef, label: "账号 " + String(accountRef.prefix(8)), scope: scope,
            observedAt: latest.map(timestamp), lastFailureAt: failureAt.map(timestamp), origin: origin, status: status,
            availableResetCredits: visible ? fact?.count : nil,
            resetCards: Array(cards.prefix(100)),
            resetCardsPartial: !visible || fact?.count == nil || fact?.count != min(cards.count, 100),
            points: visible ? fact?.points : nil, pointsState: visible ? fact?.pointsState ?? .unknown : .unknown,
            fiveHour: visible ? fact?.fiveHour : nil, sevenDay: visible ? fact?.sevenDay : nil)
    }

    private static func project(_ input: TokenObservation?, now: Date) -> Tokens {
        guard let input else {
            return Tokens(totalTokens: nil, source: .unavailable, observedAt: nil, status: .unknown, isPartial: nil)
        }
        let count = input.totalTokens.flatMap { (0...9_007_199_254_740_991).contains($0) ? String($0) : nil }
        let date = input.observedAt.flatMap { validDate($0) && $0 <= now ? $0 : nil }
        let status: Status =
            !input.sourceSucceeded
            ? .failed
            : count == nil || date == nil || input.source == .unavailable
                ? .unknown
                : now.timeIntervalSince(date!) > freshness ? .stale : .ok
        return Tokens(
            totalTokens: input.sourceSucceeded && input.source != .unavailable ? count : nil,
            source: input.source, observedAt: date.map(timestamp), status: status, isPartial: input.isPartial)
    }

    private static func quota(_ value: RateWindow?) -> Quota? {
        guard let value, value.usedPercent.isFinite, (0...100).contains(value.usedPercent) else { return nil }
        return Quota(remainingPercent: value.remainingPercent, resetsAt: value.resetsAt.flatMap { validDate($0) ? timestamp($0) : nil })
    }

    private static func coverage(_ known: Int, _ total: Int, excluded: Int) -> Completeness {
        known == 0 ? .unknown : known == total && excluded == 0 ? .complete : .partial
    }

    private static func exactDecimal(_ text: String) -> Decimal? {
        let plain = text.replacingOccurrences(of: ",", with: "")
        // Decimal has at most 38 significant digits. Reject possible rounding.
        guard plain.filter(\.isNumber).count <= 38 else { return nil }
        return Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func sumPoints(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var sum = Decimal.zero
        for value in values {
            guard var number = exactDecimal(value) else { return nil }
            var next = Decimal.zero
            guard NSDecimalAdd(&next, &sum, &number, .plain) == .noError else { return nil }
            sum = next
        }
        return NSDecimalNumber(decimal: sum).stringValue
    }

    private static func reference(_ kind: String, _ value: String) -> String {
        // Letters-only hashes also satisfy V1's phone-number rejection rule.
        let digits = Array("0123456789abcdef")
        let letters = Array("abcdefghijklmnop")
        return String(CodexResetNoticeKey.hash("miniprogram-codex-" + kind + "\0" + value).map { letters[digits.firstIndex(of: $0)!] })
    }

    private static func validDate(_ value: Date) -> Bool {
        value.timeIntervalSince1970.isFinite && value.timeIntervalSince1970 >= 946_684_800
            && value.timeIntervalSince1970 < 253_402_300_799
    }

    private static var parser: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func timestamp(_ value: Date) -> String { parser.string(from: value) }
}
