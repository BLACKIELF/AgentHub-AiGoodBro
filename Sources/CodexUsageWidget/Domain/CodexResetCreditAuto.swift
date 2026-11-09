import Darwin
import Foundation

/// Defaults bind once to a verified identity; changing that identity never inherits authorization.
struct CodexResetCreditAutoPreferences: Codable, Equatable {
    static let storageKey = "CodexManagerNext.resetCreditAuto.v1"
    var authorizedAccounts: [String: String] = [:]
    private(set) var disabledProfileIDs: Set<String> = []
    private(set) var automaticallyEnrollNewAccounts = true
    private(set) var legacyMigrationPending = false
    static let defaultLeadMinutes = 30
    static let leadPresets = [3, 5, 10, 15, 30, 60, 120, 180, 360, 720, 1440]
    static let customLeadRange = 3...1440

    var leadMinutes = Self.defaultLeadMinutes

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, authorizedAccounts, disabledProfileIDs, automaticallyEnrollNewAccounts, legacyMigrationPending, leadMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version == 1 || version == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values, debugDescription: "Unsupported reset preference version")
        }
        authorizedAccounts = try values.decode([String: String].self, forKey: .authorizedAccounts)
        leadMinutes = try values.decode(Int.self, forKey: .leadMinutes)
        if version == 1 {
            // A missing legacy grant could be an explicit off. Classify the complete
            // existing profile list before any new account may inherit the default.
            legacyMigrationPending = true
        } else {
            disabledProfileIDs = try values.decode(Set<String>.self, forKey: .disabledProfileIDs)
            automaticallyEnrollNewAccounts = try values.decode(Bool.self, forKey: .automaticallyEnrollNewAccounts)
            legacyMigrationPending = try values.decode(Bool.self, forKey: .legacyMigrationPending)
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .authorizedAccounts, in: values, debugDescription: "Invalid reset preferences")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .schemaVersion)
        try values.encode(authorizedAccounts, forKey: .authorizedAccounts)
        try values.encode(disabledProfileIDs.sorted(), forKey: .disabledProfileIDs)
        try values.encode(automaticallyEnrollNewAccounts, forKey: .automaticallyEnrollNewAccounts)
        try values.encode(legacyMigrationPending, forKey: .legacyMigrationPending)
        try values.encode(leadMinutes, forKey: .leadMinutes)
    }

    static var failClosed: Self {
        var value = Self()
        value.automaticallyEnrollNewAccounts = false
        return value
    }

    static func load(_ storedValue: Any?) -> Self {
        guard let storedValue else { return Self() }
        guard let data = storedValue as? Data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return .failClosed }
        return value
    }

    var isValid: Bool {
        (1...1440).contains(leadMinutes) && authorizedAccounts.count + disabledProfileIDs.count <= 1000
            && disabledProfileIDs.allSatisfy(Self.validProfileID)
            && disabledProfileIDs.isDisjoint(with: authorizedAccounts.keys)
            && authorizedAccounts.allSatisfy {
                Self.validProfileID($0.key)
                    && $0.value.count == 64 && $0.value.allSatisfy { "0123456789abcdef".contains($0) }
            }
    }

    private static func validProfileID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 }

    func shouldEnroll(profileID: String) -> Bool {
        isValid && automaticallyEnrollNewAccounts && !legacyMigrationPending && Self.validProfileID(profileID)
            && authorizedAccounts[profileID] == nil && !disabledProfileIDs.contains(profileID)
    }

    /// Caller supplies one complete, successfully loaded profile list. Identities
    /// must come from successful ChatGPT quota reads, never names or login guesses.
    mutating func reconcile(profileIDs: Set<String>, verifiedAccountIDs: [String: String]) {
        guard isValid, !profileIDs.isEmpty, profileIDs.count <= 1000, profileIDs.allSatisfy(Self.validProfileID) else { return }
        var next = self
        if next.legacyMigrationPending {
            next.disabledProfileIDs.formUnion(profileIDs.filter { next.authorizedAccounts[$0] == nil })
            next.legacyMigrationPending = false
        }
        for profileID in profileIDs.sorted() where next.shouldEnroll(profileID: profileID) {
            guard let accountID = verifiedAccountIDs[profileID], !accountID.isEmpty else { continue }
            next.authorizedAccounts[profileID] = DispatchActivityStore.hash(accountID)
        }
        if next.isValid { self = next }
    }

    mutating func setEnabled(_ enabled: Bool, profileID: String, accountID: String? = nil) {
        guard isValid, Self.validProfileID(profileID) else { return }
        var next = self
        if enabled {
            guard let accountID, !accountID.isEmpty else { return }
            next.disabledProfileIDs.remove(profileID)
            next.authorizedAccounts[profileID] = DispatchActivityStore.hash(accountID)
        } else {
            next.authorizedAccounts[profileID] = nil
            next.disabledProfileIDs.insert(profileID)
        }
        if next.isValid { self = next }
    }

    mutating func disableAll(profileIDs: Set<String>) {
        guard isValid, profileIDs.allSatisfy(Self.validProfileID) else { return }
        var next = self
        next.disabledProfileIDs.formUnion(profileIDs)
        next.disabledProfileIDs.formUnion(next.authorizedAccounts.keys)
        next.authorizedAccounts.removeAll()
        if next.isValid { self = next }
    }

    func permits(profileID: String, accountID: String) -> Bool {
        isValid && !profileID.isEmpty && !accountID.isEmpty && authorizedAccounts[profileID] == DispatchActivityStore.hash(accountID)
    }
    var leadSeconds: TimeInterval { Double(min(1440, max(1, leadMinutes))) * 60 }

    func isWithinExpiryWindow(_ expiry: Date, now: Date) -> Bool {
        let remaining = expiry.timeIntervalSince(now)
        return remaining > 0 && remaining <= leadSeconds
    }
}

