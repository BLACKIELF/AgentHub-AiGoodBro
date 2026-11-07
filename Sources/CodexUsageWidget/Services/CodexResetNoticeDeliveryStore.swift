import Darwin
import Foundation

enum CodexResetNoticeDeliveryPhase: String, Codable {
    case baseline, pending, sending, sent, uncertain
}

/// Accepted means the API accepted the request, never proof of human delivery.
/// Only a proven admission failure or explicit rejection is automatically retryable.
enum CodexResetNoticeDeliveryReceipt: String, Codable {
    case accepted, notSent, rejected, uncertain

    static func messageChannel(_ result: Result<MessageDeliveryOutcome, MessageChannelError>) -> Self {
        switch result {
        case .success(.accepted): return .accepted
        case .success(.duplicateSkipped): return .uncertain
        case .failure(let error):
            switch error {
            case .transportFailed, .invalidResponse, .redirected, .cancelled:
                return .uncertain
            case .httpStatus(let status):
                // A generic server error can follow a side effect. A validated
                // channel-specific rejection may be mapped explicitly by its caller.
                return status == 429 ? .rejected : .uncertain
            case .rateLimited, .rejected: return .rejected
            default: return .notSent
            }
        }
    }

    var phase: CodexResetNoticeDeliveryPhase {
        switch self {
        case .accepted: return .sent
        case .notSent, .rejected: return .pending
        case .uncertain: return .uncertain
        }
    }
}

struct CodexResetNoticeDelivery: Equatable {
    let channel: CodexResetNoticeChannel
    let candidate: CodexResetNoticeCandidate

    var keys: [String] {
        candidate.items.map { CodexResetNoticeKey.item($0, accountHash: candidate.accountHash, channel: channel) }
    }
    var batchKey: String { CodexResetNoticeKey.batch(candidate, channel: channel) }
}

struct CodexResetNoticeReservation: Equatable {
    let delivery: CodexResetNoticeDelivery
    let attemptID: UUID
    let revision: UUID
    let reservedAt: Date
}

struct CodexResetNoticeDeliveryLedger: Codable, Equatable {
    struct Record: Codable, Equatable {
        let accountHash: String
        let channel: CodexResetNoticeChannel
        let item: CodexResetNoticeCandidate.Content
        var phase: CodexResetNoticeDeliveryPhase
        var observedAt: Date
        var updatedAt: Date
        var attemptID: UUID?
        var revision: UUID?
        var receipt: CodexResetNoticeDeliveryReceipt?

        var isValid: Bool {
            let candidate = CodexResetNoticeCandidate(accountHash: accountHash, observedAt: observedAt, content: item)
            let attemptIsValid =
                phase == .baseline || phase == .pending
                ? attemptID == nil && revision == nil : attemptID != nil && revision != nil
            return candidate.isValid && candidate.items.count == 1
                && updatedAt.timeIntervalSinceReferenceDate.isFinite && attemptIsValid
                && (receipt == nil || receipt?.phase == phase)
        }
    }

    var schemaVersion = 1
    var accounts: [String: CodexResetNoticeObservation] = [:]
    var records: [String: Record] = [:]

    var isValid: Bool {
        schemaVersion == 1 && accounts.count <= CodexResetNoticeDeliveryStore.maximumAccounts
            && records.count <= CodexResetNoticeDeliveryStore.maximumRecords
            && accounts.allSatisfy { $0.key == $0.value.accountHash && $0.value.isValid }
            && records.allSatisfy { key, record in
                record.isValid && key == CodexResetNoticeKey.item(record.item, accountHash: record.accountHash, channel: record.channel)
            }
    }
}

/// No timers, credentials, transports or redemption calls are owned here.
/// Each mutation rereads the ledger under an exclusive cross-process lock.
struct CodexResetNoticeDeliveryStore {
    enum Failure: Error { case invalidState, unavailable, busy, capacity }
    static let stateName = "codex-reset-notices-v1.json"
    static let maximumAccounts = 512
    static let maximumRecords = 16_384
    private static let maximumBytes = 8 * 1_024 * 1_024
    let url: URL
    let maximumObservationAge: TimeInterval
    var directory: URL { url.deletingLastPathComponent() }

    init(directory: URL, maximumObservationAge: TimeInterval = CodexResetNoticeEvaluator.maximumObservationAge) {
        self.init(url: directory.appendingPathComponent(Self.stateName), maximumObservationAge: maximumObservationAge)
    }

