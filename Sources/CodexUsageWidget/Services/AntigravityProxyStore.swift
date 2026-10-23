import AppKit
import Combine
import Darwin
import Foundation
import Security

/// User-started private OAuth account pool. Merely constructing or displaying
/// this store reads only masked metadata; it never reads Keychain or launches.
@MainActor
final class AntigravityProxyStore: ObservableObject {
    static let shared = AntigravityProxyStore()
    static let defaultPort = 18_081

    @Published private(set) var accounts: [AntigravityProxyAccount] = []
    @Published private(set) var phase: AntigravityProxyPhase = .stopped
    @Published private(set) var signInPending = false
    @Published private(set) var completedSignInAccountID: String?
    @Published private(set) var completedSignInProvider: AntigravityProxyProvider?
    @Published private(set) var port: Int?
    @Published private(set) var issue: String?
    @Published private(set) var models: [String] = []

    @Published private(set) var availableProviders: [AntigravityProxyProvider] = []
    @Published private(set) var authorizationUserCode: String?
    private var providerModels: [AntigravityProxyProvider: [String]] = [:]
    private var signInProvider: AntigravityProxyProvider?

    func endpoint(for provider: AntigravityProxyProvider) -> URL? {
        guard availableProviders.contains(provider) else { return nil }
        return endpoint?.appendingPathComponent("providers/\(provider.rawValue)")
    }
    func models(for provider: AntigravityProxyProvider) -> [String] { providerModels[provider] ?? [] }

    private(set) var clientKey: String?
    var endpoint: URL? { port.flatMap { URL(string: "http://127.0.0.1:\($0)") } }
    var canStart: Bool { process == nil && terminatingProcess == nil && (phase == .stopped || phase == .failed) }
    var canStop: Bool { process != nil || terminatingProcess != nil }
    var canFinishTermination: Bool { process == nil && terminatingProcess == nil }
    var hasActiveRequests: Bool { accounts.contains { $0.inFlight > 0 } }

    private let directory: URL
    private let helperOverride: URL?
    private let credentialStore: any AntigravityProxyCredentialStore
    private var records: [AntigravityProxyAccount] = []
    private var process: Process?
    private var terminatingProcess: Process?
    private var input: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var runID: UUID?
    private var signInSession: String?
    private var signInCancelling = false
    private var revoked = Set<String>()
    private var metadataValid = true

    init(
        supportDirectory: URL? = nil, helperURL: URL? = nil,
        credentialStore: any AntigravityProxyCredentialStore = AntigravityProxyKeychain()
    ) {
        directory = supportDirectory ?? DispatchParticipationPaths.supportDirectory().appendingPathComponent("AntigravityProxy", isDirectory: true)
        helperOverride = helperURL
        self.credentialStore = credentialStore
        do {
            let file = directory.appendingPathComponent("accounts-v1.json")
            let saved = FileManager.default.fileExists(atPath: file.path) ? try Self.readRecords(directory) : []
            records = saved
            accounts = saved.map { row in
                var row = row
                row.inFlight = 0
                row.state = row.enabled ? .checking : .disabled
                row.models = []
                return row
            }
        } catch {
            metadataValid = false
            issue = Self.message(for: error)
        }
    }

