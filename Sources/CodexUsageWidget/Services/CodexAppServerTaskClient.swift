import Darwin
import Foundation

enum TaskConnectionReason: Hashable {
    case startup
    case taskUI
    case popover
}

protocol CodexTaskEventClient: AnyObject {
    var onSnapshot: ((CodexTaskLiveSnapshot) -> Void)? { get set }
    func start(reason: TaskConnectionReason)
    func stopIfIdle()
    func stop()
    func refreshThreads()
    func awaitSnapshot(timeout: TimeInterval) -> CodexTaskLiveSnapshot?
}

enum POSIXPipeReaderError: Error {
    case duplicateFailed(Int32)
    case readFailed(Int32)
}

enum POSIXPipeReader {
    static func duplicateDescriptor(for handle: FileHandle) throws -> Int32 {
        let descriptor = Darwin.dup(handle.fileDescriptor)
        guard descriptor >= 0 else { throw POSIXPipeReaderError.duplicateFailed(errno) }
        return descriptor
    }

    /// Foundation's `read(upToCount:)` may wait for the full requested length on
    /// a pipe. POSIX read returns as soon as any bytes are available, which is
    /// required for long-lived app-server streams that intentionally keep stdout open.
    static func readChunk(from descriptor: Int32, maximumBytes: Int) throws -> Data? {
        precondition(maximumBytes > 0)
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 { return Data(bytes.prefix(Int(count))) }
            if count == 0 { return nil }
            let code = errno
            if code == EINTR { continue }
            throw POSIXPipeReaderError.readFailed(code)
        }
    }
}

enum POSIXPipeReaderSelfTest {
    static func run() -> Bool {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let writer = pipe.fileHandleForWriting
        guard let descriptor = try? POSIXPipeReader.duplicateDescriptor(for: reader) else {
            print("POSIX pipe reader self-test failed: could not duplicate descriptor")
            return false
        }
        defer {
            Darwin.close(descriptor)
            try? reader.close()
            try? writer.close()
        }

        let payload = Data("partial response\n".utf8)
        do {
            try writer.write(contentsOf: payload)
            let startedAt = Date()
            let result = try POSIXPipeReader.readChunk(from: descriptor, maximumBytes: 64 * 1_024)
            guard result == payload, Date().timeIntervalSince(startedAt) < 1 else {
                print("POSIX pipe reader self-test failed: partial response was not returned promptly")
                return false
            }
            try writer.close()
            guard try POSIXPipeReader.readChunk(from: descriptor, maximumBytes: 64 * 1_024) == nil else {
                print("POSIX pipe reader self-test failed: EOF was not detected")
                return false
            }
        } catch {
            print("POSIX pipe reader self-test failed: \(error)")
            return false
        }

        print("POSIX pipe reader self-test passed")
        return true
    }
}

struct CodexThreadHistorySnapshot: Equatable {
    let threadID: String
    let turnIDs: [String]

    func matches(_ baseline: CodexThreadHistorySnapshot) -> Bool {
        threadID == baseline.threadID && turnIDs == baseline.turnIDs
    }
}

enum CodexThreadHistoryError: LocalizedError {
    case invalidThread
    case unavailable
    case timedOut
    case malformedPage
    case duplicateTurn
    case repeatedCursor
    case tooLarge
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidThread: return WidgetLanguage.storedOrAutomatic().text("任务标识无效", "The task ID is invalid.")
        case .unavailable: return WidgetLanguage.storedOrAutomatic().text("Codex 分页历史接口不可用", "The Codex paginated history API is unavailable.")
        case .timedOut: return WidgetLanguage.storedOrAutomatic().text("Codex 分页历史读取超时", "Reading Codex history timed out.")
        case .malformedPage: return WidgetLanguage.storedOrAutomatic().text("Codex 分页历史格式异常", "Codex history returned an invalid page.")
        case .duplicateTurn: return WidgetLanguage.storedOrAutomatic().text("Codex 分页历史出现重复轮次", "Codex history contains duplicate turns.")
        case .repeatedCursor: return WidgetLanguage.storedOrAutomatic().text("Codex 分页历史游标重复", "Codex history repeated a page cursor.")
        case .tooLarge: return WidgetLanguage.storedOrAutomatic().text("Codex 分页历史超过安全校验上限", "Codex history exceeded the safety limit.")
        case .empty: return WidgetLanguage.storedOrAutomatic().text("Codex 分页历史为空", "Codex history is empty.")
        }
    }
}

