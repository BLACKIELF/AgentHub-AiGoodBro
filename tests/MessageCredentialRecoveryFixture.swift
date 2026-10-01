import Foundation
import Security

/// Uses only held storage callbacks and synthetic credential bytes.
@main
struct MessageCredentialRecoveryFixture {
    final class Storage: MessageChannelCredentialStoring {
        var readResult: Result<MessageChannelCredential?, FeishuWebhookError> = .failure(.keychainAuthorizationRequired)
        var pending: MessageCredentialReadRequest?
        var authorizations = 0
        var reads = 0
        var writes = 0
        func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) {
            reads += 1
            completion(readResult)
        }
        func authorizeStored(_ kind: MessageChannelKind, request: MessageCredentialReadRequest) {
            precondition(pending == nil)
            authorizations += 1
            precondition(request.begin())
            pending = request
        }
        func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
            writes += 1
            preconditionFailure("Recovery must not write a credential")
        }
        @MainActor func finish(_ result: Result<MessageChannelCredential?, FeishuWebhookError>) async {
            let callback = pending!
            pending = nil
            callback.finish(result)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
    final class NoNetwork: MessageChannelTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
    }
    static func credential(fresh: Bool = false) throws -> MessageChannelCredential {
        let binding = PersonalWeChatBinding(
            baseURL: URL(string: "https://ilinkai.weixin.qq.com")!, botID: "synthetic-bot",
            contextToken: fresh ? "synthetic-context" : nil,
            contextCheckedAt: fresh ? Date() : nil)
        return try MessageChannelCredential(secret: "synthetic-binding", target: "synthetic-owner", personalBinding: binding).validated(for: .personalWeChat)
    }
    @MainActor static func main() async throws {
        let suite = "wechat-recovery-fixture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = Storage()
        let ledgerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-recovery-ledger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: ledgerDirectory) }
        let controller = MessageChannelsController(
            defaults: defaults, storage: storage,
            transport: { NoNetwork() }, personalTransport: { NoNetwork() },
            botLedger: WeChatBotEventLedger(directory: ledgerDirectory))
        controller.start()
        controller.setEnabled(true, for: .personalWeChat)
        precondition(storage.reads == 1 && storage.authorizations == 0)
        precondition(controller.personalWeChatNeedsAuthorization && !controller.personalWeChatConnected)
        precondition(!controller.personalWeChatBindingMissing)
        let weChatStatus = controller.personalWeChatStatusText
        precondition(weChatStatus?.contains("Feishu") == false && weChatStatus?.contains("飞书") == false)
        controller.setEnabled(true, for: .telegram)
        precondition(controller.personalWeChatStatusText == weChatStatus, "Another channel overwrote WeChat status")
        controller.setEnabled(false, for: .telegram)

        controller.restorePersonalWeChatConnection()
        precondition(controller.actionInFlight && controller.personalWeChatRestoreInProgress)
        controller.restorePersonalWeChatConnection()
        controller.connectPersonalWeChat()
        precondition(storage.authorizations == 1 && !controller.personalLoginInProgress)
        await storage.finish(.success(try credential()))
        precondition(!controller.actionInFlight && !controller.personalWeChatRestoreInProgress)
        precondition(controller.personalWeChatConnected && !controller.personalWeChatHasContext)
        precondition(!controller.personalWeChatNeedsAuthorization && !controller.personalWeChatBindingMissing)
        controller.stop()  // Stop before its synthetic monitor can run.
        controller.start()

        for error in [FeishuWebhookError.keychainBusy, .keychainTimedOut, .keychainAuthorizationRequired] {
            controller.restorePersonalWeChatConnection()
            await storage.finish(.failure(error))
            precondition(!controller.personalWeChatBindingMissing && !controller.personalLoginInProgress)
            precondition(!controller.personalWeChatConnected && !controller.actionInFlight)
            let status = controller.personalWeChatStatusText ?? ""
            precondition(!status.contains("expired") && !status.contains("失效") && !status.contains("飞书"))
        }
        controller.restorePersonalWeChatConnection()
        await storage.finish(.success(nil))
        precondition(controller.personalWeChatBindingMissing && !controller.personalWeChatNeedsAuthorization)
        precondition(!controller.personalWeChatConnected)

        // Superseded reads cannot reconnect a disabled, cancelled or restarted controller.
        for invalidation in 0..<3 {
            controller.restorePersonalWeChatConnection()
            switch invalidation {
            case 0: controller.setEnabled(false, for: .personalWeChat)
            case 1: controller.cancelPersonalWeChatLogin()
            default:
                controller.stop()
                controller.start()
            }
            let before = controller.personalWeChatStatusText
            precondition(controller.actionInFlight, "Pending system dialog must prevent another authorization")
            controller.restorePersonalWeChatConnection()
            await storage.finish(.success(try credential(fresh: true)))
            precondition(!controller.personalWeChatConnected && !controller.personalWeChatHasContext)
            precondition(!controller.actionInFlight && controller.personalWeChatStatusText == before)
            if invalidation == 0 { controller.setEnabled(true, for: .personalWeChat) }
        }
        controller.restorePersonalWeChatConnection()
        await storage.finish(.success(try credential(fresh: true)))
        precondition(controller.personalWeChatConnected && controller.personalWeChatHasContext)
        controller.stop()
        precondition(storage.writes == 0)
        print("PASS saved WeChat recovery: explicit-only authorization, no QR/write, distinct missing/auth/busy/timeout, scoped status, duplicate and stale callback gates")

        try await settingsTextDelivery()
        try await keychainPolicy()
        await queuedAuthorization()
        try await MessageTestAdmissionFixture.run()
    }
    final class TextTransport: MessageChannelTransport {
        private let lock = NSLock()
        private var pending: (URLRequest, CheckedContinuation<(Data, HTTPURLResponse), Error>)?
        private var captured: [URLRequest] = []
        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                precondition(pending == nil)
                captured.append(request)
                pending = (request, continuation)
                lock.unlock()
            }
        }
        func finish() {
            lock.lock()
            let (request, continuation) = pending!
            pending = nil
            lock.unlock()
            continuation.resume(returning: (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        }
    }

    @MainActor static func settingsTextDelivery() async throws {
        let suite = "wechat-settings-text-fixture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = Storage()
        let transport = TextTransport()
        let ledgerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-text-ledger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: ledgerDirectory) }
        let controller = MessageChannelsController(
            defaults: defaults, storage: storage, transport: { transport }, personalTransport: { NoNetwork() },
            botLedger: WeChatBotEventLedger(directory: ledgerDirectory))
        defer { controller.stop() }
        controller.start()
        controller.setEnabled(true, for: .personalWeChat)
        precondition(storage.authorizations == 0)
        controller.openPersonalWeChatSettings()
        controller.openPersonalWeChatSettings()
        precondition(storage.authorizations == 1 && controller.actionInFlight)
        await storage.finish(.success(try credential(fresh: true)))
        controller.openPersonalWeChatSettings()
        precondition(storage.authorizations == 1, "Connected settings must not prompt again")

        var results: [Bool] = []
        controller.sendPersonalWeChatText(String(repeating: "字", count: 2000)) { results.append($0) }
        precondition(results == [false] && transport.requests.isEmpty && !controller.actionInFlight)
        results = []
        let text = "正文完整保留\nhttps://example.com/source"
        controller.sendPersonalWeChatText(text) { results.append($0) }
        precondition(controller.actionInFlight)
        controller.sendPersonalWeChatText("duplicate") { results.append($0) }
        controller.sendTest(.personalWeChat)
        func currentTask() -> Task<Void, Never> {
            let tasks = Mirror(reflecting: controller).children.first { $0.label == "tasks" }!.value as! [MessageChannelKind: [UUID: Task<Void, Never>]]
            return tasks[.personalWeChat]!.values.first!
        }
        func waitForRequestCount(_ count: Int) async {
            for _ in 0..<10000 {
                if transport.requests.count == count { return }
                await Task.yield()
            }
            preconditionFailure("Text request not admitted")
        }
        let admitted = currentTask()
        await waitForRequestCount(1)
        let body = try JSONSerialization.jsonObject(with: transport.requests[0].httpBody!) as! [String: Any]
        let message = body["msg"] as! [String: Any]
        precondition(message["to_user_id"] as? String == "synthetic-owner")
        let item = (message["item_list"] as! [[String: Any]])[0]["text_item"] as! [String: Any]
        precondition(item["text"] as? String == text)
        transport.finish()
        await admitted.value
        precondition(results == [false, true] && !controller.actionInFlight && controller.personalWeChatPhase == .ready)

        results = []
        controller.sendPersonalWeChatText("cancelled text") { results.append($0) }
        let cancelled = currentTask()
        await waitForRequestCount(2)
        controller.setEnabled(false, for: .personalWeChat)
        transport.finish()
        await cancelled.value
        precondition(results == [false] && !controller.actionInFlight && controller.personalWeChatPhase == .disabled)
        precondition(storage.writes == 0)
        print(
            "PASS settings entry and text delivery: prompt once on open, no background/redundant prompts, exact paired target/body, UTF-8 limit, duplicate/cancel guards, no credential writes"
        )
    }

    @MainActor static func keychainPolicy() async throws {
        var allowed = true
        var policies: [Bool] = []
        var prompts = 0
        let data = try JSONEncoder().encode(credential())
        let interaction = FeishuKeychainInteraction(
            getAllowed: { allowed },
            setAllowed: {
                allowed = $0
                policies.append($0)
            })
        let store = MessageChannelKeychainStore(interaction: interaction) { _, pointer in
            guard allowed else { return errSecAuthFailed }
            prompts += 1
            pointer.pointee = data as CFData
            return errSecSuccess
        }
        let silent: Result<MessageChannelCredential?, FeishuWebhookError> = await withCheckedContinuation { callback in
            store.load(.personalWeChat) { callback.resume(returning: $0) }
        }
        if case .failure(.keychainAuthorizationRequired) = silent {} else { preconditionFailure("Silent read must request explicit permission") }
        precondition(prompts == 0 && allowed)
        let explicit: Result<MessageChannelCredential?, FeishuWebhookError> = await withCheckedContinuation { callback in
            store.authorizeStored(.personalWeChat, request: MessageCredentialReadRequest { callback.resume(returning: $0) })
        }
        let restored = try explicit.get()
        precondition(restored != nil)
        precondition(prompts == 1 && allowed && policies == [false, true, true, true])
        let cancelled = MessageChannelKeychainStore(interaction: interaction) { _, _ in errSecUserCanceled }
        let result: Result<MessageChannelCredential?, FeishuWebhookError> = await withCheckedContinuation { callback in
            cancelled.authorizeStored(.personalWeChat, request: MessageCredentialReadRequest { callback.resume(returning: $0) })
        }
        if case .failure(.keychainAuthorizationRequired) = result {} else { preconditionFailure("Cancelled authorization must not report success") }
        precondition(allowed)
        print("PASS Keychain policy: fake Security reader observes no background prompt; only explicit read allows UI; permission restored after cancellation")
    }
    @MainActor static func queuedAuthorization() async {
        for cancel in [false, true] {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            var allowed = true
            var reads = 0
            var interactiveReads = 0
            let interaction = FeishuKeychainInteraction(getAllowed: { allowed }, setAllowed: { allowed = $0 })
            let store = MessageChannelKeychainStore(interaction: interaction) { _, _ in
                reads += 1
                if reads == 1 {
                    entered.signal()
                    precondition(release.wait(timeout: .now() + 3) == .success)
                }
                if allowed { interactiveReads += 1 }
                return errSecItemNotFound
            }
            store.load(.personalWeChat) { _ in }
            let started = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success)
                }
            }
            precondition(started)
            var deliveries = 0
            let abandoned: Result<MessageChannelCredential?, FeishuWebhookError> = await withCheckedContinuation { continuation in
                let request = MessageCredentialReadRequest(waitTimeout: 0.03) { result in
                    deliveries += 1
                    continuation.resume(returning: result)
                }
                store.authorizeStored(.personalWeChat, request: request)
                if cancel { request.cancelBeforeStart() }
            }
            switch (cancel, abandoned) {
            case (false, .failure(.keychainTimedOut)), (true, .failure(.cancelled)): break
            default: preconditionFailure("Queued authorization must expire or cancel without waiting for Security")
            }
            precondition(deliveries == 1 && reads == 1 && interactiveReads == 0)
            // The second live request also drains the queue: the abandoned read
            // must never reach Security when the blocked background call returns.
            let resumed: Result<MessageChannelCredential?, FeishuWebhookError> = await withCheckedContinuation { continuation in
                store.authorizeStored(
                    .personalWeChat,
                    request: MessageCredentialReadRequest {
                        continuation.resume(returning: $0)
                    })
                release.signal()
            }
            if case .success(nil) = resumed {} else { preconditionFailure("Fresh request did not recover after blocked queue drained") }
            precondition(deliveries == 1 && reads == 2 && interactiveReads == 1 && allowed)
        }
        var completions = 0
        let active = MessageCredentialReadRequest(waitTimeout: 0.02) { _ in completions += 1 }
        precondition(active.begin())
        active.cancelBeforeStart()
        try? await Task.sleep(nanoseconds: 60_000_000)
        precondition(completions == 0 && !active.begin(), "An active system dialog must retain exclusive admission")
        active.finish(.failure(.keychainAuthorizationRequired))
        active.finish(.success(nil))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        precondition(completions == 1)
        print("PASS queued authorization: timeout/cancel releases wait without late Security reads; active system dialog retains admission and completes exactly once")
    }

}
