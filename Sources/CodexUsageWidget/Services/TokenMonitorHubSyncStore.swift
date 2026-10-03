import Combine
import Foundation
import Security

protocol TokenMonitorHubCredentialStore {
    func read() throws -> String?
    func save(_ secret: String) throws
    func clear() throws
}

struct TokenMonitorHubKeychainStore: TokenMonitorHubCredentialStore {
    private static let service = "com.aigoodbro.tokenmonitor.hub"
    private static let account = "bearer-secret"

    func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenMonitorIntegrationFailure.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw TokenMonitorIntegrationFailure.keychain(errSecDecode)
        }
        return value
    }

    func save(_ secret: String) throws {
        guard let data = secret.data(using: .utf8) else { throw TokenMonitorIntegrationFailure.invalidConfiguration }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TokenMonitorIntegrationFailure.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw TokenMonitorIntegrationFailure.keychain(status)
        }
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenMonitorIntegrationFailure.keychain(status)
        }
    }
}

@MainActor
final class TokenMonitorHubSyncStore: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var serverURL: String
    @Published private(set) var credentialStatus: TokenMonitorHubCredentialStatus
    @Published private(set) var connectionState: TokenMonitorHubConnectionState
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var error: String?
    @Published private(set) var isPublishingThisDevice: Bool
    @Published private(set) var devices: [TokenMonitorHubDevice] = []
    @Published private(set) var history: TokenMonitorHubHistory?
    @Published private(set) var localDeviceID: String?

    func localizedError(_ language: WidgetLanguage) -> String? {
        guard let error else { return nil }
        return TokenMonitorIntegrationFailure.localizedMessage(error, language: language)
    }

    nonisolated private static let urlKey = "CodexManagerNext.tokenMonitorHub.serverURL"
    nonisolated private static let enabledKey = "CodexManagerNext.tokenMonitorHub.enabled"
    nonisolated private static let publishKey = "CodexManagerNext.tokenMonitorHub.publishThisDevice"
    nonisolated private static let deviceIDKey = "CodexManagerNext.tokenMonitorHub.deviceID"
    nonisolated private static let credentialConfiguredKey = "CodexManagerNext.tokenMonitorHub.credentialConfigured"
    private let defaults: UserDefaults?
    private let credentialStore: TokenMonitorHubCredentialStore?
    private let transport: TokenMonitorHTTPTransport?
    private let previewOnly: Bool
    private var requestInFlight = false
    private var configurationRevision: UInt64 = 0

    nonisolated init(
        defaults: UserDefaults? = nil,
        credentialStore: TokenMonitorHubCredentialStore? = nil,
        transport: TokenMonitorHTTPTransport? = nil,
        previewOnly: Bool = false,
        previewEnabled: Bool = false,
        previewServerURL: String = "",
        previewCredentialStatus: TokenMonitorHubCredentialStatus = .missing,
        previewConnectionState: TokenMonitorHubConnectionState? = nil,
        previewDevices: [TokenMonitorHubDevice] = [],
        previewHistory: TokenMonitorHubHistory? = nil,
        previewLocalDeviceID: String? = nil
    ) {
        self.previewOnly = previewOnly
        if previewOnly {
            self.defaults = nil
            self.credentialStore = nil
            self.transport = nil
            _serverURL = Published(initialValue: previewServerURL)
            _isEnabled = Published(initialValue: previewEnabled)
            _isPublishingThisDevice = Published(initialValue: false)
            _credentialStatus = Published(initialValue: previewCredentialStatus)
            _connectionState = Published(initialValue: previewConnectionState ?? (previewEnabled ? .connected : .disabled))
            _devices = Published(initialValue: previewDevices)
            _history = Published(initialValue: previewHistory)
            _localDeviceID = Published(initialValue: previewLocalDeviceID)
        } else {
            let actualDefaults = defaults ?? .standard
            self.defaults = actualDefaults
            self.credentialStore = credentialStore ?? TokenMonitorHubKeychainStore()
            self.transport = transport ?? TokenMonitorURLSessionTransport()
            _serverURL = Published(initialValue: actualDefaults.string(forKey: Self.urlKey) ?? "")
            _isEnabled = Published(initialValue: actualDefaults.bool(forKey: Self.enabledKey))
            _isPublishingThisDevice = Published(initialValue: actualDefaults.bool(forKey: Self.publishKey))
            _localDeviceID = Published(initialValue: actualDefaults.string(forKey: Self.deviceIDKey))
            // Do not touch Keychain during ordinary startup. An explicit probe or enable action
            // verifies the secret; this non-secret marker only drives the settings label.
            _credentialStatus = Published(initialValue: actualDefaults.bool(forKey: Self.credentialConfiguredKey) ? .stored : .missing)
            _connectionState = Published(initialValue: actualDefaults.bool(forKey: Self.enabledKey) ? .idle : .disabled)
            _devices = Published(initialValue: [])
            _history = Published(initialValue: nil)
        }
    }

    func saveConfiguration(serverURL rawURL: String, bearerSecret rawSecret: String) throws {
        guard !previewOnly, let defaults, let credentialStore else {
            throw TokenMonitorIntegrationFailure.invalidConfiguration
        }
        let normalized = try Self.normalizeServerURL(rawURL)
        let previous = (try? Self.normalizeServerURL(serverURL)).map(\.absoluteString)
        let suppliedSecret = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !suppliedSecret.isEmpty {
            guard suppliedSecret.utf8.count <= 4096,
                suppliedSecret.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E })
            else { throw TokenMonitorIntegrationFailure.invalidConfiguration }
            try credentialStore.save(suppliedSecret)
            defaults.set(true, forKey: Self.credentialConfiguredKey)
            credentialStatus = .stored
        } else {
            guard previous == normalized.absoluteString,
                (try? credentialStore.read()) != nil
            else { throw TokenMonitorIntegrationFailure.missingCredential }
            credentialStatus = .stored
        }
        serverURL = normalized.absoluteString
        defaults.set(serverURL, forKey: Self.urlKey)
        configurationRevision &+= 1
        if previous != normalized.absoluteString {
            // A secret is never silently reused for a different destination.
            setEnabled(false)
            setPublishingThisDevice(false, confirmed: false)
        }
        error = nil
    }

    func setEnabled(_ requested: Bool) {
        guard !previewOnly, let defaults, let credentialStore else { return }
        guard requested else {
            defaults.set(false, forKey: Self.enabledKey)
            configurationRevision &+= 1
            isEnabled = false
            connectionState = .disabled
            return
        }
        guard (try? Self.normalizeServerURL(serverURL)) != nil else {
            defaults.set(false, forKey: Self.enabledKey)
            isEnabled = false
            connectionState = .failed
            error = TokenMonitorIntegrationFailure.invalidConfiguration.displayMessage
            return
        }
        guard (try? credentialStore.read()) != nil else {
            defaults.set(false, forKey: Self.enabledKey)
            isEnabled = false
            credentialStatus = .missing
            defaults.set(false, forKey: Self.credentialConfiguredKey)
            connectionState = .failed
            error = TokenMonitorIntegrationFailure.missingCredential.displayMessage
            return
        }
        credentialStatus = .stored
        defaults.set(true, forKey: Self.credentialConfiguredKey)
        defaults.set(true, forKey: Self.enabledKey)
        configurationRevision &+= 1
        isEnabled = true
        connectionState = .idle
        error = nil
    }

    func setPublishingThisDevice(_ requested: Bool, confirmed: Bool) {
        guard !previewOnly, let defaults else { return }
        let accepted = requested && confirmed && isEnabled && credentialStatus == .stored
        isPublishingThisDevice = accepted
        defaults.set(accepted, forKey: Self.publishKey)
        configurationRevision &+= 1
        if requested && !accepted {
            error = "Enable Hub sync and confirm the data scope before publishing this device."
        } else if accepted {
            error = nil
        }
    }

    func clearConfiguration() throws {
        guard !previewOnly, let defaults, let credentialStore else { return }
        setEnabled(false)
        setPublishingThisDevice(false, confirmed: false)
        try credentialStore.clear()
        defaults.removeObject(forKey: Self.urlKey)
        defaults.removeObject(forKey: Self.deviceIDKey)
        defaults.removeObject(forKey: Self.credentialConfiguredKey)
        configurationRevision &+= 1
        serverURL = ""
        credentialStatus = .missing
        localDeviceID = nil
        devices = []
        history = nil
        lastRefresh = nil
        connectionState = .disabled
        error = nil
    }

    /// An explicit, read-only connection check. It does not enable periodic access or publishing.
    func probe() async {
        await loadSnapshot(requireEnabled: false)
    }

    func refresh() async {
        await loadSnapshot(requireEnabled: true)
    }

    /// Called only after a local collector success and only when the separate publish switch is on.
    /// Tests must inject a mock transport; this function never runs as part of validation.
    func publishThisDevice(_ response: TokenMonitorResponse, now: Date = Date()) async {
        guard !previewOnly, isEnabled, isPublishingThisDevice, !requestInFlight,
            let credentialStore, let transport
        else { return }
        let revision = configurationRevision
        do {
            let baseURL = try Self.normalizeServerURL(serverURL)
            guard let secret = try credentialStore.read(), !secret.isEmpty else {
                throw TokenMonitorIntegrationFailure.missingCredential
            }
            guard revision == configurationRevision, isEnabled, isPublishingThisDevice else { return }
            let payload = try Self.makeUploadPayload(response: response, deviceID: deviceID(), hostname: localHostname(), now: now)
            let data = try JSONEncoder().encode(payload)
            guard data.count <= 12_000_000 else { throw TokenMonitorIntegrationFailure.responseTooLarge }
            var request = URLRequest(url: baseURL.appendingPathComponent("api/ingest"))
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            guard revision == configurationRevision, isEnabled, isPublishingThisDevice else { return }
            requestInFlight = true
            defer { requestInFlight = false }
            let result = try await transport.send(request, maximumResponseBytes: 256_000)
            guard revision == configurationRevision, isEnabled, isPublishingThisDevice else { return }
            guard (200...299).contains(result.statusCode) else {
                throw TokenMonitorIntegrationFailure.httpStatus(result.statusCode)
            }
            connectionState = .connected
            lastRefresh = now
            error = nil
        } catch let failure as TokenMonitorIntegrationFailure {
            guard revision == configurationRevision else { return }
            connectionState = devices.isEmpty ? .failed : .stale
            error = failure.displayMessage
        } catch is CancellationError {
            guard revision == configurationRevision else { return }
        } catch {
            guard revision == configurationRevision else { return }
            connectionState = devices.isEmpty ? .failed : .stale
            self.error = TokenMonitorIntegrationFailure.transport.displayMessage
        }
    }

    private func loadSnapshot(requireEnabled: Bool) async {
        guard !previewOnly, !Task.isCancelled else { return }
        guard let defaults, let credentialStore, let transport else { return }
        guard !requestInFlight else { return }
        guard !requireEnabled || isEnabled else {
            connectionState = .disabled
            return
        }
        guard let baseURL = try? Self.normalizeServerURL(serverURL) else {
            connectionState = .failed
            error = TokenMonitorIntegrationFailure.invalidConfiguration.displayMessage
            return
        }
        guard let secret = try? credentialStore.read(), !secret.isEmpty else {
            credentialStatus = .missing
            connectionState = .failed
            error = TokenMonitorIntegrationFailure.missingCredential.displayMessage
            return
        }
        credentialStatus = .stored
        let revision = configurationRevision
        let previousConnectionState = connectionState
        let previousError = error
        requestInFlight = true
        connectionState = .connecting
        error = nil
        defer { requestInFlight = false }
        do {
            let statsData = try await get(path: "api/stats", baseURL: baseURL, secret: secret, maximumBytes: 4_194_304)
            guard revision == configurationRevision, !requireEnabled || isEnabled else { return }
            let stats = try JSONDecoder().decode(TokenMonitorHubStats.self, from: statsData)
            guard stats.devices.count <= 256 else { throw TokenMonitorIntegrationFailure.invalidResponse }
            let historyData = try await get(path: "api/history", baseURL: baseURL, secret: secret, maximumBytes: 12_000_000)
            guard revision == configurationRevision, !requireEnabled || isEnabled else { return }
            let decodedHistory = try JSONDecoder().decode(TokenMonitorHubHistory.self, from: historyData)
            let myDeviceID = defaults.string(forKey: Self.deviceIDKey)
            devices = stats.devices.map { device in
                var value = device
                value.isCurrent = myDeviceID != nil && value.deviceId == myDeviceID
                return value
            }
            history = decodedHistory
            lastRefresh = Date()
            connectionState = .connected
            error = nil
        } catch let failure as TokenMonitorIntegrationFailure {
            guard revision == configurationRevision, !requireEnabled || isEnabled else { return }
            connectionState = (devices.isEmpty && history == nil) ? .failed : .stale
            error = failure.displayMessage
        } catch TokenMonitorHTTPTransportError.responseTooLarge {
            guard revision == configurationRevision, !requireEnabled || isEnabled else { return }
            connectionState = (devices.isEmpty && history == nil) ? .failed : .stale
            error = TokenMonitorIntegrationFailure.responseTooLarge.displayMessage
        } catch TokenMonitorHTTPTransportError.transport {
            guard revision == configurationRevision, !requireEnabled || isEnabled else { return }
            connectionState = (devices.isEmpty && history == nil) ? .failed : .stale
            error = TokenMonitorIntegrationFailure.transport.displayMessage
        } catch is CancellationError {
            guard revision == configurationRevision else { return }
            connectionState = previousConnectionState
            error = previousError
        } catch {
            guard revision == configurationRevision, !requireEnabled || isEnabled else { return }
            connectionState = (devices.isEmpty && history == nil) ? .failed : .stale
            self.error = TokenMonitorIntegrationFailure.invalidResponse.displayMessage
        }
    }

    private func get(path: String, baseURL: URL, secret: String, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: Self.endpoint(baseURL, path: path))
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let transport else { throw TokenMonitorIntegrationFailure.invalidConfiguration }
        let result: TokenMonitorHTTPResponse
        do {
            result = try await transport.send(request, maximumResponseBytes: maximumBytes)
        } catch TokenMonitorHTTPTransportError.responseTooLarge {
            throw TokenMonitorIntegrationFailure.responseTooLarge
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TokenMonitorIntegrationFailure.transport
        }
        guard (200...299).contains(result.statusCode) else {
            throw TokenMonitorIntegrationFailure.httpStatus(result.statusCode)
        }
        return result.body
    }

    private func deviceID() -> String {
        if let existing = defaults?.string(forKey: Self.deviceIDKey) { return existing }
        let value = UUID().uuidString.lowercased()
        defaults?.set(value, forKey: Self.deviceIDKey)
        localDeviceID = value
        return value
    }

    private func localHostname() -> String {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let safe = TokenMonitorHubDevice.safeLabel(raw, maximum: 96).trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "This Mac" : safe
    }

    static func normalizeServerURL(_ rawValue: String) throws -> URL {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 512,
            var parts = URLComponents(string: raw),
            let scheme = parts.scheme?.lowercased(),
            let host = parts.host?.lowercased(), !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            !raw.contains("\\"), !raw.contains("\n"), !raw.contains("\r")
        else { throw TokenMonitorIntegrationFailure.invalidConfiguration }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost")
        guard (scheme == "https") || (scheme == "http" && loopback) else {
            throw TokenMonitorIntegrationFailure.unsafeTransport
        }
        let path = parts.percentEncodedPath
        guard path.utf8.count <= 128,
            path.split(separator: "/").allSatisfy({ $0.range(of: #"^[A-Za-z0-9._~-]{1,64}$"#, options: .regularExpression) != nil && $0 != "." && $0 != ".." })
        else { throw TokenMonitorIntegrationFailure.invalidConfiguration }
        parts.scheme = scheme
        parts.host = host
        parts.path = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let url = parts.url else { throw TokenMonitorIntegrationFailure.invalidConfiguration }
        return url
    }

    private static func endpoint(_ baseURL: URL, path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private static func makeUploadPayload(response: TokenMonitorResponse, deviceID: String, hostname: String, now: Date) throws -> TokenMonitorJSON {
        guard response.status != .error,
            let aggregate = response.payload["aggregate"],
            case .object = aggregate,
            let history = response.payload["history"]
        else { throw TokenMonitorIntegrationFailure.invalidResponse }
        let periodNames = ["today", "month", "allTime"]
        let allowedPeriodKeys: Set<String> = [
            "totalTokens", "costUsd", "cacheReadTokens", "cacheWriteTokens", "outputTokens", "unclassifiedTokens",
            "timedTokens", "timedOutputTokens", "timedDurationMs", "clients", "clientCosts", "clientCacheReads",
            "clientCacheWrites", "clientOutputs", "clientUnclassifiedTokens", "models", "modelCosts", "modelCacheReads",
            "modelCacheWrites", "modelOutputs", "modelUnclassifiedTokens", "clientModels", "clientModelCosts",
        ]
        var periodMap: [String: TokenMonitorJSON] = [:]
        for name in periodNames {
            if let source = aggregate[name], let object = source.object {
                periodMap[name] = .object(object.filter { allowedPeriodKeys.contains($0.key) })
            }
        }
        guard !periodMap.isEmpty else { throw TokenMonitorIntegrationFailure.invalidResponse }
        let safeHistory = publicHistory(history)
        let clients = aggregate["allTime"]?["clients"]?.object?.keys.sorted() ?? []
        let version =
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map {
                TokenMonitorHubDevice.safeLabel($0, maximum: 32)
            } ?? "unknown"
        var payload: [String: TokenMonitorJSON] = [
            "deviceId": .string(deviceID),
            "hostname": .string(hostname),
            "platform": .string("darwin"),
            "agentVersion": .string(version),
            "agentRuntime": .string("aigoodbro-macos"),
            "updatedAt": .string(ISO8601DateFormatter().string(from: now)),
            "trackedClients": .array(clients.map(TokenMonitorJSON.string)),
            "periods": .object(periodMap),
            "projectsEnabled": .bool(false),
        ]
        if let safeHistory { payload["history"] = safeHistory }
        return .object(payload)
    }

    private static func publicHistory(_ value: TokenMonitorJSON) -> TokenMonitorJSON? {
        guard let object = value.object else { return nil }
        let daily = object["daily"]?.array?.compactMap(safeDailyRow) ?? []
        let monthly = object["monthly"]?.array?.compactMap(safeMonthlyRow) ?? []
        let summary = safeSummary(object["summary"])
        return .object(["daily": .array(daily), "monthly": .array(monthly), "summary": summary ?? .object([:])])
    }

    private static func safeDailyRow(_ value: TokenMonitorJSON) -> TokenMonitorJSON? {
        guard let object = value.object, let date = object["date"]?.string, TokenMonitorResponse.validDate(date) else { return nil }
        var result = pick(object, keys: ["tokens", "cost", "messages", "activeTimeMs", "cacheReadTokens", "cacheWriteTokens", "outputTokens", "unclassifiedTokens"])
        result["date"] = .string(date)
        if let clients = publicBreakdown(object["perClient"]) { result["perClient"] = clients }
        if let models = publicBreakdown(object["perModel"]) { result["perModel"] = models }
        return .object(result)
    }

    private static func safeMonthlyRow(_ value: TokenMonitorJSON) -> TokenMonitorJSON? {
        guard let object = value.object, let month = object["month"]?.string,
            month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil
        else { return nil }
        var result = pick(object, keys: ["tokens", "cost", "activeTimeMs"])
        result["month"] = .string(month)
        if let clients = publicBreakdown(object["perClient"]) { result["perClient"] = clients }
        if let models = publicBreakdown(object["perModel"]) { result["perModel"] = models }
        return .object(result)
    }

    private static func publicBreakdown(_ value: TokenMonitorJSON?) -> TokenMonitorJSON? {
        guard let values = value?.object else { return nil }
        let result = values.reduce(into: [String: TokenMonitorJSON]()) { output, entry in
            guard TokenMonitorSource.safeID(entry.key), let metrics = entry.value.object else { return }
            output[entry.key] = .object(pick(metrics, keys: ["tokens", "cost", "cacheReadTokens", "cacheWriteTokens", "outputTokens", "unclassifiedTokens"]))
        }
        return result.isEmpty ? nil : .object(result)
    }

    private static func safeSummary(_ value: TokenMonitorJSON?) -> TokenMonitorJSON? {
        guard let object = value?.object else { return nil }
        var result = pick(object, keys: ["totalTokens", "totalCost", "totalCostUsd", "activeDays", "currentStreak", "longestStreak", "peakDayTokens", "messages", "activeTimeMs"])
        if let model = object["favoriteModel"]?.string {
            result["favoriteModel"] = .string(TokenMonitorHubDevice.safeLabel(model, maximum: 128))
        }
        return .object(result)
    }

    private static func pick(_ object: [String: TokenMonitorJSON], keys: [String]) -> [String: TokenMonitorJSON] {
        object.filter { keys.contains($0.key) && isScalarOrObject($0.value) }
    }

    private static func isScalarOrObject(_ value: TokenMonitorJSON) -> Bool {
        switch value {
        case .number, .bool, .string, .null: return true
        case .object(let object): return object.values.allSatisfy(isScalarOrObject)
        case .array: return false
        }
    }
}

private struct TokenMonitorHubStats: Decodable {
    let devices: [TokenMonitorHubDevice]
}
