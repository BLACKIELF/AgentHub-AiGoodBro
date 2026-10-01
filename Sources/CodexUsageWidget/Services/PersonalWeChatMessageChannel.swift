import Foundation

/// Protocol adapted from Tencent/openclaw-weixin 2.4.9, commit
/// 24de5c9eb0dd5e595d7e2d090ed8a3f82870d42c. See Resources/THIRD_PARTY_NOTICES.txt.
/// Only the scanner's own conversation is used. Incoming text stays in memory
/// for a bot reply; the encrypted binding contains no message bodies.
struct PersonalWeChatBinding: Codable, Equatable {
    let baseURL: URL
    let botID: String
    let contextToken: String?
    let contextCheckedAt: Date?
    let updatesCursor: String

    init(
        baseURL: URL, botID: String, contextToken: String? = nil,
        contextCheckedAt: Date? = nil, updatesCursor: String = ""
    ) {
        self.baseURL = baseURL
        self.botID = botID
        self.contextToken = contextToken
        self.contextCheckedAt = contextCheckedAt
        self.updatesCursor = updatesCursor
    }

    func validated() throws -> Self {
        let base = try PersonalWeChatMessageChannel.validatedBaseURL(baseURL)
        let bot = try PersonalWeChatMessageChannel.validatedID(botID)
        guard updatesCursor.utf8.count <= 8192,
            updatesCursor.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
            (contextToken == nil) == (contextCheckedAt == nil),
            contextCheckedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw MessageChannelError.invalidCredential }
        if let contextToken { _ = try PersonalWeChatMessageChannel.validatedToken(contextToken, limit: 8192) }
        return Self(
            baseURL: base, botID: bot, contextToken: contextToken,
            contextCheckedAt: contextCheckedAt, updatesCursor: updatesCursor)
    }

    /// A local conservative guard, not a claim about the server's token TTL.
    func hasFreshContext(now: Date = Date()) -> Bool {
        guard contextToken != nil, let contextCheckedAt else { return false }
        let age = now.timeIntervalSince(contextCheckedAt)
        return age.isFinite && age >= -60 && age <= 24 * 3600
    }
}

final class PersonalWeChatMessageChannel {
    static let defaultBaseURL = URL(string: "https://ilinkai.weixin.qq.com")!
    static let protocolVersion = "2.4.9"
    static let documentation = URL(string: "https://github.com/Tencent/openclaw-weixin/blob/24de5c9eb0dd5e595d7e2d090ed8a3f82870d42c/docs/protocol_zh_CN.md")!

    struct LoginQR {
        let reference: String
        let content: String
    }
    enum LoginStatus {
        case waiting, scanned, expired, needsVerificationCode, verificationBlocked, alreadyBound
        case redirect(URL)
        case confirmed(MessageChannelCredential)
    }
    struct IncomingMessage: Equatable {
        let id: String
        let text: String
        let receivedAt: Date
    }
    struct Updates {
        let binding: PersonalWeChatBinding
        let contextChanged: Bool
        let messages: [IncomingMessage]
    }

    private let transport: MessageChannelTransport
    private let deduplicator: MessageEventDeduplicator

    init(transport: MessageChannelTransport, deduplicator: MessageEventDeduplicator = MessageEventDeduplicator()) {
        self.transport = transport
        self.deduplicator = deduplicator
    }