    init(url: URL, maximumObservationAge: TimeInterval = CodexResetNoticeEvaluator.maximumObservationAge) {
        self.url = url
        self.maximumObservationAge = maximumObservationAge
    }

    func read() throws -> CodexResetNoticeDeliveryLedger {
        try locked { try readUnlocked() }
    }

    /// Safe to repeat with the same successful observation as the clock crosses
    /// the threshold. Stale, failed and incomplete observations never infer IDs.
    func observe(
        _ observation: CodexResetNoticeObservation, channels: [CodexResetNoticeChannel], now: Date = Date()
    ) throws -> [CodexResetNoticeDelivery] {
        try mutate { ledger in
            guard CodexResetNoticeKey.validHash(observation.accountHash),
                observation.observedAt.timeIntervalSinceReferenceDate.isFinite,
                observation.observedAt <= now
            else { throw Failure.invalidState }
            var current = observation.isValid ? observation.canonical : observation.invalidated
            if let previous = ledger.accounts[current.accountHash] {
                guard current.observedAt >= previous.observedAt else { return [] }
                if current.observedAt == previous.observedAt && current != previous {
                    // Conflicting equal-time mirrors have no order proof. A
                    // strictly newer successful observation is needed to recover.
                    current = current.invalidated
                }
            }
            ledger.accounts[current.accountHash] = current
            let evaluation = evaluate(current, now: now)
            guard evaluation.verificationSucceeded else { return [] }
            let eligible = Set(evaluation.eligibleCards)
            var deliveries: [CodexResetNoticeDelivery] = []
            for channel in Set(channels).sorted(by: { $0.rawValue < $1.rawValue }) {
                for card in current.cards ?? [] {
                    guard let expiry = card.expiresAt else { continue }
                    let item = CodexResetNoticeCandidate.Content.expiry(cards: [card])
                    let key = CodexResetNoticeKey.expiry(
                        accountHash: current.accountHash,
                        cardHash: card.cardHash, expiresAt: expiry, channel: channel)
                    if var record = ledger.records[key] {
                        if record.phase == .baseline && eligible.contains(card) {
                            record.phase = .pending
                            record.updatedAt = now
                        }
                        if record.phase == .baseline || record.phase == .pending { record.observedAt = current.observedAt }
                        ledger.records[key] = record
                    } else if expiry > now {
                        ledger.records[key] = .init(
                            accountHash: current.accountHash, channel: channel,
                            item: item, phase: eligible.contains(card) ? .pending : .baseline,
                            observedAt: current.observedAt, updatedAt: now)
                    }
                }
                let pending = evaluation.eligibleCards.filter { card in
                    let key = CodexResetNoticeKey.expiry(
                        accountHash: current.accountHash,
                        cardHash: card.cardHash, expiresAt: card.expiresAt!, channel: channel)
                    return ledger.records[key]?.phase == .pending
                }
                if !pending.isEmpty {
                    deliveries.append(
                        .init(
                            channel: channel,
                            candidate: .init(
                                accountHash: current.accountHash,
                                observedAt: current.observedAt, content: .expiry(cards: pending))))
                }
            }
            return deliveries
        }
    }

    /// Trusted persisted change receipts share the same per-channel ledger.
    /// Reserve still requires a fresh successful observation with the same end count.
    func enqueueChange(
        accountHash: String, previous: Int, available: Int,
        previousObservedAt: Date, observedAt: Date,
        channels: [CodexResetNoticeChannel], createIfMissing: Bool = true, now: Date = Date()
    ) throws -> [CodexResetNoticeDelivery] {
        let change = CodexResetNoticeChange(
            previous: previous, available: available,
            previousObservedAt: previousObservedAt, observedAt: observedAt)
        let candidate = CodexResetNoticeCandidate(accountHash: accountHash, observedAt: observedAt, content: .change(change))
        guard candidate.isValid else { throw Failure.invalidState }
        return try mutate { ledger in
            guard current(candidate, ledger: ledger, now: now) else { return [] }
            let sentWatermarks = sentChangeWatermarks(in: ledger)
            var deliveries: [CodexResetNoticeDelivery] = []
            for channel in Set(channels).sorted(by: { $0.rawValue < $1.rawValue }) {
                let key = CodexResetNoticeKey.item(candidate.content, accountHash: accountHash, channel: channel)
                if ledger.records[key] == nil && createIfMissing {
                    // The newest accepted change remains as durable replay
                    // evidence after older accepted records are compacted.
                    if let watermark = sentWatermarks[historyKey(accountHash, channel)], observedAt <= watermark { continue }
                    ledger.records[key] = .init(
                        accountHash: accountHash, channel: channel,
                        item: candidate.content, phase: .pending, observedAt: observedAt, updatedAt: now)
                }
                if ledger.records[key]?.phase == .pending { deliveries.append(.init(channel: channel, candidate: candidate)) }
            }
            return deliveries
        }
    }