struct CodexThreadHistoryPageAccumulator {
    // ponytail: 1,000 turn IDs bound metadata memory; raise only after a real larger history is observed.
    private static let maximumPages = 4
    private static let maximumTurns = 1_000

    let threadID: String
    private(set) var turnIDs: [String] = []
    private var seenTurnIDs: Set<String> = []
    private var seenCursors: Set<String> = []
    private var pageCount = 0

    init(threadID: String) {
        self.threadID = threadID
    }

    mutating func append(result: [String: Any]) throws -> String? {
        guard let turns = result["data"] as? [[String: Any]] else {
            throw CodexThreadHistoryError.malformedPage
        }
        pageCount += 1
        guard pageCount <= Self.maximumPages,
            turnIDs.count + turns.count <= Self.maximumTurns
        else {
            throw CodexThreadHistoryError.tooLarge
        }
        for turn in turns {
            guard let turnID = turn["id"] as? String,
                !turnID.isEmpty
            else {
                throw CodexThreadHistoryError.malformedPage
            }
            guard seenTurnIDs.insert(turnID).inserted else {
                throw CodexThreadHistoryError.duplicateTurn
            }
            turnIDs.append(turnID)
        }

        let rawCursor = result["nextCursor"] ?? result["next_cursor"]
        guard let rawCursor, !(rawCursor is NSNull) else { return nil }
        guard let cursor = rawCursor as? String, !cursor.isEmpty else {
            throw CodexThreadHistoryError.malformedPage
        }
        guard !turns.isEmpty, seenCursors.insert(cursor).inserted else {
            throw turns.isEmpty
                ? CodexThreadHistoryError.malformedPage
                : CodexThreadHistoryError.repeatedCursor
        }
        return cursor
    }

    func snapshot() throws -> CodexThreadHistorySnapshot {
        guard !turnIDs.isEmpty else { throw CodexThreadHistoryError.empty }
        return CodexThreadHistorySnapshot(threadID: threadID, turnIDs: turnIDs)
    }
}

enum CodexThreadHistoryProbeSelfTest {
    static func run() -> Bool {
        var accumulator = CodexThreadHistoryPageAccumulator(threadID: "thread")
        do {
            guard
                try accumulator.append(result: [
                    "data": [["id": "new"], ["id": "middle"]],
                    "nextCursor": "older-page",
                ]) == "older-page",
                try accumulator.append(result: [
                    "data": [["id": "old"]],
                    "nextCursor": NSNull(),
                ]) == nil
            else {
                print("Codex thread history probe self-test failed: pagination")
                return false
            }
            let snapshot = try accumulator.snapshot()
            guard snapshot.turnIDs == ["new", "middle", "old"],
                snapshot.matches(snapshot),
                !snapshot.matches(
                    CodexThreadHistorySnapshot(
                        threadID: "thread",
                        turnIDs: ["new", "old"]
                    ))
            else {
                print("Codex thread history probe self-test failed: fingerprint")
                return false
            }
        } catch {
            print("Codex thread history probe self-test failed: \(error.localizedDescription)")
            return false
        }

        var duplicate = CodexThreadHistoryPageAccumulator(threadID: "thread")
        do {
            _ = try duplicate.append(result: ["data": [["id": "same"]], "nextCursor": "next"])
            _ = try duplicate.append(result: ["data": [["id": "same"]], "nextCursor": NSNull()])
            print("Codex thread history probe self-test failed: duplicate accepted")
            return false
        } catch CodexThreadHistoryError.duplicateTurn {
            print("Codex thread history probe self-test passed")
            return true
        } catch {
            print("Codex thread history probe self-test failed: wrong duplicate error")
            return false
        }
    }
}

