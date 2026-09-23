import Foundation

enum LocalCLIKind: String, Codable, CaseIterable, Identifiable {
    case claudeCode
    case grok
    case openCode
    case trae
    case workBuddy
    case kimi
    case mimo
    case zcode
    case gemini
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .grok: "Grok"
        case .openCode: "OpenCode"
        case .trae: "TRAE"
        case .workBuddy: "WorkBuddy"
        case .kimi: "Kimi Code"
        case .mimo: "MiMo"
        case .zcode: "ZCode"
        case .gemini: "Gemini CLI"
        case .antigravity: "Antigravity"
        }
    }

    var commandName: String {
        switch self {
        case .claudeCode: "claude"
        case .grok: "grok"
        case .openCode: "opencode"
        case .trae: "traecli"
        case .workBuddy: "codebuddy"
        case .kimi: "kimi"
        case .mimo: "mimo"
        case .zcode: "zcode"
        case .gemini: "gemini"
        case .antigravity: "antigravity"
        }
    }

    func defaultConfigDirectory(home: URL) -> URL {
        switch self {
        case .claudeCode:
            home.appendingPathComponent(".claude", isDirectory: true)
        case .grok:
            home.appendingPathComponent(".grok", isDirectory: true)
        case .openCode:
            home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        case .trae:
            home.appendingPathComponent(".trae-cn", isDirectory: true)
        case .workBuddy:
            home.appendingPathComponent(".workbuddy", isDirectory: true)
        case .kimi:
            home.appendingPathComponent(".kimi-code", isDirectory: true)
        case .mimo:
            home.appendingPathComponent(".local/share/mimocode", isDirectory: true)
        case .zcode:
            home.appendingPathComponent(".zcode", isDirectory: true)
        case .gemini:
            home.appendingPathComponent(".gemini", isDirectory: true)
        case .antigravity:
            home.appendingPathComponent("Library/Application Support/Antigravity", isDirectory: true)
        }
    }

    var supportsTerminalSignIn: Bool {
        switch self {
        case .claudeCode, .grok, .openCode, .workBuddy, .kimi, .gemini: true
        case .zcode, .trae, .mimo, .antigravity: false
        }
    }

    var isDesktopApplication: Bool { self == .zcode || self == .trae || self == .antigravity }

    var supportsNativeOpen: Bool {
        switch self {
        case .claudeCode, .grok, .openCode, .trae, .workBuddy, .zcode, .kimi, .gemini, .antigravity: true
        case .mimo: false
        }
    }

    var supportsLinkedEnvironments: Bool { self != .trae }

    // These providers may keep authentication outside their config folder.
    // Linked folders stay read-only until their complete isolation is supported.
    var requiresDefaultEnvironmentForLaunch: Bool {
        self == .claudeCode || self == .gemini || self == .zcode || self == .trae || self == .antigravity
    }
}

enum WorkBuddyEdition: String, CaseIterable {
    case domestic, international

    var applicationName: String { self == .domestic ? "WorkBuddy.app" : "WorkBuddy AI.app" }
    var directoryName: String { self == .domestic ? ".workbuddy" : ".workbuddy-ai" }
    var defaultProfileID: String { self == .domestic ? "local-workBuddy" : "local-workBuddy-ai" }

    static func forProfile(_ profile: LocalCLIProfile) -> Self {
        URL(fileURLWithPath: profile.configDirectory).lastPathComponent == ".workbuddy-ai" ? .international : .domestic
    }
}

struct LocalCLIProfile: Identifiable, Codable, Equatable {
    var id: String
    var kind: LocalCLIKind
    var displayName: String
    var configDirectory: String
    var isDefault: Bool
}

struct LocalCLIQuotaWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

/// A read-only observation copied from the signed-in official Grok Usage page.
///
/// This deliberately contains no account name, e-mail, token, cookie or page
/// body. The four Codable fields are the complete import contract: an anonymous
/// Grok fingerprint, the exact strings visible in the official modal, the time
/// at which they were seen, and the official source URL.
struct GrokResetStatusObservation: Codable, Equatable, Sendable {
    static let freshnessWindow: TimeInterval = 300
    static let officialAvailableTitle = "Usage Limit Reset"
    static let officialAvailableStatus = "Reset Available"
    static let officialAvailableStrings = [
        officialAvailableTitle,
        officialAvailableStatus,
        "Expires in 1 day",
    ]

