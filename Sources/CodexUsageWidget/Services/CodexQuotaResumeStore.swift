import Combine
import Darwin
import Foundation

/// An at-most-once journal for continuing turns after a confirmed account switch.
/// It never opens a daemon connection or starts a turn without an explicit call to resume.
@MainActor
final class CodexQuotaResumeStore: ObservableObject {
    @Published private(set) var pending: [CodexPausedDesktopTurn] = []
    @Published private(set) var isResuming = false
    @Published private(set) var message: String?

    var expectedAccountKey: String? { journal?.targetAccountKey }
    var isReady: Bool { journal?.ready == true && !pending.isEmpty }
    var oneShotQuotaPolicy: CodexOneShotSwitchIntent.QuotaPolicy? { journal?.oneShotQuotaPolicy }

    /// Also guards an idle switch, which has no active turns to pass through
    /// stage(_:). Read the current journal under the same lock as mutations.
    func canBeginAutomaticSwitch() -> Bool {
        guard !previewOnly, !isResuming else { return false }
        do {
            return try Self.withLock(at: privateDirectory) {
                let current = try Self.readJournal(at: privateDirectory)
                return current?.entries.allSatisfy { $0.status != .awaiting } ?? true
            }
        } catch { return false }
    }

    private enum EntryStatus: String, Codable {
        case awaiting, attempted, submitted, uncertain, skipped
    }

    private struct Entry: Codable {
        let turn: CodexPausedDesktopTurn
        let batchID: String
        var status: EntryStatus
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        var targetAccountKey: String
        var batchID: String
        var ready: Bool
        var oneShotQuotaPolicy: CodexOneShotSwitchIntent.QuotaPolicy?
        var entries: [Entry]
    }

    private enum StorageError: Error { case invalid, unavailable }

    private static let directoryName = "quota-resume"
    private static let journalName = "desktop-turns-v1.json"
    private static let lockName = ".desktop-turns.lock"
    private static let maximumBytes = 128 * 1024
    private static let maximumEntries = 512
    private static var followup: String {
        WidgetLanguage.storedOrAutomatic().text(
            "继续刚才暂停的任务；先核对已有成果，避免重复执行已完成的操作。",
            "Continue the task that was just interrupted. First check what has already been done, and avoid repeating completed actions.")
    }

    private let supportDirectory: URL
    private let previewOnly: Bool
    private var journal: Journal?

    convenience init(previewOnly: Bool = false) {
        self.init(supportDirectory: DispatchParticipationPaths.supportDirectory(), previewOnly: previewOnly)
    }

    /// An isolated support root lets the self-test exercise persistence without
    /// reading or changing the user's Desktop task state.
    init(supportDirectory: URL, previewOnly: Bool = false) {
        self.supportDirectory = supportDirectory
        self.previewOnly = previewOnly
        guard !previewOnly else { return }
        do {
            journal = try Self.readJournal(at: privateDirectory)
            refreshPublishedState()
        } catch {
            message = WidgetLanguage.storedOrAutomatic().text(
                "续做记录不可用；不会自动继续任务。", "The resume record is unavailable. No task will continue automatically.")
        }
    }

    /// Persist the exact turn IDs before the caller sends any interrupt request.
    /// A previous unresolved batch is never replaced silently.
    @discardableResult
    func stage(
        _ turns: [CodexPausedDesktopTurn], targetAccountKey: String,
        oneShotQuotaPolicy: CodexOneShotSwitchIntent.QuotaPolicy? = nil
    ) -> Bool {
        guard !previewOnly, !isResuming, Self.validAccountKey(targetAccountKey), !turns.isEmpty,
            turns.count <= 128, turns.allSatisfy(\.isValid),
            Set(turns.map(\.id)).count == turns.count
        else {
            message = WidgetLanguage.storedOrAutomatic().text(
                "暂停清单无效；没有中断任何任务。", "The pause list is invalid. No task was interrupted.")
            return false
        }
        return mutate { state in
            if let prior = state {
                guard !prior.entries.contains(where: { $0.batchID == prior.batchID && $0.status == .awaiting }),
                    prior.entries.count + turns.count <= Self.maximumEntries,
                    Set(prior.entries.map { $0.turn.id }).isDisjoint(with: turns.map(\.id))
                else { return false }
            }
            let batchID = UUID().uuidString.lowercased()
            let oldEntries = state?.entries ?? []
            state = Journal(
                schemaVersion: 1, targetAccountKey: targetAccountKey,
                batchID: batchID, ready: false, oneShotQuotaPolicy: oneShotQuotaPolicy,
                entries: oldEntries + turns.map { Entry(turn: $0, batchID: batchID, status: .awaiting) })
            return true
        }
    }

