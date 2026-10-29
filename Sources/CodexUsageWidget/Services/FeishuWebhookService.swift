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
            trimmed.unicodeScalars.allSatisfy { allowed.contains($0) },
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
            MessageNoticeFormat.reason(MessageTaskStatus.FailureReason(rawValue: rawValue) ?? .unknown, language: language)
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
    let resetCreditComparison: CodexResetCreditComparison?
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
        resetCreditComparison: CodexResetCreditComparison? = nil,
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
                if let statedBalance = accountFacts?.availableResetCredits, statedBalance != available {
                    throw FeishuWebhookError.invalidNotification
                }
            case .resetCreditsChanged(let previous, let available, let previousObservedAt, let observedAt):
                guard MessageNoticeFormat.validChange(previous: previous, available: available, previousObservedAt: previousObservedAt, observedAt: observedAt),
                    accountFacts?.availableResetCredits.map({ $0 == available }) ?? true
                else { throw FeishuWebhookError.invalidNotification }
            case .resetCreditsExpiring(let batches, let observedAt):
                guard MessageNoticeFormat.validExpiry(batches, observedAt: observedAt, enforcingThreshold: false) else { throw FeishuWebhookError.invalidNotification }
            }
        }
        if let resetCreditComparison {
            guard case .quotaChange(.quotaReset) = event,
                resetCreditComparison.isValid(at: occurredAt),
                accountFacts?.availableResetCredits == resetCreditComparison.available
            else { throw FeishuWebhookError.invalidNotification }
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
        self.resetCreditComparison = resetCreditComparison
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

/// UI-owned, bounded silent retries. This never authorizes or sends a message.
/// A generation fence also rejects work already dequeued when settings change.
final class MessageCredentialRetry {
    private var pending: DispatchWorkItem?
    private var generation = UUID()
    private var attempt = 0
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void

    init(
        schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.schedule = schedule
    }

    func cancel(resetDelay: Bool = true) {
        generation = UUID()
        pending?.cancel()
        pending = nil
        if resetDelay { attempt = 0 }
    }

    func retry(after error: FeishuWebhookError, _ operation: @escaping () -> Void) {
        switch error {
        case .keychainBusy, .keychainTimedOut, .keychainAuthorizationRequired: break
        case .keychain(let status) where status == errSecNotAvailable: break
        default:
            cancel()
            return
        }
        guard pending == nil else { return }
        let delays: [TimeInterval] = [2, 10, 30, 60]
        let delay = delays[attempt]
        attempt = min(attempt + 1, delays.count - 1)
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pending = nil
            operation()
        }
        pending = work
        schedule(delay, work)
    }

    deinit { pending?.cancel() }
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
    private let addItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let deleteItem: (CFDictionary) -> OSStatus
    private let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let credentialLock = NSLock()
    private var credentialGeneration: UInt64 = 0
    private var authorizedWebhook: URL?

    private struct Credential {
        let endpoint: URL
        let generation: UInt64
    }

    init(
        keychainReadTimeout: TimeInterval = 5,
        maximumPendingReads: Int = 16,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        keychainInteraction: FeishuKeychainInteraction = .system,
        updateItem: @escaping (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
        addItem: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd,
        deleteItem: @escaping (CFDictionary) -> OSStatus = SecItemDelete,
        copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    ) {
        precondition(keychainReadTimeout > 0 && maximumPendingReads > 0)
        self.keychainReadTimeout = keychainReadTimeout
        self.keychainInteraction = keychainInteraction
        self.updateItem = updateItem
        self.addItem = addItem
        self.deleteItem = deleteItem
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
            { generation in
                try self.storeWebhookSynchronously(rawValue, generation: generation)
                guard self.isCurrentCredential(generation) else { throw FeishuWebhookError.cancelled }
                let endpoint = try self.loadStoredWebhook()
                guard endpoint == (try Self.validatedWebhookURL(from: rawValue)) else { throw FeishuWebhookError.invalidWebhook }
                return endpoint
            }, completion: completion)
    }

    func authorizeStoredWebhook(completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
        performUserKeychainAction({ _ in try self.loadStoredWebhook() }, completion: completion)
    }

    func removeStoredWebhook(completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
        performUserKeychainAction(
            { _ in
                let status = self.deleteItem(Self.keychainQuery as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw FeishuWebhookError.credential(status)
                }
                return nil
            }, completion: completion)
    }

    /// Keep an explicitly approved endpoint only for this connection's lifetime.
    /// Disabling or replacing the connection also invalidates queued/late reads.
    func invalidateCredentialCache() {
        _ = beginCredentialGeneration()
    }

    private func beginCredentialGeneration() -> UInt64 {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        credentialGeneration &+= 1
        authorizedWebhook = nil
        return credentialGeneration
    }

    private func isCurrentCredential(_ generation: UInt64) -> Bool {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        return credentialGeneration == generation
    }

    /// Only explicit setup actions may request the native system password dialog.
    /// Keep the action pending until it returns so retries cannot stack dialogs.
    private func performUserKeychainAction(
        _ operation: @escaping (UInt64) throws -> URL?,
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        let generation = beginCredentialGeneration()
        keychainQueue.async {
            let result: Result<Void, FeishuWebhookError>
            do {
                guard self.isCurrentCredential(generation) else { throw FeishuWebhookError.cancelled }
                let endpoint = try self.keychainInteraction.perform(allowInteraction: true) {
                    // Another channel can hold the process-wide lock while this
                    // connection is disabled or replaced. Check after acquiring it.
                    guard self.isCurrentCredential(generation) else { throw FeishuWebhookError.cancelled }
                    return try operation(generation)
                }
                self.credentialLock.lock()
                let current = self.credentialGeneration == generation
                if current { self.authorizedWebhook = endpoint }
                self.credentialLock.unlock()
                guard current else { throw FeishuWebhookError.cancelled }
                result = .success(())
            } catch let error as FeishuWebhookError {
                result = .failure(error)
            } catch {
                result = .failure(.invalidWebhook)
            }
            DispatchQueue.main.async {
                completion(self.isCurrentCredential(generation) ? result : .failure(.cancelled))
            }
        }
    }

    private func storeWebhookSynchronously(_ rawValue: String, generation: UInt64) throws {
        let endpoint = try Self.validatedWebhookURL(from: rawValue)
        let data = Data(endpoint.absoluteString.utf8)
        let query = Self.keychainQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard isCurrentCredential(generation) else { throw FeishuWebhookError.cancelled }
        let updateStatus = updateItem(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw FeishuWebhookError.credential(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        guard isCurrentCredential(generation) else { throw FeishuWebhookError.cancelled }
        let addStatus = addItem(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw FeishuWebhookError.credential(addStatus)
        }
    }

    func hasStoredWebhook(completion: @escaping (Result<Bool, FeishuWebhookError>) -> Void) {
        readCredential { result in
            switch result {
            case .success: completion(.success(true))
            case .failure(.missingWebhook): completion(.success(false))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    func send(
        _ notification: FeishuSwitchNotification,
        shouldSend: @escaping () -> Bool = { true },
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        readCredential(completion: { result in
            guard shouldSend() else {
                completion(.failure(.cancelled))
                return
            }
            switch result {
            case .success(let credential):
                self.send(notification, to: credential.endpoint, credentialGeneration: credential.generation, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    private func readCredential(
        completion: @escaping (Result<Credential, FeishuWebhookError>) -> Void
    ) {
        credentialLock.lock()
        let generation = credentialGeneration
        let cached = authorizedWebhook
        credentialLock.unlock()
        // An already authorized endpoint must not queue behind another channel's
        // system dialog. Invalidation still fences the asynchronous completion.
        if let cached {
            DispatchQueue.main.async {
                completion(
                    self.isCurrentCredential(generation)
                        ? .success(Credential(endpoint: cached, generation: generation)) : .failure(.cancelled))
            }
            return
        }
        guard keychainCapacity.wait(timeout: .now()) == .success else {
            DispatchQueue.main.async {
                completion(.failure(self.isCurrentCredential(generation) ? .keychainBusy : .cancelled))
            }
            return
        }
        let read = FeishuKeychainRead<Credential>(timeout: keychainReadTimeout) { result in
            completion(self.isCurrentCredential(generation) ? result : .failure(.cancelled))
        }
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
                self.credentialLock.lock()
                let current = self.credentialGeneration == generation
                let cached = self.authorizedWebhook
                self.credentialLock.unlock()
                guard current else { throw FeishuWebhookError.cancelled }
                let endpoint =
                    try cached
                    ?? self.keychainInteraction.perform(allowInteraction: false) {
                        guard self.isCurrentCredential(generation) else { throw FeishuWebhookError.cancelled }
                        return try self.loadStoredWebhook()
                    }
                guard !read.isFinished else { return }
                self.credentialLock.lock()
                let stillCurrent = self.credentialGeneration == generation
                if stillCurrent { self.authorizedWebhook = endpoint }
                self.credentialLock.unlock()
                guard stillCurrent else { throw FeishuWebhookError.cancelled }
                read.finish(.success(Credential(endpoint: endpoint, generation: generation)))
            } catch let error as FeishuWebhookError {
                read.finish(.failure(error))
            } catch {
                read.finish(.failure(.invalidWebhook))
            }
        }
    }

    func sendManualReset(
        _ confirmation: CodexManualResetNotice, sourceAccount: FeishuMaskedAccount,
        messageOptions: FeishuMessageOptions, shouldSend: @escaping @MainActor () -> Bool,
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        let body: Data
        do { body = try Self.manualResetPayload(confirmation, sourceAccount: sourceAccount, messageOptions: messageOptions) } catch {
            completion(.failure(.invalidNotification))
            return
        }
        readCredential(completion: { result in
            Task { @MainActor in
                guard shouldSend() else {
                    completion(.failure(.cancelled))
                    return
                }
                switch result {
                case .success(let credential):
                    self.send(
                        body: body, to: credential.endpoint, credentialGeneration: credential.generation,
                        admission: shouldSend, completion: completion)
                case .failure(let error): completion(.failure(error))
                }
            }
        })
    }

    static func manualResetPayload(
        _ confirmation: CodexManualResetNotice, sourceAccount: FeishuMaskedAccount,
        messageOptions: FeishuMessageOptions = .standard, language: WidgetLanguage = .storedOrAutomatic()
    ) throws -> Data {
        guard confirmation.isValid else { throw FeishuWebhookError.invalidNotification }
        var lines = [
            language.text("**操作**：手动使用 1 张重置卡", "**Action**: Manually used 1 reset card"),
            language.text("**结果**：官方已确认重置成功", "**Result**: Official service confirmed the reset succeeded"),
        ]
        if messageOptions.includesAgentName { lines.append("**Agent**: Codex") }
        if messageOptions.includesAccountLabel {
            lines.append(language.text("**账号**：", "**Account**: ") + escapedLabel(sourceAccount.value))
        }
        lines.append(language.text("**确认时间**：", "**Confirmed**: ") + MessageNoticeFormat.fullDate(confirmation.confirmedAt))
        return try resetCardData(
            title: language.text("重置卡 · 手动使用成功", "Reset card · Manual use succeeded"),
            template: "green", sections: [lines.joined(separator: "\n")])
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
        readCredential(completion: { result in
            guard shouldSend() else {
                completion(.failure(.cancelled))
                return
            }
            switch result {
            case .success(let credential): self.send(body: body, to: credential.endpoint, credentialGeneration: credential.generation, completion: completion)
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
        readCredential(completion: { result in
            guard shouldSend() else {
                completion(.failure(.cancelled))
                return
            }
            switch result {
            case .success(let credential): self.send(body: body, to: credential.endpoint, credentialGeneration: credential.generation, completion: completion)
            case .failure(let error): completion(.failure(error))
            }
        })
    }

    static func publicResetPayload(
        _ announcement: PublicResetAnnouncement,
        language: WidgetLanguage = .storedOrAutomatic()
    ) throws -> Data {
        guard announcement.hasSourceText,
            let context = try? PublicResetContext(announcement: announcement), !context.publicText.isEmpty
        else { throw FeishuWebhookError.invalidNotification }
        let content = publicResetNoticeContent(context: context, language: language)
        return try resetCardData(title: content.title, template: content.template, sections: [content.lines.joined(separator: content.separator)])
    }

    static func publicResetNoticeContent(
        context: PublicResetContext, language: WidgetLanguage
    ) -> MessageNoticeFormat.Content {
        MessageNoticeFormat.Content(
            title: language.text(
                context.kind == .regular ? "公开重置公告 · 常规额度" : "公开重置公告 · 重置卡",
                context.kind == .regular ? "Public reset announcement · quota" : "Public reset announcement · reset credits"),
            template: context.kind == .banked ? "purple" : "turquoise",
            lines: [
                context.publicText,
                language.text("**公告时间（北京时间）**：", "**Announced (Beijing time, UTC+8)**: ")
                    + MessageNoticeFormat.fullDate(context.announcedAt),
                language.text("个人额度与重置卡以账号页官方读取为准。", "Check the official account read for your quota and reset credits."),
            ], separator: "\n\n")
    }

    static func publicResetForecastPayload(
        _ forecast: PublicResetForecastNotification,
        language: WidgetLanguage = .storedOrAutomatic()
    ) throws -> Data {
        guard forecast.isValid(now: Date()) else { throw FeishuWebhookError.invalidNotification }
        var lines: [String] = []
        if let latestBy = forecast.latestBy {
            lines.append(
                language.text("**预告时间（北京时间）**：", "**Forecast time (Beijing time, UTC+8)**: ")
                    + MessageNoticeFormat.fullDate(latestBy))
        } else {
            lines.append(language.text("**预告时间**：尚未确定", "**Forecast time**: Not yet specified"))
        }
        return try resetCardData(
            title: language.text("Codex 重置预告", "Codex reset forecast"), template: "orange",
            sections: [
                lines.joined(separator: "\n"),
                language.text(
                    "尚未确认重置完成；个人额度与重置卡以账号页官方读取为准。",
                    "Reset completion has not been confirmed. Check the official account read for your quota and reset credits."
                ),
                language.text("**预告发布于（北京时间）**：", "**Forecast published (Beijing time, UTC+8)**: ")
                    + MessageNoticeFormat.fullDate(forecast.announcedAt),
            ])
    }

    private static let messageSourceLine = MessageNoticeFormat.weChatFooter

    private static func resetCardData(title: String, template: String, sections: [String]) throws -> Data {
        var elements: [[String: Any]] = []
        for section in sections where !section.isEmpty {
            if !elements.isEmpty { elements.append(["tag": "hr"]) }
            elements.append(["tag": "markdown", "content": section])
        }
        elements.append(["tag": "markdown", "content": messageSourceLine])
        return try JSONSerialization.data(
            withJSONObject: [
                "msg_type": "interactive",
                "card": [
                    "schema": "2.0",
                    "config": ["wide_screen_mode": true],
                    "header": ["template": template, "title": ["tag": "plain_text", "content": title]],
                    "body": ["elements": elements],
                ],
            ], options: [.sortedKeys])
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
        readCredential(completion: { result in
            guard shouldSend() else {
                completion(.failure(.cancelled))
                return
            }
            switch result {
            case .success(let credential): self.send(body: body, to: credential.endpoint, credentialGeneration: credential.generation, completion: completion)
            case .failure(let error): completion(.failure(error))
            }
        })
    }

    static func taskCompletionPayload(
        _ completion: FeishuTaskCompletionNotification,
        language: WidgetLanguage = .storedOrAutomatic(),
        timeZone: TimeZone = MessageNoticeFormat.beijingTimeZone
    ) throws -> Data {
        guard completion.proof == .confirmedByTaskObserver else {
            throw FeishuWebhookError.invalidNotification
        }
        var lines = [
            language.text("**结果**：运行结束", "**Result**: Run ended")
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
                    "title": ["tag": "plain_text", "content": language.text("Codex 运行结束", "Codex run ended")],
                    "template": "green",
                ],
                "body": [
                    "elements": [
                        [
                            "tag": "markdown",
                            "content": lines.joined(separator: "\n") + "\n\n" + messageSourceLine,
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
        credentialGeneration: UInt64,
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

        send(body: body, to: endpoint, credentialGeneration: credentialGeneration, completion: completion)
    }

    private func send(
        body: Data, to endpoint: URL,
        credentialGeneration: UInt64,
        admission: (@MainActor () -> Bool)? = nil,
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

        Task { @MainActor [request] in
            // Recheck after task scheduling and before the first possible POST.
            guard admission?() != false, self.isCurrentCredential(credentialGeneration) else {
                completion(.failure(.cancelled))
                return
            }
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
            token.unicodeScalars.allSatisfy { tokenCharacters.contains($0) },
            let endpoint = components.url
        else {
            throw FeishuWebhookError.invalidWebhook
        }
        return endpoint
    }

    static func payloadData(
        for notification: FeishuSwitchNotification,
        language: WidgetLanguage = .storedOrAutomatic(),
        timeZone: TimeZone = MessageNoticeFormat.beijingTimeZone
    ) throws -> Data {
        if case .quotaChange(.resetCreditsExpiring(let batches, _)) = notification.event,
            !MessageNoticeFormat.validExpiry(batches, observedAt: Date())
        {
            throw FeishuWebhookError.invalidNotification
        }
        let content = noticeContent(for: notification, language: language)
        return try resetCardData(title: content.title, template: content.template, sections: [content.lines.joined(separator: content.separator)])
    }

    /// Both channel adapters reach this builder after their existing DTO
    /// validation. The wrappers differ only in card versus text presentation.
    static func noticeContent(
        for notification: FeishuSwitchNotification, language: WidgetLanguage
    ) -> MessageNoticeFormat.Content {
        noticeContent(
            NoticeInput(
                event: notification.event, sourceAccount: notification.sourceAccount.value,
                targetAccount: notification.targetAccount?.value, switchOrigin: notification.switchOrigin,
                triggerThresholdPercent: notification.triggerThresholdPercent,
                fiveHourTriggerThresholdPercent: notification.fiveHourTriggerThresholdPercent,
                fiveHourRemainingPercent: notification.fiveHourRemainingPercent,
                sevenDayRemainingPercent: notification.sevenDayRemainingPercent,
                accountFacts: notification.accountFacts, resetCreditComparison: notification.resetCreditComparison,
                messageOptions: notification.messageOptions, occurredAt: notification.occurredAt), language: language)
    }

    static func noticeContent(
        for status: MessageTaskStatus, options: FeishuMessageOptions, language: WidgetLanguage
    ) -> MessageNoticeFormat.Content? {
        if let context = status.publicResetContext {
            return publicResetNoticeContent(context: context, language: language)
        }
        let event: FeishuSwitchNotification.Event
        switch status.eventKind {
        case .test: event = .test
        case .lowQuotaDetected: event = .lowQuotaDetected
        case .switchSucceeded: event = .switchSucceeded
        case .switchFailed:
            event = .switchFailed(FeishuSwitchNotification.FailureReason(rawValue: status.failureReason?.rawValue ?? "unknown") ?? .unknown)
        case .quotaReset:
            event = .quotaChange(status.quotaChange ?? .quotaReset(fiveHour: false, sevenDay: false))
        case .resetCreditsAdded, .resetCreditsChanged, .resetCreditsExpiring:
            guard let change = status.quotaChange else { return nil }
            event = .quotaChange(change)
        case .publicRegularReset, .publicBankedReset, .taskStateChange: return nil
        }
        func quota(_ remaining: Double?, resetsAt: Date?) -> FeishuQuotaValue {
            return remaining.map { .finite(remainingPercent: $0, resetsAt: resetsAt) } ?? .unknown
        }
        let context = status.noticeContext
        guard
            let facts = context?.accountFacts
                ?? (try? FeishuAccountFacts(
                    fiveHour: quota(status.fiveHourRemainingPercent, resetsAt: status.accountFacts?.fiveHourResetsAt),
                    sevenDay: quota(status.sevenDayRemainingPercent, resetsAt: status.accountFacts?.sevenDayResetsAt),
                    availableResetCredits: status.accountFacts?.availableResetCredits,
                    resetCreditExpiries: status.accountFacts?.resetCreditExpiries ?? []))
        else { return nil }
        let origin: FeishuSwitchNotification.SwitchOrigin
        switch context?.switchOrigin ?? .manual {
        case .manual: origin = .manual
        case .lowQuota: origin = .lowQuota
        case .restartTest: origin = .restartTest
        }
        return noticeContent(
            NoticeInput(
                event: event, sourceAccount: context?.sourceAccount?.value ?? status.accountLabel?.value,
                targetAccount: context?.targetAccount?.value, switchOrigin: origin,
                triggerThresholdPercent: context?.sevenDayTriggerThresholdPercent ?? 10,
                fiveHourTriggerThresholdPercent: context?.fiveHourTriggerThresholdPercent ?? 5,
                fiveHourRemainingPercent: status.fiveHourRemainingPercent,
                sevenDayRemainingPercent: status.sevenDayRemainingPercent,
                accountFacts: facts, resetCreditComparison: status.resetCreditComparison,
                messageOptions: options, occurredAt: context?.observedAt ?? status.occurredAt), language: language)
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

    private struct NoticeInput {
        let event: FeishuSwitchNotification.Event
        let sourceAccount: String?
        let targetAccount: String?
        let switchOrigin: FeishuSwitchNotification.SwitchOrigin
        let triggerThresholdPercent: Int
        let fiveHourTriggerThresholdPercent: Int
        let fiveHourRemainingPercent: Double?
        let sevenDayRemainingPercent: Double?
        let accountFacts: FeishuAccountFacts
        let resetCreditComparison: CodexResetCreditComparison?
        let messageOptions: FeishuMessageOptions
        let occurredAt: Date
    }

    private static func noticeContent(_ notification: NoticeInput, language: WidgetLanguage) -> MessageNoticeFormat.Content {
        let options = notification.messageOptions
        let style = presentation(for: notification.event, origin: notification.switchOrigin, language: language)
        var title = style.title
        var lines: [String] = []
        let change: CodexQuotaEvent?
        if case .quotaChange(let value) = notification.event { change = value } else { change = nil }
        let checked =
            language.text("**核对时间（北京时间）**：", "**Checked (Beijing time, UTC+8)**: ")
            + MessageNoticeFormat.fullDate(MessageNoticeFormat.checkedAt(for: change, fallback: notification.occurredAt))

        switch notification.event {
        case .test:
            lines = [
                language.text("**结果**：\(style.result)", "**Result**: \(style.result)"),
                language.text("仅测试连接；不会切换账号、重启 Codex 或使用 Reset 卡。", "Connection test only; no account switch, Codex restart, or reset-credit use."),
            ]
        case .lowQuotaDetected:
            lines = [language.text("**结果**：\(style.result)", "**Result**: \(style.result)"), lowQuotaTrigger(for: notification, language: language)]
        case .switchSucceeded, .switchFailed:
            lines = [language.text("**结果**：\(style.result)", "**Result**: \(style.result)")]
        case .quotaChange(.quotaReset(let five, let seven)):
            let windows = [(five, language.text("5小时", "5h")), (seven, language.text("7天", "7d"))]
                .filter { $0.0 }.map { $0.1 }.joined(separator: " + ")
            title =
                windows.isEmpty
                ? language.text("额度窗口变化", "Quota window changed")
                : language.text("\(windows)额度变化", "\(windows) quota changed")
        case .quotaChange(.resetCreditsAdded(let added, _)):
            title = options.includesResetCredits ? language.text("重置卡 +\(added)", "Reset credits +\(added)") : style.title
        case .quotaChange(.resetCreditsChanged(let previous, let available, _, _)):
            title =
                options.includesResetCredits
                ? MessageNoticeFormat.changeTitle(previous: previous, available: available, language: language) : style.title
        case .quotaChange(.resetCreditsExpiring): break
        }
        if options.includesAgentName { lines.append(language.text("**Agent**：Codex", "**Agent**: Codex")) }
        if options.includesAccountLabel, let source = notification.sourceAccount.map(escapedLabel) {
            switch notification.event {
            case .switchSucceeded, .switchFailed:
                if let target = notification.targetAccount.map(escapedLabel) {
                    lines.append(language.text("**切换路径**：\(source) → \(target)", "**Switch path**: \(source) → \(target)"))
                } else {
                    lines.append(language.text("**当前账号**：\(source)", "**Current account**: \(source)"))
                }
            default:
                lines.append(language.text("**账号**：\(source)", "**Account**: \(source)"))
                if case .lowQuotaDetected = notification.event, let target = notification.targetAccount.map(escapedLabel) {
                    lines.append(language.text("**推荐账号**：\(target)", "**Recommended account**: \(target)"))
                }
            }
        }
        func appendBalance(_ balanceText: String? = nil, evidence: [String] = [], allowsUnknownExpiry: Bool = true) {
            let fixed = MessageNoticeFormat.Content(title: title, template: style.template, lines: lines + evidence).rendered()
            let budget = max(0, 4_096 - fixed.utf8.count - 1)
            lines.append(
                resetCreditLine(
                    for: notification, language: language, timeZone: MessageNoticeFormat.beijingTimeZone,
                    balanceText: balanceText, byteBudget: budget, allowsUnknownExpiry: allowsUnknownExpiry))
            lines += evidence
        }
        switch change {
        case .resetCreditsAdded, .resetCreditsChanged, .resetCreditsExpiring:
            lines += knownQuotaLines(for: notification.accountFacts, options: options, language: language)
        default: break
        }
        switch change {
        case .resetCreditsAdded(let added, let available):
            if options.includesResetCredits {
                let balance = language.text(
                    "**重置卡**：\(available - added)→\(available) 张（增加 \(added) 张）",
                    "**Reset credits**: \(available - added)→\(available) (+\(added))")
                appendBalance(balance, evidence: [checked], allowsUnknownExpiry: false)
            } else {
                lines.append(checked)
            }
        case .resetCreditsChanged(let previous, let available, let before, let observedAt):
            if options.includesResetCredits {
                let evidence = MessageNoticeFormat.comparisonLines(
                    .init(
                        previousAvailable: previous, available: available,
                        previousObservedAt: before, observedAt: observedAt), language: language)
                appendBalance(evidence[0], evidence: Array(evidence.dropFirst()), allowsUnknownExpiry: false)
            } else {
                lines.append(checked)
            }
        case .resetCreditsExpiring(let batches, let observedAt):
            if options.includesResetCredits, options.resetExpiryDetail != .none {
                let sorted = batches.sorted { $0.expiresAt < $1.expiresAt }
                let selected = options.resetExpiryDetail == .nearest ? Array(sorted.prefix(1)) : sorted
                let expiryLines = selected.map { batch in
                    language.text("\(batch.count) 张 · ", "\(batch.count) · ") + MessageNoticeFormat.fullDate(batch.expiresAt)
                        + language.text(" 到期（余", " expires (") + MessageNoticeFormat.remaining(until: batch.expiresAt, now: observedAt)
                        + language.text("）", " left)")
                }
                let tail = [language.text("打开 AiGoodBro 按需使用", "Open AiGoodBro to use when needed"), checked]
                let omitted = language.text("其余到期时间请在 AiGoodBro 查看", "See AiGoodBro for remaining expiries")
                for (index, line) in expiryLines.enumerated() {
                    let reserve = index + 1 < expiryLines.count ? [omitted] : []
                    let candidate = MessageNoticeFormat.Content(title: title, template: style.template, lines: lines + [line] + reserve + tail)
                    guard candidate.rendered().utf8.count <= 4_096 else {
                        lines.append(omitted)
                        break
                    }
                    lines.append(line)
                }
                lines += tail
            } else {
                lines.append(checked)
            }
        case .quotaReset, nil:
            if options.includesQuotas {
                for (label, value) in [("5h", notification.accountFacts.fiveHour), ("7d", notification.accountFacts.sevenDay)] {
                    lines.append(
                        quotaLine(
                            label: label, value: value, includesResetTime: options.includesResetTimes,
                            language: language, timeZone: MessageNoticeFormat.beijingTimeZone))
                }
            } else if options.includesResetTimes {
                lines += resetTimeLines(for: notification.accountFacts, language: language, timeZone: MessageNoticeFormat.beijingTimeZone)
            }
            if options.includesResetCredits {
                if let comparison = notification.resetCreditComparison {
                    let evidence = MessageNoticeFormat.comparisonLines(comparison, language: language)
                    appendBalance(evidence[0], evidence: Array(evidence.dropFirst()))
                } else {
                    let missing = change == nil ? [] : [language.text("上次有效数量缺失，净变化未知。", "Previous valid count unavailable; net change unknown.")]
                    appendBalance(evidence: missing + [checked])
                }
            } else {
                lines.append(checked)
            }
        }
        return MessageNoticeFormat.Content(title: title, template: style.template, lines: lines)
    }

    private static func escapedLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
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
        [(language.text("5h 重置", "5h reset"), facts.fiveHour), (language.text("7d 重置", "7d reset"), facts.sevenDay)]
            .map { label, value in
                guard case .finite(_, let resetsAt) = value else {
                    return language.text("**\(label)**：未知", "**\(label)**: Unknown")
                }
                return language.text("**\(label)**：", "**\(label)**: ")
                    + compactDate(resetsAt, language: language, timeZone: timeZone)
            }
    }

    /// Independent Reset notices keep any enabled, known quota facts once;
    /// absent quota or reset-time values add no unrelated unknown rows.
    private static func knownQuotaLines(
        for facts: FeishuAccountFacts, options: FeishuMessageOptions, language: WidgetLanguage
    ) -> [String] {
        [("5h", facts.fiveHour), ("7d", facts.sevenDay)].compactMap { label, value in
            switch value {
            case .unknown: return nil
            case .unlimited:
                return options.includesQuotas
                    ? quotaLine(
                        label: label, value: value, includesResetTime: false,
                        language: language, timeZone: MessageNoticeFormat.beijingTimeZone) : nil
            case .finite(_, let resetsAt):
                if options.includesQuotas {
                    return quotaLine(
                        label: label, value: value, includesResetTime: options.includesResetTimes && resetsAt != nil,
                        language: language, timeZone: MessageNoticeFormat.beijingTimeZone)
                }
                guard options.includesResetTimes, let resetsAt else { return nil }
                return language.text("**\(label) 重置**：", "**\(label) reset**: ") + MessageNoticeFormat.fullDate(resetsAt)
            }
        }
    }

    private static func resetSuffix(_ date: Date?, language: WidgetLanguage, timeZone: TimeZone) -> String {
        guard let date else { return " · " + language.text("重置时间未知", "reset unknown") }
        return " · " + language.text("重置 ", "resets ") + compactDate(date, language: language, timeZone: timeZone)
    }

    private static func resetCreditLine(
        for notification: NoticeInput,
        language: WidgetLanguage,
        timeZone: TimeZone,
        balanceText: String? = nil, byteBudget: Int = 4_096, allowsUnknownExpiry: Bool = true
    ) -> String {
        let availableCount: Int?
        if case .quotaChange(.resetCreditsAdded(_, let available)) = notification.event {
            availableCount = available
        } else if case .quotaChange(.resetCreditsChanged(_, let available, _, _)) = notification.event {
            availableCount = available
        } else {
            availableCount = notification.accountFacts.availableResetCredits
        }
        let count = availableCount.map(String.init) ?? language.text("未知", "Unknown")
        var line = balanceText ?? language.text("**可用重置卡**：\(count) 张", "**Available reset credits**: \(count)")
        guard notification.messageOptions.resetExpiryDetail != .none,
            availableCount != 0
        else { return line }
        let upcoming = notification.accountFacts.resetCreditExpiries
            .filter { $0 >= notification.occurredAt }
        let available =
            availableCount
            .map { Array(upcoming.prefix($0)) } ?? upcoming
        guard !available.isEmpty else {
            return allowsUnknownExpiry ? line + language.text(" · 到期时间未知", " · expiry unknown") : line
        }
        let dates = notification.messageOptions.resetExpiryDetail == .nearest ? Array(available.prefix(1)) : available
        let omitted = language.text(" · 其余到期时间请在 AiGoodBro 查看", " · See AiGoodBro for remaining expiries")
        var rendered: [String] = []
        for (index, date) in dates.enumerated() {
            let next = rendered + [MessageNoticeFormat.fullDate(date)]
            let candidate = line + language.text(" · 到期 ", " · expires ") + next.joined(separator: language.text("、", ", "))
            let reserve = index + 1 < dates.count ? omitted.utf8.count : 0
            guard candidate.utf8.count + reserve <= byteBudget else { break }
            rendered = next
        }
        if !rendered.isEmpty { line += language.text(" · 到期 ", " · expires ") + rendered.joined(separator: language.text("、", ", ")) }
        if rendered.count < dates.count { line += omitted }
        return line
    }

    private static func compactDate(_ date: Date?, language: WidgetLanguage, timeZone: TimeZone) -> String {
        guard let date else { return language.text("未知", "Unknown") }
        return MessageNoticeFormat.fullDate(date)
    }

    private static func lowQuotaTrigger(for notification: NoticeInput, language: WidgetLanguage) -> String {
        var reasons: [String] = []
        if let value = notification.fiveHourRemainingPercent, value <= Double(notification.fiveHourTriggerThresholdPercent) {
            reasons.append(
                notification.messageOptions.includesQuotas
                    ? language.text(
                        "5h 剩余 \(percentText(value))% ≤ \(notification.fiveHourTriggerThresholdPercent)%",
                        "5h remaining \(percentText(value))% ≤ \(notification.fiveHourTriggerThresholdPercent)%")
                    : language.text("5h 达到提醒阈值", "5h reached the alert threshold"))
        }
        if let value = notification.sevenDayRemainingPercent, value < Double(notification.triggerThresholdPercent) {
            reasons.append(
                notification.messageOptions.includesQuotas
                    ? language.text(
                        "7d 剩余 \(percentText(value))% < \(notification.triggerThresholdPercent)%", "7d remaining \(percentText(value))% < \(notification.triggerThresholdPercent)%")
                    : language.text("7d 达到提醒阈值", "7d reached the alert threshold"))
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
                language.text("🧪 Codex 连接测试", "🧪 Codex connection test"),
                language.text("测试消息", "Test message"), "blue"
            )
        case .lowQuotaDetected:
            return (
                language.text("⚠️ Codex 低额度提醒", "⚠️ Codex low-quota alert"),
                language.text("已触发额度提醒", "Quota alert threshold reached"), "orange"
            )
        case .quotaChange(.quotaReset):
            return (
                language.text("🔄 Codex 官方额度窗口变化", "🔄 Codex official quota window changed"),
                language.text("观察到官方额度恢复或新窗口", "Official quota recovery or a new window was observed"),
                "turquoise"
            )
        case .quotaChange(.resetCreditsAdded):
            return (
                language.text("重置卡变化", "Reset credits changed"),
                language.text("官方可用 Reset 次数增加", "Official available reset count increased"), "purple"
            )
        case .quotaChange(.resetCreditsChanged):
            return (language.text("重置卡变化", "Reset credits changed"), language.text("可用次数净变化", "Net change in available credits"), "purple")
        case .quotaChange(.resetCreditsExpiring):
            return (language.text("重置卡将到期", "Reset credits expire soon"), language.text("24h 内到期", "Expires within 24h"), "orange")
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
    private static var endpoint: URL?

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static var lastEndpoint: URL? {
        lock.lock()
        defer { lock.unlock() }
        return endpoint
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.endpoint = request.url
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
                let elements = body["elements"] as? [[String: Any]]
            else { return "" }
            return elements.compactMap { $0["content"] as? String }.joined(separator: "\n")
                .replacingOccurrences(of: "\\*", with: "*").replacingOccurrences(of: "\\_", with: "_")
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
            expect(markdown(payload).contains("p***-source"), "masked source missing")
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
            expect(customText.contains("5h remaining 18% ≤ 20%") && !customText.contains("7d remaining 70% < 15%"), "notification must show only the threshold actually met")
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
                String(data: testPayload, encoding: .utf8)?.contains("Codex 连接测试") == true,
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
            expect(compactText.contains("**5h**：∞"), "confirmed unlimited 5-hour value missing")
            expect(
                compactText.contains(MessageNoticeFormat.fullDate(firstExpiry)) && !compactText.contains(MessageNoticeFormat.fullDate(secondExpiry)),
                "default expiry must show nearest upcoming value only")
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
                expiryText.contains(MessageNoticeFormat.fullDate(expiryNow.addingTimeInterval(3_600)))
                    && !expiryText.contains(MessageNoticeFormat.fullDate(expiryNow.addingTimeInterval(7_200))),
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
                zeroText.contains("**Available reset credits**: 0") && !zeroText.contains("expiry unknown"),
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
            expect(
                filteredText.contains(MessageNoticeFormat.fullDate(firstExpiry)) && filteredText.contains(MessageNoticeFormat.fullDate(secondExpiry)),
                "all expiry details were not rendered")

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
            failures += credentialLifecycleTests(notification: testNotification, endpoint: valid[0])
            failures += credentialLockWaitTests(endpoint: valid[0])
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
                expect(
                    english.replacingOccurrences(of: "消息来源：aigoodbro.com", with: "").range(of: "[\\x{3400}-\\x{9FFF}\\x{F900}-\\x{FAFF}]", options: .regularExpression) == nil,
                    "English notification must not contain Chinese app copy")
                expect(english.contains("p***-source") && !english.contains("person@example.com"), "English notification must preserve masking")
                expect(body.contains("核对时间（北京时间）"), "notification check time must retain its time zone")
                expect(body.components(separatedBy: "\n").filter { $0 == "消息来源：aigoodbro.com" }.count == 1, "Feishu footer missing or repeated")
                switch change {
                case .quotaReset:
                    expect(body.contains("5h") && body.contains("7d"), "reset quotas missing")
                    expect(
                        eventHeader.title == "5小时 + 7天额度变化" && eventHeader.template == "turquoise",
                        "official quota-window card is not visually distinct")
                    expect(
                        body.contains("上次有效数量缺失，净变化未知") && !body.contains("另行核对"),
                        "window without a comparable baseline must state the missing fact")
                    expect(!body.contains("未获得或使用 Reset 卡"), "stale over-claiming window copy survived")
                case .resetCreditsAdded:
                    expect(body.contains("**重置卡**：1→3 张（增加 2 张）"), "official credit count missing")
                    expect(
                        eventHeader.title == "重置卡 +2" && eventHeader.template == "purple",
                        "reset-credit card is not visually distinct")
                    expect(
                        body.components(separatedBy: "1→3").count == 2
                            && body.components(separatedBy: "**5h**").count == 2 && body.components(separatedBy: "**7d**").count == 2,
                        "standalone credit change repeats balance or known quotas")
                    expect(
                        !body.contains("**可用重置卡**") && !body.contains("未知"),
                        "validated standalone balance gained a duplicate count or unrelated unknown fact")
                case .resetCreditsChanged, .resetCreditsExpiring:
                    failures.append("unexpected new event in legacy compatibility fixture")
                }
            }
            var hiddenOptions = FeishuMessageOptions.standard
            hiddenOptions.includesAccountLabel = false
            hiddenOptions.includesQuotas = false
            hiddenOptions.includesResetTimes = false
            hiddenOptions.includesResetCredits = false
            let hiddenEvent = try FeishuSwitchNotification(
                event: .quotaChange(.resetCreditsAdded(added: 2, available: 3)),
                sourceAccount: source, triggerThresholdPercent: 10, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: nil,
                messageOptions: hiddenOptions)
            let hiddenPayload = try FeishuWebhookService.payloadData(for: hiddenEvent, language: .zh)
            let hiddenText = markdown(hiddenPayload)
            expect(
                !hiddenText.contains(source.value) && !hiddenText.contains("1→3") && !hiddenText.contains("5h")
                    && !cardHeader(hiddenPayload).title.contains("+2"), "reset cards must honor hidden fields in both title and body")
            let conflictingFacts = try FeishuAccountFacts(
                fiveHour: .unknown, sevenDay: .unknown,
                availableResetCredits: 4, resetCreditExpiries: [])
            expect(
                (try? FeishuSwitchNotification(
                    event: .quotaChange(.resetCreditsAdded(added: 2, available: 3)),
                    sourceAccount: source, triggerThresholdPercent: 10, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: nil,
                    accountFacts: conflictingFacts)) == nil, "conflicting current balances must not enter a notification")
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

        if let previewPath = ProcessInfo.processInfo.environment["AIGOODBRO_FEISHU_PREVIEW_DIRECTORY"] {
            do { try writePreviewFixtures(to: URL(fileURLWithPath: previewPath)) } catch { failures.append("offline preview export failed") }
        }

        if failures.isEmpty {
            print("Feishu webhook self-test passed")
            return true
        }
        failures.forEach { print("Feishu webhook self-test failed: \($0)") }
        return false
    }

    private static func writePreviewFixtures(to directory: URL) throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let source = try FeishuMaskedAccount(displayName: "Pro 20x · 演示账号")
        let facts = try FeishuAccountFacts(
            fiveHour: .finite(remainingPercent: 100, resetsAt: now.addingTimeInterval(18_000)),
            sevenDay: .finite(remainingPercent: 82, resetsAt: now.addingTimeInterval(259_200)),
            availableResetCredits: 3, resetCreditExpiries: [now.addingTimeInterval(7 * 86_400)])
        var payloads: [String: Data] = [:]
        for (name, change) in [
            ("reset-credit", CodexQuotaEvent.resetCreditsAdded(added: 2, available: 3)),
            ("quota-window", .quotaReset(fiveHour: true, sevenDay: false)),
        ] {
            let event = try FeishuSwitchNotification(
                event: .quotaChange(change), sourceAccount: source,
                triggerThresholdPercent: 10, fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82,
                accountFacts: facts, occurredAt: now)
            payloads[name] = try FeishuWebhookService.payloadData(for: event, language: .zh)
        }
        let id = PublicResetForecast.sourcePostID(at: now)!
        let url = URL(string: "https://x.com/thsottiaux/status/\(id)")!
        let forecast = PublicResetForecast(
            id: id, latestBy: now.addingTimeInterval(7_200), announcedAt: now,
            sourceURL: url, fetchedAt: now)
        payloads["forecast"] = try FeishuWebhookService.publicResetForecastPayload(
            PublicResetForecastNotification(forecast, referenceDate: now), language: .zh)
        payloads["public-announcement"] = try FeishuWebhookService.publicResetPayload(
            PublicResetAnnouncement(
                id: id, resetType: .banked, announcedAt: now, text: "Synthetic preview",
                source: .init(type: "x_post", author: "thsottiaux", url: url)), language: .zh)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in payloads { try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic) }
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
            // Model Allow Once: each Security read needs its own interaction.
            guard allowed else { return errSecInteractionNotAllowed }
            prompts += 1
            result?.pointee = Data(endpoint.utf8) as CFData
            return errSecSuccess
        }
        // A successful silent startup read must be reused in memory. A later
        // locked/busy Keychain must not turn a ready channel into a password flow.
        var silentReads = 0
        let silent = FeishuWebhookService(sessionConfiguration: configuration, keychainInteraction: interaction) { _, result in
            silentReads += 1
            guard silentReads == 1 else { return errSecInteractionNotAllowed }
            result?.pointee = Data(endpoint.utf8) as CFData
            return errSecSuccess
        }
        var silentProbe: Result<Bool, FeishuWebhookError>?
        silent.hasStoredWebhook { silentProbe = $0 }
        waitUntil { silentProbe != nil }
        var silentSecondProbe: Result<Bool, FeishuWebhookError>?
        silent.hasStoredWebhook { silentSecondProbe = $0 }
        waitUntil { silentSecondProbe != nil }
        if case .success(true)? = silentSecondProbe {} else { failures.append("successful silent read was not cached") }
        expect(silentReads == 1, "ready connection unnecessarily reread Keychain")
        silent.invalidateCredentialCache()
        var silentInvalidated: Result<Bool, FeishuWebhookError>?
        silent.hasStoredWebhook { silentInvalidated = $0 }
        waitUntil { silentInvalidated != nil }
        if case .failure(.keychainAuthorizationRequired)? = silentInvalidated {} else { failures.append("invalidated silent cache reused an old credential") }
        // Keep the subsequent explicit-authorization policy assertions isolated.
        policy.removeAll()
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
        expect(policy == [false, true, false, true, true, true], "cached send accessed Keychain or UI policy was not restored")
        var cachedProbe: Result<Bool, FeishuWebhookError>?
        service.hasStoredWebhook { cachedProbe = $0 }
        waitUntil { cachedProbe != nil }
        if case .success(true)? = cachedProbe {} else { failures.append("authorized probe reread an Allow Once credential") }
        service.invalidateCredentialCache()
        var disabledSend: Result<Void, FeishuWebhookError>?
        service.send(notification) { disabledSend = $0 }
        waitUntil { disabledSend != nil }
        if case .failure(.keychainAuthorizationRequired)? = disabledSend {} else { failures.append("cleared connection reused its authorized endpoint") }
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore + 1, "cleared connection reached transport")

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

    private static func credentialLockWaitTests(endpoint: String) -> [String] {
        var failures: [String] = []
        func waitUntil(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        for action in ["authorize", "save", "remove", "probe"] {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            var operations = 0
            // Pause inside perform, before its operation. This deterministically
            // models the connection changing while waiting for the shared lock.
            let interaction = FeishuKeychainInteraction(
                getAllowed: {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 2)
                    return true
                }, setAllowed: { _ in })
            let service = FeishuWebhookService(
                keychainInteraction: interaction,
                updateItem: { _, _ in
                    operations += 1
                    return errSecSuccess
                },
                addItem: { _, _ in
                    operations += 1
                    return errSecSuccess
                },
                deleteItem: { _ in
                    operations += 1
                    return errSecSuccess
                },
                copyMatching: { _, result in
                    operations += 1
                    result?.pointee = Data(endpoint.utf8) as CFData
                    return errSecSuccess
                })
            var result: Result<Void, FeishuWebhookError>?
            switch action {
            case "authorize": service.authorizeStoredWebhook { result = $0 }
            case "save": service.storeWebhook(endpoint) { result = $0 }
            case "remove": service.removeStoredWebhook { result = $0 }
            default: service.hasStoredWebhook { result = $0.map { _ in () } }
            }
            if entered.wait(timeout: .now() + 2) != .success { failures.append("\(action) did not enter the lock-wait fixture") }
            service.invalidateCredentialCache()
            release.signal()
            waitUntil { result != nil }
            if case .failure(.cancelled)? = result {} else { failures.append("\(action) was not cancelled after waiting for the lock") }
            if operations != 0 { failures.append("\(action) accessed Keychain after invalidation while waiting for the lock") }
        }
        // A system update already in progress cannot be cancelled, but its
        // follow-up Add/readback must not start after the connection is cleared.
        for updateStatus in [errSecSuccess, errSecItemNotFound] {
            weak var interrupted: FeishuWebhookService?
            var followUpCalls = 0
            let service = FeishuWebhookService(
                keychainInteraction: FeishuKeychainInteraction(getAllowed: { true }, setAllowed: { _ in }),
                updateItem: { _, _ in
                    interrupted?.invalidateCredentialCache()
                    return updateStatus
                },
                addItem: { _, _ in
                    followUpCalls += 1
                    return errSecSuccess
                },
                copyMatching: { _, result in
                    followUpCalls += 1
                    result?.pointee = Data(endpoint.utf8) as CFData
                    return errSecSuccess
                })
            interrupted = service
            var result: Result<Void, FeishuWebhookError>?
            service.storeWebhook(endpoint) { result = $0 }
            waitUntil { result != nil }
            if case .failure(.cancelled)? = result {} else { failures.append("interrupted update did not cancel its save") }
            if followUpCalls != 0 { failures.append("interrupted update started Add or readback after invalidation") }
        }
        return failures
    }

    private static func credentialLifecycleTests(notification: FeishuSwitchNotification, endpoint: String) -> [String] {
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
        let interaction = FeishuKeychainInteraction(getAllowed: { allowed }, setAllowed: { allowed = $0 })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeishuWebhookTestProtocol.self]
        let replacement = "https://open.larksuite.com/open-apis/bot/v2/hook/fixture-replacement-123456"
        var stored = Data(endpoint.utf8)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var blockFirstRead = true
        var deleted = false
        let service = FeishuWebhookService(
            sessionConfiguration: configuration, keychainInteraction: interaction,
            updateItem: { _, attributes in
                stored = (attributes as NSDictionary)[kSecValueData as String] as! Data
                return errSecSuccess
            },
            deleteItem: { _ in
                deleted = true
                return errSecSuccess
            },
            copyMatching: { _, result in
                guard allowed else { return errSecInteractionNotAllowed }
                let value = stored
                if blockFirstRead {
                    blockFirstRead = false
                    entered.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
                result?.pointee = value as CFData
                return errSecSuccess
            })
        var oldAuthorization: Result<Void, FeishuWebhookError>?
        service.authorizeStoredWebhook { oldAuthorization = $0 }
        expect(entered.wait(timeout: .now() + 2) == .success, "authorization fixture did not start")
        var replacementResult: Result<Void, FeishuWebhookError>?
        service.storeWebhook(replacement) { replacementResult = $0 }
        release.signal()
        waitUntil { oldAuthorization != nil && replacementResult != nil }
        if case .failure(.cancelled)? = oldAuthorization {} else { failures.append("late authorization revived the replaced connection") }
        expect(replacementResult?.isSuccess == true, "replacement was not saved and read back")
        let requestsBefore = FeishuWebhookTestProtocol.requestCount
        var delivered: Result<Void, FeishuWebhookError>?
        service.send(notification) { result in DispatchQueue.main.async { delivered = result } }
        waitUntil { delivered != nil }
        expect(delivered?.isSuccess == true, "replacement cache did not support background delivery")
        expect(FeishuWebhookTestProtocol.lastEndpoint == URL(string: replacement), "replacement used the old endpoint")

        var pendingSend: Result<Void, FeishuWebhookError>?
        service.send(notification) { pendingSend = $0 }
        service.invalidateCredentialCache()
        waitUntil { pendingSend != nil }
        if case .failure(.cancelled)? = pendingSend {} else { failures.append("cleared pending read was not cancelled") }
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore + 1, "clear allowed a pending notification through")

        // A successful Security call with a queued main-thread completion must
        // not report readiness after the user closes the connection.
        var lateCompletion: Result<Void, FeishuWebhookError>?
        service.authorizeStoredWebhook { lateCompletion = $0 }
        service.keychainQueue.sync {}
        service.invalidateCredentialCache()
        waitUntil { lateCompletion != nil }
        if case .failure(.cancelled)? = lateCompletion {} else { failures.append("late authorization completion reported a cleared connection ready") }

        var authorization: Result<Void, FeishuWebhookError>?
        service.authorizeStoredWebhook { authorization = $0 }
        waitUntil { authorization != nil }
        expect(authorization?.isSuccess == true, "fixture authorization did not recover")
        var removal: Result<Void, FeishuWebhookError>?
        service.removeStoredWebhook { removal = $0 }
        waitUntil { removal != nil }
        expect(deleted && removal?.isSuccess == true, "remove did not use the isolated Keychain operation")
        var removedSend: Result<Void, FeishuWebhookError>?
        service.send(notification) { removedSend = $0 }
        waitUntil { removedSend != nil }
        if case .failure(.keychainAuthorizationRequired)? = removedSend {} else { failures.append("removed connection reused cached authorization") }
        expect(FeishuWebhookTestProtocol.requestCount == requestsBefore + 1, "removed connection reached transport")

        let readEntered = DispatchSemaphore(value: 0)
        let readRelease = DispatchSemaphore(value: 0)
        let readService = FeishuWebhookService(
            sessionConfiguration: configuration, keychainInteraction: interaction,
            copyMatching: { _, result in
                readEntered.signal()
                _ = readRelease.wait(timeout: .now() + 2)
                result?.pointee = Data(endpoint.utf8) as CFData
                return errSecSuccess
            })
        var oldRead: Result<Bool, FeishuWebhookError>?
        readService.hasStoredWebhook { oldRead = $0 }
        expect(readEntered.wait(timeout: .now() + 2) == .success, "background fixture did not start")
        readService.invalidateCredentialCache()
        readRelease.signal()
        waitUntil { oldRead != nil }
        if case .failure(.cancelled)? = oldRead {} else { failures.append("late background read revived a cleared connection") }
        expect(allowed, "lifecycle test left Keychain interaction disabled")
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
            expect(cardHeader(payload).title == "Codex 运行结束" && cardHeader(payload).template == "green", "task-completion card is not green or mislabeled")
            expect(text.contains("运行结束") && !text.contains("任务已完成") && text.contains("CLI 派发任务"), "run end and category missing")
            expect(markdown(payload).hasSuffix("\n消息来源：aigoodbro.com"), "task-completion footer missing")
            expect(text.contains("CLI 派发任务") && text.contains("**尝试次数**：2") && text.contains("pro20x"), "bounded fields missing")
            expect(text.contains("请打开原任务查看结果") && !text.contains("已验收"), "completion must direct users to the result without claiming acceptance")
            expect(!text.contains(id.uuidString) && !text.contains("事件 ID"), "internal event ID rendered")
            let kimi = try? FeishuTaskCompletionNotification(
                eventID: id, proof: .confirmedByTaskObserver, category: .kimiConversation,
                occurredAt: now.addingTimeInterval(-30), now: now)
            expect(kimi != nil, "kimi category rejected")
            let englishData = try FeishuWebhookService.taskCompletionPayload(confirmed, language: .en)
            let english = String(data: englishData, encoding: .utf8) ?? ""
            expect(
                english.replacingOccurrences(of: "消息来源：aigoodbro.com", with: "").range(of: "\\p{Han}", options: .regularExpression) == nil,
                "English task card must not contain Chinese copy")
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
