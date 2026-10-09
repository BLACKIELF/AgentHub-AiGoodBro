import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

/// Subscription credentials never enter profile JSON, logs, or the UI. Reads do
/// not renew a rotating refresh token. Only explicit capture/switch may mutate.
struct ClaudeSubscriptionService {
    enum Failure: String, Error { case invalid, unavailable, busy, identityChanged, expired, reauthenticationRequired, readOnly, rolledBack, rollbackFailed }
    struct Identity: Equatable {
        let uuid: String
        let organization: String
        let email: String?
        var fingerprint: String { Self.fingerprint(uuid: uuid, organization: organization) }
        static func fingerprint(uuid: String, organization: String) -> String {
            SHA256.hash(data: Data(("claude-subscription\0" + uuid + "\0" + organization).utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Snapshot {
        let credential: Data
        let identity: Identity
        let oauthAccount: [String: Any]
    }
    struct VerifiedCurrent {
        let fingerprint: String
        let credentialRevision: String
        let configDigest: String
        let configPath: String
    }
    struct Dependencies {
        var readKeychain: (String, String) throws -> Data? = ClaudeSubscriptionService.readKeychain
        var writeKeychain: (String, String, Data?) throws -> Void = ClaudeSubscriptionService.writeKeychain
        var idle: () throws -> Bool = ClaudeSubscriptionService.processesIdle
        var transport: any LocalCLIQuotaTransport = LocalCLIURLSessionTransport()
        var now: () -> Date = { Date() }
    }
    static let nativeService = "AiGoodBro.Next.ClaudeSubscriptions"
    let home: URL
    let support: URL
    var dependencies = Dependencies()
    private var defaultDirectory: URL { home.appendingPathComponent(".claude") }
    private var configURL: URL {
        let legacy = defaultDirectory.appendingPathComponent(".config.json")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : home.appendingPathComponent(".claude.json")
    }
    static var keychainAccount: String { ProcessInfo.processInfo.environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName() }
    static func directoryKeychainService(_ exportedDirectory: String) -> String {
        let digest = SHA256.hash(data: Data(exportedDirectory.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
        return value
    }
    static func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 32768,
            !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return text
    }
    static func oauth(_ data: Data, now: Date) throws -> [String: Any] {
        let value = try oauthAllowExpired(data)
        guard let expiry = value["expiresAt"] as? NSNumber,
            expiry.doubleValue > now.timeIntervalSince1970 * 1000
        else { throw Failure.expired }
        return value
    }
    private static func oauthAllowExpired(_ data: Data) throws -> [String: Any] {
        guard let value = try object(data)["claudeAiOauth"] as? [String: Any], text(value["accessToken"]) != nil,
            let expiry = value["expiresAt"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
            expiry.doubleValue.isFinite
        else { throw Failure.invalid }
        return value
    }
    private func read(_ url: URL, missing: Bool = false) throws -> Data? {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.invalid }
        return try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: 1_048_576, allowMissing: missing)
    }
    private func requireIdle() throws { guard try dependencies.idle() else { throw Failure.busy } }
    private func rejectAPIRoute() throws {
        if let data = try read(defaultDirectory.appendingPathComponent("settings.json"), missing: true) {
            let env = try Self.object(data)["env"] as? [String: Any] ?? [:]
            guard
                ![
                    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                    "CLAUDE_CODE_USE_MANTLE",
                ].contains(where: { Self.text(env[$0]) != nil })
            else { throw Failure.readOnly }
        }
    }
    private func liveCredential() throws -> Data {
        // macOS Claude renews Keychain first; a stale file must never win.
        if let data = try dependencies.readKeychain("Claude Code-credentials", Self.keychainAccount) { return data }
        guard let data = try read(defaultDirectory.appendingPathComponent(".credentials.json"), missing: true) else { throw Failure.unavailable }
        return data
    }
    func officialIdentity(_ credential: Data) async throws -> Identity {
        let oauth = try Self.oauth(credential, now: dependencies.now())
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.timeoutInterval = 15
        request.setValue("Bearer " + Self.text(oauth["accessToken"])!, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await dependencies.transport.response(for: request)
        guard response.statusCode == 200 else { throw Failure.unavailable }
        let root = try Self.object(response.data)
        guard let account = root["account"] as? [String: Any], let uuid = Self.text(account["uuid"]), uuid.utf8.count <= 128 else { throw Failure.invalid }
        let organization = (root["organization"] as? [String: Any]).flatMap { Self.text($0["uuid"]) } ?? ""
        guard organization.utf8.count <= 128 else { throw Failure.invalid }
        return Identity(uuid: uuid, organization: organization, email: LocalCLIQuotaPresentation.validIdentity(account["email"] as? String))
    }
    private func storedIdentity(_ account: [String: Any]) throws -> Identity {
        guard let uuid = Self.text(account["accountUuid"]), uuid.utf8.count <= 128 else { throw Failure.invalid }
        return Identity(uuid: uuid, organization: Self.text(account["organizationUuid"]) ?? "", email: LocalCLIQuotaPresentation.validIdentity(account["emailAddress"] as? String))
    }
    func verifyCurrent(expectedFingerprint: String? = nil) async throws -> VerifiedCurrent {
        try Task.checkCancellation()
        try rejectAPIRoute()
        let config = configURL.standardizedFileURL
        let configPath = config.path
        guard let configBytes = try read(config), let account = try Self.object(configBytes)["oauthAccount"] as? [String: Any] else { throw Failure.invalid }
        let declared = try storedIdentity(account)
        let live = try liveCredential()
        let official = try await officialIdentity(live)
        try Task.checkCancellation()
        guard official.fingerprint == declared.fingerprint,
            expectedFingerprint.map({ $0 == official.fingerprint }) ?? true
        else { throw Failure.identityChanged }
        try rejectAPIRoute()
        guard configURL.standardizedFileURL.path == configPath,
            try read(config) == configBytes, try liveCredential() == live
        else { throw Failure.identityChanged }
        _ = try Self.oauth(live, now: dependencies.now())
        return VerifiedCurrent(
            fingerprint: official.fingerprint, credentialRevision: Self.digest(live),
            configDigest: Self.digest(configBytes), configPath: configPath)
    }
    func isCurrent(_ observation: VerifiedCurrent) throws -> Bool {
        try rejectAPIRoute()
        let config = configURL.standardizedFileURL
        guard config.path == observation.configPath, let configBytes = try read(config, missing: true),
            Self.digest(configBytes) == observation.configDigest,
            let account = try Self.object(configBytes)["oauthAccount"] as? [String: Any],
            try storedIdentity(account).fingerprint == observation.fingerprint
        else { return false }
        let live = try liveCredential()
        guard Self.digest(live) == observation.credentialRevision else { return false }
        do { _ = try Self.oauth(live, now: dependencies.now()) } catch Failure.expired { return false }
        try rejectAPIRoute()
        guard configURL.standardizedFileURL.path == observation.configPath,
            try read(config) == configBytes, try liveCredential() == live
        else { return false }
        return true
    }
    func candidates() throws -> [ClaudeSubscriptionCandidate] {
        guard let data = try read(home.appendingPathComponent(".claude-swap-backup/sequence.json"), missing: true) else { return [] }
        let root = try Self.object(data)
        guard let accounts = root["accounts"] as? [String: Any], accounts.count <= 64 else { throw Failure.invalid }
        return accounts.keys.sorted().compactMap { slot in
            guard let n = Int(slot), (1...10000).contains(n), String(n) == slot,
                let record = accounts[slot] as? [String: Any], let uuid = Self.text(record["uuid"]),
                let email = LocalCLIQuotaPresentation.validIdentity(record["email"] as? String), safeEmail(email)
            else { return nil }
            let organization = record["organizationUuid"] as? String ?? ""
            let identity = Identity(uuid: uuid, organization: organization, email: email)
            return ClaudeSubscriptionCandidate(
                id: slot, label: "Claude " + slot,
                maskedIdentity: LocalCLIQuotaPresentation.maskedIdentity(email), planLabel: nil,
                sourceLabel: "claude-swap", canImport: identity.fingerprint.count == 64)
        }
    }
    private func safeEmail(_ email: String) -> Bool { !email.contains("/") && !email.contains("\\") && !email.contains("..") && email.utf8.count <= 254 }
    func reference(candidateID: String) throws -> ClaudeSubscriptionReference {
        let (_, identity) = try cswapCredential(slot: candidateID)
        return ClaudeSubscriptionReference(source: .cswap, slot: candidateID, identityFingerprint: identity.fingerprint)
    }
    private enum SlotLocation {
        case keychain(String, String)
        case encodedFile(URL)
    }
    private struct StoredSlot {
        let location: SlotLocation
        let bytes: Data
        let snapshot: Snapshot
    }
    private func storedSlot(_ reference: ClaudeSubscriptionReference) throws -> StoredSlot {
        if reference.source == .native {
            guard UUID(uuidString: reference.slot) != nil,
                let data = try dependencies.readKeychain(Self.nativeService, reference.slot),
                let root = try Self.object(data)["credential"] as? [String: Any],
                let account = try Self.object(data)["oauthAccount"] as? [String: Any]
            else { throw Failure.unavailable }
            let identity = try storedIdentity(account)
            guard identity.fingerprint == reference.identityFingerprint else { throw Failure.identityChanged }
            return StoredSlot(
                location: .keychain(Self.nativeService, reference.slot), bytes: data,
                snapshot: Snapshot(credential: try Self.bytes(root), identity: identity, oauthAccount: account))
        }
        let slot = reference.slot
        guard let n = Int(slot), String(n) == slot, (1...10000).contains(n),
            let sequence = try read(home.appendingPathComponent(".claude-swap-backup/sequence.json")),
            let accounts = try Self.object(sequence)["accounts"] as? [String: Any], let record = accounts[slot] as? [String: Any],
            let uuid = Self.text(record["uuid"]), let email = LocalCLIQuotaPresentation.validIdentity(record["email"] as? String), safeEmail(email)
        else { throw Failure.invalid }
        let identity = Identity(uuid: uuid, organization: record["organizationUuid"] as? String ?? "", email: email)
        guard identity.fingerprint == reference.identityFingerprint else { throw Failure.identityChanged }
        let root = home.appendingPathComponent(".claude-swap-backup")
        let slug = email.precomposedStringWithCanonicalMapping.map { character -> String in
            character.unicodeScalars.count == 1 && character.unicodeScalars.first!.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
                ? String(character) : "_"
        }.joined()
        // A session or stashed successor may own the sole newer refresh grant.
        // Basic switching refuses this unresolved lineage instead of copying it.
        var metadata = stat()
        let session = root.appendingPathComponent("sessions/" + slot + "-" + slug)
        if lstat(session.path, &metadata) == 0 { throw Failure.busy }
        guard errno == ENOENT else { throw Failure.unavailable }
        for path in ["credentials/.unclaimed-manifest.json", ".unclaimed-manifest.json"] {
            if let manifest = try read(root.appendingPathComponent(path), missing: true), !manifest.isEmpty { throw Failure.busy }
        }
        let configFile = home.appendingPathComponent(".claude-swap-backup/configs/.claude-config-\(slot)-\(email).json")
        guard let config = try read(configFile), let account = try Self.object(config)["oauthAccount"] as? [String: Any],
            try storedIdentity(account).fingerprint == identity.fingerprint
        else { throw Failure.identityChanged }
        let file = home.appendingPathComponent(".claude-swap-backup/credentials/.creds-\(slot)-\(email).enc")
        if let encoded = try read(file, missing: true) {
            guard let text = String(data: encoded, encoding: .utf8), let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw Failure.invalid
            }
            return StoredSlot(location: .encodedFile(file), bytes: encoded, snapshot: Snapshot(credential: bytes, identity: identity, oauthAccount: account))
        }
        let keychainAccount = "account-\(slot)-\(email)"
        guard let credential = try dependencies.readKeychain("claude-swap", keychainAccount) else { throw Failure.unavailable }
        return StoredSlot(
            location: .keychain("claude-swap", keychainAccount), bytes: credential, snapshot: Snapshot(credential: credential, identity: identity, oauthAccount: account))
    }
    private func cswapCredential(slot: String) throws -> (Data, Identity) {
        guard let data = try read(home.appendingPathComponent(".claude-swap-backup/sequence.json")),
            let record = (try Self.object(data)["accounts"] as? [String: Any])?[slot] as? [String: Any],
            let uuid = Self.text(record["uuid"])
        else { throw Failure.invalid }
        let fingerprint = Identity.fingerprint(uuid: uuid, organization: record["organizationUuid"] as? String ?? "")
        let snapshot = try storedSlot(ClaudeSubscriptionReference(source: .cswap, slot: slot, identityFingerprint: fingerprint)).snapshot
        return (snapshot.credential, snapshot.identity)
    }
    private func cswapRevisions(_ references: [ClaudeSubscriptionReference]) throws -> [String: Data] {
        let references = references.filter { $0.source == .cswap }
        if references.isEmpty { return [:] }
        let root = home.appendingPathComponent(".claude-swap-backup")
        guard let sequence = try read(root.appendingPathComponent("sequence.json")) else { throw Failure.unavailable }
        var result = ["sequence": sequence]
        let accounts = try Self.object(sequence)["accounts"] as? [String: Any] ?? [:]
        for reference in references {
            guard let record = accounts[reference.slot] as? [String: Any], let email = Self.text(record["email"]), safeEmail(email),
                let config = try read(root.appendingPathComponent("configs/.claude-config-" + reference.slot + "-" + email + ".json"))
            else { throw Failure.invalid }
            result[reference.slot] = config
        }
        return result
    }
    private func readStorage(_ location: SlotLocation) throws -> Data? {
        switch location {
        case .keychain(let service, let account): return try dependencies.readKeychain(service, account)
        case .encodedFile(let url): return try read(url, missing: true)
        }
    }
    private func writeStorage(_ location: SlotLocation, expected: Data, updated: Data) throws {
        guard try readStorage(location) == expected else { throw Failure.identityChanged }
        switch location {
        case .keychain(let service, let account): try dependencies.writeKeychain(service, account, updated)
        case .encodedFile(let url): try replaceEncodedCredential(url, expected: expected, updated: updated)
        }
    }
    private func replaceEncodedCredential(_ url: URL, expected: Data, updated: Data) throws {
        guard updated.count <= 1_048_576, try read(url) == expected else { throw Failure.identityChanged }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".aigoodbro-credential-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        var removeTemporary = true
        defer {
            close(fd)
            if removeTemporary { _ = unlink(temporary.path) }
        }
        try updated.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure.unavailable }
                offset += written
            }
        }
        guard fsync(fd) == 0, try read(temporary) == updated, try read(url) == expected else { throw Failure.identityChanged }
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP)) == 0 else { throw Failure.unavailable }
        removeTemporary = false
        let displaced = try read(temporary)
        if displaced == expected {
            removeTemporary = true
            return
        }
        // A writer slipped past the final comparison: swap its bytes back only
        // while our exact payload is still the target. Retain recovery otherwise.
        guard try read(url) == updated, renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP)) == 0,
            try read(temporary) == updated
        else { throw Failure.rollbackFailed }
        removeTemporary = true
        throw Failure.identityChanged
    }
    func credential(_ reference: ClaudeSubscriptionReference) throws -> Snapshot {
        let stored = try storedSlot(reference).snapshot
        if try activeFingerprint() == reference.identityFingerprint {
            return Snapshot(credential: try liveCredential(), identity: stored.identity, oauthAccount: stored.oauthAccount)
        }
        return stored
    }
    func loadQuota(_ reference: ClaudeSubscriptionReference, now: Date) async -> LocalCLIQuotaResult {
        func result(_ state: LocalCLIQuotaState, _ code: String?, identity: Identity? = nil, plan: String? = nil, windows: [LocalCLIQuotaWindow] = []) -> LocalCLIQuotaResult {
            LocalCLIQuotaResult(
                state: state, fetchedAt: now, maskedIdentity: identity?.email.map(LocalCLIQuotaPresentation.maskedIdentity), identityFingerprint: identity?.fingerprint,
                planLabel: plan, windows: windows, balance: nil, balanceCurrency: nil, sourceLabel: "Anthropic OAuth usage", messageCode: code)
        }
        do {
            let before = try credential(reference)
            let beforeActive = try activeFingerprint()
            let identity = try await officialIdentity(before.credential)
            guard identity.fingerprint == reference.identityFingerprint else { throw Failure.identityChanged }
            let oauth = try Self.oauth(before.credential, now: now)
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.timeoutInterval = 15
            request.setValue("Bearer " + Self.text(oauth["accessToken"])!, forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let response = try await dependencies.transport.response(for: request)
            guard try credential(reference).credential == before.credential, try activeFingerprint() == beforeActive else { throw Failure.identityChanged }
            guard response.statusCode == 200 else {
                return result(response.statusCode == 429 ? .rateLimited : .unavailable, response.statusCode == 429 ? "local_cli_rate_limited" : "local_cli_unavailable")
            }
            let windows = try LocalCLIQuotaReader.parseClaude(response.data)
            guard LocalCLIQuotaPresentation.validWindows(windows) else { throw Failure.invalid }
            return result(
                .available, nil, identity: identity,
                plan: LocalCLIQuotaPresentation.boundedLabel(oauth["subscriptionType"] as? String) ?? LocalCLIQuotaPresentation.boundedLabel(oauth["rateLimitTier"] as? String),
                windows: windows)
        } catch Failure.identityChanged { return result(.unavailable, "local_cli_claude_credentials_changed") } catch Failure.expired {
            return result(.unavailable, "local_cli_credentials_expired")
        } catch { return result(.unavailable, "local_cli_unavailable") }
    }
    func capture(slot: String, replacing expectedReference: ClaudeSubscriptionReference? = nil) async throws -> ClaudeSubscriptionReference {
        guard UUID(uuidString: slot) != nil else { throw Failure.invalid }
        try requireIdle()
        try rejectAPIRoute()
        let previousSlot = try dependencies.readKeychain(Self.nativeService, slot)
        if let expectedReference {
            guard expectedReference.source == .native, expectedReference.slot == slot else { throw Failure.invalid }
        } else if previousSlot != nil {
            throw Failure.identityChanged
        }
        let recoveryAccount = expectedReference.map(renewalAccount)
        let previousRecovery = try recoveryAccount.flatMap { try dependencies.readKeychain(Self.nativeService, $0) }
        let before = try liveCredential()
        guard let config = try read(configURL), let account = try Self.object(config)["oauthAccount"] as? [String: Any] else { throw Failure.invalid }
        let declared = try storedIdentity(account)
        let official = try await officialIdentity(before)
        guard declared.fingerprint == official.fingerprint, expectedReference.map({ $0.identityFingerprint == official.fingerprint }) ?? true else { throw Failure.identityChanged }
        try requireIdle()
        try rejectAPIRoute()
        guard try liveCredential() == before, try read(configURL) == config,
            try dependencies.readKeychain(Self.nativeService, slot) == previousSlot
        else { throw Failure.identityChanged }
        let locks = try MutationLocks(directory: defaultDirectory, config: configURL, support: support)
        defer { locks.release() }
        try locks.verify()
        guard try liveCredential() == before, try read(configURL) == config,
            try dependencies.readKeychain(Self.nativeService, slot) == previousSlot
        else { throw Failure.identityChanged }
        if let recoveryAccount {
            guard try dependencies.readKeychain(Self.nativeService, recoveryAccount) == previousRecovery else { throw Failure.identityChanged }
        }
        if let previousRecovery {
            let record = try Self.object(previousRecovery)
            guard Self.text(record["identityFingerprint"]) == official.fingerprint,
                let pendingDigest = Self.text(record["pendingDigest"]), pendingDigest.count == 64
            else { throw Failure.identityChanged }
            let oauth = try Self.oauth(before, now: dependencies.now())
            let successor = record["credential"] as? [String: Any]
            let successorOAuth = successor?["claudeAiOauth"] as? [String: Any]
            let exactSuccessor: Bool
            if let successor, Self.text(record["successorDigest"])?.count == 64 {
                exactSuccessor = try Self.bytes(successor) == Self.bytes(Self.object(before))
            } else {
                exactSuccessor = false
            }
            let independentGrant =
                Self.text(oauth["refreshToken"]).map {
                    Self.digest(Data($0.utf8)) != pendingDigest && $0 != Self.text(successorOAuth?["refreshToken"])
                } ?? false
            // Access-token identity alone does not prove that a refresh grant
            // changed. Refuse an old/uncertain grant before replacing the slot.
            guard exactSuccessor || independentGrant else { throw Failure.reauthenticationRequired }
        }
        let payload = try Self.bytes(["credential": Self.object(before), "oauthAccount": account])
        do {
            try dependencies.writeKeychain(Self.nativeService, slot, payload)
            guard try dependencies.readKeychain(Self.nativeService, slot) == payload else { throw Failure.unavailable }
        } catch {
            let current = try dependencies.readKeychain(Self.nativeService, slot)
            if current == payload { try dependencies.writeKeychain(Self.nativeService, slot, previousSlot) } else if current != previousSlot { throw Failure.rollbackFailed }
            throw Failure.rolledBack
        }
        let reference = ClaudeSubscriptionReference(source: .native, slot: slot, identityFingerprint: official.fingerprint)
        if let recoveryAccount {
            guard try dependencies.readKeychain(Self.nativeService, recoveryAccount) == previousRecovery else { throw Failure.identityChanged }
            if previousRecovery != nil {
                try dependencies.writeKeychain(Self.nativeService, recoveryAccount, nil)
                guard try dependencies.readKeychain(Self.nativeService, recoveryAccount) == nil else { throw Failure.unavailable }
            }
        }
        return reference
    }
    func removeCaptured(_ reference: ClaudeSubscriptionReference) throws {
        guard reference.source == .native else { return }
        try dependencies.writeKeychain(Self.nativeService, reference.slot, nil)
    }
    func activeFingerprint() throws -> String? {
        guard let config = try read(configURL, missing: true), let account = try Self.object(config)["oauthAccount"] as? [String: Any] else { return nil }
        return try storedIdentity(account).fingerprint
    }

    private func renewalAccount(_ reference: ClaudeSubscriptionReference) -> String {
        let identity = reference.source.rawValue + "\0" + reference.slot + "\0" + reference.identityFingerprint
        return "renewal-" + Self.digest(Data(identity.utf8))
    }

    private func slotPayload(_ reference: ClaudeSubscriptionReference, stored: StoredSlot, credential: Data) throws -> Data {
        if reference.source == .native {
            var root = try Self.object(stored.bytes)
            root["credential"] = try Self.object(credential)
            return try Self.bytes(root)
        }
        if case .encodedFile = stored.location { return Data(credential.base64EncodedString().utf8) }
        return credential
    }

    private func writeRenewalRecord(_ account: String, expected: Data?, updated: Data) throws {
        guard try dependencies.readKeychain(Self.nativeService, account) == expected else { throw Failure.identityChanged }
        do { try dependencies.writeKeychain(Self.nativeService, account, updated) } catch {
            // A Keychain writer can fail after committing. Its readback, not
            // the return code alone, determines whether the successor is safe.
            guard try dependencies.readKeychain(Self.nativeService, account) == updated else { throw Failure.unavailable }
        }
        guard try dependencies.readKeychain(Self.nativeService, account) == updated else { throw Failure.unavailable }
    }

    /// Called only by an explicit switch while the existing mutation/consume
    /// locks are held. A pending marker prevents reusing an uncertain grant.
    private func switchTarget(_ reference: ClaudeSubscriptionReference, stored: StoredSlot, validate: () throws -> Void) async throws -> StoredSlot {
        let account = renewalAccount(reference)
        var recovery = try dependencies.readKeychain(Self.nativeService, account)
        let oauth = try Self.oauthAllowExpired(stored.snapshot.credential)
        if recovery == nil {
            do {
                _ = try Self.oauth(stored.snapshot.credential, now: dependencies.now())
                let identity = try await officialIdentity(stored.snapshot.credential)
                guard identity.fingerprint == reference.identityFingerprint else { throw Failure.identityChanged }
                try validate()
                return stored
            } catch Failure.expired {}
            guard let refreshToken = Self.text(oauth["refreshToken"]) else { throw Failure.reauthenticationRequired }
            var record: [String: Any] = [
                "identityFingerprint": reference.identityFingerprint,
                "slotDigest": Self.digest(stored.bytes), "pendingDigest": Self.digest(Data(refreshToken.utf8)),
            ]
            let pending = try Self.bytes(record)
            try validate()
            try writeRenewalRecord(account, expected: nil, updated: pending)
            var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.bytes([
                "grant_type": "refresh_token", "refresh_token": refreshToken,
                "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            ])
            do {
                let response = try await dependencies.transport.response(for: request)
                guard response.statusCode == 200 else { throw Failure.reauthenticationRequired }
                let reply = try Self.object(response.data)
                guard let access = Self.text(reply["access_token"]), let seconds = reply["expires_in"] as? NSNumber,
                    CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.doubleValue.isFinite,
                    seconds.doubleValue > 0
                else { throw Failure.reauthenticationRequired }
                let expiry = (dependencies.now().timeIntervalSince1970 + seconds.doubleValue) * 1000
                guard expiry.isFinite else { throw Failure.reauthenticationRequired }
                var updated = try Self.object(stored.snapshot.credential)
                var renewed = oauth
                renewed["accessToken"] = access
                renewed["expiresAt"] = expiry
                if let value = reply["refresh_token"], !(value is NSNull) {
                    guard let raw = value as? String else { throw Failure.reauthenticationRequired }
                    if !raw.isEmpty {
                        guard let rotated = Self.text(raw) else { throw Failure.reauthenticationRequired }
                        renewed["refreshToken"] = rotated
                    }
                }
                if let scope = Self.text(reply["scope"]) { renewed["scopes"] = scope.split(separator: " ").map(String.init) }
                if let refreshSeconds = reply["refresh_token_expires_in"] as? NSNumber {
                    let refreshExpiry = (dependencies.now().timeIntervalSince1970 + refreshSeconds.doubleValue) * 1000
                    guard CFGetTypeID(refreshSeconds) != CFBooleanGetTypeID(), refreshSeconds.doubleValue > 0,
                        refreshExpiry.isFinite
                    else { throw Failure.reauthenticationRequired }
                    renewed["refreshTokenExpiresAt"] = refreshExpiry
                }
                updated["claudeAiOauth"] = renewed
                let credential = try Self.bytes(updated)
                record["credential"] = updated
                record["successorDigest"] = Self.digest(try slotPayload(reference, stored: stored, credential: credential))
                let successor = try Self.bytes(record)
                // Save the rotated grant before cancellation, identity checks,
                // or a slot CAS can fail. Use the same service and existing ACL.
                try writeRenewalRecord(account, expected: pending, updated: successor)
                recovery = successor
            } catch {
                // A timeout or an unpersisted response can have consumed the
                // refresh grant. Leave pendingDigest and require official login.
                throw Failure.reauthenticationRequired
            }
        }
        guard let recovery else { throw Failure.unavailable }
        let record = try Self.object(recovery)
        guard Self.text(record["identityFingerprint"]) == reference.identityFingerprint,
            let slotDigest = Self.text(record["slotDigest"]),
            let pendingDigest = Self.text(record["pendingDigest"]), pendingDigest.count == 64
        else { throw Failure.identityChanged }
        let recoveredOAuth = (record["credential"] as? [String: Any])?["claudeAiOauth"] as? [String: Any]
        if Self.digest(stored.bytes) != slotDigest, let refreshToken = Self.text(oauth["refreshToken"]),
            Self.digest(Data(refreshToken.utf8)) != pendingDigest,
            refreshToken != Self.text(recoveredOAuth?["refreshToken"])
        {
            // The original slot owner may explicitly save a fresh official
            // login (including claude-swap). Accept only a different grant
            // with a verified identity; never discard an uncertain old grant
            // merely because its surrounding metadata changed.
            try validate()
            let identity = try await officialIdentity(stored.snapshot.credential)
            guard identity.fingerprint == reference.identityFingerprint else { throw Failure.identityChanged }
            try validate()
            guard try dependencies.readKeychain(Self.nativeService, account) == recovery else { throw Failure.identityChanged }
            try dependencies.writeKeychain(Self.nativeService, account, nil)
            guard try dependencies.readKeychain(Self.nativeService, account) == nil else { throw Failure.unavailable }
            return stored
        }
        guard let root = record["credential"] as? [String: Any], let successorDigest = Self.text(record["successorDigest"]) else {
            throw Failure.reauthenticationRequired
        }
        let credential = try Self.bytes(root)
        let payload = try slotPayload(reference, stored: stored, credential: credential)
        guard [slotDigest, successorDigest].contains(Self.digest(stored.bytes)),
            Self.digest(payload) == successorDigest
        else { throw Failure.identityChanged }
        guard try dependencies.readKeychain(Self.nativeService, account) == recovery else { throw Failure.identityChanged }
        do { _ = try Self.oauth(credential, now: dependencies.now()) } catch Failure.expired { throw Failure.reauthenticationRequired }
        try validate()
        let identity = try await officialIdentity(credential)
        guard identity.fingerprint == reference.identityFingerprint else { throw Failure.identityChanged }
        try validate()
        guard try dependencies.readKeychain(Self.nativeService, account) == recovery else { throw Failure.identityChanged }
        if stored.bytes != payload {
            do { try writeStorage(stored.location, expected: stored.bytes, updated: payload) } catch let failure as Failure { throw failure } catch { throw Failure.unavailable }
        }
        guard try readStorage(stored.location) == payload else { throw Failure.unavailable }
        // Failed cleanup is harmless: a later explicit switch recognizes this
        // exact successor and never POSTs the old refresh token again.
        if try dependencies.readKeychain(Self.nativeService, account) == recovery {
            try? dependencies.writeKeychain(Self.nativeService, account, nil)
        }
        return try storedSlot(reference)
    }

    func switchTo(_ target: ClaudeSubscriptionReference, allReferences: [ClaudeSubscriptionReference]) async throws {
        try requireIdle()
        try rejectAPIRoute()
        let sourceRevisions = try cswapRevisions(allReferences)
        let profileRegistry = support.appendingPathComponent("local-cli-accounts-v1.json")
        let profileRevision = try read(profileRegistry, missing: true)
        let targetStored = try storedSlot(target)
        let liveBefore = try liveCredential()
        guard let beforeConfig = try read(configURL) else { throw Failure.invalid }
        var config = try Self.object(beforeConfig)
        guard let currentAccount = config["oauthAccount"] as? [String: Any] else { throw Failure.invalid }
        let declared = try storedIdentity(currentAccount)
        guard let source = allReferences.first(where: { $0.identityFingerprint == declared.fingerprint }) else { throw Failure.readOnly }
        let cswapLocks = try CSWAPLocks(home: home, references: [source, target], includeGlobalLock: allReferences.contains { $0.source == .cswap })
        defer { cswapLocks.release() }
        let locks = try MutationLocks(directory: defaultDirectory, config: configURL, support: support)
        defer { locks.release() }
        func validate() throws {
            try Task.checkCancellation()
            try locks.verify()
            try cswapLocks.verify()
            try requireIdle()
            try rejectAPIRoute()
            guard try cswapRevisions(allReferences) == sourceRevisions, try read(profileRegistry, missing: true) == profileRevision,
                try liveCredential() == liveBefore, try read(configURL) == beforeConfig
            else { throw Failure.identityChanged }
        }
        try validate()
        let sourceIdentity = try await officialIdentity(liveBefore)
        guard sourceIdentity.fingerprint == source.identityFingerprint else { throw Failure.identityChanged }
        try validate()
        if source.identityFingerprint == target.identityFingerprint { return }
        let selectedStored = try await switchTarget(target, stored: targetStored) {
            try validate()
            guard try storedSlot(target).bytes == targetStored.bytes else { throw Failure.identityChanged }
        }
        let selected = selectedStored.snapshot
        try validate()
        guard try storedSlot(target).bytes == selectedStored.bytes else { throw Failure.identityChanged }
        let service = "Claude Code-credentials"
        let account = Self.keychainAccount
        let beforeKeychain = try dependencies.readKeychain(service, account)
        let credentialFile = defaultDirectory.appendingPathComponent(".credentials.json")
        let beforeFile = try read(credentialFile, missing: true)
        let sourceStored = try storedSlot(source)
        guard sourceStored.snapshot.identity.fingerprint == sourceIdentity.fingerprint else { throw Failure.identityChanged }
        let sourceSlot = sourceStored.bytes
        var liveObject = try Self.object(liveBefore)
        liveObject["claudeAiOauth"] = try Self.object(selected.credential)["claudeAiOauth"]
        let updatedCredential = try Self.bytes(liveObject)
        let updatedFile: Data?
        if let beforeFile {
            var fileObject = try Self.object(beforeFile)
            fileObject["claudeAiOauth"] = try Self.object(selected.credential)["claudeAiOauth"]
            updatedFile = try Self.bytes(fileObject)
        } else {
            updatedFile = nil
        }
        config["oauthAccount"] = selected.oauthAccount
        let updatedConfig = try Self.bytes(config)
        let sourcePayload: Data
        if source.source == .native {
            sourcePayload = try Self.bytes(["credential": Self.object(liveBefore), "oauthAccount": currentAccount])
        } else {
            var original = try Self.object(sourceStored.snapshot.credential)
            original["claudeAiOauth"] = try Self.object(liveBefore)["claudeAiOauth"]
            let credential = try Self.bytes(original)
            if case .encodedFile = sourceStored.location { sourcePayload = Data(credential.base64EncodedString().utf8) } else { sourcePayload = credential }
        }
        let sequenceURL = home.appendingPathComponent(".claude-swap-backup/sequence.json")
        let beforeSequence = sourceRevisions["sequence"]
        let updatedSequence: Data?
        if let beforeSequence {
            var sequence = try Self.object(beforeSequence)
            sequence["activeAccountNumber"] = target.source == .cswap ? Int(target.slot).map { $0 as Any } : NSNull()
            updatedSequence = try Self.bytes(sequence)
        } else {
            updatedSequence = nil
        }
        var slotWritten = false
        var keychainWritten = false
        var fileWritten = false
        var configWritten = false
        var sequenceWritten = false
        do {
            try locks.verify()
            try cswapLocks.verify()
            try Task.checkCancellation()
            _ = try Self.oauth(selected.credential, now: dependencies.now())
            slotWritten = true
            try writeStorage(sourceStored.location, expected: sourceSlot, updated: sourcePayload)
            guard try readStorage(sourceStored.location) == sourcePayload else { throw Failure.unavailable }
            try locks.verify()
            try cswapLocks.verify()
            try requireIdle()
            guard try read(profileRegistry, missing: true) == profileRevision else { throw Failure.identityChanged }
            try locks.verify()
            keychainWritten = true
            try dependencies.writeKeychain(service, account, updatedCredential)
            if let beforeFile {
                try locks.verify()
                fileWritten = true
                try DispatchParticipationSync.writeSnapshot(updatedFile!, at: credentialFile, replacing: beforeFile)
            }
            try locks.verify()
            configWritten = true
            try DispatchParticipationSync.writeSnapshot(updatedConfig, at: configURL, replacing: beforeConfig)
            if let updatedSequence, let beforeSequence {
                try locks.verify()
                try cswapLocks.verify()
                sequenceWritten = true
                try DispatchParticipationSync.writeSnapshot(updatedSequence, at: sequenceURL, replacing: beforeSequence)
            }
            try locks.verify()
            try cswapLocks.verify()
            guard try liveCredential() == updatedCredential, try read(configURL) == updatedConfig,
                try activeFingerprint() == target.identityFingerprint
            else { throw Failure.identityChanged }
        } catch {
            // Restore only bytes still owned by this transaction. A concurrent
            // change never gets overwritten; surface recovery-required instead.
            do {
                try locks.verify()
                try cswapLocks.verify()
                if sequenceWritten {
                    let current = try read(sequenceURL)
                    if current == updatedSequence {
                        try DispatchParticipationSync.writeSnapshot(beforeSequence!, at: sequenceURL, replacing: updatedSequence!)
                    } else if current != beforeSequence {
                        throw Failure.identityChanged
                    }
                }
                if configWritten {
                    let current = try read(configURL)
                    if current == updatedConfig {
                        try DispatchParticipationSync.writeSnapshot(beforeConfig, at: configURL, replacing: updatedConfig)
                    } else if current != beforeConfig {
                        throw Failure.identityChanged
                    }
                }
                if fileWritten {
                    let current = try read(credentialFile)
                    if current == updatedFile {
                        try DispatchParticipationSync.writeSnapshot(beforeFile!, at: credentialFile, replacing: updatedFile!)
                    } else if current != beforeFile {
                        throw Failure.identityChanged
                    }
                }
                if keychainWritten {
                    let current = try dependencies.readKeychain(service, account)
                    if current == updatedCredential {
                        try dependencies.writeKeychain(service, account, beforeKeychain)
                    } else if current != beforeKeychain {
                        throw Failure.identityChanged
                    }
                }
                if slotWritten {
                    let current = try readStorage(sourceStored.location)
                    if current == sourcePayload {
                        try writeStorage(sourceStored.location, expected: sourcePayload, updated: sourceSlot)
                    } else if current != sourceSlot {
                        throw Failure.identityChanged
                    }
                }
                guard try liveCredential() == liveBefore, try read(configURL) == beforeConfig else { throw Failure.identityChanged }
                throw Failure.rolledBack
            } catch Failure.rolledBack { throw Failure.rolledBack } catch { throw Failure.rollbackFailed }
        }
    }
    /// No process is killed. Missing/oversized/ambiguous process evidence blocks.
    static func processesIdle() throws -> Bool {
        let data = try BoundedLocalProcess.run(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "comm=,args="], maximumOutputBytes: 2_097_152, timeout: 3)
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw Failure.unavailable }
        return processEvidenceIsIdle(value)
    }
    static func processEvidenceIsIdle(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return !value.split(separator: "\n").contains { line in
            let lower = line.lowercased()
            let command = lower.split(separator: " ").first.map(String.init) ?? ""
            let basename = URL(fileURLWithPath: command).lastPathComponent
            return lower.contains("/claude/versions/") || basename == "claude" || basename == "cswap" || lower.contains("claude-code") || lower.contains("claude_swap")
                || lower.contains("visual studio code.app/") || lower.contains("cursor.app/") || lower.contains("claude.app/")
                || (basename == "node" && lower.contains("/claude/"))
        }
    }
    static func readKeychain(_ service: String, _ account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 1_048_576 else { throw Failure.unavailable }
        return data
    }
    static func writeKeychain(_ service: String, _ account: String, _ data: Data?) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
            return
        }
        guard data.count <= 1_048_576 else { throw Failure.invalid }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.unavailable }
    }
    /// Same file-lock inodes as claude-swap. Consume locks precede its registry
    /// lock; none are broken or unlinked. Only invoked for an explicit switch.
    private final class CSWAPLocks {
        private var files: [(URL, Int32, stat)] = []
        init(home: URL, references: [ClaudeSubscriptionReference], includeGlobalLock: Bool = false) throws {
            let slots = references.filter { $0.source == .cswap }.map(\.slot)
            if slots.isEmpty && !includeGlobalLock { return }
            let root = home.appendingPathComponent(".claude-swap-backup")
            var urls = Set(slots).sorted().map { root.appendingPathComponent("credentials/.consume-" + $0 + ".lock") }
            if includeGlobalLock || !slots.isEmpty { urls.append(root.appendingPathComponent(".lock")) }
            do {
                for url in urls {
                    guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.invalid }
                    let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    var info = stat()
                    guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
                        info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0
                    else {
                        if fd >= 0 { close(fd) }
                        throw Failure.invalid
                    }
                    files.append((url, fd, info))
                    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
                }
            } catch {
                release()
                throw error
            }
        }
        func verify() throws {
            for (url, _, original) in files {
                var current = stat()
                guard lstat(url.path, &current) == 0, current.st_ino == original.st_ino, current.st_dev == original.st_dev else { throw Failure.identityChanged }
            }
        }
        func release() {
            for (_, fd, _) in files.reversed() {
                _ = flock(fd, LOCK_UN)
                close(fd)
            }
            files.removeAll()
        }
        deinit { release() }
    }
    private final class MutationLocks {
        private var locks: [(URL, Int32, stat)] = []
        private var fileDescriptor: Int32 = -1
        private let queue = DispatchQueue(label: "AiGoodBro.claude-subscription-lock-heartbeat")
        private var heartbeat: DispatchSourceTimer?
        init(directory: URL, config: URL, support: URL) throws {
            do {
                guard support.standardizedFileURL == support.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.invalid }
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                fileDescriptor = open(support.appendingPathComponent(".claude-subscription-switch.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                var fileInfo = stat()
                guard fileDescriptor >= 0, fstat(fileDescriptor, &fileInfo) == 0, fileInfo.st_mode & S_IFMT == S_IFREG,
                    fileInfo.st_uid == geteuid(), fileInfo.st_nlink == 1, fileInfo.st_mode & 0o077 == 0,
                    flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0
                else { throw Failure.busy }
                for url in [directory.appendingPathComponent(".oauth_refresh.lock"), URL(fileURLWithPath: directory.path + ".lock"), URL(fileURLWithPath: config.path + ".lock")] {
                    guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
                        mkdir(url.path, 0o700) == 0
                    else { throw Failure.busy }
                    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    var info = stat()
                    guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR else {
                        if fd >= 0 { close(fd) }
                        throw Failure.invalid
                    }
                    locks.append((url, fd, info))
                }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    for (url, fd, original) in self.locks {
                        var current = stat()
                        if lstat(url.path, &current) == 0, current.st_ino == original.st_ino, current.st_dev == original.st_dev { _ = futimes(fd, nil) }
                    }
                }
                heartbeat = timer
                timer.resume()
            } catch {
                release()
                throw error
            }
        }
        func verify() throws {
            for (url, _, original) in locks {
                var current = stat()
                guard lstat(url.path, &current) == 0, current.st_ino == original.st_ino, current.st_dev == original.st_dev,
                    abs(Date().timeIntervalSince1970 - Double(current.st_mtimespec.tv_sec)) < 8
                else { throw Failure.identityChanged }
            }
        }
        func release() {
            heartbeat?.cancel()
            heartbeat = nil
            queue.sync {}
            for (url, fd, original) in locks.reversed() {
                var current = stat()
                if lstat(url.path, &current) == 0, current.st_ino == original.st_ino, current.st_dev == original.st_dev { _ = rmdir(url.path) }
                close(fd)
            }
            locks.removeAll()
            if fileDescriptor >= 0 {
                _ = flock(fileDescriptor, LOCK_UN)
                close(fileDescriptor)
                fileDescriptor = -1
            }
        }
        deinit { release() }
    }
}
