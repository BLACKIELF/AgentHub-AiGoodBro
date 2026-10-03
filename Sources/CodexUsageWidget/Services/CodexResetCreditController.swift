import Combine
import Darwin
import Foundation

@MainActor
final class CodexResetCreditController: ObservableObject {
    enum ConfirmationStep: Equatable {
        case idle
        case reviewing(CodexResetCreditReview)
        case consumption(CodexResetCreditReview)
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool

        static func == (lhs: Notice, rhs: Notice) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published private(set) var step: ConfirmationStep = .idle
    @Published private(set) var isWorking = false
    @Published var notice: Notice?

    private static var activeProfileID: String?
    private static let challengeLifetime: TimeInterval = 2 * 60
    private let activityStore: DispatchActivityStore
    private let pendingStore: ResetCreditPendingAttemptStore
    private var generation = UUID()
    private var requestedIdentity: (profileID: String, accountID: String)?
    private var isConsuming = false
    private var ownedProfileID: String?

    init(
        activityStore: DispatchActivityStore = .live,
        pendingStore: ResetCreditPendingAttemptStore = .live
    ) {
        self.activityStore = activityStore
        self.pendingStore = pendingStore
    }

    func beginReview(profile: CodexProfile, selectedProfileID: String?) {
        guard !isWorking, step == .idle else { return }
        guard selectedProfileID == profile.id else {
            fail(.selectionChanged)
            return
        }
        guard let accountID = profile.lastSnapshot?.accountID, !accountID.isEmpty else {
            fail(.identityUnavailable)
            return
        }
        let existingPending: ResetCreditPendingAttempt?
        do {
            existingPending = try pendingStore.pendingAttempt()
            if let existingPending,
                !existingPending.matchesIdentity(profileID: profile.id, accountID: accountID)
            {
                fail(.pendingAttemptRequiresReconciliation)
                return
            }
        } catch {
            fail(.pendingAttemptRequiresReconciliation)
            return
        }
        guard Self.activeProfileID == nil else {
            fail(.conflictingActivity)
            return
        }
        Self.activeProfileID = profile.id
        ownedProfileID = profile.id
        isWorking = true
        isConsuming = false
        requestedIdentity = (profile.id, accountID)
        let operation = UUID()
        generation = operation
        let remark = Self.safeRemark(for: profile)
        let context = RuntimeLoadContext.live(codexHomeDirectory: profile.codexHomeURL)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CodexUsageReader().readResetCreditReview(
                context: context,
                profile: profile,
                expectedAccountID: accountID,
                accountRemark: remark
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if Self.activeProfileID == profile.id { Self.activeProfileID = nil }
                    return
                }
                guard self.generation == operation else {
                    self.isWorking = false
                    self.isConsuming = false
                    self.requestedIdentity = nil
                    self.releaseOwnership()
                    return
                }
                self.isWorking = false
                self.requestedIdentity = nil
                switch result {
                case .success(let review):
                    guard existingPending?.matches(review) != false else {
                        self.fail(.pendingAttemptRequiresReconciliation)
                        return
                    }
                    self.step = .reviewing(review)
                case .failure(let failure):
                    if existingPending != nil,
                        [.creditAvailabilityUnavailable, .noAvailableCredit, .creditChanged].contains(failure)
                    {
                        self.fail(.pendingAttemptRequiresReconciliation)
                    } else {
                        self.fail(failure)
                    }
                }
            }
        }
    }

    func confirmReviewed(profile: CodexProfile, selectedProfileID: String?) {
        guard case .reviewing(let review) = step,
            current(profile: profile, selectedProfileID: selectedProfileID, matches: review)
        else {
            invalidate(with: .selectionChanged)
            return
        }
        guard challengeIsFresh(review) else {
            invalidate(with: .expiredChallenge)
            return
        }
        step = .consumption(review)
    }

    /// This is the only controller edge that can reach the reader's consume call.
    /// It is reachable only from `ConfirmationStep.consumption` (the second dialog).
    func confirmConsumption(
        profile: CodexProfile,
        selectedProfileID: String?,
        hubAccountAlias: String?,
        onConfirmedResult: @escaping () -> Void
    ) {
        guard !isWorking, case .consumption(let review) = step,
            current(profile: profile, selectedProfileID: selectedProfileID, matches: review)
        else {
            invalidate(with: .selectionChanged)
            return
        }
        guard challengeIsFresh(review) else {
            invalidate(with: .expiredChallenge)
            return
        }

        let leaseID: String
        do {
            leaseID = try activityStore.reserveMaintenance(
                account: profile.recordedAccountKey,
                alias: hubAccountAlias ?? "reset-\(DispatchActivityStore.hash(profile.recordedAccountKey))"
            )
        } catch {
            invalidate(with: .conflictingActivity)
            return
        }
        let pending: ResetCreditPendingAttempt
        let reusesPendingAttempt: Bool
        do {
            (pending, reusesPendingAttempt) = try pendingStore.loadOrCreate(for: review)
        } catch {
            try? activityStore.finishMaintenance(leaseID, succeeded: false)
            invalidate(with: .pendingAttemptRequiresReconciliation)
            return
        }

        step = .idle
        isWorking = true
        isConsuming = true
        requestedIdentity = (profile.id, review.accountID)
        let operation = UUID()
        generation = operation
        let context = RuntimeLoadContext.live(codexHomeDirectory: profile.codexHomeURL)
        Task { [activityStore, pendingStore] in
            let available: Bool
            if let hubAccountAlias {
                available = await HubConsoleModel.warmUpAvailability(for: hubAccountAlias, excludingLocalLease: leaseID) == .idle
            } else {
                available = true
            }
            guard available, self.generation == operation else {
                try? activityStore.finishMaintenance(leaseID, succeeded: false)
                if !reusesPendingAttempt { try? pendingStore.clear(expected: pending) }
                self.invalidate(with: available ? .selectionChanged : .conflictingActivity)
                return
            }
            let result = await Task.detached(priority: .userInitiated) {
                CodexUsageReader().consumeResetCredit(
                    context: context,
                    profile: profile,
                    review: review,
                    idempotencyKey: pending.idempotencyKey
                )
            }.value
            let confirmed: Bool
            switch result {
            case .success: confirmed = true
            case .failure: confirmed = false
            }
            try? activityStore.finishMaintenance(leaseID, succeeded: confirmed)
            if confirmed { try? pendingStore.clear(expected: pending) }
            if case .failure(let failure) = result,
                !reusesPendingAttempt, failure != .outcomeUnknown
            {
                try? pendingStore.clear(expected: pending)
            }
            DispatchQueue.main.async { [weak self] in
                if Self.activeProfileID == profile.id { Self.activeProfileID = nil }
                if confirmed { onConfirmedResult() }
                guard let self else { return }
                self.ownedProfileID = nil
                guard self.generation == operation else {
                    self.isWorking = false
                    self.isConsuming = false
                    self.requestedIdentity = nil
                    return
                }
                self.isWorking = false
                self.isConsuming = false
                self.requestedIdentity = nil
                self.step = .idle
                switch result {
                case .success(let outcome):
                    self.notice = Notice(message: Self.message(for: outcome), isError: outcome != .reset)
                case .failure(let failure):
                    self.notice = Notice(message: failure.localizedDescription, isError: true)
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        step = .idle
        notice = nil
        if !isWorking {
            releaseOwnership()
            requestedIdentity = nil
            isConsuming = false
        }
    }

    func invalidateIfProfileChanged(profile: CodexProfile, selectedProfileID: String?) {
        if step == .idle, isWorking, let requestedIdentity {
            if selectedProfileID != requestedIdentity.profileID
                || profile.id != requestedIdentity.profileID
                || profile.lastSnapshot?.accountID != requestedIdentity.accountID
            {
                cancel()
            }
            return
        }
        guard step != .idle else { return }
        let review: CodexResetCreditReview
        switch step {
        case .reviewing(let value), .consumption(let value): review = value
        case .idle: return
        }
        if !current(profile: profile, selectedProfileID: selectedProfileID, matches: review) {
            invalidate(with: .selectionChanged)
        }
    }

    private func current(
        profile: CodexProfile,
        selectedProfileID: String?,
        matches review: CodexResetCreditReview
    ) -> Bool {
        selectedProfileID == review.profileID
            && profile.id == review.profileID
            && profile.lastSnapshot?.accountID == review.accountID
    }

    private func challengeIsFresh(_ review: CodexResetCreditReview) -> Bool {
        let age = Date().timeIntervalSince(review.observedAt)
        return age >= 0 && age <= Self.challengeLifetime
    }

    private func invalidate(with failure: CodexResetCreditFailure) {
        step = .idle
        releaseOwnership()
        fail(failure)
    }

    private func fail(_ failure: CodexResetCreditFailure) {
        isWorking = false
        notice = Notice(message: failure.localizedDescription, isError: true)
        if step == .idle {
            releaseOwnership()
            requestedIdentity = nil
            isConsuming = false
        }
    }

    private func releaseOwnership() {
        guard let ownedProfileID else { return }
        if Self.activeProfileID == ownedProfileID { Self.activeProfileID = nil }
        self.ownedProfileID = nil
    }

    private static func safeRemark(for profile: CodexProfile) -> String {
        let display = AccountDisplay.profileName(profile)
            .components(separatedBy: .controlCharacters).joined()
        return String(display.prefix(80))
    }

    private static func message(for outcome: CodexResetCreditConsumeOutcome) -> String {
        let language = WidgetLanguage.storedOrAutomatic()
        switch outcome {
        case .reset:
            return language.text("重置已确认。额度将刷新。", "Reset confirmed. Limits will refresh.")
        case .nothingToReset:
            return language.text("当前没有可重置的额度窗口。额度将刷新。", "No limit window is currently eligible. Limits will refresh.")
        case .noCredit:
            return language.text("没有可用的重置卡。额度将刷新。", "No reset card is available. Limits will refresh.")
        case .alreadyRedeemed:
            return language.text("这张重置卡已使用。额度将刷新。", "This reset card was already used. Limits will refresh.")
        }
    }
}

struct ResetCreditPendingAttempt: Codable, Equatable {
    let schemaVersion: Int
    let accountKey: String
    let profileID: String
    let creditID: String
    let expiresAt: Date?
    let idempotencyKey: String
    let createdAt: Date

    init(review: CodexResetCreditReview, idempotencyKey: String) {
        schemaVersion = 1
        accountKey = DispatchActivityStore.hash(review.accountID)
        profileID = review.profileID
        creditID = review.card.creditID
        expiresAt = review.card.expiresAt
        self.idempotencyKey = idempotencyKey
        createdAt = Date()
    }

    func matches(_ review: CodexResetCreditReview) -> Bool {
        schemaVersion == 1
            && accountKey == DispatchActivityStore.hash(review.accountID)
            && profileID == review.profileID
            && creditID == review.card.creditID
            && expiresAt == review.card.expiresAt
            && !idempotencyKey.isEmpty
    }

    func matchesIdentity(profileID: String, accountID: String) -> Bool {
        schemaVersion == 1
            && accountKey == DispatchActivityStore.hash(accountID)
            && self.profileID == profileID
    }

    var isValid: Bool {
        schemaVersion == 1
            && accountKey.count == 64
            && accountKey.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && Self.validField(profileID, maximumBytes: 256)
            && Self.validField(creditID, maximumBytes: 512)
            && UUID(uuidString: idempotencyKey) != nil
            && idempotencyKey.utf8.count == 36
            && createdAt.timeIntervalSince1970.isFinite
            && (expiresAt?.timeIntervalSince1970.isFinite ?? true)
    }

    private static func validField(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

struct ResetCreditPendingAttemptStore {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let pending: ResetCreditPendingAttempt?
    }

    static let live = ResetCreditPendingAttemptStore(
        url: DispatchParticipationPaths.supportDirectory()
            .appendingPathComponent("reset-credit", isDirectory: true)
            .appendingPathComponent("pending-attempt-v1.json")
    )
    let url: URL

    func pendingAttempt() throws -> ResetCreditPendingAttempt? {
        let data = try DispatchParticipationSync.readBoundedRegularFile(
            url, maximumBytes: 16 * 1_024, allowMissing: true
        )
        try validateFileIfPresent(data != nil)
        return try decode(data)
    }

    func loadOrCreate(for review: CodexResetCreditReview) throws -> (ResetCreditPendingAttempt, Bool) {
        try prepareDirectory()
        return try DispatchParticipationSync.withSnapshotLock(at: url) {
            let original = try DispatchParticipationSync.readBoundedRegularFile(
                url, maximumBytes: 16 * 1_024, allowMissing: true
            )
            try validateFileIfPresent(original != nil)
            if let existing = try decode(original) {
                guard existing.matches(review) else {
                    throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation
                }
                return (existing, true)
            }
            let pending = ResetCreditPendingAttempt(
                review: review,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            guard pending.isValid else {
                throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation
            }
            let data = try encode(pending)
            try DispatchParticipationSync.writeSnapshot(data, at: url, replacing: original)
            guard
                try DispatchParticipationSync.readBoundedRegularFile(
                    url, maximumBytes: 16 * 1_024, allowMissing: false
                ) == data
            else {
                throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation
            }
            try validateFileIfPresent(true)
            return (pending, false)
        }
    }

    func clear(expected: ResetCreditPendingAttempt) throws {
        guard expected.isValid else {
            throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation
        }
        try prepareDirectory()
        try DispatchParticipationSync.withSnapshotLock(at: url) {
            guard
                let original = try DispatchParticipationSync.readBoundedRegularFile(
                    url, maximumBytes: 16 * 1_024, allowMissing: false
                ), try decode(original) == expected
            else {
                throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation
            }
            try validateFileIfPresent(true)
            let data = try encode(nil)
            try DispatchParticipationSync.writeSnapshot(data, at: url, replacing: original)
            guard
                try DispatchParticipationSync.readBoundedRegularFile(
                    url, maximumBytes: 16 * 1_024, allowMissing: false
                ) == data
            else {
                throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation
            }
            try validateFileIfPresent(true)
        }
    }

    private func decode(_ data: Data?) throws -> ResetCreditPendingAttempt? {
        guard let data else { return nil }
        guard data.count <= 16 * 1_024,
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.schemaVersion == 1,
            envelope.pending?.isValid != false
        else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
        return envelope.pending
    }

    private func encode(_ pending: ResetCreditPendingAttempt?) throws -> Data {
        let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, pending: pending))
        guard data.count <= 16 * 1_024 else {
            throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation
        }
        return data
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard lstat(directory.path, &info) == 0,
            info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(),
            info.st_mode & 0o077 == 0
        else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
    }

    private func validateFileIfPresent(_ isPresent: Bool) throws {
        guard isPresent else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(),
            info.st_nlink == 1,
            info.st_mode & 0o077 == 0
        else { throw CodexResetCreditFailure.pendingAttemptRequiresReconciliation }
    }
}
