import Cocoa
import Combine

enum VisualEnergyMode: Equatable {
    // This describes visibility and system energy pressure. Components that
    // animate must still gate on their own focus and interaction state.
    case suspended
    case constrained
    case normal
}

final class UsageStore: ObservableObject {
    @Published private(set) var engineState = TokenMonitorEngineState()
    @Published private(set) var statisticsEngineChoice = StatisticsEngineChoice.stored()
    private var engineGeneration = TokenMonitorGeneration()
    private var engineCancellation: TokenMonitorCancellation?
    private var engineLocalSources: [TokenMonitorSource] = []
    private var statisticsIncludesManagedCodex = true
    @Published private(set) var engineLimitsByProfileID: [String: TokenMonitorResponse] = [:]
    private var engineQuotaCancellation: TokenMonitorCancellation?
    private var engineLimitsSelector: ((TokenMonitorResponse, String) -> TokenMonitorJSON?)?

    /// Optional additional selector restriction; it cannot override confirmed target binding.
    func configureStatisticsLimitsSelector(_ selector: @escaping (TokenMonitorResponse, String) -> TokenMonitorJSON?) {
        engineLimitsSelector = selector
        cancelStatisticsEngine()
    }

    /// Root supplies the existing local account store's metadata, never credentials.
    /// History remains unattributed: a current CLI login does not prove historical account ownership.
    func configureStatisticsLocalProfiles(_ localProfiles: [LocalCLIProfile]) {
        engineLocalSources = localProfiles.compactMap { profile in
            let provider: String
            let logs: String
            switch profile.kind {
            case .grok:
                provider = "grok"
                logs = "sessions"
            case .claudeCode:
                provider = "claude"
                logs = "projects"
            default: return nil  // Other exact provider log-root mappings require WorkBuddy confirmation.
            }
            return TokenMonitorSource(
                id: "local-" + profile.id, providerId: provider, kind: .agentLogs,
                canonicalPath: URL(fileURLWithPath: profile.configDirectory).appendingPathComponent(logs).path,
                pathRole: .logRoot, toolId: provider)
        }
        cancelStatisticsEngine()
        if hasStarted { refresh(queueIfBusy: true) }
    }

    /// Caller supplies approved upstream collector roots and exact path roles, never inferred homes.
    func configureStatisticsSources(_ sources: [TokenMonitorSource], includeManagedCodex: Bool = true) throws {
        guard sources.allSatisfy({ $0.authority == .upstream }) else { throw TokenMonitorFailure.invalidSource }
        engineLocalSources = try TokenMonitorSource.validated(sources)
        statisticsIncludesManagedCodex = includeManagedCodex
        cancelStatisticsEngine()
        if hasStarted { refresh(queueIfBusy: true) }
    }

