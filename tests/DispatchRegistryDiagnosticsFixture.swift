import Darwin
import Foundation

enum HubAccountTaskPhase { case maintenance, starting, running, cancelRequested, uncertain, awaitingAcceptance, succeeded, failed, cancelled, unavailable }
struct HubAccountTaskStatus { let phase: HubAccountTaskPhase; let updatedAt: Date? }
enum DispatchParticipationPaths { static func supportDirectory() -> URL { fatalError("fixture must not access the live store") } }
enum DispatchParticipationError: Error { case fileAccess }

// The runner substitutes only system calls and the log sink in a disposable
// copy of the production file. Every registry transaction is production code.
enum RegistryFault {
    static var mode = ""
    static var writeCalls = 0
    static var syncCalls = 0
    static var logs: [(String, String, Int32)] = []
    static func reset(_ mode: String = "") { self.mode = mode; writeCalls = 0; syncCalls = 0; logs = [] }
    static func record(_ stage: String, _ cause: String, _ code: Int32) { logs.append((stage, cause, code)) }
    static func openRead(_ path: String, _ flags: Int32) -> Int32 {
        if mode == "read-open" { errno = EACCES; return -1 }
        return Darwin.open(path, flags)
    }
    static func read(_ handle: FileHandle, _ count: Int) throws -> Data? {
        if mode == "read-data" {
            throw NSError(domain: NSCocoaErrorDomain, code: 256,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))])
        }
        return try handle.read(upToCount: count)
    }
    static func openTemporary(_ path: String, _ flags: Int32, _ permissions: mode_t) -> Int32 {
        if mode == "temporary-full" { errno = ENOSPC; return -1 }
        return Darwin.open(path, flags, permissions)
    }
    static func write(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
        writeCalls += 1
        if mode == "write-full" { errno = ENOSPC; return -1 }
        if mode == "write-interrupt" && writeCalls == 1 { errno = EINTR; return -1 }
        if mode == "write-interrupt" && writeCalls == 2 { return Darwin.write(fd, pointer, min(7, count)) }
        return Darwin.write(fd, pointer, count)
    }
    static func sync(_ fd: Int32) -> Int32 {
        syncCalls += 1
        if mode == "sync-full" { errno = ENOSPC; return -1 }
        if mode == "sync-interrupt" && syncCalls == 1 { errno = EINTR; return -1 }
        if mode == "sync-interrupt-exhausted" { errno = EINTR; return -1 }
        return Darwin.fsync(fd)
    }
    static func rename(_ source: String, _ target: String) -> Int32 {
        if mode == "publish-io" { errno = EIO; return -1 }
        return Darwin.rename(source, target)
    }
}

enum FixtureError: Error { case assertion(String) }

@main struct DispatchRegistryDiagnosticsFixture {
    static var checks = 0
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DISPATCH_REGISTRY_FIXTURE_ROOT"]!, isDirectory: true)
    static let profile = "fixture-profile"

