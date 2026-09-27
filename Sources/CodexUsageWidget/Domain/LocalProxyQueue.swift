import Foundation

enum LocalProxyPhase: String { case stopped, starting, running, stopping, failed }
struct LocalProxyQueueRow: Identifiable, Equatable {
    let id: String
    let label: String
    let isEnabled: Bool
    let isPriority: Bool
    let isCurrent: Bool
    let quotaText: String?
    let state: String
    let cooldownUntil: Date?
}
struct LocalProxyPreferences: Codable {
    var schemaVersion = 1
    var isEnabled = false
    var order: [String] = []
    var enabledIDs: Set<String> = []
    var knownIDs: Set<String> = []
    var priorityIDs: Set<String> = []
}
enum LocalProxyFailure: String, Error {
    case busy, identity, quota, stopping, unavailable
    case credentialsBusy = "credentials_busy"
    case quotaUnknown = "quota_unknown"
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
    var leaseID: String? = nil
    var accessToken: String? = nil
    var accountID: String? = nil
    var expiresAt: Int64? = nil
    var error: String? = nil
    var retryAt: Int64? = nil
    static func failure(_ reason: LocalProxyFailure) -> Self { Self(ok: false, error: reason.rawValue) }
}

/// Subscription windows only. Credits never grant admission or paid fallback.
enum LocalProxyAdmission {
    static let quotaMaximumAge: TimeInterval = 120
    static func quota(_ profile: CodexProfile, now: Date = Date()) -> LocalProxyFailure? {
        guard let snapshot = profile.lastSnapshot, snapshot.quotaReadSucceeded == true,
            let account = snapshot.accountID, !account.isEmpty,
            let email = snapshot.email, !email.isEmpty,
            (0...quotaMaximumAge).contains(now.timeIntervalSince(snapshot.fetchedAt)),
            (profile.lastQuotaReadFailureAt ?? .distantPast) < snapshot.fetchedAt,
            let seven = snapshot.sevenDay
        else { return .quotaUnknown }
        // Official Pro may omit the short window. Only admit that shape when
        // paid-credit fallback is explicitly impossible; nil is never zero.
        if snapshot.fiveHour == nil {
            guard ["pro", "prolite"].contains(snapshot.planType?.lowercased() ?? ""),
                snapshot.creditBalanceUnlimited == false,
                let balance = snapshot.creditBalance?.trimmingCharacters(in: .whitespacesAndNewlines),
                !balance.isEmpty, let number = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")), number == 0,
                balance.range(of: #"^0+(\.0+)?$"#, options: .regularExpression) != nil
            else { return .quotaUnknown }
        }
        let windows = [seven] + [snapshot.fiveHour, snapshot.monthly].compactMap { $0 }
        guard windows.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.resetsAt.map({ $0 > now }) == true }) else { return .quotaUnknown }
        return windows.contains { $0.usedPercent >= 100 } ? .quota : nil
    }
}
