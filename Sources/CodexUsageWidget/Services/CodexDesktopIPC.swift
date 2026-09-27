import Darwin
import Foundation

/// Same-user, local-only transport for the installed Codex Desktop IPC router.
/// The wire versions below are pinned to Desktop 26.917.71314; unknown messages fail closed.
final class CodexDesktopIPC {
    enum IPCError: Error {
        case mainThread
        case unavailable
        case unsafeSocket
        case invalidFrame
        case timedOut
        case disconnected
        case unsupportedRequest
        case unexpectedResponse
        case remote(String)
    }

    static let shared = CodexDesktopIPC()

    private final class Pending {
        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any]?
    }

    private struct Subscription {
        let ownerClientID: String
        let callback: ([String: Any]) -> Void
        var revision: Int?
    }

    private let socketPath: String
    private let maximumFrameBytes = 16 * 1_024 * 1_024
    private let connectLock = NSLock()
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let readerQueue = DispatchQueue(label: "com.blackielf.codex-account-manager-next.desktop-ipc.reader", qos: .utility)
    private let callbackQueue = DispatchQueue(label: "com.blackielf.codex-account-manager-next.desktop-ipc.callback", qos: .utility)
    private var descriptor: Int32 = -1
    private var connectionEpoch = UUID()
    private var clientID: String?
    private var pending: [String: Pending] = [:]
    private var verifiedOwners: [String: String] = [:]
    private var subscriptions: [String: Subscription] = [:]

    init(socketPath: String = NSHomeDirectory() + "/.codex/ipc/ipc.sock") {
        self.socketPath = socketPath
    }

    deinit { close() }

    /// Returns the complete response envelope, including `handledByClientId`.
    /// Call from a background queue. Follower mutations require a freshly discovered owner.
    func request(
        method: String,
        params: [String: Any],
        targetClientId: String? = nil,
        hostId: String = "local",
        timeout: TimeInterval = 5
    ) throws -> [String: Any] {
        guard !Thread.isMainThread else { throw IPCError.mainThread }
        guard hostId == "local", timeout > 0, timeout <= 30 else { throw IPCError.unsupportedRequest }
        let version: Int
        switch method {
        case "thread-owner-discovery":
            guard let conversationID = params["conversationId"] as? String,
                !conversationID.isEmpty,
                params["hostId"] as? String == "local"
            else { throw IPCError.unsupportedRequest }
            version = 1
        case "thread-follower-start-turn", "thread-follower-interrupt-turn":
            guard let conversationID = params["conversationId"] as? String,
                let targetClientId, !targetClientId.isEmpty
            else { throw IPCError.unsupportedRequest }
            stateLock.lock()
            let owner = verifiedOwners[conversationID]
            stateLock.unlock()
            guard owner == targetClientId else { throw IPCError.unsupportedRequest }
            if method == "thread-follower-start-turn" {
                guard params["turnStart"] is [String: Any] else { throw IPCError.unsupportedRequest }
                version = 2
            } else {
                guard let mode = params["mode"] as? String,
                    ["system", "user-stop"].contains(mode),
                    let expectedTurnID = params["expectedTurnId"] as? String,
                    UUID(uuidString: expectedTurnID) != nil
                else { throw IPCError.unsupportedRequest }
                version = 4
            }
        default:
            throw IPCError.unsupportedRequest
        }
        try ensureConnected(timeout: timeout)
        let response = try sendRequest(
            method: method,
            params: params,
            version: version,
            targetClientID: targetClientId,
            timeout: timeout
        )
        guard response["method"] as? String == method,
            response["resultType"] as? String == "success"
        else { throw IPCError.unexpectedResponse }
        if let targetClientId {
            guard response["handledByClientId"] as? String == targetClientId else {
                throw IPCError.unexpectedResponse
            }
        }
        return response
    }

    func discoverOwner(
        conversationId: String,
        hostId: String = "local",
        timeout: TimeInterval = 5
    ) throws -> String? {
        do {
            let response = try request(
                method: "thread-owner-discovery",
                params: ["hostId": hostId, "conversationId": conversationId],
                timeout: timeout
            )
            guard let owner = response["handledByClientId"] as? String, !owner.isEmpty,
                (response["result"] as? [String: Any])?["supportsUntrustedAppInput"] as? Bool == true
            else { throw IPCError.unexpectedResponse }
            stateLock.lock()
            verifiedOwners[conversationId] = owner
            stateLock.unlock()
            return owner
        } catch IPCError.remote(let code) where code == "no-client-found" {
            stateLock.lock()
            verifiedOwners.removeValue(forKey: conversationId)
            stateLock.unlock()
            return nil
        }
    }

    /// Sends the installed Desktop's follower broadcast. The callback receives
    /// only state changes for this thread from its verified owner.
    func follow(
        conversationId: String,
        ownerClientId: String,
        hostId: String = "local",
        onStateChange: @escaping ([String: Any]) -> Void
    ) throws {
        guard !Thread.isMainThread else { throw IPCError.mainThread }
        guard hostId == "local" else { throw IPCError.unsupportedRequest }
        try ensureConnected(timeout: 5)
        stateLock.lock()
        let verified = verifiedOwners[conversationId]
        if verified == ownerClientId {
            subscriptions[conversationId] = Subscription(ownerClientID: ownerClientId, callback: onStateChange)
        }
        stateLock.unlock()
        guard verified == ownerClientId else { throw IPCError.unsupportedRequest }
        try sendFollowing(conversationId: conversationId, following: true)
    }

    func unfollow(conversationId: String) throws {
        guard !Thread.isMainThread else { throw IPCError.mainThread }
        stateLock.lock()
        let wasFollowing = subscriptions.removeValue(forKey: conversationId) != nil
        stateLock.unlock()
        if wasFollowing { try sendFollowing(conversationId: conversationId, following: false) }
    }

    /// Reads one full Desktop-owned state snapshot. A missing snapshot is unknown,
    /// never evidence that the task is idle. The entire state stays in memory.
    func snapshot(
        conversationId: String,
        hostId: String = "local",
        ownerClientId: String,
        timeout: TimeInterval = 10
    ) throws -> [String: Any] {
        guard !Thread.isMainThread else { throw IPCError.mainThread }
        guard timeout > 0, timeout <= 30 else { throw IPCError.unsupportedRequest }
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var captured: [String: Any]?
        try follow(conversationId: conversationId, ownerClientId: ownerClientId, hostId: hostId) { change in
            guard change["type"] as? String == "snapshot",
                let state = change["conversationState"] as? [String: Any]
            else { return }
            resultLock.lock()
            if captured == nil {
                captured = state
                semaphore.signal()
            }
            resultLock.unlock()
        }
        defer { try? unfollow(conversationId: conversationId) }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { throw IPCError.timedOut }
        resultLock.lock()
        let state = captured
        resultLock.unlock()
        guard let state else { throw IPCError.unexpectedResponse }
        return state
    }

    func close() {
        stateLock.lock()
        let fd = descriptor
        descriptor = -1
        clientID = nil
        verifiedOwners.removeAll()
        subscriptions.removeAll()
        let waiters = Array(pending.values)
        pending.removeAll()
        stateLock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for waiter in waiters {
            waiter.response = ["resultType": "error", "error": "connection-closed"]
            waiter.semaphore.signal()
        }
    }

    private func ensureConnected(timeout: TimeInterval) throws {
        connectLock.lock()
        defer { connectLock.unlock() }
        stateLock.lock()
        let existing = clientID != nil && descriptor >= 0
        stateLock.unlock()
        if existing { return }
        let fd = try openSocket()
        let epoch = UUID()
        stateLock.lock()
        descriptor = fd
        connectionEpoch = epoch
        stateLock.unlock()
        readerQueue.async { [weak self] in self?.readLoop(fd: fd, epoch: epoch) }
        do {
            let response = try sendRequest(
                method: "initialize",
                params: ["clientType": "aigoodbro"],
                version: 0,
                targetClientID: nil,
                timeout: timeout
            )
            guard response["resultType"] as? String == "success",
                response["method"] as? String == "initialize",
                let result = response["result"] as? [String: Any],
                let id = result["clientId"] as? String, !id.isEmpty,
                response["handledByClientId"] as? String == id
            else { throw IPCError.unexpectedResponse }
            stateLock.lock()
            clientID = id
            stateLock.unlock()
        } catch {
            close()
            throw error
        }
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        version: Int,
        targetClientID: String?,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let requestID = UUID().uuidString.lowercased()
        let waiter = Pending()
        stateLock.lock()
        let sourceID = clientID ?? "initializing-client"
        pending[requestID] = waiter
        stateLock.unlock()
        var message: [String: Any] = [
            "type": "request", "requestId": requestID, "sourceClientId": sourceID,
            "version": version, "method": method, "params": params,
            "timeoutMs": Int(timeout * 1_000),
        ]
        if let targetClientID { message["targetClientId"] = targetClientID }
        do { try send(message) } catch {
            stateLock.lock()
            pending.removeValue(forKey: requestID)
            stateLock.unlock()
            throw error
        }
        guard waiter.semaphore.wait(timeout: .now() + timeout) == .success else {
            stateLock.lock()
            pending.removeValue(forKey: requestID)
            stateLock.unlock()
            throw IPCError.timedOut
        }
        guard let response = waiter.response else { throw IPCError.disconnected }
        if response["resultType"] as? String == "error" {
            throw IPCError.remote(response["error"] as? String ?? "unknown")
        }
        return response
    }

    private func sendFollowing(conversationId: String, following: Bool) throws {
        stateLock.lock()
        let id = clientID
        stateLock.unlock()
        guard let id else { throw IPCError.disconnected }
        try send([
            "type": "broadcast", "method": "thread-stream-following-changed",
            "version": 1, "sourceClientId": id,
            "params": ["conversationId": conversationId, "hostId": "local", "following": following],
        ])
    }

    private func send(_ message: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(message),
            let payload = try? JSONSerialization.data(withJSONObject: message),
            payload.count > 0, payload.count <= maximumFrameBytes
        else { throw IPCError.invalidFrame }
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let fd = descriptor
        stateLock.unlock()
        guard fd >= 0 else { throw IPCError.disconnected }
        try frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw IPCError.invalidFrame }
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent < 0 && errno == EINTR { continue }
                throw IPCError.disconnected
            }
        }
    }

    private func readLoop(fd: Int32, epoch: UUID) {
        while true {
            guard let header = try? readExactly(4, fd: fd) else { break }
            let size = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            guard size > 0, size <= maximumFrameBytes,
                let payload = try? readExactly(Int(size), fd: fd),
                let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { break }
            handle(object)
        }
        stateLock.lock()
        let isCurrent = connectionEpoch == epoch && descriptor == fd
        stateLock.unlock()
        if isCurrent { close() }
    }

    private func handle(_ message: [String: Any]) {
        if message["type"] as? String == "response",
            let id = message["requestId"] as? String
        {
            stateLock.lock()
            let waiter = pending.removeValue(forKey: id)
            waiter?.response = message
            stateLock.unlock()
            waiter?.semaphore.signal()
            return
        }
        guard message["type"] as? String == "broadcast",
            message["method"] as? String == "thread-stream-state-changed",
            message["version"] as? Int == 11,
            let sourceID = message["sourceClientId"] as? String,
            let targets = message["targetClientIds"] as? [String],
            let params = message["params"] as? [String: Any],
            params["hostId"] as? String == "local",
            let conversationID = params["conversationId"] as? String,
            let change = params["change"] as? [String: Any],
            let kind = change["type"] as? String,
            let revision = change["revision"] as? Int
        else { return }
        stateLock.lock()
        let id = clientID
        var subscription = subscriptions[conversationID]
        guard let id, targets.contains(id), subscription?.ownerClientID == sourceID else {
            stateLock.unlock()
            return
        }
        if kind == "snapshot", change["conversationState"] is [String: Any] {
            subscription?.revision = revision
        } else if kind == "patches", subscription?.revision == change["baseRevision"] as? Int,
            change["patches"] is [Any]
        {
            subscription?.revision = revision
        } else {
            stateLock.unlock()
            return
        }
        subscriptions[conversationID] = subscription
        let callback = subscription?.callback
        stateLock.unlock()
        if let callback { callbackQueue.async { callback(change) } }
    }

    private func readExactly(_ count: Int, fd: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress?.advanced(by: offset), count - offset)
            }
            if received > 0 {
                offset += received
                continue
            }
            if received < 0 && errno == EINTR { continue }
            throw IPCError.disconnected
        }
        return Data(bytes)
    }

    private func openSocket() throws -> Int32 {
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw IPCError.unavailable
        }
        let directory = (socketPath as NSString).deletingLastPathComponent
        var directoryStat = stat()
        var socketStat = stat()
        guard lstat(directory, &directoryStat) == 0,
            (directoryStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
            directoryStat.st_uid == getuid(),
            (directoryStat.st_mode & 0o077) == 0,
            lstat(socketPath, &socketStat) == 0,
            (socketStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
            socketStat.st_uid == getuid(),
            (socketStat.st_mode & 0o077) == 0
        else { throw IPCError.unsafeSocket }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.unavailable }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
        let addressLength = pathOffset + pathBytes.count
        address.sun_len = UInt8(addressLength)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                socketPath.withCString { source in
                    _ = Darwin.strlcpy(destination, source, pathBytes.count)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(addressLength))
            }
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        var currentSocketStat = stat()
        guard connected == 0,
            getpeereid(fd, &peerUID, &peerGID) == 0,
            peerUID == getuid(),
            lstat(socketPath, &currentSocketStat) == 0,
            currentSocketStat.st_dev == socketStat.st_dev,
            currentSocketStat.st_ino == socketStat.st_ino
        else {
            Darwin.close(fd)
            throw IPCError.unsafeSocket
        }
        return fd
    }
}
