import Foundation

/// The providers for which the account-add flow has an official login seam.
///
/// `LocalCLIKind` intentionally does not contain Codex (Codex profiles use a
/// separate app-server store), so the login workflow has its own small target
/// type. A parent coordinator can construct a target from either store.
enum LocalCLILoginProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case grok
    case openCode
    case workBuddy
    case zcode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .grok: "Grok"
        case .openCode: "OpenCode"
        case .workBuddy: "WorkBuddy"
        case .zcode: "ZCode"
        }
    }
}

/// A provider-specific account target. `configDirectory` is only a routing
/// hint for an injected adapter; the workflow never reads it.
struct LocalCLILoginTarget: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let provider: LocalCLILoginProvider
    let displayName: String
    let configDirectory: String?

    init(
        id: String,
        provider: LocalCLILoginProvider,
        displayName: String = "",
        configDirectory: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.configDirectory = configDirectory
    }

    static func provider(for kind: LocalCLIKind) -> LocalCLILoginProvider? {
        switch kind {
        case .grok: .grok
        case .openCode: .openCode
        case .workBuddy: .workBuddy
        case .zcode: .zcode
        case .claudeCode, .trae, .kimi, .mimo, .gemini, .antigravity: nil
        }
    }
}

enum LocalCLIEvidenceSupport: String, Codable, Equatable, Sendable {
    case verified
    case unverified
    case unsupported
}

enum LocalCLILoginMethod: String, Codable, Equatable, Sendable {
    case codexAppServerAccountLogin
    case grokCLIWebOAuth
    case openCodeProviderAuth
    case workBuddyBundledCLI
    case zcodeDesktop
    case unsupported
}

/// Reviewable metadata for a provider's official entry points and evidence.
/// It is deliberately descriptive: the injected capability remains the only
/// code allowed to inspect a local installation or start an official flow.
struct LocalCLILoginCapabilityDescriptor: Codable, Equatable, Sendable {
    let provider: LocalCLILoginProvider
    let loginMethod: LocalCLILoginMethod
    let authorization: LocalCLIEvidenceSupport
    let identity: LocalCLIEvidenceSupport
    let quota: LocalCLIEvidenceSupport
    let models: LocalCLIEvidenceSupport
    let authorizationSource: String
    let identitySource: String
    let quotaSource: String
    let modelSource: String
    let supportsFallbackAssociation: Bool
    let notes: String

    var supportsAuthorization: Bool { authorization == .verified }
    var hasVerifiedIdentity: Bool { identity == .verified }
    var hasVerifiedQuota: Bool { quota == .verified }
    var hasVerifiedModels: Bool { models == .verified }

    static func official(for provider: LocalCLILoginProvider) -> Self {
        switch provider {
        case .codex:
            Self(
                provider: .codex,
                loginMethod: .codexAppServerAccountLogin,
                authorization: .verified,
                identity: .verified,
                quota: .verified,
                models: .unverified,
                authorizationSource: "app-server account/login/start and account/login/cancel",
                identitySource: "CodexOfficialProfileReader",
                quotaSource: "CodexUsageReader",
                modelSource: "no general per-model verifier is wired; use an injected minimal CLI verifier",
                supportsFallbackAssociation: false,
                notes: "A login completion or process exit is only a trigger for identity verification.")
        case .grok:
            Self(
                provider: .grok,
                loginMethod: .grokCLIWebOAuth,
                authorization: .verified,
                identity: .verified,
                quota: .verified,
                models: .unverified,
                authorizationSource: "grok login --oauth",
                identitySource: "LocalCLIQuotaReader official billing identity",
                quotaSource: "LocalCLIQuotaReader official billing endpoint",
                modelSource: "injected official CLI model probe",
                supportsFallbackAssociation: true,
                notes: "The billing response, not a free or plan label, is the quota evidence.")
        case .openCode:
            Self(
                provider: .openCode,
                loginMethod: .openCodeProviderAuth,
                authorization: .verified,
                identity: .unverified,
                quota: .verified,
                models: .unverified,
                authorizationSource: "opencode auth login",
                identitySource: "provider auth state exists, but no stable identity adapter is wired",
                quotaSource: "opencode-go usage evidence",
                modelSource: "injected provider/model probe",
                supportsFallbackAssociation: true,
                notes: "Provider auth confirms login; only opencode-go usage confirms quota.")
        case .workBuddy:
            Self(
                provider: .workBuddy,
                loginMethod: .workBuddyBundledCLI,
                authorization: .verified,
                identity: .unsupported,
                quota: .unsupported,
                models: .unsupported,
                authorizationSource: "official WorkBuddy app bundle CLI; user enters /login",
                identitySource: "no verified adapter",
                quotaSource: "no verified adapter",
                modelSource: "no verified adapter",
                supportsFallbackAssociation: true,
                notes: "Opening the bundled CLI can request login, but cannot establish ready state by itself.")
        case .zcode:
            Self(
                provider: .zcode,
                loginMethod: .zcodeDesktop,
                authorization: .verified,
                identity: .unsupported,
                quota: .unverified,
                models: .unverified,
                authorizationSource: "official ZCode desktop application",
                identitySource: "no verified native OAuth identity adapter",
                quotaSource: "Coding Plan configuration is not native OAuth identity evidence",
                modelSource: "no verified per-model adapter",
                supportsFallbackAssociation: true,
                notes: "Open the default desktop app for sign-in; opening it does not prove account or model readiness.")
        }
    }
}

