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
    @Published private(set) var claudeSubscriptionCandidates: [ClaudeSubscriptionCandidate] = []
    @Published private(set) var claudeSwitching: Set<String> = []
    @Published private(set) var claudeActiveProfileID: String?
    @Published var message: String?
    private var requests: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var loginTasks: [String: Task<Void, Never>] = [:]
    private var authenticationTasks: [String: Task<Void, Never>] = [:]
    private var loginVerification: Set<String> = []
    private var quotaAttemptedAt: [String: Date] = [:]
    private var quotaAttemptState: [String: LocalCLIQuotaState] = [:]
    private var quotaCredentialVersions: [String: CredentialVersion] = [:]
    private var queuedCredentialRefresh: Set<String> = []
    private var saved: [LocalCLIProfile] = []
    private var savedDigest: Data?
    private var storageValid = true
    private var previewOnly = false
    private var claudeCurrent: ClaudeSubscriptionService.VerifiedCurrent?
    private var claudeIdentityTask: Task<Void, Never>?
    private var claudeLoginAttemptID: UUID?
    private var claudeOpening: Set<String> = []
    @Published private(set) var claudeIdentityUnavailable = false
    private let home: URL
    private let support: URL
    private let applicationsDirectory: URL
    private let quotaLoader: QuotaLoader?
    private let claudeService: ClaudeSubscriptionService
    private let authenticationReader: LocalCLIAuthenticationReader
    private let terminalOpener: (LocalCLIProfile, String, URL) async throws -> Void
    private let grokObservationReader: GrokResetStatusObservationReader
    private let clock: @Sendable () -> Date

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        support: URL = DispatchParticipationPaths.supportDirectory(),
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        quotaLoader: QuotaLoader? = nil,
        grokObservationReader: GrokResetStatusObservationReader = GrokResetStatusObservationReader(),
        claudeSubscriptionService: ClaudeSubscriptionService? = nil,
        authenticationReader: LocalCLIAuthenticationReader? = nil,
        terminalOpener: @escaping (LocalCLIProfile, String, URL) async throws -> Void = { profile, executable, directory in
            _ = try await LocalCLITerminalLauncher.launch(profile: profile, executable: executable, action: .open, workingDirectory: directory)
        },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.support = support
        self.applicationsDirectory = applicationsDirectory
        self.quotaLoader = quotaLoader
        let service = claudeSubscriptionService ?? ClaudeSubscriptionService(home: home, support: support)
        self.claudeService = service
        self.authenticationReader = authenticationReader ?? LocalCLIAuthenticationReader(claudeSubscriptionService: service)
        self.terminalOpener = terminalOpener
        self.grokObservationReader = grokObservationReader
        self.clock = clock
    }

    static func preview(profiles: [LocalCLIProfile], quotas: [String: LocalCLIQuotaResult], root: URL, activeClaudeProfileID: String? = nil) -> LocalCLIAccountStore {
        let model = LocalCLIAccountStore(home: root, support: root, applicationsDirectory: root)
        model.previewOnly = true
        model.profiles = profiles
        model.quotas = quotas
        model.claudeActiveProfileID = activeClaudeProfileID
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
        claudeIdentityTask?.cancel()
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
            if kind == .antigravity {
                if let app = applicationRoots.map({ $0.appendingPathComponent("Antigravity.app", isDirectory: true) })
                    .first(where: isOfficialAntigravity)
                {
                    found[kind] = app.path
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
        discoverClaudeSubscriptions()
    }

    func discoverClaudeSubscriptions() {
        guard !previewOnly else { return }
        do { claudeSubscriptionCandidates = try claudeService.candidates() }
        catch { claudeSubscriptionCandidates = [] }
        reconcileClaudeIdentity()
    }

    /// Preview state is exposed for UI-only controls; it never enables an
    /// authentication or account mutation path.
    var isPreview: Bool { previewOnly }

    /// Claude-swap's supported flow starts in the official Claude Code login,
    /// then explicitly saves the resulting current subscription. Keep those
    /// actions separate so an existing credential cannot be mistaken for a
    /// newly completed login.
    var canBeginClaudeSubscriptionSignIn: Bool {
        guard !previewOnly, claudeSwitching.isEmpty, claudeOpening.isEmpty, signingIn.isEmpty,
            let profile = profiles.first(where: { $0.kind == .claudeCode && $0.isDefault })
        else { return false }
        return canSignIn(profile) && !signingIn.contains(profile.id)
    }

    var claudeSubscriptionSignInMessage: String? {
        guard let profile = profiles.first(where: { $0.kind == .claudeCode && $0.isDefault }) else {
            return language.text("尚未发现 Claude Code 官方 CLI。", "The official Claude Code CLI was not found.")
        }
        return loginMessages[profile.id]
    }

    func startClaudeSubscriptionSignIn() {
        guard let profile = profiles.first(where: { $0.kind == .claudeCode && $0.isDefault }) else {
            message = language.text("请先安装 Claude Code 官方 CLI。", "Install the official Claude Code CLI first.")
            return
        }
        guard canBeginClaudeSubscriptionSignIn else { return }
        signIn(profile)
    }

    private func reconcileClaudeIdentity() {
        guard !previewOnly else { return }
        guard !profiles.contains(where: { $0.kind == .claudeCode && signingIn.contains($0.id) }) else { return }
        if !claudeIdentityUnavailable, let current = claudeCurrent,
            (try? claudeService.isCurrent(current)) == true {
            claudeActiveProfileID = profiles.first { $0.claudeSubscription?.identityFingerprint == current.fingerprint }?.id
            return
        }
        claudeCurrent = nil
        claudeActiveProfileID = nil
        guard profiles.contains(where: { $0.claudeSubscription != nil }) else { return }
        guard claudeIdentityTask == nil else { return }
        claudeIdentityTask = Task { [weak self] in
            guard let self else { return }
            defer { self.claudeIdentityTask = nil }
            do {
                let current = try await self.claudeService.verifyCurrent()
                guard !Task.isCancelled, (try? self.claudeService.isCurrent(current)) == true else { return }
                self.claudeCurrent = current
                self.claudeIdentityUnavailable = false
                self.claudeActiveProfileID = self.profiles.first {
                    $0.claudeSubscription?.identityFingerprint == current.fingerprint
                }?.id
            } catch {
                guard !Task.isCancelled else { return }
                self.claudeCurrent = nil
                self.claudeActiveProfileID = nil
            }
        }
    }

    private func clearClaudeQuota() {
        for profile in profiles where profile.kind == .claudeCode {
            tasks.removeValue(forKey: profile.id)?.cancel()
            requests.removeValue(forKey: profile.id)
            quotas.removeValue(forKey: profile.id)
            stale.remove(profile.id)
            refreshing.remove(profile.id)
            quotaCredentialVersions.removeValue(forKey: profile.id)
            quotaAttemptedAt.removeValue(forKey: profile.id)
            quotaAttemptState.removeValue(forKey: profile.id)
        }
    }

    private func quarantineClaudeIdentity() {
        claudeIdentityTask?.cancel()
        claudeIdentityUnavailable = true
        claudeCurrent = nil
        claudeActiveProfileID = nil
        clearClaudeQuota()
    }

    private func loadQuota(_ profile: LocalCLIProfile) async -> LocalCLIQuotaResult {
        if let quotaLoader { return await quotaLoader(profile) }
        switch profile.kind {
        case .gemini, .mimo, .trae, .workBuddy: return await AdditionalCLIQuotaReader().load(profile: profile)
        case .zcode: return await ZCodeCLIQuotaReader().load(profile: profile)
        case .antigravity: return await AntigravityCLIQuotaReader().load(profile: profile)
        case .claudeCode, .grok, .openCode, .kimi:
            return await LocalCLIQuotaReader(claudeSubscriptionService: claudeService).load(profile: profile)
        }
    }

    @discardableResult
    func importClaudeSubscription(candidateID: String, name: String) -> LocalCLIProfile? {
        guard !previewOnly, storageValid, validName(name), saved.count < 64 else { return nil }
        do {
            let reference = try claudeService.reference(candidateID: candidateID)
            guard !saved.contains(where: { $0.claudeSubscription?.identityFingerprint == reference.identityFingerprint }) else {
                message = language.text("这个订阅账号已保存。", "This subscription is already saved."); return nil
            }
            return saveClaudeReference(reference, name: name)
        } catch { claudeFailure(error); return nil }
    }

    @discardableResult
    func captureClaudeSubscription(name: String) async -> LocalCLIProfile? {
        guard !previewOnly, storageValid, validName(name), saved.count < 64, claudeSwitching.isEmpty,
            signingIn.isEmpty, !claudeIdentityUnavailable, claudeOpening.isEmpty else { return nil }
        let slot = UUID().uuidString.lowercased()
        claudeSwitching.insert(slot)
        defer { claudeSwitching.remove(slot) }
        do {
            let reference = try await claudeService.capture(slot: slot)
            guard !saved.contains(where: { $0.claudeSubscription?.identityFingerprint == reference.identityFingerprint }) else {
                try claudeService.removeCaptured(reference)
                if let existing = saved.first(where: { $0.claudeSubscription?.identityFingerprint == reference.identityFingerprint }), let existingReference = existing.claudeSubscription, existingReference.source == .native {
                    _ = try await claudeService.capture(slot: existingReference.slot, replacing: existingReference)
                    quotas.removeValue(forKey: existing.id); stale.remove(existing.id)
                    discoverClaudeSubscriptions()
                    message = language.text("已更新这个订阅账号的官方登录凭据。", "Official sign-in credentials updated for this subscription.")
                    return existing
                }
                message = language.text("这个订阅账号已关联 claude-swap；请使用其原槽管理登录。", "This subscription is linked to claude-swap; manage sign-in in its existing slot."); return nil
            }
            guard let profile = saveClaudeReference(reference, name: name) else { try claudeService.removeCaptured(reference); return nil }
            discoverClaudeSubscriptions()
            return profile
        } catch { claudeFailure(error); return nil }
    }

    private func saveClaudeReference(_ reference: ClaudeSubscriptionReference, name: String) -> LocalCLIProfile? {
        let id = UUID().uuidString.lowercased()
        let path = support.appendingPathComponent("claude-subscriptions/" + id).path
        // This is a storage-only descriptor, never a second runnable token copy.
        let profile = LocalCLIProfile(id: id, kind: .claudeCode, displayName: name, configDirectory: path, isDefault: false, claudeSubscription: reference)
        guard save(saved + [profile]) else { return nil }
        return profile
    }

    func canSwitchClaudeSubscription(_ profile: LocalCLIProfile) -> Bool {
        !previewOnly && storageValid && profiles.contains(profile) && claudeSwitching.isEmpty
            && signingIn.isEmpty
            && claudeOpening.isEmpty && !claudeIdentityUnavailable
            && profile.claudeSubscription != nil && installed[.claudeCode] != nil
            && claudeCurrent != nil
            && profiles.contains { $0.claudeSubscription != nil && $0.id == claudeActiveProfileID }
    }

    @discardableResult
    func switchClaudeSubscription(_ profile: LocalCLIProfile) async -> Bool {
        guard canSwitchClaudeSubscription(profile), let reference = profile.claudeSubscription else { return false }
        claudeSwitching.insert(profile.id)
        defer { claudeSwitching.remove(profile.id) }
        do {
            try await claudeService.switchTo(reference, allReferences: profiles.compactMap(\.claudeSubscription))
            clearClaudeQuota()
            claudeCurrent = nil
            discoverClaudeSubscriptions()
            message = language.text("Claude 订阅账号已切换。重新打开 Claude Code 后使用该账号。", "Claude subscription switched. Reopen Claude Code to use this account.")
            return true
        } catch { claudeFailure(error); return false }
    }

    private func claudeFailure(_ error: Error) {
        if (error as? ClaudeSubscriptionService.Failure) == .rollbackFailed { quarantineClaudeIdentity() }
        else if (error as? ClaudeSubscriptionService.Failure) == .identityChanged
            || (error as? ClaudeSubscriptionService.Failure) == .readOnly {
            claudeCurrent = nil
            claudeActiveProfileID = nil
        }
        let reason = (error as? ClaudeSubscriptionService.Failure)?.rawValue ?? "unavailable"
        message = language.text("Claude 账号操作未完成（" + reason + "）。重试前请先检查账号状态。", "Claude account operation did not complete (" + reason + "). Check the account before retrying.")
    }

    func profiles(for kind: LocalCLIKind) -> [LocalCLIProfile] { profiles.filter { $0.kind == kind } }

    /// Only expose creation where the official launcher isolates credentials,
    /// configuration and runtime state without replacing the user's HOME.
    func canCreateAccount(kind: LocalCLIKind) -> Bool {
        guard !previewOnly, storageValid, saved.count < 64 else { return false }
        switch kind {
        case .grok, .openCode, .kimi:
            return installed[kind] != nil
        case .workBuddy:
            return !workBuddyInstalled.isEmpty
        default:
            return false
        }
    }

    func createGrokAccount(name: String) -> LocalCLIProfile? {
        createAccount(kind: .grok, name: name)
    }

    func createAccount(
        kind: LocalCLIKind,
        name: String,
        workBuddyEdition: WorkBuddyEdition? = nil
    ) -> LocalCLIProfile? {
        guard canCreateAccount(kind: kind), validName(name) else {
            fail(Failure.invalid)
            return nil
        }
        guard
            !profiles.contains(where: {
                $0.kind == kind && $0.displayName.caseInsensitiveCompare(name) == .orderedSame
            })
        else {
            message = language.text("该平台已有同名账号，请换一个名称。", "This provider already has an account with that name. Choose another name.")
            return nil
        }
        let edition: WorkBuddyEdition?
        if kind == .workBuddy {
            edition = workBuddyEdition ?? WorkBuddyEdition.allCases.first { workBuddyInstalled[$0] != nil }
            guard let edition, workBuddyInstalled[edition] != nil else {
                fail(Failure.invalid)
                return nil
            }
        } else {
            guard workBuddyEdition == nil else {
                fail(Failure.invalid)
                return nil
            }
            edition = nil
        }
        let id = UUID().uuidString.lowercased()
        let managedRoot = home.appendingPathComponent(".codex-account-manager-next", isDirectory: true)
        let root = managedRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
        let accountRoot = root.appendingPathComponent(id.replacingOccurrences(of: "-", with: ""), isDirectory: true)
        let directory: URL
        switch kind {
        case .openCode:
            // Must match the launcher's XDG suffix contract. All four XDG roots
            // are then derived inside this account's unique root.
            directory = accountRoot.appendingPathComponent(".local/share/opencode", isDirectory: true)
        case .workBuddy:
            guard let edition else { return nil }
            directory = accountRoot.appendingPathComponent(edition.directoryName, isDirectory: true)
        default:
            directory = accountRoot
        }
        var createdAccountRoot = false
        do {
            guard validDirectory(directory.path),
                kind != .grok || directory.appendingPathComponent("leader.sock").path.utf8.count < 104
            else {
                throw Failure.invalid
            }
            try prepareManagedAccountDirectory(managedRoot)
            try prepareManagedAccountDirectory(root)
            // A preexisting or replaced slot is never adopted or deleted.
            guard mkdir(accountRoot.path, 0o700) == 0 else { throw Failure.invalid }
            createdAccountRoot = true
            if kind == .openCode {
                for relative in [".local", ".local/share", ".local/share/opencode", ".config", ".local/state", ".cache"] {
                    try prepareManagedAccountDirectory(accountRoot.appendingPathComponent(relative, isDirectory: true))
                }
            } else if directory != accountRoot {
                try prepareManagedAccountDirectory(directory)
            }
            let profile = LocalCLIProfile(id: id, kind: kind, displayName: name, configDirectory: directory.path, isDefault: false)
            guard save(saved + [profile]) else {
                try? FileManager.default.removeItem(at: accountRoot)
                return nil
            }
            return profile
        } catch {
            if createdAccountRoot { try? FileManager.default.removeItem(at: accountRoot) }
            fail(error)
            return nil
        }
    }

    private func prepareManagedAccountDirectory(_ directory: URL) throws {
        guard validDirectory(directory.path) else { throw Failure.invalid }
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw Failure.invalid }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw Failure.invalid }
    }

    func signIn(_ profile: LocalCLIProfile, updateProvider: Bool = false) {
        guard canSignIn(profile), signingIn.isEmpty,
            let executable = executable(for: profile)
        else { return }
        if profile.kind == .claudeCode {
            do {
                guard try claudeService.dependencies.idle() else { throw ClaudeSubscriptionService.Failure.busy }
            } catch {
                loginMessages[profile.id] = language.text(
                    "请先结束正在运行的 Claude 会话，再登录另一个订阅。",
                    "Finish running Claude sessions before signing in to another subscription.")
                return
            }
            claudeIdentityTask?.cancel()
            claudeCurrent = nil
            claudeActiveProfileID = nil
            clearClaudeQuota()
            loginVerification.remove(profile.id)
        }
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
        let claudeAttemptID = profile.kind == .claudeCode ? UUID() : nil
        if profile.kind == .claudeCode { claudeLoginAttemptID = claudeAttemptID }
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
            case .zcode, .antigravity:
                language.text(
                    "请在 \(profile.kind.displayName) 桌面应用中完成登录。",
                    "Complete sign-in in the \(profile.kind.displayName) desktop app.")
            case .gemini:
                language.text(
                    "在 Gemini CLI 中使用 Google 登录或 API Key；已有配置会复用。需要更换方式时输入 /auth。完成后自动检测，不必退出终端；额度单独读取。",
                    "Use Google sign-in or an API key in Gemini CLI. Existing configuration is reused; enter /auth to change it. Detection does not require closing Terminal; quota is read separately."
                )
            case .claudeCode:
                language.text(
                    "请在 Claude Code 官方页面完成浏览器授权；完成后核验订阅身份，再由你保存当前订阅。",
                    "Complete browser authorization on the official Claude Code page. The subscription identity is then checked; save the current subscription explicitly.")
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
                    claudeAttemptID == nil || self.claudeLoginAttemptID == claudeAttemptID
                else { return }
                guard let current = self.profiles.first(where: { $0.id == profile.id && $0.configDirectory == profile.configDirectory })
                else { throw ClaudeSubscriptionService.Failure.identityChanged }
                if profile.kind == .claudeCode, code == 0 {
                    self.loginMessages[profile.id] = self.language.text("官方登录流程已结束，正在核验订阅身份。", "Official sign-in ended. Checking the subscription identity.")
                    let verified = try await self.claudeService.verifyCurrent()
                    try Task.checkCancellation()
                    guard claudeAttemptID == self.claudeLoginAttemptID else { return }
                    guard self.profiles.contains(where: {
                            $0.id == current.id && $0.kind == current.kind
                                && $0.configDirectory == current.configDirectory
                                && $0.claudeSubscription == current.claudeSubscription
                        }), self.signingIn.contains(profile.id)
                    else { throw ClaudeSubscriptionService.Failure.identityChanged }
                    guard try self.claudeService.isCurrent(verified) else { throw ClaudeSubscriptionService.Failure.identityChanged }
                    self.claudeCurrent = verified
                    self.claudeIdentityUnavailable = false
                    self.claudeActiveProfileID = self.profiles.first {
                        $0.claudeSubscription?.identityFingerprint == verified.fingerprint
                    }?.id
                    self.signingIn.remove(profile.id)
                    self.loginTasks.removeValue(forKey: profile.id)
                    self.authentication[profile.id] = self.authenticationReader.read(current)
                    self.loginMessages[profile.id] = self.language.text(
                        "订阅身份已核验。确认当前账号后，点击“保存当前订阅”；已有账号不会重复添加。",
                        "Subscription identity verified. Confirm the current account and choose Save subscription; an existing account will not be duplicated.")
                    self.refresh(current)
                    self.claudeLoginAttemptID = nil
                    return
                }
                self.signingIn.remove(profile.id)
                self.loginTasks.removeValue(forKey: profile.id)
                self.authenticationTasks.removeValue(forKey: profile.id)?.cancel()
                if profile.kind == .claudeCode { self.claudeLoginAttemptID = nil }
                if code == 0 {
                    self.loginVerification.insert(profile.id)
                    self.loginMessages[profile.id] = self.language.text("官方登录流程已结束，正在核验账号。", "The official sign-in flow ended. Verifying the account.")
                    self.refresh(current)
                } else {
                    self.loginMessages[profile.id] = self.language.text("登录未完成，请查看终端提示后重试。", "Sign-in did not finish. Check the terminal and try again.")
                }
            } catch {
                guard let self, !Task.isCancelled,
                    claudeAttemptID == nil || self.claudeLoginAttemptID == claudeAttemptID
                else { return }
                self.signingIn.remove(profile.id)
                self.loginTasks.removeValue(forKey: profile.id)
                self.authenticationTasks.removeValue(forKey: profile.id)?.cancel()
                if profile.kind == .claudeCode { self.claudeLoginAttemptID = nil }
                self.loginMessages[profile.id] = self.language.text(
                    profile.kind == .claudeCode ? "登录流程结束，但当前订阅身份尚未核验，请重新检查。" : "暂未确认登录结果。若浏览器已授权，点击刷新核验；终端窗口已保留。",
                    profile.kind == .claudeCode ? "The sign-in flow ended, but the current subscription identity was not verified. Check again." : "Sign-in has not been confirmed. If browser authorization finished, refresh to verify. The terminal was left open.")
            }
        }
        // `claude auth login` finishes with its own exit receipt. Watching old
        // credentials would falsely finish a new authorization attempt.
        guard profile.kind != .claudeCode else { return }
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
        if let reference = profile.claudeSubscription {
            guard let localDefault = profiles.first(where: { $0.kind == .claudeCode && $0.isDefault }),
                let current = claudeCurrent, !claudeIdentityUnavailable, claudeOpening.isEmpty
            else {
                message = language.text("当前 Claude 登录已改变，请刷新并确认后再打开。", "Claude sign-in changed. Refresh and confirm before opening.")
                return
            }
            claudeOpening.insert(profile.id)
            Task { [weak self] in
                guard let self else { return }
                defer { self.claudeOpening.remove(profile.id) }
                do {
                    guard !Task.isCancelled, self.profiles.contains(profile), self.profiles.contains(localDefault),
                        !self.claudeIdentityUnavailable, !self.signingIn.contains(localDefault.id), current.fingerprint == reference.identityFingerprint,
                        try self.claudeService.isCurrent(current) else { throw ClaudeSubscriptionService.Failure.identityChanged }
                    try self.rejectClaudeProjectAPIRoute(workingDirectory)
                    try await self.terminalOpener(localDefault, executable, workingDirectory)
                } catch { self.claudeFailure(error) }
            }
            return
        }
        if profile.kind.isDesktopApplication {
            let app = URL(fileURLWithPath: executable, isDirectory: true)
            let verified =
                switch profile.kind {
                case .zcode: isOfficialZCode(app)
                case .antigravity: isOfficialAntigravity(app)
                default: isOfficialTRAESOLO(app)
                }
            guard verified else { return }
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
        if profile.kind == .claudeCode { claudeOpening.insert(profile.id) }
        Task { [weak self] in
            do {
                guard let self else { return }
                defer { if profile.kind == .claudeCode { self.claudeOpening.remove(profile.id) } }
                guard !Task.isCancelled, !self.signingIn.contains(profile.id), self.profiles.contains(profile) else { return }
                try await self.terminalOpener(profile, executable, workingDirectory)
            } catch {
                self?.message = self?.language.text("未能打开 CLI，请检查终端与工作目录。", "The CLI could not open. Check Terminal and the working directory.")
            }
        }
    }

    private func rejectClaudeProjectAPIRoute(_ directory: URL) throws {
        let keys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_MANTLE"]
        var current = directory.standardizedFileURL
        while true {
            for name in ["settings.json", "settings.local.json"] {
                let file = current.appendingPathComponent(".claude/" + name)
                if let data = try DispatchParticipationSync.readBoundedRegularFile(file, maximumBytes: 1_048_576, allowMissing: true) {
                    let env = try ClaudeSubscriptionService.object(data)["env"] as? [String: Any] ?? [:]
                    guard !keys.contains(where: { ClaudeSubscriptionService.text(env[$0]) != nil }) else { throw ClaudeSubscriptionService.Failure.readOnly }
                }
            }
            if current == home.standardizedFileURL { break }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
    }

    /// The user has finished authorization inside an interactive TUI. Stop only
    /// waiting for its exit; leave the user's terminal and its receipt intact.
    func checkInteractiveSignIn(_ profile: LocalCLIProfile) {
        guard profiles.contains(profile) else { return }
        if profile.kind == .claudeCode {
            guard !signingIn.contains(profile.id) else { return }
            authentication[profile.id] = authenticationReader.read(profile)
            refresh(profile)
            return
        }
        loginTasks.removeValue(forKey: profile.id)?.cancel()
        authenticationTasks.removeValue(forKey: profile.id)?.cancel()
        signingIn.remove(profile.id)
        authentication[profile.id] = authenticationReader.read(profile)
        loginVerification.insert(profile.id)
        refresh(profile)
    }

    func checkLocalSignIns() {
        for profile in profiles { checkLocalSignIn(profile) }
    }

    /// Recheck the visible provider after an external CLI may have changed its
    /// credentials. File metadata is only a change signal; quota and identity
    /// still come from the profile's own official reader.
    func refreshIfNeeded(kind: LocalCLIKind? = nil, profileIDs: Set<String>? = nil, maximumAge: TimeInterval = 5 * 60) {
        guard !previewOnly else { return }
        if kind == nil || kind == .claudeCode { reconcileClaudeIdentity() }
        let now = clock()
        let ageLimit = maximumAge.isFinite ? max(0, maximumAge) : 5 * 60
        for profile in profiles
        where (kind == nil || profile.kind == kind)
            && (profileIDs == nil || profileIDs!.contains(profile.id))
        {
            if profile.kind == .claudeCode, signingIn.contains("local-claudeCode") { continue }
            let previousAuthentication = authentication[profile.id]
            checkLocalSignIn(profile)
            let version = credentialVersion(for: profile)
            let credentialsChanged = quotaCredentialVersions[profile.id].map { $0 != version } ?? false
            let authenticationChanged =
                previousAuthentication != nil
                && previousAuthentication != authentication[profile.id]
            if credentialsChanged || authenticationChanged {
                quotas.removeValue(forKey: profile.id)
                stale.remove(profile.id)
            }
            if refreshing.contains(profile.id) {
                if credentialsChanged || authenticationChanged { queuedCredentialRefresh.insert(profile.id) }
                continue
            }
            if let attemptedAt = quotaAttemptedAt[profile.id] {
                let elapsed = max(0, now.timeIntervalSince(attemptedAt))
                if quotaAttemptState[profile.id] == .rateLimited, elapsed < 15 * 60 { continue }
                // Successful reads use the original snapshot age below. A
                // slow success must not add another 60 seconds after completion.
                // Failed reads and rate limits retain their existing backoff.
                if quotaAttemptState[profile.id] != .available,
                    !credentialsChanged && !authenticationChanged, elapsed < 60
                {
                    continue
                }
            }
            if !credentialsChanged && !authenticationChanged,
                let quota = quotas[profile.id], quota.state == .available,
                !stale.contains(profile.id),
                (0..<ageLimit).contains(now.timeIntervalSince(quota.fetchedAt))
            {
                continue
            }
            refresh(profile)
        }
    }

    private func checkLocalSignIn(_ profile: LocalCLIProfile) {
        let evidence = authenticationReader.read(profile)
        authentication[profile.id] = evidence
        // Claude's `auth login` has an explicit terminal exit and must not be
        // completed merely because its old credential file is still present.
        // Other interactive CLIs retain their existing configuration watcher.
        if profile.kind != .claudeCode, evidence.isConfigured, signingIn.contains(profile.id) {
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
        if profile.kind == .claudeCode {
            guard !previewOnly, storageValid, claudeSwitching.isEmpty, claudeOpening.isEmpty else { return false }
        }
        return profile.kind.supportsTerminalSignIn && profiles.contains(profile)
            && executable(for: profile) != nil
            && (!profile.kind.requiresDefaultEnvironmentForLaunch || profile.isDefault)
    }

    func canOpen(_ profile: LocalCLIProfile) -> Bool {
        !previewOnly && profile.kind.supportsNativeOpen && profiles.contains(profile)
            && (profile.kind != .claudeCode || (!claudeIdentityUnavailable && claudeOpening.isEmpty && claudeSwitching.isEmpty))
            && (profile.kind != .claudeCode || !profiles.contains { $0.kind == .claudeCode && signingIn.contains($0.id) })
            && executable(for: profile) != nil
            && (!profile.kind.requiresDefaultEnvironmentForLaunch || profile.isDefault
                || (profile.kind == .claudeCode && profile.claudeSubscription != nil && profile.id == claudeActiveProfileID
                    && claudeCurrent != nil))
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
        if kind == .antigravity, !AntigravityCLIQuotaReader.hasLinkedCache(at: directory) {
            message = language.text(
                "请选择包含 User/globalStorage/state.vscdb 的 Antigravity 独立配置目录。关联只读取该档案，不切换桌面当前账号。",
                "Choose an Antigravity profile containing User/globalStorage/state.vscdb. Linking reads that profile only; it never changes the desktop account.")
            return
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
            quotaAttemptedAt.removeValue(forKey: profile.id)
            quotaAttemptState.removeValue(forKey: profile.id)
            quotaCredentialVersions.removeValue(forKey: profile.id)
            queuedCredentialRefresh.remove(profile.id)
        }
    }

    func refresh(_ profile: LocalCLIProfile) {
        guard !previewOnly else { return }
        guard profiles.contains(profile) else { return }
        guard profile.kind != .claudeCode || !signingIn.contains("local-claudeCode") else { return }
        if profile.kind == .claudeCode { reconcileClaudeIdentity() }
        let previousAuthentication = authentication[profile.id]
        let currentAuthentication = authenticationReader.read(profile)
        authentication[profile.id] = currentAuthentication
        let requestCredentialVersion = credentialVersion(for: profile)
        let credentialsChanged = quotaCredentialVersions[profile.id].map { $0 != requestCredentialVersion } ?? false
        let authenticationChanged = previousAuthentication != nil && previousAuthentication != currentAuthentication
        if credentialsChanged || authenticationChanged {
            quotas.removeValue(forKey: profile.id)
            stale.remove(profile.id)
        }
        if refreshing.contains(profile.id) {
            if credentialsChanged || authenticationChanged { queuedCredentialRefresh.insert(profile.id) }
            return
        }
        quotaAttemptedAt[profile.id] = clock()
        quotaCredentialVersions[profile.id] = requestCredentialVersion
        let request = UUID()
        requests[profile.id] = request
        refreshing.insert(profile.id)
        tasks[profile.id] = Task { [weak self] in
            guard let self else { return }
            let loaded = await self.loadQuota(profile)
            guard !Task.isCancelled, self.requests[profile.id] == request,
                let currentProfile = self.profiles.first(where: {
                    $0.id == profile.id && $0.kind == profile.kind && $0.configDirectory == profile.configDirectory
                        && $0.claudeSubscription == profile.claudeSubscription
                })
            else { return }
            self.refreshing.remove(profile.id)
            if profile.kind == .claudeCode { self.reconcileClaudeIdentity() }
            self.tasks.removeValue(forKey: profile.id)
            let queuedRefresh = self.queuedCredentialRefresh.remove(profile.id) != nil
            if self.credentialVersion(for: profile) != requestCredentialVersion || queuedRefresh {
                self.requests.removeValue(forKey: profile.id)
                self.quotas.removeValue(forKey: profile.id)
                self.stale.remove(profile.id)
                self.quotaCredentialVersions.removeValue(forKey: profile.id)
                let now = self.clock()
                let previousRateLimitStillActive =
                    self.quotaAttemptState[profile.id] == .rateLimited
                    && self.quotaAttemptedAt[profile.id].map { max(0, now.timeIntervalSince($0)) < 15 * 60 } == true
                if loaded.state == .rateLimited {
                    self.quotaAttemptedAt[profile.id] = now
                    self.quotaAttemptState[profile.id] = .rateLimited
                } else if !previousRateLimitStillActive {
                    self.quotaAttemptedAt.removeValue(forKey: profile.id)
                    self.quotaAttemptState.removeValue(forKey: profile.id)
                }
                if queuedRefresh || loaded.state == .available, loaded.state != .rateLimited, !previousRateLimitStillActive {
                    self.refresh(currentProfile)
                }
                return
            }
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
            self.quotaAttemptedAt[profile.id] = now
            self.quotaAttemptState[profile.id] = loaded.state
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
            let credentialSourceChanged =
                profile.kind == .claudeCode
                && loaded.messageCode == "local_cli_claude_credentials_changed"
            if credentialSourceChanged {
                // Keychain rotations have no file metadata generation. Never
                // retain the old account's quota or derived identity on this signal.
                self.quotaCredentialVersions.removeValue(forKey: profile.id)
            }
            if !credentialSourceChanged, result.state != .available, result.state != .needsLogin, previous?.state == .available {
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

    private struct CredentialVersion: Equatable {
        struct File: Equatable {
            let device: dev_t
            let inode: ino_t
            let size: off_t
            let modified: timespec
            let changed: timespec

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                    && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                    && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
            }
        }

        let directory: String
        let files: [File?]
    }

    private func credentialVersion(for profile: LocalCLIProfile) -> CredentialVersion {
        let names: [String] =
            switch profile.kind {
            case .kimi: ["credentials/kimi-code.json", "device_id"]
            case .grok, .openCode, .mimo: ["auth.json"]
            case .claudeCode: [".credentials.json", "settings.json"]
            case .gemini: ["settings.json", "oauth_creds.json", ".env"]
            case .zcode: ["v2/setting.json", "v2/config.json", "v2/credentials.json"]
            case .trae, .workBuddy, .antigravity: []
            }
        let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
        var urls = names.map { directory.appendingPathComponent($0) }
        if profile.kind == .claudeCode, profile.isDefault,
            directory.standardizedFileURL == LocalCLIKind.claudeCode.defaultConfigDirectory(home: home).standardizedFileURL
        {
            let relay = home.appendingPathComponent(".cc-switch", isDirectory: true)
            urls += ["cc-switch.db", "cc-switch.db-wal"].map { relay.appendingPathComponent($0) }
        }
        let files = urls.map { url -> CredentialVersion.File? in
            var info = stat()
            let path = url.path
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_uid == geteuid(), info.st_nlink == 1
            else { return nil }
            return CredentialVersion.File(
                device: info.st_dev, inode: info.st_ino, size: info.st_size,
                modified: info.st_mtimespec, changed: info.st_ctimespec)
        }
        return CredentialVersion(directory: profile.configDirectory, files: files)
    }

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
        let previousScopes = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var result: [LocalCLIProfile] = []
        for kind in LocalCLIKind.allCases where installed[kind] != nil || (kind == .claudeCode && (hasClaudeAPIConfiguration() || saved.contains { $0.kind == .claudeCode })) {
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
        let retainedIDs = Set(
            result.filter {
                previousScopes[$0.id]?.kind == $0.kind && previousScopes[$0.id]?.configDirectory == $0.configDirectory && previousScopes[$0.id]?.claudeSubscription == $0.claudeSubscription
            }.map(\.id))
        for id in Array(tasks.keys) where !retainedIDs.contains(id) {
            tasks.removeValue(forKey: id)?.cancel()
        }
        requests = requests.filter { retainedIDs.contains($0.key) }
        quotas = quotas.filter { retainedIDs.contains($0.key) }
        stale.formIntersection(retainedIDs)
        refreshing.formIntersection(retainedIDs)
        for id in Array(loginTasks.keys) where !retainedIDs.contains(id) {
            loginTasks.removeValue(forKey: id)?.cancel()
        }
        for id in Array(authenticationTasks.keys) where !retainedIDs.contains(id) {
            authenticationTasks.removeValue(forKey: id)?.cancel()
        }
        authentication = authentication.filter { retainedIDs.contains($0.key) }
        signingIn.formIntersection(retainedIDs)
        loginVerification.formIntersection(retainedIDs)
        loginMessages = loginMessages.filter { retainedIDs.contains($0.key) }
        quotaAttemptedAt = quotaAttemptedAt.filter { retainedIDs.contains($0.key) }
        quotaAttemptState = quotaAttemptState.filter { retainedIDs.contains($0.key) }
        quotaCredentialVersions = quotaCredentialVersions.filter { retainedIDs.contains($0.key) }
        queuedCredentialRefresh.formIntersection(retainedIDs)
    }

    /// A configured API account can report a balance before its CLI is installed.
    /// This discovers a profile only; launch readiness still requires an executable.
    private func hasClaudeAPIConfiguration() -> Bool {
        let file = LocalCLIKind.claudeCode.defaultConfigDirectory(home: home).appendingPathComponent("settings.json")
        guard let data = try? DispatchParticipationSync.readBoundedRegularFile(file, maximumBytes: 256 * 1024, allowMissing: false),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let environment = settings["env"] as? [String: Any]
        else { return false }
        return ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].contains { key in
            guard let value = environment[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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

    private func isOfficialAntigravity(_ app: URL) -> Bool {
        guard app.lastPathComponent == "Antigravity.app", validDirectory(app.path),
            regularFile(app.appendingPathComponent("Contents/MacOS/Antigravity"), executable: true),
            let data = try? DispatchParticipationSync.readBoundedRegularFile(
                app.appendingPathComponent("Contents/Info.plist"), maximumBytes: 256 * 1024, allowMissing: false),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return info["CFBundleIdentifier"] as? String == "com.google.antigravity"
            && info["CFBundleExecutable"] as? String == "Antigravity"
    }

    private func validProfile(_ profile: LocalCLIProfile) -> Bool {
        guard validName(profile.displayName), validDirectory(profile.configDirectory) else { return false }
        if let reference = profile.claudeSubscription {
            guard profile.kind == .claudeCode, !profile.isDefault, UUID(uuidString: profile.id) != nil,
                profile.configDirectory == support.appendingPathComponent("claude-subscriptions/" + profile.id).path,
                reference.identityFingerprint.count == 64,
                reference.identityFingerprint.allSatisfy({ $0.isHexDigit }) else { return false }
            return reference.source == .native ? UUID(uuidString: reference.slot) != nil : Int(reference.slot).map { (1...10000).contains($0) && String($0) == reference.slot } == true
        }
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
