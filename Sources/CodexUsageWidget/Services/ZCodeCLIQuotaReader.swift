import CoreFoundation
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Read-only quota adapter for the selected native ZCode coding-plan account.
/// Selection and account-key binding follow the pinned Token Monitor ZCode discovery contract;
/// this adapter never falls back to a config mirror that may belong to another account.
struct ZCodeCLIQuotaReader {
    private enum Failure: Error {
        case unsupportedConfiguration
        case inactiveProvider
        case credentialsMissing
        case credentialsUnreadable
        case invalidConfiguration
        case invalidResponse
        case unauthorized
        case forbidden
        case accountChanged
        case rateLimited
        case unavailable
    }

    private struct Credential {
        let apiKey: String
        let host: String
        let accountID: String
    }

    private static let maximumBytes = 1_048_576
    private static let quotaPath = "/api/monitor/usage/quota/limit"
    private static let officialHosts: Set<String> = ["open.bigmodel.cn", "api.z.ai"]

    private let transport: any LocalCLIQuotaTransport
    private let fileReader: LocalCLIQuotaReader.FileReader
    private let decryptor: (String) -> String?

    init(
        transport: any LocalCLIQuotaTransport = LocalCLIURLSessionTransport(),
        fileReader: @escaping LocalCLIQuotaReader.FileReader = { url, maximumBytes, allowMissing in
            try DispatchParticipationSync.readBoundedRegularFile(
                url,
                maximumBytes: maximumBytes,
                allowMissing: allowMissing)
        },
        decryptor: @escaping (String) -> String? = { ZCodeCLIQuotaReader.decryptStoredCredential($0) }
    ) {
        self.transport = transport
        self.fileReader = fileReader
        self.decryptor = decryptor
    }

    func load(profile: LocalCLIProfile, now: Date = Date()) async -> LocalCLIQuotaResult {
        guard profile.kind == .zcode else {
            return result(state: .unsupported, now: now, messageCode: "local_cli_adapter_not_owned")
        }
        do {
            let credential = try credential(profile: profile)
            var components = URLComponents()
            components.scheme = "https"
            components.host = credential.host
            components.path = Self.quotaPath
            guard let url = components.url else { throw Failure.invalidConfiguration }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("CodexUsageWidget-Next", forHTTPHeaderField: "User-Agent")

            let response: LocalCLIHTTPResponse
            do {
                response = try await transport.response(for: request)
            } catch {
                throw Failure.unavailable
            }
            guard response.data.count <= Self.maximumBytes else { throw Failure.invalidResponse }
            switch response.statusCode {
            case 200: break
            case 401: throw Failure.unauthorized
            case 403: throw Failure.forbidden
            case 429: throw Failure.rateLimited
            default: throw Failure.unavailable
            }
            let parsed = try Self.parse(response.data, now: now)
            guard let current = try? self.credential(profile: profile),
                current.accountID == credential.accountID,
                current.apiKey == credential.apiKey,
                current.host == credential.host
            else { throw Failure.accountChanged }
            return result(
                state: .available,
                now: now,
                plan: parsed.plan,
                windows: parsed.windows)
        } catch let failure as Failure {
            switch failure {
            case .unsupportedConfiguration:
                return result(
                    state: .unsupported, now: now,
                    messageCode: "local_cli_zcode_coding_plan_unsupported")
            case .inactiveProvider:
                return result(state: .unsupported, now: now, messageCode: "local_cli_zcode_inactive_provider")
            case .credentialsMissing:
                return result(state: .needsLogin, now: now, messageCode: "local_cli_needs_login")
            case .credentialsUnreadable:
                return result(state: .unavailable, now: now, messageCode: "local_cli_zcode_account_unverified")
            case .unauthorized:
                return result(state: .unavailable, now: now, messageCode: "local_cli_remote_unauthorized")
            case .forbidden:
                return result(state: .unavailable, now: now, messageCode: "local_cli_remote_forbidden")
            case .accountChanged:
                return result(state: .unavailable, now: now, messageCode: "local_cli_zcode_account_changed")
            case .rateLimited:
                return result(state: .rateLimited, now: now, messageCode: "local_cli_rate_limited")
            case .invalidConfiguration:
                return result(
                    state: .unavailable, now: now,
                    messageCode: "local_cli_invalid_credentials")
            case .invalidResponse:
                return result(
                    state: .unavailable, now: now,
                    messageCode: "local_cli_invalid_response")
            case .unavailable:
                return result(state: .unavailable, now: now, messageCode: "local_cli_unavailable")
            }
        } catch {
            return result(state: .unavailable, now: now, messageCode: "local_cli_unavailable")
        }
    }

