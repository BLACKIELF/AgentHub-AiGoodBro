import CryptoKit
import Darwin
import Foundation

/// An at-most-once journal for the paired user's bot messages. Only hashed
/// message IDs and delivery metadata are stored, never text or credentials.
final class WeChatBotEventLedger {
    enum Phase: String, Codable { case received, submitted, replyAttempted, accepted, uncertain }
    enum Failure: Error { case unavailable, invalid, capacity }
    struct Entry: Codable, Equatable {
        let id: UUID
        let receivedAt: Date
        var phase: Phase
        var threadID: String?
        var turnID: String?
    }
    private let directory: URL
    private static let filename = "events-v1.json"
    private static let maximumEntries = 512
    private static let maximumBytes = 128 * 1024

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexAccountManagerNext/PersonalWeChat", isDirectory: true)
    ) {
        self.directory = directory.standardizedFileURL
    }

    static func eventID(owner: String, messageID: String) -> UUID {
        let digest = SHA256.hash(data: Data(("AiGoodBro-WeChat-v1\u{0}" + owner + "\u{0}" + messageID).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// A durable claim precedes any Codex instruction or bot response. Existing
    /// claims, including interrupted/uncertain attempts, are never replayed.
    func claim(owner: String, messageID: String, receivedAt: Date, now: Date = Date()) throws -> UUID? {
        let age = now.timeIntervalSince(receivedAt)
        guard !owner.isEmpty, owner.utf8.count <= 1024, !messageID.isEmpty, messageID.utf8.count <= 256,
            age.isFinite, age >= -5, age <= 120
        else { throw Failure.invalid }
        let id = Self.eventID(owner: owner, messageID: messageID)
        return try locked {
            var entries = try read().filter { now.timeIntervalSince($0.receivedAt) < 7 * 24 * 3600 }
            if entries.contains(where: { $0.id == id }) { return nil }
            guard entries.count < Self.maximumEntries else { throw Failure.capacity }
            entries.append(Entry(id: id, receivedAt: receivedAt, phase: .received))
            try write(entries)
            return id
        }
    }

    func mark(_ id: UUID, phase: Phase, threadID: String? = nil, turnID: String? = nil) throws {
        try locked {
            var entries = try read()
            guard let index = entries.firstIndex(where: { $0.id == id }) else { throw Failure.invalid }
            let old = entries[index]
            let permitted: Bool
            switch (old.phase, phase) {
            case (.received, .submitted), (.received, .replyAttempted), (.received, .uncertain),
                (.submitted, .replyAttempted), (.submitted, .uncertain),
                (.replyAttempted, .accepted), (.replyAttempted, .uncertain),
                (.uncertain, .replyAttempted):
                permitted = true
            default: permitted = false
            }
            guard permitted,
                threadID.map({ UUID(uuidString: $0) != nil }) ?? true,
                turnID.map({ UUID(uuidString: $0) != nil }) ?? true,
                old.threadID == nil || threadID == nil || old.threadID == threadID,
                old.turnID == nil || turnID == nil || old.turnID == turnID
            else { throw Failure.invalid }
            if phase == .submitted, threadID == nil || turnID == nil { throw Failure.invalid }
            entries[index].phase = phase
            entries[index].threadID = old.threadID ?? threadID
            entries[index].turnID = old.turnID ?? turnID
            try write(entries)
        }
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path else { throw Failure.invalid }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw Failure.invalid }
        let fd = Darwin.open(
            directory.appendingPathComponent(".events.lock").path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
            flock(fd, LOCK_EX | LOCK_NB) == 0
        else { throw Failure.unavailable }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }

    private func read() throws -> [Entry] {
        let fd = Darwin.open(directory.appendingPathComponent(Self.filename).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return [] }
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
            info.st_size > 0, info.st_size <= Self.maximumBytes
        else { throw Failure.invalid }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            guard count > 0 else { throw Failure.unavailable }
            offset += count
        }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(bytes))
        guard entries.count <= Self.maximumEntries, Set(entries.map(\.id)).count == entries.count,
            entries.allSatisfy({
                $0.receivedAt.timeIntervalSince1970.isFinite
                    && ($0.threadID.map { UUID(uuidString: $0) != nil } ?? true)
                    && ($0.turnID.map { UUID(uuidString: $0) != nil } ?? true)
            })
        else { throw Failure.invalid }
        return entries
    }

    private func write(_ entries: [Entry]) throws {
        let data = try JSONEncoder().encode(entries)
        guard data.count <= Self.maximumBytes else { throw Failure.capacity }
        let temporary = directory.appendingPathComponent(".events-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer {
            Darwin.close(fd)
            unlink(temporary.path)
        }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            guard count > 0 else { throw Failure.unavailable }
            offset += count
        }
        guard fsync(fd) == 0 else { throw Failure.unavailable }
        _ = try read()
        guard rename(temporary.path, directory.appendingPathComponent(Self.filename).path) == 0 else { throw Failure.unavailable }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw Failure.unavailable }
    }
}