enum CodexThreadHistoryProbe {
    private static let maximumOutputBufferBytes = 2 * 1_024 * 1_024
    private static let pageSize = 250

    /// Reads only turn IDs and cursors. `itemsView=notLoaded` keeps message bodies out of this process.
    static func capture(
        threadID: String,
        timeout: TimeInterval = 15
    ) -> Result<CodexThreadHistorySnapshot, CodexThreadHistoryError> {
        guard !Thread.isMainThread else { return .failure(.unavailable) }
        guard CodexSessionLink.url(threadID: threadID) != nil else { return .failure(.invalidThread) }
        guard let executable = CodexExecutable.path() else { return .failure(.unavailable) }

        CodexCredentialAccessGate.lock.lock()
        defer { CodexCredentialAccessGate.lock.unlock() }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(.unavailable)
        }

        let inputHandle = input.fileHandleForWriting
        let outputHandle = output.fileHandleForReading
        guard let outputDescriptor = try? POSIXPipeReader.duplicateDescriptor(for: outputHandle) else {
            try? inputHandle.close()
            if process.isRunning { process.terminate() }
            try? outputHandle.close()
            return .failure(.unavailable)
        }

        let writeLock = NSLock()
        var acceptsWrites = true
        @discardableResult
        func writeMessage(_ request: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: request) else { return false }
            writeLock.lock()
            defer { writeLock.unlock() }
            guard acceptsWrites else { return false }
            do {
                try inputHandle.write(contentsOf: data)
                try inputHandle.write(contentsOf: Data("\n".utf8))
                return true
            } catch {
                acceptsWrites = false
                return false
            }
        }

        let resultLock = NSLock()
        let completed = DispatchSemaphore(value: 0)
        var finalResult: Result<CodexThreadHistorySnapshot, CodexThreadHistoryError>?
        func finish(_ result: Result<CodexThreadHistorySnapshot, CodexThreadHistoryError>) {
            resultLock.lock()
            let shouldSignal = finalResult == nil
            if shouldSignal { finalResult = result }
            resultLock.unlock()
            if shouldSignal { completed.signal() }
        }

        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer {
                Darwin.close(outputDescriptor)
                finish(.failure(.unavailable))
                readerFinished.signal()
            }
            var buffer = Data()
            var accumulator = CodexThreadHistoryPageAccumulator(threadID: threadID)
            var historyRequestID: Int64 = 2

            func sendHistoryPage(cursor: String?) {
                var params: [String: Any] = [
                    "threadId": threadID,
                    "limit": pageSize,
                    "sortDirection": "desc",
                    "itemsView": "notLoaded",
                ]
                if let cursor { params["cursor"] = cursor }
                guard
                    writeMessage([
                        "id": historyRequestID,
                        "method": "thread/turns/list",
                        "params": params,
                    ])
                else {
                    finish(.failure(.unavailable))
                    return
                }
            }

            func responseID(_ value: Any?) -> Int64? {
                if let value = value as? Int { return Int64(value) }
                if let value = value as? Int64 { return value }
                if let value = value as? NSNumber { return value.int64Value }
                return nil
            }

            func parseLine(_ line: Data) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let requestID = responseID(object["id"])
                else { return }
                if requestID == 1 {
                    guard object["error"] == nil,
                        writeMessage(["method": "initialized"])
                    else {
                        finish(.failure(.unavailable))
                        return
                    }
                    sendHistoryPage(cursor: nil)
                    return
                }
                guard requestID == historyRequestID else { return }
                guard object["error"] == nil,
                    let result = object["result"] as? [String: Any]
                else {
                    finish(.failure(.unavailable))
                    return
                }
                do {
                    if let nextCursor = try accumulator.append(result: result) {
                        historyRequestID &+= 1
                        sendHistoryPage(cursor: nextCursor)
                    } else {
                        finish(.success(try accumulator.snapshot()))
                    }
                } catch let error as CodexThreadHistoryError {
                    finish(.failure(error))
                } catch {
                    finish(.failure(.malformedPage))
                }
            }

            while true {
                let data: Data
                do {
                    guard
                        let next = try POSIXPipeReader.readChunk(
                            from: outputDescriptor,
                            maximumBytes: 64 * 1_024
                        )
                    else { return }
                    data = next
                } catch {
                    return
                }
                buffer.append(data)
                guard buffer.count <= maximumOutputBufferBytes else {
                    finish(.failure(.tooLarge))
                    return
                }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { parseLine(line) }
                    resultLock.lock()
                    let isComplete = finalResult != nil
                    resultLock.unlock()
                    if isComplete { return }
                }
            }
        }

        if !writeMessage([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-account-manager-next",
                    "title": "Codex Account Manager Next",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "optOutNotificationMethods": [],
                ],
            ],
        ]) {
            finish(.failure(.unavailable))
        }

        if completed.wait(timeout: .now() + timeout) == .timedOut {
            finish(.failure(.timedOut))
        }
        writeLock.lock()
        acceptsWrites = false
        try? inputHandle.close()
        writeLock.unlock()
        if process.isRunning { process.terminate() }
        try? outputHandle.close()
        _ = readerFinished.wait(timeout: .now() + 1)
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        resultLock.lock()
        let result = finalResult ?? .failure(.unavailable)
        resultLock.unlock()
        return result
    }
}