    private func credential(profile: LocalCLIProfile) throws -> Credential {
        let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true).standardizedFileURL
        let expected = LocalCLIKind.zcode.defaultConfigDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL
        guard profile.isDefault, directory == expected else { throw Failure.unsupportedConfiguration }
        let base = directory.appendingPathComponent("v2", isDirectory: true)
        guard let settingsData = try fileReader(base.appendingPathComponent("setting.json"), Self.maximumBytes, true),
            let configData = try fileReader(base.appendingPathComponent("config.json"), Self.maximumBytes, true)
        else { throw Failure.unsupportedConfiguration }
        guard let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
            let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
            let family = Self.nonempty(settings["providerFamilyDomain"]),
            ["zai", "bigmodel"].contains(family),
            let selections = settings["providerFamilyConnectionSelections"] as? [String: Any],
            let selected = selections[family] as? [String: Any],
            let kind = Self.nonempty(selected["kind"]),
            kind == "individual-coding-plan"
        else { throw Failure.unsupportedConfiguration }
        let providerID = "builtin:\(family)-coding-plan"
        guard let providers = config["provider"] as? [String: Any],
            let entry = providers[providerID] as? [String: Any]
        else { throw Failure.unsupportedConfiguration }
        if let rawEnabled = entry["enabled"] {
            guard let enabled = Self.strictBool(rawEnabled) else { throw Failure.invalidConfiguration }
            if !enabled {
                let reason = Self.nonempty(entry["systemDisabledReason"])
                guard reason != nil, reason != "oauth_provider_inactive" else { throw Failure.inactiveProvider }
            }
        }
        guard let options = entry["options"] as? [String: Any] else { throw Failure.invalidConfiguration }
        guard let rawBaseURL = Self.nonempty(options["baseURL"]),
            let components = URLComponents(string: rawBaseURL),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(), Self.officialHosts.contains(host),
            host == (family == "zai" ? "api.z.ai" : "open.bigmodel.cn"),
            components.user == nil, components.password == nil, components.port == nil,
            components.query == nil, components.fragment == nil
        else { throw Failure.unsupportedConfiguration }