    func start(networkProxy: String = "") async {
        guard canStart else { return }
        phase = .starting
        issue = nil
        do {
            guard metadataValid else { throw AntigravityProxyFailure.invalidData }
            try prepareDirectory()
            let helper = try verifiedHelper()
            let client = try loadClientKey()
            var bootstrapAccounts: [[String: Any]] = []
            for row in records {
                guard row.hasValidIdentity,
                    let data = try credentialStore.read(Self.credentialKey(row.id, row.generation)),
                    let credential = try? JSONDecoder().decode(AntigravityProxyCredential.self, from: data),
                    credential.isValid, credential.provider == row.provider, credential.accountID == row.id, credential.generation == row.generation
                else { throw AntigravityProxyFailure.keychain }
                bootstrapAccounts.append([
                    "credential": try JSONSerialization.jsonObject(with: JSONEncoder().encode(credential)),
                    "enabled": row.enabled, "concurrencyLimit": row.concurrencyLimit,
                    "cooldownUntil": row.cooldownEpoch ?? 0,
                ])
            }
            let child = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            child.executableURL = helper
            child.currentDirectoryURL = directory
            child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            child.standardInput = stdin
            child.standardOutput = stdout
            child.standardError = FileHandle.nullDevice
            let run = UUID()
            runID = run
            process = child
            input = stdin.fileHandleForWriting
            clientKey = client
            child.terminationHandler = { [weak self] child in
                Task { @MainActor [weak self] in self?.exited(run: run, child: child) }
            }
            try child.run()
            try send([
                "schemaVersion": 1, "clientKey": client, "port": Self.defaultPort,
                "networkProxy": networkProxy, "accounts": bootstrapAccounts,
            ])
            let output = stdout.fileHandleForReading
            outputTask = Task.detached { [weak self] in
                var pending = Data()
                while !Task.isCancelled {
                    guard let bytes = await Self.readOutput(output) else { break }
                    pending.append(bytes)
                    if pending.count > 1_048_576 {
                        await self?.invalidOutput(run: run)
                        break
                    }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending.prefix(upTo: newline))
                        pending.removeSubrange(...newline)
                        await self?.consume(line, run: run)
                    }
                }
                try? output.close()
            }
            for _ in 0..<100 {
                if runID != run || phase != .starting { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if runID == run, phase == .starting { throw AntigravityProxyFailure.connection }
        } catch {
            stop()
            phase = .failed
            issue = Self.message(for: error)
        }
    }

    func stop() {
        signInSession = nil
        signInProvider = nil
        signInCancelling = false
        completedSignInAccountID = nil
        completedSignInProvider = nil
        authorizationUserCode = nil
        signInPending = false
        runID = nil
        try? send(["command": "shutdown"])
        try? input?.close()
        input = nil
        if let child = process, child.isRunning {
            terminatingProcess = child
            child.terminate()
        }
        process = nil
        outputTask?.cancel()
        outputTask = nil
        port = nil
        clientKey = nil
        models = []
        providerModels = [:]
        availableProviders = []
        accounts = records.map { row in
            var row = row
            row.inFlight = 0
            row.state = row.enabled ? .checking : .disabled
            row.models = []
            return row
        }
        phase = .stopped
    }

