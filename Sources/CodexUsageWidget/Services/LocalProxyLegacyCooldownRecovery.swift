import CoreFoundation
import Darwin
import Foundation

/// Explicit stopped-helper recovery only. Automatic quota recovery remains fail-closed.
enum LocalProxyLegacyCooldownRecovery {
    struct Candidate {
        let profileID: String
        let recordCount: Int
        let cooldownUntil: Date
        let latestRecordAt: Date
    }

    struct Confirmation: Identifiable {
        let id = UUID()
        var profileID: String { prepared.candidate.profileID }
        var recordCount: Int { prepared.candidate.recordCount }
        var cooldownUntil: Date { prepared.candidate.cooldownUntil }
        var preparedLatestRecordAt: Date { prepared.candidate.latestRecordAt }
        fileprivate let prepared: Prepared
    }

    enum Failure: Error, Equatable { case unavailable, changed, ineligible, backup }

    struct Prepared {
        let candidate: Candidate
        fileprivate let directory: URL
        fileprivate let bytes: Data
        fileprivate let retained: [[String: Any]]
        fileprivate let version: Version
    }

    fileprivate struct Version: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
        var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1e9) }
    }

    private static func file(_ directory: URL) -> URL { directory.appendingPathComponent("cooldown.json") }

    private static func checkDirectory(_ directory: URL) throws {
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.unavailable }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw Failure.unavailable }
    }

    private static func read(_ directory: URL) throws -> (Data, Version) {
        try checkDirectory(directory)
        let url = file(directory)
        var before = stat()
        var after = stat()
        guard lstat(url.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o077 == 0
        else { throw Failure.unavailable }
        guard let bytes = try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: 1024 * 1024),
            lstat(url.path, &after) == 0, after.st_mode & S_IFMT == S_IFREG,
            after.st_uid == geteuid(), after.st_nlink == 1, after.st_mode & 0o077 == 0,
            Version(before) == Version(after)
        else { throw Failure.changed }
        return (bytes, Version(after))
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let value = raw as? String else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = format.date(from: value) { return parsed }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: value)
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func unknown(_ row: [String: Any]) -> Bool {
        guard let raw = row["error"], !(raw is NSNull) else { return true }
        guard let error = raw as? [String: Any], Set(error.keys).isSubset(of: ["httpStatus", "credentialQuota", "absent"]),
            let status = error["httpStatus"] as? NSNumber, CFGetTypeID(status) != CFBooleanGetTypeID(),
            status.doubleValue == 0,
            error["credentialQuota"] == nil || boolean(error["credentialQuota"]) == false,
            error["absent"] == nil || boolean(error["absent"]) == false
        else { return false }
        return true
    }

    private static func credentialQuota(_ row: [String: Any]) -> Bool {
        guard let error = row["error"] as? [String: Any], Set(error.keys).isSubset(of: ["httpStatus", "credentialQuota", "absent"]),
            let status = error["httpStatus"] as? NSNumber, CFGetTypeID(status) != CFBooleanGetTypeID(), status.doubleValue == 429,
            boolean(error["credentialQuota"]) == true,
            error["absent"] == nil || boolean(error["absent"]) == false
        else { return false }
        return true
    }

    private static func propagatedAbsence(_ row: [String: Any]) -> Bool {
        guard boolean(row["credentialQuotaPropagated"]) == true,
            let error = row["error"] as? [String: Any], Set(error.keys).isSubset(of: ["httpStatus", "credentialQuota", "absent"]),
            let status = error["httpStatus"] as? NSNumber, CFGetTypeID(status) != CFBooleanGetTypeID(), status.doubleValue == 0,
            boolean(error["absent"]) == true,
            error["credentialQuota"] == nil || boolean(error["credentialQuota"]) == false
        else { return false }
        return true
    }

    static func prepare(at directory: URL, profileID: String, now: Date = Date()) throws -> Prepared {
        let (bytes, version) = try read(directory)
        return try prepare(bytes: bytes, version: version, directory: directory, profileID: profileID, now: now)
    }

    private static func prepare(bytes: Data, version: Version, directory: URL, profileID: String, now: Date) throws -> Prepared {
        guard let rows = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]], rows.count <= 4096,
            rows.allSatisfy({ ($0["id"] as? String).map { !$0.isEmpty && $0.utf8.count <= 128 } == true })
        else { throw Failure.unavailable }
        let target = rows.filter { $0["id"] as? String == profileID }
        guard !target.isEmpty,
            let root = target.first(where: { ($0["model"] as? String ?? "").isEmpty }),
            root["reason"] as? String == "credential_quota", let until = date(root["until"]), until > now,
            target.contains(where: unknown)
        else { throw Failure.ineligible }
        let provenRoot = credentialQuota(root)
        guard unknown(root) || provenRoot else { throw Failure.ineligible }
        var latest = version.modified
        var models = Set<String>()
        for row in target {
            let model = row["model"] as? String ?? ""
            guard Set(row.keys).isSubset(of: ["id", "model", "reason", "until", "recover", "exceeded", "backoff", "updatedAt", "error", "kind", "identityHash", "credentialQuotaPropagated"]),
                row["kind"] == nil || row["kind"] as? String == "account",
                row["credentialQuotaPropagated"] == nil || boolean(row["credentialQuotaPropagated"]) != nil,
                boolean(row["exceeded"]) == true, let reason = row["reason"] as? String,
                date(row["until"]) == until, date(row["recover"]) == until,
                row["model"] == nil || row["model"] is String,
                model.utf8.count <= 128, models.insert(model).inserted
            else { throw Failure.ineligible }
            // Explicit recovery can encounter partially migrated records: a
            // proven account quota alongside older unknown model errors. Keep
            // automatic recovery strict, and never discard an independent layer.
            let legacy = unknown(row) && ["credential_quota", "temporary_error"].contains(reason)
            let proven = provenRoot && credentialQuota(row) && ["credential_quota", "quota"].contains(reason)
            let cleanSibling = provenRoot && !model.isEmpty && reason == "credential_quota" && propagatedAbsence(row)
            guard legacy || proven || cleanSibling else { throw Failure.ineligible }
            if let raw = row["updatedAt"] {
                guard let updated = date(raw) else { throw Failure.ineligible }
                latest = max(latest, updated)
            }
        }
        return Prepared(
            candidate: Candidate(profileID: profileID, recordCount: target.count, cooldownUntil: until, latestRecordAt: latest),
            directory: directory, bytes: bytes, retained: rows.filter { $0["id"] as? String != profileID }, version: version)
    }

    static func candidates(at directory: URL, profileIDs: Set<String>) -> Set<String> {
        guard let (bytes, version) = try? read(directory) else { return [] }
        let now = Date()
        return Set(profileIDs.filter { (try? prepare(bytes: bytes, version: version, directory: directory, profileID: $0, now: now)) != nil })
    }

    static func confirm(_ prepared: Prepared) throws -> Confirmation {
        try revalidate(prepared)
        return Confirmation(prepared: prepared)
    }

    private static func revalidate(_ prepared: Prepared) throws {
        let (bytes, version) = try read(prepared.directory)
        guard bytes == prepared.bytes, version == prepared.version else { throw Failure.changed }
    }

    /// The caller must recheck stopped state, identity and this action's saved fresh proof.
    static func commit(_ confirmation: Confirmation, validate: () throws -> Void) throws -> URL {
        let prepared = confirmation.prepared
        try checkDirectory(prepared.directory)
        return try DispatchParticipationSync.withSnapshotLock(at: file(prepared.directory)) {
            try validate()
            try revalidate(prepared)
            let backup = prepared.directory.appendingPathComponent("cooldown-legacy-backup-\(UUID().uuidString).json")
            let descriptor = Darwin.open(backup.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Failure.backup }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: prepared.bytes)
                try handle.synchronize()
                try handle.close()
                var info = stat()
                guard lstat(backup.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                    info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
                    try DispatchParticipationSync.readBoundedRegularFile(backup, maximumBytes: 1024 * 1024) == prepared.bytes
                else { throw Failure.backup }
            } catch {
                try? handle.close()
                throw Failure.backup
            }
            let replacement = try JSONSerialization.data(withJSONObject: prepared.retained, options: [.sortedKeys])
            guard let decoded = try JSONSerialization.jsonObject(with: replacement) as? [[String: Any]],
                NSArray(array: decoded).isEqual(to: prepared.retained)
            else { throw Failure.unavailable }
            try validate()
            try revalidate(prepared)
            try DispatchParticipationSync.writeSnapshot(replacement, at: file(prepared.directory), replacing: prepared.bytes)
            guard try read(prepared.directory).0 == replacement else { throw Failure.changed }
            return backup
        }
    }
}
