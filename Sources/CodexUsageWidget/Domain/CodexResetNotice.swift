import CryptoKit
import Foundation

struct CodexResetCreditExpiryBatch: Codable, Equatable {
    let expiresAt: Date
    let count: Int
}

/// A successful official single-card consume response, never inferred from a balance delta.
/// Only hashes and the confirmation time are persisted or passed to notification builders.
struct CodexManualResetNotice: Codable, Equatable {
    let eventHash: String
    let profileHash: String
    let confirmedAt: Date

    var isValid: Bool {
        [eventHash, profileHash].allSatisfy { value in
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        } && confirmedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

enum CodexResetNoticeChannel: String, Codable, CaseIterable {
    case local, feishu, telegram
    case weChat = "wechat"
    case personalWeChat = "personal-wechat"
}

/// Only hashes of backend card identifiers may leave the fresh official reader.
/// A display/cache index is not a card identifier.
struct CodexResetNoticeCard: Codable, Equatable, Hashable {
    let cardHash: String
    let expiresAt: Date?

    init?(cardID: String, expiresAt: Date?) {
        guard CodexResetNoticeKey.validBackendID(cardID),
            expiresAt?.timeIntervalSinceReferenceDate.isFinite != false
        else { return nil }
        self.cardHash = CodexResetNoticeKey.hash(cardID)
        self.expiresAt = expiresAt
    }

    var isValid: Bool {
        CodexResetNoticeKey.validHash(cardHash)
            && expiresAt?.timeIntervalSinceReferenceDate.isFinite != false
    }
}

struct CodexResetNoticeObservation: Codable, Equatable {
    let accountHash: String
    let observedAt: Date
    let availableCount: Int?
    let cards: [CodexResetNoticeCard]?
    let verificationSucceeded: Bool

    /// Call only with a fresh official UsageSnapshot, after the existing identity
    /// gate. Cached projections and engine-only counts do not prove card IDs.
    static func official(
        accountID: String, snapshot: UsageSnapshot, identityVerified: Bool
    ) -> Self? {
        guard CodexResetNoticeKey.validBackendID(accountID),
            snapshot.refreshedAt.timeIntervalSinceReferenceDate.isFinite
        else { return nil }
        let accountHash = CodexResetNoticeKey.hash(accountID)
        let verified = identityVerified && snapshot.quotaReadSucceeded
        let details = verified ? snapshot.credits?.resetCreditDetails : nil
        let cards = details?.compactMap { CodexResetNoticeCard(cardID: $0.id, expiresAt: $0.expiresAt) }
        let allIDsValid = details == nil || cards?.count == details?.count
        let observation = Self(
            accountHash: accountHash, observedAt: snapshot.refreshedAt,
            availableCount: verified ? snapshot.credits?.resetCredits : nil,
            cards: cards, verificationSucceeded: verified && allIDsValid)
        return observation.isValid ? observation : observation.invalidated
    }

    var isValid: Bool {
        CodexResetNoticeKey.validHash(accountHash)
            && observedAt.timeIntervalSinceReferenceDate.isFinite
            && availableCount.map({ (0...1_000_000).contains($0) }) != false
            && cards.map({ values in
                values.count <= 1_024 && values.allSatisfy(\.isValid)
                    && Set(values.map(\.cardHash)).count == values.count
                    && availableCount.map({ values.count <= $0 }) != false
            }) != false
    }

    var invalidated: Self {
        Self(
            accountHash: accountHash, observedAt: observedAt, availableCount: nil,
            cards: nil, verificationSucceeded: false)
    }

    var canonical: Self {
        Self(
            accountHash: accountHash, observedAt: observedAt, availableCount: availableCount,
            cards: cards?.sorted { $0.cardHash < $1.cardHash }, verificationSucceeded: verificationSucceeded)
    }
}

enum CodexResetNoticeEvaluator {
    static let thresholdSeconds: TimeInterval = 24 * 60 * 60
    static let maximumObservationAge: TimeInterval = 5 * 60

    struct Evaluation: Equatable {
        let accountHash: String
        let observedAt: Date
        let verificationSucceeded: Bool
        let availableCount: Int?
        let eligibleCards: [CodexResetNoticeCard]
        let unknownExpiryCount: Int?
        let nextThresholdAt: Date?

        var expiryBatches: [CodexResetCreditExpiryBatch] {
            CodexResetNoticeCandidate.batches(for: eligibleCards)
        }
    }

    static func evaluate(
        _ observation: CodexResetNoticeObservation, now: Date,
        maximumObservationAge: TimeInterval = maximumObservationAge
    ) -> Evaluation {
        let age = now.timeIntervalSince(observation.observedAt)
        let verified =
            observation.isValid && observation.verificationSucceeded
            && now.timeIntervalSinceReferenceDate.isFinite
            && maximumObservationAge.isFinite && maximumObservationAge > 0 && maximumObservationAge <= 1_800
            && age >= 0 && age <= maximumObservationAge && observation.availableCount != nil
        guard verified else {
            return Evaluation(
                accountHash: observation.accountHash, observedAt: observation.observedAt,
                verificationSucceeded: false, availableCount: nil, eligibleCards: [],
                unknownExpiryCount: nil, nextThresholdAt: nil)
        }
        let cards = observation.cards ?? []
        let known = cards.compactMap(\.expiresAt)
        let eligible = cards.filter { card in
            guard let expiry = card.expiresAt else { return false }
            let remaining = expiry.timeIntervalSince(now)
            return remaining > 0 && remaining <= thresholdSeconds
        }.sorted {
            $0.expiresAt! == $1.expiresAt! ? $0.cardHash < $1.cardHash : $0.expiresAt! < $1.expiresAt!
        }
        let thresholds = known.map { $0.addingTimeInterval(-thresholdSeconds) }.filter { $0 > now }
        return Evaluation(
            accountHash: observation.accountHash, observedAt: observation.observedAt,
            verificationSucceeded: true, availableCount: observation.availableCount,
            eligibleCards: eligible, unknownExpiryCount: observation.availableCount.map { $0 - known.count },
            nextThresholdAt: thresholds.min())
    }
}

struct CodexResetNoticeChange: Codable, Equatable {
    let previous: Int
    let available: Int
    let previousObservedAt: Date
    let observedAt: Date

    var isValid: Bool {
        (0...1_000_000).contains(previous) && (0...1_000_000).contains(available)
            && previous != available
            && previousObservedAt.timeIntervalSinceReferenceDate.isFinite
            && observedAt.timeIntervalSinceReferenceDate.isFinite && previousObservedAt < observedAt
    }
}

struct CodexResetNoticeCandidate: Codable, Equatable {
    enum Content: Codable, Equatable {
        case expiry(cards: [CodexResetNoticeCard])
        case change(CodexResetNoticeChange)
        case manualReset(CodexManualResetNotice)
    }

    let accountHash: String
    let observedAt: Date
    let content: Content

    var expiryBatches: [CodexResetCreditExpiryBatch] {
        guard case .expiry(let cards) = content else { return [] }
        return Self.batches(for: cards)
    }

    static func batches(for cards: [CodexResetNoticeCard]) -> [CodexResetCreditExpiryBatch] {
        let groups = Dictionary(grouping: cards.compactMap(\.expiresAt), by: { $0 })
        return groups.keys.sorted().map { CodexResetCreditExpiryBatch(expiresAt: $0, count: groups[$0]!.count) }
    }

    var isValid: Bool {
        guard CodexResetNoticeKey.validHash(accountHash), observedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        switch content {
        case .expiry(let cards):
            return !cards.isEmpty && cards.count <= 1_024 && cards.allSatisfy { $0.isValid && $0.expiresAt != nil }
                && Set(cards.map(\.cardHash)).count == cards.count
        case .change(let change):
            return change.isValid && observedAt == change.observedAt
        case .manualReset(let manual):
            return manual.isValid && observedAt == manual.confirmedAt
        }
    }

    var items: [Content] {
        switch content {
        case .expiry(let cards):
            return cards.sorted { $0.cardHash < $1.cardHash }.map { .expiry(cards: [$0]) }
        case .change, .manualReset: return [content]
        }
    }
}

enum CodexResetNoticeKey {
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash the complete Date representation; formatting or rounding an expiry
    /// for display must never change its identity.
    static func exactDate(_ value: Date) -> String {
        String(value.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }

    static func expiry(
        accountHash: String, cardHash: String, expiresAt: Date, channel: CodexResetNoticeChannel
    ) -> String {
        hash(["expiry-v1", accountHash, cardHash, exactDate(expiresAt), "86400", channel.rawValue].joined(separator: "|"))
    }

    static func change(
        accountHash: String, previous: Int, available: Int,
        previousObservedAt: Date, observedAt: Date, channel: CodexResetNoticeChannel
    ) -> String {
        hash(
            [
                "change-v1", accountHash, String(previous), String(available),
                exactDate(previousObservedAt), exactDate(observedAt), channel.rawValue,
            ].joined(separator: "|"))
    }

    static func item(_ content: CodexResetNoticeCandidate.Content, accountHash: String, channel: CodexResetNoticeChannel) -> String {
        switch content {
        case .expiry(let cards):
            guard cards.count == 1, let card = cards.first, let expiresAt = card.expiresAt else { return "" }
            return expiry(accountHash: accountHash, cardHash: card.cardHash, expiresAt: expiresAt, channel: channel)
        case .manualReset(let manual):
            return hash(["manual-reset-v1", accountHash, manual.eventHash, channel.rawValue].joined(separator: "|"))
        case .change(let value):
            return change(
                accountHash: accountHash, previous: value.previous, available: value.available,
                previousObservedAt: value.previousObservedAt, observedAt: value.observedAt, channel: channel)
        }
    }

    static func batch(_ candidate: CodexResetNoticeCandidate, channel: CodexResetNoticeChannel) -> String {
        hash((["batch-v1"] + candidate.items.map { item($0, accountHash: candidate.accountHash, channel: channel) }.sorted()).joined(separator: "|"))
    }

    static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validBackendID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    }
}
