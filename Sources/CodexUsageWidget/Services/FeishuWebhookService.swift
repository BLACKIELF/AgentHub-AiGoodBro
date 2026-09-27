import Foundation
import Security

enum FeishuWebhookError: LocalizedError {
    case invalidWebhook
    case missingWebhook
    case keychain(OSStatus)
    case keychainAuthorizationRequired
    case keychainTimedOut
    case keychainBusy
    case cancelled
    case invalidMaskedAccount
    case invalidNotification
    case encodingFailed
    case transportFailed
    case invalidResponse
    case httpStatus(Int)
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidWebhook:
            return WidgetLanguage.storedOrAutomatic().text("飞书 Webhook 地址无效。", "The Feishu webhook URL is invalid.")
        case .missingWebhook:
            return WidgetLanguage.storedOrAutomatic().text("尚未保存飞书 Webhook。", "No Feishu webhook has been saved.")
        case .keychain(let status):
            return WidgetLanguage.storedOrAutomatic().text("无法访问飞书 Webhook 凭据（\(status)）。", "Could not access the Feishu webhook credential (\(status)).")
        case .keychainAuthorizationRequired:
            return WidgetLanguage.storedOrAutomatic().text(
                "飞书连接需要钥匙串授权。请在使用引导或自动化中心点击“授权连接”；后台不会弹出密码框。",
                "Feishu needs Keychain permission. Choose Authorize connection in Getting started or Automation. Background checks will not show password prompts.")
        case .keychainTimedOut:
            return WidgetLanguage.storedOrAutomatic().text("读取飞书配置超时；账号刷新与暖号继续运行。", "Reading the Feishu configuration timed out. Account refresh and warm-up continue.")
        case .keychainBusy:
            return WidgetLanguage.storedOrAutomatic().text(
                "飞书配置仍在等待系统响应；账号刷新与暖号继续运行。", "The Feishu configuration is still waiting for the system. Account refresh and warm-up continue.")
        case .cancelled:
            return WidgetLanguage.storedOrAutomatic().text("飞书通知已取消。", "The Feishu notification was cancelled.")
        case .invalidMaskedAccount:
            return WidgetLanguage.storedOrAutomatic().text("通知中的账号名称必须先脱敏。", "Account names must be masked before sending a notification.")
        case .invalidNotification:
            return WidgetLanguage.storedOrAutomatic().text("飞书通知内容无效。", "The Feishu notification content is invalid.")
        case .encodingFailed:
            return WidgetLanguage.storedOrAutomatic().text("无法生成飞书通知。", "Could not create the Feishu notification.")
        case .transportFailed:
            return WidgetLanguage.storedOrAutomatic().text("飞书通知发送失败。", "Could not send the Feishu notification.")
        case .invalidResponse:
            return WidgetLanguage.storedOrAutomatic().text("飞书返回了无法识别的响应。", "Feishu returned an unrecognized response.")
        case .httpStatus(let status):
            return WidgetLanguage.storedOrAutomatic().text("飞书通知请求失败（HTTP \(status)）。", "The Feishu notification request failed (HTTP \(status)).")
        case .rejected(let code):
            return WidgetLanguage.storedOrAutomatic().text("飞书拒绝了通知（\(code)）。", "Feishu rejected the notification (\(code)).")
        }
    }

    static func credential(_ status: OSStatus) -> FeishuWebhookError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .keychainAuthorizationRequired
        default:
            return .keychain(status)
        }
    }
}

/// A display-only account label. Raw email addresses, IDs and paths are rejected.
struct FeishuMaskedAccount: Equatable {
    let value: String

    /// Only UI display names enter this initializer; credentials and account IDs do not.
    init(displayName: String, dispatchCode: String? = nil) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-•·()（）"))
        guard !name.isEmpty, name.count <= 48,
            name.unicodeScalars.allSatisfy({
                allowed.contains($0) || $0.properties.generalCategory == .otherSymbol
                    || $0.value == 0x200D || $0.value == 0xFE0F
            }),
            dispatchCode == nil || dispatchCode?.range(of: "^[A-Z]$", options: .regularExpression) != nil
        else { throw FeishuWebhookError.invalidMaskedAccount }
        // Dispatch letters are useful inside the app, but are not account facts
        // and must never be rendered in outbound messages.
        value = name
    }

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " ._-*•()（）")
        )
        guard !trimmed.isEmpty,
            trimmed.count <= 64,
            trimmed.unicodeScalars.allSatisfy(allowed.contains),
            trimmed.contains("***") || trimmed.contains("•••")
        else {
            throw FeishuWebhookError.invalidMaskedAccount
        }
        self.value = trimmed
    }
}

struct FeishuSwitchNotification {
    enum SwitchOrigin: Equatable {
        case manual
        case lowQuota
        case restartTest
    }

    enum Event {
        case test
        case lowQuotaDetected
        case quotaChange(CodexQuotaEvent)
        case switchSucceeded
        case switchFailed(FailureReason)
    }

    enum FailureReason: String {
        case noEligibleAccount
        case appBusy
        case validationFailed
        case restartFailed
        case networkUnavailable
        case unknown

        var displayName: String {
            displayName(.storedOrAutomatic())
        }

        func displayName(_ language: WidgetLanguage) -> String {
            switch self {
            case .noEligibleAccount: return language.text("没有符合条件的候选账号", "No eligible account")
            case .appBusy: return language.text("Codex 正在处理任务", "Codex is working on a task")
            case .validationFailed: return language.text("切换前校验失败", "Pre-switch verification failed")
            case .restartFailed: return language.text("Codex 安全重启失败", "Codex could not restart safely")
            case .networkUnavailable: return language.text("网络不可用", "Network unavailable")
            case .unknown: return language.text("未知错误", "Unknown error")
            }
        }
    }

    let event: Event
    let sourceAccount: FeishuMaskedAccount
    let targetAccount: FeishuMaskedAccount?
    let switchOrigin: SwitchOrigin
    let triggerThresholdPercent: Int
    let fiveHourTriggerThresholdPercent: Int
    let fiveHourRemainingPercent: Double?
    let sevenDayRemainingPercent: Double?
    let accountFacts: FeishuAccountFacts
    let messageOptions: FeishuMessageOptions
    let occurredAt: Date
    let eventID: UUID

    init(
        event: Event,
        sourceAccount: FeishuMaskedAccount,
        targetAccount: FeishuMaskedAccount? = nil,
        switchOrigin: SwitchOrigin = .manual,
        triggerThresholdPercent: Int,
        fiveHourTriggerThresholdPercent: Int = 5,
        fiveHourRemainingPercent: Double?,
        sevenDayRemainingPercent: Double?,
        accountFacts: FeishuAccountFacts? = nil,
        messageOptions: FeishuMessageOptions = .standard,
        occurredAt: Date = Date(),
        eventID: UUID = UUID()
    ) throws {
        let percentages = [fiveHourRemainingPercent, sevenDayRemainingPercent].compactMap { $0 }
        guard (1...100).contains(triggerThresholdPercent),
            (1...100).contains(fiveHourTriggerThresholdPercent),
            percentages.allSatisfy({ (0...100).contains($0) })
        else {
            throw FeishuWebhookError.invalidNotification
        }
        if case .switchSucceeded = event, targetAccount == nil {
            throw FeishuWebhookError.invalidNotification
        }
        if case .lowQuotaDetected = event,
            !(fiveHourRemainingPercent.map { $0 <= Double(fiveHourTriggerThresholdPercent) } ?? false),
            !(sevenDayRemainingPercent.map { $0 < Double(triggerThresholdPercent) } ?? false)
        {
            throw FeishuWebhookError.invalidNotification
        }
        if case .quotaChange(let change) = event {
            switch change {
            case .quotaReset(let fiveHour, let sevenDay):
                guard fiveHour || sevenDay else { throw FeishuWebhookError.invalidNotification }
            case .resetCreditsAdded(let added, let available):
                guard added > 0, available >= added else { throw FeishuWebhookError.invalidNotification }
            }
        }
        self.event = event
        self.sourceAccount = sourceAccount
        self.targetAccount = targetAccount
        self.switchOrigin = switchOrigin
        self.triggerThresholdPercent = triggerThresholdPercent
        self.fiveHourTriggerThresholdPercent = fiveHourTriggerThresholdPercent
        self.fiveHourRemainingPercent = fiveHourRemainingPercent
        self.sevenDayRemainingPercent = sevenDayRemainingPercent
        self.accountFacts =
            try accountFacts
            ?? FeishuAccountFacts.quotasOnly(
                fiveHourRemaining: fiveHourRemainingPercent,
                sevenDayRemaining: sevenDayRemainingPercent
            )
        self.messageOptions = messageOptions
        self.occurredAt = occurredAt
        self.eventID = eventID
    }
}

