import Combine
import Foundation
import Security

protocol MessageChannelCredentialStoring {
    func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void)
    func authorizeStored(_ kind: MessageChannelKind, request: MessageCredentialReadRequest)
    func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void)
    func saveBackground(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void)
}

extension MessageChannelCredentialStoring {
    func authorizeStored(_ kind: MessageChannelKind, request: MessageCredentialReadRequest) {
        guard request.begin() else { return }
        load(kind) { request.finish($0) }
    }

    func saveBackground(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
        save(value, for: kind, completion: completion)
    }
}

/// A queued authorization may expire or be cancelled before Security starts.
/// Once Security starts, retain admission until its own dialog returns.
final class MessageCredentialReadRequest {
    private enum State { case waiting, active, finished }
    private let lock = NSLock()
    private var state: State = .waiting
    private let deadline: DispatchTime
    private let completion: (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void

    init(waitTimeout: TimeInterval = 6, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) {
        self.completion = completion
        deadline = .now() + waitTimeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + waitTimeout) { [weak self] in
            self?.finishWaiting(.failure(.keychainTimedOut))
        }
    }

    func begin() -> Bool {
        lock.lock()
        guard state == .waiting else {
            lock.unlock()
            return false
        }
        guard DispatchTime.now() < deadline else {
            state = .finished
            lock.unlock()
            DispatchQueue.main.async { self.completion(.failure(.keychainTimedOut)) }
            return false
        }
        state = .active
        lock.unlock()
        return true
    }

    func cancelBeforeStart() { finishWaiting(.failure(.cancelled)) }

    private func finishWaiting(_ result: Result<MessageChannelCredential?, FeishuWebhookError>) {
        lock.lock()
        guard state == .waiting else {
            lock.unlock()
            return
        }
        state = .finished
        lock.unlock()
        DispatchQueue.main.async { self.completion(result) }
    }

    func finish(_ result: Result<MessageChannelCredential?, FeishuWebhookError>) {
        lock.lock()
        guard state != .finished else {
            lock.unlock()
            return
        }
        state = .finished
        lock.unlock()
        DispatchQueue.main.async { self.completion(result) }
    }
}

/// One encrypted record per channel. Background reads never request a system
/// dialog, and use the same bounded read and interaction lock as Feishu.
final class MessageChannelKeychainStore: MessageChannelCredentialStoring {
    private let queue = DispatchQueue(label: "com.blackielf.codex-account-manager-next.message-keychain", qos: .utility)
    private let capacity = DispatchSemaphore(value: 2)
    private let interaction: FeishuKeychainInteraction
    private let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus

    init(
        interaction: FeishuKeychainInteraction = .system,
        copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus = { SecItemCopyMatching($0, $1) }
    ) {
        self.interaction = interaction
        self.copyMatching = copyMatching
    }

