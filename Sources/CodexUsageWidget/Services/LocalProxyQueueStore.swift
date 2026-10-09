import AppKit
import Combine
import Darwin
import Foundation
import Security

/// A release is acknowledged only after the exact registry row is terminal,
/// but its MainActor mirror cleanup may run later. Keep paid admission closed
/// for that exact run/profile until the refresh fence is installed.
private final class LocalProxyReleaseFence: @unchecked Sendable {
    private struct Tuple: Hashable {
        let runID: String
        let requestID: String
        let profileID: String
        let leaseID: String
    }
    private let lock = NSLock()
    private var pending: Set<Tuple> = []

    func mark(runID: String, requestID: String, profileID: String, leaseID: String) {
        lock.lock(); defer { lock.unlock() }
        pending.insert(Tuple(runID: runID, requestID: requestID, profileID: profileID, leaseID: leaseID))
    }

    func clear(runID: String, requestID: String, profileID: String, leaseID: String) {
        lock.lock(); defer { lock.unlock() }
        pending.remove(Tuple(runID: runID, requestID: requestID, profileID: profileID, leaseID: leaseID))
    }

    func clear(runID: String) {
        lock.lock(); defer { lock.unlock() }
        pending = pending.filter { $0.runID != runID }
    }

    func contains(runID: String, profileID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pending.contains { $0.runID == runID && $0.profileID == profileID }
    }
}

private let localProxyReleaseFence = LocalProxyReleaseFence()

/// Keeps the last displayed value separate from the queue's current control state.
/// Routine changes are throttled to the latest value at a fixed deadline;
/// explicit actions can publish immediately without waiting for that deadline.
struct LocalProxyDisplayPublicationGate<Value: Equatable> {
    enum Decision: Equatable {
        case unchanged
        case publish
        case deferUntil(TimeInterval)
    }

    private(set) var publishedValue: Value
    private(set) var lastPublishedAt: TimeInterval?
    let interval: TimeInterval

    init(initial: Value, interval: TimeInterval = 60) {
        publishedValue = initial
        self.interval = interval
    }

    mutating func offer(_ value: Value, at uptime: TimeInterval, immediate: Bool = false) -> Decision {
        guard value != publishedValue else { return .unchanged }
        if !immediate, let lastPublishedAt, uptime < lastPublishedAt + interval {
            return .deferUntil(lastPublishedAt + interval)
        }
        publishedValue = value
        lastPublishedAt = uptime
        return .publish
    }
}

/// Independent opt-in queue. Construction never starts a helper or opens auth files.
@MainActor final class LocalProxyQueueStore: ObservableObject {
    enum ExitReason: String {
        case requestedStop = "requested_stop"
        case startupFailure = "startup_failure"
        case controlFailure = "control_failure"
        case unexpectedExit = "unexpected_exit"
    }

    // Control/admission always reads current rows. Only the published display copy
    // drives the queue window and the Edge Dock presentation.
    private(set) var rows: [LocalProxyQueueRow] = []
    @Published private(set) var displayRows: [LocalProxyQueueRow] = []
    private var displayGate = LocalProxyDisplayPublicationGate<[LocalProxyQueueRow]>(initial: [])
    private var displayPublishTask: Task<Void, Never>?
    private var resetCreditRefreshTarget: CodexProfile?
    private var manualRefreshTargets: [String: CodexProfile] = [:]
    @Published private(set) var phase: LocalProxyPhase = .stopped
    @Published private(set) var membershipChangeWaiting = false
    @Published private(set) var endpoint: String?
    enum PreferencesFailure { case read, save }
    @Published private(set) var preferencesFailure: PreferencesFailure?
    @Published private(set) var issue: String?
    var visibleIssue: String? {
        preferencesFailure != nil && issue == message(.unavailable) ? nil : issue
    }
    @Published private(set) var isEnabled = false
    @Published private(set) var desktopAvailable = false
    @Published private(set) var creditFallbackEnabled = false
    @Published private(set) var creditPrimaryFloor = 2000
    @Published private(set) var creditSecondaryFloor = 1500
    var canEdit: Bool { process == nil && (phase == .stopped || phase == .failed) && leases.isEmpty }
    var canReorder: Bool {
        !usageStore.isPreview && !preferencesBlocked && !finishing
            && (canEdit || (phase == .running && process?.isRunning == true))
    }
    var canEditPolicy: Bool { canReorder }
    func canSetAccountLast(id: String) -> Bool {
        canReorder && rows.contains(where: { $0.id == id })
    }
    func canEditPolicy(for id: String) -> Bool {
        canEditPolicy && rows.contains(where: { $0.id == id }) && (canEdit || isRegisteredBindingCurrent(id))
    }
    func hasStaleRunningBinding(for id: String) -> Bool {
        phase == .running && process?.isRunning == true && rows.contains(where: { $0.id == id })
            && registeredPool[id] != nil && !isRegisteredBindingCurrent(id)
    }
    var canStart: Bool { canEdit && rows.count <= 100 && rows.contains(where: \.isEnabled) && !usageStore.isPreview && !preferencesBlocked }
    func canToggleAccount(id: String) -> Bool {
        guard !usageStore.isPreview, !preferencesBlocked, !finishing, rows.contains(where: { $0.id == id }) else { return false }
        if canEdit { return true }
        guard phase == .running, process?.isRunning == true, registeredPool[id] != nil else { return false }
        // Existing requests retain their order and admitted leases. Removal
        // also blocks later admissions from an older waiting/retrying request;
        // unrelated traffic must not lock every account's participation switch.
        // Removal remains available even when the profile's current identity
        // differs; re-enabling requires the binding verified at startup.
        return preferences.enabledIDs.contains(id) || isRegisteredBindingCurrent(id)
    }
    var canStop: Bool { process != nil && phase != .stopping }
    var canFinishTermination: Bool { process == nil && leases.isEmpty }
    var requiresStopConfirmation: Bool {
        process != nil || !leases.isEmpty || phase == .starting || phase == .stopping
    }

    private let usageStore: UsageStore
    private let directory: URL
    private var preferences = LocalProxyPreferences()
    private var preferencesBlocked = false
    private var policyRevision: UInt64 = 0
    private var observation: AnyCancellable?
    private var orderObservation: AnyCancellable?
    private var process: Process?
    private var input: FileHandle?
    private var bridge: LocalProxyBridge?
    private var runID: String?
    private var runDirectory: URL?
    private var controlKey: String?
    private var clientKey: String?
    private var desktopConnection: URL?
    private var activeIDs = Set<String>()
    private struct PoolBinding {
        let home: URL
        let account: String
        let accountID: String
    }
    private struct MembershipSnapshot {
        let order: [String]
        let lastResortIDs: [String]
        let deferredIDs: [String]
        let creditFallback: Bool
        let capturedAt: TimeInterval
    }
    private var registeredPool: [String: PoolBinding] = [:]
    private var membershipSnapshots: [String: MembershipSnapshot] = [:]
    // HTTP requests have a 15-minute bound. Completed requests send an
    // idempotent order_end; this timeout bounds leaked snapshots after failure.
    private let membershipSnapshotLifetime: TimeInterval = 16 * 60
    private let maximumMembershipSnapshots = 4096
    private struct Lease {
        let id: String
        let profileID: String
        let requestID: String
        let runID: String
        var isAdmitted = false
    }
    private var leases: [String: Lease] = [:]
    private var accountStates: [String: String] = [:]
    private var cooldowns: [String: Date] = [:]
    private var balanceRefreshLeases = Set<String>()
    private var creditRefreshAfter: [String: Date] = [:]
    private var outputTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var finishing = false
    private var requestedExitReason: ExitReason?

