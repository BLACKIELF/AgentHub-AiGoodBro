import Cocoa
import CryptoKit
import Darwin
import Foundation

enum CodexCredentialAccessGate {
    static let lock = NSRecursiveLock()

    private static let registryLock = NSLock()
    private static var homeLocks: [String: NSRecursiveLock] = [:]

    /// 系统默认登录（官方 Codex 正在使用的 home）以外，只读额度读取按 home 串行；
    /// 同一 home 的读取互斥，不同 home 之间允许并发。
    static func homeLock(forHomePath path: String) -> NSRecursiveLock {
        let key = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = homeLocks[key] { return existing }
        let created = NSRecursiveLock()
        homeLocks[key] = created
        return created
    }
}

enum CodexLoginError: LocalizedError {
    case browserUnavailable
    case cancelled
    case credentialsUnavailable
    case identityMismatch
    case message(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .browserUnavailable: return WidgetLanguage.storedOrAutomatic().text("无法打开官方登录网页", "Could not open the official sign-in page.")
        case .cancelled: return WidgetLanguage.storedOrAutomatic().text("登录已取消，原账号未受影响", "Sign-in was canceled. The original account is unchanged.")
        case .credentialsUnavailable: return WidgetLanguage.storedOrAutomatic().text("官方登录已完成，但没有生成可保存的本机凭据", "Sign-in completed, but no local credentials were available to save.")
        case .identityMismatch:
            return WidgetLanguage.storedOrAutomatic().text("登录身份与这张账号卡不一致，未写入原账号", "The signed-in identity does not match this account card. Nothing was overwritten.")
        case .message(let message): return message
        case .timedOut: return WidgetLanguage.storedOrAutomatic().text("等待官方登录完成超时，原账号未受影响", "Sign-in timed out. The original account is unchanged.")
        }
    }
}

private enum CodexLoginProtocolState: Equatable {
    case initializing
    case starting
    case waiting(loginID: String)
    case readingAccount
    case finished
}

private enum CodexLoginProtocolEvent: Equatable {
    case none
    case initialized
    case loginStarted(loginID: String, authURL: String)
    case loginCompleted
    case authenticated(email: String)
    case failed(String)
}

private enum CodexLoginProtocolParser {
    static func event(
        from object: [String: Any],
        state: CodexLoginProtocolState
    ) -> CodexLoginProtocolEvent {
        if object["method"] as? String == "account/login/completed" {
            guard case .waiting(let expectedLoginID) = state,
                let params = object["params"] as? [String: Any]
            else { return .none }
            if let receivedLoginID = params["loginId"] as? String,
                receivedLoginID != expectedLoginID
            {
                return .none
            }
            guard params["success"] as? Bool == true else {
                return .failed(nonEmpty(params["error"] as? String) ?? WidgetLanguage.storedOrAutomatic().text("官方登录未完成", "Sign-in did not complete."))
            }
            return .loginCompleted
        }

        guard let responseID = integerID(object["id"]) else { return .none }
        if let error = object["error"] as? [String: Any] {
            return .failed(nonEmpty(error["message"] as? String) ?? WidgetLanguage.storedOrAutomatic().text("官方登录服务返回错误", "The sign-in service returned an error."))
        }
        switch (state, responseID) {
        case (.initializing, 1):
            return .initialized
        case (.starting, 2):
            guard let result = object["result"] as? [String: Any],
                result["type"] as? String == "chatgpt",
                let loginID = nonEmpty(result["loginId"] as? String),
                let authURL = nonEmpty(result["authUrl"] as? String)
            else { return .failed(WidgetLanguage.storedOrAutomatic().text("官方登录服务返回了无法识别的响应", "The sign-in service returned an unrecognized response.")) }
            return .loginStarted(loginID: loginID, authURL: authURL)
        case (.readingAccount, 3):
            guard let result = object["result"] as? [String: Any],
                let account = result["account"] as? [String: Any],
                account["type"] as? String == "chatgpt",
                let email = nonEmpty(account["email"] as? String)
            else { return .failed(WidgetLanguage.storedOrAutomatic().text("登录完成，但无法确认账号身份", "Sign-in completed, but the account identity could not be verified.")) }
            return .authenticated(email: email)
        default:
            return .none
        }
    }

