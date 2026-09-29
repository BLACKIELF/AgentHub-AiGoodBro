import AppKit
import Combine
import Darwin
import Foundation
import Security

/// Independent opt-in queue. Construction never starts a helper or opens auth files.
@MainActor final class LocalProxyQueueStore: ObservableObject {
    @Published private(set) var rows: [LocalProxyQueueRow] = []
    @Published private(set) var phase: LocalProxyPhase = .stopped
    @Published private(set) var endpoint: String?
    @Published private(set) var issue: String?
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
    var canStart: Bool { canEdit && rows.contains(where: \.isEnabled) && !usageStore.isPreview && !preferencesBlocked }
    var canStop: Bool { process != nil && phase != .stopping }
    var canFinishTermination: Bool { process == nil && leases.isEmpty }
    var requiresStopConfirmation: Bool {
        process != nil || !leases.isEmpty || phase == .starting || phase == .stopping
    }

    private let usageStore: UsageStore
    private let directory: URL
    private var preferences = LocalProxyPreferences()
    private var preferencesBlocked = false
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
    private struct Lease {
        let id: String
        let profileID: String
        let requestID: String
        let runID: String
    }
    private var leases: [String: Lease] = [:]
    private var accountStates: [String: String] = [:]
    private var cooldowns: [String: Date] = [:]
    private var balanceRefreshLeases = Set<String>()
    private var creditRefreshAfter: [String: Date] = [:]
    private var outputTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var finishing = false