/// Cancellation and the consume write share one lock, so revocation wins before admission.
final class CodexResetCreditAutoAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    func cancel() {
        lock.lock()
        revoked = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }
    func admit(_ operation: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked && operation()
    }
}

struct CodexResetCreditAutoStateStore {
    struct Entry: Codable {
        enum Phase: String, Codable { case prepared, completed, deferred, uncertain }
        var attemptID = UUID()
        var expiresAt: Date? = nil
        let accountHash: String
        let cardHash: String
        var phase: Phase
        var outcome: String?
        var nextRetry: Date?
        let quotaFingerprint: String
    }
    static let live = Self(
        url: DispatchParticipationPaths.supportDirectory()
            .appendingPathComponent("reset-credit/auto-state-v1.json"))
    let url: URL
    private struct Envelope: Codable {
        let version: Int
        var entries: [Entry]
        var rejectedThrough: Date? = nil
    }
    private func prepare() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
    }
    private func valid(_ entry: Entry) -> Bool {
        func hash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
        return hash(entry.accountHash) && hash(entry.cardHash) && hash(entry.quotaFingerprint)
            && (entry.expiresAt?.timeIntervalSince1970.isFinite ?? false)
            && (entry.nextRetry?.timeIntervalSince1970.isFinite ?? true)
            && (entry.outcome?.utf8.count ?? 0) <= 64
    }
    private func read() throws -> Envelope {
        guard let data = try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: 65536, allowMissing: true) else {
            return Envelope(version: 1, entries: [])
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation
        }
        let result = try JSONDecoder().decode(Envelope.self, from: data)
        guard result.version == 1, result.entries.count <= 256, result.entries.allSatisfy(valid),
            Set(result.entries.map(\.attemptID)).count == result.entries.count,
            Set(result.entries.map { $0.accountHash + $0.cardHash }).count == result.entries.count,
            result.rejectedThrough?.timeIntervalSince1970.isFinite ?? true
        else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
        return result
    }
    func requiresReconciliation(accountID: String) throws -> Bool {
        try prepare()
        return try DispatchParticipationSync.withSnapshotLock(at: url) {
            try read().entries.contains {
                $0.accountHash == DispatchActivityStore.hash(accountID)
                    && ($0.phase == .prepared || $0.phase == .uncertain)
            }
        }
    }
    func mayAttempt(accountID: String, cardID: String, fingerprint: String, now: Date) throws -> Bool {
        try prepare()
        return try DispatchParticipationSync.withSnapshotLock(at: url) {
            let entries = try read().entries
            let account = DispatchActivityStore.hash(accountID)
            if entries.contains(where: { $0.accountHash == account && ($0.phase == .prepared || $0.phase == .uncertain) }) { return false }
            guard let prior = entries.last(where: { $0.accountHash == account && $0.cardHash == DispatchActivityStore.hash(cardID) }) else { return true }
            return prior.phase == .deferred && (prior.nextRetry ?? .distantFuture) <= now
                && (prior.outcome == "notSent" || prior.quotaFingerprint != fingerprint)
        }
    }
    func claim(_ entry: Entry, now: Date = Date()) throws -> Bool {
        guard valid(entry), entry.phase == .prepared else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
        try prepare()
        return try DispatchParticipationSync.withSnapshotLock(at: url) {
            var journal = try read()
            let removed = journal.entries.filter { ($0.phase == .completed || $0.phase == .deferred) && ($0.expiresAt ?? .distantFuture) <= now }
            if let newest = removed.compactMap(\.expiresAt).max() {
                journal.rejectedThrough = max(journal.rejectedThrough ?? .distantPast, newest)
            }
            journal.entries.removeAll { ($0.phase == .completed || $0.phase == .deferred) && ($0.expiresAt ?? .distantFuture) <= now }
            guard let expiry = entry.expiresAt, expiry > now, expiry > (journal.rejectedThrough ?? .distantPast),
                !journal.entries.contains(where: { $0.accountHash == entry.accountHash && ($0.phase == .prepared || $0.phase == .uncertain) })
            else { return false }
            if let prior = journal.entries.last(where: { $0.accountHash == entry.accountHash && $0.cardHash == entry.cardHash }) {
                guard prior.phase == .deferred, (prior.nextRetry ?? .distantFuture) <= now,
                    prior.outcome == "notSent" || prior.quotaFingerprint != entry.quotaFingerprint
                else { return false }
                journal.entries.removeAll { $0.attemptID == prior.attemptID }
            }
            guard journal.entries.count < 256 else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
            journal.entries.append(entry)
            let data = try JSONEncoder().encode(journal)
            guard data.count + 256 <= 65536 else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
            try DispatchParticipationSync.writePrivateProxyPreferences(data, at: url)
            return true
        }
    }
    func record(_ entry: Entry) throws {
        guard valid(entry), entry.phase != .prepared else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
        try prepare()
        try DispatchParticipationSync.withSnapshotLock(at: url) {
            var journal = try read()
            guard
                journal.entries.contains(where: {
                    $0.attemptID == entry.attemptID && $0.phase == .prepared && $0.accountHash == entry.accountHash && $0.cardHash == entry.cardHash
                        && $0.expiresAt == entry.expiresAt
                })
            else {
                throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation
            }
            journal.entries.removeAll { $0.attemptID == entry.attemptID }
            guard journal.entries.count < 256 else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
            journal.entries.append(entry)
            let data = try JSONEncoder().encode(journal)
            guard data.count <= 65536 else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
            try DispatchParticipationSync.writePrivateProxyPreferences(data, at: url)
        }
    }
}
