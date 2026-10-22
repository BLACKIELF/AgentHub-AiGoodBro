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

    var cooldownUntil: Date? { cooldownEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    enum CodingKeys: String, CodingKey {
        case id, provider, maskedIdentity, generation, enabled, concurrencyLimit, inFlight, state, lastError, models
        case cooldownEpoch = "cooldownUntil"
    }

    var hasValidIdentity: Bool {
        id.range(of: "^\(provider.accountPrefix)-[a-f0-9]{32}$", options: .regularExpression) != nil
            && generation.range(of: "^[A-Za-z0-9_-]{20,128}$", options: .regularExpression) != nil
            && maskedIdentity.utf8.count <= 160 && maskedIdentity.contains("***")
            && (1...8).contains(concurrencyLimit) && (0...8).contains(inFlight)
            && models.count <= 512
            && models.allSatisfy { $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil }
    }
}

/// This value is only encoded into the child stdin or the app's Keychain item.
/// It must never be rendered or passed to diagnostics.
struct AntigravityProxyCredential: Codable, Sendable {
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
}