    init(usageStore: UsageStore) {
        self.usageStore = usageStore
        directory = DispatchParticipationPaths.supportDirectory()
        if !usageStore.isPreview {
            do {
                if let data = try DispatchParticipationSync.readBoundedRegularFile(
                    directory.appendingPathComponent("local-proxy-queue-v1.json"), maximumBytes: 65536, allowMissing: true)
                {
                    let saved = try JSONDecoder().decode(LocalProxyPreferences.self, from: data)
                    guard saved.schemaVersion == 1, saved.order.count <= 1000, Set(saved.order).count == saved.order.count,
                        saved.enabledIDs.count <= 1000,
                        LocalProxyPreferences.validCreditFloors(primary: saved.creditFloors.primary, secondary: saved.creditFloors.secondary)
                    else { throw LocalProxyFailure.unavailable }
                    preferences = saved
                }
            } catch {
                preferencesBlocked = true
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
        preferences.isEnabled = value
        isEnabled = value
        savePreferences()
    }
    func setCreditFallback(_ enabled: Bool) {
        guard canEdit, !usageStore.isPreview, !preferencesBlocked else { return }
        preferences.creditFallback = enabled
        creditFallbackEnabled = enabled
        savePreferences()
        rebuildRows()
    }
    @discardableResult
    func setCreditFloors(primary: Int, secondary: Int) -> Bool {
        guard canEdit, !usageStore.isPreview, !preferencesBlocked,
            LocalProxyPreferences.validCreditFloors(primary: primary, secondary: secondary)
        else { return false }
        preferences.creditPrimaryFloor = primary
        preferences.creditSecondaryFloor = secondary
        creditPrimaryFloor = primary
        creditSecondaryFloor = secondary
        savePreferences()
        rebuildRows()
        return !preferencesBlocked
    }
    func setAccountEnabled(id: String, enabled: Bool) {
        guard canEdit, !usageStore.isPreview, !preferencesBlocked, rows.contains(where: { $0.id == id }) else { return }
        if enabled { preferences.enabledIDs.insert(id) } else { preferences.enabledIDs.remove(id) }
        savePreferences()
        rebuildRows()
    }
    func setAccountPriority(id: String, priority: Bool) {
        guard canReorder, !usageStore.isPreview, !preferencesBlocked, rows.contains(where: { $0.id == id }) else { return }
        if priority { preferences.priorityIDs.insert(id) } else { preferences.priorityIDs.remove(id) }
        savePreferences()
        rebuildRows()
    }
    func moveAccount(id: String, by offset: Int) {
        guard canMoveAccount(id: id, by: offset),
            let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset)
        else { return }
        var ids = rows.map(\.id)
        ids.swapAt(index, index + offset)
        preferences.order = ids
        savePreferences()
        rebuildRows()
    }
    func canMoveAccount(id: String, by offset: Int) -> Bool {
        guard canReorder, !usageStore.isPreview, !preferencesBlocked, offset == -1 || offset == 1,
            let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset)
        else { return false }
        let source = rows[index]
        let target = rows[index + offset]
        return source.isDesktopAccount == target.isDesktopAccount && source.isPriority == target.isPriority
    }
    /// The existing explicit quota-only operation; does not request a warm-up.
    func refreshStatus() {
        guard !usageStore.isPreview else {
            rebuildRows()
            return
        }
        usageStore.refreshLocalProxyQuotas(profileIDs: Set(rows.filter(\.isEnabled).map(\.id)))
        rebuildRows()
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
        let bundled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?
            .appendingPathComponent("Contents/Resources/codex").path
        guard
            let selected = [bundled, CodexExecutable.path()].compactMap({ $0 })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }
        let executable = URL(fileURLWithPath: selected).resolvingSymlinksInPath().path
        let connection: [String: Any] = [
            "schemaVersion": 1, "runID": runID, "endpoint": endpoint,
            "clientKey": clientKey, "codexExecutable": executable,
        ]
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
            try DispatchActivityStore.live.finishStoppedProxyRuns()
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
            activeIDs = Set(rows.filter(\.isEnabled).map(\.id))
            accountStates = [:]
            cooldowns = [:]
            startupStep = "bridge"
            bridge = try LocalProxyBridge(path: folder.appendingPathComponent("control.sock").path) { [weak self] request in
                guard let self else { return .failure(.stopping) }
                return await self.handle(request)
            }
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
                "accounts": rows.filter(\.isEnabled).map { ["id": $0.id] },
                "models": CodexExecutionPreference.Model.allCases.map(\.rawValue),
                "creditFallback": creditFallbackEnabled,
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
                await stop()
                phase = .failed
            }
        } catch {
            let nsError = error as NSError
            let detail = " [\(startupStep):\(nsError.code)]"
            issue = (error as? LocalProxyNetworkSettings.Failure).map { LocalProxyNetworkSettings.message($0, language: .storedOrAutomatic()) } ?? (message(.unavailable) + detail)
            if process?.isRunning == true { await stop() } else { cleanupConfirmedExit() }
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

    func stop() async {
        if phase == .stopping {
            for _ in 0..<90 {
                if phase != .stopping { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }
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
        cleanupConfirmedExit()
        if unexpected {
            phase = .failed
            issue = message(.unavailable)
        }
    }
    private func cleanupConfirmedExit() {
        guard process?.isRunning != true else { return }
        for lease in Array(leases.values) {
            do {
                try update(lease, state: "cancelled")
                leases.removeValue(forKey: lease.id)
                if balanceRefreshLeases.remove(lease.id) != nil {
                    creditRefreshAfter[lease.profileID] = Date()
                }
            } catch { issue = message(.unavailable) }
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
        phase = leases.isEmpty ? .stopped : .failed
        accountStates = [:]
        cooldowns = [:]
        rebuildRows()
    }

    private func handle(_ request: LocalProxyRequest) async -> LocalProxyReply {
        guard request.schemaVersion == 1, request.runID == runID, request.key == controlKey,
            UUID(uuidString: request.requestID) != nil, activeIDs.contains(request.profileID)
        else { return .failure(.identity) }
        if request.command == "order" {
            guard request.leaseID == nil, !preferencesBlocked, !finishing,
                phase == .running, process?.isRunning == true
            else { return .failure(.stopping) }
            let order = rows.map(\.id).filter { activeIDs.contains($0) }
            guard order.count == activeIDs.count, Set(order) == activeIDs else { return .failure(.identity) }
            return LocalProxyReply(ok: true, order: order)
        }
        if request.command == "release" || request.command == "heartbeat" {
            guard let id = request.leaseID, let lease = leases[id], lease.runID == request.runID,
                lease.requestID == request.requestID, lease.profileID == request.profileID
            else { return .failure(.identity) }
            do {
                try update(lease, state: request.command == "release" ? "accepted" : "running")
                if request.command == "release" {
                    leases.removeValue(forKey: id)
                    if balanceRefreshLeases.remove(id) != nil {
                        creditRefreshAfter[lease.profileID] = Date()
                        usageStore.refreshLocalProxyQuotas(profileIDs: [lease.profileID])
                    }
                }
                return LocalProxyReply(ok: true)
            } catch { return .failure(.unavailable) }
        }
        let commands = ["acquire", "acquire_credit_primary", "acquire_credit_secondary", "acquire_desktop", "acquire_desktop_credit_primary", "acquire_desktop_credit_secondary"]
        guard commands.contains(request.command), request.leaseID == nil else { return .failure(.identity) }
        let desktopPass = request.command.contains("desktop")
        let floor: Int? = request.command.hasSuffix("primary") ? creditPrimaryFloor : request.command.hasSuffix("secondary") ? creditSecondaryFloor : nil
        guard floor == nil || creditFallbackEnabled else { return .failure(.quota) }
        guard !finishing, phase == .running, let child = process, child.isRunning else { return .failure(.stopping) }
        guard let profile = usageStore.profiles.first(where: { $0.id == request.profileID }), !profile.isSystemProfile,
            let system = usageStore.profiles.first(where: \.isSystemProfile),
            let alias = alias(for: profile)
        else { return .failure(.identity) }
        let isDesktop = profile.recordedAccountKey == system.recordedAccountKey || profile.lastSnapshot?.accountID == system.lastSnapshot?.accountID
        guard desktopPass == isDesktop else { return .failure(.identity) }
        // Paid admission needs an observation after the previous request ended,
        // including a subscription request that may have crossed its limit.
        if floor != nil, let after = creditRefreshAfter[profile.id] {
            usageStore.refreshLocalProxyQuotas(profileIDs: [profile.id])
            for _ in 0..<30 {
                if (usageStore.profiles.first { $0.id == profile.id }?.lastSnapshot?.fetchedAt ?? .distantPast) > after { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard !Task.isCancelled, !finishing, phase == .running, process === child,
            child.isRunning, request.runID == runID
        else { return .failure(.stopping) }
        func admission(_ candidate: CodexProfile) -> LocalProxyFailure? {
            if floor != nil,
                let failure = LocalProxyAdmission.creditPool(usageStore.profiles, activeIDs: activeIDs, refreshAfter: creditRefreshAfter)
            {
                if failure == .quotaUnknown { usageStore.refreshLocalProxyQuotas(profileIDs: activeIDs) }
                return failure
            }
            return LocalProxyAdmission.quota(candidate, creditFloor: floor, allowPaidCredits: creditFallbackEnabled)
        }
        guard let fresh = currentBinding(profile, system: system) else { return .failure(.identity) }
        if let failure = admission(fresh) { return .failure(failure) }
        let lease: Lease
        do {
            let id = try DispatchActivityStore.live.reserveProxy(
                account: profile.recordedAccountKey, alias: alias, runID: request.runID, requestID: request.requestID, profileID: profile.id, childPID: child.processIdentifier)
            lease = Lease(id: id, profileID: profile.id, requestID: request.requestID, runID: request.runID)
            leases[id] = lease
        } catch DispatchActivityStore.Failure.busy { return .failure(.busy) } catch { return .failure(.unavailable) }
        func reject(_ reason: LocalProxyFailure) -> LocalProxyReply {
            if leases[lease.id] != nil {
                do {
                    try update(lease, state: "cancelled")
                    leases.removeValue(forKey: lease.id)
                    balanceRefreshLeases.remove(lease.id)
                } catch {}
            }
            return .failure(reason)
        }
        let availability = await HubConsoleModel.warmUpAvailability(for: alias, excludingLocalLease: lease.id)
        guard availability == .idle else { return reject(availability == .busy ? .busy : .unavailable) }
        guard phase == .running, process === child, child.isRunning, request.runID == runID, leases[lease.id] != nil,
            let latest = currentBinding(profile, system: system)
        else { return reject(.stopping) }
        if let failure = admission(latest) { return reject(failure) }
        do {
            let paid = creditFallbackEnabled
            let credential = try await Task.detached {
                try LocalProxyCredentialReader.read(profile: latest, system: system, allowDesktopAccount: desktopPass, creditFloor: floor, allowPaidCredits: paid)
            }.value
            guard phase == .running, process === child, child.isRunning, request.runID == runID, leases[lease.id] != nil,
                let current = currentBinding(latest, system: system)
            else { return reject(.stopping) }
            if let failure = admission(current) { return reject(failure) }
            try update(lease, state: "running")
            if creditFallbackEnabled { balanceRefreshLeases.insert(lease.id) }
            return LocalProxyReply(ok: true, leaseID: lease.id, accessToken: credential.token, accountID: credential.accountID, expiresAt: Int64(credential.expiresAt))
        } catch let failure as LocalProxyFailure { return reject(failure) } catch { return reject(.unavailable) }
    }
    private func currentBinding(_ profile: CodexProfile, system: CodexProfile) -> CodexProfile? {
        guard let latest = usageStore.profiles.first(where: { $0.id == profile.id }), !latest.isSystemProfile,
            latest.codexHomeURL == profile.codexHomeURL, latest.recordedAccountKey == profile.recordedAccountKey,
            latest.lastSnapshot?.accountID == profile.lastSnapshot?.accountID,
            let central = usageStore.profiles.first(where: \.isSystemProfile), central.id == system.id,
            central.codexHomeURL == system.codexHomeURL, central.recordedAccountKey == system.recordedAccountKey,
            central.lastSnapshot?.accountID == system.lastSnapshot?.accountID
        else { return nil }
        return latest
    }
    private func update(_ lease: Lease, state: String) throws {
        try DispatchActivityStore.live.updateProxy(lease.id, runID: lease.runID, requestID: lease.requestID, profileID: lease.profileID, state: state)
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
                Task { [weak self] in await self?.stop() }
                return
            }
            phase = .running
            quotaTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    guard let self, self.phase == .running else { return }
                    self.refreshStatus()
                }
            }
        case "account":
            guard let id = object["profileID"] as? String, activeIDs.contains(id),
                let state = object["state"] as? String,
                ["current", "ready", "quota", "login_expired", "temporary_error", "busy", "credentials_busy", "quota_unknown", "subscription_pending"].contains(state)
            else { return }
            if state == "current" { for key in accountStates.keys where accountStates[key] == "current" { accountStates[key] = "ready" } }
            accountStates[id] = state
            if let until = object["cooldownUntil"] as? Double, until.isFinite, until > Date().timeIntervalSince1970, until < Date().timeIntervalSince1970 + 8 * 86400 {
                cooldowns[id] = Date(timeIntervalSince1970: until)
            } else {
                cooldowns[id] = nil
            }
            rebuildRows()
        case "error":
            issue = message(.unavailable)
            if let code = object["errorCode"] as? String, ["lease_acquire_unknown", "lease_release_unknown", "lease_heartbeat_failed"].contains(code) {
                Task { [weak self] in await self?.stop() }
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
            if profile.recordedAccountKey != central?.recordedAccountKey { preferences.enabledIDs.insert(profile.id) }
            if profile.isDispatchPriorityEnabled { preferences.priorityIDs.insert(profile.id) }
        }
        let ids = preferences.order.filter { id in profiles.contains { $0.id == id } } + profiles.map(\.id).filter { !preferences.order.contains($0) }
        func isDesktop(_ id: String) -> Bool { profiles.first { $0.id == id }?.recordedAccountKey == central?.recordedAccountKey }
        rows = ids.sorted {
            if isDesktop($0) != isDesktop($1) { return !isDesktop($0) }
            return preferences.priorityIDs.contains($0) && !preferences.priorityIDs.contains($1)
        }.compactMap { id in
            guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
            let failure = LocalProxyAdmission.quota(profile, allowPaidCredits: creditFallbackEnabled)
            let state = accountStates[id] ?? (failure?.rawValue ?? "ready")
            let quota: String
            if failure == nil || failure == .quota, let snapshot = profile.lastSnapshot {
                let language = WidgetLanguage.storedOrAutomatic()
                let windows: [(String, CodexQuotaWindowSnapshot?)] = [
                    (language.text("5 小时", "5h"), snapshot.fiveHour),
                    (language.text("每周", "Weekly"), snapshot.sevenDay),
                    (language.text("每月", "Monthly"), snapshot.monthly),
                ]
                let remaining = windows.compactMap { label, window -> String? in
                    guard let window else { return nil }
                    return label + " " + String(format: "%.1f%%", max(0, 100 - window.usedPercent))
                }.joined(separator: " · ")
                quota = language.text("剩余：", "Remaining: ") + remaining
            } else {
                quota = message(failure ?? .quotaUnknown)
            }
            return LocalProxyQueueRow(
                id: id, label: AccountDisplay.profileName(profile, allProfiles: usageStore.profiles),
                accountNumber: AccountDisplay.number(for: profile, in: usageStore.profiles),
                windows: [("5h", profile.lastSnapshot?.fiveHour), ("7d", profile.lastSnapshot?.sevenDay), ("30d", profile.lastSnapshot?.monthly)]
                    .filter { $0.0 != "30d" || $0.1 != nil }
                    .map {
                        LocalProxyQuotaWindow(
                            id: $0.0, remaining: $0.1.flatMap { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) ? 100 - $0.usedPercent : nil },
                            resetsAt: $0.1?.resetsAt)
                    },
                creditBalance: usageStore.creditBalancePresentation(for: profile),
                resetCardCount: usageStore.availableResetCredits(for: profile),
                snapshotStale: profile.lastQuotaReadFailureAt != nil || profile.lastSnapshot.map { Date().timeIntervalSince($0.fetchedAt) > 1_800 } != false,
                isDesktopAccount: isDesktop(id),
                isEnabled: preferences.enabledIDs.contains(id),
                isPriority: preferences.priorityIDs.contains(id), isCurrent: state == "current", quotaText: quota, state: state, cooldownUntil: cooldowns[id])
        }
    }
    private func savePreferences() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                throw LocalProxyFailure.unavailable
            }
            let url = directory.appendingPathComponent("local-proxy-queue-v1.json")
            let data = try JSONEncoder().encode(preferences)
            // Atomic replacement cannot follow a destination symlink; permissions stay private.
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            preferencesBlocked = true
            issue = message(.unavailable)
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
        case .identity: return language.text("账号身份未确认", "Account identity is unverified")
        case .quota: return language.text("订阅额度已用尽", "Subscription quota exhausted")
        case .quotaUnknown: return language.text("额度未知或已过期，请刷新", "Quota missing or stale; refresh limits")
        case .loginExpired: return language.text("登录已过期，请手动重新登录", "Login expired; sign in manually")
        case .stopping: return language.text("尚未确认代理完全停止，账号占用已保留", "Proxy stop is unconfirmed; reservations retained")
        case .unavailable: return language.text("代理暂不可用，请检查额度与本地运行状态", "Proxy unavailable; check limits and local runtime")
        }
    }
}