    /// The caller owns any confirmation for interrupting live requests.
    /// Only this store's exact child is stopped; no system CLI is searched.
    func finishForTermination() async {
        stop()
        for _ in 0..<50 {
            guard let child = terminatingProcess else { return }
            if !child.isRunning {
                terminatingProcess = nil
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Keep canFinishTermination false if the child has not confirmed exit.
        // The app's existing termination coordinator can present that failure.
    }

    func addAccount(provider: AntigravityProxyProvider = .antigravity) async {
        if canStart { await start() }
        guard phase == .running, !signInPending else { return }
        guard availableProviders.contains(provider) else {
            issue = "此平台的网页授权组件尚不可用。"
            return
        }
        do {
            let session = try Self.randomKey()
            signInSession = session
            signInProvider = provider
            signInCancelling = false
            completedSignInAccountID = nil
            completedSignInProvider = nil
            authorizationUserCode = nil
            signInPending = true
            issue = nil
            try send(["command": "auth", "requestID": session, "provider": provider.rawValue])
        } catch {
            signInSession = nil
            signInProvider = nil
            signInCancelling = false
            authorizationUserCode = nil
            signInPending = false
            issue = Self.message(for: error)
        }
    }

    func cancelSignIn() {
        guard signInPending, !signInCancelling, let session = signInSession else { return }
        signInCancelling = true
        authorizationUserCode = nil
        try? send(["command": "cancel_auth", "requestID": session])
        // Keep the session locked until the helper acknowledges its terminal
        // result; a rapid retry must not receive oauth_busy from the old run.
    }

    func removeAccount(_ id: String) {
        guard let row = records.first(where: { $0.id == id }) else { return }
        // Revoke locally before any asynchronous child event can write Keychain.
        revoked.insert(Self.credentialKey(id, row.generation))
        do {
            let remaining = records.filter { $0.id != id }
            if process != nil { try send(["command": "remove", "accountID": id, "generation": row.generation]) }
            // Keep the identity available for retry until secret deletion succeeds.
            // Keychain removal is idempotent if metadata persistence then fails.
            try credentialStore.remove(Self.credentialKey(id, row.generation))
            try saveRecords(remaining)
            records = remaining
            accounts.removeAll { $0.id == id }
            issue = nil
        } catch {
            stop()
            issue = Self.message(for: error)
        }
    }

    func setEnabled(_ id: String, enabled: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        do {
            var next = records
            next[index].enabled = enabled
            try saveRecords(next)
            records = next
            if let displayIndex = accounts.firstIndex(where: { $0.id == id }) { accounts[displayIndex].enabled = enabled }
            if process != nil {
                try send([
                    "command": "set_enabled", "accountID": id, "generation": records[index].generation,
                    "enabled": enabled, "concurrencyLimit": records[index].concurrencyLimit,
                ])
            }
        } catch {
            stop()
            issue = Self.message(for: error)
        }
    }

    func refreshStatus() {
        do {
            try send(["command": "snapshot"])
            try send(["command": "refresh_models"])
        } catch { issue = Self.message(for: error) }
    }

    private func consume(_ line: Data, run: UUID) {
        guard runID == run else { return }
        guard let event = try? JSONDecoder().decode(AntigravityProxyEvent.self, from: line),
            ["ready", "snapshot", "open_browser", "persist_credential", "auth_result", "error"].contains(event.event)
        else {
            invalidOutput(run: run)
            return
        }
        // Credential-bearing IPC is handled here and is never copied into
        // issue, status, telemetry, request logs or user-visible events.
        switch event.event {
        case "persist_credential":
            var accepted = false
            if let request = event.requestID, let credential = event.credential,
                credential.isValid, event.provider == credential.provider, event.accountID == credential.accountID, event.generation == credential.generation,
                !revoked.contains(Self.credentialKey(credential.accountID, credential.generation))
            {
                do {
                    try persistCredential(credential, purpose: event.purpose, session: event.sessionID)
                    accepted = true
                } catch { issue = Self.message(for: error) }
                try? send(["command": "persist_result", "requestID": request, "ok": accepted])
            } else if let request = event.requestID {
                try? send(["command": "persist_result", "requestID": request, "ok": false])
            }
        case "ready":
            guard let value = event.port, value == Self.defaultPort else {
                invalidOutput(run: run)
                return
            }
            let providers = event.providers ?? [.antigravity]
            guard Set(providers).count == providers.count else {
                invalidOutput(run: run)
                return
            }
            availableProviders = providers
            port = value
            phase = .running
        case "snapshot":
            let rows = event.accounts ?? []
            guard rows.count <= 100, rows.allSatisfy(\.hasValidIdentity), Set(rows.map(\.id)).count == rows.count else {
                invalidOutput(run: run)
                return
            }
            var changed = false
            accounts = rows.compactMap { row in
                guard let index = records.firstIndex(where: { $0.id == row.id && $0.generation == row.generation && $0.provider == row.provider }) else { return nil }
                var row = row
                row.enabled = records[index].enabled
                if row.cooldownEpoch != records[index].cooldownEpoch {
                    records[index].cooldownEpoch = row.cooldownEpoch
                    changed = true
                }
                return row
            }
            var catalogs: [AntigravityProxyProvider: [String]] = [:]
            let reported = event.providerModels ?? ["antigravity": event.models ?? []]
            for (name, values) in reported {
                guard let provider = AntigravityProxyProvider(rawValue: name), availableProviders.contains(provider) else {
                    invalidOutput(run: run)
                    return
                }
                let allowed = Set(accounts.filter { $0.enabled && $0.provider == provider }.flatMap(\.models))
                guard values.count <= 512, values.allSatisfy({ allowed.contains($0) }) else {
                    invalidOutput(run: run)
                    return
                }
                catalogs[provider] = Array(Set(values)).sorted()
            }
            providerModels = catalogs
            models = catalogs[.antigravity] ?? []
            if changed {
                do { try saveRecords(records) } catch {
                    stop()
                    issue = Self.message(for: error)
                }
            }
        case "open_browser":
            guard signInPending, !signInCancelling, event.sessionID == signInSession,
                let provider = signInProvider, (event.provider ?? .antigravity) == provider,
                let text = event.url, let url = Self.validatedAuthorizationURL(text, provider: provider, userCode: event.userCode)
            else { return }
            if let code = event.userCode {
                guard code.range(of: "^[A-Za-z0-9-]{1,32}$", options: .regularExpression) != nil else {
                    invalidOutput(run: run)
                    return
                }
                authorizationUserCode = code
            }
            if !NSWorkspace.shared.open(url) {
                cancelSignIn()
                issue = "无法打开网页授权页，请稍后重试。"
            }
        case "auth_result":
            guard event.sessionID == signInSession,
                let provider = signInProvider, event.provider == provider
            else { return }
            let cancelled = signInCancelling
            let existingIssue = issue
            var resultIssue: String?
            var completedAccountID: String?
            if cancelled || event.code == "oauth_cancelled" {
                resultIssue = nil
            } else if event.code == "ok",
                let id = event.accountID,
                records.contains(where: { $0.id == id && $0.provider == provider })
            {
                completedAccountID = id
            } else if event.code == "ok" {
                resultIssue = "授权结果与已保存账号不一致，请停止后重试。"
            } else if event.code == "credential_store_rejected", existingIssue != nil {
                resultIssue = existingIssue
            } else {
                resultIssue = Self.authorizationIssue(event.code)
            }
            // Publish the terminal result before unlocking the next attempt.
            issue = resultIssue
            completedSignInProvider = completedAccountID == nil ? nil : provider
            completedSignInAccountID = completedAccountID
            signInSession = nil
            signInProvider = nil
            signInCancelling = false
            authorizationUserCode = nil
            signInPending = false
        default:
            issue = "多平台代理未能完成操作，请停止后重试。"
        }
    }

    private func persistCredential(_ credential: AntigravityProxyCredential, purpose: String?, session: String?) throws {
        let key = Self.credentialKey(credential.accountID, credential.generation)
        if purpose == "refresh" {
            guard records.contains(where: { $0.id == credential.accountID && $0.generation == credential.generation && $0.provider == credential.provider }) else {
                throw AntigravityProxyFailure.invalidData
            }
            try credentialStore.save(JSONEncoder().encode(credential), account: key)
        } else if purpose == "add" {
            guard signInPending, !signInCancelling, signInSession == session, signInProvider == credential.provider, records.count < 100,
                !records.contains(where: { $0.id == credential.accountID })
            else { throw AntigravityProxyFailure.invalidData }
            let encoded = try JSONEncoder().encode(credential)
            try credentialStore.save(encoded, account: key)
            do {
                guard try credentialStore.read(key) == encoded else { throw AntigravityProxyFailure.keychain }
                let next = records + [credential.account]
                try saveRecords(next)
                records = next
                accounts = next
            } catch {
                try? credentialStore.remove(key)
                throw error
            }
        } else {
            throw AntigravityProxyFailure.invalidData
        }
    }

    static func validatedAuthorizationURL(_ text: String, provider: AntigravityProxyProvider = .antigravity, userCode: String? = nil) -> URL? {
        if provider == .kimi || provider == .xai {
            guard let userCode, userCode.range(of: "^[A-Za-z0-9-]{1,32}$", options: .regularExpression) != nil,
                text.utf8.count < 8_192, let parts = URLComponents(string: text), parts.scheme == "https",
                parts.port == nil, parts.user == nil, parts.password == nil, parts.fragment == nil,
                let query = parts.queryItems, query.count == 1, query[0].name == "user_code", query[0].value == userCode
            else { return nil }
            let hosts = provider == .kimi ? ["www.kimi.com", "kimi.com"] : ["accounts.x.ai", "auth.x.ai"]
            let path = provider == .kimi ? "/code/authorize_device" : "/oauth2/device"
            guard hosts.contains(parts.host ?? ""), parts.path == path else { return nil }
            return parts.url
        }
        if provider != .antigravity {
            guard provider == .claude, text.utf8.count < 8_192,
                let parts = URLComponents(string: text), parts.scheme == "https", parts.host == "claude.ai",
                parts.path == "/oauth/authorize", parts.port == nil, parts.user == nil, parts.password == nil,
                parts.fragment == nil, let query = parts.queryItems
            else { return nil }
            func one(_ name: String) -> String? {
                let values = query.filter { $0.name == name }
                return values.count == 1 ? values.first?.value : nil
            }
            guard one("response_type") == "code", one("code_challenge_method") == "S256",
                one("redirect_uri") == "http://localhost:54545/callback",
                one("state")?.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
                one("code_challenge")?.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
            else { return nil }
            return parts.url
        }
        guard text.utf8.count < 8_192, let parts = URLComponents(string: text), parts.scheme == "https",
            parts.host == "accounts.google.com", parts.port == nil, parts.user == nil, parts.password == nil,
            parts.path == "/o/oauth2/v2/auth", parts.fragment == nil,
            let query = parts.queryItems
        else { return nil }
        func one(_ name: String) -> String? {
            let values = query.filter { $0.name == name }
            return values.count == 1 ? values.first?.value : nil
        }
        guard one("code_challenge_method") == "S256", one("response_type") == "code",
            let state = one("state"), state.count >= 32,
            let challenge = one("code_challenge"), challenge.count == 43,
            let redirect = one("redirect_uri"), let callback = URLComponents(string: redirect),
            callback.scheme == "http", callback.host == "127.0.0.1", callback.user == nil, callback.password == nil,
            callback.path == "/oauth-callback", callback.query == nil, callback.fragment == nil,
            let callbackPort = callback.port, (1...65_535).contains(callbackPort)
        else { return nil }
        return parts.url
    }

    private func send(_ value: [String: Any]) throws {
        guard let input else { throw AntigravityProxyFailure.connection }
        var data = try JSONSerialization.data(withJSONObject: value)
        guard data.count < 1_048_576 else { throw AntigravityProxyFailure.invalidData }
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func loadClientKey() throws -> String {
        if let data = try credentialStore.read("client-key"), let key = String(data: data, encoding: .utf8), (32...256).contains(key.utf8.count) { return key }
        let key = try Self.randomKey()
        try credentialStore.save(Data(key.utf8), account: "client-key")
        return key
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let properties = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard properties.isSymbolicLink == false, properties.isDirectory == true,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
        else { throw AntigravityProxyFailure.storage }
    }

    private func saveRecords(_ values: [AntigravityProxyAccount]) throws {
        try prepareDirectory()
        let file = directory.appendingPathComponent("accounts-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink == false else { throw AntigravityProxyFailure.storage }
        }
        let data = try JSONEncoder().encode(values)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func readRecords(_ directory: URL) throws -> [AntigravityProxyAccount] {
        let file = directory.appendingPathComponent("accounts-v1.json")
        let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink == false, (properties.fileSize ?? Int.max) <= 1_048_576 else {
            throw AntigravityProxyFailure.storage
        }
        let rows = try JSONDecoder().decode([AntigravityProxyAccount].self, from: Data(contentsOf: file))
        guard rows.count <= 100, rows.allSatisfy(\.hasValidIdentity), Set(rows.map(\.id)).count == rows.count else {
            throw AntigravityProxyFailure.invalidData
        }
        return rows
    }

    private func verifiedHelper() throws -> URL {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("AntigravityProxy/aigoodbro-antigravity-proxy") else {
            throw AntigravityProxyFailure.unavailable
        }
        let helper = helperOverride ?? bundled
        let properties = try helper.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink == false, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AntigravityProxyFailure.unavailable
        }
        for url in helperOverride == nil ? [Bundle.main.bundleURL, helper] : [helper] {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess
            else { throw AntigravityProxyFailure.unavailable }
        }
        return helper
    }

    private static func credentialKey(_ id: String, _ generation: String) -> String { "account.\(id).\(generation)" }

    private static func randomKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AntigravityProxyFailure.unavailable }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func invalidOutput(run: UUID) {
        guard runID == run else { return }
        stop()
        phase = .failed
        issue = "多平台代理返回了无效状态，已停止。"
    }

    private func exited(run: UUID, child: Process) {
        if terminatingProcess === child { terminatingProcess = nil }
        guard runID == run else { return }
        stop()
        phase = .failed
        issue = "多平台代理已退出，请重新启动。"
    }

    private static func authorizationIssue(_ code: String?) -> String {
        guard let code else { return "账号授权未完成，请重新登录。" }
        switch code {
        case "account_exists": return "这个账号已在授权账号池中。"
        case "oauth_busy": return "上一次授权尚未结束，请稍后重试。"
        case "oauth_timeout": return "网页授权已超时，请重新添加账号。"
        case "oauth_denied": return "网页授权被拒绝，请重新选择账号。"
        case "oauth_browser_unavailable": return "无法打开网页授权页，请稍后重试。"
        case "oauth_listener_unavailable": return "本机授权回调端口不可用，请稍后重试。"
        case "oauth_token_exchange_failed": return "授权码交换失败，请重新登录。"
        case "oauth_identity_failed", "oauth_identity_mismatch": return "授权已返回，但无法确认账号身份。"
        case "oauth_project_failed": return "账号已授权，但无法确认项目权限。"
        case "credential_store_rejected", "credential_store_timeout", "credential_store_unavailable":
            return "授权凭据未能保存，请检查本机钥匙串或存储权限。"
        case "provider_unavailable": return "此平台的网页授权组件尚不可用。"
        default:
            if code.hasPrefix("oauth_token_exchange_failed_http_") { return "授权码交换被服务端拒绝，请重新登录。" }
            if code.hasPrefix("oauth_identity_failed_http_") { return "无法从服务端确认授权账号身份。" }
            if code.hasPrefix("oauth_project_failed_http_") { return "无法从服务端确认项目权限。" }
            return "账号授权未完成，请重新登录。"
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AntigravityProxyFailure.keychain: return "无法读取或保存授权凭据，请解锁系统钥匙串后重试。"
        case AntigravityProxyFailure.storage: return "无法保存授权账号池，请检查本机存储权限。"
        case AntigravityProxyFailure.invalidData: return "授权账号状态不一致，请停止后重试。"
        case AntigravityProxyFailure.connection: return "无法连接多平台代理，请检查 18081 端口是否可用。"
        default: return "多平台代理组件不可用，请检查应用安装。"
        }
    }

    nonisolated private static func readOutput(_ file: FileHandle) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var bytes = [UInt8](repeating: 0, count: 4_096)
                var count: Int
                repeat { count = Darwin.read(file.fileDescriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
                continuation.resume(returning: count > 0 ? Data(bytes.prefix(count)) : nil)
            }
        }
    }
}