    private static func integerID(_ value: Any?) -> Int64? {
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ChromeProfileBrowser {
    private struct Record {
        let binding: ChromeProfileBinding
        let normalizedUserName: String?
    }

    static func availableProfiles(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ChromeProfileBinding] {
        records(fileManager: fileManager, homeDirectory: homeDirectory).map(\.binding)
    }

    static func matchingProfile(
        for accountEmail: String?,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ChromeProfileBinding? {
        let normalized = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !normalized.isEmpty else { return nil }
        return records(fileManager: fileManager, homeDirectory: homeDirectory)
            .first { $0.normalizedUserName == normalized }?
            .binding
    }

    static func open(
        _ url: URL,
        binding: ChromeProfileBinding?,
        managedUserDataDirectory: URL? = nil,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard url.scheme?.lowercased() == "https" else { throw CodexLoginError.browserUnavailable }
        guard binding != nil || managedUserDataDirectory != nil else {
            guard NSWorkspace.shared.open(url) else { throw CodexLoginError.browserUnavailable }
            return
        }
        if let binding {
            guard binding.isValid,
                records(fileManager: fileManager, homeDirectory: homeDirectory)
                    .contains(where: { $0.binding.directoryName == binding.directoryName })
            else {
                throw CodexLoginError.message(
                    WidgetLanguage.storedOrAutomatic().text("绑定的 Chrome 用户资料不可用，请重新选择后再登录", "The linked Chrome profile is unavailable. Select it again before signing in."))
            }
        }
        if let managedUserDataDirectory {
            do {
                try fileManager.createDirectory(
                    at: managedUserDataDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: managedUserDataDirectory.path
                )
            } catch {
                throw CodexLoginError.message(WidgetLanguage.storedOrAutomatic().text("无法准备账号专属 Chrome 会话", "Could not prepare an isolated Chrome session for this account."))
            }
        }
        guard let executable = chromeExecutable(fileManager: fileManager) else {
            throw CodexLoginError.message(
                WidgetLanguage.storedOrAutomatic().text("未找到 Google Chrome，无法打开账号专属登录窗口", "Google Chrome was not found. The account's sign-in window could not be opened."))
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = launchArguments(
            binding: binding,
            managedUserDataDirectory: managedUserDataDirectory,
            url: url
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CodexLoginError.browserUnavailable
        }
    }

    fileprivate static func launchArguments(
        binding: ChromeProfileBinding?,
        managedUserDataDirectory: URL? = nil,
        url: URL
    ) -> [String] {
        if let binding {
            return ["--profile-directory=\(binding.directoryName)", "--new-window", url.absoluteString]
        }
        if let managedUserDataDirectory {
            return [
                "--user-data-dir=\(managedUserDataDirectory.path)",
                "--profile-directory=Default",
                "--no-first-run",
                "--new-window",
                url.absoluteString,
            ]
        }
        return ["--new-window", url.absoluteString]
    }

    private static func records(fileManager: FileManager, homeDirectory: URL) -> [Record] {
        let chromeRoot =
            homeDirectory
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        let localStateURL = chromeRoot.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localStateURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = object["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: Any]
        else { return [] }

        return infoCache.compactMap { directoryName, rawValue -> Record? in
            guard let value = rawValue as? [String: Any],
                fileManager.fileExists(
                    atPath: chromeRoot.appendingPathComponent(directoryName, isDirectory: true).path
                ),
                let binding = ChromeProfileBinding(
                    directoryName: directoryName,
                    displayName: value["name"] as? String ?? directoryName
                )
            else { return nil }
            let userName = (value["user_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return Record(binding: binding, normalizedUserName: userName?.isEmpty == false ? userName : nil)
        }
        .sorted {
            if $0.binding.directoryName == "Default" { return true }
            if $1.binding.directoryName == "Default" { return false }
            return $0.binding.displayName.localizedStandardCompare($1.binding.displayName) == .orderedAscending
        }
    }

    private static func chromeExecutable(fileManager: FileManager) -> URL? {
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")?
                .appendingPathComponent("Contents/MacOS/Google Chrome"),
            URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

private final class CodexLoginSession {
    private let profile: CodexProfile
    private let browserChoice: CodexDeviceBrowserChoice
    private let executableURL: URL
    private let fileManager: FileManager
    let stagingHomeURL: URL
    private let completion: (Result<Void, Error>) -> Void
    private let onPhaseChange: (CodexDeviceLoginPhase) -> Void
    private let completionQueue: DispatchQueue
    private let browserOpener: ((CodexProfile, URL, CodexDeviceBrowserChoice) -> Bool)?
    private let queue = DispatchQueue(label: "com.blackielf.codex-account-manager-next.account-login", qos: .userInitiated)
    private let worker = DispatchQueue(label: "com.blackielf.codex-account-manager-next.account-login.process", qos: .utility)
    private var parser = CodexDeviceCodeParser()
    private var authorization: CodexDeviceAuthorization?
    private var cancellation: CodexLoginError?
    private var browserOpening = false
    private var isFinished = false
    private var started = false
    private var startedAt = Date()

    init(
        profile: CodexProfile,
        browserChoice: CodexDeviceBrowserChoice,
        executableURL: URL,
        fileManager: FileManager = .default,
        completionQueue: DispatchQueue = .main,
        browserOpener: ((CodexProfile, URL, CodexDeviceBrowserChoice) -> Bool)? = nil,
        onPhaseChange: @escaping (CodexDeviceLoginPhase) -> Void = { _ in },
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard !profile.isSystemProfile else { throw CodexLoginError.identityMismatch }
        self.profile = profile
        self.browserChoice = browserChoice
        self.executableURL = executableURL
        self.fileManager = fileManager
        self.completion = completion
        self.completionQueue = completionQueue
        self.onPhaseChange = onPhaseChange
        self.browserOpener = browserOpener
        stagingHomeURL = fileManager.temporaryDirectory
            .appendingPathComponent("camnext-login-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingHomeURL.path)
    }

    func start() throws {
        queue.async {
            guard !self.started, !self.isFinished else { return }
            self.started = true
            self.startedAt = Date()
            self.parser = CodexDeviceCodeParser(startedAt: self.startedAt)
            self.worker.async { self.run() }
        }
    }

    private func run() {
        var environment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = stagingHomeURL.path
        environment["RUST_LOG"] = "off"
        let result: Result<Void, Error>
        do {
            _ = try BoundedLocalProcess.run(
                executable: executableURL,
                arguments: ["login", "--device-auth", "-c", "cli_auth_credentials_store=\"file\""],
                environment: environment, maximumOutputBytes: CodexDeviceCodeParser.maximumBytes, timeout: 15 * 60,
                stream: { data in
                    try self.queue.sync {
                        guard self.cancellation == nil else { throw CodexLoginError.cancelled }
                        try self.parser.consume(data)
                        if self.authorization == nil, let authorization = self.parser.authorization {
                            self.authorization = authorization
                            self.emit(.waiting(authorization, .opening))
                            self.openPageOnQueue()
                        }
                    }
                },
                isCancelled: {
                    self.queue.sync {
                        let deadline = self.authorization?.expiresAt ?? self.startedAt.addingTimeInterval(120)
                        if self.cancellation == nil, Date() >= deadline {
                            self.cancellation = .timedOut
                            self.authorization = nil
                            self.emit(.cancelling)
                        }
                        return self.cancellation != nil
                    }
                },
                includeStandardError: true, awaitCleanup: true
            )
            result = .success(())
        } catch {
            // Raw CLI text and generic system errors never reach the UI or logs.
            if error is CodexDeviceLoginFailure {
                result = .failure(CodexDeviceLoginFailure.invalidResponse)
            } else if case BoundedLocalProcessError.outputTooLarge = error {
                result = .failure(CodexDeviceLoginFailure.invalidResponse)
            } else {
                result = .failure(CodexDeviceLoginFailure.unavailable)
            }
        }
        // run returns only after its owned process group is gone, including cancellation.
        queue.async { self.completeAfterChildStops(result) }
    }

    func cancel() {
        queue.async {
            guard !self.isFinished else { return }
            self.cancellation = .cancelled
            self.authorization = nil
            self.emit(.cancelling)
        }
    }

    func reopenPage() {
        queue.async {
            guard !self.isFinished, self.cancellation == nil, !self.browserOpening,
                let authorization = self.authorization, authorization.isValid()
            else { return }
            self.emit(.waiting(authorization, .opening))
            self.openPageOnQueue()
        }
    }

    private func openPageOnQueue() {
        guard !isFinished, cancellation == nil, !browserOpening,
            let authorization, authorization.isValid()
        else { return }
        browserOpening = true
        let choice = browserChoice
        let browserQueue = browserOpener == nil ? DispatchQueue.main : completionQueue
        browserQueue.async {
            guard self.queue.sync(execute: { !self.isFinished && self.cancellation == nil && authorization.isValid() }) else { return }
            let opened: Bool
            if let browserOpener = self.browserOpener {
                opened = browserOpener(self.profile, authorization.url, choice)
            } else {
                let plan = CodexDeviceBrowserRouting.launchPlan(choice: choice, profile: self.profile)
                do {
                    try ChromeProfileBrowser.open(
                        authorization.url, binding: plan.binding, managedUserDataDirectory: plan.managedUserDataDirectory)
                    opened = true
                } catch { opened = false }
            }
            self.queue.async {
                self.browserOpening = false
                guard !self.isFinished, self.cancellation == nil, authorization.isValid() else { return }
                self.emit(.waiting(authorization, opened ? .opened : .unavailable))
            }
        }
    }

    private func emit(_ phase: CodexDeviceLoginPhase) {
        completionQueue.async { [onPhaseChange] in onPhaseChange(phase) }
    }

    private func completeAfterChildStops(_ processResult: Result<Void, Error>) {
        guard !isFinished else { return }
        var result = processResult
        if let cancellation {
            result = .failure(cancellation)
        } else if case .success = result {
            parser.finish()
            do {
                guard parser.authorization != nil else { throw CodexDeviceLoginFailure.invalidResponse }
                emit(.verifying)
                let authURL = stagingHomeURL.appendingPathComponent("auth.json")
                guard let data = try? DispatchParticipationSync.readBoundedRegularFile(authURL, maximumBytes: 1024 * 1024),
                    let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data)
                else { throw CodexLoginError.credentialsUnavailable }
                try Self.promoteCredentials(from: stagingHomeURL, to: profile, authenticatedEmail: identity.email, fileManager: fileManager)
            } catch { result = .failure(error) }
        }
        isFinished = true
        authorization = nil
        parser = CodexDeviceCodeParser()
        finishCleanup(result)
    }

    private func finishCleanup(_ result: Result<Void, Error>) {
        do {
            if fileManager.fileExists(atPath: stagingHomeURL.path) { try fileManager.removeItem(at: stagingHomeURL) }
        } catch {
            queue.asyncAfter(deadline: .now() + 1) { self.finishCleanup(result) }
            return
        }
        completionQueue.async { [completion] in completion(result) }
    }

    fileprivate static func promoteCredentials(
        from stagingHomeURL: URL,
        to profile: CodexProfile,
        authenticatedEmail: String,
        fileManager: FileManager
    ) throws {
        CodexCredentialAccessGate.lock.lock()
        defer { CodexCredentialAccessGate.lock.unlock() }
        let homes = Set([stagingHomeURL, profile.codexHomeURL].map { CodexCredentialTransaction.canonical($0).path }).sorted()
        guard homes.count == 2 else { throw CodexCredentialTransaction.Failure.invalidRoot }
        let locks = homes.map { CodexCredentialAccessGate.homeLock(forHomePath: $0) }
        locks.forEach { $0.lock() }
        defer { locks.reversed().forEach { $0.unlock() } }
        let stagedAuthURL = stagingHomeURL.appendingPathComponent("auth.json")
        let targetAuthURL = profile.codexHomeURL.appendingPathComponent("auth.json")
        guard let authData = try? DispatchParticipationSync.readBoundedRegularFile(stagedAuthURL, maximumBytes: 1024 * 1024),
            let object = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any],
            tokens["access_token"] is String
        else { throw CodexLoginError.credentialsUnavailable }
        guard let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: authData),
            identity.email == normalizedEmail(authenticatedEmail),
            profile.matchesRecordedAccount(email: identity.email),
            profile.lastSnapshot?.accountID == nil
                || profile.lastSnapshot?.accountID == identity.accountID
        else { throw CodexLoginError.identityMismatch }

        let credentialLock =
            profile.isSystemProfile
            ? CodexCredentialAccessGate.lock
            : CodexCredentialAccessGate.homeLock(forHomePath: profile.codexHomePath)
        credentialLock.lock()
        defer { credentialLock.unlock() }
        let previousAuth = try DispatchParticipationSync.readBoundedRegularFile(targetAuthURL, maximumBytes: 1024 * 1024, allowMissing: true)
        var wroteAuth = false
        do {
            try fileManager.createDirectory(
                at: profile.codexHomeURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.codexHomePath)
            guard try CodexCredentialTransaction.read(stagedAuthURL) == authData,
                try CodexCredentialTransaction.read(targetAuthURL) == previousAuth
            else { throw CodexCredentialTransaction.Failure.superseded }
            try authData.write(to: targetAuthURL, options: .atomic)
            wroteAuth = true
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetAuthURL.path)
            guard try DispatchParticipationSync.readBoundedRegularFile(targetAuthURL, maximumBytes: 1024 * 1024) == authData else {
                throw CodexLoginError.credentialsUnavailable
            }
        } catch {
            if wroteAuth {
                try CodexCredentialTransaction.restoreOwned(
                    previous: previousAuth, written: authData, at: targetAuthURL, fileManager: fileManager
                )
            }
            throw error
        }
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    static func deviceSessionSelfTest() -> Bool {
        let callbacks = DispatchQueue(label: "next.device-session-test.callback")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-session-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let target = root.appendingPathComponent("profile")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let authURL = target.appendingPathComponent("auth.json")
            let original = Data("original-fixture-credentials".utf8)
            try original.write(to: authURL)
            let profile = CodexProfile(id: "synthetic-A", name: "Demo A", codexHomePath: target.path, isSystemProfile: false, createdAt: Date())
            for scenario in ["cancel", "expire", "early-exit", "missing-credentials"] {
                let executable = root.appendingPathComponent(scenario)
                let lifetime = scenario == "expire" ? "1 second" : "15 minutes"
                let ending = scenario == "early-exit" ? "exit 7" : scenario == "missing-credentials" ? "exit 0" : "exec /bin/sleep 30"
                let script = "#!/bin/sh\nprintf '%s\\n' 'https://auth.openai.com/codex/device' 'Enter this one-time code (expires in \(lifetime))' 'DEMO-ONLY' >&2\n\(ending)\n"
                try script.write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
                let ready = DispatchSemaphore(value: 0)
                let completed = DispatchSemaphore(value: 0)
                var openCount = 0
                var wrongTarget = false
                var completionError: Error?
                let session = try CodexLoginSession(
                    profile: profile, browserChoice: .dedicatedChrome, executableURL: executable, completionQueue: callbacks,
                    browserOpener: { frozenProfile, url, choice in
                        openCount += 1
                        wrongTarget =
                            wrongTarget || frozenProfile.id != "synthetic-A" || url != CodexDeviceCodeParser.officialURL
                            || choice != .dedicatedChrome
                        return false
                    },
                    onPhaseChange: { phase in
                        if case .waiting(_, .unavailable) = phase { ready.signal() }
                    },
                    completion: { result in
                        if case .failure(let error) = result { completionError = error }
                        completed.signal()
                    }
                )
                try session.start()
                if scenario == "cancel" {
                    guard ready.wait(timeout: .now() + 3) == .success else {
                        session.cancel()
                        return false
                    }
                    session.reopenPage()
                    guard ready.wait(timeout: .now() + 3) == .success else {
                        session.cancel()
                        return false
                    }
                    session.reopenPage()
                    guard ready.wait(timeout: .now() + 3) == .success,
                        callbacks.sync(execute: { openCount == 3 && !wrongTarget })
                    else {
                        session.cancel()
                        return false
                    }
                    session.cancel()
                }
                guard completed.wait(timeout: .now() + 5) == .success,
                    callbacks.sync(execute: { completionError != nil }),
                    !FileManager.default.fileExists(atPath: session.stagingHomeURL.path),
                    try Data(contentsOf: authURL) == original
                else {
                    session.cancel()
                    return false
                }
                if scenario == "expire" {
                    guard case CodexLoginError.timedOut? = callbacks.sync(execute: { completionError as? CodexLoginError }) else { return false }
                }
            }
            let boundProfile = CodexProfile(
                id: "synthetic-A", name: "Demo A", codexHomePath: target.path, isSystemProfile: false, createdAt: Date(),
                chromeProfile: ChromeProfileBinding(directoryName: "Default", displayName: "Personal"))
            guard let personalBinding = boundProfile.chromeProfile else { return false }
            let dedicatedPlan = CodexDeviceBrowserRouting.launchPlan(choice: .dedicatedChrome, profile: boundProfile)
            let defaultPlan = CodexDeviceBrowserRouting.launchPlan(choice: .systemDefault, profile: boundProfile)
            guard dedicatedPlan.binding == nil,
                dedicatedPlan.managedUserDataDirectory == boundProfile.codexHomeURL.appendingPathComponent("chrome-session", isDirectory: true),
                defaultPlan.binding == nil,
                defaultPlan.managedUserDataDirectory == nil,
                personalBinding.directoryName == "Default"
            else { return false }
            var frozenChoices: [CodexDeviceBrowserChoice] = []
            let freezeExecutable = root.appendingPathComponent("freeze")
            try "#!/bin/sh\nprintf '%s\\n' 'https://auth.openai.com/codex/device' 'Enter this one-time code (expires in 15 minutes)' 'DEMO-ONLY' >&2\nexec /bin/sleep 30\n"
                .write(to: freezeExecutable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: freezeExecutable.path)
            let freezeReady = DispatchSemaphore(value: 0)
            let freezeDone = DispatchSemaphore(value: 0)
            let freezeSession = try CodexLoginSession(
                profile: boundProfile, browserChoice: .systemDefault, executableURL: freezeExecutable, completionQueue: callbacks,
                browserOpener: { _, _, choice in
                    frozenChoices.append(choice)
                    return true
                },
                onPhaseChange: { phase in
                    if case .waiting(_, .opened) = phase { freezeReady.signal() }
                },
                completion: { _ in freezeDone.signal() }
            )
            try freezeSession.start()
            guard freezeReady.wait(timeout: .now() + 3) == .success else {
                freezeSession.cancel()
                return false
            }
            freezeSession.reopenPage()
            guard freezeReady.wait(timeout: .now() + 3) == .success else {
                freezeSession.cancel()
                return false
            }
            freezeSession.cancel()
            guard freezeDone.wait(timeout: .now() + 5) == .success,
                callbacks.sync(execute: { frozenChoices }) == [.systemDefault, .systemDefault]
            else { return false }
            print("device session cancellation, expiry, browser retry, exit and credential-preservation self-test passed")
            return true
        } catch { return false }
    }

    static func cleanupSelfTest() -> Bool {
        let callbacks = DispatchQueue(label: "next.login-cleanup-test.callback")
        let completed = DispatchSemaphore(value: 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-login-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("fixture")
            let pidFile = root.appendingPathComponent("pid")
            let script = "#!/bin/sh\nprintf '%s' $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let profile = CodexProfile(
                id: "cleanup-fixture", name: "Fixture", codexHomePath: root.appendingPathComponent("profile").path, isSystemProfile: false, createdAt: Date())
            var count = 0
            let session = try CodexLoginSession(
                profile: profile, browserChoice: .systemDefault, executableURL: executable, completionQueue: callbacks
            ) { _ in
                count += 1
                completed.signal()
            }
            try session.start()
            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)), Darwin.kill(pid, 0) == 0 else {
                session.cancel()
                return false
            }
            session.cancel()
            guard completed.wait(timeout: .now() + 5) == .success,
                callbacks.sync(execute: { count }) == 1,
                Darwin.kill(pid, 0) != 0, errno == ESRCH,
                !FileManager.default.fileExists(atPath: session.stagingHomeURL.path)
            else { return false }
            let failed = DispatchSemaphore(value: 0)
            let missing = try CodexLoginSession(
                profile: profile, browserChoice: .dedicatedChrome, executableURL: root.appendingPathComponent("missing"),
                completionQueue: callbacks
            ) { result in
                if case .failure = result { failed.signal() }
            }
            try missing.start()
            return failed.wait(timeout: .now() + 3) == .success && !FileManager.default.fileExists(atPath: missing.stagingHomeURL.path)
        } catch { return false }
    }
}

private enum CodexWarmUpFailure: LocalizedError, Equatable {
    case credentialsUnavailable
    case identityMismatch
    case invalidRequest
    case redirected
    case timedOut
    case networkUnavailable
    case unauthorized
    case forbidden
    case rateLimited
    case serviceUnavailable
    case rejected(Int)
    case streamFailed
    case incompleteStream
    case oversizedStream

    var persistenceCode: String {
        switch self {
        case .credentialsUnavailable: return "credentials-unavailable"
        case .identityMismatch: return "identity-mismatch"
        case .invalidRequest: return "invalid-request"
        case .redirected: return "redirected"
        case .timedOut: return "timeout"
        case .networkUnavailable: return "network"
        case .unauthorized: return "http-401"
        case .forbidden: return "http-403"
        case .rateLimited: return "http-429"
        case .serviceUnavailable: return "http-5xx"
        case .rejected(let status): return "http-\(status)"
        case .streamFailed: return "stream-failed"
        case .incompleteStream: return "stream-incomplete"
        case .oversizedStream: return "stream-oversized"
        }
    }

    var errorDescription: String? {
        switch self {
        case .credentialsUnavailable: return WidgetLanguage.storedOrAutomatic().text("账号凭据不可用，请重新登录该账号", "Account credentials are unavailable. Sign in again.")
        case .identityMismatch: return WidgetLanguage.storedOrAutomatic().text("账号凭据与账号卡不一致，已阻止暖号", "The credentials do not match this account card. Warm-up was blocked.")
        case .invalidRequest: return WidgetLanguage.storedOrAutomatic().text("无法生成安全的暖号请求", "Could not create a safe warm-up request.")
        case .redirected: return WidgetLanguage.storedOrAutomatic().text("官方暖号地址发生重定向，已停止发送凭据", "The warm-up endpoint redirected. Credentials were not forwarded.")
        case .timedOut: return WidgetLanguage.storedOrAutomatic().text("官方暖号请求超时", "The warm-up request timed out.")
        case .networkUnavailable: return WidgetLanguage.storedOrAutomatic().text("网络连接失败", "The network connection failed.")
        case .unauthorized: return WidgetLanguage.storedOrAutomatic().text("账号登录已失效，请重新登录", "This sign-in has expired. Sign in again.")
        case .forbidden: return WidgetLanguage.storedOrAutomatic().text("该账号无权执行暖号请求", "This account is not allowed to run a warm-up request.")
        case .rateLimited: return WidgetLanguage.storedOrAutomatic().text("官方暂时限制了请求频率", "The service temporarily rate-limited requests.")
        case .serviceUnavailable: return WidgetLanguage.storedOrAutomatic().text("官方暖号服务暂时不可用", "The warm-up service is temporarily unavailable.")
        case .rejected(let status): return WidgetLanguage.storedOrAutomatic().text("官方拒绝了暖号请求（HTTP \(status)）", "The warm-up request was rejected (HTTP \(status)).")
        case .streamFailed: return WidgetLanguage.storedOrAutomatic().text("官方暖号流返回失败", "The warm-up stream reported a failure.")
        case .incompleteStream: return WidgetLanguage.storedOrAutomatic().text("官方暖号流未返回完成标记", "The warm-up stream ended without a completion marker.")
        case .oversizedStream: return WidgetLanguage.storedOrAutomatic().text("官方暖号流超过安全上限", "The warm-up stream exceeded the safety limit.")
        }
    }

    static func httpStatus(_ status: Int) -> CodexWarmUpFailure {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 429: return .rateLimited
        case 500...599: return .serviceUnavailable
        default: return .rejected(status)
        }
    }

    static func network(_ error: Error) -> CodexWarmUpFailure {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timedOut
        }
        return .networkUnavailable
    }
}

private enum CodexWarmUpStreamOutcome: Equatable {
    case pending
    case completed
    case failed
    case oversized
}

private struct CodexWarmUpSSEParser {
    private static let maximumBytes = 64 * 1_024
    private var buffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var bufferedBytes = 0

    mutating func append(_ data: Data) -> CodexWarmUpStreamOutcome {
        guard buffer.count + bufferedBytes + data.count <= Self.maximumBytes else {
            return .oversized
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard var line = String(data: lineData, encoding: .utf8) else { return .failed }
            if line.last == "\r" { line.removeLast() }
            let outcome = consume(line)
            if outcome != .pending { return outcome }
        }
        return .pending
    }

    mutating func finish() -> CodexWarmUpStreamOutcome {
        if !buffer.isEmpty {
            guard var line = String(data: buffer, encoding: .utf8) else { return .failed }
            buffer.removeAll(keepingCapacity: false)
            if line.last == "\r" { line.removeLast() }
            let outcome = consume(line)
            if outcome != .pending { return outcome }
        }
        return processEvent()
    }

