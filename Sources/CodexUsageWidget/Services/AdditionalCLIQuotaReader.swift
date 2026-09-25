import CoreFoundation
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Read-only adapters for locally selected Gemini CLI, MiMo Code, ZCode, WorkBuddy, and TRAE profiles.
///
/// Gemini uses the native, already-fresh OAuth access token. This reader never refreshes or writes it.
/// MiMo, ZCode native, WorkBuddy, and TRAE stop at the source-backed support boundary described in
/// `docs/additional-cli-provider-sources.md` instead of treating API balances, desktop membership,
/// or local tokens as CLI quota.
struct AdditionalCLIQuotaReader {
    private enum Failure: Error {
        case credentialsMissing
        case credentialsExpired
        case invalidCredentials
        case invalidResponse
        case unauthorized
        case rateLimited
        case unavailable
    }

    private static let maximumBytes = 1_048_576
    private static let geminiLoadHost = "cloudcode-pa.googleapis.com"
    private static let geminiLoadPath = "/v1internal:loadCodeAssist"
    private static let geminiQuotaPath = "/v1internal:retrieveUserQuota"

    private let transport: any LocalCLIQuotaTransport
    private let fileReader: LocalCLIQuotaReader.FileReader

    init(
        transport: any LocalCLIQuotaTransport = LocalCLIURLSessionTransport(),
        fileReader: @escaping LocalCLIQuotaReader.FileReader = { url, maximumBytes, allowMissing in
            try DispatchParticipationSync.readBoundedRegularFile(
                url,
                maximumBytes: maximumBytes,
                allowMissing: allowMissing)
        }
    ) {
        self.transport = transport
        self.fileReader = fileReader
    }

    func load(profile: LocalCLIProfile, now: Date = Date()) async -> LocalCLIQuotaResult {
        do {
            switch profile.kind {
            case .gemini:
                return try await loadGemini(profile: profile, now: now)
            case .mimo:
                return try loadMiMo(profile: profile, now: now)
            case .zcode:
                return result(
                    state: .unsupported,
                    now: now,
                    source: "ZCode native account",
                    messageCode: "local_cli_zcode_native_quota_unsupported")
            case .workBuddy, .trae:
                // No confirmed official quota interface. Unknown, not needsLogin, and no I/O.
                return result(
                    state: .unsupported,
                    now: now,
                    source: sourceLabel(for: profile.kind),
                    messageCode: "local_cli_unsupported")
            case .claudeCode, .grok, .openCode, .kimi, .antigravity:
                return result(
                    state: .unsupported,
                    now: now,
                    source: profile.kind.displayName,
                    messageCode: "local_cli_adapter_not_owned")
            }
        } catch let failure as Failure {
            return failureResult(failure, kind: profile.kind, now: now)
        } catch {
            return result(
                state: .unavailable,
                now: now,
                source: sourceLabel(for: profile.kind),
                messageCode: "local_cli_unavailable")
        }
    }

    private func loadGemini(profile: LocalCLIProfile, now: Date) async throws -> LocalCLIQuotaResult {
        let settingsData = try fileReader(
            directoryURL(profile).appendingPathComponent("settings.json"),
            Self.maximumBytes,
            true)
        if let settingsData {
            let settings = try Self.object(settingsData, failure: .invalidCredentials)
            if let selectedType = Self.geminiSelectedAuthType(settings) {
                guard selectedType == "oauth-personal" else {
                    return result(
                        state: .unsupported,
                        now: now,
                        source: sourceLabel(for: .gemini),
                        messageCode: "local_cli_gemini_oauth_personal_required")
                }
            }
        }

        let credentials = try Self.object(
            credentialData(profile: profile, relativePath: "oauth_creds.json"),
            failure: .invalidCredentials)
        guard let accessToken = Self.nonempty(credentials["access_token"]) else {
            throw Failure.credentialsMissing
        }
        guard let expiryMilliseconds = Self.strictDouble(credentials["expiry_date"]),
            expiryMilliseconds > now.addingTimeInterval(60).timeIntervalSince1970 * 1_000
        else {
            throw Failure.credentialsExpired
        }

        let claims = Self.geminiClaims(fromIDToken: Self.nonempty(credentials["id_token"]))
        let statusResponse = try await checkedResponse(
            for: Self.geminiRequest(
                path: Self.geminiLoadPath,
                token: accessToken,
                body: [
                    "metadata": [
                        "ideType": "GEMINI_CLI",
                        "pluginType": "GEMINI",
                    ]
                ]))
        let status = try Self.parseGeminiCodeAssist(
            statusResponse.data,
            hostedDomain: claims.hostedDomain)

        var quotaBody: [String: Any] = [:]
        if let project = status.projectID {
            quotaBody["project"] = project
        }
        let quotaResponse = try await checkedResponse(
            for: Self.geminiRequest(
                path: Self.geminiQuotaPath,
                token: accessToken,
                body: quotaBody))
        let windows = try Self.parseGeminiQuota(quotaResponse.data, now: now)

        return result(
            state: .available,
            now: now,
            identity: claims.identity,
            fingerprintKind: .gemini,
            plan: status.plan,
            windows: windows,
            source: sourceLabel(for: .gemini))
    }

