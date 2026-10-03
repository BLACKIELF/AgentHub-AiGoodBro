import Foundation

// Offline regression tests for the Telegram / WeChat message channels.
// Only synthetic placeholder credentials and a fake transport are used; no
// Keychain item is created and no real network request is issued.

final class SyntheticCredentialProvider: MessageChannelCredentialProviding {
    var enabled: [MessageChannelKind: Bool] = [:]
    var credentials: [MessageChannelKind: String] = [:]
    var targets: [MessageChannelKind: String] = [:]

    func isEnabled(_ kind: MessageChannelKind) -> Bool { enabled[kind] ?? false }
    func credential(for kind: MessageChannelKind) -> String? { credentials[kind] }
    func targetID(for kind: MessageChannelKind) -> String? { targets[kind] }
}

final class FakeTransport: MessageChannelTransport {
    enum Behavior {
        case respond(status: Int, body: Data)
        case fail(URLError)
        case hold(DispatchSemaphore, status: Int, body: Data)
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
    }

    private func waitForRelease(_ release: DispatchSemaphore) {
        guard release.wait(timeout: .now() + 5) == .success else {
            fatalError("held transport was not released")
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let captured = request
        record(captured)
        switch behavior {
        case .respond(let status, let body):
            return (body, HTTPURLResponse(url: captured.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .fail(let error):
            throw error
        case .hold(let release, let status, let body):
            waitForRelease(release)
            return (body, HTTPURLResponse(url: captured.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

enum MessageChannelsTests {
    static let syntheticToken = "1234567890:AAExampleSyntheticToken0000000000000"
    static let syntheticChatID = "-100200300"
    static let syntheticKey = "01234567-89ab-cdef-0123-456789abcdef"
    static let okBody = Data(#"{"ok":true,"result":{"message_id":42}}"#.utf8)
    static let weComOKBody = Data(#"{"errcode":0,"errmsg":"ok"}"#.utf8)

    static var failures: [String] = []

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    static func run() {
        testTargetAndCredentialValidation()
        testSanitizedStatusDTO()
        testPhaseLifecycle()
        testSendsAndFailures()
        testDuplicateSuppression()
        testCancellation()
        testWeComAdapter()
        testWeComMessageOptions()
        testPersonalWeChat()
        testDeduplicatorCapacity()
        testAcceptanceRegressions()
        testConcurrentDuplicateSuppression()

        if failures.isEmpty {
            print("Message channels offline regression passed")
        } else {
            failures.forEach { print("message channels test failed: \($0)") }
            exit(1)
        }
    }

    private static func fixedNow() -> Date {
        Date(timeIntervalSince1970: 1_760_000_000)
    }

    private static func testAcceptanceRegressions() {
        for body in [#"{"errcode":false}"#, #"{"errcode":0.2}"#] {
            expect(WeChatMessageChannel.parseResponseBody(Data(body.utf8)) == .invalid, "non-integer WeCom success accepted")
        }
        expect(TelegramMessageChannel.parseResponseBody(Data(#"{"ok":1,"result":{}}"#.utf8)) == .invalid,
            "non-boolean Telegram success accepted")
        expect(TelegramMessageChannel.parseResponseBody(Data(#"{"ok":false,"error_code":false}"#.utf8)) == .invalid,
            "boolean Telegram error accepted")
        let provider = SyntheticCredentialProvider()
        provider.enabled[.telegram] = true
        provider.credentials[.telegram] = syntheticToken
        provider.targets[.telegram] = syntheticChatID
        let transport = FakeTransport(behavior: .respond(status: 200, body: okBody))
        let channel = makeTelegramChannel(provider: provider, transport: transport)
        let future = runAsync { await channel.send(try! makeStatus(occurredAt: fixedNow().addingTimeInterval(3600))) }
        expect(future == .failure(.staleStatus), "future event accepted")
        _ = runAsync { await channel.send(try! makeStatus()) }
        expect(channel.phase == .ready, "accepted configuration did not verify")
        provider.targets[.telegram] = "-100200301"
        expect(channel.phase == .pendingVerification, "new target inherited old verification")
        let reflected = TelegramMessageChannel.parseResponseBody(
            Data("{\"ok\":false,\"error_code\":400,\"description\":\"\(syntheticToken)\"}".utf8))
        if case .rejected(_, let description) = reflected {
            expect(description == nil, "server reflected credential retained in error DTO")
        }
    }

    private static func makeStatus(
        eventKind: MessageTaskStatus.EventKind = .switchSucceeded,
        account: String? = "p***-source",
        occurredAt: Date? = nil,
        eventID: UUID = UUID()
    ) throws -> MessageTaskStatus {
        try MessageTaskStatus(
            eventKind: eventKind,
            accountLabel: account.map { try MessageChannelAccountLabel($0) },
            fiveHourRemainingPercent: 12,
            sevenDayRemainingPercent: 64,
            occurredAt: occurredAt ?? fixedNow(),
            eventID: eventID
        )
    }

    private static func makeTelegramChannel(
        provider: SyntheticCredentialProvider,
        transport: FakeTransport,
        deduplicator: MessageEventDeduplicator = MessageEventDeduplicator(),
        maximumStatusAge: TimeInterval = 300
    ) -> TelegramMessageChannel {
        TelegramMessageChannel(
            credentials: provider, transport: transport, deduplicator: deduplicator,
            maximumStatusAge: maximumStatusAge, now: fixedNow)
    }

    // 非法目标：token/chat id 校验与 endpoint 构造
    private static func testTargetAndCredentialValidation() {
        expect((try? TelegramMessageChannel.validatedBotToken(syntheticToken)) != nil, "valid synthetic token rejected")
        for invalid in [
            "",
            "1234:short",
            "1234567890:nohashatall",
            "1234567890:has spaces must fail aaaaaaaaaaaaa",
            "1234567890:AAExampleSyntheticToken0000000000000:extra",
            "abc123456:AAExampleSyntheticToken0000000000000",
        ] {
            expect((try? TelegramMessageChannel.validatedBotToken(invalid)) == nil, "unsafe bot token accepted: \(invalid.prefix(24))")
        }
        expect((try? TelegramMessageChannel.validatedChatID(syntheticChatID)) != nil, "numeric group chat id rejected")
        expect((try? TelegramMessageChannel.validatedChatID("@channel_user")) != nil, "channel username rejected")
        for invalid in [
            "", "0", "-0", "12x45", "--100", "not a chat", "@1bad", "user@host", "/path/to/chat",
            "@user space", String(repeating: "a", count: 64),
        ] {
            expect((try? TelegramMessageChannel.validatedChatID(invalid)) == nil, "unsafe chat id accepted: \(invalid.prefix(24))")
        }
        let endpoint = TelegramMessageChannel.endpoint(token: syntheticToken)
        expect(endpoint != nil, "telegram endpoint missing")
        expect(endpoint?.scheme == "https" && endpoint?.host == "api.telegram.org", "telegram endpoint host mismatch")
        expect(endpoint?.query == nil && endpoint?.fragment == nil, "telegram endpoint must not carry query or fragment")
        expect(
            WeChatMessageChannel.endpoint(key: syntheticKey)?.query == "key=\(syntheticKey)",
            "WeCom webhook endpoint deviates from the official protocol")
        expect(WeChatMessageChannel.endpoint(key: syntheticKey)?.host == "qyapi.weixin.qq.com", "WeCom host mismatch")
        expect((try? WeChatMessageChannel.validatedWebhookKey(syntheticKey)) != nil, "valid webhook key rejected")
        for invalid in ["", "uppercase-UUID-KEY", "01234567-89ab-cdef-0123-456789abcde", "012345678901234567890123456789012345"] {
            expect((try? WeChatMessageChannel.validatedWebhookKey(invalid)) == nil, "unsafe webhook key accepted: \(invalid.prefix(24))")
        }
    }

    // 敏感字段拒绝：DTO 不能携带未脱敏内容
    private static func testSanitizedStatusDTO() {
        expect((try? MessageChannelAccountLabel("person@example.com")) == nil, "raw email accepted as account label")
        expect((try? MessageChannelAccountLabel("/private/var/account")) == nil, "path accepted as account label")
        expect((try? MessageChannelAccountLabel("[click](https://x.invalid)")) == nil, "markdown link accepted as account label")
        expect((try? MessageChannelAccountLabel("p***-source")) != nil, "masked label rejected")
        expect((try? MessageChannelAccountLabel("evan")) != nil, "display-name label rejected")
        expect((try? MessageChannelTaskLabel("重置巡检 07")) != nil, "plain task label rejected")
        for invalid in ["email@task", "C:/path", "a\nb", String(repeating: "长", count: 49)] {
            expect((try? MessageChannelTaskLabel(invalid)) == nil, "unsafe task label accepted: \(invalid.prefix(12))")
        }
        for invalid in [Double.nan, Double.infinity, -0.1, 100.1] {
            expect(
                (try? MessageTaskStatus(
                    eventKind: .lowQuotaDetected, accountLabel: try MessageChannelAccountLabel("p***-source"),
                    fiveHourRemainingPercent: invalid, occurredAt: fixedNow())) == nil,
                "invalid quota percentage accepted")
        }
        do {
            let status = try makeStatus()
            let payload = String(data: try TelegramMessageChannel.requestPayload(status: status, chatID: syntheticChatID, language: .en), encoding: .utf8) ?? ""
            expect(!payload.contains(status.eventID.uuidString), "payload leaked the internal event ID")
            expect(!payload.contains("@"), "payload contains an at-sign")
            expect(payload.contains("p***-source"), "payload lost the masked account label")
            let wecom = String(data: try WeChatMessageChannel.requestPayload(status: status, language: .en), encoding: .utf8) ?? ""
            expect(wecom.contains("msgtype") && wecom.contains("markdown"), "WeCom payload missing markdown msgtype")
            expect(!wecom.contains(syntheticKey), "WeCom payload leaked the webhook key")
        } catch {
            failures.append("sanitized payload construction failed: \(error)")
        }
        expect((try? TelegramMessageChannel.payload(chatID: syntheticChatID, text: String(repeating: "a", count: 4097))) == nil, "over-limit Telegram text accepted")
        expect((try? TelegramMessageChannel.payload(chatID: syntheticChatID, text: String(repeating: "a", count: 4096))) != nil, "limit Telegram text rejected")
        expect((try? WeChatMessageChannel.payload(content: String(repeating: "a", count: 4097))) == nil, "over-limit WeCom content accepted")
    }

    // 状态生命周期：默认关闭 → 可配置 → 待验证 → 已验证
    private static func testPhaseLifecycle() {
        let provider = SyntheticCredentialProvider()
        let channel = makeTelegramChannel(provider: provider, transport: FakeTransport(behavior: .respond(status: 200, body: okBody)))
        expect(channel.phase == .disabled, "telegram must start disabled")
        provider.enabled[.telegram] = true
        expect(channel.phase == .needsSetup, "enabled telegram without credential must need setup")
        provider.credentials[.telegram] = syntheticToken
        expect(channel.phase == .needsSetup, "telegram without target must need setup")
        provider.targets[.telegram] = syntheticChatID
        expect(channel.phase == .pendingVerification, "configured telegram must await verification")
        let receipt = runAsync { await channel.verifyConnection() }
        expect(!isFailure(receipt), "verify connection failed")
        expect(channel.phase == .ready, "verified telegram must be ready")
        provider.credentials[.telegram] = "broken"
        expect(channel.phase == .needsSetup, "invalid credential must drop telegram back to needs setup")

        let weChatProvider = SyntheticCredentialProvider()
        let weChat = WeChatMessageChannel(credentials: weChatProvider, transport: FakeTransport(behavior: .respond(status: 200, body: weComOKBody)), now: fixedNow)
        expect(weChat.phase == .disabled, "WeCom must start disabled")
        weChatProvider.enabled[.weChat] = true
        expect(weChat.phase == .needsSetup, "enabled WeCom without key must need setup")
        weChatProvider.credentials[.weChat] = syntheticKey
        let weComReceipt = runAsync { await weChat.verifyConnection() }
        expect(!isFailure(weComReceipt), "WeCom verify connection failed")
        expect(weChat.phase == .ready, "verified WeCom must be ready")
        let capabilities = weChat.capabilities
        expect(capabilities.count == 3, "WeChat capability list must cover all three variants")
        expect(
            capabilities.first { $0.variant == .personal }?.phase == .disabled,
            "personal WeChat must be supported but opt-in")
        expect(
            capabilities.first { $0.variant == .officialAccount }?.phase == .unavailable(.officialAccountRequiresServerApproval),
            "official account must be reported unavailable")
        expect(
            capabilities.first { $0.variant == .workGroupBot }?.phase == .ready,
            "WeCom group robot capability must follow the service phase")
    }

    // 伪 transport：401/429/5xx/重定向/缺凭据/陈旧状态/错误脱敏
    private static func testSendsAndFailures() {
        let provider = SyntheticCredentialProvider()
        provider.enabled[.telegram] = true
        provider.credentials[.telegram] = syntheticToken
        provider.targets[.telegram] = syntheticChatID

        func channelFor(_ behavior: FakeTransport.Behavior, age: TimeInterval = 300) -> (TelegramMessageChannel, FakeTransport) {
            let transport = FakeTransport(behavior: behavior)
            return (makeTelegramChannel(provider: provider, transport: transport, maximumStatusAge: age), transport)
        }

        var (channel, _) = channelFor(.respond(status: 401, body: Data()))
        var result = runAsync { await channel.send(try! makeStatus()) }
        expect(result == .failure(.httpStatus(401)), "401 did not surface as httpStatus")

        (channel, _) = channelFor(.respond(status: 429, body: Data(#"{"ok":false,"error_code":429,"parameters":{"retry_after":42}}"#.utf8)))
        result = runAsync { await channel.send(try! makeStatus()) }
        guard case .failure(.rateLimited(let seconds)) = result else {
            failures.append("429 did not surface as rateLimited")
            return
        }
        expect(seconds == 42, "429 retry_after hint lost")

        (channel, _) = channelFor(.respond(status: 429, body: Data(#"{"ok":false}"#.utf8)))
        result = runAsync { await channel.send(try! makeStatus()) }
        guard case .failure(.rateLimited(let seconds)) = result else {
            failures.append("429 without parameters did not surface as rateLimited")
            return
        }
        expect(seconds == nil, "429 without parameters must not invent a retry hint")

        (channel, _) = channelFor(.respond(status: 500, body: Data()))
        result = runAsync { await channel.send(try! makeStatus()) }
        expect(result == .failure(.httpStatus(500)), "5xx did not surface as httpStatus")

        // 重定向：302 响应不是成功路径
        (channel, _) = channelFor(.respond(status: 302, body: Data()))
        result = runAsync { await channel.send(try! makeStatus()) }
        expect(result == .failure(.httpStatus(302)), "redirect status did not fail closed")

        (channel, _) = channelFor(.respond(status: 200, body: Data(#"{"ok":false,"error_code":400,"description":"chat not found"}"#.utf8)))
        result = runAsync { await channel.send(try! makeStatus()) }
        guard case .failure(.rejected(let code, _)) = result else {
            failures.append("ok=false body did not surface as rejected")
            return
        }
        expect(code == 400, "rejected code mismatch")

        (channel, _) = channelFor(.respond(status: 200, body: Data("not json".utf8)))
        result = runAsync { await channel.send(try! makeStatus()) }
        expect(result == .failure(.invalidResponse), "malformed body did not surface as invalidResponse")

        // 缺凭据：在禁用之外还要区分凭据与目标
        let bareProvider = SyntheticCredentialProvider()
        bareProvider.enabled[.telegram] = true
        let bareChannel = makeTelegramChannel(provider: bareProvider, transport: FakeTransport(behavior: .respond(status: 200, body: okBody)))
        result = runAsync { await bareChannel.send(try! makeStatus()) }
        expect(result == .failure(.missingCredential), "missing credential did not fail closed")
        bareProvider.credentials[.telegram] = syntheticToken
        result = runAsync { await bareChannel.send(try! makeStatus()) }
        expect(result == .failure(.missingTarget), "missing target did not fail closed")
        bareProvider.targets[.telegram] = "user@host"
        result = runAsync { await bareChannel.send(try! makeStatus()) }
        expect(result == .failure(.invalidTarget), "unsafe target did not fail closed")

        // 陈旧状态拒绝
        let (staleChannel, staleTransport) = channelFor(.respond(status: 200, body: okBody))
        result = runAsync {
            await staleChannel.send(try! makeStatus(occurredAt: fixedNow().addingTimeInterval(-301)))
        }
        expect(result == .failure(.staleStatus), "stale status was not refused")
        expect(staleTransport.requests.isEmpty, "stale status still issued a request")

        // 错误脱敏：transport 错误与错误文本绝不携带 token
        let errorURL = URL(string: "https://api.telegram.org/bot\(syntheticToken)/sendMessage")!
        (channel, _) = channelFor(.fail(URLError(.badURL, userInfo: [NSURLErrorKey: errorURL])))
        result = runAsync { await channel.send(try! makeStatus()) }
        if case .failure(let transportError) = result {
            expect(transportError == .transportFailed, "transport error was not masked")
            expect(transportError.errorDescription?.contains(syntheticToken) == false, "error text leaked the bot token")
        } else {
            failures.append("failing transport did not fail closed")
        }

        // 用户主动取消（shouldSend 复查）
        let (cancelChannel, cancelTransport) = channelFor(.respond(status: 200, body: okBody))
        result = runAsync { await cancelChannel.send(try! makeStatus(), shouldSend: { false }) }
        expect(result == .failure(.cancelled), "shouldSend=false did not cancel")
        expect(cancelTransport.requests.isEmpty, "cancelled send issued a request")
    }

    // 重复事件：同一 eventID 只发一次
    private static func testDuplicateSuppression() {
        let provider = SyntheticCredentialProvider()
        provider.enabled[.telegram] = true
        provider.credentials[.telegram] = syntheticToken
        provider.targets[.telegram] = syntheticChatID
        let deduplicator = MessageEventDeduplicator()
        let transport = FakeTransport(behavior: .respond(status: 200, body: okBody))
        let channel = makeTelegramChannel(provider: provider, transport: transport, deduplicator: deduplicator)
        let eventID = UUID(uuidString: "00000000-0000-0000-0000-0000000000d1")!
        let status = try! makeStatus(eventID: eventID)
        let first = runAsync { await channel.send(status) }
        guard case .success(.accepted(let receipt)) = first else {
            failures.append("first duplicate-test send did not accept")
            return
        }
        expect(receipt.remoteMessageID == "42", "telegram message_id missing from receipt")
        let second = runAsync { await channel.send(status) }
        guard case .success(.duplicateSkipped) = second else {
            failures.append("duplicate event was sent again")
            return
        }
        expect(transport.requests.count == 1, "duplicate event issued a second request")
    }

    private static func testConcurrentDuplicateSuppression() {
        let provider = SyntheticCredentialProvider()
        provider.enabled[.telegram] = true
        provider.credentials[.telegram] = syntheticToken
        provider.targets[.telegram] = syntheticChatID
        let release = DispatchSemaphore(value: 0)
        let transport = FakeTransport(behavior: .hold(release, status: 200, body: okBody))
        let channel = makeTelegramChannel(provider: provider, transport: transport)
        let status = try! makeStatus()
        let first = Task { await channel.send(status) }
        let deadline = Date().addingTimeInterval(2)
        while transport.requests.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        expect(transport.requests.count == 1, "first concurrent send did not start")
        let second = runAsync { await channel.send(status) }
        expect(second == .success(.duplicateSkipped), "in-flight duplicate was not suppressed")
        release.signal()
        _ = runAsync { await first.value }
        expect(transport.requests.count == 1, "concurrent event made two network requests")
    }

    // 迟到响应与取消
    private static func testCancellation() {
        let provider = SyntheticCredentialProvider()
        provider.enabled[.telegram] = true
        provider.credentials[.telegram] = syntheticToken
        provider.targets[.telegram] = syntheticChatID
        let deduplicator = MessageEventDeduplicator()
        let release = DispatchSemaphore(value: 0)
        let transport = FakeTransport(behavior: .hold(release, status: 200, body: okBody))
        let channel = makeTelegramChannel(provider: provider, transport: transport, deduplicator: deduplicator)
        let status = try! makeStatus()
        let task = Task { await channel.send(status) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        expect(transport.requests.count == 1, "held send never reached the transport")
        task.cancel()
        release.signal()
        let result = runAsync { await task.value }
        guard case .failure(.cancelled) = result else {
            failures.append("late response after cancellation did not report cancelled")
            return
        }
        expect(!deduplicator.hasSeen(status.eventID), "cancelled send claimed the event as delivered")
        // 取消后同一事件仍可重发（未被误标记为重复）
        let retryTransport = FakeTransport(behavior: .respond(status: 200, body: okBody))
        let retryChannel = makeTelegramChannel(provider: provider, transport: retryTransport, deduplicator: deduplicator)
        let retry = runAsync { await retryChannel.send(status) }
        guard case .success(.accepted) = retry else {
            failures.append("retry after cancellation was suppressed as a duplicate")
            return
        }
    }

    private static func testWeComMessageOptions() {
        do {
            let now = Date(timeIntervalSince1970: 1_790_000_000)
            let facts = try MessageChannelAccountFacts(fiveHourResetsAt: now.addingTimeInterval(18_000),
                sevenDayResetsAt: now.addingTimeInterval(604_800), availableResetCredits: 3,
                resetCreditExpiries: [now.addingTimeInterval(86_400), now.addingTimeInterval(172_800)])
            let status = try MessageTaskStatus(eventKind: .resetCreditsAdded,
                accountLabel: MessageChannelAccountLabel(displayName: "演示账号"),
                fiveHourRemainingPercent: 100, sevenDayRemainingPercent: nil,
                occurredAt: now, quotaChange: .resetCreditsAdded(added: 2, available: 3), accountFacts: facts)
            var options = FeishuMessageOptions.standard
            let detailed = WeChatMessageChannel.messageContent(status: status, options: options, language: .zh)
            expect(detailed.contains("新增 2 次") && detailed.contains("1 → 3"), "verified reset increase lost its before/after balance")
            expect(detailed.contains("7 天**：剩余 未知") && !detailed.contains("7 天**：剩余 100%"), "unknown quota was fabricated")
            expect(detailed.contains("发现时间不等于实际到账时间") && detailed.contains("北京时间"), "WeCom detected time was confused with grant time")
            expect(detailed.contains("演示账号") && !detailed.contains("**Agent**"), "default WeCom fields drifted from the selected options")
            options.notifiesFiveHourReset = false
            options.applyContentPreset(.compact)
            let compact = WeChatMessageChannel.messageContent(status: status, options: options, language: .zh)
            expect(!compact.contains("**5 小时**") && !compact.contains(" · 到期 "), "compact content retained detailed quota/expiry fields")
            expect(compact.contains("新增 2 次") && !options.notifiesFiveHourReset, "density change altered window-alert choices")
            options.includesAccountLabel = false
            options.includesResetCredits = false
            let custom = WeChatMessageChannel.messageContent(status: status, options: options, language: .zh)
            expect(!custom.contains("演示账号") && !custom.contains("新增 2 次") && !custom.contains("1 → 3"), "custom hidden fields still disclosed account/reset quantities")

            let reset = try MessageTaskStatus(eventKind: .quotaReset, accountLabel: status.accountLabel,
                occurredAt: now, quotaChange: .quotaReset(fiveHour: true, sevenDay: true))
            let selected = reset.selectingQuotaWindows(options)
            expect(selected?.quotaChange == .quotaReset(fiveHour: false, sevenDay: true), "WeCom window selection retained the disabled 5h window")
            expect(selected?.eventID == reset.eventID, "window filtering changed the idempotency identity")
            options.notifiesSevenDayReset = false
            expect(reset.selectingQuotaWindows(options) == nil, "both disabled windows still notified")
            expect(status.selectingQuotaWindows(options) == status, "window switches suppressed reset-credit increases")

            let many = try MessageChannelAccountFacts(availableResetCredits: 500,
                resetCreditExpiries: (1...500).map { now.addingTimeInterval(Double($0) * 3600) })
            let longStatus = try MessageTaskStatus(eventKind: .resetCreditsAdded, accountLabel: status.accountLabel,
                occurredAt: now, quotaChange: .resetCreditsAdded(added: 1, available: 500), accountFacts: many)
            options = .standard
            options.resetExpiryDetail = .all
            let bounded = WeChatMessageChannel.messageContent(status: longStatus, options: options, language: .zh)
            expect(bounded.utf8.count <= WeChatMessageChannel.contentByteLimit && bounded.contains("其余到期时间"), "all expiries exceeded the WeCom byte limit or silently disappeared")
            expect(bounded.contains("发现时间不等于实际到账时间"), "expiry truncation removed the interpretation footer")
            _ = try WeChatMessageChannel.requestPayload(status: longStatus, messageOptions: options, language: .zh)
            expect((try? MessageTaskStatus(eventKind: .resetCreditsAdded, accountLabel: status.accountLabel,
                occurredAt: now, quotaChange: .resetCreditsAdded(added: 2, available: 1))) == nil, "invalid reset balance accepted")
            expect((try? MessageChannelAccountFacts(fiveHourResetsAt: Date(timeIntervalSince1970: .nan))) == nil, "nonfinite snapshot time accepted")
        } catch { failures.append("WeCom message options failed: \(error)") }
    }

    private static func testPersonalWeChat() {
        do {
            let now = Date()
            let base = PersonalWeChatMessageChannel.defaultBaseURL
            for invalid in ["http://ilinkai.weixin.qq.com", "https://ilinkai.weixin.qq.com.evil.invalid",
                "https://evil.invalid", "https://ilinkai.weixin.qq.com/path", "https://token@ilinkai.weixin.qq.com",
                "https://ilinkai.weixin.qq.com?token=placeholder", "https://ilinkai.weixin.qq.com:8443"] {
                expect((try? PersonalWeChatMessageChannel.validatedBaseURL(URL(string: invalid)!)) == nil, "personal WeChat accepted an untrusted endpoint")
            }
            let qrRequest = try PersonalWeChatMessageChannel.qrRequest()
            let qrBody = try JSONSerialization.jsonObject(with: qrRequest.httpBody!) as! [String: Any]
            expect(qrRequest.httpMethod == "POST" && qrRequest.url?.path == "/ilink/bot/get_bot_qrcode", "QR request does not follow Tencent's current POST protocol")
            expect(qrBody["local_token_list"] as? [String] == [] && qrBody["base_info"] == nil && qrRequest.value(forHTTPHeaderField: "Authorization") == nil, "QR request reused unrelated tokens or credentials")
            let uin = Data(base64Encoded: qrRequest.value(forHTTPHeaderField: "X-WECHAT-UIN") ?? "").flatMap { String(data: $0, encoding: .utf8) }
            expect(uin.flatMap(UInt32.init) != nil, "X-WECHAT-UIN is not a base64 decimal uint32")
            let loginRequest = try PersonalWeChatMessageChannel.loginStatusRequest(reference: "fixture-qr", verificationCode: "123456")
            expect(loginRequest.httpMethod == "GET" && loginRequest.value(forHTTPHeaderField: "AuthorizationType") == nil,
                "QR polling leaked bot authentication headers")
            expect(loginRequest.url?.query?.contains("verify_code=123456") == true, "pairing code was omitted")
            let unbound = MessageChannelCredential(secret: "synthetic-ilink-token", target: "scanner@im.wechat",
                personalBinding: PersonalWeChatBinding(baseURL: base, botID: "fixture-bot"))
            let status = try MessageTaskStatus(eventKind: .test, occurredAt: now)
            expect((try? PersonalWeChatMessageChannel.messageRequest(status: status, credential: unbound, now: now)) == nil,
                "personal WeChat sent without a verified conversation context")
            func message(user: String = "scanner@im.wechat", bot: String = "fixture-bot", token: String, offset: Double = 0) -> [String: Any] {
                ["message_type": 1, "from_user_id": user, "to_user_id": bot, "context_token": token,
                    "create_time_ms": Int(now.addingTimeInterval(offset).timeIntervalSince1970 * 1000),
                    "item_list": [["type": 1, "text_item": ["text": "private inbound body must never be retained"]]]]
            }
            let updates = try PersonalWeChatMessageChannel.bindingFromUpdates([
                "msgs": [message(user: "other@im.wechat", token: "wrong-user"), message(bot: "wrong-bot", token: "wrong-bot"),
                         message(token: "stale-token", offset: -90_000), message(token: "future-token", offset: 3_600),
                         message(token: "fresh-context")], "get_updates_buf": "fixture-cursor"], credential: unbound, now: now)
            expect(updates.contextChanged && updates.binding.contextToken == "fresh-context" && updates.binding.updatesCursor == "fixture-cursor", "context did not stay bound to the scanner's own bot and recent message")
            for rawID in ["9007199254740993", "18446744073709551615"] {
                var inbound = message(token: "fresh-context")
                inbound["message_state"] = 2
                inbound["message_id"] = try JSONSerialization.jsonObject(with: Data(rawID.utf8), options: .fragmentsAllowed)
                let parsed = try PersonalWeChatMessageChannel.bindingFromUpdates(["msgs": [inbound]], credential: unbound, now: now)
                expect(parsed.messages.first?.id == rawID, "numeric uint64 message ID was lost or rounded")
            }
            for invalidID: Any in [true, -1, 0.5] {
                var inbound = message(token: "fresh-context")
                inbound["message_state"] = 2
                inbound["message_id"] = invalidID
                let parsed = try PersonalWeChatMessageChannel.bindingFromUpdates(["msgs": [inbound]], credential: unbound, now: now)
                expect(parsed.messages.isEmpty, "invalid message ID admitted a command")
            }
            let credential = MessageChannelCredential(secret: unbound.secret, target: unbound.target, personalBinding: updates.binding)
            let roundTrip = try JSONDecoder().decode(MessageChannelCredential.self, from: JSONEncoder().encode(credential))
            expect(roundTrip.personalBinding == updates.binding, "encrypted-record session round trip lost context/cursor")
            let request = try PersonalWeChatMessageChannel.messageRequest(status: status, credential: credential, language: .zh, now: now)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let msg = body["msg"] as! [String: Any]
            expect(msg["to_user_id"] as? String == unbound.target && msg["context_token"] as? String == "fresh-context", "personal notification recipient/context mismatch")
            expect(msg["message_type"] as? Int == 2 && msg["message_state"] as? Int == 2 && request.value(forHTTPHeaderField: "Authorization") == "Bearer " + unbound.secret, "personal notification wire format mismatch")
            let encoded = String(data: request.httpBody!, encoding: .utf8)!
            expect(!encoded.contains(unbound.secret) && !encoded.contains("private inbound body") && !encoded.contains("**"), "personal text included credentials, incoming text or Markdown formatting")
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            for response in [#"{"unexpected":true}"#, #"{"ret":false}"#, #"{"ret":0.5}"#, #"{"ret":0,"errcode":-1}"#] {
                expect((try? PersonalWeChatMessageChannel.responseObject(Data(response.utf8), http: http, request: request, requiresAcceptance: true)) == nil, "personal notification falsely accepted an ambiguous response")
            }
            do {
                _ = try PersonalWeChatMessageChannel.responseObject(Data(#"{"ret":-14}"#.utf8), http: http, request: request, requiresAcceptance: true)
                failures.append("expired personal session accepted")
            } catch { expect(error as? MessageChannelError == .weChatSessionExpired, "expired session was not surfaced for reconnect") }
            for response in ["{}", #"{"message_id":18446744073709551615}"#] {
                expect((try? PersonalWeChatMessageChannel.responseObject(Data(response.utf8), http: http, request: request, requiresAcceptance: true)) != nil,
                    "official success response with omitted default fields was rejected")
            }
            let pollingTransport = FakeTransport(behavior: .respond(status: 200, body: Data(#"{"msgs":[],"get_updates_buf":"next-cursor"}"#.utf8)))
            let pollingChannel = PersonalWeChatMessageChannel(transport: pollingTransport)
            let polling = runAsync { () -> Bool in
                do {
                    let update = try await pollingChannel.updates(unbound, now: now)
                    return update.binding.updatesCursor == "next-cursor" && update.messages.isEmpty
                } catch { return false }
            }
            expect(polling == true, "successful iLink poll without optional ret was rejected")
            expect((try? PersonalWeChatMessageChannel.bindingFromUpdates(["msgs": "invalid"], credential: unbound, now: now)) == nil,
                "malformed polling messages were accepted")
            var inbound = message(token: "fresh-context")
            inbound["message_state"] = 2
            inbound["message_id"] = NSNumber(value: UInt64.max)
            inbound["item_list"] = [["type": 1, "text_item": ["text": "/状态"]]]
            let incomingData = try JSONSerialization.data(withJSONObject: ["msgs": [inbound], "get_updates_buf": "next-cursor"])
            let incomingTransport = FakeTransport(behavior: .respond(status: 200, body: incomingData))
            let received = runAsync { try? await PersonalWeChatMessageChannel(transport: incomingTransport).updates(unbound, now: now) }
            expect(received?.messages.first?.text == "/状态" && received?.binding.hasFreshContext(now: now) == true,
                "wire response did not enable context and deliver the status command")
            let emptyAck = FakeTransport(behavior: .respond(status: 200, body: Data("{}".utf8)))
            let reply = runAsync { await PersonalWeChatMessageChannel(transport: emptyAck).sendText("测试回复", eventID: UUID(), credential: credential) }
            expect(!isFailure(reply) && emptyAck.requests.count == 1, "reply with omitted success fields did not complete once")
            let transport = FakeTransport(behavior: .respond(status: 200, body: Data(#"{"ret":0}"#.utf8)))
            let channel = PersonalWeChatMessageChannel(transport: transport)
            let first = runAsync { await channel.send(status, credential: credential, options: .standard) }
            expect(!isFailure(first), "personal text send did not accept a verified response")
            let duplicate = runAsync { await channel.send(status, credential: credential, options: .standard) }
            expect(duplicate == .success(.duplicateSkipped) && transport.requests.count == 1, "personal duplicate send was not suppressed")
            let cancelled = runAsync { await channel.send(try! MessageTaskStatus(eventKind: .test, occurredAt: Date()), credential: credential, options: .standard, shouldSend: { false }) }
            expect(cancelled == .failure(.cancelled) && transport.requests.count == 1, "personal disabled/revised delivery still sent")
            let loginTransport = FakeTransport(behavior: .respond(status: 200, body: Data(#"{"status":"confirmed","bot_token":"synthetic-ilink-token","ilink_bot_id":"fixture-bot","ilink_user_id":"scanner@im.wechat","baseurl":"https://ilinkai.weixin.qq.com"}"#.utf8)))
            let login = runAsync { try? await PersonalWeChatMessageChannel(transport: loginTransport).pollLogin(reference: "fixture-qr", base: base, verificationCode: nil) }
            if case .confirmed(let saved)? = login {
                expect(saved.personalBinding?.hasFreshContext(now: now) == false && saved.target == unbound.target, "QR confirmation falsely verified notification delivery/context")
            } else { failures.append("official QR confirmation did not produce a bound credential") }
        } catch { failures.append("personal WeChat regression failed: \(error)") }
    }

    // 企业微信群机器人适配器
    private static func testWeComAdapter() {
        let provider = SyntheticCredentialProvider()
        provider.enabled[.weChat] = true
        provider.credentials[.weChat] = syntheticKey
        let transport = FakeTransport(behavior: .respond(status: 200, body: weComOKBody))
        let channel = WeChatMessageChannel(credentials: provider, transport: transport, now: fixedNow)
        let result = runAsync { await channel.send(try! makeStatus()) }
        guard case .success(.accepted) = result else {
            failures.append("WeCom accepted body did not surface as accepted")
            return
        }
        expect(transport.requests.count == 1, "WeCom request count mismatch")
        let request = transport.requests[0]
        expect(request.url?.host == "qyapi.weixin.qq.com", "WeCom host mismatch")
        expect(request.url?.path == "/cgi-bin/webhook/send", "WeCom path mismatch")
        expect(request.url?.query == "key=\(syntheticKey)", "WeCom query mismatch")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        expect(body.contains("markdown"), "WeCom payload is not markdown")
        expect(!body.contains(syntheticKey), "WeCom request body leaked the webhook key")

        transport.behavior = .respond(status: 200, body: Data(#"{"errcode":45009,"errmsg":"api freq out of limit"}"#.utf8))
        let limited = runAsync { await channel.send(try! makeStatus()) }
        guard case .failure(.rateLimited) = limited else {
            failures.append("WeCom 45009 did not surface as rateLimited")
            return
        }
        transport.behavior = .respond(status: 200, body: Data(#"{"errcode":93000,"errmsg":"invalid webhookurl"}"#.utf8))
        let rejected = runAsync { await channel.send(try! makeStatus()) }
        guard case .failure(.rejected(let code, _)) = rejected else {
            failures.append("WeCom errcode body did not surface as rejected")
            return
        }
        expect(code == 93000, "WeCom rejected code mismatch")
        transport.behavior = .respond(status: 404, body: Data())
        let httpFailure = runAsync { await channel.send(try! makeStatus()) }
        expect(httpFailure == .failure(.httpStatus(404)), "WeCom HTTP 404 did not surface as httpStatus")

        // 错误脱敏：webhook key 不能出现在错误文本
        provider.credentials[.weChat] = "definitely-not-a-guid"
        let invalid = runAsync { await channel.send(try! makeStatus()) }
        expect(invalid == .failure(.invalidCredential), "invalid WeCom key did not fail closed")
        if case .failure(let credentialError) = invalid {
            expect(credentialError.errorDescription?.contains("definitely-not-a-guid") == false, "WeCom error text leaked the webhook key")
        }
    }

    // 去重器容量边界
    private static func testDeduplicatorCapacity() {
        let deduplicator = MessageEventDeduplicator(capacity: 2)
        let first = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-0000000000a3")!
        deduplicator.claim(first)
        deduplicator.claim(second)
        expect(deduplicator.hasSeen(first), "bounded deduplicator lost a fresh event")
        deduplicator.claim(third)
        expect(!deduplicator.hasSeen(first), "deduplicator did not evict the oldest event")
        expect(deduplicator.hasSeen(second) && deduplicator.hasSeen(third), "deduplicator evicted live events")
        expect(!deduplicator.claim(second), "deduplicator re-claimed a live event")
    }
}

/// Runs an async expression to completion on a background task while the
/// calling thread pumps MainActor work (script-mode tests are synchronous).
private final class TestResultBox<Value> {
    private let lock = NSLock()
    private var stored: Value?
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; stored = value }
    func get() -> Value? { lock.lock(); defer { lock.unlock() }; return stored }
}

private func runAsync<T>(_ body: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let captured = TestResultBox<T>()
    Task {
        captured.set(await body())
        semaphore.signal()
    }
    let deadline = Date().addingTimeInterval(10)
    while captured.get() == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    guard semaphore.wait(timeout: .now()) == .success, let value = captured.get() else {
        fatalError("offline async fixture did not finish within ten seconds")
    }
    return value
}

private func isFailure<T, E: Error>(_ result: Result<T, E>) -> Bool {
    if case .failure = result { return true }
    return false
}

MessageChannelsTests.run()
