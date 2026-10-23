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
    var isProPlan = false
    let isEnabled: Bool
    let isPriority: Bool
    let isCurrent: Bool
    let quotaText: String?
    let state: String
    let cooldownUntil: Date?
    var cooldownKind: String? = nil
    var probeState: String? = nil
    var activeRequestCount = 0
    var policy = LocalProxyAccountPolicy()
    var usesDefaultCreditFloors = true
    var isLast = false
    var isFixedLast = false
    var pausesAfterReset = false
    var resetPausedAt: Date? = nil
}
struct LocalProxyQuotaWindow: Identifiable, Equatable {
    let id: String
    let remaining: Double?
    let resetsAt: Date?
    var constrainedByWeekly = false
    var isWeeklyOnlyPro = false
}
struct LocalProxyPreferences: Codable {
    var schemaVersion = 1
    var isEnabled = false
    var order: [String] = []
    var enabledIDs: Set<String> = []
    var knownIDs: Set<String> = []
    var priorityIDs: Set<String> = []
    var lastIDs: Set<String>? = nil
    // Absence keeps the inherited/default rule; false is an explicit opt-out.
    var lastOverrides: [String: Bool]? = nil
    var creditFallback: Bool? = nil
    var creditPrimaryFloor: Int? = nil
    var creditSecondaryFloor: Int? = nil
    var accountPolicies: [String: LocalProxyAccountPolicy]? = nil
    var resetStopRules: [String: LocalProxyResetStopRule]? = nil
    // Persist the visible home for a known identity without storing its email.
    var accountRepresentatives: [String: String]? = nil

    var listenPort: Int? = nil
    var clientKeyMode: LocalProxyClientKeyMode? = nil
    // In-memory credentials; the store writes only a Keychain reference to disk.
    var secretsReference: String? = nil
    var persistentClientKey: String? = nil
    var egress: LocalProxyEgressSettings? = nil
    var effectiveListenPort: Int { listenPort ?? 18080 }
    var effectiveClientKeyMode: LocalProxyClientKeyMode { clientKeyMode ?? .persistent }
    var validNetworkSettings: Bool {
        (effectiveListenPort == 0 || (1024...65535).contains(effectiveListenPort))
            && (persistentClientKey.map { Data(base64Encoded: $0)?.count == 32 } ?? true)
            && (egress ?? LocalProxyEgressSettings()).isValid
    }

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
    var validResetStopRules: Bool {
        guard let resetStopRules else { return true }
        return resetStopRules.count <= 1000
            && resetStopRules.allSatisfy {
                !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.isValid
            }
    }
    var validAccountPolicies: Bool {
        guard let accountPolicies else { return true }
        return accountPolicies.count <= 1000 && accountPolicies.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.isValid }
    }
    var validAccountRepresentatives: Bool {
        guard let accountRepresentatives else { return true }
        return accountRepresentatives.count <= 1000
            && accountRepresentatives.allSatisfy {
                $0.key.utf8.count == 64 && $0.key.allSatisfy { "0123456789abcdef".contains($0) }
                    && !$0.value.isEmpty && $0.value.utf8.count <= 256
            }
    }
    var validLastIDs: Bool {
        guard let lastIDs else { return true }
        return lastIDs.count <= 1000 && lastIDs.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
    }
    var validLastOverrides: Bool {
        guard let lastOverrides else { return true }
        return lastOverrides.count <= 1000 && lastOverrides.keys.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
    }
}

/// Optional, account-bound automation. Only hashes and observation dates persist.
struct LocalProxyResetStopRule: Codable, Equatable {
    let accountHash: String
    let armedAt: Date
    var pausedAt: Date? = nil

    var isValid: Bool {
        accountHash.utf8.count == 64 && accountHash.allSatisfy { "0123456789abcdef".contains($0) }
            && armedAt.timeIntervalSince1970.isFinite
            && pausedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= armedAt } != false
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
    case registryStateInvalid = "registry_state_invalid"
    case registryUnavailable = "registry_unavailable"
    case quotaUnknown = "quota_unknown"
    case subscriptionPending = "subscription_pending"
    case loginExpired = "login_expired"
    case stageNotApplicable = "stage_not_applicable"
    case notParticipating = "not_participating"
    case admissionUnknown = "admission_unknown"
    case acquireAbandoned = "acquire_abandoned"
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
    var lastResortIDs: [String]? = nil
    var deferredIDs: [String]? = nil
    var creditFallback: Bool? = nil
    var leaseID: String? = nil
    var accessToken: String? = nil
    var accountID: String? = nil
    var expiresAt: Int64? = nil
    var error: String? = nil
    var retryAt: Int64? = nil
    var resolution: String? = nil
    var quotaObservedAt: Double? = nil
    var probeStatus: String? = nil
    var probeObservedAt: Double? = nil
    var probeIdentityHash: String? = nil
    static func failure(_ reason: LocalProxyFailure) -> Self { Self(ok: false, error: reason.rawValue) }
}

