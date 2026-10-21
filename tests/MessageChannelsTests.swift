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

final class AdvancingWeChatTransport: MessageChannelTransport {
    let response: Data
    let onResponse: () -> Void
    init(response: Data, onResponse: @escaping () -> Void) {
        self.response = response
        self.onResponse = onResponse
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await Task.yield()
        onResponse()
        return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        expect(MessageNoticeFormatSelfTest.run(), "shared notice formatting failed")
        testTargetAndCredentialValidation()
        testSanitizedStatusDTO()
        testPhaseLifecycle()
        testSendsAndFailures()
        testDuplicateSuppression()
        testCancellation()
        testWeComAdapter()
        testWeComMessageOptions()
        testWeChatNoticePresentation()
        testNoYearNoticeDates()
        testActualNoticeRoutingParity()
        testResetNoticePayloads()
        testPersonalWeChat()
        testDeduplicatorCapacity()
        testAcceptanceRegressions()
        testConcurrentDuplicateSuppression()
        if failures.isEmpty { exportWeChatExamplesIfRequested() }

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
            expect(detailed.contains("重置卡 +2") && detailed.contains("1→3"), "verified reset increase lost its before/after balance")
            expect(detailed.contains("**5h**：剩余 100%") && !detailed.contains("**7d**"), "standalone reset lost known quota or included unknown quota noise")
            let quotaStatus = try MessageTaskStatus(eventKind: .quotaReset, accountLabel: status.accountLabel,
                fiveHourRemainingPercent: 100, sevenDayRemainingPercent: nil, occurredAt: now,
                quotaChange: .quotaReset(fiveHour: true, sevenDay: false), accountFacts: facts)
            let quotaText = WeChatMessageChannel.messageContent(status: quotaStatus, options: options, language: .zh)
            expect(quotaText.contains("**5h**：剩余 100%") && quotaText.contains("**7d**：未知")
                && !quotaText.contains("**7d**：剩余 100%"), "known/unknown quota facts were omitted or fabricated")
            var resetTimesOnly = options
            resetTimesOnly.includesQuotas = false
            let resetTimes = WeChatMessageChannel.messageContent(status: status, options: resetTimesOnly, language: .zh)
            expect(resetTimes.contains("5h 重置") && resetTimes.contains(MessageNoticeFormat.fullDate(facts.fiveHourResetsAt!))
                && !resetTimes.contains("100%") && !resetTimes.contains("**7d"), "standalone reset-time-only option lost known time or disclosed unknown quota")
            expect(detailed.contains("核对时间（北京时间）") && !detailed.contains("到账"), "WeCom detection was confused with grant time")
            expect(detailed.hasSuffix(MessageNoticeFormat.weChatFooterSuffix) && detailed.components(separatedBy: "\n").filter { $0 == MessageNoticeFormat.weChatFooter }.count == 1, "WeCom footer missing or repeated")
            expect(detailed.contains("演示账号") && !detailed.contains("**Agent**"), "default WeCom fields drifted from the selected options")
            options.notifiesFiveHourReset = false
            options.applyContentPreset(.compact)
            let compact = WeChatMessageChannel.messageContent(status: status, options: options, language: .zh)
            expect(!compact.contains("**5h**") && !compact.contains(" · 到期 "), "compact content retained detailed quota/expiry fields")
            expect(compact.contains("重置卡 +2") && !options.notifiesFiveHourReset, "density change altered window-alert choices")
            options.includesAccountLabel = false
            options.includesResetCredits = false
            let custom = WeChatMessageChannel.messageContent(status: status, options: options, language: .zh)
            expect(!custom.contains("演示账号") && !custom.contains("重置卡 +2") && !custom.contains("1→3"), "custom hidden fields still disclosed account/reset quantities")

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
            expect(bounded.contains("核对时间（北京时间）") && bounded.hasSuffix(MessageNoticeFormat.weChatFooterSuffix), "expiry truncation removed checked time or footer")
            _ = try WeChatMessageChannel.requestPayload(status: longStatus, messageOptions: options, language: .zh)
            expect((try? MessageTaskStatus(eventKind: .resetCreditsAdded, accountLabel: status.accountLabel,
                occurredAt: now, quotaChange: .resetCreditsAdded(added: 2, available: 1))) == nil, "invalid reset balance accepted")
            expect((try? MessageChannelAccountFacts(fiveHourResetsAt: Date(timeIntervalSince1970: .nan))) == nil, "nonfinite snapshot time accepted")
        } catch { failures.append("WeCom message options failed: \(error)") }
    }

    private static func testResetNoticePayloads() {
        do {
            let now = Date()
            let label = try MessageChannelAccountLabel(displayName: "演示账号")
            let before = now.addingTimeInterval(-600)
            for (previous, available, title) in [(1, 3, "重置卡 +2"), (3, 1, "重置卡 -2"), (1, 0, "重置卡 -1")] {
                let event = CodexQuotaEvent.resetCreditsChanged(previous: previous, available: available, previousObservedAt: before, observedAt: now)
                let status = try MessageTaskStatus(eventKind: .resetCreditsChanged, accountLabel: label, occurredAt: now, quotaChange: event)
                let summary = status.summary(.zh)
                expect(summary.contains(title) && summary.contains("可用 \(previous)→\(available) 次") && summary.contains("净变化 · 快照"), "change payload lost signed delta or snapshots")
                expect(summary.contains("原因待核实") == (available < previous) && !summary.contains("已使用") && !summary.contains("到账"), "change invented a cause")
                expect(summary.components(separatedBy: "\n").filter { $0 == MessageNoticeFormat.footer }.count == 1, "Telegram change footer missing or repeated")
                let weChat = WeChatMessageChannel.messageContent(status: status, options: .standard, language: .zh)
                expect(weChat.components(separatedBy: "\n").filter { $0 == MessageNoticeFormat.weChatFooter }.count == 1, "WeChat change footer missing or repeated")
                expect(weChat.contains("\(previous)→\(available) 张") && weChat.contains(MessageNoticeFormat.fullDate(before)), "WeChat change lost balance or complete evidence time")
                let telegram = try JSONSerialization.jsonObject(with: TelegramMessageChannel.requestPayload(status: status, chatID: syntheticChatID, language: .zh)) as! [String: Any]
                expect((telegram["text"] as? String)?.contains(title) == true, "Telegram dropped change facts")
            }
            let batches = [CodexResetCreditExpiryBatch(expiresAt: now.addingTimeInterval(3600), count: 1), CodexResetCreditExpiryBatch(expiresAt: now.addingTimeInterval(7200), count: 2)]
            let expiry = try MessageTaskStatus(eventKind: .resetCreditsExpiring, accountLabel: label, occurredAt: now,
                quotaChange: .resetCreditsExpiring(batches: batches, observedAt: now))
            var allExpiryOptions = FeishuMessageOptions.standard
            allExpiryOptions.resetExpiryDetail = .all
            let content = WeChatMessageChannel.messageContent(status: expiry, options: allExpiryOptions, language: .zh)
            for batch in batches {
                expect(content.contains("\(batch.count) 张 · " + MessageNoticeFormat.fullDate(batch.expiresAt)), "expiry payload lost a batch quantity/date")
            }
            let nearest = WeChatMessageChannel.messageContent(status: expiry, options: .standard, language: .zh)
            expect(nearest.contains(MessageNoticeFormat.fullDate(batches[0].expiresAt))
                && !nearest.contains(MessageNoticeFormat.fullDate(batches[1].expiresAt)), "nearest WeChat expiry disclosed another batch")
            expect(content.hasSuffix(MessageNoticeFormat.weChatFooterSuffix) && !content.contains("已使用") && !content.contains("到账"), "expiry footer or fact boundary failed")
            let expired = try MessageTaskStatus(eventKind: .resetCreditsExpiring, accountLabel: label, occurredAt: now,
                quotaChange: .resetCreditsExpiring(batches: [.init(expiresAt: now.addingTimeInterval(-1), count: 1)], observedAt: now.addingTimeInterval(-60)))
            expect((try? TelegramMessageChannel.requestPayload(status: expired, chatID: syntheticChatID)) == nil, "Telegram sent an expired reminder")
            expect((try? WeChatMessageChannel.requestPayload(status: expired)) == nil, "WeCom sent an expired reminder")
            let observedEarlier = now.addingTimeInterval(-60)
            let crossing = try MessageTaskStatus(eventKind: .resetCreditsExpiring, accountLabel: label, occurredAt: now,
                quotaChange: .resetCreditsExpiring(batches: [.init(expiresAt: observedEarlier.addingTimeInterval(24 * 3600 + 30), count: 1)], observedAt: observedEarlier))
            expect((try? TelegramMessageChannel.requestPayload(status: crossing, chatID: syntheticChatID)) != nil, "Telegram rejected a cached expiry entering the 24h window")
            expect((try? WeChatMessageChannel.requestPayload(status: crossing)) != nil, "WeCom rejected a cached expiry entering the 24h window")
            let originalCheck = "核实 " + MessageNoticeFormat.shortTime(observedEarlier)
            expect(crossing.summary(.zh).contains(originalCheck)
                && WeChatMessageChannel.messageContent(status: crossing, options: .standard, language: .zh).contains(MessageNoticeFormat.fullDate(observedEarlier)), "cached expiry used dispatch time as a new check time")
            let outside = try MessageTaskStatus(eventKind: .resetCreditsExpiring, accountLabel: label, occurredAt: now,
                quotaChange: .resetCreditsExpiring(batches: [.init(expiresAt: now.addingTimeInterval(24 * 3600 + 30), count: 1)], observedAt: now))
            expect((try? TelegramMessageChannel.requestPayload(status: outside, chatID: syntheticChatID)) == nil, "Telegram sent a reminder currently beyond 24h")
            expect((try? WeChatMessageChannel.requestPayload(status: outside)) == nil, "WeCom sent a reminder currently beyond 24h")
            expect((try? MessageTaskStatus(eventKind: .resetCreditsChanged, accountLabel: label, occurredAt: now,
                quotaChange: .resetCreditsChanged(previous: 1, available: 1, previousObservedAt: before, observedAt: now))) == nil, "zero change accepted")
            expect((try? MessageTaskStatus(eventKind: .resetCreditsExpiring, accountLabel: label, occurredAt: now,
                quotaChange: .resetCreditsExpiring(batches: [.init(expiresAt: now.addingTimeInterval(3600), count: 0)], observedAt: now))) == nil, "zero expiry accepted")
        } catch { failures.append("reset notice payloads failed: \(error)") }
    }

    private static func weChatExamples() throws -> [(id: String, category: String, status: MessageTaskStatus)] {
        // Fixed synthetic observations, never submitted to a channel. Public
        // sentences are quoted source text supplied in this review session.
        let now = ISO8601DateFormatter().date(from: "2026-10-20T08:00:00Z")!
        let before = now.addingTimeInterval(-1800)
        let account = try MessageChannelAccountLabel(displayName: "示例账号 01")
        let target = try MessageChannelAccountLabel(displayName: "示例账号 02")
        let task = try MessageChannelTaskLabel("示例任务")
        func context(target: MessageChannelAccountLabel? = nil) throws -> MessageNoticeContext {
            try .init(sourceAccount: account, targetAccount: target,
                fiveHourTriggerThresholdPercent: 5, sevenDayTriggerThresholdPercent: 15, observedAt: now)
        }
        func facts(_ count: Int) throws -> MessageChannelAccountFacts {
            try .init(fiveHourResetsAt: now.addingTimeInterval(18_000),
                sevenDayResetsAt: now.addingTimeInterval(259_200), availableResetCredits: count,
                resetCreditExpiries: count == 0 ? [] : [now.addingTimeInterval(3 * 3600), now.addingTimeInterval(23 * 3600)])
        }
        func window(_ previous: Int?, _ available: Int, five: Bool = true, seven: Bool = false) throws -> MessageTaskStatus {
            try .init(eventKind: .quotaReset, accountLabel: account,
                fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82, occurredAt: now,
                quotaChange: .quotaReset(fiveHour: five, sevenDay: seven), accountFacts: facts(available),
                resetCreditComparison: previous.map {
                    .init(previousAvailable: $0, available: available, previousObservedAt: before, observedAt: now)
                }, noticeContext: context())
        }
        var values: [(id: String, category: String, status: MessageTaskStatus)] = [
            ("test", "连接与切换", try .init(eventKind: .test, accountLabel: account,
                fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82, occurredAt: now, accountFacts: facts(2))),
            ("low-quota", "连接与切换", try .init(eventKind: .lowQuotaDetected, accountLabel: account,
                fiveHourRemainingPercent: 4, sevenDayRemainingPercent: 12, occurredAt: now, accountFacts: facts(2),
                noticeContext: context(target: target))),
            ("switch-success", "连接与切换", try .init(eventKind: .switchSucceeded, accountLabel: account,
                fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82, occurredAt: now, accountFacts: facts(2),
                noticeContext: context(target: target))),
            ("window-5h", "额度与重置卡", try window(2, 2)),
            ("window-7d", "额度与重置卡", try window(2, 2, five: false, seven: true)),
            ("window-both", "额度与重置卡", try window(2, 2, seven: true)),
            ("window-increase", "额度与重置卡", try window(1, 3)),
            ("window-decrease", "额度与重置卡", try window(3, 2)),
            ("window-unchanged", "额度与重置卡", try window(2, 2)),
            ("window-to-zero", "额度与重置卡", try window(1, 0)),
            ("window-zero", "额度与重置卡", try window(0, 0)),
            ("window-no-previous", "额度与重置卡", try window(nil, 2)),
            ("reset-added", "额度与重置卡", try .init(eventKind: .resetCreditsAdded, accountLabel: account,
                fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82,
                occurredAt: now, quotaChange: .resetCreditsAdded(added: 2, available: 3), accountFacts: facts(3))),
            ("reset-increase", "额度与重置卡", try .init(eventKind: .resetCreditsChanged, accountLabel: account,
                fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82,
                occurredAt: now, quotaChange: .resetCreditsChanged(previous: 1, available: 3,
                    previousObservedAt: before, observedAt: now), accountFacts: facts(3))),
            ("reset-decrease", "额度与重置卡", try .init(eventKind: .resetCreditsChanged, accountLabel: account,
                fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82,
                occurredAt: now, quotaChange: .resetCreditsChanged(previous: 3, available: 2,
                    previousObservedAt: before, observedAt: now), accountFacts: facts(2))),
            ("reset-expiring", "额度与重置卡", try .init(eventKind: .resetCreditsExpiring, accountLabel: account,
                fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82,
                occurredAt: now, quotaChange: .resetCreditsExpiring(batches: [
                    .init(expiresAt: now.addingTimeInterval(3 * 3600), count: 1),
                    .init(expiresAt: now.addingTimeInterval(23 * 3600), count: 1),
                ], observedAt: now), accountFacts: facts(2))),
        ]
        for reason in [MessageTaskStatus.FailureReason.noEligibleAccount, .appBusy, .validationFailed, .restartFailed, .networkUnavailable, .unknown] {
            values.append(("switch-failure-" + reason.rawValue, "连接与切换",
                try .init(eventKind: .switchFailed, accountLabel: account,
                    fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82,
                    failureReason: reason, occurredAt: now, accountFacts: facts(2),
                    noticeContext: context(target: reason == .noEligibleAccount ? nil : target))))
        }
        for state in [MessageTaskStatus.TaskState.idle, .running, .waitingInput, .completed, .failed, .interrupted, .disconnected] {
            values.append(("task-state-" + state.rawValue, "任务状态",
                try .init(eventKind: .taskStateChange, accountLabel: account, taskLabel: task,
                    taskState: state, occurredAt: now)))
        }
        for (kind, text) in [
            (PublicResetAnnouncement.Kind.regular, "Day 15/ Nevermind, we're still cooking... and reset. Enjoy."),
            (.banked, "Confirmed landed across all accounts. How are we doing so far?"),
        ] {
            let announcedAt = now.addingTimeInterval(-2 * 3600)
            let id = PublicResetForecast.sourcePostID(at: announcedAt)!
            let event = PublicResetAnnouncement(id: id, resetType: kind, announcedAt: announcedAt, text: text,
                source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/" + id)))
            let context = try PublicResetContext(announcement: event, now: now)
            values.append((kind == .regular ? "public-regular" : "public-banked", "公共公告与预告",
                try .init(eventKind: kind == .regular ? .publicRegularReset : .publicBankedReset,
                    occurredAt: now, publicResetContext: context)))
        }
        return values
    }

    private static func testWeChatNoticePresentation() {
        do {
            let examples = try weChatExamples()
            expect(examples.count == 31 && Set(examples.map { $0.id }).count == 31, "WeChat example inventory incomplete or duplicated")
            for example in examples {
                let text = WeChatMessageChannel.messageContent(status: example.status, options: .standard, language: .zh, markdown: false)
                expect(text.hasSuffix(MessageNoticeFormat.weChatFooterSuffix)
                    && text.components(separatedBy: MessageNoticeFormat.weChatFooter).count == 2, "WeChat source line missing or duplicated: " + example.id)
                expect(!text.contains("https://") && !text.contains("x.com") && !text.contains("**"), "WeChat includes a source URL or Markdown: " + example.id)
                expect(text.utf8.count <= WeChatMessageChannel.contentByteLimit, "WeChat sample exceeds transport size: " + example.id)
                expect(MessageNoticeFormat.withWeChatFooter(MessageNoticeFormat.withWeChatFooter(text)) == text, "WeChat generated footer is not idempotent")
                if let context = example.status.publicResetContext {
                    expect(text.contains(context.publicText) && text.contains(MessageNoticeFormat.fullDate(context.announcedAt)), "WeChat public text or complete time lost")
                    expect(text.contains("个人额度与重置卡以账号页官方读取为准。") && !text.contains("第三方汇总")
                        && !text.contains("待核实") && text.contains("\n\n" + context.publicText + "\n\n"), "WeChat public paragraphs or boundary drifted")
                    let telegram = example.status.summary(.zh)
                    expect(telegram.contains(context.sourceURL.absoluteString) && telegram.hasSuffix(MessageNoticeFormat.footerSuffix), "Telegram public wording changed with WeChat formatting")
                }
                if let comparison = example.status.resetCreditComparison {
                    expect(text.contains("\(comparison.previousAvailable)→\(comparison.available) 张")
                        && text.contains(MessageNoticeFormat.fullDate(comparison.previousObservedAt))
                        && text.contains(MessageNoticeFormat.fullDate(comparison.observedAt)), "WeChat window lost signed/zero comparison")
                    expect(text.contains("减少原因未确认。") == (comparison.delta < 0), "WeChat window invented a decrease cause")
                    expect(text.contains("到期") == (comparison.available > 0), "WeChat window lost current expiry boundary")
                    var options = FeishuMessageOptions.standard
                    options.notifiesFiveHourReset = false
                    if let selected = example.status.selectingQuotaWindows(options) {
                        expect(selected.resetCreditComparison == comparison && selected.eventID == example.status.eventID
                            && selected.noticeContext == example.status.noticeContext, "window filtering dropped comparison, notice context or event identity")
                    }
                    options.includesResetCredits = false
                    options.includesAccountLabel = false
                    options.includesQuotas = false
                    options.includesResetTimes = false
                    let hidden = WeChatMessageChannel.messageContent(status: example.status, options: options, language: .zh, markdown: false)
                    expect(!hidden.contains("重置卡") && !hidden.contains("→") && !hidden.contains("示例账号")
                        && !hidden.contains("剩余") && !hidden.contains("到期"), "WeChat window hidden options leaked facts")
                }
            }
            let now = Date(), before = now.addingTimeInterval(-600)
            let account = try MessageChannelAccountLabel(displayName: "示例账号 01")
            let facts = try MessageChannelAccountFacts(availableResetCredits: 2)
            func window(_ comparison: CodexResetCreditComparison, facts: MessageChannelAccountFacts?,
                        event: CodexQuotaEvent = .quotaReset(fiveHour: true, sevenDay: true),
                        context: MessageNoticeContext? = nil) throws -> MessageTaskStatus {
                try .init(eventKind: .quotaReset, accountLabel: account, occurredAt: now,
                    quotaChange: event, accountFacts: facts, resetCreditComparison: comparison, noticeContext: context)
            }
            let comparison = CodexResetCreditComparison(previousAvailable: 3, available: 2, previousObservedAt: before, observedAt: now.addingTimeInterval(-1))
            let status = try window(comparison, facts: facts)
            expect(status.occurredAt == now && status.resetCreditComparison?.observedAt != now, "observation time replaced dispatch freshness")
            expect((try? window(comparison, facts: nil)) == nil, "comparison accepted without current official count")
            expect((try? window(.init(previousAvailable: 3, available: 1, previousObservedAt: before, observedAt: now), facts: facts)) == nil, "comparison accepted a mismatched balance")
            expect((try? window(.init(previousAvailable: -1, available: 2, previousObservedAt: before, observedAt: now), facts: facts)) == nil, "negative comparison accepted")
            expect((try? window(.init(previousAvailable: 3, available: 2, previousObservedAt: now, observedAt: before), facts: facts)) == nil, "reversed comparison accepted")
            expect((try? window(.init(previousAvailable: 3, available: 2, previousObservedAt: before, observedAt: now.addingTimeInterval(1)), facts: facts)) == nil, "future comparison accepted")
            expect((try? MessageTaskStatus(eventKind: .resetCreditsAdded, accountLabel: account, occurredAt: now,
                quotaChange: .resetCreditsAdded(added: 1, available: 2), accountFacts: facts, resetCreditComparison: comparison)) == nil, "comparison accepted for a non-window event")
            let conflictingFacts = try FeishuAccountFacts(fiveHour: .unknown, sevenDay: .unknown,
                availableResetCredits: 99, resetCreditExpiries: [])
            let conflictingContext = try MessageNoticeContext(sourceAccount: account, observedAt: now, accountFacts: conflictingFacts)
            expect((try? MessageTaskStatus(eventKind: .switchSucceeded, accountLabel: account, occurredAt: now,
                accountFacts: facts, noticeContext: conflictingContext)) == nil, "notice context overrode a contradictory current official count")
            let matchingFacts = try FeishuAccountFacts(fiveHour: .unknown, sevenDay: .unknown,
                availableResetCredits: 2, resetCreditExpiries: [])
            let staleContext = try MessageNoticeContext(sourceAccount: account, observedAt: comparison.observedAt.addingTimeInterval(-1), accountFacts: matchingFacts)
            expect((try? window(comparison, facts: facts, context: staleContext)) == nil, "pre-comparison context observation was accepted")
            expect((try? window(comparison, facts: facts, context: conflictingContext)) == nil, "comparison accepted mismatched context facts")
            let credential = MessageChannelCredential(secret: "synthetic-ilink-token", target: "scanner@im.wechat",
                personalBinding: .init(baseURL: PersonalWeChatMessageChannel.defaultBaseURL, botID: "fixture-bot",
                    contextToken: "synthetic-context", contextCheckedAt: now))
            let request = try PersonalWeChatMessageChannel.messageRequest(status: status, credential: credential, language: .zh, now: now)
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let msg = object["msg"] as! [String: Any]
            let item = ((msg["item_list"] as! [[String: Any]])[0]["text_item"] as! [String: Any])["text"] as! String
            expect(item == WeChatMessageChannel.messageContent(status: status, options: .standard, language: .zh, markdown: false), "Personal/WeCom generated notice facts drifted")
            expect((try? PersonalWeChatMessageChannel.messageRequest(status: status, credential: credential, now: now.addingTimeInterval(121))) == nil, "comparison bypassed the 120-second dispatch guard")
        } catch { failures.append("WeChat notice presentation failed: \(error)") }
    }

    private static func testNoYearNoticeDates() {
        do {
            let initialFailures = failures.count
            let before = ISO8601DateFormatter().date(from: "2026-12-31T15:50:00Z")!
            let after = ISO8601DateFormatter().date(from: "2026-12-31T16:10:00Z")!
            let account = try MessageChannelAccountLabel(displayName: "示例账号 01")
            let comparison = CodexResetCreditComparison(previousAvailable: 3, available: 2,
                previousObservedAt: before, observedAt: after)
            let facts = try MessageChannelAccountFacts(fiveHourResetsAt: after.addingTimeInterval(3600), availableResetCredits: 2)
            let status = try MessageTaskStatus(eventKind: .quotaReset, accountLabel: account, fiveHourRemainingPercent: 100, occurredAt: after,
                quotaChange: .quotaReset(fiveHour: true, sevenDay: false), accountFacts: facts, resetCreditComparison: comparison)
            for language in [WidgetLanguage.zh, .en] {
                let text = WeChatMessageChannel.messageContent(status: status, options: .standard, language: language, markdown: false)
                expect(text.contains("12/31 23:50 → 01/01 00:10") && text.contains("01/01 01:10"), "WeChat cross-year evidence or reset time lost month/day")
                expect(text.range(of: #"\b(?:\d{4}|\d{2})/\d{2}/\d{2} \d{2}:\d{2}\b"#, options: .regularExpression) == nil, "WeChat generated date still includes a year")
            }
            let original = "Original 2026年12月31日 23:50.\n\nKeep 2027年1月1日 00:10."
            let id = PublicResetForecast.sourcePostID(at: after)!
            let event = PublicResetAnnouncement(id: id, resetType: .regular, announcedAt: after, text: original,
                source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/" + id)))
            let context = try PublicResetContext(announcement: event, now: after)
            let publicStatus = try MessageTaskStatus(eventKind: .publicRegularReset, occurredAt: after, publicResetContext: context)
            let text = WeChatMessageChannel.messageContent(status: publicStatus, options: .standard, language: .zh, markdown: false)
            expect(context.publicText.contains("2026年12月31日") && context.publicText.contains("2027年1月1日")
                && text.contains("\n\n" + context.publicText + "\n\n") && text.contains("公告时间（北京时间）：01/01 00:10"), "WeChat date display rewrote the accepted source paragraph")
            expect(status.occurredAt == after && status.resetCreditComparison == comparison && facts.fiveHourResetsAt == after.addingTimeInterval(3600), "date presentation changed stored fact timestamps")
            if failures.count == initialFailures {
                print("PASS no-year WeChat dates: bilingual cross-year comparisons/resets; literal dated source paragraphs and stored dates preserved")
            }
        } catch { failures.append("no-year WeChat date presentation failed: \(error)") }
    }

    private static func testActualNoticeRoutingParity() {
        // NoticeRoutingStore contains the actual UsageStore method extracted by
        // the runner. Only the receiver and non-message data shapes are stubs.
        do {
            let dispatchedAt = Date(), observedAt = dispatchedAt.addingTimeInterval(-1800)
            let source = try FeishuMaskedAccount(displayName: "示例账号 01")
            let target = try FeishuMaskedAccount(displayName: "示例账号 02")
            var snapshot = UsageSnapshot(
                fiveHourQuota: .init(remainingPercent: 4, resetsAt: observedAt.addingTimeInterval(5 * 3600)),
                sevenDayQuota: .init(remainingPercent: 12, resetsAt: observedAt.addingTimeInterval(3 * 86400)),
                account: .init(planType: "plus"), credits: .init(resetCredits: 2,
                    resetCreditDetails: [.init(expiresAt: observedAt.addingTimeInterval(3 * 3600))]))
            snapshot.refreshedAt = observedAt
            let officialFacts = try FeishuAccountFacts.snapshot(snapshot)
            // Deliberately differs from the official snapshot. The trigger
            // values and current official quota fields must retain both facts.
            let quota = AutomaticSwitchQuotaState(fiveHourRemaining: 1, sevenDayRemaining: 2)
            let comparison = CodexResetCreditComparison(previousAvailable: 3, available: 2,
                previousObservedAt: observedAt.addingTimeInterval(-1800), observedAt: observedAt)
            let caller = NoticeRoutingStore(), callerEventID = UUID(), callStarted = Date()
            caller.sendFeishuNotification(event: .lowQuotaDetected, source: source, target: target, quota: quota,
                factsSnapshot: snapshot, eventID: callerEventID, switchOrigin: .lowQuota)
            let callEnded = Date()
            guard let selectedByCaller = caller.messageChannels.values.first else {
                failures.append("actual notice caller dropped the low-quota event"); return
            }
            expect(selectedByCaller.noticeContext?.observedAt == snapshot.refreshedAt,
                "actual low-quota caller replaced the older official snapshot time with dispatch time")
            expect(selectedByCaller.occurredAt >= callStarted && selectedByCaller.occurredAt <= callEnded
                && selectedByCaller.eventID == callerEventID, "actual caller lost the fresh transport clock or event identity")
            expect(WeChatMessageChannel.messageContent(status: selectedByCaller, options: .standard, language: .zh)
                .contains(MessageNoticeFormat.fullDate(snapshot.refreshedAt)), "actual caller rendered dispatch time as the official check time")
            let credential = MessageChannelCredential(secret: "synthetic-ilink-token", target: "scanner@im.wechat",
                personalBinding: .init(baseURL: PersonalWeChatMessageChannel.defaultBaseURL, botID: "fixture-bot",
                    contextToken: "synthetic-context", contextCheckedAt: callEnded))
            expect((try? PersonalWeChatMessageChannel.messageRequest(status: selectedByCaller, credential: credential, now: callEnded)) != nil,
                "old official snapshot incorrectly tripped fresh personal-WeChat dispatch admission")
            func lines(_ text: String) -> [String] {
                text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\\*", with: "*")
                    .replacingOccurrences(of: "\\_", with: "_").components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            func cardText(_ data: Data) throws -> String {
                let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let card = root["card"] as! [String: Any], header = card["header"] as! [String: Any]
                let title = (header["title"] as! [String: Any])["content"] as! String
                let elements = (card["body"] as! [String: Any])["elements"] as! [[String: Any]]
                return ([title] + elements.compactMap { $0["content"] as? String }).joined(separator: "\n")
            }
            var hidden = FeishuMessageOptions.standard
            hidden.includesAgentName = false
            hidden.includesAccountLabel = false
            hidden.includesQuotas = false
            hidden.includesResetTimes = false
            hidden.includesResetCredits = false
            var allExpiries = FeishuMessageOptions.standard
            allExpiries.resetExpiryDetail = .all
            var resetTimesOnly = FeishuMessageOptions.standard
            resetTimesOnly.includesQuotas = false
            var checked = 0
            let events: [FeishuSwitchNotification.Event] = [
                .lowQuotaDetected, .switchSucceeded, .switchFailed(.networkUnavailable),
                .quotaChange(.quotaReset(fiveHour: true, sevenDay: true)),
            ]
            for origin in [FeishuSwitchNotification.SwitchOrigin.manual, .lowQuota, .restartTest] {
                for event in events {
                    let store = NoticeRoutingStore(), eventID = UUID()
                    let isWindow: Bool
                    if case .quotaChange(.quotaReset) = event { isWindow = true } else { isWindow = false }
                    store.sendAdditionalChannelEvent(event, source: source, target: target, quota: quota,
                        factsSnapshot: snapshot, resetCreditComparison: isWindow ? comparison : nil, eventID: eventID,
                        switchOrigin: origin, dispatchedAt: dispatchedAt, observedAt: observedAt)
                    guard let status = store.messageChannels.values.first, let context = status.noticeContext else {
                        failures.append("actual notice route dropped a valid event"); continue
                    }
                    expect(store.messageChannels.values.count == 1 && status.eventID == eventID, "actual route duplicated or replaced event identity")
                    expect(context.sourceAccount?.value == source.value && context.targetAccount?.value == target.value,
                        "actual route lost source/target identity")
                    expect(context.switchOrigin.rawValue == String(describing: origin), "actual route lost switch origin")
                    expect(context.fiveHourTriggerThresholdPercent == 5 && context.sevenDayTriggerThresholdPercent == 15,
                        "actual route changed configured trigger thresholds")
                    expect(context.accountFacts == officialFacts, "actual route replaced official snapshot facts")
                    expect(status.occurredAt == dispatchedAt && context.observedAt == observedAt,
                        "actual route conflated original observation and fresh transport time")
                    for language in [WidgetLanguage.zh, .en] {
                        for options in [FeishuMessageOptions.standard, hidden, allExpiries, resetTimesOnly] {
                            let independent = try FeishuSwitchNotification(event: event, sourceAccount: source, targetAccount: target,
                                switchOrigin: origin, triggerThresholdPercent: 15, fiveHourTriggerThresholdPercent: 5,
                                fiveHourRemainingPercent: 1, sevenDayRemainingPercent: 2,
                                accountFacts: FeishuAccountFacts.snapshot(snapshot), resetCreditComparison: isWindow ? comparison : nil,
                                messageOptions: options, occurredAt: observedAt, eventID: eventID)
                            let expected = try cardText(FeishuWebhookService.payloadData(for: independent, language: language))
                            let actual = WeChatMessageChannel.messageContent(status: status, options: options, language: language, markdown: false)
                            expect(lines(actual) == lines(expected), "actual route changed title, fields, order, values or original time across channels")
                            expect(actual.contains(MessageNoticeFormat.fullDate(observedAt)), "actual route omitted original checked time")
                            if !options.includesAccountLabel {
                                expect(!actual.contains(source.value) && !actual.contains(target.value), "actual route privacy option leaked source/target")
                            }
                            if !options.includesQuotas {
                                expect(!actual.contains("%") && !expected.contains("%"), "quota opt-out leaked numeric percentages in a field or trigger reason")
                                if case .lowQuotaDetected = event {
                                    expect(actual.contains("5h") && actual.contains("7d")
                                        && actual.contains(language == .zh ? "触发原因" : "Trigger"), "hidden quota option lost the actual met trigger windows")
                                }
                            }
                            checked += 1
                        }
                    }
                    if isWindow {
                        var selection = FeishuMessageOptions.standard
                        selection.notifiesFiveHourReset = false
                        let filtered = status.selectingQuotaWindows(selection)
                        expect(filtered?.noticeContext == context && filtered?.resetCreditComparison == comparison
                            && filtered?.occurredAt == dispatchedAt && filtered?.eventID == eventID,
                            "quota selection dropped live notice metadata or transport freshness")
                    }
                }
            }
            expect(checked == 96, "actual route parity matrix incomplete")
            print("Actual UsageStore notice route: \(checked) bilingual/options parity checks; original observation and fresh transport clocks verified")
        } catch { failures.append("actual notice routing parity failed: \(error)") }
    }

    private static func exportWeChatExamplesIfRequested() {
        guard let directory = ProcessInfo.processInfo.environment["MESSAGE_CHANNEL_PREVIEW_DIR"], !directory.isEmpty else { return }
        do {
            let values = try weChatExamples().map { example -> [String: String] in
                let text = WeChatMessageChannel.messageContent(status: example.status, options: .standard, language: .zh, markdown: false)
                return ["id": example.id, "title": String(text.split(separator: "\n")[0]),
                    "text": text, "category": example.category]
            }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url.appendingPathComponent("wechat-examples-1020v3.json"), options: .atomic)
            print("Exported \(values.count) synthetic WeChat formatter examples; no sends.")
        } catch { failures.append("WeChat sample export failed: \(error)") }
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
            // Exercise the production async entry: the poll returns 21 seconds
            // after it starts, with a command written during that wait.
            let pollStart = Date(timeIntervalSince1970: 1_800_000_000)
            let pollReturn = pollStart.addingTimeInterval(21)
            func timedMessage(id: String, createdAt: Date, user: String = "scanner@im.wechat", text: String = "/状态") -> [String: Any] {
                ["message_type": 1, "message_state": 2, "message_id": id,
                 "from_user_id": user, "to_user_id": "fixture-bot", "context_token": "context-" + id,
                 "create_time_ms": Int(createdAt.timeIntervalSince1970 * 1000),
                 "item_list": [["type": 1, "text_item": ["text": text]]]]
            }
            let delayedBody = try JSONSerialization.data(withJSONObject: ["msgs": [
                timedMessage(id: "during-poll", createdAt: pollStart.addingTimeInterval(20)),
                timedMessage(id: "ordinary-during-poll", createdAt: pollStart.addingTimeInterval(20.5), text: "synthetic ordinary message"),
                timedMessage(id: "expired", createdAt: pollReturn.addingTimeInterval(-121)),
                timedMessage(id: "future", createdAt: pollReturn.addingTimeInterval(6)),
                timedMessage(id: "other-owner", createdAt: pollReturn, user: "other@im.wechat")
            ], "get_updates_buf": "after-long-poll"])
            var responseReturned = false
            var clockSamples = 0
            let advancing = AdvancingWeChatTransport(response: delayedBody) { responseReturned = true }
            let delayedChannel = PersonalWeChatMessageChannel(transport: advancing, clock: {
                clockSamples += 1
                expect(responseReturned, "updates sampled its clock before the transport returned")
                return responseReturned ? pollReturn : pollStart
            })
            let delayedUpdate = runAsync { try? await delayedChannel.updates(unbound) }
            expect(delayedUpdate?.messages.map(\.id) == ["during-poll", "ordinary-during-poll"], "long-poll arrival was lost or stale/future/non-owner command admitted")
            expect(clockSamples == 1 && delayedUpdate?.binding.updatesCursor == "after-long-poll", "long-poll result did not use one response-time clock sample")
            // Context permits its existing 60-second future tolerance; the
            // stricter command guard still excludes this genuine future item.
            expect(delayedUpdate?.binding.contextCheckedAt == pollReturn.addingTimeInterval(6), "context timestamp did not preserve newest eligible server evidence")
            let credential = MessageChannelCredential(secret: unbound.secret, target: unbound.target, personalBinding: updates.binding)
            let roundTrip = try JSONDecoder().decode(MessageChannelCredential.self, from: JSONEncoder().encode(credential))
            expect(roundTrip.personalBinding == updates.binding, "encrypted-record session round trip lost context/cursor")
            let retainedBinding = PersonalWeChatBinding(
                baseURL: base, botID: "fixture-bot", contextToken: "retained-context",
                contextCheckedAt: now.addingTimeInterval(-3 * 24 * 3600), updatesCursor: "retained-cursor")
            let persisted = MessageChannelCredential(secret: unbound.secret, target: unbound.target, personalBinding: retainedBinding)
            let restored = try JSONDecoder().decode(MessageChannelCredential.self, from: JSONEncoder().encode(persisted)).validated(for: .personalWeChat)
            expect(restored.personalBinding == retainedBinding && retainedBinding.hasUsableContext(now: now),
                "restored verified context was locally expired after 24 hours")
            let retainedRequest = try PersonalWeChatMessageChannel.messageRequest(status: status, credential: restored, now: now)
            let retainedMessage = (try JSONSerialization.jsonObject(with: retainedRequest.httpBody!) as! [String: Any])["msg"] as! [String: Any]
            expect(retainedMessage["context_token"] as? String == "retained-context" && retainedMessage["to_user_id"] as? String == unbound.target,
                "restored context changed its recipient or token during notification preparation")
            let unchanged = try PersonalWeChatMessageChannel.bindingFromUpdates([
                "msgs": [message(user: "other@im.wechat", token: "foreign-user", offset: 1),
                         message(bot: "foreign-bot", token: "foreign-bot", offset: 1),
                         message(token: "older-context", offset: -90_000),
                         message(token: "future-context", offset: 61)]
            ], credential: credential, now: now)
            expect(unchanged.binding == updates.binding && !unchanged.contextChanged,
                "foreign, older or future context replaced the verified binding")
            let invalidFuture = PersonalWeChatBinding(
                baseURL: base, botID: "fixture-bot", contextToken: "future-context", contextCheckedAt: now.addingTimeInterval(61))
            expect(!invalidFuture.hasUsableContext(now: now), "future context bypassed the existing clock-skew guard")
            let backlog = try PersonalWeChatMessageChannel.bindingFromUpdates([
                "msgs": [timedMessage(id: "old-backlog", createdAt: now.addingTimeInterval(-3 * 24 * 3600))]
            ], credential: unbound, now: now)
            expect(backlog.binding.contextToken == "context-old-backlog" && backlog.binding.hasUsableContext(now: now) && backlog.messages.isEmpty,
                "old bound context was lost or its message escaped the 120-second execution window")
            let request = try PersonalWeChatMessageChannel.messageRequest(status: status, credential: credential, language: .zh, now: now)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let msg = body["msg"] as! [String: Any]
            expect(msg["to_user_id"] as? String == unbound.target && msg["context_token"] as? String == "fresh-context", "personal notification recipient/context mismatch")
            expect(msg["message_type"] as? Int == 2 && msg["message_state"] as? Int == 2 && request.value(forHTTPHeaderField: "Authorization") == "Bearer " + unbound.secret, "personal notification wire format mismatch")
            let encoded = String(data: request.httpBody!, encoding: .utf8)!
            expect(!encoded.contains(unbound.secret) && !encoded.contains("private inbound body") && !encoded.contains("**"), "personal text included credentials, incoming text or Markdown formatting")
            let item = ((msg["item_list"] as! [[String: Any]])[0]["text_item"] as! [String: Any])["text"] as! String
            expect(item.components(separatedBy: "\n").filter { $0 == MessageNoticeFormat.weChatFooter }.count == 1, "personal status footer missing or repeated")
            let source = "```swift\r\n\tlet website = \"aigoodbro.com\"\r\n```\r\n\r\naigoodbro.com\r\n"
            let rawRequest = try PersonalWeChatMessageChannel.textRequest(source, eventID: UUID(), credential: credential, now: now)
            let rawBody = try JSONSerialization.jsonObject(with: rawRequest.httpBody!) as! [String: Any]
            let rawMsg = rawBody["msg"] as! [String: Any]
            let rawItem = ((rawMsg["item_list"] as! [[String: Any]])[0]["text_item"] as! [String: Any])["text"] as! String
            expect(Array(rawItem.utf8) == Array((source + MessageNoticeFormat.footerSuffix).utf8), "personal send mutated raw code, CRLF or source footer")
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            for response in [#"{"unexpected":true}"#, #"{"ret":false}"#, #"{"ret":0.5}"#, #"{"ret":0,"errcode":-1}"#] {
                expect((try? PersonalWeChatMessageChannel.responseObject(Data(response.utf8), http: http, request: request, requiresAcceptance: true)) == nil, "personal notification falsely accepted an ambiguous response")
            }
            for response in [#"{"ret":-14}"#, #"{"errcode":-14}"#] {
                do {
                    _ = try PersonalWeChatMessageChannel.responseObject(Data(response.utf8), http: http, request: request, requiresAcceptance: true)
                    failures.append("expired personal session accepted")
                } catch { expect(error as? MessageChannelError == .weChatSessionExpired, "expired session was not surfaced for reconnect") }
            }
            do {
                let unauthorized = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                _ = try PersonalWeChatMessageChannel.responseObject(Data("{}".utf8), http: unauthorized, request: request, requiresAcceptance: true)
                failures.append("unauthorized personal session accepted")
            } catch { expect(error as? MessageChannelError == .httpStatus(401), "unauthorized response lost its original failure") }
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
            expect(received?.messages.first?.text == "/状态" && received?.binding.hasUsableContext(now: now) == true,
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
                expect(saved.personalBinding?.hasUsableContext(now: now) == false && saved.target == unbound.target, "QR confirmation falsely verified notification delivery/context")
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
