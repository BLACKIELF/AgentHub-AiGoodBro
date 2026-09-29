import Foundation

enum LocalProxyPhase: String { case stopped, starting, running, stopping, failed }
struct LocalProxyQueueRow: Identifiable, Equatable {
    let id: String
    let label: String
    var accountNumber: Int? = nil
    var windows: [LocalProxyQuotaWindow] = []
    var creditBalance: CreditBalancePresentation? = nil
    var resetCardCount: Int? = nil
    var snapshotStale = false
    var isDesktopAccount = false
    let isEnabled: Bool
    let isPriority: Bool
    let isCurrent: Bool
    let quotaText: String?
    let state: String
    let cooldownUntil: Date?
}
struct LocalProxyQuotaWindow: Identifiable, Equatable {
    let id: String
    let remaining: Double?
    let resetsAt: Date?
}
struct LocalProxyPreferences: Codable {
    var schemaVersion = 1
    var isEnabled = false
    var order: [String] = []
    var enabledIDs: Set<String> = []
    var knownIDs: Set<String> = []
    var priorityIDs: Set<String> = []
    var creditFallback: Bool? = nil
    var creditPrimaryFloor: Int? = nil
    var creditSecondaryFloor: Int? = nil

    var creditFloors: (primary: Int, secondary: Int) {
        (creditPrimaryFloor ?? 2000, creditSecondaryFloor ?? 1500)
    }
    static func validCreditFloors(primary: Int, secondary: Int) -> Bool {
        primary > secondary && secondary >= 0
    }
}
enum LocalProxyFailure: String, Error {
    case busy, identity, quota, stopping, unavailable
    case credentialsBusy = "credentials_busy"
    case quotaUnknown = "quota_unknown"
    case subscriptionPending = "subscription_pending"
    case loginExpired = "login_expired"
}
struct LocalProxyRequest: Decodable, Sendable {
    let schemaVersion: Int
    let runID: String
    let key: String
    let command: String
    let requestID: String
    let profileID: String
    let leaseID: String?
}
struct LocalProxyReply: Encodable, Sendable {
    var ok: Bool
    var order: [String]? = nil
    var leaseID: String? = nil
    var accessToken: String? = nil
    var accountID: String? = nil
    var expiresAt: Int64? = nil
    var error: String? = nil
    var retryAt: Int64? = nil
    static func failure(_ reason: LocalProxyFailure) -> Self { Self(ok: false, error: reason.rawValue) }
}

/// Paid credits are admitted only by an explicit queue opt-in and a fresh,
/// finite balance above the requested floor. Unknown values never grant access.
enum LocalProxyAdmission {
    static let quotaMaximumAge: TimeInterval = 120
    /// A busy, cooling-down or unverified account is not proof that its
    /// subscription is exhausted. Check every enrolled account before credits.
    static func creditPool(
        _ profiles: [CodexProfile], activeIDs: Set<String>, refreshAfter: [String: Date] = [:], now: Date = Date()
    ) -> LocalProxyFailure? {
        guard !activeIDs.isEmpty else { return .identity }
        for id in activeIDs.sorted() {
            let matches = profiles.filter { $0.id == id }
            guard matches.count == 1, let profile = matches.first, !profile.isSystemProfile else { return .identity }
            if let after = refreshAfter[id], (profile.lastSnapshot?.fetchedAt ?? .distantPast) <= after { return .quotaUnknown }
            let failure = quota(profile, now: now, allowPaidCredits: true)
            if failure == nil { return .subscriptionPending }
            if failure != .quota { return failure }
        }
        return nil
    }
    static func quota(_ profile: CodexProfile, now: Date = Date(), creditFloor: Int? = nil, allowPaidCredits: Bool = false) -> LocalProxyFailure? {
        guard let snapshot = profile.lastSnapshot, snapshot.quotaReadSucceeded == true,
            let account = snapshot.accountID, !account.isEmpty,
            let email = snapshot.email, !email.isEmpty,
            (0...quotaMaximumAge).contains(now.timeIntervalSince(snapshot.fetchedAt)),
            (profile.lastQuotaReadFailureAt ?? .distantPast) < snapshot.fetchedAt,
            let seven = snapshot.sevenDay
        else { return .quotaUnknown }
        // Official Pro may omit the short window. Without explicit paid-credit
        // permission, that shape still requires a confirmed zero credit balance.
        if snapshot.fiveHour == nil {
            guard ["pro", "prolite"].contains(snapshot.planType?.lowercased() ?? "") else { return .quotaUnknown }
            if !allowPaidCredits {
                guard snapshot.creditBalanceUnlimited == false,
                    let balance = snapshot.creditBalance?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !balance.isEmpty, let number = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")), number == 0,
                    balance.range(of: #"^0+(\.0+)?$"#, options: .regularExpression) != nil
                else { return .quotaUnknown }
            }
        }
        let windows = [seven] + [snapshot.fiveHour, snapshot.monthly].compactMap { $0 }
        guard windows.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.resetsAt.map({ $0 > now }) == true }) else { return .quotaUnknown }
        let exhausted = windows.contains { $0.usedPercent >= 100 }
        guard let creditFloor else { return exhausted ? .quota : nil }
        guard allowPaidCredits, creditFloor >= 0, exhausted else { return .quota }
        guard snapshot.creditBalanceUnlimited == false,
            let raw = snapshot.creditBalance?.trimmingCharacters(in: .whitespacesAndNewlines),
            raw.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
            let balance = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
            balance > Decimal(creditFloor)
        else { return .quota }
        return nil
    }
}