    /// Only the owner of a confirmed target identity should call this method.
    func markSwitchSucceeded(accountKey: String) {
        guard Self.validAccountKey(accountKey), accountKey == expectedAccountKey else {
            message = WidgetLanguage.storedOrAutomatic().text(
                "目标账号未核实；续做请求未发送。", "The target account was not verified. No resume request was sent.")
            return
        }
        _ = mutate { state in
            guard var current = state, current.targetAccountKey == accountKey,
                current.entries.contains(where: { $0.batchID == current.batchID && $0.status == .awaiting })
            else { return false }
            current.ready = true
            state = current
            return true
        }
    }

    /// Explicitly closes an abandoned plan. Never call this merely because a
    /// pause partially failed: its interrupted turns may still need recovery.
    func abandonStaged() {
        guard !isResuming else { return }
        _ = mutate { state in
            guard var current = state,
                current.entries.contains(where: { $0.batchID == current.batchID && $0.status == .awaiting })
            else { return false }
            for index in current.entries.indices
            where current.entries[index].batchID == current.batchID
                && current.entries[index].status == .awaiting
            {
                current.entries[index].status = .skipped
            }
            current.ready = false
            state = current
            return true
        }
    }

    func resume(
        client: CodexAppServerTaskClient,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async {
        await resume(
            request: { method, params in
                await client.desktopResumeRequest(method, params: params)
            }, shouldContinue: shouldContinue)
    }

    /// Injectable protocol boundary used solely by local simulations.
    func resume(
        request: @escaping @MainActor (String, [String: Any]) async -> [String: Any]?,
        beforeStart: @escaping @MainActor ([String: String]) async -> Bool = { _ in true },
        shouldContinue: @escaping @MainActor () -> Bool
    ) async {
        guard !isResuming, isReady else { return }
        isResuming = true
        defer { isResuming = false }
        let expectedKey = expectedAccountKey
        var submitted = 0
        var skipped = 0
        var startedTurns: [String: String] = [:]
        for turn in pending {
            func allowed() -> Bool {
                !Task.isCancelled && isReady && expectedAccountKey == expectedKey && shouldContinue()
            }
            guard allowed() else {
                message = WidgetLanguage.storedOrAutomatic().text(
                    "账号或任务状态发生变化；续做已停止。", "The account or task state changed. Resuming stopped.")
                return
            }
            guard let firstRead = await request("thread/read", ["threadId": turn.threadID, "includeTurns": false]),
                Self.isIdleOrNotLoaded(firstRead, threadID: turn.threadID), allowed(),
                let firstTurns = await request("thread/turns/list", Self.turnListParams(turn.threadID)),
                let firstState = Self.latestTurnState(firstTurns, turnID: turn.turnID), allowed()
            else {
                message = WidgetLanguage.storedOrAutomatic().text(
                    "任务状态未能确认；续做请求未发送。", "The task state could not be verified. No resume request was sent.")
                return
            }
            if firstState == .alreadyContinued {
                guard update(turn, to: .skipped) else { return }
                skipped += 1
                continue
            }
            guard firstState == .interrupted,
                let resumed = await request("thread/resume", ["threadId": turn.threadID]),
                Self.threadID(in: resumed) == turn.threadID, allowed(),
                let secondRead = await request("thread/read", ["threadId": turn.threadID, "includeTurns": false]),
                Self.isIdle(secondRead, threadID: turn.threadID), allowed(),
                let secondTurns = await request("thread/turns/list", Self.turnListParams(turn.threadID)),
                let secondState = Self.latestTurnState(secondTurns, turnID: turn.turnID), allowed()
            else {
                message = WidgetLanguage.storedOrAutomatic().text(
                    "任务状态未能确认；续做请求未发送。", "The task state could not be verified. No resume request was sent.")
                return
            }
            if secondState == .alreadyContinued {
                guard update(turn, to: .skipped) else { return }
                skipped += 1
                continue
            }
            guard secondState == .interrupted else {
                message = WidgetLanguage.storedOrAutomatic().text(
                    "任务已变化；续做请求未发送。", "The task changed. No resume request was sent.")
                return
            }
            // This durable transition is the one-way boundary. A crash or timeout
            // after it cannot cause a second turn/start for the same turn ID.
            guard await beforeStart(startedTurns), allowed(),
                let finalRead = await request("thread/read", ["threadId": turn.threadID, "includeTurns": false]),
                Self.isIdle(finalRead, threadID: turn.threadID), allowed(),
                let finalTurns = await request("thread/turns/list", Self.turnListParams(turn.threadID)),
                Self.latestTurnState(finalTurns, turnID: turn.turnID) == .interrupted, allowed()
            else {
                message = WidgetLanguage.storedOrAutomatic().text(
                    "续做前任务状态已变化；没有提交新请求。", "Task state changed before continuation. No new request was sent.")
                return
            }
            guard update(turn, to: .attempted), !Task.isCancelled,
                expectedAccountKey == expectedKey, shouldContinue()
            else {
                message = WidgetLanguage.storedOrAutomatic().text(
                    "续做尝试无法安全记录；请求未发送。", "The resume attempt could not be recorded safely. No request was sent.")
                return
            }
            let result = await request(
                "turn/start",
                [
                    "threadId": turn.threadID,
                    "input": [["type": "text", "text": Self.followup, "text_elements": []]],
                ])
            if let startedID = Self.startedTurnID(result), startedID != turn.turnID {
                guard update(turn, to: .submitted) else { return }
                startedTurns[turn.threadID] = startedID
                submitted += 1
            } else {
                _ = update(turn, to: .uncertain)
                message = WidgetLanguage.storedOrAutomatic().text(
                    "续做结果未确认；该任务不会自动重试。", "The resume result is uncertain. This task will not retry automatically.")
                return
            }
        }
        message = WidgetLanguage.storedOrAutomatic().text(
            "已提交 \(submitted) 个任务的续做请求，跳过 \(skipped) 个已变化任务。",
            "Submitted resume requests for \(submitted) tasks; skipped \(skipped) tasks that already changed.")
    }

    private static func turnListParams(_ threadID: String) -> [String: Any] {
        ["threadId": threadID, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"]
    }

    private static func threadID(in response: [String: Any]) -> String? {
        (response["thread"] as? [String: Any])?["id"] as? String
    }

    private static func status(_ response: [String: Any], threadID: String) -> String? {
        guard self.threadID(in: response) == threadID,
            let thread = response["thread"] as? [String: Any],
            let status = thread["status"] as? [String: Any]
        else { return nil }
        return status["type"] as? String
    }

    private static func isIdleOrNotLoaded(_ response: [String: Any], threadID: String) -> Bool {
        guard let value = status(response, threadID: threadID) else { return false }
        return value == "idle" || value == "notLoaded"
    }

    private static func isIdle(_ response: [String: Any], threadID: String) -> Bool {
        status(response, threadID: threadID) == "idle"
    }

    private enum LatestTurnState { case interrupted, alreadyContinued, active, unknown }

    private static func latestTurnState(_ response: [String: Any], turnID: String) -> LatestTurnState? {
        guard let rows = response["data"] as? [[String: Any]], rows.count == 1,
            let first = rows.first, let latestID = first["id"] as? String,
            CodexPausedDesktopTurn(threadID: "thread", turnID: latestID).isValid,
            let status = first["status"] as? String
        else { return nil }
        if latestID != turnID {
            switch status {
            case "completed", "interrupted": return .alreadyContinued
            case "inProgress": return .active
            default: return .unknown
            }
        }
        switch status {
        case "interrupted": return .interrupted
        case "completed": return .alreadyContinued
        case "inProgress": return .active
        default: return .unknown
        }
    }

    private static func startedTurnID(_ response: [String: Any]?) -> String? {
        guard let response, let turn = response["turn"] as? [String: Any],
            let id = turn["id"] as? String,
            CodexPausedDesktopTurn(threadID: "thread", turnID: id).isValid
        else { return nil }
        return id
    }

    private func update(_ turn: CodexPausedDesktopTurn, to status: EntryStatus) -> Bool {
        mutate { state in
            guard var current = state, current.ready,
                let index = current.entries.firstIndex(where: { $0.batchID == current.batchID && $0.turn == turn }),
                (current.entries[index].status == .awaiting && (status == .attempted || status == .skipped))
                    || (current.entries[index].status == .attempted && (status == .submitted || status == .uncertain))
            else { return false }
            current.entries[index].status = status
            state = current
            return true
        }
    }

    private func mutate(_ action: (inout Journal?) -> Bool) -> Bool {
        guard !previewOnly else { return false }
        do {
            let next = try Self.withLock(at: privateDirectory) { () throws -> Journal in
                var current = try Self.readJournal(at: privateDirectory)
                guard action(&current), let current else { throw StorageError.invalid }
                try Self.writeJournal(current, at: privateDirectory)
                return current
            }
            journal = next
            refreshPublishedState()
            message = nil
            return true
        } catch {
            message = WidgetLanguage.storedOrAutomatic().text(
                "续做记录未保存；没有发送新请求。", "The resume record was not saved. No new request was sent.")
            return false
        }
    }

    private func refreshPublishedState() {
        guard let journal else {
            pending = []
            return
        }
        pending = journal.entries.filter { $0.batchID == journal.batchID && $0.status == .awaiting }.map(\.turn)
    }

    private var privateDirectory: URL {
        supportDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private static func validAccountKey(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.utf8.count == 64
            && digest.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func validate(_ value: Journal) throws {
        guard value.schemaVersion == 1, validAccountKey(value.targetAccountKey),
            UUID(uuidString: value.batchID) != nil, value.entries.count <= maximumEntries,
            Set(value.entries.map { $0.turn.id }).count == value.entries.count,
            value.entries.allSatisfy({ $0.turn.isValid && UUID(uuidString: $0.batchID) != nil }),
            value.entries.contains(where: { $0.batchID == value.batchID })
        else { throw StorageError.invalid }
    }

    private static func checkDirectory(_ path: String, privateOnly: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & (privateOnly ? 0o077 : 0o022) == 0
        else { throw StorageError.unavailable }
    }

    private static func ensureDirectory(at url: URL) throws {
        let root = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try checkDirectory(root.path, privateOnly: false)
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw StorageError.unavailable }
        try checkDirectory(url.path, privateOnly: true)
    }

    private static func readJournal(at directory: URL) throws -> Journal? {
        var info = stat()
        let root = directory.deletingLastPathComponent()
        if lstat(root.path, &info) == 0 {
            try checkDirectory(root.path, privateOnly: false)
        } else if errno != ENOENT {
            throw StorageError.unavailable
        }
        if lstat(directory.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw StorageError.unavailable
        }
        try checkDirectory(directory.path, privateOnly: true)
        let url = directory.appendingPathComponent(journalName)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw StorageError.unavailable
        }
        defer { Darwin.close(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1,
            info.st_mode & 0o077 == 0, info.st_size > 0,
            info.st_size <= maximumBytes
        else { throw StorageError.invalid }
        var data = Data(count: Int(info.st_size))
        let totalCount = data.count
        var offset = 0
        while offset < totalCount {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), totalCount - offset)
            }
            guard count > 0 else { throw StorageError.unavailable }
            offset += count
        }
        let value = try JSONDecoder().decode(Journal.self, from: data)
        try validate(value)
        return value
    }

    private static func writeJournal(_ value: Journal, at directory: URL) throws {
        try validate(value)
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw StorageError.invalid }
        let temporary = directory.appendingPathComponent(".desktop-turns-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StorageError.unavailable }
        defer {
            Darwin.close(descriptor)
            unlink(temporary.path)
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else { throw StorageError.unavailable }
            offset += written
        }
        guard fsync(descriptor) == 0 else { throw StorageError.unavailable }
        // Reject a planted link or unsafe file before atomic replacement.
        _ = try readJournal(at: directory)
        guard rename(temporary.path, directory.appendingPathComponent(journalName).path) == 0
        else { throw StorageError.unavailable }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw StorageError.unavailable }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw StorageError.unavailable }
    }

    private static func withLock<T>(at directory: URL, _ action: () throws -> T) throws -> T {
        try ensureDirectory(at: directory)
        let lockURL = directory.appendingPathComponent(lockName)
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StorageError.unavailable }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else { throw StorageError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
}