    enum Evidence: Equatable, Sendable {
        case availableUnknownCountAndExactExpiry
        case unavailable
        case unknown
        case expired
        case ambiguous
    }

    let accountFingerprint: String
    let visibleStrings: [String]
    let observedAt: Date
    let sourceURL: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case accountFingerprint
        case visibleStrings
        case observedAt
        case sourceURL
    }

    init(
        accountFingerprint: String,
        visibleStrings: [String],
        observedAt: Date,
        sourceURL: String
    ) {
        self.accountFingerprint = accountFingerprint
        self.visibleStrings = visibleStrings
        self.observedAt = observedAt
        self.sourceURL = sourceURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountFingerprint = try container.decode(String.self, forKey: .accountFingerprint)
        visibleStrings = try container.decode([String].self, forKey: .visibleStrings)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)

        let dateDecoder = try container.superDecoder(forKey: .observedAt)
        let value = try dateDecoder.singleValueContainer()
        if let string = try? value.decode(String.self), let date = Self.parseDate(string) {
            observedAt = date
        } else if let seconds = try? value.decode(Double.self), seconds.isFinite {
            observedAt = Date(timeIntervalSince1970: seconds)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .observedAt,
                in: container,
                debugDescription: "Grok reset observation time is not an ISO-8601 date or finite Unix time")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountFingerprint, forKey: .accountFingerprint)
        try container.encode(visibleStrings, forKey: .visibleStrings)
        try container.encode(Self.iso8601(observedAt), forKey: .observedAt)
        try container.encode(sourceURL, forKey: .sourceURL)
    }

    var evidence: Evidence {
        Self.classify(visibleStrings)
    }

    /// A status is deliberately narrower than the visible-text contract. The
    /// source keeps every original line, while this parser only recognizes a
    /// small, explicit vocabulary and a bounded relative-date grammar.
    private static func classify(_ strings: [String]) -> Evidence {
        let normalized = strings.map(normalizedLine)
        guard !normalized.isEmpty else { return .ambiguous }

        let title = normalized.first.map { stripTerminalPunctuation($0).lowercased() }
        let hasOfficialTitle = title == officialAvailableTitle.lowercased()
        guard hasOfficialTitle else { return .ambiguous }
        let body = normalized.dropFirst().map { stripTerminalPunctuation($0).lowercased() }
        guard body.count >= 1, body.count <= 2 else { return .unknown }
        let bodyHasUnknown = body.contains { unknownPhrases.contains($0) }
        let bodyHasUnavailable = body.contains { unavailablePhrases.contains($0) }
        let bodyHasAvailable = body.contains { availablePhrases.contains($0) }
        let relativeExpiry = body.compactMap(parseRelativeExpiry)
        let bodyHasExpired = body.contains { expiredPhrases.contains($0) }
        let bodyIsBoundedSyntax = body.allSatisfy {
            availablePhrases.contains($0)
                || unavailablePhrases.contains($0)
                || unknownPhrases.contains($0)
                || expiredPhrases.contains($0)
                || parseRelativeExpiry($0) != nil
        }

        guard bodyIsBoundedSyntax else {
            return .unknown
        }
        let explicitStatusCount = body.filter {
            availablePhrases.contains($0)
                || unavailablePhrases.contains($0)
                || unknownPhrases.contains($0)
                || expiredPhrases.contains($0)
        }.count
        guard explicitStatusCount == 1, relativeExpiry.count <= 1 else { return .unknown }
        if bodyHasUnavailable {
            return .unavailable
        }
        if bodyHasExpired {
            return .expired
        }
        if hasOfficialTitle && bodyHasUnknown {
            return .unknown
        }
        if hasOfficialTitle && (bodyHasAvailable || !relativeExpiry.isEmpty) {
            // The relative wording is independent evidence. It is retained as
            // text only; no timestamp is inferred from it.
            return .availableUnknownCountAndExactExpiry
        }
        return .unknown
    }

    /// The title line is safe to render for both fresh and stale observations.
    /// It is nil for an unrecognised/ambiguous set of visible strings.
    var displayTitle: String? {
        guard evidence != .ambiguous else { return nil }
        return visibleStrings.first
    }

    /// The detail line intentionally retains the relative expiry wording. It
    /// never turns "1 day" into a timestamp or a card count.
    var displayDetail: String? {
        guard evidence != .ambiguous, visibleStrings.count > 1 else { return nil }
        return visibleStrings.dropFirst().joined(separator: " · ")
    }

    /// A dated line is available even after the 300-second freshness window.
    /// The date is an observation timestamp, not an inferred card expiry.
    var datedDisplayDetail: String? {
        guard let detail = displayDetail else { return nil }
        return "\(detail) · Observed \(Self.iso8601(observedAt))"
    }

    /// Status-only website evidence has no exact count or expiry. Availability
    /// is not a count of one and cannot authorize redemption or priority.
    var availableCount: Int? { nil }
    var exactExpiry: Date? { nil }
    var status: Status? {
        switch evidence {
        case .availableUnknownCountAndExactExpiry: .available
        case .unavailable: .unavailable
        case .unknown: .unknown
        case .expired: .expired
        case .ambiguous: nil
        }
    }

    enum Status: Equatable, Sendable {
        case available
        case unavailable
        case unknown
        case expired
    }

    /// The raw relative wording is exposed separately from status. It is only
    /// a display value and is never converted to an absolute expiry date.
    var relativeExpiryText: String? {
        guard evidence != .ambiguous else { return nil }
        return visibleStrings.dropFirst().first(where: {
            Self.parseRelativeExpiry(Self.stripTerminalPunctuation(Self.normalizedLine($0))) != nil
        })
    }

    /// Only fresh affirmative or negative evidence is a current status.
    /// Unknown, explicitly expired, and stale observations remain dated history.
    func currentStatus(at now: Date) -> Status? {
        guard isObservationFresh(at: now) else { return nil }
        switch status {
        case .available, .unavailable: return status
        case .unknown, .expired, nil: return nil
        }
    }

    func mayAffectPriority(at now: Date) -> Bool {
        currentStatus(at: now) == .available
    }
    var mayAuthorizeRedemption: Bool { false }

    /// Structural validation does not require the observation to be fresh. A
    /// stale but valid observation remains useful as dated display text.
    func isStructurallyValid() -> Bool {
        Self.validFingerprint(accountFingerprint)
            && visibleStrings.count >= 1 && visibleStrings.count <= 16
            && visibleStrings.allSatisfy {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && $0.utf8.count <= 256
                    && !$0.unicodeScalars.contains {
                        CharacterSet.controlCharacters.contains($0) && $0.value != 0x09
                    }
            }
            && observedAt.timeIntervalSince1970.isFinite
            && Self.validSourceURL(sourceURL)
    }

    /// Future observations are rejected. Old observations are accepted so
    /// callers can keep their dated text while explicitly gating actions.
    func isValid(at now: Date) -> Bool {
        isStructurallyValid() && now.timeIntervalSince1970.isFinite
            && observedAt <= now
    }

    func isObservationFresh(at now: Date) -> Bool {
        guard isValid(at: now) else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age.isFinite && age >= 0 && age <= Self.freshnessWindow
    }

    func isFresh(at now: Date) -> Bool {
        currentStatus(at: now) == .available
    }

    static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
            }
    }

    static func validSourceURL(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048,
            !value.isEmpty,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            let url = URL(string: value),
            url.scheme?.lowercased() == "https",
            url.user == nil,
            url.password == nil,
            url.port == nil,
            let host = url.host?.lowercased()
        else { return false }
        // Keep the allowlist exact. In particular, do not accept arbitrary
        // subdomains or a look-alike suffix such as grok.com.example.test.
        return ["grok.com", "www.grok.com", "accounts.x.ai", "x.ai", "www.x.ai"].contains(host)
    }

    private static let availablePhrases: Set<String> = [
        "reset available",
        "reset card available",
        "reset cards available",
    ]

    private static let unavailablePhrases: Set<String> = [
        "no reset available",
        "no reset card available",
        "no reset cards available",
        "no reset card is available",
        "no reset cards are available",
        "no reset card",
        "no reset cards",
        "reset unavailable",
        "reset card unavailable",
        "reset cards unavailable",
        "reset not available",
        "reset card not available",
        "reset cards not available",
    ]

    private static let unknownPhrases: Set<String> = [
        "reset status unknown",
        "reset availability unknown",
        "reset card status unknown",
        "unknown",
    ]

    private static let expiredPhrases: Set<String> = [
        "expired",
        "reset expired",
        "reset card expired",
        "reset cards expired",
        "no longer available",
    ]

    private static func normalizedLine(_ value: String) -> String {
        var pieces: [String] = []
        var piece = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !piece.isEmpty {
                    pieces.append(piece)
                    piece = ""
                }
            } else {
                piece.unicodeScalars.append(scalar)
            }
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces.joined(separator: " ")
    }

    private static func stripTerminalPunctuation(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scalar = result.unicodeScalars.last, ".,:;!?。！？：；，、".unicodeScalars.contains(scalar) {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseRelativeExpiry(_ value: String) -> String? {
        let normalized = normalizedLine(value)
        let tokens = stripTerminalPunctuation(normalized).lowercased().split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count == 4, tokens[0] == "expires", tokens[1] == "in" else { return nil }
        let numberToken = String(tokens[2])
        guard numberToken.count <= 3, !numberToken.isEmpty,
            numberToken.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
            let number = Int(numberToken), (1...365).contains(number)
        else { return nil }
        let unit = String(tokens[3])
        guard ["minute", "minutes", "hour", "hours", "day", "days", "week", "weeks", "month", "months", "year", "years"].contains(unit)
        else { return nil }
        if number == 1 {
            guard ["minute", "hour", "day", "week", "month", "year"].contains(unit) else { return nil }
        } else {
            guard ["minutes", "hours", "days", "weeks", "months", "years"].contains(unit) else { return nil }
        }
        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// One prepaid reset card attached to a CLI account.
///
/// Data contract (2026-09-11): the official Grok CLI billing response recorded in
/// `review-inputs/grok-reset-schema-0911v1.json` (HTTP 200) carries no reset-card
/// fields (`resetCardFieldsPresent: false`). `quotaResetAt`, `currentPeriod.end` and
/// `billingPeriodEnd` describe quota or billing cycles and must never be mapped onto
/// `expiresAt`. Production parsing therefore keeps the card list `nil`
/// ("information unavailable"); synthetic exact-card data exists only in offline
/// fixtures so merge precedence can be validated without inventing an API shape.
struct LocalCLIResetCard: Identifiable, Equatable {
    let id: String
    let expiresAt: Date?
}

enum LocalCLIQuotaState: String {
    case available
    case unavailable
    case needsLogin
    case unsupported
    case rateLimited
}

struct LocalCLIQuotaResult: Equatable {
    let state: LocalCLIQuotaState
    let fetchedAt: Date
    let maskedIdentity: String?
    let identityFingerprint: String?
    let planLabel: String?
    let windows: [LocalCLIQuotaWindow]
    let balance: Double?
    let balanceCurrency: String?
    let sourceLabel: String
    let messageCode: String?
    /// `nil` means the official response carried no reset-card fields (the case for
    /// Grok per review-inputs/grok-reset-schema-0911v1.json). A non-nil list comes
    /// only from future officially documented exact card evidence; quota reset dates
    /// never fill it.
    var resetCards: [LocalCLIResetCard]? = nil
    /// The read time for `resetCards`, kept separately so an omitted card field
    /// cannot make an older known set look freshly observed after a quota refresh.
    var resetCardsObservedAt: Date? = nil
    /// Website evidence is intentionally separate from billing-card evidence:
    /// the official Usage modal can say that a reset is available without
    /// exposing a count or an exact expiry timestamp.
    var grokResetObservation: GrokResetStatusObservation? = nil
    /// The provider may return a billing-period boundary without a usage
    /// percentage. Preserve it independently; it is not a reset-card expiry.
    var periodResetsAt: Date? = nil
}

enum LocalCLIQuotaPresentation {
    static func boundedLabel(_ value: String?, maximumUTF8Bytes: Int = 64) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.utf8.count <= maximumUTF8Bytes,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return trimmed
    }

    static func validIdentity(_ value: String?) -> String? {
        guard let value = boundedLabel(value, maximumUTF8Bytes: 254) else { return nil }
        if value.contains("@") {
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                let domain = boundedLabel(String(parts[1]), maximumUTF8Bytes: 128),
                domain.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) })
            else { return nil }
        }
        return value
    }

    static func maskedIdentity(_ value: String) -> String {
        if let at = value.firstIndex(of: "@") {
            return "\(value[..<at].prefix(1))***@\(value[value.index(after: at)...])"
        }
        guard value.count > 4 else { return String(repeating: "*", count: max(3, value.count)) }
        return "\(value.prefix(2))***\(value.suffix(2))"
    }

    static func validWindows(_ windows: [LocalCLIQuotaWindow]) -> Bool {
        windows.count <= 256 && Set(windows.map(\.id)).count == windows.count
            && windows.allSatisfy {
                boundedLabel($0.id, maximumUTF8Bytes: 128) != nil
                    && boundedLabel($0.label, maximumUTF8Bytes: 128) != nil
                    && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                    && ($0.resetsAt.map { $0.timeIntervalSince1970.isFinite } ?? true)
            }
    }

    static func validResetCards(_ cards: [LocalCLIResetCard]) -> Bool {
        cards.count <= 256
            && Set(cards.map(\.id)).count == cards.count
            && cards.allSatisfy {
                boundedLabel($0.id, maximumUTF8Bytes: 128) != nil
                    && ($0.expiresAt.map { $0.timeIntervalSince1970.isFinite } ?? true)
            }
    }
}

