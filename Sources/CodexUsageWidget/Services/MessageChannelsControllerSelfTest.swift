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
        func hasPending(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return pending.contains { $0.0.url?.path == path }
        }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                sent.append(request)
                pending.append((request, continuation))
                lock.unlock()
            }
        }
        func completePath(_ path: String, responseBody: String) {
            lock.lock()
            let callbacks = pending.filter { $0.0.url?.path == path }
            pending.removeAll { $0.0.url?.path == path }
            lock.unlock()
            for (request, callback) in callbacks {
                callback.resume(returning: (Data(responseBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
            }
        }
        func completeAll(status: Int = 200, responseBody: String? = nil) {
            lock.lock()
            let callbacks = pending
            pending.removeAll()
            lock.unlock()
            for (request, callback) in callbacks {
                let body = responseBody ?? (request.url?.host == "api.telegram.org" ? #"{"ok":true,"result":{"message_id":17}}"# : #"{"errcode":0}"#)
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
        controller.setEnabled(false, for: .telegram)
        controller.setEnabled(true, for: .weChat)
        storage.resolve(weChat)
        var options = FeishuMessageOptions.standard
        options.notifiesFiveHourReset = false
        options.includesAccountLabel = false
        controller.setWeChatMessageOptions(options)
        let optionsReloaded = MessageChannelsController(defaults: defaults, storage: storage, transport: { transport })
        expect(optionsReloaded.weChatMessageOptions == options, "WeCom content/window options persist independently")
        let beforeReset = transport.count
        let label = try! MessageChannelAccountLabel(displayName: "Synthetic fixture")
        let five = try! MessageTaskStatus(
            eventKind: .quotaReset, accountLabel: label, occurredAt: Date(),
            quotaChange: .quotaReset(fiveHour: true, sevenDay: false))
        controller.send(five)
        settle()
        expect(transport.count == beforeReset, "disabled WeCom 5h reset still sent")
        let seven = try! MessageTaskStatus(
            eventKind: .quotaReset, accountLabel: label, occurredAt: Date(),
            quotaChange: .quotaReset(fiveHour: false, sevenDay: true))
        controller.send(seven)
        spin { transport.count == beforeReset + 1 }
        expect(transport.count == beforeReset + 1, "enabled WeCom 7d reset did not send")
        let selectedBody = String(data: transport.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        expect(!selectedBody.contains(label.value), "WeCom controller ignored account visibility")
        options.includesAccountLabel = true
        controller.setWeChatMessageOptions(options)
        transport.completeAll()
        settle()
        expect(controller.weChatPhase == .pendingVerification, "changed WeCom options accepted an obsolete in-flight receipt")
        let personalStorage = Storage()
        let personalHTTP = Transport()
        let personalDefaults = UserDefaults(suiteName: suite + ".personal")!
        defer { personalDefaults.removePersistentDomain(forName: suite + ".personal") }
        let ledgerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-controller-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: ledgerDirectory) }
        let dedicatedThread = UUID().uuidString
        var creationCount = 0
        var pendingCreation: CheckedContinuation<WeChatCodexThreadCreation, Never>?
        var conversationStarts = 0
        var activeTurn = UUID().uuidString
        var turnComplete = false
        let dedicatedConnection = WeChatCodexConversationConnection(
            owner: { _ in "synthetic-desktop" },
            snapshot: { thread, _ in
                var value: [String: Any] = [
                    "id": thread, "hostId": "local", "resumeState": "resumed",
                    "requests": [Any](), "threadRuntimeStatus": ["type": "idle"],
                ]
                if turnComplete {
                    value["turns"] = [
                        [
                            "id": activeTurn, "status": "completed",
                            "items": [
                                ["type": "agentMessage", "phase": "final_answer", "text": "synthetic dedicated reply"]
                            ],
                        ]
                    ]
                }
                return value
            },
            start: { thread, _, _, _, _ in
                guard thread == dedicatedThread else { return nil }
                conversationStarts += 1
                activeTurn = UUID().uuidString
                turnComplete = true
                return activeTurn
            }, close: {})
        let personal = MessageChannelsController(
            defaults: personalDefaults, storage: personalStorage,
            transport: { personalHTTP }, personalTransport: { personalHTTP },
            botLedger: WeChatBotEventLedger(directory: ledgerDirectory),
            conversationFactory: { WeChatCodexConversation(connection: dedicatedConnection, pollIntervalNanoseconds: 1_000_000) })
        personal.onCreatePersonalChat = { _ in
            creationCount += 1
            return await withCheckedContinuation { pendingCreation = $0 }
        }
        personal.onPersonalBotCommand = { $0 == "/状态" ? "synthetic cached status" : nil }
        defer {
            personal.stop()
            personalHTTP.completeAll()
            settle()
        }
        personal.start()
        personal.connectPersonalWeChat()
        personal.sendTest(.personalWeChat)
        settle()
        expect(
            !personal.personalWeChatEnabled && personalStorage.loads.isEmpty && personalHTTP.count == 0,
            "personal WeChat performs no I/O without opt-in")
        personal.setEnabled(true, for: .personalWeChat)
        personalStorage.resolve(nil)
        let qrOperation = personal.connectPersonalWeChat()
        expect(qrOperation != nil && personal.personalReconnectInFlight, "accepted QR login must return its operation token")
        expect(personal.connectPersonalWeChat() == nil && personal.restorePersonalWeChatConnection() == nil, "duplicate QR or restore superseded active QR")
        personal.cancelPersonalWeChatLogin(operationID: UUID())
        expect(personal.personalLoginInProgress, "unowned page cancellation stopped active QR")
        spin { personalHTTP.lastRequest?.url?.path == "/ilink/bot/get_bot_qrcode" }
        expect(personal.personalLoginInProgress && personalStorage.saves.isEmpty, "QR start saved a credential before confirmation")
        personalHTTP.completeAll(responseBody: #"{"qrcode":"synthetic-qr-reference","qrcode_img_content":"https://example.invalid/synthetic-qr"}"#)
        spin { personalHTTP.lastRequest?.url?.path == "/ilink/bot/get_qrcode_status" }
        expect(personal.personalLoginQRCode != nil && !personal.personalWeChatConnected, "QR presentation falsely marked the account connected")
        personalHTTP.completeAll(
            responseBody:
                #"{"status":"confirmed","bot_token":"synthetic-personal-token","ilink_bot_id":"synthetic-bot","ilink_user_id":"scanner@im.wechat","baseurl":"https://ilinkai.weixin.qq.com"}"#
        )
        spin { personalStorage.saves.count == 1 }
        expect(personal.actionInFlight && !personal.personalWeChatConnected, "connection bypassed Keychain acknowledgement")
        guard personalStorage.saves.count == 1 else {
            failures.append("personal QR confirmation did not request one credential save")
            failures.forEach { print("Message channel controller self-test failed: \($0)") }
            return false
        }
        personalStorage.saves.removeFirst().2(.success(()))
        spin { personal.personalWeChatConnected && !personal.personalLoginInProgress && personalHTTP.lastRequest?.url?.path == "/ilink/bot/getupdates" }
        expect(
            !personal.personalWeChatHasContext && personal.personalWeChatPhase == .needsSetup,
            "QR confirmation was confused with message context or delivery acceptance")
        let personalCount = personalHTTP.count
        personal.sendTest(.personalWeChat)
        settle()
        expect(personalHTTP.count == personalCount, "personal test sent before the scanner established a context")
        let incoming: [String: Any] = [
            "ret": 0, "get_updates_buf": "synthetic-cursor",
            "msgs": [
                [
                    "message_type": 1, "from_user_id": "scanner@im.wechat", "to_user_id": "synthetic-bot",
                    "context_token": "synthetic-context", "create_time_ms": Int(Date().timeIntervalSince1970 * 1000),
                ]
            ],
        ]
        personalHTTP.completeAll(responseBody: String(data: try! JSONSerialization.data(withJSONObject: incoming), encoding: .utf8)!)
        spin { personal.personalWeChatHasContext && !personalStorage.saves.isEmpty }
        expect(
            personal.personalWeChatPhase == .pendingVerification && personal.personalLoginQRCode == nil,
            "receiving a context falsely marked API delivery verified or retained the login QR")
        if !personalStorage.saves.isEmpty {
            let persisted = personalStorage.saves.removeFirst()
            expect(persisted.0.personalBinding?.contextToken == "synthetic-context", "background encrypted-record update lost personal context")
            persisted.2(.success(()))
        } else {
            failures.append("personal context was not saved to the encrypted record")
        }
        while !personalStorage.saves.isEmpty { personalStorage.saves.removeFirst().2(.success(())) }
        personal.sendTest(.personalWeChat)
        spin { personalHTTP.lastRequest?.url?.path == "/ilink/bot/sendmessage" }
        expect(personal.personalWeChatPhase == .pendingVerification, "personal test was marked accepted before the HTTP response")
        personalHTTP.completeAll(responseBody: #"{"ret":0}"#)
        spin { personal.personalWeChatPhase == .ready }
        expect(personal.personalWeChatPhase == .ready, "successful personal test did not verify the channel")
        spin { personalHTTP.lastRequest?.url?.path == "/ilink/bot/getupdates" }
        // Cursor-only progress cannot cancel a held explicit notification.
        personal.sendTest(.personalWeChat)
        spin { personalHTTP.hasPending("/ilink/bot/sendmessage") }
        spin { personalHTTP.hasPending("/ilink/bot/getupdates") }
        personalHTTP.completePath("/ilink/bot/getupdates", responseBody: #"{"msgs":[],"get_updates_buf":"cursor-only-held-send"}"#)
        settle()
        expect(personal.actionInFlight, "cursor-only poll cancelled held notification")
        personalHTTP.completePath("/ilink/bot/sendmessage", responseBody: "{}")
        spin { !personal.actionInFlight && personal.personalWeChatPhase == .ready }
        expect(personal.personalWeChatPhase == .ready, "held notification lost acceptance after cursor-only poll")
        spin { personalHTTP.hasPending("/ilink/bot/getupdates") }
        let command: [String: Any] = [
            "ret": 0, "get_updates_buf": "synthetic-command-cursor",
            "msgs": [
                [
                    "message_id": "synthetic-command-id", "message_type": 1, "message_state": 2,
                    "from_user_id": "scanner@im.wechat", "to_user_id": "synthetic-bot",
                    "context_token": "synthetic-context", "create_time_ms": Int(Date().timeIntervalSince1970 * 1000),
                    "item_list": [["type": 1, "text_item": ["text": "/状态"]]],
                ]
            ],
        ]
        let commandBody = String(data: try! JSONSerialization.data(withJSONObject: command), encoding: .utf8)!
        personalHTTP.completeAll(responseBody: commandBody)
        spin { personalHTTP.lastRequest?.url?.path == "/ilink/bot/sendmessage" }
        expect(
            personal.personalReconnectInFlight && !personal.personalBotIsReplying && !personal.actionInFlight,
            "command reply needs scoped reconnect admission without globally blocking channels")
        let heldCount = personalHTTP.count
        let heldLoads = personalStorage.loads.count
        expect(personal.connectPersonalWeChat() == nil && personal.restorePersonalWeChatConnection() == nil, "command reply was cancelled by reconnect")
        personal.setEnabled(true, for: .personalWeChat)
        let heldAutomaticTasks = Mirror(reflecting: personal).children.first { $0.label == "personalBotTasks" }?.value as? [UUID: Task<Void, Never>]
        let heldAutomaticReply = heldAutomaticTasks?.values.first
        personal.setPersonalChatThread("")
        expect(
            heldAutomaticReply?.isCancelled == false && personal.personalBotTasksInFlight,
            "same empty thread selection cancelled an active command reply")
        personal.cancelPersonalWeChatLogin(operationID: qrOperation!)
        expect(
            personalHTTP.count == heldCount && personalStorage.loads.count == heldLoads && personal.personalBotTasksInFlight,
            "same enabled value or late QR page cancellation changed held command")
        let botBody = String(data: personalHTTP.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        expect(
            botBody.contains("synthetic cached status") && !personal.personalChatEnabled,
            "local command failed without model conversation enabled")
        personalHTTP.completeAll(responseBody: #"{"ret":0}"#)
        spin { personalHTTP.lastRequest?.url?.path == "/ilink/bot/getupdates" }
        let beforeDuplicate = personalHTTP.count
        personalHTTP.completeAll(responseBody: commandBody)
        settle()
        expect(personalHTTP.count == beforeDuplicate, "duplicate command sent a second bot reply")
        // A batch larger than the active send limit retains its old cursor
        // until the ninth command receives a durable claim.
        spin { personalHTTP.hasPending("/ilink/bot/getupdates") }
        let beforeBurst = personalHTTP.count
        var burst = command
        burst["get_updates_buf"] = "synthetic-burst-cursor"
        burst["msgs"] = (0..<9).map { index -> [String: Any] in
            var item = (command["msgs"] as! [[String: Any]])[0]
            item["message_id"] = "synthetic-burst-\(index)"
            item["create_time_ms"] = Int(Date().timeIntervalSince1970 * 1000)
            return item
        }
        personalStorage.saves.removeAll()
        personalHTTP.completeAll(responseBody: String(data: try! JSONSerialization.data(withJSONObject: burst), encoding: .utf8)!)
        spin { personalHTTP.count - beforeBurst == 8 }
        expect(personalHTTP.count - beforeBurst == 8, "burst exceeded eight active replies")
        expect(!personalStorage.saves.contains { $0.0.personalBinding?.updatesCursor == "synthetic-burst-cursor" }, "cursor advanced before ninth command admission")
        personalHTTP.completeAll(responseBody: "{}")
        spin { personalHTTP.count - beforeBurst == 9 }
        expect(personalHTTP.count - beforeBurst == 9, "ninth command was silently lost")
        expect(personalStorage.saves.contains { $0.0.personalBinding?.updatesCursor == "synthetic-burst-cursor" }, "complete burst did not persist its cursor")
        personalHTTP.completeAll(responseBody: "{}")
        spin { personalHTTP.hasPending("/ilink/bot/getupdates") }
        let afterBurst = personalHTTP.count
        personalHTTP.completeAll(responseBody: String(data: try! JSONSerialization.data(withJSONObject: burst), encoding: .utf8)!)
        settle()
        expect(personalHTTP.count == afterBurst, "burst redelivery repeated an already claimed reply")
        while !personalStorage.saves.isEmpty { personalStorage.saves.removeFirst().2(.success(())) }
        // A chat-setting change wakes capacity admission without ending polling.
        spin { personalHTTP.hasPending("/ilink/bot/getupdates") }
        var cancelledBurst = burst
        cancelledBurst["get_updates_buf"] = "synthetic-cancelled-cursor"
        cancelledBurst["msgs"] = (0..<9).map { index -> [String: Any] in
            var item = (command["msgs"] as! [[String: Any]])[0]
            item["message_id"] = "synthetic-cancelled-\(index)"
            item["create_time_ms"] = Int(Date().timeIntervalSince1970 * 1000)
            return item
        }
        let beforeCancellation = personalHTTP.count
        personalStorage.saves.removeAll()
        personalHTTP.completeAll(responseBody: String(data: try! JSONSerialization.data(withJSONObject: cancelledBurst), encoding: .utf8)!)
        spin { personalHTTP.count - beforeCancellation == 8 }
        personal.setPersonalChatEnabled(true)
        personalHTTP.completeAll(responseBody: "{}")
        let recoveryDeadline = Date().addingTimeInterval(7)
        while !personalHTTP.hasPending("/ilink/bot/getupdates") && Date() < recoveryDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        expect(personalHTTP.hasPending("/ilink/bot/getupdates"), "chat epoch change permanently stopped polling")
        expect(!personalStorage.saves.contains { $0.0.personalBinding?.updatesCursor == "synthetic-cancelled-cursor" }, "cancelled batch advanced cursor")
        while !personalStorage.saves.isEmpty { personalStorage.saves.removeFirst().2(.success(())) }
        personal.setPersonalChatEnabled(true)
        // Durable-claim failure must leave cursor unchanged and retry later.
        spin { personalHTTP.hasPending("/ilink/bot/getupdates") }
        let journalFile = ledgerDirectory.appendingPathComponent("events-v1.json")
        let validJournal = try! Data(contentsOf: journalFile)
        try! Data("invalid-synthetic-journal".utf8).write(to: journalFile)
        var failedBatch = command
        failedBatch["get_updates_buf"] = "synthetic-failed-cursor"
        var failedItem = (command["msgs"] as! [[String: Any]])[0]
        failedItem["message_id"] = "synthetic-failed-command"
        failedItem["create_time_ms"] = Int(Date().timeIntervalSince1970 * 1000)
        failedBatch["msgs"] = [failedItem]
        personalStorage.saves.removeAll()
        let beforeFailure = personalHTTP.count
        personalHTTP.completeAll(responseBody: String(data: try! JSONSerialization.data(withJSONObject: failedBatch), encoding: .utf8)!)
        settle()
        expect(personalHTTP.count == beforeFailure, "failed durable claim sent a reply")
        expect(!personalStorage.saves.contains { $0.0.personalBinding?.updatesCursor == "synthetic-failed-cursor" }, "failed durable claim advanced cursor")
        try! validJournal.write(to: journalFile)
        let retryDeadline = Date().addingTimeInterval(7)
        while !personalHTTP.hasPending("/ilink/bot/getupdates") && Date() < retryDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        expect(personalHTTP.hasPending("/ilink/bot/getupdates"), "claim failure did not back off and resume polling")
        func ordinary(_ id: String) -> String {
            let value: [String: Any] = [
                "ret": 0, "get_updates_buf": "synthetic-command-cursor",
                "msgs": [
                    [
                        "message_id": id, "message_type": 1, "message_state": 2,
                        "from_user_id": "scanner@im.wechat", "to_user_id": "synthetic-bot",
                        "context_token": "synthetic-context", "create_time_ms": Int((Date().timeIntervalSince1970 * 1000).rounded(.up)),
                        "item_list": [["type": 1, "text_item": ["text": "synthetic ordinary message"]]],
                    ]
                ],
            ]
            return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
        }
        // First text reserves one creation. A second incoming text while it is
        // held must not create or submit another conversation.
        spin { personalHTTP.hasPending("/ilink/bot/getupdates") }
        personalHTTP.completeAll(responseBody: ordinary("ordinary-one"))
        spin { pendingCreation != nil }
        expect(creationCount == 1 && conversationStarts == 0, "first text must reserve before submitting")
        spin { personalHTTP.hasPending("/ilink/bot/getupdates") }
        personalHTTP.completeAll(responseBody: ordinary("ordinary-overlap"))
        spin { personalHTTP.lastRequest?.url?.path == "/ilink/bot/sendmessage" }
        expect(creationCount == 1 && conversationStarts == 0, "overlapping first messages created duplicate chats")
        personalHTTP.completeAll(responseBody: #"{"ret":0}"#)
        pendingCreation?.resume(returning: .created(dedicatedThread))
        pendingCreation = nil
        spin { conversationStarts == 1 && personalHTTP.hasPending("/ilink/bot/sendmessage") }
        expect(
            personal.personalAutomaticThreadID == dedicatedThread && personal.personalChatThreadID.isEmpty,
            "automatic binding overwrote manual selection mode")
        expect(
            (String(data: personalHTTP.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? "").contains("synthetic dedicated reply"),
            "automatic conversation did not return its final answer")
        personalHTTP.completeAll(responseBody: #"{"ret":0}"#)
        spin { !personal.personalBotIsReplying && personalHTTP.hasPending("/ilink/bot/getupdates") }
        personalHTTP.completeAll(responseBody: ordinary("ordinary-two"))
        spin { conversationStarts == 2 && personalHTTP.hasPending("/ilink/bot/sendmessage") }
        expect(creationCount == 1, "second text created a different conversation")
        expect(
            (try? WeChatBotEventLedger(directory: ledgerDirectory).conversationID(owner: "synthetic-bot\u{0}scanner@im.wechat")) == dedicatedThread,
            "dedicated binding did not survive a new ledger instance")
        personalHTTP.completeAll(responseBody: #"{"ret":0}"#)
        spin { !personal.personalBotIsReplying }
        spin { personalHTTP.hasPending("/ilink/bot/getupdates") }
        let beforeOrdinaryReplay = personalHTTP.count
        personalHTTP.completeAll(responseBody: ordinary("ordinary-two"))
        settle()
        expect(
            conversationStarts == 2 && creationCount == 1 && personalHTTP.count == beforeOrdinaryReplay,
            "ordinary duplicate reopened conversation or called model again")
        // A retained legacy/manual selection never falls back to creating a
        // new automatic chat, and changed credential identity needs approval.
        let manualSuite = "message-manual-thread-fixture-\(UUID())"
        let manualDefaults = UserDefaults(suiteName: manualSuite)!
        defer { manualDefaults.removePersistentDomain(forName: manualSuite) }
        manualDefaults.set(dedicatedThread, forKey: "CodexManagerNext.messageChannel.personal-wechat.chatThread.v1")
        manualDefaults.set(true, forKey: "CodexManagerNext.messageChannel.personal-wechat.chatEnabled.v1")
        manualDefaults.set(true, forKey: "CodexManagerNext.messageChannel.personal-wechat.enabled")
        let manualStorage = Storage()
        let manualHTTP = Transport()
        var manualCreates = 0
        let manual = MessageChannelsController(
            defaults: manualDefaults, storage: manualStorage, transport: { manualHTTP }, personalTransport: { manualHTTP },
            botLedger: WeChatBotEventLedger(directory: ledgerDirectory.appendingPathComponent("manual")),
            conversationFactory: { WeChatCodexConversation(connection: dedicatedConnection, pollIntervalNanoseconds: 1_000_000) })
        manual.onCreatePersonalChat = { _ in
            manualCreates += 1
            return .unavailable
        }
        defer {
            manual.stop()
            manualHTTP.completeAll()
            settle()
        }
        manual.start()
        let manualBinding = PersonalWeChatBinding(
            baseURL: URL(string: "https://ilinkai.weixin.qq.com")!, botID: "synthetic-bot",
            contextToken: "synthetic-context", contextCheckedAt: Date())
        let manualCredential = MessageChannelCredential(secret: "synthetic-manual-token", target: "scanner@im.wechat", personalBinding: manualBinding)
        manualStorage.resolve(manualCredential)
        spin { manualHTTP.hasPending("/ilink/bot/getupdates") }
        let beforeManualStart = conversationStarts
        manualHTTP.completePath("/ilink/bot/getupdates", responseBody: ordinary("manual-legacy"))
        spin { manualHTTP.hasPending("/ilink/bot/sendmessage") }
        expect(
            manual.personalChatNeedsConfirmation && manual.personalChatThreadID == dedicatedThread && manual.personalChatEnabled,
            "legacy manual configuration was reset rather than held for approval")
        expect(
            manualCreates == 0 && conversationStarts == beforeManualStart,
            "unapproved manual thread created or submitted a Codex conversation")
        manualHTTP.completePath("/ilink/bot/sendmessage", responseBody: "{}")
        spin { !manual.personalBotTasksInFlight && manualHTTP.hasPending("/ilink/bot/getupdates") }
        manual.setPersonalChatThread(dedicatedThread)
        expect(!manual.personalChatNeedsConfirmation, "same thread could not be explicitly approved")
        manualHTTP.completePath("/ilink/bot/getupdates", responseBody: ordinary("manual-approved"))
        spin { manualHTTP.hasPending("/ilink/bot/sendmessage") }
        expect(conversationStarts == beforeManualStart + 1 && manualCreates == 0, "approved manual thread was not submitted exactly once")
        let heldManualTasks = Mirror(reflecting: manual).children.first { $0.label == "personalBotTasks" }?.value as? [UUID: Task<Void, Never>]
        let heldManualReply = heldManualTasks?.values.first
        let heldManualRequestCount = manualHTTP.count
        manual.setPersonalChatThread(dedicatedThread)
        expect(
            heldManualReply?.isCancelled == false && manual.personalBotTasksInFlight && manual.personalBotIsReplying
                && manualHTTP.count == heldManualRequestCount && !manual.personalChatNeedsConfirmation,
            "same approved manual thread selection cancelled an active Codex reply")
        manualHTTP.completePath("/ilink/bot/sendmessage", responseBody: "{}")
        spin { !manual.personalBotTasksInFlight }
        expect(manual.restorePersonalWeChatConnection() != nil, "idle manual connection could not restore")
        manualStorage.resolve(MessageChannelCredential(secret: "synthetic-changed-manual-token", target: manualCredential.target, personalBinding: manualBinding))
        spin { manualHTTP.hasPending("/ilink/bot/getupdates") }
        manualHTTP.completePath("/ilink/bot/getupdates", responseBody: ordinary("manual-new-token"))
        spin { manualHTTP.hasPending("/ilink/bot/sendmessage") }
        expect(
            manual.personalChatNeedsConfirmation && manual.personalChatThreadID == dedicatedThread && manualCreates == 0
                && conversationStarts == beforeManualStart + 1, "changed token reused manual approval or silently created a replacement")
        manualHTTP.completeAll(responseBody: "{}")
        let longReply = MessageChannelsController.boundedPersonalReply(String(repeating: "测", count: 3000))
        expect(longReply.utf8.count <= 4096 && longReply.contains("全文请在 Codex"), "long bot reply silently truncated or exceeded byte limit")
        personal.sendTest(.personalWeChat)
        spin { personal.actionInFlight }
        personal.setEnabled(false, for: .personalWeChat)
        personalHTTP.completeAll(responseBody: #"{"ret":0}"#)
        settle()
        expect(
            personal.personalWeChatPhase == .disabled && !personal.personalWeChatHasContext && !personal.personalWeChatConnected,
            "disabling personal WeChat retained connection state or accepted an obsolete send")
        if failures.isEmpty {
            print("Message channel controller self-test passed: opt-in, persistence, callback revisions, independent completion, bounded sends and personal QR/context/delivery")
        } else {
            failures.forEach { print("Message channel controller self-test failed: \($0)") }
        }
        return failures.isEmpty
    }
}
