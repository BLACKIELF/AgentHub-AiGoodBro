import CoreFoundation
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Read-only Coding Plan and Start Plan quotas for the selected native ZCode account.
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

    private struct Credential: Equatable {
        let apiKey: String?
        let host: String
        let accountID: String
        let billingJWT: String?
        let deviceMid: String?
    }

    private struct Lane {
        var plan: String? = nil
        var windows: [LocalCLIQuotaWindow] = []
        var failure: Failure? = nil
        var noCodingPlan = false
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
            // Billing is account-wide, including while Coding Plan is selected.
            // Each endpoint has its own credential; one failure must not erase
            // the other endpoint's verified quota.
            async let codingRequest = codingQuota(credential, now: now)
            async let billingRequest = billingQuota(credential, now: now)
            let (coding, billing) = await (codingRequest, billingRequest)
            guard let current = try? self.credential(profile: profile), current == credential
            else { throw Failure.accountChanged }
            let fingerprint = SHA256.hash(data: Data(("zcode:" + credential.host + ":" + credential.accountID).utf8)).map { String(format: "%02x", $0) }.joined()
            let windows = billing.windows + coding.windows
            if !windows.isEmpty {
                return result(state: .available, now: now, fingerprint: fingerprint,
                              plan: billing.plan ?? coding.plan, windows: windows,
                              messageCode: billing.failure != nil || coding.failure != nil
                                ? "local_cli_zcode_partial_quota" : nil)
            }
            if let failure = billing.failure ?? coding.failure { throw failure }
            return result(state: .unsupported, now: now, fingerprint: fingerprint,
                          messageCode: coding.noCodingPlan && credential.billingJWT == nil
                            ? "local_cli_zcode_no_coding_plan" : "local_cli_zcode_no_quota")
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

    private func codingQuota(_ credential: Credential, now: Date) async -> Lane {
        guard let apiKey = credential.apiKey else { return Lane() }
        do {
            var components = URLComponents()
            components.scheme = "https"
            components.host = credential.host == "open.bigmodel.cn" ? "bigmodel.cn" : credential.host
            components.path = Self.quotaPath
            guard let url = components.url else { throw Failure.invalidConfiguration }
            let data = try await fetch(url, authorization: apiKey)
            if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                Self.strictDouble(envelope["code"]) == 500,
                (envelope["msg"] as? String ?? envelope["message"] as? String) == "当前用户不存在coding plan"
            { return Lane(noCodingPlan: true) }
            let parsed = try Self.parse(data, now: now)
            return Lane(plan: parsed.plan, windows: parsed.windows)
        } catch { return Lane(failure: error as? Failure ?? .unavailable) }
    }

    private func billingQuota(_ credential: Credential, now: Date) async -> Lane {
        guard let jwt = credential.billingJWT else { return Lane() }
        guard let deviceMid = credential.deviceMid else { return Lane(failure: .credentialsUnreadable) }
        do {
            let url = URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance")!
            let data = try await fetch(url, authorization: "Bearer " + jwt, deviceMid: deviceMid)
            let parsed = try Self.parseBilling(data, now: now)
            return Lane(plan: parsed.plan, windows: parsed.windows)
        } catch { return Lane(failure: error as? Failure ?? .unavailable) }
    }

    private func fetch(_ url: URL, authorization: String, deviceMid: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(deviceMid, forHTTPHeaderField: "X-Device-Mid")
        request.setValue("CodexUsageWidget-Next", forHTTPHeaderField: "User-Agent")
        let response: LocalCLIHTTPResponse
        do { response = try await transport.response(for: request) }
        catch { throw Failure.unavailable }
        guard response.data.count <= Self.maximumBytes else { throw Failure.invalidResponse }
        switch response.statusCode {
        case 200: return response.data
        case 401: throw Failure.unauthorized
        case 403: throw Failure.forbidden
        case 429: throw Failure.rateLimited
        default: throw Failure.unavailable
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
            ["individual-coding-plan", "start-plan"].contains(kind)
        else { throw Failure.unsupportedConfiguration }
        let providerID = kind == "start-plan" ? "builtin:\(family)-start-plan" : "builtin:\(family)-coding-plan"
        let providers = config["provider"] as? [String: Any]
        let entry = providers?[providerID] as? [String: Any]
        if kind == "individual-coding-plan", entry == nil { throw Failure.unsupportedConfiguration }
        var requiresActiveSession = false
        if let rawEnabled = entry?["enabled"] {
            guard let enabled = Self.strictBool(rawEnabled) else { throw Failure.invalidConfiguration }
            if !enabled {
                let reason = Self.nonempty(entry?["systemDisabledReason"])
                guard reason != nil else { throw Failure.inactiveProvider }
                requiresActiveSession = reason == "oauth_provider_inactive"
            }
        }
        let host = family == "zai" ? "api.z.ai" : "open.bigmodel.cn"
        if kind == "individual-coding-plan" {
            guard let options = entry?["options"] as? [String: Any] else { throw Failure.invalidConfiguration }
            guard let rawBaseURL = Self.nonempty(options["baseURL"]),
                let components = URLComponents(string: rawBaseURL),
                components.scheme?.lowercased() == "https",
                let configuredHost = components.host?.lowercased(), Self.officialHosts.contains(configuredHost),
                configuredHost == host,
                components.user == nil, components.password == nil, components.port == nil,
                components.query == nil, components.fragment == nil
            else { throw Failure.unsupportedConfiguration }
        }

        guard let storeData = try fileReader(base.appendingPathComponent("credentials.json"), Self.maximumBytes, true)
        else { throw Failure.credentialsMissing }
        guard let store = try? JSONSerialization.jsonObject(with: storeData) as? [String: Any]
        else { throw Failure.credentialsUnreadable }
        // The provider registry may retain oauth_provider_inactive after login.
        // ZCode's OAuthCredentialRepo reads the encrypted active-provider entry
        // as the session authority. Never repair the registry or use another
        // family's saved account; the selected account's own key is still required.
        var activeFamilyVerified = false
        if let active = store["oauth:active_provider"] {
            guard let encrypted = active as? String, decryptor(encrypted) == family
            else { throw Failure.inactiveProvider }
            activeFamilyVerified = true
        } else if requiresActiveSession {
            throw Failure.inactiveProvider
        }
        guard let encryptedProfile = store["oauth:\(family):user_info"] as? String,
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
        func storedSecret(_ name: String) -> String? {
            guard let encrypted = store[name] as? String,
                let secret = decryptor(encrypted).flatMap(Self.nonempty),
                secret.utf8.count <= 16 * 1_024,
                !secret.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { return nil }
            return secret
        }
        let apiKey = kind == "individual-coding-plan" ? storedSecret(keyName) : nil
        // The account-wide JWT follows the active OAuth family, never a saved
        // provider mirror or another family's account. Recheck it after both reads.
        let billingJWT = activeFamilyVerified ? storedSecret("zcodejwttoken") : nil
        var deviceMid: String?
        if billingJWT != nil,
            let data = try fileReader(base.appendingPathComponent("telemetry-state.json"), Self.maximumBytes, true),
            let telemetry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let mid = Self.nonempty(telemetry["deviceMid"]), mid.utf8.count <= 512,
            !mid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        { deviceMid = mid }
        guard apiKey != nil || billingJWT != nil else { throw Failure.credentialsUnreadable }
        return Credential(apiKey: apiKey, host: host, accountID: identity, billingJWT: billingJWT, deviceMid: deviceMid)
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

    /// The native billing gateway returns all grants, including expired ones.
    /// Keep model buckets separate so different expiries/allowances are not added.
    private static func parseBilling(_ data: Data, now: Date) throws -> (plan: String?, windows: [LocalCLIQuotaWindow]) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            billingNumber(envelope["code"]) == 0,
            let payload = envelope["data"] as? [String: Any],
            let plans = payload["plans"] as? [[String: Any]], plans.count <= 256,
            let balances = payload["balances"] as? [[String: Any]], balances.count <= 256
        else { throw Failure.invalidResponse }
        func timestamp(_ raw: Any?) throws -> Date? {
            guard let raw, !(raw is NSNull) else { return nil }
            guard let seconds = billingNumber(raw), seconds >= 0,
                seconds <= Date.distantFuture.timeIntervalSince1970
            else { throw Failure.invalidResponse }
            return seconds == 0 ? nil : Date(timeIntervalSince1970: seconds)
        }
        let reference = max(now, try timestamp(payload["server_time"]) ?? now)
        var windowsByID: [String: LocalCLIQuotaWindow] = [:]
        var planNames = Set<String>()
        for balance in balances {
            let matches = plans.filter { plan in
                if let userPlan = nonempty(balance["user_plan_id"]), let candidate = nonempty(plan["user_plan_id"]) {
                    return userPlan == candidate
                }
                guard let planID = nonempty(balance["plan_id"]) else { return false }
                return planID == nonempty(plan["plan_id"])
            }
            guard matches.count == 1, let plan = matches.first else { throw Failure.invalidResponse }
            guard (plan["status"] as? String)?.lowercased() == "active" else { continue }
            if let end = try timestamp(plan["ends_at"]), end <= reference { continue }
            if let start = try timestamp(plan["starts_at"]), start > reference { continue }
            let entitlements = plan["entitlements"] as? [[String: Any]] ?? []
            let entitlementID = nonempty(balance["entitlement_id"])
            let entitlement = entitlementID.flatMap { id in entitlements.first { nonempty($0["entitlement_id"]) == id } }
            if let effective = try timestamp(entitlement?["effective_at"]), effective > reference { continue }
            let reset = try timestamp(balance["expires_at"])
                ?? timestamp(balance["period_end"]) ?? timestamp(plan["ends_at"])
            if let reset, reset <= reference { continue }
            guard let total = billingNumber(balance["total_units"]), total > 0,
                let label = boundedLabel(balance["show_name"]) ?? boundedLabel(entitlement?["show_name"])
            else { throw Failure.invalidResponse }
            let used = billingNumber(balance["used_units"])
            let remaining: Double
            if let raw = balance["remaining_units"] {
                guard let value = billingNumber(raw) else { throw Failure.invalidResponse }
                remaining = value
            } else {
                guard let used, used >= 0, used <= total else { throw Failure.invalidResponse }
                remaining = total - used
            }
            guard remaining >= 0, remaining <= total,
                balance["used_units"] == nil || (used != nil && used! >= 0 && used! <= total)
            else { throw Failure.invalidResponse }
            let keyFields = ["user_plan_id", "plan_id", "entitlement_id", "bucket_id", "period_start", "expires_at"]
            let key = try JSONSerialization.data(withJSONObject: keyFields.map { balance[$0] ?? NSNull() }, options: [.sortedKeys])
            let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
            let unit = nonempty(balance["unit_type"]) ?? nonempty(entitlement?["unit_type"])
            let period = nonempty(entitlement?["period"]) ?? nonempty(balance["period"])
            var window = LocalCLIQuotaWindow(id: "zcode-start-" + digest, label: label,
                                             usedPercent: (1 - remaining / total) * 100,
                                             resetsAt: reset, isExpiry: period == "one_time")
            if unit == "token" {
                // JSON numbers above 2^53 cannot preserve exact token counts.
                guard total <= 9_007_199_254_740_991,
                    let exactTotal = Int64(exactly: total), let exactRemaining = Int64(exactly: remaining)
                else { throw Failure.invalidResponse }
                window.totalTokens = exactTotal
                window.remainingTokens = exactRemaining
            }
            if let previous = windowsByID[window.id], previous != window { throw Failure.invalidResponse }
            windowsByID[window.id] = window
            if let name = boundedLabel(plan["name"]) { planNames.insert(name) }
        }
        let windows = windowsByID.values.sorted {
            $0.label == $1.label ? $0.id < $1.id : $0.label < $1.label
        }
        return (planNames.sorted().first, windows)
    }

    private static func billingNumber(_ value: Any?) -> Double? {
        if let number = strictDouble(value) { return number }
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 32,
            text == text.trimmingCharacters(in: .whitespacesAndNewlines),
            let number = Double(text), number.isFinite
        else { return nil }
        return number
    }

    private func result(
        state: LocalCLIQuotaState,
        now: Date,
        fingerprint: String? = nil,
        plan: String? = nil,
        windows: [LocalCLIQuotaWindow] = [],
        messageCode: String? = nil
    ) -> LocalCLIQuotaResult {
        LocalCLIQuotaResult(
            state: state,
            fetchedAt: now,
            maskedIdentity: nil,
            identityFingerprint: fingerprint,
            planLabel: plan,
            windows: windows,
            balance: nil,
            balanceCurrency: nil,
            sourceLabel: "ZCode official account quotas",
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