    init(usageStore: UsageStore, previewPreferences: LocalProxyPreferences? = nil) {
        self.usageStore = usageStore
        directory = DispatchParticipationPaths.supportDirectory()
        if usageStore.isPreview, let previewPreferences, previewPreferences.validAccountPolicies,
            previewPreferences.validLastIDs, previewPreferences.validLastOverrides {
            preferences = previewPreferences
        }
        if !usageStore.isPreview {
            do {
                if let data = try DispatchParticipationSync.readBoundedRegularFile(
                    directory.appendingPathComponent("local-proxy-queue-v1.json"), maximumBytes: 65536, allowMissing: true)
                {
                    let saved = try JSONDecoder().decode(LocalProxyPreferences.self, from: data)
                    guard saved.schemaVersion == 1, saved.order.count <= 1000, Set(saved.order).count == saved.order.count,
                        saved.enabledIDs.count <= 1000, saved.validAccountPolicies, saved.validLastIDs, saved.validLastOverrides,
                        LocalProxyPreferences.validCreditFloors(primary: saved.creditFloors.primary, secondary: saved.creditFloors.secondary)
                    else { throw LocalProxyFailure.unavailable }
                    preferences = saved
                }
            } catch {
                preferencesBlocked = true
                preferencesFailure = .read
                issue = message(.unavailable)
            }
        }
        isEnabled = preferences.isEnabled
        creditFallbackEnabled = preferences.creditFallback == true
        creditPrimaryFloor = preferences.creditFloors.primary
        creditSecondaryFloor = preferences.creditFloors.secondary
        rebuildRows()
        observation = usageStore.$profiles.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildRows() }
        }
        orderObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildRows() }
        }
    }

    func setOptIn(_ value: Bool) {
        guard canEdit, !usageStore.isPreview, !preferencesBlocked else { return }
        let previous = preferences
        preferences.isEnabled = value
        guard savePreferences() else {
            preferences = previous
            return
        }
        isEnabled = value
    }
    func setCreditFallback(_ enabled: Bool) {
        guard canEditPolicy else { return }
        let previous = preferences
        preferences.creditFallback = enabled
        guard savePreferences() else {
            preferences = previous
            return
        }
        creditFallbackEnabled = enabled
        policyChanged()
    }
    @discardableResult
    func setCreditFloors(primary: Int, secondary: Int) -> Bool {
        guard canEditPolicy,
            LocalProxyPreferences.validCreditFloors(primary: primary, secondary: secondary)
        else { return false }
        let previous = preferences
        preferences.creditPrimaryFloor = primary
        preferences.creditSecondaryFloor = secondary
        guard savePreferences() else {
            preferences = previous
            return false
        }
        creditPrimaryFloor = primary
        creditSecondaryFloor = secondary
        policyChanged()
        return true
    }
    @discardableResult
    func setAccountPolicy(id: String, policy: LocalProxyAccountPolicy) -> Bool {
        guard canEditPolicy(for: id), policy.isValid else { return false }
        let previous = preferences
        var policies = preferences.accountPolicies ?? [:]
        policies[id] = policy
        preferences.accountPolicies = policies
        guard preferences.validAccountPolicies, savePreferences() else {
            preferences = previous
            return false
        }
        policyChanged()
        return true
    }
    private func policyChanged() {
        policyRevision &+= 1
        accountStates = accountStates.filter { !["quota", "usage_limit", "subscription_pending", "quota_unknown"].contains($0.value) }
        rebuildRows()
        flushDisplayRows()
    }
    func setAccountEnabled(id: String, enabled: Bool) {
        guard canToggleAccount(id: id) else { return }
        let previous = preferences
        if enabled { preferences.enabledIDs.insert(id) } else { preferences.enabledIDs.remove(id) }
        guard savePreferences() else {
            preferences = previous
            rebuildRows()
            return
        }
        if phase == .running {
            activeIDs = preferences.enabledIDs.intersection(Set(registeredPool.keys))
        }
        rebuildRows()
    }
    func setAccountPriority(id: String, priority: Bool) {
        guard canReorder, !usageStore.isPreview, !preferencesBlocked, rows.contains(where: { $0.id == id }) else { return }
        let previous = preferences
        if priority {
            setLastPreference(id: id, last: false)
            preferences.priorityIDs.insert(id)
        } else { preferences.priorityIDs.remove(id) }
        if !savePreferences() { preferences = previous }
        rebuildRows()
    }
    func setAccountLast(id: String, last: Bool) {
        guard canSetAccountLast(id: id) else { return }
        let previous = preferences
        setLastPreference(id: id, last: last)
        if !savePreferences() { preferences = previous }
        rebuildRows()
    }
    private func setLastPreference(id: String, last: Bool) {
        var overrides = preferences.lastOverrides ?? [:]
        overrides[id] = last
        preferences.lastOverrides = overrides
        var ids = preferences.lastIDs ?? []
        preferences.priorityIDs.remove(id)
        if last {
            ids.insert(id)
        } else { ids.remove(id) }
        preferences.lastIDs = ids
    }
    private func orderingGroup(for id: String) -> Int? {
        usageStore.profiles.first { $0.id == id }.map {
            LocalProxyRouting.group($0, userLast: preferences.lastIDs?.contains(id) == true,
                lastOverride: preferences.lastOverrides?[id])
        }
    }
    func moveAccount(id: String, by offset: Int) {
        guard canMoveAccount(id: id, by: offset),
            let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset)
        else { return }
        var ids = rows.map(\.id)
        ids.swapAt(index, index + offset)
        let previous = preferences
        let source = rows[index]
        let target = rows[index + offset]
        // Moving across a sorting group explicitly adopts the adjacent row's
        // choice, so rebuilding and the helper's routing cannot undo the move.
        // Participation, identity, spending limits and leases are untouched.
        if source.isLast != target.isLast || source.isPriority != target.isPriority {
            setLastPreference(id: id, last: target.isLast)
            if target.isPriority { preferences.priorityIDs.insert(id) }
            else { preferences.priorityIDs.remove(id) }
        }
        preferences.order = ids
        if !savePreferences() { preferences = previous }
        rebuildRows()
    }
    func canMoveAccount(id: String, by offset: Int) -> Bool {
        guard canReorder, !usageStore.isPreview, !preferencesBlocked, offset == -1 || offset == 1,
            let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset)
        else { return false }
        let source = rows[index]
        let target = rows[index + offset]
        // Desktop has a separate verified admission pass. An arrow cannot
        // change that identity or claim an order the helper cannot apply.
        return source.isDesktopAccount == target.isDesktopAccount
    }
    /// The existing explicit quota-only operation; does not request a warm-up.
    func refreshStatus(displayFreshResultsImmediately: Bool = false) {
        guard !usageStore.isPreview else {
            rebuildRows()
            return
        }
        // A quota refresh is the authoritative chance to replace helper-reported
        // quota failures. Do not let an older pipe event mask recovered limits.
        accountStates = accountStates.filter { !["quota", "usage_limit", "subscription_pending", "quota_unknown"].contains($0.value) }
        let ids = Set(rows.filter(\.isEnabled).map(\.id))
        if displayFreshResultsImmediately {
            manualRefreshTargets = [:]
            for profile in usageStore.profiles where ids.contains(profile.id) {
                manualRefreshTargets[profile.id] = profile
            }
        }
        usageStore.refreshLocalProxyQuotas(profileIDs: ids)
        rebuildRows()
    }

    struct ResetCreditTarget {
        let profile: CodexProfile
        let selectedProfileID: String?
        let hubAccountAlias: String?
    }

    /// Resolve the current queue identity without selecting or switching an account.
    func resetCreditTarget(for id: String) -> ResetCreditTarget? {
        let matches = usageStore.profiles.filter { $0.id == id }
        guard rows.filter({ $0.id == id }).count == 1, matches.count == 1,
            let profile = matches.first, !profile.isSystemProfile,
            let accountID = profile.lastSnapshot?.accountID, !accountID.isEmpty
        else { return nil }
        let allowsAction = !usageStore.isPreview && !finishing
        return ResetCreditTarget(
            profile: profile, selectedProfileID: allowsAction ? profile.id : nil,
            hubAccountAlias: allowsAction ? alias(for: profile) : nil)
    }

    /// The button calls this only after its existing two-confirmation flow succeeds.
    func refreshAfterResetCredit(_ target: ResetCreditTarget) {
        guard !usageStore.isPreview, target.selectedProfileID == target.profile.id,
            let current = resetCreditTarget(for: target.profile.id),
            current.selectedProfileID == target.selectedProfileID,
            current.profile.lastSnapshot?.accountID == target.profile.lastSnapshot?.accountID,
            current.profile.codexHomeURL == target.profile.codexHomeURL
        else { return }
        resetCreditRefreshTarget = current.profile
        usageStore.refreshLocalProxyQuotas(profileIDs: [current.profile.id])
        rebuildRows()
        flushDisplayRows()
    }

    /// Publish the current in-memory queue state on an explicit UI action.
    /// This does not start a quota or network refresh.
    func flushDisplayRows() {
        publishDisplayRows(immediately: true)
    }
    func copyConnectionDetails() {
        guard phase == .running, let endpoint, let clientKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "# OpenAI-compatible HTTP clients; Codex Desktop settings are unchanged.\nOPENAI_BASE_URL=\(endpoint)\nOPENAI_API_KEY=\(clientKey)", forType: .string)
    }

    /// Writes only the per-run loopback key. Account credentials never enter this file.
    private func prepareDesktopConnection() throws {
        guard let runID, let runDirectory, let endpoint, let clientKey
        else { throw LocalProxyFailure.unavailable }
        let bundled = CodexExecutable.bundledPath()
        guard
            let selected = [bundled, CodexExecutable.path()].compactMap({ $0 })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }
        let executable = URL(fileURLWithPath: selected).resolvingSymlinksInPath().path
        var connection: [String: Any] = [
            "schemaVersion": 1, "runID": runID, "endpoint": endpoint,
            "clientKey": clientKey, "codexExecutable": executable,
        ]
        if let networkProxy = try LocalProxyNetworkSettings.load() { connection["networkProxy"] = networkProxy }
        let data = try JSONSerialization.data(withJSONObject: connection)
        let destination = runDirectory.appendingPathComponent("desktop-connection.json")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LocalProxyFailure.unavailable
        }
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LocalProxyFailure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        desktopConnection = destination
        desktopAvailable = true
    }

    /// The user launches a fresh Desktop instance; an existing process cannot
    /// adopt CLI/environment overrides while its current turns are running.
    func connectDesktop() {
        guard phase == .running, desktopAvailable, let desktopConnection else { return }
        let language = WidgetLanguage.storedOrAutomatic()
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty else {
            issue = language.text(
                "请先退出 Codex，再点“接入桌面”。重新打开并继续的任务将使用反代。",
                "Quit Codex first, then choose Connect Desktop. Reopened and resumed tasks will use the proxy.")
            return
        }
        do {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            else { throw LocalProxyFailure.unavailable }
            let helper = try verifiedHelper()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.environment = [
                "CODEX_CLI_PATH": helper.path,
                "AIGOODBRO_PROXY_CONNECTION_FILE": desktopConnection.path,
                "CODEX_APP_SERVER_FORCE_CLI": "1",
                "CODEX_APP_SERVER_USE_LOCAL_DAEMON": "0",
                "CODEX_APP_SERVER_WS_URL": "",
            ]
            issue = nil
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in self?.issue = self?.message(.unavailable) }
            }
        } catch { issue = message(.unavailable) }
    }

    func start() async {
        guard canStart, isEnabled else { return }
        phase = .starting
        issue = nil
        finishing = false
        refreshStatus()
        var startupStep = "network"
        do {
            let networkProxy = try LocalProxyNetworkSettings.load()
            startupStep = "helper"
            let helper = try verifiedHelper()
            startupStep = "activity"
            try DispatchActivityStore.live.finishStoppedProxyRuns(retiringCurrentRun: true)
            startupStep = "state"
            let run = UUID().uuidString.lowercased()
            let control = try randomKey()
            let client = try randomKey()
            let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("aigoodbro-next-proxy-" + run, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            runDirectory = folder
            let stateDirectory = directory.appendingPathComponent("LocalProxy", isDirectory: true)
            try Self.prepareStateDirectory(stateDirectory)
            runID = run
            controlKey = control
            clientKey = client
            runDirectory = folder
            // Register the entire verified managed pool once. Live toggles
            // only select a subset; no new auth object is introduced mid-run.
            var pool: [String: PoolBinding] = [:]
            for row in rows {
                guard let profile = usageStore.profiles.first(where: { $0.id == row.id }),
                    !profile.isSystemProfile, let accountID = profile.lastSnapshot?.accountID,
                    !accountID.isEmpty, pool[row.id] == nil
                else { throw LocalProxyFailure.identity }
                pool[row.id] = PoolBinding(
                    home: profile.codexHomeURL,
                    account: profile.recordedAccountKey, accountID: accountID)
            }
            guard !pool.isEmpty, pool.count <= 100 else { throw LocalProxyFailure.unavailable }
            registeredPool = pool
            membershipSnapshots = [:]
            activeIDs = Set(rows.filter(\.isEnabled).map(\.id))
            accountStates = [:]
            cooldowns = [:]
            startupStep = "bridge"
            let permittedProfiles = Set(pool.keys)
            bridge = try LocalProxyBridge(
                path: folder.appendingPathComponent("control.sock").path,
                resolve: { [weak self] request in
                    guard request.schemaVersion == 1, request.command == "acquire_resolve",
                        request.runID == run, request.key == control, request.leaseID == nil,
                        UUID(uuidString: request.requestID) != nil, permittedProfiles.contains(request.profileID)
                    else { return .failure(.identity) }
                    do {
                        let resolution = try DispatchActivityStore.live.abandonProxy(
                            runID: request.runID, requestID: request.requestID, profileID: request.profileID, enforceFreshness: true)
                        Task { @MainActor [weak self] in self?.forgetAbandoned(request) }
                        return LocalProxyReply(ok: true, resolution: resolution.rawValue)
                    } catch DispatchActivityStore.Failure.busy { return .failure(.controlBusy) } catch { return .failure(.admissionUnknown) }
                },
                maintenance: { [weak self] request in
                    let reply = Self.maintainLease(
                        request, run: run, key: control, permittedProfiles: permittedProfiles)
                    if reply.ok, request.command == "release" {
                        // Ownership is durably released before acknowledging.
                        // UI work must never delay a control reply.
                        Task { @MainActor [weak self] in self?.completeLeaseRelease(request) }
                    }
                    return reply
                },
                rollback: { [weak self] request in
                    let deadline = ProcessInfo.processInfo.systemUptime + 8
                    while true {
                        do {
                            _ = try DispatchActivityStore.live.abandonProxy(
                                runID: request.runID, requestID: request.requestID, profileID: request.profileID, enforceFreshness: true)
                            break
                        } catch DispatchActivityStore.Failure.busy {
                            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DispatchActivityStore.Failure.busy }
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                    }
                    Task { @MainActor [weak self] in self?.forgetAbandoned(request) }
                },
                onRollbackFailure: { [weak self] request in
                    // The helper still reconciles the failed reply. Give that
                    // exact request time to commit its deny marker before
                    // treating a transient registry lock as unknown.
                    Task.detached { [weak self] in
                        let deadline = ProcessInfo.processInfo.systemUptime + 40
                        repeat {
                            if (try? DispatchActivityStore.live.isProxyAcquireAbandoned(
                                runID: request.runID, requestID: request.requestID, profileID: request.profileID)) == true
                            {
                                return
                            }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        } while ProcessInfo.processInfo.systemUptime < deadline
                        await MainActor.run { [weak self] in
                            guard let self, self.runID == run else { return }
                            self.issue = self.message(.unavailable)
                            try? DispatchActivityStore.live.appendIssue(
                                id: "proxy-control-\(run)", phase: "control_failure",
                                summary: "Local proxy acquire reply rollback remained unknown after reconciliation.")
                            Task { await self.stop(reason: .controlFailure) }
                        }
                    }
                },
                handler: { [weak self] request in
                    guard let self else { return .failure(.stopping) }
                    return await self.handle(request)
                }
            )
            let child = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            child.executableURL = helper
            child.standardInput = stdin
            child.standardOutput = stdout
            child.standardError = FileHandle.nullDevice
            // No inherited account home, OAuth variable, proxy, or DYLD configuration.
            child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            child.currentDirectoryURL = folder
            child.terminationHandler = { [weak self] child in
                Task { @MainActor [weak self] in self?.childExited(child) }
            }
            process = child
            input = stdin.fileHandleForWriting
            startupStep = "launch"
            try child.run()
            var configuration: [String: Any] = [
                "schemaVersion": 1, "runID": run, "controlSocket": folder.appendingPathComponent("control.sock").path,
                "controlKey": control, "clientKey": client, "port": 0, "stateDirectory": stateDirectory.resolvingSymlinksInPath().path,
                "accounts": rows.map { ["id": $0.id] },
                "models": CodexExecutionPreference.Model.allCases.map(\.rawValue),
                "desktopFallback": true,
            ]
            if let networkProxy { configuration["networkProxy"] = networkProxy }
            var bytes = try JSONSerialization.data(withJSONObject: configuration)
            bytes.append(10)
            try input?.write(contentsOf: bytes)
            let output = stdout.fileHandleForReading
            outputTask = Task.detached { [weak self] in
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !Task.isCancelled {
                    // FileHandle.read(upToCount:) fills a pipe read until its
                    // requested count or EOF. Read available bytes so readiness
                    // and account JSONL events reach the UI immediately.
                    let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    pending.append(contentsOf: buffer.prefix(count))
                    guard pending.count <= 16384 else { break }
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
            if runID == run, phase == .starting {
                issue = message(.unavailable)
                await stop(reason: .startupFailure)
                phase = .failed
            }
        } catch {
            let nsError = error as NSError
            let detail = " [\(startupStep):\(nsError.code)]"
            issue = (error as? LocalProxyNetworkSettings.Failure).map { LocalProxyNetworkSettings.message($0, language: .storedOrAutomatic()) } ?? (message(.unavailable) + detail)
            if let child = process {
                if child.isRunning { await stop(reason: .startupFailure) } else { childExited(child) }
            } else {
                cleanupConfirmedExit()
            }
            phase = .failed
        }
    }

    /// Cooldowns outlive a helper process. Reuse the directory on subsequent starts,
    /// but never follow a replacement link or accept a directory owned by another user.
    static func prepareStateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw LocalProxyFailure.unavailable }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw LocalProxyFailure.unavailable }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw LocalProxyFailure.unavailable }
    }

    static func validateHelperLocation(_ helper: URL) throws {
        // Bundle resource URLs may carry a base URL. Compare normalized file URLs,
        // while still rejecting a real symlink anywhere in the executable path.
        guard helper.resolvingSymlinksInPath().standardizedFileURL == helper.standardizedFileURL,
            FileManager.default.isExecutableFile(atPath: helper.path)
        else { throw LocalProxyFailure.unavailable }
    }

    func stop(reason: ExitReason = .requestedStop) async {
        if phase == .stopping {
            for _ in 0..<90 {
                if phase != .stopping { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }
        requestedExitReason = reason
        phase = .stopping
        try? input?.write(contentsOf: Data("{\"command\":\"stop\"}\n".utf8))
        try? input?.close()
        input = nil
        guard let child = process else {
            cleanupConfirmedExit()
            return
        }
        for _ in 0..<40 {
            if !child.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if child.isRunning { child.terminate() }
        for _ in 0..<20 {
            if !child.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        for _ in 0..<20 {
            if !child.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !child.isRunning {
            childExited(child)
        } else {
            phase = .failed
            issue = message(.stopping)
            for lease in leases.values { try? update(lease, state: "uncertain") }
        }
    }
    func shutdown() async { await finishForTermination() }
    func finishForTermination() async {
        finishing = true
        await stop()
    }

    private func childExited(_ child: Process) {
        guard process === child, !child.isRunning else { return }
        let unexpected = phase == .running || phase == .starting
        let reason = unexpected ? ExitReason.unexpectedExit : (requestedExitReason ?? .requestedStop)
        if let runID {
            let summary = "Local proxy helper exited with status \(child.terminationStatus) (\(reason.rawValue))."
            try? DispatchActivityStore.live.appendIssue(id: "proxy-\(runID)", phase: reason.rawValue, summary: summary)
        }
        cleanupConfirmedExit()
        requestedExitReason = nil
        if unexpected {
            phase = .failed
            issue = message(.unavailable)
        }
    }
    private func cleanupConfirmedExit() {
        guard process?.isRunning != true else { return }
        if let runID {
            DispatchActivityStore.closeProxyRun(runID)
            localProxyReleaseFence.clear(runID: runID)
        }
        var registryCleanupFailed = false
        for lease in Array(leases.values) {
            do {
                try retireLeaseAfterExit(lease)
            } catch { issue = message(.unavailable) }
        }
        do { try DispatchActivityStore.live.finishStoppedProxyRuns(retiringCurrentRun: true) } catch {
            registryCleanupFailed = true
            issue = message(.unavailable)
        }
        if !registryCleanupFailed {
            // A contended per-lease write can precede a successful batch
            // retirement. Reconcile its exact terminal record before dropping
            // the run identity; otherwise an old UI mirror blocks the next start.
            for lease in Array(leases.values) {
                do { try retireLeaseAfterExit(lease) } catch { issue = message(.unavailable) }
            }
        }
        try? input?.close()
        input = nil
        process = nil
        bridge?.stop()
        bridge = nil
        outputTask?.cancel()
        outputTask = nil
        quotaTask?.cancel()
        quotaTask = nil
        if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
        runDirectory = nil
        runID = nil
        controlKey = nil
        clientKey = nil
        desktopConnection = nil
        desktopAvailable = false
        endpoint = nil
        activeIDs = []
        registeredPool = [:]
        membershipSnapshots = [:]
        refreshMembershipWaitState()
        phase = leases.isEmpty && !registryCleanupFailed ? .stopped : .failed
        accountStates = [:]
        cooldowns = [:]
        rebuildRows()
    }

    private func retireLeaseAfterExit(_ lease: Lease) throws {
        try update(lease, state: "cancelled", allowTerminalCleanup: true)
        leases.removeValue(forKey: lease.id)
        if balanceRefreshLeases.remove(lease.id) != nil {
            creditRefreshAfter[lease.profileID] = Date()
        }
    }

    private func refreshMembershipWaitState() {
        let pending = !membershipSnapshots.isEmpty || !leases.isEmpty
        if membershipChangeWaiting != pending { membershipChangeWaiting = pending }
    }

    private func pruneMembershipSnapshots(at now: TimeInterval) {
        membershipSnapshots = membershipSnapshots.filter { now >= $0.value.capturedAt && now - $0.value.capturedAt < membershipSnapshotLifetime }
        refreshMembershipWaitState()
    }

    private func isMembershipSnapshotCurrent(_ snapshot: MembershipSnapshot, requestID: String) -> Bool {
        guard let current = membershipSnapshots[requestID], current.capturedAt == snapshot.capturedAt,
            current.order == snapshot.order, current.lastResortIDs == snapshot.lastResortIDs, current.deferredIDs == snapshot.deferredIDs,
            current.creditFallback == snapshot.creditFallback
        else { return false }
        let elapsed = ProcessInfo.processInfo.systemUptime - current.capturedAt
        return elapsed >= 0 && elapsed < membershipSnapshotLifetime
    }

    private func isRegisteredBindingCurrent(_ id: String) -> Bool {
        guard let bound = registeredPool[id],
            let profile = usageStore.profiles.first(where: { $0.id == id }),
            !profile.isSystemProfile, profile.codexHomeURL == bound.home,
            profile.recordedAccountKey == bound.account,
            profile.lastSnapshot?.accountID == bound.accountID
        else { return false }
        return true
    }

    private func handle(_ request: LocalProxyRequest) async -> LocalProxyReply {
        let admissionDeadline = (request.receivedAt ?? ProcessInfo.processInfo.systemUptime) + 18
        guard request.schemaVersion == 1, request.runID == runID, request.key == controlKey,
            UUID(uuidString: request.requestID) != nil
        else { return .failure(.identity) }
        if request.command == "order_end" {
            guard request.profileID.isEmpty, request.leaseID == nil else { return .failure(.identity) }
            membershipSnapshots.removeValue(forKey: request.requestID)
            refreshMembershipWaitState()
            return LocalProxyReply(ok: true)
        }
        guard registeredPool[request.profileID] != nil else { return .failure(.identity) }
        if request.command == "order" {
            guard request.leaseID == nil, !preferencesBlocked, !finishing,
                phase == .running, process?.isRunning == true
            else { return .failure(.stopping) }
            let now = ProcessInfo.processInfo.systemUptime
            pruneMembershipSnapshots(at: now)
            if let existing = membershipSnapshots[request.requestID] {
                return LocalProxyReply(ok: true, order: existing.order, lastResortIDs: existing.lastResortIDs, deferredIDs: existing.deferredIDs, creditFallback: existing.creditFallback)
            }
            guard membershipSnapshots.count < maximumMembershipSnapshots else { return .failure(.controlBusy) }
            let order = rows.map(\.id).filter { activeIDs.contains($0) && isRegisteredBindingCurrent($0) }
            guard Set(order).count == order.count else { return .failure(.identity) }
            // New requests use effective choices, including an explicit Pro
            // opt-out. Existing snapshots retain their original metadata.
            let lastResortIDs: [String] = []
            let deferredIDs = order.filter { orderingGroup(for: $0) == 1 }
            membershipSnapshots[request.requestID] = MembershipSnapshot(
                order: order, lastResortIDs: lastResortIDs, deferredIDs: deferredIDs, creditFallback: creditFallbackEnabled, capturedAt: now)
            refreshMembershipWaitState()
            return LocalProxyReply(ok: true, order: order, lastResortIDs: lastResortIDs, deferredIDs: deferredIDs, creditFallback: creditFallbackEnabled)
        }
        if request.command == "release" || request.command == "heartbeat" {
            guard let id = request.leaseID, let lease = leases[id], lease.runID == request.runID,
                lease.requestID == request.requestID, lease.profileID == request.profileID
            else { return .failure(.identity) }
            let run = request.runID
            let key = request.key
            let profiles = Set(registeredPool.keys)
            let reply = await Task.detached {
                Self.maintainLease(
                    request, run: run, key: key, permittedProfiles: profiles)
            }.value
            if reply.ok, request.command == "release" { completeLeaseRelease(request) }
            return reply
        }
        let commands = ["acquire", "acquire_credit_primary", "acquire_credit_secondary", "acquire_desktop", "acquire_desktop_credit_primary", "acquire_desktop_credit_secondary"]
        guard commands.contains(request.command), request.leaseID == nil,
            let membership = membershipSnapshots[request.requestID],
            membership.order.contains(request.profileID),
            isMembershipSnapshotCurrent(membership, requestID: request.requestID)
        else { return .failure(.identity) }
        guard activeIDs.contains(request.profileID), preferences.enabledIDs.contains(request.profileID)
        else { return .failure(.notParticipating) }
        let requestMembers = Set(membership.order)
        guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return .failure(.admissionDeadline) }
        let desktopPass = request.command.contains("desktop")
        let policy = preferences.resolvedPolicy(for: request.profileID)
        let revision = policyRevision
        let floor: Int? = request.command.hasSuffix("primary") ? policy.creditPrimaryFloor : request.command.hasSuffix("secondary") ? policy.creditSecondaryFloor : nil
        guard floor == nil || (creditFallbackEnabled && policy.allowsCredits) else { return .failure(.quota) }
        if floor != nil && requestMembers.intersection(activeIDs).intersection(preferences.enabledIDs).contains(where: { localProxyReleaseFence.contains(runID: request.runID, profileID: $0) }) {
            // A prior paid lease has committed its terminal registry state, but
            // its quota refresh has not yet crossed back to the UI projection.
            // Unknown balance must never authorize another paid admission.
            return .failure(.quotaUnknown)
        }
        guard !finishing, phase == .running, let child = process, child.isRunning else { return .failure(.stopping) }
        guard let profile = usageStore.profiles.first(where: { $0.id == request.profileID }), !profile.isSystemProfile,
            let system = usageStore.profiles.first(where: \.isSystemProfile),
            let alias = alias(for: profile)
        else { return .failure(.identity) }
        let isDesktop = profile.recordedAccountKey == system.recordedAccountKey || profile.lastSnapshot?.accountID == system.lastSnapshot?.accountID
        guard desktopPass == isDesktop else { return .failure(.stageNotApplicable) }
        func admission(_ candidate: CodexProfile) -> LocalProxyFailure? {
            // A saved removal revokes any admission not yet committed, including
            // retries with an older order snapshot. Heartbeat/release for an
            // already admitted response remain independent of this check.
            guard activeIDs.contains(request.profileID), preferences.enabledIDs.contains(request.profileID)
            else { return .notParticipating }
            // A policy edit may occur across any await below. Releasing a token
            // under superseded spending limits is never allowed. A rolled-back
            // tuple stays denied; a fresh request can use the current policy.
            guard revision == policyRevision else { return .policyChanged }
            if floor != nil && requestMembers.intersection(activeIDs).intersection(preferences.enabledIDs).contains(where: { localProxyReleaseFence.contains(runID: request.runID, profileID: $0) }) {
                return .quotaUnknown
            }
            if floor != nil,
                let failure = LocalProxyAdmission.creditPool(
                    usageStore.profiles, activeIDs: requestMembers.intersection(activeIDs).intersection(preferences.enabledIDs), refreshAfter: creditRefreshAfter, policies: preferences.accountPolicies ?? [:])
            {
                return failure
            }
            return LocalProxyAdmission.quota(candidate, creditFloor: floor, allowPaidCredits: creditFallbackEnabled, policy: policy)
        }
        guard let initial = currentBinding(profile, system: system) else { return .failure(.identity) }
        // Refresh before rejecting a stale snapshot. Paid admission observes the
        // whole frozen pool, including releases that may have consumed quota.
        // The existing admission deadline and all identity/credit checks remain.
        if admission(initial) == .quotaUnknown {
            usageStore.refreshLocalProxyQuotas(profileIDs: floor == nil ? [profile.id] : requestMembers)
            for _ in 0..<30 {
                guard !Task.isCancelled, !finishing, phase == .running, process === child,
                    child.isRunning, request.runID == runID,
                    isMembershipSnapshotCurrent(membership, requestID: request.requestID)
                else { return .failure(.stopping) }
                guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return .failure(.admissionDeadline) }
                guard let updated = currentBinding(profile, system: system) else { return .failure(.identity) }
                if admission(updated) != .quotaUnknown { break }
                let left = admissionDeadline - ProcessInfo.processInfo.systemUptime
                try? await Task.sleep(nanoseconds: UInt64(min(0.1, max(0, left)) * 1_000_000_000))
            }
        }
        guard !Task.isCancelled, !finishing, phase == .running, process === child,
            child.isRunning, request.runID == runID,
            isMembershipSnapshotCurrent(membership, requestID: request.requestID)
        else { return .failure(.stopping) }
        guard let fresh = currentBinding(profile, system: system) else { return .failure(.identity) }
        if let failure = admission(fresh) { return .failure(failure) }
        guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return .failure(.admissionDeadline) }
        let lease: Lease
        func rollBack(_ lease: Lease) async throws {
            try await Task.detached {
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                while true {
                    do {
                        _ = try DispatchActivityStore.live.abandonProxy(
                            runID: lease.runID, requestID: lease.requestID, profileID: lease.profileID,
                            enforceFreshness: request.receivedAt != nil)
                        return
                    } catch DispatchActivityStore.Failure.busy {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw DispatchActivityStore.Failure.busy }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            }.value
        }
        do {
            let account = profile.recordedAccountKey
            let profileID = profile.id
            let pid = child.processIdentifier
            let id = try await Task.detached {
                try DispatchActivityStore.live.reserveProxy(
                    account: account, alias: alias, runID: request.runID, requestID: request.requestID, profileID: profileID, childPID: pid,
                    admissionDeadline: admissionDeadline, enforceFreshness: request.receivedAt != nil)
            }.value
            lease = Lease(id: id, profileID: profile.id, requestID: request.requestID, runID: request.runID)
            guard !Task.isCancelled, !finishing, phase == .running, process === child,
                child.isRunning, runID == request.runID,
                isMembershipSnapshotCurrent(membership, requestID: request.requestID)
            else {
                do { try await rollBack(lease) } catch { return .failure(.admissionUnknown) }
                return .failure(.stopping)
            }
            leases[id] = lease
            refreshMembershipWaitState()
        } catch DispatchActivityStore.Failure.acquireAbandoned {
            return LocalProxyReply(ok: false, error: LocalProxyFailure.acquireAbandoned.rawValue, resolution: "abandoned")
        } catch DispatchActivityStore.Failure.busy { return .failure(.busy) } catch DispatchActivityStore.Failure.deadline { return .failure(.admissionDeadline) } catch {
            return .failure(.unavailable)
        }
        func reject(_ reason: LocalProxyFailure) async -> LocalProxyReply {
            var reply = LocalProxyReply.failure(reason)
            let retryableRollback = reason == .busy || reason == .credentialsBusy || reason == .policyChanged
            if leases[lease.id] != nil {
                do {
                    try await rollBack(lease)
                    leases.removeValue(forKey: lease.id)
                    balanceRefreshLeases.remove(lease.id)
                    refreshMembershipWaitState()
                    if retryableRollback { reply.resolution = "abandoned" }
                } catch {
                    return .failure(.admissionUnknown)
                }
            }
            return reply
        }
        guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return await reject(.admissionDeadline) }
        if let candidate = currentBinding(profile, system: system), let failure = admission(candidate) { return await reject(failure) }
        let availability = await HubConsoleModel.warmUpAvailability(for: alias, excludingLocalLease: lease.id, deadline: admissionDeadline)
        guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return await reject(.admissionDeadline) }
        guard availability == .idle else { return await reject(availability == .busy ? .busy : .unavailable) }
        guard phase == .running, process === child, child.isRunning, request.runID == runID, leases[lease.id] != nil,
            let latest = currentBinding(profile, system: system)
        else { return await reject(.stopping) }
        if let failure = admission(latest) { return await reject(failure) }
        do {
            let paid = creditFallbackEnabled
            let credential = try await Task.detached {
                try LocalProxyCredentialReader.read(
                    profile: latest, system: system, allowDesktopAccount: desktopPass, creditFloor: floor, allowPaidCredits: paid, policy: policy, deadline: admissionDeadline)
            }.value
            guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return await reject(.admissionDeadline) }
            guard phase == .running, process === child, child.isRunning, request.runID == runID, leases[lease.id] != nil,
                isMembershipSnapshotCurrent(membership, requestID: request.requestID),
                let current = currentBinding(latest, system: system)
            else { return await reject(.stopping) }
            if let failure = admission(current) { return await reject(failure) }
            try await Task.detached {
                try DispatchActivityStore.live.updateProxy(lease.id, runID: lease.runID, requestID: lease.requestID, profileID: lease.profileID, state: "running")
            }.value
            guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return await reject(.admissionDeadline) }
            guard !finishing, phase == .running, process === child, child.isRunning, request.runID == runID,
                leases[lease.id] != nil, isMembershipSnapshotCurrent(membership, requestID: request.requestID),
                let final = currentBinding(latest, system: system)
            else { return await reject(.stopping) }
            if let failure = admission(final) { return await reject(failure) }
            let persistedActive: Bool
            do {
                persistedActive = try DispatchActivityStore.live.isProxyLeaseActive(
                    lease.id, runID: lease.runID, requestID: lease.requestID,
                    profileID: lease.profileID, childPID: child.processIdentifier) {
                        if let failure = admission(final) { throw failure }
                    }
            } catch let failure as LocalProxyFailure { return await reject(failure)
            } catch { return await reject(.admissionUnknown) }
            guard persistedActive else { return await reject(.stopping) }
            leases[lease.id]?.isAdmitted = true
            rebuildRows()
            if creditFallbackEnabled { balanceRefreshLeases.insert(lease.id) }
            return LocalProxyReply(ok: true, leaseID: lease.id, accessToken: credential.token, accountID: credential.accountID, expiresAt: Int64(credential.expiresAt))
        } catch let failure as LocalProxyFailure { return await reject(failure) } catch { return await reject(.unavailable) }
    }
    private func forgetAbandoned(_ request: LocalProxyRequest) {
        guard runID == request.runID else { return }
        for lease in leases.values where lease.requestID == request.requestID && lease.profileID == request.profileID {
            leases.removeValue(forKey: lease.id)
            balanceRefreshLeases.remove(lease.id)
        }
        refreshMembershipWaitState()
        rebuildRows()
    }
    private func currentBinding(_ profile: CodexProfile, system: CodexProfile) -> CodexProfile? {
        guard isRegisteredBindingCurrent(profile.id),
            let latest = usageStore.profiles.first(where: { $0.id == profile.id }), !latest.isSystemProfile,
            latest.codexHomeURL == profile.codexHomeURL, latest.recordedAccountKey == profile.recordedAccountKey,
            latest.lastSnapshot?.accountID == profile.lastSnapshot?.accountID,
            let central = usageStore.profiles.first(where: \.isSystemProfile), central.id == system.id,
            central.codexHomeURL == system.codexHomeURL, central.recordedAccountKey == system.recordedAccountKey,
            central.lastSnapshot?.accountID == system.lastSnapshot?.accountID
        else { return nil }
        return latest
    }
    nonisolated private static func maintainLease(
        _ request: LocalProxyRequest, run: String, key: String, permittedProfiles: Set<String>,
        activity: DispatchActivityStore = .live
    ) -> LocalProxyReply {
        guard request.schemaVersion == 1, request.runID == run, request.key == key,
            ["heartbeat", "release"].contains(request.command),
            UUID(uuidString: request.requestID) != nil, permittedProfiles.contains(request.profileID),
            let id = request.leaseID, UUID(uuidString: id) != nil
        else { return .failure(.identity) }
        do {
            try activity.updateProxy(
                id, runID: run, requestID: request.requestID, profileID: request.profileID,
                state: request.command == "release" ? "accepted" : "running",
                onCommit: request.command == "release" ? {
                    localProxyReleaseFence.mark(runID: request.runID, requestID: request.requestID,
                        profileID: request.profileID, leaseID: id)
                } : nil)
            return LocalProxyReply(ok: true)
        } catch DispatchActivityStore.Failure.busy { return .failure(.controlBusy) }
        catch { return .failure(.unavailable) }
    }

    private func completeLeaseRelease(_ request: LocalProxyRequest) {
        guard request.runID == runID, let id = request.leaseID, let lease = leases[id],
            lease.runID == request.runID, lease.requestID == request.requestID, lease.profileID == request.profileID
        else { return }
        leases.removeValue(forKey: id)
        refreshMembershipWaitState()
        if balanceRefreshLeases.remove(id) != nil {
            creditRefreshAfter[lease.profileID] = Date()
            usageStore.refreshLocalProxyQuotas(profileIDs: [lease.profileID])
        }
        localProxyReleaseFence.clear(runID: request.runID, requestID: request.requestID,
            profileID: request.profileID, leaseID: id)
        rebuildRows()
    }

    private func update(_ lease: Lease, state: String, allowTerminalCleanup: Bool = false) throws {
        try DispatchActivityStore.live.updateProxy(
            lease.id, runID: lease.runID, requestID: lease.requestID, profileID: lease.profileID,
            state: state, allowTerminalCleanup: allowTerminalCleanup)
    }

    private func updateAfterContention(_ lease: Lease, state: String, deadline: TimeInterval) async throws {
        while true {
            do {
                try update(lease, state: state)
                return
            } catch DispatchActivityStore.Failure.busy {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw DispatchActivityStore.Failure.busy }
                // Yield the main actor; only a lock refusal before mutation can retry.
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func consume(_ data: Data, run: String) {
        guard runID == run, data.count <= 8192,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = (object["event"] ?? object["type"]) as? String
        else { return }
        switch type {
        case "ready":
            guard phase == .starting, let port = object["port"] as? Int, (1024...65535).contains(port) else { return }
            endpoint = "http://127.0.0.1:\(port)/v1"
            do { try prepareDesktopConnection() } catch {
                issue = message(.unavailable)
                Task { [weak self] in await self?.stop(reason: .startupFailure) }
                return
            }
            phase = .running
            quotaTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    guard let self, self.phase == .running else { return }
                    self.pruneMembershipSnapshots(at: ProcessInfo.processInfo.systemUptime)
                    self.refreshStatus()
                }
            }
        case "account":
            guard let id = object["profileID"] as? String, activeIDs.contains(id),
                let state = object["state"] as? String,
                ["current", "ready", "quota", "usage_limit", "login_expired", "temporary_error", "busy", "credentials_busy", "quota_unknown", "subscription_pending"].contains(
                    state)
            else { return }
            accountStates[id] = state
            if let until = object["cooldownUntil"] as? Double, until.isFinite, until > Date().timeIntervalSince1970, until < Date().timeIntervalSince1970 + 8 * 86400 {
                cooldowns[id] = Date(timeIntervalSince1970: until)
            } else {
                cooldowns[id] = nil
            }
            rebuildRows()
        case "error":
            let code = object["errorCode"] as? String ?? ""
            let details: Set<String> = ["timeout", "eof", "decode", "unavailable", "admission_unknown", "missing_lease", "control_busy", "identity", "rejected"]
            let detail = (object["errorDetail"] as? String).flatMap { details.contains($0) ? $0 : nil }
            let resolutionDetail = (object["resolutionDetail"] as? String).flatMap { details.contains($0) ? $0 : nil }
            if code == "lease_acquire_reconciled" {
                if let runID, phase == .running || phase == .starting {
                    try? DispatchActivityStore.live.appendIssue(
                        id: "proxy-control-\(runID)", phase: "reconciled",
                        summary: "Local proxy acquire reconciled\(detail.map { ": \($0)" } ?? "").")
                }
                return
            }
            issue = message(.unavailable)
            if ["lease_acquire_unknown", "lease_release_unknown", "lease_heartbeat_failed"].contains(code) {
                if let runID, phase == .running || phase == .starting {
                    try? DispatchActivityStore.live.appendIssue(
                        id: "proxy-control-\(runID)", phase: "control_failure",
                        summary: "Local proxy control failure: \(code)\(detail.map { ": \($0)" } ?? "")\(resolutionDetail.map { "; resolution: \($0)" } ?? "").")
                }
                Task { [weak self] in await self?.stop(reason: .controlFailure) }
            }
        case "stopped": break  // A message is not proof that the process has exited.
        default: break
        }
    }
    private func rebuildRows() {
        let central = usageStore.profiles.first(where: \.isSystemProfile)
        var seen = Set<String>()
        let profiles = usageStore.profiles.filter {
            !$0.isSystemProfile && $0.lastSnapshot?.accountID != nil && seen.insert($0.recordedAccountKey).inserted
        }
        // First observation seeds only this queue; dispatch settings are never written.
        for profile in profiles where !preferences.knownIDs.contains(profile.id) {
            preferences.knownIDs.insert(profile.id)
            if profile.recordedAccountKey != central?.recordedAccountKey,
                process == nil || registeredPool[profile.id] != nil
            {
                preferences.enabledIDs.insert(profile.id)
            }
            if profile.isDispatchPriorityEnabled, orderingGroup(for: profile.id) == 0 { preferences.priorityIDs.insert(profile.id) }
        }
        let ids = preferences.order.filter { id in profiles.contains { $0.id == id } } + profiles.map(\.id).filter { !preferences.order.contains($0) }
        let orderIndex = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { min($0, $1) })
        func isDesktop(_ id: String) -> Bool { profiles.first { $0.id == id }?.recordedAccountKey == central?.recordedAccountKey }
        rows = ids.sorted {
            let leftGroup = orderingGroup(for: $0) ?? 0
            let rightGroup = orderingGroup(for: $1) ?? 0
            if leftGroup != rightGroup { return leftGroup < rightGroup }
            if isDesktop($0) != isDesktop($1) { return !isDesktop($0) }
            let leftPriority = leftGroup == 0 && preferences.priorityIDs.contains($0)
            let rightPriority = rightGroup == 0 && preferences.priorityIDs.contains($1)
            if leftPriority != rightPriority { return leftPriority }
            return (orderIndex[$0] ?? .max) < (orderIndex[$1] ?? .max)
        }.compactMap { id in
            guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
            let policy = preferences.resolvedPolicy(for: id)
            let failure = LocalProxyAdmission.quota(profile, allowPaidCredits: creditFallbackEnabled, policy: policy)
            // Pipe events can arrive after release, or report another request's
            // busy result. Only an admitted, still-owned lease proves activity.
            let activeRequestCount = leases.values.filter { $0.profileID == id && $0.isAdmitted }.count
            let isCurrent = activeRequestCount > 0
            let reportedState = accountStates[id].flatMap { $0 == "current" ? nil : $0 }
            let state = isCurrent ? "current" : failure == .usageLimit ? "usage_limit" : reportedState ?? (failure?.rawValue ?? "ready")
            func officialRemaining(_ window: CodexQuotaWindowSnapshot?) -> Double? {
                window.flatMap { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) ? 100 - $0.usedPercent : nil }
            }
            let weeklyRemaining = officialRemaining(profile.lastSnapshot?.sevenDay)
            let displayWindows = [("5h", profile.lastSnapshot?.fiveHour), ("7d", profile.lastSnapshot?.sevenDay), ("30d", profile.lastSnapshot?.monthly)]
                .filter { $0.0 != "30d" || $0.1 != nil }
                .map { label, window in
                    LocalProxyQuotaWindow(
                        id: label,
                        remaining: label == "5h"
                            ? QuotaAvailabilityPresentation.reportedFiveHourRemaining(officialRemaining(window), sevenDay: weeklyRemaining)
                            : officialRemaining(window),
                        resetsAt: window?.resetsAt,
                        constrainedByWeekly: label == "5h" && QuotaAvailabilityPresentation.isWeeklyExhausted(weeklyRemaining),
                        isWeeklyOnlyPro: label == "5h" && QuotaAvailabilityPresentation.weeklyOnlyPro(profile))
                }
            let quota: String
            if failure == nil || failure == .quota, profile.lastSnapshot != nil {
                let language = WidgetLanguage.storedOrAutomatic()
                let remaining = displayWindows.compactMap { window -> String? in
                    guard let remaining = window.remaining else { return nil }
                    let label =
                        window.id == "5h"
                        ? language.text("5 小时", "5h")
                        : window.id == "7d" ? language.text("每周", "Weekly") : language.text("每月", "Monthly")
                    return label + " " + String(format: "%.1f%%", remaining)
                }.joined(separator: " · ")
                quota = language.text("剩余：", "Remaining: ") + remaining
            } else {
                quota = message(failure ?? .quotaUnknown)
            }
            return LocalProxyQueueRow(
                id: id, label: AccountDisplay.profileName(profile, allProfiles: usageStore.profiles),
                accountNumber: AccountDisplay.number(for: profile, in: usageStore.profiles),
                windows: displayWindows,
                creditBalance: usageStore.creditBalancePresentation(for: profile),
                resetCardCount: usageStore.availableResetCredits(for: profile),
                snapshotStale: profile.lastQuotaReadFailureAt != nil || profile.lastSnapshot.map { Date().timeIntervalSince($0.fetchedAt) > 1_800 } != false,
                isDesktopAccount: isDesktop(id),
                isEnabled: preferences.enabledIDs.contains(id),
                isPriority: preferences.priorityIDs.contains(id) && orderingGroup(for: id) != 1, isCurrent: state == "current", quotaText: quota, state: state, cooldownUntil: cooldowns[id],
                activeRequestCount: activeRequestCount, policy: policy,
                usesDefaultCreditFloors: preferences.policy(for: id).creditPrimaryFloor == nil,
                isLast: orderingGroup(for: id) == 1)
        }
        var immediately = false
        if let target = resetCreditRefreshTarget {
            if let current = usageStore.profiles.first(where: { $0.id == target.id }),
                current.lastSnapshot?.accountID == target.lastSnapshot?.accountID,
                current.codexHomeURL == target.codexHomeURL
            {
                if current.lastSnapshot?.fetchedAt != target.lastSnapshot?.fetchedAt
                    || current.lastQuotaReadFailureAt != target.lastQuotaReadFailureAt
                {
                    immediately = true
                    resetCreditRefreshTarget = nil
                }
            } else {
                resetCreditRefreshTarget = nil
            }
        }
        var completedManualRefreshes: [String] = []
        for (id, target) in manualRefreshTargets {
            guard let current = usageStore.profiles.first(where: { $0.id == id }),
                current.lastSnapshot?.accountID == target.lastSnapshot?.accountID,
                current.codexHomeURL == target.codexHomeURL
            else {
                completedManualRefreshes.append(id)
                continue
            }
            if current.lastSnapshot?.fetchedAt != target.lastSnapshot?.fetchedAt
                || current.lastQuotaReadFailureAt != target.lastQuotaReadFailureAt
            {
                immediately = true
                completedManualRefreshes.append(id)
            }
        }
        for id in completedManualRefreshes { manualRefreshTargets.removeValue(forKey: id) }
        publishDisplayRows(immediately: immediately)
    }

    private func publishDisplayRows(immediately: Bool = false) {
        let uptime = ProcessInfo.processInfo.systemUptime
        switch displayGate.offer(rows, at: uptime, immediate: immediately) {
        case .unchanged:
            displayPublishTask?.cancel()
            displayPublishTask = nil
        case .publish:
            displayPublishTask?.cancel()
            displayPublishTask = nil
            displayRows = rows
        case .deferUntil(let deadline):
            guard displayPublishTask == nil else { return }
            displayPublishTask = Task { [weak self] in
                let nanoseconds = UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000)
                do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
                guard let self else { return }
                self.displayPublishTask = nil
                self.publishDisplayRows()
            }
        }
    }

    @discardableResult
    private func savePreferences() -> Bool {
        do {
            guard preferences.validLastIDs, preferences.validLastOverrides else { throw LocalProxyFailure.unavailable }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                throw LocalProxyFailure.unavailable
            }
            let url = directory.appendingPathComponent("local-proxy-queue-v1.json")
            let data = try JSONEncoder().encode(preferences)
            guard data.count <= 65536 else { throw LocalProxyFailure.unavailable }
            try DispatchParticipationSync.writePrivateProxyPreferences(data, at: url)
            return true
        } catch {
            preferencesBlocked = true
            preferencesFailure = .save
            issue = message(.unavailable)
            return false
        }
    }
    private func alias(for profile: CodexProfile) -> String? {
        if let alias = DispatchCodeCatalog.alias(for: profile.id) { return HubAccountTaskStatusResolver.canonicalAlias(alias) }
        let snapshot = directory.appendingPathComponent(DispatchParticipationPaths.snapshotFileName)
        guard let paths = try? DispatchParticipationPaths.live(snapshot: snapshot),
            let data = try? DispatchParticipationSync.readBoundedRegularFile(paths.hubConfig, maximumBytes: 256 * 1024),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let accounts = object["accounts"] as? [[String: Any]], accounts.count <= 1000
        else { return nil }
        let aliases = accounts.compactMap { ($0["alias"] as? String).map(HubAccountTaskStatusResolver.canonicalAlias) }
        guard aliases.count == accounts.count, !aliases.contains(""), Set(aliases).count == aliases.count else { return nil }
        let home = profile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
        let matches = accounts.filter { row in
            guard let path = row["home"] as? String, path.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == home
        }
        guard matches.count == 1, let result = matches[0]["alias"] as? String else { return nil }
        return HubAccountTaskStatusResolver.canonicalAlias(result)
    }
    private func verifiedHelper() throws -> URL {
        guard let resources = Bundle.main.resourceURL else { throw LocalProxyFailure.unavailable }
        let helper = resources.appendingPathComponent("LocalProxy/aigoodbro-local-proxy")
        try Self.validateHelperLocation(helper)
        // The enclosing resource seal binds this helper to the packaged application.
        for url in [Bundle.main.bundleURL, helper] {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess
            else { throw LocalProxyFailure.unavailable }
        }
        return helper
    }
    private func randomKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LocalProxyFailure.unavailable }
        return Data(bytes).base64EncodedString()
    }
    private func message(_ failure: LocalProxyFailure) -> String {
        let language = WidgetLanguage.storedOrAutomatic()
        switch failure {
        case .subscriptionPending: return language.text("先用完参与账号的订阅额度", "Use all enrolled subscription quota first")
        case .busy: return language.text("账号正在执行其他任务", "Account is busy")
        case .credentialsBusy: return language.text("凭据正在读取或更新，请稍后重试", "Credentials are being read or updated; retry shortly")
        case .controlBusy: return language.text("代理控制通道忙碌，请稍后重试", "Proxy control channel is busy; retry shortly")
        case .policyChanged: return language.text("规则已更新，正在重新选择账号", "Rules changed; selecting an account again")
        case .admissionDeadline: return language.text("账号接入超时，请稍后重试", "Account admission timed out; retry shortly")
        case .acquireAbandoned: return language.text("本次账号接入已回滚，请重新请求", "Account admission rolled back; retry request")
        case .identity: return language.text("账号身份未确认", "Account identity is unverified")
        case .quota: return language.text("订阅额度已用尽", "Subscription quota exhausted")
        case .usageLimit: return language.text("已达自定 5 小时使用上限", "Custom 5h usage limit reached")
        case .quotaUnknown: return language.text("额度未知或已过期，请刷新", "Quota missing or stale; refresh limits")
        case .loginExpired: return language.text("登录已过期，请手动重新登录", "Login expired; sign in manually")
        case .stageNotApplicable: return message(.unavailable)
        case .notParticipating: return language.text("已取消参与，跳过此账号", "Participation disabled; skipping this account")
        case .admissionUnknown: return message(.unavailable)
        case .stopping: return language.text("尚未确认代理完全停止，账号占用已保留", "Proxy stop is unconfirmed; reservations retained")
        case .unavailable: return language.text("代理暂不可用，请检查额度与本地运行状态", "Proxy unavailable; check limits and local runtime")
        }
    }
}