final class CodexAppServerTaskClient: CodexTaskEventClient {
    private struct PendingThreadListCompletion {
        let id: UUID
        let callback: (CodexTaskLiveSnapshot?) -> Void
    }

    private struct PendingThreadListToken {
        let requestID: Int64
        let completionID: UUID
    }

    private final class SnapshotWaiter {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var snapshot: CodexTaskLiveSnapshot?
        private var didFinish = false
        private var token: PendingThreadListToken?

        func register(_ token: PendingThreadListToken?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didFinish else { return false }
            self.token = token
            return true
        }

        func finish(_ snapshot: CodexTaskLiveSnapshot?) {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            self.snapshot = snapshot
            didFinish = true
            lock.unlock()
            semaphore.signal()
        }

        func cancel() -> PendingThreadListToken? {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return nil
            }
            didFinish = true
            let token = self.token
            self.token = nil
            lock.unlock()
            return token
        }

        func value() -> CodexTaskLiveSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }
    }

    private final class PauseRequestAdmission: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !cancelled
        }
    }

    var onSnapshot: ((CodexTaskLiveSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.blackielf.codex-account-manager-next.task-app-server", qos: .utility)
    private let fileManager: FileManager
    private let homeDirectory: URL
    private var webSocket: AFUnixWebSocket?
    private var isConnected = false
    private var reducer = TaskRuntimeReducer()
    private var connectionMode: TaskConnectionMode = .disconnected
    private var activeReasons: Set<TaskConnectionReason> = []
    private var nextRequestID: Int64 = 100
    private var pendingThreadListIDs: Set<Int64> = []
    private var pendingThreadListSpans: [Int64: PerformanceSpan] = [:]
    private var pendingThreadListTimeouts: [Int64: DispatchWorkItem] = [:]
    private var pendingThreadListCompletions: [Int64: [PendingThreadListCompletion]] = [:]
    private var pendingThreadListRequestGenerations: [Int64: UInt64] = [:]
    private var pendingPauseRequests: [Int64: ([String: Any]?) -> Void] = [:]
    private var pendingPauseTimeouts: [Int64: DispatchWorkItem] = [:]
    private var initializeTimeout: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var hasRetriedConnection = false
    private var isStopping = false
    private var connectionGeneration: UInt64 = 0

    private let initializeRequestID: Int64 = 1
    private let maximumOutputBufferBytes = 1 * 1_024 * 1_024
    private let maximumThreadListCount = 1_000
    private let threadListTimeoutSeconds: TimeInterval = 10

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func start(reason: TaskConnectionReason) {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeReasons.insert(reason)
            if self.isConnected || self.webSocket != nil {
                if reason != .startup { self.requestThreadList() }
                return
            }

            let sharedDaemonAvailable = self.fileManager.fileExists(atPath: self.defaultDaemonSocket.path)
            guard sharedDaemonAvailable else { return }
            self.hasRetriedConnection = false
            self.launch(mode: .sharedDaemon)
        }
    }

    func stopIfIdle() {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeReasons.remove(.taskUI)
            self.activeReasons.remove(.popover)
            if self.connectionMode == .isolated {
                self.stopProcess()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.activeReasons.removeAll()
            self?.stopProcess()
        }
    }

    func refreshThreads() {
        queue.async { [weak self] in
            self?.requestThreadList()
        }
    }

    func awaitSnapshot(timeout: TimeInterval = 8) -> CodexTaskLiveSnapshot? {
        let waiter = SnapshotWaiter()
        queue.async { [weak self] in
            guard let self else {
                waiter.finish(nil)
                return
            }
            let token = self.requestThreadList { snapshot in
                waiter.finish(snapshot)
            }
            if !waiter.register(token), let token {
                self.removePendingThreadListCompletion(token)
            }
        }
        guard waiter.semaphore.wait(timeout: .now() + timeout) == .success else {
            if let token = waiter.cancel() {
                queue.async { [weak self] in self?.removePendingThreadListCompletion(token) }
            }
            return nil
        }
        return waiter.value()
    }

    /// Pausing never grants access to login, credentials or prompt submission.
    func desktopPauseRequest(_ method: String, params: [String: Any]) async -> [String: Any]? {
        guard ["thread/loaded/list", "thread/read", "thread/turns/list", "turn/interrupt"].contains(method)
        else { return nil }
        return await desktopQuotaRequest(method, params: params)
    }

    /// Only the persisted continuation coordinator may submit a continuation in
    /// an existing, verified thread. No thread/start or authentication RPC exists.
    func desktopResumeRequest(_ method: String, params: [String: Any]) async -> [String: Any]? {
        guard ["thread/read", "thread/resume", "thread/turns/list", "turn/start"].contains(method)
        else { return nil }
        return await desktopQuotaRequest(method, params: params)
    }

    /// A single empty thread, requested only after the WeChat controller has
    /// durably reserved the paired user's dedicated binding. No settings or
    /// authentication overrides, and no model turn is submitted by this client.
    func createPersonalWeChatThread(admission: WeChatCodexSendAdmission) async -> WeChatCodexThreadCreation {
        guard admission.isActive, !Task.isCancelled else { return .unavailable }
        let workspace = homeDirectory.appendingPathComponent(
            "Library/Application Support/CodexAccountManagerNext/PersonalWeChat/Workspace", isDirectory: true)
        guard workspace.standardizedFileURL == workspace.resolvingSymlinksInPath().standardizedFileURL else { return .unavailable }
        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return .unavailable }
        let result = await desktopQuotaRequest(
            "thread/start", params: ["cwd": workspace.path, "ephemeral": false], shouldSend: { admission.isActive },
            onSend: { admission.markRequestAttempted() })
        guard let thread = (result?["thread"] as? [String: Any])?["id"] as? String,
            UUID(uuidString: thread) != nil
        else { return admission.wasRequestAttempted ? .uncertain : .unavailable }
        // Even a cancellation after creation must return the ID for durable
        // recovery. Naming is optional; its failure must not trigger creation.
        if admission.isActive, !Task.isCancelled {
            _ = await desktopQuotaRequest(
                "thread/name/set", params: ["threadId": thread, "name": "微信专用对话"], shouldSend: { admission.isActive })
        }
        return .created(thread)
    }

    private func desktopQuotaRequest(
        _ method: String, params: [String: Any], shouldSend: @escaping () -> Bool = { true }, onSend: (() -> Void)? = nil
    ) async -> [String: Any]? {
        guard !Task.isCancelled, shouldSend() else { return nil }
        let admission = PauseRequestAdmission()
        return await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    queue.async { [weak self] in
                        guard admission.isActive, shouldSend(), let self, self.isConnected, self.connectionMode == .sharedDaemon,
                            self.initializeTimeout == nil, self.webSocket != nil
                        else {
                            continuation.resume(returning: nil)
                            return
                        }
                        let id = self.nextRequestID
                        self.nextRequestID &+= 1
                        self.pendingPauseRequests[id] = { continuation.resume(returning: $0) }
                        let timeout = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            self.pendingPauseTimeouts.removeValue(forKey: id)
                            self.pendingPauseRequests.removeValue(forKey: id)?(nil)
                        }
                        self.pendingPauseTimeouts[id] = timeout
                        self.queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                        onSend?()
                        if !self.writeJSONObject(["id": id, "method": method, "params": params]) {
                            self.pendingPauseTimeouts.removeValue(forKey: id)?.cancel()
                            self.pendingPauseRequests.removeValue(forKey: id)?(nil)
                        }
                    }
                }
            }, onCancel: { admission.cancel() })
    }

    private var defaultDaemonSocket: URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("app-server-control", isDirectory: true)
            .appendingPathComponent("app-server-control.sock")
    }

    private func launch(mode: TaskConnectionMode) {
        isStopping = false
        pendingThreadListIDs.removeAll()
        pendingThreadListSpans.removeAll()
        pendingThreadListTimeouts.values.forEach { $0.cancel() }
        pendingThreadListTimeouts.removeAll()
        pendingThreadListCompletions.removeAll()
        pendingThreadListRequestGenerations.removeAll()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionMode = .disconnected
        isConnected = false
        let webSocket = AFUnixWebSocket(
            socketPath: defaultDaemonSocket.path,
            maximumMessageBytes: maximumOutputBufferBytes,
            callbackQueue: queue
        )
        self.webSocket = webSocket
        webSocket.start(
            onReady: { [weak self, weak webSocket] in
                guard let self, let webSocket,
                    self.connectionGeneration == generation,
                    self.webSocket === webSocket
                else { return }
                self.isConnected = true
                self.connectionMode = mode
                guard
                    self.writeJSONObject([
                        "id": self.initializeRequestID,
                        "method": "initialize",
                        "params": [
                            "clientInfo": [
                                "name": "codex-account-manager-next",
                                "title": "Codex Account Manager Next",
                                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                            ],
                            "capabilities": [
                                "experimentalApi": false,
                                "optOutNotificationMethods": [],
                            ],
                        ],
                    ])
                else {
                    self.handleDisconnect(generation: generation)
                    return
                }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.connectionGeneration == generation,
                        self.initializeTimeout != nil
                    else { return }
                    self.handleDisconnect(generation: generation)
                }
                self.initializeTimeout = timeout
                self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
            },
            onMessage: { [weak self] data in
                guard let self, self.connectionGeneration == generation,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                self.handle(object)
            },
            onDisconnect: { [weak self] in
                debugLog("AFUnixWebSocket: onDisconnect received generation=\(generation)")
                self?.handleDisconnect(generation: generation)
            }
        )
    }

    private func handle(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            guard object["id"] == nil else { return }
            let params = object["params"] as? [String: Any] ?? [:]
            if reducer.applyNotification(method: method, params: params) {
                publishSnapshot()
            }
            return
        }

        guard let responseID = Self.integerID(object["id"]) else { return }
        if responseID == initializeRequestID {
            initializeTimeout?.cancel()
            initializeTimeout = nil
            guard object["error"] == nil else {
                handleDisconnect()
                return
            }
            _ = writeJSONObject(["method": "initialized"])
            requestThreadList()
            return
        }

        if let completion = pendingPauseRequests.removeValue(forKey: responseID) {
            pendingPauseTimeouts.removeValue(forKey: responseID)?.cancel()
            completion(object["error"] == nil ? object["result"] as? [String: Any] : nil)
            return
        }
        guard pendingThreadListIDs.remove(responseID) != nil else { return }
        pendingThreadListTimeouts.removeValue(forKey: responseID)?.cancel()
        let completions = (pendingThreadListCompletions.removeValue(forKey: responseID) ?? [])
            .map(\.callback)
        let requestGeneration = pendingThreadListRequestGenerations.removeValue(forKey: responseID)
        let span = pendingThreadListSpans.removeValue(forKey: responseID)
        guard let result = object["result"] as? [String: Any],
            let threads = result["data"] as? [[String: Any]]
        else {
            if let span {
                PerformanceMonitor.shared.end(span, success: false)
            }
            completions.forEach { $0(nil) }
            return
        }

        if let span {
            PerformanceMonitor.shared.end(span)
        }
        let nextCursor =
            (result["nextCursor"] as? String)
            ?? (result["next_cursor"] as? String)
        guard threads.count < maximumThreadListCount,
            nextCursor?.isEmpty != false
        else {
            reducer.disconnect()
            publishSnapshot()
            completions.forEach { $0(nil) }
            return
        }
        reducer.replaceThreads(
            threads,
            connectionMode: connectionMode,
            requestGeneration: requestGeneration
        )
        let snapshot = reducer.snapshot()
        publishSnapshot(snapshot)
        completions.forEach { $0(snapshot) }
    }

    @discardableResult
    private func requestThreadList(completion: ((CodexTaskLiveSnapshot?) -> Void)? = nil) -> PendingThreadListToken? {
        guard isConnected, webSocket != nil, initializeTimeout == nil else {
            completion?(nil)
            return nil
        }
        if let pendingID = pendingThreadListIDs.first {
            if let completion {
                let completionID = UUID()
                pendingThreadListCompletions[pendingID, default: []].append(
                    PendingThreadListCompletion(id: completionID, callback: completion)
                )
                return PendingThreadListToken(requestID: pendingID, completionID: completionID)
            }
            return nil
        }
        let requestID = nextRequestID
        nextRequestID &+= 1
        pendingThreadListIDs.insert(requestID)
        pendingThreadListRequestGenerations[requestID] = reducer.currentNotificationGeneration
        var completionToken: PendingThreadListToken?
        if let completion {
            let completionID = UUID()
            pendingThreadListCompletions[requestID] = [
                PendingThreadListCompletion(id: completionID, callback: completion)
            ]
            completionToken = PendingThreadListToken(requestID: requestID, completionID: completionID)
        }
        pendingThreadListSpans[requestID] = PerformanceMonitor.shared.begin(.appServerTasks)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                self.pendingThreadListIDs.remove(requestID) != nil
            else { return }
            self.pendingThreadListTimeouts.removeValue(forKey: requestID)
            let completions = (self.pendingThreadListCompletions.removeValue(forKey: requestID) ?? [])
                .map(\.callback)
            self.pendingThreadListRequestGenerations.removeValue(forKey: requestID)
            if let span = self.pendingThreadListSpans.removeValue(forKey: requestID) {
                PerformanceMonitor.shared.end(span, success: false)
            }
            completions.forEach { $0(nil) }
        }
        pendingThreadListTimeouts[requestID] = timeout
        queue.asyncAfter(deadline: .now() + threadListTimeoutSeconds, execute: timeout)
        let wrote = writeJSONObject([
            "id": requestID,
            "method": "thread/list",
            "params": [
                "limit": maximumThreadListCount,
                "sortKey": "recency_at",
                "sortDirection": "desc",
                "useStateDbOnly": true,
            ],
        ])
        if !wrote {
            pendingThreadListIDs.remove(requestID)
            pendingThreadListTimeouts.removeValue(forKey: requestID)?.cancel()
            let completions = (pendingThreadListCompletions.removeValue(forKey: requestID) ?? [])
                .map(\.callback)
            pendingThreadListRequestGenerations.removeValue(forKey: requestID)
            if let span = pendingThreadListSpans.removeValue(forKey: requestID) {
                PerformanceMonitor.shared.end(span, success: false)
            }
            completions.forEach { $0(nil) }
            handleDisconnect()
        }
        return completionToken
    }

    private func removePendingThreadListCompletion(_ token: PendingThreadListToken) {
        guard var completions = pendingThreadListCompletions[token.requestID] else { return }
        completions.removeAll { $0.id == token.completionID }
        if completions.isEmpty {
            pendingThreadListCompletions.removeValue(forKey: token.requestID)
        } else {
            pendingThreadListCompletions[token.requestID] = completions
        }
    }

    private func writeJSONObject(_ object: [String: Any]) -> Bool {
        guard let webSocket,
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return false }
        return webSocket.sendText(data)
    }

    private func publishSnapshot(_ snapshot: CodexTaskLiveSnapshot? = nil) {
        let snapshot = snapshot ?? reducer.snapshot()
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(snapshot)
        }
    }

    private func handleDisconnect(generation: UInt64? = nil) {
        if let generation, generation != connectionGeneration { return }
        guard connectionMode != .disconnected || webSocket != nil else { return }
        initializeTimeout?.cancel()
        initializeTimeout = nil
        let disconnectedSocket = webSocket
        webSocket = nil
        isConnected = false
        pendingThreadListIDs.removeAll()
        pendingThreadListTimeouts.values.forEach { $0.cancel() }
        pendingThreadListTimeouts.removeAll()
        let pendingCompletions = pendingThreadListCompletions.values
            .flatMap { $0 }
            .map(\.callback)
        pendingThreadListCompletions.removeAll()
        pendingThreadListRequestGenerations.removeAll()
        pendingCompletions.forEach { $0(nil) }
        for span in pendingThreadListSpans.values {
            PerformanceMonitor.shared.end(span, success: false)
        }
        pendingThreadListSpans.removeAll()
        pendingPauseTimeouts.values.forEach { $0.cancel() }
        pendingPauseTimeouts.removeAll()
        let pauseCompletions = Array(pendingPauseRequests.values)
        pendingPauseRequests.removeAll()
        pauseCompletions.forEach { $0(nil) }
        connectionMode = .disconnected
        reducer.disconnect()
        publishSnapshot()
        disconnectedSocket?.close()
        scheduleReconnectIfNeeded()
    }

    private func stopProcess() {
        guard !isStopping else { return }
        isStopping = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        initializeTimeout?.cancel()
        initializeTimeout = nil
        handleDisconnect()
        isStopping = false
    }

    private func scheduleReconnectIfNeeded() {
        guard !isStopping, !activeReasons.isEmpty, !hasRetriedConnection,
            reconnectWorkItem == nil
        else { return }
        hasRetriedConnection = true
        debugLog("AFUnixWebSocket: scheduling reconnect in 30 seconds")
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.activeReasons.isEmpty,
                self.fileManager.fileExists(atPath: self.defaultDaemonSocket.path),
                self.webSocket == nil
            else { return }
            debugLog("AFUnixWebSocket: starting 30-second reconnect attempt")
            self.launch(mode: .sharedDaemon)
        }
        reconnectWorkItem = retry
        queue.asyncAfter(deadline: .now() + 30, execute: retry)
    }

    private static func integerID(_ value: Any?) -> Int64? {
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}