    static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw FixtureError.assertion(label) }
        checks += 1
    }
    static func fixture() throws -> (DispatchActivityStore, URL, String, String, String, Data) {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let store = DispatchActivityStore(directory: folder)
        let run = UUID().uuidString, request = UUID().uuidString
        RegistryFault.reset()
        let lease = try store.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run,
            requestID: request, profileID: profile, childPID: getpid())
        try store.updateProxy(lease, runID: run, requestID: request, profileID: profile, state: "running")
        let registry = folder.appendingPathComponent(DispatchActivityStore.stateName)
        return (store, registry, run, request, lease, try Data(contentsOf: registry))
    }
    static func matches(_ stage: String, _ cause: String, _ code: Int32) -> Bool {
        RegistryFault.logs.count == 1 && RegistryFault.logs[0].0 == stage
            && RegistryFault.logs[0].1 == cause && RegistryFault.logs[0].2 == code
    }
    static func failedUpdate(_ mode: String, _ stage: String, _ cause: String, _ code: Int32,
                             accessError: Bool = false) throws {
        let (store, registry, run, request, lease, before) = try fixture()
        var committed = false
        RegistryFault.reset(mode)
        do {
            try store.updateProxy(lease, runID: run, requestID: request, profileID: profile, state: "accepted", onCommit: { committed = true })
            throw FixtureError.assertion("\(mode): expected failure")
        } catch DispatchActivityStore.Failure.unavailable {
            try expect(!accessError, "\(mode): original unavailable result")
        } catch DispatchParticipationError.fileAccess {
            try expect(accessError, "\(mode): original read error")
        }
        try expect(matches(stage, cause, code), "\(mode): safe diagnostic")
        try expect(!committed, "\(mode): no admission fence")
        try expect(Data(contentsOf: registry) == before, "\(mode): registry unchanged")
        let remnants = try FileManager.default.contentsOfDirectory(atPath: registry.deletingLastPathComponent().path)
        try expect(!remnants.contains(where: { $0.hasPrefix(".dispatch-activity-") }), "\(mode): temporary file removed")
    }
    static func successfulInterrupt(_ mode: String) throws {
        let (store, registry, run, request, lease, before) = try fixture()
        var committed = 0
        RegistryFault.reset(mode)
        try store.updateProxy(lease, runID: run, requestID: request, profileID: profile, state: "accepted", onCommit: { committed += 1 })
        try expect(RegistryFault.logs.isEmpty, "\(mode): recovered interruption does not report failure")
        try expect((mode == "write-interrupt" ? RegistryFault.writeCalls >= 3 : RegistryFault.syncCalls >= 2), "\(mode): injected interruption was retried")
        try expect(committed == 1, "\(mode): fence published once")
        try expect(Data(contentsOf: registry) != before, "\(mode): committed registry")
        RegistryFault.reset()
        try expect(store.read().leases.first(where: { $0.leaseId == lease })?.state == "accepted", "\(mode): terminal state persisted")
    }
    static func invalidInput(_ bytes: Data, _ stage: String, _ cause: String, _ kind: String) throws {
        let (store, registry, _, _, _, _) = try fixture()
        try bytes.write(to: registry)
        RegistryFault.reset()
        do {
            _ = try store.read()
            throw FixtureError.assertion("\(kind): expected failure")
        } catch is DecodingError {
            try expect(kind == "malformed", "malformed preserves decoder result")
        } catch DispatchActivityStore.Failure.invalidState {
            try expect(kind == "schema" || kind == "count", "schema and count preserve invalid state result")
        } catch DispatchParticipationError.fileAccess {
            try expect(kind == "limit", "limit preserves file access result")
        }
        try expect(matches(stage, cause, 0), "\(kind): safe diagnostic")
        try expect(Data(contentsOf: registry) == bytes, "\(kind): bytes untouched")
    }
    static func lockContention() throws {
        let (store, registry, run, request, lease, before) = try fixture()
        let lock = Darwin.open(registry.deletingLastPathComponent().appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw FixtureError.assertion("fixture lock") }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        RegistryFault.reset()
        var committed = false
        do {
            try store.updateProxy(lease, runID: run, requestID: request, profileID: profile, state: "accepted", onCommit: { committed = true })
            throw FixtureError.assertion("busy: expected refusal")
        } catch DispatchActivityStore.Failure.busy {}
        try expect(!committed && RegistryFault.logs.isEmpty, "lock contention remains ordinary busy")
        try expect(Data(contentsOf: registry) == before, "lock contention leaves registry unchanged")
    }
    static func concurrentTransitions() throws {
        let (store, registry, run, request, lease, _) = try fixture()
        let attempts = DispatchGroup()
        let resultLock = NSLock()
        var failures = 0
        // Exercise the real lock, read, JSON rewrite and rename with independent
        // requests. A busy refusal is an expected no-write result.
        for index in 0..<64 {
            attempts.enter()
            DispatchQueue.global().async {
                defer { attempts.leave() }
                do {
                    let id = try store.reserveProxy(account: "concurrent-\(index)", alias: "concurrent-\(index)",
                        runID: run, requestID: UUID().uuidString, profileID: profile, childPID: getpid())
                    _ = id
                } catch DispatchActivityStore.Failure.busy {
                } catch {
                    resultLock.lock(); failures += 1; resultLock.unlock()
                }
            }
        }
        attempts.wait()
        try expect(failures == 0, "concurrent writers only succeed or receive busy")
        var committed = false
        try store.updateProxy(lease, runID: run, requestID: request, profileID: profile, state: "accepted", onCommit: { committed = true })
        try expect(committed, "release publishes fence after successful registry replacement")
        let afterRelease = try Data(contentsOf: registry)
        do {
            try store.updateProxy(lease, runID: run, requestID: request, profileID: profile, state: "running")
            throw FixtureError.assertion("late heartbeat resurrected terminal lease")
        } catch DispatchActivityStore.Failure.invalidState {}
        try expect(Data(contentsOf: registry) == afterRelease, "late heartbeat leaves terminal release unchanged")
        try expect(store.read().leases.first(where: { $0.leaseId == lease })?.state == "accepted", "release remains terminal")
    }
    static func atomicReadDuringWrites() throws {
        let (store, _, run, request, lease, _) = try fixture()
        let start = DispatchSemaphore(value: 0), group = DispatchGroup(), resultLock = NSLock()
        var errors = 0, reads = 0
        RegistryFault.reset()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            start.wait()
            for _ in 0..<30 {
                do {
                    try store.updateProxy(lease, runID: run, requestID: request, profileID: profile, state: "running")
                } catch {
                    resultLock.lock(); errors += 1; resultLock.unlock()
                }
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            start.wait()
            for _ in 0..<150 {
                do {
                    let snapshot = try store.read()
                    resultLock.lock()
                    reads += 1
                    if !snapshot.leases.contains(where: { $0.leaseId == lease && $0.state == "running" }) { errors += 1 }
                    resultLock.unlock()
                } catch {
                    resultLock.lock(); errors += 1; resultLock.unlock()
                }
            }
        }
        start.signal(); start.signal(); group.wait()
        try expect(reads == 150 && errors == 0, "unlocked readers see complete snapshots during atomic replacements")
    }
    static func main() {
        do {
            try failedUpdate("read-open", "readOpen", "io", EACCES, accessError: true)
            try failedUpdate("read-data", "readData", "io", EIO, accessError: true)
            try failedUpdate("temporary-full", "temporaryOpen", "capacity", ENOSPC)
            try failedUpdate("write-full", "write", "capacity", ENOSPC)
            try failedUpdate("sync-full", "sync", "capacity", ENOSPC)
            try failedUpdate("sync-interrupt-exhausted", "sync", "io", EINTR)
            try failedUpdate("publish-io", "publish", "io", EIO)
            try successfulInterrupt("write-interrupt")
            try successfulInterrupt("sync-interrupt")
            try invalidInput(Data("{".utf8), "decode", "invalid", "malformed")
            try invalidInput(Data("{\"schemaVersion\":2,\"leases\":[]}".utf8), "decode", "invalid", "schema")
            let hash = String(repeating: "a", count: 64)
            let rows: [[String: Any]] = (0...2000).map { index in [
                "leaseId": "fixture-\(index)", "ownerThreadId": "fixture", "taskId": "fixture",
                "accountKey": hash, "aliasKey": hash, "projectKey": hash, "route": "fixture", "state": "running",
                "createdAt": 1, "updatedAt": 1, "heartbeatDueAt": 1,
            ] }
            try invalidInput(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "leases": rows]), "limit", "capacity", "count")
            try invalidInput(Data(repeating: 0, count: 2 * 1024 * 1024 + 1), "limit", "capacity", "limit")
            try lockContention()
            try concurrentTransitions()
            try atomicReadDuringWrites()
            print("registry-diagnostics: PASS \(checks) checks")
        } catch {
            print("registry-diagnostics: FAIL \(error)")
            exit(1)
        }
    }
}