    /// MiMo Code's native `xiaomi` entry proves which selected CLI account is active, but its API key is
    /// an inference credential. No installed/primary source links that credential to the platform balance
    /// and token-plan endpoints, which are browser-cookie authenticated. Preserve the account identity and
    /// expose the limitation; do not make a speculative request or report local tokens as quota.
    private func loadMiMo(profile: LocalCLIProfile, now: Date) throws -> LocalCLIQuotaResult {
        let root = try Self.object(
            credentialData(profile: profile, relativePath: "auth.json"),
            failure: .invalidCredentials)
        guard let entry = root["xiaomi"] as? [String: Any],
            Self.nonempty(entry["type"])?.lowercased() == "api",
            Self.nonempty(entry["key"]) != nil
        else {
            throw Failure.credentialsMissing
        }
        guard let metadata = entry["metadata"] as? [String: Any],
            let userID = Self.nonempty(metadata["uid"])
        else {
            throw Failure.invalidCredentials
        }
        return result(
            state: .unsupported,
            now: now,
            identity: userID,
            fingerprintKind: .mimo,
            source: "MiMo CLI account metadata",
            messageCode: "local_cli_mimo_native_quota_unsupported")
    }

    private func checkedResponse(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        guard let url = request.url,
            url.scheme == "https",
            url.host == Self.geminiLoadHost,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            [Self.geminiLoadPath, Self.geminiQuotaPath].contains(url.path)
        else {
            throw Failure.invalidResponse
        }

        let response: LocalCLIHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            throw Failure.unavailable
        }
        guard response.data.count <= Self.maximumBytes else { throw Failure.invalidResponse }
        switch response.statusCode {
        case 200: return response
        case 401, 403: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        default: throw Failure.unavailable
        }
    }

    private func credentialData(profile: LocalCLIProfile, relativePath: String) throws -> Data {
        guard
            let data = try fileReader(
                directoryURL(profile).appendingPathComponent(relativePath),
                Self.maximumBytes,
                true)
        else { throw Failure.credentialsMissing }
        return data
    }

    private func directoryURL(_ profile: LocalCLIProfile) -> URL {
        URL(fileURLWithPath: profile.configDirectory, isDirectory: true).standardizedFileURL
    }

    private static func geminiRequest(path: String, token: String, body: [String: Any]) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = geminiLoadHost
        components.path = path
        guard let url = components.url else { throw Failure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexUsageWidget-Next", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func failureResult(_ failure: Failure, kind: LocalCLIKind, now: Date) -> LocalCLIQuotaResult {
        switch failure {
        case .credentialsMissing, .credentialsExpired, .unauthorized:
            result(
                state: .needsLogin,
                now: now,
                source: sourceLabel(for: kind),
                messageCode: "local_cli_needs_login")
        case .rateLimited:
            result(
                state: .rateLimited,
                now: now,
                source: sourceLabel(for: kind),
                messageCode: "local_cli_rate_limited")
        case .invalidCredentials:
            result(
                state: .unavailable,
                now: now,
                source: sourceLabel(for: kind),
                messageCode: "local_cli_invalid_credentials")
        case .invalidResponse:
            result(
                state: .unavailable,
                now: now,
                source: sourceLabel(for: kind),
                messageCode: "local_cli_invalid_response")
        case .unavailable:
            result(
                state: .unavailable,
                now: now,
                source: sourceLabel(for: kind),
                messageCode: "local_cli_unavailable")
        }
    }

    private func result(
        state: LocalCLIQuotaState,
        now: Date,
        identity: String? = nil,
        fingerprintKind: LocalCLIKind? = nil,
        plan: String? = nil,
        windows: [LocalCLIQuotaWindow] = [],
        source: String,
        messageCode: String? = nil
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
            balance: nil,
            balanceCurrency: nil,
            sourceLabel: source,
            messageCode: validWindows ? messageCode : "local_cli_invalid_response")
    }

    private func sourceLabel(for kind: LocalCLIKind) -> String {
        switch kind {
        case .gemini: "Gemini CLI Code Assist quota"
        case .mimo: "MiMo CLI account metadata"
        case .zcode: "ZCode native account"
        case .workBuddy: "WorkBuddy CLI"
        case .trae: "TRAE SOLO"
        case .claudeCode, .grok, .openCode, .kimi, .antigravity: kind.displayName
        }
    }
}