    func selectStatisticsEngine(_ choice: StatisticsEngineChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: StatisticsEngineChoice.storageKey)
        statisticsEngineChoice = choice
        cancelStatisticsEngine()
        // Previous-mode values must not be aggregated with the newly selected authority.
        engineState = TokenMonitorEngineState()
        engineLimitsByProfileID = [:]
        refresh(queueIfBusy: true)
    }

    private func cancelStatisticsEngine() {
        engineGeneration.invalidate()
        engineCancellation?.cancel()
        engineCancellation = nil
        engineState.phase = .stopped
    }

    private func refreshStatisticsEngine() {
        cancelStatisticsEngine()
        let choice = StatisticsEngineChoice.stored()
        statisticsEngineChoice = choice
        guard choice == .upstream else {
            engineState = TokenMonitorEngineState(phase: choice == .custom ? .custom : .legacy)
            return
        }
        let generation = engineGeneration.value
        let cancellation = TokenMonitorCancellation()
        engineCancellation = cancellation
        engineState.phase = .loading
        engineState.failureCode = nil
        let candidates = statisticsIncludesManagedCodex ? profiles.filter { !$0.isSystemProfile } : []
        let localSources = engineLocalSources
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let context = RuntimeLoadContext.live(statisticsPreference: preference)
            var sources = localSources
            for profile in candidates {
                let home = profile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
                // Registered home provenance is independent of current login and historical ownership.
                sources.append(
                    TokenMonitorSource(
                        id: profile.id, providerId: "codex", kind: .managedAccount,
                        canonicalPath: home.path, pathRole: .codexHome, toolId: "codex"))
            }
            var request = TokenMonitorRequest(
                operation: .collectUsage,
                timezone: context.statistics.resolvedIdentifier,
                cacheDirectory: context.cacheDirectory.appendingPathComponent("TokenMonitorEngine").path,
                sources: sources)
            // A full multi-agent history scan can outlast a single account quota request.
            request.options.timeoutMs = 60_000
            let result: Result<TokenMonitorEngineState, TokenMonitorFailure>
            do {
                guard !sources.isEmpty else { throw TokenMonitorFailure.invalidSource }
                let response = try TokenMonitorEngine().collect(request: request, cancellation: cancellation)
                guard response.status != .error else { throw TokenMonitorFailure.engineError }
                let prepared = TokenMonitorEngineState(phase: response.status == .ok ? .ready : .partial, lastGood: response)
                guard prepared.dashboardJSON != nil else { throw TokenMonitorFailure.invalidResponse }
                result = .success(prepared)
            } catch { result = .failure((error as? TokenMonitorFailure) ?? .invalidResponse) }
            DispatchQueue.main.async {
                guard self.engineGeneration.accepts(generation), !cancellation.isCancelled,
                    choice == StatisticsEngineChoice.stored(), preference == self.statisticsPreference
                else { return }
                self.engineCancellation = nil
                switch result {
                case .success(let prepared):
                    self.engineState = prepared
                case .failure(let failure):
                    self.engineState.phase = .failed
                    self.engineState.failureCode = failure
                }
            }
        }
    }

    private struct StatisticsSnapshotCacheEntry {
        let snapshot: MultiRuntimeUsageSnapshot
        let cachedAt: Date
    }

    private struct AuthFileState: Equatable {
        let exists: Bool
        let size: UInt64?
        let modifiedAt: Date?
        let fileNumber: UInt64?
    }

    private struct AutomaticSwitchContext {
        let sourceProfileID: String
        let sourceIdentityKey: String
        let sourceAccountID: String
        let sourceAuthFingerprint: Data
        let sourceAccount: FeishuMaskedAccount
        let targetAccount: FeishuMaskedAccount
        let sourceQuota: AutomaticSwitchQuotaState
        let eventID: UUID
        let thresholds: LowQuotaAlertThresholds
        var completeTasks: CodexTaskLiveSnapshot?
    }

    private static func automaticQuotaEvidenceIsFresh(
        succeeded: Bool?, fetchedAt: Date, failedAt: Date?, now: Date
    ) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return succeeded == true && (failedAt.map { $0 < fetchedAt } ?? true)
            && age >= -5 && age <= CodexAutomaticSwitchPolicy.quotaSnapshotMaximumAge
    }

    private var switchPreparationEvidenceID: UUID?

    private static let feishuNotificationsEnabledKey = "CodexManagerNext.feishuNotifications.enabled"
    private static let feishuQuotaResetEnabledKey = "CodexManagerNext.feishuNotifications.quotaReset"
    private static let feishuResetCreditEnabledKey = "CodexManagerNext.feishuNotifications.resetCredit"
    private static let feishuTaskCompletionEnabledKey = "CodexManagerNext.feishuNotifications.taskCompletion"
    private static let feishuMessageOptionsKey = "CodexManagerNext.feishuNotifications.messageOptions.v1"
    private static let localNotificationsEnabledKey = "CodexManagerNext.localNotifications.enabled"
    private static let officialLifetimeHighWaterKey = "CodexManagerNext.tokens.officialLifetimeHighWater"
    private static let localLifetimeHighWaterKey = "CodexManagerNext.tokens.localLifetimeHighWater"
    private static let dispatchQuotaRefreshNotification = Notification.Name(
        "local.codex.account-manager-next.refresh-dispatch-quotas"
    )

    @Published var snapshot: UsageSnapshot = .empty
    @Published var multiRuntimeSnapshot: MultiRuntimeUsageSnapshot = .empty
    @Published var runtimeSnapshots: [RuntimeUsageSnapshot] = []
    @Published var selectedRuntimeScope: RuntimeScope = .codex
    @Published var visibleRuntimeScopes: [RuntimeScope] = RuntimeScope.allCases
    @Published var isRefreshing = false
    @Published private(set) var statisticsPreference: StatisticsTimeZonePreference
    @Published private(set) var statisticsTransitionMessage: String?
    @Published private(set) var isSwitchingStatisticsTimeZone = false
    @Published private(set) var visualEnergyMode: VisualEnergyMode = .suspended
    @Published private(set) var codexLiveTasks: CodexTaskLiveSnapshot = .disconnected
    @Published private(set) var taskFocusRequest: TaskFocusRequest?
    @Published private(set) var isTaskOverviewVisible = false
    @Published private(set) var profiles: [CodexProfile]
    @Published private(set) var officialAccountsLifetimeTokens: Int64?
    @Published private(set) var localAllAgentsLifetimeTokens: Int64?
    @Published private(set) var selectedMonitorProfileID: String
    @Published private(set) var selectedLaunchProfileID: String
    @Published private(set) var accountManagerMessage: String?
    @Published private(set) var operationsIssueJournalMessage: String?
    @Published private(set) var accountSwitchAlertMessage: String?
    @Published private(set) var forcedAccountSwitchProfileID: String?
    @Published private(set) var isLoggingIn = false
    @Published private(set) var deviceLogin: CodexDeviceLoginPresentation?
    private var deviceLoginTarget: CodexProfile?
    private var deviceLoginIsAdding = false
    private var deviceLoginAddedSourceID: String?
    private var activeLoginMaintenanceLeases = Set<String>()
    private var loginShuttingDown = false
    @Published private(set) var isLaunchingCodex = false {
        didSet {
            if !isLaunchingCodex {
                desktopSwitchTargetID = nil
                finishDesktopSwitchMaintenance()
            }
        }
    }
    @Published private(set) var desktopSwitchTargetID: String?
    @Published private(set) var canCancelDesktopSwitch = false
    private var desktopSwitchPreparationTask: Task<Void, Never>?
    private var desktopSwitchMaintenanceLeases: [String] = []
    private var desktopSwitchSucceeded = false
    @Published private(set) var isAwaitingCodexHistoryConfirmation = false
    @Published private(set) var warmingProfileID: String?
    @Published private(set) var refreshingProfileIDs: Set<String> = []
    @Published private(set) var warmUpSelection: CodexWarmUpSelection
    @Published private(set) var automaticAccountSwitchEnabled: Bool
    @Published private(set) var accountRefreshFrequency: AccountRefreshFrequency = .automatic
    @Published private(set) var lowQuotaAlertThresholds: LowQuotaAlertThresholds = .standard
    private(set) var pausedAutomationFeatures: [PausedAutomationFeature] = []
    @Published private(set) var feishuNotificationsEnabled: Bool
    @Published private(set) var feishuQuotaResetEnabled = false
    @Published private(set) var feishuResetCreditEnabled = false
    @Published private(set) var feishuTaskCompletionNotificationsEnabled = false
    @Published private(set) var feishuMessageOptions: FeishuMessageOptions
    @Published private(set) var feishuWebhookConfigured = false
    @Published private(set) var feishuNeedsAuthorization = false
    @Published private(set) var isUpdatingFeishuConnection = false
    @Published private(set) var feishuNotificationMessage: String?
    @Published private(set) var localNotificationsEnabled = false
    @Published private(set) var localNotificationMessage: String?
    @Published private(set) var localNotificationAuthorization: NextLocalNotificationService.AuthorizationState?
    @Published private(set) var isRequestingLocalNotificationPermission = false
    private var localNotificationPermissionRequestID: UUID?
    @Published private(set) var automationEvents: [AccountAutomationEvent]
    let publicResetAnnouncements: PublicResetAnnouncementMonitor

    var automaticWarmUpEnabled: Bool { warmUpSelection.isEnabled }

    private var fullTimer: Timer?
    private var statisticsRolloverTimer: Timer?
    private var warmUpTimer: Timer?
    private var quotaEventTracker = CodexQuotaEventTracker()
    private var warmUpMaintenanceTimer: Timer?
    private var quotaResetRefreshTimer: Timer?
    private var quotaResetRefreshAttempts: [String: Date] = [:]
    private var systemTimeZoneObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    private var thermalStateObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var codexActivationObserver: NSObjectProtocol?
    private var dispatchQuotaRefreshObserver: NSObjectProtocol?
    private var codexInactiveSince: Date?
    private var isCodexFrontmost = false
    private var foregroundCodexThread: (id: String, capturedAt: Date)?
    private var isRefreshingWarmUpProfiles = false
    private var hasPendingDispatchQuotaRefresh = false
    private var warmUpRefreshStartedAt: Date?
    private var warmUpResetTracker = CodexWarmUpResetTracker()
    private var hubWarmUpDeferredUntilByAccount: [String: Date] = [:]
    private var hubWarmUpUnavailableUntil: Date?
    private var refreshGeneration: UInt64 = 0
    private var hasPendingRefresh = false
    private var statisticsSnapshotCache: [String: StatisticsSnapshotCacheEntry] = [:]
    private var statisticsSnapshotCacheOrder: [String] = []
    private var statisticsFeedbackTimer: Timer?
    private var authDirectorySource: DispatchSourceFileSystemObject?
    private var authFileSource: DispatchSourceFileSystemObject?
    private var authRefreshWorkItem: DispatchWorkItem?
    private var monitoredAuthState: AuthFileState?
    private var ignoresAuthChangesUntil: Date?
    private var isAccountSwitchTransactionActive = false
    private var accountSwitchGeneration = TaskTransactionGeneration()
    private var pendingRestoreHandle: CodexSessionRestoreHandle?
    private var automaticSwitchTargetID: String?
    private var automaticCandidateRefreshAttemptAt: Date?
    private var automaticSwitchContext: AutomaticSwitchContext?
    private var codexHistoryConfirmationSuccess: (() -> Void)?
    private var codexHistoryConfirmationFailure: ((String) -> Void)?
    private var codexHistoryConfirmationTimeout: DispatchWorkItem?
    private var hasStarted = false
    private var pendingLaunchProfileID: String?
    private var isMainWindowActive = false
    private var lastFullRefreshCompletedAt: Date?
    private var fullRefreshCancellation: TokenMonitorCancellation?
    private var identityRefreshCancellation: TokenMonitorCancellation?
    private let statisticsSnapshotCacheLimit = 4
    private let statisticsSnapshotCacheTTL: TimeInterval = 3 * 60
    private var foregroundFullRefreshInterval: TimeInterval { accountRefreshFrequency.interval(default: 3 * 60) }
    private var backgroundFullRefreshInterval: TimeInterval { accountRefreshFrequency.interval(default: 5 * 60) }
    private let hubWarmUpRetryDelay: TimeInterval = 5 * 60
    private let profileStore: CodexProfileStore
    private let accountActions = CodexAccountActions()
    private let taskClient = CodexAppServerTaskClient()
    private let feishuWebhookService = FeishuWebhookService()
    let messageChannels = MessageChannelsController()
    private var feishuConfigurationRevision = 0
    private var feishuTaskCompletionObserver = FeishuTaskCompletionObserver()
    private let automationAuditStore = AccountAutomationAuditStore()
    private let terminalLauncher = TerminalAppLauncher()
    let isPreview: Bool

    private func beginAccountSwitchTransaction() -> UInt64 {
        pendingRestoreHandle?.cancel()
        pendingRestoreHandle = nil
        clearCodexHistoryConfirmation()
        let generation = accountSwitchGeneration.begin()
        isAccountSwitchTransactionActive = true
        return generation
    }

    private func finishAccountSwitchTransaction() {
        pendingRestoreHandle?.cancel()
        pendingRestoreHandle = nil
        clearCodexHistoryConfirmation()
        accountSwitchGeneration.invalidate()
        isAccountSwitchTransactionActive = false
    }

    private func invalidateAccountSwitchTransaction() {
        pendingRestoreHandle?.cancel()
        pendingRestoreHandle = nil
        clearCodexHistoryConfirmation()
        accountSwitchGeneration.invalidate()
        isAccountSwitchTransactionActive = false
    }

    private func isCurrentAccountSwitchTransaction(_ generation: UInt64) -> Bool {
        isAccountSwitchTransactionActive && accountSwitchGeneration.accepts(generation)
    }

    init() {
        isPreview = false
        publicResetAnnouncements = PublicResetAnnouncementMonitor()
        statisticsPreference = StatisticsTimeZonePreferenceStore.load()
        automaticAccountSwitchEnabled = UserDefaults.standard.bool(forKey: CodexAutomaticSwitchPolicy.enabledDefaultsKey)
        lowQuotaAlertThresholds = .load()
        accountRefreshFrequency = .load()
        pausedAutomationFeatures = PausedAutomationFeature.read(from: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain))
        feishuNotificationsEnabled = NextFeatureDefaults.isEnabled(Self.feishuNotificationsEnabledKey)
        feishuQuotaResetEnabled = NextFeatureDefaults.isEnabled(Self.feishuQuotaResetEnabledKey)
        feishuResetCreditEnabled = NextFeatureDefaults.isEnabled(Self.feishuResetCreditEnabledKey)
        feishuTaskCompletionNotificationsEnabled = NextFeatureDefaults.isEnabled(Self.feishuTaskCompletionEnabledKey)
        feishuMessageOptions = Self.loadFeishuMessageOptions()
        localNotificationsEnabled = NextFeatureDefaults.isEnabled(Self.localNotificationsEnabledKey)
        let profileStore = CodexProfileStore()
        warmUpSelection = CodexWarmUpSelection.load(hasExistingInstallation: profileStore.hadSavedStateOnLoad)
        try? profileStore.discardUnverifiedManagedProfiles()
        self.profileStore = profileStore
        profiles = profileStore.profiles
        officialAccountsLifetimeTokens = Self.persistedHighWater(
            forKey: Self.officialLifetimeHighWaterKey,
            observed: Self.observedOfficialLifetimeTokens(in: profileStore.profiles)
        )
        localAllAgentsLifetimeTokens = Self.persistedHighWater(
            forKey: Self.localLifetimeHighWaterKey,
            observed: nil
        )
        selectedMonitorProfileID = profileStore.selectedMonitorProfileID
        selectedLaunchProfileID = profileStore.selectedLaunchProfileID
        automationEvents = automationAuditStore.load()
        refreshFeishuWebhookConfiguration()
    }

    /// Documentation fixtures never load account credentials, Keychain, audit logs or
    /// persistent token totals. All profile-store I/O is confined to the supplied sandbox.
    init(previewProfiles: [CodexProfile], snapshot: UsageSnapshot, isolatedRoot: URL) {
        isPreview = true
        publicResetAnnouncements = PublicResetAnnouncementMonitor(preview: true)
        statisticsPreference = .default
        profileStore = CodexProfileStore(
            homeDirectory: isolatedRoot.appendingPathComponent("home"),
            applicationSupportDirectory: isolatedRoot.appendingPathComponent("support")
        )
        profiles = previewProfiles
        self.snapshot = snapshot
        selectedMonitorProfileID = previewProfiles.first?.id ?? "system"
        selectedLaunchProfileID = previewProfiles.first?.id ?? "system"
        officialAccountsLifetimeTokens = Self.observedOfficialLifetimeTokens(in: previewProfiles)
        localAllAgentsLifetimeTokens = nil
        automationEvents = []
        warmUpSelection = .none
        automaticAccountSwitchEnabled = false
        feishuNotificationsEnabled = false
        feishuTaskCompletionNotificationsEnabled = false
        feishuMessageOptions = .standard
        feishuWebhookConfigured = false
    }

    var runtimeSummaries: [RuntimeMenuSummary] {
        RuntimeScope.allCases.compactMap { scope in
            runtimeSnapshot(for: scope)?.summary
        }
    }

    var totalTodayTokens: Int64 {
        multiRuntimeSnapshot.totalTodayTokens
    }

    var selectedMonitorProfile: CodexProfile? {
        profiles.first { $0.id == selectedMonitorProfileID }
    }

    var selectedLaunchProfile: CodexProfile? {
        profiles.first { $0.id == selectedLaunchProfileID }
    }

    var availableChromeProfiles: [ChromeProfileBinding] {
        isPreview ? [] : ChromeProfileBrowser.availableProfiles()
    }

    private var terminalLaunchesInProgress: Set<String> = []
    private var terminalMonitors: [String: Task<Void, Never>] = [:]

    func openTerminal(for profileID: String, workingDirectory: URL? = nil) {
        guard !isPreview, !isLoggingIn, !isLaunchingCodex, !isAccountSwitchTransactionActive,
            !terminalLaunchesInProgress.contains(profileID),
            let profile = profiles.first(where: { $0.id == profileID }), !profile.isSystemProfile
        else { return }
        guard let alias = configuredHubAccountAlias(for: profile) else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("未找到可信账号映射，请先检查账号配置", "No trusted account mapping. Check this account's configuration.")
            return
        }
        terminalLaunchesInProgress.insert(profileID)
        let accountName = AccountDisplay.profileName(profile, allProfiles: profiles)
        let directory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        Task { @MainActor in
            defer { terminalLaunchesInProgress.remove(profileID) }
            let lease: String
            do { lease = try DispatchActivityStore.live.reserveTerminal(account: profile.recordedAccountKey, alias: alias, workingDirectory: directory) } catch {
                accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "账号或工作目录已有占用，或状态待核实；终端未启动", "This account or directory is occupied or unverified. Terminal was not started.")
                return
            }
            guard await HubConsoleModel.warmUpAvailability(for: alias, excludingLocalLease: lease) == .idle,
                !isLoggingIn, !isLaunchingCodex, !isAccountSwitchTransactionActive,
                let latest = profiles.first(where: { $0.id == profileID }), latest.recordedAccountKey == profile.recordedAccountKey
            else {
                guard await persistTerminalActivity(lease, state: "cancelled") else { return }
                accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号状态尚未确认或正在使用；终端未启动", "Account status is unverified or busy. Terminal was not started.")
                return
            }
            guard latest.matchesRecordedCredential(CodexOfficialProfileReader.credentialIdentity(codexHomeURL: latest.codexHomeURL)) else {
                guard await persistTerminalActivity(lease, state: "cancelled") else { return }
                accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "账号凭据与记录不一致，请先重新登录该账号", "Account credentials do not match this profile. Sign in to this account again.")
                return
            }
            do {
                let session = try await terminalLauncher.launch(
                    codexHome: latest.codexHomeURL, workingDirectory: directory,
                    preference: try latest.validatedExecutionPreference(), leaseID: lease)
                accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "已请求打开 \(accountName) 的终端，正在等待启动回执…", "Opening Terminal for \(accountName); waiting for its launch receipt…")
                monitorTerminal(session, lease: lease, accountName: accountName)
            } catch let error as TerminalLaunchDeliveryError {
                if await persistTerminalActivity(lease, state: "uncertain") { accountManagerMessage = error.localizedDescription }
                monitorTerminal(error.session, lease: lease, accountName: accountName)
            } catch {
                guard await persistTerminalActivity(lease, state: "failed") else { return }
                accountManagerMessage = error.localizedDescription
            }
        }
    }

    private func resumeTerminalMonitoring() {
        do {
            for lease in try DispatchActivityStore.live.read().leases where lease.route == "terminal" && lease.occupied {
                do {
                    let session = try TerminalLaunchSession.recovering(leaseID: lease.leaseId)
                    try DispatchActivityStore.live.resumeTerminal(lease)
                    let profile = profiles.first { DispatchActivityStore.hash($0.recordedAccountKey) == lease.accountKey }
                    let name =
                        profile.map { AccountDisplay.profileName($0, allProfiles: profiles) }
                        ?? WidgetLanguage.storedOrAutomatic().text("已隔离账号", "Isolated account")
                    monitorTerminal(session, lease: lease.leaseId, accountName: name)
                } catch {
                    recordOperationsIssue(
                        id: "terminal-recovery-unverified",
                        summary: "A prior terminal reservation could not be reconciled with a private receipt and a stopped owner. Occupancy was preserved.")
                }
            }
        } catch {
            recordOperationsIssue(id: "terminal-recovery-read-failed", summary: "Terminal reservation recovery could not read the shared state. Existing occupancy was preserved.")
        }
    }

    @discardableResult
    private func updateTerminalActivity(_ lease: String, state: String, pid: pid_t? = nil) -> Bool {
        do {
            try DispatchActivityStore.live.updateTerminal(lease, state: state, pid: pid)
            return true
        } catch {
            recordOperationsIssue(id: "terminal-state-save-failed", summary: "Terminal occupancy could not be persisted. Treat the account as unverified until reconciled.")
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "终端占用状态保存失败，请核实该账号后再派单", "Terminal occupancy could not be saved. Verify this account before assigning work.")
            return false
        }
    }

    @MainActor
    private func persistTerminalActivity(_ lease: String, state: String, pid: pid_t? = nil, session: TerminalLaunchSession? = nil) async -> Bool {
        var delay: UInt64 = 1_000_000_000
        while !Task.isCancelled {
            // Recheck after every storage retry; a previous receipt check is not a permit.
            if let session, state == "awaiting_acceptance" || state == "failed" {
                guard let code = session.verifiedExitCode(),
                    state == (code == 0 ? "awaiting_acceptance" : "failed")
                else {
                    _ = await persistTerminalActivity(lease, state: "uncertain")
                    return false
                }
            }
            if updateTerminalActivity(lease, state: state, pid: pid) { return true }
            // Keep both the reservation and its observer while storage recovers.
            // A transient lock or disk error must not orphan an active terminal.
            do { try await Task.sleep(nanoseconds: delay) } catch { return false }
            delay = min(delay * 2, 30_000_000_000)
        }
        return false
    }

    private func monitorTerminal(_ session: TerminalLaunchSession, lease: String, accountName: String) {
        terminalMonitors[lease] = Task { @MainActor [weak self] in
            let startedAt = Date()
            var reportedRunning = false
            var reportedUncertain = false
            var missingProcessSince: Date?
            defer { self?.terminalMonitors.removeValue(forKey: lease) }
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    switch try session.readState() {
                    case .pending:
                        if Date().timeIntervalSince(startedAt) > 15, !reportedUncertain {
                            guard await self.persistTerminalActivity(lease, state: "uncertain") else { return }
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "终端没有返回启动回执；请检查 Terminal，账号占用保留待核实", "No terminal launch receipt. Check Terminal; the account remains reserved until verified.")
                            reportedUncertain = true
                        }
                    case .started(let pid):
                        if !session.hasMatchingLiveProcess(pid) {
                            // The wrapper may have exited between the receipt read and
                            // the process check. Allow its atomic final receipt to land.
                            if let missingProcessSince, Date().timeIntervalSince(missingProcessSince) >= 1 {
                                guard await self.persistTerminalActivity(lease, state: "uncertain") else { return }
                                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                    "终端进程与回执无法确认匹配；占用保留待核实", "The terminal process could not be matched to its receipt. Its reservation remains until verified.")
                                return
                            }
                            if missingProcessSince == nil { missingProcessSince = Date() }
                            try await Task.sleep(nanoseconds: 250_000_000)
                            continue
                        }
                        missingProcessSince = nil
                        guard await self.persistTerminalActivity(lease, state: "running", pid: pid) else { return }
                        if !reportedRunning {
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "\(accountName) 的终端启动脚本已运行，请查看终端内的 CLI 提示", "Terminal launch script is running for \(accountName). Check the CLI prompt in Terminal.")
                            reportedRunning = true
                        }
                    case .exited(let code):
                        guard session.verifiedExitCode() == code else {
                            guard await self.persistTerminalActivity(lease, state: "uncertain") else { return }
                            reportedUncertain = true
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "终端退出回执尚不能证明进程组已结束；占用保留待核实", "The exit receipt does not yet prove the process group has ended. The reservation is preserved.")
                            // EXIT runs before the writer disappears. Keep observing;
                            // descendants may also legitimately outlive the wrapper.
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                            continue
                        }
                        guard await self.persistTerminalActivity(lease, state: code == 0 ? "awaiting_acceptance" : "failed", session: session) else { return }
                        self.accountManagerMessage =
                            code == 0
                            ? WidgetLanguage.storedOrAutomatic().text("\(accountName) 的终端会话已结束", "Terminal session for \(accountName) has ended.")
                            : WidgetLanguage.storedOrAutomatic().text(
                                "\(accountName) 的 CLI 已退出（代码 \(code)），请查看终端错误", "CLI for \(accountName) exited with code \(code). Check the terminal error.")
                        if code < 128 { session.removeAfterExit() }
                        return
                    }
                } catch {
                    guard !Task.isCancelled, await self.persistTerminalActivity(lease, state: "uncertain") else { return }
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "终端回执无法读取；占用保留待核实", "The terminal receipt could not be read. Its reservation remains until verified.")
                    return
                }
                do { try await Task.sleep(nanoseconds: reportedRunning || reportedUncertain ? 10_000_000_000 : 250_000_000) } catch { return }
            }
        }
    }

    func copyTerminalCommand(for profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }), !profile.isSystemProfile else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "请选择已隔离的账号环境；不会生成指向 ~/.codex 的启动命令", "Select an isolated account profile. A launch command for the system Codex profile will not be generated.")
            return
        }
        do {
            let command = try terminalLauncher.launchCommand(
                codexHome: profile.codexHomeURL,
                workingDirectory: nil,
                preference: try profile.validatedExecutionPreference()
            )
            NSPasteboard.general.clearContents()
            let copied = NSPasteboard.general.setString(command, forType: .string)
            accountManagerMessage =
                copied
                ? WidgetLanguage.storedOrAutomatic().text("启动命令已复制；执行前请确认账号空闲", "CLI launch command copied. Verify the account is idle before running it.")
                : WidgetLanguage.storedOrAutomatic().text("无法写入剪贴板，请重试", "Could not write to the clipboard. Try again.")
        } catch {
            accountManagerMessage = error.localizedDescription
        }
    }

    func totalTodayTokens(for scopes: [RuntimeScope]) -> Int64 {
        scopes.reduce(Int64(0)) { total, scope in
            total + (runtimeSnapshot(for: scope)?.todayTokens ?? 0)
        }
    }

    func addProfile() {
        beginAddingProfile(copyingRemarkFrom: nil, chromeProfile: nil)
    }

    func addProfile(using chromeProfile: ChromeProfileBinding) {
        beginAddingProfile(copyingRemarkFrom: nil, chromeProfile: chromeProfile)
    }

    func loginProfileIndependently(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
            profile.isSystemProfile
        else { return }
        beginAddingProfile(copyingRemarkFrom: profile.id, chromeProfile: profile.chromeProfile)
    }

    private func beginAddingProfile(
        copyingRemarkFrom sourceProfileID: String?,
        chromeProfile: ChromeProfileBinding?
    ) {
        guard warmingProfileID == nil else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号暖号正在执行；完成后再添加账号", "Wait for the current warm-up to finish before adding an account.")
            return
        }
        guard !isRefreshingWarmUpProfiles else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号数据仍在读取；完成后再添加账号", "Wait for account data to finish loading before adding an account.")
            return
        }
        guard !isPreview, !loginShuttingDown, !isLoggingIn, !isLaunchingCodex, !isAccountSwitchTransactionActive else { return }
        let profile: CodexProfile
        do {
            profile = try profileStore.addManagedProfile(
                copyingRemarkFrom: sourceProfileID,
                chromeProfile: chromeProfile
            )
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("创建账号失败：\(error.localizedDescription)", "Could not create the profile: \(error.localizedDescription)")
            return
        }

        presentDeviceLogin(profile, adding: true, sourceID: sourceProfileID)
        let requestID = deviceLogin?.id
        isLoggingIn = true
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("请在浏览器中登录新账号…", "Sign in to the new account in your browser…")
        do {
            try accountActions.login(
                profile: profile,
                onPhaseChange: { [weak self] phase in
                    self?.receiveDeviceLoginPhase(phase, requestID: requestID)
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.verifyAddedProfile(profile, replacingSystemProfileID: sourceProfileID)
                    case .failure(let error):
                        let phase = self.deviceLoginFailurePhase(error)
                        self.discardAddedProfile(profile, message: self.safeDeviceLoginMessage(phase))
                        self.deviceLogin?.phase = phase
                    }
                })
        } catch {
            let phase = deviceLoginFailurePhase(error)
            discardAddedProfile(profile, message: safeDeviceLoginMessage(phase))
            deviceLogin?.phase = phase
        }
    }

    private func verifyAddedProfile(_ profile: CodexProfile, replacingSystemProfileID: String?) {
        deviceLogin?.phase = .verifying
        let startedAt = Date()
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("登录完成，正在验证账号…", "Sign-in complete. Verifying the account…")
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let context = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: profile.codexHomeURL
            )
            let verifiedSnapshot = CodexUsageReader().load(context: context)
            let officialProfile = CodexOfficialProfileReader.load(codexHomeURL: profile.codexHomeURL)
            let credentialIdentity = CodexOfficialProfileReader.credentialIdentity(
                codexHomeURL: profile.codexHomeURL
            )
            DispatchQueue.main.async {
                guard let email = verifiedSnapshot.account?.email,
                    !email.isEmpty,
                    credentialIdentity?.email == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                else {
                    self.discardAddedProfile(profile, message: WidgetLanguage.storedOrAutomatic().text("没有识别到有效账号，本次未添加", "No valid account was found. Nothing was added."))
                    return
                }
                if let existing = self.profiles.first(where: {
                    $0.lastSnapshot?.accountID == credentialIdentity?.accountID
                }) {
                    try? self.profileStore.discardManagedProfile(profile.id)
                    try? self.profileStore.selectMonitor(existing.id)
                    self.syncProfiles()
                    self.configureAuthMonitoring()
                    self.isLoggingIn = false
                    self.presentDeviceLogin(existing)
                    self.deviceLogin?.phase = .quotaPending
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("这个账号已经在列表中", "This account is already in the list.")
                    self.clearDisplayedAccount()
                    self.refresh(queueIfBusy: true)
                    return
                }
                do {
                    try self.profileStore.record(verifiedSnapshot, for: profile.id, allowAccountOnly: true)
                    if let officialProfile {
                        try self.profileStore.recordOfficialProfile(officialProfile, for: profile.id)
                    }
                    if let replacingSystemProfileID {
                        try self.profileStore.setRemark("", for: replacingSystemProfileID)
                    }
                    try self.profileStore.selectMonitor(profile.id)
                    self.syncProfiles()
                    self.configureAuthMonitoring()
                    self.isLoggingIn = false
                    self.deviceLoginIsAdding = false
                    self.deviceLogin?.phase =
                        CodexDeviceLoginVerification.hasFreshQuota(verifiedSnapshot, since: startedAt)
                            && self.profiles.first(where: { $0.id == profile.id })?.lastSnapshot?.fetchedAt == verifiedSnapshot.refreshedAt
                            && self.profiles.first(where: { $0.id == profile.id })?.lastQuotaReadFailureAt == nil
                        ? .completed : .quotaPending
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已添加 \(AccountDisplay.masked(email))", "Added \(AccountDisplay.masked(email)).")
                    self.clearDisplayedAccount()
                    self.refresh(queueIfBusy: true)
                } catch {
                    self.discardAddedProfile(
                        profile,
                        message: WidgetLanguage.storedOrAutomatic().text("账号保存失败：\(error.localizedDescription)", "Could not save the account: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func discardAddedProfile(_ profile: CodexProfile, message: String) {
        try? profileStore.discardManagedProfile(profile.id)
        syncProfiles()
        isLoggingIn = false
        accountManagerMessage = message
        deviceLogin?.phase = .failed(.missingCredentials)
    }

    func localResetHistoryCount(for profile: CodexProfile) -> Int {
        profileStore.resetCounter(accountKey: profile.recordedAccountKey).total
    }

    func availableResetCredits(for profile: CodexProfile) -> Int? {
        if profile.id == selectedMonitorProfileID {
            return snapshot.credits?.resetCredits
        }
        return profile.lastSnapshot?.availableResetCredits
    }

    func resetCreditExpiries(for profile: CodexProfile) -> [Date] {
        if profile.id == selectedMonitorProfileID {
            return snapshot.credits?.resetCreditDetails?.compactMap(\.expiresAt).sorted() ?? []
        }
        return profile.lastSnapshot?.resetCreditExpiries ?? []
    }

    func adjustResetCount(for profile: CodexProfile, delta: Int) {
        do {
            try profileStore.adjustResetManualOffset(
                accountKey: profile.recordedAccountKey,
                delta: delta,
                fallbackExpiry: nil
            )
            syncProfiles()
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "重置次数校正失败：\(error.localizedDescription)", "Could not adjust local reset history: \(error.localizedDescription)")
        }
    }

    func selectMonitorProfile(_ id: String) {
        guard id != selectedMonitorProfileID else { return }
        guard captureCurrentProfile() else { return }
        do {
            try profileStore.selectMonitor(id)
            syncProfiles()
            configureAuthMonitoring()
            clearDisplayedAccount()
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已切换监控账号", "Monitoring account changed. Desktop sign-in is unchanged.")
            refresh(queueIfBusy: true)
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "切换失败：\(error.localizedDescription)", "Could not change the monitored account: \(error.localizedDescription)")
        }
    }

    func selectLaunchProfile(_ id: String) {
        guard captureCurrentProfile() else { return }
        do {
            try profileStore.selectLaunch(id)
            syncProfiles()
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已设为下次启动账号", "Saved as the next Desktop launch account.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "保存启动账号失败：\(error.localizedDescription)", "Could not save the launch account: \(error.localizedDescription)")
        }
    }

    func setProfileRemark(_ remark: String, for id: String) {
        do {
            try profileStore.setRemark(remark, for: id)
            syncProfiles()
            accountManagerMessage =
                remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? WidgetLanguage.storedOrAutomatic().text("已恢复账号默认名称", "Restored the default account label.")
                : WidgetLanguage.storedOrAutomatic().text("账号备注已保存", "Account label saved.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("保存备注失败：\(error.localizedDescription)", "Could not save the label: \(error.localizedDescription)")
        }
    }

    func automaticSwitchParticipation(for profile: CodexProfile) -> Bool {
        automaticSwitchParticipation(for: profile.id)
    }

    func dispatchPriority(for profile: CodexProfile) -> Bool {
        CodexProfile.prioritizesDispatch(profile.id, among: profiles)
    }

    private func automaticSwitchParticipation(for profileID: String) -> Bool {
        CodexProfile.participatesInAutomaticSwitch(profileID, among: profiles)
    }

    func setAutomaticSwitchParticipation(_ enabled: Bool, for id: String) {
        guard !isPreview else { return }
        do {
            try profileStore.setDispatchParticipationFromUI(enabled, for: id)
            DispatchCodeCatalog.reload()
            syncProfiles()
            accountManagerMessage =
                enabled
                ? WidgetLanguage.storedOrAutomatic().text(
                    "该账号已加入调度；Next、Hub 配置与编号已同步", "Account added to the pool. Next, Hub config and pool code are synced.")
                : WidgetLanguage.storedOrAutomatic().text(
                    "该账号已退出调度并保留原编号；Next 与 Hub 配置已同步，额度刷新和两种暖号照常",
                    "Account excluded from the pool with its code retained. Next and Hub config are synced; limit refresh and both warm-up windows continue.")
            debugLog("dispatch participation: three-source sync succeeded")
            refreshWarmUpProfilesThenSchedule()
        } catch {
            let message =
                (error as? DispatchParticipationError)?.localizedDescription
                ?? WidgetLanguage.storedOrAutomatic().text("参与调度同步失败，请检查配置与备份", "Pool sync failed. Check the configuration and backups.")
            accountManagerMessage = message
            debugLog("dispatch participation: \(message)")
            syncProfiles()
        }
    }

    func setDispatchPriority(_ enabled: Bool, for id: String) {
        guard !isPreview else { return }
        do {
            try profileStore.setDispatchPriorityFromUI(enabled, for: id)
            DispatchCodeCatalog.reload()
            syncProfiles()
            accountManagerMessage =
                enabled
                ? WidgetLanguage.storedOrAutomatic().text(
                    "已加入调度并保存优先偏好；三源已同步（当前 Hub 尚未消费优先标记）", "Pool membership and priority preference saved. Hub does not yet use priority for account selection.")
                : WidgetLanguage.storedOrAutomatic().text("已取消优先偏好，保留原参与设置；三源已同步", "Priority preference cleared and synced. Pool membership is unchanged.")
            refreshWarmUpProfilesThenSchedule()
        } catch {
            accountManagerMessage =
                (error as? DispatchParticipationError)?.localizedDescription
                ?? WidgetLanguage.storedOrAutomatic().text("优先派活同步失败，请检查配置与备份", "Priority preference sync failed. Check the configuration and backups.")
            syncProfiles()
        }
    }

    func setDispatchParticipationWindow(_ window: DispatchParticipationWindow, for id: String) -> Bool {
        guard !isPreview else { return false }
        do {
            try profileStore.setDispatchParticipationWindow(window, for: id)
            syncProfiles()
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "已保存参与时间段；支持该规则的调度入口会在新派单前检查", "Dispatch hours saved; compatible dispatch entry points check them before new assignments.")
            return true
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("保存参与时间段失败，请检查配置后重试", "Could not save dispatch hours. Check the configuration and retry.")
            return false
        }
    }

    func setProTierMultiplier(_ multiplier: Int?, for id: String) {
        do {
            try profileStore.setProTierMultiplier(multiplier, for: id)
            syncProfiles()
            accountManagerMessage =
                multiplier.map { WidgetLanguage.storedOrAutomatic().text("Pro 档位已设为 \($0)x", "Pro tier label set to \($0)x.") }
                ?? WidgetLanguage.storedOrAutomatic().text("Pro 档位已恢复为未指定", "Pro tier label cleared.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "Pro 档位保存失败：\(error.localizedDescription)", "Could not save the Pro tier label: \(error.localizedDescription)")
        }
    }

    func setExecutionPreference(
        _ preference: CodexExecutionPreference,
        for id: String,
        applyToAll: Bool
    ) {
        do {
            try profileStore.setExecutionPreference(preference, for: id, applyToAll: applyToAll)
            syncProfiles()
            let summary = "\(preference.model.displayName) · \(preference.reasoningEffort.displayName) · \(preference.serviceTier.displayName)"
            accountManagerMessage =
                applyToAll
                ? WidgetLanguage.storedOrAutomatic().text("已将 \(summary) 应用到所有独立账号", "Applied \(summary) to all isolated profiles.")
                : WidgetLanguage.storedOrAutomatic().text("该账号后续 CLI 与任务派单将使用 \(summary)", "New CLI sessions and dispatched tasks for this profile will use \(summary).")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "执行偏好保存失败：\(error.localizedDescription)", "Could not save model settings: \(error.localizedDescription)")
        }
    }

    func setChromeProfile(_ binding: ChromeProfileBinding?, for id: String) {
        do {
            try profileStore.setChromeProfile(binding, for: id)
            syncProfiles()
            accountManagerMessage =
                binding.map { WidgetLanguage.storedOrAutomatic().text("已绑定 Chrome 用户资料：\($0.displayName)", "Chrome profile set to \($0.displayName).") }
                ?? WidgetLanguage.storedOrAutomatic().text("已启用自动匹配；无匹配时使用账号专属 Chrome 会话", "Automatic Chrome matching enabled. A dedicated profile is used when no match is found.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "Chrome 用户资料保存失败：\(error.localizedDescription)", "Could not save the Chrome profile: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func reorderProfiles(_ orderedIDs: [String], expectedCurrentOrder: [String]) -> Bool {
        do {
            try profileStore.reorderProfiles(orderedIDs, expectedCurrentOrder: expectedCurrentOrder)
            profiles = profileStore.profiles
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号顺序已保存", "Account order saved.")
            return true
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("调整顺序失败：\(error.localizedDescription)", "Could not save account order: \(error.localizedDescription)")
            return false
        }
    }

    func moveProfile(_ id: String, relativeTo targetID: String, before: Bool) {
        do {
            try profileStore.moveProfile(id, relativeTo: targetID, before: before)
            syncProfiles()
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号顺序已保存", "Account order saved.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("调整顺序失败：\(error.localizedDescription)", "Could not save account order: \(error.localizedDescription)")
        }
    }

    func deleteProfile(_ id: String) {
        guard !isLoggingIn,
            !isLaunchingCodex,
            warmingProfileID == nil,
            let profile = profiles.first(where: { $0.id == id }),
            !profile.isSystemProfile
        else {
            if warmingProfileID != nil {
                accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号暖号正在执行；完成后再删除账号", "Wait for the current warm-up to finish before removing an account.")
            }
            return
        }
        let wasMonitoring = id == selectedMonitorProfileID
        do {
            try profileStore.removeManagedProfile(id)
            syncProfiles()
            if wasMonitoring {
                configureAuthMonitoring()
                clearDisplayedAccount()
                refresh(queueIfBusy: true)
            }
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已删除 \(AccountDisplay.profileName(profile))", "Removed \(AccountDisplay.profileName(profile)).")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("删除账号失败：\(error.localizedDescription)", "Could not remove the account: \(error.localizedDescription)")
        }
    }

    func loginSelectedMonitorProfile() {
        loginProfile(selectedMonitorProfileID)
    }

    private var loginPreflightID: UUID?
    private var loginMaintenanceFinishes: [String: Task<Void, Never>] = [:]

    func setDeviceLoginLayoutPreview() {
        guard isPreview else { return }
        refreshingProfileIDs = Set(profiles.prefix(1).map(\.id))
        warmingProfileID = profiles.dropFirst().first?.id
    }

    static func deviceLoginTargetSelfTest() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-target-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 2, root: root)
        store.presentDeviceLogin(store.profiles[0])
        let originalID = store.deviceLogin!.id
        store.selectedMonitorProfileID = store.profiles[1].id
        store.receiveDeviceLoginPhase(.verifying, requestID: originalID)
        guard store.deviceLogin?.profileID == store.profiles[0].id,
            store.deviceLogin?.phase == .verifying
        else { return false }
        store.presentDeviceLogin(store.profiles[1])
        store.receiveDeviceLoginPhase(.completed, requestID: originalID)
        guard store.deviceLogin?.profileID == store.profiles[1].id,
            store.deviceLogin?.phase == .preparing
        else { return false }
        print("device login frozen target and stale callback self-test passed")
        return true
    }

    private func presentDeviceLogin(_ profile: CodexProfile, adding: Bool = false, sourceID: String? = nil) {
        deviceLoginTarget = profile
        deviceLoginIsAdding = adding
        deviceLoginAddedSourceID = sourceID
        let code = DispatchCodeCatalog.code(for: profile.id, allowsLocalRead: !isPreview)
        let name = AccountDisplay.profileName(profile) + (code.map { " · \($0)" } ?? "")
        deviceLogin = CodexDeviceLoginPresentation(id: UUID(), profileID: profile.id, targetName: name, phase: .preparing)
    }

    private func receiveDeviceLoginPhase(_ phase: CodexDeviceLoginPhase, requestID: UUID?) {
        guard let requestID, deviceLogin?.id == requestID else { return }
        if deviceLogin?.phase == .cancelling { return }
        deviceLogin?.phase = phase
        if phase.authorization == nil { deviceLogin?.copiedUntil = nil }
    }

    private func deviceLoginFailurePhase(_ error: Error) -> CodexDeviceLoginPhase {
        if let error = error as? CodexLoginError {
            switch error {
            case .cancelled: return .cancelled
            case .timedOut: return .expired
            case .identityMismatch: return .failed(.identityMismatch)
            case .credentialsUnavailable: return .failed(.missingCredentials)
            default: return .failed(.unavailable)
            }
        }
        return .failed((error as? CodexDeviceLoginFailure) ?? .unavailable)
    }

    func copyDeviceCode() {
        guard !isPreview, let authorization = deviceLogin?.phase.authorization, authorization.isValid() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authorization.code, forType: .string)
        deviceLogin?.copiedUntil = Date().addingTimeInterval(3)
    }

    func copyDeviceAuthURL() {
        guard !isPreview, let authorization = deviceLogin?.phase.authorization, authorization.isValid() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authorization.url.absoluteString, forType: .string)
    }

    func reopenDeviceAuthPage() {
        guard !isPreview, deviceLogin?.phase.authorization?.isValid() == true else { return }
        accountActions.reopenDeviceAuthPage()
    }

    func dismissDeviceLogin() {
        guard !isLoggingIn, deviceLogin?.phase.canDismiss == true else { return }
        deviceLogin = nil
        deviceLoginTarget = nil
    }

    func regenerateDeviceCode() {
        guard !isPreview, !isLoggingIn, !accountActions.isLoginRunning,
            activeLoginMaintenanceLeases.isEmpty, let target = deviceLoginTarget
        else { return }
        if deviceLoginIsAdding {
            beginAddingProfile(copyingRemarkFrom: deviceLoginAddedSourceID, chromeProfile: target.chromeProfile)
        } else {
            loginProfile(target.id)
        }
    }

    func retryDeviceLoginVerification() {
        guard !isPreview, !isLoggingIn, let target = deviceLoginTarget else { return }
        loginProfile(target.id, verificationOnly: true)
    }

    func cancelLogin() {
        guard isLoggingIn, deviceLogin?.phase != .verifying else { return }
        deviceLogin?.phase = .cancelling
        deviceLogin?.copiedUntil = nil
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在取消登录…", "Cancelling sign-in…")
        if loginPreflightID != nil {
            // Keep the reservation until the pending preflight returns and releases it.
            loginPreflightID = nil
        } else {
            accountActions.cancelLogin()
        }
    }

    func finishLoginForTermination() async {
        loginShuttingDown = true
        cancelLogin()
        while isLoggingIn || accountActions.isLoginRunning || !activeLoginMaintenanceLeases.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func loginProfile(_ profileID: String, verificationOnly: Bool = false) {
        guard !isPreview, !loginShuttingDown, !isLoggingIn, !isLaunchingCodex, !isAccountSwitchTransactionActive,
            let profile = profiles.first(where: { $0.id == profileID }), !profile.isSystemProfile
        else { return }
        presentDeviceLogin(profile)
        guard warmingProfileID == nil, !isRefreshingWarmUpProfiles,
            let alias = configuredHubAccountAlias(for: profile)
        else {
            deviceLogin?.phase = .failed(.busy)
            accountManagerMessage = CodexDeviceLoginFailure.busy.message(WidgetLanguage.storedOrAutomatic())
            return
        }
        let lease: String
        do { lease = try DispatchActivityStore.live.reserveMaintenance(account: profile.recordedAccountKey, alias: alias) } catch {
            deviceLogin?.phase = .failed(.busy)
            accountManagerMessage = CodexDeviceLoginFailure.busy.message(WidgetLanguage.storedOrAutomatic())
            return
        }
        activeLoginMaintenanceLeases.insert(lease)
        let requestID = deviceLogin!.id
        loginPreflightID = requestID
        isLoggingIn = true
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在核对账号占用…", "Checking account availability…")
        Task { @MainActor in
            let availability = await HubConsoleModel.warmUpAvailability(for: alias, excludingLocalLease: lease)
            guard loginPreflightID == requestID else {
                finishAccountMaintenance(lease, succeeded: false) {
                    self.isLoggingIn = false
                    self.deviceLogin?.phase = .cancelled
                    self.accountManagerMessage = CodexLoginError.cancelled.localizedDescription
                }
                return
            }
            loginPreflightID = nil
            guard availability == .idle, !isLaunchingCodex, !isAccountSwitchTransactionActive,
                let current = profiles.first(where: { $0.id == profile.id }), current.recordedAccountKey == profile.recordedAccountKey
            else {
                finishAccountMaintenance(lease, succeeded: false) {
                    self.isLoggingIn = false
                    self.deviceLogin?.phase = .failed(.busy)
                    self.accountManagerMessage = CodexDeviceLoginFailure.busy.message(WidgetLanguage.storedOrAutomatic())
                }
                return
            }
            if verificationOnly { verifyReloggedProfile(current, maintenanceLease: lease) } else { performProfileLogin(current, maintenanceLease: lease) }
        }
    }

    private func performProfileLogin(_ profile: CodexProfile, maintenanceLease: String) {
        let requestID = deviceLogin?.id
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在生成授权代码…", "Generating an authorization code…")
        do {
            try accountActions.login(
                profile: profile,
                onPhaseChange: { [weak self] phase in
                    self?.receiveDeviceLoginPhase(phase, requestID: requestID)
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.verifyReloggedProfile(profile, maintenanceLease: maintenanceLease)
                    case .failure(let error):
                        let phase = self.deviceLoginFailurePhase(error)
                        self.finishAccountMaintenance(maintenanceLease, succeeded: false) {
                            self.isLoggingIn = false
                            self.deviceLogin?.phase = phase
                            self.accountManagerMessage = self.safeDeviceLoginMessage(phase)
                        }
                    }
                })
        } catch {
            let phase = deviceLoginFailurePhase(error)
            finishAccountMaintenance(maintenanceLease, succeeded: false) {
                self.isLoggingIn = false
                self.deviceLogin?.phase = phase
                self.accountManagerMessage = self.safeDeviceLoginMessage(phase)
            }
        }
    }

    private func safeDeviceLoginMessage(_ phase: CodexDeviceLoginPhase) -> String {
        switch phase {
        case .cancelled: return CodexLoginError.cancelled.localizedDescription
        case .expired: return CodexLoginError.timedOut.localizedDescription
        case .failed(let failure): return failure.message(WidgetLanguage.storedOrAutomatic())
        default: return WidgetLanguage.storedOrAutomatic().text("正在验证登录结果…", "Verifying sign-in…")
        }
    }

    private func finishAccountMaintenance(_ lease: String, succeeded: Bool, completion: (() -> Void)? = nil) {
        guard loginMaintenanceFinishes[lease] == nil else { return }
        loginMaintenanceFinishes[lease] = Task { @MainActor [weak self] in
            defer { self?.loginMaintenanceFinishes.removeValue(forKey: lease) }
            var delay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try DispatchActivityStore.live.finishMaintenance(lease, succeeded: succeeded)
                    self.activeLoginMaintenanceLeases.remove(lease)
                    completion?()
                    return
                } catch {
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "账号维护占用尚未保存完成，正在重试；账号暂不派单", "Finishing the account reservation is pending. Retrying; dispatch remains blocked.")
                }
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                delay = min(delay * 2, 30_000_000_000)
            }
        }
    }

    private func verifyReloggedProfile(_ profile: CodexProfile, maintenanceLease: String) {
        deviceLogin?.phase = .verifying
        let requestID = deviceLogin?.id
        let startedAt = Date()
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("网页授权已完成，正在确认账号身份和额度…", "Web authorization completed. Checking identity and limits…")
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let context = RuntimeLoadContext.live(statisticsPreference: preference, codexHomeDirectory: profile.codexHomeURL)
            let verifiedSnapshot = CodexUsageReader().load(context: context)
            let officialProfile = CodexOfficialProfileReader.load(codexHomeURL: profile.codexHomeURL)
            let credentialIdentity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: profile.codexHomeURL)
            DispatchQueue.main.async {
                var verified = false
                var phase: CodexDeviceLoginPhase = .failed(.verification)
                defer {
                    self.finishAccountMaintenance(maintenanceLease, succeeded: verified) {
                        self.isLoggingIn = false
                        guard self.deviceLogin?.id == requestID else { return }
                        self.deviceLogin?.phase = phase
                    }
                }
                guard self.deviceLogin?.id == requestID,
                    let current = self.profiles.first(where: { $0.id == profile.id }), current.recordedAccountKey == profile.recordedAccountKey,
                    let verifiedAccount = verifiedSnapshot.account,
                    profile.matchesRecordedAccount(email: verifiedAccount.email),
                    profile.matchesRecordedCredential(credentialIdentity)
                else {
                    self.accountManagerMessage = CodexDeviceLoginFailure.verification.message(WidgetLanguage.storedOrAutomatic())
                    return
                }
                do {
                    try self.profileStore.record(verifiedSnapshot, for: profile.id, allowAccountOnly: true)
                    if let officialProfile { try self.profileStore.recordOfficialProfile(officialProfile, for: profile.id) }
                    try self.profileStore.selectMonitor(profile.id)
                    self.syncProfiles()
                    self.configureAuthMonitoring()
                    self.clearDisplayedAccount()
                    verified = true
                    phase =
                        CodexDeviceLoginVerification.hasFreshQuota(verifiedSnapshot, since: startedAt)
                            && self.profiles.first(where: { $0.id == profile.id })?.lastSnapshot?.fetchedAt == verifiedSnapshot.refreshedAt
                            && self.profiles.first(where: { $0.id == profile.id })?.lastQuotaReadFailureAt == nil
                        ? .completed : .quotaPending
                    self.accountManagerMessage =
                        phase == .completed
                        ? WidgetLanguage.storedOrAutomatic().text("登录完成，身份与额度已验证。", "Sign-in complete. Identity and limits verified.")
                        : WidgetLanguage.storedOrAutomatic().text("账号身份已确认，额度暂未读到。", "Account identity confirmed. Limits are not yet available.")
                    self.refresh(queueIfBusy: true)
                } catch {
                    phase = .failed(.save)
                    self.accountManagerMessage = CodexDeviceLoginFailure.save.message(WidgetLanguage.storedOrAutomatic())
                }
            }
        }
    }

    func dismissAccountSwitchAlert() {
        accountSwitchAlertMessage = nil
        forcedAccountSwitchProfileID = nil
    }

    func confirmForcedAccountSwitch() {
        guard let profileID = forcedAccountSwitchProfileID else { return }
        dismissAccountSwitchAlert()
        launchCodex(with: profileID, forceWithoutSessionRestore: true)
    }

    private func refreshTaskSnapshotIfStale(now: Date = Date()) {
        guard now.timeIntervalSince(codexLiveTasks.refreshedAt) > 20 else { return }
        guard let refreshedSnapshot = taskClient.awaitSnapshot(timeout: 8) else { return }
        codexLiveTasks = refreshedSnapshot
    }

    func launchCodex(with profileID: String, forceWithoutSessionRestore: Bool = false) {
        guard !isLaunchingCodex, !isLoggingIn, !isAccountSwitchTransactionActive else {
            presentAccountSwitchBlock(
                WidgetLanguage.storedOrAutomatic().text(
                    "已有登录或切换正在处理，请等待完成；当前账号未改变", "A sign-in or switch is already in progress. Wait for it to finish."), isAutomatic: automaticSwitchTargetID == profileID)
            return
        }
        // Publish before any disk, process or network work. This also reserves
        // the interaction against double-clicks and scheduled warm-up.
        desktopSwitchSucceeded = false
        desktopSwitchTargetID = profileID
        isLaunchingCodex = true
        canCancelDesktopSwitch = true
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在准备切换…", "Preparing to switch…")
        let isAutomatic = automaticSwitchTargetID == profileID
        if !isAutomatic { cancelQuotaRefreshesForDesktopSwitch() }
        let preparationID = UUID()
        switchPreparationEvidenceID = preparationID
        desktopSwitchPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var handedOff = false
            defer {
                if !handedOff, switchPreparationEvidenceID == preparationID {
                    switchPreparationEvidenceID = nil
                    finishDesktopSwitchPreparation()
                    isLaunchingCodex = false
                    finishAutomaticSwitchAttempt(
                        for: profileID, succeeded: false, failureReason: .validationFailed,
                        detail: WidgetLanguage.storedOrAutomatic().text(
                            "切换准备未完成或已取消", "Switch preparation failed or was cancelled."))
                }
            }
            let deadline = Date().addingTimeInterval(45)
            while isAutomatic && (isRefreshing || isRefreshingWarmUpProfiles || warmingProfileID != nil) {
                accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "切换已排队，正在等待本次账号读取结束…", "Switch queued. Waiting for the current account check to finish…")
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                guard Date() < deadline else {
                    finishDesktopSwitchPreparation()
                    isLaunchingCodex = false
                    accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "本次账号读取耗时过长，切换已取消；请稍后重试", "The account check took too long. Switch cancelled; try again shortly.")
                    return
                }
            }
            guard !Task.isCancelled else { return }
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在检查桌面任务…", "Checking Desktop tasks…")
            let client = taskClient
            if isAutomatic { automaticSwitchContext?.completeTasks = nil }
            let refreshed = await Task.detached(priority: .userInitiated) {
                client.awaitSnapshot(timeout: 5)
            }.value
            guard !Task.isCancelled else { return }
            if let refreshed {
                codexLiveTasks = refreshed
                if isAutomatic { automaticSwitchContext?.completeTasks = refreshed }
            } else {
                codexLiveTasks = .disconnected
                // Manual requests still need to reach beginCodexSwitch's explicit
                // confirmation. Missing task evidence never grants force itself.
                guard !isAutomatic else {
                    accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "完整任务读取失败，切换已取消", "Complete task read failed; switching cancelled.")
                    return
                }
            }
            let board = snapshot.taskBoard
            let canRestore =
                !forceWithoutSessionRestore
                && CodexAutomaticSwitchPolicy.hasNoActiveTasks(codexLiveTasks, legacyManagerRunning: false)
            let visibleThread = await Task.detached(priority: .userInitiated) {
                canRestore ? CodexSessionOpener.visibleThreadID(in: board) : nil
            }.value
            guard !Task.isCancelled else { return }
            let reserved = await reserveDesktopSwitchMaintenance(for: profileID)
            guard !Task.isCancelled else { return }
            guard reserved else {
                finishDesktopSwitchPreparation()
                isLaunchingCodex = false
                return
            }
            finishDesktopSwitchPreparation()
            handedOff = true
            switchPreparationEvidenceID = nil
            beginCodexSwitch(with: profileID, forceWithoutSessionRestore: forceWithoutSessionRestore, visibleThreadID: visibleThread)
        }
    }

    private func cancelQuotaRefreshesForDesktopSwitch() {
        refreshGeneration &+= 1
        fullRefreshCancellation?.cancel()
        fullRefreshCancellation = nil
        identityRefreshCancellation?.cancel()
        identityRefreshCancellation = nil
        engineQuotaCancellation?.cancel()
        engineQuotaCancellation = nil
        isRefreshing = false
        isRefreshingWarmUpProfiles = false
        refreshingProfileIDs.removeAll()
        warmUpRefreshStartedAt = nil
        hasPendingRefresh = false
        authRefreshWorkItem?.cancel()
        authRefreshWorkItem = nil
    }

    func requestDesktopSwitch(with profileID: String, status: HubAccountTaskStatus) {
        if status.isBusy {
            dismissAccountSwitchAlert()
            presentAccountSwitchBlock(
                status.blockingReason(WidgetLanguage.storedOrAutomatic())
                    ?? WidgetLanguage.storedOrAutomatic().text("账号占用尚未确认，请刷新任务状态后再试", "Account availability is unverified. Refresh task status and try again."),
                isAutomatic: false)
            return
        }
        launchCodex(with: profileID)
    }

    private func reserveDesktopSwitchMaintenance(for profileID: String) async -> Bool {
        guard desktopSwitchMaintenanceLeases.isEmpty,
            let target = profiles.first(where: { $0.id == profileID }),
            let source = profiles.first(where: \.isSystemProfile)
        else {
            presentAccountSwitchBlock(
                WidgetLanguage.storedOrAutomatic().text(
                    "切换准备未完成：账号记录缺失或上次维护尚未结束", "Switch preparation is unavailable: account records or unfinished maintenance need attention."),
                isAutomatic: automaticSwitchTargetID == profileID)
            return false
        }
        let accounts = target.recordedAccountKey == source.recordedAccountKey ? [target] : [source, target]
        let mappings = accounts.map { profile -> (account: String, alias: String, hubAlias: String?) in
            let managed = profiles.first { !$0.isSystemProfile && $0.recordedAccountKey == profile.recordedAccountKey }
            let alias = configuredHubAccountAlias(for: managed ?? profile)
            return (profile.recordedAccountKey, alias ?? "desktop-\(DispatchActivityStore.hash(profile.recordedAccountKey))", alias)
        }
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在检查账号占用…", "Checking account availability…")
        do {
            desktopSwitchMaintenanceLeases = try DispatchActivityStore.live.reserveMaintenance(accounts: mappings.map { ($0.account, $0.alias) })
        } catch {
            presentAccountSwitchBlock(
                WidgetLanguage.storedOrAutomatic().text(
                    "源账号或目标账号仍有任务占用，或占用记录无法读取；当前账号未改变", "The source or target account is occupied, or its reservation cannot be read. The account is unchanged."),
                isAutomatic: automaticSwitchTargetID == profileID)
            return false
        }
        // Standalone installations need no Hub. Configured accounts use the
        // same authoritative busy check as login, terminal launch and warm-up.
        for (index, mapping) in mappings.enumerated() {
            guard !Task.isCancelled else { return false }
            if let alias = mapping.hubAlias {
                let lease = desktopSwitchMaintenanceLeases[index]
                guard await HubConsoleModel.warmUpAvailability(for: alias, excludingLocalLease: lease) == .idle else {
                    if !Task.isCancelled {
                        presentAccountSwitchBlock(
                            WidgetLanguage.storedOrAutomatic().text(
                                "账号有任务或任务服务未连接，暂不能确认占用；当前账号未改变", "The account is busy or the task service is disconnected. Availability is unverified; the account is unchanged."),
                            isAutomatic: automaticSwitchTargetID == profileID)
                    }
                    return false
                }
            }
        }
        return !Task.isCancelled
    }

    private func finishDesktopSwitchMaintenance() {
        guard !desktopSwitchMaintenanceLeases.isEmpty, CodexAccountActions.switchRecoveryIsClear() else { return }
        let leases = desktopSwitchMaintenanceLeases
        desktopSwitchMaintenanceLeases = []
        for lease in leases { finishAccountMaintenance(lease, succeeded: desktopSwitchSucceeded) }
    }

    func cancelDesktopSwitchPreparation() {
        guard canCancelDesktopSwitch, !isAccountSwitchTransactionActive else { return }
        desktopSwitchPreparationTask?.cancel()
        finishDesktopSwitchPreparation()
        isLaunchingCodex = false
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已取消切换，当前账号未改变", "Switch cancelled. The current account is unchanged.")
    }

    private func finishDesktopSwitchPreparation() {
        desktopSwitchPreparationTask = nil
        canCancelDesktopSwitch = false
    }

    private func beginCodexSwitch(with profileID: String, forceWithoutSessionRestore: Bool, visibleThreadID: String?) {
        var startedVerification = false
        defer { if !startedVerification { isLaunchingCodex = false } }
        let isAutomaticSwitch = automaticSwitchTargetID == profileID
        let isForcedManualSwitch = CodexManualAccountSwitchPolicy.isForcedManualSwitch(
            isAutomaticSwitch: isAutomaticSwitch,
            userConfirmedForce: forceWithoutSessionRestore
        )
        if !isAutomaticSwitch { dismissAccountSwitchAlert() }
        guard warmingProfileID == nil else {
            presentAccountSwitchBlock(
                WidgetLanguage.storedOrAutomatic().text("账号暖号正在执行；完成后再切换", "Wait for warm-up to finish before switching accounts."), isAutomatic: isAutomaticSwitch)
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("账号暖号尚未完成", "Account warm-up is still in progress.")
            )
            return
        }
        guard !isLoggingIn,
            !isAutomaticSwitch || (!isRefreshing && !isRefreshingWarmUpProfiles)
        else {
            presentAccountSwitchBlock(
                WidgetLanguage.storedOrAutomatic().text("账号数据仍在读取；完成后再切换", "Wait for account data to finish loading before switching."), isAutomatic: isAutomaticSwitch)
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("账号数据读取尚未完成", "Account data is still loading.")
            )
            return
        }
        guard let profile = profiles.first(where: { $0.id == profileID }),
            let systemProfile = profiles.first(where: \.isSystemProfile)
        else {
            presentAccountSwitchBlock(WidgetLanguage.storedOrAutomatic().text("启动前置校验未通过；请刷新后再试", "Launch checks failed. Refresh and try again."), isAutomatic: isAutomaticSwitch)
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("启动前置条件未通过", "Launch prerequisites were not met.")
            )
            return
        }
        let legacyManagerRunning =
            !NSRunningApplication
            .runningApplications(withBundleIdentifier: "local.codex.account-manager")
            .isEmpty
        let taskBoardForRestore = snapshot.taskBoard
        let codexWasRunning =
            !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.openai.codex")
            .isEmpty
        if CodexManualAccountSwitchPolicy.requiresForceConfirmation(
            codexWasRunning: codexWasRunning,
            isAutomaticSwitch: isAutomaticSwitch,
            isForcedManualSwitch: isForcedManualSwitch,
            canPreserveSession: visibleThreadID != nil
                && CodexAutomaticSwitchPolicy.hasNoActiveTasks(codexLiveTasks, legacyManagerRunning: legacyManagerRunning)
        ) {
            forcedAccountSwitchProfileID = profileID
            presentAccountSwitchBlock(
                WidgetLanguage.storedOrAutomatic().text(
                    "请先确认所有 Codex 对话都已关闭、没有任务正在运行。强制切换将不恢复当前对话，是否继续？",
                    "First close all Codex conversations and confirm no tasks are running. A forced switch will not restore the current conversation. Continue?"),
                isAutomatic: false
            )
            return
        }
        let threadIDToRestore: String?
        if codexWasRunning, !isForcedManualSwitch {
            threadIDToRestore =
                visibleThreadID
                ?? recentForegroundCodexThreadID(in: taskBoardForRestore)
        } else {
            threadIDToRestore = nil
        }
        guard isForcedManualSwitch || !codexWasRunning || threadIDToRestore != nil else {
            let message: String
            if isAutomaticSwitch {
                message = WidgetLanguage.storedOrAutomatic().text(
                    "自动切换已暂停：无法确认当前对话，Codex 保持原账号", "Automatic switching paused: the current conversation could not be verified. Codex remains on the original account.")
            } else {
                forcedAccountSwitchProfileID = profileID
                message = WidgetLanguage.storedOrAutomatic().text(
                    "无法确认当前 Codex 对话。请先确认所有 Codex 对话都已关闭、没有任务正在运行。强制切换将不恢复当前对话，是否继续？",
                    "The current Codex conversation could not be verified. Close all conversations and confirm no tasks are running. A forced switch will not restore the current conversation. Continue?"
                )
            }
            presentAccountSwitchBlock(message, isAutomatic: isAutomaticSwitch)
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("当前可见对话无法精确识别", "The visible conversation could not be identified reliably.")
            )
            return
        }
        guard !isAutomaticSwitch || !codexWasRunning || visibleThreadID != nil else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "自动切换已暂停：无法确认当前对话的恢复位置", "Automatic switching paused: the current conversation cannot be restored reliably.")
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .appBusy,
                detail: WidgetLanguage.storedOrAutomatic().text("Codex 仍在运行，无法自动确认界面历史", "Codex is running; conversation history cannot be confirmed automatically.")
            )
            return
        }
        let isWithinAutomaticSwitchScope =
            automaticSwitchParticipation(for: profileID)
            && automaticSwitchContext.map {
                automaticSwitchParticipation(for: $0.sourceProfileID)
            } == true
        guard !isAutomaticSwitch || isWithinAutomaticSwitchScope else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("自动切换已取消：账号已被排除自动切换范围", "Automatic switching cancelled: the account is no longer opted in.")
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("源账号或目标账号已被排除自动切换范围", "The source or target account is no longer opted in.")
            )
            return
        }
        if isAutomaticSwitch { taskClient.refreshThreads() }
        guard
            !isAutomaticSwitch
                || CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                    codexLiveTasks,
                    legacyManagerRunning: legacyManagerRunning
                )
        else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "自动切换已暂停：当前仍有活跃或无法确认的 Codex 任务", "Automatic switching paused: a Codex task is active or its status is unverified.")
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .appBusy,
                detail: WidgetLanguage.storedOrAutomatic().text("任务安全状态未通过", "Task safety checks did not pass.")
            )
            return
        }
        let targetCredentialHome =
            profileStore.effectiveCredentialHome(for: profile.id)
            ?? profile.codexHomeURL
        startedVerification = true
        accountManagerMessage =
            isAutomaticSwitch
            ? WidgetLanguage.storedOrAutomatic().text(
                "安全自动切换：正在验证 \(AccountDisplay.profileName(profile))…", "Safe automatic switch: verifying \(AccountDisplay.profileName(profile))…")
            : WidgetLanguage.storedOrAutomatic().text("正在验证 \(AccountDisplay.profileName(profile))…", "Verifying \(AccountDisplay.profileName(profile))…")
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let historyBaselineResult = threadIDToRestore.map {
                CodexThreadHistoryProbe.capture(threadID: $0)
            }
            let context = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: targetCredentialHome
            )
            let systemContext = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: systemProfile.codexHomeURL
            )
            let verified =
                isAutomaticSwitch
                ? CodexSwitchPreparation.load(source: systemContext, target: context)
                : (
                    source: CodexSwitchSnapshotProjection.manualSnapshot(home: systemProfile.codexHomeURL, saved: systemProfile.lastSnapshot),
                    target: CodexSwitchSnapshotProjection.manualSnapshot(home: targetCredentialHome, saved: profile.lastSnapshot)
                )
            let verifiedSnapshot = verified.target
            let currentSystemSnapshot = verified.source
            let verifiedOfficialProfile = profile.officialProfile
            let currentSystemOfficialProfile = systemProfile.officialProfile
            let targetCredentialIdentity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: targetCredentialHome)
            let currentSystemCredentialIdentity = CodexOfficialProfileReader.credentialIdentity(
                codexHomeURL: systemProfile.codexHomeURL
            )
            DispatchQueue.main.async {
                var historyBaseline: CodexThreadHistorySnapshot?
                if let historyBaselineResult {
                    switch historyBaselineResult {
                    case .success(let snapshot):
                        historyBaseline = snapshot
                    case .failure(let error):
                        self.isLaunchingCodex = false
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "分页历史预检失败；没有切换账号：\(error.localizedDescription)", "History preflight failed. The account was not switched: \(error.localizedDescription)")
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: false,
                            failureReason: .validationFailed,
                            detail: WidgetLanguage.storedOrAutomatic().text("分页历史预检失败", "History preflight failed.")
                        )
                        return
                    }
                }
                guard let currentSystemCredentialIdentity, let targetCredentialIdentity,
                    let verifiedAccount = verifiedSnapshot.account,
                    let verifiedEmail = verifiedAccount.email?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(),
                    let currentSystemEmail = currentSystemSnapshot.account?.email?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(),
                    targetCredentialIdentity.email == verifiedEmail,
                    currentSystemCredentialIdentity.email == currentSystemEmail,
                    !isAutomaticSwitch
                        || (currentSystemEmail == systemProfile.recordedAccountKey
                            && systemProfile.matchesRecordedCredential(currentSystemCredentialIdentity))
                else {
                    self.isLaunchingCodex = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "账号验证失败；没有切换 Codex，原账号未受影响", "Account verification failed. Codex was not switched; the original account is unchanged.")
                    self.finishAutomaticSwitchAttempt(
                        for: profileID,
                        succeeded: false,
                        failureReason: .validationFailed,
                        detail: WidgetLanguage.storedOrAutomatic().text("目标或当前账号官方身份不可用", "The current or target account identity could not be verified.")
                    )
                    return
                }
                guard
                    profile.isSystemProfile
                        || (profile.matchesRecordedAccount(email: verifiedAccount.email)
                            && profile.matchesRecordedCredential(targetCredentialIdentity))
                else {
                    self.isLaunchingCodex = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "账号身份与已保存记录不一致；没有切换 Codex", "Account identity does not match the saved profile. Codex was not switched.")
                    self.finishAutomaticSwitchAttempt(
                        for: profileID,
                        succeeded: false,
                        failureReason: .validationFailed,
                        detail: WidgetLanguage.storedOrAutomatic().text("目标账号身份与账号卡不一致", "The target identity does not match the account profile.")
                    )
                    return
                }
                if isAutomaticSwitch {
                    self.taskClient.refreshThreads()
                    let preflightNow = Date()
                    let currentEmail = currentSystemSnapshot.account?.email?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let quotaAge = preflightNow.timeIntervalSince(currentSystemSnapshot.refreshedAt)
                    let currentQuota = AutomaticSwitchQuotaState(snapshot: currentSystemSnapshot)
                    let triggeredWindows = currentQuota.triggeredWindows(thresholds: self.lowQuotaAlertThresholds)
                    let targetQuotaAge = preflightNow.timeIntervalSince(verifiedSnapshot.refreshedAt)
                    let targetIsEligible =
                        CodexAutomaticSwitchPolicy.preferredCandidate(
                            [.init(profileID: profile.id, quota: AutomaticSwitchQuotaState(snapshot: verifiedSnapshot))],
                            for: triggeredWindows
                        ) != nil
                    let legacyManagerRunning =
                        !NSRunningApplication
                        .runningApplications(withBundleIdentifier: "local.codex.account-manager")
                        .isEmpty
                    guard let context = self.automaticSwitchContext,
                        let completeTasks = context.completeTasks,
                        !profile.isSystemProfile,
                        context.thresholds == self.lowQuotaAlertThresholds,
                        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty || threadIDToRestore != nil,
                        self.automaticAccountSwitchEnabled,
                        self.automaticSwitchParticipation(for: profileID),
                        self.automaticSwitchParticipation(for: context.sourceProfileID),
                        self.profiles.first(where: \.isSystemProfile)?.lastSnapshot?.accountID == context.sourceAccountID,
                        currentEmail == context.sourceIdentityKey,
                        currentSystemCredentialIdentity.accountID == context.sourceAccountID,
                        (try? self.accountActions.currentSystemAuthFingerprint(
                            expectedEmail: context.sourceIdentityKey,
                            expectedAccountID: context.sourceAccountID)) == context.sourceAuthFingerprint,
                        targetCredentialIdentity.accountID == profile.lastSnapshot?.accountID,
                        currentQuota.fiveHourRemaining != nil,
                        currentQuota.sevenDayRemaining != nil,
                        (systemProfile.lastQuotaReadFailureAt ?? .distantPast) < currentSystemSnapshot.refreshedAt,
                        (profile.lastQuotaReadFailureAt ?? .distantPast) < verifiedSnapshot.refreshedAt,
                        currentSystemSnapshot.quotaReadSucceeded,
                        verifiedSnapshot.quotaReadSucceeded,
                        quotaAge >= -5,
                        quotaAge <= CodexAutomaticSwitchPolicy.quotaSnapshotMaximumAge,
                        targetQuotaAge >= -5,
                        targetQuotaAge <= CodexAutomaticSwitchPolicy.quotaSnapshotMaximumAge,
                        !triggeredWindows.isEmpty,
                        targetIsEligible,
                        CodexAutomaticSwitchPolicy.hasSafeTaskState(
                            completeTasks,
                            codexInactiveSince: self.codexInactiveSince,
                            legacyManagerRunning: legacyManagerRunning,
                            now: preflightNow
                        ),
                        CodexAutomaticSwitchPolicy.hasSafeTaskState(
                            self.codexLiveTasks,
                            codexInactiveSince: self.codexInactiveSince,
                            legacyManagerRunning: legacyManagerRunning,
                            now: preflightNow
                        )
                    else {
                        self.isLaunchingCodex = false
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "自动切换已取消：最终身份、额度、任务或前台条件不再安全", "Automatic switching cancelled: final identity, limit, task or foreground checks no longer pass.")
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: false,
                            failureReason: .validationFailed,
                            detail: WidgetLanguage.storedOrAutomatic().text("最终安全预检未通过", "Final safety checks did not pass.")
                        )
                        return
                    }
                }
                var sourceBackupProfile: CodexProfile?
                do {
                    if isAutomaticSwitch || !systemProfile.matchesRecordedCredential(currentSystemCredentialIdentity) {
                        try self.profileStore.record(
                            currentSystemSnapshot, for: systemProfile.id,
                            allowAccountOnly: true, allowSystemAccountChange: true)
                    }
                    let currentEmail = currentSystemSnapshot.account?.email?.lowercased()
                    if currentSystemCredentialIdentity.accountID != targetCredentialIdentity.accountID {
                        sourceBackupProfile = try self.profileStore.preserveSystemLogin(
                            expectedEmail: currentEmail,
                            expectedAccountID: currentSystemCredentialIdentity.accountID
                        )
                    }
                    if isAutomaticSwitch {
                        try self.profileStore.record(
                            verifiedSnapshot, for: profile.id,
                            allowSystemAccountChange: profile.isSystemProfile)
                    }
                    self.syncProfiles()
                } catch {
                    self.isLaunchingCodex = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "启动前保存失败：\(error.localizedDescription)", "Could not save state before launch: \(error.localizedDescription)")
                    self.finishAutomaticSwitchAttempt(
                        for: profileID,
                        succeeded: false,
                        failureReason: .validationFailed,
                        detail: error.localizedDescription
                    )
                    return
                }
                let launchProfile = self.profiles.first(where: { $0.id == profile.id }) ?? profile
                self.accountManagerMessage =
                    isAutomaticSwitch
                    ? WidgetLanguage.storedOrAutomatic().text(
                        "安全自动切换：正在切换到 \(AccountDisplay.profileName(profile))…", "Safe automatic switch: switching to \(AccountDisplay.profileName(profile))…")
                    : WidgetLanguage.storedOrAutomatic().text("正在切换到 \(AccountDisplay.profileName(profile))…", "Switching to \(AccountDisplay.profileName(profile))…")
                let legacyManagerRunning =
                    !NSRunningApplication
                    .runningApplications(withBundleIdentifier: "local.codex.account-manager")
                    .isEmpty
                let requiresCodexRestart = targetCredentialIdentity != currentSystemCredentialIdentity
                if !isForcedManualSwitch, requiresCodexRestart {
                    self.taskClient.refreshThreads()
                }
                do {
                    let activeRecords = self.codexLiveTasks.records.values.filter {
                        $0.state == .running || $0.state == .waitingInput
                            || $0.state == .recorded || $0.state == .disconnected
                    }
                    debugLog(
                        "switch timing: guard mode=\(self.codexLiveTasks.connectionMode) "
                            + "age=\(Int(Date().timeIntervalSince(self.codexLiveTasks.refreshedAt)))s "
                            + "active=\(activeRecords.count) "
                            + "states=" + activeRecords.map { "\($0.state)" }.sorted().joined(separator: ",")
                    )
                }
                guard
                    isForcedManualSwitch
                        || !requiresCodexRestart
                        || CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                            self.codexLiveTasks,
                            legacyManagerRunning: legacyManagerRunning
                        )
                else {
                    self.isLaunchingCodex = false
                    let message =
                        isAutomaticSwitch
                        ? WidgetLanguage.storedOrAutomatic().text(
                            "自动切换已取消：写入前检测到活跃或无法确认的任务", "Automatic switching cancelled: an active or unverified task was detected before writing.")
                        : WidgetLanguage.storedOrAutomatic().text(
                            "没有切换：当前对话仍在执行，请等待本轮完成后再点“切换并打开”", "Not switched: the current turn is still running. Wait for it to finish, then choose Switch Desktop.")
                    self.presentAccountSwitchBlock(message, isAutomatic: isAutomaticSwitch)
                    self.finishAutomaticSwitchAttempt(
                        for: profileID,
                        succeeded: false,
                        failureReason: .appBusy,
                        detail: WidgetLanguage.storedOrAutomatic().text("写入前任务安全状态发生变化", "Task safety status changed before writing.")
                    )
                    return
                }
                if isAutomaticSwitch {
                    guard let context = self.automaticSwitchContext,
                        let completeTasks = context.completeTasks,
                        context.thresholds == self.lowQuotaAlertThresholds,
                        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty || threadIDToRestore != nil,
                        self.automaticAccountSwitchEnabled,
                        self.automaticSwitchParticipation(for: profileID),
                        self.automaticSwitchParticipation(for: context.sourceProfileID),
                        CodexAutomaticSwitchPolicy.hasSafeTaskState(
                            completeTasks,
                            codexInactiveSince: self.codexInactiveSince,
                            legacyManagerRunning: legacyManagerRunning
                        ),
                        CodexAutomaticSwitchPolicy.hasSafeTaskState(
                            self.codexLiveTasks,
                            codexInactiveSince: self.codexInactiveSince,
                            legacyManagerRunning: legacyManagerRunning
                        )
                    else {
                        self.isLaunchingCodex = false
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "自动切换已取消：写入前任务或前台条件发生变化", "Automatic switching cancelled: task or foreground conditions changed before writing.")
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: false,
                            failureReason: .appBusy,
                            detail: WidgetLanguage.storedOrAutomatic().text("写入前安全状态发生变化", "Safety conditions changed before writing.")
                        )
                        return
                    }
                }
                let transactionGeneration = self.beginAccountSwitchTransaction()
                self.accountActions.launchCodex(
                    profile: launchProfile,
                    sourceBackupProfile: sourceBackupProfile,
                    expectedSourceIdentity: currentSystemCredentialIdentity,
                    retainRecoveryJournal: requiresCodexRestart && historyBaseline != nil,
                    allowForcedTermination: isForcedManualSwitch,
                    progress: { [weak self] message in
                        guard let self, self.isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
                        self.accountManagerMessage = message
                    }
                ) { [weak self] error in
                    guard let self, self.isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
                    self.taskClient.start(reason: .startup)
                    self.taskClient.refreshThreads()
                    self.configureAuthMonitoring()
                    if let error {
                        do {
                            try self.profileStore.selectLaunch(systemProfile.id)
                            self.syncProfiles()
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "账号切换失败，启动账号已回滚：\(error.localizedDescription)", "Account switch failed; the launch account was restored: \(error.localizedDescription)")
                        } catch {
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "账号切换失败，且启动账号回滚失败：\(error.localizedDescription)",
                                "Account switch failed and the launch account could not be restored: \(error.localizedDescription)")
                        }
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: false,
                            failureReason: .restartFailed,
                            detail: error.localizedDescription
                        )
                        self.synchronizeMonitorWithCurrentCodex(announce: true)
                        guard let threadIDToRestore, let historyBaseline else {
                            self.finishAccountSwitchTransaction()
                            self.isLaunchingCodex = false
                            return
                        }
                        let failureMessage =
                            self.accountManagerMessage ?? WidgetLanguage.storedOrAutomatic().text("账号切换失败，原账号已恢复", "Account switch failed. The original account was restored.")
                        self.verifyRestoredTaskMetadata(
                            threadID: threadIDToRestore,
                            baseline: historyBaseline,
                            transactionGeneration: transactionGeneration
                        ) { [weak self] verified in
                            guard let self, self.isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
                            self.finishAccountSwitchTransaction()
                            self.isLaunchingCodex = false
                            self.accountManagerMessage =
                                verified
                                ? WidgetLanguage.storedOrAutomatic().text(
                                    "\(failureMessage)；原任务深链已请求，分页数据已确认", "\(failureMessage) The original task was requested and its paginated history verified.")
                                : WidgetLanguage.storedOrAutomatic().text(
                                    "\(failureMessage)；原任务仍在本机，但深链或分页数据未确认", "\(failureMessage) The original task remains local, but its link or paginated history is unverified.")
                        }
                        return
                    }

                    do {
                        try self.profileStore.record(
                            verifiedSnapshot,
                            for: systemProfile.id,
                            allowAccountOnly: true,
                            allowSystemAccountChange: true
                        )
                        if let verifiedOfficialProfile {
                            try self.profileStore.recordOfficialProfile(verifiedOfficialProfile, for: systemProfile.id)
                        }
                        try self.profileStore.syncSystemAuthToMatchingManagedProfiles()
                        try self.profileStore.selectLaunch(profile.id)
                        try self.profileStore.selectMonitor(profile.id)
                        self.syncProfiles()
                        self.configureAuthMonitoring()
                        self.clearDisplayedAccount()
                    } catch {
                        self.rollbackManualSwitch(
                            reason: WidgetLanguage.storedOrAutomatic().text(
                                "账号状态保存失败：\(error.localizedDescription)", "Could not save account state: \(error.localizedDescription)"),
                            attemptedProfileID: profileID,
                            targetProfile: launchProfile,
                            rollbackProfile: sourceBackupProfile,
                            systemProfile: systemProfile,
                            originalSnapshot: currentSystemSnapshot,
                            originalOfficialProfile: currentSystemOfficialProfile,
                            threadID: threadIDToRestore,
                            taskBoard: taskBoardForRestore,
                            historyBaseline: historyBaseline,
                            recoverPendingSwitch: requiresCodexRestart && historyBaseline != nil,
                            expectedCurrentIdentity: targetCredentialIdentity,
                            transactionGeneration: transactionGeneration
                        )
                        return
                    }

                    guard requiresCodexRestart,
                        let threadIDToRestore,
                        let historyBaseline
                    else {
                        self.desktopSwitchSucceeded = true
                        self.finishAccountSwitchTransaction()
                        self.isLaunchingCodex = false
                        self.accountManagerMessage =
                            isAutomaticSwitch
                            ? WidgetLanguage.storedOrAutomatic().text("安全自动切换已完成，Codex 已重新打开", "Safe automatic switch complete. Codex reopened.")
                            : (requiresCodexRestart
                                ? WidgetLanguage.storedOrAutomatic().text("已切换账号并重新打开 Codex，额度随后刷新", "Account switched and Codex reopened. Limits refresh next.")
                                : WidgetLanguage.storedOrAutomatic().text("已核对本机登录为此账号，Codex 已打开；额度随后刷新", "Local sign-in matches this account. Codex is open; limits refresh next."))
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: true,
                            detail: WidgetLanguage.storedOrAutomatic().text("登录凭据、Codex 重启与账号状态均已确认", "Sign-in, Codex restart and account state verified.")
                        )
                        self.refresh(queueIfBusy: true)
                        return
                    }

                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已切换账号，正在验证原任务恢复", "Account switched. Verifying that the original task was restored.")
                    self.restoreManualTaskOrRollback(
                        threadID: threadIDToRestore,
                        taskBoard: taskBoardForRestore,
                        historyBaseline: historyBaseline,
                        attemptedProfileID: profileID,
                        targetProfile: launchProfile,
                        rollbackProfile: sourceBackupProfile,
                        systemProfile: systemProfile,
                        originalSnapshot: currentSystemSnapshot,
                        originalOfficialProfile: currentSystemOfficialProfile,
                        transactionGeneration: transactionGeneration
                    )
                }
            }
        }
    }

    private func restoreManualTaskOrRollback(
        threadID: String,
        taskBoard: TaskBoard?,
        historyBaseline: CodexThreadHistorySnapshot,
        attemptedProfileID: String,
        targetProfile: CodexProfile,
        rollbackProfile: CodexProfile?,
        systemProfile: CodexProfile,
        originalSnapshot: UsageSnapshot,
        originalOfficialProfile: CodexOfficialProfileSnapshot?,
        transactionGeneration: UInt64
    ) {
        verifyRestoredTaskMetadata(
            threadID: threadID,
            baseline: historyBaseline,
            transactionGeneration: transactionGeneration
        ) { [weak self] verified in
            guard let self, self.isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
            guard verified else {
                self.rollbackManualSwitch(
                    reason: WidgetLanguage.storedOrAutomatic().text("未能请求打开原任务或确认分页历史", "Could not reopen the original task or verify its paginated history."),
                    attemptedProfileID: attemptedProfileID,
                    targetProfile: targetProfile,
                    rollbackProfile: rollbackProfile,
                    systemProfile: systemProfile,
                    originalSnapshot: originalSnapshot,
                    originalOfficialProfile: originalOfficialProfile,
                    threadID: threadID,
                    taskBoard: taskBoard,
                    historyBaseline: historyBaseline,
                    recoverPendingSwitch: true,
                    transactionGeneration: transactionGeneration
                )
                return
            }

            let isAutomaticSwitch = self.automaticSwitchTargetID == attemptedProfileID
            self.beginCodexHistoryConfirmation(
                isAutomaticSwitch: isAutomaticSwitch,
                onSuccess: { [weak self] in
                    guard let self, self.isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
                    self.accountManagerMessage =
                        isAutomaticSwitch
                        ? WidgetLanguage.storedOrAutomatic().text("任务恢复与分页历史核验通过，正在完成自动换号", "Task restoration and paginated history verified. Finalizing automatic switching.")
                        : WidgetLanguage.storedOrAutomatic().text("界面历史已确认，正在提交账号切换", "Conversation history confirmed. Finalizing the account switch.")
                    self.accountActions.commitPendingSwitch { [weak self] error in
                        guard let self, self.isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
                        if let error {
                            self.rollbackManualSwitch(
                                reason: WidgetLanguage.storedOrAutomatic().text(
                                    "账号切换提交失败：\(error.localizedDescription)", "Could not finalize the account switch: \(error.localizedDescription)"),
                                attemptedProfileID: attemptedProfileID,
                                targetProfile: targetProfile,
                                rollbackProfile: rollbackProfile,
                                systemProfile: systemProfile,
                                originalSnapshot: originalSnapshot,
                                originalOfficialProfile: originalOfficialProfile,
                                threadID: threadID,
                                taskBoard: taskBoard,
                                historyBaseline: historyBaseline,
                                recoverPendingSwitch: true,
                                transactionGeneration: transactionGeneration
                            )
                            return
                        }
                        self.desktopSwitchSucceeded = true
                        self.finishAccountSwitchTransaction()
                        self.isLaunchingCodex = false
                        self.accountManagerMessage =
                            isAutomaticSwitch
                            ? WidgetLanguage.storedOrAutomatic().text(
                                "自动换号已完成；已请求恢复原任务并核对分页历史", "Automatic switching complete. The original task was reopened and its paginated history verified.")
                            : WidgetLanguage.storedOrAutomatic().text(
                                "已切换账号；原任务窗口、分页数据和界面历史均已确认", "Account switched. The original task window, paginated data and visible history were verified.")
                        self.finishAutomaticSwitchAttempt(
                            for: attemptedProfileID,
                            succeeded: true,
                            detail: isAutomaticSwitch
                                ? WidgetLanguage.storedOrAutomatic().text("身份、重启、账号状态与分页历史核验通过", "Identity, restart, account state and paginated history verified.")
                                : WidgetLanguage.storedOrAutomatic().text(
                                    "登录凭据、Codex 重启、账号状态、分页数据与界面历史均已确认", "Sign-in, restart, account state, paginated data and visible history verified.")
                        )
                        self.refresh(queueIfBusy: true)
                    }
                },
                onFailure: { [weak self] reason in
                    self?.rollbackManualSwitch(
                        reason: reason,
                        attemptedProfileID: attemptedProfileID,
                        targetProfile: targetProfile,
                        rollbackProfile: rollbackProfile,
                        systemProfile: systemProfile,
                        originalSnapshot: originalSnapshot,
                        originalOfficialProfile: originalOfficialProfile,
                        threadID: threadID,
                        taskBoard: taskBoard,
                        historyBaseline: historyBaseline,
                        recoverPendingSwitch: true,
                        transactionGeneration: transactionGeneration
                    )
                }
            )
        }
    }

    private func verifyRestoredTaskMetadata(
        threadID: String,
        baseline: CodexThreadHistorySnapshot,
        transactionGeneration: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        guard isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
        let handle = CodexSessionOpener.requestRestore(threadID: threadID) { [weak self] routed in
            guard let self, self.isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
            self.pendingRestoreHandle = nil
            guard routed else {
                completion(false)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let verified: Bool
                switch CodexThreadHistoryProbe.capture(threadID: threadID) {
                case .success(let current): verified = current.matches(baseline)
                case .failure: verified = false
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
                    completion(verified)
                }
            }
        }
        if isCurrentAccountSwitchTransaction(transactionGeneration) {
            pendingRestoreHandle = handle
        } else {
            handle.cancel()
        }
    }

    private func beginCodexHistoryConfirmation(
        isAutomaticSwitch: Bool,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        clearCodexHistoryConfirmation()
        // The caller has already verified restoration and the complete paginated
        // history. Automatic mode commits this evidence; manual mode additionally
        // asks the user to inspect the visible history.
        if isAutomaticSwitch {
            onSuccess()
            return
        }
        codexHistoryConfirmationSuccess = onSuccess
        codexHistoryConfirmationFailure = onFailure
        isAwaitingCodexHistoryConfirmation = true
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
            "分页数据一致；请在 Codex 检查旧消息，再于 90 秒内确认", "Paginated history matches. Check older messages in Codex and confirm within 90 seconds.")
        let timeout = DispatchWorkItem { [weak self] in
            self?.resolveCodexHistoryConfirmation(
                succeeded: false,
                reason: WidgetLanguage.storedOrAutomatic().text("90 秒内未确认界面历史完整", "Conversation history was not confirmed within 90 seconds.")
            )
        }
        codexHistoryConfirmationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
    }

    func confirmRestoredCodexHistory() {
        resolveCodexHistoryConfirmation(succeeded: true, reason: "")
    }

    func rejectRestoredCodexHistory() {
        resolveCodexHistoryConfirmation(succeeded: false, reason: WidgetLanguage.storedOrAutomatic().text("用户确认界面历史不完整", "The user reported missing conversation history."))
    }

    private func resolveCodexHistoryConfirmation(succeeded: Bool, reason: String) {
        guard isAwaitingCodexHistoryConfirmation else { return }
        let success = codexHistoryConfirmationSuccess
        let failure = codexHistoryConfirmationFailure
        clearCodexHistoryConfirmation()
        succeeded ? success?() : failure?(reason)
    }

    private func clearCodexHistoryConfirmation() {
        codexHistoryConfirmationTimeout?.cancel()
        codexHistoryConfirmationTimeout = nil
        codexHistoryConfirmationSuccess = nil
        codexHistoryConfirmationFailure = nil
        isAwaitingCodexHistoryConfirmation = false
    }

    private func rollbackManualSwitch(
        reason: String,
        attemptedProfileID: String,
        targetProfile: CodexProfile,
        rollbackProfile: CodexProfile?,
        systemProfile: CodexProfile,
        originalSnapshot: UsageSnapshot,
        originalOfficialProfile: CodexOfficialProfileSnapshot?,
        threadID: String?,
        taskBoard: TaskBoard?,
        historyBaseline: CodexThreadHistorySnapshot?,
        recoverPendingSwitch: Bool,
        expectedCurrentIdentity: CodexCredentialIdentity? = nil,
        transactionGeneration: UInt64
    ) {
        guard isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
        guard let rollbackProfile else {
            finishAccountSwitchTransaction()
            isLaunchingCodex = false
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "严重：\(reason)，且没有可验证的原账号备份", "Critical: \(reason). No verifiable backup of the original account is available.")
            finishAutomaticSwitchAttempt(
                for: attemptedProfileID,
                succeeded: false,
                failureReason: .restartFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("\(reason)；缺少原账号备份", "\(reason). Original account backup is missing.")
            )
            return
        }

        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("\(reason)，正在安全回滚原账号", "\(reason). Safely restoring the original account.")
        let liveTargetProfile = profiles.first(where: { $0.id == targetProfile.id }) ?? targetProfile
        let liveRollbackProfile = profiles.first(where: { $0.id == rollbackProfile.id }) ?? rollbackProfile

        let finishRuntimeRollback: (Error?) -> Void = { [weak self] rollbackError in
            guard let self, self.isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
            if let rollbackError {
                self.finishAccountSwitchTransaction()
                self.isLaunchingCodex = false
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "严重：原任务未恢复，原账号回滚也失败：\(rollbackError.localizedDescription)",
                    "Critical: the original task and account could not be restored: \(rollbackError.localizedDescription)")
                self.finishAutomaticSwitchAttempt(
                    for: attemptedProfileID,
                    succeeded: false,
                    failureReason: .restartFailed,
                    detail: WidgetLanguage.storedOrAutomatic().text("任务恢复失败且账号回滚失败", "Task restoration and account rollback both failed.")
                )
                self.synchronizeMonitorWithCurrentCodex(announce: true)
                return
            }

            var stateSaveError: Error?
            do {
                try self.profileStore.record(
                    originalSnapshot,
                    for: systemProfile.id,
                    allowAccountOnly: true,
                    allowSystemAccountChange: true
                )
                if let originalOfficialProfile {
                    try self.profileStore.recordOfficialProfile(originalOfficialProfile, for: systemProfile.id)
                }
                try self.profileStore.syncSystemAuthToMatchingManagedProfiles()
                try self.profileStore.selectLaunch(liveRollbackProfile.id)
                try self.profileStore.selectMonitor(liveRollbackProfile.id)
                self.syncProfiles()
                self.configureAuthMonitoring()
                self.clearDisplayedAccount()
            } catch {
                stateSaveError = error
            }

            self.taskClient.start(reason: .startup)
            self.taskClient.refreshThreads()
            guard let threadID else {
                self.finishManualRollback(
                    attemptedProfileID: attemptedProfileID,
                    taskMetadataVerified: true,
                    stateSaveError: stateSaveError,
                    transactionGeneration: transactionGeneration
                )
                return
            }
            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已回滚原账号，正在恢复原任务", "Original account restored. Reopening the original task.")
            guard let historyBaseline else {
                self.finishManualRollback(
                    attemptedProfileID: attemptedProfileID,
                    taskMetadataVerified: false,
                    stateSaveError: stateSaveError,
                    transactionGeneration: transactionGeneration
                )
                return
            }
            self.verifyRestoredTaskMetadata(
                threadID: threadID,
                baseline: historyBaseline,
                transactionGeneration: transactionGeneration
            ) { [weak self] verified in
                self?.finishManualRollback(
                    attemptedProfileID: attemptedProfileID,
                    taskMetadataVerified: verified,
                    stateSaveError: stateSaveError,
                    transactionGeneration: transactionGeneration
                )
            }
        }

        if recoverPendingSwitch {
            accountActions.recoverPendingSwitchIfNeeded { outcome in
                switch outcome {
                case .success(.restoredOriginalAuth), .success(.originalAuthAlreadyPresent):
                    finishRuntimeRollback(nil)
                case .success(.noPendingSwitch), .success(.preservedExternalAuth):
                    finishRuntimeRollback(
                        NSError(
                            domain: "CodexAccountManagerNext.Switch",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text("恢复记录不可用于安全回滚", "The recovery record cannot be used for a safe rollback.")
                            ]
                        ))
                case .failure(let error):
                    finishRuntimeRollback(error)
                }
            }
        } else {
            guard let expectedCurrentIdentity else {
                finishRuntimeRollback(
                    NSError(
                        domain: "CodexAccountManagerNext.Switch", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text("回滚来源身份未验证，已取消操作", "Rollback source identity is unverified; no changes were made.")
                        ]))
                return
            }
            accountActions.launchCodex(
                profile: liveRollbackProfile,
                sourceBackupProfile: liveTargetProfile,
                expectedSourceIdentity: expectedCurrentIdentity,
                completion: finishRuntimeRollback
            )
        }
    }

    private func finishManualRollback(
        attemptedProfileID: String,
        taskMetadataVerified: Bool,
        stateSaveError: Error?,
        transactionGeneration: UInt64
    ) {
        guard isCurrentAccountSwitchTransaction(transactionGeneration) else { return }
        finishAccountSwitchTransaction()
        isLaunchingCodex = false
        if let stateSaveError {
            accountManagerMessage =
                taskMetadataVerified
                ? WidgetLanguage.storedOrAutomatic().text(
                    "已回滚原账号并确认原任务分页数据，但账号状态保存失败：\(stateSaveError.localizedDescription)",
                    "Original account and paginated task history restored, but account state could not be saved: \(stateSaveError.localizedDescription)")
                : WidgetLanguage.storedOrAutomatic().text(
                    "已回滚原账号，但原任务深链或分页数据未确认且状态保存失败：\(stateSaveError.localizedDescription)",
                    "Original account restored, but its task link or paginated history is unverified and state could not be saved: \(stateSaveError.localizedDescription)")
        } else {
            accountManagerMessage =
                taskMetadataVerified
                ? WidgetLanguage.storedOrAutomatic().text("切换未通过，已安全回滚原账号并确认原任务分页数据", "Switch checks failed. Original account safely restored and paginated task history verified.")
                : WidgetLanguage.storedOrAutomatic().text(
                    "已安全回滚原账号；原任务仍在本机，但深链或分页数据未确认", "Original account safely restored. The task remains local, but its link or paginated history is unverified.")
        }
        finishAutomaticSwitchAttempt(
            for: attemptedProfileID,
            succeeded: false,
            failureReason: .restartFailed,
            detail: taskMetadataVerified
                ? WidgetLanguage.storedOrAutomatic().text("切换未通过，已回滚原账号并确认任务分页数据", "Switch checks failed. Original account restored and task history verified.")
                : WidgetLanguage.storedOrAutomatic().text("已回滚原账号，但任务窗口或分页数据未确认", "Original account restored; the task window or paginated history remains unverified.")
        )
        refresh(queueIfBusy: true)
    }

    func setAutomaticAccountSwitchEnabled(_ enabled: Bool) {
        guard !pausedAutomationFeatures.contains(.lowQuota) else { return }
        guard automaticAccountSwitchEnabled != enabled else { return }
        automaticAccountSwitchEnabled = enabled
        if !isPreview { UserDefaults.standard.set(enabled, forKey: CodexAutomaticSwitchPolicy.enabledDefaultsKey) }
        guard !isPreview else { return }
        scheduleWarmUpMaintenanceTimer()
        if enabled {
            codexInactiveSince = nil
            updateCodexForegroundState()
            taskClient.start(reason: .startup)
            taskClient.refreshThreads()
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "自动换号已开启；低于额度阈值时核对备用账号，任务空闲后切换",
                "Automatic switching enabled. Below the quota threshold, verify a backup and switch when tasks are idle.")
            refresh(queueIfBusy: true)
            refreshWarmUpProfilesThenSchedule(performWarmUpAfterRefresh: false, quotaOnly: true)
        } else {
            if automaticSwitchTargetID != nil, canCancelDesktopSwitch { cancelDesktopSwitchPreparation() }
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("额度不足自动换号已关闭", "Automatic switching for low quota is off.")
        }
    }

    func setLowQuotaAlertThresholds(fiveHour: Int, sevenDay: Int) {
        let thresholds = LowQuotaAlertThresholds(fiveHour: fiveHour, sevenDay: sevenDay)
        guard thresholds != lowQuotaAlertThresholds else { return }
        lowQuotaAlertThresholds = thresholds
        if !isPreview { thresholds.save() }
    }

    var localNotificationAuthorizationReady: Bool {
        guard let state = localNotificationAuthorization, state.alertsEnabled else { return false }
        return state.status == .authorized || state.status == .provisional
    }

    var localNotificationUsesSystemSettings: Bool {
        guard let state = localNotificationAuthorization else { return false }
        return state.status != .notDetermined && state.status != .unknown
    }

    func configureLocalNotifications() {
        guard !isPreview, !pausedAutomationFeatures.contains(.localNotification) else { return }
        guard localNotificationUsesSystemSettings else {
            setLocalNotificationsEnabled(true)
            return
        }
        setLocalNotificationsEnabled(true, requestAuthorization: false)
        let destinations = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for destination in destinations {
            if let url = URL(string: destination), NSWorkspace.shared.open(url) { return }
        }
        localNotificationMessage = WidgetLanguage.storedOrAutomatic().text(
            "请打开系统设置 > 通知，选择 Next 并允许通知。", "Open System Settings > Notifications, choose Next, then allow notifications.")
    }

    var enabledSetupFeatureCount: Int {
        [
            warmUpSelection.fiveHour, warmUpSelection.sevenDay, automaticAccountSwitchEnabled,
            localNotificationsEnabled, feishuNotificationsEnabled, feishuQuotaResetEnabled, feishuResetCreditEnabled,
        ]
        .filter { $0 }.count
    }

    func enableAllSetupFeatures() {
        guard !isPreview else {
            warmUpSelection = .all
            automaticAccountSwitchEnabled = true
            localNotificationsEnabled = true
            feishuNotificationsEnabled = true
            feishuQuotaResetEnabled = true
            feishuResetCreditEnabled = true
            return
        }
        if !warmUpSelection.fiveHour { setWarmUpFiveHourEnabled(true) }
        if !warmUpSelection.sevenDay { setWarmUpSevenDayEnabled(true) }
        if !automaticAccountSwitchEnabled { setAutomaticAccountSwitchEnabled(true) }
        setLocalNotificationsEnabled(true, requestAuthorization: false)
        setFeishuNotificationsEnabled(true)
        setFeishuQuotaResetEnabled(true)
        setFeishuResetCreditEnabled(true)
    }

    func setLocalNotificationsEnabled(_ enabled: Bool, requestAuthorization: Bool = true) {
        guard !pausedAutomationFeatures.contains(.localNotification) else { return }
        localNotificationPermissionRequestID = nil
        isRequestingLocalNotificationPermission = false
        localNotificationsEnabled = enabled
        quotaEventTracker.reset()
        if hasStarted { scheduleWarmUpMaintenanceTimer() }
        if !isPreview { UserDefaults.standard.set(enabled, forKey: Self.localNotificationsEnabledKey) }
        if !enabled || isPreview || !requestAuthorization {
            localNotificationMessage =
                enabled
                ? WidgetLanguage.storedOrAutomatic().text("功能已开启；完成 macOS 授权后接收通知。", "Enabled. Allow macOS notifications to receive alerts.")
                : WidgetLanguage.storedOrAutomatic().text("系统通知已关闭", "System notifications are off.")
            if enabled { refreshLocalNotificationAuthorization() }
            return
        }
        let requestID = UUID()
        localNotificationPermissionRequestID = requestID
        isRequestingLocalNotificationPermission = true
        NextLocalNotificationService.shared.requestAlertAuthorization(userInitiated: true) { [weak self] result in
            guard let self, self.localNotificationPermissionRequestID == requestID else { return }
            self.localNotificationPermissionRequestID = nil
            self.isRequestingLocalNotificationPermission = false
            switch result {
            case .success(let state):
                self.localNotificationAuthorization = state
                self.localNotificationMessage = WidgetLanguage.storedOrAutomatic().text(
                    "系统通知已开启；额度与重置消息将提交给 macOS。", "System notifications are on. Limit and reset alerts will be submitted to macOS.")
            case .failure(let error):
                self.localNotificationMessage = self.localNotificationErrorMessage(error)
                self.refreshLocalNotificationAuthorization()
            }
        }
    }

    /// 手动刷新公告，并沿用自动检查的状态、通知与飞书投递流程。
    @MainActor
    func refreshResetAnnouncements() {
        publicResetAnnouncements.check()
    }

    func refreshLocalNotificationAuthorization() {
        guard !isPreview else { return }
        NextLocalNotificationService.shared.authorizationStatus { [weak self] state in
            guard let self, !self.isRequestingLocalNotificationPermission else { return }
            self.localNotificationAuthorization = state
            let language = WidgetLanguage.storedOrAutomatic()
            switch state.status {
            case .notDetermined:
                self.localNotificationMessage = language.text("等待 macOS 授权；点击“允许系统通知”完成设置。", "Waiting for macOS permission. Choose Allow notifications to continue.")
            case .denied:
                self.localNotificationMessage = language.text(
                    "macOS 未允许通知；可在系统设置的通知中开启 Next。", "Notifications are denied in macOS. Enable Next in System Settings > Notifications.")
            case .authorized, .provisional:
                self.localNotificationMessage =
                    state.alertsEnabled
                    ? language.text("macOS 已允许通知；是否发送仍由本页开关控制。", "macOS permits alerts. This switch controls whether Next sends them.")
                    : language.text("macOS 提醒样式已关闭，请在系统通知设置中调整。", "Alerts are disabled in macOS notification settings.")
            case .ephemeral, .unknown:
                self.localNotificationMessage = language.text("系统通知状态无法确认，暂不发送。", "System notification status is unverified. No notification will be sent.")
            }
        }
    }

    private func localNotificationErrorMessage(_ error: NextLocalNotificationService.ServiceError) -> String {
        let language = WidgetLanguage.storedOrAutomatic()
        switch error {
        case .authorizationDenied, .alertsDisabled:
            return language.text("macOS 未允许提醒；请在系统设置的通知中开启 Next。", "macOS alerts are disabled. Enable Next in System Settings > Notifications.")
        case .authorizationNotDetermined, .userInitiationRequired:
            return language.text("请点击“允许系统通知”完成 macOS 授权。", "Choose Allow notifications to complete macOS authorization.")
        case .invalidQuotaData:
            return language.text("额度数据尚未确认，本次未发送系统通知。", "Limits are unverified. No system notification was sent.")
        case .unsupportedAuthorizationStatus, .authorizationRequestFailed:
            return language.text("未能确认系统通知权限，请稍后重试。", "System notification permission could not be verified. Try again later.")
        case .notificationSubmissionFailed:
            return language.text("未能提交系统通知，请检查 macOS 通知设置。", "The notification could not be submitted. Check macOS notification settings.")
        }
    }

    private func sendLocalLowQuotaNotification(_ quota: AutomaticSwitchQuotaState) {
        guard !isPreview, localNotificationsEnabled else { return }
        NextLocalNotificationService.shared.submitLowQuotaNotification(
            fiveHourRemainingPercent: quota.fiveHourRemaining,
            sevenDayRemainingPercent: quota.sevenDayRemaining
        ) { [weak self] result in
            guard let self, self.localNotificationsEnabled else { return }
            switch result {
            case .success:
                self.localNotificationMessage = WidgetLanguage.storedOrAutomatic().text(
                    "通知已提交给 macOS；显示由系统通知与专注模式设置决定。", "Submitted to macOS. Notification and Focus settings control how it appears.")
            case .failure(let error):
                self.localNotificationMessage = self.localNotificationErrorMessage(error)
            }
        }
    }

    func setFeishuNotificationsEnabled(_ enabled: Bool) {
        guard !pausedAutomationFeatures.contains(.feishu) else { return }
        feishuConfigurationRevision += 1
        feishuTaskCompletionObserver = FeishuTaskCompletionObserver()
        feishuNotificationsEnabled = enabled
        if !isPreview { UserDefaults.standard.set(enabled, forKey: Self.feishuNotificationsEnabledKey) }
        quotaEventTracker.reset()
        scheduleWarmUpMaintenanceTimer()
        feishuNotificationMessage =
            enabled
            ? (feishuWebhookConfigured
                ? WidgetLanguage.storedOrAutomatic().text(
                    "已开启飞书通知；可分别选择额度重置和 Reset 卡提醒", "Feishu notifications enabled. Limit reset and new reset credit alerts can be selected separately.")
                : WidgetLanguage.storedOrAutomatic().text("功能已开启；保存飞书机器人地址后开始接收通知。", "Enabled. Save a Feishu bot webhook to receive notifications."))
            : WidgetLanguage.storedOrAutomatic().text("飞书推送已关闭", "Feishu notifications disabled.")
        if enabled, !feishuWebhookConfigured { refreshFeishuWebhookConfiguration() }
    }

    func setFeishuQuotaResetEnabled(_ enabled: Bool) {
        guard !pausedAutomationFeatures.contains(.feishu) else { return }
        feishuConfigurationRevision += 1
        feishuQuotaResetEnabled = enabled
        if !isPreview { UserDefaults.standard.set(enabled, forKey: Self.feishuQuotaResetEnabledKey) }
        quotaEventTracker.reset()
        scheduleWarmUpMaintenanceTimer()
    }

    func setFeishuResetCreditEnabled(_ enabled: Bool) {
        guard !pausedAutomationFeatures.contains(.feishu) else { return }
        feishuConfigurationRevision += 1
        feishuTaskCompletionObserver = FeishuTaskCompletionObserver()
        feishuResetCreditEnabled = enabled
        if !isPreview { UserDefaults.standard.set(enabled, forKey: Self.feishuResetCreditEnabledKey) }
        quotaEventTracker.reset()
        scheduleWarmUpMaintenanceTimer()
    }

    func setFeishuTaskCompletionNotificationsEnabled(_ enabled: Bool) {
        guard !pausedAutomationFeatures.contains(.feishu) else { return }
        feishuConfigurationRevision += 1
        feishuTaskCompletionObserver = FeishuTaskCompletionObserver()
        feishuTaskCompletionNotificationsEnabled = enabled
        if !isPreview { UserDefaults.standard.set(enabled, forKey: Self.feishuTaskCompletionEnabledKey) }
        if !enabled { feishuTaskCompletionObserver = FeishuTaskCompletionObserver() }
    }

    func setFeishuMessageOptions(_ options: FeishuMessageOptions) {
        guard !pausedAutomationFeatures.contains(.feishu) else { return }
        feishuMessageOptions = options
        guard !isPreview, let data = try? JSONEncoder().encode(options) else { return }
        UserDefaults.standard.set(data, forKey: Self.feishuMessageOptionsKey)
    }

    private static func loadFeishuMessageOptions() -> FeishuMessageOptions {
        guard let data = UserDefaults.standard.data(forKey: feishuMessageOptionsKey),
            let options = try? JSONDecoder().decode(FeishuMessageOptions.self, from: data)
        else { return .standard }
        return options
    }

    func creditBalancePresentation(for profile: CodexProfile) -> CreditBalancePresentation {
        // The profile store already applies identity verification and observation ordering.
        // A shared live snapshot has no account ID, so email alone cannot bind its balance.
        CreditBalancePresentation(
            balance: profile.lastSnapshot?.creditBalance,
            unlimited: profile.lastSnapshot?.creditBalanceUnlimited,
            source: .profileSnapshot,
            snapshotAt: profile.lastSnapshot?.fetchedAt
        )
    }

    private var observesOfficialQuotaEvents: Bool {
        localNotificationsEnabled
            || messageChannels.telegramEnabled || messageChannels.weChatEnabled
            || (feishuNotificationsEnabled && feishuWebhookConfigured
                && (feishuQuotaResetEnabled || feishuResetCreditEnabled))
    }

    private func refreshFeishuWebhookConfiguration() {
        guard !isPreview, !isUpdatingFeishuConnection else { return }
        feishuConfigurationRevision += 1
        feishuTaskCompletionObserver = FeishuTaskCompletionObserver()
        let revision = feishuConfigurationRevision
        feishuWebhookService.hasStoredWebhook { [weak self] result in
            guard let self, self.feishuConfigurationRevision == revision else { return }
            switch result {
            case .success(let configured):
                self.feishuWebhookConfigured = configured
                self.feishuNeedsAuthorization = false
            case .failure(let error):
                self.feishuWebhookConfigured = false
                self.handleFeishuCredentialFailure(error)
            }
            self.quotaEventTracker.reset()
            if self.hasStarted { self.scheduleWarmUpMaintenanceTimer() }
        }
    }

    func saveFeishuWebhook(_ value: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isPreview, !isUpdatingFeishuConnection else {
            completion(false)
            return
        }
        do {
            _ = try FeishuWebhookService.validatedWebhookURL(from: value)
        } catch {
            feishuNotificationMessage = error.localizedDescription
            completion(false)
            return
        }
        beginFeishuConnectionUpdate()
        feishuWebhookService.storeWebhook(value) { [weak self] result in
            guard let self else {
                completion(false)
                return
            }
            completion(self.finishFeishuConnectionUpdate(result))
        }
    }

    func authorizeFeishuConnection() {
        guard !isPreview, !isUpdatingFeishuConnection else { return }
        beginFeishuConnectionUpdate()
        feishuWebhookService.authorizeStoredWebhook { [weak self] result in
            _ = self?.finishFeishuConnectionUpdate(result)
        }
    }

    private func beginFeishuConnectionUpdate() {
        isUpdatingFeishuConnection = true
        feishuConfigurationRevision += 1
        feishuNotificationMessage = WidgetLanguage.storedOrAutomatic().text(
            "请在 macOS 系统弹窗中完成授权；无需在 Next 中输入电脑密码。",
            "Complete authorization in the macOS dialog. Never enter your Mac password in Next.")
    }

    private func finishFeishuConnectionUpdate(_ result: Result<Void, FeishuWebhookError>) -> Bool {
        isUpdatingFeishuConnection = false
        switch result {
        case .success:
            feishuWebhookConfigured = true
            feishuNeedsAuthorization = false
            feishuNotificationMessage = WidgetLanguage.storedOrAutomatic().text(
                "飞书已连接。后台检查不会弹出密码框。", "Feishu is connected. Background checks will not show password prompts.")
            quotaEventTracker.reset()
            if hasStarted { scheduleWarmUpMaintenanceTimer() }
            return true
        case .failure(let error):
            feishuWebhookConfigured = false
            handleFeishuCredentialFailure(error)
            return false
        }
    }

    static func feishuConnectionCompletionSelfTest(_ failedSave: Result<Void, FeishuWebhookError>) -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-feishu-connection-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 1, root: root)
        store.feishuWebhookConfigured = true
        store.beginFeishuConnectionUpdate()
        guard !store.finishFeishuConnectionUpdate(failedSave),
            !store.feishuWebhookConfigured, !store.isUpdatingFeishuConnection
        else { return false }
        // Only a failed connection operation clears readiness. A transport error
        // for an already confirmed connection must not require setup again.
        store.feishuWebhookConfigured = true
        store.handleFeishuCredentialFailure(.transportFailed)
        return store.feishuWebhookConfigured
    }

    private func handleFeishuCredentialFailure(_ error: FeishuWebhookError) {
        feishuNotificationMessage = error.localizedDescription
        switch error {
        case .keychainAuthorizationRequired, .keychainTimedOut, .keychainBusy:
            feishuWebhookConfigured = false
            feishuNeedsAuthorization = true
        case .missingWebhook:
            feishuWebhookConfigured = false
            feishuNeedsAuthorization = false
        default:
            break
        }
    }

    func removeFeishuWebhook() {
        guard !isPreview, !isUpdatingFeishuConnection else { return }
        beginFeishuConnectionUpdate()
        feishuWebhookService.removeStoredWebhook { [weak self] result in
            guard let self else { return }
            self.isUpdatingFeishuConnection = false
            switch result {
            case .success:
                self.feishuWebhookConfigured = false
                self.feishuNeedsAuthorization = false
                self.feishuNotificationsEnabled = false
                UserDefaults.standard.set(false, forKey: Self.feishuNotificationsEnabledKey)
                self.quotaEventTracker.reset()
                if self.hasStarted { self.scheduleWarmUpMaintenanceTimer() }
                self.feishuNotificationMessage = WidgetLanguage.storedOrAutomatic().text("飞书 Webhook 已移除", "Feishu webhook removed.")
            case .failure(let error):
                self.handleFeishuCredentialFailure(error)
            }
        }
    }

    func sendFeishuTestNotification() {
        guard feishuWebhookConfigured,
            let source = selectedMonitorProfile.flatMap(maskedAccount(for:))
        else {
            feishuNotificationMessage = WidgetLanguage.storedOrAutomatic().text("请先保存有效的飞书 Webhook", "Save a valid Feishu webhook first.")
            return
        }
        let quota = AutomaticSwitchQuotaState(snapshot: snapshot)
        sendFeishuNotification(
            event: .test,
            source: source,
            target: nil,
            quota: quota,
            factsSnapshot: snapshot,
            eventID: UUID(),
            isTest: true
        )
    }

    private func evaluateAutomaticAccountSwitch() {
        guard hasStarted,
            automaticAccountSwitchEnabled,
            automaticSwitchContext == nil,
            automaticSwitchTargetID == nil,
            !isAccountSwitchTransactionActive,
            desktopSwitchMaintenanceLeases.isEmpty,
            !isLoggingIn,
            !isLaunchingCodex,
            !isRefreshing,
            !isRefreshingWarmUpProfiles,
            warmingProfileID == nil,
            let systemProfile = profiles.first(where: \.isSystemProfile),
            let savedSource = systemProfile.lastSnapshot,
            let sourceIdentityEmail = savedSource.email,
            let sourceIdentityID = savedSource.accountID
        else { return }
        let sourceSnapshot = CodexSwitchSnapshotProjection.snapshot(
            saved: savedSource, identity: CodexCredentialIdentity(email: sourceIdentityEmail, accountID: sourceIdentityID))
        guard
            sourceSnapshot.quotaReadSucceeded,
            let sourceEmail = sourceSnapshot.account?.email?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !sourceEmail.isEmpty,
            let sourceProfile = profiles.first(where: { !$0.isSystemProfile && $0.lastSnapshot?.accountID == sourceIdentityID }) ?? profiles.first(where: \.isSystemProfile),
            let sourceAccountID = sourceProfile.lastSnapshot?.accountID,
            !sourceAccountID.isEmpty,
            systemProfile.lastSnapshot?.accountID == sourceAccountID,
            sourceProfile.recordedAccountKey == sourceEmail,
            systemProfile.recordedAccountKey == sourceEmail,
            automaticSwitchParticipation(for: sourceProfile)
        else { return }

        let now = Date()
        guard
            Self.automaticQuotaEvidenceIsFresh(
                succeeded: sourceSnapshot.quotaReadSucceeded,
                fetchedAt: sourceSnapshot.refreshedAt,
                failedAt: sourceProfile.lastQuotaReadFailureAt, now: now
            ),
            Self.automaticQuotaEvidenceIsFresh(
                succeeded: sourceProfile.lastSnapshot?.quotaReadSucceeded,
                fetchedAt: sourceProfile.lastSnapshot?.fetchedAt ?? .distantPast,
                failedAt: sourceProfile.lastQuotaReadFailureAt, now: now
            ),
            Self.automaticQuotaEvidenceIsFresh(
                succeeded: systemProfile.lastSnapshot?.quotaReadSucceeded,
                fetchedAt: systemProfile.lastSnapshot?.fetchedAt ?? .distantPast,
                failedAt: systemProfile.lastQuotaReadFailureAt, now: now
            )
        else { return }
        let defaults = UserDefaults.standard
        let sourceQuota = AutomaticSwitchQuotaState(snapshot: sourceSnapshot)
        let legacyManagerRunning =
            !NSRunningApplication
            .runningApplications(withBundleIdentifier: "local.codex.account-manager")
            .isEmpty
        guard
            CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: automaticAccountSwitchEnabled,
                sourceQuota: sourceQuota,
                sourceRefreshedAt: sourceSnapshot.refreshedAt,
                taskSnapshot: codexLiveTasks,
                codexInactiveSince: codexInactiveSince,
                legacyManagerRunning: legacyManagerRunning,
                lastAttemptAt: defaults.object(forKey: CodexAutomaticSwitchPolicy.lastAttemptDefaultsKey) as? Date,
                lastSucceededAt: defaults.object(forKey: CodexAutomaticSwitchPolicy.lastSuccessDefaultsKey) as? Date,
                thresholds: lowQuotaAlertThresholds,
                now: now
            )
        else { return }

        let candidates = profiles.filter { profile in
            !profile.isSystemProfile
                && automaticSwitchParticipation(for: profile)
                && profile.lastSnapshot?.accountID != sourceAccountID
                && profile.lastSnapshot?.email?.isEmpty == false
                && profile.lastSnapshot?.accountID?.isEmpty == false
                && FileManager.default.fileExists(
                    atPath: profile.codexHomeURL.appendingPathComponent("auth.json").path
                )
        }
        let staleCandidateIDs = Set(
            candidates.filter { profile in
                guard let snapshot = profile.lastSnapshot else { return true }
                return !Self.automaticQuotaEvidenceIsFresh(
                    succeeded: snapshot.quotaReadSucceeded, fetchedAt: snapshot.fetchedAt,
                    failedAt: profile.lastQuotaReadFailureAt, now: now)
            }.map(\.id))
        if !staleCandidateIDs.isEmpty,
            automaticCandidateRefreshAttemptAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true
        {
            automaticCandidateRefreshAttemptAt = now
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "额度不足，正在核对备用账号额度…", "Quota is low. Checking backup account limits…")
            refreshWarmUpProfilesThenSchedule(
                performWarmUpAfterRefresh: false,
                profileIDs: staleCandidateIDs.union([sourceProfile.id, systemProfile.id]),
                quotaOnly: true, refreshMembershipDates: false,
                completion: { [weak self] _ in
                    guard let self, self.automaticAccountSwitchEnabled else { return }
                    self.taskClient.refreshThreads()
                    self.evaluateAutomaticAccountSwitch()
                })
            return
        }
        let triggeredWindows = sourceQuota.triggeredWindows(thresholds: lowQuotaAlertThresholds)
        let preferred = CodexAutomaticSwitchPolicy.preferredCandidate(
            candidates.compactMap { profile in
                guard let snapshot = profile.lastSnapshot,
                    Self.automaticQuotaEvidenceIsFresh(
                        succeeded: snapshot.quotaReadSucceeded, fetchedAt: snapshot.fetchedAt,
                        failedAt: profile.lastQuotaReadFailureAt, now: now)
                else { return nil }
                return .init(
                    profileID: profile.id,
                    quota: AutomaticSwitchQuotaState(
                        fiveHourRemaining: snapshot.fiveHour.map { 100 - $0.usedPercent },
                        sevenDayRemaining: snapshot.sevenDay.map { 100 - $0.usedPercent }
                    )
                )
            },
            for: triggeredWindows
        )
        let recommendedProfile = preferred.flatMap { candidate in
            candidates.first(where: { $0.id == candidate.profileID })
        }
        // Failed candidate reads can retry after the bounded refresh backoff.
        // They do not consume the switch transaction's one-hour retry window.
        guard recommendedProfile != nil || staleCandidateIDs.isEmpty else { return }
        defaults.set(now, forKey: CodexAutomaticSwitchPolicy.lastAttemptDefaultsKey)
        let recommendedName =
            recommendedProfile.map {
                AccountDisplay.profileName($0, allProfiles: profiles)
            }
            ?? WidgetLanguage.storedOrAutomatic().text(
                "无合格候选：需新鲜且读取成功的完整额度、两个窗口可用、触发窗口至少 30%",
                "No eligible candidate: fresh successful complete limits, both windows available, and at least 30% in triggered windows are required.")
        let detail = WidgetLanguage.storedOrAutomatic().text(
            "额度低于阈值；候选账号：\(recommendedName)", "Usage limits are low. Candidate: \(recommendedName)")
        accountManagerMessage = detail
        sendLocalLowQuotaNotification(sourceQuota)
        if let source = maskedAccount(for: sourceProfile) {
            sendFeishuNotification(
                event: .lowQuotaDetected,
                source: source,
                target: recommendedProfile.flatMap(maskedAccount(for:)),
                quota: sourceQuota,
                factsSnapshot: sourceSnapshot,
                eventID: UUID()
            )
        }
        recordAutomationEvent(level: .warning, title: WidgetLanguage.storedOrAutomatic().text("低额度提醒", "Low-limit alert"), detail: detail)
        guard let target = recommendedProfile,
            let source = maskedAccount(for: sourceProfile),
            let targetAccount = maskedAccount(for: target)
        else { return }
        do {
            let fingerprint = try accountActions.currentSystemAuthFingerprint(
                expectedEmail: sourceEmail, expectedAccountID: sourceAccountID)
            automaticSwitchContext = AutomaticSwitchContext(
                sourceProfileID: sourceProfile.id, sourceIdentityKey: sourceEmail,
                sourceAccountID: sourceAccountID, sourceAuthFingerprint: fingerprint,
                sourceAccount: source, targetAccount: targetAccount, sourceQuota: sourceQuota,
                eventID: UUID(), thresholds: lowQuotaAlertThresholds, completeTasks: nil)
            automaticSwitchTargetID = target.id
            launchCodex(with: target.id)
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "自动切换已取消：当前身份无法验证", "Automatic switching cancelled: current identity could not be verified.")
        }
    }

    private func finishAutomaticSwitchAttempt(
        for profileID: String,
        succeeded: Bool,
        failureReason: FeishuSwitchNotification.FailureReason = .unknown,
        detail: String
    ) {
        guard automaticSwitchTargetID == profileID,
            let context = automaticSwitchContext
        else { return }
        automaticSwitchTargetID = nil
        automaticSwitchContext = nil
        if succeeded {
            UserDefaults.standard.set(Date(), forKey: CodexAutomaticSwitchPolicy.lastSuccessDefaultsKey)
            UserDefaults.standard.removeObject(forKey: CodexAutomaticSwitchPolicy.lastAttemptDefaultsKey)
            recordAutomationEvent(
                level: .success,
                title: WidgetLanguage.storedOrAutomatic().text("自动切换完成", "Automatic switch complete"),
                detail: "\(context.sourceAccount.value) → \(context.targetAccount.value) · \(detail)"
            )
            sendFeishuNotification(
                event: .switchSucceeded,
                source: context.sourceAccount,
                target: context.targetAccount,
                quota: context.sourceQuota,
                eventID: context.eventID,
                switchOrigin: .lowQuota
            )
        } else {
            recordAutomationEvent(
                level: .failure,
                title: WidgetLanguage.storedOrAutomatic().text("自动切换失败", "Automatic switch failed"),
                detail: "\(context.sourceAccount.value) · \(detail)"
            )
            sendFeishuNotification(
                event: .switchFailed(failureReason),
                source: context.sourceAccount,
                target: context.targetAccount,
                quota: context.sourceQuota,
                eventID: context.eventID,
                switchOrigin: .lowQuota
            )
        }
        taskClient.stop()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasStarted, self.automaticAccountSwitchEnabled else { return }
            self.taskClient.start(reason: .startup)
            self.taskClient.refreshThreads()
        }
    }

    private func sendFeishuNotification(
        event: FeishuSwitchNotification.Event,
        source: FeishuMaskedAccount,
        target: FeishuMaskedAccount?,
        quota: AutomaticSwitchQuotaState,
        factsSnapshot: UsageSnapshot? = nil,
        eventID: UUID,
        switchOrigin: FeishuSwitchNotification.SwitchOrigin = .manual,
        isTest: Bool = false
    ) {
        if !isTest, hasStarted {
            sendAdditionalChannelEvent(event, source: source, target: target, quota: quota, eventID: eventID)
        }
        guard isTest || feishuNotificationsEnabled, feishuWebhookConfigured, !isUpdatingFeishuConnection else { return }
        switch event {
        case .quotaChange(.quotaReset) where !feishuQuotaResetEnabled: return
        case .quotaChange(.resetCreditsAdded) where !feishuResetCreditEnabled: return
        default: break
        }
        do {
            let notification = try FeishuSwitchNotification(
                event: event,
                sourceAccount: source,
                targetAccount: target,
                switchOrigin: switchOrigin,
                triggerThresholdPercent: lowQuotaAlertThresholds.sevenDay,
                fiveHourTriggerThresholdPercent: lowQuotaAlertThresholds.fiveHour,
                fiveHourRemainingPercent: quota.fiveHourRemaining,
                sevenDayRemainingPercent: quota.sevenDayRemaining,
                accountFacts: try factsSnapshot.map(FeishuAccountFacts.snapshot)
                    ?? FeishuAccountFacts.quotasOnly(
                        fiveHourRemaining: quota.fiveHourRemaining,
                        sevenDayRemaining: quota.sevenDayRemaining
                    ),
                messageOptions: feishuMessageOptions,
                eventID: eventID
            )
            feishuNotificationMessage =
                isTest
                ? WidgetLanguage.storedOrAutomatic().text("正在发送飞书测试通知…", "Sending a Feishu test notification…")
                : WidgetLanguage.storedOrAutomatic().text("正在推送飞书通知…", "Sending a Feishu notification…")
            let configurationRevision = feishuConfigurationRevision
            feishuWebhookService.send(
                notification,
                shouldSend: { [weak self] in
                    guard let self, self.feishuConfigurationRevision == configurationRevision,
                        self.feishuWebhookConfigured, !self.isUpdatingFeishuConnection, isTest || self.feishuNotificationsEnabled
                    else { return false }
                    switch event {
                    case .quotaChange(.quotaReset): return self.feishuQuotaResetEnabled
                    case .quotaChange(.resetCreditsAdded): return self.feishuResetCreditEnabled
                    default: return true
                    }
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, self.feishuConfigurationRevision == configurationRevision else { return }
                        switch result {
                        case .success:
                            self.feishuNotificationMessage =
                                isTest
                                ? WidgetLanguage.storedOrAutomatic().text("飞书测试通知已送达", "Feishu test notification delivered.")
                                : WidgetLanguage.storedOrAutomatic().text("通知已推送到飞书", "Notification delivered to Feishu.")
                        case .failure(.cancelled):
                            break
                        case .failure(let error):
                            self.handleFeishuCredentialFailure(error)
                            self.recordAutomationEvent(
                                level: .warning,
                                title: WidgetLanguage.storedOrAutomatic().text("飞书推送失败", "Feishu notification failed"),
                                detail: error.localizedDescription
                            )
                        }
                    }
                })
        } catch {
            feishuNotificationMessage = error.localizedDescription
        }
    }

    private func sendAdditionalChannelEvent(
        _ event: FeishuSwitchNotification.Event, source: FeishuMaskedAccount, target: FeishuMaskedAccount?,
        quota: AutomaticSwitchQuotaState, eventID: UUID
    ) {
        let kind: MessageTaskStatus.EventKind
        var failure: MessageTaskStatus.FailureReason?
        switch event {
        case .test: return
        case .lowQuotaDetected: kind = .lowQuotaDetected
        case .quotaChange(.quotaReset): kind = .quotaReset
        case .quotaChange(.resetCreditsAdded): kind = .resetCreditsAdded
        case .switchSucceeded: kind = .switchSucceeded
        case .switchFailed(let reason):
            kind = .switchFailed
            failure = MessageTaskStatus.FailureReason(rawValue: reason.rawValue) ?? .unknown
        }
        let account = kind == .switchSucceeded ? (target ?? source) : source
        guard
            let status = try? MessageTaskStatus(
                eventKind: kind, accountLabel: MessageChannelAccountLabel(account.value),
                fiveHourRemainingPercent: quota.fiveHourRemaining, sevenDayRemainingPercent: quota.sevenDayRemaining,
                failureReason: failure, occurredAt: Date(), eventID: eventID
            )
        else { return }
        messageChannels.send(status)
    }

    /// Consumes live task snapshots for observer-confirmed completion
    /// notifications. The proof comes from the pure observer: only a turn seen
    /// running on the current live connection, later reported completed with a
    /// stable turn identifier and plausible timestamp, confirms. While any
    /// notification gate is closed the observer stays empty, so a later opt-in
    /// or reconnect can never replay runs observed while gated off, and a
    /// gated-off snapshot itself never confirms.
    private func handleTaskCompletionSnapshot(from snapshot: CodexTaskLiveSnapshot) {
        guard hasStarted, !isPreview,
            feishuTaskCompletionNotificationsEnabled, feishuNotificationsEnabled,
            feishuWebhookConfigured, !isUpdatingFeishuConnection,
            !pausedAutomationFeatures.contains(.feishu)
        else {
            feishuTaskCompletionObserver = FeishuTaskCompletionObserver()
            return
        }
        let observations = feishuTaskCompletionObserver.observe(snapshot, now: Date())
        let notifications = observations.compactMap { observation -> FeishuTaskCompletionNotification? in
            // Construction fails closed; an unbuildable event is dropped
            // before it can reach the sender.
            try? FeishuTaskCompletionNotification(
                eventID: UUID(),
                source: .codexTaskObserver,
                proof: .confirmedByTaskObserver,
                category: .codexConversation,
                occurredAt: observation.occurredAt)
        }
        guard !notifications.isEmpty else { return }
        sendTaskCompletionNotifications(notifications)
    }

    /// Sends through the existing Feishu sender only. The opt-in gate is
    /// rechecked after the credential read, together with the configuration
    /// revision, so a stop, a switched-off toggle or a changed connection
    /// cancels late sends instead of delivering them. Thread and turn
    /// identifiers stay inside this process: the DTO carries no task text,
    /// account label or attempt count.
    private func sendTaskCompletionNotifications(_ notifications: [FeishuTaskCompletionNotification]) {
        for notification in notifications {
            let configurationRevision = feishuConfigurationRevision
            feishuWebhookService.sendTaskCompletion(
                notification,
                shouldSend: { [weak self] in
                    guard let self else { return false }
                    return self.hasStarted && self.feishuTaskCompletionNotificationsEnabled
                        && self.feishuNotificationsEnabled && self.feishuWebhookConfigured
                        && !self.isUpdatingFeishuConnection
                        && configurationRevision == self.feishuConfigurationRevision
                        && !self.pausedAutomationFeatures.contains(.feishu)
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, self.feishuConfigurationRevision == configurationRevision else { return }
                        switch result {
                        case .success, .failure(.cancelled):
                            break
                        case .failure(let error):
                            self.handleFeishuCredentialFailure(error)
                            self.recordAutomationEvent(
                                level: .warning,
                                title: WidgetLanguage.storedOrAutomatic().text(
                                    "飞书任务完成通知发送失败", "Feishu task-completion notification failed"),
                                detail: error.localizedDescription)
                            self.feishuNotificationMessage = WidgetLanguage.storedOrAutomatic().text(
                                "任务完成通知发送失败", "The task-completion notification failed to send.")
                        }
                    }
                })
        }
    }

    private func maskedAccount(for profile: CodexProfile) -> FeishuMaskedAccount? {
        let displayProfile =
            profile.isSystemProfile
            ? profiles.first {
                !$0.isSystemProfile && $0.recordedAccountKey == profile.recordedAccountKey
                    && $0.lastSnapshot?.accountID == profile.lastSnapshot?.accountID
            } ?? profile : profile
        if let account = try? FeishuMaskedAccount(
            displayName: AccountDisplay.profileName(displayProfile, allProfiles: profiles)
        ) {
            return account
        }
        let first = profile.lastSnapshot?.email?.first.map(String.init) ?? "c"
        let safeFirst = first.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) ? first : "c"
        let suffix = String(profile.id.filter { $0.isLetter || $0.isNumber }.prefix(4))
        return try? FeishuMaskedAccount("\(safeFirst)***-\(suffix.isEmpty ? "acct" : suffix)")
    }

    private func observeOfficialQuotaChanges(_ current: UsageSnapshot, profileID: String) {
        guard !isPreview, observesOfficialQuotaEvents, current.quotaReadSucceeded,
            let profile = profileStore.profiles.first(where: { $0.id == profileID }),
            let saved = profile.lastSnapshot, saved.fetchedAt == current.refreshedAt,
            let accountID = saved.accountID, !accountID.isEmpty,
            let identity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: profile.codexHomeURL),
            identity.accountID == accountID,
            profile.matchesRecordedCredential(identity),
            profile.matchesRecordedAccount(email: current.account?.email),
            let source = maskedAccount(for: profile)
        else { return }
        let observation = CodexQuotaEventTracker.Observation(
            capturedAt: current.refreshedAt,
            limitID: current.limitId,
            fiveHour: current.fiveHourQuota,
            sevenDay: current.sevenDayQuota,
            resetCredits: current.credits?.resetCredits
        )
        let changes = quotaEventTracker.observe(observation, verifiedAccountID: accountID)
        for change in changes {
            if localNotificationsEnabled && !pausedAutomationFeatures.contains(.localNotification) {
                NextLocalNotificationService.shared.submitOfficialReset(change) { [weak self] result in
                    guard let self else { return }
                    if case .failure(let error) = result { self.localNotificationMessage = self.localNotificationErrorMessage(error) }
                }
            }
            let enabled: Bool
            switch change {
            case .quotaReset: enabled = feishuQuotaResetEnabled
            case .resetCreditsAdded: enabled = feishuResetCreditEnabled
            }
            guard enabled || messageChannels.telegramEnabled || messageChannels.weChatEnabled else { continue }
            sendFeishuNotification(
                event: .quotaChange(change), source: source, target: nil,
                quota: AutomaticSwitchQuotaState(snapshot: current), factsSnapshot: current, eventID: UUID()
            )
        }
    }

    private func recordAutomationEvent(
        level: AccountAutomationEvent.Level,
        title: String,
        detail: String
    ) {
        let event = AccountAutomationEvent(
            id: UUID(),
            occurredAt: Date(),
            level: level,
            title: title,
            detail: sanitizedAutomationDetail(detail)
        )
        if let saved = try? automationAuditStore.append(event) {
            automationEvents = saved
        }
    }

    private func sanitizedAutomationDetail(_ detail: String) -> String {
        var value = String(detail.prefix(512))
        let privateRoots = [
            FileManager.default.homeDirectoryForCurrentUser.path,
            FileManager.default.temporaryDirectory.path,
        ].filter { !$0.isEmpty }
        for root in privateRoots {
            value = value.replacingOccurrences(of: root, with: "~")
        }
        for pattern in [
            #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"https://\S+"#,
        ] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..., in: value)
            value = expression.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: "[已隐藏]"
            )
        }
        return value
    }

    func setWarmUpFiveHourEnabled(_ enabled: Bool) {
        guard !pausedAutomationFeatures.contains(.fiveHour) else { return }
        warmUpSelection.fiveHour = enabled
        warmUpSelection.save()
        accountManagerMessage =
            enabled
            ? WidgetLanguage.storedOrAutomatic().text("5 小时暖号已开启；将按每个账号自己的重置时间轮流执行", "5h warm-up enabled. Each account follows its own reset time, one at a time.")
            : WidgetLanguage.storedOrAutomatic().text("5 小时暖号已关闭", "5h warm-up disabled.")
        handleWarmUpSelectionChanged()
    }

    func setWarmUpSevenDayEnabled(_ enabled: Bool) {
        guard !pausedAutomationFeatures.contains(.sevenDay) else { return }
        warmUpSelection.sevenDay = enabled
        warmUpSelection.save()
        accountManagerMessage =
            enabled
            ? WidgetLanguage.storedOrAutomatic().text("7 天暖号已开启；每个账号将按自己的周窗口执行", "Weekly warm-up enabled. Each account follows its own weekly reset.")
            : WidgetLanguage.storedOrAutomatic().text("7 天暖号已关闭", "Weekly warm-up disabled.")
        handleWarmUpSelectionChanged()
    }

    func setAutomaticWarmUpEnabled(_ enabled: Bool) {
        setWarmUpSevenDayEnabled(enabled)
        if !enabled { setWarmUpFiveHourEnabled(false) }
    }

    func refreshProfile(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard hasStarted,
            warmingProfileID == nil,
            !isRefreshingWarmUpProfiles,
            !isLoggingIn,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive
        else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号操作正在进行，请稍后再刷新", "An account operation is in progress. Wait before refreshing.")
            return
        }
        let name = AccountDisplay.profileName(profile)
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在刷新 \(name) 的额度…", "Refreshing limits for \(name)…")
        refreshWarmUpProfilesThenSchedule(
            performWarmUpAfterRefresh: false,
            profileIDs: [profileID]
        ) { [weak self] succeeded in
            self?.accountManagerMessage =
                succeeded
                ? WidgetLanguage.storedOrAutomatic().text("\(name) 的额度已刷新", "Limits refreshed for \(name).")
                : WidgetLanguage.storedOrAutomatic().text("\(name) 的额度刷新失败；已保留旧快照", "Could not refresh limits for \(name). The previous snapshot was preserved.")
        }
    }

    func warmUpProfile(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard warmingProfileID == nil,
            !isRefreshingWarmUpProfiles,
            !isLoggingIn,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive
        else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号操作正在进行，请稍后再暖号", "An account operation is in progress. Wait before warming up.")
            return
        }
        let name = AccountDisplay.profileName(profile)
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在刷新 \(name) 的额度并校验凭据…", "Refreshing limits and verifying sign-in for \(name)…")
        refreshWarmUpProfilesThenSchedule(
            performWarmUpAfterRefresh: false,
            profileIDs: [profileID],
            quotaOnly: true,
            retryQuotaReadOnce: true
        ) { [weak self] succeeded in
            guard let self else { return }
            guard succeeded,
                let refreshed = self.profiles.first(where: { $0.id == profileID })
            else {
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("\(name) 的额度或凭据校验失败，已阻止暖号", "Limit or sign-in checks failed for \(name). Warm-up was blocked.")
                return
            }
            self.performWarmUp(refreshed, manual: true)
        }
    }

    private func handleWarmUpSelectionChanged() {
        scheduleWarmUpMaintenanceTimer()
        if !warmUpSelection.isEnabled {
            warmUpTimer?.invalidate()
            warmUpTimer = nil
            warmUpResetTracker.removeAll()
            return
        }
        refreshWarmUpProfilesThenSchedule()
    }

    private func scheduleQuotaResetRefresh(at retryAt: Date? = nil) {
        quotaResetRefreshTimer?.invalidate()
        quotaResetRefreshTimer = nil
        guard hasStarted, !isPreview else { return }
        let now = Date()
        guard
            let deadline = retryAt
                ?? profiles.compactMap({
                    CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: $0, lastAttemptAt: quotaResetRefreshAttempts[$0.id], now: now)
                }).min()
        else { return }
        let timer = Timer(fire: max(deadline, now.addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            guard let self, self.hasStarted else { return }
            self.quotaResetRefreshTimer = nil
            guard !self.isRefreshingWarmUpProfiles, self.warmingProfileID == nil,
                !self.isLoggingIn, !self.isLaunchingCodex, !self.isAccountSwitchTransactionActive
            else {
                self.scheduleQuotaResetRefresh(at: Date().addingTimeInterval(5))
                return
            }
            let now = Date()
            let dueIDs = Set(
                self.profiles.filter {
                    CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: $0, lastAttemptAt: self.quotaResetRefreshAttempts[$0.id], now: now).map { $0 <= now } ?? false
                }.map(\.id))
            guard !dueIDs.isEmpty else {
                self.scheduleQuotaResetRefresh()
                return
            }
            for id in dueIDs { self.quotaResetRefreshAttempts[id] = now }
            self.refreshWarmUpProfilesThenSchedule(
                performWarmUpAfterRefresh: self.warmUpSelection.isEnabled,
                profileIDs: dueIDs,
                quotaOnly: true
            )
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        quotaResetRefreshTimer = timer
    }

    /// 独立维护所有账号的官方额度：暖号开启时每 10 分钟刷新，关闭时每 30 分钟刷新。
    /// 维护刷新始终 quota-only，不会发送暖号请求；暖号仅由独立的到期判定触发。
    private func scheduleWarmUpMaintenanceTimer() {
        guard hasStarted else { return }
        let interval = accountRefreshFrequency.interval(
            default: automaticAccountSwitchEnabled
                ? 3 * 60
                : CodexWarmUpPolicy.maintenanceRefreshInterval(
                    warmUpEnabled: warmUpSelection.isEnabled,
                    quotaNotificationsEnabled: observesOfficialQuotaEvents
                ))
        if let timer = warmUpMaintenanceTimer,
            timer.isValid,
            !CodexWarmUpPolicy.maintenanceTimerNeedsReplacement(
                currentInterval: timer.timeInterval,
                requestedInterval: interval
            )
        {
            return
        }
        warmUpMaintenanceTimer?.invalidate()
        warmUpMaintenanceTimer = nil
        let timer = Timer(
            fire: Date().addingTimeInterval(interval),
            interval: interval,
            repeats: true
        ) { [weak self] _ in
            guard let self,
                self.hasStarted
            else { return }
            if self.isRefreshingWarmUpProfiles {
                // 看门狗：上一轮全量刷新卡死超过 12 分钟时强制复位，
                // 避免额度证据无限过期、暖号与失败标记全部静默停摆。
                guard let startedAt = self.warmUpRefreshStartedAt,
                    Date().timeIntervalSince(startedAt) > 12 * 60
                else { return }
                self.isRefreshingWarmUpProfiles = false
                self.warmUpRefreshStartedAt = nil
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("检测到上一轮账号刷新卡住，已自动恢复", "A stalled account refresh was detected and recovered.")
            }
            self.refreshWarmUpProfilesThenSchedule(
                performWarmUpAfterRefresh: self.warmUpSelection.isEnabled,
                quotaOnly: true,
                retryQuotaReadOnce: true
            )
        }
        timer.tolerance = min(interval * 0.1, observesOfficialQuotaEvents ? 5 : 30)
        RunLoop.main.add(timer, forMode: .common)
        warmUpMaintenanceTimer = timer
    }

    private func effectiveWarmUpSelection(
        for profile: CodexProfile,
        unexpected: Set<CodexWarmUpWindowKind> = []
    ) -> CodexWarmUpSelection {
        CodexWarmUpPolicy.effectiveSelection(
            warmUpSelection,
            participatesInAutomaticSwitch: automaticSwitchParticipation(for: profile),
            unexpected: unexpected
        )
    }

    /// 额度读取失败的卡片提示；官方明确拒绝令牌（401/吊销）时给出明确的重新登录指引。
    private func quotaFailureStatusText(for profile: CodexProfile, language: WidgetLanguage) -> String? {
        guard let failureAt = profile.lastQuotaReadFailureAt else { return nil }
        let base = language.text("额度读取失败 ", "Limit refresh failed ") + language.dateTime(failureAt)
        if profile.lastQuotaReadFailureReason == "oauth-invalidated" {
            return base + language.text("；该账号登录已失效，请在账号卡上重新登录", ". Sign-in expired; sign in again from this account card.")
        }
        return base + language.text("；旧额度仅供参考，如持续出现请对该账号重新登录", ". Previous values are for reference only. Sign in again if this persists.")
    }

    func warmUpStatus(for profile: CodexProfile, language: WidgetLanguage = .storedOrAutomatic()) -> String? {
        if warmingProfileID == profile.id {
            return language.text("正在发送最小请求，以开始已开启的额度窗口…", "Sending a minimal request to start the selected usage window…")
        }
        guard warmUpSelection.isEnabled || profile.lastWarmUpAt != nil || profile.lastQuotaReadFailureAt != nil else { return nil }
        if CodexWarmUpPolicy.hasExhaustedSubscriptionWindow(profile) {
            let exhausted = language.text(
                "订阅额度已用完，暖号已暂停；等待官方窗口恢复",
                "Subscription quota exhausted. Warm-up paused until the official window recovers.")
            return [exhausted, quotaFailureStatusText(for: profile, language: language)]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        let selection = effectiveWarmUpSelection(for: profile)
        let last = profile.lastWarmUpAt.flatMap { date -> String? in
            if profile.lastWarmUpSucceeded == true {
                return language.text("最近暖号成功 ", "Last warm-up succeeded ") + language.dateTime(date)
            }
            let detail =
                warmUpFailureDetail(profile.lastWarmUpFailureReason, language: language)
                .map { language.text("（\($0)）", " (\($0))") } ?? ""
            return language.text("最近暖号失败\(detail) ", "Last warm-up failed\(detail) ") + language.dateTime(date)
        }
        guard warmUpSelection.isEnabled else {
            let failure = quotaFailureStatusText(for: profile, language: language)
            return [language.text("智能暖号已关闭", "Auto warm-up off"), last, failure].compactMap { $0 }.joined(separator: " · ")
        }
        var parts = [last].compactMap { $0 }
        if let failureText = quotaFailureStatusText(for: profile, language: language) {
            parts.append(failureText)
        }
        if selection.fiveHour {
            if CodexWarmUpPolicy.shouldSkipFiveHourToProtectWeekly(profile) {
                parts.append(language.text("5 小时等待恢复 · 7 天额度已用尽", "5h waiting for recovery · weekly limit exhausted"))
            } else {
                parts.append(
                    warmUpWindowStatus(
                        label: language.text("5 小时", "5h"),
                        window: profile.lastSnapshot?.fiveHour,
                        profile: profile,
                        successfulInterval: CodexWarmUpPolicy.fiveHourSuccessInterval,
                        language: language
                    ))
            }
        }
        if selection.sevenDay {
            parts.append(
                warmUpWindowStatus(
                    label: language.text("7 天", "7d"),
                    window: profile.lastSnapshot?.sevenDay,
                    profile: profile,
                    successfulInterval: CodexWarmUpPolicy.sevenDaySuccessInterval,
                    language: language
                ))
        }
        return parts.joined(separator: " · ")
    }

    private func warmUpFailureDetail(_ reason: String?, language: WidgetLanguage) -> String? {
        switch reason {
        case "timeout": return language.text("请求超时", "Request timed out")
        case "network": return language.text("网络失败", "Network error")
        case "http-401", "credentials-unavailable": return language.text("登录失效", "Sign-in expired")
        case "http-403": return language.text("无权访问", "Access denied")
        case "http-429": return language.text("频率受限", "Rate limited")
        case "http-5xx": return language.text("官方服务异常", "Service error")
        case "stream-failed": return language.text("官方返回失败", "Request failed")
        case "stream-incomplete": return language.text("响应未完成", "Incomplete response")
        default: return nil
        }
    }

    private func warmUpWindowStatus(
        label: String,
        window: CodexQuotaWindowSnapshot?,
        profile: CodexProfile,
        successfulInterval: TimeInterval,
        language: WidgetLanguage
    ) -> String {
        if CodexWarmUpPolicy.isWindowIdle(window) {
            if profile.lastWarmUpSucceeded == true, let lastWarmUpAt = profile.lastWarmUpAt {
                let next = lastWarmUpAt.addingTimeInterval(successfulInterval + CodexWarmUpPolicy.resetGrace)
                if next > Date() {
                    return language.text("下次暖号 \(label) ", "Next \(label) warm-up ") + language.dateTime(next)
                }
            }
            if profile.lastWarmUpSucceeded == false, let attemptedAt = profile.lastWarmUpAt {
                let retryAt = attemptedAt.addingTimeInterval(CodexWarmUpPolicy.failureRetryInterval)
                if retryAt > Date() {
                    return language.text("\(label)自动复核重试 ", "\(label) recheck and retry ") + language.dateTime(retryAt)
                }
            }
            return language.text("\(label)等待额度刷新后自动继续", "\(label) continues after limit refresh")
        }
        if let resetsAt = window?.resetsAt, resetsAt > Date() {
            return language.text("下次暖号 \(label) ", "Next \(label) warm-up ") + language.dateTime(resetsAt)
        }
        return language.text("\(label)等待官方窗口，自动复核中", "\(label) awaiting the official window; rechecking automatically")
    }

    private func runDueWarmUp() {
        guard let profile = nextDueWarmUpProfile() else { return }
        performWarmUp(profile)
    }

    private func performWarmUp(_ profile: CodexProfile, manual: Bool = false) {
        guard CodexWarmUpPolicy.canSendWarmUpRequest(profile) else {
            if manual {
                accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "订阅额度已用完或尚未核实，已阻止暖号；等待官方额度恢复",
                    "Subscription quota is exhausted or unverified. Warm-up is blocked until official limits recover.")
            }
            return
        }
        let resetTicket = warmUpResetTracker.ticket(for: profile.recordedAccountKey)
        let unexpected = Set(resetTicket.keys)
        guard manual || warmUpSelection.isEnabled,
            warmingProfileID == nil,
            !isRefreshingWarmUpProfiles,
            !isLoggingIn,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive,
            manual
                || CodexWarmUpPolicy.isDue(
                    profile,
                    selection: effectiveWarmUpSelection(for: profile, unexpected: unexpected),
                    unexpected: unexpected
                )
        else { return }
        warmingProfileID = profile.id
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
            "正在确认 \(AccountDisplay.profileName(profile)) 是否空闲…", "Checking whether \(AccountDisplay.profileName(profile)) is idle…")
        guard let alias = hubAccountAlias(for: profile) else {
            warmingProfileID = nil
            hubWarmUpDeferredUntilByAccount[profile.recordedAccountKey] = Date().addingTimeInterval(hubWarmUpRetryDelay)
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("无法确认账号在 Hub 中的身份，已阻止暖号", "Could not verify the account's Hub mapping. Warm-up was blocked.")
            scheduleWarmUpTimer()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let activityLease: String
            do {
                activityLease = try DispatchActivityStore.live.reserveWarmUp(account: profile.recordedAccountKey, alias: alias)
            } catch {
                self.warmingProfileID = nil
                self.hubWarmUpDeferredUntilByAccount[profile.recordedAccountKey] = Date().addingTimeInterval(self.hubWarmUpRetryDelay)
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "账号已有准备或运行占用，或占用状态待核实；暖号保留并稍后复核",
                    "The account is reserved, running, or unverified. Warm-up remains queued.")
                self.scheduleWarmUpTimer()
                return
            }
            let availability = await HubConsoleModel.warmUpAvailability(for: alias, excludingLocalLease: activityLease)
            self.continueWarmUp(profile, manual: manual, availability: availability, resetTicket: resetTicket, activityLease: activityLease)
        }
    }

    private func continueWarmUp(
        _ profile: CodexProfile,
        manual: Bool,
        availability: HubWarmUpAvailability,
        resetTicket: CodexWarmUpResetTracker.Ticket,
        activityLease: String
    ) {
        guard
            CodexWarmUpPolicy.canContinueAfterAsyncCheck(
                serviceIsRunning: hasStarted,
                requestIsCurrent: warmingProfileID == profile.id,
                warmUpIsEnabled: manual || warmUpSelection.isEnabled,
                accountOperationIsIdle: !isLoggingIn && !isLaunchingCodex && !isAccountSwitchTransactionActive
            ),
            profiles.contains(where: { $0.id == profile.id && $0.recordedAccountKey == profile.recordedAccountKey })
        else {
            finishWarmUpActivity(activityLease, succeeded: false, cancelled: true)
            if warmingProfileID == profile.id { warmingProfileID = nil }
            scheduleWarmUpTimer()
            return
        }
        let accountKey = profile.recordedAccountKey
        switch availability {
        case .busy:
            finishWarmUpActivity(activityLease, succeeded: false, cancelled: true)
            hubWarmUpUnavailableUntil = nil
            hubWarmUpDeferredUntilByAccount[accountKey] = Date().addingTimeInterval(hubWarmUpRetryDelay)
            warmingProfileID = nil
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "Hub 正在使用 \(AccountDisplay.profileName(profile))，暖号保留并稍后重试", "Hub is using \(AccountDisplay.profileName(profile)). Warm-up remains queued for retry.")
            scheduleWarmUpTimer()
            return
        case .unavailable:
            finishWarmUpActivity(activityLease, succeeded: false, cancelled: true)
            hubWarmUpUnavailableUntil = Date().addingTimeInterval(hubWarmUpRetryDelay)
            warmingProfileID = nil
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("暂时无法确认 Hub 账号状态，已阻止暖号", "Hub account status is unverified. Warm-up was blocked.")
            scheduleWarmUpTimer()
            return
        case .idle:
            hubWarmUpUnavailableUntil = nil
            hubWarmUpDeferredUntilByAccount.removeValue(forKey: accountKey)
        }
        // Re-read every mutable gate after the asynchronous Hub check. A quota
        // refresh, reset ticket, or selected window may have changed in flight.
        guard
            let currentProfile = profiles.first(where: {
                $0.id == profile.id && $0.recordedAccountKey == profile.recordedAccountKey
            }), CodexWarmUpPolicy.canSendWarmUpRequest(currentProfile),
            manual
                || {
                    let currentUnexpected = warmUpResetTracker.kinds(for: currentProfile.recordedAccountKey)
                    return CodexWarmUpPolicy.isDue(
                        currentProfile,
                        selection: effectiveWarmUpSelection(for: currentProfile, unexpected: currentUnexpected),
                        unexpected: currentUnexpected
                    )
                }()
        else {
            finishWarmUpActivity(activityLease, succeeded: false, cancelled: true)
            warmingProfileID = nil
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "订阅额度已用完或尚未核实，已阻止暖号；等待官方额度恢复",
                "Subscription quota is exhausted or unverified. Warm-up is blocked until official limits recover.")
            scheduleWarmUpTimer()
            return
        }
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
            "正在为 \(AccountDisplay.profileName(currentProfile)) 发送最小请求…", "Sending a minimal request for \(AccountDisplay.profileName(currentProfile))…")
        do {
            try accountActions.warmUp(profile: currentProfile) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    var saved = true
                    do {
                        try self.profileStore.recordWarmUp(at: Date(), succeeded: true, for: profile.id)
                    } catch {
                        saved = false
                        self.hubWarmUpDeferredUntilByAccount[accountKey] = Date().addingTimeInterval(CodexWarmUpPolicy.failureRetryInterval)
                        self.recordOperationsIssue(
                            id: "warmup-state-save-failed", summary: "Warm-up returned successfully but its saved state could not be updated. Automatic retry was deferred.")
                    }
                    self.warmUpResetTracker.acknowledge(resetTicket, for: accountKey)
                    self.finishWarmUpActivity(activityLease, succeeded: true)
                    self.syncProfiles()
                    self.warmingProfileID = nil
                    self.accountManagerMessage =
                        saved
                        ? WidgetLanguage.storedOrAutomatic().text(
                            "\(AccountDisplay.profileName(profile)) 已发送最小请求，正在确认窗口是否开始…",
                            "Minimal request sent for \(AccountDisplay.profileName(profile)). Checking whether a usage window started…")
                        : WidgetLanguage.storedOrAutomatic().text(
                            "最小请求已成功，但暖号记录保存失败；已延后重试，请核实账号历史",
                            "The minimal request succeeded, but its history could not be saved. Retry was deferred; verify account history.")
                    self.refreshProfileAfterWarmUp(profile, manual: manual)
                case .failure(let error):
                    self.finishWarmUpActivity(activityLease, succeeded: false)
                    self.recordOperationsIssue(
                        id: "warmup-request-failed",
                        summary: "An automatic or manual warm-up request failed. The account retains its bounded retry plan; inspect the account detail for its failure category.")
                    self.recordWarmUpFailure(
                        at: Date(),
                        succeeded: false,
                        failureReason: CodexAccountActions.warmUpFailureReason(for: error),
                        for: profile.id
                    )
                    self.syncProfiles()
                    self.warmingProfileID = nil
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "\(AccountDisplay.profileName(profile)) 暖号失败：\(error.localizedDescription)；5 分钟后自动复核重试",
                        "Warm-up failed for \(AccountDisplay.profileName(profile)): \(error.localizedDescription). Rechecking for retry in 5 minutes.")
                    self.scheduleWarmUpTimer()
                }
            }
        } catch {
            finishWarmUpActivity(activityLease, succeeded: false)
            recordOperationsIssue(id: "warmup-start-failed", summary: "A warm-up request could not start. The account retains its bounded retry plan.")
            recordWarmUpFailure(
                at: Date(),
                succeeded: false,
                failureReason: CodexAccountActions.warmUpFailureReason(for: error),
                for: profile.id
            )
            syncProfiles()
            warmingProfileID = nil
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "暖号启动失败：\(error.localizedDescription)；5 分钟后自动复核重试", "Could not start warm-up: \(error.localizedDescription). Rechecking for retry in 5 minutes.")
            scheduleWarmUpTimer()
        }
    }

    private func recordWarmUpFailure(at date: Date, succeeded: Bool, failureReason: String?, for profileID: String) {
        do { try profileStore.recordWarmUp(at: date, succeeded: succeeded, failureReason: failureReason, for: profileID) } catch {
            hubWarmUpDeferredUntilByAccount[profiles.first(where: { $0.id == profileID })?.recordedAccountKey ?? profileID] = Date().addingTimeInterval(
                CodexWarmUpPolicy.failureRetryInterval)
            recordOperationsIssue(
                id: "warmup-failure-save-failed",
                summary: "A warm-up failed and its failure record could not be saved. Retry is deferred; verify account history before further maintenance.")
        }
    }

    private func finishWarmUpActivity(_ lease: String, succeeded: Bool, cancelled: Bool = false) {
        do {
            try DispatchActivityStore.live.finishWarmUp(lease, succeeded: succeeded, cancelled: cancelled)
        } catch {
            recordOperationsIssue(
                id: "warmup-reservation-release-failed",
                summary: "Warm-up ended but its shared reservation could not be released. Preserve the occupied state until process and ownership are verified.")
        }
    }

    private func recordOperationsIssue(id: String, summary: String) {
        guard !isPreview else { return }
        do {
            let code = warmingProfileID.flatMap { DispatchCodeCatalog.code(for: $0) }
            try DispatchActivityStore.live.appendIssue(id: id, phase: "observed", summary: summary, code: code)
            operationsIssueJournalMessage = nil
        } catch {
            operationsIssueJournalMessage = WidgetLanguage.storedOrAutomatic().text(
                "运行问题日志写入失败；请保留当前问题信息，稍后复核日志权限",
                "The shared issue journal could not be updated. Preserve the issue details and check journal access.")
        }
    }

    func openOperationsIssueJournal() {
        guard !isPreview else { return }
        let url = DispatchActivityStore.live.directory.appendingPathComponent(DispatchActivityStore.issueName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("暂无运行问题记录", "No operational issues have been recorded.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func hubAccountAlias(for profile: CodexProfile) -> String? {
        configuredHubAccountAlias(for: profile)
    }

    private func nextDueWarmUpProfile(now: Date = Date()) -> CodexProfile? {
        if let unavailableUntil = hubWarmUpUnavailableUntil, unavailableUntil > now { return nil }
        return CodexProfile.groupsByRecordedAccount(profiles).compactMap { group -> CodexProfile? in
            guard let accountKey = group.first?.recordedAccountKey,
                hubWarmUpDeferredUntilByAccount[accountKey].map({ $0 <= now }) ?? true
            else { return nil }
            guard
                group.allSatisfy({
                    let unexpected = warmUpResetTracker.kinds(for: $0.recordedAccountKey)
                    return CodexWarmUpPolicy.isDue(
                        $0,
                        selection: effectiveWarmUpSelection(for: $0, unexpected: unexpected),
                        unexpected: unexpected,
                        now: now
                    )
                })
            else { return nil }
            return group.first { $0.id == selectedMonitorProfileID } ?? group.first
        }.first
    }

    private func scheduleWarmUpTimer() {
        guard !isRefreshingWarmUpProfiles else { return }
        warmUpTimer?.invalidate()
        warmUpTimer = nil
        guard warmUpSelection.isEnabled, hasStarted, warmingProfileID == nil else { return }
        if let profile = nextDueWarmUpProfile() {
            performWarmUp(profile)
            return
        }
        guard let fireAt = nextScheduledWarmUp() else { return }
        scheduleWarmUpRefresh(at: fireAt)
    }

    private func scheduleWarmUpRefresh(at fireAt: Date) {
        guard hasStarted, warmUpSelection.isEnabled, warmingProfileID == nil else { return }
        warmUpTimer?.invalidate()
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.warmUpTimer = nil
            self.refreshWarmUpProfilesThenSchedule(quotaOnly: true)
        }
        timer.tolerance = fireAt.timeIntervalSinceNow < 30 ? 1 : 2
        RunLoop.main.add(timer, forMode: .common)
        warmUpTimer = timer
    }

    private func nextScheduledWarmUp(now: Date = Date()) -> Date? {
        if let unavailableUntil = hubWarmUpUnavailableUntil, unavailableUntil > now {
            return unavailableUntil
        }
        return CodexProfile.groupsByRecordedAccount(profiles).compactMap { group -> Date? in
            if let accountKey = group.first?.recordedAccountKey,
                let deferredUntil = hubWarmUpDeferredUntilByAccount[accountKey],
                deferredUntil > now
            {
                return deferredUntil
            }
            let dates = group.compactMap { profile -> Date? in
                let unexpected = warmUpResetTracker.kinds(for: profile.recordedAccountKey)
                let selection = effectiveWarmUpSelection(for: profile, unexpected: unexpected)
                let eligibleNext = CodexWarmUpPolicy.nextEligibleDate(
                    for: profile,
                    selection: selection,
                    unexpected: unexpected,
                    now: now
                ).flatMap { $0 > now ? $0 : nil }
                return [
                    eligibleNext,
                    CodexWarmUpPolicy.nextScheduledResetDate(
                        for: profile,
                        selection: selection,
                        now: now
                    ),
                ].compactMap { $0 }.min()
            }
            guard dates.count == group.count else { return nil }
            return dates.max()
        }.min()
    }

    private func noteUnexpectedWarmUpResets(previous: CodexProfile, current: UsageSnapshot) {
        guard warmUpSelection.isEnabled else { return }
        let now = Date()
        var kinds: Set<CodexWarmUpWindowKind> = []
        if warmUpSelection.fiveHour,
            CodexWarmUpPolicy.didResetUnexpectedly(
                previous: previous.lastSnapshot?.fiveHour,
                current: current.fiveHourQuota.map(CodexQuotaWindowSnapshot.init),
                now: now
            )
        {
            kinds.insert(.fiveHour)
        }
        if warmUpSelection.sevenDay,
            CodexWarmUpPolicy.didResetUnexpectedly(
                previous: previous.lastSnapshot?.sevenDay,
                current: current.sevenDayQuota.map(CodexQuotaWindowSnapshot.init),
                now: now
            )
        {
            kinds.insert(.sevenDay)
        }
        guard !kinds.isEmpty else { return }
        warmUpResetTracker.note(kinds, for: previous.recordedAccountKey)
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
            "检测到 \(AccountDisplay.profileName(previous)) 官方额度提前重置；暖号调度将独立执行一次",
            "An early limit reset was detected for \(AccountDisplay.profileName(previous)). Warm-up will be scheduled separately once.")
    }

    private func refreshProfileAfterWarmUp(_ profile: CodexProfile, manual: Bool = false) {
        let generation = refreshGeneration
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let context = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: profile.codexHomeURL
            )
            let snapshot = CodexUsageReader().load(context: context, quotaOnly: true)
            DispatchQueue.main.async {
                guard self.refreshGeneration == generation, !self.isLaunchingCodex, !self.isAccountSwitchTransactionActive else { return }
                do {
                    try self.profileStore.record(snapshot, for: profile.id)
                    self.observeOfficialQuotaChanges(snapshot, profileID: profile.id)
                } catch {
                    // Preserve the existing refresh failure path; no event is sent.
                }
                self.syncProfiles()
                let updated = self.profiles.first { $0.id == profile.id } ?? profile
                if manual {
                    self.accountManagerMessage =
                        snapshot.quotaReadSucceeded
                        ? WidgetLanguage.storedOrAutomatic().text(
                            "\(AccountDisplay.profileName(profile)) 已暖号并刷新额度", "Warm-up complete and limits refreshed for \(AccountDisplay.profileName(profile)).")
                        : WidgetLanguage.storedOrAutomatic().text(
                            "\(AccountDisplay.profileName(profile)) 已发送最小请求；官方额度暂不可用",
                            "Minimal request sent for \(AccountDisplay.profileName(profile)). Current usage limits are unavailable.")
                    if profile.id == self.selectedMonitorProfileID {
                        self.refresh(queueIfBusy: true)
                    }
                    self.scheduleWarmUpTimer()
                    return
                }
                let selection = self.effectiveWarmUpSelection(
                    for: updated,
                    unexpected: self.warmUpResetTracker.kinds(for: updated.recordedAccountKey)
                )
                let stillIdle =
                    (selection.fiveHour && CodexWarmUpPolicy.isWindowIdle(updated.lastSnapshot?.fiveHour))
                    || (selection.sevenDay && CodexWarmUpPolicy.isWindowIdle(updated.lastSnapshot?.sevenDay))
                if stillIdle {
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "\(AccountDisplay.profileName(profile)) 已发送最小请求，继续按暖号周期复核",
                        "Minimal request sent for \(AccountDisplay.profileName(profile)). Scheduled warm-up checks will continue.")
                } else {
                    let resetTexts = [
                        selection.fiveHour
                            ? updated.lastSnapshot?.fiveHour?.resetsAt.map {
                                WidgetLanguage.storedOrAutomatic().text("5 小时重置 ", "5h resets ") + WidgetLanguage.storedOrAutomatic().dateTime($0)
                            } : nil,
                        selection.sevenDay
                            ? updated.lastSnapshot?.sevenDay?.resetsAt.map {
                                WidgetLanguage.storedOrAutomatic().text("7 天重置 ", "7d resets ") + WidgetLanguage.storedOrAutomatic().dateTime($0)
                            } : nil,
                    ].compactMap { $0 }
                    self.accountManagerMessage =
                        resetTexts.isEmpty
                        ? WidgetLanguage.storedOrAutomatic().text(
                            "\(AccountDisplay.profileName(profile)) 已开始额度窗口", "A usage window started for \(AccountDisplay.profileName(profile)).")
                        : WidgetLanguage.storedOrAutomatic().text(
                            "\(AccountDisplay.profileName(profile)) 已开始额度窗口 · ", "A usage window started for \(AccountDisplay.profileName(profile)) · ")
                            + resetTexts.joined(separator: " · ")
                }
                if profile.id == self.selectedMonitorProfileID {
                    self.refresh(queueIfBusy: true)
                }
                self.scheduleWarmUpTimer()
            }
        }
    }

    private func refreshWarmUpProfilesThenSchedule(
        performWarmUpAfterRefresh: Bool = true,
        profileIDs: Set<String>? = nil,
        quotaOnly: Bool = true,
        retryQuotaReadOnce: Bool = false,
        refreshMembershipDates: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        if performWarmUpAfterRefresh {
            warmUpTimer?.invalidate()
            warmUpTimer = nil
        }
        guard hasStarted,
            !isRefreshingWarmUpProfiles,
            !isLoggingIn,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive
        else {
            // A reset deadline can overlap a refresh or account operation. Keep
            // the deadline pending; the next attempt still runs every warm-up gate.
            if performWarmUpAfterRefresh {
                scheduleWarmUpRefresh(at: Date().addingTimeInterval(5))
            }
            return
        }
        let profiles = profileIDs.map { ids in self.profiles.filter { ids.contains($0.id) } } ?? self.profiles
        guard !profiles.isEmpty else { return }
        let refreshingIDs = Set(profiles.map(\.id))
        let preference = statisticsPreference
        isRefreshingWarmUpProfiles = true
        refreshingProfileIDs = refreshingIDs
        warmUpRefreshStartedAt = Date()
        let quotaCancellation = TokenMonitorCancellation()
        engineQuotaCancellation?.cancel()
        engineQuotaCancellation = quotaCancellation
        let limitsSelector = engineLimitsSelector
        DispatchQueue.global(qos: .utility).async {
            let contexts = profiles.map { profile in
                RuntimeLoadContext.live(
                    statisticsPreference: preference,
                    codexHomeDirectory: profile.codexHomeURL
                )
            }
            // 第一阶段：官方额度读取按账号并行（系统 home 内部仍串行），上限 4 个并发 app-server。
            let readerCount = contexts.count
            var quotaResults: [(appServer: CodexUsageReader.AppServerSnapshot, messages: [String])] = .init(
                repeating: (CodexUsageReader.AppServerSnapshot(), []),
                count: readerCount
            )
            let quotaResultsLock = NSLock()
            let workerCount = min(4, max(1, readerCount))
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                var index = worker
                while index < readerCount {
                    var readMessages: [String] = []
                    let reader = CodexUsageReader()
                    let appServer = reader.readQuotaSnapshot(
                        context: contexts[index],
                        quotaOnly: quotaOnly,
                        messages: &readMessages,
                        managedProfile: profiles[index],
                        cancellation: quotaCancellation,
                        selectLimitsProvider: limitsSelector
                    )
                    quotaResultsLock.lock()
                    quotaResults[index] = (appServer, readMessages)
                    quotaResultsLock.unlock()
                    index += workerCount
                }
            }
            // 第二阶段：本地统计与重试保持串行，行为与旧链路一致。
            let snapshots: [(id: String, snapshot: UsageSnapshot)] = quotaResults.indices.map { index in
                let profile = profiles[index]
                var snapshot = CodexUsageReader().finishingLoad(
                    appServer: quotaResults[index].appServer,
                    messages: quotaResults[index].messages,
                    context: contexts[index],
                    quotaOnly: quotaOnly
                )
                if retryQuotaReadOnce, !snapshot.quotaReadSucceeded {
                    let retryContext = RuntimeLoadContext.live(
                        statisticsPreference: preference,
                        codexHomeDirectory: profile.codexHomeURL
                    )
                    snapshot = CodexUsageReader().load(
                        context: retryContext, quotaOnly: quotaOnly,
                        managedProfile: profile, cancellation: quotaCancellation, selectLimitsProvider: limitsSelector)
                }
                return (profile.id, snapshot)
            }
            DispatchQueue.main.async {
                guard self.engineQuotaCancellation === quotaCancellation else { return }
                self.isRefreshingWarmUpProfiles = false
                self.refreshingProfileIDs.subtract(refreshingIDs)
                self.warmUpRefreshStartedAt = nil
                guard self.hasStarted else { return }
                guard !quotaCancellation.isCancelled else {
                    completion?(false)
                    return
                }
                for index in quotaResults.indices {
                    if let envelope = quotaResults[index].appServer.engineLimits {
                        self.engineLimitsByProfileID[profiles[index].id] = envelope
                    }
                }
                var savedSuccessfulQuota = false
                var saveFailed = false
                for (profileID, snapshot) in snapshots {
                    if snapshot.quotaReadSucceeded,
                        let previous = self.profiles.first(where: { $0.id == profileID }),
                        previous.matchesRecordedAccount(email: snapshot.account?.email)
                    {
                        self.noteUnexpectedWarmUpResets(previous: previous, current: snapshot)
                    }
                    do {
                        try self.profileStore.record(snapshot, for: profileID)
                        self.observeOfficialQuotaChanges(snapshot, profileID: profileID)
                        savedSuccessfulQuota = savedSuccessfulQuota || snapshot.quotaReadSucceeded
                    } catch {
                        saveFailed = true
                    }
                }
                self.syncProfiles()
                if saveFailed {
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "部分额度已读取但未能保存，请重试刷新。",
                        "Some usage limits were read but could not be saved. Refresh again.")
                }
                completion?(savedSuccessfulQuota && !saveFailed)
                if refreshMembershipDates { self.refreshExpiredMembershipDates() }
                if performWarmUpAfterRefresh {
                    if self.warmUpSelection.isEnabled {
                        self.runDueWarmUp()
                    }
                    self.scheduleWarmUpTimer()
                }
                if self.hasPendingDispatchQuotaRefresh {
                    self.hasPendingDispatchQuotaRefresh = false
                    self.requestDispatchQuotaRefresh()
                }
            }
        }
    }

    private func requestDispatchQuotaRefresh() {
        guard hasStarted else { return }
        if isRefreshingWarmUpProfiles {
            hasPendingDispatchQuotaRefresh = true
            return
        }
        guard !isLoggingIn, !isLaunchingCodex, !isAccountSwitchTransactionActive else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("Next 调度额度刷新已阻止：账号操作尚未结束", "Pool limit refresh blocked: an account operation is still in progress.")
            return
        }
        let systemAccountKey = profiles.first(where: \.isSystemProfile)?.recordedAccountKey
        let profileIDs = Set(
            profiles.filter {
                !$0.isSystemProfile
                    && $0.recordedAccountKey != systemAccountKey
                    && automaticSwitchParticipation(for: $0)
            }.map(\.id))
        guard !profileIDs.isEmpty else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("Next 调度额度刷新已阻止：没有允许参与的账号", "Pool limit refresh blocked: no accounts are opted in.")
            return
        }
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在为 Next 调度刷新账号额度…", "Refreshing limits for the Next account pool…")
        let requestedAt = Date()
        refreshWarmUpProfilesThenSchedule(
            performWarmUpAfterRefresh: false,
            profileIDs: profileIDs,
            quotaOnly: true,
            retryQuotaReadOnce: true,
            refreshMembershipDates: false,
            completion: { [weak self] savedSuccessfully in
                guard let self else { return }
                let refreshedCount = self.profiles.filter { profile in
                    guard profileIDs.contains(profile.id),
                        let snapshot = profile.lastSnapshot,
                        snapshot.quotaReadSucceeded == true,
                        snapshot.fetchedAt >= requestedAt
                    else { return false }
                    return profile.lastQuotaReadFailureAt.map { $0 < snapshot.fetchedAt } ?? true
                }.count
                self.accountManagerMessage =
                    savedSuccessfully
                    ? WidgetLanguage.storedOrAutomatic().text(
                        "调度额度刷新结束：\(refreshedCount)/\(profileIDs.count) 个账号取得新鲜额度。",
                        "Pool refresh finished: \(refreshedCount)/\(profileIDs.count) accounts have fresh limits.")
                    : WidgetLanguage.storedOrAutomatic().text(
                        "调度额度刷新未完成，请查看账号状态后重试。",
                        "Pool refresh did not complete. Check the account status and try again.")
            }
        )
    }

    func stageLaunchProfileID(_ profileID: String) {
        guard !hasStarted, pendingLaunchProfileID == nil else { return }
        pendingLaunchProfileID = profileID
    }

    private func launchPendingProfileAfterInitialRefresh(deadline: Date = Date().addingTimeInterval(20)) {
        guard let profileID = pendingLaunchProfileID else { return }
        guard isRefreshing else {
            pendingLaunchProfileID = nil
            launchCodex(with: profileID)
            return
        }
        guard Date() < deadline else {
            pendingLaunchProfileID = nil
            debugLog("switch timing: launch argument abandoned because the initial quota refresh exceeded 20 seconds")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.launchPendingProfileAfterInitialRefresh(deadline: deadline)
        }
    }

    @MainActor
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        messageChannels.onConfigurationChanged = { [weak self] in
            guard let self, self.hasStarted else { return }
            self.quotaEventTracker.reset()
            self.scheduleWarmUpMaintenanceTimer()
        }
        messageChannels.start()
        resumeTerminalMonitoring()
        isLaunchingCodex = true
        let recoveryGeneration = beginAccountSwitchTransaction()
        accountActions.recoverPendingSwitchIfNeeded { [weak self] result in
            guard let self, self.hasStarted,
                self.isCurrentAccountSwitchTransaction(recoveryGeneration)
            else { return }
            if case .success = result {
                do {
                    try DispatchActivityStore.live.finishRecoveredDesktopMaintenance(recoveryIsClear: CodexAccountActions.switchRecoveryIsClear())
                } catch {
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "上次切换的占用记录尚未恢复，相关账号暂不派单", "The previous switch reservation is still pending recovery. Affected accounts remain reserved.")
                }
            }
            self.isLaunchingCodex = false
            self.finishAccountSwitchTransaction()
            switch result {
            case .success(.noPendingSwitch):
                break
            case .success(.restoredOriginalAuth(let reopened)):
                self.accountManagerMessage =
                    reopened
                    ? WidgetLanguage.storedOrAutomatic().text("检测到上次切换中断；已恢复原账号并重新打开 Codex", "An interrupted switch was detected. Original account restored and Codex reopened.")
                    : WidgetLanguage.storedOrAutomatic().text("检测到上次切换中断；已恢复原账号", "An interrupted switch was detected. Original account restored.")
            case .success(.originalAuthAlreadyPresent(let reopened)):
                self.accountManagerMessage =
                    reopened
                    ? WidgetLanguage.storedOrAutomatic().text("上次切换未完成；原账号未变化并已重新打开 Codex", "The last switch did not finish. Original account unchanged; Codex reopened.")
                    : WidgetLanguage.storedOrAutomatic().text("上次切换未完成；原账号未变化", "The last switch did not finish. Original account unchanged.")
            case .success(.preservedExternalAuth):
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "上次切换后凭据已被外部更新；已保留最新状态，不做覆盖", "Sign-in data changed outside Next after the last switch. The latest state was preserved.")
            case .failure(let error):
                self.automaticAccountSwitchEnabled = false
                UserDefaults.standard.set(false, forKey: CodexAutomaticSwitchPolicy.enabledDefaultsKey)
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "未完成切换恢复失败；自动切换已关闭：\(error.localizedDescription)", "Could not recover the interrupted switch. Automatic switching is disabled: \(error.localizedDescription)")
            }
            self.launchPendingProfileAfterInitialRefresh()
            self.startAfterPendingSwitchRecovery()
        }
    }

    @MainActor
    private func startAfterPendingSwitchRecovery() {
        guard hasStarted else { return }
        publicResetAnnouncements.configure(
            notifyLocally: { [weak self] announcement in
                guard let self, self.hasStarted, self.publicResetAnnouncements.enabled,
                    self.localNotificationsEnabled, !self.pausedAutomationFeatures.contains(.localNotification)
                else { return .inAppOnly }
                return await withCheckedContinuation { continuation in
                    NextLocalNotificationService.shared.submitResetAnnouncement(announcement) { result in
                        switch result {
                        case .success: continuation.resume(returning: .submitted)
                        case .failure(.notificationSubmissionFailed): continuation.resume(returning: .retry)
                        case .failure: continuation.resume(returning: .inAppOnly)
                        }
                    }
                }
            },
            canSend: { [weak self] in
                guard let self else { return false }
                return self.feishuNotificationsEnabled && self.feishuWebhookConfigured && !self.isUpdatingFeishuConnection
                    && !self.pausedAutomationFeatures.contains(.feishu)
            },
            send: { [weak self] announcement in
                guard let self else { return .failure(.cancelled) }
                let revision = self.feishuConfigurationRevision
                let admission = self.publicResetAnnouncements.deliveryAdmission()
                return await withCheckedContinuation { continuation in
                    self.feishuWebhookService.sendPublicResetAnnouncement(
                        announcement,
                        shouldSend: { [weak self] in
                            guard let self else { return false }
                            return admission() && self.hasStarted && self.publicResetAnnouncements.enabled && self.feishuNotificationsEnabled
                                && self.feishuWebhookConfigured && !self.isUpdatingFeishuConnection && revision == self.feishuConfigurationRevision
                                && !self.pausedAutomationFeatures.contains(.feishu)
                        },
                        completion: { [weak self] result in
                            Task { @MainActor [weak self] in
                                if admission(), let self, revision == self.feishuConfigurationRevision, case .failure(let error) = result {
                                    self.handleFeishuCredentialFailure(error)
                                }
                                continuation.resume(returning: result)
                            }
                        })
                }
            },
            channelRevision: { [weak self] kind in
                guard let self, self.hasStarted, self.publicResetAnnouncements.enabled else { return nil }
                return self.messageChannels.publicResetRevision(kind)
            },
            sendChannel: { [weak self] announcement, kind, revision in
                guard let self else { return .failure(.cancelled) }
                let admission = self.publicResetAnnouncements.deliveryAdmission()
                return await self.messageChannels.sendPublicReset(announcement, to: kind, revision: revision) { [weak self] in
                    guard let self else { return false }
                    return admission() && self.hasStarted && self.publicResetAnnouncements.enabled
                }
            },
            onChannelResult: { [weak self] result in
                guard let self else { return }
                self.messageChannels.recordPublicResetChannelResult(result)
                if result.state != .accepted {
                    self.recordOperationsIssue(
                        id: "public-reset-" + result.channel.rawValue,
                        summary: result.statusText)
                }
            })
        updateCodexForegroundState()
        if codexActivationObserver == nil {
            codexActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.updateCodexForegroundState(frontmostBundleID: application?.bundleIdentifier)
                if application?.bundleIdentifier == "com.openai.codex" {
                    self?.taskClient.start(reason: .startup)
                    self?.taskClient.refreshThreads()
                }
            }
        }
        taskClient.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.codexLiveTasks = snapshot
            self.rememberForegroundCodexThread(from: snapshot)
            self.evaluateAutomaticAccountSwitch()
            self.handleTaskCompletionSnapshot(from: snapshot)
            self.messageChannels.observeTaskSnapshot(snapshot)
        }
        taskClient.start(reason: .startup)
        configureAuthMonitoring()
        synchronizeMonitorWithCurrentCodex(announce: false)
        if dispatchQuotaRefreshObserver == nil {
            dispatchQuotaRefreshObserver = DistributedNotificationCenter.default().addObserver(
                forName: Self.dispatchQuotaRefreshNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.requestDispatchQuotaRefresh()
            }
        }
        refreshStaleOfficialProfiles()
        refreshWarmUpProfilesThenSchedule()
        systemTimeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.statisticsPreference.selection == .system else { return }
            self.scheduleStatisticsRollover()
            self.refresh(queueIfBusy: true)
        }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateVisualEnergyMode()
        }
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateVisualEnergyMode()
        }
        updateVisualEnergyMode()
        scheduleStatisticsRollover()
        scheduleFullRefreshTimer()
        scheduleWarmUpMaintenanceTimer()
        scheduleQuotaResetRefresh()
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.codexInactiveSince = nil
                self?.updateCodexForegroundState()
                self?.taskClient.refreshThreads()
                self?.refreshWarmUpProfilesThenSchedule()
            }
        }
    }

    private func refreshStaleOfficialProfiles() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let staleProfiles = profiles.filter {
            $0.id != selectedMonitorProfileID
                && ($0.officialProfile?.fetchedAt ?? .distantPast) < cutoff
        }
        guard !staleProfiles.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            let loaded = staleProfiles.compactMap { profile in
                CodexOfficialProfileReader.load(codexHomeURL: profile.codexHomeURL)
                    .map { (profile.id, $0) }
            }
            DispatchQueue.main.async {
                for (profileID, snapshot) in loaded {
                    try? self.profileStore.recordOfficialProfile(snapshot, for: profileID)
                }
                if !loaded.isEmpty { self.syncProfiles() }
            }
        }
    }

    func accountTaskAlias(for profile: CodexProfile) -> String? {
        guard !isPreview else { return nil }
        return configuredHubAccountAlias(for: profile)
    }

    private func configuredHubAccountAlias(for profile: CodexProfile) -> String? {
        if let alias = DispatchCodeCatalog.alias(for: profile.id) { return HubAccountTaskStatusResolver.canonicalAlias(alias) }
        // Monitoring-only accounts have no dispatch code. Match their existing Hub home without opting them in.
        let snapshotURL = DispatchParticipationPaths.supportDirectory().appendingPathComponent(DispatchParticipationPaths.snapshotFileName)
        guard let paths = try? DispatchParticipationPaths.live(snapshot: snapshotURL),
            let data = try? DispatchParticipationSync.readBoundedRegularFile(paths.hubConfig, maximumBytes: 256 * 1_024),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accounts = object["accounts"] as? [[String: Any]],
            accounts.count <= DispatchParticipationSync.maximumCatalogEntries
        else { return nil }
        let aliases = accounts.compactMap { ($0["alias"] as? String).map(HubAccountTaskStatusResolver.canonicalAlias) }
        guard aliases.count == accounts.count, !aliases.contains(""), Set(aliases).count == aliases.count else { return nil }
        let expectedHome = profile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
        let matches = accounts.filter {
            guard let home = $0["home"] as? String, home.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL == expectedHome
        }
        guard matches.count == 1, let alias = matches[0]["alias"] as? String else { return nil }
        return HubAccountTaskStatusResolver.canonicalAlias(alias)
    }

    private func refreshExpiredMembershipDates() {
        guard hasStarted, !isPreview, !isRefreshingWarmUpProfiles, warmingProfileID == nil,
            !isLoggingIn, !isLaunchingCodex, !isAccountSwitchTransactionActive
        else { return }
        let systemAccountKey = profiles.first(where: \.isSystemProfile)?.recordedAccountKey
        let candidates = Array(
            profiles.filter {
                CodexOfficialProfileReader.needsMembershipRefresh($0, systemAccountKey: systemAccountKey)
                    && hubAccountAlias(for: $0) != nil
            }.prefix(4))
        guard !candidates.isEmpty else { return }
        let candidateIDs = Set(candidates.map(\.id))
        let preference = statisticsPreference
        let cancellation = TokenMonitorCancellation()
        engineQuotaCancellation?.cancel()
        engineQuotaCancellation = cancellation
        isRefreshingWarmUpProfiles = true
        refreshingProfileIDs.formUnion(candidateIDs)
        warmUpRefreshStartedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            for candidate in candidates {
                guard !cancellation.isCancelled else { break }
                guard self.hasStarted, !self.isLoggingIn, !self.isLaunchingCodex,
                    !self.isAccountSwitchTransactionActive, self.warmingProfileID == nil,
                    let profile = self.profiles.first(where: { $0.id == candidate.id }),
                    CodexOfficialProfileReader.needsMembershipRefresh(profile, systemAccountKey: systemAccountKey),
                    let alias = self.hubAccountAlias(for: profile),
                    let overview = try? await HubConsoleModel.fetchInspectionOverview(),
                    HubWarmUpAvailability.resolve(for: alias, overview: overview) == .idle
                else { continue }
                guard self.hasStarted, !self.isLoggingIn, !self.isLaunchingCodex,
                    !self.isAccountSwitchTransactionActive, self.warmingProfileID == nil
                else { break }
                let attemptedAt = Date()
                do {
                    try self.profileStore.recordMembershipRefresh(at: attemptedAt, succeeded: false, for: profile.id)
                } catch { continue }
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "正在更新 \(AccountDisplay.profileName(profile)) 的会员日期…",
                    "Updating the subscription date for \(AccountDisplay.profileName(profile))…")
                let result = await Task.detached(priority: .utility) {
                    let context = RuntimeLoadContext.live(statisticsPreference: preference, codexHomeDirectory: profile.codexHomeURL, quotaCancellation: cancellation)
                    let reader = CodexUsageReader()
                    var messages: [String] = []
                    let account = reader.readQuotaSnapshot(
                        context: context, quotaOnly: true, messages: &messages, refreshingMembershipFor: profile)
                    let identity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: profile.codexHomeURL)
                    let succeeded = account.membershipRefreshSucceeded && profile.matchesRecordedCredential(identity)
                    let official = succeeded && !cancellation.isCancelled ? CodexOfficialProfileReader.load(codexHomeURL: profile.codexHomeURL) : nil
                    let snapshot = reader.finishingLoad(appServer: account, messages: messages, context: context, quotaOnly: true)
                    return (succeeded, official, snapshot)
                }.value
                guard self.hasStarted, !cancellation.isCancelled, self.engineQuotaCancellation === cancellation,
                    self.profiles.first(where: { $0.id == profile.id })?.recordedAccountKey == profile.recordedAccountKey
                else { break }
                let succeeded = result.0 && result.1 != nil
                try? self.profileStore.recordMembershipRefresh(at: attemptedAt, succeeded: succeeded, for: profile.id)
                if let official = result.1 { try? self.profileStore.recordOfficialProfile(official, for: profile.id) }
                if result.2.quotaReadSucceeded { try? self.profileStore.record(result.2, for: profile.id) }
                self.syncProfiles()
                self.accountManagerMessage =
                    succeeded
                    ? WidgetLanguage.storedOrAutomatic().text(
                        "\(AccountDisplay.profileName(profile)) 的会员日期已重新核查",
                        "Subscription date rechecked for \(AccountDisplay.profileName(profile)).")
                    : WidgetLanguage.storedOrAutomatic().text(
                        "\(AccountDisplay.profileName(profile)) 的会员日期刷新失败，稍后自动重试",
                        "Could not update the subscription date for \(AccountDisplay.profileName(profile)). It will retry later.")
            }
            guard self.engineQuotaCancellation === cancellation else { return }
            self.engineQuotaCancellation = nil
            self.isRefreshingWarmUpProfiles = false
            self.refreshingProfileIDs.subtract(candidateIDs)
            self.warmUpRefreshStartedAt = nil
            guard self.hasStarted else { return }
            if self.hasPendingDispatchQuotaRefresh {
                self.hasPendingDispatchQuotaRefresh = false
                self.requestDispatchQuotaRefresh()
            }
            self.scheduleWarmUpTimer()
        }
    }

    @MainActor
    func stop() {
        fullRefreshCancellation?.cancel()
        fullRefreshCancellation = nil
        identityRefreshCancellation?.cancel()
        identityRefreshCancellation = nil
        cancelStatisticsEngine()
        engineQuotaCancellation?.cancel()
        engineQuotaCancellation = nil
        feishuTaskCompletionObserver = FeishuTaskCompletionObserver()
        messageChannels.stop()
        invalidateAccountSwitchTransaction()
        desktopSwitchPreparationTask?.cancel()
        finishDesktopSwitchPreparation()
        publicResetAnnouncements.stop()
        terminalMonitors.values.forEach { $0.cancel() }
        terminalMonitors.removeAll()
        loginPreflightID = nil
        loginMaintenanceFinishes.values.forEach { $0.cancel() }
        loginMaintenanceFinishes.removeAll()
        hasStarted = false
        isTaskOverviewVisible = false
        taskClient.stop()
        codexLiveTasks = .disconnected
        fullTimer?.invalidate()
        statisticsRolloverTimer?.invalidate()
        statisticsFeedbackTimer?.invalidate()
        warmUpTimer?.invalidate()
        warmUpTimer = nil
        warmUpMaintenanceTimer?.invalidate()
        warmUpMaintenanceTimer = nil
        quotaResetRefreshTimer?.invalidate()
        quotaResetRefreshTimer = nil
        quotaResetRefreshAttempts.removeAll()
        // Invalidate an availability lookup that has not started its request.
        // Any late callback will release its lease through the current-request gate.
        warmingProfileID = nil
        warmUpRefreshStartedAt = nil
        isRefreshingWarmUpProfiles = false
        refreshingProfileIDs.removeAll()
        hasPendingDispatchQuotaRefresh = false
        accountActions.cancelLogin()
        stopAuthMonitoring()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let codexActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(codexActivationObserver)
            self.codexActivationObserver = nil
        }
        if let dispatchQuotaRefreshObserver {
            DistributedNotificationCenter.default().removeObserver(dispatchQuotaRefreshObserver)
            self.dispatchQuotaRefreshObserver = nil
        }
        codexInactiveSince = nil
        isCodexFrontmost = false
        foregroundCodexThread = nil
        if let systemTimeZoneObserver {
            NotificationCenter.default.removeObserver(systemTimeZoneObserver)
            self.systemTimeZoneObserver = nil
        }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
        if let thermalStateObserver {
            NotificationCenter.default.removeObserver(thermalStateObserver)
            self.thermalStateObserver = nil
        }
        visualEnergyMode = .suspended
        PerformanceMonitor.shared.flush()
    }

    func refresh(queueIfBusy: Bool = false, scheduleWarmUpAfterRefresh: Bool = true) {
        guard !isRefreshing,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive
        else {
            if queueIfBusy { hasPendingRefresh = true }
            return
        }
        refreshStatisticsEngine()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let cancellation = TokenMonitorCancellation()
        fullRefreshCancellation?.cancel()
        fullRefreshCancellation = cancellation
        let preference = statisticsPreference
        let profileID = selectedMonitorProfileID
        let codexHomeDirectory = profileStore.effectiveCredentialHome(for: profileID)
        ignoresAuthChangesUntil = Date().addingTimeInterval(5)
        isRefreshing = true
        let performanceSpan = PerformanceMonitor.shared.begin(.fullRefresh)

        DispatchQueue.global(qos: .utility).async {
            let multiSnapshot = MultiRuntimeUsageReader().load(
                statisticsPreference: preference,
                generation: generation,
                codexHomeDirectory: codexHomeDirectory,
                quotaCancellation: cancellation
            )
            let officialProfile =
                cancellation.isCancelled
                ? nil
                : codexHomeDirectory.flatMap {
                    CodexOfficialProfileReader.load(codexHomeURL: $0)
                }
            let credentialIdentity = codexHomeDirectory.flatMap {
                CodexOfficialProfileReader.credentialIdentity(codexHomeURL: $0)
            }
            DispatchQueue.main.async {
                PerformanceMonitor.shared.end(performanceSpan)
                guard self.fullRefreshCancellation === cancellation, !cancellation.isCancelled else { return }
                self.fullRefreshCancellation = nil
                if generation == self.refreshGeneration,
                    multiSnapshot.statisticsIdentity.preference == self.statisticsPreference
                {
                    let incoming = multiSnapshot.displaySnapshot(for: .codex)
                    let profile = self.profiles.first { $0.id == profileID }
                    let hasIdentity = incoming.account?.email?.isEmpty == false
                    let duplicate = incoming.account?.email.flatMap { email in
                        self.profiles.first {
                            $0.id != profileID
                                && $0.lastSnapshot?.email != nil
                                && $0.matchesRecordedAccount(email: email)
                                && ($0.lastSnapshot?.accountID == nil
                                    || $0.lastSnapshot?.accountID == credentialIdentity?.accountID)
                        }
                    }
                    let identityMismatch =
                        profile.map {
                            (incoming.quotaReadSucceeded || hasIdentity)
                                && (!$0.matchesRecordedAccount(email: incoming.account?.email)
                                    || !$0.matchesRecordedCredential(credentialIdentity))
                        } ?? false
                    if let profile, profile.isSystemProfile,
                        let duplicate, !duplicate.isSystemProfile
                    {
                        try? self.profileStore.selectMonitor(duplicate.id)
                        self.syncProfiles()
                        self.configureAuthMonitoring()
                        self.clearDisplayedAccount()
                        self.hasPendingRefresh = true
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "当前 Codex 登录的是 \(AccountDisplay.profileName(duplicate))，已切换监控", "Codex is signed in as \(AccountDisplay.profileName(duplicate)). Monitoring updated.")
                    } else if identityMismatch {
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "检测到 CODEX_HOME 已登录另一个账号，已阻止额度串号", "This profile is signed in to a different account. Its limits were not saved.")
                    } else {
                        self.apply(multiSnapshot)
                        self.captureCurrentProfile()
                        if let officialProfile {
                            try? self.profileStore.recordOfficialProfile(officialProfile, for: profileID)
                            self.syncProfiles()
                        }
                        if let duplicate, !duplicate.isSystemProfile, let profile {
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "\(AccountDisplay.profileName(profile)) 与 \(AccountDisplay.profileName(duplicate)) 登录的是同一账号",
                                "\(AccountDisplay.profileName(profile)) and \(AccountDisplay.profileName(duplicate)) use the same account.")
                        }
                    }
                    self.cacheStatisticsSnapshot(multiSnapshot)
                    if self.isSwitchingStatisticsTimeZone {
                        self.finishStatisticsTimeZoneSwitch()
                    }
                }
                self.isRefreshing = false
                self.lastFullRefreshCompletedAt = Date()
                self.scheduleFullRefreshTimer()
                if scheduleWarmUpAfterRefresh {
                    self.scheduleWarmUpTimer()
                }
                if self.hasPendingRefresh {
                    self.hasPendingRefresh = false
                    self.refresh()
                } else {
                    self.taskClient.start(reason: .startup)
                    self.taskClient.refreshThreads()
                    self.evaluateAutomaticAccountSwitch()
                }
            }
        }
    }

    func refreshQuotas() {
        refreshWarmUpProfilesThenSchedule(performWarmUpAfterRefresh: false)
        refresh(scheduleWarmUpAfterRefresh: false)
    }

    private func updateCodexForegroundState(frontmostBundleID: String? = nil) {
        let bundleID = frontmostBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let codexIsFrontmost = bundleID == "com.openai.codex"
        if codexIsFrontmost, !isCodexFrontmost {
            foregroundCodexThread = nil
        }
        isCodexFrontmost = codexIsFrontmost
        if codexIsFrontmost {
            codexInactiveSince = nil
            rememberForegroundCodexThread(from: codexLiveTasks)
        } else if codexInactiveSince == nil {
            codexInactiveSince = Date()
        }
    }

    private func rememberForegroundCodexThread(
        from snapshot: CodexTaskLiveSnapshot,
        now: Date = Date()
    ) {
        guard isCodexFrontmost,
            let threadID = CodexSessionOpener.uniqueActiveThreadID(in: snapshot, now: now)
        else { return }
        foregroundCodexThread = (threadID, now)
    }

    private func recentForegroundCodexThreadID(
        in taskBoard: TaskBoard?,
        now: Date = Date()
    ) -> String? {
        guard let capture = foregroundCodexThread,
            now.timeIntervalSince(capture.capturedAt) >= 0,
            now.timeIntervalSince(capture.capturedAt) <= 15 * 60,
            CodexSessionOpener.containsThread(capture.id, in: taskBoard)
        else { return nil }
        return capture.id
    }

    private func presentAccountSwitchBlock(_ message: String, isAutomatic: Bool) {
        accountManagerMessage = message
        if !isAutomatic { accountSwitchAlertMessage = message }
    }

    func updateStatisticsTimeZone(_ preference: StatisticsTimeZonePreference) {
        let repaired = preference.repaired()
        guard repaired != statisticsPreference else { return }
        refreshGeneration &+= 1
        statisticsPreference = repaired
        StatisticsTimeZonePreferenceStore.save(repaired)
        scheduleStatisticsRollover()
        isSwitchingStatisticsTimeZone = true
        statisticsTransitionMessage = statisticsSwitchingMessage(for: repaired)

        let key = statisticsCacheKey(for: repaired)
        if let cached = validCachedStatisticsSnapshot(forKey: key) {
            let identity = StatisticsIdentity(
                preference: repaired,
                resolvedIdentifier: StatisticsContext(preference: repaired, now: Date()).resolvedIdentifier,
                generation: refreshGeneration,
                now: Date()
            )
            let rebound = MultiRuntimeUsageSnapshot(
                refreshedAt: cached.refreshedAt,
                runtimes: cached.runtimes,
                aggregate: cached.aggregate,
                leadership: cached.leadership,
                statisticsIdentity: identity
            )
            apply(rebound)
            cacheStatisticsSnapshot(rebound)
            finishStatisticsTimeZoneSwitch(cached: true)
            return
        }
        refresh(queueIfBusy: true)
    }

    private func statisticsCacheKey(for preference: StatisticsTimeZonePreference) -> String {
        StatisticsContext(preference: preference, now: Date()).resolvedIdentifier
    }

    private func validCachedStatisticsSnapshot(forKey key: String) -> MultiRuntimeUsageSnapshot? {
        guard let entry = statisticsSnapshotCache[key],
            Date().timeIntervalSince(entry.cachedAt) <= statisticsSnapshotCacheTTL
        else {
            statisticsSnapshotCache.removeValue(forKey: key)
            statisticsSnapshotCacheOrder.removeAll { $0 == key }
            return nil
        }
        statisticsSnapshotCacheOrder.removeAll { $0 == key }
        statisticsSnapshotCacheOrder.append(key)
        return entry.snapshot
    }

    private func cacheStatisticsSnapshot(_ snapshot: MultiRuntimeUsageSnapshot) {
        let key = snapshot.statisticsIdentity.resolvedIdentifier
        statisticsSnapshotCache[key] = StatisticsSnapshotCacheEntry(snapshot: snapshot, cachedAt: Date())
        statisticsSnapshotCacheOrder.removeAll { $0 == key }
        statisticsSnapshotCacheOrder.append(key)
        while statisticsSnapshotCacheOrder.count > statisticsSnapshotCacheLimit {
            let evicted = statisticsSnapshotCacheOrder.removeFirst()
            statisticsSnapshotCache.removeValue(forKey: evicted)
        }
    }

    private func statisticsSwitchingMessage(for preference: StatisticsTimeZonePreference) -> String {
        let identifier = StatisticsContext(preference: preference, now: Date()).resolvedIdentifier
        return WidgetLanguage.storedOrAutomatic().text("正在切换到 \(identifier)…", "Switching to \(identifier)…")
    }

    private func finishStatisticsTimeZoneSwitch(cached: Bool = false) {
        isSwitchingStatisticsTimeZone = false
        let identifier = multiRuntimeSnapshot.statisticsIdentity.resolvedIdentifier
        statisticsTransitionMessage =
            cached
            ? WidgetLanguage.storedOrAutomatic().text("已切换到 \(identifier) · 缓存", "Switched to \(identifier) · cached")
            : WidgetLanguage.storedOrAutomatic().text("已切换到 \(identifier)", "Switched to \(identifier)")
        statisticsFeedbackTimer?.invalidate()
        statisticsFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.statisticsTransitionMessage = nil
        }
    }

    private func scheduleStatisticsRollover() {
        statisticsRolloverTimer?.invalidate()
        let context = StatisticsContext(preference: statisticsPreference, now: Date())
        let start = context.calendar.startOfDay(for: context.now)
        guard let nextDay = context.calendar.date(byAdding: .day, value: 1, to: start) else { return }
        statisticsRolloverTimer = Timer(fire: nextDay.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            self?.scheduleStatisticsRollover()
            self?.refresh(queueIfBusy: true)
        }
        if let statisticsRolloverTimer {
            RunLoop.main.add(statisticsRolloverTimer, forMode: .common)
        }
    }

    func selectRuntime(_ scope: RuntimeScope) {
        let nextScope = visibleRuntimeScopes.contains(scope) ? scope : (visibleRuntimeScopes.first ?? scope)
        selectedRuntimeScope = nextScope
        snapshot = multiRuntimeSnapshot.displaySnapshot(for: nextScope)
        updateLocalLifetimeHighWater()
    }

    func requestTaskFocus(scope: RuntimeScope, threadID: String?) {
        selectRuntime(scope)
        taskFocusRequest = TaskFocusRequest(id: UUID(), runtimeScope: scope, threadID: threadID)
    }

    func attentionItems(for scopes: [RuntimeScope], updateResult: AppUpdateResult) -> [TaskAttentionItem] {
        var items: [TaskAttentionItem] = []
        for scope in scopes {
            guard let runtime = runtimeSnapshot(for: scope) else { continue }
            items.append(contentsOf: runtime.snapshot.taskBoard?.attentionItems(scope: scope) ?? [])
            if runtime.status == .unavailable || runtime.status == .stale || runtime.status == .snapshotNeeded {
                items.append(
                    TaskAttentionItem(
                        id: "data-\(scope.runtimeId)-\(runtime.status.rawValue)",
                        kind: .dataIssue,
                        runtimeScope: scope,
                        threadID: nil,
                        title: scope.displayName,
                        since: runtime.snapshot.refreshedAt
                    ))
            }
        }
        if updateResult.status == .updateAvailable {
            items.append(
                TaskAttentionItem(
                    id: "update-\(updateResult.latestVersionLabel ?? "available")",
                    kind: .update,
                    runtimeScope: nil,
                    threadID: nil,
                    title: updateResult.latestVersionLabel ?? "AiGoodBro",
                    since: updateResult.checkedAt
                ))
        }
        return items
    }

    func highestPriorityAttention(
        for scopes: [RuntimeScope],
        updateResult: AppUpdateResult
    ) -> TaskAttentionItem? {
        TaskAttentionSelector.highestPriority(attentionItems(for: scopes, updateResult: updateResult))
    }

    func runtimeSnapshot(for scope: RuntimeScope) -> RuntimeUsageSnapshot? {
        runtimeSnapshots.first { $0.scope == scope }
    }

    func updateVisibleRuntimeScopes(_ scopes: [RuntimeScope]) {
        visibleRuntimeScopes = scopes.isEmpty ? RuntimeScope.allCases : scopes
        if !visibleRuntimeScopes.contains(selectedRuntimeScope) {
            selectRuntime(visibleRuntimeScopes.first ?? selectedRuntimeScope)
        }
    }

    func setMainWindowActive(_ isActive: Bool) {
        guard isMainWindowActive != isActive else { return }
        isMainWindowActive = isActive
        updateVisualEnergyMode()
        guard hasStarted else { return }
        scheduleFullRefreshTimer()
        if isActive {
            refreshIfStale(maximumAge: foregroundFullRefreshInterval)
        }
    }

    func setTaskOverviewVisible(_ isVisible: Bool) {
        guard isTaskOverviewVisible != isVisible else { return }
        isTaskOverviewVisible = isVisible
        guard hasStarted else { return }
        scheduleFullRefreshTimer()
        guard isVisible else { return }
        refreshIfStale(maximumAge: foregroundFullRefreshInterval)
        taskClient.start(reason: .startup)
        taskClient.refreshThreads()
    }

    private func updateVisualEnergyMode() {
        guard isMainWindowActive else {
            visualEnergyMode = .suspended
            return
        }

        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled || processInfo.thermalState != .nominal {
            visualEnergyMode = .constrained
        } else {
            visualEnergyMode = .normal
        }
    }

    func refreshIfStale(maximumAge: TimeInterval) {
        // An in-flight full refresh will make the snapshot fresh; queueing a
        // second one here commonly doubles startup work when occlusion state
        // arrives just after the initial load begins.
        guard !isRefreshing else { return }
        guard let lastFullRefreshCompletedAt else {
            refresh(queueIfBusy: true)
            return
        }
        guard Date().timeIntervalSince(lastFullRefreshCompletedAt) >= maximumAge else { return }
        refresh(queueIfBusy: true)
    }

    func setTaskBoardSelected(_ isSelected: Bool) {
        // Legacy dashboard compatibility. Account monitoring has no task polling.
    }

    func setStatusPopoverVisible(_ isVisible: Bool) {
        // Account monitoring has no live task stream.
    }

    private func scheduleFullRefreshTimer() {
        fullTimer?.invalidate()
        fullTimer = nil
        guard hasStarted else { return }

        let interval =
            isMainWindowActive || isTaskOverviewVisible
            ? foregroundFullRefreshInterval
            : backgroundFullRefreshInterval
        let elapsed = lastFullRefreshCompletedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        let nextDelay = max(1, interval - elapsed)
        let timer = Timer(
            fire: Date().addingTimeInterval(nextDelay),
            interval: interval,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        fullTimer = timer
    }

    func setAccountRefreshFrequency(_ frequency: AccountRefreshFrequency) {
        guard accountRefreshFrequency != frequency else { return }
        accountRefreshFrequency = frequency
        if !isPreview { UserDefaults.standard.set(frequency.rawValue, forKey: AccountRefreshFrequency.defaultsKey) }
        scheduleFullRefreshTimer()
        scheduleWarmUpMaintenanceTimer()
    }

    private func apply(_ multiSnapshot: MultiRuntimeUsageSnapshot) {
        let performanceSpan = PerformanceMonitor.shared.begin(.statePublish)
        defer { PerformanceMonitor.shared.end(performanceSpan) }
        let reconciledRuntimes = RuntimeQuotaContinuity.reconcile(
            previous: runtimeSnapshots,
            incoming: multiSnapshot.runtimes
        )
        let reconciledSnapshot = MultiRuntimeUsageSnapshot(
            refreshedAt: multiSnapshot.refreshedAt,
            runtimes: reconciledRuntimes,
            aggregate: multiSnapshot.aggregate,
            leadership: multiSnapshot.leadership,
            statisticsIdentity: multiSnapshot.statisticsIdentity
        )
        let nextScope = reconciledSnapshot.defaultScope(
            preferred: selectedRuntimeScope,
            allowedScopes: visibleRuntimeScopes
        )
        multiRuntimeSnapshot = reconciledSnapshot
        runtimeSnapshots = reconciledRuntimes
        selectedRuntimeScope = nextScope
        snapshot = reconciledSnapshot.displaySnapshot(for: nextScope)
        updateLocalLifetimeHighWater()
    }

    /// Desktop sign-in and the account used for quota monitoring are separate
    /// choices. Follow the live Desktop identity only while monitoring the
    /// system profile itself or when the saved choice no longer exists.
    static func shouldFollowDesktopIdentity(
        selectedMonitorProfileID: String,
        systemProfileID: String,
        existingProfileIDs: Set<String>
    ) -> Bool {
        !existingProfileIDs.contains(selectedMonitorProfileID)
            || selectedMonitorProfileID == systemProfileID
    }

    @discardableResult
    private func captureCurrentProfile() -> Bool {
        let effectiveHome = profileStore.effectiveCredentialHome(for: selectedMonitorProfileID)
        let credentialIdentity = effectiveHome.flatMap {
            CodexOfficialProfileReader.credentialIdentity(codexHomeURL: $0)
        }
        if snapshot.quotaReadSucceeded,
            let profile = selectedMonitorProfile,
            !profile.matchesRecordedAccount(email: snapshot.account?.email)
                || !profile.matchesRecordedCredential(credentialIdentity)
        {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号身份不一致，未覆盖原额度快照", "Account identity mismatch. The previous limit snapshot was not overwritten.")
            return false
        }
        do {
            if let profile = selectedMonitorProfile {
                noteUnexpectedWarmUpResets(previous: profile, current: snapshot)
            }
            try profileStore.record(snapshot, for: selectedMonitorProfileID)
            observeOfficialQuotaChanges(snapshot, profileID: selectedMonitorProfileID)
            if let effectiveHome,
                let systemHome = profiles.first(where: \.isSystemProfile)?.codexHomeURL,
                effectiveHome.standardizedFileURL == systemHome.standardizedFileURL
            {
                try profileStore.syncSystemAuthToMatchingManagedProfiles()
            }
            syncProfiles()
            return true
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("快照保存失败：\(error.localizedDescription)", "Could not save the snapshot: \(error.localizedDescription)")
            return false
        }
    }

    private func syncProfiles() {
        profiles = profileStore.profiles
        let activeProfileIDs = Set(profiles.map(\.id))
        quotaResetRefreshAttempts = quotaResetRefreshAttempts.filter { activeProfileIDs.contains($0.key) }
        let observed = Self.observedOfficialLifetimeTokens(in: profiles)
        officialAccountsLifetimeTokens =
            isPreview
            ? observed
            : Self.persistedHighWater(forKey: Self.officialLifetimeHighWaterKey, observed: observed)
        selectedMonitorProfileID = profileStore.selectedMonitorProfileID
        selectedLaunchProfileID = profileStore.selectedLaunchProfileID
        scheduleQuotaResetRefresh()
    }

    private func updateLocalLifetimeHighWater() {
        let observed = snapshot.local.flatMap { local in
            local.hasCompleteTotals ? (local.allAgentsLifetimeTokens ?? local.lifetimeTokens) : nil
        }
        localAllAgentsLifetimeTokens = Self.persistedHighWater(
            forKey: Self.localLifetimeHighWaterKey,
            observed: observed
        )
    }

    private static func observedOfficialLifetimeTokens(in profiles: [CodexProfile]) -> Int64? {
        let totals = CodexProfile.groupsByRecordedAccount(profiles).compactMap { group in
            group.compactMap { $0.officialProfile?.lifetimeTokens }.max()
        }
        return totals.isEmpty ? nil : totals.reduce(0, +)
    }

    private static func persistedHighWater(forKey key: String, observed: Int64?) -> Int64? {
        let stored = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value ?? 0
        let locked = max(stored, observed ?? 0)
        if locked > stored { UserDefaults.standard.set(locked, forKey: key) }
        return locked > 0 ? locked : nil
    }

    private func clearDisplayedAccount() {
        refreshGeneration &+= 1
        runtimeSnapshots = []
        multiRuntimeSnapshot = .empty
        snapshot = .empty
    }

    private func configureAuthMonitoring() {
        cancelAuthSources()
        guard hasStarted, let profile = profiles.first(where: \.isSystemProfile) else { return }
        monitoredAuthState = authFileState(for: profile)

        authDirectorySource = makeAuthSource(
            path: profile.codexHomePath,
            events: [.write, .delete, .rename],
            forceRefresh: false
        )
        let authURL = profile.codexHomeURL.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: authURL.path) {
            authFileSource = makeAuthSource(
                path: authURL.path,
                events: [.write, .delete, .rename, .attrib],
                forceRefresh: true
            )
        }
    }

    private func makeAuthSource(
        path: String,
        events: DispatchSource.FileSystemEvent,
        forceRefresh: Bool
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: events,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleAuthChange(forceRefresh: forceRefresh)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func handleAuthChange(forceRefresh: Bool) {
        guard let profile = profiles.first(where: \.isSystemProfile) else { return }
        let nextState = authFileState(for: profile)
        guard forceRefresh || nextState != monitoredAuthState else { return }
        let wasSignedIn = monitoredAuthState?.exists == true
        monitoredAuthState = nextState
        if isAccountSwitchTransactionActive {
            configureAuthMonitoring()
            return
        }
        if let ignoresAuthChangesUntil, Date() < ignoresAuthChangesUntil {
            configureAuthMonitoring()
            return
        }
        _ = captureCurrentProfile()
        accountManagerMessage =
            wasSignedIn && !nextState.exists
            ? WidgetLanguage.storedOrAutomatic().text("检测到账号退出，已保存最后一次额度", "Sign-out detected. The last known limits were saved.")
            : WidgetLanguage.storedOrAutomatic().text("检测到登录状态变化，正在核对账号…", "Sign-in state changed. Verifying the account…")

        authRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.synchronizeMonitorWithCurrentCodex(announce: true)
        }
        authRefreshWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
        configureAuthMonitoring()
    }

    private func synchronizeMonitorWithCurrentCodex(announce: Bool) {
        guard let systemProfile = profiles.first(where: \.isSystemProfile) else {
            refresh(queueIfBusy: true)
            return
        }
        let authExists = authFileState(for: systemProfile).exists
        let preference = statisticsPreference
        let cancellation = TokenMonitorCancellation()
        identityRefreshCancellation?.cancel()
        identityRefreshCancellation = cancellation
        DispatchQueue.global(qos: .utility).async {
            let context = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: systemProfile.codexHomeURL,
                quotaCancellation: cancellation
            )
            let systemSnapshot = CodexUsageReader().load(context: context)
            let officialProfile = cancellation.isCancelled ? nil : CodexOfficialProfileReader.load(codexHomeURL: systemProfile.codexHomeURL)
            DispatchQueue.main.async {
                guard self.identityRefreshCancellation === cancellation, !cancellation.isCancelled else { return }
                self.identityRefreshCancellation = nil
                let previousMonitorID = self.profileStore.selectedMonitorProfileID
                do {
                    if systemSnapshot.account?.email?.isEmpty == false {
                        try self.profileStore.record(
                            systemSnapshot,
                            for: systemProfile.id,
                            allowAccountOnly: true,
                            allowSystemAccountChange: true
                        )
                        if let officialProfile {
                            try self.profileStore.recordOfficialProfile(officialProfile, for: systemProfile.id)
                        }
                        do {
                            try self.profileStore.syncSystemAuthToMatchingManagedProfiles()
                        } catch {
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "同账号凭据同步失败：\(error.localizedDescription)", "Could not sync the matching account's sign-in: \(error.localizedDescription)")
                        }
                    }
                    let shouldFollow = Self.shouldFollowDesktopIdentity(
                        selectedMonitorProfileID: self.profileStore.selectedMonitorProfileID,
                        systemProfileID: systemProfile.id,
                        existingProfileIDs: Set(self.profileStore.profiles.map(\.id))
                    )
                    if shouldFollow {
                        if systemSnapshot.account?.email?.isEmpty == false {
                            _ = try self.profileStore.selectMonitorForSystemAccount()
                        } else {
                            try self.profileStore.selectMonitor(systemProfile.id)
                        }
                    }
                    self.syncProfiles()
                    self.configureAuthMonitoring()
                    if previousMonitorID != self.selectedMonitorProfileID {
                        self.clearDisplayedAccount()
                    }
                    if announce && !self.isLoggingIn && !self.isAccountSwitchTransactionActive {
                        self.accountManagerMessage =
                            systemSnapshot.account?.email?.isEmpty == false
                            ? WidgetLanguage.storedOrAutomatic().text("已同步当前 Codex 登录账号与剩余额度", "Current Codex account and remaining limits synced.")
                            : (authExists
                                ? WidgetLanguage.storedOrAutomatic().text("正在核对当前 Codex 登录账号", "Verifying the current Codex account.")
                                : WidgetLanguage.storedOrAutomatic().text("当前 Codex 尚未登录", "Codex is not signed in."))
                    }
                } catch {
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "同步当前 Codex 账号失败：\(error.localizedDescription)", "Could not sync the current Codex account: \(error.localizedDescription)")
                }
                self.refresh(queueIfBusy: true)
            }
        }
    }

    private func authFileState(for profile: CodexProfile) -> AuthFileState {
        let path = profile.codexHomeURL.appendingPathComponent("auth.json").path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return AuthFileState(exists: false, size: nil, modifiedAt: nil, fileNumber: nil)
        }
        return AuthFileState(
            exists: true,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            modifiedAt: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func cancelAuthSources() {
        authDirectorySource?.cancel()
        authFileSource?.cancel()
        authDirectorySource = nil
        authFileSource = nil
    }

    private func stopAuthMonitoring() {
        authRefreshWorkItem?.cancel()
        authRefreshWorkItem = nil
        monitoredAuthState = nil
        ignoresAuthChangesUntil = nil
        cancelAuthSources()
    }

}
