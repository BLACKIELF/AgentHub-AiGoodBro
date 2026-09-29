import Darwin
import Foundation

private enum LocalProxySocketError: Error { case unavailable, invalidRequest }

/// Local, user-owned IPC. No URLs, paths, credentials or arbitrary commands are accepted.
final class LocalProxyBridge: @unchecked Sendable {
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private let slots = DispatchSemaphore(value: 8)

    init(path: String, handler: @escaping @MainActor @Sendable (LocalProxyRequest) async -> LocalProxyReply) throws {
        guard path.utf8.count < 104, !FileManager.default.fileExists(atPath: path) else { throw LocalProxySocketError.unavailable }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
        else { throw LocalProxySocketError.unavailable }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalProxySocketError.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0,
            fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
        else {
            Darwin.close(descriptor)
            if bound == 0 { unlink(path) }
            throw LocalProxySocketError.unavailable
        }
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "AiGoodBro.LocalProxyIPC"))
        let slots = self.slots
        readSource.setEventHandler {
            for _ in 0..<8 {
                let client = Darwin.accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), slots.wait(timeout: .now()) == .success else {
                    Darwin.close(client)
                    continue
                }
                // Read only one bounded line per connection. Slow/malformed
                // clients cannot hold the UI thread or an unlimited worker pool.
                Task.detached(priority: .userInitiated) {
                    defer {
                        Darwin.close(client)
                        slots.signal()
                    }
                    _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                    Self.configure(client)
                    do {
                        let request = try JSONDecoder().decode(LocalProxyRequest.self, from: Self.readLine(client))
                        let reply = await handler(request)
                        var data = try JSONEncoder().encode(reply)
                        data.append(10)
                        try Self.write(data, to: client)
                    } catch {
                        // Never expose account metadata in IPC diagnostics.
                    }
                }
            }
        }
        // The listener is closed only after its event handler has finished;
        // accepted descriptors stay owned by their bounded request tasks.
        readSource.setCancelHandler { Darwin.close(descriptor) }
        source = readSource
        readSource.resume()
    }

    func stop() {
        lock.lock()
        let previous = source
        source = nil
        lock.unlock()
        previous?.cancel()
    }

    deinit { stop() }

    private static func configure(_ descriptor: Int32) {
        // Accepted sockets must be blocking even when the listener isn't.
        _ = fcntl(descriptor, F_SETFL, 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func readLine(_ descriptor: Int32) throws -> Data {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while received.count <= 4096 {
            let count = Darwin.recv(descriptor, &buffer, min(buffer.count, 4097 - received.count), 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw LocalProxySocketError.invalidRequest }
            received.append(contentsOf: buffer.prefix(count))
            if let newline = received.firstIndex(of: 10) {
                guard received.suffix(from: received.index(after: newline)).allSatisfy({ $0 == 10 || $0 == 13 }) else { throw LocalProxySocketError.invalidRequest }
                return received.prefix(upTo: newline)
            }
        }
        throw LocalProxySocketError.invalidRequest
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LocalProxySocketError.unavailable }
                offset += count
            }
        }
    }
}

