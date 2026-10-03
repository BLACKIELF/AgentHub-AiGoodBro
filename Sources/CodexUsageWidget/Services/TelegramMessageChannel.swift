import CryptoKit
import Foundation

/// Minimal native Telegram relay using the official Bot API `sendMessage`.
///
/// Security invariants:
/// - HTTPS only, fixed host `api.telegram.org`, fixed path shape, port 443,
///   no query, no fragment; every redirect is refused by the transport.
/// - The bot token travels only inside the request URL and is never returned,
///   displayed, logged, or embedded in an error.
/// - Requests carry the sanitized `MessageTaskStatus` DTO and nothing else:
///   no prompts, responses, paths, or raw account identifiers.
/// - Default off. Sends require the injected provider to report the channel
///   enabled, a stored credential, and a stored target; otherwise they fail
///   closed.
/// - A 2xx response only means the Bot API accepted the message; delivery to
///   a human is never promised.
final class TelegramMessageChannel {
    static let apiHost = "api.telegram.org"
    static let messageUTF16Limit = 4096

    enum ParsedResponse: Equatable {
        case accepted(MessageDeliveryReceipt)
        case rateLimited(retryAfterSeconds: Int?)
        case rejected(code: Int, description: String?)
        case invalid
    }

    private let credentials: MessageChannelCredentialProviding
    private let transport: MessageChannelTransport
    private let deduplicator: MessageEventDeduplicator
    private let maximumStatusAge: TimeInterval
    private let now: () -> Date

    /// Set after any accepted send against the live configuration; cleared
    /// when the provider stops reporting a usable configuration.
    private let verificationLock = NSLock()
    private var verified: (fingerprint: Data, revision: UInt64, receipt: MessageDeliveryReceipt)?