        guard let storeData = try fileReader(base.appendingPathComponent("credentials.json"), Self.maximumBytes, true)
        else { throw Failure.credentialsMissing }
        guard let store = try? JSONSerialization.jsonObject(with: storeData) as? [String: Any],
            let encryptedProfile = store["oauth:\(family):user_info"] as? String,
            let profileJSON = decryptor(encryptedProfile),
            let profileData = profileJSON.data(using: .utf8),
            let account = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any]
        else { throw Failure.credentialsUnreadable }
        let identity: String?
        if let id = Self.nonempty(account["id"]),
            account["username"] is String,
            account["displayName"] is String
        {
            identity = id
        } else {
            identity = family == "zai" ? Self.nonempty(account["user_id"]) : nil
        }
        guard let identity, identity.utf8.count <= 512,
            !identity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw Failure.credentialsUnreadable }
        let keyName = "account-provider:coding-plan:account:\(family)-\(kind):account:\(Self.encodeURIComponent(identity)):api-key"
        guard let encryptedKey = store[keyName] as? String,
            let apiKey = decryptor(encryptedKey).flatMap(Self.nonempty),
            apiKey.utf8.count <= 16 * 1_024,
            !apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw Failure.credentialsUnreadable }
        return Credential(apiKey: apiKey, host: host, accountID: identity)
    }

    private static func encodeURIComponent(_ value: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
        return value.utf8.map { safe.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    static func decryptStoredCredential(_ value: String, secretOverride: String? = nil) -> String? {
        guard value.hasPrefix("enc:v1:"), value.utf8.count <= maximumBytes else { return nil }
        let fields = value.dropFirst("enc:v1:".count).split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3,
            let nonceData = base64URL(fields[0]), nonceData.count == 12,
            let tagData = base64URL(fields[1]), tagData.count == 16,
            let ciphertext = base64URL(fields[2]), ciphertext.count <= maximumBytes
        else { return nil }
        let explicit = (secretOverride ?? ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secret =
            (explicit?.isEmpty == false ? explicit : nil)
            ?? "zcode-credential-fallback:darwin:\(FileManager.default.homeDirectoryForCurrentUser.path):\(NSUserName())"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
            let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData),
            let plaintext = try? AES.GCM.open(box, using: key),
            let decoded = String(data: plaintext, encoding: .utf8), !decoded.isEmpty
        else { return nil }
        return decoded
    }

    private static func base64URL(_ value: Substring) -> Data? {
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    private static func parse(_ data: Data, now: Date) throws -> (plan: String?, windows: [LocalCLIQuotaWindow]) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = strictDouble(envelope["code"]), code == 200,
            strictBool(envelope["success"]) == true,
            let payload = envelope["data"] as? [String: Any],
            let limits = payload["limits"] as? [[String: Any]],
            !limits.isEmpty, limits.count <= 16
        else { throw Failure.invalidResponse }

        var identifiers = Set<String>()
        let windows = try limits.map { item -> LocalCLIQuotaWindow in
            guard let type = nonempty(item["type"]),
                let unit = strictInteger(item["unit"]),
                let number = strictInteger(item["number"]),
                let used = strictNonnegative(item["currentValue"]),
                let allowance = strictNonnegative(item["usage"]), allowance > 0,
                used <= allowance
            else { throw Failure.invalidResponse }
            if let rawPercent = item["percentage"] {
                guard let percent = strictNonnegative(rawPercent), percent <= 100 else {
                    throw Failure.invalidResponse
                }
            }

            let id: String
            let label: String
            switch (type, unit, number) {
            case ("CREDIT_LIMIT", 3, 5), ("TOKENS_LIMIT", _, 5):
                id = "zai-coding-plan-5-hour"
                label = "5-hour"
            case ("CREDIT_LIMIT", 6, 1), ("TOKENS_LIMIT", _, 7):
                id = "zai-coding-plan-weekly"
                label = "Weekly"
            case ("MCP_LIMIT", _, _), ("TIME_LIMIT", _, _):
                id = "zai-coding-plan-mcp"
                label = "MCP"
            default:
                throw Failure.invalidResponse
            }
            guard identifiers.insert(id).inserted else { throw Failure.invalidResponse }

            let reset: Date?
            if let rawReset = item["nextResetTime"] {
                guard let milliseconds = strictNonnegative(rawReset), milliseconds > 0,
                    milliseconds / 1_000 <= Date.distantFuture.timeIntervalSince1970
                else { throw Failure.invalidResponse }
                let parsed = Date(timeIntervalSince1970: milliseconds / 1_000)
                guard parsed.timeIntervalSince1970.isFinite, parsed >= now else {
                    throw Failure.invalidResponse
                }
                reset = parsed
            } else {
                reset = nil
            }
            let percent = used / allowance * 100
            guard percent.isFinite, 0...100 ~= percent else { throw Failure.invalidResponse }
            return LocalCLIQuotaWindow(id: id, label: label, usedPercent: percent, resetsAt: reset)
        }
        return (boundedLabel(payload["level"]), windows)
    }

    private func result(
        state: LocalCLIQuotaState,
        now: Date,
        plan: String? = nil,
        windows: [LocalCLIQuotaWindow] = [],
        messageCode: String? = nil
    ) -> LocalCLIQuotaResult {
        LocalCLIQuotaResult(
            state: state,
            fetchedAt: now,
            maskedIdentity: nil,
            identityFingerprint: nil,
            planLabel: plan,
            windows: windows,
            balance: nil,
            balanceCurrency: nil,
            sourceLabel: "ZCode selected GLM/Z.AI Coding Plan",
            messageCode: messageCode)
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return value
    }

    private static func strictDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func strictNonnegative(_ value: Any?) -> Double? {
        guard let value = strictDouble(value), value >= 0 else { return nil }
        return value
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let value = strictNonnegative(value) else { return nil }
        return Int(exactly: value)
    }

    private static func boundedLabel(_ value: Any?) -> String? {
        guard let value = nonempty(value), value.utf8.count <= 64,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }
}
