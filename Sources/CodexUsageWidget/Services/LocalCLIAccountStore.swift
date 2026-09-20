import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation

@MainActor
final class LocalCLIAccountStore: ObservableObject {
    typealias QuotaLoader = @Sendable (LocalCLIProfile) async -> LocalCLIQuotaResult
    @Published private(set) var profiles: [LocalCLIProfile] = []
    @Published private(set) var installed: [LocalCLIKind: String] = [:]
    @Published private(set) var workBuddyInstalled: [WorkBuddyEdition: String] = [:]
    @Published private(set) var quotas: [String: LocalCLIQuotaResult] = [:]
    @Published private(set) var stale: Set<String> = []
    @Published private(set) var refreshing: Set<String> = []
    @Published private(set) var signingIn: Set<String> = []
    @Published private(set) var loginMessages: [String: String] = [:]
    @Published private(set) var authentication: [String: LocalCLIAuthentication] = [:]
    @Published var message: String?
    private var requests: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var loginTasks: [String: Task<Void, Never>] = [:]
    private var authenticationTasks: [String: Task<Void, Never>] = [:]
    private var loginVerification: Set<String> = []
    private var saved: [LocalCLIProfile] = []
    private var savedDigest: Data?
    private var storageValid = true
    private let home: URL
    private let support: URL
    private let applicationsDirectory: URL
    private let quotaLoader: QuotaLoader
    private let grokObservationReader: GrokResetStatusObservationReader
    private let clock: @Sendable () -> Date

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        support: URL = DispatchParticipationPaths.supportDirectory(),
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        quotaLoader: @escaping QuotaLoader = { profile in
            switch profile.kind {
            case .gemini, .mimo:
                await AdditionalCLIQuotaReader().load(profile: profile)
            case .zcode:
                await ZCodeCLIQuotaReader().load(profile: profile)
            case .claudeCode, .grok, .openCode, .kimi, .trae, .workBuddy:
                await LocalCLIQuotaReader().load(profile: profile)
            }
        },
        grokObservationReader: GrokResetStatusObservationReader = GrokResetStatusObservationReader(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.support = support
        self.applicationsDirectory = applicationsDirectory
        self.quotaLoader = quotaLoader
        self.grokObservationReader = grokObservationReader
        self.clock = clock
    }

    static func preview(profiles: [LocalCLIProfile], quotas: [String: LocalCLIQuotaResult], root: URL) -> LocalCLIAccountStore {
        let model = LocalCLIAccountStore(home: root, support: root, applicationsDirectory: root)
        model.profiles = profiles
        model.quotas = quotas
        for profile in profiles {
            let executable = root.appendingPathComponent(profile.kind.commandName).path
            model.installed[profile.kind] = executable
            if profile.kind == .workBuddy { model.workBuddyInstalled[WorkBuddyEdition.forProfile(profile)] = executable }
        }
        return model
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
        loginTasks.values.forEach { $0.cancel() }
        authenticationTasks.values.forEach { $0.cancel() }
    }