private final class FeishuRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A webhook token is part of the URL. Refusing every redirect prevents
        // both cross-origin disclosure and HTTPS downgrade without ambiguity.
        completionHandler(nil)
    }
}

/// A timed-out Security call cannot be cancelled. Discard its eventual result,
/// including the endpoint, so an old notification is never sent after recovery.
final class FeishuKeychainRead<Value> {
    private let lock = NSLock()
    private let deadline: DispatchTime
    private var completion: ((Result<Value, FeishuWebhookError>) -> Void)?

    init(timeout: TimeInterval, completion: @escaping (Result<Value, FeishuWebhookError>) -> Void) {
        deadline = .now() + timeout
        self.completion = completion
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion == nil || DispatchTime.now() >= deadline
    }

    func finish(_ result: Result<Value, FeishuWebhookError>) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        guard let callback else { return }
        let delivered: Result<Value, FeishuWebhookError> = DispatchTime.now() >= deadline ? .failure(.keychainTimedOut) : result
        DispatchQueue.main.async { callback(delivered) }
    }
}

/// Existing credentials use the file-based macOS Keychain. Its UI policy is
/// process-wide; query-only authentication flags do not protect legacy items.
/// Serialize every app-owned Keychain operation and restore the previous policy.
final class FeishuKeychainInteraction {
    private static let lock = NSLock()
    private let getAllowed: () throws -> Bool
    private let setAllowed: (Bool) throws -> Void

    static let system = FeishuKeychainInteraction(
        getAllowed: {
            var allowed: DarwinBoolean = false
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            guard status == errSecSuccess else { throw FeishuWebhookError.credential(status) }
            return allowed.boolValue
        },
        setAllowed: { allowed in
            let status = SecKeychainSetUserInteractionAllowed(allowed)
            guard status == errSecSuccess else { throw FeishuWebhookError.credential(status) }
        })

    init(getAllowed: @escaping () throws -> Bool, setAllowed: @escaping (Bool) throws -> Void) {
        self.getAllowed = getAllowed
        self.setAllowed = setAllowed
    }

    func perform<Value>(allowInteraction: Bool, _ operation: () throws -> Value) throws -> Value {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let previous = try getAllowed()
        try setAllowed(allowInteraction)
        let result = Result { try operation() }
        try setAllowed(previous)
        return try result.get()
    }
}

final class FeishuWebhookService {
    static let keychainService = "com.blackielf.codex-account-manager-next.feishu-webhook"

    private static let keychainAccount = "default"
    private static let allowedHosts = Set(["open.feishu.cn", "open.larksuite.com"])
    private static let webhookPathPrefix = "/open-apis/bot/v2/hook/"
    private static let maximumResponseBytes = 64 * 1024