    private func query(_ kind: MessageChannelKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.blackielf.codex-account-manager-next.message-channel.\(kind.rawValue)",
            kSecAttrAccount as String: "default",
        ]
    }

    func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) {
        guard capacity.wait(timeout: .now()) == .success else {
            DispatchQueue.main.async { completion(.failure(.keychainBusy)) }
            return
        }
        let read = FeishuKeychainRead<MessageChannelCredential?>(timeout: 6, completion: completion)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { read.finish(.failure(.keychainTimedOut)) }
        queue.async {
            defer { self.capacity.signal() }
            guard !read.isFinished else { return }
            do {
                let value: MessageChannelCredential? = try self.interaction.perform(allowInteraction: false) {
                    try self.readStoredCredential(kind)
                }
                read.finish(.success(value))
            } catch let error as FeishuWebhookError { read.finish(.failure(error)) } catch { read.finish(.failure(.invalidNotification)) }
        }
    }

    /// Explicit user action only. Keep it pending until the system dialog returns
    /// so a timeout cannot admit another authorization prompt.
    func authorizeStored(_ kind: MessageChannelKind, request: MessageCredentialReadRequest) {
        queue.async {
            do {
                let result: Result<MessageChannelCredential?, FeishuWebhookError>? = try self.interaction.perform(allowInteraction: true) {
                    // Check after both the channel queue and the shared Security
                    // interaction lock: abandoned queued work never opens a dialog.
                    guard request.begin() else { return nil }
                    do { return .success(try self.readStoredCredential(kind)) } catch let error as FeishuWebhookError { return .failure(error) } catch {
                        return .failure(.invalidNotification)
                    }
                }
                if let result { request.finish(result) }
            } catch let error as FeishuWebhookError { request.finish(.failure(error)) } catch { request.finish(.failure(.invalidNotification)) }
        }
    }

    private func readStoredCredential(_ kind: MessageChannelKind) throws -> MessageChannelCredential? {
        var query = self.query(kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw FeishuWebhookError.credential(status) }
        guard let data = item as? Data, data.count <= 32768,
            let credential = try? JSONDecoder().decode(MessageChannelCredential.self, from: data).validated(for: kind)
        else { throw FeishuWebhookError.invalidNotification }
        return credential
    }

    func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
        save(value, for: kind, allowInteraction: true, completion: completion)
    }

    func saveBackground(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
        save(value, for: kind, allowInteraction: false, completion: completion)
    }

    private func save(
        _ value: MessageChannelCredential, for kind: MessageChannelKind, allowInteraction: Bool,
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        // The controller keeps this explicit user action pending until Security
        // returns; a timeout must not allow overlapping credential writes.
        queue.async {
            let result: Result<Void, FeishuWebhookError>
            do {
                try self.interaction.perform(allowInteraction: allowInteraction) {
                    let data = try JSONEncoder().encode(value.validated(for: kind))
                    guard data.count <= 32768 else { throw FeishuWebhookError.invalidNotification }
                    let query = self.query(kind)
                    let attributes: [String: Any] = [
                        kSecValueData as String: data,
                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    ]
                    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                    if status == errSecItemNotFound {
                        var item = query
                        attributes.forEach { item[$0.key] = $0.value }
                        status = SecItemAdd(item as CFDictionary, nil)
                    }
                    guard status == errSecSuccess else { throw FeishuWebhookError.credential(status) }
                }
                result = .success(())
            } catch let error as FeishuWebhookError { result = .failure(error) } catch { result = .failure(.invalidNotification) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private final class FrozenMessageChannelCredential: MessageChannelCredentialProviding {
    let kind: MessageChannelKind
    let value: MessageChannelCredential
    init(kind: MessageChannelKind, value: MessageChannelCredential) {
        self.kind = kind
        self.value = value
    }
    func isEnabled(_ kind: MessageChannelKind) -> Bool { self.kind == kind }
    func credential(for kind: MessageChannelKind) -> String? { self.kind == kind ? value.secret : nil }
    func targetID(for kind: MessageChannelKind) -> String? { self.kind == kind ? value.target : nil }
}

/// UI-owned coordinator, like UsageStore. All state mutations and credential
/// callbacks run on the main queue; each send freezes its target and revision.
final class MessageChannelsController: ObservableObject {
    @Published private(set) var telegramEnabled: Bool
    @Published private(set) var weChatEnabled: Bool
    @Published private(set) var personalWeChatEnabled: Bool
    @Published private(set) var personalChatEnabled: Bool
    @Published private(set) var personalChatThreadID: String
    @Published private(set) var personalAutomaticThreadID = ""
    var personalEffectiveChatThreadID: String { personalChatThreadID.isEmpty ? personalAutomaticThreadID : personalChatThreadID }
    @Published private(set) var personalChatTargets: [WeChatCodexConversationTarget] = []
    @Published private(set) var personalBotIsReplying = false
    @Published private(set) var weChatMessageOptions: FeishuMessageOptions
    @Published private(set) var telegramPhase: MessageChannelPhase = .disabled
    @Published private(set) var weChatPhase: MessageChannelPhase = .disabled
    @Published private(set) var personalWeChatPhase: MessageChannelPhase = .disabled
    @Published private(set) var personalWeChatConnected = false
    @Published private(set) var personalWeChatHasContext = false
    @Published private(set) var personalWeChatNeedsAuthorization = false
    @Published private(set) var personalWeChatBindingMissing = false
    @Published private(set) var personalWeChatRestoreInProgress = false
    @Published private(set) var personalWeChatStatusText: String?
    @Published private(set) var personalLoginInProgress = false
    @Published private(set) var personalLoginQRCode: String?
    @Published private(set) var personalLoginNeedsCode = false
    @Published private(set) var statusText: String?
    @Published private(set) var actionInFlight = false
    var onConfigurationChanged: (() -> Void)?
    var onPersonalBotCommand: ((String) -> String?)?
    var onRefreshPersonalChatTargets: (() -> Void)?
    var onCreatePersonalChat: ((WeChatCodexSendAdmission) async -> WeChatCodexThreadCreation)?
    var onOpenPersonalChatThread: ((String) -> Bool)?

    private let defaults: UserDefaults
    private let storage: MessageChannelCredentialStoring
    private let transport: () -> MessageChannelTransport
    private let personalTransport: () -> MessageChannelTransport
    private var credentials: [MessageChannelKind: MessageChannelCredential] = [:]
    private var revisions: [MessageChannelKind: UUID] = [:]
    private var tasks: [MessageChannelKind: [UUID: Task<Void, Never>]] = [:]
    private var completionObservers: [MessageChannelKind: FeishuTaskCompletionObserver] = [:]
    private let telegramEvents = MessageEventDeduplicator()
    private let weChatEvents = MessageEventDeduplicator()
    private let personalWeChatEvents = MessageEventDeduplicator()
    private var personalConnectionEpoch = UUID()
    private var personalMonitor: Task<Void, Never>?
    private var personalLogin: Task<Void, Never>?
    private var personalVerificationCode: String?
    private let botLedger: WeChatBotEventLedger
    private let conversationFactory: @MainActor () -> WeChatCodexConversation
    private var personalConversation: WeChatCodexConversation?
    private var personalChatMessageID: UUID?
    private var personalBotTasks: [UUID: Task<Void, Never>] = [:]
    private var personalChatEpoch = UUID()
    private var personalMessagesNotBefore = Date.distantFuture
    private var personalChatNotBefore = Date()
    private var personalTargetsRefreshedAt = Date.distantPast
    private var credentialWriteInFlight = false {
        didSet { updateActionInFlight() }
    }
    private var explicitTest: (kind: MessageChannelKind, id: UUID)? {
        didSet { updateActionInFlight() }
    }
    private var personalAuthorizationRequest: MessageCredentialReadRequest?
    private var personalAuthorizationID: UUID? {
        didSet {
            personalWeChatRestoreInProgress = personalAuthorizationID != nil
            updateActionInFlight()
        }
    }
    private func updateActionInFlight() {
        actionInFlight = credentialWriteInFlight || explicitTest != nil || personalAuthorizationID != nil
    }
    private var running = false

    init(
        defaults: UserDefaults = .standard, storage: MessageChannelCredentialStoring = MessageChannelKeychainStore(),
        transport: @escaping () -> MessageChannelTransport = { URLSessionMessageChannelTransport() },
        personalTransport: @escaping () -> MessageChannelTransport = {
            URLSessionMessageChannelTransport(requestTimeout: 40, resourceTimeout: 45)
        },
        botLedger: WeChatBotEventLedger = WeChatBotEventLedger(),
        conversationFactory: @escaping @MainActor () -> WeChatCodexConversation = { WeChatCodexConversation() }
    ) {
        self.defaults = defaults
        self.storage = storage
        self.transport = transport
        self.personalTransport = personalTransport
        self.botLedger = botLedger
        self.conversationFactory = conversationFactory
        telegramEnabled = defaults.bool(forKey: Self.enabledKey(.telegram))
        weChatEnabled = defaults.bool(forKey: Self.enabledKey(.weChat))
        personalWeChatEnabled = defaults.bool(forKey: Self.enabledKey(.personalWeChat))
        personalChatEnabled = defaults.bool(forKey: Self.personalChatEnabledKey)
        let thread = defaults.string(forKey: Self.personalChatThreadKey) ?? ""
        personalChatThreadID = UUID(uuidString: thread) == nil ? "" : thread
        weChatMessageOptions =
            defaults.data(forKey: Self.weChatOptionsKey)
            .flatMap { try? JSONDecoder().decode(FeishuMessageOptions.self, from: $0) } ?? .standard
    }

    private static func enabledKey(_ kind: MessageChannelKind) -> String { "CodexManagerNext.messageChannel.\(kind.rawValue).enabled" }
    private static let weChatOptionsKey = "CodexManagerNext.messageChannel.wechat.messageOptions.v1"
    private static let personalChatEnabledKey = "CodexManagerNext.messageChannel.personal-wechat.chatEnabled.v1"
    private static let personalChatThreadKey = "CodexManagerNext.messageChannel.personal-wechat.chatThread.v1"

    func setPersonalChatEnabled(_ enabled: Bool) {
        guard !credentialWriteInFlight, enabled != personalChatEnabled else { return }
        cancelPersonalBotTasks()
        personalChatEnabled = enabled
        personalChatNotBefore = Date()
        defaults.set(enabled, forKey: Self.personalChatEnabledKey)
    }

    func setPersonalChatThread(_ id: String) {
        guard !credentialWriteInFlight, id != personalChatThreadID,
            id.isEmpty || UUID(uuidString: id) != nil && personalChatTargets.contains(where: { $0.id == id })
        else { return }
        cancelPersonalBotTasks()
        personalChatThreadID = id
        personalChatNotBefore = Date()
        defaults.set(id, forKey: Self.personalChatThreadKey)
    }

    private func cancelPersonalBotTasks() {
        personalChatEpoch = UUID()
        personalBotTasks.values.forEach { $0.cancel() }
        personalBotTasks.removeAll()
        personalChatMessageID = nil
        personalBotIsReplying = false
    }

    func setWeChatMessageOptions(_ options: FeishuMessageOptions) {
        guard !actionInFlight, options != weChatMessageOptions,
            let data = try? JSONEncoder().encode(options)
        else { return }
        defaults.set(data, forKey: Self.weChatOptionsKey)
        weChatMessageOptions = options
        invalidate(.weChat)
        invalidate(.personalWeChat)
        onConfigurationChanged?()
    }
    private func isEnabled(_ kind: MessageChannelKind) -> Bool {
        switch kind {
        case .telegram: return telegramEnabled
        case .weChat: return weChatEnabled
        case .personalWeChat: return personalWeChatEnabled
        }
    }
    private func setPhase(_ phase: MessageChannelPhase, for kind: MessageChannelKind) {
        switch kind {
        case .telegram: telegramPhase = phase
        case .weChat: weChatPhase = phase
        case .personalWeChat: personalWeChatPhase = phase
        }
    }

    func start() {
        guard !running else { return }
        running = true
        for kind in MessageChannelKind.allCases where isEnabled(kind) { load(kind) }
    }

    func stop() {
        running = false
        stopPersonalConnection()
        personalWeChatConnected = false
        personalWeChatHasContext = false
        credentials.removeAll()
        for kind in MessageChannelKind.allCases { invalidate(kind) }
    }

    private func invalidate(_ kind: MessageChannelKind) {
        if explicitTest?.kind == kind { explicitTest = nil }
        revisions[kind] = UUID()
        if kind == .personalWeChat { personalAuthorizationRequest?.cancelBeforeStart() }
        completionObservers.removeValue(forKey: kind)
        tasks.removeValue(forKey: kind)?.values.forEach { $0.cancel() }
        setPhase(isEnabled(kind) ? (credentials[kind] == nil ? .needsSetup : .pendingVerification) : .disabled, for: kind)
        if kind == .personalWeChat {
            personalWeChatHasContext = isEnabled(kind) && (credentials[kind]?.personalBinding?.hasFreshContext() ?? false)
            if isEnabled(kind), !personalWeChatHasContext { setPhase(.needsSetup, for: kind) }
        }
    }

    func setEnabled(_ enabled: Bool, for kind: MessageChannelKind) {
        // A pending storage write cannot be superseded by a settings toggle.
        guard !credentialWriteInFlight else { return }
        switch kind {
        case .telegram: telegramEnabled = enabled
        case .weChat: weChatEnabled = enabled
        case .personalWeChat:
            personalWeChatEnabled = enabled
            personalWeChatStatusText = nil
            personalWeChatNeedsAuthorization = false
            personalWeChatBindingMissing = false
            stopPersonalConnection()
            personalWeChatConnected = false
            personalWeChatHasContext = false
        }
        defaults.set(enabled, forKey: Self.enabledKey(kind))
        invalidate(kind)
        if enabled && running { load(kind) } else { credentials.removeValue(forKey: kind) }
        onConfigurationChanged?()
    }

    private func load(_ kind: MessageChannelKind) {
        if kind == .personalWeChat { stopPersonalConnection() }
        invalidate(kind)
        let revision = revisions[kind]
        storage.load(kind) { [weak self] result in
            guard let self, self.running, self.isEnabled(kind), self.revisions[kind] == revision else { return }
            self.applyStoredCredential(result, for: kind)
        }
    }

    /// Opening the settings sheet is the explicit authorization action.
    func openPersonalWeChatSettings() {
        guard personalWeChatEnabled, !personalWeChatConnected, !personalWeChatBindingMissing else { return }
        restorePersonalWeChatConnection()
    }

    /// Restores the saved binding without requesting a QR or writing a credential.
    func restorePersonalWeChatConnection() {
        guard running, personalWeChatEnabled, !actionInFlight, !personalLoginInProgress else { return }
        stopPersonalConnection()
        invalidate(.personalWeChat)
        let revision = revisions[.personalWeChat]
        let action = UUID()
        personalAuthorizationID = action
        setPersonalStatus(WidgetLanguage.storedOrAutomatic().text("请在系统提示中允许读取已保存的微信连接。", "Allow access to the saved WeChat connection in the system prompt."))
        let request = MessageCredentialReadRequest { [weak self] result in
            guard let self, self.personalAuthorizationID == action else { return }
            self.personalAuthorizationID = nil
            self.personalAuthorizationRequest = nil
            guard self.running, self.personalWeChatEnabled, self.revisions[.personalWeChat] == revision else { return }
            self.applyStoredCredential(result, for: .personalWeChat)
        }
        personalAuthorizationRequest = request
        storage.authorizeStored(.personalWeChat, request: request)
    }

    private func applyStoredCredential(_ result: Result<MessageChannelCredential?, FeishuWebhookError>, for kind: MessageChannelKind) {
        switch result {
        case .success(let credential):
            credentials[kind] = credential
            setPhase(credential == nil ? .needsSetup : .pendingVerification, for: kind)
            if kind == .personalWeChat {
                personalWeChatNeedsAuthorization = false
                personalWeChatBindingMissing = credential == nil
                personalWeChatConnected = credential != nil
                personalAutomaticThreadID =
                    credential.flatMap { value in
                        guard let binding = value.personalBinding else { return nil }
                        return try? botLedger.conversationID(owner: binding.botID + "\u{0}" + (value.target ?? ""))
                    } ?? ""
                personalWeChatHasContext = credential?.personalBinding?.hasFreshContext() ?? false
                if !personalWeChatHasContext { setPhase(.needsSetup, for: kind) }
                let language = WidgetLanguage.storedOrAutomatic()
                setPersonalStatus(
                    credential == nil
                        ? language.text("本机没有已保存的微信连接，请扫码连接。", "No saved WeChat connection was found. Scan to connect.")
                        : personalWeChatHasContext
                            ? language.text("已恢复微信连接，可以发送测试消息。", "WeChat connection restored. You can send a test message.")
                            : MessageChannelError.weChatContextRequired.localizedDescription)
                if credential != nil { startPersonalMonitor() }
            }
        case .failure(let error):
            credentials.removeValue(forKey: kind)
            setPhase(.needsSetup, for: kind)
            if kind == .personalWeChat {
                personalWeChatConnected = false
                personalWeChatHasContext = false
                personalWeChatBindingMissing = false
                if case .keychainAuthorizationRequired = error { personalWeChatNeedsAuthorization = true }
                setPersonalStatus(Self.credentialStatus(error, for: kind))
            } else {
                statusText = Self.credentialStatus(error, for: kind)
            }
        }
    }

    private func setPersonalStatus(_ text: String) {
        personalWeChatStatusText = text
        statusText = text
    }

    private func setStatus(_ text: String, for kind: MessageChannelKind) {
        if kind == .personalWeChat { setPersonalStatus(text) } else { statusText = text }
    }

    private static func credentialStatus(_ error: FeishuWebhookError, for kind: MessageChannelKind) -> String {
        let language = WidgetLanguage.storedOrAutomatic()
        let name = kind.displayName(language)
        switch error {
        case .keychainAuthorizationRequired:
            return language.text("\(name)连接需要钥匙串授权，请点击“恢复连接”并允许访问。", "\(name) needs Keychain permission. Choose Restore connection and allow access.")
        case .keychainTimedOut:
            return language.text("读取\(name)连接超时，请重试恢复连接；已保存的绑定未删除。", "Reading the \(name) connection timed out. Retry restoring it; the saved binding was not deleted.")
        case .keychainBusy:
            return language.text("\(name)连接仍在等待系统响应，请稍后重试。", "\(name) is still waiting for the system. Try again shortly.")
        case .keychain(let code):
            return language.text("无法读取\(name)已保存的连接（\(code)），请重试恢复连接。", "Could not read the saved \(name) connection (\(code)). Retry restoring it.")
        default:
            return language.text("\(name)已保存的连接无法读取，请重试恢复连接或重新扫码。", "Could not read the saved \(name) connection. Retry restoring it or scan again.")
        }
    }

    func save(secret: String, target: String?, for kind: MessageChannelKind, completion: @escaping (Bool) -> Void) {
        guard !actionInFlight, !personalLoginInProgress else {
            completion(false)
            return
        }
        let value: MessageChannelCredential
        do { value = try MessageChannelCredential(secret: secret, target: target).validated(for: kind) } catch {
            statusText = error.localizedDescription
            completion(false)
            return
        }
        credentialWriteInFlight = true
        invalidate(kind)
        let revision = revisions[kind]
        storage.save(value, for: kind) { [weak self] result in
            guard let self else {
                completion((try? result.get()) != nil)
                return
            }
            self.credentialWriteInFlight = false
            switch result {
            case .success:
                if self.revisions[kind] == revision {
                    self.credentials[kind] = value
                    self.setPhase(self.isEnabled(kind) ? .pendingVerification : .disabled, for: kind)
                }
                self.statusText = WidgetLanguage.storedOrAutomatic().text("配置已保存，请发送测试消息验证。", "Saved. Send a test message to verify the configuration.")
                completion(true)
            case .failure(let error):
                self.statusText = error.localizedDescription
                completion(false)
            }
        }
    }

    /// Readiness only; never exposes credentials or loads Keychain on this path.
    @MainActor
    func publicResetRevision(_ kind: MessageChannelKind) -> UUID? {
        guard running, isEnabled(kind), !credentialWriteInFlight,
            let value = credentials[kind], (try? value.validated(for: kind)) != nil
        else { return nil }
        if kind == .personalWeChat,
            !personalWeChatConnected || !personalWeChatHasContext || value.personalBinding?.hasFreshContext() != true
        {
            return nil
        }
        return revisions[kind]
    }

    /// Await the official adapter result, not the ordinary fire-and-forget queue.
    @MainActor
    func sendPublicReset(
        _ announcement: PublicResetAnnouncement, to kind: MessageChannelKind,
        revision: UUID, shouldSend: @escaping () -> Bool
    ) async -> Result<MessageDeliveryOutcome, MessageChannelError> {
        guard publicResetRevision(kind) == revision, shouldSend(),
            let value = credentials[kind],
            let context = try? PublicResetContext(announcement: announcement),
            let status = try? MessageTaskStatus(
                eventKind: announcement.resetType == .regular ? .publicRegularReset : .publicBankedReset,
                occurredAt: Date(), publicResetContext: context)
        else { return .failure(.cancelled) }
        let frozen = FrozenMessageChannelCredential(kind: kind, value: value)
        let valid = { self.publicResetRevision(kind) == revision && shouldSend() }
        let result: Result<MessageDeliveryOutcome, MessageChannelError>
        switch kind {
        case .telegram:
            result = await TelegramMessageChannel(credentials: frozen, transport: transport()).send(status, shouldSend: valid)
        case .weChat:
            result = await WeChatMessageChannel(
                credentials: frozen, transport: transport(),
                messageOptions: weChatMessageOptions
            ).send(status, shouldSend: valid)
        case .personalWeChat:
            let personalWeChatValid: @MainActor () -> Bool = {
                self.publicResetRevision(kind) == revision && shouldSend()
            }
            result = await PersonalWeChatMessageChannel(transport: transport()).send(
                status,
                credential: value, options: weChatMessageOptions, shouldSend: personalWeChatValid)
        }
        guard valid(), !Task.isCancelled else { return .failure(.cancelled) }
        return result
    }

    @MainActor
    func recordPublicResetChannelResult(_ result: PublicResetChannelResult) {
        statusText = result.statusText
    }

    func sendTest(_ kind: MessageChannelKind) {
        guard !actionInFlight,
            let status = try? MessageTaskStatus(eventKind: .test, occurredAt: Date())
        else { return }
        send(status, to: kind, explicit: true)
    }

    func sendPersonalWeChatText(_ text: String, completion: @escaping (Bool) -> Void = { _ in }) {
        let kind = MessageChannelKind.personalWeChat
        guard running, personalWeChatEnabled, !actionInFlight, !personalLoginInProgress,
            personalWeChatConnected, personalWeChatHasContext, let value = credentials[kind]
        else {
            completion(false)
            return
        }
        let eventID = UUID()
        do {
            _ = try PersonalWeChatMessageChannel.textRequest(text, eventID: eventID, credential: value)
        } catch {
            setPersonalStatus(error.localizedDescription)
            completion(false)
            return
        }
        let revision = revisions[kind]
        let selectedTransport = transport()
        explicitTest = (kind, eventID)
        tasks[kind, default: [:]][eventID] = Task { @MainActor [weak self] in
            var accepted = false
            defer { completion(accepted) }
            guard let self else { return }
            defer {
                if self.revisions[kind] == revision { self.tasks[kind]?.removeValue(forKey: eventID) }
                if self.explicitTest?.id == eventID { self.explicitTest = nil }
            }
            let valid: @MainActor () -> Bool = { self.running && self.personalWeChatEnabled && self.revisions[kind] == revision }
            guard valid(), !Task.isCancelled else { return }
            let channel = PersonalWeChatMessageChannel(transport: selectedTransport, deduplicator: self.personalWeChatEvents)
            let result = await channel.sendText(text, eventID: eventID, credential: value, shouldSend: valid)
            guard valid(), !Task.isCancelled else { return }
            switch result {
            case .success(.accepted):
                accepted = true
                self.setPhase(.ready, for: kind)
                self.setPersonalStatus(WidgetLanguage.storedOrAutomatic().text("个人微信 API 已接收文本。", "Personal WeChat API accepted the text."))
            case .success(.duplicateSkipped): break
            case .failure(let error):
                if error == .weChatSessionExpired {
                    self.stopPersonalConnection()
                    self.credentials.removeValue(forKey: kind)
                    self.personalWeChatConnected = false
                    self.personalWeChatHasContext = false
                    self.invalidate(kind)
                } else {
                    self.setPhase(.pendingVerification, for: kind)
                }
                self.setPersonalStatus(error.localizedDescription)
            }
        }
    }

    func observeTaskSnapshot(_ snapshot: CodexTaskLiveSnapshot) {
        guard running else { return }
        updatePersonalChatTargets(snapshot)
        for kind in MessageChannelKind.allCases {
            guard isEnabled(kind), credentials[kind] != nil, !credentialWriteInFlight else {
                completionObservers.removeValue(forKey: kind)
                continue
            }
            var observer = completionObservers[kind] ?? FeishuTaskCompletionObserver()
            let completions = observer.observe(snapshot, now: Date())
            completionObservers[kind] = observer
            for completion in completions {
                guard
                    let status = try? MessageTaskStatus(
                        eventKind: .taskStateChange,
                        taskLabel: MessageChannelTaskLabel("Codex"), taskState: .completed,
                        occurredAt: completion.occurredAt)
                else { continue }
                send(status, to: kind)
            }
        }
    }

    func send(_ status: MessageTaskStatus) {
        for kind in MessageChannelKind.allCases { send(status, to: kind) }
    }

    private func send(_ status: MessageTaskStatus, to kind: MessageChannelKind, explicit: Bool = false) {
        guard running, isEnabled(kind), !credentialWriteInFlight, let value = credentials[kind] else { return }
        let messageOptions = weChatMessageOptions
        guard let status = kind != .telegram ? status.selectingQuotaWindows(messageOptions) : status else { return }
        if kind == .personalWeChat,
            !personalWeChatConnected || !personalWeChatHasContext || value.personalBinding?.hasFreshContext() != true
        {
            personalWeChatHasContext = false
            setPhase(.needsSetup, for: kind)
            if explicit { setPersonalStatus(MessageChannelError.weChatContextRequired.localizedDescription) }
            return
        }
        guard tasks[kind]?[status.eventID] == nil else { return }
        let automaticCount = (tasks[kind]?.count ?? 0) - (explicitTest?.kind == kind ? 1 : 0)
        guard explicit || automaticCount < 4 else {
            statusText = WidgetLanguage.storedOrAutomatic().text("当前发送请求过多，本条未发送。", "Too many sends are in progress; this event was not sent.")
            return
        }
        let revision = revisions[kind]
        let credential = FrozenMessageChannelCredential(kind: kind, value: value)
        let selectedTransport = transport()
        if explicit { explicitTest = (kind, status.eventID) }
        tasks[kind, default: [:]][status.eventID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.revisions[kind] == revision {
                    self.tasks[kind]?.removeValue(forKey: status.eventID)
                }
                if self.explicitTest?.id == status.eventID { self.explicitTest = nil }
            }
            guard self.running, !Task.isCancelled, self.revisions[kind] == revision else { return }
            let result: Result<MessageDeliveryOutcome, MessageChannelError>
            switch kind {
            case .telegram:
                let channel = TelegramMessageChannel(credentials: credential, transport: selectedTransport, deduplicator: self.telegramEvents)
                result = await channel.send(status)
            case .weChat:
                let channel = WeChatMessageChannel(
                    credentials: credential, transport: selectedTransport,
                    deduplicator: self.weChatEvents, messageOptions: messageOptions)
                result = await channel.send(status)
            case .personalWeChat:
                let channel = PersonalWeChatMessageChannel(transport: selectedTransport, deduplicator: self.personalWeChatEvents)
                result = await channel.send(
                    status, credential: value, options: messageOptions,
                    shouldSend: { @MainActor in self.running && self.personalWeChatEnabled && self.revisions[kind] == revision })
            }
            guard self.running, !Task.isCancelled, self.isEnabled(kind), self.revisions[kind] == revision else { return }
            switch result {
            case .success(.accepted):
                self.setPhase(.ready, for: kind)
                self.setStatus(WidgetLanguage.storedOrAutomatic().text("\(kind.displayName(.zh)) API 已接收消息。", "\(kind.displayName(.en)) API accepted the message."), for: kind)
            case .success(.duplicateSkipped): break
            case .failure(let error):
                if kind == .personalWeChat, error == .weChatSessionExpired {
                    self.stopPersonalConnection()
                    self.credentials.removeValue(forKey: kind)
                    self.personalWeChatConnected = false
                    self.personalWeChatHasContext = false
                    self.invalidate(kind)
                } else {
                    self.setPhase(.pendingVerification, for: kind)
                }
                self.setStatus(error.localizedDescription, for: kind)
            }
        }
    }

    private func stopPersonalConnection() {
        cancelPersonalBotTasks()
        personalMessagesNotBefore = .distantFuture
        personalConnectionEpoch = UUID()
        personalMonitor?.cancel()
        personalMonitor = nil
        personalLogin?.cancel()
        personalLogin = nil
        personalLoginInProgress = false
        personalLoginQRCode = nil
        personalLoginNeedsCode = false
        personalVerificationCode = nil
    }

    func cancelPersonalWeChatLogin() {
        if personalAuthorizationID != nil {
            // Security owns its dialog. Invalidate the result, but retain the
            // busy token until it returns so retries cannot stack prompts.
            invalidate(.personalWeChat)
            setPersonalStatus(
                WidgetLanguage.storedOrAutomatic().text("已停止恢复连接；若系统授权窗口仍打开，请在其中取消。", "Recovery was stopped. If the system authorization dialog is still open, cancel it there."))
            return
        }
        guard personalLoginInProgress, !credentialWriteInFlight else { return }
        stopPersonalConnection()
        if running && personalWeChatEnabled { load(.personalWeChat) }
    }

    func submitPersonalWeChatCode(_ code: String) {
        guard personalLoginInProgress, personalLoginNeedsCode,
            code.range(of: "^[0-9]{4,10}$", options: .regularExpression) != nil
        else { return }
        personalVerificationCode = code
        personalLoginNeedsCode = false
    }

    func connectPersonalWeChat() {
        guard running, personalWeChatEnabled, !actionInFlight else { return }
        stopPersonalConnection()
        credentials.removeValue(forKey: .personalWeChat)
        personalAutomaticThreadID = ""
        personalWeChatConnected = false
        invalidate(.personalWeChat)
        personalLoginInProgress = true
        let epoch = personalConnectionEpoch
        let channel = PersonalWeChatMessageChannel(transport: personalTransport())
        personalLogin = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.personalConnectionEpoch == epoch {
                    self.personalLoginInProgress = false
                    self.personalLoginQRCode = nil
                    self.personalLoginNeedsCode = false
                    self.personalVerificationCode = nil
                    self.personalLogin = nil
                }
            }
            do {
                let qr = try await channel.startLogin()
                guard !Task.isCancelled, self.personalConnectionEpoch == epoch else { return }
                self.personalLoginQRCode = qr.content
                self.setPersonalStatus(WidgetLanguage.storedOrAutomatic().text("用手机微信扫一扫，并确认连接。", "Scan with WeChat on your phone and confirm the connection."))
                var base = PersonalWeChatMessageChannel.defaultBaseURL
                let deadline = Date().addingTimeInterval(5 * 60)
                while Date() < deadline, !Task.isCancelled, self.personalConnectionEpoch == epoch {
                    let code = self.personalVerificationCode
                    self.personalVerificationCode = nil
                    let status = try await channel.pollLogin(reference: qr.reference, base: base, verificationCode: code)
                    guard !Task.isCancelled, self.personalConnectionEpoch == epoch else { return }
                    switch status {
                    case .waiting: break
                    case .scanned:
                        self.setPersonalStatus(WidgetLanguage.storedOrAutomatic().text("已扫码，请在手机上确认。", "Scanned. Confirm on your phone."))
                    case .redirect(let url): base = url
                    case .needsVerificationCode:
                        self.personalLoginNeedsCode = true
                        self.setPersonalStatus(WidgetLanguage.storedOrAutomatic().text("输入手机微信显示的配对码。", "Enter the pairing code shown on your phone."))
                    case .expired, .verificationBlocked:
                        self.setPersonalStatus(WidgetLanguage.storedOrAutomatic().text("二维码或配对码已失效，请重新扫码。", "The QR or pairing code expired. Scan again."))
                        return
                    case .alreadyBound:
                        self.setPersonalStatus(
                            WidgetLanguage.storedOrAutomatic().text("服务端未签发新凭据；正在核对本机已有连接。", "No new credential was issued. Checking the existing local connection."))
                        self.load(.personalWeChat)
                        return
                    case .confirmed(let credential):
                        guard !self.credentialWriteInFlight else { throw FeishuWebhookError.keychainBusy }
                        self.personalLoginQRCode = nil
                        self.credentialWriteInFlight = true
                        let saved: Result<Void, FeishuWebhookError> = await withCheckedContinuation { callback in
                            self.storage.save(credential, for: .personalWeChat) { callback.resume(returning: $0) }
                        }
                        self.credentialWriteInFlight = false
                        guard self.running, self.personalWeChatEnabled, self.personalConnectionEpoch == epoch else { return }
                        try saved.get()
                        self.credentials[.personalWeChat] = credential
                        self.personalAutomaticThreadID =
                            (try? self.botLedger.conversationID(
                                owner: (credential.personalBinding?.botID ?? "") + "\u{0}" + (credential.target ?? ""))) ?? ""
                        self.personalWeChatConnected = true
                        self.personalWeChatNeedsAuthorization = false
                        self.personalWeChatBindingMissing = false
                        self.invalidate(.personalWeChat)
                        self.setPersonalStatus(MessageChannelError.weChatContextRequired.localizedDescription)
                        self.startPersonalMonitor()
                        self.onConfigurationChanged?()
                        return
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if !Task.isCancelled { self.setPersonalStatus(WidgetLanguage.storedOrAutomatic().text("扫码已超时，请重新连接。", "QR login timed out. Reconnect.")) }
            } catch {
                guard !Task.isCancelled, self.personalConnectionEpoch == epoch else { return }
                self.setPersonalStatus((error as? FeishuWebhookError).map { Self.credentialStatus($0, for: .personalWeChat) } ?? error.localizedDescription)
            }
        }
    }

    private func startPersonalMonitor() {
        personalMonitor?.cancel()
        personalMessagesNotBefore = Date()
        let epoch = personalConnectionEpoch
        let channel = PersonalWeChatMessageChannel(transport: personalTransport())
        personalMonitor = Task { @MainActor [weak self] in
            guard let self else { return }
            var failures = 0
            while self.running, self.personalWeChatEnabled, self.personalConnectionEpoch == epoch,
                !Task.isCancelled, let credential = self.credentials[.personalWeChat]
            {
                do {
                    let update = try await channel.updates(credential)
                    guard !Task.isCancelled, self.personalConnectionEpoch == epoch,
                        self.credentials[.personalWeChat]?.secret == credential.secret
                    else { return }
                    if failures > 0 {
                        self.setPersonalStatus(
                            WidgetLanguage.storedOrAutomatic().text(
                                "微信消息连接已恢复。", "WeChat message connection restored."))
                    }
                    failures = 0
                    let current = MessageChannelCredential(secret: credential.secret, target: credential.target, personalBinding: update.binding)
                    self.credentials[.personalWeChat] = current
                    let previouslyHadContext = self.personalWeChatHasContext
                    self.personalWeChatHasContext = update.binding.hasFreshContext()
                    if !previouslyHadContext && self.personalWeChatHasContext {
                        self.setPersonalStatus(WidgetLanguage.storedOrAutomatic().text("微信会话已就绪，可以发送测试消息。", "WeChat conversation is ready. You can send a test message."))
                    }
                    if update.binding != credential.personalBinding {
                        self.invalidate(.personalWeChat)
                        self.storage.saveBackground(current, for: .personalWeChat) { [weak self] result in
                            guard let self, self.personalConnectionEpoch == epoch else { return }
                            if case .failure = result {
                                self.setPersonalStatus(
                                    WidgetLanguage.storedOrAutomatic().text(
                                        "会话只在本次运行中可用；钥匙串未保存更新。", "The session is available for this run; the Keychain update was not saved."))
                            }
                        }
                        if update.contextChanged { self.onConfigurationChanged?() }
                    } else if !self.personalWeChatHasContext {
                        self.setPhase(.needsSetup, for: .personalWeChat)
                    }
                    self.handlePersonalMessages(update.messages)
                } catch {
                    guard !Task.isCancelled, self.personalConnectionEpoch == epoch else { return }
                    failures += 1
                    let issue = error as? MessageChannelError ?? .transportFailed
                    if issue == .weChatSessionExpired {
                        self.credentials.removeValue(forKey: .personalWeChat)
                        self.personalWeChatConnected = false
                        self.personalWeChatHasContext = false
                        self.invalidate(.personalWeChat)
                        self.setPersonalStatus(issue.localizedDescription)
                        return
                    }
                    self.setPersonalStatus(issue.localizedDescription)
                    // Malformed polling responses are retried with the saved cursor.
                    // They do not prove that the QR login has expired.
                    if issue == .redirected || issue == .httpStatus(401) || issue == .httpStatus(403) {
                        if failures >= 3 {
                            self.stopPersonalConnection()
                            self.credentials.removeValue(forKey: .personalWeChat)
                            self.personalWeChatConnected = false
                            self.personalWeChatHasContext = false
                            self.invalidate(.personalWeChat)
                            return
                        }
                    }
                }
                do { try await Task.sleep(nanoseconds: UInt64(min(30, failures == 0 ? 1 : 5 * failures)) * 1_000_000_000) } catch { return }
            }
        }
    }

    func refreshPersonalChatTargets() {
        personalTargetsRefreshedAt = .distantPast
        onRefreshPersonalChatTargets?()
    }

    private func updatePersonalChatTargets(_ snapshot: CodexTaskLiveSnapshot) {
        guard snapshot.connectionMode != .disconnected,
            Date().timeIntervalSince(personalTargetsRefreshedAt) >= 60
        else { return }
        personalTargetsRefreshedAt = Date()
        personalChatTargets = snapshot.records.values
            .filter { UUID(uuidString: $0.threadID) != nil }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(100).map {
                let name = ($0.name ?? "Codex").components(separatedBy: .controlCharacters).joined(separator: " ")
                return WeChatCodexConversationTarget(
                    id: $0.threadID,
                    title: String(name.prefix(80)))
            }
    }

    private enum PersonalChatResolution {
        case ready(String)
        case unavailable
        case uncertain
    }

    @MainActor
    private func resolvePersonalChat(owner: String, valid: @escaping () -> Bool) async -> PersonalChatResolution {
        if !personalChatThreadID.isEmpty { return .ready(personalChatThreadID) }
        do {
            if let existing = try botLedger.conversationID(owner: owner) {
                personalAutomaticThreadID = existing
                return .ready(existing)
            }
            guard let create = onCreatePersonalChat, valid(), !Task.isCancelled else { return .unavailable }
            switch try botLedger.reserveConversation(owner: owner) {
            case .bound(let thread):
                personalAutomaticThreadID = thread
                return .ready(thread)
            case .uncertain: return .uncertain
            case .create: break
            }
            let admission = WeChatCodexSendAdmission()
            let result = await withTaskCancellationHandler(
                operation: { await create(admission) }, onCancel: { admission.cancel() })
            switch result {
            case .created(let thread):
                // Save even if the user disabled/rebound while creation was in
                // flight. The old owner's ID is retained, but no turn is sent.
                try botLedger.bindConversation(owner: owner, threadID: thread)
                guard valid(), !Task.isCancelled else { return .unavailable }
                personalAutomaticThreadID = thread
                refreshPersonalChatTargets()
                return .ready(thread)
            case .unavailable:
                try botLedger.releaseUnsentConversation(owner: owner)
                return .unavailable
            case .uncertain: return .uncertain
            }
        } catch { return .uncertain }
    }

    @MainActor
    private func handlePersonalMessages(_ messages: [PersonalWeChatMessageChannel.IncomingMessage]) {
        guard running, personalWeChatEnabled, personalWeChatConnected,
            let binding = credentials[.personalWeChat]?.personalBinding
        else { return }
        let owner = binding.botID + "\u{0}" + (credentials[.personalWeChat]?.target ?? "")
        for message in messages where message.receivedAt >= personalMessagesNotBefore {
            guard personalBotTasks.count < 8 else { break }
            let claimed: UUID?
            do { claimed = try botLedger.claim(owner: owner, messageID: message.id, receivedAt: message.receivedAt) } catch {
                setPersonalStatus("微信消息去重记录不可用，已暂停该消息。")
                continue
            }
            guard let id = claimed else { continue }
            let epoch = personalChatEpoch
            let connectionEpoch = personalConnectionEpoch
            personalBotTasks[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.personalChatEpoch == epoch {
                        self.personalBotTasks.removeValue(forKey: id)
                        if self.personalChatMessageID == id { self.personalChatMessageID = nil }
                        self.personalBotIsReplying = self.personalChatMessageID != nil
                    }
                }
                let valid: @MainActor () -> Bool = {
                    self.running && self.personalWeChatEnabled && self.personalWeChatConnected
                        && self.personalChatEpoch == epoch && self.personalConnectionEpoch == connectionEpoch
                }
                guard valid(), !Task.isCancelled else { return }
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let reply: String
                if text.hasPrefix("/") {
                    let command = text.lowercased()
                    if ["/帮助", "/help"].contains(command) {
                        reply = Self.personalBotHelp
                    } else if let local = self.onPersonalBotCommand?(command) {
                        reply = local
                    } else {
                        reply = Self.personalBotHelp
                    }
                } else if !self.personalChatEnabled || message.receivedAt < self.personalChatNotBefore {
                    reply = "Codex 对话尚未启用。请在电脑上的微信机器人设置中开启对话；默认自动建立专用对话。\n" + Self.personalBotHelp
                } else if self.personalChatMessageID != nil {
                    reply = "这个 Codex 聊天正在处理任务，请等结束后再发消息。"
                } else {
                    self.personalChatMessageID = id
                    self.personalBotIsReplying = true
                    let automatic = self.personalChatThreadID.isEmpty
                    let resolved = await self.resolvePersonalChat(owner: owner, valid: valid)
                    guard valid(), !Task.isCancelled else { return }
                    switch resolved {
                    case .unavailable:
                        reply = "暂时无法连接 Codex，请在电脑上打开 Codex 后再发消息。专用对话尚未创建。"
                    case .uncertain:
                        reply = "微信专用对话的创建结果待核对，已停止自动新建。请在电脑上检查 Codex，或在微信设置中选择已有对话。"
                    case .ready(let thread):
                        if self.personalConversation == nil { self.personalConversation = self.conversationFactory() }
                        guard let conversation = self.personalConversation else { return }
                        let outcome = await conversation.reply(
                            threadID: thread, eventID: id, text: text,
                            shouldContinue: valid,
                            openDedicatedThread: automatic ? { self.onOpenPersonalChatThread?(thread) ?? false } : nil,
                            onSubmitted: { turn in
                                do {
                                    try self.botLedger.mark(id, phase: .submitted, threadID: thread, turnID: turn)
                                    return true
                                } catch { return false }
                            })
                        guard valid(), !Task.isCancelled else { return }
                        switch outcome {
                        case .reply(let answer): reply = answer
                        case .busy: reply = "这个 Codex 聊天正在处理任务，请等结束后再发消息。"
                        case .awaitingHuman: reply = "Codex 需要你在电脑上确认或补充信息，请打开原聊天处理。"
                        case .unavailable: reply = "暂时无法连接或读取所选 Codex 原聊天，请在电脑上打开它后再试。"
                        case .failed: reply = "本次 Codex 任务失败，请在电脑上查看原聊天。"
                        case .interrupted: reply = "本次 Codex 任务已中断，请在电脑上查看原聊天。"
                        case .timedOut: reply = "Codex 仍未返回最终结果，请在电脑上查看原聊天；这条消息不会自动重发。"
                        case .uncertain:
                            try? self.botLedger.mark(id, phase: .uncertain)
                            reply = "本次提交结果不确定，请在电脑上查看原聊天；这条消息不会自动重发。"
                        case .cancelled: return
                        }
                    }
                }
                guard valid(), !Task.isCancelled,
                    let credential = self.credentials[.personalWeChat],
                    credential.personalBinding?.hasFreshContext() == true
                else { return }
                do { try self.botLedger.mark(id, phase: .replyAttempted) } catch {
                    self.setPersonalStatus("微信回复记录未能保存，已暂停发送。")
                    return
                }
                let result = await PersonalWeChatMessageChannel(transport: self.transport()).sendText(
                    Self.boundedPersonalReply(reply), eventID: id, credential: credential, shouldSend: valid)
                switch result {
                case .success(.accepted): try? self.botLedger.mark(id, phase: .accepted)
                case .success(.duplicateSkipped): break
                case .failure(let error):
                    try? self.botLedger.mark(id, phase: .uncertain)
                    if valid(), !Task.isCancelled {
                        self.setPersonalStatus(error.localizedDescription)
                    }
                }
            }
        }
    }

    private static let personalBotHelp = "微信机器人：开启对话后，首次发文字自动建立专用 Codex 对话，以后固定续聊；也可在电脑上选择已有对话。\n/状态 查看连接和任务数量\n/任务 查看需要关注的任务\n/重置卡 查看最新重置卡\n/帮助 查看说明\n审批和登录请在电脑上完成。"

    static func boundedPersonalReply(_ text: String) -> String {
        guard text.utf8.count > 4096 else { return text }
        let footer = "\n\n（内容较长，全文请在 Codex 原聊天查看。）"
        var prefix = ""
        let budget = 4096 - footer.utf8.count
        for character in text {
            guard prefix.utf8.count + String(character).utf8.count <= budget else { break }
            prefix.append(character)
        }
        return prefix + footer
    }
}
