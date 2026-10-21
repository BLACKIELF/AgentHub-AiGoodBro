import CryptoKit
import Foundation

/// Personal WeChat uses Tencent's iLink bot protocol. WeCom retains its
/// separate group-robot webhook; Official Accounts require server deployment.
enum WeChatVariantKind: String, CaseIterable {
    /// 个人微信：腾讯官方 iLink 协议，用户主动扫码绑定。
    case personal
    /// 企业微信群机器人：官方 webhook 协议，本应用可最小实现。
    case workGroupBot
    /// 公众号：需要已备案服务端，应用内无法完成。
    case officialAccount

    func displayName(_ language: WidgetLanguage) -> String {
        switch self {
        case .personal: return language.text("个人微信", "Personal WeChat")
        case .workGroupBot: return language.text("企业微信群机器人", "WeCom group robot")
        case .officialAccount: return language.text("公众号", "Official Account")
        }
    }
}

struct WeChatChannelCapability: Equatable {
    let variant: WeChatVariantKind
    let phase: MessageChannelPhase
    let helpURL: URL?

    func summary(_ language: WidgetLanguage) -> String {
        switch phase {
        case .unavailable(let reason):
            return reason.summary(language)
        case .disabled:
            return language.text("默认关闭；可在设置中启用。", "Disabled by default; enable it in settings.")
        case .needsSetup:
            return variant == .personal
                ? language.text(
                    "开启后扫码连接，再给绑定的机器人发一句话。", "Enable, scan to connect, then send a message to the paired bot.")
                : language.text(
                    "已支持官方协议；需要粘贴企业微信群机器人的 Webhook Key。",
                    "Official protocol supported; paste the WeCom group-robot webhook key.")
        case .pendingVerification:
            return language.text("已配置，等待发送测试消息验证。", "Configured; send a test message to verify.")
        case .ready:
            return language.text("已配置且最近一次测试通过。", "Configured and verified by the latest test.")
        }
    }
}

enum WeChatChannelCapabilities {
    static let developerSite = URL(string: "https://developers.weixin.qq.com")!
    static let workRobotDocumentation = URL(string: "https://developer.work.weixin.qq.com/document/path/91770")!
    static let officialAccountDocumentation =
        URL(string: "https://developers.weixin.qq.com/doc/offiaccount/Getting_Started/Overview.html")!

    /// Static capability facts; the workGroupBot phase becomes concrete once
    /// a provider reports configuration for `.weChat`.
    static func all(
        workGroupBotPhase: MessageChannelPhase = .needsSetup,
        personalPhase: MessageChannelPhase = .disabled
    ) -> [WeChatChannelCapability] {
        [
            WeChatChannelCapability(
                variant: .personal, phase: personalPhase, helpURL: PersonalWeChatMessageChannel.documentation),
            WeChatChannelCapability(
                variant: .workGroupBot, phase: workGroupBotPhase, helpURL: workRobotDocumentation),
            WeChatChannelCapability(
                variant: .officialAccount,
                phase: .unavailable(.officialAccountRequiresServerApproval),
                helpURL: officialAccountDocumentation),
        ]
    }
}

/// Minimal WeCom group-robot webhook adapter (`qyapi.weixin.qq.com`,
/// `cgi-bin/webhook/send`), always labeled as 企业微信 — never as personal
/// WeChat being connected. The webhook key arrives only through the injected
/// provider and is never logged, displayed, or embedded in errors.
final class WeChatMessageChannel {
    static let webhookHost = "qyapi.weixin.qq.com"
    static let webhookPath = "/cgi-bin/webhook/send"
    /// Official limit: one robot accepts at most 20 messages per minute and a
    /// markdown content is bounded at 4096 bytes.
    static let contentByteLimit = 4096

    enum ParsedResponse: Equatable {
        case accepted(MessageDeliveryReceipt)
        case rateLimited
        case rejected(code: Int, description: String?)
        case invalid
    }