extension LocalCLIQuotaResult {
    // Two-line UI wiring (owned by ZCode): render `officialGrokResetTitle` on
    // line one and `officialGrokResetDetail` on line two. Use only
    // `officialGrokResetMayAffectPriority(at:)` for observation-driven ordering;
    // never derive a count or exact expiry from these strings.
    var officialGrokResetTitle: String? { grokResetObservation?.displayTitle }
    var officialGrokResetDetail: String? { grokResetObservation?.datedDisplayDetail }
    var officialGrokResetObservedAt: Date? { grokResetObservation?.observedAt }
    var officialGrokResetStatus: GrokResetStatusObservation.Status? { grokResetObservation?.status }
    var officialGrokResetRelativeExpiry: String? { grokResetObservation?.relativeExpiryText }

    func officialGrokResetCurrentStatus(at now: Date) -> GrokResetStatusObservation.Status? {
        grokResetObservation?.currentStatus(at: now)
    }

    func officialGrokResetIsFresh(at now: Date) -> Bool {
        grokResetObservation?.isFresh(at: now) == true
    }

    var officialGrokResetIsFresh: Bool {
        officialGrokResetIsFresh(at: Date())
    }

    var officialGrokResetAvailableCount: Int? { grokResetObservation?.availableCount }
    var officialGrokResetExactExpiry: Date? { grokResetObservation?.exactExpiry }
    func officialGrokResetMayAffectPriority(at now: Date) -> Bool {
        grokResetObservation?.mayAffectPriority(at: now) == true
    }
    var officialGrokResetMayAuthorizeRedemption: Bool {
        grokResetObservation?.mayAuthorizeRedemption == true
    }

    var officialGrokResetCardEvidenceAt: Date? {
        resetCardsObservedAt ?? (resetCards == nil ? nil : fetchedAt)
    }

    func officialGrokResetCardsAreFresh(at now: Date) -> Bool {
        guard let evidenceAt = officialGrokResetCardEvidenceAt else { return false }
        let age = now.timeIntervalSince(evidenceAt)
        return age.isFinite && age >= 0 && age <= GrokResetStatusObservation.freshnessWindow
    }
}
