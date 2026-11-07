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
    final class ImmediateSuccess: MessageChannelTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    final class MainActorAdmissionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        private var allOnMain = true
        func record() {
            lock.lock()
            checks += 1
            allOnMain = allOnMain && Thread.isMainThread
            lock.unlock()
        }
        var snapshot: (Int, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (checks, allOnMain)
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
        if ProcessInfo.processInfo.environment["MESSAGE_CONTINUITY_ONLY"] == "1" {
            if try await !automaticCredentialRecovery() { exit(1) }
            return
        }
        if ProcessInfo.processInfo.environment["MESSAGE_CHANNEL_CAPACITY_ONLY"] == "1" {
            if try await !backgroundReadCapacity() { exit(1) }
            return
        }
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

        let firstRecovery = controller.restorePersonalWeChatConnection()!
        controller.cancelPersonalWeChatLogin(operationID: UUID())
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

        let secondRecovery = controller.restorePersonalWeChatConnection()!
        controller.cancelPersonalWeChatLogin(operationID: firstRecovery)
        precondition(controller.personalWeChatRestoreInProgress, "A departed page cancelled another page's recovery")
        controller.cancelPersonalWeChatLogin(operationID: secondRecovery)
        await storage.finish(.success(try credential(fresh: true)))
        precondition(!controller.personalWeChatConnected, "Cancelled authorization callback restored a connection")

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

        try await manualChatAuthorization()
        try await settingsTextDelivery()
        try await keychainPolicy()
        await queuedAuthorization()
        try await MessageTestAdmissionFixture.run()
        try await detachedPersonalWeChatAdmission()
        try await composedPublicResetAdmission()
        if try await !contextRefreshDelivery() { exit(1) }
        if try await !backgroundCredentialLifecycle() { exit(1) }
        if try await !backgroundReadCapacity() { exit(1) }
    }

    /// Real controller startup failures must recover without an interactive read.
    @MainActor static func automaticCredentialRecovery() async throws -> Bool {
        var failures: [String] = []
        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        var calls = 0
        let retry = MessageCredentialRetry { scheduled.append(($0, $1)) }
        for delay in [2.0, 10.0, 30.0, 60.0, 60.0] {
            retry.retry(after: .keychainBusy) { calls += 1 }
            retry.retry(after: .keychainBusy) { calls += 100 }
            precondition(scheduled.count == 1 && scheduled[0].0 == delay, "Retry was duplicated or exceeded its bounded delay")
            scheduled.removeFirst().1.perform()
        }
        precondition(calls == 5)
        retry.retry(after: .keychainTimedOut) { calls += 1 }
        let abandoned = scheduled.removeFirst().1
        retry.cancel()
        abandoned.perform()
        precondition(calls == 5, "Cancelled queued retry ran")
        retry.retry(after: .keychainAuthorizationRequired) { calls += 1 }
        precondition(scheduled.count == 1 && scheduled[0].0 == 2)
        retry.cancel()
        scheduled.removeAll()
        retry.retry(after: .missingWebhook) { calls += 1 }
        precondition(scheduled.isEmpty, "Missing credential retried forever")
        for (index, issue) in [FeishuWebhookError.keychainBusy, .keychainTimedOut, .keychainAuthorizationRequired].enumerated() {
            let suite = "message-continuity-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            let storage = Storage()
            storage.readResult = .failure(issue)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            let controller = MessageChannelsController(
                defaults: defaults, storage: storage,
                transport: { NoNetwork() }, personalTransport: { NoNetwork() },
                botLedger: WeChatBotEventLedger(directory: directory))
            controller.start()
            controller.setEnabled(true, for: .personalWeChat)
            storage.readResult = .success(try credential(fresh: true))
            let deadline = Date().addingTimeInterval(3)
            while !controller.personalWeChatConnected, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            if !controller.personalWeChatConnected || !controller.personalWeChatHasContext || storage.reads != 2 {
                failures.append("startup failure \(index) did not silently restore the saved binding")
            }
            if storage.authorizations != 0 || storage.writes != 0 { failures.append("automatic recovery requested authorization or rewrote a binding") }
            controller.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let suite = "message-settings-continuity-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = Storage()
        let controller = MessageChannelsController(
            defaults: defaults, storage: storage,
            transport: { NoNetwork() }, personalTransport: { NoNetwork() })
        controller.start()
        controller.setEnabled(true, for: .personalWeChat)
        controller.openPersonalWeChatSettings()
        if storage.authorizations != 0 { failures.append("opening settings requested a password dialog") }
        if storage.pending != nil { await storage.finish(.failure(.keychainAuthorizationRequired)) }
        controller.setEnabled(false, for: .personalWeChat)
        let readsBefore = storage.reads
        try await Task.sleep(nanoseconds: 2_200_000_000)
        if storage.reads != readsBefore { failures.append("disabled channel retried a credential read") }
        controller.stop()
        failures.forEach { print("FAIL message continuity: \($0)") }
        if failures.isEmpty { print("PASS message continuity: busy/timeout/locked startup restores silently, settings do not authorize, disable cancels retry") }
        return failures.isEmpty
    }

    @MainActor static func backgroundReadCapacity() async throws -> Bool {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        var allowed = true
        var reads = 0
        var interactiveReads = 0
        var gateReleased = true
        let values: [MessageChannelKind: MessageChannelCredential] = [
            .telegram: MessageChannelCredential(secret: "1234567890:AAExampleSyntheticToken0000000000000", target: "-100200300"),
            .weChat: MessageChannelCredential(secret: "01234567-89ab-cdef-0123-456789abcdef", target: nil),
            .personalWeChat: try credential(fresh: true),
        ]
        let encoded = try Dictionary(
            uniqueKeysWithValues: values.map { kind, value in
                ("com.blackielf.codex-account-manager-next.message-channel." + kind.rawValue, try JSONEncoder().encode(value))
            })
        let interaction = FeishuKeychainInteraction(getAllowed: { allowed }, setAllowed: { allowed = $0 })
        let store = MessageChannelKeychainStore(interaction: interaction) { query, pointer in
            reads += 1
            if allowed { interactiveReads += 1 }
            if reads == 1 {
                firstEntered.signal()
                gateReleased = releaseFirst.wait(timeout: .now() + 3) == .success
            }
            guard let service = (query as NSDictionary)[kSecAttrService as String] as? String,
                let data = encoded[service]
            else { return errSecItemNotFound }
            pointer.pointee = data as CFData
            return errSecSuccess
        }
        var results: [MessageChannelKind: Result<MessageChannelCredential?, FeishuWebhookError>] = [:]
        store.load(.telegram) { results[.telegram] = $0 }
        let firstBlocked = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: firstEntered.wait(timeout: .now() + 3) == .success)
            }
        }
        guard firstBlocked else {
            releaseFirst.signal()
            print("FAIL background read capacity: first synthetic reader did not enter")
            return false
        }
        store.load(.weChat) { results[.weChat] = $0 }
        store.load(.personalWeChat) { results[.personalWeChat] = $0 }
        var overflow: Result<MessageChannelCredential?, FeishuWebhookError>?
        store.load(.telegram) { overflow = $0 }
        let overflowDeadline = Date().addingTimeInterval(1)
        while overflow == nil, Date() < overflowDeadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        releaseFirst.signal()
        let deadline = Date().addingTimeInterval(2)
        while results.count < MessageChannelKind.allCases.count, Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        var failures: [String] = []
        for kind in MessageChannelKind.allCases {
            if case .success(let value)? = results[kind], value?.secret == values[kind]?.secret {
            } else {
                let detail: String
                if case .failure(.keychainBusy)? = results[kind] { detail = "keychainBusy" } else { detail = "missing or failed result" }
                failures.append("\(kind.rawValue) startup read was rejected: \(detail)")
            }
        }
        if case .failure(.keychainBusy)? = overflow {} else { failures.append("fourth read escaped the bounded capacity") }
        if reads != 3 || interactiveReads != 0 || !allowed || !gateReleased {
            failures.append("unexpected reader/policy count: reads=\(reads) interactive=\(interactiveReads)")
        }
        failures.forEach { print("FAIL background read capacity: \($0)") }
        if failures.isEmpty {
            print(
                "PASS background read capacity: all 3 channel credentials restored with first reader gated; fourth refused; 3 synthetic Security reads, 0 interactive reads, no authorization or writes"
            )
        }
        return failures.isEmpty
    }

    /// Keep binding-load races inside the existing offline production-source fixture.
    @MainActor static func backgroundCredentialLifecycle() async throws -> Bool {
        final class DeferredStorage: MessageChannelCredentialStoring {
            var loads: [(MessageChannelKind, (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void)] = []
            var reads = 0
            var authorizations = 0
            var authorization: MessageCredentialReadRequest?
            func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) {
                reads += 1
                loads.append((kind, completion))
            }
            func authorizeStored(_ kind: MessageChannelKind, request: MessageCredentialReadRequest) {
                precondition(kind == .personalWeChat && authorization == nil && request.begin())
                authorizations += 1
                authorization = request
            }
            func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
                preconditionFailure("Lifecycle recovery must not request an interactive credential write")
            }
            func saveBackground(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
                completion(.success(()))
            }
            func resolve(_ result: Result<MessageChannelCredential?, FeishuWebhookError>) { loads.removeFirst().1(result) }
            func finishAuthorization(_ result: Result<MessageChannelCredential?, FeishuWebhookError>) async {
                let request = authorization!
                authorization = nil
                request.finish(result)
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            }
        }
        final class PollTransport: MessageChannelTransport {
            private let lock = NSLock()
            private var pending: [(URLRequest, CheckedContinuation<(Data, HTTPURLResponse), Error>)] = []
            func hasPending(_ path: String) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return pending.contains { $0.0.url?.path == path }
            }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    pending.append((request, continuation))
                    lock.unlock()
                }
            }
            func finish(_ path: String? = nil, status: Int = 200, body: String = "{}", error: Error? = nil) {
                lock.lock()
                let callbacks = pending.filter { path == nil || $0.0.url?.path == path }
                pending.removeAll { path == nil || $0.0.url?.path == path }
                lock.unlock()
                for (request, callback) in callbacks {
                    if let error {
                        callback.resume(throwing: error)
                    } else {
                        callback.resume(returning: (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
                    }
                }
            }
        }
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }
        func waitUntil(_ seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
            return condition()
        }
        let poll = "/ilink/bot/getupdates"
        let initial = try credential(fresh: true)
        func fixture(_ kind: MessageChannelKind = .personalWeChat, _ scenario: String) async throws {
            let suite = "wechat-background-load-fixture-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "CodexManagerNext.messageChannel.\(kind.rawValue).enabled")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            let storage = DeferredStorage()
            let transport = PollTransport()
            let controller = MessageChannelsController(
                defaults: defaults, storage: storage, transport: { transport }, personalTransport: { transport },
                botLedger: WeChatBotEventLedger(directory: directory))
            defer {
                controller.stop()
                transport.finish(error: CancellationError())
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            controller.start()
            precondition(storage.reads == 1 && !controller.actionInFlight)
            let value = try kind == .personalWeChat ? initial : MessageChannelCredential(secret: "00000000-0000-0000-0000-000000000000", target: nil).validated(for: .weChat)
            func editOptions() {
                var options = controller.weChatMessageOptions
                options.includesAccountLabel.toggle()
                controller.setWeChatMessageOptions(options)
            }
            switch scenario {
            case "control", "options", "authorization-required":
                if scenario != "control" {
                    editOptions()
                    editOptions()
                    editOptions()
                }
                storage.resolve(scenario == "authorization-required" ? .failure(.keychainAuthorizationRequired) : .success(value))
                if scenario == "authorization-required" {
                    expect(controller.personalWeChatNeedsAuthorization && !controller.personalWeChatConnected, "option edit lost the background authorization-required result")
                    expect(!transport.hasPending(poll), "background read error started polling")
                } else if kind == .personalWeChat {
                    let started = await waitUntil { transport.hasPending(poll) }
                    expect(controller.personalWeChatConnected && controller.personalWeChatHasContext && started, "\(scenario): personal binding load did not connect and poll")
                } else {
                    expect(controller.weChatPhase == .pendingVerification, "\(scenario): WeCom binding load was discarded")
                }
                expect(storage.reads == 1 && storage.loads.isEmpty && storage.authorizations == 0, "content edit retried or authorized a credential read")
                if let revision = controller.publicResetRevision(kind) {
                    editOptions()
                    expect(controller.publicResetRevision(kind) != revision, "content edit retained outbound delivery revision")
                    expect(storage.reads == 1, "connected content edit reread credentials")
                }
            case "disable", "stop", "restart", "disable-enable":
                if scenario == "disable" || scenario == "disable-enable" {
                    controller.setEnabled(false, for: kind)
                    if scenario == "disable-enable" { controller.setEnabled(true, for: kind) }
                } else {
                    controller.stop()
                    if scenario == "restart" { controller.start() }
                }
                editOptions()
                storage.resolve(.success(value))
                expect(
                    !controller.personalWeChatConnected && !transport.hasPending(poll) && controller.publicResetRevision(kind) == nil,
                    "\(scenario): stale background load restored credentials")
                if scenario == "restart" || scenario == "disable-enable" {
                    precondition(storage.loads.count == 1 && storage.reads == 2)
                    storage.resolve(.success(value))
                    let started = await waitUntil { transport.hasPending(poll) }
                    expect(controller.personalWeChatConnected && started, "\(scenario): latest background load was not applied")
                }
            case "rebind":
                precondition(controller.connectPersonalWeChat() != nil)
                storage.resolve(.success(value))
                expect(!controller.personalWeChatConnected && !transport.hasPending(poll), "QR rebind accepted an older background binding")
                controller.setEnabled(false, for: kind)
            case "restore", "cancel-restore":
                let action = controller.restorePersonalWeChatConnection()!
                let options = controller.weChatMessageOptions
                editOptions()
                expect(controller.weChatMessageOptions == options, "content edit bypassed explicit authorization admission")
                storage.resolve(.success(value))
                expect(!controller.personalWeChatConnected && !transport.hasPending(poll), "explicit authorization accepted an older background binding")
                if scenario == "cancel-restore" { controller.cancelPersonalWeChatLogin(operationID: action) }
                await storage.finishAuthorization(.success(value))
                if scenario == "cancel-restore" {
                    expect(
                        !controller.personalWeChatConnected && !controller.personalWeChatHasContext && !controller.actionInFlight, "cancelled explicit authorization reconnected")
                } else {
                    let started = await waitUntil { transport.hasPending(poll) }
                    expect(controller.personalWeChatConnected && started && !controller.actionInFlight, "valid explicit authorization did not connect")
                }
                expect(storage.reads == 1 && storage.authorizations == 1, "explicit recovery changed background read admission")
            case "poll-retry":
                storage.resolve(.success(value))
                let initialPoll = await waitUntil { transport.hasPending(poll) }
                precondition(initialPoll)
                transport.finish(poll, error: URLError(.notConnectedToInternet))
                let retried = await waitUntil(7) { transport.hasPending(poll) }
                expect(retried && controller.personalWeChatConnected, "transport failure did not retry the existing binding")
                transport.finish(poll, body: #"{"msgs":[],"get_updates_buf":"synthetic-next"}"#)
                let resumedPoll = await waitUntil { transport.hasPending(poll) }
                precondition(resumedPoll)
                for attempt in 1...3 {
                    transport.finish(poll, status: 401)
                    if attempt < 3 {
                        let retry = await waitUntil(TimeInterval(attempt * 5 + 2)) { transport.hasPending(poll) }
                        expect(retry && controller.personalWeChatConnected, "401 attempt \(attempt) did not retain bounded retry")
                    }
                }
                let disconnected = await waitUntil { !controller.personalWeChatConnected }
                expect(disconnected && !controller.personalWeChatHasContext && controller.publicResetRevision(kind) == nil, "third 401 retained connection or delivery admission")
                expect(storage.reads == 1 && storage.authorizations == 0, "poll retry automatically reread or authorized credentials")
            default: preconditionFailure("Unknown lifecycle fixture")
            }
        }
        for kind in [MessageChannelKind.weChat, .personalWeChat] {
            for scenario in ["control", "options", "disable", "stop"] { try await fixture(kind, scenario) }
        }
        for scenario in ["authorization-required", "restart", "disable-enable", "rebind", "restore", "cancel-restore", "poll-retry"] {
            try await fixture(.personalWeChat, scenario)
        }
        failures.forEach { print("FAIL background credential lifecycle: \($0)") }
        if failures.isEmpty {
            print(
                "PASS background credential lifecycle: WeCom/personal options keep one pending load; disable/stop/restart/rebind/authorization reject stale loads; content changes still invalidate delivery; transport retry and three-401 recovery gates preserved"
            )
        }
        return failures.isEmpty
    }
    @MainActor static func manualChatAuthorization() async throws {
        let suite = "wechat-manual-authorization-fixture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let thread = UUID().uuidString
        let threadKey = "CodexManagerNext.messageChannel.personal-wechat.chatThread.v1"
        let chatKey = "CodexManagerNext.messageChannel.personal-wechat.chatEnabled.v1"
        let fingerprintKey = "CodexManagerNext.messageChannel.personal-wechat.chatAuthorization.v1"
        defaults.set(thread, forKey: threadKey)
        defaults.set(true, forKey: chatKey)
        let storage = Storage()
        storage.readResult = .success(try credential(fresh: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-manual-ledger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MessageChannelsController(
            defaults: defaults, storage: storage, transport: { NoNetwork() }, personalTransport: { NoNetwork() },
            botLedger: WeChatBotEventLedger(directory: directory))
        defer { controller.stop() }
        controller.start()
        controller.setEnabled(true, for: .personalWeChat)
        precondition(
            controller.personalChatNeedsConfirmation && controller.personalChatThreadID == thread && controller.personalChatEnabled,
            "Legacy manual selection must remain intact and require approval")
        controller.setPersonalChatThread(thread)
        let fingerprint = defaults.string(forKey: fingerprintKey)!
        precondition(!controller.personalChatNeedsConfirmation && fingerprint.count == 64 && !fingerprint.contains("synthetic"))
        let original = try credential(fresh: true)
        let changedContext = PersonalWeChatBinding(
            baseURL: URL(string: "https://ILINKAI.weixin.qq.com:443/")!, botID: "synthetic-bot",
            contextToken: "synthetic-new-context", contextCheckedAt: Date(), updatesCursor: "synthetic-new-cursor")
        let refreshed = try MessageChannelCredential(secret: original.secret, target: original.target, personalBinding: changedContext)
            .validated(for: .personalWeChat)
        controller.restorePersonalWeChatConnection()
        await storage.finish(.success(refreshed))
        precondition(
            !controller.personalChatNeedsConfirmation && defaults.string(forKey: fingerprintKey) == fingerprint,
            "Same identity normalized URL/context/cursor refresh invalidated manual approval")
        for changed in [
            try MessageChannelCredential(secret: "synthetic-new-token", target: original.target, personalBinding: original.personalBinding).validated(for: .personalWeChat),
            try MessageChannelCredential(secret: original.secret, target: "synthetic-new-owner", personalBinding: original.personalBinding).validated(for: .personalWeChat),
        ] {
            controller.restorePersonalWeChatConnection()
            await storage.finish(.success(changed))
            precondition(
                controller.personalChatNeedsConfirmation && controller.personalChatThreadID == thread && controller.personalChatEnabled,
                "New token or owner inherited manual thread approval")
            precondition(defaults.string(forKey: fingerprintKey) == fingerprint, "Rebind silently rewrote prior approval")
        }
        controller.setPersonalChatThread(thread)
        precondition(
            !controller.personalChatNeedsConfirmation && defaults.string(forKey: fingerprintKey) != fingerprint,
            "Same thread selection must permit explicit approval for the current owner")
        precondition(storage.writes == 0)
        print("PASS manual thread approval: legacy held, normalized identity survives context/cursor refresh, changed token/owner requires explicit same-thread approval")
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
        precondition(storage.authorizations == 0 && !controller.actionInFlight, "Opening settings must not authorize")
        controller.restorePersonalWeChatConnection()
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
        precondition(item["text"] as? String == MessageNoticeFormat.preservingOriginalBody(text))
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
            "PASS settings entry and text delivery: no prompt on open, explicit restore only, exact paired target/body, UTF-8 limit, duplicate/cancel guards, no credential writes"
        )
    }

    static func detachedPersonalWeChatAdmission() async throws {
        let probe = MainActorAdmissionProbe()
        let sendTextPassed = await Task.detached { () -> Bool in
            let channel = PersonalWeChatMessageChannel(transport: ImmediateSuccess())
            let eventID = UUID()
            let credential = try! credential(fresh: true)
            let result = await channel.sendText(
                "fixture", eventID: eventID, credential: credential,
                shouldSend: {
                    probe.record()
                    return true
                })
            if case .success(.accepted) = result { return true }
            return false
        }.value
        let sendPassed = await Task.detached { () -> Bool in
            let channel = PersonalWeChatMessageChannel(transport: ImmediateSuccess())
            let status = try! MessageTaskStatus(eventKind: .test, occurredAt: Date())
            let credential = try! credential(fresh: true)
            let result = await channel.send(
                status, credential: credential, options: .standard,
                shouldSend: {
                    probe.record()
                    return true
                })
            if case .success(.accepted) = result { return true }
            return false
        }.value
        let snapshot = probe.snapshot
        precondition(sendTextPassed && sendPassed && snapshot.0 == 4 && snapshot.1)
        print("PASS personal WeChat detached admission: both async send paths hop synchronous predicates to MainActor before and after transport")
    }

    @MainActor static func composedPublicResetAdmission() async throws {
        let suite = "wechat-public-reset-admission-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = Storage()
        storage.readResult = .success(try credential(fresh: true))
        let transport = ImmediateSuccess()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-public-reset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MessageChannelsController(
            defaults: defaults, storage: storage, transport: { transport }, personalTransport: { NoNetwork() },
            botLedger: WeChatBotEventLedger(directory: directory))
        defer { controller.stop() }
        controller.start()
        controller.setEnabled(true, for: .personalWeChat)
        precondition(controller.personalWeChatConnected && controller.personalWeChatHasContext)

        let event = PublicResetAnnouncement(
            id: "123", resetType: .regular, announcedAt: Date(), text: "fixture",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/123")))
        let revision = controller.publicResetRevision(.personalWeChat)!
        var checks = 0
        let result = await controller.sendPublicReset(
            event, to: .personalWeChat, revision: revision,
            shouldSend: {
                precondition(Thread.isMainThread, "composed public-reset admission ran off MainActor")
                checks += 1
                return true
            })
        guard case .success(.accepted) = result else { preconditionFailure("composed personal-WeChat delivery was not accepted") }
        precondition(checks >= 4, "each synchronous composed admission must be checked on MainActor")
        print("PASS composed public reset: controller revision and synchronous admission checks remained on MainActor through PersonalWeChatMessageChannel.send")
    }

    /// Holds both polling and delivery responses so a context refresh lands
    /// between an admitted send and its API acknowledgement.
    @MainActor static func contextRefreshDelivery() async throws -> Bool {
        final class PollingStorage: MessageChannelCredentialStoring {
            var value: MessageChannelCredential
            var saved: [MessageChannelCredential] = []
            init(_ value: MessageChannelCredential) { self.value = value }
            func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) {
                completion(.success(value))
            }
            func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
                preconditionFailure("Polling must never request an interactive credential write")
            }
            func saveBackground(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
                saved.append(value)
                completion(.success(()))
            }
        }
        final class HeldTransport: MessageChannelTransport {
            private let lock = NSLock()
            private var pending: [(URLRequest, CheckedContinuation<(Data, HTTPURLResponse), Error>)] = []
            func hasPending(_ path: String) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return pending.contains { $0.0.url?.path == path }
            }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    pending.append((request, continuation))
                    lock.unlock()
                }
            }
            func finish(_ path: String? = nil, body: String = "{}") {
                lock.lock()
                let callbacks = pending.filter { path == nil || $0.0.url?.path == path }
                pending.removeAll { path == nil || $0.0.url?.path == path }
                lock.unlock()
                for (request, callback) in callbacks {
                    callback.resume(returning: (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
                }
            }
        }
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }
        func waitUntil(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
            precondition(condition(), "Synthetic polling/delivery did not reach the held response")
        }
        let suite = "wechat-context-refresh-fixture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let initial = try credential(fresh: true)
        let storage = PollingStorage(initial)
        let transport = HeldTransport()
        let controller = MessageChannelsController(
            defaults: defaults, storage: storage, transport: { transport }, personalTransport: { transport },
            botLedger: WeChatBotEventLedger(directory: directory))
        defer {
            controller.stop()
            transport.finish()
        }
        func currentTask() -> Task<Void, Never> {
            let tasks = Mirror(reflecting: controller).children.first { $0.label == "tasks" }!.value as! [MessageChannelKind: [UUID: Task<Void, Never>]]
            return tasks[.personalWeChat]!.values.first!
        }
        func refresh(_ token: String, at date: Date, cursor: String) throws -> String {
            let body: [String: Any] = [
                "get_updates_buf": cursor,
                "msgs": [
                    [
                        "message_type": 1, "from_user_id": initial.target!, "to_user_id": initial.personalBinding!.botID,
                        "context_token": token, "create_time_ms": Int(date.timeIntervalSince1970 * 1000),
                    ]
                ],
            ]
            return String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        }
        controller.start()
        controller.setEnabled(true, for: .personalWeChat)
        controller.sendTest(.personalWeChat)
        let verified = currentTask()
        await waitUntil { transport.hasPending("/ilink/bot/sendmessage") && transport.hasPending("/ilink/bot/getupdates") }
        transport.finish("/ilink/bot/sendmessage")
        await verified.value
        precondition(controller.personalWeChatPhase == .ready)

        let revision = controller.publicResetRevision(.personalWeChat)!
        controller.sendTest(.personalWeChat)
        let held = currentTask()
        await waitUntil { transport.hasPending("/ilink/bot/sendmessage") }
        let refreshedAt = Date().addingTimeInterval(0.01)
        transport.finish("/ilink/bot/getupdates", body: try refresh("synthetic-refreshed-context", at: refreshedAt, cursor: "refresh-held-send"))
        await waitUntil { storage.saved.contains { $0.personalBinding?.updatesCursor == "refresh-held-send" } }
        expect(controller.publicResetRevision(.personalWeChat) == revision, "same binding context token refresh replaced the delivery revision")
        expect(!held.isCancelled && controller.actionInFlight, "same binding context token refresh cancelled an admitted notification")
        expect(controller.personalWeChatPhase == .ready, "fresh context token refresh discarded prior API verification")
        transport.finish("/ilink/bot/sendmessage")
        await held.value
        expect(!controller.actionInFlight && controller.personalWeChatPhase == .ready, "held notification lost its API acknowledgement after context refresh")

        await waitUntil { transport.hasPending("/ilink/bot/getupdates") }
        let event = PublicResetAnnouncement(
            id: "123", resetType: .regular, announcedAt: Date(), text: "fixture",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/123")))
        let resetRevision = controller.publicResetRevision(.personalWeChat)!
        let reset = Task { @MainActor in
            await controller.sendPublicReset(event, to: .personalWeChat, revision: resetRevision, shouldSend: { true })
        }
        await waitUntil { transport.hasPending("/ilink/bot/sendmessage") }
        transport.finish("/ilink/bot/getupdates", body: try refresh("synthetic-refreshed-context", at: refreshedAt.addingTimeInterval(1), cursor: "refresh-held-reset"))
        await waitUntil { storage.saved.contains { $0.personalBinding?.updatesCursor == "refresh-held-reset" } }
        expect(controller.publicResetRevision(.personalWeChat) == resetRevision, "same binding context timestamp refresh replaced the public-reset revision")
        transport.finish("/ilink/bot/sendmessage")
        if case .success(.accepted) = await reset.value {
        } else {
            failures.append("public reset lost its API acknowledgement after context refresh")
        }

        let cancelledRevision = controller.publicResetRevision(.personalWeChat)!
        let cancelled = Task { @MainActor in
            await controller.sendPublicReset(event, to: .personalWeChat, revision: cancelledRevision, shouldSend: { true })
        }
        await waitUntil { transport.hasPending("/ilink/bot/sendmessage") }
        controller.setEnabled(false, for: .personalWeChat)
        transport.finish("/ilink/bot/sendmessage")
        expect(controller.publicResetRevision(.personalWeChat) == nil, "disabled personal channel retained public-reset admission")
        if case .failure(.cancelled) = await cancelled.value {
        } else {
            failures.append("disabled personal channel accepted a stale public-reset acknowledgement")
        }
        transport.finish()
        let retainedBinding = PersonalWeChatBinding(
            baseURL: initial.personalBinding!.baseURL, botID: initial.personalBinding!.botID,
            contextToken: "synthetic-retained-context", contextCheckedAt: Date().addingTimeInterval(-3 * 24 * 3600))
        let retainedCredential = MessageChannelCredential(secret: initial.secret, target: initial.target, personalBinding: retainedBinding)
        storage.value = try JSONDecoder().decode(MessageChannelCredential.self, from: JSONEncoder().encode(retainedCredential)).validated(for: .personalWeChat)
        controller.setEnabled(true, for: .personalWeChat)
        controller.sendTest(.personalWeChat)
        let restoredSend = currentTask()
        await waitUntil { transport.hasPending("/ilink/bot/sendmessage") && transport.hasPending("/ilink/bot/getupdates") }
        transport.finish("/ilink/bot/sendmessage")
        await restoredSend.value
        precondition(controller.personalWeChatPhase == .ready)
        let retainedRevision = controller.publicResetRevision(.personalWeChat)!
        transport.finish("/ilink/bot/getupdates", body: #"{"msgs":[],"get_updates_buf":"retained-cursor-only"}"#)
        await waitUntil { storage.saved.contains { $0.personalBinding?.updatesCursor == "retained-cursor-only" } }
        expect(
            controller.personalWeChatHasContext && controller.personalWeChatPhase == .ready,
            "a cursor-only poll locally expired the restored context")
        expect(controller.publicResetRevision(.personalWeChat) == retainedRevision, "restored context lost admission without a server rejection")
        let retainedReset = Task { @MainActor in
            await controller.sendPublicReset(event, to: .personalWeChat, revision: retainedRevision, shouldSend: { true })
        }
        await waitUntil { transport.hasPending("/ilink/bot/sendmessage") }
        transport.finish("/ilink/bot/sendmessage")
        if case .success(.accepted) = await retainedReset.value {
        } else {
            failures.append("restored context older than 24 hours blocked a tracked notification")
        }
        await waitUntil { transport.hasPending("/ilink/bot/getupdates") }
        transport.finish("/ilink/bot/getupdates", body: #"{"ret":-14}"#)
        await waitUntil { !controller.personalWeChatConnected }
        expect(
            !controller.personalWeChatHasContext && controller.personalWeChatPhase == .needsSetup
                && controller.publicResetRevision(.personalWeChat) == nil, "explicit server session expiry retained admission")
        controller.sendTest(.personalWeChat)
        expect(!transport.hasPending("/ilink/bot/sendmessage"), "server-expired context still sent a notification")
        if case .failure(.cancelled) = await controller.sendPublicReset(event, to: .personalWeChat, revision: retainedRevision, shouldSend: { true }) {
        } else {
            failures.append("server-expired context still sent a public reset")
        }
        failures.forEach { print("FAIL context refresh: \($0)") }
        if failures.isEmpty {
            print(
                "PASS context refresh: held notification/public reset keep revision and acceptance; restored context survives 24h and cursor-only polls; disable/server expiry still block delivery; synthetic background storage only"
            )
        }
        return failures.isEmpty
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