    static func validatedToken(_ value: String, limit: Int = 4096) throws -> String {
        guard !value.isEmpty, value.utf8.count <= limit,
            value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 })
        else { throw MessageChannelError.invalidCredential }
        return value
    }

    static func validatedID(_ value: String) throws -> String {
        guard value.range(of: "^[A-Za-z0-9@._-]{1,256}$", options: .regularExpression) != nil else {
            throw MessageChannelError.invalidTarget
        }
        return value
    }

    static func validatedBaseURL(_ value: URL) throws -> URL {
        guard let parts = URLComponents(url: value, resolvingAgainstBaseURL: false),
            parts.scheme == "https", let host = parts.host?.lowercased(),
            host.range(of: "^ilink[a-z0-9-]*\\.weixin\\.qq\\.com$", options: .regularExpression) != nil,
            parts.port == nil || parts.port == 443,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty || parts.path == "/",
            let base = URL(string: "https://" + host)
        else { throw MessageChannelError.invalidCredential }
        return base
    }

    private static func request(
        base: URL, path: String, token: String? = nil,
        query: [URLQueryItem] = [], body: [String: Any]? = nil,
        timeout: TimeInterval = 15, includeBaseInfo: Bool = true
    ) throws -> URLRequest {
        var parts = URLComponents(url: try validatedBaseURL(base), resolvingAgainstBaseURL: false)!
        parts.path = "/ilink/bot/" + path
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw MessageChannelError.encodingFailed }
        var result = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        result.httpMethod = body == nil ? "GET" : "POST"
        result.setValue("bot", forHTTPHeaderField: "iLink-App-Id")
        result.setValue(String((2 << 16) | (4 << 8) | 9), forHTTPHeaderField: "iLink-App-ClientVersion")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        if var body {
            result.setValue("application/json", forHTTPHeaderField: "Content-Type")
            result.setValue("ilink_bot_token", forHTTPHeaderField: "AuthorizationType")
            let uin = Data(String(UInt32.random(in: .min ... .max)).utf8).base64EncodedString()
            result.setValue(uin, forHTTPHeaderField: "X-WECHAT-UIN")
            if let token { result.setValue("Bearer " + (try validatedToken(token)), forHTTPHeaderField: "Authorization") }
            if includeBaseInfo {
                body["base_info"] = ["channel_version": protocolVersion, "bot_agent": "AiGoodBro/9.6.45"]
            }
            result.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        }
        return result
    }

    static func qrRequest() throws -> URLRequest {
        try request(
            base: defaultBaseURL, path: "get_bot_qrcode", query: [URLQueryItem(name: "bot_type", value: "3")],
            body: ["local_token_list": [String]()], includeBaseInfo: false)
    }

    static func loginStatusRequest(reference: String, base: URL = defaultBaseURL, verificationCode: String? = nil) throws -> URLRequest {
        _ = try validatedToken(reference)
        var query = [URLQueryItem(name: "qrcode", value: reference)]
        if let verificationCode {
            guard verificationCode.range(of: "^[0-9]{4,10}$", options: .regularExpression) != nil else {
                throw MessageChannelError.invalidStatus
            }
            query.append(URLQueryItem(name: "verify_code", value: verificationCode))
        }
        return try request(base: base, path: "get_qrcode_status", query: query, timeout: 40)
    }

    static func updatesRequest(_ credential: MessageChannelCredential) throws -> URLRequest {
        let credential = try credential.validated(for: .personalWeChat)
        return try request(
            base: credential.personalBinding!.baseURL, path: "getupdates", token: credential.secret,
            body: ["get_updates_buf": credential.personalBinding!.updatesCursor], timeout: 40)
    }

    static func messageRequest(
        status: MessageTaskStatus, credential: MessageChannelCredential,
        options: FeishuMessageOptions = .standard, language: WidgetLanguage = .storedOrAutomatic(),
        now: Date = Date()
    ) throws -> URLRequest {
        let age = now.timeIntervalSince(status.occurredAt)
        guard age.isFinite, age >= 0, age <= 120 else { throw MessageChannelError.staleStatus }
        // The shared formatter receives only the existing masked status DTO.
        let text = WeChatMessageChannel.messageContent(status: status, options: options, language: language, markdown: false)
        return try textRequest(text, eventID: status.eventID, credential: credential, now: now)
    }

    static func textRequest(
        _ text: String, eventID: UUID, credential: MessageChannelCredential,
        now: Date = Date()
    ) throws -> URLRequest {
        let credential = try credential.validated(for: .personalWeChat)
        let binding = credential.personalBinding!
        guard binding.hasFreshContext(now: now) else { throw MessageChannelError.weChatContextRequired }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\n" || $0 == "\t" })
        else { throw MessageChannelError.invalidStatus }
        guard text.utf8.count <= WeChatMessageChannel.contentByteLimit else {
            throw MessageChannelError.messageTooLong(limit: WeChatMessageChannel.contentByteLimit)
        }
        let msg: [String: Any] = [
            "from_user_id": "", "to_user_id": credential.target!,
            "client_id": "aigoodbro-" + eventID.uuidString.lowercased(), "message_type": 2, "message_state": 2,
            "context_token": binding.contextToken!, "item_list": [["type": 1, "text_item": ["text": text]]],
        ]
        return try request(base: binding.baseURL, path: "sendmessage", token: credential.secret, body: ["msg": msg])
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    // JSONSerialization preserves uint64 integers in NSNumber. Never convert
    // message IDs through Double, which merges distinct IDs above 2^53.
    private static func messageID(_ value: Any?) -> String? {
        if let value = value as? String {
            return (try? validatedToken(value, limit: 256)) == nil ? nil : value
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let value = UInt64(number.stringValue), value > 0
        else { return nil }
        return String(value)
    }

    static func responseObject(
        _ data: Data, http: HTTPURLResponse, request: URLRequest,
        requiresAcceptance: Bool
    ) throws -> [String: Any] {
        guard http.url == request.url else { throw MessageChannelError.redirected }
        guard !(300..<400).contains(http.statusCode) else { throw MessageChannelError.redirected }
        if http.statusCode == 429 { throw MessageChannelError.rateLimited(retryAfterSeconds: nil) }
        guard (200..<300).contains(http.statusCode) else { throw MessageChannelError.httpStatus(http.statusCode) }
        guard data.count <= URLSessionMessageChannelTransport.maximumResponseBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw MessageChannelError.invalidResponse }
        let ret = integer(object["ret"])
        let code = integer(object["errcode"])
        if object["ret"] != nil && ret == nil || object["errcode"] != nil && code == nil { throw MessageChannelError.invalidResponse }
        if ret == -14 || code == -14 { throw MessageChannelError.weChatSessionExpired }
        if let failure = [ret, code].compactMap({ $0 }).first(where: { $0 != 0 }) {
            throw MessageChannelError.rejected(code: failure, description: nil)
        }
        // Successful protobuf JSON can omit every default field, including ret.
        // For sends accept an empty success object or a server message ID too;
        // an unrelated object is still not a delivery acknowledgement.
        guard
            !requiresAcceptance || ret == 0 || code == 0 || object.isEmpty
                || messageID(object["message_id"]) != nil
        else { throw MessageChannelError.invalidResponse }
        return object
    }

    private func fetch(_ request: URLRequest, requiresAcceptance: Bool = false) async throws -> [String: Any] {
        do {
            let (data, http) = try await transport.send(request)
            try Task.checkCancellation()
            return try Self.responseObject(data, http: http, request: request, requiresAcceptance: requiresAcceptance)
        } catch is CancellationError {
            throw MessageChannelError.cancelled
        } catch let error as MessageChannelError {
            throw error
        } catch { throw MessageChannelError.transportFailed }
    }

    func startLogin() async throws -> LoginQR {
        let object = try await fetch(Self.qrRequest())
        guard let reference = object["qrcode"] as? String, let content = object["qrcode_img_content"] as? String,
            !content.isEmpty, content.utf8.count <= 4096,
            !content.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw MessageChannelError.invalidResponse }
        _ = try Self.validatedToken(reference)
        return LoginQR(reference: reference, content: content)
    }

    func pollLogin(reference: String, base: URL, verificationCode: String?) async throws -> LoginStatus {
        let object = try await fetch(Self.loginStatusRequest(reference: reference, base: base, verificationCode: verificationCode))
        switch object["status"] as? String {
        case "wait": return .waiting
        case "scaned": return .scanned
        case "expired": return .expired
        case "need_verifycode": return .needsVerificationCode
        case "verify_code_blocked": return .verificationBlocked
        case "binded_redirect": return .alreadyBound
        case "scaned_but_redirect":
            guard let host = object["redirect_host"] as? String, let url = URL(string: "https://" + host) else { throw MessageChannelError.invalidResponse }
            return .redirect(try Self.validatedBaseURL(url))
        case "confirmed":
            guard let token = object["bot_token"] as? String, let bot = object["ilink_bot_id"] as? String,
                let user = object["ilink_user_id"] as? String,
                let base = URL(string: object["baseurl"] as? String ?? Self.defaultBaseURL.absoluteString)
            else { throw MessageChannelError.invalidResponse }
            return .confirmed(
                try MessageChannelCredential(
                    secret: token, target: user,
                    personalBinding: PersonalWeChatBinding(baseURL: base, botID: bot)
                ).validated(for: .personalWeChat))
        default: throw MessageChannelError.invalidResponse
        }
    }

    func updates(_ credential: MessageChannelCredential, now: Date = Date()) async throws -> Updates {
        let object = try await fetch(Self.updatesRequest(credential), requiresAcceptance: false)
        return try Self.bindingFromUpdates(object, credential: credential, now: now)
    }

    static func bindingFromUpdates(_ object: [String: Any], credential: MessageChannelCredential, now: Date) throws -> Updates {
        let credential = try credential.validated(for: .personalWeChat)
        let old = credential.personalBinding!
        var token = old.contextToken
        var checkedAt = old.contextCheckedAt
        var incoming: [IncomingMessage] = []
        // iLink omits zero-valued status fields on successful polling responses.
        // Validate the endpoint payload separately; sending still requires acceptance.
        guard object["msgs"] == nil || object["msgs"] is [[String: Any]],
            object["get_updates_buf"] == nil || object["get_updates_buf"] is String
        else { throw MessageChannelError.invalidResponse }
        let messages = object["msgs"] as? [[String: Any]] ?? []
        guard messages.count <= 256 else { throw MessageChannelError.invalidResponse }
        for message in messages {
            guard integer(message["message_type"]) == 1,
                message["from_user_id"] as? String == credential.target,
                message["to_user_id"] == nil || message["to_user_id"] as? String == old.botID,
                let candidate = message["context_token"] as? String,
                (try? validatedToken(candidate, limit: 8192)) != nil,
                let timestamp = integer(message["create_time_ms"]),
                timestamp > 0
            else { continue }
            let receivedAt = Date(timeIntervalSince1970: Double(timestamp) / 1000)
            let age = now.timeIntervalSince(receivedAt)
            guard age >= -60, age <= 24 * 3600 else { continue }
            if receivedAt >= (checkedAt ?? .distantPast) {
                token = candidate
                checkedAt = receivedAt
            }
            // Old cursor backlog can refresh the notification context but must
            // never become a delayed Codex instruction. Only complete text
            // messages with an explicit recipient and stable server ID qualify.
            guard age >= -5, age <= 120,
                message["to_user_id"] as? String == old.botID,
                integer(message["message_state"]) == 2,
                let id = messageID(message["message_id"]),
                (try? validatedToken(id, limit: 256)) != nil,
                let items = message["item_list"] as? [[String: Any]], !items.isEmpty, items.count <= 8,
                items.allSatisfy({ integer($0["type"]) == 1 })
            else { continue }
            let parts = items.compactMap { ($0["text_item"] as? [String: Any])?["text"] as? String }
            let text = parts.joined(separator: "\n").replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard parts.count == items.count, !text.isEmpty, text.utf8.count <= 4096,
                text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\n" || $0 == "\t" })
            else { continue }
            incoming.append(IncomingMessage(id: id, text: text, receivedAt: receivedAt))
        }
        let cursor = object["get_updates_buf"] as? String
        let binding = try PersonalWeChatBinding(
            baseURL: old.baseURL, botID: old.botID, contextToken: token,
            contextCheckedAt: checkedAt, updatesCursor: cursor?.isEmpty == false ? cursor! : old.updatesCursor
        ).validated()
        return Updates(
            binding: binding,
            contextChanged: token != old.contextToken || checkedAt != old.contextCheckedAt,
            messages: incoming.sorted { $0.receivedAt < $1.receivedAt })
    }

    /// Replies are attempted once. A lost API response cannot trigger another
    /// send in this process; the bot controller also journals the attempt.
    func sendText(
        _ text: String, eventID: UUID, credential: MessageChannelCredential,
        shouldSend: @escaping () -> Bool = { true }
    ) async -> Result<MessageDeliveryOutcome, MessageChannelError> {
        guard shouldSend(), !Task.isCancelled else { return .failure(.cancelled) }
        switch deduplicator.begin(eventID) {
        case .duplicate: return .success(.duplicateSkipped)
        case .atCapacity: return .failure(.rateLimited(retryAfterSeconds: nil))
        case .reserved: break
        }
        defer { deduplicator.release(eventID) }
        do {
            let request = try Self.textRequest(text, eventID: eventID, credential: credential)
            guard shouldSend(), !Task.isCancelled else { return .failure(.cancelled) }
            deduplicator.claim(eventID)
            _ = try await fetch(request, requiresAcceptance: true)
            return .success(.accepted(MessageDeliveryReceipt(acceptedAt: Date(), remoteMessageID: nil)))
        } catch let error as MessageChannelError {
            return .failure(error)
        } catch { return .failure(.encodingFailed) }
    }

    func send(
        _ status: MessageTaskStatus, credential: MessageChannelCredential, options: FeishuMessageOptions,
        shouldSend: @escaping () -> Bool = { true }
    ) async -> Result<MessageDeliveryOutcome, MessageChannelError> {
        guard shouldSend(), !Task.isCancelled else { return .failure(.cancelled) }
        switch deduplicator.begin(status.eventID) {
        case .duplicate: return .success(.duplicateSkipped)
        case .atCapacity: return .failure(.rateLimited(retryAfterSeconds: nil))
        case .reserved: break
        }
        defer { deduplicator.release(status.eventID) }
        do {
            let request = try Self.messageRequest(status: status, credential: credential, options: options)
            _ = try await fetch(request, requiresAcceptance: true)
            guard shouldSend(), !Task.isCancelled else { return .failure(.cancelled) }
            deduplicator.claim(status.eventID)
            return .success(.accepted(MessageDeliveryReceipt(acceptedAt: Date(), remoteMessageID: nil)))
        } catch let error as MessageChannelError {
            return .failure(error)
        } catch { return .failure(.encodingFailed) }
    }
}