    private mutating func consume(_ line: String) -> CodexWarmUpStreamOutcome {
        if line.isEmpty { return processEvent() }
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            let value = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            bufferedBytes += value.utf8.count
            guard bufferedBytes <= Self.maximumBytes else { return .oversized }
            dataLines.append(value)
        }
        return .pending
    }

    private mutating func processEvent() -> CodexWarmUpStreamOutcome {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            bufferedBytes = 0
        }
        if let eventName {
            if Self.isTerminal(eventName) { return .completed }
            if Self.isFailure(eventName) { return .failed }
        }
        guard !dataLines.isEmpty else { return .pending }
        let payload = dataLines.joined(separator: "\n")
        if payload == "[DONE]" { return .completed }
        guard let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return .pending }
        if Self.isTerminal(type) { return .completed }
        if Self.isFailure(type) { return .failed }
        return .pending
    }

    private static func isTerminal(_ value: String) -> Bool {
        value == "response.completed" || value == "response.done"
    }

    private static func isFailure(_ value: String) -> Bool {
        value == "error" || value == "response.failed" || value == "response.incomplete"
    }
}

/// Direct request shape and SSE completion rules adapted from
/// qxcnm/Codex-Manager `account_warmup.rs` (MIT, copyright 2026 hongshun.gao).
private enum CodexWarmUpProtocol {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    private static let maximumAuthBytes = 1 * 1_024 * 1_024
    private static let model = "gpt-5.6-luna"

    static func request(for profile: CodexProfile, fileManager: FileManager = .default) throws -> URLRequest {
        let authURL = profile.codexHomeURL.appendingPathComponent("auth.json")
        let homePath = profile.codexHomeURL.standardizedFileURL.path
        let systemHomePath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL.path
        let lock =
            homePath == systemHomePath
            ? CodexCredentialAccessGate.lock
            : CodexCredentialAccessGate.homeLock(forHomePath: homePath)
        lock.lock()
        defer { lock.unlock() }

        guard let attributes = try? fileManager.attributesOfItem(atPath: authURL.path),
            let size = attributes[.size] as? NSNumber,
            size.intValue > 0,
            size.intValue <= maximumAuthBytes,
            let authData = try? Data(contentsOf: authURL),
            let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: authData),
            let auth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
            let tokens = auth["tokens"] as? [String: Any],
            let accessToken = nonEmpty(tokens["access_token"] as? String)
        else { throw CodexWarmUpFailure.credentialsUnavailable }
        guard profile.matchesRecordedCredential(identity) else {
            throw CodexWarmUpFailure.identityMismatch
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(identity.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex_cli_rs/0.153.0", forHTTPHeaderField: "User-Agent")
        guard let body = try? JSONSerialization.data(withJSONObject: requestBody()) else {
            throw CodexWarmUpFailure.invalidRequest
        }
        request.httpBody = body
        return request
    }

    static func requestBody(message: String = "hi") -> [String: Any] {
        [
            "model": model,
            "instructions": "",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": message]],
                ]
            ],
            "stream": true,
            "store": false,
        ]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}

private final class CodexWarmUpSession: NSObject, URLSessionDataDelegate {
    private let request: URLRequest
    private let completion: (Result<Void, Error>) -> Void
    private var parser = CodexWarmUpSSEParser()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isFinished = false

    init(request: URLRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        self.request = request
        self.completion = completion
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(CodexWarmUpFailure.redirected))
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            completionHandler(.cancel)
            finish(.failure(CodexWarmUpFailure.networkUnavailable))
            return
        }
        guard (200...299).contains(status) else {
            completionHandler(.cancel)
            finish(.failure(CodexWarmUpFailure.httpStatus(status)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        switch parser.append(data) {
        case .completed: finish(.success(()))
        case .failed: finish(.failure(CodexWarmUpFailure.streamFailed))
        case .oversized: finish(.failure(CodexWarmUpFailure.oversizedStream))
        case .pending: break
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished else { return }
        if let error {
            finish(.failure(CodexWarmUpFailure.network(error)))
            return
        }
        switch parser.finish() {
        case .completed: finish(.success(()))
        case .failed: finish(.failure(CodexWarmUpFailure.streamFailed))
        case .oversized: finish(.failure(CodexWarmUpFailure.oversizedStream))
        case .pending: finish(.failure(CodexWarmUpFailure.incompleteStream))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !isFinished else { return }
        isFinished = true
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        DispatchQueue.main.async { [completion] in completion(result) }
    }
}

enum CodexWarmUpProtocolSelfTest {
    static func run() -> Bool {
        let body = CodexWarmUpProtocol.requestBody()
        guard body["model"] as? String == "gpt-5.6-luna",
            body["stream"] as? Bool == true,
            body["store"] as? Bool == false,
            CodexWarmUpFailure.httpStatus(401) == .unauthorized,
            CodexWarmUpFailure.httpStatus(429) == .rateLimited,
            requestContractPasses()
        else {
            print("Codex warm-up protocol self-test failed: request contract")
            return false
        }

        var completed = CodexWarmUpSSEParser()
        guard completed.append(Data("event: response.created\ndata: {\"type\":\"response.created\"}\n\n".utf8)) == .pending,
            completed.append(Data("event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n".utf8)) == .completed
        else {
            print("Codex warm-up protocol self-test failed: completion event")
            return false
        }
        var failed = CodexWarmUpSSEParser()
        guard failed.append(Data("event: response.failed\ndata: {\"type\":\"response.failed\"}\n\n".utf8)) == .failed else {
            print("Codex warm-up protocol self-test failed: failure event")
            return false
        }
        var fragmented = CodexWarmUpSSEParser()
        guard fragmented.append(Data("event: response.com".utf8)) == .pending,
            fragmented.append(Data("pleted\ndata: {\"type\":\"response.completed\"}\n\n".utf8)) == .completed
        else {
            print("Codex warm-up protocol self-test failed: fragmented completion event")
            return false
        }
        print("Codex warm-up protocol self-test passed")
        return true
    }

    private static func requestContractPasses() -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("camnext-warm-up-protocol-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let claims = try JSONSerialization.data(withJSONObject: [
                "email": "warm-up-self-test@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": "acct-warm-up-self-test"],
            ])
            let encoded = claims.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let token = "x.\(encoded).y"
            let auth = try JSONSerialization.data(withJSONObject: [
                "tokens": [
                    "access_token": token,
                    "id_token": token,
                    "account_id": "acct-warm-up-self-test",
                ]
            ])
            try auth.write(to: root.appendingPathComponent("auth.json"), options: .atomic)
            let profile = CodexProfile(
                id: "warm-up-protocol-self-test",
                name: "warm-up-protocol-self-test",
                codexHomePath: root.path,
                isSystemProfile: false,
                createdAt: Date()
            )
            let request = try CodexWarmUpProtocol.request(for: profile, fileManager: fileManager)
            return request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses"
                && request.httpMethod == "POST"
                && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
                && request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-warm-up-self-test"
                && request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
                && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
                && request.httpBody?.isEmpty == false
        } catch {
            return false
        }
    }
}

final class CodexAccountActions {
    enum PendingSwitchRecoveryOutcome: Equatable {
        case noPendingSwitch
        case restoredOriginalAuth(codexWasReopened: Bool)
        case originalAuthAlreadyPresent(codexWasReopened: Bool)
        case preservedExternalAuth
    }

    fileprivate struct PendingSwitchJournal: Codable, Equatable {
        let version: Int
        let createdAt: Date
        let originalAuth: Data?
        let targetAuthFingerprint: Data
        let originalIdentityDigest: Data?
        let targetIdentityDigest: Data?
        let originalCodexWasRunning: Bool
        let originalDaemonWasRunning: Bool?

        init(
            originalAuth: AuthState,
            targetAuthFingerprint: Data,
            targetIdentity: CodexCredentialIdentity,
            originalCodexWasRunning: Bool,
            originalDaemonWasRunning: Bool,
            createdAt: Date = Date()
        ) {
            version = 2
            self.createdAt = createdAt
            switch originalAuth {
            case .missing:
                self.originalAuth = nil
            case .data(let data):
                self.originalAuth = data
            }
            self.targetAuthFingerprint = targetAuthFingerprint
            originalIdentityDigest = CodexAccountActions.identityDigest(for: originalAuth)
            targetIdentityDigest = CodexAccountActions.identityDigest(for: targetIdentity)
            self.originalCodexWasRunning = originalCodexWasRunning
            self.originalDaemonWasRunning = originalDaemonWasRunning
        }

        var originalAuthState: AuthState {
            originalAuth.map(AuthState.data) ?? .missing
        }
    }

    fileprivate enum PendingSwitchRecoveryDecision: Equatable {
        case rollbackOriginal
        case originalAlreadyPresent
        case preserveExternal
    }

    private var loginSession: CodexLoginSession?
    private var warmUpSession: CodexWarmUpSession?

    var isLoginRunning: Bool { loginSession != nil }
    var isWarmUpRunning: Bool { warmUpSession != nil }

    func login(
        profile: CodexProfile,
        browserChoice: CodexDeviceBrowserChoice,
        onPhaseChange: @escaping (CodexDeviceLoginPhase) -> Void = { _ in },
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard !isLoginRunning else { throw CodexLoginError.message(WidgetLanguage.storedOrAutomatic().text("已有账号正在登录", "Another account is signing in.")) }
        guard !isWarmUpRunning else {
            throw CodexLoginError.message(WidgetLanguage.storedOrAutomatic().text("账号暖号正在执行；完成后再登录", "A warm-up is running. Wait for it to finish before signing in."))
        }
        guard let executable = TerminalAppLauncher.codexExecutable() else {
            throw CodexDeviceLoginFailure.cliUnavailable
        }
        let session = try CodexLoginSession(
            profile: profile,
            browserChoice: browserChoice,
            executableURL: URL(fileURLWithPath: executable),
            onPhaseChange: onPhaseChange
        ) { [weak self] result in
            self?.loginSession = nil
            completion(result)
        }
        loginSession = session
        do {
            try session.start()
        } catch {
            loginSession = nil
            throw error
        }
    }

    func cancelLogin() {
        loginSession?.cancel()
    }

    func reopenDeviceAuthPage() { loginSession?.reopenPage() }