    private func configurationFingerprint() -> Data {
        let value = [credentials.credential(for: .telegram) ?? "", credentials.targetID(for: .telegram) ?? ""].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(value.utf8)))
    }

    var verifiedReceipt: MessageDeliveryReceipt? {
        let fingerprint = configurationFingerprint()
        let revision = credentials.revision(for: .telegram)
        verificationLock.lock()
        defer { verificationLock.unlock() }
        guard credentials.isEnabled(.telegram), verified?.fingerprint == fingerprint, verified?.revision == revision else {
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
        maximumStatusAge: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) {
        precondition(maximumStatusAge > 0)
        self.credentials = credentials
        self.transport = transport
        self.deduplicator = deduplicator
        self.maximumStatusAge = maximumStatusAge
        self.now = now
    }

    var phase: MessageChannelPhase {
        guard credentials.isEnabled(.telegram) else { return .disabled }
        guard let token = credentials.credential(for: .telegram), (try? Self.validatedBotToken(token)) != nil else {
            return .needsSetup
        }
        guard let target = credentials.targetID(for: .telegram), (try? Self.validatedChatID(target)) != nil else {
            return .needsSetup
        }
        return verifiedReceipt == nil ? .pendingVerification : .ready
    }

    /// Sends a connection-test status so the user can verify the setup.
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
        guard credentials.isEnabled(.telegram) else { return .failure(.channelDisabled) }
        let age = now().timeIntervalSince(status.occurredAt)
        guard age.isFinite, age >= 0, age <= maximumStatusAge else { return .failure(.staleStatus) }
        switch deduplicator.begin(status.eventID) {
        case .duplicate: return .success(.duplicateSkipped)
        case .atCapacity: return .failure(.rateLimited(retryAfterSeconds: nil))
        case .reserved: break
        }
        defer { deduplicator.release(status.eventID) }
        let fingerprint = configurationFingerprint()
        let revision = credentials.revision(for: .telegram)
        guard shouldSend() else { return .failure(.cancelled) }
        guard !Task.isCancelled else { return .failure(.cancelled) }

        guard let rawToken = credentials.credential(for: .telegram) else { return .failure(.missingCredential) }
        let token: String
        do { token = try Self.validatedBotToken(rawToken) } catch { return .failure(.invalidCredential) }
        guard let rawTarget = credentials.targetID(for: .telegram) else { return .failure(.missingTarget) }
        let chatID: String
        do { chatID = try Self.validatedChatID(rawTarget) } catch { return .failure(.invalidTarget) }

        let payload: Data
        do {
            payload = try Self.requestPayload(status: status, chatID: chatID)
        } catch let error as MessageChannelError {
            return .failure(error)
        } catch {
            return .failure(.encodingFailed)
        }
        guard let endpoint = Self.endpoint(token: token) else { return .failure(.invalidCredential) }

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
            // Transport errors can embed the secret URL; report without cause.
            return .failure(.transportFailed)
        }
        // A response that arrives after cancellation must not read as success.
        guard !Task.isCancelled, shouldSend(), credentials.isEnabled(.telegram),
            credentials.revision(for: .telegram) == revision, configurationFingerprint() == fingerprint
        else { return .failure(.cancelled) }

        switch http.statusCode {
        case 200..<300:
            break
        case 429:
            if case .rateLimited(let seconds) = Self.parseResponseBody(data, now: now) {
                return .failure(.rateLimited(retryAfterSeconds: seconds))
            }
            return .failure(.rateLimited(retryAfterSeconds: nil))
        default:
            return .failure(.httpStatus(http.statusCode))
        }
        switch Self.parseResponseBody(data, now: now) {
        case .accepted(let receipt):
            deduplicator.claim(status.eventID)
            recordVerification(receipt, fingerprint: fingerprint, revision: revision)
            return .success(.accepted(receipt))
        case .rateLimited(let seconds):
            return .failure(.rateLimited(retryAfterSeconds: seconds))
        case .rejected(let code, let description):
            return .failure(.rejected(code: code, description: description))
        case .invalid:
            return .failure(.invalidResponse)
        }
    }

    /// `<bot_id>:<hash>` per the official Bot API; conservative bounds.
    static func validatedBotToken(_ rawValue: String) throws -> String {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let botID = parts.first,
            let hash = parts.last,
            (5...12).contains(botID.count),
            botID.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
            (30...64).contains(hash.count),
            hash.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" })
        else {
            throw MessageChannelError.invalidCredential
        }
        return token
    }

    /// Numeric chat identifiers (groups are negative) or `@channelusername`.
    static func validatedChatID(_ rawValue: String) throws -> String {
        let target = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("-") || target.first?.isNumber == true {
            let digits = target.hasPrefix("-") ? String(target.dropFirst()) : target
            guard (1...15).contains(digits.count),
                digits.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
                digits != "0"
            else {
                throw MessageChannelError.invalidTarget
            }
            return target
        }
        let username = target.hasPrefix("@") ? String(target.dropFirst()) : target
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard (4...32).contains(username.count),
            let first = username.unicodeScalars.first,
            CharacterSet.letters.contains(first),
            username.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw MessageChannelError.invalidTarget
        }
        return "@" + username
    }

    /// Builds `https://api.telegram.org/bot<token>/sendMessage`. The result
    /// must never be logged: the token is part of the path.
    static func endpoint(token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.port = 443
        components.path = "/bot\(token)/sendMessage"
        guard components.query == nil, components.fragment == nil else { return nil }
        return components.url
    }

    static func requestPayload(status: MessageTaskStatus, chatID: String, language: WidgetLanguage = .storedOrAutomatic()) throws -> Data {
        try payload(chatID: chatID, text: status.summary(language))
    }

    static func payload(chatID: String, text: String) throws -> Data {
        guard text.utf16.count <= messageUTF16Limit else {
            throw MessageChannelError.messageTooLong(limit: messageUTF16Limit)
        }
        let payload: [String: Any] = [
            "chat_id": chatID,
            "text": text,
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

    /// Parses `{"ok":true,"result":{"message_id":123}}`,
    /// `{"ok":false,"error_code":400,"description":"..."}`, or
    /// `{"ok":false,"parameters":{"retry_after":42}}`.
    static func parseResponseBody(_ data: Data, now: () -> Date = Date.init) -> ParsedResponse {
        guard data.count <= URLSessionMessageChannelTransport.maximumResponseBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .invalid
        }
        guard let ok = object["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else { return .invalid }
        if ok.boolValue {
            guard let result = object["result"] as? [String: Any] else { return .invalid }
            var messageID: String?
            if let number = result["message_id"] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                let value = Int64(exactly: number.doubleValue)
            {
                messageID = String(value)
            }
            return .accepted(MessageDeliveryReceipt(acceptedAt: now(), remoteMessageID: messageID))
        }
        if let parameters = object["parameters"] as? [String: Any],
            let retryAfter = parameters["retry_after"] as? NSNumber,
            CFGetTypeID(retryAfter) != CFBooleanGetTypeID(),
            let value = Int(exactly: retryAfter.doubleValue)
        {
            return .rateLimited(retryAfterSeconds: min(max(value, 1), 3600))
        }
        guard let number = object["error_code"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let code = Int(exactly: number.doubleValue)
        else { return .invalid }
        // Server descriptions may reflect the secret URL or credential.
        return .rejected(code: code, description: nil)
    }
}
