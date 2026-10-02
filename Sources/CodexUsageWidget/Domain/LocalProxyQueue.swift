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
    var activeRequestCount = 0
    var policy = LocalProxyAccountPolicy()
    var usesDefaultCreditFloors = true
}
struct LocalProxyQuotaWindow: Identifiable, Equatable {
    let id: String
    let remaining: Double?
    let resetsAt: Date?
    var constrainedByWeekly = false
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
    var accountPolicies: [String: LocalProxyAccountPolicy]? = nil

    var creditFloors: (primary: Int, secondary: Int) {
        (creditPrimaryFloor ?? 2000, creditSecondaryFloor ?? 1500)
    }
    static func validCreditFloors(primary: Int, secondary: Int) -> Bool {
        primary > secondary && secondary >= 0
    }
    func policy(for id: String) -> LocalProxyAccountPolicy { accountPolicies?[id] ?? LocalProxyAccountPolicy() }
    func resolvedPolicy(for id: String) -> LocalProxyAccountPolicy {
        var policy = policy(for: id)
        policy.creditPrimaryFloor = policy.creditPrimaryFloor ?? creditFloors.primary
        policy.creditSecondaryFloor = policy.creditSecondaryFloor ?? creditFloors.secondary
        return policy
    }
    var validAccountPolicies: Bool {
        guard let accountPolicies else { return true }
        return accountPolicies.count <= 1000 && accountPolicies.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.isValid }
    }
}

struct LocalProxyAccountPolicy: Codable, Equatable {
    var fiveHourUsedLimit: Double = 100
    var allowsCredits = true
    var creditPrimaryFloor: Int? = nil
    var creditSecondaryFloor: Int? = nil
    var isValid: Bool {
        guard fiveHourUsedLimit.isFinite, (0...100).contains(fiveHourUsedLimit) else { return false }
        if creditPrimaryFloor == nil && creditSecondaryFloor == nil { return true }
        guard let primary = creditPrimaryFloor, let secondary = creditSecondaryFloor else { return false }
        return LocalProxyPreferences.validCreditFloors(primary: primary, secondary: secondary)
    }
}
enum LocalProxyFailure: String, Error {
    case busy, identity, quota, stopping, unavailable
    case credentialsBusy = "credentials_busy"
    case controlBusy = "control_busy"
    case quotaUnknown = "quota_unknown"
    case subscriptionPending = "subscription_pending"
    case loginExpired = "login_expired"
    case stageNotApplicable = "stage_not_applicable"
    case admissionUnknown = "admission_unknown"
    case admissionDeadline = "admission_deadline"
    case usageLimit = "usage_limit"
    case policyChanged = "policy_changed"
}
struct LocalProxyRequest: Decodable, Sendable {
    let schemaVersion: Int
    let runID: String
    let key: String
    let command: String
    let requestID: String
    let profileID: String
    let leaseID: String?
    // Assigned by the socket reader. It is never accepted from the peer.
    var receivedAt: TimeInterval? = nil
    enum CodingKeys: String, CodingKey {
        case schemaVersion, runID, key, command, requestID, profileID, leaseID
    }
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
    var resolution: String? = nil
    static func failure(_ reason: LocalProxyFailure) -> Self { Self(ok: false, error: reason.rawValue) }
}

/// Paid credits are admitted only by an explicit queue opt-in and a fresh,
/// finite balance above the requested floor. Unknown values never grant access.
enum LocalProxyAdmission {
    static let quotaMaximumAge: TimeInterval = 120
    /// A busy, cooling-down or unverified account is not proof that its
    /// subscription is exhausted. Check every enrolled account before credits.
    static func creditPool(
        _ profiles: [CodexProfile], activeIDs: Set<String>, refreshAfter: [String: Date] = [:], policies: [String: LocalProxyAccountPolicy] = [:], now: Date = Date()
    ) -> LocalProxyFailure? {
        guard !activeIDs.isEmpty else { return .identity }
        for id in activeIDs.sorted() {
            let matches = profiles.filter { $0.id == id }
            guard matches.count == 1, let profile = matches.first, !profile.isSystemProfile else { return .identity }
            if let after = refreshAfter[id], (profile.lastSnapshot?.fetchedAt ?? .distantPast) <= after { return .quotaUnknown }
            let failure = quota(profile, now: now, allowPaidCredits: true, policy: policies[id] ?? LocalProxyAccountPolicy())
            if failure == nil { return .subscriptionPending }
            if failure != .quota && failure != .usageLimit { return failure }
        }
        return nil
    }
    static func quota(
        _ profile: CodexProfile, now: Date = Date(), creditFloor: Int? = nil, allowPaidCredits: Bool = false, policy: LocalProxyAccountPolicy = LocalProxyAccountPolicy()
    ) -> LocalProxyFailure? {
        guard policy.isValid else { return .quotaUnknown }
        guard let snapshot = profile.lastSnapshot, snapshot.quotaReadSucceeded == true,
            let account = snapshot.accountID, !account.isEmpty,
            let email = snapshot.email, !email.isEmpty,
            (0...quotaMaximumAge).contains(now.timeIntervalSince(snapshot.fetchedAt)),
            (profile.lastQuotaReadFailureAt ?? .distantPast) < snapshot.fetchedAt,
            let seven = snapshot.sevenDay
        else { return .quotaUnknown }
        // Official Pro can expose only a weekly subscription window. A positive
        // credit balance does not invalidate that subscription; paid admission
        // remains a separate explicit stage after the subscription is exhausted.
        if snapshot.fiveHour == nil {
            guard ["pro", "prolite"].contains(snapshot.planType?.lowercased() ?? "") else { return .quotaUnknown }
            guard policy.fiveHourUsedLimit == 100 else { return .quotaUnknown }
        }
        let windows = [seven] + [snapshot.fiveHour, snapshot.monthly].compactMap { $0 }
        guard windows.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.resetsAt.map({ $0 > now }) == true }) else { return .quotaUnknown }
        if policy.fiveHourUsedLimit < 100,
            let fiveHour = snapshot.fiveHour, fiveHour.usedPercent >= policy.fiveHourUsedLimit
        {
            return .usageLimit
        }
        let exhausted = windows.contains { $0.usedPercent >= 100 }
        guard let creditFloor else { return exhausted ? .quota : nil }
        guard allowPaidCredits, policy.allowsCredits, creditFloor >= 0, exhausted else { return .quota }
        guard snapshot.creditBalanceUnlimited == false,
            let raw = snapshot.creditBalance?.trimmingCharacters(in: .whitespacesAndNewlines),
            raw.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
            let balance = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
            balance > Decimal(creditFloor)
        else { return .quota }
        return nil
    }
}