/// This affects selection order only; quota and identity admission stay separate.
enum LocalProxyRouting {
    static func isLastResort(_ profile: CodexProfile) -> Bool {
        // All verified Pro plans share the same default. A local multiplier or
        // account name is display metadata, never routing evidence.
        ["pro", "prolite"].contains(profile.resolvedPlanType ?? "")
    }
    static func group(_ profile: CodexProfile, userLast: Bool, lastOverride: Bool? = nil) -> Int {
        // Default and explicit last choices share one movable group. Only a
        // missing override inherits the default; a saved false survives reloads
        // and plan changes instead of silently putting Pro back at the end.
        (lastOverride ?? (userLast || isLastResort(profile))) ? 1 : 0
    }
}

/// Paid credits are admitted only by an explicit queue opt-in and a fresh,
/// finite balance above the requested floor. Unknown values never grant access.
enum LocalProxyAdmission {
    static let quotaMaximumAge: TimeInterval = 120
    static let quotaRefreshWait: TimeInterval = 6
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
        // Pro and Prolite require the official seven-day window. Absent short
        // windows do not block admission, but a valid reported exhausted limit
        // still prevents subscription use. The display multiplier is irrelevant.
        let isPro = profile.isProPlan
        if !isPro && snapshot.fiveHour == nil { return .quotaUnknown }
        let windows = isPro ? [seven] : [seven] + [snapshot.fiveHour, snapshot.monthly].compactMap { $0 }
        guard windows.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.resetsAt.map({ $0 > now }) == true }) else { return .quotaUnknown }
        let extraWindows: [CodexQuotaWindowSnapshot] = [snapshot.fiveHour, snapshot.monthly].compactMap { $0 }
        let reportedExtraExhausted =
            isPro
            && extraWindows.contains { window in
                let validExhaustedPercent = window.usedPercent.isFinite && window.usedPercent >= 100 && window.usedPercent <= 100
                let hasFutureReset = window.resetsAt.map { $0 > now } == true
                return validExhaustedPercent && hasFutureReset
            }
        if !isPro && policy.fiveHourUsedLimit < 100,
            let fiveHour = snapshot.fiveHour, fiveHour.usedPercent >= policy.fiveHourUsedLimit
        {
            return .usageLimit
        }
        let exhausted = windows.contains { $0.usedPercent >= 100 } || reportedExtraExhausted
        // An explicit official extra hard limit cannot be bypassed with points.
        if reportedExtraExhausted { return .quota }
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

enum LocalProxyClientKeyMode: String, Codable, CaseIterable {
    case persistent, perRun
}

struct LocalProxyEgressSettings: Codable, Equatable {
    var enabled = false
    var mihomoAPI = ""
    // Hydrated from the dedicated Keychain item; omitted from persisted preferences.
    var mihomoSecret = ""
    var group = ""
    var whitelist: [String] = []
    var isUntouchedLegacyDefault: Bool {
        enabled && mihomoAPI == "http://127.0.0.1:9097" && group == "极简" && whitelist.isEmpty && mihomoSecret.isEmpty
    }
    var isValid: Bool {
        if enabled || !mihomoAPI.isEmpty {
            guard let url = URLComponents(string: mihomoAPI), url.scheme == "http",
                ["127.0.0.1", "[::1]", "::1"].contains(url.host ?? ""),
                url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                url.path.isEmpty, url.port.map({ (1...65535).contains($0) }) != false
            else { return false }
        }
        guard !enabled || !group.isEmpty, group.utf8.count <= 256, !group.contains(where: \.isNewline), !group.contains("\0"),
            group == group.trimmingCharacters(in: .whitespacesAndNewlines),
            mihomoSecret.utf8.count <= 4096, !mihomoSecret.contains(where: \.isNewline), !mihomoSecret.contains("\0"),
            whitelist.count <= 64, Set(whitelist).count == whitelist.count
        else { return false }
        return whitelist.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains(where: \.isNewline) && !$0.contains("\0") && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