/// Reads under the same in-process gates as credential writers, then rechecks
/// the exact bytes before returning. No refresh, token repair or credential write.
enum LocalProxyCredentialReader {
    struct Value: Sendable {
        let token: String
        let accountID: String
        let expiresAt: Double
    }
    static func read(profile: CodexProfile, system: CodexProfile, now: Date = Date(), allowDesktopAccount: Bool = false, creditFloor: Int? = nil, allowPaidCredits: Bool = false)
        throws -> Value
    {
        try withBoundedGates([profile.codexHomeURL, system.codexHomeURL]) {
            let home = CodexCredentialTransaction.canonical(profile.codexHomeURL)
            let central = CodexCredentialTransaction.canonical(system.codexHomeURL)
            guard !profile.isSystemProfile, home != central,
                home == profile.codexHomeURL.standardizedFileURL,
                let data = try readSnapshot(home: home),
                let centralData = try readSnapshot(home: central),
                let centralIdentity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: centralData)
            else { throw LocalProxyFailure.identity }
            let result = try validate(
                data: data, profile: profile, centralIdentity: centralIdentity, now: now, allowDesktopAccount: allowDesktopAccount, creditFloor: creditFloor,
                allowPaidCredits: allowPaidCredits)
            guard try readSnapshot(home: home) == data,
                try readSnapshot(home: central) == centralData,
                CodexCredentialTransaction.canonical(profile.codexHomeURL) == home,
                CodexCredentialTransaction.canonical(system.codexHomeURL) == central
            else { throw LocalProxyFailure.identity }
            return result
        }
    }

    private static func readSnapshot(home: URL) throws -> Data? {
        var directory = stat()
        guard lstat(home.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
            directory.st_uid == geteuid(), directory.st_mode & 0o022 == 0
        else { throw LocalProxyFailure.identity }
        let file = home.appendingPathComponent("auth.json")
        var before = stat()
        guard lstat(file.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0
        else { throw LocalProxyFailure.identity }
        let data = try CodexCredentialTransaction.read(file)
        var after = stat()
        guard lstat(file.path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw LocalProxyFailure.identity }
        return data
    }

    private static func withBoundedGates<T>(_ homes: [URL], operation: () throws -> T) throws -> T {
        // Quota refreshes use the same credential gates. Allow a short refresh
        // to finish without misclassifying it as a task occupying this account.
        // Keep this below the 25s bridge deadline, including the 6s Hub check.
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        let gates =
            [CodexCredentialAccessGate.lock] + Set(homes.map { CodexCredentialTransaction.canonical($0).path }).sorted().map { CodexCredentialAccessGate.homeLock(forHomePath: $0) }
        var acquired: [NSRecursiveLock] = []
        defer { acquired.reversed().forEach { $0.unlock() } }
        for gate in gates {
            while !gate.try() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw LocalProxyFailure.credentialsBusy }
                Thread.sleep(forTimeInterval: 0.01)
            }
            acquired.append(gate)
        }
        return try operation()
    }

    static func validate(
        data: Data, profile: CodexProfile, centralIdentity: CodexCredentialIdentity, now: Date, allowDesktopAccount: Bool = false, creditFloor: Int? = nil,
        allowPaidCredits: Bool = false
    ) throws -> Value {
        guard data.count <= 1024 * 1024, !profile.isSystemProfile,
            let snapshot = profile.lastSnapshot,
            let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data),
            profile.matchesRecordedCredential(identity),
            snapshot.accountID == identity.accountID,
            snapshot.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == identity.email,
            allowDesktopAccount
                ? (identity.email == centralIdentity.email && identity.accountID == centralIdentity.accountID)
                : (identity.email != centralIdentity.email && identity.accountID != centralIdentity.accountID),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any], let token = tokens["access_token"] as? String,
            token.utf8.count <= 32768, !token.contains("\n"), !token.contains("\r")
        else { throw LocalProxyFailure.identity }
        if let failure = LocalProxyAdmission.quota(profile, now: now, creditFloor: creditFloor, allowPaidCredits: allowPaidCredits) { throw failure }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw LocalProxyFailure.loginExpired }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let decoded = Data(base64Encoded: encoded), let claims = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
            let expiry = claims["exp"] as? Double, expiry.isFinite, expiry < Double(Int64.max), expiry > now.timeIntervalSince1970 + 60,
            let issued = claims["iat"] as? Double, issued.isFinite, issued > 0,
            issued <= snapshot.fetchedAt.timeIntervalSince1970,
            issued <= now.timeIntervalSince1970
        else { throw LocalProxyFailure.loginExpired }
        // A newly minted generation needs a fresh official quota observation.
        return Value(token: token, accountID: identity.accountID, expiresAt: expiry)
    }
}