    func discover() {
        let fm = FileManager.default
        var found: [LocalCLIKind: String] = [:]
        var workBuddyFound: [WorkBuddyEdition: String] = [:]
        let applicationRoots = [applicationsDirectory, home.appendingPathComponent("Applications", isDirectory: true)]
        for kind in LocalCLIKind.allCases {
            if kind == .workBuddy {
                // WorkBuddy ships a product-specific CLI. Never substitute an external
                // codebuddy/cbc executable, which may belong to another product/account.
                for edition in WorkBuddyEdition.allCases {
                    for applicationRoot in applicationRoots {
                        let app = applicationRoot.appendingPathComponent(edition.applicationName, isDirectory: true)
                        let cli = app.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/bin/codebuddy")
                        let electron = app.appendingPathComponent("Contents/MacOS/Electron")
                        let product = app.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/product.json")
                        if regularFile(cli, executable: true), regularFile(electron, executable: true),
                            regularFile(product, executable: false)
                        {
                            workBuddyFound[edition] = cli.path
                            break
                        }
                    }
                }
                found[kind] = workBuddyFound[.domestic] ?? workBuddyFound[.international]
                continue
            }
            if kind == .trae {
                let names = ["TRAE SOLO CN.app", "TRAE SOLO.app"]
                if let app = applicationRoots.flatMap({ root in names.map { root.appendingPathComponent($0, isDirectory: true) } })
                    .first(where: isOfficialTRAESOLO)
                {
                    found[kind] = app.path
                }
                continue
            }
            if kind == .zcode {
                for applicationRoot in applicationRoots {
                    let app = applicationRoot.appendingPathComponent("ZCode.app", isDirectory: true)
                    if isOfficialZCode(app) {
                        found[kind] = app.path
                        break
                    }
                }
                continue
            }
            var candidates = [
                home.appendingPathComponent(".local/bin/\(kind.commandName)").path,
                "/opt/homebrew/bin/\(kind.commandName)", "/usr/local/bin/\(kind.commandName)",
            ]
            if kind == .grok { candidates.insert(home.appendingPathComponent(".grok/bin/grok").path, at: 0) }
            if kind == .mimo { candidates.insert(home.appendingPathComponent(".mimocode/bin/mimo").path, at: 0) }
            if let path = candidates.first(where: fm.isExecutableFile(atPath:)) {
                found[kind] = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
        }
        installed = found
        workBuddyInstalled = workBuddyFound
        do {
            let data = try DispatchParticipationSync.readBoundedRegularFile(storageURL, maximumBytes: 256 * 1024, allowMissing: true)
            let decoded = try data.map { try JSONDecoder().decode([LocalCLIProfile].self, from: $0) } ?? []
            guard decoded.count <= 64, Set(decoded.map(\.id)).count == decoded.count,
                decoded.allSatisfy(validProfile)
            else { throw Failure.invalid }
            saved = decoded
            savedDigest = data.map { Data(SHA256.hash(data: $0)) }
            storageValid = true
        } catch {
            storageValid = false
            message = language.text("账号关联记录无法读取；原文件已保留。", "Account links could not be read. The existing file was preserved.")
        }
        rebuildProfiles()
        mergeImportedGrokObservation()
        checkLocalSignIns()
    }

    func profiles(for kind: LocalCLIKind) -> [LocalCLIProfile] { profiles.filter { $0.kind == kind } }

    func createGrokAccount(name: String) -> LocalCLIProfile? {
        guard storageValid, validName(name), installed[.grok] != nil, saved.count < 64 else {
            fail(Failure.invalid)
            return nil
        }
        let id = UUID().uuidString.lowercased()
        let root = home.appendingPathComponent(".codex-account-manager-next/grok", isDirectory: true)
        let directory = root.appendingPathComponent(id.replacingOccurrences(of: "-", with: ""), isDirectory: true)
        do {
            guard validDirectory(root.path), directory.appendingPathComponent("leader.sock").path.utf8.count < 104 else {
                throw Failure.invalid
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == geteuid(), info.st_mode & 0o077 == 0
            else { throw Failure.invalid }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let profile = LocalCLIProfile(id: id, kind: .grok, displayName: name, configDirectory: directory.path, isDefault: false)
            guard save(saved + [profile]) else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            return profile
        } catch {
            fail(error)
            return nil
        }
    }

    func signIn(_ profile: LocalCLIProfile, updateProvider: Bool = false) {
        guard canSignIn(profile), signingIn.isEmpty,
            let executable = executable(for: profile)
        else { return }
        if profile.kind == .openCode, !updateProvider {
            checkLocalSignIn(profile)
            if hasConfiguredAuthentication(profile) {
                loginMessages[profile.id] = language.text(
                    "已复用保存的服务商配置，可直接打开 OpenCode。需要新增或更换 API 时选择“添加或更新服务商”。",
                    "Saved provider configuration is ready to reuse. Open OpenCode directly; choose Add or update provider only to change credentials.")
                return
            }
        }
        let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
        do {
            if profile.isDefault {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            guard validDirectory(directory.path) else { throw Failure.invalid }
        } catch {
            fail(error)
            return
        }
        tasks.removeValue(forKey: profile.id)?.cancel()
        requests.removeValue(forKey: profile.id)
        refreshing.remove(profile.id)
        quotas.removeValue(forKey: profile.id)
        stale.remove(profile.id)
        signingIn.insert(profile.id)
        loginMessages[profile.id] =
            switch profile.kind {
            case .grok:
                language.text(
                    "请在浏览器完成 Grok OAuth。完成后会自动核验当前独立环境。",
                    "Complete Grok OAuth in your browser. The isolated environment will then be verified.")
            case .openCode:
                language.text(
                    "请在官方 opencode 中选择服务商并登录。模型按“服务商/模型”区分；凭据只填写在官方终端。",
                    "Choose and sign in to a provider in official opencode. Models are identified as provider/model; enter credentials only in the official terminal.")
            case .workBuddy:
                language.text(
                    "请在 WorkBuddy 内置 CLI 中输入 /login 完成登录，再选择账号可用的模型。",
                    "Enter /login in WorkBuddy's bundled CLI, then choose a model available to your account.")
            case .zcode:
                language.text(
                    "请在 ZCode 桌面应用中完成登录。",
                    "Complete sign-in in the ZCode desktop app.")
            case .gemini:
                language.text(
                    "在 Gemini CLI 中使用 Google 登录或 API Key；已有配置会复用。需要更换方式时输入 /auth。完成后自动检测，不必退出终端；额度单独读取。",
                    "Use Google sign-in or an API key in Gemini CLI. Existing configuration is reused; enter /auth to change it. Detection does not require closing Terminal; quota is read separately."
                )
            case .claudeCode:
                language.text(
                    "已打开 Claude Code 官方登录。完成浏览器授权后自动刷新；API 配置与订阅额度分别核验。",
                    "Official Claude Code sign-in is open. Limits refresh after browser authorization; API configuration and subscription limits are verified separately.")
            case .trae, .kimi, .mimo:
                language.text(
                    "请在官方 CLI 中完成登录；凭据只填写在官方终端。",
                    "Complete sign-in in the official CLI and enter credentials only there.")
            }
        loginTasks[profile.id] = Task { [weak self] in
            do {
                let session = try await LocalCLITerminalLauncher.launch(profile: profile, executable: executable, action: .signIn, workingDirectory: directory)
                let code = try await LocalCLITerminalLauncher.waitForExit(session)
                guard let self, !Task.isCancelled,
                    let current = self.profiles.first(where: { $0.id == profile.id && $0.configDirectory == profile.configDirectory })
                else { return }
                self.signingIn.remove(profile.id)
                self.loginTasks.removeValue(forKey: profile.id)
                self.authenticationTasks.removeValue(forKey: profile.id)?.cancel()
                if code == 0 {
                    self.loginVerification.insert(profile.id)
                    self.loginMessages[profile.id] = self.language.text("官方登录流程已结束，正在核验账号。", "The official sign-in flow ended. Verifying the account.")
                    self.refresh(current)
                } else {
                    self.loginMessages[profile.id] = self.language.text("登录未完成，请查看终端提示后重试。", "Sign-in did not finish. Check the terminal and try again.")
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.signingIn.remove(profile.id)
                self.loginTasks.removeValue(forKey: profile.id)
                self.authenticationTasks.removeValue(forKey: profile.id)?.cancel()
                self.loginMessages[profile.id] = self.language.text(
                    "暂未确认登录结果。若浏览器已授权，点击刷新核验；终端窗口已保留。", "Sign-in has not been confirmed. If browser authorization finished, refresh to verify. The terminal was left open.")
            }
        }
        authenticationTasks[profile.id]?.cancel()
        authenticationTasks[profile.id] = Task { [weak self] in
            // Interactive CLIs remain open after authentication. Watch their
            // local credential evidence instead of requiring process exit.
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.signingIn.contains(profile.id) else { return }
                self.checkLocalSignIn(profile)
            }
        }
    }

    func openCLI(_ profile: LocalCLIProfile, workingDirectory: URL) {
        guard canOpen(profile), !signingIn.contains(profile.id),
            let executable = executable(for: profile)
        else { return }
        if profile.kind.isDesktopApplication {
            let app = URL(fileURLWithPath: executable, isDirectory: true)
            guard profile.kind == .zcode ? isOfficialZCode(app) : isOfficialTRAESOLO(app) else { return }
            Task { [weak self] in
                do {
                    _ = try await NSWorkspace.shared.openApplication(
                        at: app, configuration: NSWorkspace.OpenConfiguration())
                } catch {
                    self?.message = self?.language.text(
                        "未能打开桌面应用，请确认官方应用仍安装在“应用程序”中。",
                        "The desktop app could not open. Confirm that the official app is still installed in Applications.")
                }
            }
            return
        }
        let profileDirectory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
        do {
            if profile.isDefault {
                try FileManager.default.createDirectory(
                    at: profileDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            guard validDirectory(profileDirectory.path) else { throw Failure.invalid }
        } catch {
            fail(error)
            return
        }
        Task { [weak self] in
            do {
                _ = try await LocalCLITerminalLauncher.launch(profile: profile, executable: executable, action: .open, workingDirectory: workingDirectory)
            } catch {
                self?.message = self?.language.text("未能打开 CLI，请检查终端与工作目录。", "The CLI could not open. Check Terminal and the working directory.")
            }
        }
    }

    /// The user has finished authorization inside an interactive TUI. Stop only
    /// waiting for its exit; leave the user's terminal and its receipt intact.
    func checkInteractiveSignIn(_ profile: LocalCLIProfile) {
        guard profiles.contains(profile) else { return }
        loginTasks.removeValue(forKey: profile.id)?.cancel()
        authenticationTasks.removeValue(forKey: profile.id)?.cancel()
        signingIn.remove(profile.id)
        authentication[profile.id] = LocalCLIAuthenticationReader().read(profile)
        loginVerification.insert(profile.id)
        refresh(profile)
    }

    func checkLocalSignIns() {
        for profile in profiles { checkLocalSignIn(profile) }
    }

    private func checkLocalSignIn(_ profile: LocalCLIProfile) {
        let evidence = LocalCLIAuthenticationReader().read(profile)
        authentication[profile.id] = evidence
        if evidence.isConfigured, signingIn.contains(profile.id) {
            checkInteractiveSignIn(profile)
        }
    }

    func hasConfiguredAuthentication(_ profile: LocalCLIProfile) -> Bool {
        authentication[profile.id]?.isConfigured == true
            || (!stale.contains(profile.id) && quotas[profile.id]?.state == .available && quotas[profile.id]?.identityFingerprint?.isEmpty == false)
    }

    func authenticationTitle(_ profile: LocalCLIProfile) -> String {
        if let evidence = authentication[profile.id], evidence.isConfigured { return evidence.title(language) }
        return language.text("已读到账号", "Account detected")
    }

    func canSignIn(_ profile: LocalCLIProfile) -> Bool {
        profile.kind.supportsTerminalSignIn && profiles.contains(profile)
            && executable(for: profile) != nil
            && (!profile.kind.requiresDefaultEnvironmentForLaunch || profile.isDefault)
    }

    func canOpen(_ profile: LocalCLIProfile) -> Bool {
        profile.kind.supportsNativeOpen && profiles.contains(profile)
            && executable(for: profile) != nil
            && (!profile.kind.requiresDefaultEnvironmentForLaunch || profile.isDefault)
    }

    func executable(for profile: LocalCLIProfile) -> String? {
        profile.kind == .workBuddy ? workBuddyInstalled[WorkBuddyEdition.forProfile(profile)] : installed[profile.kind]
    }

    func link(kind: LocalCLIKind, directory: URL, name: String) {
        let path = directory.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard kind.supportsLinkedEnvironments, validName(name), validDirectory(path), installed[kind] != nil,
            !path.lowercased().hasSuffix(".app"),
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            fail(Failure.invalid)
            return
        }
        if kind == .grok {
            var info = stat()
            guard lstat(directory.appendingPathComponent("auth.json").path, &info) == 0,
                info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1
            else {
                message = language.text(
                    "这个文件夹没有 Grok 登录配置。请使用“新增账号并登录”，或选择含 auth.json 的已有配置文件夹。",
                    "This folder has no Grok sign-in configuration. Add an account and sign in, or select an existing folder containing auth.json.")
                return
            }
        }
        guard !profiles.contains(where: { $0.kind == kind && $0.configDirectory == path }) else {
            message = language.text("这个账号目录已经关联。", "This account directory is already linked.")
            return
        }
        var next = saved
        next.append(LocalCLIProfile(id: UUID().uuidString.lowercased(), kind: kind, displayName: name, configDirectory: path, isDefault: false))
        save(next)
    }

    @discardableResult
    func rename(_ profile: LocalCLIProfile, name: String) -> Bool {
        guard profiles.contains(profile), validName(name) else {
            fail(Failure.invalid)
            return false
        }
        var next = saved
        var value = profile
        value.displayName = name
        if let index = next.firstIndex(where: { $0.id == profile.id }) { next[index] = value } else { next.append(value) }
        return save(next)
    }

    func unlink(_ profile: LocalCLIProfile) {
        guard !profile.isDefault, !signingIn.contains(profile.id) else { return }
        if save(saved.filter { $0.id != profile.id }) {
            tasks.removeValue(forKey: profile.id)?.cancel()
            requests.removeValue(forKey: profile.id)
            quotas.removeValue(forKey: profile.id)
            stale.remove(profile.id)
            refreshing.remove(profile.id)
            loginMessages.removeValue(forKey: profile.id)
            loginVerification.remove(profile.id)
            authentication.removeValue(forKey: profile.id)
            authenticationTasks.removeValue(forKey: profile.id)?.cancel()
        }
    }

    func refresh(_ profile: LocalCLIProfile) {
        authentication[profile.id] = LocalCLIAuthenticationReader().read(profile)
        guard !refreshing.contains(profile.id), profiles.contains(profile) else { return }
        let request = UUID()
        requests[profile.id] = request
        refreshing.insert(profile.id)
        tasks[profile.id] = Task { [weak self] in
            guard let self else { return }
            let loaded = await self.quotaLoader(profile)
            guard !Task.isCancelled, self.requests[profile.id] == request,
                self.profiles.contains(where: { $0.id == profile.id && $0.configDirectory == profile.configDirectory })
            else { return }
            self.refreshing.remove(profile.id)
            self.tasks.removeValue(forKey: profile.id)
            let previous = self.quotas[profile.id]
            let now = self.clock()
            let observation =
                profile.kind == .grok
                ? self.grokObservationReader.load(from: self.support, now: now)
                : nil
            let result = GrokResetStatusMerger.merge(
                previous: previous,
                incoming: loaded,
                profileKind: profile.kind,
                observation: observation,
                now: now)
            if self.loginVerification.remove(profile.id) != nil {
                self.loginMessages[profile.id] =
                    result.state == .available
                    ? self.language.text(
                        "对应额度接口已验证当前配置；模型执行状态仍以 CLI 为准。",
                        "The matching quota endpoint verified this configuration; model execution status still comes from the CLI.")
                    : self.language.text(
                        "已检查登录配置；额度暂未提供，可打开官方工具继续使用。",
                        "Sign-in configuration checked. Quota is unavailable; open the official tool to continue.")
            }
            if result.state != .available, result.state != .needsLogin, previous?.state == .available {
                self.stale.insert(profile.id)
            } else {
                self.quotas[profile.id] = result
                self.stale.remove(profile.id)
            }
        }
    }

    func sharesQuota(_ profile: LocalCLIProfile) -> Bool {
        guard let fingerprint = quotas[profile.id]?.identityFingerprint else { return false }
        return profiles.contains { $0.id != profile.id && $0.kind == profile.kind && quotas[$0.id]?.identityFingerprint == fingerprint }
    }

    private var storageURL: URL { support.appendingPathComponent("local-cli-accounts-v1.json") }
    private var language: WidgetLanguage { WidgetLanguage.storedOrAutomatic() }
    private enum Failure: Error, Equatable { case invalid, conflict }

    private func mergeImportedGrokObservation() {
        let now = clock()
        guard let observation = grokObservationReader.load(from: support, now: now) else { return }
        for profile in profiles where profile.kind == .grok {
            guard let current = quotas[profile.id] else { continue }
            quotas[profile.id] = GrokResetStatusMerger.merge(
                previous: current,
                incoming: current,
                profileKind: .grok,
                observation: observation,
                now: now)
        }
    }

    private func rebuildProfiles() {
        var result: [LocalCLIProfile] = []
        for kind in LocalCLIKind.allCases where installed[kind] != nil {
            if kind == .workBuddy {
                for edition in WorkBuddyEdition.allCases where workBuddyInstalled[edition] != nil {
                    let directory = home.appendingPathComponent(edition.directoryName).standardizedFileURL.path
                    result.append(
                        saved.first { $0.id == edition.defaultProfileID && $0.kind == kind && $0.isDefault && $0.configDirectory == directory }
                            ?? LocalCLIProfile(
                                id: edition.defaultProfileID, kind: kind,
                                displayName: edition == .domestic ? language.text("WorkBuddy 国内版", "WorkBuddy China") : language.text("WorkBuddy 国际版", "WorkBuddy International"),
                                configDirectory: directory, isDefault: true))
                }
                result += saved.filter { $0.kind == kind && !$0.isDefault }
                continue
            }
            let id = "local-" + kind.rawValue
            let directory = kind.defaultConfigDirectory(home: home).standardizedFileURL.path
            if let override = saved.first(where: { $0.id == id && $0.kind == kind && $0.isDefault && $0.configDirectory == directory }) {
                result.append(override)
            } else {
                result.append(
                    LocalCLIProfile(
                        id: id, kind: kind,
                        displayName: language.text("本机登录", "Local sign-in"), configDirectory: directory, isDefault: true))
            }
            result += saved.filter { $0.kind == kind && !$0.isDefault }
        }
        profiles = result
        let activeIDs = Set(result.map(\.id))
        for id in Array(tasks.keys) where !activeIDs.contains(id) {
            tasks.removeValue(forKey: id)?.cancel()
        }
        requests = requests.filter { activeIDs.contains($0.key) }
        quotas = quotas.filter { activeIDs.contains($0.key) }
        stale.formIntersection(activeIDs)
        refreshing.formIntersection(activeIDs)
        for id in Array(loginTasks.keys) where !activeIDs.contains(id) {
            loginTasks.removeValue(forKey: id)?.cancel()
        }
        for id in Array(authenticationTasks.keys) where !activeIDs.contains(id) {
            authenticationTasks.removeValue(forKey: id)?.cancel()
        }
        authentication = authentication.filter { activeIDs.contains($0.key) }
        signingIn.formIntersection(activeIDs)
        loginVerification.formIntersection(activeIDs)
        loginMessages = loginMessages.filter { activeIDs.contains($0.key) }
    }

    private func validName(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 64 && !value.contains("@")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func validDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return path.hasPrefix("/") && path.utf8.count <= 4096 && url.standardizedFileURL.path == path
            && url.resolvingSymlinksInPath().path == path
    }

    private func regularFile(_ url: URL, executable: Bool) -> Bool {
        var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/"),
            url.standardizedFileURL.path == url.path,
            url.resolvingSymlinksInPath().path == url.path,
            lstat(url.path, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == 0 || info.st_uid == geteuid()
        else { return false }
        return !executable || info.st_mode & 0o111 != 0
    }

    private func isOfficialZCode(_ app: URL) -> Bool {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard app.lastPathComponent == "ZCode.app", validDirectory(app.path),
            regularFile(app.appendingPathComponent("Contents/MacOS/ZCode"), executable: true),
            let data = try? DispatchParticipationSync.readBoundedRegularFile(plist, maximumBytes: 256 * 1024, allowMissing: false),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return info["CFBundleIdentifier"] as? String == "dev.zcode.app" && info["CFBundleExecutable"] as? String == "ZCode"
    }

    private func isOfficialTRAESOLO(_ app: URL) -> Bool {
        var info = stat()
        guard app.isFileURL, app.path.hasPrefix("/"),
            app.standardizedFileURL.path == app.path,
            app.resolvingSymlinksInPath().path == app.path,
            lstat(app.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            let identifier = Bundle(url: app)?.bundleIdentifier?.lowercased()
        else { return false }
        return identifier == "cn.trae.solo.app" || identifier == "com.trae.solo.app"
    }

    private func validProfile(_ profile: LocalCLIProfile) -> Bool {
        guard validName(profile.displayName), validDirectory(profile.configDirectory) else { return false }
        if profile.isDefault {
            if profile.kind == .workBuddy {
                return WorkBuddyEdition.allCases.contains {
                    profile.id == $0.defaultProfileID && profile.configDirectory == home.appendingPathComponent($0.directoryName).standardizedFileURL.path
                }
            }
            return profile.id == "local-" + profile.kind.rawValue
                && profile.configDirectory == profile.kind.defaultConfigDirectory(home: home).standardizedFileURL.path
        }
        if profile.kind == .workBuddy,
            WorkBuddyEdition.allCases.contains(where: { profile.configDirectory == home.appendingPathComponent($0.directoryName).standardizedFileURL.path })
        {
            return false
        }
        return UUID(uuidString: profile.id) != nil
            && profile.configDirectory != profile.kind.defaultConfigDirectory(home: home).standardizedFileURL.path
    }

    @discardableResult private func save(_ next: [LocalCLIProfile]) -> Bool {
        do {
            guard storageValid, next.count <= 64, Set(next.map(\.id)).count == next.count,
                next.allSatisfy(validProfile)
            else { throw Failure.invalid }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(support.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == geteuid(), info.st_mode & 0o077 == 0
            else { throw Failure.invalid }
            let fd = Darwin.open(support.appendingPathComponent(".local-cli-accounts.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.invalid }
            defer { Darwin.close(fd) }
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                info.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0
            else { throw Failure.conflict }
            defer { flock(fd, LOCK_UN) }
            let current = try DispatchParticipationSync.readBoundedRegularFile(storageURL, maximumBytes: 256 * 1024, allowMissing: true)
            guard current.map({ Data(SHA256.hash(data: $0)) }) == savedDigest else { throw Failure.conflict }
            let data = try JSONEncoder().encode(next)
            guard data.count <= 256 * 1024 else { throw Failure.invalid }
            try DispatchParticipationSync.writeSnapshot(data, at: storageURL, replacing: current)
            saved = next
            savedDigest = Data(SHA256.hash(data: data))
            rebuildProfiles()
            message = nil
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fail(_ error: Error) {
        message =
            (error as? Failure) == .conflict
            ? language.text("关联记录已在别处改变，请重新扫描后再保存。", "Account links changed elsewhere. Scan again before saving.")
            : language.text("未保存：请使用简短名称和有效的独立配置目录。", "Not saved. Use a short name and a valid isolated configuration directory.")
    }
}