    private let credentials: MessageChannelCredentialProviding
    private let transport: MessageChannelTransport
    private let deduplicator: MessageEventDeduplicator
    private let messageOptions: FeishuMessageOptions
    private let maximumStatusAge: TimeInterval
    private let now: () -> Date

    private let verificationLock = NSLock()
    private var verified: (fingerprint: Data, revision: UInt64, receipt: MessageDeliveryReceipt)?

    private func configurationFingerprint() -> Data {
        let value = [credentials.credential(for: .weChat) ?? "", credentials.targetID(for: .weChat) ?? ""].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(value.utf8)))
    }

    var verifiedReceipt: MessageDeliveryReceipt? {
        let fingerprint = configurationFingerprint()
        let revision = credentials.revision(for: .weChat)
        verificationLock.lock()
        defer { verificationLock.unlock() }
        guard credentials.isEnabled(.weChat), verified?.fingerprint == fingerprint, verified?.revision == revision else {
            verified = nil
            return nil
        }
        return verified?.receipt
    }

    private func recordVerification(_ receipt: MessageDeliveryReceipt, fingerprint: Data, revision: UInt64) {
        verificationLock.lock()
        defer { verificationLock.unlock() }
        verified = (fingerprint, revision, receipt)
    }

    init(
        credentials: MessageChannelCredentialProviding,
        transport: MessageChannelTransport = URLSessionMessageChannelTransport(),
        deduplicator: MessageEventDeduplicator = MessageEventDeduplicator(),
        messageOptions: FeishuMessageOptions = .standard,
        maximumStatusAge: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) {
        precondition(maximumStatusAge > 0)
        self.credentials = credentials
        self.transport = transport
        self.deduplicator = deduplicator
        self.messageOptions = messageOptions
        self.maximumStatusAge = maximumStatusAge
        self.now = now
    }

    /// The only send-capable WeChat variant in this app.
    var phase: MessageChannelPhase {
        guard credentials.isEnabled(.weChat) else { return .disabled }
        guard let key = credentials.credential(for: .weChat), (try? Self.validatedWebhookKey(key)) != nil else {
            return .needsSetup
        }
        return verifiedReceipt == nil ? .pendingVerification : .ready
    }

    var capabilities: [WeChatChannelCapability] {
        WeChatChannelCapabilities.all(workGroupBotPhase: phase)
    }

    func verifyConnection() async -> Result<MessageDeliveryReceipt, MessageChannelError> {
        let status: MessageTaskStatus
        do {
            status = try MessageTaskStatus(eventKind: .test, occurredAt: now())
        } catch {
            return .failure(.invalidStatus)
        }
        return await send(status).map { outcome in
            switch outcome {
            case .accepted(let receipt):
                return receipt
            case .duplicateSkipped:
                return MessageDeliveryReceipt(acceptedAt: self.now(), remoteMessageID: nil)
            }
        }
    }

    @MainActor
    func send(_ status: MessageTaskStatus, shouldSend: () -> Bool = { true }) async -> Result<MessageDeliveryOutcome, MessageChannelError> {
        guard credentials.isEnabled(.weChat) else { return .failure(.channelDisabled) }
        let age = now().timeIntervalSince(status.occurredAt)
        guard age.isFinite, age >= 0, age <= maximumStatusAge else { return .failure(.staleStatus) }
        switch deduplicator.begin(status.eventID) {
        case .duplicate: return .success(.duplicateSkipped)
        case .atCapacity: return .failure(.rateLimited(retryAfterSeconds: nil))
        case .reserved: break
        }
        defer { deduplicator.release(status.eventID) }
        let fingerprint = configurationFingerprint()
        let revision = credentials.revision(for: .weChat)
        guard shouldSend() else { return .failure(.cancelled) }
        guard !Task.isCancelled else { return .failure(.cancelled) }

        guard let rawKey = credentials.credential(for: .weChat) else { return .failure(.missingCredential) }
        let key: String
        do { key = try Self.validatedWebhookKey(rawKey) } catch { return .failure(.invalidCredential) }

        let payload: Data
        do {
            payload = try Self.requestPayload(status: status, messageOptions: messageOptions)
        } catch let error as MessageChannelError {
            return .failure(error)
        } catch {
            return .failure(.encodingFailed)
        }
        guard let endpoint = Self.endpoint(key: key) else { return .failure(.invalidCredential) }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(request)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            // Transport errors can embed the webhook key; report without cause.
            return .failure(.transportFailed)
        }
        guard !Task.isCancelled, shouldSend(), credentials.isEnabled(.weChat),
            credentials.revision(for: .weChat) == revision, configurationFingerprint() == fingerprint
        else { return .failure(.cancelled) }

        switch http.statusCode {
        case 200..<300:
            break
        case 429:
            return .failure(.rateLimited(retryAfterSeconds: nil))
        default:
            return .failure(.httpStatus(http.statusCode))
        }
        switch Self.parseResponseBody(data, now: now) {
        case .accepted(let receipt):
            deduplicator.claim(status.eventID)
            recordVerification(receipt, fingerprint: fingerprint, revision: revision)
            return .success(.accepted(receipt))
        case .rateLimited:
            return .failure(.rateLimited(retryAfterSeconds: nil))
        case .rejected(let code, let description):
            return .failure(.rejected(code: code, description: description))
        case .invalid:
            return .failure(.invalidResponse)
        }
    }

    /// Webhook keys are lowercase GUIDs (`8-4-4-4-12` hex).
    static func validatedWebhookKey(_ rawValue: String) throws -> String {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        guard key.range(of: pattern, options: .regularExpression) != nil else {
            throw MessageChannelError.invalidCredential
        }
        return key
    }

    /// The official protocol carries the key in the query string; the fixed
    /// host and path keep the surface unambiguous.
    static func endpoint(key: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = webhookHost
        components.port = 443
        components.path = webhookPath
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard components.query == "key=\(key)", components.fragment == nil else { return nil }
        return components.url
    }

    static func requestPayload(
        status: MessageTaskStatus, messageOptions: FeishuMessageOptions = .standard,
        language: WidgetLanguage = .storedOrAutomatic()
    ) throws -> Data {
        guard status.hasCurrentExpiry() else { throw MessageChannelError.staleStatus }
        return try payload(content: messageContent(status: status, options: messageOptions, language: language))
    }

    static func messageContent(
        status: MessageTaskStatus, options: FeishuMessageOptions,
        language: WidgetLanguage, markdown: Bool = true
    ) -> String {
        if let content = FeishuWebhookService.noticeContent(for: status, options: options, language: language) {
            return content.rendered(markdown: markdown)
        }
        // Task-state updates are supported by WeChat independently of the
        // observer-confirmed Feishu completion event. Raw replies use their
        // separate preservation/chunking path and never enter this formatter.
        let title = status.summary(language).components(separatedBy: "\n")[0]
        var lines: [String] = []
        if options.includesAgentName { lines.append(language.text("**Agent**：Codex", "**Agent**: Codex")) }
        if options.includesAccountLabel, let account = status.accountLabel {
            lines.append(language.text("**账号**：", "**Account**: ") + escapedLabel(account.value))
        }
        if let task = status.taskLabel { lines.append(language.text("任务：", "Task: ") + escapedLabel(task.value)) }
        if let state = status.taskState { lines.append(language.text("状态：", "State: ") + MessageNoticeFormat.state(state, language: language)) }
        if let reason = status.failureReason { lines.append(language.text("原因：", "Reason: ") + MessageNoticeFormat.reason(reason, language: language)) }
        let hasFacts = status.accountFacts != nil || status.fiveHourRemainingPercent != nil || status.sevenDayRemainingPercent != nil
        if hasFacts {
            for (label, remaining, resetsAt) in [
                ("5h", status.fiveHourRemainingPercent, status.accountFacts?.fiveHourResetsAt),
                ("7d", status.sevenDayRemainingPercent, status.accountFacts?.sevenDayResetsAt),
            ] {
                let reset = resetsAt.map(MessageNoticeFormat.fullDate) ?? language.text("未知", "Unknown")
                if options.includesQuotas {
                    let value =
                        remaining.map {
                            $0.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))) + "%"
                        } ?? language.text("未知", "Unknown")
                    var line = "**\(label)**：" + language.text("剩余 ", "remaining ") + value
                    if options.includesResetTimes { line += language.text(" · 重置 ", " · resets ") + reset }
                    lines.append(line)
                } else if options.includesResetTimes {
                    lines.append("**\(label)** " + language.text("重置：", "resets: ") + reset)
                }
            }
        }
        let checked =
            language.text("**核对时间（北京时间）**：", "**Checked (Beijing time, UTC+8)**: ")
            + MessageNoticeFormat.fullDate(status.occurredAt)
        if options.includesResetCredits, hasFacts {
            let fixed = MessageNoticeFormat.Content(title: title, template: "blue", lines: lines + [checked]).rendered()
            lines.append(
                taskResetCreditLine(
                    status: status, options: options, language: language,
                    byteBudget: max(0, contentByteLimit - fixed.utf8.count - 1)))
        }
        lines.append(checked)
        return MessageNoticeFormat.Content(title: title, template: "blue", lines: lines).rendered(markdown: markdown)
    }

    private static func taskResetCreditLine(
        status: MessageTaskStatus, options: FeishuMessageOptions, language: WidgetLanguage, byteBudget: Int
    ) -> String {
        let count = status.accountFacts?.availableResetCredits
        let value = count.map(String.init) ?? language.text("未知", "Unknown")
        let prefix = language.text("**重置卡可用**：\(value) 次", "**Available resets**: \(value)")
        guard options.resetExpiryDetail != .none, count != 0 else { return prefix }
        let upcoming = (status.accountFacts?.resetCreditExpiries ?? []).filter { $0 >= status.occurredAt }
        let available = count.map { Array(upcoming.prefix($0)) } ?? upcoming
        let dates = options.resetExpiryDetail == .nearest ? Array(available.prefix(1)) : available
        guard !dates.isEmpty else { return prefix + language.text(" · 到期时间未知", " · expiry unknown") }
        let omitted = language.text(" · 其余到期时间请在 AiGoodBro 查看", " · See AiGoodBro for remaining expiries")
        var rendered: [String] = []
        for (index, date) in dates.enumerated() {
            let next = rendered + [MessageNoticeFormat.fullDate(date)]
            let candidate = prefix + language.text(" · 到期 ", " · expires ") + next.joined(separator: language.text("、", ", "))
            let reserve = index + 1 < dates.count ? omitted.utf8.count : 0
            guard candidate.utf8.count + reserve <= byteBudget else { break }
            rendered = next
        }
        var line = prefix
        if !rendered.isEmpty { line += language.text(" · 到期 ", " · expires ") + rendered.joined(separator: language.text("、", ", ")) }
        if rendered.count < dates.count { line += omitted }
        return line
    }

    private static func escapedLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
    }

    static func payload(content: String) throws -> Data {
        guard content.utf8.count <= contentByteLimit else {
            throw MessageChannelError.messageTooLong(limit: contentByteLimit)
        }
        let payload: [String: Any] = [
            "msgtype": "markdown",
            "markdown": ["content": content],
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw MessageChannelError.encodingFailed
        }
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw MessageChannelError.encodingFailed
        }
    }

    /// Parses `{"errcode":0,"errmsg":"ok"}`.
    static func parseResponseBody(_ data: Data, now: () -> Date = Date.init) -> ParsedResponse {
        guard data.count <= URLSessionMessageChannelTransport.maximumResponseBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let number = object["errcode"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let code = Int(exactly: number.doubleValue)
        else {
            return .invalid
        }
        if code == 0 {
            return .accepted(MessageDeliveryReceipt(acceptedAt: now(), remoteMessageID: nil))
        }
        if code == 45009 { return .rateLimited }
        return .rejected(code: code, description: nil)
    }
}