    /// Persist consumption confirmation separately from transport outcome. A
    /// disabled channel records a baseline and never acquires historical intent.
    func enqueueManualReset(
        accountHash: String, manual: CodexManualResetNotice, notifyFeishu: Bool, now: Date = Date()
    ) throws -> [CodexResetNoticeDelivery] {
        let candidate = CodexResetNoticeCandidate(accountHash: accountHash, observedAt: manual.confirmedAt, content: .manualReset(manual))
        guard candidate.isValid, manual.confirmedAt <= now else { throw Failure.invalidState }
        return try mutate { ledger in
            for record in ledger.records.values {
                if case .manualReset(let existing) = record.item, existing.eventHash == manual.eventHash {
                    guard record.accountHash == accountHash && existing.profileHash == manual.profileHash else { throw Failure.invalidState }
                }
            }
            let key = CodexResetNoticeKey.item(candidate.content, accountHash: accountHash, channel: .feishu)
            if ledger.records[key] == nil {
                ledger.records[key] = .init(
                    accountHash: accountHash, channel: .feishu, item: candidate.content,
                    phase: notifyFeishu ? .pending : .baseline, observedAt: manual.confirmedAt, updatedAt: now)
            }
            guard let record = ledger.records[key], record.phase == .pending else { return [] }
            // A repeated callback cannot replace the original confirmed time.
            return [.init(channel: .feishu, candidate: .init(accountHash: record.accountHash, observedAt: record.observedAt, content: record.item))]
        }
    }

    func pendingManualResets() throws -> [CodexResetNoticeDelivery] {
        try locked {
            let ledger = try readUnlocked()
            return ledger.records.values.compactMap { record in
                guard record.channel == .feishu, record.phase == .pending, case .manualReset = record.item else { return nil }
                return .init(channel: .feishu, candidate: .init(accountHash: record.accountHash, observedAt: record.observedAt, content: record.item))
            }.sorted { $0.candidate.observedAt < $1.candidate.observedAt }
        }
    }

    /// Suppress only the duplicate one-card change notice around exactly one
    /// confirmed consume. Expiry, multiple consumes and ambiguous intervals keep
    /// the original honest balance-change reporting.
    func hasSingleManualReset(accountHash: String, previous: Int, available: Int, after: Date, through: Date) throws -> Bool {
        guard (0...1_000_000).contains(previous), (0...1_000_000).contains(available), previous - available == 1, after < through else { return false }
        return try locked {
            let ledger = try readUnlocked()
            let matches = ledger.records.values.filter { record in
                guard record.accountHash == accountHash, case .manualReset(let manual) = record.item else { return false }
                return manual.confirmedAt > after && manual.confirmedAt <= through
            }
            return matches.count == 1
        }
    }

    /// Must run before invoking an existing sender. The caller retains its
    /// credential/configuration revision and admission gates at the send boundary.
    func reserve(
        _ delivery: CodexResetNoticeDelivery, revision: UUID, now: Date = Date()
    ) throws -> CodexResetNoticeReservation? {
        guard delivery.candidate.isValid else { throw Failure.invalidState }
        return try mutate { ledger in
            guard current(delivery.candidate, ledger: ledger, now: now),
                delivery.keys.allSatisfy({ ledger.records[$0]?.phase == .pending })
            else { return nil }
            let reservation = CodexResetNoticeReservation(
                delivery: delivery,
                attemptID: UUID(), revision: revision, reservedAt: now)
            for key in delivery.keys {
                ledger.records[key]!.phase = .sending
                ledger.records[key]!.attemptID = reservation.attemptID
                ledger.records[key]!.revision = revision
                ledger.records[key]!.receipt = nil
                ledger.records[key]!.updatedAt = now
            }
            return reservation
        }
    }