    func currentSystemAuthFingerprint(
        expectedEmail: String,
        expectedAccountID: String
    ) throws -> Data {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard case .data(let data) = try Self.authState(at: authURL),
            let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data),
            identity.email == Self.normalizedEmail(expectedEmail),
            identity.accountID == expectedAccountID
        else {
            throw Self.switchError(
                WidgetLanguage.storedOrAutomatic().text("当前 Codex 凭据身份与低额度触发账号不一致", "The current Codex identity does not match the account that triggered the low-quota event."))
        }
        return Self.authFingerprint(data)
    }

    static func switchRecoveryIsClear() -> Bool {
        do { return try loadPendingSwitchJournal(fileManager: .default) == nil } catch { return false }
    }

    func commitPendingSwitch(completion: @escaping (Error?) -> Void) {
        let fileManager = FileManager.default
        let switchLock: Int32
        do {
            switchLock = try Self.acquireSwitchLock(fileManager: fileManager)
        } catch {
            completion(error)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            CodexCredentialAccessGate.lock.lock()
            defer {
                Self.releaseSwitchLock(switchLock)
                CodexCredentialAccessGate.lock.unlock()
            }
            let result: Error?
            do {
                guard let journal = try Self.loadPendingSwitchJournal(fileManager: fileManager) else {
                    throw Self.switchError(WidgetLanguage.storedOrAutomatic().text("没有可提交的账号切换恢复记录", "No account-switch recovery record is available to commit."))
                }
                let authURL = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex/auth.json")
                guard
                    Self.pendingSwitchRecoveryDecision(
                        current: try Self.authState(at: authURL),
                        journal: journal
                    ) == .rollbackOriginal
                else {
                    throw Self.switchError(
                        WidgetLanguage.storedOrAutomatic().text(
                            "提交前账号身份已变化；保留恢复记录且不覆盖", "The account identity changed before commit. The recovery record was retained and nothing was overwritten."))
                }
                try Self.clearPendingSwitchJournal(fileManager: fileManager)
                result = nil
            } catch {
                result = error
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func recoverPendingSwitchIfNeeded(
        completion: @escaping (Result<PendingSwitchRecoveryOutcome, Error>) -> Void
    ) {
        let fileManager = FileManager.default
        let switchLock: Int32
        do {
            switchLock = try Self.acquireSwitchLock(fileManager: fileManager)
        } catch {
            completion(.failure(error))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            CodexCredentialAccessGate.lock.lock()
            defer {
                Self.releaseSwitchLock(switchLock)
                CodexCredentialAccessGate.lock.unlock()
            }
            let result: Result<PendingSwitchRecoveryOutcome, Error>
            do {
                guard let journal = try Self.loadPendingSwitchJournal(fileManager: fileManager) else {
                    result = .success(.noPendingSwitch)
                    DispatchQueue.main.async { completion(result) }
                    return
                }
                let systemHome = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex", isDirectory: true)
                let systemAuthURL = systemHome.appendingPathComponent("auth.json")
                let currentAuth = try Self.authState(at: systemAuthURL)
                let originalDaemonWasRunning =
                    try journal.originalDaemonWasRunning
                    ?? Self.codexDaemonIsRunning()
                switch Self.pendingSwitchRecoveryDecision(current: currentAuth, journal: journal) {
                case .preserveExternal:
                    guard
                        Self.pendingSwitchRecoveryDecision(
                            current: try Self.authState(at: systemAuthURL),
                            journal: journal
                        ) == .preserveExternal
                    else {
                        throw Self.switchError(
                            WidgetLanguage.storedOrAutomatic().text("清理恢复记录前凭据再次变化；已保留恢复记录", "Credentials changed before cleanup. The recovery record was retained."))
                    }
                    try Self.clearPendingSwitchJournal(fileManager: fileManager)
                    result = .success(.preservedExternalAuth)
                case .originalAlreadyPresent:
                    let reopened = try Self.restoreOriginalCodexRuntimeIfNeeded(
                        originalAuth: currentAuth,
                        originalCodexWasRunning: journal.originalCodexWasRunning,
                        originalDaemonWasRunning: originalDaemonWasRunning,
                        systemHome: systemHome
                    )
                    guard
                        Self.pendingSwitchRecoveryDecision(
                            current: try Self.authState(at: systemAuthURL),
                            journal: journal
                        ) == .originalAlreadyPresent
                    else {
                        throw Self.switchError(
                            WidgetLanguage.storedOrAutomatic().text(
                                "补开原 Codex 期间凭据变化；已保留恢复记录且不覆盖",
                                "Credentials changed while reopening the original Codex session. The recovery record was retained and nothing was overwritten."))
                    }
                    try Self.clearPendingSwitchJournal(fileManager: fileManager)
                    result = .success(.originalAuthAlreadyPresent(codexWasReopened: reopened))
                case .rollbackOriginal:
                    guard
                        let appURL = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: "com.openai.codex"
                        )
                    else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try Self.stopCodexGracefullyIfRunning(appURL: appURL)
                    _ = try Self.stopCodexDaemonIfRunning()
                    guard
                        Self.pendingSwitchRecoveryDecision(
                            current: try Self.authState(at: systemAuthURL),
                            journal: journal
                        ) == .rollbackOriginal
                    else {
                        throw Self.switchError(
                            WidgetLanguage.storedOrAutomatic().text("恢复前凭据再次变化；已保留外部最新状态，不覆盖", "Credentials changed again before recovery. The newer external state was preserved.")
                        )
                    }
                    try fileManager.createDirectory(
                        at: systemHome,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    let ownedRecoveryState = try Self.authState(at: systemAuthURL)
                    guard Self.pendingSwitchRecoveryDecision(current: ownedRecoveryState, journal: journal) == .rollbackOriginal
                    else { throw CodexCredentialTransaction.Failure.superseded }
                    try Self.restoreAuth(journal.originalAuthState, expected: ownedRecoveryState, at: systemAuthURL, fileManager: fileManager)
                    guard try Self.authState(at: systemAuthURL) == journal.originalAuthState else {
                        throw Self.switchError(WidgetLanguage.storedOrAutomatic().text("启动恢复写回原账号后校验失败", "Startup recovery could not verify the restored original account."))
                    }
                    let reopened = try Self.restoreOriginalCodexRuntimeIfNeeded(
                        originalAuth: journal.originalAuthState,
                        originalCodexWasRunning: journal.originalCodexWasRunning,
                        originalDaemonWasRunning: originalDaemonWasRunning,
                        systemHome: systemHome,
                        appURL: appURL
                    )
                    guard
                        Self.pendingSwitchRecoveryDecision(
                            current: try Self.authState(at: systemAuthURL),
                            journal: journal
                        ) == .originalAlreadyPresent
                    else {
                        throw Self.switchError(
                            WidgetLanguage.storedOrAutomatic().text(
                                "原 Codex 恢复期间凭据变化；已保留恢复记录且不覆盖",
                                "Credentials changed while restoring the original Codex session. The recovery record was retained and nothing was overwritten."))
                    }
                    try Self.clearPendingSwitchJournal(fileManager: fileManager)
                    result = .success(.restoredOriginalAuth(codexWasReopened: reopened))
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func launchCodex(
        profile: CodexProfile,
        sourceBackupProfile: CodexProfile? = nil,
        expectedSourceIdentity: CodexCredentialIdentity,
        retainRecoveryJournal: Bool = false,
        allowForcedTermination: Bool = false,
        progress: @escaping (String) -> Void = { _ in },
        completion: @escaping (Error?) -> Void
    ) {
        guard !isLoginRunning else {
            completion(
                Self.switchError(WidgetLanguage.storedOrAutomatic().text("账号登录仍在进行；完成后再切换 Desktop", "Sign-in is still in progress. Wait before switching Desktop accounts.")))
            return
        }
        guard !isWarmUpRunning else {
            completion(Self.switchError(WidgetLanguage.storedOrAutomatic().text("账号暖号仍在运行；完成后会再允许切换", "A warm-up is still running. Switching will be available when it finishes.")))
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            completion(CocoaError(.fileNoSuchFile))
            return
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.account-manager").isEmpty else {
            completion(
                Self.switchError(
                    WidgetLanguage.storedOrAutomatic().text(
                        "旧版账号管理器仍在运行；为避免两个管理器同时改写登录，请先退出旧版", "The legacy account manager is running. Quit it before switching to avoid competing credential writes.")))
            return
        }

        let finish: (Error?) -> Void = { error in
            DispatchQueue.main.async { completion(error) }
        }
        let report: (String, String) -> Void = { chinese, english in
            DispatchQueue.main.async { progress(WidgetLanguage.storedOrAutomatic().text(chinese, english)) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            report("正在准备安全切换…", "Preparing the safe switch…")
            let fileManager = FileManager.default
            let systemHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
            let systemAuthURL = systemHome.appendingPathComponent("auth.json")
            let targetAuthURL = profile.codexHomeURL.appendingPathComponent("auth.json")
            let switchLock: Int32
            do {
                switchLock = try Self.acquireSwitchLock(fileManager: fileManager)
            } catch {
                finish(error)
                return
            }

            let previousAuth: AuthState
            let targetAuth: Data?
            let targetIdentity: CodexCredentialIdentity?
            do {
                guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.account-manager").isEmpty else {
                    throw Self.switchError(
                        WidgetLanguage.storedOrAutomatic().text("旧版账号管理器在切换准备期间启动；已取消写入", "The legacy account manager started during switch preparation. Writing was canceled."))
                }
                guard try Self.loadPendingSwitchJournal(fileManager: fileManager) == nil else {
                    throw Self.switchError(
                        WidgetLanguage.storedOrAutomatic().text("检测到未完成的账号切换；请先完成启动恢复", "An unfinished account switch was detected. Complete startup recovery first."))
                }
                previousAuth = try Self.authState(at: systemAuthURL)
                // Bind every entry point, including manual same-account opens,
                // to the identity checked and reserved before this transaction.
                try Self.validateSwitchSource(previousAuth, expected: expectedSourceIdentity)
                if profile.isSystemProfile {
                    targetAuth = nil
                    targetIdentity = nil
                } else {
                    let auth = try Self.validatedManagedAuth(at: targetAuthURL, profile: profile)
                    targetAuth = auth
                    targetIdentity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: auth)
                }
            } catch {
                Self.releaseSwitchLock(switchLock)
                finish(error)
                return
            }

            let previousIdentity: CodexCredentialIdentity?
            if case .data(let data) = previousAuth {
                previousIdentity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data)
            } else {
                previousIdentity = nil
            }
            let requiresRestart = targetIdentity.map { $0 != previousIdentity } ?? false
            let runningApplications =
                requiresRestart
                ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                : []
            let previousProcessIDs = Set(runningApplications.map(\.processIdentifier))
            let originalCodexWasRunning: Bool
            let originalDaemonWasRunning: Bool
            do {
                if requiresRestart {
                    let detectedProcessIDs = try Self.codexProcessIDs(appURL: appURL)
                    originalCodexWasRunning = !runningApplications.isEmpty || !detectedProcessIDs.isEmpty
                    originalDaemonWasRunning = try Self.codexDaemonIsRunning()
                } else {
                    originalCodexWasRunning = false
                    originalDaemonWasRunning = false
                }
            } catch {
                Self.releaseSwitchLock(switchLock)
                finish(error)
                return
            }
            let preparedJournal: PendingSwitchJournal?
            do {
                if let targetAuth, let targetIdentity, requiresRestart {
                    let pending = PendingSwitchJournal(
                        originalAuth: previousAuth,
                        targetAuthFingerprint: Self.authFingerprint(targetAuth),
                        targetIdentity: targetIdentity,
                        originalCodexWasRunning: originalCodexWasRunning,
                        originalDaemonWasRunning: originalDaemonWasRunning
                    )
                    try Self.persistPendingSwitchJournal(pending, fileManager: fileManager)
                    preparedJournal = pending
                } else {
                    preparedJournal = nil
                }
            } catch {
                Self.releaseSwitchLock(switchLock)
                finish(error)
                return
            }
            if requiresRestart, !runningApplications.allSatisfy({ $0.terminate() }) {
                try? Self.clearPendingSwitchJournal(fileManager: fileManager)
                Self.releaseSwitchLock(switchLock)
                finish(Self.switchError(WidgetLanguage.storedOrAutomatic().text("Codex 拒绝了安全退出；账号未切换", "Codex did not accept a graceful exit. The account was not switched.")))
                return
            }

            let transactionStartedAt = DispatchTime.now().uptimeNanoseconds
            defer {
                Self.logSwitchTiming(stage: "total", startedAt: transactionStartedAt)
            }
            CodexCredentialAccessGate.lock.lock()
            let transactionHomes = [systemHome, profile.codexHomeURL] + (sourceBackupProfile.map { [$0.codexHomeURL] } ?? [])
            let transactionLocks = Set(transactionHomes.map { CodexCredentialTransaction.canonical($0).path }).sorted().map {
                CodexCredentialAccessGate.homeLock(forHomePath: $0)
            }
            transactionLocks.forEach { $0.lock() }
            defer {
                transactionLocks.reversed().forEach { $0.unlock() }
                Self.releaseSwitchLock(switchLock)
                CodexCredentialAccessGate.lock.unlock()
            }
            var journal = preparedJournal
            var journalPersisted = preparedJournal != nil
            var originalAuthForRecovery = previousAuth
            var daemonShouldRunAfterTransaction = originalDaemonWasRunning
            do {
                if requiresRestart {
                    report("正在安全退出 Codex…", "Closing Codex safely…")
                    try Self.measureSwitchStage("退出等待") {
                        try Self.waitForCodexExit(
                            appURL: appURL,
                            runningApplications: runningApplications,
                            allowForcedTermination: allowForcedTermination
                        )
                    }
                } else {
                    Self.logSwitchTiming(stage: "退出等待", milliseconds: 0)
                }
                daemonShouldRunAfterTransaction = try Self.measureSwitchStage("daemon 停") {
                    if requiresRestart {
                        return try Self.stopCodexDaemonIfRunning() || originalDaemonWasRunning
                    }
                    return daemonShouldRunAfterTransaction
                }
                report("正在切换账号…", "Switching accounts…")
                try Self.measureSwitchStage("凭据写入") {
                    try fileManager.createDirectory(
                        at: systemHome,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    if let targetAuth, requiresRestart {
                        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.account-manager").isEmpty else {
                            throw Self.switchError(
                                WidgetLanguage.storedOrAutomatic().text("旧版账号管理器在写入前启动；已取消切换", "The legacy account manager started before writing. Switching was canceled."))
                        }
                        let currentSourceAuth = try Self.authState(at: systemAuthURL)
                        if currentSourceAuth != previousAuth {
                            guard Self.identityDigest(for: currentSourceAuth) == Self.identityDigest(for: previousAuth),
                                let targetIdentity,
                                let existingJournal = journal
                            else {
                                throw Self.switchError(
                                    WidgetLanguage.storedOrAutomatic().text(
                                        "切换期间 Codex 登录账号已变化；已取消写入", "The signed-in Codex account changed during the switch. Writing was canceled."))
                            }
                            let updatedJournal = PendingSwitchJournal(
                                originalAuth: currentSourceAuth,
                                targetAuthFingerprint: Self.authFingerprint(targetAuth),
                                targetIdentity: targetIdentity,
                                originalCodexWasRunning: originalCodexWasRunning,
                                originalDaemonWasRunning: originalDaemonWasRunning,
                                createdAt: existingJournal.createdAt
                            )
                            try Self.replacePendingSwitchJournal(
                                existingJournal,
                                with: updatedJournal,
                                fileManager: fileManager
                            )
                            journal = updatedJournal
                            originalAuthForRecovery = currentSourceAuth
                        }
                        if let sourceBackupProfile {
                            try Self.writeManagedAuthBackup(
                                originalAuthForRecovery,
                                to: sourceBackupProfile,
                                sourceHome: systemHome,
                                fileManager: fileManager
                            )
                        }
                        try Self.validateSwitchSource(currentSourceAuth, expected: expectedSourceIdentity)
                        guard try Self.codexDaemonIsRunning() == false else {
                            throw Self.switchError(
                                WidgetLanguage.storedOrAutomatic().text(
                                    "Codex 共享运行时在写入前重新出现；账号未切换", "The shared Codex runtime restarted before writing. The account was not switched."))
                        }
                        // Recheck immediately before writing; this is not an atomic
                        // exclusion of independently launched external processes.
                        guard try Self.codexProcessIDs(appURL: appURL).isEmpty,
                            NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
                        else {
                            throw Self.switchError(
                                WidgetLanguage.storedOrAutomatic().text(
                                    "Codex Desktop 在写入前重新运行；账号未切换", "Codex Desktop restarted before writing. The account was not switched."))
                        }
                        guard try Self.authState(at: systemAuthURL) == currentSourceAuth,
                            try CodexCredentialTransaction.read(targetAuthURL) == targetAuth
                        else { throw CodexCredentialTransaction.Failure.superseded }
                        try targetAuth.write(to: systemAuthURL, options: .atomic)
                        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: systemAuthURL.path)
                        guard try Data(contentsOf: systemAuthURL) == targetAuth else {
                            throw Self.switchError(WidgetLanguage.storedOrAutomatic().text("目标账号凭据写入后校验失败", "Target account credentials could not be verified after writing."))
                        }
                    }
                }
                report("正在验证账号…", "Verifying the account…")
                try Self.measureSwitchStage("凭据校验") {
                    if let targetIdentity, requiresRestart {
                        guard try Self.codexDaemonIsRunning() == false else {
                            throw Self.switchError(
                                WidgetLanguage.storedOrAutomatic().text(
                                    "Codex 共享运行时在验证前重新出现；已停止切换", "The shared Codex runtime restarted before verification. Switching was stopped."))
                        }
                        try Self.verifyAccountCredentials(at: systemHome, expectedIdentity: targetIdentity)
                        guard try Self.codexDaemonIsRunning() == false else {
                            throw Self.switchError(
                                WidgetLanguage.storedOrAutomatic().text(
                                    "目标验证期间出现第二个凭据写者；已停止切换", "Another credential writer appeared during target verification. Switching was stopped."))
                        }
                    }
                }
                try Self.measureSwitchStage("daemon 启") {
                    if requiresRestart {
                        try Self.startCodexDaemonIfNeeded(daemonShouldRunAfterTransaction)
                    }
                }
                report("正在打开 Codex…", "Opening Codex…")
                try Self.measureSwitchStage("打开 Codex") {
                    try Self.openCodex(at: appURL)
                }
                try Self.measureSwitchStage("新进程确认") {
                    if requiresRestart {
                        try Self.waitForNewCodexProcess(previousProcessIDs: previousProcessIDs)
                    }
                }
                report("正在确认桌面账号…", "Confirming the Desktop account…")
                try Self.measureSwitchStage("运行时身份验证") {
                    if let targetIdentity {
                        try Self.verifyRuntimeIdentity(
                            at: systemHome,
                            expectedIdentity: targetIdentity,
                            daemonRequired: daemonShouldRunAfterTransaction
                        )
                    }
                }
                if requiresRestart,
                    !Self.hasNewCodexProcess(previousProcessIDs: previousProcessIDs)
                {
                    throw Self.switchError(WidgetLanguage.storedOrAutomatic().text("目标账号确认后 Codex 进程已退出", "Codex exited after the target account was verified."))
                }
                if Self.shouldClearPendingSwitchJournal(
                    journalPersisted: journalPersisted,
                    retainRecoveryJournal: retainRecoveryJournal
                ) {
                    guard let journal,
                        Self.pendingSwitchRecoveryDecision(
                            current: try Self.authState(at: systemAuthURL),
                            journal: journal
                        ) == .rollbackOriginal
                    else {
                        throw Self.switchError(
                            WidgetLanguage.storedOrAutomatic().text(
                                "完成切换前凭据再次变化；不会覆盖外部最新状态", "Credentials changed before the switch completed. The newer external state will not be overwritten."))
                    }
                    try Self.clearPendingSwitchJournal(fileManager: fileManager)
                    journalPersisted = false
                }
                finish(nil)
            } catch let switchFailure {
                report("正在恢复原账号…", "Restoring the original account…")
                var reportedError: Error = switchFailure
                if let journal, journalPersisted {
                    do {
                        switch Self.pendingSwitchRecoveryDecision(
                            current: try Self.authState(at: systemAuthURL),
                            journal: journal
                        ) {
                        case .originalAlreadyPresent:
                            break
                        case .preserveExternal:
                            throw Self.switchError(
                                WidgetLanguage.storedOrAutomatic().text(
                                    "切换失败后凭据已被其他程序修改；已保留外部最新状态，不覆盖", "Another program changed credentials after the switch failed. The newer external state was preserved."))
                        case .rollbackOriginal:
                            try Self.stopCodexGracefullyIfRunning(appURL: appURL)
                            daemonShouldRunAfterTransaction =
                                try Self.stopCodexDaemonIfRunning()
                                || daemonShouldRunAfterTransaction
                            guard
                                Self.pendingSwitchRecoveryDecision(
                                    current: try Self.authState(at: systemAuthURL),
                                    journal: journal
                                ) == .rollbackOriginal
                            else {
                                throw Self.switchError(
                                    WidgetLanguage.storedOrAutomatic().text(
                                        "恢复前凭据再次变化；已保留外部最新状态，不覆盖", "Credentials changed again before recovery. The newer external state was preserved."))
                            }
                            let ownedRecoveryState = try Self.authState(at: systemAuthURL)
                            guard Self.pendingSwitchRecoveryDecision(current: ownedRecoveryState, journal: journal) == .rollbackOriginal
                            else { throw CodexCredentialTransaction.Failure.superseded }
                            try Self.restoreAuth(originalAuthForRecovery, expected: ownedRecoveryState, at: systemAuthURL, fileManager: fileManager)
                            guard try Self.authState(at: systemAuthURL) == originalAuthForRecovery else {
                                throw Self.switchError(WidgetLanguage.storedOrAutomatic().text("原账号凭据回滚后校验失败", "The original credentials could not be verified after rollback."))
                            }
                        }
                    } catch {
                        reportedError = Self.switchError(
                            WidgetLanguage.storedOrAutomatic().text(
                                "账号切换失败，且原凭据回滚未完成：\(error.localizedDescription)", "Account switching failed and credential rollback is incomplete: \(error.localizedDescription)")
                        )
                    }
                }

                var restoredAuthState: AuthState?
                var originalStateRestored = false
                do {
                    let current = try Self.authState(at: systemAuthURL)
                    restoredAuthState = current
                    originalStateRestored =
                        journal.map {
                            Self.pendingSwitchRecoveryDecision(current: current, journal: $0)
                                == .originalAlreadyPresent
                        } ?? (current == originalAuthForRecovery)
                } catch {
                    reportedError = Self.switchError(
                        WidgetLanguage.storedOrAutomatic().text(
                            "\(reportedError.localizedDescription)；无法确认原凭据是否已恢复",
                            "\(reportedError.localizedDescription); restoration of the original credentials could not be verified.")
                    )
                }
                var originalRuntimeRestored = !originalCodexWasRunning && !daemonShouldRunAfterTransaction
                if originalStateRestored, originalCodexWasRunning || daemonShouldRunAfterTransaction {
                    do {
                        _ = try Self.restoreOriginalCodexRuntimeIfNeeded(
                            originalAuth: restoredAuthState ?? originalAuthForRecovery,
                            originalCodexWasRunning: originalCodexWasRunning,
                            originalDaemonWasRunning: daemonShouldRunAfterTransaction,
                            systemHome: systemHome,
                            appURL: appURL,
                            previousProcessIDs: previousProcessIDs
                        )
                        originalRuntimeRestored = true
                    } catch {
                        reportedError = Self.switchError(
                            WidgetLanguage.storedOrAutomatic().text(
                                "\(reportedError.localizedDescription)；原 Codex 也未能重新打开并确认身份",
                                "\(reportedError.localizedDescription); the original Codex session could not be reopened and its identity verified.")
                        )
                    }
                }
                if journalPersisted, originalStateRestored, originalRuntimeRestored {
                    do {
                        guard let journal,
                            Self.pendingSwitchRecoveryDecision(
                                current: try Self.authState(at: systemAuthURL),
                                journal: journal
                            ) == .originalAlreadyPresent
                        else {
                            throw Self.switchError(
                                WidgetLanguage.storedOrAutomatic().text("清理恢复记录前凭据再次变化；已保留恢复记录", "Credentials changed before cleanup. The recovery record was retained."))
                        }
                        try Self.clearPendingSwitchJournal(fileManager: fileManager)
                        journalPersisted = false
                    } catch {
                        reportedError = Self.switchError(
                            WidgetLanguage.storedOrAutomatic().text(
                                "\(reportedError.localizedDescription)；已恢复原账号，但未能清理恢复记录",
                                "\(reportedError.localizedDescription); the original account was restored, but the recovery record could not be removed.")
                        )
                    }
                }
                let finalError = reportedError
                finish(finalError)
            }
        }
    }

    fileprivate enum AuthState: Equatable {
        case missing
        case data(Data)
    }

    private static func waitForCodexExit(
        appURL: URL,
        runningApplications: [NSRunningApplication],
        allowForcedTermination: Bool = false
    ) throws {
        let gracefulDeadline = Date().addingTimeInterval(allowForcedTermination ? 3 : 10)
        while Date() < gracefulDeadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty,
                try codexProcessIDs(appURL: appURL).isEmpty
            {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        guard allowForcedTermination else {
            throw switchError(
                WidgetLanguage.storedOrAutomatic().text(
                    "Codex 尚未安全退出；账号未切换，请等待当前任务结束后重试", "Codex has not exited safely. The account is unchanged; finish the current task and try again."))
        }
        for application in runningApplications where !application.isTerminated {
            guard application.forceTerminate() else {
                throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 无法退出；账号未切换", "Codex could not exit. The account was not switched."))
            }
        }
        let forcedDeadline = Date().addingTimeInterval(10)
        while Date() < forcedDeadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty,
                try codexProcessIDs(appURL: appURL).isEmpty
            {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard try codexProcessIDs(appURL: appURL).isEmpty else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 强制退出后仍有主进程残留；账号未切换", "A Codex main process remained after force quit. The account was not switched."))
        }
        throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 仍在运行；账号未切换", "Codex is still running. The account was not switched."))
    }

    private static func waitForNewCodexProcess(previousProcessIDs: Set<pid_t>) throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if hasNewCodexProcess(previousProcessIDs: previousProcessIDs) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 未在 30 秒内重新启动，原账号已恢复", "Codex did not restart within 30 seconds. The original account was restored."))
    }

    private static func hasNewCodexProcess(previousProcessIDs: Set<pid_t>) -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.openai.codex")
            .contains { !$0.isTerminated && !previousProcessIDs.contains($0.processIdentifier) }
    }

    private static func stopCodexGracefullyIfRunning(appURL: URL) throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        let processIDs = try codexProcessIDs(appURL: appURL)
        guard applications.allSatisfy({ $0.terminate() }) else {
            throw switchError(
                WidgetLanguage.storedOrAutomatic().text(
                    "新 Codex 未能安全退出；为避免运行中身份错配，未恢复原凭据", "The new Codex session could not exit safely. Original credentials were not restored to avoid a live identity mismatch."))
        }
        if !applications.isEmpty || !processIDs.isEmpty {
            try waitForCodexExit(appURL: appURL, runningApplications: applications)
        }
    }

    private static func verifyAccountCredentials(
        at codexHome: URL,
        expectedIdentity: CodexCredentialIdentity
    ) throws {
        let snapshot = CodexUsageReader().load(
            context: RuntimeLoadContext.live(codexHomeDirectory: codexHome)
        )
        let credentialIdentity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: codexHome)
        guard normalizedEmail(snapshot.account?.email) == expectedIdentity.email,
            credentialIdentity == expectedIdentity,
            snapshot.quotaReadSucceeded
        else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("目标账号未通过官方身份与额度验收", "The target account did not pass official identity and quota verification."))
        }
    }

    private static func verifyRuntimeIdentity(
        at codexHome: URL,
        expectedIdentity: CodexCredentialIdentity,
        daemonRequired: Bool
    ) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let identity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: codexHome)
            let daemonReady = !daemonRequired || (try? codexDaemonIsRunning()) == true
            if identity == expectedIdentity, daemonReady { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 冷启动后未确认目标账号与共享运行时", "The target account and shared runtime could not be verified after a cold start."))
    }

    private static func codexDaemonIsRunning() throws -> Bool {
        do {
            let data = try runCodexDaemonCommand("version")
            guard let running = daemonRunningStatus(from: data)
            else { throw switchError(WidgetLanguage.storedOrAutomatic().text("无法读取 Codex 共享运行时状态", "Could not read the shared Codex runtime status.")) }
            return running
        } catch {
            guard try processIDsOwningSocket(at: sharedDaemonControlSocket.path).isEmpty else {
                throw error
            }
            return false
        }
    }

    fileprivate static func daemonRunningStatus(from data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status = object["status"] as? String
        else { return nil }
        switch status {
        case "running": return true
        case "stopped", "notRunning", "not_running": return false
        default: return nil
        }
    }

    fileprivate static func daemonSocketPath(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let path = object["socketPath"] as? String,
            path.hasPrefix("/"),
            !path.contains("\0")
        else { return nil }
        return path
    }

    @discardableResult
    private static func stopCodexDaemonIfRunning() throws -> Bool {
        guard try codexDaemonIsRunning() else { return false }
        if sharedDaemonLaunchAgentIsLoaded() {
            let ownerProcessIDs = try daemonSocketOwnerProcessIDs()
            try runLaunchctl(
                ["bootout", sharedDaemonLaunchAgentTarget],
                failureMessage: WidgetLanguage.storedOrAutomatic().text("无法暂停 Mimi 的 Codex 共享运行时", "Could not pause Mimi's shared Codex runtime.")
            )
            try terminateDaemonProcesses(ownerProcessIDs)
        } else {
            _ = try runCodexDaemonCommand("stop")
        }
        let deadline = Date().addingTimeInterval(10)
        var consecutiveStoppedChecks = 0
        while Date() < deadline {
            if try codexDaemonIsRunning() == false {
                consecutiveStoppedChecks += 1
                if consecutiveStoppedChecks >= 3 { return true }
            } else {
                consecutiveStoppedChecks = 0
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 共享运行时未能保持停止；账号未切换", "The shared Codex runtime did not remain stopped. The account was not switched."))
    }

    private static func startCodexDaemonIfNeeded(_ shouldRun: Bool) throws {
        guard shouldRun, try codexDaemonIsRunning() == false else { return }
        try removeStaleSharedDaemonControlSocket()
        if FileManager.default.fileExists(atPath: sharedDaemonLaunchAgentPlist.path),
            !sharedDaemonLaunchAgentIsLoaded()
        {
            try startSharedDaemonLaunchAgent()
        } else {
            _ = try runCodexDaemonCommand("start")
        }
        // Mimi 会在启动共享运行时前恢复插件，实机可能超过 10 秒。
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if try codexDaemonIsRunning() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 共享运行时未能重新启动", "The shared Codex runtime could not restart."))
    }

    private static let sharedDaemonLaunchAgentLabel = "com.gaixianggeng.mimi.codex-shared-daemon"

    private static var sharedDaemonLaunchAgentDomain: String {
        "gui/\(getuid())"
    }

    private static var sharedDaemonLaunchAgentTarget: String {
        "\(sharedDaemonLaunchAgentDomain)/\(sharedDaemonLaunchAgentLabel)"
    }

    private static var sharedDaemonLaunchAgentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(sharedDaemonLaunchAgentLabel).plist")
    }

    private static var sharedDaemonControlSocket: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/app-server-control/app-server-control.sock")
    }

    private static func sharedDaemonLaunchAgentIsLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", sharedDaemonLaunchAgentTarget]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func startSharedDaemonLaunchAgent() throws {
        let deadline = Date().addingTimeInterval(5)
        var lastError: Error?
        repeat {
            if sharedDaemonLaunchAgentIsLoaded() { return }
            do {
                try runLaunchctl(
                    ["bootstrap", sharedDaemonLaunchAgentDomain, sharedDaemonLaunchAgentPlist.path],
                    failureMessage: WidgetLanguage.storedOrAutomatic().text("无法恢复 Mimi 的 Codex 共享运行时", "Could not restore Mimi's shared Codex runtime.")
                )
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.2)
            }
        } while Date() < deadline
        throw lastError ?? switchError(WidgetLanguage.storedOrAutomatic().text("无法恢复 Mimi 的 Codex 共享运行时", "Could not restore Mimi's shared Codex runtime."))
    }

    private static func daemonSocketOwnerProcessIDs() throws -> [pid_t] {
        let version = try runCodexDaemonCommand("version")
        guard let socketPath = daemonSocketPath(from: version) else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法定位 Mimi 的 Codex 共享运行时", "Could not locate Mimi's shared Codex runtime."))
        }
        return try processIDsOwningSocket(at: socketPath)
    }

    private static func processIDsOwningSocket(at socketPath: String) throws -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--", socketPath]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法探测 Mimi 的 Codex 共享运行时进程", "Could not inspect Mimi's shared Codex runtime processes."))
        }
        let data = try readAllBytes(
            from: output.fileHandleForReading.fileDescriptor,
            maximumBytes: 8 * 1_024,
            failureMessage: WidgetLanguage.storedOrAutomatic().text("无法读取 Mimi 的 Codex 共享运行时进程", "Could not read Mimi's shared Codex runtime processes.")
        )
        process.waitUntilExit()
        if process.terminationStatus == 1 { return [] }
        guard process.terminationStatus == 0,
            let text = String(data: data, encoding: .utf8)
        else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法探测 Mimi 的 Codex 共享运行时进程", "Could not inspect Mimi's shared Codex runtime processes."))
        }
        let processIDs = try text.split(whereSeparator: \.isNewline).map { value -> pid_t in
            guard value.allSatisfy({ $0.isNumber }),
                let processID = pid_t(String(value)),
                processID > 1,
                processID != getpid()
            else { throw switchError(WidgetLanguage.storedOrAutomatic().text("Mimi 的 Codex 共享运行时返回了无效进程", "Mimi's shared Codex runtime returned an invalid process.")) }
            return processID
        }
        guard processIDs.count <= 8 else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("Mimi 的 Codex 共享运行时进程数量异常", "Mimi's shared Codex runtime returned an unexpected process count."))
        }
        return Array(Set(processIDs))
    }

    private static func removeStaleSharedDaemonControlSocket() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sharedDaemonControlSocket.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: sharedDaemonControlSocket.path)
        guard attributes[.type] as? FileAttributeType == .typeSocket else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 共享运行时控制路径不是 socket；已停止切换", "The shared runtime control path is not a socket. Switching was stopped."))
        }
        guard try processIDsOwningSocket(at: sharedDaemonControlSocket.path).isEmpty else { return }
        try fileManager.removeItem(at: sharedDaemonControlSocket)
    }

    private static func terminateDaemonProcesses(_ processIDs: [pid_t]) throws {
        for processID in processIDs where processExists(processID) {
            guard Darwin.kill(processID, SIGTERM) == 0 || errno == ESRCH else {
                throw switchError(WidgetLanguage.storedOrAutomatic().text("无法停止 Mimi 的 Codex 共享运行时进程", "Could not stop Mimi's shared Codex runtime process."))
            }
        }
        let gracefulDeadline = Date().addingTimeInterval(3)
        while Date() < gracefulDeadline {
            if processIDs.allSatisfy({ !processExists($0) }) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for processID in processIDs where processExists(processID) {
            guard Darwin.kill(processID, SIGKILL) == 0 || errno == ESRCH else {
                throw switchError(WidgetLanguage.storedOrAutomatic().text("无法强制停止 Mimi 的 Codex 共享运行时进程", "Could not force-stop Mimi's shared Codex runtime process."))
            }
        }
        let forcedDeadline = Date().addingTimeInterval(3)
        while Date() < forcedDeadline {
            if processIDs.allSatisfy({ !processExists($0) }) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard processIDs.allSatisfy({ !processExists($0) }) else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("Mimi 的 Codex 共享运行时进程仍未退出", "Mimi's shared Codex runtime process has not exited."))
        }
    }

    private static func processExists(_ processID: pid_t) -> Bool {
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func runLaunchctl(_ arguments: [String], failureMessage: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw switchError(failureMessage)
        }
        guard process.terminationStatus == 0 else {
            throw switchError(failureMessage, code: Int(process.terminationStatus))
        }
    }

    private static func runCodexDaemonCommand(_ command: String) throws -> Data {
        guard let executable = CodexExecutable.path() else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "daemon", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法执行 Codex 共享运行时命令", "Could not run the shared Codex runtime command."))
        }
        guard finished.wait(timeout: .now() + 12) == .success else {
            if process.isRunning { process.terminate() }
            throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 共享运行时命令超时", "The shared Codex runtime command timed out."))
        }
        guard process.terminationStatus == 0 else {
            throw switchError(
                WidgetLanguage.storedOrAutomatic().text("Codex 共享运行时命令失败", "The shared Codex runtime command failed."),
                code: Int(process.terminationStatus)
            )
        }
        return try readAllBytes(
            from: output.fileHandleForReading.fileDescriptor,
            maximumBytes: 64 * 1_024,
            failureMessage: WidgetLanguage.storedOrAutomatic().text("无法读取 Codex 共享运行时命令结果", "Could not read the shared Codex runtime command result.")
        )
    }

    private static func codexProcessIDs(appURL: URL) throws -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // app-server 位于 Resources 并由 daemon 生命周期单独停止；这里只等待主 App 退出。
        process.arguments = ["-f", "\(NSRegularExpression.escapedPattern(for: appURL.path))/Contents/MacOS/"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法启动 Codex 进程探测；已取消账号切换", "Could not start Codex process inspection. Switching was canceled."))
        }
        let data: Data
        do {
            data = try readAllBytes(
                from: output.fileHandleForReading.fileDescriptor,
                maximumBytes: 64 * 1_024,
                failureMessage: WidgetLanguage.storedOrAutomatic().text("无法读取 Codex 进程探测结果；已取消账号切换", "Could not read Codex process inspection results. Switching was canceled.")
            )
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        switch process.terminationStatus {
        case 1:
            return []
        case 0:
            break
        default:
            throw switchError(
                WidgetLanguage.storedOrAutomatic().text("Codex 进程探测异常退出；已取消账号切换", "Codex process inspection exited unexpectedly. Switching was canceled."),
                code: Int(process.terminationStatus)
            )
        }
        guard let outputText = String(data: data, encoding: .utf8), !outputText.isEmpty else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 进程探测返回空结果；已取消账号切换", "Codex process inspection returned no result. Switching was canceled."))
        }
        var lines = outputText.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("Codex 进程探测返回空结果；已取消账号切换", "Codex process inspection returned no result. Switching was canceled."))
        }
        return try lines.map { line in
            guard !line.isEmpty,
                line.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
                let processID = pid_t(line),
                processID > 0
            else {
                throw switchError(
                    WidgetLanguage.storedOrAutomatic().text("Codex 进程探测返回非数字 PID；已取消账号切换", "Codex process inspection returned an invalid PID. Switching was canceled."))
            }
            return processID
        }
    }

    private static func openCodex(at appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw switchError(
                WidgetLanguage.storedOrAutomatic().text("无法重新打开 Codex，原账号已恢复", "Could not reopen Codex. The original account was restored."), code: Int(process.terminationStatus))
        }
    }

    fileprivate static func validatedManagedAuth(at url: URL, profile: CodexProfile) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法读取目标账号凭据", "Could not read the target account's credentials."))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String,
            !accessToken.isEmpty,
            let expectedAccountID = profile.lastSnapshot?.accountID,
            !expectedAccountID.isEmpty,
            let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data),
            identity.accountID == expectedAccountID,
            profile.matchesRecordedCredential(identity)
        else { throw switchError(WidgetLanguage.storedOrAutomatic().text("目标账号凭据无效或身份与账号卡不一致", "Target credentials are invalid or do not match the account card.")) }
        return data
    }

    private static func writeManagedAuthBackup(
        _ state: AuthState,
        to profile: CodexProfile,
        sourceHome: URL,
        fileManager: FileManager
    ) throws {
        guard !profile.isSystemProfile,
            case .data(let data) = state,
            profile.matchesRecordedCredential(
                CodexOfficialProfileReader.credentialIdentity(fromAuthData: data)
            )
        else {
            throw switchError(
                WidgetLanguage.storedOrAutomatic().text("原账号最新凭据无法安全绑定到账号卡", "The original account's latest credentials could not be safely matched to its account card."))
        }
        guard let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data)
        else { throw CodexCredentialTransaction.Failure.invalidIdentity }
        switch try CodexCredentialTransaction.copy(
            from: sourceHome, to: profile.codexHomeURL,
            managedRoot: fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex-account-manager-next/profiles", isDirectory: true),
            expectedSource: data, identity: identity
        ) {
        case .copied, .unchanged, .preservedValidExisting:
            return
        }
    }

    fileprivate static func authState(at url: URL) throws -> AuthState {
        do {
            return .data(try Data(contentsOf: url))
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return .missing
        } catch {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法安全读取当前 Codex 凭据；已取消切换", "Current Codex credentials could not be read safely. Switching was canceled."))
        }
    }

    fileprivate static func authFingerprint(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    fileprivate static func validateSwitchSource(_ auth: AuthState, expected: CodexCredentialIdentity) throws {
        guard !expected.email.isEmpty, !expected.accountID.isEmpty,
            case .data(let data) = auth,
            CodexOfficialProfileReader.credentialIdentity(fromAuthData: data) == expected
        else {
            throw switchError(
                WidgetLanguage.storedOrAutomatic().text(
                    "准备期间 Codex 账号已变化；已取消切换，请重新检查后再试", "The Codex account changed during preparation. Switching was canceled; check it and try again."))
        }
    }

    fileprivate static func identityDigest(for identity: CodexCredentialIdentity) -> Data {
        Data(SHA256.hash(data: Data("\(identity.email)\u{0}\(identity.accountID)".utf8)))
    }

    fileprivate static func identityDigest(for state: AuthState) -> Data? {
        guard case .data(let data) = state,
            let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data)
        else { return nil }
        return identityDigest(for: identity)
    }

    fileprivate static func mayRestoreAuth(
        didWriteTarget: Bool,
        current: AuthState,
        target: Data
    ) -> Bool {
        didWriteTarget && current == .data(target)
    }

    fileprivate static func credentialEmail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any]
        else { return nil }
        return normalizedEmail(CodexOfficialProfileReader.email(fromIDToken: tokens["id_token"] as? String))
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func restoreAuth(_ state: AuthState, expected: AuthState, at url: URL, fileManager: FileManager) throws {
        guard try authState(at: url) == expected else { throw CodexCredentialTransaction.Failure.superseded }
        switch state {
        case .data(let data):
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        case .missing:
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    private static func restoreOriginalCodexRuntimeIfNeeded(
        originalAuth: AuthState,
        originalCodexWasRunning: Bool,
        originalDaemonWasRunning: Bool,
        systemHome: URL,
        appURL suppliedAppURL: URL? = nil,
        previousProcessIDs suppliedProcessIDs: Set<pid_t>? = nil
    ) throws -> Bool {
        guard originalCodexWasRunning || originalDaemonWasRunning else { return false }
        try startCodexDaemonIfNeeded(originalDaemonWasRunning)

        let originalIdentity: CodexCredentialIdentity?
        if case .data(let data) = originalAuth {
            originalIdentity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data)
        } else {
            originalIdentity = nil
        }
        guard originalCodexWasRunning else {
            if let identity = originalIdentity {
                try verifyRuntimeIdentity(
                    at: systemHome,
                    expectedIdentity: identity,
                    daemonRequired: originalDaemonWasRunning
                )
            }
            return false
        }
        guard
            let appURL = suppliedAppURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        else { throw CocoaError(.fileNoSuchFile) }

        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        let processIDs = try codexProcessIDs(appURL: appURL)
        if applications.isEmpty, !processIDs.isEmpty {
            throw switchError(
                WidgetLanguage.storedOrAutomatic().text(
                    "仅检测到未受控的 Codex 辅助进程；未自动补开原 Codex", "Only unmanaged Codex helper processes were found. The original Codex session was not reopened automatically."))
        }

        var previousProcessIDs = suppliedProcessIDs ?? []
        previousProcessIDs.formUnion(applications.map(\.processIdentifier))
        let needsFreshLaunch = applications.isEmpty || originalIdentity == nil
        if !applications.isEmpty, originalIdentity == nil {
            try stopCodexGracefullyIfRunning(appURL: appURL)
            guard try authState(at: systemHome.appendingPathComponent("auth.json")) == originalAuth else {
                throw switchError(
                    WidgetLanguage.storedOrAutomatic().text(
                        "重启原 Codex 前凭据变化；已保留恢复记录且不覆盖",
                        "Credentials changed before restarting the original Codex session. The recovery record was retained and nothing was overwritten."))
            }
        }

        var reopened = false
        if needsFreshLaunch {
            try openCodex(at: appURL)
            try waitForNewCodexProcess(previousProcessIDs: previousProcessIDs)
            reopened = true
        }
        if let identity = originalIdentity {
            try verifyRuntimeIdentity(
                at: systemHome,
                expectedIdentity: identity,
                daemonRequired: originalDaemonWasRunning
            )
        }
        return reopened
    }

    fileprivate static func pendingSwitchRecoveryDecision(
        current: AuthState,
        journal: PendingSwitchJournal
    ) -> PendingSwitchRecoveryDecision {
        if current == journal.originalAuthState { return .originalAlreadyPresent }
        if case .data(let data) = current,
            authFingerprint(data) == journal.targetAuthFingerprint
        {
            return .rollbackOriginal
        }
        guard let currentIdentityDigest = identityDigest(for: current) else { return .preserveExternal }
        let originalIdentityDigest =
            journal.originalIdentityDigest
            ?? identityDigest(for: journal.originalAuthState)
        if currentIdentityDigest == originalIdentityDigest { return .originalAlreadyPresent }
        if currentIdentityDigest == journal.targetIdentityDigest { return .rollbackOriginal }
        return .preserveExternal
    }

    fileprivate static func shouldClearPendingSwitchJournal(
        journalPersisted: Bool,
        retainRecoveryJournal: Bool
    ) -> Bool {
        journalPersisted && !retainRecoveryJournal
    }

    fileprivate static func persistPendingSwitchJournal(
        _ journal: PendingSwitchJournal,
        fileManager: FileManager,
        applicationSupportDirectory: URL? = nil
    ) throws {
        try validatePendingSwitchJournal(journal)
        guard
            try loadPendingSwitchJournal(
                fileManager: fileManager,
                applicationSupportDirectory: applicationSupportDirectory
            ) == nil
        else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("已有未完成的账号切换恢复记录", "An unfinished account-switch recovery record already exists."))
        }
        let directory = try accountManagerSupportDirectory(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory,
            createIfNeeded: true
        )
        let url = directory.appendingPathComponent("pending-account-switch-v1.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        try writeMode600AtomicallyWithoutReplacement(data, to: url)
        guard
            let loaded = try loadPendingSwitchJournal(
                fileManager: fileManager,
                applicationSupportDirectory: applicationSupportDirectory
            ),
            loaded.originalAuthState == journal.originalAuthState,
            loaded.targetAuthFingerprint == journal.targetAuthFingerprint,
            loaded.originalIdentityDigest == journal.originalIdentityDigest,
            loaded.targetIdentityDigest == journal.targetIdentityDigest,
            loaded.originalCodexWasRunning == journal.originalCodexWasRunning,
            loaded.originalDaemonWasRunning == journal.originalDaemonWasRunning
        else { throw switchError(WidgetLanguage.storedOrAutomatic().text("账号切换恢复记录写入后校验失败", "The account-switch recovery record could not be verified after writing.")) }
    }

    fileprivate static func replacePendingSwitchJournal(
        _ expected: PendingSwitchJournal,
        with replacement: PendingSwitchJournal,
        fileManager: FileManager,
        applicationSupportDirectory: URL? = nil
    ) throws {
        try validatePendingSwitchJournal(replacement)
        guard
            try loadPendingSwitchJournal(
                fileManager: fileManager,
                applicationSupportDirectory: applicationSupportDirectory
            ) == expected
        else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("账号切换恢复记录已变化；未覆盖最新状态", "The recovery record changed. Its newer state was not overwritten."))
        }
        let directory = try accountManagerSupportDirectory(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory,
            createIfNeeded: false
        )
        let url = directory.appendingPathComponent("pending-account-switch-v1.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeMode600Atomically(
            encoder.encode(replacement),
            to: url,
            replacingExisting: true
        )
        guard
            try loadPendingSwitchJournal(
                fileManager: fileManager,
                applicationSupportDirectory: applicationSupportDirectory
            ) == replacement
        else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("账号切换恢复记录更新后校验失败", "The recovery record could not be verified after updating."))
        }
    }

    fileprivate static func loadPendingSwitchJournal(
        fileManager: FileManager,
        applicationSupportDirectory: URL? = nil
    ) throws -> PendingSwitchJournal? {
        let directory = try accountManagerSupportDirectory(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory,
            createIfNeeded: false
        )
        let url = directory.appendingPathComponent("pending-account-switch-v1.json")
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法安全打开账号切换恢复记录", "Could not safely open the account-switch recovery record."), code: Int(errno))
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法读取账号切换恢复记录属性", "Could not read the recovery record's file attributes."), code: Int(errno))
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            (metadata.st_mode & mode_t(0o777)) == mode_t(0o600),
            metadata.st_size >= 0,
            metadata.st_size <= 1_048_576
        else { throw switchError(WidgetLanguage.storedOrAutomatic().text("账号切换恢复记录类型、权限或大小不安全", "The recovery record has an unsafe file type, permissions, or size.")) }

        let data = try readAllBytes(
            from: descriptor,
            maximumBytes: 1_048_576,
            failureMessage: WidgetLanguage.storedOrAutomatic().text("无法读取账号切换恢复记录", "Could not read the account-switch recovery record.")
        )
        let journal: PendingSwitchJournal
        do {
            journal = try JSONDecoder().decode(PendingSwitchJournal.self, from: data)
        } catch {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("账号切换恢复记录损坏；已停止自动切换", "The recovery record is corrupt. Automatic switching was stopped."))
        }
        try validatePendingSwitchJournal(journal)
        return journal
    }

    fileprivate static func clearPendingSwitchJournal(
        fileManager: FileManager,
        applicationSupportDirectory: URL? = nil
    ) throws {
        let directory = try accountManagerSupportDirectory(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory,
            createIfNeeded: false
        )
        let url = directory.appendingPathComponent("pending-account-switch-v1.json")
        let result = url.path.withCString { Darwin.unlink($0) }
        guard result == 0 else {
            if errno == ENOENT { return }
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法清理账号切换恢复记录", "Could not remove the account-switch recovery record."), code: Int(errno))
        }
        try syncDirectory(directory)
    }

    private static func validatePendingSwitchJournal(_ journal: PendingSwitchJournal) throws {
        let validVersion = journal.version == 1 || journal.version == 2
        let validIdentityDigests =
            journal.version == 1
            || (journal.targetIdentityDigest?.count == SHA256.Digest.byteCount
                && journal.originalIdentityDigest.map { $0.count == SHA256.Digest.byteCount } != false
                && journal.originalDaemonWasRunning != nil)
        guard validVersion,
            validIdentityDigests,
            journal.targetAuthFingerprint.count == SHA256.Digest.byteCount
        else { throw switchError(WidgetLanguage.storedOrAutomatic().text("账号切换恢复记录版本或指纹无效", "The recovery record's version or fingerprint is invalid.")) }
    }

    private static func writeMode600AtomicallyWithoutReplacement(_ data: Data, to url: URL) throws {
        try writeMode600Atomically(data, to: url, replacingExisting: false)
    }

    private static func writeMode600Atomically(
        _ data: Data,
        to url: URL,
        replacingExisting: Bool
    ) throws {
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法创建账号切换恢复记录临时文件", "Could not create a temporary recovery-record file."), code: Int(errno))
        }
        var installed = false
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if !installed { temporaryURL.path.withCString { _ = Darwin.unlink($0) } }
        }

        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法设置账号切换恢复记录权限", "Could not set the recovery record's permissions."), code: Int(errno))
        }
        try writeAllBytes(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法持久化账号切换恢复记录", "Could not persist the account-switch recovery record."), code: Int(errno))
        }
        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法关闭账号切换恢复记录", "Could not close the account-switch recovery record."), code: Int(errno))
        }
        let renameResult = temporaryURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in
                replacingExisting
                    ? Darwin.rename(sourcePath, destinationPath)
                    : Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard renameResult == 0 else {
            throw switchError(
                !replacingExisting && errno == EEXIST
                    ? WidgetLanguage.storedOrAutomatic().text("已有未完成的账号切换恢复记录", "An unfinished account-switch recovery record already exists.")
                    : WidgetLanguage.storedOrAutomatic().text("无法原子安装账号切换恢复记录", "Could not atomically install the account-switch recovery record."),
                code: Int(errno)
            )
        }
        installed = true
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func writeAllBytes(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw switchError(WidgetLanguage.storedOrAutomatic().text("无法完整写入账号切换恢复记录", "Could not write the complete account-switch recovery record."), code: Int(errno))
                }
                offset += written
            }
        }
    }

    private static func readAllBytes(
        from descriptor: Int32,
        maximumBytes: Int,
        failureMessage: String
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw switchError(failureMessage, code: Int(errno)) }
            if count == 0 { return result }
            guard result.count <= maximumBytes - count else {
                throw switchError(WidgetLanguage.storedOrAutomatic().text("\(failureMessage)；数据超过安全上限", "\(failureMessage); data exceeded the safety limit."))
            }
            result.append(contentsOf: buffer[0..<count])
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法打开恢复记录目录进行持久化", "Could not open the recovery-record folder for persistence."), code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw switchError(WidgetLanguage.storedOrAutomatic().text("无法持久化恢复记录目录", "Could not persist the recovery-record folder."), code: Int(errno))
        }
    }

    private static func accountManagerSupportDirectory(
        fileManager: FileManager,
        applicationSupportDirectory: URL?,
        createIfNeeded: Bool
    ) throws -> URL {
        let support =
            applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        let directory = support.appendingPathComponent("CodexAccountManagerNext", isDirectory: true)
        if createIfNeeded {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return directory
    }

    fileprivate static func acquireSwitchLock(
        fileManager: FileManager,
        applicationSupportDirectory: URL? = nil
    ) throws -> Int32 {
        let directory = try accountManagerSupportDirectory(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory,
            createIfNeeded: true
        )
        let descriptor = Darwin.open(
            directory.appendingPathComponent("account-switch.lock").path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw switchError(WidgetLanguage.storedOrAutomatic().text("无法建立账号切换锁", "Could not create the account-switch lock.")) }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) != -1 else {
            Darwin.close(descriptor)
            throw switchError(WidgetLanguage.storedOrAutomatic().text("另一个账号切换正在进行", "Another account switch is in progress."))
        }
        return descriptor
    }

    fileprivate static func releaseSwitchLock(_ descriptor: Int32) {
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        Darwin.close(descriptor)
    }

    private static func measureSwitchStage<T>(
        _ stage: String,
        operation: () throws -> T
    ) rethrows -> T {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer { logSwitchTiming(stage: stage, startedAt: startedAt) }
        return try operation()
    }

    private static func logSwitchTiming(stage: String, startedAt: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        logSwitchTiming(stage: stage, milliseconds: Int((elapsed + 500_000) / 1_000_000))
    }

    private static func logSwitchTiming(stage: String, milliseconds: Int) {
        debugLog("switch timing: \(stage)=\(milliseconds)ms")
    }

    private static func switchError(_ message: String, code: Int = 1) -> NSError {
        NSError(
            domain: "CodexAccountManagerNext.AccountSwitch",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    func warmUp(
        profile: CodexProfile,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard !isLoginRunning else {
            throw NSError(
                domain: "CodexAccountActions",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text("账号登录正在执行；完成后再暖号", "Sign-in is running. Wait for it to finish before warming up.")]
            )
        }
        guard !isWarmUpRunning else {
            throw NSError(
                domain: "CodexAccountActions",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text("已有暖号请求在执行，请稍候", "A warm-up request is already running. Please wait.")]
            )
        }
        let request = try CodexWarmUpProtocol.request(for: profile)
        let session = CodexWarmUpSession(request: request) { [weak self] result in
            self?.warmUpSession = nil
            completion(result)
        }
        warmUpSession = session
        session.start()
    }

    static func warmUpFailureReason(for error: Error) -> String {
        (error as? CodexWarmUpFailure)?.persistenceCode ?? "unknown"
    }
}

