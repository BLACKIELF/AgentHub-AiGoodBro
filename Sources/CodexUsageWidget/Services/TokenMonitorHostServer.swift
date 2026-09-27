import Darwin
import Foundation

struct TokenMonitorHostRequest: Decodable, Sendable {
    enum Command: String, Decodable, Sendable {
        case openWorkbench, openAccounts, openTasks, openSettings, checkForUpdates, quitHost
        case switchCodexAccount
        case getManagedCodexAccounts
    }

    let id: String
    let cmd: Command
    let vendorAccountId: String?
    let recordedAccountKey: String?

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw HostSocketError.invalidRequest }
        let request = try JSONDecoder().decode(Self.self, from: data)
        let allowed: Set<String> =
            request.cmd == .switchCodexAccount
            ? ["id", "cmd", "vendorAccountId", "recordedAccountKey"] : ["id", "cmd"]
        guard Set(object.keys).isSubset(of: allowed),
            request.id.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil
        else { throw HostSocketError.invalidRequest }
        if request.cmd == .switchCodexAccount {
            guard let account = request.vendorAccountId, !account.isEmpty, account.utf8.count <= 256,
                !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                request.recordedAccountKey?.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
            else { throw HostSocketError.invalidRequest }
        }
        return request
    }
}

struct TokenMonitorHostReply: Encodable, Sendable {
    let id: String
    let ok: Bool
    var error: String? = nil
    var accountId: String? = nil
    var accounts: [TokenMonitorManagedCodexAccount]? = nil

    static func failure(_ id: String, _ code: String) -> Self { Self(id: id, ok: false, error: code) }
}

private enum HostSocketError: Error { case unavailable, invalidRequest }

/// Local, user-owned IPC. No URLs, paths, credentials or arbitrary commands are accepted.
final class TokenMonitorHostServer: @unchecked Sendable {
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private let slots = DispatchSemaphore(value: 8)

    init(path: String, handler: @escaping @MainActor @Sendable (TokenMonitorHostRequest) async -> TokenMonitorHostReply) throws {
        guard path.utf8.count < 104, !FileManager.default.fileExists(atPath: path) else { throw HostSocketError.unavailable }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
        else { throw HostSocketError.unavailable }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HostSocketError.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0,
            fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
        else {
            Darwin.close(descriptor)
            if bound == 0 { unlink(path) }
            throw HostSocketError.unavailable
        }
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "AiGoodBro.TokenMonitorHostIPC"))
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
                    Self.configure(client)
                    do {
                        let request = try TokenMonitorHostRequest.decode(Self.readLine(client))
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
            guard count > 0 else { throw HostSocketError.invalidRequest }
            received.append(contentsOf: buffer.prefix(count))
            if let newline = received.firstIndex(of: 10) {
                guard received.suffix(from: received.index(after: newline)).allSatisfy({ $0 == 10 || $0 == 13 }) else { throw HostSocketError.invalidRequest }
                return received.prefix(upTo: newline)
            }
        }
        throw HostSocketError.invalidRequest
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw HostSocketError.unavailable }
                offset += count
            }
        }
    }
}
