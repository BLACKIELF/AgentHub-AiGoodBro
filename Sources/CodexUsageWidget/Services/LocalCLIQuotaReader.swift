import CoreFoundation
import CryptoKit
import Foundation
import Security

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct LocalCLIHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

protocol LocalCLIQuotaTransport: Sendable {
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse
}

private enum LocalCLIReaderFailure: Error {
    case credentialsMissing
    case credentialsExpired
    case invalidCredentials
    case invalidResponse
    case responseTooLarge
    case unauthorized
    case rateLimited
    case keychainUnavailable
    case unavailable
}

private final class LocalCLIURLSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalCLIHTTPResponse, Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var terminalError: Error?
    private var finished = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func start(request: URLRequest, session: URLSession) async throws -> LocalCLIHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            record(error: LocalCLIReaderFailure.invalidResponse)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            record(error: LocalCLIReaderFailure.responseTooLarge)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        if data.count > maximumBytes - chunk.count {
            terminalError = LocalCLIReaderFailure.responseTooLarge
            lock.unlock()
            dataTask.cancel()
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let storedError = terminalError ?? error
        let storedResponse = response
        let storedData = data
        lock.unlock()
        if let storedError {
            finish(.failure(storedError))
        } else if let storedResponse {
            var headers: [String: String] = [:]
            for (key, value) in storedResponse.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
            finish(
                .success(
                    LocalCLIHTTPResponse(
                        statusCode: storedResponse.statusCode,
                        headers: headers,
                        data: storedData)))
        } else {
            finish(.failure(LocalCLIReaderFailure.invalidResponse))
        }
    }

    private func record(error: Error) {
        lock.lock()
        terminalError = error
        lock.unlock()
    }

    private func finish(_ result: Result<LocalCLIHTTPResponse, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

struct LocalCLIURLSessionTransport: LocalCLIQuotaTransport {
    private static let maximumResponseBytes = 1_048_576

    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        let delegate = LocalCLIURLSessionDelegate(maximumBytes: Self.maximumResponseBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await delegate.start(request: request, session: session)
    }
}

struct LocalCLIQuotaReader {
    typealias FileReader = (URL, Int, Bool) throws -> Data?
    typealias ClaudeKeychainReader = () throws -> Data?

    private static let maximumCredentialBytes = 1_048_576
    typealias UpstreamReader = (LocalCLIProfile, Date) async throws -> LocalCLIQuotaResult
    private let upstreamReader: UpstreamReader?
    private let transport: any LocalCLIQuotaTransport
    private let fileReader: FileReader
    private let claudeKeychainReader: ClaudeKeychainReader

    init(
        transport: (any LocalCLIQuotaTransport)? = nil,
        fileReader: FileReader? = nil,
        claudeKeychainReader: ClaudeKeychainReader? = nil,
        upstreamReader: UpstreamReader? = nil
    ) {
        self.upstreamReader =
            upstreamReader
            ?? (transport == nil && fileReader == nil && claudeKeychainReader == nil
                ? { profile, now in try await TokenMonitorLocalCLIQuotaReader().load(profile: profile, now: now) } : nil)
        self.transport = transport ?? LocalCLIURLSessionTransport()
        self.fileReader =
            fileReader ?? { url, maximumBytes, allowMissing in
                try DispatchParticipationSync.readBoundedRegularFile(
                    url,
                    maximumBytes: maximumBytes,
                    allowMissing: allowMissing)
            }
        self.claudeKeychainReader = claudeKeychainReader ?? Self.readDefaultClaudeKeychain
    }

    func load(profile: LocalCLIProfile, now: Date = Date()) async -> LocalCLIQuotaResult {
        if profile.kind == .openCode, let upstreamReader {
            do {
                try Task.checkCancellation()
                return try await upstreamReader(profile, now)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? TokenMonitorFailure) == .cancelled {
                    return result(state: .unavailable, now: now, source: TokenMonitorLocalCLIQuotaReader.sourceLabel, messageCode: "local_cli_cancelled")
                }
                if case TokenMonitorLocalCLIQuotaReader.Failure.rejected(let reason) = error {
                    return result(
                        state: .unavailable, now: now, source: TokenMonitorLocalCLIQuotaReader.sourceLabel,
                        messageCode: "local_cli_upstream_" + reason.rawValue)
                }
                if let failure = error as? TokenMonitorFailure,
                    ![.missingBundle, .timedOut, .spawnFailed, .processFailed, .engineError].contains(failure)
                {
                    return result(
                        state: .unavailable, now: now, source: TokenMonitorLocalCLIQuotaReader.sourceLabel,
                        messageCode: "local_cli_upstream_" + failure.rawValue)
                }
                let reason: String
                if case TokenMonitorLocalCLIQuotaReader.Failure.unavailable(let value) = error {
                    reason = value.rawValue
                } else {
                    reason = (error as? TokenMonitorFailure)?.rawValue ?? "engine_error"
                }
                guard !Task.isCancelled else {
                    return result(state: .unavailable, now: now, source: TokenMonitorLocalCLIQuotaReader.sourceLabel, messageCode: "local_cli_cancelled")
                }
                let native = await loadNative(profile: profile, now: now)
                guard !Task.isCancelled else {
                    return result(state: .unavailable, now: now, source: TokenMonitorLocalCLIQuotaReader.sourceLabel, messageCode: "local_cli_cancelled")
                }
                return LocalCLIQuotaResult(
                    state: native.state, fetchedAt: native.fetchedAt, maskedIdentity: native.maskedIdentity,
                    identityFingerprint: native.identityFingerprint, planLabel: native.planLabel, windows: native.windows,
                    balance: native.balance, balanceCurrency: native.balanceCurrency,
                    sourceLabel: "OpenCode Go native fallback (" + reason + ")", messageCode: native.messageCode)
            }
        }
        return await loadNative(profile: profile, now: now)
    }

    private func loadNative(profile: LocalCLIProfile, now: Date) async -> LocalCLIQuotaResult {
        do {
            switch profile.kind {
            case .grok:
                return try await loadGrok(profile: profile, now: now)
            case .kimi:
                return try await loadKimi(profile: profile, now: now)
            case .claudeCode:
                return try await loadClaude(profile: profile, now: now)
            case .openCode:
                return try await loadOpenCode(profile: profile, now: now)
            case .mimo, .zcode, .gemini, .trae, .workBuddy, .antigravity:
                return result(
                    state: .unsupported,
                    now: now,
                    source: profile.kind.displayName,
                    messageCode: "local_cli_unsupported")
            }
        } catch let failure as LocalCLIReaderFailure {
            return failureResult(failure, kind: profile.kind, now: now)
        } catch {
            return result(
                state: .unavailable,
                now: now,
                source: sourceLabel(for: profile.kind),
                messageCode: "local_cli_unavailable")
        }
    }

    private func loadGrok(profile: LocalCLIProfile, now: Date) async throws -> LocalCLIQuotaResult {
        let root = try Self.object(credentialData(profile: profile, relativePath: "auth.json"))
        let candidates = root.compactMap { key, value -> (String, [String: Any])? in
            guard let entry = value as? [String: Any], Self.nonempty(entry["key"]) != nil else { return nil }
            guard key.hasPrefix("https://auth.x.ai::") || key == "https://accounts.x.ai/sign-in" else {
                return nil
            }
            return (key, entry)
        }
        guard candidates.count == 1,
            let entry = candidates.first?.1,
            let token = Self.nonempty(entry["key"])
        else {
            throw LocalCLIReaderFailure.invalidCredentials
        }
        if let rawExpiry = entry["expires_at"] {
            guard let expiry = Self.parseDate(rawExpiry), expiry > now else {
                throw LocalCLIReaderFailure.credentialsExpired
            }
        }

        let identity = Self.nonempty(entry["user_id"]) ?? Self.nonempty(entry["email"])
        var request = fixedRequest("https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        if let userID = Self.nonempty(entry["user_id"]) {
            let headerID = Self.asciiHeader(userID, fallback: "")
            if !headerID.isEmpty { request.setValue(headerID, forHTTPHeaderField: "x-userid") }
        }
        request.setValue("CodexUsageWidget-Next", forHTTPHeaderField: "User-Agent")
        let response = try await checkedResponse(for: request)
        let parsed = try Self.parseGrok(response.data)
        return result(
            state: .available,
            now: now,
            identity: identity,
            fingerprintKind: .grok,
            plan: parsed.plan,
            windows: parsed.windows,
            balance: parsed.balanceUSD,
            currency: parsed.balanceUSD == nil ? nil : "USD",
            source: sourceLabel(for: .grok),
            messageCode: parsed.windows.isEmpty ? "local_cli_usage_not_reported" : nil,
            resetCards: parsed.resetCards,
            periodResetsAt: parsed.periodResetsAt)
    }

    private func loadKimi(profile: LocalCLIProfile, now: Date) async throws -> LocalCLIQuotaResult {
        let root = try Self.object(
            credentialData(
                profile: profile,
                relativePath: "credentials/kimi-code.json"))
        guard let token = Self.nonempty(root["access_token"]) else {
            throw LocalCLIReaderFailure.credentialsMissing
        }
        guard let expiry = Self.strictDouble(root["expires_at"], allowString: true) else {
            throw LocalCLIReaderFailure.invalidCredentials
        }
        guard expiry > now.addingTimeInterval(60).timeIntervalSince1970 else {
            throw LocalCLIReaderFailure.credentialsExpired
        }
        guard
            let deviceData = try fileReader(
                directoryURL(profile).appendingPathComponent("device_id"),
                Self.maximumCredentialBytes,
                true),
            let deviceID = String(data: deviceData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !deviceID.isEmpty
        else {
            throw LocalCLIReaderFailure.invalidCredentials
        }

        var request = fixedRequest("https://api.kimi.com/coding/v1/usages")
        let version = Self.asciiHeader(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionLabel = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let requestDeviceID = Self.asciiHeader(deviceID, fallback: "")
        guard !requestDeviceID.isEmpty else { throw LocalCLIReaderFailure.invalidCredentials }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi_code_cli", forHTTPHeaderField: "X-Msh-Platform")
        request.setValue(version, forHTTPHeaderField: "X-Msh-Version")
        request.setValue(Self.asciiHeader(ProcessInfo.processInfo.hostName), forHTTPHeaderField: "X-Msh-Device-Name")
        request.setValue("macOS \(osVersionLabel) \(Self.architectureName)", forHTTPHeaderField: "X-Msh-Device-Model")
        request.setValue(osVersionLabel, forHTTPHeaderField: "X-Msh-Os-Version")
        request.setValue(requestDeviceID, forHTTPHeaderField: "X-Msh-Device-Id")
        request.setValue("CodexUsageWidget-Next", forHTTPHeaderField: "User-Agent")
        let response = try await checkedResponse(for: request)
        let parsed = try Self.parseKimi(response.data)
        let identity = Self.nonempty(root["user_id"]) ?? Self.jwtIdentity(token)
        return result(
            state: .available,
            now: now,
            identity: identity,
            fingerprintKind: .kimi,
            plan: parsed.plan,
            windows: parsed.windows,
            source: sourceLabel(for: .kimi))
    }

    private func loadClaude(profile: LocalCLIProfile, now: Date) async throws -> LocalCLIQuotaResult {
        // Selected directories are isolated deliberately. This adapter never falls back to
        // Claude Code's default Keychain identity or prompts for Keychain access.
        let credentialsURL = directoryURL(profile).appendingPathComponent(".credentials.json")
        var credentialsData: Data
        var loadedKeychain = false
        if let fileData = try fileReader(credentialsURL, Self.maximumCredentialBytes, true) {
            credentialsData = fileData
        } else if isDefaultClaudeDirectory(profile) {
            do {
                guard let keychainData = try claudeKeychainReader() else {
                    throw LocalCLIReaderFailure.credentialsMissing
                }
                guard keychainData.count <= Self.maximumCredentialBytes else {
                    throw LocalCLIReaderFailure.invalidCredentials
                }
                credentialsData = keychainData
                loadedKeychain = true
            } catch let failure as LocalCLIReaderFailure {
                throw failure
            } catch {
                throw LocalCLIReaderFailure.keychainUnavailable
            }
        } else {
            throw LocalCLIReaderFailure.credentialsMissing
        }
        var oauth = try Self.claudeOAuth(credentialsData)
        if !Self.claudeTokenIsFresh(oauth, now: now), !loadedKeychain, isDefaultClaudeDirectory(profile) {
            // An old credentials file can outlive the CLI's current Keychain
            // login. Only the actual default environment may use that identity.
            do {
                if let freshData = try claudeKeychainReader() {
                    guard freshData.count <= Self.maximumCredentialBytes else {
                        throw LocalCLIReaderFailure.invalidCredentials
                    }
                    credentialsData = freshData
                    oauth = try Self.claudeOAuth(credentialsData)
                }
            } catch let failure as LocalCLIReaderFailure {
                throw failure
            } catch {
                throw LocalCLIReaderFailure.keychainUnavailable
            }
        }
        guard Self.claudeTokenIsFresh(oauth, now: now) else { throw LocalCLIReaderFailure.credentialsExpired }
        guard let token = Self.nonempty(oauth["accessToken"]) else { throw LocalCLIReaderFailure.invalidCredentials }
        var request = fixedRequest("https://api.anthropic.com/api/oauth/usage")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        let response = try await checkedResponse(for: request)
        let windows = try Self.parseClaude(response.data)
        return result(
            state: .available,
            now: now,
            plan: Self.nonempty(oauth["subscriptionType"]) ?? Self.nonempty(oauth["rateLimitTier"]),
            windows: windows,
            source: sourceLabel(for: .claudeCode))
    }

    private func loadOpenCode(profile: LocalCLIProfile, now: Date) async throws -> LocalCLIQuotaResult {
        let root = try Self.object(credentialData(profile: profile, relativePath: "auth.json"))
        guard let rawEntry = root["opencode-go"] else {
            guard !root.isEmpty else { throw LocalCLIReaderFailure.credentialsMissing }
            // auth.json may contain valid provider identities without OpenCode Go.
            // That means only this quota adapter is unavailable, not that OpenCode
            // itself is signed out.
            return result(
                state: .unsupported,
                now: now,
                source: sourceLabel(for: .openCode),
                messageCode: "local_cli_opencode_go_not_connected")
        }
        guard let entry = rawEntry as? [String: Any],
            Self.nonempty(entry["type"])?.lowercased() == "api",
            let key = Self.nonempty(entry["key"])
        else { throw LocalCLIReaderFailure.invalidCredentials }
        var request = fixedRequest("https://opencode.ai/zen/go/v1/usage")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexUsageWidget-Next", forHTTPHeaderField: "User-Agent")
        let response = try await checkedResponse(for: request)
        let windows = try Self.parseOpenCode(response.data)
        return result(
            state: .available,
            now: now,
            windows: windows,
            source: sourceLabel(for: .openCode))
    }

    private func checkedResponse(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil else {
            throw LocalCLIReaderFailure.invalidResponse
        }
        let response: LocalCLIHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch let failure as LocalCLIReaderFailure {
            throw failure
        } catch {
            throw LocalCLIReaderFailure.unavailable
        }
        guard response.data.count <= Self.maximumCredentialBytes else {
            throw LocalCLIReaderFailure.responseTooLarge
        }
        switch response.statusCode {
        case 200: return response
        case 401, 403: throw LocalCLIReaderFailure.unauthorized
        case 429: throw LocalCLIReaderFailure.rateLimited
        default: throw LocalCLIReaderFailure.unavailable
        }
    }

    private func credentialData(profile: LocalCLIProfile, relativePath: String) throws -> Data {
        guard
            let data = try fileReader(
                directoryURL(profile).appendingPathComponent(relativePath),
                Self.maximumCredentialBytes,
                true)
        else { throw LocalCLIReaderFailure.credentialsMissing }
        return data
    }

    private func directoryURL(_ profile: LocalCLIProfile) -> URL {
        URL(fileURLWithPath: profile.configDirectory, isDirectory: true).standardizedFileURL
    }

    private func isDefaultClaudeDirectory(_ profile: LocalCLIProfile) -> Bool {
        guard profile.kind == .claudeCode, profile.isDefault else { return false }
        let expected = LocalCLIKind.claudeCode.defaultConfigDirectory(
            home: FileManager.default.homeDirectoryForCurrentUser
        ).standardizedFileURL
        return directoryURL(profile) == expected
    }

    private func fixedRequest(_ value: String) -> URLRequest {
        var request = URLRequest(url: URL(string: value)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func failureResult(_ failure: LocalCLIReaderFailure, kind: LocalCLIKind, now: Date)
        -> LocalCLIQuotaResult
    {
        switch failure {
        case .credentialsMissing, .credentialsExpired:
            result(state: .needsLogin, now: now, source: sourceLabel(for: kind), messageCode: "local_cli_needs_login")
        case .unauthorized:
            result(state: .unavailable, now: now, source: sourceLabel(for: kind), messageCode: "local_cli_authorization_unverified")
        case .rateLimited:
            result(state: .rateLimited, now: now, source: sourceLabel(for: kind), messageCode: "local_cli_rate_limited")
        case .invalidCredentials:
            result(state: .unavailable, now: now, source: sourceLabel(for: kind), messageCode: "local_cli_invalid_credentials")
        case .invalidResponse, .responseTooLarge:
            result(state: .unavailable, now: now, source: sourceLabel(for: kind), messageCode: "local_cli_invalid_response")
        case .keychainUnavailable:
            result(state: .unavailable, now: now, source: sourceLabel(for: kind), messageCode: "local_cli_keychain_unavailable")
        case .unavailable:
            result(state: .unavailable, now: now, source: sourceLabel(for: kind), messageCode: "local_cli_unavailable")
        }
    }

    private func result(
        state: LocalCLIQuotaState,
        now: Date,
        identity: String? = nil,
        fingerprintKind: LocalCLIKind? = nil,
        plan: String? = nil,
        windows: [LocalCLIQuotaWindow] = [],
        balance: Double? = nil,
        currency: String? = nil,
        source: String,
        messageCode: String? = nil,
        resetCards: [LocalCLIResetCard]? = nil,
        periodResetsAt: Date? = nil
    ) -> LocalCLIQuotaResult {
        let safeIdentity = LocalCLIQuotaPresentation.validIdentity(identity)
        let validWindows = LocalCLIQuotaPresentation.validWindows(windows)
        return LocalCLIQuotaResult(
            state: validWindows ? state : .unavailable,
            fetchedAt: now,
            maskedIdentity: safeIdentity.map(LocalCLIQuotaPresentation.maskedIdentity),
            identityFingerprint: safeIdentity.flatMap { value in
                fingerprintKind.map { Self.fingerprint(kind: $0, identity: value) }
            },
            planLabel: LocalCLIQuotaPresentation.boundedLabel(plan),
            windows: validWindows ? windows : [],
            balance: balance,
            balanceCurrency: currency,
            sourceLabel: source,
            messageCode: validWindows ? messageCode : "local_cli_invalid_response",
            resetCards: resetCards,
            resetCardsObservedAt: resetCards == nil ? nil : now,
            periodResetsAt: periodResetsAt)
    }

    private func sourceLabel(for kind: LocalCLIKind) -> String {
        switch kind {
        case .grok: "Grok CLI billing"
        case .kimi: "Kimi Code API"
        case .claudeCode: "Anthropic OAuth usage"
        case .openCode: "OpenCode Go API"
        case .mimo, .zcode, .gemini, .trae, .workBuddy, .antigravity: kind.displayName
        }
    }

    private static func readDefaultClaudeKeychain() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecAttrAccount: NSUserName(),
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw LocalCLIReaderFailure.keychainUnavailable }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw LocalCLIReaderFailure.keychainUnavailable
        }
    }
}

extension LocalCLIQuotaReader {
    private static func claudeOAuth(_ data: Data) throws -> [String: Any] {
        guard let oauth = try object(data)["claudeAiOauth"] as? [String: Any],
            nonempty(oauth["accessToken"]) != nil
        else { throw LocalCLIReaderFailure.invalidCredentials }
        return oauth
    }

    private static func claudeTokenIsFresh(_ oauth: [String: Any], now: Date) -> Bool {
        guard let expiry = strictDouble(oauth["expiresAt"]) else { return false }
        return expiry > now.timeIntervalSince1970 * 1_000
    }

    /// Parses the official `GET /v1/billing?format=credits` response. Per
    /// review-inputs/grok-reset-schema-0911v1.json, the current response carries
    /// no reset-card fields, so resetCards remains nil (unknown). Website reset
    /// status is merged separately after an exact account-fingerprint match.
    /// `currentPeriod.end`, `billingPeriodEnd` and quota reset values feed quota
    /// windows and the independently known period boundary only; mapping them
    /// to a reset-card expiry is prohibited.
    static func parseGrok(_ data: Data) throws -> (
        plan: String?, windows: [LocalCLIQuotaWindow], resetCards: [LocalCLIResetCard]?, balanceUSD: Double?, periodResetsAt: Date?
    ) {
        let root = try object(data)
        guard let config = root["config"] as? [String: Any] else {
            throw LocalCLIReaderFailure.invalidResponse
        }
        let plan = nonempty(config["subscriptionTier"]) ?? nonempty(root["subscriptionTier"])
        let resetsAt =
            ((config["currentPeriod"] as? [String: Any]).flatMap { parseDate($0["end"]) })
            ?? parseDate(config["billingPeriodEnd"])
        let percent: Double?
        if let rawPercent = config["creditUsagePercent"], !(rawPercent is NSNull) {
            percent = try requiredPercent(rawPercent)
        } else if let cap = try grokCents(config["monthlyLimit"]), cap > 0,
            let used = try grokCents(config["used"]), used >= 0
        {
            // Only the legacy included budget describes subscription usage.
            // onDemandCap/onDemandUsed are a different balance entirely.
            percent = try validatedPercent(used / cap * 100)
        } else {
            percent = nil
        }
        let periodType = (config["currentPeriod"] as? [String: Any])?["type"] as? String
        let label =
            periodType == "USAGE_PERIOD_TYPE_WEEKLY"
            ? "7-day"
            : periodType == "USAGE_PERIOD_TYPE_MONTHLY" ? "Monthly" : "Credits"
        let windows =
            percent.map {
                [LocalCLIQuotaWindow(id: "credits", label: label, usedPercent: $0, resetsAt: resetsAt)]
            } ?? []
        // xai-org/grok-build's credit bar displays the absolute prepaid ledger
        // balance in dollars. Zero is a known balance, not a missing field.
        let balance = try grokCents(config["prepaidBalance"]).map { abs($0) / 100 }
        return (plan, windows, nil, balance, resetsAt)
    }

    private static func grokCents(_ raw: Any?) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let amount = raw as? [String: Any] else { throw LocalCLIReaderFailure.invalidResponse }
        // Proto3 JSON represents a present zero-valued Cent as {}.
        guard let rawValue = amount["val"] else { return 0 }
        guard let value = strictDouble(rawValue), value.rounded() == value,
            abs(value) <= 9_007_199_254_740_991
        else { throw LocalCLIReaderFailure.invalidResponse }
        return value
    }

    static func parseKimi(_ data: Data) throws -> (plan: String?, windows: [LocalCLIQuotaWindow]) {
        let root = try object(data)
        let plan = nonempty(root["planName"]) ?? nonempty(root["plan_name"])
        var windows: [LocalCLIQuotaWindow] = []
        // The current endpoint also returns named ratio pools. Keep all three
        // independent windows, including the monthly pool, and never fill a
        // missing usage ratio with zero.
        if let rawPools = root["usages"], !(rawPools is NSNull) {
            guard let pools = rawPools as? [String: Any] else { throw LocalCLIReaderFailure.invalidResponse }
            for (key, id, label) in [("limit_5h", "session", "5-hour"), ("limit_7d", "weekly", "7-day"), ("limit_month_total", "monthly", "Monthly")] {
                guard let raw = pools[key], !(raw is NSNull) else { continue }
                guard let pool = raw as? [String: Any] else { throw LocalCLIReaderFailure.invalidResponse }
                guard let rawRatio = pool["used_ratio"], !(rawRatio is NSNull) else { continue }
                guard let ratio = strictDouble(rawRatio), ratio >= 0 else { throw LocalCLIReaderFailure.invalidResponse }
                windows.append(
                    LocalCLIQuotaWindow(
                        id: id, label: label, usedPercent: min(1, ratio) * 100, resetsAt: parseDate(pool["reset_time"])))
            }
        }
        guard !windows.isEmpty || root.keys.contains("usage") || root.keys.contains("limits") else {
            throw LocalCLIReaderFailure.invalidResponse
        }
        // A migration response may provide only one new pool. Fill the other
        // kinds from legacy windows; a new pool wins only for its own kind.
        if !windows.contains(where: { $0.id == "weekly" }) {
            if let usage = root["usage"] as? [String: Any] {
                windows.append(try quotaWindow(id: "weekly", label: "7-day", detail: usage))
            } else if root["usage"] != nil && !(root["usage"] is NSNull) {
                throw LocalCLIReaderFailure.invalidResponse
            }
        }
        if let rawLimits = root["limits"] {
            guard let limits = rawLimits as? [[String: Any]] else {
                if !(rawLimits is NSNull) { throw LocalCLIReaderFailure.invalidResponse }
                return (plan, windows)
            }
            for (index, item) in limits.enumerated() {
                let detail = (item["detail"] as? [String: Any]) ?? item
                let minutes = try kimiWindowMinutes(item["window"])
                let label: String
                if minutes == 300 { label = "5-hour" } else if minutes == 10_080 { label = "7-day" } else { label = "Usage" }
                let id = minutes == 300 ? "session" : minutes == 10_080 ? "weekly" : "limit-\(index)-\(minutes ?? 0)"
                guard !windows.contains(where: { $0.id == id }) else { continue }
                windows.append(try quotaWindow(id: id, label: label, detail: detail))
            }
        }
        return (plan, windows)
    }

    static func parseClaude(_ data: Data) throws -> [LocalCLIQuotaWindow] {
        let root = try object(data)
        var windows: [LocalCLIQuotaWindow] = []
        let known: [(String, String)] = [
            ("five_hour", "5-hour"),
            ("seven_day", "7-day"),
            ("seven_day_oauth_apps", "7-day OAuth apps"),
            ("seven_day_opus", "7-day Opus"),
            ("seven_day_sonnet", "7-day Sonnet"),
        ]
        for (key, label) in known where root.keys.contains(key) {
            guard let raw = root[key] else { continue }
            if raw is NSNull { continue }
            guard let window = raw as? [String: Any] else { throw LocalCLIReaderFailure.invalidResponse }
            guard let utilization = window["utilization"], !(utilization is NSNull) else { continue }
            windows.append(
                LocalCLIQuotaWindow(
                    id: key,
                    label: label,
                    usedPercent: try requiredPercent(utilization),
                    resetsAt: parseDate(window["resets_at"])))
        }
        if let rawLimits = root["limits"] {
            guard let limits = rawLimits as? [[String: Any]] else {
                if !(rawLimits is NSNull) { throw LocalCLIReaderFailure.invalidResponse }
                return windows
            }
            for (index, limit) in limits.enumerated() {
                if let rawActive = limit["is_active"] {
                    guard let active = strictBool(rawActive) else {
                        throw LocalCLIReaderFailure.invalidResponse
                    }
                    if !active { continue }
                }
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])
                let label = nonempty(model?["display_name"]) ?? nonempty(limit["kind"]) ?? "Scoped usage"
                guard let percent = limit["percent"], !(percent is NSNull) else { continue }
                windows.append(
                    LocalCLIQuotaWindow(
                        id: "limit-\(index)",
                        label: label,
                        usedPercent: try requiredPercent(percent),
                        resetsAt: parseDate(limit["resets_at"])))
            }
        }
        return windows
    }

    static func parseOpenCode(_ data: Data) throws -> [LocalCLIQuotaWindow] {
        let root = try object(data)
        guard let usage = root["usage"] as? [String: Any] else {
            throw LocalCLIReaderFailure.invalidResponse
        }
        let definitions = [("rolling", "Rolling"), ("weekly", "7-day"), ("monthly", "Monthly")]
        var windows: [LocalCLIQuotaWindow] = []
        for (key, label) in definitions where usage.keys.contains(key) {
            guard let raw = usage[key] else { continue }
            if raw is NSNull { continue }
            guard let window = raw as? [String: Any] else { throw LocalCLIReaderFailure.invalidResponse }
            let percent: Double
            if nonempty(window["status"]) == "rate-limited" {
                if let supplied = window["percent"] { _ = try requiredPercent(supplied) }
                percent = 100
            } else {
                percent = try requiredPercent(window["percent"])
            }
            windows.append(
                LocalCLIQuotaWindow(
                    id: key,
                    label: label,
                    usedPercent: percent,
                    resetsAt: parseDate(window["resetsAt"])))
        }
        return windows
    }

    private static func quotaWindow(id: String, label: String, detail: [String: Any]) throws
        -> LocalCLIQuotaWindow
    {
        guard let limit = strictDouble(detail["limit"], allowString: true), limit > 0 else {
            throw LocalCLIReaderFailure.invalidResponse
        }
        let used: Double
        if let value = detail["used"] {
            guard let parsed = strictDouble(value, allowString: true), parsed >= 0 else {
                throw LocalCLIReaderFailure.invalidResponse
            }
            used = parsed
        } else {
            guard let remaining = strictDouble(detail["remaining"], allowString: true),
                remaining >= 0, remaining <= limit
            else { throw LocalCLIReaderFailure.invalidResponse }
            used = limit - remaining
        }
        return LocalCLIQuotaWindow(
            id: id,
            label: label,
            usedPercent: try validatedPercent(used / limit * 100),
            resetsAt: parseDate(detail["resetTime"]) ?? parseDate(detail["resetAt"])
                ?? parseDate(detail["reset_time"]) ?? parseDate(detail["reset_at"]))
    }

    private static func kimiWindowMinutes(_ raw: Any?) throws -> Int? {
        guard let raw else { return nil }
        guard let window = raw as? [String: Any],
            let duration = strictDouble(window["duration"], allowString: true),
            duration > 0, duration.rounded() == duration
        else { throw LocalCLIReaderFailure.invalidResponse }
        let multiplier: Double
        switch nonempty(window["timeUnit"]) ?? "" {
        case let unit where unit.contains("MINUTE"): multiplier = 1
        case let unit where unit.contains("HOUR"): multiplier = 60
        case let unit where unit.contains("DAY"): multiplier = 1_440
        case "": multiplier = 1
        default: throw LocalCLIReaderFailure.invalidResponse
        }
        let minutes = duration * multiplier
        guard let exactMinutes = Int(exactly: minutes) else { throw LocalCLIReaderFailure.invalidResponse }
        return exactMinutes
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else { throw LocalCLIReaderFailure.invalidResponse }
        return object
    }

    private static func nonempty(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func strictBool(_ raw: Any?) -> Bool? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func strictDouble(_ raw: Any?, allowString: Bool = false) -> Double? {
        if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            let number = value.doubleValue
            return number.isFinite ? number : nil
        }
        if allowString, let value = nonempty(raw), let number = Double(value), number.isFinite {
            return number
        }
        return nil
    }

    private static func requiredPercent(_ raw: Any?) throws -> Double {
        guard let value = strictDouble(raw) else { throw LocalCLIReaderFailure.invalidResponse }
        return try validatedPercent(value)
    }

    private static func validatedPercent(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0, value <= 100 else {
            throw LocalCLIReaderFailure.invalidResponse
        }
        return value
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = nonempty(raw) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func asciiHeader(_ raw: String, fallback: String = "unknown") -> String {
        let value = String(raw.unicodeScalars.filter { (0x20...0x7e).contains($0.value) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private static var architectureName: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    private static func jwtIdentity(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let payload = try? object(data) else { return nil }
        return nonempty(payload["user_id"]) ?? nonempty(payload["sub"])
    }

    private static func fingerprint(kind: LocalCLIKind, identity: String) -> String {
        let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data("next-local-cli:v1:\(kind.rawValue):\(normalized)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
