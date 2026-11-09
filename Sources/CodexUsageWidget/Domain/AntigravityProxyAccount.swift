import CryptoKit
import Foundation

enum AntigravityProxyProvider: String, Codable, CaseIterable, Sendable {
    case antigravity, claude, kimi, xai
    var accountPrefix: String { self == .antigravity ? "ag" : rawValue }
}

enum AntigravityProxyPhase: String, Sendable {
    case stopped, starting, running, failed
}

enum AntigravityProxyAccountState: String, Codable, Sendable {
    case checking, ready, busy, cooling, disabled
    case reauthRequired = "reauth_required"
}

struct AntigravityProxyModelDetail: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var remainingFraction: Double? = nil
    var resetAt: Int64? = nil
    var disabled: Bool? = nil

    var resetsAt: Date? { resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var isValid: Bool {
        Self.validModelID(id) && Self.validLabel(displayName)
            && (remainingFraction.map { $0.isFinite && (0...1).contains($0) } ?? true)
            && (resetAt.map(Self.validEpoch) ?? true)
    }
    static func validModelID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) == value.startIndex..<value.endIndex
    }
    static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.newlines.contains($0)
                    || $0.properties.generalCategory == .format
            }
    }
    static func validEpoch(_ value: Int64) -> Bool { (1...253_402_300_799).contains(value) }
}

struct AntigravityProxyQuotaWindow: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var pool: String
    var label: String
    var remainingFraction: Double? = nil
    var resetAt: Int64? = nil
    var modelIDs: [String]? = nil
    var windowSeconds: Int64? = nil
    var remainingAmount: Double? = nil
    var totalAmount: Double? = nil
    var unit: String? = nil

    var resetsAt: Date? { resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var isValid: Bool {
        AntigravityProxyModelDetail.validModelID(id)
            && AntigravityProxyModelDetail.validLabel(pool) && AntigravityProxyModelDetail.validLabel(label)
            && (remainingFraction.map { $0.isFinite && (0...1).contains($0) } ?? true)
            && (resetAt.map(AntigravityProxyModelDetail.validEpoch) ?? true)
            && (windowSeconds.map { (1...31_622_400).contains($0) } ?? true)
            && (remainingAmount.map { $0.isFinite && $0 >= 0 && $0 <= 9_007_199_254_740_991 } ?? true)
            && (totalAmount.map { $0.isFinite && $0 > 0 && $0 <= 9_007_199_254_740_991 } ?? true)
            && (remainingAmount == nil || totalAmount == nil || remainingAmount! <= totalAmount!)
            && (unit.map { $0.utf8.count <= 24 && AntigravityProxyModelDetail.validLabel($0) } ?? true)
            && (modelIDs.map { $0.count <= 512 && Set($0).count == $0.count && $0.allSatisfy(AntigravityProxyModelDetail.validModelID) } ?? true)
    }
}