    private let redirectGuard: FeishuRedirectGuard
    private let session: URLSession
    fileprivate let keychainQueue = DispatchQueue(label: "com.blackielf.codex-account-manager-next.feishu-keychain", qos: .utility)
    private let keychainCapacity: DispatchSemaphore
    private let keychainReadTimeout: TimeInterval
    private let keychainInteraction: FeishuKeychainInteraction
    private let updateItem: (CFDictionary, CFDictionary) -> OSStatus
    private let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    init(
        keychainReadTimeout: TimeInterval = 5,
        maximumPendingReads: Int = 16,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        keychainInteraction: FeishuKeychainInteraction = .system,
        updateItem: @escaping (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
        copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    ) {
        precondition(keychainReadTimeout > 0 && maximumPendingReads > 0)
        self.keychainReadTimeout = keychainReadTimeout
        self.keychainInteraction = keychainInteraction
        self.updateItem = updateItem
        keychainCapacity = DispatchSemaphore(value: maximumPendingReads)
        self.copyMatching = copyMatching
        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1

        let redirectGuard = FeishuRedirectGuard()
        self.redirectGuard = redirectGuard
        session = URLSession(
            configuration: configuration,
            delegate: redirectGuard,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func storeWebhook(_ rawValue: String, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
        performUserKeychainAction(
            {
                try self.storeWebhookSynchronously(rawValue)
                _ = try self.loadStoredWebhook()
            }, completion: completion)
    }

    func authorizeStoredWebhook(completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
        performUserKeychainAction({ _ = try self.loadStoredWebhook() }, completion: completion)
    }

    func removeStoredWebhook(completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
        performUserKeychainAction(
            {
                let status = SecItemDelete(Self.keychainQuery as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw FeishuWebhookError.credential(status)
                }
            }, completion: completion)
    }

    /// Only explicit setup actions may request the native system password dialog.
    /// Keep the action pending until it returns so retries cannot stack dialogs.
    private func performUserKeychainAction(
        _ operation: @escaping () throws -> Void,
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        keychainQueue.async {
            let result: Result<Void, FeishuWebhookError>
            do {
                try self.keychainInteraction.perform(allowInteraction: true, operation)
                result = .success(())
            } catch let error as FeishuWebhookError {
                result = .failure(error)
            } catch {
                result = .failure(.invalidWebhook)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func storeWebhookSynchronously(_ rawValue: String) throws {
        let endpoint = try Self.validatedWebhookURL(from: rawValue)
        let data = Data(endpoint.absoluteString.utf8)
        let query = Self.keychainQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = updateItem(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw FeishuWebhookError.credential(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw FeishuWebhookError.credential(addStatus)
        }
    }

    func hasStoredWebhook(completion: @escaping (Result<Bool, FeishuWebhookError>) -> Void) {
        readCredential(
            {
                do {
                    _ = try self.loadStoredWebhook()
                    return true
                } catch FeishuWebhookError.missingWebhook {
                    return false
                }
            }, completion: completion)
    }

    func send(
        _ notification: FeishuSwitchNotification,
        shouldSend: @escaping () -> Bool = { true },
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        readCredential(
            { try self.loadStoredWebhook() },
            completion: { result in
                guard shouldSend() else {
                    completion(.failure(.cancelled))
                    return
                }
                switch result {
                case .success(let endpoint):
                    self.send(notification, to: endpoint, completion: completion)
                case .failure(let error):
                    completion(.failure(error))
                }
            })
    }

    private func readCredential<Value>(
        _ operation: @escaping () throws -> Value,
        completion: @escaping (Result<Value, FeishuWebhookError>) -> Void
    ) {
        guard keychainCapacity.wait(timeout: .now()) == .success else {
            DispatchQueue.main.async { completion(.failure(.keychainBusy)) }
            return
        }
        let read = FeishuKeychainRead<Value>(timeout: keychainReadTimeout, completion: completion)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + keychainReadTimeout) {
            read.finish(.failure(.keychainTimedOut))
        }
        keychainQueue.async {
            defer { self.keychainCapacity.signal() }
            guard !read.isFinished else {
                read.finish(.failure(.keychainTimedOut))
                return
            }
            do {
                read.finish(.success(try self.keychainInteraction.perform(allowInteraction: false, operation)))
            } catch let error as FeishuWebhookError {
                read.finish(.failure(error))
            } catch {
                read.finish(.failure(.invalidWebhook))
            }
        }
    }

    func sendPublicResetAnnouncement(
        _ announcement: PublicResetAnnouncement,
        shouldSend: @escaping () -> Bool,
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        let body: Data
        do { body = try Self.publicResetPayload(announcement) } catch {
            completion(.failure(.invalidNotification))
            return
        }
        readCredential(
            { try self.loadStoredWebhook() },
            completion: { result in
                guard shouldSend() else {
                    completion(.failure(.cancelled))
                    return
                }
                switch result {
                case .success(let endpoint): self.send(body: body, to: endpoint, completion: completion)
                case .failure(let error): completion(.failure(error))
                }
            })
    }

    func sendPublicResetForecast(
        _ forecast: PublicResetForecastNotification,
        shouldSend: @escaping () -> Bool,
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        let body: Data
        do { body = try Self.publicResetForecastPayload(forecast) } catch {
            completion(.failure(.invalidNotification))
            return
        }
        readCredential(
            { try self.loadStoredWebhook() },
            completion: { result in
                guard shouldSend() else {
                    completion(.failure(.cancelled))
                    return
                }
                switch result {
                case .success(let endpoint): self.send(body: body, to: endpoint, completion: completion)
                case .failure(let error): completion(.failure(error))
                }
            })
    }

    static func publicResetPayload(
        _ announcement: PublicResetAnnouncement,
        language: WidgetLanguage = .storedOrAutomatic()
    ) throws -> Data {
        guard announcement.isValid(now: Date()) else { throw FeishuWebhookError.invalidNotification }
        let link = announcement.source.url ?? PublicResetClient.siteURL
        let message =
            announcement.summary(language)
            + "\n\n" + language.text("来源：Codex Resets（第三方汇总）", "Source: Codex Resets (third-party feed)")
            + "\n[" + language.text("查看来源", "View source") + "](\(link.absoluteString))"
        let template = announcement.resetType == .banked ? "purple" : "turquoise"
        return try JSONSerialization.data(withJSONObject: [
            "msg_type": "interactive",
            "card": [
                "header": ["template": template, "title": ["tag": "plain_text", "content": announcement.title(language)]],
                "elements": [["tag": "div", "text": ["tag": "lark_md", "content": message]]],
            ],
        ])
    }

    static func publicResetForecastPayload(
        _ forecast: PublicResetForecastNotification,
        language: WidgetLanguage = .storedOrAutomatic()
    ) throws -> Data {
        guard forecast.isValid(now: Date()) else { throw FeishuWebhookError.invalidNotification }
        var lines = [
            language.text("**状态**：公开重置预告，待来源确认", "**Status**: Public reset forecast; awaiting source confirmation"),
            language.text("**发布时间**：", "**Published**: ") + language.dateTime(forecast.announcedAt),
        ]
        if let latestBy = forecast.latestBy {
            lines.append(language.text("**预计最晚时间**：", "**Expected by**: ") + language.dateTime(latestBy))
        } else {
            lines.append(language.text("**预计重置时间**：待确认", "**Expected reset time**: To be confirmed"))
        }
        lines.append(language.text("这只是公开预告，不代表重置已完成或额度已到账。", "This is only a public forecast; it does not confirm completion or credited quota."))
        lines.append(language.text("来源：Codex Resets（公开预告）", "Source: Codex Resets (public forecast)"))
        lines.append("[" + language.text("查看来源帖文", "View source post") + "](\(forecast.sourceURL.absoluteString))")
        let payload: [String: Any] = [
            "msg_type": "interactive",
            "card": [
                "header": [
                    "template": "turquoise",
                    "title": ["tag": "plain_text", "content": language.text("重置预告 · 待确认", "Reset forecast · unconfirmed")],
                ],
                "elements": [["tag": "div", "text": ["tag": "lark_md", "content": lines.joined(separator: "\n\n")]]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Sends an observer-confirmed task-completion card. The DTO itself fails
    /// closed; the payload is built before any credential read, the opt-in
    /// gate is rechecked after it, and the existing allowlisted sender,
    /// redirect guard and bounded response parsing are reused without a
    /// second transport. The event ID stays out of the rendered card.
    func sendTaskCompletion(
        _ taskCompletion: FeishuTaskCompletionNotification,
        shouldSend: @escaping () -> Bool = { true },
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        let body: Data
        do { body = try Self.taskCompletionPayload(taskCompletion) } catch {
            completion(.failure(.invalidNotification))
            return
        }
        readCredential(
            { try self.loadStoredWebhook() },
            completion: { result in
                guard shouldSend() else {
                    completion(.failure(.cancelled))
                    return
                }
                switch result {
                case .success(let endpoint): self.send(body: body, to: endpoint, completion: completion)
                case .failure(let error): completion(.failure(error))
                }
            })
    }

    static func taskCompletionPayload(
        _ completion: FeishuTaskCompletionNotification,
        language: WidgetLanguage = .storedOrAutomatic(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) throws -> Data {
        guard completion.proof == .confirmedByTaskObserver else {
            throw FeishuWebhookError.invalidNotification
        }
        var lines = [
            language.text("**结果**：任务已完成", "**Result**: Task completed")
        ]
        switch completion.category {
        case .dispatchedAgent:
            lines.append(language.text("**类型**：CLI 派发任务", "**Type**: Dispatched agent task"))
        case .kimiConversation:
            lines.append(language.text("**类型**：Kimi 会话任务", "**Type**: Kimi conversation task"))
        case .codexConversation:
            lines.append(language.text("**类型**：Codex 对话", "**Type**: Codex conversation"))
        }
        if let attempts = completion.attemptCount {
            lines.append(language.text("**尝试次数**：\(attempts)", "**Attempts**: \(attempts)"))
        }
        if let account = completion.accountLabel {
            lines.append(language.text("**账号**：\(account.value)", "**Account**: \(account.value)"))
        }
        lines.append(
            language.text("**时间**：", "**Time**: ")
                + compactDate(completion.occurredAt, language: language, timeZone: timeZone))
        lines.append(
            language.text(
                "请打开原任务查看结果。",
                "Open the original task to review the result."))

        let payload: [String: Any] = [
            "msg_type": "interactive",
            "card": [
                "schema": "2.0",
                "config": ["wide_screen_mode": true],
                "header": [
                    "title": ["tag": "plain_text", "content": language.text("✅ Codex 任务完成", "✅ Codex task completed")],
                    "template": "green",
                ],
                "body": [
                    "elements": [
                        [
                            "tag": "markdown",
                            "content": lines.joined(separator: "\n"),
                        ]
                    ]
                ],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw FeishuWebhookError.encodingFailed
        }
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw FeishuWebhookError.encodingFailed
        }
    }

    private func send(
        _ notification: FeishuSwitchNotification,
        to endpoint: URL,
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        let body: Data
        do {
            body = try Self.payloadData(for: notification)
        } catch let error as FeishuWebhookError {
            completion(.failure(error))
            return
        } catch {
            completion(.failure(.encodingFailed))
            return
        }

        send(body: body, to: endpoint, completion: completion)
    }

    private func send(
        body: Data, to endpoint: URL,
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 12
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Task { [request] in
            do {
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    completion(.failure(.httpStatus(http.statusCode)))
                    return
                }
                guard response.expectedContentLength <= Self.maximumResponseBytes else {
                    completion(.failure(.invalidResponse))
                    return
                }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < Self.maximumResponseBytes else {
                        completion(.failure(.invalidResponse))
                        return
                    }
                    data.append(byte)
                }
                completion(Self.parseResponse(data))
            } catch {
                // URLSession errors can contain the secret URL.
                completion(.failure(.transportFailed))
            }
        }
    }

    static func validatedWebhookURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.count <= 512,
            trimmed.unicodeScalars.allSatisfy({
                !$0.properties.isWhitespace && $0.properties.generalCategory != .control
            }),
            let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            allowedHosts.contains(host),
            components.user == nil,
            components.password == nil,
            components.port == nil || components.port == 443,
            components.query == nil,
            components.fragment == nil,
            components.percentEncodedPath.hasPrefix(webhookPathPrefix)
        else {
            throw FeishuWebhookError.invalidWebhook
        }

        let token = String(components.percentEncodedPath.dropFirst(webhookPathPrefix.count))
        let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard (16...256).contains(token.count),
            token.unicodeScalars.allSatisfy(tokenCharacters.contains),
            let endpoint = components.url
        else {
            throw FeishuWebhookError.invalidWebhook
        }
        return endpoint
    }

    static func payloadData(
        for notification: FeishuSwitchNotification,
        language: WidgetLanguage = .storedOrAutomatic(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) throws -> Data {
        let presentation = presentation(for: notification.event, origin: notification.switchOrigin, language: language)
        let options = notification.messageOptions
        var lines = [language.text("**结果**：\(presentation.result)", "**Result**: \(presentation.result)")]
        switch notification.event {
        case .test:
            lines.append(language.text("仅测试连接；不会切换账号、重启 Codex 或使用 Reset 卡。", "Connection test only; no account switch, Codex restart, or reset-credit use."))
        case .quotaChange(let change):
            switch change {
            case .quotaReset:
                lines.append(
                    language.text(
                        "**变化类型**：仅报告官方额度窗口变化；Reset 卡增减及使用状态另行核对",
                        "**Change type**: Official quota-window change reported only; reset-credit changes and usage are verified separately"))
            case .resetCreditsAdded(let added, let available):
                lines.append(
                    language.text(
                        "**变化类型**：获得 Reset 卡 / 重置机会",
                        "**Change type**: Reset credit / reset opportunity granted"))
                lines.append(language.text("**变化**：新增 \(added) 次，可用 \(available) 次", "**Change**: +\(added), \(available) available"))
            }
        case .lowQuotaDetected:
            lines.append(lowQuotaTrigger(for: notification, language: language))
        case .switchSucceeded, .switchFailed:
            break
        }
        if options.includesAgentName {
            lines.append(language.text("**Agent**：Codex", "**Agent**: Codex"))
        }
        if options.includesAccountLabel {
            switch notification.event {
            case .switchSucceeded, .switchFailed:
                if let target = notification.targetAccount {
                    lines.append(
                        language.text(
                            "**切换路径**：\(notification.sourceAccount.value) → \(target.value)",
                            "**Switch path**: \(notification.sourceAccount.value) → \(target.value)"))
                } else {
                    lines.append(
                        language.text(
                            "**当前账号**：\(notification.sourceAccount.value)",
                            "**Current account**: \(notification.sourceAccount.value)"))
                }
            default:
                lines.append(language.text("**账号**：\(notification.sourceAccount.value)", "**Account**: \(notification.sourceAccount.value)"))
                if case .lowQuotaDetected = notification.event, let target = notification.targetAccount {
                    lines.append(language.text("**推荐账号**：\(target.value)", "**Recommended account**: \(target.value)"))
                }
            }
        }
        if options.includesQuotas {
            lines.append(
                quotaLine(
                    label: language.text("5 小时", "5h"), value: notification.accountFacts.fiveHour,
                    includesResetTime: options.includesResetTimes, language: language, timeZone: timeZone
                )
            )
            lines.append(
                quotaLine(
                    label: language.text("7 天", "7d"), value: notification.accountFacts.sevenDay,
                    includesResetTime: options.includesResetTimes, language: language, timeZone: timeZone
                )
            )
        } else if options.includesResetTimes {
            lines += resetTimeLines(for: notification.accountFacts, language: language, timeZone: timeZone)
        }
        if options.includesResetCredits {
            lines.append(resetCreditLine(for: notification, language: language, timeZone: timeZone))
        }

        let payload: [String: Any] = [
            "msg_type": "interactive",
            "card": [
                "schema": "2.0",
                "config": ["wide_screen_mode": true],
                "header": [
                    "title": ["tag": "plain_text", "content": presentation.title],
                    "template": presentation.template,
                ],
                "body": [
                    "elements": [
                        [
                            "tag": "markdown",
                            "content": lines.joined(separator: "\n"),
                        ]
                    ]
                ],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw FeishuWebhookError.encodingFailed
        }
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw FeishuWebhookError.encodingFailed
        }
    }

    static func parseResponse(_ data: Data) -> Result<Void, FeishuWebhookError> {
        guard data.count <= maximumResponseBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure(.invalidResponse)
        }
        let rawCode = object["code"] ?? object["StatusCode"]
        let code: Int?
        if let number = rawCode as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            number.doubleValue.rounded() == number.doubleValue
        {
            code = number.intValue
        } else if let string = rawCode as? String {
            code = Int(string)
        } else {
            code = nil
        }
        guard let code else { return .failure(.invalidResponse) }
        return code == 0 ? .success(()) : .failure(.rejected(code))
    }

    private func loadStoredWebhook() throws -> URL {
        var query = Self.keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw FeishuWebhookError.missingWebhook }
        guard status == errSecSuccess else { throw FeishuWebhookError.credential(status) }
        guard let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw FeishuWebhookError.invalidWebhook
        }
        return try Self.validatedWebhookURL(from: value)
    }

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func percentText(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }

    private static func quotaLine(
        label: String,
        value: FeishuQuotaValue,
        includesResetTime: Bool,
        language: WidgetLanguage,
        timeZone: TimeZone
    ) -> String {
        let detail: String
        switch value {
        case .finite(let remaining, let resetsAt):
            detail =
                language.text(
                    "剩余 \(percentText(remaining))%",
                    "\(percentText(remaining))% left"
                )
                + (includesResetTime ? resetSuffix(resetsAt, language: language, timeZone: timeZone) : "")
        case .unlimited:
            detail = "∞"
        case .unknown:
            detail = language.text("未知", "Unknown")
        }
        return language.text("**\(label)**：\(detail)", "**\(label)**: \(detail)")
    }

    private static func resetTimeLines(
        for facts: FeishuAccountFacts,
        language: WidgetLanguage,
        timeZone: TimeZone
    ) -> [String] {
        [(language.text("5 小时重置", "5h reset"), facts.fiveHour), (language.text("7 天重置", "7d reset"), facts.sevenDay)]
            .map { label, value in
                guard case .finite(_, let resetsAt) = value else {
                    return language.text("**\(label)**：未知", "**\(label)**: Unknown")
                }
                return language.text("**\(label)**：", "**\(label)**: ")
                    + compactDate(resetsAt, language: language, timeZone: timeZone)
            }
    }

    private static func resetSuffix(_ date: Date?, language: WidgetLanguage, timeZone: TimeZone) -> String {
        guard let date else { return " · " + language.text("重置时间未知", "reset unknown") }
        return " · " + language.text("重置 ", "resets ") + compactDate(date, language: language, timeZone: timeZone)
    }

    private static func resetCreditLine(
        for notification: FeishuSwitchNotification,
        language: WidgetLanguage,
        timeZone: TimeZone
    ) -> String {
        let count = notification.accountFacts.availableResetCredits.map(String.init) ?? language.text("未知", "Unknown")
        var line = language.text("**可用 Reset 卡**：\(count) 次", "**Available resets**: \(count)")
        guard notification.messageOptions.resetExpiryDetail != .none,
            notification.accountFacts.availableResetCredits != 0
        else { return line }
        let upcoming = notification.accountFacts.resetCreditExpiries
            .filter { $0 >= notification.occurredAt }
        let available =
            notification.accountFacts.availableResetCredits
            .map { Array(upcoming.prefix($0)) } ?? upcoming
        guard !available.isEmpty else { return line + language.text(" · 到期时间未知", " · expiry unknown") }
        let dates = notification.messageOptions.resetExpiryDetail == .nearest ? Array(available.prefix(1)) : available
        let formatted = dates.map { compactDate($0, language: language, timeZone: timeZone) }.joined(separator: language.text("、", ", "))
        line += language.text(" · 到期 \(formatted)", " · expires \(formatted)")
        return line
    }

    private static func compactDate(_ date: Date?, language: WidgetLanguage, timeZone: TimeZone) -> String {
        guard let date else { return language.text("未知", "Unknown") }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = timeZone
        formatter.dateFormat = language == .zh ? "M月d日 HH:mm" : "M/d HH:mm"
        return formatter.string(from: date)
    }

    private static func lowQuotaTrigger(for notification: FeishuSwitchNotification, language: WidgetLanguage) -> String {
        var reasons: [String] = []
        if let value = notification.fiveHourRemainingPercent, value <= Double(notification.fiveHourTriggerThresholdPercent) {
            reasons.append(
                language.text(
                    "5 小时剩余 \(percentText(value))% ≤ \(notification.fiveHourTriggerThresholdPercent)%",
                    "5-hour remaining \(percentText(value))% ≤ \(notification.fiveHourTriggerThresholdPercent)%"))
        }
        if let value = notification.sevenDayRemainingPercent, value < Double(notification.triggerThresholdPercent) {
            reasons.append(
                language.text(
                    "7 天剩余 \(percentText(value))% < \(notification.triggerThresholdPercent)%", "7-day remaining \(percentText(value))% < \(notification.triggerThresholdPercent)%"))
        }
        return language.text("**触发原因**：", "**Trigger**: ")
            + (reasons.isEmpty ? language.text("未确认低额度条件", "Low-quota condition unverified") : reasons.joined(separator: "; "))
    }

    private static func presentation(for event: FeishuSwitchNotification.Event, origin: FeishuSwitchNotification.SwitchOrigin, language: WidgetLanguage) -> (
        title: String,
        result: String,
        template: String
    ) {
        switch event {
        case .test:
            return (
                language.text("🧪 Codex 飞书连接测试", "🧪 Codex Feishu connection test"),
                language.text("测试消息", "Test message"), "blue"
            )
        case .lowQuotaDetected:
            return (
                language.text("⚠️ Codex 低额度提醒", "⚠️ Codex low-quota alert"),
                language.text("额度低于已设阈值", "Quota is below the configured threshold"), "orange"
            )
        case .quotaChange(.quotaReset):
            return (
                language.text("🔄 Codex 官方额度窗口变化", "🔄 Codex official quota window changed"),
                language.text("观察到官方额度恢复或新窗口", "Official quota recovery or a new window was observed"),
                "turquoise"
            )
        case .quotaChange(.resetCreditsAdded):
            return (
                language.text("🎫 Codex 获得 Reset 卡", "🎫 Codex reset credit granted"),
                language.text("官方可用 Reset 次数增加", "Official available reset count increased"), "purple"
            )
        case .switchSucceeded:
            let title =
                origin == .restartTest
                ? language.text("🧪 Codex 测试重启完成", "🧪 Codex restart test complete")
                : origin == .lowQuota
                    ? language.text("🔀 Codex 账号自动切换成功", "🔀 Codex automatic account switch succeeded")
                    : language.text("🔀 Codex 桌面账号手动切换成功", "🔀 Codex Desktop account switch succeeded")
            return (title, language.text("账号切换成功", "Account switch successful"), "blue")
        case .switchFailed(let reason):
            let title =
                origin == .restartTest
                ? language.text("⛔️ Codex 测试重启未完成", "⛔️ Codex restart test incomplete")
                : origin == .lowQuota
                    ? language.text("⛔️ Codex 自动切换未完成", "⛔️ Codex automatic switch incomplete")
                    : language.text("⛔️ Codex 手动切换未完成", "⛔️ Codex manual switch incomplete")
            return (title, reason.displayName(language), "red")
        }
    }

}

private final class FeishuWebhookTestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":0}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum FeishuWebhookServiceSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        if !PublicResetAnnouncementSelfTest.run() { failures.append("public reset announcement policy failed") }
        if !CodexQuotaEventTrackerSelfTest.run() { failures.append("quota event policy failed") }
        if !FeishuTaskCompletionSelfTest.run() { failures.append("task completion policy failed") }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func markdown(_ data: Data) -> String {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let card = root["card"] as? [String: Any],
                let body = card["body"] as? [String: Any],
                let elements = body["elements"] as? [[String: Any]],
                let content = elements.first?["content"] as? String
            else { return "" }
            return content
        }
        func cardHeader(_ data: Data) -> (title: String, template: String) {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let card = root["card"] as? [String: Any],
                let header = card["header"] as? [String: Any],
                let title = header["title"] as? [String: Any],
                let content = title["content"] as? String,
                let template = header["template"] as? String
            else { return ("", "") }
            return (content, template)
        }

        let valid = [
            "https://open.feishu.cn/open-apis/bot/v2/hook/12345678-1234-1234-1234-123456789abc",
            "https://open.larksuite.com/open-apis/bot/v2/hook/abcdefghijklmnop",
        ]
        valid.forEach {
            expect((try? FeishuWebhookService.validatedWebhookURL(from: $0)) != nil, "valid endpoint rejected")
        }

        let invalid = [
            "http://open.feishu.cn/open-apis/bot/v2/hook/1234567890abcdef",
            "https://open.feishu.cn.evil.example/open-apis/bot/v2/hook/1234567890abcdef",
            "https://open.feishu.cn/open-apis/bot/v2/hook/1234567890abcdef?copy=1",
            "https://open.feishu.cn/open-apis/bot/v2/hook/short",
            "https://user@open.feishu.cn/open-apis/bot/v2/hook/1234567890abcdef",
            "https://open.feishu.cn/open-apis/bot/v2/hook/1234567890abcdef/extra",
        ]
        invalid.forEach {
            expect((try? FeishuWebhookService.validatedWebhookURL(from: $0)) == nil, "unsafe endpoint accepted")
        }

        expect((try? FeishuMaskedAccount("person@example.com")) == nil, "raw account accepted")
        do {
            let source = try FeishuMaskedAccount("p***-source")
            let target = try FeishuMaskedAccount("n***-target")
            let notification = try FeishuSwitchNotification(
                event: .switchSucceeded,
                sourceAccount: source,
                targetAccount: target,
                triggerThresholdPercent: 10,
                fiveHourRemainingPercent: 8,
                sevenDayRemainingPercent: 62,
                occurredAt: Date(timeIntervalSince1970: 0),
                eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            )
            let payload = try FeishuWebhookService.payloadData(for: notification, language: .zh)
            let text = String(data: payload, encoding: .utf8) ?? ""
            let switchHeader = cardHeader(payload)
            expect(text.contains("\"msg_type\":\"interactive\""), "interactive payload missing")
            expect(text.contains("p***-source"), "masked source missing")
            expect(
                switchHeader.title == "🔀 Codex 桌面账号手动切换成功" && switchHeader.template == "blue",
                "account-switch card is not visually distinct")
            expect(markdown(payload).contains("**切换路径**：p***-source → n***-target"), "account-switch path is not prominent")
            expect(!text.contains("person@example.com"), "raw account leaked")
            expect(!text.contains(notification.eventID.uuidString), "internal event ID rendered")
            expect((try? FeishuMaskedAccount("person@example.com***")) == nil, "email-like label accepted")
            let customThresholds = try FeishuSwitchNotification(
                event: .lowQuotaDetected, sourceAccount: source,
                triggerThresholdPercent: 15, fiveHourTriggerThresholdPercent: 20,
                fiveHourRemainingPercent: 18, sevenDayRemainingPercent: 70
            )
            let customPayload = try FeishuWebhookService.payloadData(for: customThresholds, language: .en)
            let customText = String(data: customPayload, encoding: .utf8) ?? ""
            let lowHeader = cardHeader(customPayload)
            expect(customText.contains("5-hour remaining 18% ≤ 20%") && !customText.contains("7-day remaining 70% < 15%"), "notification must show only the threshold actually met")
            expect(
                lowHeader.title == "⚠️ Codex low-quota alert" && lowHeader.template == "orange",
                "low-quota card is not visually distinct")

            let testNotification = try FeishuSwitchNotification(
                event: .test,
                sourceAccount: source,
                triggerThresholdPercent: 10,
                fiveHourRemainingPercent: nil,
                sevenDayRemainingPercent: nil,
                occurredAt: Date(timeIntervalSince1970: 0),
                eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            )
            let testPayload = try FeishuWebhookService.payloadData(for: testNotification, language: .zh)
            expect(
                String(data: testPayload, encoding: .utf8)?.contains("Codex 飞书连接测试") == true,
                "test notification mislabeled"
            )
            let testText = String(data: testPayload, encoding: .utf8) ?? ""
            expect(!testText.contains("触发规则") && !testText.contains("≤") && !testText.contains("自动切换"), "connection test must not claim a quota trigger or automatic switch")
            let named = try FeishuMaskedAccount(displayName: "evan", dispatchCode: "A")
            let unassigned = try FeishuMaskedAccount(displayName: "pro20x")
            let emoji = try FeishuMaskedAccount(displayName: "👨‍🍳", dispatchCode: "F")
            expect(named.value == "evan", "dispatch code leaked into outbound account label")
            expect(unassigned.value == "pro20x", "unassigned display name must remain readable")
            expect(emoji.value == "👨‍🍳", "emoji labels must remain readable without dispatch code")
            for invalid in ["person@example.com", "/private/account", "[click](https://example.invalid)", "line\nline"] {
                expect((try? FeishuMaskedAccount(displayName: invalid, dispatchCode: "A")) == nil, "unsafe display name accepted")
            }
            for origin in [FeishuSwitchNotification.SwitchOrigin.manual, .restartTest] {
                let manual = try FeishuSwitchNotification(
                    event: .switchSucceeded, sourceAccount: named, targetAccount: target, switchOrigin: origin,
                    triggerThresholdPercent: 10, fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 80
                )
                let body = String(data: try FeishuWebhookService.payloadData(for: manual, language: .zh), encoding: .utf8) ?? ""
                expect(
                    body.contains(origin == .manual ? "手动切换" : "测试重启") && !body.contains("自动切换") && !body.contains("≤"),
                    "explicit manual and restart test causes must not become quota triggers")
            }
            let shanghai = TimeZone(identifier: "Asia/Shanghai")!
            let firstExpiry = Date(timeIntervalSince1970: 172_800)
            let secondExpiry = Date(timeIntervalSince1970: 259_200)
            let facts = try FeishuAccountFacts(
                fiveHour: .unlimited,
                sevenDay: .finite(remainingPercent: 64, resetsAt: firstExpiry),
                availableResetCredits: 2,
                resetCreditExpiries: [secondExpiry, firstExpiry]
            )
            let compact = try FeishuSwitchNotification(
                event: .test, sourceAccount: unassigned,
                triggerThresholdPercent: 10, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: 64,
                accountFacts: facts, occurredAt: Date(timeIntervalSince1970: 0),
                eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
            )
            let compactText = markdown(try FeishuWebhookService.payloadData(for: compact, language: .zh, timeZone: shanghai))
            expect(compactText.contains("**账号**：pro20x"), "default account label missing")
            expect(compactText.contains("**5 小时**：∞"), "confirmed unlimited 5-hour value missing")
            expect(compactText.contains("1月3日 08:00") && !compactText.contains("1月4日 08:00"), "default expiry must show nearest upcoming value only")
            expect(!compactText.contains("事件 ID") && !compactText.contains("00000000-0000"), "compact card exposed audit UUID")
            expect(!compactText.contains("**Agent**"), "agent name must be optional and off by default")

            let expiryNow = Date(timeIntervalSince1970: 200_000)
            let expiryFacts = try FeishuAccountFacts(
                fiveHour: .unknown,
                sevenDay: .unknown,
                availableResetCredits: 1,
                resetCreditExpiries: [
                    expiryNow.addingTimeInterval(-60),
                    expiryNow.addingTimeInterval(3_600),
                    expiryNow.addingTimeInterval(7_200),
                ]
            )
            let expiryNotification = try FeishuSwitchNotification(
                event: .test, sourceAccount: unassigned,
                triggerThresholdPercent: 10, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: nil,
                accountFacts: expiryFacts, occurredAt: expiryNow
            )
            let expiryText = markdown(
                try FeishuWebhookService.payloadData(for: expiryNotification, language: .en, timeZone: shanghai)
            )
            expect(
                expiryText.contains("1/3 16:33") && !expiryText.contains("1/3 17:33"),
                "expired detail hid the nearest available expiry"
            )
            let zeroFacts = try FeishuAccountFacts(
                fiveHour: .unknown,
                sevenDay: .unknown,
                availableResetCredits: 0,
                resetCreditExpiries: []
            )
            let zeroNotification = try FeishuSwitchNotification(
                event: .test, sourceAccount: unassigned,
                triggerThresholdPercent: 10, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: nil,
                accountFacts: zeroFacts, occurredAt: expiryNow
            )
            let zeroText = markdown(
                try FeishuWebhookService.payloadData(for: zeroNotification, language: .en, timeZone: shanghai)
            )
            expect(
                zeroText.contains("**Available resets**: 0") && !zeroText.contains("expiry unknown"),
                "zero available resets appended an irrelevant unknown expiry"
            )

            var allOptions = FeishuMessageOptions.standard
            allOptions.includesAgentName = true
            allOptions.includesAccountLabel = false
            allOptions.includesQuotas = false
            allOptions.includesResetTimes = false
            allOptions.resetExpiryDetail = .all
            let persistedOptions = try JSONDecoder().decode(
                FeishuMessageOptions.self,
                from: JSONEncoder().encode(allOptions)
            )
            expect(persistedOptions == allOptions, "message options did not persist losslessly")
            let filtered = try FeishuSwitchNotification(
                event: .test, sourceAccount: unassigned,
                triggerThresholdPercent: 10, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: 64,
                accountFacts: facts, messageOptions: allOptions, occurredAt: Date(timeIntervalSince1970: 0)
            )
            let filteredText = markdown(try FeishuWebhookService.payloadData(for: filtered, language: .en, timeZone: shanghai))
            expect(filteredText.contains("**Agent**: Codex"), "enabled agent field missing")
            expect(!filteredText.contains("pro20x") && !filteredText.contains("**5h**") && !filteredText.contains("**7d**"), "disabled fields rendered")
            expect(filteredText.contains("1/3 08:00") && filteredText.contains("1/4 08:00"), "all expiry details were not rendered")

            let finitePro = FeishuQuotaValue.generalFiveHour(
                window: RateWindow(usedPercent: 37, windowDurationMins: 300, resetsAt: nil), confirmedPlan: "pro"
            )
            expect(finitePro == .finite(remainingPercent: 63, resetsAt: nil), "finite Pro 5-hour window was overwritten")
            expect(FeishuQuotaValue.generalFiveHour(window: nil, confirmedPlan: "PRO") == .unknown, "missing Pro 5-hour window was not unknown")
            expect(FeishuQuotaValue.generalFiveHour(window: nil, confirmedPlan: nil) == .unknown, "missing plan and 5-hour window was not unknown")
            expect(FeishuQuotaValue.generalFiveHour(window: nil, confirmedPlan: " \tpro\n") == .unknown, "missing whitespace-padded Pro 5-hour window was not unknown")
            expect(FeishuQuotaValue.generalFiveHour(window: nil, confirmedPlan: "plus") == .unknown, "missing non-Pro 5-hour window was not unknown")
            for invalidPercent in [Double.nan, Double.infinity, -0.1, 100.1] {
                expect(
                    (try? FeishuAccountFacts.quotasOnly(
                        fiveHourRemaining: invalidPercent,
                        sevenDayRemaining: nil
                    )) == nil,
                    "invalid quota percentage was clamped into a valid outbound fact"
                )
            }
            expect(CreditBalancePresentation(credits: nil).value == .unavailable, "missing balance became zero")
            expect(
                CreditBalancePresentation(
                    credits: CreditsInfo(hasCredits: true, unlimited: false, balance: "0", resetCredits: nil, resetCreditDetails: nil)
                ).value == .reported("0"), "zero balance became unavailable"
            )
            expect(
                CreditBalancePresentation(
                    credits: CreditsInfo(hasCredits: true, unlimited: false, balance: "USD 5", resetCredits: nil, resetCreditDetails: nil)
                ).value == .unavailable, "unspecified balance text was labeled as currency"
            )
            expect(
                CreditBalancePresentation(
                    balance: "1,234.50", unlimited: false
                ).value == .reported("1,234.50"), "valid decimal balance was rejected"
            )
            expect(
                CreditBalancePresentation(
                    balance: "1,2.3.4", unlimited: false
                ).value == .unavailable, "malformed decimal balance was accepted"
            )
            expect(
                (try? FeishuSwitchNotification(
                    event: .lowQuotaDetected, sourceAccount: named,
                    triggerThresholdPercent: 10, fiveHourRemainingPercent: 5.4, sevenDayRemainingPercent: 10
                )) == nil, "rounded quota must not falsely meet the low-quota threshold")
            failures += credentialIsolationTests(notification: testNotification, endpoint: valid[0])
            failures += credentialAuthorizationTests(notification: testNotification, endpoint: valid[0])
            for change in [
                CodexQuotaEvent.quotaReset(fiveHour: true, sevenDay: true),
                .resetCreditsAdded(added: 2, available: 3),
            ] {
                let event = try FeishuSwitchNotification(
                    event: .quotaChange(change), sourceAccount: source,
                    triggerThresholdPercent: 10, fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 80
                )
                let eventPayload = try FeishuWebhookService.payloadData(for: event, language: .zh)
                let body = markdown(eventPayload)
                let eventHeader = cardHeader(eventPayload)
                expect(body.contains("p***-source"), "quota event missing masked account")
                expect(!body.contains("触发规则"), "quota event inherited low-quota rule")
                expect(!body.contains("目标账号"), "quota event suggests switching")
                let english = markdown(try FeishuWebhookService.payloadData(for: event, language: .en))
                expect(english.range(of: "\\p{Han}", options: .regularExpression) == nil, "English notification must not contain Chinese app copy")
                expect(english.contains("p***-source") && !english.contains("person@example.com"), "English notification must preserve masking")
                switch change {
                case .quotaReset:
                    expect(body.contains("5 小时") && body.contains("7 天"), "reset quotas missing")
                    expect(
                        eventHeader.title == "🔄 Codex 官方额度窗口变化" && eventHeader.template == "turquoise",
                        "official quota-window card is not visually distinct")
                    expect(
                        body.contains("仅报告官方额度窗口变化") && body.contains("另行核对"),
                        "official window observation must not claim reset-credit facts")
                    expect(!body.contains("未获得或使用 Reset 卡"), "stale over-claiming window copy survived")
                case .resetCreditsAdded:
                    expect(body.contains("新增 2 次") && body.contains("可用 3 次"), "official credit count missing")
                    expect(
                        eventHeader.title == "🎫 Codex 获得 Reset 卡" && eventHeader.template == "purple",
                        "reset-credit card is not visually distinct")
                    expect(body.contains("获得 Reset 卡 / 重置机会"), "reset-credit grant is not explicit")
                }
            }
            for invalidChange in [
                CodexQuotaEvent.quotaReset(fiveHour: false, sevenDay: false),
                .resetCreditsAdded(added: 0, available: 1),
                .resetCreditsAdded(added: 3, available: 2),
            ] {
                expect(
                    (try? FeishuSwitchNotification(
                        event: .quotaChange(invalidChange), sourceAccount: source,
                        triggerThresholdPercent: 10, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: nil
                    )) == nil, "invalid quota event accepted")
            }
        } catch {
            failures.append("payload construction failed")
        }

        expect(FeishuWebhookService.parseResponse(Data(#"{"code":0,"msg":"success"}"#.utf8)).isSuccess, "code=0 rejected")
        expect(FeishuWebhookService.parseResponse(Data(#"{"StatusCode":0,"StatusMessage":"success"}"#.utf8)).isSuccess, "StatusCode=0 rejected")
        expect(!FeishuWebhookService.parseResponse(Data(#"{"code":19024}"#.utf8)).isSuccess, "failure code accepted")
        expect(!FeishuWebhookService.parseResponse(Data(#"{"code":false}"#.utf8)).isSuccess, "boolean code accepted")
        expect(!FeishuWebhookService.parseResponse(Data(#"{"code":0.5}"#.utf8)).isSuccess, "fractional code accepted")
        expect(!FeishuWebhookService.parseResponse(Data(#"{"msg":"success"}"#.utf8)).isSuccess, "missing code accepted")

        if failures.isEmpty {
            print("Feishu webhook self-test passed")
            return true
        }
        failures.forEach { print("Feishu webhook self-test failed: \($0)") }
        return false
    }

    private static func credentialIsolationTests(notification: FeishuSwitchNotification, endpoint: String) -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func waitUntil(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeishuWebhookTestProtocol.self]
        let requestsBefore = FeishuWebhookTestProtocol.requestCount
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        let readLock = NSLock()
        var readCount = 0
        var readOnMain = false
        let service = FeishuWebhookService(
            keychainReadTimeout: 0.15, maximumPendingReads: 2,
            sessionConfiguration: configuration,
            keychainInteraction: FeishuKeychainInteraction(getAllowed: { true }, setAllowed: { _ in }),
            copyMatching: { _, result in
                readLock.lock()
                readCount += 1
                readOnMain = readOnMain || Thread.isMainThread
                readLock.unlock()
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                result?.pointee = Data(endpoint.utf8) as CFData
                exited.signal()
                return errSecSuccess
            }
        )
        var sendResults: [Result<Void, FeishuWebhookError>] = []
        var probeResults: [Result<Bool, FeishuWebhookError>] = []
        service.send(notification) { sendResults.append($0) }
        expect(entered.wait(timeout: .now() + 1) == .success, "credential read did not begin in background")
        readLock.lock()
        let initialReadOnMain = readOnMain
        readLock.unlock()
        expect(!initialReadOnMain, "credential read blocked main thread")
        service.hasStoredWebhook { probeResults.append($0) }
        service.hasStoredWebhook { probeResults.append($0) }
        var mainThreadProgressed = false
        DispatchQueue.main.async { mainThreadProgressed = true }
        waitUntil { sendResults.count == 1 && probeResults.count == 2 && mainThreadProgressed }
        expect(mainThreadProgressed, "main queue stalled behind credential read")
        expect(sendResults.count == 1, "blocked send did not complete once")
        expect(probeResults.count == 2, "queued probes did not finish")
        expect(
            sendResults.contains {
                if case .failure(.keychainTimedOut) = $0 { return true }
                return false
            }, "blocked send did not time out")
        expect(
            probeResults.contains {
                if case .failure(.keychainTimedOut) = $0 { return true }
                return false
            }, "queued probe did not time out")
        expect(
            probeResults.contains {
                if case .failure(.keychainBusy) = $0 { return true }
                return false
            }, "pending reads were not bounded")
        release.signal()
        expect(exited.wait(timeout: .now() + 1) == .success, "mock credential read did not exit")
        service.keychainQueue.sync {}
        var recoveredResults: [Result<Bool, FeishuWebhookError>] = []
        // The timed-out queued probe must be discarded before another Security call.
        service.hasStoredWebhook { recoveredResults.append($0) }
        release.signal()
        waitUntil { !recoveredResults.isEmpty }
        expect(
            recoveredResults.contains {
                if case .success(true) = $0 { return true }
                return false
            }, "credential probe did not recover")
        readLock.lock()
        let completedReadCount = readCount
        readLock.unlock()
        expect(completedReadCount == 2, "expired queued probe accessed Keychain")
        expect(sendResults.count == 1 && probeResults.count == 2, "late credential result completed twice")
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore, "timed-out send issued a late request")

        let successService = FeishuWebhookService(
            sessionConfiguration: configuration,
            keychainInteraction: FeishuKeychainInteraction(getAllowed: { true }, setAllowed: { _ in })
        ) { _, result in
            result?.pointee = Data(endpoint.utf8) as CFData
            return errSecSuccess
        }
        var successfulSend: Result<Void, FeishuWebhookError>?
        successService.send(notification) { result in
            DispatchQueue.main.async { successfulSend = result }
        }
        waitUntil { successfulSend != nil }
        expect(successfulSend?.isSuccess == true, "background credential read broke valid sends")
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore + 1, "valid send did not use isolated transport")
        var cancelledSend: Result<Void, FeishuWebhookError>?
        successService.send(notification, shouldSend: { false }, completion: { cancelledSend = $0 })
        waitUntil { cancelledSend != nil }
        if case .failure(.cancelled)? = cancelledSend {} else { failures.append("send did not recheck opt-in after credential read") }
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore + 1, "cancelled send issued a request")
        withExtendedLifetime((service, successService)) {}
        return failures
    }

    private static func credentialAuthorizationTests(notification: FeishuSwitchNotification, endpoint: String) -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func waitUntil(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        var allowed = true
        var authorized = false
        var policy: [Bool] = []
        var prompts = 0
        var readOnMain = false
        let interaction = FeishuKeychainInteraction(
            getAllowed: { allowed },
            setAllowed: {
                allowed = $0
                policy.append($0)
            })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeishuWebhookTestProtocol.self]
        let service = FeishuWebhookService(sessionConfiguration: configuration, keychainInteraction: interaction) { query, result in
            readOnMain = readOnMain || Thread.isMainThread
            guard (query as NSDictionary)[kSecReturnData as String] as? Bool == true else { return errSecParam }
            if !authorized {
                guard allowed else { return errSecInteractionNotAllowed }
                prompts += 1
                authorized = true
            }
            result?.pointee = Data(endpoint.utf8) as CFData
            return errSecSuccess
        }
        let requestsBefore = FeishuWebhookTestProtocol.requestCount
        var probe: Result<Bool, FeishuWebhookError>?
        service.hasStoredWebhook { probe = $0 }
        waitUntil { probe != nil }
        if case .failure(.keychainAuthorizationRequired)? = probe {} else { failures.append("silent probe hid authorization requirement") }
        var blocked: Result<Void, FeishuWebhookError>?
        service.send(notification) { blocked = $0 }
        waitUntil { blocked != nil }
        if case .failure(.keychainAuthorizationRequired)? = blocked {} else { failures.append("background send did not fail closed") }
        service.keychainQueue.sync {}
        expect(prompts == 0 && allowed, "background read requested UI or failed to restore policy")
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore, "unauthorized send reached transport")

        var authorization: Result<Void, FeishuWebhookError>?
        service.authorizeStoredWebhook { authorization = $0 }
        waitUntil { authorization != nil }
        service.keychainQueue.sync {}
        expect(authorization?.isSuccess == true && prompts == 1, "explicit authorization did not request access once")
        expect(!readOnMain, "authorization blocked the main thread")
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore, "authorization sent an unsolicited notification")
        var delivered: Result<Void, FeishuWebhookError>?
        service.send(notification) { result in DispatchQueue.main.async { delivered = result } }
        waitUntil { delivered != nil }
        service.keychainQueue.sync {}
        expect(delivered?.isSuccess == true && prompts == 1, "authorized background delivery requested another prompt")
        expect(policy == [false, true, false, true, true, true, false, true], "Keychain UI policy was not scoped to explicit actions")

        let cancelled = FeishuWebhookService(sessionConfiguration: configuration, keychainInteraction: interaction) { _, _ in errSecUserCanceled }
        var cancellation: Result<Void, FeishuWebhookError>?
        cancelled.authorizeStoredWebhook { cancellation = $0 }
        waitUntil { cancellation != nil }
        cancelled.keychainQueue.sync {}
        if case .failure(.keychainAuthorizationRequired)? = cancellation {} else { failures.append("cancelled authorization reported connected") }
        expect(allowed, "throwing Keychain operation left global interaction disabled")

        var reachedOperation = false
        let failingPolicy = FeishuKeychainInteraction(
            getAllowed: { true }, setAllowed: { _ in throw FeishuWebhookError.keychain(errSecNotAvailable) })
        do {
            try failingPolicy.perform(allowInteraction: false) { reachedOperation = true }
            failures.append("failed UI suppression was accepted")
        } catch {}
        expect(!reachedOperation, "credential read ran when UI suppression failed")

        var storedValue: Data?
        let failedReadback = FeishuWebhookService(
            sessionConfiguration: configuration, keychainInteraction: interaction,
            updateItem: { _, attributes in
                storedValue = (attributes as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            },
            copyMatching: { _, _ in errSecNotAvailable })
        var saveResult: Result<Void, FeishuWebhookError>?
        failedReadback.storeWebhook(endpoint) { saveResult = $0 }
        waitUntil { saveResult != nil }
        failedReadback.keychainQueue.sync {}
        expect(storedValue == Data(endpoint.utf8), "readback failure fixture did not save the new value")
        if case .failure(.keychain(errSecNotAvailable))? = saveResult {} else { failures.append("readback failure was not reported") }
        if let saveResult {
            expect(UsageStore.feishuConnectionCompletionSelfTest(saveResult), "failed connection retained stale readiness or cleared unrelated transport readiness")
        }
        return failures
    }
}

private extension Result where Success == Void, Failure == FeishuWebhookError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

enum FeishuTaskCompletionSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func cardHeader(_ data: Data) -> (title: String, template: String) {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let card = root["card"] as? [String: Any],
                let header = card["header"] as? [String: Any],
                let title = header["title"] as? [String: Any],
                let content = title["content"] as? String,
                let template = header["template"] as? String
            else { return ("", "") }
            return (content, template)
        }
        func markdown(_ data: Data) -> String {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let card = root["card"] as? [String: Any],
                let body = card["body"] as? [String: Any],
                let elements = body["elements"] as? [[String: Any]],
                let content = elements.first?["content"] as? String
            else { return "" }
            return content
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000d001")!

        do {
            let account = try FeishuMaskedAccount(displayName: "pro20x")
            let confirmed = try FeishuTaskCompletionNotification(
                eventID: id, proof: .confirmedByTaskObserver, category: .dispatchedAgent,
                attemptCount: 2, accountLabel: account, occurredAt: now.addingTimeInterval(-30), now: now)
            let payload = try FeishuWebhookService.taskCompletionPayload(confirmed, language: .zh, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
            let text = String(data: payload, encoding: .utf8) ?? ""
            expect(cardHeader(payload).title == "✅ Codex 任务完成" && cardHeader(payload).template == "green", "task-completion card is not green or mislabeled")
            expect(text.contains("任务已完成") && text.contains("CLI 派发任务"), "completion result and category missing")
            expect(text.contains("CLI 派发任务") && text.contains("**尝试次数**：2") && text.contains("pro20x"), "bounded fields missing")
            expect(text.contains("请打开原任务查看结果") && !text.contains("已验收"), "completion must direct users to the result without claiming acceptance")
            expect(!text.contains(id.uuidString) && !text.contains("事件 ID"), "internal event ID rendered")
            let kimi = try? FeishuTaskCompletionNotification(
                eventID: id, proof: .confirmedByTaskObserver, category: .kimiConversation,
                occurredAt: now.addingTimeInterval(-30), now: now)
            expect(kimi != nil, "kimi category rejected")
            let englishData = try FeishuWebhookService.taskCompletionPayload(confirmed, language: .en)
            let english = String(data: englishData, encoding: .utf8) ?? ""
            expect(english.range(of: "\\p{Han}", options: .regularExpression) == nil, "English task card must not contain Chinese copy")
            expect(english.contains("Open the original task to review the result.") && !english.contains("accepted"), "English result review guidance missing")

            for invalid in [
                try? FeishuTaskCompletionNotification(
                    eventID: id, proof: .confirmedByTaskObserver, category: .dispatchedAgent,
                    occurredAt: now.addingTimeInterval(120), now: now),
                try? FeishuTaskCompletionNotification(
                    eventID: id, proof: .confirmedByTaskObserver, category: .dispatchedAgent,
                    occurredAt: now.addingTimeInterval(-25 * 3600), now: now),
                try? FeishuTaskCompletionNotification(
                    eventID: id, proof: .confirmedByTaskObserver, category: .dispatchedAgent,
                    attemptCount: 0, occurredAt: now.addingTimeInterval(-30), now: now),
                try? FeishuTaskCompletionNotification(
                    eventID: id, proof: .confirmedByTaskObserver, category: .dispatchedAgent,
                    attemptCount: 65, occurredAt: now.addingTimeInterval(-30), now: now),
            ] {
                expect(invalid == nil, "invalid task-completion DTO accepted")
            }
            let rawEmailAccount: FeishuMaskedAccount?
            rawEmailAccount = try? FeishuMaskedAccount("person@example.com")
            expect(rawEmailAccount == nil, "raw email label accepted into task DTO")
        } catch {
            failures.append("task completion payload construction failed")
        }

        var gate = FeishuTaskCompletionGate(capacity: 2)
        func event(_ uuid: UUID) -> FeishuTaskCompletionNotification? {
            try? FeishuTaskCompletionNotification(
                eventID: uuid, proof: .confirmedByTaskObserver, category: .dispatchedAgent,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000), now: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let first = UUID(uuidString: "00000000-0000-0000-0000-00000000da01")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-00000000da02")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-00000000da03")!
        if let one = event(first), let two = event(second), let three = event(third) {
            expect(gate.admit(one), "first confirmed completion refused")
            expect(!gate.admit(one), "duplicate completion admitted")
            expect(gate.admit(two), "second completion refused")
            expect(gate.admit(three), "capacity bound evicted the wrong entry")
            expect(!gate.admit(two), "eviction did not drop the oldest entry")
            expect(gate.admit(one), "evicted entry could not be re-admitted as genuinely new")
        } else {
            failures.append("gate fixture construction failed")
        }

        failures += taskCompletionSendSelfTest(event: event(first))
        if failures.isEmpty {
            print("Feishu task completion self-test passed")
            return true
        }
        failures.forEach { print("Feishu task completion self-test failed: \($0)") }
        return false
    }

    /// Synthetic URLProtocol transport only: no real webhook, Keychain,
    /// account, or reset-credit flow is contacted.
    private static func taskCompletionSendSelfTest(event: FeishuTaskCompletionNotification?) -> [String] {
        var failures: [String] = []
        guard let completion = event else {
            return ["task completion send fixture failed"]
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func waitUntil(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        let endpoint = "https://open.feishu.cn/open-apis/bot/v2/hook/12345678-1234-1234-1234-123456789abc"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeishuWebhookTestProtocol.self]
        let requestsBefore = FeishuWebhookTestProtocol.requestCount
        let service = FeishuWebhookService(
            sessionConfiguration: configuration,
            keychainInteraction: FeishuKeychainInteraction(getAllowed: { true }, setAllowed: { _ in }),
            copyMatching: { _, result in
                result?.pointee = Data(endpoint.utf8) as CFData
                return errSecSuccess
            }
        )
        var delivered: Result<Void, FeishuWebhookError>?
        service.sendTaskCompletion(completion) { result in
            DispatchQueue.main.async { delivered = result }
        }
        waitUntil { delivered != nil }
        service.keychainQueue.sync {}
        expect(delivered?.isSuccess == true, "confirmed task completion send failed")
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore + 1, "task-completion send did not use the isolated transport")

        var cancelled: Result<Void, FeishuWebhookError>?
        service.sendTaskCompletion(completion, shouldSend: { false }, completion: { cancelled = $0 })
        waitUntil { cancelled != nil }
        service.keychainQueue.sync {}
        if case .failure(.cancelled)? = cancelled {} else { failures.append("task-completion send ignored the opt-in gate") }
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore + 1, "cancelled task-completion send issued a request")

        var refused = 0
        var gate = FeishuTaskCompletionGate(capacity: 8)
        for _ in 0..<3 where !gate.admit(completion) { refused += 1 }
        expect(refused == 2, "repeated completion events were not deduplicated before send")
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore + 1, "dedup gate must run before any transport use")
        withExtendedLifetime(service) {}
        return failures
    }
}
