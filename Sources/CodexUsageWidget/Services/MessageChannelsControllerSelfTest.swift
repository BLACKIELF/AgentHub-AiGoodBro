import Foundation

/// Real controller sequences with deferred storage and HTTP completions.
/// No Keychain access or network transport is created.
enum MessageChannelsControllerSelfTest {
    private final class Storage: MessageChannelCredentialStoring {
        var loads: [(MessageChannelKind, (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void)] = []
        var saves: [(MessageChannelCredential, MessageChannelKind, (Result<Void, FeishuWebhookError>) -> Void)] = []
        func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) {
            loads.append((kind, completion))
        }
        func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
            saves.append((value, kind, completion))
        }
        func resolve(_ value: MessageChannelCredential?, at index: Int = 0) { loads.remove(at: index).1(.success(value)) }
    }
    private final class Transport: MessageChannelTransport {
        private let lock = NSLock()
        private var pending: [(URLRequest, CheckedContinuation<(Data, HTTPURLResponse), Error>)] = []
        private var sent: [URLRequest] = []
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return sent.count
        }
        var lastRequest: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return sent.last
        }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                sent.append(request)
                pending.append((request, continuation))
                lock.unlock()
            }
        }
        func completeAll(status: Int = 200) {
            lock.lock()
            let callbacks = pending
            pending.removeAll()
            lock.unlock()
            for (request, callback) in callbacks {
                let body = request.url?.host == "api.telegram.org" ? #"{"ok":true,"result":{"message_id":17}}"# : #"{"errcode":0}"#
                callback.resume(returning: (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
            }
        }
    }
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { failures.append(name) } }
        func spin(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let suite = "message-channel-controller-fixture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = Storage()
        let transport = Transport()
        let controller = MessageChannelsController(defaults: defaults, storage: storage, transport: { transport })
        let telegram = MessageChannelCredential(secret: "1234567890:AAExampleSyntheticToken0000000000000", target: "-100200300")
        let changed = MessageChannelCredential(secret: "1234567890:AAExampleSyntheticToken0000000000001", target: "-100200301")
        let weChat = MessageChannelCredential(secret: "01234567-89ab-cdef-0123-456789abcdef", target: nil)
        defer {
            controller.stop()
            transport.completeAll()
            settle()
        }
        controller.start()
        controller.sendTest(.telegram)
        settle()
        expect(!controller.telegramEnabled && !controller.weChatEnabled, "channels default off")
        expect(storage.loads.isEmpty && storage.saves.isEmpty && transport.count == 0, "default off performs no credential or network I/O")

        controller.setEnabled(true, for: .telegram)
        controller.setEnabled(false, for: .telegram)
        controller.setEnabled(true, for: .telegram)
        expect(storage.loads.count == 2, "each enabled revision loads once")
        storage.resolve(changed, at: 1)
        storage.resolve(telegram)
        controller.sendTest(.telegram)
        spin { transport.count == 1 }
        expect(transport.lastRequest?.url?.path.contains(changed.secret) == true, "late credential read cannot replace the new target")
        expect(controller.telegramPhase == .pendingVerification, "loading is not API verification")
        transport.completeAll()
        spin { controller.telegramPhase == .ready }
        expect(controller.telegramPhase == .ready && controller.weChatPhase == .disabled, "test verifies only its own channel")

        controller.sendTest(.telegram)
        spin { transport.count == 2 }
        controller.setEnabled(false, for: .telegram)
        transport.completeAll()
        settle()
        expect(controller.telegramPhase == .disabled, "disabled channel ignores in-flight success")
        controller.setEnabled(true, for: .telegram)
        storage.resolve(telegram)
        var saved = false
        controller.save(secret: changed.secret, target: changed.target, for: .telegram) { saved = $0 }
        expect(controller.actionInFlight && storage.saves.count == 1, "save waits for storage acknowledgement")
        controller.sendTest(.telegram)
        settle()
        expect(transport.count == 2, "no send during credential write")
        guard storage.saves.count == 1 else {
            failures.forEach { print("Message channel controller self-test failed: \($0)") }
            return false
        }
        storage.saves.removeFirst().2(.success(()))
        expect(saved && !controller.actionInFlight && controller.telegramPhase == .pendingVerification, "saved configuration requires verification")
        controller.sendTest(.telegram)
        spin { transport.count == 3 }
        transport.completeAll(status: 401)
        settle()
        expect(controller.telegramPhase == .pendingVerification, "HTTP rejection cannot verify channel")

        controller.sendTest(.telegram)
        spin { transport.count == 4 }
        controller.stop()
        controller.start()
        storage.resolve(changed)
        transport.completeAll()
        settle()
        expect(controller.telegramPhase == .pendingVerification, "stop/start invalidates delivery receipt")
        controller.setEnabled(true, for: .weChat)
        storage.resolve(weChat)
        let now = Date()
        func snapshot(_ state: TaskRuntimeState, turn: String = "fixture-turn") -> CodexTaskLiveSnapshot {
            CodexTaskLiveSnapshot(
                connectionMode: .sharedDaemon,
                records: [
                    "fixture-thread": TaskLiveRecord(
                        threadID: "fixture-thread", name: nil, state: state,
                        updatedAt: state == .running ? now.addingTimeInterval(-10) : now,
                        turnID: turn, connectionMode: .sharedDaemon)
                ], refreshedAt: now)
        }
        controller.observeTaskSnapshot(snapshot(.completed))
        settle()
        expect(transport.count == 4, "initial completed snapshot stays silent")
        controller.observeTaskSnapshot(snapshot(.running))
        controller.observeTaskSnapshot(snapshot(.completed))
        spin { transport.count == 6 }
        expect(transport.count == 6, "both opted-in channels receive completion")
        transport.completeAll()
        settle()
        controller.observeTaskSnapshot(snapshot(.completed))
        settle()
        expect(transport.count == 6, "repeated completion stays silent on both channels")

        controller.setEnabled(false, for: .weChat)
        controller.observeTaskSnapshot(snapshot(.running, turn: "second-turn"))
        controller.setEnabled(true, for: .weChat)
        storage.resolve(weChat)
        controller.observeTaskSnapshot(snapshot(.completed, turn: "second-turn"))
        spin { transport.count == 7 }
        expect(transport.count == 7, "new opt-in cannot inherit another channel's running evidence")
        transport.completeAll()
        settle()
        controller.setEnabled(false, for: .weChat)
        for _ in 0..<5 {
            guard let status = try? MessageTaskStatus(eventKind: .taskStateChange, taskLabel: MessageChannelTaskLabel("Codex"), taskState: .completed, occurredAt: Date()) else {
                failures.append("valid task label creates a sendable status")
                failures.forEach { print("Message channel controller self-test failed: \($0)") }
                return false
            }
            controller.send(status)
        }
        spin { transport.count >= 11 }
        expect(transport.count == 11, "in-flight sends bounded to four")
        transport.completeAll()
        settle()
        controller.sendTest(.telegram)
        spin { transport.count == 12 }
        transport.completeAll(status: 401)
        settle()
        expect(controller.telegramPhase == .pendingVerification, "later rejection removes previous verified status")
        let reloaded = MessageChannelsController(defaults: defaults, storage: storage, transport: { transport })
        expect(reloaded.telegramEnabled && !reloaded.weChatEnabled, "enabled flags persist")
        if failures.isEmpty {
            print("Message channel controller self-test passed: opt-in, persistence, callback revisions, independent completion and bounded sends")
        } else {
            failures.forEach { print("Message channel controller self-test failed: \($0)") }
        }
        return failures.isEmpty
    }
}