private final class LoginPromotionFailureFileManager: FileManager, @unchecked Sendable {
    var failPath: String?
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if path == failPath {
            failPath = nil
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

enum CodexAccountLoginProtocolSelfTest {
    static func run() -> Bool {
        guard CodexLoginSession.cleanupSelfTest(), CodexLoginSession.deviceSessionSelfTest() else {
            print("account login cleanup self-test failed")
            return false
        }
        let started = CodexLoginProtocolParser.event(
            from: [
                "id": 2,
                "result": [
                    "type": "chatgpt",
                    "loginId": "login-1",
                    "authUrl": "https://auth.openai.com/example",
                ],
            ],
            state: .starting
        )
        let wrongCompletion = CodexLoginProtocolParser.event(
            from: [
                "method": "account/login/completed",
                "params": ["loginId": "other-login", "success": true],
            ],
            state: .waiting(loginID: "login-1")
        )
        let completed = CodexLoginProtocolParser.event(
            from: [
                "method": "account/login/completed",
                "params": ["loginId": "login-1", "success": true],
            ],
            state: .waiting(loginID: "login-1")
        )
        let authenticated = CodexLoginProtocolParser.event(
            from: [
                "id": 3,
                "result": [
                    "requiresOpenaiAuth": true,
                    "account": ["type": "chatgpt", "email": "person@example.com"],
                ],
            ],
            state: .readingAccount
        )
        let failure = CodexLoginProtocolParser.event(
            from: [
                "method": "account/login/completed",
                "params": ["loginId": "login-2", "success": false, "error": "cancelled"],
            ],
            state: .waiting(loginID: "login-2")
        )
        let lateCompletion = CodexLoginProtocolParser.event(
            from: [
                "method": "account/login/completed",
                "params": ["loginId": "login-2", "success": true],
            ],
            state: .finished
        )
        guard
            started
                == .loginStarted(
                    loginID: "login-1",
                    authURL: "https://auth.openai.com/example"
                ),
            wrongCompletion == .none,
            completed == .loginCompleted,
            authenticated == .authenticated(email: "person@example.com"),
            failure == .failed("cancelled"),
            lateCompletion == .none
        else {
            print("account login protocol self-test failed")
            return false
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codex-login-self-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        do {
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            let target = root.appendingPathComponent("target", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            let loginPayload = Data(#"{"email":"person@example.com"}"#.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let stagedAuth = Data(
                #"{"tokens":{"access_token":"test-only","id_token":"e30.\#(loginPayload).sig","account_id":"acct-person"}}"#.utf8
            )
            let originalAuth = Data(#"{"original":true}"#.utf8)
            try stagedAuth.write(to: staging.appendingPathComponent("auth.json"))
            try originalAuth.write(to: target.appendingPathComponent("auth.json"))
            let profile = CodexProfile(
                id: "test",
                name: "person@example.com",
                codexHomePath: target.path,
                isSystemProfile: false,
                createdAt: Date(timeIntervalSince1970: 0),
                lastSnapshot: CodexAccountSnapshot(
                    accountType: "chatgpt",
                    planType: nil,
                    email: "person@example.com",
                    accountID: "acct-person",
                    limitId: nil,
                    limitName: nil,
                    fiveHour: nil,
                    sevenDay: nil,
                    monthly: nil,
                    fetchedAt: Date(timeIntervalSince1970: 0),
                    appServerVersion: nil
                )
            )
            do {
                try CodexLoginSession.promoteCredentials(
                    from: staging,
                    to: profile,
                    authenticatedEmail: "other@example.com",
                    fileManager: fileManager
                )
                print("account login protocol self-test failed: identity mismatch was accepted")
                return false
            } catch {}
            guard try Data(contentsOf: target.appendingPathComponent("auth.json")) == originalAuth else {
                print("account login protocol self-test failed: identity mismatch overwrote auth")
                return false
            }
            try CodexLoginSession.promoteCredentials(
                from: staging,
                to: profile,
                authenticatedEmail: "PERSON@example.com",
                fileManager: fileManager
            )
            guard try Data(contentsOf: target.appendingPathComponent("auth.json")) == stagedAuth else {
                print("account login protocol self-test failed: verified auth was not promoted")
                return false
            }
            let failedPromotionAuth = Data(String(decoding: stagedAuth, as: UTF8.self).replacingOccurrences(of: "test-only", with: "changed-test-only").utf8)
            try failedPromotionAuth.write(to: staging.appendingPathComponent("auth.json"))
            let failingManager = LoginPromotionFailureFileManager()
            failingManager.failPath = target.appendingPathComponent("auth.json").path
            do {
                try CodexLoginSession.promoteCredentials(from: staging, to: profile, authenticatedEmail: "person@example.com", fileManager: failingManager)
                return false
            } catch {}
            guard try Data(contentsOf: target.appendingPathComponent("auth.json")) == stagedAuth else { return false }
            try stagedAuth.write(to: staging.appendingPathComponent("auth.json"))
            var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
            var legacySnapshot = legacyObject["lastSnapshot"] as! [String: Any]
            legacySnapshot.removeValue(forKey: "accountID")
            legacyObject["lastSnapshot"] = legacySnapshot
            let legacyProfile = try JSONDecoder().decode(CodexProfile.self, from: JSONSerialization.data(withJSONObject: legacyObject))
            guard legacyProfile.matchesRecordedCredential(.init(email: "person@example.com", accountID: "acct-person")),
                !legacyProfile.matchesRecordedCredential(nil),
                !legacyProfile.matchesRecordedCredential(.init(email: "other@example.com", accountID: "acct-other")),
                !profile.matchesRecordedCredential(.init(email: "person@example.com", accountID: "acct-other"))
            else { return false }
            try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: staging.appendingPathComponent("auth.json"))
            do {
                try CodexLoginSession.promoteCredentials(from: staging, to: profile, authenticatedEmail: "person@example.com", fileManager: fileManager)
                return false
            } catch {}
            guard try Data(contentsOf: target.appendingPathComponent("auth.json")) == stagedAuth else { return false }
        } catch {
            print("account login protocol self-test failed: \(error)")
            return false
        }
        print("account login protocol self-test passed")
        return true
    }
}

enum CodexManualAccountSwitchPolicy {
    static func isForcedManualSwitch(
        isAutomaticSwitch: Bool,
        userConfirmedForce: Bool
    ) -> Bool {
        userConfirmedForce && !isAutomaticSwitch
    }

    static func requiresForceConfirmation(
        codexWasRunning: Bool,
        isAutomaticSwitch: Bool,
        isForcedManualSwitch: Bool,
        canPreserveSession: Bool = false
    ) -> Bool {
        codexWasRunning && !isAutomaticSwitch && !isForcedManualSwitch && !canPreserveSession
    }
}

enum CodexAccountSwitchSafetySelfTest {
    static func run() -> Bool {
        guard
            CodexSwitchPreparation.selfTest(),
            CodexSwitchSnapshotProjection.selfTest(),
            !CodexManualAccountSwitchPolicy.requiresForceConfirmation(
                codexWasRunning: true, isAutomaticSwitch: false,
                isForcedManualSwitch: false, canPreserveSession: true),
            CodexManualAccountSwitchPolicy.requiresForceConfirmation(
                codexWasRunning: true,
                isAutomaticSwitch: false,
                isForcedManualSwitch: false
            ),
            !CodexManualAccountSwitchPolicy.requiresForceConfirmation(
                codexWasRunning: false,
                isAutomaticSwitch: false,
                isForcedManualSwitch: false
            ),
            CodexManualAccountSwitchPolicy.isForcedManualSwitch(
                isAutomaticSwitch: false,
                userConfirmedForce: true
            ),
            !CodexManualAccountSwitchPolicy.isForcedManualSwitch(
                isAutomaticSwitch: true,
                userConfirmedForce: true
            )
        else {
            print("Codex account switch safety self-test failed: manual force policy")
            return false
        }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codex-account-switch-safety-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        do {
            let home = root.appendingPathComponent("profile", isDirectory: true)
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
            let payload = Data(#"{"email":"person@example.com"}"#.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let auth = Data(
                #"{"tokens":{"access_token":"test-only","id_token":"e30.\#(payload).sig","account_id":"acct-person"}}"#.utf8
            )
            let authURL = home.appendingPathComponent("auth.json")
            try auth.write(to: authURL)
            let profile = CodexProfile(
                id: "test",
                name: "person@example.com",
                codexHomePath: home.path,
                isSystemProfile: false,
                createdAt: Date(timeIntervalSince1970: 0),
                lastSnapshot: CodexAccountSnapshot(
                    accountType: "chatgpt",
                    planType: "plus",
                    email: "person@example.com",
                    accountID: "acct-person",
                    limitId: nil,
                    limitName: nil,
                    fiveHour: nil,
                    sevenDay: nil,
                    monthly: nil,
                    fetchedAt: Date(timeIntervalSince1970: 0),
                    appServerVersion: nil
                )
            )
            guard try CodexAccountActions.validatedManagedAuth(at: authURL, profile: profile) == auth else {
                print("Codex account switch safety self-test failed: valid identity rejected")
                return false
            }
            var mismatched = profile
            mismatched.lastSnapshot = CodexAccountSnapshot(
                accountType: "chatgpt",
                planType: "plus",
                email: "other@example.com",
                accountID: "acct-person",
                limitId: nil,
                limitName: nil,
                fiveHour: nil,
                sevenDay: nil,
                monthly: nil,
                fetchedAt: Date(timeIntervalSince1970: 0),
                appServerVersion: nil
            )
            guard (try? CodexAccountActions.validatedManagedAuth(at: authURL, profile: mismatched)) == nil else {
                print("Codex account switch safety self-test failed: mismatched identity accepted")
                return false
            }
            let descriptor = try CodexAccountActions.acquireSwitchLock(
                fileManager: fileManager,
                applicationSupportDirectory: root
            )
            CodexAccountActions.releaseSwitchLock(descriptor)
            let attributes = try fileManager.attributesOfItem(
                atPath: root.appendingPathComponent("CodexAccountManagerNext/account-switch.lock").path
            )
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                print("Codex account switch safety self-test failed: lock permissions")
                return false
            }
            guard try CodexAccountActions.authState(at: authURL) == .data(auth),
                try CodexAccountActions.authState(at: root.appendingPathComponent("missing-auth.json")) == .missing,
                CodexAccountActions.authFingerprint(auth) == CodexAccountActions.authFingerprint(auth),
                CodexAccountActions.authFingerprint(auth) != CodexAccountActions.authFingerprint(Data("different".utf8)),
                CodexAccountActions.mayRestoreAuth(
                    didWriteTarget: true,
                    current: .data(auth),
                    target: auth
                ),
                !CodexAccountActions.mayRestoreAuth(
                    didWriteTarget: true,
                    current: .data(Data("external-change".utf8)),
                    target: auth
                ),
                !CodexAccountActions.mayRestoreAuth(
                    didWriteTarget: false,
                    current: .data(auth),
                    target: auth
                ),
                CodexAccountActions.daemonRunningStatus(
                    from: Data(#"{"status":"running"}"#.utf8)
                ) == true,
                CodexAccountActions.daemonRunningStatus(
                    from: Data(#"{"status":"notRunning"}"#.utf8)
                ) == false,
                CodexAccountActions.daemonRunningStatus(from: Data(#"{"status":"unknown"}"#.utf8)) == nil,
                CodexAccountActions.daemonSocketPath(
                    from: Data(#"{"socketPath":"/tmp/codex.sock"}"#.utf8)
                ) == "/tmp/codex.sock",
                CodexAccountActions.daemonSocketPath(
                    from: Data(#"{"socketPath":"relative.sock"}"#.utf8)
                ) == nil
            else {
                print("Codex account switch safety self-test failed: auth state, fingerprint, or rollback ownership")
                return false
            }
            do {
                _ = try CodexAccountActions.authState(at: home)
                print("Codex account switch safety self-test failed: unreadable auth treated as missing")
                return false
            } catch {}
            func makeAuth(email: String, accountID: String, accessToken: String) -> Data {
                let tokenPayload = Data(#"{"email":"\#(email)"}"#.utf8)
                    .base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                return Data(
                    #"{"tokens":{"access_token":"\#(accessToken)","id_token":"e30.\#(tokenPayload).sig","account_id":"\#(accountID)"}}"#.utf8
                )
            }
            let originalAuth = makeAuth(
                email: "source@example.com",
                accountID: "acct-source",
                accessToken: "source-original"
            )
            let rotatedOriginalAuth = makeAuth(
                email: "source@example.com",
                accountID: "acct-source",
                accessToken: "source-rotated"
            )
            let rotatedTargetAuth = makeAuth(
                email: "person@example.com",
                accountID: "acct-person",
                accessToken: "target-rotated"
            )
            let externalAuth = makeAuth(
                email: "external@example.com",
                accountID: "acct-external",
                accessToken: "external"
            )
            let expectedSource = CodexCredentialIdentity(email: "source@example.com", accountID: "acct-source")
            try CodexAccountActions.validateSwitchSource(.data(originalAuth), expected: expectedSource)
            try CodexAccountActions.validateSwitchSource(.data(rotatedOriginalAuth), expected: expectedSource)
            let sameEmailDifferentIdentity = makeAuth(email: "source@example.com", accountID: "acct-other", accessToken: "external")
            for changed in [CodexAccountActions.AuthState.data(externalAuth), .data(sameEmailDifferentIdentity), .missing] {
                do {
                    try CodexAccountActions.validateSwitchSource(changed, expected: expectedSource)
                    print("Codex account switch safety self-test failed: source identity drift accepted")
                    return false
                } catch {}
            }
            let pending = CodexAccountActions.PendingSwitchJournal(
                originalAuth: .data(originalAuth),
                targetAuthFingerprint: CodexAccountActions.authFingerprint(auth),
                targetIdentity: CodexCredentialIdentity(
                    email: "person@example.com",
                    accountID: "acct-person"
                ),
                originalCodexWasRunning: true,
                originalDaemonWasRunning: true,
                createdAt: Date(timeIntervalSince1970: 0)
            )
            try CodexAccountActions.persistPendingSwitchJournal(
                pending,
                fileManager: fileManager,
                applicationSupportDirectory: root
            )
            let journalURL = root.appendingPathComponent(
                "CodexAccountManagerNext/pending-account-switch-v1.json"
            )
            let journalAttributes = try fileManager.attributesOfItem(atPath: journalURL.path)
            guard (journalAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                try CodexAccountActions.loadPendingSwitchJournal(
                    fileManager: fileManager,
                    applicationSupportDirectory: root
                ) == pending,
                CodexAccountActions.pendingSwitchRecoveryDecision(
                    current: .data(auth),
                    journal: pending
                ) == .rollbackOriginal,
                CodexAccountActions.pendingSwitchRecoveryDecision(
                    current: .data(originalAuth),
                    journal: pending
                ) == .originalAlreadyPresent,
                CodexAccountActions.pendingSwitchRecoveryDecision(
                    current: .data(rotatedOriginalAuth),
                    journal: pending
                ) == .originalAlreadyPresent,
                CodexAccountActions.pendingSwitchRecoveryDecision(
                    current: .data(rotatedTargetAuth),
                    journal: pending
                ) == .rollbackOriginal,
                CodexAccountActions.pendingSwitchRecoveryDecision(
                    current: .data(externalAuth),
                    journal: pending
                ) == .preserveExternal,
                CodexAccountActions.shouldClearPendingSwitchJournal(
                    journalPersisted: true,
                    retainRecoveryJournal: false
                ),
                !CodexAccountActions.shouldClearPendingSwitchJournal(
                    journalPersisted: true,
                    retainRecoveryJournal: true
                ),
                !CodexAccountActions.shouldClearPendingSwitchJournal(
                    journalPersisted: false,
                    retainRecoveryJournal: false
                )
            else {
                print("Codex account switch safety self-test failed: journal decision or permissions")
                return false
            }
            let updatedPending = CodexAccountActions.PendingSwitchJournal(
                originalAuth: .data(rotatedOriginalAuth),
                targetAuthFingerprint: CodexAccountActions.authFingerprint(auth),
                targetIdentity: CodexCredentialIdentity(
                    email: "person@example.com",
                    accountID: "acct-person"
                ),
                originalCodexWasRunning: true,
                originalDaemonWasRunning: true,
                createdAt: pending.createdAt
            )
            try CodexAccountActions.replacePendingSwitchJournal(
                pending,
                with: updatedPending,
                fileManager: fileManager,
                applicationSupportDirectory: root
            )
            guard
                try CodexAccountActions.loadPendingSwitchJournal(
                    fileManager: fileManager,
                    applicationSupportDirectory: root
                ) == updatedPending
            else {
                print("Codex account switch safety self-test failed: journal rotation update")
                return false
            }
            try CodexAccountActions.clearPendingSwitchJournal(
                fileManager: fileManager,
                applicationSupportDirectory: root
            )
            guard !fileManager.fileExists(atPath: journalURL.path),
                try CodexAccountActions.loadPendingSwitchJournal(
                    fileManager: fileManager,
                    applicationSupportDirectory: root
                ) == nil
            else {
                print("Codex account switch safety self-test failed: journal cleanup")
                return false
            }

            let legacyJournal = try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "createdAt": Date(timeIntervalSince1970: 0).timeIntervalSinceReferenceDate,
                "originalAuth": originalAuth.base64EncodedString(),
                "targetAuthFingerprint": CodexAccountActions.authFingerprint(auth).base64EncodedString(),
                "originalCodexWasRunning": true,
            ])
            try legacyJournal.write(to: journalURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            guard
                let loadedLegacy = try CodexAccountActions.loadPendingSwitchJournal(
                    fileManager: fileManager,
                    applicationSupportDirectory: root
                ),
                loadedLegacy.version == 1,
                CodexAccountActions.pendingSwitchRecoveryDecision(
                    current: .data(rotatedOriginalAuth),
                    journal: loadedLegacy
                ) == .originalAlreadyPresent
            else {
                print("Codex account switch safety self-test failed: legacy journal recovery")
                return false
            }
            try CodexAccountActions.clearPendingSwitchJournal(
                fileManager: fileManager,
                applicationSupportDirectory: root
            )

            let chromeHome = root.appendingPathComponent("chrome-home", isDirectory: true)
            let chromeRoot =
                chromeHome
                .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
            try fileManager.createDirectory(
                at: chromeRoot.appendingPathComponent("Default", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: chromeRoot.appendingPathComponent("Profile 2", isDirectory: true),
                withIntermediateDirectories: true
            )
            let localState = try JSONSerialization.data(withJSONObject: [
                "profile": [
                    "info_cache": [
                        "Default": ["name": "工作", "user_name": "person@example.com"],
                        "Profile 2": ["name": "备用", "user_name": "source@example.com"],
                        "Guest Profile": ["name": "访客"],
                    ]
                ]
            ])
            try localState.write(to: chromeRoot.appendingPathComponent("Local State"), options: .atomic)
            let chromeProfiles = ChromeProfileBrowser.availableProfiles(
                fileManager: fileManager,
                homeDirectory: chromeHome
            )
            let managedChrome = root.appendingPathComponent("managed-chrome", isDirectory: true)
            guard let authenticationURL = URL(string: "https://auth.openai.com/example"),
                chromeProfiles.map(\.directoryName) == ["Default", "Profile 2"],
                ChromeProfileBrowser.matchingProfile(
                    for: "PERSON@example.com",
                    fileManager: fileManager,
                    homeDirectory: chromeHome
                )?.directoryName == "Default",
                let boundChrome = chromeProfiles.first,
                ChromeProfileBrowser.launchArguments(
                    binding: boundChrome,
                    url: authenticationURL
                ) == [
                    "--profile-directory=Default",
                    "--new-window",
                    "https://auth.openai.com/example",
                ],
                ChromeProfileBrowser.launchArguments(
                    binding: nil,
                    managedUserDataDirectory: managedChrome,
                    url: authenticationURL
                ) == [
                    "--user-data-dir=\(managedChrome.path)",
                    "--profile-directory=Default",
                    "--no-first-run",
                    "--new-window",
                    "https://auth.openai.com/example",
                ]
            else {
                print("Codex account switch safety self-test failed: Chrome profile routing")
                return false
            }
            let routed = CodexProfile(
                id: "chrome-route", name: "Demo", codexHomePath: managedChrome.path, isSystemProfile: false, createdAt: Date(),
                chromeProfile: boundChrome)
            let dedicatedRoute = CodexDeviceBrowserRouting.launchPlan(choice: .dedicatedChrome, profile: routed)
            let defaultRoute = CodexDeviceBrowserRouting.launchPlan(choice: .systemDefault, profile: routed)
            guard dedicatedRoute.binding == nil,
                dedicatedRoute.managedUserDataDirectory == routed.codexHomeURL.appendingPathComponent("chrome-session", isDirectory: true),
                defaultRoute.binding == nil,
                defaultRoute.managedUserDataDirectory == nil
            else {
                print("Codex account switch safety self-test failed: frozen browser routing")
                return false
            }
            print("Codex account switch safety self-test passed")
            return true
        } catch {
            print("Codex account switch safety self-test failed: \(error)")
            return false
        }
    }
}