/// The complete display/persistence DTO. OAuth material is a separate private
/// Keychain record and is never part of this type or an application log.
struct AntigravityProxyAccount: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var provider: AntigravityProxyProvider = .antigravity
    var maskedIdentity: String
    var generation: String
    var enabled: Bool
    var concurrencyLimit: Int
    var inFlight: Int
    var state: AntigravityProxyAccountState
    var cooldownEpoch: Int64?
    var lastError: String?
    var models: [String]
    /// Runtime observations only; the store never writes these into account records.
    var modelDetails: [AntigravityProxyModelDetail]? = nil
    var modelDetailsUpdatedAt: Int64? = nil
    var sharedWindows: [AntigravityProxyQuotaWindow]? = nil
    var quotaIssue: String? = nil

    var cooldownUntil: Date? { cooldownEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var modelDetailsObservedAt: Date? { modelDetailsUpdatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    var withoutRuntimeQuota: Self {
        var row = self
        row.modelDetails = nil
        row.modelDetailsUpdatedAt = nil
        row.sharedWindows = nil
        row.quotaIssue = nil
        return row
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, maskedIdentity, generation, enabled, concurrencyLimit, inFlight, state, lastError, models
        case modelDetails, modelDetailsUpdatedAt, sharedWindows, quotaIssue
        case cooldownEpoch = "cooldownUntil"
    }

    var hasValidIdentity: Bool {
        id.range(of: "^\(provider.accountPrefix)-[a-f0-9]{32}$", options: .regularExpression) != nil
            && generation.range(of: "^[A-Za-z0-9_-]{20,128}$", options: .regularExpression) != nil
            && maskedIdentity.utf8.count <= 160 && maskedIdentity.contains("***")
            && (1...8).contains(concurrencyLimit) && (0...8).contains(inFlight)
            && models.count <= 512
            && models.allSatisfy(AntigravityProxyModelDetail.validModelID)
            && (modelDetails.map { $0.count <= 512 && Set($0.map(\.id)).count == $0.count && $0.allSatisfy(\.isValid) } ?? true)
            && (modelDetailsUpdatedAt.map(AntigravityProxyModelDetail.validEpoch) ?? true)
            && (sharedWindows.map { $0.count <= 256 && Set($0.map(\.id)).count == $0.count && $0.allSatisfy(\.isValid) } ?? true)
            && (quotaIssue == nil || quotaIssue == "summary_unavailable")
    }
}

/// This value is only encoded into the child stdin or the app's Keychain item.
/// It must never be rendered or passed to diagnostics.
struct AntigravityProxyCredential: Codable, Equatable, Sendable {
    var provider: AntigravityProxyProvider = .antigravity
    let accountID: String
    let generation: String
    let maskedIdentity: String
    let accessToken: String
    let refreshToken: String
    let projectID: String
    let expiresAt: Int64
    var idToken: String? = nil
    var deviceID: String? = nil
    var accountSubject: String? = nil
    var organizationID: String? = nil
    var refreshExpiresAt: Int64? = nil

    var account: AntigravityProxyAccount {
        AntigravityProxyAccount(
            id: accountID, provider: provider, maskedIdentity: maskedIdentity, generation: generation,
            enabled: true, concurrencyLimit: 1, inFlight: 0, state: .checking, models: [])
    }

    var isValid: Bool {
        account.hasValidIdentity && !accessToken.isEmpty && accessToken.utf8.count <= 16_384
            && !refreshToken.isEmpty && refreshToken.utf8.count <= 16_384
            && (provider != .antigravity || !projectID.isEmpty) && projectID.utf8.count <= 1_024 && expiresAt > 0
            && (idToken?.utf8.count ?? 0) <= 16_384
            && [deviceID, accountSubject, organizationID].allSatisfy { ($0?.utf8.count ?? 0) <= 1_024 }
    }

    var fingerprint: String {
        let fields = [
            provider.rawValue, accountID, generation, maskedIdentity, accessToken, refreshToken,
            projectID, String(expiresAt), idToken ?? "", deviceID ?? "", accountSubject ?? "",
            organizationID ?? "", String(refreshExpiresAt ?? 0),
        ]
        var data = Data("aigoodbro-proxy-credential-v1\0".utf8)
        for field in fields { data.append(Data("\(field.utf8.count):\(field)".utf8)) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Stored in a separate generation-bound Keychain item. Older app versions
/// continue to read only the previously verified active item.
struct AntigravityProxyPendingRefresh: Codable, Equatable, Sendable {
    let baseFingerprint: String
    let credential: AntigravityProxyCredential

    func isValid(for active: AntigravityProxyCredential) -> Bool {
        let value = credential
        guard value.isValid, value.provider == .xai, value.provider == active.provider,
            value.accountID == active.accountID, value.generation == active.generation,
            value.maskedIdentity == active.maskedIdentity,
            let subject = value.accountSubject, !subject.isEmpty, subject == active.accountSubject,
            value.projectID == active.projectID, (value.deviceID ?? "") == (active.deviceID ?? ""),
            (value.organizationID ?? "") == (active.organizationID ?? ""), (value.refreshExpiresAt ?? 0) == (active.refreshExpiresAt ?? 0),
            baseFingerprint == active.fingerprint
        else { return false }
        let digest = SHA256.hash(data: Data("xai\0\(subject)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return value.accountID == "xai-" + digest
    }
}

struct AntigravityProxyEvent: Decodable, Sendable {
    let event: String
    let provider: AntigravityProxyProvider?
    let providers: [AntigravityProxyProvider]?
    let providerModels: [String: [String]]?
    let userCode: String?
    let requestID: String?
    let sessionID: String?
    let accountID: String?
    let generation: String?
    let port: Int?
    let url: String?
    let code: String?
    let purpose: String?
    let accounts: [AntigravityProxyAccount]?
    let models: [String]?
    let credential: AntigravityProxyCredential?
    let expectedCredentialFingerprint: String?
}