    /// Recheck at the existing transport admission boundary after any async
    /// credential load. A reserve is not permission to use superseded facts.
    func isCurrent(_ reservation: CodexResetNoticeReservation, now: Date = Date()) throws -> Bool {
        guard reservation.delivery.candidate.isValid else { throw Failure.invalidState }
        return try locked {
            let ledger = try readUnlocked()
            return current(reservation.delivery.candidate, ledger: ledger, now: now)
                && reservation.delivery.keys.allSatisfy { key in
                    guard let record = ledger.records[key] else { return false }
                    return record.phase == .sending && record.attemptID == reservation.attemptID
                        && record.revision == reservation.revision
                }
        }
    }

    /// A callback from a disabled/rebound connection cannot update a new revision.
    /// Failed receipt persistence leaves durable sending, recovered as uncertain.
    @discardableResult
    func record(
        _ reservation: CodexResetNoticeReservation, receipt: CodexResetNoticeDeliveryReceipt,
        currentRevision: UUID, now: Date = Date()
    ) throws -> Bool {
        guard currentRevision == reservation.revision else { return false }
        guard reservation.delivery.candidate.isValid else { throw Failure.invalidState }
        return try mutate { ledger in
            let keys = reservation.delivery.keys
            guard
                keys.allSatisfy({ key in
                    guard let record = ledger.records[key] else { return false }
                    return record.phase == .sending && record.attemptID == reservation.attemptID && record.revision == reservation.revision
                })
            else { return false }
            for key in keys {
                ledger.records[key]!.phase = receipt.phase
                ledger.records[key]!.receipt = receipt
                ledger.records[key]!.updatedAt = now
                if receipt.phase == .pending {
                    ledger.records[key]!.attemptID = nil
                    ledger.records[key]!.revision = nil
                }
            }
            return true
        }
    }

    /// Call only before entering a sender, with proof that no transport was
    /// invoked. This releases its own reservation after an admission revocation;
    /// it never treats an old connection revision as the current one.
    @discardableResult
    func releaseUnsent(_ reservation: CodexResetNoticeReservation, now: Date = Date()) throws -> Bool {
        guard reservation.delivery.candidate.isValid else { throw Failure.invalidState }
        return try mutate { ledger in
            let keys = reservation.delivery.keys
            guard
                keys.allSatisfy({ key in
                    guard let record = ledger.records[key] else { return false }
                    return record.phase == .sending && record.attemptID == reservation.attemptID
                        && record.revision == reservation.revision
                })
            else { return false }
            for key in keys {
                ledger.records[key]!.phase = .pending
                ledger.records[key]!.attemptID = nil
                ledger.records[key]!.revision = nil
                ledger.records[key]!.receipt = .notSent
                ledger.records[key]!.updatedAt = now
            }
            return true
        }
    }

    /// A revoked connection may conservatively close only its own in-flight
    /// attempt. It cannot accept an old callback or affect a later reservation.
    @discardableResult
    func markUncertain(_ reservation: CodexResetNoticeReservation, now: Date = Date()) throws -> Bool {
        guard reservation.delivery.candidate.isValid else { throw Failure.invalidState }
        return try mutate { ledger in
            let keys = reservation.delivery.keys
            guard
                keys.allSatisfy({ key in
                    guard let record = ledger.records[key] else { return false }
                    return record.phase == .sending && record.attemptID == reservation.attemptID
                        && record.revision == reservation.revision
                })
            else { return false }
            for key in keys {
                ledger.records[key]!.phase = .uncertain
                ledger.records[key]!.receipt = .uncertain
                ledger.records[key]!.updatedAt = now
            }
            return true
        }
    }

    /// Call once at app startup after owning the delivery scheduler, never while
    /// another live sender owns these reservations. Uncertain is not replayable.
    func recoverInterruptedSends(now: Date = Date()) throws {
        try mutate { ledger in
            for key in ledger.records.keys where ledger.records[key]?.phase == .sending {
                ledger.records[key]!.phase = .uncertain
                ledger.records[key]!.receipt = .uncertain
                ledger.records[key]!.updatedAt = now
            }
        }
    }

    private func evaluate(_ observation: CodexResetNoticeObservation, now: Date) -> CodexResetNoticeEvaluator.Evaluation {
        CodexResetNoticeEvaluator.evaluate(observation, now: now, maximumObservationAge: maximumObservationAge)
    }

