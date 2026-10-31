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
        lock.lock()
        defer { lock.unlock() }
        pending.insert(Tuple(runID: runID, requestID: requestID, profileID: profileID, leaseID: leaseID))
    }

    func clear(runID: String, requestID: String, profileID: String, leaseID: String) {
        lock.lock()
        defer { lock.unlock() }
        pending.remove(Tuple(runID: runID, requestID: requestID, profileID: profileID, leaseID: leaseID))
    }

    func clear(runID: String) {
        lock.lock()
        defer { lock.unlock() }
        pending = pending.filter { $0.runID != runID }
    }

    func contains(runID: String, profileID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending.contains { $0.runID == runID && $0.profileID == profileID }
    }
}

private let localProxyReleaseFence = LocalProxyReleaseFence()

/// A run-owned, append-only permission set shared by independent control queues.
private final class LocalProxyRunProfiles: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>
    init(_ ids: Set<String>) { self.ids = ids }
    func insert(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        ids.insert(id)
    }
    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

/// Disk I/O cannot be cancelled reliably. Complete the caller at most once,
/// while a late worker remains unable to declare the cleanup successful.
private final class LocalProxyIOCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }

    func complete(_ value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

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
    nonisolated private static let issueQueue = DispatchQueue(label: "AiGoodBro.LocalProxyIssues", qos: .utility)
    nonisolated private static let issueSlots = DispatchSemaphore(value: 16)

    nonisolated private static func recordIssue(id: String, phase: String, summary: String) {
        // The journal is best effort; a blocked disk must not prevent Stop or
        // Quit, and a failed disk must not create an unbounded task backlog.
        guard issueSlots.wait(timeout: .now()) == .success else { return }
        issueQueue.async {
            defer { issueSlots.signal() }
            for attempt in 0..<3 {
                do {
                    try DispatchActivityStore.live.appendIssue(id: id, phase: phase, summary: summary)
                    return
                } catch DispatchActivityStore.Failure.busy where attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.05)
                } catch {
                    return
                }
            }
        }
    }

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
    @Published private(set) var listenPort = 18080
    @Published private(set) var clientKeyMode = LocalProxyClientKeyMode.persistent
    @Published private(set) var egressSettings = LocalProxyEgressSettings()
    @Published private(set) var selfCheck = LocalProxySelfCheckModel()
    @Published private(set) var egressState = "unconfigured"
    @Published private(set) var discoveringNodes = false
    private var selfCheckTask: Task<Void, Never>?
    private var selfCheckRequestID: String?
    private var cooldownKinds: [String: String] = [:]
    private var probeStates: [String: String] = [:]
    private var activeProbes = Set<String>()
    enum PreferencesFailure { case read, save }
    @Published private(set) var preferencesFailure: PreferencesFailure?
    @Published private(set) var issue: String?
    var visibleIssue: String? {
        preferencesFailure != nil && issue == message(.unavailable) ? nil : issue
    }
    @Published private(set) var isEnabled = false
    @Published private(set) var automaticRecoveryEnabled = false
    @Published private(set) var automaticRecoveryMessage: String?
    @Published private(set) var isAutomaticallyRecovering = false
    @Published private(set) var desktopAvailable = false
    @Published private(set) var creditFallbackEnabled = false
    @Published private(set) var creditPrimaryFloor = 2000
    @Published private(set) var creditSecondaryFloor = 1500
    @Published private(set) var legacyCooldownRecoveryIDs = Set<String>()
    @Published private(set) var isPreparingLegacyCooldownRecovery = false
    @Published private(set) var quotaPolicyMessage: String?
    var canEdit: Bool { process == nil && (phase == .stopped || phase == .failed) && leases.isEmpty && exitCleanupID == nil }
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
    private var canStartRun: Bool {
        canEdit && !isPreparingLegacyCooldownRecovery && legacyRecoveryPreparedConfirmation == nil && rows.count <= 100 && rows.contains(where: \.isEnabled)
            && !usageStore.isPreview && !preferencesBlocked && !finishing
    }
    var canStart: Bool { canStartRun && !isAutomaticallyRecovering }
    var canSetAutomaticRecovery: Bool { !usageStore.isPreview && !preferencesBlocked && !finishing }
    func canToggleAccount(id: String) -> Bool {
        guard !usageStore.isPreview, !preferencesBlocked, !finishing, rows.contains(where: { $0.id == id }) else { return false }
        if canEdit { return true }
        guard phase == .running, process?.isRunning == true else { return false }
        // Existing requests retain their order and admitted leases. Removal
        // also blocks later admissions from an older waiting/retrying request;
        // unrelated traffic must not lock every account's participation switch.
        // Removal remains available even when the profile's current identity
        // differs; re-enabling requires the binding verified at startup.
        return preferences.enabledIDs.contains(id) || (registeredPool[id] != nil && isRegisteredBindingCurrent(id))
    }
    var canStop: Bool { isAutomaticallyRecovering || ((process != nil || exitCleanupID != nil) && phase != .stopping) }
    var canFinishTermination: Bool { process == nil && leases.isEmpty && exitCleanupID == nil && !isAutomaticallyRecovering }
    var requiresStopConfirmation: Bool {
        process != nil || !leases.isEmpty || exitCleanupID != nil || isAutomaticallyRecovering || phase == .starting || phase == .stopping
    }

    private let usageStore: UsageStore
    private let previewPendingRegistrationIDs: Set<String>
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
    private struct PoolBinding: Equatable {
        let home: URL
        let account: String
        let accountID: String
    }
    private struct MembershipSnapshot {
        let order: [String]
        let lastResortIDs: [String]
        let deferredIDs: [String]
        let creditFallback: Bool
        let revocations: [String: UUID]
        let capturedAt: TimeInterval
    }
    private var registeredPool: [String: PoolBinding] = [:]
    private var runProfiles: LocalProxyRunProfiles?
    private struct HotRegistration {
        let requestID: String
        let runID: String
        let binding: PoolBinding
        var acknowledged = false
    }
    private var hotRegistrations: [String: HotRegistration] = [:]
    private var attemptedHotBindings: [String: PoolBinding] = [:]
    @Published private(set) var hotActivationIDs = Set<String>()
    @Published private(set) var hotActivationErrors: [String: String] = [:]
    private var membershipSnapshots: [String: MembershipSnapshot] = [:]
    private var memberRevocations: [String: UUID] = [:]
    // HTTP requests have a 15-minute bound. Completed requests send an
    // idempotent order_end; this timeout bounds leaked snapshots after failure.
    private let membershipSnapshotLifetime: TimeInterval = 16 * 60
    private let maximumMembershipSnapshots = 4096
    private struct Lease: Sendable {
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
    private var exitCleanupTask: Task<Void, Never>?
    private var exitCleanupID: UUID?
    private var exitCleanupRunID: String?
    private var exitCleanupEvidenceID: UUID?
    private var exitCleanupEvidence: ExitCleanupEvidence?
    private let exitCleanupWorker = DispatchSemaphore(value: 1)
    private var finishing = false
    private var forceTerminationRequested = false
    private var requestedExitReason: ExitReason?
    private var startAttemptID: UUID?
    private struct AutomaticRecoveryPlan {
        let id: UUID
        let failedRun: String
        let port: Int
        let clientKey: String
        let bindings: [String: PoolBinding]
        let systemIdentity: LegacyRecoveryIdentity
        let delay: UInt64
    }
    private var automaticRecoveryPlan: AutomaticRecoveryPlan?
    private var automaticRecoveryTask: Task<Void, Never>?
    private var automaticRecoveryStartingRun: String?
    private var cancelledAutomaticRecoveryRun: String?
    private var automaticRecoveryAttempts: [TimeInterval] = []
    private struct LegacyRecoveryIdentity: Equatable {
        let id: String
        let home: URL
        let account: String
        let accountID: String
        init?(_ profile: CodexProfile) {
            guard let accountID = profile.lastSnapshot?.accountID, !accountID.isEmpty else { return nil }
            id = profile.id
            home = profile.codexHomeURL
            account = profile.recordedAccountKey
            self.accountID = accountID
        }
    }
    private struct LegacyRecoveryTicket {
        let id: UUID
        let target: LegacyRecoveryIdentity
        let system: LegacyRecoveryIdentity
        let refreshStartedAt: Date
    }
    private struct LegacyRecoveryPreparation {
        let ticket: LegacyRecoveryTicket
        let prepared: LocalProxyLegacyCooldownRecovery.Prepared
        let continuation: CheckedContinuation<LocalProxyLegacyCooldownRecovery.Confirmation?, Never>
    }
    private var legacyRecoveryPreparation: LegacyRecoveryPreparation?
    private var legacyRecoveryTicket: LegacyRecoveryTicket?
    private var legacyRecoveryPreparedConfirmation: LocalProxyLegacyCooldownRecovery.Confirmation?
    private var legacyRecoveryGeneration = UUID()

    init(usageStore: UsageStore, previewPreferences: LocalProxyPreferences? = nil, previewPendingRegistrationIDs: Set<String> = []) {
        self.usageStore = usageStore
        self.previewPendingRegistrationIDs = usageStore.isPreview ? previewPendingRegistrationIDs : []
        directory = DispatchParticipationPaths.supportDirectory()
        if usageStore.isPreview, let previewPreferences, previewPreferences.validAccountPolicies, previewPreferences.validAccountRepresentatives,
            previewPreferences.validLastIDs, previewPreferences.validLastOverrides, previewPreferences.validResetStopRules
        {
            preferences = previewPreferences
        }
        if !usageStore.isPreview {
            do {
                if let data = try DispatchParticipationSync.readBoundedRegularFile(
                    directory.appendingPathComponent("local-proxy-queue-v1.json"), maximumBytes: 65536, allowMissing: true)
                {
                    var saved = try JSONDecoder().decode(LocalProxyPreferences.self, from: data)
                    if let reference = saved.secretsReference {
                        let secrets = try LocalProxyPreferenceSecrets.read(reference)
                        saved.persistentClientKey = secrets.clientKey
                        if saved.egress != nil { saved.egress?.mihomoSecret = secrets.mihomoSecret }
                    }
                    let inheritedEgressDefault = saved.egress?.isUntouchedLegacyDefault == true
                    if inheritedEgressDefault { saved.egress = LocalProxyEgressSettings() }
                    guard saved.schemaVersion == 1, saved.order.count <= 1000, Set(saved.order).count == saved.order.count,
                        saved.enabledIDs.count <= 1000, saved.validAccountPolicies, saved.validAccountRepresentatives, saved.validLastIDs, saved.validLastOverrides,
                        saved.validResetStopRules, saved.validNetworkSettings,
                        LocalProxyPreferences.validCreditFloors(primary: saved.creditFloors.primary, secondary: saved.creditFloors.secondary)
                    else { throw LocalProxyFailure.unavailable }
                    preferences = saved
                    if inheritedEgressDefault || (saved.secretsReference == nil && (saved.persistentClientKey != nil || !(saved.egress?.mihomoSecret.isEmpty ?? true))) {
                        guard savePreferences() else { throw LocalProxyFailure.unavailable }
                    }
                }
            } catch {
                preferencesBlocked = true
                preferencesFailure = .read
                issue = message(.unavailable)
            }
        }
        listenPort = preferences.effectiveListenPort
        clientKeyMode = preferences.effectiveClientKeyMode
        egressSettings = preferences.egress ?? LocalProxyEgressSettings()
        isEnabled = preferences.isEnabled
        automaticRecoveryEnabled = preferences.automaticRecoveryEnabled == true
        creditFallbackEnabled = preferences.creditFallback == true
        creditPrimaryFloor = preferences.creditFloors.primary
        creditSecondaryFloor = preferences.creditFloors.secondary
        usageStore.proxyQuotaResetObservationEnabled = preferences.resetStopRules?.isEmpty == false
        usageStore.onProxyOfficialQuotaReset = { [weak self] profileID, accountID, observedAt in
            self?.pauseAfterOfficialQuotaReset(profileID: profileID, accountID: accountID, observedAt: observedAt)
        }
        rebuildRows()
        observation = usageStore.$profiles.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildRows() }
        }
        orderObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildRows() }
        }
    }

    @discardableResult
    func setNetworkSettings(port: Int, mode: LocalProxyClientKeyMode, egress: LocalProxyEgressSettings) -> Bool {
        guard canEdit, !usageStore.isPreview, !preferencesBlocked else { return false }
        let previous = preferences
        preferences.listenPort = port
        preferences.clientKeyMode = mode
        preferences.egress = egress
        guard preferences.validNetworkSettings else {
            preferences = previous
            return false
        }
        guard savePreferences() else {
            preferences = previous
            return false
        }
        listenPort = port
        clientKeyMode = mode
        egressSettings = egress
        return true
    }

    func discoverEgressNodes(settings: LocalProxyEgressSettings) async -> [String]? {
        guard canEdit, !usageStore.isPreview, !discoveringNodes else { return nil }
        discoveringNodes = true
        defer { discoveringNodes = false }
        do {
            let nodes = try await LocalProxyNetworkProbe.selectorNodes(settings: settings)
            if nodes.isEmpty { issue = "未找到指定分组中的可用候选节点，请核对控制地址与分组。" }
            return nodes
        } catch {
            issue = "无法读取出口节点，请核对控制地址、密钥与分组。"
            return nil
        }
    }

    func probeNow(profileID: String) {
        guard phase == .running, activeIDs.contains(profileID), cooldownKinds[profileID] == "egress", probeStates[profileID] != "probing" else { return }
        sendNetworkCommand(["command": "probe", "profileID": profileID])
    }

    private func sendNetworkCommand(_ object: [String: Any]) {
        guard phase == .running, !finishing, process?.isRunning == true else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input?.write(contentsOf: data)
        } catch { issue = message(.unavailable) }
    }

    private func probeOfficialBackend(profileID: String, expectedRun: String) async -> LocalProxyReply {
        guard phase == .running, process?.isRunning == true, !finishing, !preferencesBlocked, runID == expectedRun else { return .failure(.stopping) }
        guard activeIDs.contains(profileID), preferences.enabledIDs.contains(profileID) else { return .failure(.notParticipating) }
        guard !activeProbes.contains(profileID), activeProbes.count < 2 else { return .failure(.credentialsBusy) }
        guard let profile = usageStore.profiles.first(where: { $0.id == profileID }),
            let system = usageStore.profiles.first(where: \.isSystemProfile),
            let current = currentBinding(profile, system: system), isRegisteredBindingCurrent(profileID)
        else { return .failure(.identity) }
        let revocation = memberRevocations[profileID]
        let desktop = current.lastSnapshot?.accountID == system.lastSnapshot?.accountID
        activeProbes.insert(profileID)
        defer { activeProbes.remove(profileID) }
        do {
            let credential = try await Task.detached {
                try LocalProxyCredentialReader.readForProbe(profile: current, system: system, allowDesktopAccount: desktop)
            }.value
            guard phase == .running, runID == expectedRun, !finishing, currentBinding(current, system: system) != nil,
                memberRevocations[profileID] == revocation, activeIDs.contains(profileID), preferences.enabledIDs.contains(profileID)
            else { return .failure(.notParticipating) }
            let observedAt = Date().timeIntervalSince1970
            let status = try await LocalProxyNetworkProbe.official(token: credential.token, accountID: credential.accountID)
            let after = try await Task.detached {
                try LocalProxyCredentialReader.readForProbe(profile: current, system: system, allowDesktopAccount: desktop)
            }.value
            guard !Task.isCancelled, after.token == credential.token, after.accountID == credential.accountID,
                phase == .running, runID == expectedRun, !finishing, currentBinding(current, system: system) != nil,
                memberRevocations[profileID] == revocation, activeIDs.contains(profileID), preferences.enabledIDs.contains(profileID)
            else { return .failure(.identity) }
            return LocalProxyReply(ok: true, probeStatus: status, probeObservedAt: observedAt, probeIdentityHash: DispatchActivityStore.hash(credential.accountID))
        } catch let failure as LocalProxyFailure { return .failure(failure) } catch { return .failure(.unavailable) }
    }

    func runSelfCheck() {
        guard phase == .running, !usageStore.isPreview, !selfCheck.isRunning, let run = runID, let endpoint, let key = clientKey else { return }
        selfCheck.begin()
        if !egressSettings.enabled {
            selfCheck.update("egress", passed: true, detail: "跟随系统代理，自动切换未开启")
        }
        let checkID = UUID().uuidString
        selfCheckRequestID = checkID
        sendNetworkCommand(["command": "self_check", "requestID": checkID])
        selfCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let proxy = try LocalProxyNetworkSettings.load()
                self.selfCheck.update("system", passed: proxy != nil, detail: proxy != nil ? "已启用手动系统代理" : "未启用系统代理；请检查系统网络设置")
            } catch { self.selfCheck.update("system", passed: false, detail: "系统代理设置不可用；请检查手动代理与 PAC 设置") }
            let candidates = self.rows.filter { $0.isEnabled && self.registeredPool[$0.id] != nil }
            let probeRow = candidates.first { $0.isDesktopAccount } ?? candidates.first
            if let probeRow {
                let proof = await self.probeOfficialBackend(profileID: probeRow.id, expectedRun: run)
                guard self.runID == run, self.selfCheckRequestID == checkID, !Task.isCancelled else { return }
                self.selfCheck.update(
                    "official", passed: proof.ok && proof.probeStatus == "reachable",
                    detail: proof.ok && proof.probeStatus == "reachable" ? "已启用账号本轮 usage 请求成功" : "已启用账号后端探测失败；请检查登录和网络")
            } else {
                self.selfCheck.update("official", passed: false, detail: "没有已启用并注册的账号；请先核验并启用账号")
            }
            let endpointOK = (try? await LocalProxyNetworkProbe.models(endpoint: endpoint, key: key)) == true
            guard self.runID == run, self.selfCheckRequestID == checkID, !Task.isCancelled else { return }
            self.selfCheck.update("endpoint", passed: endpointOK, detail: endpointOK ? "端口、访问密钥和模型列表验证成功" : "端点验证失败；请检查端口、密钥与反代进程")
            let active = self.rows.filter(\.isEnabled)
            let cooling = active.filter { ($0.cooldownUntil ?? .distantPast) > Date() }.count
            let limited = active.filter { ["quota", "usage_limit"].contains($0.state) }.count
            let available = active.filter { ($0.cooldownUntil ?? .distantPast) <= Date() && ["ready", "current"].contains($0.state) }.count
            let unknown = active.filter { !["ready", "current", "quota", "usage_limit", "busy"].contains($0.state) && ($0.cooldownUntil ?? .distantPast) <= Date() }.count
            self.selfCheck.update("pool", passed: available > 0, detail: "可用 \(available) · 冷却 \(cooling) · 限流/额度 \(limited) · 未确认 \(unknown) · 总数 \(active.count)")
            for _ in 0..<160 {
                if self.selfCheck.steps.first(where: { $0.id == "egress" })?.passed != nil { break }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard self.runID == run, self.selfCheckRequestID == checkID else { return }
            }
            if self.selfCheck.steps.first(where: { $0.id == "egress" })?.passed == nil {
                self.selfCheck.update("egress", passed: false, detail: "出口探测超时；请检查控制 API 和分组")
            }
            self.selfCheck.isRunning = false
            self.selfCheckTask = nil
        }
    }

    private func consumeEgress(_ object: [String: Any]) {
        guard let state = object["state"] as? String,
            ["healthy", "disabled", "unconfigured", "unavailable", "dead", "switched", "all_dead", "changed"].contains(state)
        else { return }
        egressState = state
        if let requestID = object["requestID"] as? String, requestID == selfCheckRequestID {
            let latency = (object["latencyMS"] as? Int).flatMap { (0...60000).contains($0) ? $0 : nil }
            if state == "disabled", !egressSettings.enabled {
                selfCheck.update("egress", passed: true, detail: "跟随系统代理，自动切换未开启")
            } else {
                selfCheck.update(
                    "egress", passed: state == "healthy", detail: state == "healthy" ? "当前分组节点可达" + (latency.map { " · \($0) ms" } ?? "") : "出口未验证（\(state)）；请检查控制地址、分组和节点")
            }
        }
        if ["switched", "all_dead"].contains(state), let runID {
            Self.recordIssue(
                id: "proxy-network-\(runID)", phase: state,
                summary: state == "switched" ? "Local proxy watchdog switched an unavailable egress node." : "Local proxy watchdog found no reachable allowlisted node.")
        }
    }

    func setOptIn(_ value: Bool) {
        if !value { cancelAutomaticRecovery(stopStartingRun: true) }
        guard canEdit, !usageStore.isPreview, !preferencesBlocked else { return }
        let previous = preferences
        preferences.isEnabled = value
        guard savePreferences() else {
            preferences = previous
            return
        }
        isEnabled = value
    }
    @discardableResult
    func setAutomaticRecovery(_ enabled: Bool) -> Bool {
        // Revocation takes effect even if saving the preference subsequently fails.
        if !enabled { cancelAutomaticRecovery(stopStartingRun: true) }
        guard canSetAutomaticRecovery else { return false }
        let previous = preferences
        preferences.automaticRecoveryEnabled = enabled
        guard savePreferences() else {
            preferences = previous
            cancelAutomaticRecovery()
            return false
        }
        automaticRecoveryEnabled = enabled
        return true
    }

    private func cancelAutomaticRecovery(message: String? = nil, stopStartingRun: Bool = false) {
        if stopStartingRun, let run = automaticRecoveryStartingRun, runID == run, phase == .starting {
            cancelledAutomaticRecoveryRun = run
            Task { [weak self] in await self?.stop(expectedRun: run) }
        }
        // Revoke the generation, not the stop/start Task: cancelling a graceful
        // stop's sleeps would accelerate its termination deadlines.
        automaticRecoveryPlan = nil
        automaticRecoveryTask = nil
        automaticRecoveryStartingRun = nil
        isAutomaticallyRecovering = false
        automaticRecoveryMessage = message
    }

    private func failAutomaticRecovery(_ reason: String) {
        guard let plan = automaticRecoveryPlan else { return }
        Self.recordIssue(
            id: "proxy-recovery-\(plan.failedRun)", phase: "recovery_failed",
            summary: "Local proxy automatic recovery stopped: \(reason).")
        cancelAutomaticRecovery(
            message: WidgetLanguage.storedOrAutomatic().text(
                "自动恢复未完成，请检查后手动开启反代。", "Automatic recovery did not complete. Check the issue and start the proxy manually."))
    }

    private func prepareAutomaticRecovery(run: String, code: String, detail: String?, resolution: String?) {
        if automaticRecoveryPlan == nil { automaticRecoveryMessage = nil }
        let transient: Set<String> = ["timeout", "eof", "transport_unavailable", "registry_unavailable", "control_busy", "unavailable"]
        guard ["lease_acquire_unknown", "lease_release_unknown", "lease_heartbeat_failed"].contains(code),
            let detail, transient.contains(detail),
            resolution.map({ transient.contains($0) }) ?? (code != "lease_acquire_unknown")
        else {
            failAutomaticRecovery("ineligible_failure")
            return
        }
        if automaticRecoveryPlan?.failedRun == run { return }
        guard
            runID == run, phase == .running, process?.isRunning == true,
            automaticRecoveryEnabled, isEnabled, !preferencesBlocked, !finishing,
            preferences.effectiveListenPort != 0, preferences.effectiveClientKeyMode == .persistent,
            let clientKey, clientKey == preferences.persistentClientKey,
            endpoint == "http://127.0.0.1:\(preferences.effectiveListenPort)/v1",
            let system = usageStore.profiles.first(where: \.isSystemProfile), let systemIdentity = LegacyRecoveryIdentity(system),
            system.lastSnapshot?.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            failAutomaticRecovery("ineligible_failure")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        automaticRecoveryAttempts.removeAll { now - $0 >= 600 }
        guard automaticRecoveryAttempts.count < 3 else {
            automaticRecoveryMessage = WidgetLanguage.storedOrAutomatic().text(
                "10 分钟内已尝试自动恢复 3 次，已暂停；请检查后手动开启。",
                "Automatic recovery paused after 3 attempts in 10 minutes. Check the issue and start manually.")
            Self.recordIssue(
                id: "proxy-recovery-\(run)", phase: "recovery_exhausted",
                summary: "Local proxy automatic recovery exhausted its 10-minute budget.")
            return
        }
        let delays: [UInt64] = [2, 5, 10]
        let delay = delays[automaticRecoveryAttempts.count]
        automaticRecoveryAttempts.append(now)
        automaticRecoveryPlan = AutomaticRecoveryPlan(
            id: UUID(), failedRun: run, port: preferences.effectiveListenPort, clientKey: clientKey,
            bindings: registeredPool, systemIdentity: systemIdentity, delay: delay)
        isAutomaticallyRecovering = true
        automaticRecoveryMessage = WidgetLanguage.storedOrAutomatic().text(
            "正在安全停止故障反代，随后自动恢复…", "Safely stopping the failed proxy before automatic recovery…")
        Self.recordIssue(
            id: "proxy-recovery-\(run)", phase: "recovery_pending",
            summary: "Local proxy automatic recovery scheduled (attempt \(automaticRecoveryAttempts.count) of 3).")
    }

    private func automaticRecoveryInputsMatch(_ plan: AutomaticRecoveryPlan) -> Bool {
        guard automaticRecoveryEnabled, isEnabled, !preferencesBlocked, !finishing,
            preferences.effectiveListenPort == plan.port, preferences.effectiveClientKeyMode == .persistent,
            preferences.persistentClientKey == plan.clientKey,
            let system = usageStore.profiles.first(where: \.isSystemProfile), LegacyRecoveryIdentity(system) == plan.systemIdentity,
            (try? makeRegisteredPool()) == plan.bindings
        else { return false }
        let enabledRows = rows.filter(\.isEnabled)
        return !enabledRows.isEmpty
            && enabledRows.allSatisfy { row in
                guard let profile = usageStore.profiles.first(where: { $0.id == row.id }), !profile.isSystemProfile,
                    let accountID = profile.lastSnapshot?.accountID, !accountID.isEmpty
                else { return false }
                return plan.bindings[row.id] == PoolBinding(home: profile.codexHomeURL, account: profile.recordedAccountKey, accountID: accountID)
            }
    }

    private func scheduleAutomaticRecoveryAfterCleanup() {
        guard let plan = automaticRecoveryPlan, automaticRecoveryTask == nil else { return }
        guard canStartRun, automaticRecoveryInputsMatch(plan) else {
            failAutomaticRecovery("cleanup_or_configuration_not_ready")
            return
        }
        automaticRecoveryMessage = WidgetLanguage.storedOrAutomatic().text(
            "将在 \(plan.delay) 秒后自动恢复反代…", "Automatically recovering the proxy in \(plan.delay) seconds…")
        automaticRecoveryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: plan.delay * 1_000_000_000) } catch { return }
            guard let self, self.automaticRecoveryPlan?.id == plan.id else { return }
            guard self.canStartRun, self.automaticRecoveryInputsMatch(plan) else {
                self.failAutomaticRecovery("configuration_changed")
                return
            }
            // Reuse the bounded, read-only credential validator off-main. It
            // neither refreshes tokens nor switches the central Desktop account.
            let profiles = self.usageStore.profiles.filter { !$0.isSystemProfile && self.preferences.enabledIDs.contains($0.id) && plan.bindings[$0.id] != nil }
            let validatedIDs = Set(profiles.map(\.id))
            guard let system = self.usageStore.profiles.first(where: \.isSystemProfile) else {
                self.failAutomaticRecovery("identity_unconfirmed")
                return
            }
            let identitiesValid = await Task.detached {
                do {
                    for profile in profiles {
                        _ = try LocalProxyCredentialReader.readForProbe(
                            profile: profile, system: system, allowDesktopAccount: profile.lastSnapshot?.accountID == system.lastSnapshot?.accountID,
                            requireSystemIdentity: true)
                    }
                    return !profiles.isEmpty
                } catch { return false }
            }.value
            guard self.automaticRecoveryPlan?.id == plan.id else { return }
            guard identitiesValid, self.canStartRun, self.automaticRecoveryInputsMatch(plan),
                Set(self.rows.filter(\.isEnabled).map(\.id)) == validatedIDs
            else {
                self.failAutomaticRecovery("identity_or_configuration_unconfirmed")
                return
            }
            self.automaticRecoveryMessage = WidgetLanguage.storedOrAutomatic().text("正在恢复反代…", "Recovering the proxy…")
            await self.startRun()
            // ready clears this exact plan. A failed or superseded start must
            // never be reported as recovered or restart a newer user session.
            if self.automaticRecoveryPlan?.id == plan.id { self.failAutomaticRecovery("start_failed") }
        }
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
    // Only verified plan types select a window. A label or display multiplier
    // never promotes an unknown/other plan into this batch.
    private var quotaPolicyTargets: [(id: String, isProPlan: Bool)] {
        rows.compactMap { row in
            guard
                let profile = usageStore.profiles.first(where: {
                    $0.id == row.id && !$0.isSystemProfile && ($0.resolvedPlanType == "plus" || $0.isProPlan)
                })
            else { return nil }
            return (row.id, profile.isProPlan)
        }
    }
    var quotaPolicyTargetCount: Int { quotaPolicyTargets.count }
    var uniformQuotaRemainingReserve: Double? {
        let targets = quotaPolicyTargets
        let values = targets.map { preferences.policy(for: $0.id).remainingReserve(isProPlan: $0.isProPlan) }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
    var canApplyQuotaRemainingReserve: Bool {
        let targets = quotaPolicyTargets
        return canEditPolicy && !targets.isEmpty && Set(targets.map(\.id)).count == targets.count
            && targets.allSatisfy { target in
                let matches = usageStore.profiles.filter { $0.id == target.id }
                return matches.count == 1 && matches.first?.isSystemProfile == false
                    && matches.first?.lastSnapshot?.accountID?.isEmpty == false && canEditPolicy(for: target.id)
            }
    }
    @discardableResult
    func setQuotaRemainingReserve(_ remaining: Double) -> Bool {
        let language = WidgetLanguage.storedOrAutomatic()
        guard remaining.isFinite, (0...100).contains(remaining) else {
            quotaPolicyMessage = language.text("请输入 0–100 的剩余额度百分比。", "Enter a remaining-quota percentage from 0 to 100.")
            return false
        }
        guard quotaPolicyTargetCount > 0 else {
            quotaPolicyMessage = language.text("当前没有已核实的 Plus 或 Pro 账号；其他及未知套餐规则未修改。", "No verified Plus or Pro accounts; other and unknown plan rules remain unchanged.")
            return false
        }
        guard canApplyQuotaRemainingReserve else {
            quotaPolicyMessage = language.text(
                "全部规则未修改：有目标账号身份或运行绑定无法核实，请核对后再试。",
                "No rules changed: a target account identity or running binding could not be verified. Check it and retry.")
            return false
        }
        let targets = quotaPolicyTargets
        let usedLimit = LocalProxyAccountPolicy.complementPercent(remaining)
        let previous = preferences
        var policies = preferences.accountPolicies ?? [:]
        for target in targets {
            var policy = preferences.policy(for: target.id)
            if target.isProPlan { policy.sevenDayUsedLimit = usedLimit } else { policy.fiveHourUsedLimit = usedLimit }
            policies[target.id] = policy
        }
        preferences.accountPolicies = policies
        guard preferences.validAccountPolicies, savePreferences() else {
            preferences = previous
            quotaPolicyMessage = language.text("全部规则未保存，仍使用原规则。", "No rules were saved; previous rules remain.")
            return false
        }
        policyChanged()
        quotaPolicyMessage = language.text(
            "已为 \(targets.count) 个 Plus / Pro 账号保存剩余额度 \(remaining.formatted())%：Plus 5 小时，Pro 7 天；其他套餐不变。",
            "Saved a \(remaining.formatted())% remaining-quota reserve for \(targets.count) Plus / Pro accounts: Plus 5h, Pro 7d; other plans remain unchanged.")
        return true
    }
    private func policyChanged() {
        policyRevision &+= 1
        clearRefreshableAccountStates()
        rebuildRows()
        flushDisplayRows()
    }
    private func clearRefreshableAccountStates() {
        let now = Date()
        let refreshable: Set<String> = ["quota", "usage_limit", "subscription_pending", "quota_unknown", "temporary_error"]
        accountStates = accountStates.filter { id, state in
            // Quota refresh cannot prove an account or credential gate became idle.
            // Keep the helper's real quota/error cooldown effective until expiry.
            if let until = cooldowns[id], until > now { return true }
            return !refreshable.contains(state)
        }
    }
    func canSetResetStop(id: String) -> Bool {
        canReorder && rows.contains { $0.id == id }
            && (canEdit || isRegisteredBindingCurrent(id))
            && usageStore.profiles.first { $0.id == id }?.lastSnapshot?.accountID?.isEmpty == false
    }

    func setResetStop(id: String, enabled: Bool) {
        guard canSetResetStop(id: id),
            let accountID = usageStore.profiles.first(where: { $0.id == id })?.lastSnapshot?.accountID
        else { return }
        let previous = preferences
        var rules = preferences.resetStopRules ?? [:]
        if enabled {
            rules[id] = LocalProxyResetStopRule(accountHash: DispatchActivityStore.hash(accountID), armedAt: Date())
        } else {
            rules.removeValue(forKey: id)
        }
        preferences.resetStopRules = rules.isEmpty ? nil : rules
        if !savePreferences() { preferences = previous }
        usageStore.proxyQuotaResetObservationEnabled = preferences.resetStopRules?.isEmpty == false
        rebuildRows()
    }

    /// Called only after UsageStore verifies a fresh account-bound official
    /// quota observation. Notices, forecasts and clocks cannot enter this path.
    private func pauseAfterOfficialQuotaReset(profileID: String, accountID: String, observedAt: Date) {
        let now = Date()
        guard !usageStore.isPreview, !preferencesBlocked, !finishing,
            !accountID.isEmpty, (0...60).contains(now.timeIntervalSince(observedAt)),
            usageStore.profiles.contains(where: { $0.id == profileID && $0.lastSnapshot?.accountID == accountID })
        else { return }
        let hash = DispatchActivityStore.hash(accountID)
        let matching = (preferences.resetStopRules ?? [:]).filter { id, rule in
            rows.contains(where: { $0.id == id })
                && usageStore.profiles.contains(where: { $0.id == id && $0.lastSnapshot?.accountID == accountID })
                && (canEdit || isRegisteredBindingCurrent(id))
                && rule.accountHash == hash && observedAt > rule.armedAt
                && observedAt > (rule.pausedAt ?? .distantPast)
        }
        guard !matching.isEmpty else { return }
        let mirrors = Set(usageStore.profiles.filter { !$0.isSystemProfile && $0.lastSnapshot?.accountID == accountID }.map(\.id))
            .union(registeredPool.filter { $0.value.accountID == accountID }.map(\.key))
        guard !preferences.enabledIDs.isDisjoint(with: mirrors) else { return }
        let previous = preferences
        preferences.enabledIDs.subtract(mirrors)
        for (id, var rule) in matching {
            rule.pausedAt = observedAt
            preferences.resetStopRules?[id] = rule
        }
        guard savePreferences() else {
            preferences = previous
            rebuildRows()
            return
        }
        let revocation = UUID()
        for id in mirrors { memberRevocations[id] = revocation }
        if phase == .running { activeIDs = preferences.enabledIDs.intersection(Set(registeredPool.keys)) }
        // Do not release or cancel admitted leases. Existing responses finish;
        // new orders and older waiting/retrying admissions see the revocation.
        rebuildRows()
        flushDisplayRows()
    }

    func canHotActivateAccount(id: String) -> Bool {
        guard !usageStore.isPreview, !preferencesBlocked, !finishing,
            phase == .running, process?.isRunning == true, registeredPool[id] == nil,
            hotActivationIDs.isEmpty, registeredPool.count < 100, runProfiles != nil,
            let binding = hotActivationBinding(id: id)
        else { return false }
        return attemptedHotBindings[id].map { $0 == binding } ?? true
    }

    private func hotActivationBinding(id: String) -> PoolBinding? {
        let matches = usageStore.profiles.filter { $0.id == id && !$0.isSystemProfile }
        guard matches.count == 1, let profile = matches.first,
            rows.contains(where: { $0.id == id }), profile.dispatchRegistrationPending != true,
            let accountID = profile.lastSnapshot?.accountID, !accountID.isEmpty,
            alias(for: profile) != nil,
            !registeredPool.values.contains(where: { $0.accountID == accountID || $0.account == profile.recordedAccountKey })
        else { return nil }
        return PoolBinding(home: profile.codexHomeURL, account: profile.recordedAccountKey, accountID: accountID)
    }

    func cancelHotActivation(id: String) {
        hotRegistrations.removeValue(forKey: id)
        hotActivationIDs.remove(id)
        // Any helper placeholder remains denied by host membership. Retain its
        // immutable attempted binding so a changed identity cannot reuse it.
    }

    private func failHotActivation(id: String, code: String, requestID: String) {
        let allowed = [
            "identity", "credentials_busy", "login_expired", "unavailable", "timeout", "save",
            "duplicate_identity", "pool_full", "cooldown_pending", "cooldown_unavailable", "registration_failed",
        ]
        let reason = allowed.contains(code) ? code : "unavailable"
        hotActivationErrors[id] = reason
        Self.recordIssue(
            id: "proxy-hot-\(requestID)", phase: "hot_activation_\(reason)",
            summary: "Local proxy account hot activation did not finish: \(reason).")
    }

    func hotActivationFailureMessage(_ code: String) -> String {
        let language = WidgetLanguage.storedOrAutomatic()
        switch code {
        case "credentials_busy": return language.text("凭据正在读取或更新，账号尚未加入；请稍后重试。", "Credentials are being read or updated. The account has not joined; retry shortly.")
        case "login_expired":
            return language.text("登录凭据已过期或尚未同步额度，请刷新此账号后重试。", "Sign-in credentials expired or need a matching quota observation. Refresh this account, then retry.")
        case "identity":
            return language.text("账号身份与已登记资料不一致，账号尚未加入；请检查此账号的登录状态。", "The account identity does not match its registration. The account has not joined; check its sign-in.")
        case "duplicate_identity": return language.text("此账号身份已在反代中，请使用已参与的同身份账号卡。", "This account identity is already in the proxy. Use its participating account card.")
        case "pool_full": return language.text("当前反代已登记 100 个账号，无法继续加入。", "The current proxy has registered 100 accounts and cannot add another.")
        case "cooldown_pending": return language.text("此账号仍有冷却记录，请在冷却结束后重试。", "This account has a remaining cooldown. Retry when it expires.")
        case "cooldown_unavailable": return language.text("无法核对冷却记录，账号尚未加入；请稍后重试。", "Cooldown records could not be verified. The account has not joined; retry shortly.")
        case "timeout":
            return language.text("反代未在 10 秒内确认加入，账号尚未加入；请稍后重试。", "The proxy did not acknowledge registration within 10 seconds. The account has not joined; retry shortly.")
        case "save": return language.text("参与设置保存失败，账号尚未加入；请检查可用空间后重试。", "Participation settings could not be saved. The account has not joined; check free space, then retry.")
        case "registration_failed": return language.text("反代登记失败，账号尚未加入；请稍后重试。", "Proxy registration failed. The account has not joined; retry shortly.")
        default: return language.text("反代控制通道暂不可用，账号尚未加入；请稍后重试。", "The proxy control channel is unavailable. The account has not joined; retry shortly.")
        }
    }

    func hotActivateAccount(id: String) async {
        guard canHotActivateAccount(id: id), let binding = hotActivationBinding(id: id),
            let run = runID, let child = process, let pipe = input, let runProfiles,
            let profile = usageStore.profiles.first(where: { $0.id == id }),
            let system = usageStore.profiles.first(where: \.isSystemProfile)
        else { return }
        let requestID = UUID().uuidString.lowercased()
        hotRegistrations[id] = HotRegistration(requestID: requestID, runID: run, binding: binding)
        hotActivationIDs.insert(id)
        hotActivationErrors.removeValue(forKey: id)
        defer {
            if hotRegistrations[id]?.requestID == requestID { hotRegistrations.removeValue(forKey: id) }
            if hotRegistrations[id] == nil { hotActivationIDs.remove(id) }
        }
        func current() -> Bool {
            !Task.isCancelled && !finishing && phase == .running && runID == run && process === child && child.isRunning
                && hotRegistrations[id]?.requestID == requestID && hotActivationBinding(id: id) == binding
                && usageStore.profiles.first(where: \.isSystemProfile).map {
                    $0.codexHomeURL == system.codexHomeURL && $0.recordedAccountKey == system.recordedAccountKey
                        && $0.lastSnapshot?.accountID == system.lastSnapshot?.accountID
                } == true
        }
        func verified() async -> LocalProxyFailure? {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var retry = false
            while current() {
                if retry, ProcessInfo.processInfo.systemUptime >= deadline { return .credentialsBusy }
                guard let currentProfile = usageStore.profiles.first(where: { $0.id == profile.id }),
                    let currentSystem = usageStore.profiles.first(where: \.isSystemProfile)
                else { return .identity }
                let failure = await Task.detached { () -> LocalProxyFailure? in
                    do {
                        _ = try LocalProxyCredentialReader.readForProbe(
                            profile: currentProfile, system: currentSystem,
                            allowDesktopAccount: currentProfile.lastSnapshot?.accountID == currentSystem.lastSnapshot?.accountID,
                            requireSystemIdentity: true)
                        return nil
                    } catch let failure as LocalProxyFailure { return failure } catch { return .unavailable }
                }.value
                guard current() else { return .stopping }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard failure == .credentialsBusy, remaining > 0 else { return failure }
                retry = true
                do { try await Task.sleep(nanoseconds: UInt64(min(0.05, remaining) * 1_000_000_000)) } catch { return .stopping }
            }
            return .stopping
        }
        let initialFailure = await verified()
        guard current() else { return }
        if let failure = initialFailure {
            failHotActivation(id: id, code: failure.rawValue, requestID: requestID)
            return
        }
        attemptedHotBindings[id] = binding
        do {
            var data = try JSONSerialization.data(withJSONObject: [
                "command": "register_account", "runID": run, "requestID": requestID,
                "profileID": id, "identityHash": DispatchActivityStore.hash(binding.accountID),
            ])
            data.append(10)
            // All writes to this inherited control pipe are MainActor-serialized.
            // Require room for one atomic pipe record so a stalled helper cannot
            // block the UI or postpone cancellation/ACK timeout indefinitely.
            let descriptor = pipe.fileDescriptor
            var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard data.count <= fpathconf(descriptor, _PC_PIPE_BUF),
                Darwin.poll(&writable, 1, 0) == 1, writable.revents & Int16(POLLOUT) != 0,
                writable.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0
            else { throw LocalProxyFailure.unavailable }
            try pipe.write(contentsOf: data)
        } catch {
            failHotActivation(id: id, code: "unavailable", requestID: requestID)
            return
        }
        for _ in 0..<100 {
            guard current() else { return }
            if hotRegistrations[id]?.acknowledged == true { break }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
        guard current(), hotRegistrations[id]?.acknowledged == true else {
            if hotRegistrations[id]?.requestID == requestID { failHotActivation(id: id, code: "timeout", requestID: requestID) }
            return
        }
        // Recheck the local identity after acknowledgment. No network quota
        // refresh or model request is sent to validate registration.
        let finalFailure = await verified()
        guard current() else { return }
        if let failure = finalFailure {
            failHotActivation(id: id, code: failure.rawValue, requestID: requestID)
            return
        }
        let previous = preferences
        preferences.knownIDs.insert(id)
        preferences.enabledIDs.insert(id)
        guard savePreferences() else {
            preferences = previous
            failHotActivation(id: id, code: "save", requestID: requestID)
            return
        }
        runProfiles.insert(id)
        registeredPool[id] = binding
        activeIDs.insert(id)
        accountStates.removeValue(forKey: id)
        hotActivationErrors.removeValue(forKey: id)
        rebuildRows()
        flushDisplayRows()
    }

    func setAccountEnabled(id: String, enabled: Bool) {
        guard canToggleAccount(id: id), !enabled || canEdit || isRegisteredBindingCurrent(id),
            let profile = usageStore.profiles.first(where: { $0.id == id })
        else { return }
        let identityKey = representativeIdentityKey(for: profile)
        let mirrorIDs = Set(usageStore.profiles.filter { !$0.isSystemProfile && representativeIdentityKey(for: $0) == identityKey }.map(\.id))
            .union(registeredPool.filter { DispatchActivityStore.hash($0.value.account) == identityKey }.map(\.key))
        let previous = preferences
        preferences.knownIDs.formUnion(mirrorIDs)
        if enabled {
            preferences.enabledIDs.formUnion(mirrorIDs)
            for member in mirrorIDs {
                if var rule = preferences.resetStopRules?[member],
                    let accountID = profile.lastSnapshot?.accountID, rule.accountHash == DispatchActivityStore.hash(accountID)
                {
                    rule = LocalProxyResetStopRule(accountHash: rule.accountHash, armedAt: Date())
                    preferences.resetStopRules?[member] = rule
                }
            }
        } else {
            preferences.enabledIDs.subtract(mirrorIDs)
        }
        guard savePreferences() else {
            preferences = previous
            rebuildRows()
            return
        }
        if !enabled {
            let revocation = UUID()
            for member in mirrorIDs { memberRevocations[member] = revocation }
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
        } else {
            preferences.priorityIDs.remove(id)
        }
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
        } else {
            ids.remove(id)
        }
        preferences.lastIDs = ids
    }
    private func orderingGroup(for id: String) -> Int? {
        usageStore.profiles.first { $0.id == id }.map {
            LocalProxyRouting.group(
                $0, userLast: preferences.lastIDs?.contains(id) == true,
                lastOverride: preferences.lastOverrides?[id])
        }
    }
    func moveAccount(id: String, by offset: Int) {
        let displayed = panelOrderedDisplayRows
        guard canMoveAccount(id: id, by: offset),
            let index = displayed.firstIndex(where: { $0.id == id }), displayed.indices.contains(index + offset)
        else { return }
        var ids = displayed.map(\.id)
        ids.swapAt(index, index + offset)
        let previous = preferences
        let source = displayed[index]
        let target = displayed[index + offset]
        // Moving across a sorting group explicitly adopts the adjacent row's
        // choice, so rebuilding and the helper's routing cannot undo the move.
        // Participation, identity, spending limits and leases are untouched.
        if source.isLast != target.isLast || source.isPriority != target.isPriority {
            setLastPreference(id: id, last: target.isLast)
            if target.isPriority { preferences.priorityIDs.insert(id) } else { preferences.priorityIDs.remove(id) }
        }
        preferences.order = ids
        if !savePreferences() { preferences = previous }
        rebuildRows()
        flushDisplayRows()
    }
    func canMoveAccount(id: String, by offset: Int) -> Bool {
        let displayed = panelOrderedDisplayRows
        guard canReorder, !usageStore.isPreview, !preferencesBlocked, offset == -1 || offset == 1,
            let index = displayed.firstIndex(where: { $0.id == id }), displayed.indices.contains(index + offset)
        else { return false }
        let source = displayed[index]
        let target = displayed[index + offset]
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
        // Refresh stale host admission failures while preserving live helper cooldowns.
        clearRefreshableAccountStates()
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
    func recordManualResetConfirmed(_ receipt: CodexResetCreditController.ManualResetConfirmation) {
        usageStore.recordManualResetConfirmed(receipt)
    }
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

    func canRecoverLegacyCooldown(for id: String) -> Bool {
        canEdit && !isPreparingLegacyCooldownRecovery && legacyRecoveryPreparedConfirmation == nil && !usageStore.isPreview && !preferencesBlocked && !finishing
            && legacyCooldownRecoveryIDs.contains(id) && preferences.enabledIDs.contains(id)
            && rows.filter { $0.id == id }.count == 1
    }

    func prepareLegacyCooldownRecovery(for id: String, completion: @escaping (Bool) -> Void) {
        guard canRecoverLegacyCooldown(for: id) else {
            completion(false)
            return
        }
        let generation = UUID()
        legacyRecoveryGeneration = generation
        Task { @MainActor in
            guard legacyRecoveryGeneration == generation else {
                completion(false)
                return
            }
            let confirmation = await prepareLegacyCooldownRecovery(for: id)
            guard legacyRecoveryGeneration == generation else {
                completion(false)
                return
            }
            legacyRecoveryPreparedConfirmation = confirmation
            completion(legacyRecoveryPreparedConfirmation != nil)
        }
    }

    @discardableResult
    func recoverLegacyCooldown(for id: String) -> Bool {
        guard let confirmation = legacyRecoveryPreparedConfirmation, confirmation.profileID == id else { return false }
        legacyRecoveryPreparedConfirmation = nil
        return commitLegacyCooldownRecovery(confirmation)
    }

    func cancelLegacyCooldownRecovery() {
        legacyRecoveryGeneration = UUID()
        cancelLegacyCooldownRecoveryPreparation()
        legacyRecoveryPreparedConfirmation = nil
        legacyRecoveryTicket = nil
    }

    /// Refresh this identity explicitly, then let the existing profiles publisher
    /// resume preparation only after the observation was successfully saved.
    func prepareLegacyCooldownRecovery(for id: String) async -> LocalProxyLegacyCooldownRecovery.Confirmation? {
        guard canRecoverLegacyCooldown(for: id), !Task.isCancelled else { return nil }
        do {
            let (profile, system) = try legacyRecoveryProfiles(for: id)
            guard let target = LegacyRecoveryIdentity(profile), let central = LegacyRecoveryIdentity(system) else { throw LocalProxyFailure.identity }
            let prepared = try LocalProxyLegacyCooldownRecovery.prepare(at: directory.appendingPathComponent("LocalProxy", isDirectory: true), profileID: id)
            let ticket = LegacyRecoveryTicket(id: UUID(), target: target, system: central, refreshStartedAt: Date())
            legacyRecoveryTicket = nil
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    legacyRecoveryPreparation = LegacyRecoveryPreparation(ticket: ticket, prepared: prepared, continuation: continuation)
                    isPreparingLegacyCooldownRecovery = true
                    issue = nil
                    usageStore.refreshLocalProxyQuotas(profileIDs: [id])
                    completeLegacyCooldownRecoveryPreparation()
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.legacyRecoveryPreparation?.ticket.id == ticket.id else { return }
                    self?.cancelLegacyCooldownRecoveryPreparation()
                }
            }
        } catch {
            legacyCooldownRecoveryIssue(error)
            return nil
        }
    }

    func cancelLegacyCooldownRecoveryPreparation() {
        guard let pending = legacyRecoveryPreparation else { return }
        legacyRecoveryPreparation = nil
        isPreparingLegacyCooldownRecovery = false
        pending.continuation.resume(returning: nil)
    }

    private func completeLegacyCooldownRecoveryPreparation() {
        guard let pending = legacyRecoveryPreparation else { return }
        do {
            let (profile, _) = try legacyRecoveryProfiles(for: pending.ticket.target.id, matching: pending.ticket)
            if let failed = profile.lastQuotaReadFailureAt, failed >= pending.ticket.refreshStartedAt { throw LocalProxyFailure.quotaUnknown }
            guard let observed = profile.lastSnapshot?.fetchedAt, observed > pending.ticket.refreshStartedAt else { return }
            try validateLegacyCooldownRecoveryEvidence(pending.ticket, after: pending.prepared.candidate.latestRecordAt)
            let confirmation = try LocalProxyLegacyCooldownRecovery.confirm(pending.prepared)
            legacyRecoveryTicket = LegacyRecoveryTicket(
                id: confirmation.id, target: pending.ticket.target,
                system: pending.ticket.system, refreshStartedAt: pending.ticket.refreshStartedAt)
            legacyRecoveryPreparation = nil
            isPreparingLegacyCooldownRecovery = false
            pending.continuation.resume(returning: confirmation)
        } catch {
            legacyCooldownRecoveryIssue(error)
            cancelLegacyCooldownRecoveryPreparation()
        }
    }

    /// The UI calls this only after confirming the exact prepared account.
    @discardableResult
    func commitLegacyCooldownRecovery(_ confirmation: LocalProxyLegacyCooldownRecovery.Confirmation) -> Bool {
        guard let ticket = legacyRecoveryTicket, ticket.id == confirmation.id, ticket.target.id == confirmation.profileID else {
            legacyCooldownRecoveryIssue(LocalProxyLegacyCooldownRecovery.Failure.changed)
            return false
        }
        legacyRecoveryTicket = nil
        do {
            _ = try LocalProxyLegacyCooldownRecovery.commit(confirmation) {
                try self.validateLegacyCooldownRecoveryEvidence(ticket, after: confirmation.preparedLatestRecordAt)
            }
            accountStates[confirmation.profileID] = nil
            cooldowns[confirmation.profileID] = nil
            rebuildRows()
            flushDisplayRows()
            issue = WidgetLanguage.storedOrAutomatic().text(
                "该账号旧冷却已备份并恢复；启动后仍按身份、额度与参与条件校验。",
                "This account's legacy cooldown was backed up and recovered. Starting the proxy still checks identity, quota and participation.")
            return true
        } catch {
            legacyCooldownRecoveryIssue(error)
            rebuildRows()
            flushDisplayRows()
            return false
        }
    }

    private func legacyRecoveryProfiles(for id: String, matching ticket: LegacyRecoveryTicket? = nil) throws -> (CodexProfile, CodexProfile) {
        guard canEdit, !usageStore.isPreview, !preferencesBlocked, !finishing, preferences.enabledIDs.contains(id) else { throw LocalProxyFailure.notParticipating }
        let targets = usageStore.profiles.filter { $0.id == id }
        let systems = usageStore.profiles.filter(\.isSystemProfile)
        guard targets.count == 1, let profile = targets.first, !profile.isSystemProfile,
            systems.count == 1, let system = systems.first,
            let target = LegacyRecoveryIdentity(profile), let central = LegacyRecoveryIdentity(system),
            target.home != central.home, (target.account == central.account) == (target.accountID == central.accountID),
            ticket == nil || (ticket?.target == target && ticket?.system == central)
        else { throw LocalProxyFailure.identity }
        let registry = try DispatchActivityStore.live.read()
        let accountKey = DispatchActivityStore.hash(profile.recordedAccountKey)
        let aliasKey = alias(for: profile).map(DispatchActivityStore.hash)
        guard !registry.leases.contains(where: { $0.occupied && ($0.accountKey == accountKey || $0.aliasKey == aliasKey || $0.proxyProfileKey == DispatchActivityStore.hash(id)) })
        else { throw LocalProxyFailure.busy }
        return (profile, system)
    }

    private func validateLegacyCooldownRecoveryEvidence(_ ticket: LegacyRecoveryTicket, after cutoff: Date) throws {
        let (profile, system) = try legacyRecoveryProfiles(for: ticket.target.id, matching: ticket)
        guard let observed = profile.lastSnapshot?.fetchedAt, observed > ticket.refreshStartedAt, observed > cutoff else { throw LocalProxyFailure.quotaUnknown }
        if let failure = LocalProxyAdmission.quota(profile, policy: preferences.resolvedPolicy(for: profile.id)) { throw failure }
        // The reader double-checks both auth files and identities. Discard its token.
        _ = try LocalProxyCredentialReader.read(
            profile: profile, system: system,
            allowDesktopAccount: profile.recordedAccountKey == system.recordedAccountKey,
            policy: preferences.resolvedPolicy(for: profile.id))
    }

    private func legacyCooldownRecoveryIssue(_ error: Error) {
        let language = WidgetLanguage.storedOrAutomatic()
        if let failure = error as? LocalProxyFailure {
            issue = message(failure)
        } else if error as? LocalProxyLegacyCooldownRecovery.Failure == .backup {
            issue = language.text("旧冷却备份失败，原记录未清除。", "Legacy cooldown backup failed; the original records were retained.")
        } else {
            issue = language.text("旧冷却恢复未确认；记录或身份可能已变化，请重新准备。", "Legacy cooldown recovery was not confirmed. Records or identity may have changed; prepare again.")
        }
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
        cancelAutomaticRecovery()
        await startRun()
    }

    private func makeRegisteredPool() throws -> [String: PoolBinding] {
        var pool: [String: PoolBinding] = [:]
        for row in rows {
            guard let profile = usageStore.profiles.first(where: { $0.id == row.id }),
                !profile.isSystemProfile, pool[row.id] == nil
            else { throw LocalProxyFailure.identity }
            guard let accountID = profile.lastSnapshot?.accountID, !accountID.isEmpty else { continue }
            pool[row.id] = PoolBinding(home: profile.codexHomeURL, account: profile.recordedAccountKey, accountID: accountID)
        }
        guard !pool.isEmpty, pool.count <= 100 else { throw LocalProxyFailure.unavailable }
        return pool
    }

    private func startRun() async {
        guard canStartRun, isEnabled else { return }
        let attempt = UUID()
        startAttemptID = attempt
        exitCleanupTask?.cancel()
        exitCleanupTask = nil
        phase = .starting
        issue = nil
        refreshStatus()
        var startupStep = "network"
        do {
            let networkProxy = try LocalProxyNetworkSettings.load()
            startupStep = "helper"
            let helper = try verifiedHelper()
            startupStep = "activity"
            // The registry can be stalled behind a reservation or a disk sync.
            // Keep startup cancellable and keep Stop/Quit gated until the
            // same worker has really released its ownership.
            let preflightID = UUID()
            exitCleanupID = preflightID
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while true {
                guard startAttemptID == attempt, exitCleanupID == preflightID, phase == .starting else { return }
                let preflight = await Self.boundedExitCleanup(
                    nil, leases: [], gate: exitCleanupWorker, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                guard startAttemptID == attempt, exitCleanupID == preflightID, phase == .starting else { return }
                guard let preflight else { throw LocalProxyFailure.unavailable }
                if !preflight.registryFailed {
                    exitCleanupID = nil
                    break
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard preflight.busy, !preflight.nonRetryable, remaining > 0 else {
                    exitCleanupID = nil
                    throw LocalProxyFailure.unavailable
                }
                try await Task.sleep(nanoseconds: UInt64(min(0.1, remaining) * 1_000_000_000))
            }
            startupStep = "state"
            let run = UUID().uuidString.lowercased()
            let control = try randomKey()
            let client: String
            if preferences.effectiveClientKeyMode == .persistent {
                if let saved = preferences.persistentClientKey {
                    client = saved
                } else {
                    client = try randomKey()
                    preferences.persistentClientKey = client
                    guard savePreferences() else { throw LocalProxyFailure.unavailable }
                }
            } else {
                client = try randomKey()
            }
            let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("aigoodbro-next-proxy-" + run, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            runDirectory = folder
            let stateDirectory = directory.appendingPathComponent("LocalProxy", isDirectory: true)
            try Self.prepareStateDirectory(stateDirectory)
            runID = run
            if automaticRecoveryPlan != nil { automaticRecoveryStartingRun = run }
            controlKey = control
            clientKey = client
            runDirectory = folder
            // Register the initial verified pool. Later additions require an explicit
            // identity-bound helper acknowledgment before they enter new orders.
            let pool = try makeRegisteredPool()
            if let plan = automaticRecoveryPlan, pool != plan.bindings { throw LocalProxyFailure.identity }
            registeredPool = pool
            membershipSnapshots = [:]
            memberRevocations = [:]
            activeIDs = Set(rows.filter(\.isEnabled).map(\.id)).intersection(Set(pool.keys))
            accountStates = [:]
            cooldowns = [:]
            startupStep = "bridge"
            let permittedProfiles = LocalProxyRunProfiles(Set(pool.keys))
            runProfiles = permittedProfiles
            bridge = try LocalProxyBridge(
                path: folder.appendingPathComponent("control.sock").path,
                resolve: { [weak self] request in
                    guard request.schemaVersion == 1, request.command == "acquire_resolve",
                        request.runID == run, request.key == control, request.leaseID == nil,
                        UUID(uuidString: request.requestID) != nil, permittedProfiles.snapshot().contains(request.profileID)
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
                        request, run: run, key: control, permittedProfiles: permittedProfiles.snapshot())
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
                            Self.recordIssue(
                                id: "proxy-control-\(run)", phase: "control_failure",
                                summary: "Local proxy acquire reply rollback remained unknown after reconciliation.")
                            self.failAutomaticRecovery("rollback_unconfirmed")
                            Task { await self.stop(reason: .controlFailure, expectedRun: run) }
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
            input = stdin.fileHandleForWriting
            startupStep = "launch"
            try child.run()
            // A Process that failed to launch has no terminationStatus; never
            // pass it to the exited-child path. Its callback runs on MainActor
            // after this synchronous launch and assignment complete.
            process = child
            var configuration: [String: Any] = [
                "schemaVersion": 1, "runID": run, "controlSocket": folder.appendingPathComponent("control.sock").path,
                "controlKey": control, "clientKey": client, "port": preferences.effectiveListenPort, "stateDirectory": stateDirectory.resolvingSymlinksInPath().path,
                "accounts": rows.filter { pool[$0.id] != nil }.map { ["id": $0.id] },
                "models": CodexExecutionPreference.Model.allCases.map(\.rawValue),
                "desktopFallback": true,
            ]
            configuration["accountIdentityHashes"] = pool.mapValues { DispatchActivityStore.hash($0.accountID) }
            configuration["egress"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(egressSettings))
            if let networkProxy { configuration["networkProxy"] = networkProxy }
            var bytes = try JSONSerialization.data(withJSONObject: configuration)
            bytes.append(10)
            try input?.write(contentsOf: bytes)
            let output = stdout.fileHandleForReading
            outputTask = Task.detached { [weak self] in
                var pending = Data()
                while !Task.isCancelled {
                    guard let bytes = await Self.readHelperOutput(output) else { break }
                    pending.append(bytes)
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
                if startAttemptID != attempt || runID != run || phase != .starting { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if startAttemptID == attempt, runID == run, phase == .starting {
                issue = message(.unavailable)
                failAutomaticRecovery("ready_timeout")
                await stop(reason: .startupFailure, expectedRun: run)
                if startAttemptID == attempt { phase = .failed }
            }
        } catch {
            guard startAttemptID == attempt else { return }
            failAutomaticRecovery("startup_failed")
            let nsError = error as NSError
            let detail = " [\(startupStep):\(nsError.code)]"
            issue = (error as? LocalProxyNetworkSettings.Failure).map { LocalProxyNetworkSettings.message($0, language: .storedOrAutomatic()) } ?? (message(.unavailable) + detail)
            if let child = process {
                if child.isRunning { await stop(reason: .startupFailure, expectedRun: runID) } else { childExited(child) }
            } else {
                cleanupConfirmedExit(preserveFailure: true)
            }
            if startAttemptID == attempt, exitCleanupID == nil { phase = .failed }
        }
    }

    nonisolated private static func readHelperOutput(_ output: FileHandle) async -> Data? {
        await withCheckedContinuation { continuation in
            // An idle helper pipe can wait indefinitely. Suspend the Task and
            // keep that blocking read outside the cooperative control executor.
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: 4096)
                var count: Int
                repeat { count = Darwin.read(output.fileDescriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
                continuation.resume(returning: count > 0 ? Data(buffer.prefix(count)) : nil)
            }
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

    func stop(reason: ExitReason = .requestedStop, expectedRun: String? = nil) async {
        guard !forceTerminationRequested else { return }
        if let expectedRun, runID != expectedRun { return }
        if reason == .requestedStop {
            startAttemptID = nil
            cancelAutomaticRecovery()
        } else if reason == .startupFailure {
            failAutomaticRecovery("startup_failed")
        }
        if phase == .stopping {
            for _ in 0..<90 {
                guard !forceTerminationRequested else { return }
                if phase != .stopping {
                    await exitCleanupTask?.value
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }
        requestedExitReason = reason
        phase = .stopping
        // The helper treats EOF like its stop command. Closing cannot wait for
        // space in a full input pipe; the child is still confirmed gone before
        // any lease is retired.
        try? input?.close()
        input = nil
        guard let child = process else {
            cleanupConfirmedExit()
            await exitCleanupTask?.value
            return
        }
        for _ in 0..<40 {
            guard !forceTerminationRequested else { return }
            if !child.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !forceTerminationRequested else { return }
        if child.isRunning { child.terminate() }
        for _ in 0..<20 {
            guard !forceTerminationRequested else { return }
            if !child.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !forceTerminationRequested else { return }
        if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        for _ in 0..<20 {
            guard !forceTerminationRequested else { return }
            if !child.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !forceTerminationRequested else { return }
        if !child.isRunning {
            childExited(child)
            await exitCleanupTask?.value
        } else {
            failAutomaticRecovery("child_exit_unconfirmed")
            phase = .failed
            issue = message(.stopping)
            let unresolved = Array(leases.values)
            DispatchQueue.global(qos: .utility).async {
                for lease in unresolved {
                    try? DispatchActivityStore.live.updateProxy(
                        lease.id, runID: lease.runID, requestID: lease.requestID, profileID: lease.profileID, state: "uncertain")
                }
            }
        }
    }
    func shutdown() async { await finishForTermination() }
    /// Called only after the user confirms interruption and forced exit. Do not
    /// await a registry, treat any lease as retired, or look up other processes.
    func forceStopForConfirmedTermination() {
        forceTerminationRequested = true
        finishing = true
        startAttemptID = nil
        automaticRecoveryTask?.cancel()
        cancelAutomaticRecovery()
        exitCleanupTask?.cancel()
        outputTask?.cancel()
        quotaTask?.cancel()
        selfCheckTask?.cancel()
        phase = .stopping
        try? input?.close()
        input = nil
        if let child = process, child.isRunning, child.processIdentifier > 1 {
            _ = kill(child.processIdentifier, SIGKILL)
        }
    }

    func finishForTermination() async {
        finishing = true
        await stop()
    }
    func resumeAfterCancelledTermination() {
        // AppKit has explicitly rejected quitting; keep recovery revoked while
        // allowing the user to finish cleanup and start manually again.
        cancelAutomaticRecovery()
        finishing = false
    }

    private func childExited(_ child: Process) {
        guard !forceTerminationRequested, process === child, !child.isRunning else { return }
        let unexpected = phase == .running || phase == .starting
        let reason = unexpected ? ExitReason.unexpectedExit : (requestedExitReason ?? .requestedStop)
        if let runID {
            let summary = "Local proxy helper exited with status \(child.terminationStatus) (\(reason.rawValue))."
            Self.recordIssue(id: "proxy-\(runID)", phase: reason.rawValue, summary: summary)
        }
        cleanupConfirmedExit(preserveFailure: unexpected && automaticRecoveryPlan == nil)
        requestedExitReason = nil
        if unexpected && automaticRecoveryPlan == nil {
            automaticRecoveryMessage = nil
            issue = message(.unavailable)
        }
    }
    private struct ExitCleanupResult: Sendable {
        let retired: [Lease]
        let registryFailed: Bool
        let busy: Bool
        let nonRetryable: Bool
    }

    /// Exact durable successes remain usable if the registry later prunes its
    /// bounded terminal history. This is scoped to one confirmed-exit owner;
    /// absent records without this evidence never count as retired.
    private final class ExitCleanupEvidence: @unchecked Sendable {
        private let lock = NSLock()
        private var retired: [String: Lease] = [:]

        func remember(_ lease: Lease) {
            lock.lock()
            retired[lease.id] = lease
            lock.unlock()
        }

        func take() -> [Lease] {
            lock.lock()
            let result = Array(retired.values)
            retired.removeAll()
            lock.unlock()
            return result
        }
    }

    nonisolated private static func retireExitedRun(_ run: String?, leases: [Lease], gate: DispatchSemaphore, evidence: ExitCleanupEvidence?) -> ExitCleanupResult {
        guard gate.wait(timeout: .now()) == .success else {
            return ExitCleanupResult(retired: [], registryFailed: true, busy: true, nonRetryable: false)
        }
        defer { gate.signal() }
        if let run { DispatchActivityStore.closeProxyRun(run) }
        var remaining = leases
        var retired: [Lease] = []
        var busy = false
        var nonRetryable = false
        func retireRemaining() {
            var failed: [Lease] = []
            for lease in remaining {
                do {
                    try DispatchActivityStore.live.updateProxy(
                        lease.id, runID: lease.runID, requestID: lease.requestID, profileID: lease.profileID,
                        state: "cancelled", allowTerminalCleanup: true)
                    retired.append(lease)
                    evidence?.remember(lease)
                } catch {
                    failed.append(lease)
                    if let failure = error as? DispatchActivityStore.Failure, case .busy = failure {
                        busy = true
                    } else {
                        nonRetryable = true
                    }
                }
            }
            remaining = failed
        }
        retireRemaining()
        var registryFailed = false
        do { try DispatchActivityStore.live.finishStoppedProxyRuns(retiringCurrentRun: true) } catch {
            registryFailed = true
            if let failure = error as? DispatchActivityStore.Failure, case .busy = failure {
                busy = true
            } else {
                nonRetryable = true
            }
        }
        if !registryFailed {
            // Batch retirement can resolve an earlier failed individual write.
            nonRetryable = false
            retireRemaining()
        }
        return ExitCleanupResult(retired: retired, registryFailed: registryFailed, busy: busy, nonRetryable: nonRetryable)
    }

    nonisolated private static func boundedExitCleanup(_ run: String?, leases: [Lease], gate: DispatchSemaphore, evidence: ExitCleanupEvidence? = nil, timeout: TimeInterval = 3)
        async -> ExitCleanupResult?
    {
        await withCheckedContinuation { continuation in
            let completion = LocalProxyIOCompletion(continuation)
            DispatchQueue.global(qos: .utility).async {
                completion.complete(retireExitedRun(run, leases: leases, gate: gate, evidence: evidence))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                completion.complete(nil)
            }
        }
    }

    private func cleanupConfirmedExit(retryID: UUID? = nil, remainingRetries: Int = 3, preserveFailure: Bool = false) {
        guard !forceTerminationRequested, process?.isRunning != true else { return }
        // A delayed cleanup must never act on a subsequently started run, or
        // replace the task owned by a newer manual cleanup attempt.
        if let retryID {
            guard exitCleanupID == retryID, process == nil, runID == nil, phase == .failed else { return }
        } else {
            exitCleanupTask?.cancel()
            if runID != nil {
                exitCleanupEvidenceID = nil
                exitCleanupEvidence = nil
            }
            // An instance that never owned a run has no local retirement to
            // await; unrelated registry contention must not prevent quitting.
            let ownsCleanup = process != nil || runID != nil || !leases.isEmpty || exitCleanupID != nil
            exitCleanupID = ownsCleanup ? UUID() : nil
        }
        exitCleanupTask = nil
        let cleanupID = exitCleanupID
        if cleanupID != nil, exitCleanupEvidenceID == nil {
            exitCleanupEvidenceID = UUID()
            exitCleanupEvidence = ExitCleanupEvidence()
        }
        let evidenceID = exitCleanupEvidenceID
        let evidence = exitCleanupEvidence
        for lease in evidence?.take() ?? [] {
            guard let current = leases[lease.id], current.runID == lease.runID,
                current.requestID == lease.requestID, current.profileID == lease.profileID
            else { continue }
            leases.removeValue(forKey: lease.id)
            if balanceRefreshLeases.remove(lease.id) != nil {
                creditRefreshAfter[lease.profileID] = Date()
            }
        }
        if let runID { exitCleanupRunID = runID }
        let cleanupRun = exitCleanupRunID
        if let cleanupRun { localProxyReleaseFence.clear(runID: cleanupRun) }
        let cleanupLeases = Array(leases.values)
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
        cancelledAutomaticRecoveryRun = nil
        controlKey = nil
        clientKey = nil
        selfCheckTask?.cancel()
        selfCheckTask = nil
        selfCheckRequestID = nil
        selfCheck.isRunning = false
        cooldownKinds = [:]
        probeStates = [:]
        egressState = "unconfigured"
        desktopConnection = nil
        desktopAvailable = false
        endpoint = nil
        activeIDs = []
        registeredPool = [:]
        runProfiles = nil
        hotRegistrations = [:]
        attemptedHotBindings = [:]
        hotActivationIDs = []
        hotActivationErrors = [:]
        membershipSnapshots = [:]
        memberRevocations = [:]
        refreshMembershipWaitState()
        accountStates = [:]
        cooldowns = [:]
        guard let cleanupID else {
            phase = .stopped
            rebuildRows()
            return
        }
        phase = .stopping
        let gate = exitCleanupWorker
        exitCleanupTask = Task { [weak self] in
            let result = await Self.boundedExitCleanup(cleanupRun, leases: cleanupLeases, gate: gate, evidence: evidence)
            guard let self, !Task.isCancelled, self.exitCleanupID == cleanupID,
                self.exitCleanupEvidenceID == evidenceID, self.process == nil, self.runID == nil
            else { return }
            self.exitCleanupTask = nil
            for lease in evidence?.take() ?? [] {
                guard let current = self.leases[lease.id], current.runID == lease.runID,
                    current.requestID == lease.requestID, current.profileID == lease.profileID
                else { continue }
                self.leases.removeValue(forKey: lease.id)
                if self.balanceRefreshLeases.remove(lease.id) != nil {
                    self.creditRefreshAfter[lease.profileID] = Date()
                }
            }
            self.refreshMembershipWaitState()
            guard let result else {
                // The worker may still finish later. Keep the run identity and
                // every lease without exact durable evidence; never permit
                // start or quit until the full cleanup has been confirmed.
                self.phase = .failed
                self.issue = self.message(.unavailable)
                self.failAutomaticRecovery("lease_cleanup_unconfirmed")
                return
            }
            let complete = self.leases.isEmpty && !result.registryFailed
            if complete {
                self.exitCleanupID = nil
                self.exitCleanupRunID = nil
                self.exitCleanupEvidenceID = nil
                self.exitCleanupEvidence = nil
            }
            self.phase = complete && !preserveFailure ? .stopped : .failed
            self.rebuildRows()
            if complete {
                self.scheduleAutomaticRecoveryAfterCleanup()
                return
            }
            self.issue = self.message(.unavailable)
            guard result.busy, !result.nonRetryable, remainingRetries > 0 else {
                self.failAutomaticRecovery("lease_cleanup_unconfirmed")
                return
            }
            // Retry only exact retirement after the child is confirmed gone.
            self.exitCleanupTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let self, !Task.isCancelled, self.exitCleanupID == cleanupID,
                    self.process == nil, self.runID == nil, self.phase == .failed
                else { return }
                self.cleanupConfirmedExit(retryID: cleanupID, remainingRetries: remainingRetries - 1, preserveFailure: preserveFailure)
                await self.exitCleanupTask?.value
            }
            await self.exitCleanupTask?.value
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
            current.creditFallback == snapshot.creditFallback, current.revocations == snapshot.revocations
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
        if request.command == "egress_probe" {
            guard request.leaseID == nil else { return .failure(.identity) }
            return await probeOfficialBackend(profileID: request.profileID, expectedRun: request.runID)
        }
        if request.command == "quota_recovery" {
            guard request.leaseID == nil else { return .failure(.identity) }
            guard !preferencesBlocked, !finishing, phase == .running, process?.isRunning == true
            else { return .failure(.stopping) }
            guard activeIDs.contains(request.profileID), preferences.enabledIDs.contains(request.profileID)
            else { return .failure(.notParticipating) }
            guard let profile = usageStore.profiles.first(where: { $0.id == request.profileID }),
                let system = usageStore.profiles.first(where: \.isSystemProfile),
                let current = currentBinding(profile, system: system)
            else { return .failure(.identity) }
            // Read-only evidence for a recovered subscription, before the helper
            // filters persisted cooldowns. This neither admits a request nor
            // returns credentials, creates order state or starts a quota refresh.
            if let failure = LocalProxyAdmission.quota(current, policy: preferences.resolvedPolicy(for: current.id)) {
                return .failure(failure)
            }
            return LocalProxyReply(ok: true, quotaObservedAt: current.lastSnapshot!.fetchedAt.timeIntervalSince1970)
        }
        if request.command == "order" {
            guard request.leaseID == nil, !preferencesBlocked, !finishing,
                phase == .running, process?.isRunning == true
            else { return .failure(.stopping) }
            let now = ProcessInfo.processInfo.systemUptime
            pruneMembershipSnapshots(at: now)
            if let existing = membershipSnapshots[request.requestID] {
                return LocalProxyReply(
                    ok: true, order: existing.order, lastResortIDs: existing.lastResortIDs, deferredIDs: existing.deferredIDs, creditFallback: existing.creditFallback)
            }
            guard membershipSnapshots.count < maximumMembershipSnapshots else { return .failure(.controlBusy) }
            let order = rows.map(\.id).filter { activeIDs.contains($0) && isRegisteredBindingCurrent($0) }
            guard Set(order).count == order.count else { return .failure(.identity) }
            // New requests use effective choices, including an explicit Pro
            // opt-out. Existing snapshots retain their original metadata.
            let lastResortIDs: [String] = []
            let deferredIDs = order.filter { orderingGroup(for: $0) == 1 }
            membershipSnapshots[request.requestID] = MembershipSnapshot(
                order: order, lastResortIDs: lastResortIDs, deferredIDs: deferredIDs, creditFallback: creditFallbackEnabled,
                revocations: memberRevocations.filter { order.contains($0.key) }, capturedAt: now)
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
        guard membership.revocations[request.profileID] == memberRevocations[request.profileID]
        else { return .failure(.notParticipating) }
        func requestMembers() -> Set<String> {
            Set(
                membership.order.filter {
                    activeIDs.contains($0) && preferences.enabledIDs.contains($0) && membership.revocations[$0] == memberRevocations[$0]
                })
        }
        guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return .failure(.admissionDeadline) }
        let desktopPass = request.command.contains("desktop")
        let policy = preferences.resolvedPolicy(for: request.profileID)
        let revision = policyRevision
        let floor: Int? = request.command.hasSuffix("primary") ? policy.creditPrimaryFloor : request.command.hasSuffix("secondary") ? policy.creditSecondaryFloor : nil
        guard floor == nil || (creditFallbackEnabled && policy.allowsCredits) else { return .failure(.quota) }
        if floor != nil
            && requestMembers().contains(where: { localProxyReleaseFence.contains(runID: request.runID, profileID: $0) })
        {
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
            guard membership.revocations[request.profileID] == memberRevocations[request.profileID]
            else { return .notParticipating }
            // A policy edit may occur across any await below. Releasing a token
            // under superseded spending limits is never allowed. A rolled-back
            // tuple stays denied; a fresh request can use the current policy.
            guard revision == policyRevision else { return .policyChanged }
            if floor != nil
                && requestMembers().contains(where: {
                    localProxyReleaseFence.contains(runID: request.runID, profileID: $0)
                })
            {
                return .quotaUnknown
            }
            if floor != nil,
                let failure = LocalProxyAdmission.creditPool(
                    usageStore.profiles, activeIDs: requestMembers(), refreshAfter: creditRefreshAfter,
                    policies: preferences.accountPolicies ?? [:])
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
            // A bad account must not consume the whole selector opportunity.
            // Keep time for final admission and let later healthy accounts run.
            let refreshDeadline = min(admissionDeadline - 1, ProcessInfo.processInfo.systemUptime + LocalProxyAdmission.quotaRefreshWait)
            let failuresBefore = Dictionary(
                usageStore.profiles
                    .filter { (floor == nil ? Set([profile.id]) : requestMembers()).contains($0.id) }
                    .map { ($0.id, $0.lastQuotaReadFailureAt ?? .distantPast) }, uniquingKeysWith: { max($0, $1) })
            usageStore.refreshLocalProxyQuotas(profileIDs: floor == nil ? [profile.id] : requestMembers())
            while true {
                guard !Task.isCancelled, !finishing, phase == .running, process === child,
                    child.isRunning, request.runID == runID,
                    isMembershipSnapshotCurrent(membership, requestID: request.requestID)
                else { return .failure(.stopping) }
                guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return .failure(.admissionDeadline) }
                guard let updated = currentBinding(profile, system: system) else { return .failure(.identity) }
                if admission(updated) != .quotaUnknown { break }
                if usageStore.profiles.contains(where: { candidate in
                    guard let before = failuresBefore[candidate.id], let failedAt = candidate.lastQuotaReadFailureAt else { return false }
                    return failedAt > before && failedAt >= (candidate.lastSnapshot?.fetchedAt ?? .distantPast)
                }) {
                    return .failure(.quotaUnknown)
                }
                guard ProcessInfo.processInfo.systemUptime < refreshDeadline else { return .failure(.quotaUnknown) }
                let left = refreshDeadline - ProcessInfo.processInfo.systemUptime
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
        } catch DispatchActivityStore.Failure.accountBusy { return .failure(.busy) } catch DispatchActivityStore.Failure.busy {
            // The registry lock refused the write before a reservation existed.
            // Keep this distinct from an occupied account or duplicate tuple;
            // only this confirmed no-mutation refusal is safe for bridge retry.
            return .failure(.controlBusy)
        } catch DispatchActivityStore.Failure.deadline { return .failure(.admissionDeadline) } catch {
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
        let availability = await HubConsoleModel.warmUpAvailability(
            for: alias, excludingLocalLease: lease.id, deadline: admissionDeadline, maxConcurrent: DispatchActivityStore.proxyMaxConcurrentPerAccount)
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
            do {
                try await updateAfterContention(lease, state: "running", deadline: admissionDeadline)
            } catch DispatchActivityStore.Failure.busy {
                return await reject(.busy)
            }
            guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return await reject(.admissionDeadline) }
            guard !finishing, phase == .running, process === child, child.isRunning, request.runID == runID,
                leases[lease.id] != nil, isMembershipSnapshotCurrent(membership, requestID: request.requestID),
                let final = currentBinding(latest, system: system)
            else { return await reject(.stopping) }
            if let failure = admission(final) { return await reject(failure) }
            func verifyFinalAdmission() throws {
                guard !Task.isCancelled, !finishing, phase == .running, process === child,
                    child.isRunning, request.runID == runID, leases[lease.id] != nil,
                    isMembershipSnapshotCurrent(membership, requestID: request.requestID),
                    let checked = currentBinding(final, system: system)
                else { throw LocalProxyFailure.stopping }
                if let failure = admission(checked) { throw failure }
            }
            let persistedActive: Bool
            do {
                persistedActive = try await isProxyLeaseActiveAfterContention(
                    lease, childPID: child.processIdentifier, deadline: admissionDeadline, verifyAdmission: verifyFinalAdmission)
                try verifyFinalAdmission()
            } catch DispatchActivityStore.Failure.busy {
                return await reject(.busy)
            } catch let failure as LocalProxyFailure {
                return await reject(failure)
            } catch { return await reject(.admissionUnknown) }
            guard ProcessInfo.processInfo.systemUptime < admissionDeadline else { return await reject(.admissionDeadline) }
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
                onCommit: request.command == "release"
                    ? {
                        localProxyReleaseFence.mark(
                            runID: request.runID, requestID: request.requestID,
                            profileID: request.profileID, leaseID: id)
                    } : nil)
            return LocalProxyReply(ok: true)
        } catch DispatchActivityStore.Failure.busy {
            return .failure(.controlBusy)
        } catch DispatchActivityStore.Failure.invalidState {
            return .failure(.registryStateInvalid)
        } catch {
            return .failure(.registryUnavailable)
        }
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
        localProxyReleaseFence.clear(
            runID: request.runID, requestID: request.requestID,
            profileID: request.profileID, leaseID: id)
        rebuildRows()
    }

    private func updateAfterContention(_ lease: Lease, state: String, deadline: TimeInterval) async throws {
        while true {
            do {
                try await Task.detached {
                    try DispatchActivityStore.live.updateProxy(
                        lease.id, runID: lease.runID, requestID: lease.requestID,
                        profileID: lease.profileID, state: state)
                }.value
                return
            } catch DispatchActivityStore.Failure.busy {
                let left = deadline - ProcessInfo.processInfo.systemUptime
                guard left > 0 else { throw DispatchActivityStore.Failure.busy }
                // Only a lock refusal before mutation can retry within this budget.
                try await Task.sleep(nanoseconds: UInt64(min(0.05, left) * 1_000_000_000))
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw DispatchActivityStore.Failure.busy }
            }
        }
    }

    private func isProxyLeaseActiveAfterContention(
        _ lease: Lease, childPID: pid_t, deadline: TimeInterval, verifyAdmission: @escaping () throws -> Void
    ) async throws -> Bool {
        while true {
            // Retry may resume after policy, binding, membership or lifecycle changed.
            try verifyAdmission()
            do {
                return try DispatchActivityStore.live.isProxyLeaseActive(
                    lease.id, runID: lease.runID, requestID: lease.requestID,
                    profileID: lease.profileID, childPID: childPID, verifyAdmission: verifyAdmission)
            } catch DispatchActivityStore.Failure.busy {
                let left = deadline - ProcessInfo.processInfo.systemUptime
                guard left > 0 else { throw DispatchActivityStore.Failure.busy }
                try await Task.sleep(nanoseconds: UInt64(min(0.05, left) * 1_000_000_000))
                try verifyAdmission()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw DispatchActivityStore.Failure.busy }
            }
        }
    }

    private func consume(_ data: Data, run: String) {
        guard !forceTerminationRequested, runID == run, data.count <= 8192,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = (object["event"] ?? object["type"]) as? String
        else { return }
        switch type {
        case "ready":
            guard phase == .starting, let port = object["port"] as? Int, (1024...65535).contains(port) else { return }
            guard cancelledAutomaticRecoveryRun != run else { return }
            if let plan = automaticRecoveryPlan, automaticRecoveryStartingRun == run,
                process?.isRunning != true || startAttemptID == nil || !automaticRecoveryInputsMatch(plan)
            {
                failAutomaticRecovery("ready_identity_or_process_unconfirmed")
                Task { [weak self] in await self?.stop(reason: .startupFailure, expectedRun: run) }
                return
            }
            guard preferences.effectiveListenPort == 0 || preferences.effectiveListenPort == port else {
                issue = message(.unavailable)
                Task { [weak self] in await self?.stop(reason: .startupFailure, expectedRun: run) }
                return
            }
            endpoint = "http://127.0.0.1:\(port)/v1"
            do { try prepareDesktopConnection() } catch {
                issue = message(.unavailable)
                Task { [weak self] in await self?.stop(reason: .startupFailure, expectedRun: run) }
                return
            }
            phase = .running
            if let plan = automaticRecoveryPlan, automaticRecoveryStartingRun == run {
                Self.recordIssue(
                    id: "proxy-recovery-\(plan.failedRun)", phase: "recovery_ready",
                    summary: "Local proxy restarted on its original endpoint. In-flight requests were not replayed.")
                cancelAutomaticRecovery(
                    message: WidgetLanguage.storedOrAutomatic().text(
                        "反代已自动重新开启；中断的请求请重试。",
                        "The proxy restarted automatically. Retry any interrupted request."))
            }
            quotaTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    guard let self, self.phase == .running else { return }
                    self.pruneMembershipSnapshots(at: ProcessInfo.processInfo.systemUptime)
                    self.refreshStatus()
                }
            }
        case "account_registered":
            guard let id = object["profileID"] as? String, var pending = hotRegistrations[id],
                pending.runID == run, object["runID"] as? String == run,
                object["requestID"] as? String == pending.requestID,
                object["identityHash"] as? String == DispatchActivityStore.hash(pending.binding.accountID),
                phase == .running, !finishing
            else { return }
            if object["state"] as? String == "registered", object["errorCode"] == nil {
                pending.acknowledged = true
                hotRegistrations[id] = pending
            } else {
                let reason = object["errorCode"] as? String ?? "unavailable"
                failHotActivation(id: id, code: reason, requestID: pending.requestID)
                cancelHotActivation(id: id)
            }
        case "account":
            guard let id = object["profileID"] as? String, activeIDs.contains(id),
                let state = object["state"] as? String,
                ["current", "ready", "quota", "usage_limit", "login_expired", "temporary_error", "busy", "credentials_busy", "quota_unknown", "subscription_pending"].contains(
                    state)
            else { return }
            let cooldown: Date?
            if let until = object["cooldownUntil"] as? Double, until.isFinite, until > Date().timeIntervalSince1970, until < Date().timeIntervalSince1970 + 8 * 86400 {
                cooldown = Date(timeIntervalSince1970: until)
            } else {
                cooldown = nil
            }
            // Busy waiters report the same account every polling cycle. Only
            // changed control state needs projection; duplicate events must not
            // flood MainActor with rebuilds and delay admission replies.
            let kind = object["cooldownKind"] as? String == "egress" ? "egress" : nil
            let probe = (object["probeState"] as? String).flatMap { ["probing", "waiting", "failed"].contains($0) ? $0 : nil }
            guard accountStates[id] != state || cooldowns[id] != cooldown || cooldownKinds[id] != kind || probeStates[id] != probe else { return }
            cooldownKinds[id] = kind
            probeStates[id] = probe
            accountStates[id] = state
            cooldowns[id] = cooldown
            rebuildRows()
        case "egress":
            consumeEgress(object)
        case "error":
            let code = object["errorCode"] as? String ?? ""
            let details: Set<String> = [
                "timeout", "eof", "decode", "unavailable", "transport_unavailable", "registry_state_invalid", "registry_unavailable",
                "admission_unknown", "missing_lease", "control_busy", "identity", "rejected",
            ]
            let detail = (object["errorDetail"] as? String).flatMap { details.contains($0) ? $0 : nil }
            let resolutionDetail = (object["resolutionDetail"] as? String).flatMap { details.contains($0) ? $0 : nil }
            if code == "lease_acquire_reconciled" {
                if let runID, phase == .running || phase == .starting {
                    Self.recordIssue(
                        id: "proxy-control-\(runID)", phase: "reconciled",
                        summary: "Local proxy acquire reconciled\(detail.map { ": \($0)" } ?? "").")
                }
                return
            }
            if code == "listen_port_occupied" {
                issue = WidgetLanguage.storedOrAutomatic().text(
                    "端口 \(listenPort) 已被占用。请停止占用服务或修改监听端口；不会自动更换端口。", "Port \(listenPort) is occupied. Stop the listener or change the port; no fallback port is used.")
            } else {
                issue = message(.unavailable)
            }
            if ["lease_acquire_unknown", "lease_release_unknown", "lease_heartbeat_failed"].contains(code) {
                // A present but unrecognized detail is not an absent field.
                let recoveryResolution = object["resolutionDetail"] == nil ? nil : (resolutionDetail ?? "rejected")
                prepareAutomaticRecovery(run: run, code: code, detail: detail, resolution: recoveryResolution)
                if let runID, phase == .running || phase == .starting {
                    Self.recordIssue(
                        id: "proxy-control-\(runID)", phase: "control_failure",
                        summary: "Local proxy control failure: \(code)\(detail.map { ": \($0)" } ?? "")\(resolutionDetail.map { "; resolution: \($0)" } ?? "").")
                }
                Task { [weak self] in await self?.stop(reason: .controlFailure, expectedRun: run) }
            }
        case "stopped": break  // A message is not proof that the process has exited.
        default: break
        }
    }
    private func rebuildRows() {
        let recoveryIDs = LocalProxyLegacyCooldownRecovery.candidates(
            at: directory.appendingPathComponent("LocalProxy", isDirectory: true),
            profileIDs: Set(usageStore.profiles.filter { !$0.isSystemProfile }.map(\.id)))
        // @Published emits even for equal sets. Preserve the display throttle
        // when quota, leases or other real control state changes rebuild rows.
        if legacyCooldownRecoveryIDs != recoveryIDs { legacyCooldownRecoveryIDs = recoveryIDs }
        completeLegacyCooldownRecoveryPreparation()
        let central = usageStore.profiles.first(where: \.isSystemProfile)
        var representatives = preferences.accountRepresentatives ?? [:]
        let rememberedIDs = Set(representatives.values)
        let candidates = usageStore.profiles.filter {
            !$0.isSystemProfile
                && ($0.lastSnapshot?.accountID?.isEmpty == false || preferences.knownIDs.contains($0.id)
                    || rememberedIDs.contains($0.id) || registeredPool[$0.id] != nil)
        }
        let groups = Dictionary(grouping: candidates, by: representativeIdentityKey)
        var selected: [String: String] = [:]
        for (key, group) in groups {
            let oldRepresentative = representatives[key]
            let registered = group.first { profile in registeredPool[profile.id].map { DispatchActivityStore.hash($0.account) == key } == true }
            let persisted = group.first { $0.id == representatives[key] }
            let known = group.filter { preferences.knownIDs.contains($0.id) }
            let configured = known.first {
                preferences.lastOverrides?[$0.id] != nil || preferences.priorityIDs.contains($0.id)
                    || preferences.lastIDs?.contains($0.id) == true || preferences.accountPolicies?[$0.id] != nil
            }
            let ordered = preferences.order.compactMap { id in known.first { $0.id == id } }.first
            guard let representative = registered ?? persisted ?? configured ?? ordered ?? known.first ?? group.first else { continue }
            selected[key] = representative.id
            if persisted == nil, let oldRepresentative, oldRepresentative != representative.id {
                inheritRepresentativeChoices(from: oldRepresentative, to: representative.id, identityKey: key, mirrorIDs: Set(group.map(\.id)))
            }
            // A disappeared run member cannot be replaced with a new home.
            // Keep its durable representative until this run has retired.
            if oldRepresentative.flatMap({ registeredPool[$0] }) == nil || persisted != nil || registered != nil {
                representatives[key] = representative.id
            }
        }
        preferences.accountRepresentatives = representatives.isEmpty ? nil : representatives
        var seen = Set<String>()
        let profiles = candidates.filter {
            let key = representativeIdentityKey(for: $0)
            return selected[key] == $0.id && seen.insert(key).inserted
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
            // Project the latest persisted failure without changing admission or
            // helper state. A newer successful observation supersedes it.
            let hasCurrentOAuthInvalidation =
                profile.lastQuotaReadFailureReason == "oauth-invalidated"
                && profile.lastQuotaReadFailureAt.map { failedAt in
                    guard let snapshot = profile.lastSnapshot, snapshot.quotaReadSucceeded == true else { return true }
                    return failedAt >= snapshot.fetchedAt
                } == true
            let reportedState = accountStates[id].flatMap { $0 == "current" ? nil : $0 }
            let state =
                isCurrent ? "current" : hasCurrentOAuthInvalidation ? "login_expired" : failure == .usageLimit ? "usage_limit" : reportedState ?? (failure?.rawValue ?? "ready")
            func officialRemaining(_ window: CodexQuotaWindowSnapshot?) -> Double? {
                window.flatMap { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) ? 100 - $0.usedPercent : nil }
            }
            let isProPlan = profile.isProPlan
            let weeklyRemaining = officialRemaining(profile.lastSnapshot?.sevenDay)
            let sourceWindows: [(String, CodexQuotaWindowSnapshot?)] =
                isProPlan
                ? [("7d", profile.lastSnapshot?.sevenDay)]
                : [("5h", profile.lastSnapshot?.fiveHour), ("7d", profile.lastSnapshot?.sevenDay), ("30d", profile.lastSnapshot?.monthly)]
            let displayWindows =
                sourceWindows
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
            if hasCurrentOAuthInvalidation {
                quota = message(.loginExpired)
            } else if failure == nil || failure == .quota, profile.lastSnapshot != nil {
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
                isDesktopAccount: isDesktop(id), isProPlan: isProPlan,
                requiresRunRegistration: previewPendingRegistrationIDs.contains(id)
                    || (phase == .running && process?.isRunning == true && registeredPool[id] == nil),
                isEnabled: preferences.enabledIDs.contains(id),
                isPriority: preferences.priorityIDs.contains(id) && orderingGroup(for: id) != 1, isCurrent: state == "current", quotaText: quota, state: state,
                cooldownUntil: cooldowns[id], cooldownKind: cooldownKinds[id], probeState: probeStates[id],
                activeRequestCount: activeRequestCount, policy: policy,
                usesDefaultCreditFloors: preferences.policy(for: id).creditPrimaryFloor == nil,
                isLast: orderingGroup(for: id) == 1,
                pausesAfterReset: preferences.resetStopRules?[id].map { rule in
                    profile.lastSnapshot?.accountID.map { rule.accountHash == DispatchActivityStore.hash($0) } == true
                } == true,
                resetPausedAt: preferences.resetStopRules?[id].flatMap { rule in
                    profile.lastSnapshot?.accountID.map { rule.accountHash == DispatchActivityStore.hash($0) } == true ? rule.pausedAt : nil
                })
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

    private func representativeIdentityKey(for profile: CodexProfile) -> String {
        if profile.lastSnapshot?.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            if let bound = registeredPool[profile.id] { return DispatchActivityStore.hash(bound.account) }
            let saved = preferences.accountRepresentatives?.filter { $0.value == profile.id }.map(\.key) ?? []
            if saved.count == 1, let key = saved.first { return key }
        }
        return DispatchActivityStore.hash(profile.recordedAccountKey)
    }

    private func inheritRepresentativeChoices(from oldID: String, to newID: String, identityKey: String, mirrorIDs: Set<String>) {
        guard preferences.knownIDs.contains(oldID) else { return }
        preferences.knownIDs.formUnion(mirrorIDs)
        if let current = usageStore.profiles.first(where: { $0.id == oldID }), representativeIdentityKey(for: current) != identityKey {
            // A historical pointer cannot transfer another identity's current
            // spending and routing rules. Require a deliberate new choice.
            preferences.enabledIDs.subtract(mirrorIDs)
            return
        }
        if !preferences.enabledIDs.contains(oldID) {
            preferences.enabledIDs.subtract(mirrorIDs)
        } else if process == nil {
            preferences.enabledIDs.formUnion(mirrorIDs)
        }
        if preferences.order.contains(oldID) {
            preferences.order = preferences.order.filter { $0 != newID }.map { $0 == oldID ? newID : $0 }
        }
        if let override = preferences.lastOverrides?[oldID] { preferences.lastOverrides?[newID] = override } else { preferences.lastOverrides?.removeValue(forKey: newID) }
        if preferences.lastIDs?.contains(oldID) == true { preferences.lastIDs?.insert(newID) } else { preferences.lastIDs?.remove(newID) }
        if preferences.priorityIDs.contains(oldID) { preferences.priorityIDs.insert(newID) } else { preferences.priorityIDs.remove(newID) }
        if let policy = preferences.accountPolicies?[oldID] { preferences.accountPolicies?[newID] = policy } else { preferences.accountPolicies?.removeValue(forKey: newID) }
        if let rule = preferences.resetStopRules?[oldID] { preferences.resetStopRules?[newID] = rule } else { preferences.resetStopRules?.removeValue(forKey: newID) }
        preferences.resetStopRules?.removeValue(forKey: oldID)
    }

    /// Explicit arrow moves persist the manual display order. Otherwise seed
    /// from the account panel, so participation and routing choices never
    /// reshuffle the list. Routing groups still apply to new admissions.
    private var panelOrderedDisplayRows: [LocalProxyQueueRow] {
        let ids = preferences.order + usageStore.profiles.map(\.id).filter { !preferences.order.contains($0) }
        let panelIndex = Dictionary(
            ids.enumerated().map { ($1, $0) },
            uniquingKeysWith: { min($0, $1) })
        return rows.sorted { (panelIndex[$0.id] ?? .max) < (panelIndex[$1.id] ?? .max) }
    }

    private func publishDisplayRows(immediately: Bool = false) {
        let uptime = ProcessInfo.processInfo.systemUptime
        switch displayGate.offer(panelOrderedDisplayRows, at: uptime, immediate: immediately) {
        case .unchanged:
            displayPublishTask?.cancel()
            displayPublishTask = nil
        case .publish:
            displayPublishTask?.cancel()
            displayPublishTask = nil
            displayRows = panelOrderedDisplayRows
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
            guard preferences.validLastIDs, preferences.validLastOverrides, preferences.validAccountRepresentatives, preferences.validResetStopRules,
                preferences.validNetworkSettings
            else {
                throw LocalProxyFailure.unavailable
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                throw LocalProxyFailure.unavailable
            }
            let url = directory.appendingPathComponent("local-proxy-queue-v1.json")
            let previousReference = preferences.secretsReference
            let reference = UUID().uuidString
            try LocalProxyPreferenceSecrets(clientKey: preferences.persistentClientKey, mihomoSecret: preferences.egress?.mihomoSecret ?? "").save(reference)
            do {
                var redacted = preferences
                redacted.secretsReference = reference
                redacted.persistentClientKey = nil
                redacted.egress?.mihomoSecret = ""
                let data = try JSONEncoder().encode(redacted)
                guard data.count <= 65536 else { throw LocalProxyFailure.unavailable }
                try DispatchParticipationSync.writePrivateProxyPreferences(data, at: url)
                preferences.secretsReference = reference
            } catch {
                LocalProxyPreferenceSecrets.remove(reference)
                throw error
            }
            if let previousReference { LocalProxyPreferenceSecrets.remove(previousReference) }
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
        case .usageLimit: return language.text("已达剩余额度底线", "Remaining-quota reserve reached")
        case .quotaUnknown: return language.text("额度未知或已过期，请刷新", "Quota missing or stale; refresh limits")
        case .loginExpired: return language.text("登录已过期，请手动重新登录", "Login expired; sign in manually")
        case .stageNotApplicable: return message(.unavailable)
        case .notParticipating: return language.text("已取消参与，跳过此账号", "Participation disabled; skipping this account")
        case .admissionUnknown, .registryStateInvalid, .registryUnavailable: return message(.unavailable)
        case .stopping: return language.text("尚未确认代理完全停止，账号占用已保留", "Proxy stop is unconfirmed; reservations retained")
        case .unavailable: return language.text("代理暂不可用，请检查额度与本地运行状态", "Proxy unavailable; check limits and local runtime")
        }
    }
}

/// Immutable Keychain revisions keep the old settings and credentials consistent
/// if a settings write fails. Missing/locked credentials never rotate silently.
private struct LocalProxyPreferenceSecrets: Codable {
    var clientKey: String?
    var mihomoSecret: String
    private static func query(_ reference: String) throws -> [String: Any] {
        guard UUID(uuidString: reference) != nil else { throw LocalProxyFailure.unavailable }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.aigoodbro.Next.LocalProxyPreferences.v1",
            kSecAttrAccount as String: reference,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }
    static func read(_ reference: String) throws -> Self {
        var query = try query(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, data.count <= 65536
        else { throw LocalProxyFailure.unavailable }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func save(_ reference: String) throws {
        var query = try Self.query(reference)
        query[kSecValueData as String] = try JSONEncoder().encode(self)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw LocalProxyFailure.unavailable }
    }
    static func remove(_ reference: String) {
        guard let query = try? query(reference) else { return }
        SecItemDelete(query as CFDictionary)
    }
}