extension AdditionalCLIQuotaReader {
    private struct GeminiCodeAssistStatus {
        let projectID: String?
        let plan: String?
    }

    private struct GeminiIdentityClaims {
        let identity: String?
        let hostedDomain: String?
    }

    private static func parseGeminiCodeAssist(
        _ data: Data,
        hostedDomain: String?
    ) throws -> GeminiCodeAssistStatus {
        let root = try object(data, failure: .invalidResponse)
        let projectID: String? = {
            if let value = nonempty(root["cloudaicompanionProject"]) { return value }
            guard let project = root["cloudaicompanionProject"] as? [String: Any] else { return nil }
            return nonempty(project["id"]) ?? nonempty(project["projectId"])
        }()

        let tierObject = root["currentTier"] as? [String: Any]
        if root["currentTier"] != nil && !(root["currentTier"] is NSNull) && tierObject == nil {
            throw Failure.invalidResponse
        }
        let tier = tierObject.flatMap { nonempty($0["id"]) }
        let paidTierName: String? = {
            if let paid = root["paidTier"] as? [String: Any] { return nonempty(paid["name"]) }
            if let paid = tierObject?["paidTier"] as? [String: Any] { return nonempty(paid["name"]) }
            return nil
        }()
        let plan: String?
        if let paidTierName {
            plan = paidTierName
        } else {
            switch tier {
            case "standard-tier": plan = "Paid"
            case "free-tier": plan = hostedDomain == nil ? "Free" : "Workspace"
            case "legacy-tier": plan = "Legacy"
            case nil: plan = nil
            default: plan = nil
            }
        }
        return GeminiCodeAssistStatus(projectID: projectID, plan: plan)
    }

    static func parseGeminiQuota(_ data: Data, now: Date = Date()) throws -> [LocalCLIQuotaWindow] {
        let root = try object(data, failure: .invalidResponse)
        guard let buckets = root["buckets"] as? [[String: Any]], !buckets.isEmpty else {
            throw Failure.invalidResponse
        }

        var byModel: [String: (remaining: Double, reset: Date?)] = [:]
        for bucket in buckets {
            guard let rawModelID = bucket["modelId"] as? String,
                let modelID = LocalCLIQuotaPresentation.boundedLabel(rawModelID, maximumUTF8Bytes: 128),
                modelID == rawModelID,
                let remaining = strictDouble(bucket["remainingFraction"]),
                (0...1).contains(remaining)
            else { throw Failure.invalidResponse }
            let reset: Date?
            if bucket.keys.contains("resetTime"), !(bucket["resetTime"] is NSNull) {
                guard let parsed = parseDate(bucket["resetTime"]),
                    parsed.timeIntervalSince1970.isFinite,
                    parsed >= now
                else { throw Failure.invalidResponse }
                reset = parsed
            } else {
                reset = nil
            }
            if let current = byModel[modelID] {
                if remaining < current.remaining { byModel[modelID] = (remaining, reset) }
            } else {
                byModel[modelID] = (remaining, reset)
            }
        }
        guard !byModel.isEmpty else { throw Failure.invalidResponse }
        return try byModel.sorted { $0.key < $1.key }.map { modelID, value in
            let used = (1 - value.remaining) * 100
            guard used.isFinite, (0...100).contains(used) else { throw Failure.invalidResponse }
            return LocalCLIQuotaWindow(
                id: "model:\(modelID)",
                label: modelID,
                usedPercent: used,
                resetsAt: value.reset)
        }
    }

    private static func geminiSelectedAuthType(_ root: [String: Any]) -> String? {
        guard let security = root["security"] as? [String: Any],
            let auth = security["auth"] as? [String: Any]
        else { return nil }
        return nonempty(auth["selectedType"])
    }

    private static func geminiClaims(fromIDToken token: String?) -> GeminiIdentityClaims {
        guard let token else { return GeminiIdentityClaims(identity: nil, hostedDomain: nil) }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return GeminiIdentityClaims(identity: nil, hostedDomain: nil) }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
            let payload = try? object(data, failure: .invalidCredentials)
        else { return GeminiIdentityClaims(identity: nil, hostedDomain: nil) }
        return GeminiIdentityClaims(
            identity: nonempty(payload["email"]) ?? nonempty(payload["sub"]),
            hostedDomain: nonempty(payload["hd"]))
    }

    private static func object(_ data: Data, failure: Failure) throws -> [String: Any] {
        guard data.count <= maximumBytes,
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else { throw failure }
        return object
    }

    private static func nonempty(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func strictDouble(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = nonempty(raw) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func fingerprint(kind: LocalCLIKind, identity: String) -> String {
        let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data("next-local-cli:v1:\(kind.rawValue):\(normalized)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