    private func current(_ candidate: CodexResetNoticeCandidate, ledger: CodexResetNoticeDeliveryLedger, now: Date) -> Bool {
        if case .manualReset(let manual) = candidate.content {
            let key = CodexResetNoticeKey.item(candidate.content, accountHash: candidate.accountHash, channel: .feishu)
            return candidate.isValid && manual.confirmedAt <= now && ledger.records[key]?.item == candidate.content
                && ledger.records[key]?.accountHash == candidate.accountHash && ledger.records[key]?.observedAt == candidate.observedAt
        }
        guard let observation = ledger.accounts[candidate.accountHash] else { return false }
        let evaluation = evaluate(observation, now: now)
        guard evaluation.verificationSucceeded else { return false }
        switch candidate.content {
        case .expiry(let cards):
            return observation.observedAt == candidate.observedAt
                && Set(cards).isSubset(of: Set(evaluation.eligibleCards))
        case .change(let change):
            return observation.observedAt >= change.observedAt && observation.availableCount == change.available
        case .manualReset: return false  // Handled above without quota inference.
        }
    }

    private func mutate<T>(_ body: (inout CodexResetNoticeDeliveryLedger) throws -> T) throws -> T {
        guard maximumObservationAge.isFinite && maximumObservationAge > 0 && maximumObservationAge <= 1_800 else { throw Failure.invalidState }
        return try locked {
            var ledger = try readUnlocked()
            let before = ledger
            let result = try body(&ledger)
            pruneCompletedRecords(in: &ledger)
            guard ledger.accounts.count <= Self.maximumAccounts, ledger.records.count <= Self.maximumRecords else { throw Failure.capacity }
            guard ledger.isValid else { throw Failure.invalidState }
            if ledger != before { try writeUnlocked(ledger) }
            return result
        }
    }

    private func historyKey(_ accountHash: String, _ channel: CodexResetNoticeChannel) -> String {
        accountHash + ":" + channel.rawValue
    }

    private func sentChangeWatermarks(in ledger: CodexResetNoticeDeliveryLedger) -> [String: Date] {
        var watermarks: [String: Date] = [:]
        for record in ledger.records.values where record.phase == .sent {
            guard case .change = record.item else { continue }
            let key = historyKey(record.accountHash, record.channel)
            watermarks[key] = max(watermarks[key] ?? record.observedAt, record.observedAt)
        }
        return watermarks
    }

    private func pruneCompletedRecords(in ledger: inout CodexResetNoticeDeliveryLedger) {
        let watermarks = sentChangeWatermarks(in: ledger)
        ledger.records = ledger.records.filter { _, record in
            // Unsent, in-flight and uncertain outcomes keep their full evidence.
            guard record.phase == .baseline || record.phase == .sent else { return true }
            switch record.item {
            case .expiry(let cards):
                // A durable observation past expiry prevents a rolled-back clock
                // or stale response from recreating a previously accepted notice.
                guard let observedAt = ledger.accounts[record.accountHash]?.observedAt else { return true }
                return !cards.allSatisfy { $0.expiresAt.map { $0 <= observedAt } == true }
            case .manualReset:
                return true  // Retain consumption and idempotency proof independent of send outcome.
            case .change:
                guard record.phase == .sent, let watermark = watermarks[historyKey(record.accountHash, record.channel)] else { return true }
                return record.observedAt >= watermark
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw Failure.unavailable }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw Failure.unavailable }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.unavailable }
        let fd = Darwin.open(
            directory.appendingPathComponent(".codex-reset-notices.lock").path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0
        else { throw Failure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK || errno == EAGAIN ? Failure.busy : Failure.unavailable
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func readUnlocked() throws -> CodexResetNoticeDeliveryLedger {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw Failure.unavailable }
            return .init()
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
            info.st_size >= 0, info.st_size <= Self.maximumBytes
        else { throw Failure.invalidState }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unavailable }
            if count == 0 { break }
            guard data.count + count <= Self.maximumBytes else { throw Failure.invalidState }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == info.st_size else { throw Failure.invalidState }
        let ledger: CodexResetNoticeDeliveryLedger
        do { ledger = try JSONDecoder().decode(CodexResetNoticeDeliveryLedger.self, from: data) } catch { throw Failure.invalidState }
        guard ledger.isValid else { throw Failure.invalidState }
        return ledger
    }

    private func writeUnlocked(_ ledger: CodexResetNoticeDeliveryLedger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ledger)
        guard data.count <= Self.maximumBytes else { throw Failure.capacity }
        let temporary = directory.appendingPathComponent(".codex-reset-notices-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: temporary)
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw Failure.unavailable }
            offset += written
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw Failure.unavailable }
    }
}