enum LocalCLILoginWorkflowState: String, Codable, Equatable, Sendable {
    case detecting
    case needsAuthorization
    case waitingForReturn
    case verifyingIdentity
    case quotaPending
    case modelsPending
    case ready
    case cancelled
    case failed
}

typealias LocalCLILoginState = LocalCLILoginWorkflowState

struct LocalCLILoginIdentity: Codable, Equatable, Sendable {
    /// A stable, non-secret identity digest supplied by an injected reader.
    /// Raw account identifiers must never be passed to this workflow.
    let fingerprint: String
    let maskedLabel: String?

    init(fingerprint: String, maskedLabel: String? = nil) {
        self.fingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maskedLabel = maskedLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isUsable: Bool {
        fingerprint.utf8.count == 64
            && fingerprint.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

enum LocalCLILoginIdentityEvidence: Equatable, Sendable {
    case verified(LocalCLILoginIdentity)
    case missing
    case unverified
    case unsupported
}

typealias LocalCLILoginIdentityResult = LocalCLILoginIdentityEvidence

struct LocalCLILoginDetectionEvidence: Equatable, Sendable {
    let installed: Bool
    let source: String

    init(installed: Bool, source: String = "injected installation detector") {
        self.installed = installed
        self.source = source
    }
}

struct LocalCLILoginLaunchReceipt: Equatable, Sendable {
    let id: UUID
    let source: String

    init(id: UUID = UUID(), source: String = "injected official launcher") {
        self.id = id
        self.source = source
    }
}

enum LocalCLILoginQuotaEvidenceStatus: String, Codable, Equatable, Sendable {
    case verified
    case unavailable
    case unverified
    case unsupported
}

struct LocalCLILoginQuotaEvidence: Codable, Equatable, Sendable {
    let status: LocalCLILoginQuotaEvidenceStatus
    let identityFingerprint: String?
    let source: String

    init(
        status: LocalCLILoginQuotaEvidenceStatus,
        identityFingerprint: String? = nil,
        source: String = "injected quota reader"
    ) {
        self.status = status
        self.identityFingerprint = identityFingerprint
        self.source = source
    }
}

enum LocalCLILoginModelEvidenceStatus: String, Codable, Equatable, Sendable {
    case verified
    case unavailable
    case unverified
    case unsupported
}

struct LocalCLILoginModelEvidence: Codable, Equatable, Sendable {
    let model: String
    let status: LocalCLILoginModelEvidenceStatus
    let identityFingerprint: String?
    let source: String

    init(
        model: String,
        status: LocalCLILoginModelEvidenceStatus,
        identityFingerprint: String? = nil,
        source: String = "injected model verifier"
    ) {
        self.model = model
        self.status = status
        self.identityFingerprint = identityFingerprint
        self.source = source
    }
}

enum LocalCLILoginFailureReason: String, Codable, Equatable, Sendable {
    case unsupported
    case notInstalled
    case authorizationFailed
    case identityMissing
    case identityUnverified
    case identityMismatch
    case quotaUnavailable
    case quotaUnverified
    case quotaUnsupported
    case modelUnavailable
    case modelUnverified
    case modelUnsupported
    case modelMismatch
    case invalidTarget
    case cancelled
}

struct LocalCLILoginFailure: Codable, Equatable, Sendable {
    let reason: LocalCLILoginFailureReason
    let model: String?

    init(reason: LocalCLILoginFailureReason, model: String? = nil) {
        self.reason = reason
        self.model = model
    }
}

struct LocalCLILoginStatus: Equatable, Sendable {
    var state: LocalCLILoginWorkflowState
    var attemptID: UUID?
    var targetID: String?
    var provider: LocalCLILoginProvider?
    var authorizationReceiptID: UUID?
    var identityFingerprint: String?
    var maskedIdentity: String?
    var quota: LocalCLILoginQuotaEvidence?
    var verifiedModels: [String: LocalCLILoginModelEvidence]
    var failure: LocalCLILoginFailure?

    static let empty = Self(
        state: .detecting,
        attemptID: nil,
        targetID: nil,
        provider: nil,
        authorizationReceiptID: nil,
        identityFingerprint: nil,
        maskedIdentity: nil,
        quota: nil,
        verifiedModels: [:],
        failure: nil)
}

/// Pure state machine used by the coordinator and by offline fixtures.
struct LocalCLILoginWorkflow: Equatable, Sendable {
    let target: LocalCLILoginTarget
    let attemptID: UUID
    let expectedIdentityFingerprint: String?
    let targetModels: [String]
    private(set) var status: LocalCLILoginStatus

    init(
        target: LocalCLILoginTarget,
        attemptID: UUID = UUID(),
        expectedIdentity: LocalCLILoginIdentity? = nil,
        targetModels: [String] = []
    ) {
        self.target = target
        self.attemptID = attemptID
        self.expectedIdentityFingerprint = expectedIdentity?.fingerprint
        var uniqueModels: [String] = []
        for model in targetModels {
            let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !uniqueModels.contains(value) { uniqueModels.append(value) }
        }
        self.targetModels = uniqueModels
        self.status = LocalCLILoginStatus(
            state: .detecting,
            attemptID: attemptID,
            targetID: target.id,
            provider: target.provider,
            authorizationReceiptID: nil,
            identityFingerprint: nil,
            maskedIdentity: nil,
            quota: nil,
            verifiedModels: [:],
            failure: nil)
    }

    var isTerminal: Bool {
        switch status.state {
        case .ready, .cancelled, .failed: true
        default: false
        }
    }

    var allTargetModelsVerified: Bool {
        targetModels.allSatisfy { status.verifiedModels[$0]?.status == .verified }
    }

    func accepts(_ identity: LocalCLILoginIdentity) -> Bool {
        guard identity.isUsable else { return false }
        guard let expectedIdentityFingerprint else { return true }
        return expectedIdentityFingerprint == identity.fingerprint
    }

    @discardableResult
    mutating func markNeedsAuthorization() -> Bool {
        guard status.state == .detecting else { return false }
        status.state = .needsAuthorization
        return true
    }

    @discardableResult
    mutating func markWaitingForReturn(receipt: LocalCLILoginLaunchReceipt) -> Bool {
        guard status.state == .needsAuthorization else { return false }
        status.authorizationReceiptID = receipt.id
        status.state = .waitingForReturn
        return true
    }

    @discardableResult
    mutating func markVerifyingIdentity() -> Bool {
        guard status.state == .detecting || status.state == .waitingForReturn else { return false }
        status.state = .verifyingIdentity
        status.authorizationReceiptID = nil
        return true
    }

    @discardableResult
    mutating func recordIdentity(_ identity: LocalCLILoginIdentity) -> Bool {
        guard status.state == .verifyingIdentity, accepts(identity) else { return false }
        status.identityFingerprint = identity.fingerprint
        status.maskedIdentity = identity.maskedLabel
        return true
    }

    @discardableResult
    mutating func markQuotaPending() -> Bool {
        guard status.state == .verifyingIdentity, status.identityFingerprint != nil else { return false }
        status.state = .quotaPending
        return true
    }

    @discardableResult
    mutating func recordQuota(_ evidence: LocalCLILoginQuotaEvidence) -> Bool {
        guard status.state == .quotaPending else { return false }
        status.quota = evidence
        return true
    }

    @discardableResult
    mutating func markModelsPending() -> Bool {
        guard status.state == .quotaPending,
            status.quota?.status == .verified,
            status.identityFingerprint != nil
        else { return false }
        status.state = .modelsPending
        return true
    }

    @discardableResult
    mutating func recordModel(_ evidence: LocalCLILoginModelEvidence) -> Bool {
        guard status.state == .modelsPending,
            targetModels.contains(evidence.model),
            evidence.status == .verified
        else { return false }
        status.verifiedModels[evidence.model] = evidence
        return true
    }

    @discardableResult
    mutating func markReady() -> Bool {
        guard status.state == .modelsPending,
            status.quota?.status == .verified,
            !targetModels.isEmpty,
            allTargetModelsVerified
        else { return false }
        status.state = .ready
        return true
    }

    @discardableResult
    mutating func markCancelled() -> Bool {
        guard !isTerminal else { return false }
        status.state = .cancelled
        status.failure = LocalCLILoginFailure(reason: .cancelled)
        return true
    }

    @discardableResult
    mutating func markFailed(_ reason: LocalCLILoginFailureReason, model: String? = nil) -> Bool {
        guard !isTerminal else { return false }
        status.state = .failed
        status.failure = LocalCLILoginFailure(reason: reason, model: model)
        return true
    }
}

enum LocalCLILoginCapabilityError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupported
    case unavailable
    case failed

    var description: String {
        switch self {
        case .unsupported: "unsupported"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }
}

protocol LocalCLILoginCapability: Sendable {
    var descriptor: LocalCLILoginCapabilityDescriptor { get }

    func detect(target: LocalCLILoginTarget) async -> LocalCLILoginDetectionEvidence
    func discoverIdentity(target: LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence
    func startAuthorization(target: LocalCLILoginTarget) async throws -> LocalCLILoginLaunchReceipt
    func cancelAuthorization(target: LocalCLILoginTarget, receipt: LocalCLILoginLaunchReceipt) async
    func readQuota(target: LocalCLILoginTarget) async -> LocalCLILoginQuotaEvidence
    func verifyModel(target: LocalCLILoginTarget, model: String) async -> LocalCLILoginModelEvidence

    /// Optional fallback for an advanced, explicitly associated environment.
    /// The normal login path never invokes it automatically.
    func fallbackAssociation(target: LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence
}

extension LocalCLILoginCapability {
    func fallbackAssociation(target: LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence {
        .unsupported
    }
}

/// Closure-backed capability used by the parent wiring and offline fixtures.
struct LocalCLILoginCapabilityAdapter: LocalCLILoginCapability {
    let descriptor: LocalCLILoginCapabilityDescriptor
    private let detectBlock: @Sendable (LocalCLILoginTarget) async -> LocalCLILoginDetectionEvidence
    private let identityBlock: @Sendable (LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence
    private let startBlock: @Sendable (LocalCLILoginTarget) async throws -> LocalCLILoginLaunchReceipt
    private let cancelBlock: @Sendable (LocalCLILoginTarget, LocalCLILoginLaunchReceipt) async -> Void
    private let quotaBlock: @Sendable (LocalCLILoginTarget) async -> LocalCLILoginQuotaEvidence
    private let modelBlock: @Sendable (LocalCLILoginTarget, String) async -> LocalCLILoginModelEvidence
    private let fallbackBlock: @Sendable (LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence

    init(
        descriptor: LocalCLILoginCapabilityDescriptor,
        detect: @escaping @Sendable (LocalCLILoginTarget) async -> LocalCLILoginDetectionEvidence,
        discoverIdentity: @escaping @Sendable (LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence,
        startAuthorization: @escaping @Sendable (LocalCLILoginTarget) async throws -> LocalCLILoginLaunchReceipt,
        cancelAuthorization: @escaping @Sendable (LocalCLILoginTarget, LocalCLILoginLaunchReceipt) async -> Void = { _, _ in },
        readQuota: @escaping @Sendable (LocalCLILoginTarget) async -> LocalCLILoginQuotaEvidence,
        verifyModel: @escaping @Sendable (LocalCLILoginTarget, String) async -> LocalCLILoginModelEvidence,
        fallbackAssociation: @escaping @Sendable (LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence = { _ in .unsupported }
    ) {
        self.descriptor = descriptor
        self.detectBlock = detect
        self.identityBlock = discoverIdentity
        self.startBlock = startAuthorization
        self.cancelBlock = cancelAuthorization
        self.quotaBlock = readQuota
        self.modelBlock = verifyModel
        self.fallbackBlock = fallbackAssociation
    }

    func detect(target: LocalCLILoginTarget) async -> LocalCLILoginDetectionEvidence {
        await detectBlock(target)
    }

    func discoverIdentity(target: LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence {
        await identityBlock(target)
    }

    func startAuthorization(target: LocalCLILoginTarget) async throws -> LocalCLILoginLaunchReceipt {
        try await startBlock(target)
    }

    func cancelAuthorization(target: LocalCLILoginTarget, receipt: LocalCLILoginLaunchReceipt) async {
        await cancelBlock(target, receipt)
    }

    func readQuota(target: LocalCLILoginTarget) async -> LocalCLILoginQuotaEvidence {
        await quotaBlock(target)
    }

    func verifyModel(target: LocalCLILoginTarget, model: String) async -> LocalCLILoginModelEvidence {
        await modelBlock(target, model)
    }

    func fallbackAssociation(target: LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence {
        await fallbackBlock(target)
    }
}
