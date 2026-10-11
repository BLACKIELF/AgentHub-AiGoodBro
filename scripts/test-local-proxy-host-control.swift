import Darwin
import Foundation

private enum LocalProxyControlFixtureFailure: Error { case check(String), socket }

private final class LocalProxyControlFixtureResult: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var bytes: Data?
    func complete(_ value: Data?) {
        lock.lock(); bytes = value; lock.unlock()
        done.signal()
    }
    func value() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
}

extension LocalProxyHostFixtures {
    private static func occupyControlFixtureWorker(_ release: DispatchSemaphore) {
        _ = release.wait(timeout: .now() + 10)
    }

    @MainActor static func controlRecoveryFixtures() async throws {
        try await controlProgressFixtures()
        try await quotaRecoveryFixtures()
    }

    private static func controlFixtureRequestID() -> String {
        let time = String(format: "%012llx", UInt64(Date().timeIntervalSince1970 * 1000))
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(time.prefix(8))-\(time.suffix(4))-7\(random.prefix(3))-a\(random.dropFirst(3).prefix(3))-\(random.dropFirst(6).prefix(12))"
    }

    /// Synchronous clients run on GCD so the test itself does not need the
    /// cooperative executor whose unavailable worker it is reproducing.
    private static func controlFixtureRPC(path: String, run: String, command: String, requestID: String, leaseID: String? = nil, abandonReply: Bool = false) -> Data? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var object: [String: Any] = ["schemaVersion": 1, "runID": run, "key": "control-fixture-key", "command": command,
            "requestID": requestID, "profileID": "control-fixture-profile"]
        if let leaseID { object["leaseID"] = leaseID }
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        line.append(10)
        let written = line.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        guard written == line.count else { return nil }
        if abandonReply { _ = Darwin.shutdown(fd, SHUT_RDWR); return nil }
        var received = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while received.count <= 65536 {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            received.append(contentsOf: buffer.prefix(count))
            if received.last == 10 { return received }
        }
        return nil
    }

    @MainActor static func controlProgressFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("CONTROL_PROGRESS_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sockets = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agb-control-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: sockets) }
        let path = sockets.appendingPathComponent("control.sock").path
        let activity = DispatchActivityStore.live, run = UUID().uuidString
        let profileID = "control-fixture-profile", key = "control-fixture-key"
        let maintenanceRequest = controlFixtureRequestID()
        let lease = try activity.reserveProxy(account: "control-fixture-account", alias: "control-fixture-alias", runID: run,
            requestID: maintenanceRequest, profileID: profileID, childPID: getpid(), enforceFreshness: true)
        let bridge = try LocalProxyBridge(path: path, resolve: { request in
            guard request.runID == run, request.key == key, request.command == "acquire_resolve", request.profileID == profileID,
                request.leaseID == nil else { return .failure(.identity) }
            do {
                let resolution = try activity.abandonProxy(runID: run, requestID: request.requestID, profileID: profileID, enforceFreshness: true)
                return LocalProxyReply(ok: true, resolution: resolution.rawValue)
            } catch DispatchActivityStore.Failure.busy { return .failure(.controlBusy) } catch { return .failure(.admissionUnknown) }
        }, maintenance: { request in
            LocalProxyQueueStore.maintainLease(request, run: run, key: key, permittedProfiles: [profileID], activity: activity)
        }, handler: { _ in .failure(.admissionDeadline) })
        defer { bridge.stop(); localProxyReleaseFence.clear(runID: run) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blockedWorker = Task.detached(priority: .userInitiated) {
            entered.signal()
            Self.occupyControlFixtureWorker(release)
        }
        defer { release.signal() }
        try expect(entered.wait(timeout: .now() + 2) == .success, "synthetic helper read occupies cooperative worker")
        func rpc(_ command: String, _ requestID: String, leaseID: String? = nil) throws -> [String: Any] {
            let result = LocalProxyControlFixtureResult()
            DispatchQueue.global(qos: .userInitiated).async {
                result.complete(Self.controlFixtureRPC(path: path, run: run, command: command, requestID: requestID, leaseID: leaseID))
            }
            // Deliberately occupy MainActor too. Resolver and maintenance ACKs
            // must need neither UI progress nor a cooperative worker.
            try expect(result.done.wait(timeout: .now() + 2) == .success, "\(command) returns while MainActor is occupied")
            if result.value() == nil, command == "acquire_resolve", checks == 2,
                ProcessInfo.processInfo.environment["PROXY_CONTROL_EXPECT_STALL"] == "1"
            {
                print("CONTROL_NEGATIVE_REPRODUCED: acquire_resolve stalled while cooperative worker was occupied")
                bridge.stop()
                try? FileManager.default.removeItem(at: sockets)
                exit(42)
            }
            guard let bytes = result.value(), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { throw LocalProxyControlFixtureFailure.check("\(command) timed out with cooperative worker occupied") }
            return object
        }
        let late = controlFixtureRequestID()
        let resolved = try rpc("acquire_resolve", late)
        try expect(resolved["ok"] as? Bool == true && resolved["resolution"] as? String == "not_reserved",
            "unstarted acquire resolves without cooperative or UI progress")
        do {
            _ = try activity.reserveProxy(account: "late-fixture", alias: "late-fixture", runID: run, requestID: late,
                profileID: profileID, childPID: getpid(), enforceFreshness: true)
            throw LocalProxyControlFixtureFailure.check("late acquire crossed durable deny marker")
        } catch DispatchActivityStore.Failure.acquireAbandoned {
            try expect(true, "not_reserved installs durable denial before a late acquire")
        }
        let lockFD = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR)
        guard lockFD >= 0 else { throw LocalProxyControlFixtureFailure.socket }
        defer { Darwin.close(lockFD) }
        try expect(flock(lockFD, LOCK_EX | LOCK_NB) == 0, "synthetic registry writer owns file lock")
        let contended = controlFixtureRequestID(), before = try Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))
        let busy = try rpc("acquire_resolve", contended)
        try expect(busy["error"] as? String == "control_busy" && busy["ok"] as? Bool == false,
            "registry contention replies explicitly instead of waiting behind the lock")
        try expect(try Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName)) == before,
            "refused resolver leaves registry bytes intact")
        _ = flock(lockFD, LOCK_UN)
        let retried = try rpc("acquire_resolve", contended)
        try expect(retried["resolution"] as? String == "not_reserved", "authoritatively refused resolver can retry after contention")
        let heartbeat = try rpc("heartbeat", maintenanceRequest, leaseID: lease)
        try expect(heartbeat["ok"] as? Bool == true, "heartbeat commits while cooperative worker is occupied")
        let released = try rpc("release", maintenanceRequest, leaseID: lease)
        try expect(released["ok"] as? Bool == true && localProxyReleaseFence.contains(runID: run, profileID: profileID),
            "release commits durable terminal row and fence before UI cleanup")
        let unsafe = try rpc("acquire_resolve", maintenanceRequest)
        try expect(unsafe["ok"] as? Bool == false && unsafe["error"] as? String == "admission_unknown",
            "terminal accepted lease stays unknown and cannot become a safe no-reservation result")
        release.signal()
        await blockedWorker.value
        let pipe = Pipe()
        let idleRead = Task.detached { await LocalProxyQueueStore.readHelperOutput(pipe.fileHandleForReading) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let executorProgress = DispatchSemaphore(value: 0)
        Task.detached { executorProgress.signal() }
        try expect(executorProgress.wait(timeout: .now() + 1) == .success,
            "idle helper output read suspends without consuming the cooperative worker")
        let line = Data("fixture-ready\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: line)
        let delivered = await idleRead.value
        try expect(delivered == line, "output reader delivers available bytes before EOF")
        try pipe.fileHandleForWriting.close(); try pipe.fileHandleForReading.close()
        for _ in 0..<10 {
            let bytes: Data? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.controlFixtureRPC(path: path, run: run, command: "order", requestID: UUID().uuidString))
                }
            }
            let object = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard object?["error"] as? String == "admission_deadline" else { throw LocalProxyControlFixtureFailure.check("asynchronous handler reply lost") }
        }
        try expect(true, "ordinary handler replies transfer descriptor ownership and release all eight slots")
        let rolledBack = DispatchSemaphore(value: 0)
        let rollbackPath = sockets.appendingPathComponent("rollback.sock").path
        let rollbackBridge = try LocalProxyBridge(path: rollbackPath, rollback: { _ in rolledBack.signal() }, handler: { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return LocalProxyReply(ok: true, leaseID: UUID().uuidString)
        })
        defer { rollbackBridge.stop() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Self.controlFixtureRPC(path: rollbackPath, run: run, command: "acquire", requestID: UUID().uuidString, abandonReply: true)
                continuation.resume()
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(rolledBack.wait(timeout: .now() + 1) == .success, "failed acquired-lease reply still runs rollback after descriptor transfer")
        print("PASS: \(checks) control progress checks; synthetic socket, registry and worker only")
    }

    @MainActor static func quotaRecoveryFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("QUOTA_RECOVERY_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date(), window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: Date().addingTimeInterval(3600))
        let profile = CodexProfile(id: "recovery-fixture", lastSnapshot: CodexAccountSnapshot(planType: "plus", creditBalance: "3000", creditBalanceUnlimited: false,
            accountID: "recovery-fixture-account", email: "recovery-fixture@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        var system = profile; system = CodexProfile(id: "recovery-system", isSystemProfile: true, lastSnapshot: system.lastSnapshot)
        let usage = UsageStore([profile, system]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let run = UUID().uuidString, key = "recovery-fixture-key"
        store.process = child; store.phase = .running; store.runID = run; store.controlKey = key
        store.registeredPool = [profile.id: LocalProxyQueueStore.PoolBinding(home: profile.codexHomeURL,
            account: profile.recordedAccountKey, accountID: profile.lastSnapshot!.accountID!)]
        store.activeIDs = [profile.id]; store.preferences.enabledIDs = [profile.id]
        let request = LocalProxyRequest(schemaVersion: 1, runID: run, key: key, command: "quota_recovery",
            requestID: UUID().uuidString, profileID: profile.id, leaseID: nil)
        func recovered() async -> LocalProxyReply { await store.handle(request) }
        func reject(_ expected: LocalProxyFailure, _ label: String) async throws {
            let reply = await recovered()
            try expect(!reply.ok && reply.error == expected.rawValue && reply.quotaObservedAt == nil
                && reply.accessToken == nil && reply.accountID == nil && reply.leaseID == nil, label)
        }
        let beforeRegistry = try? Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))
        let fresh = await recovered()
        try expect(fresh.ok && fresh.quotaObservedAt == now.timeIntervalSince1970, "fresh subscription evidence returns exact observation timestamp")
        try expect(fresh.accessToken == nil && fresh.accountID == nil && fresh.leaseID == nil && fresh.expiresAt == nil,
            "quota recovery never returns credentials or ownership")
        try expect(store.leases.isEmpty && store.membershipSnapshots.isEmpty && usage.refreshCount == 0
            && (try? Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))) == beforeRegistry,
            "read-only recovery creates no lease, order, registry write or quota refresh")
        store.activeIDs = []; try await reject(.notParticipating, "live membership removal denies recovery"); store.activeIDs = [profile.id]
        store.preferences.enabledIDs = []; try await reject(.notParticipating, "persisted opt-out denies recovery"); store.preferences.enabledIDs = [profile.id]
        usage.profiles[0].lastSnapshot?.fetchedAt = now.addingTimeInterval(-121)
        try await reject(.quotaUnknown, "stale quota cannot clear cooldown"); usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.fetchedAt = now.addingTimeInterval(30)
        try await reject(.quotaUnknown, "future-dated observation cannot clear cooldown"); usage.profiles[0] = profile
        usage.profiles[0].lastQuotaReadFailureAt = now
        try await reject(.quotaUnknown, "last failed refresh fences the previous observation"); usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.quotaReadSucceeded = false
        try await reject(.quotaUnknown, "failed quota evidence denies recovery"); usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.accountID = "changed-fixture-account"
        try await reject(.identity, "registered identity change denies recovery"); usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.email = "changed-fixture@example.invalid"
        try await reject(.identity, "registered account change denies recovery"); usage.profiles[0] = profile
        store.creditFallbackEnabled = true
        usage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 100
        try await reject(.quota, "available paid credits cannot masquerade as subscription recovery"); usage.profiles[0] = profile
        store.preferences.accountPolicies = [profile.id: LocalProxyAccountPolicy(fiveHourUsedLimit: 10)]
        try await reject(.usageLimit, "per-account subscription limit still gates recovery"); store.preferences.accountPolicies = nil
        store.finishing = true; try await reject(.stopping, "finishing run denies recovery"); store.finishing = false
        let invalid = await store.handle(LocalProxyRequest(schemaVersion: 1, runID: run, key: key, command: "quota_recovery",
            requestID: UUID().uuidString, profileID: profile.id, leaseID: UUID().uuidString))
        try expect(invalid.error == "identity" && invalid.quotaObservedAt == nil, "lease-bearing quota evidence command is invalid")
        print("PASS: \(checks) quota recovery host checks; synthetic Plus profile only")
        try await policySaveAdmissionFixtures()
    }

    /// Compose the production preference writer, reload and request handler.
    /// The UsageStore input and sleeping child are isolated fixture peripherals;
    /// no credential file, actual helper or provider is needed for a denied request.
    @MainActor static func policySaveAdmissionFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("POLICY_SAVE_ADMISSION_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let preferenceURL = root.appendingPathComponent("local-proxy-queue-v1.json")
        let previous = FileManager.default.fileExists(atPath: preferenceURL.path) ? try Data(contentsOf: preferenceURL) : nil
        defer {
            LocalProxyFixtureRuntime.failPreferenceRename = false
            if let previous { try? DispatchParticipationSync.writePrivateProxyPreferences(previous, at: preferenceURL) }
            else { try? FileManager.default.removeItem(at: preferenceURL) }
        }
        let now = Date(), window = CodexQuotaWindowSnapshot(usedPercent: 30, resetsAt: now.addingTimeInterval(3600))
        let profile = CodexProfile(id: "policy-save-fixture", lastSnapshot: CodexAccountSnapshot(planType: "plus",
            accountID: "policy-save-account", email: "policy-save@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        var centralSnapshot = profile.lastSnapshot!
        centralSnapshot.accountID = "policy-save-central-account"; centralSnapshot.email = "policy-save-central@example.invalid"
        let system = CodexProfile(id: "policy-save-central", isSystemProfile: true, lastSnapshot: centralSnapshot)
        let usage = UsageStore([profile, system]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        func activate(_ candidate: LocalProxyQueueStore) {
            candidate.process = child; candidate.phase = .running; candidate.runID = UUID().uuidString
            candidate.controlKey = "policy-save-fixture-key"
            candidate.registeredPool = [profile.id: LocalProxyQueueStore.PoolBinding(home: profile.codexHomeURL,
                account: profile.recordedAccountKey, accountID: profile.lastSnapshot!.accountID!)]
            candidate.activeIDs = candidate.preferences.enabledIDs.intersection([profile.id])
        }
        func request(_ candidate: LocalProxyQueueStore, _ command: String, id: String = UUID().uuidString) -> LocalProxyRequest {
            LocalProxyRequest(schemaVersion: 1, runID: candidate.runID!, key: candidate.controlKey!, command: command,
                requestID: id, profileID: command == "order_end" ? "" : profile.id, leaseID: nil)
        }
        activate(store)
        let defaultEvidence = await store.handle(request(store, "quota_recovery"))
        try expect(defaultEvidence.ok && store.rows.first?.policy.fiveHourUsedLimit == 100,
            "default 100 limit accepts the same fresh 30 percent quota evidence")
        let limit = LocalProxyAccountPolicy(fiveHourUsedLimit: 30)
        try expect(store.canEditPolicy(for: profile.id) && store.setAccountPolicy(id: profile.id, policy: limit),
            "running production Store saves the selected 30 percent limit")
        let savedBytes = try Data(contentsOf: preferenceURL)
        let saved = try JSONDecoder().decode(LocalProxyPreferences.self, from: savedBytes)
        try expect(saved.accountPolicies?[profile.id] == limit && saved.enabledIDs.contains(profile.id),
            "production atomic JSON commit contains 30 and retains participation")
        try expect(store.rows.first?.policy.fiveHourUsedLimit == 30 && store.rows.first?.state == "usage_limit"
            && store.displayRows.first?.policy.fiveHourUsedLimit == 30 && store.displayRows.first?.state == "usage_limit",
            "successful save immediately publishes 30 and the native usage limit state")
        let registryURL = root.appendingPathComponent(DispatchActivityStore.stateName)
        func denied(_ candidate: LocalProxyQueueStore, _ label: String) async throws {
            let beforeRegistry = try? Data(contentsOf: registryURL), id = UUID().uuidString
            let ordered = await candidate.handle(request(candidate, "order", id: id))
            try expect(ordered.ok && ordered.order == [profile.id], "\(label): production order creates a valid membership snapshot")
            let reply = await candidate.handle(request(candidate, "acquire", id: id))
            try expect(!reply.ok && reply.error == "usage_limit" && reply.accessToken == nil
                && reply.accountID == nil && reply.leaseID == nil && reply.expiresAt == nil,
                "\(label): production acquire denies with usage_limit before credentials")
            try expect(candidate.leases.isEmpty && (try? Data(contentsOf: registryURL)) == beforeRegistry,
                "\(label): denied admission leaves the isolated registry unchanged")
            let ended = await candidate.handle(request(candidate, "order_end", id: id))
            try expect(ended.ok && candidate.membershipSnapshots.isEmpty, "\(label): order cleanup retires only its fixture snapshot")
        }
        try await denied(store, "next request at exactly 30")
        let reloadedUsage = UsageStore([profile, system]); reloadedUsage.isPreview = false
        let reloaded = LocalProxyQueueStore(usageStore: reloadedUsage)
        try expect(reloaded.preferencesFailure == nil && reloaded.rows.first?.policy.fiveHourUsedLimit == 30
            && reloaded.displayRows.first?.policy.fiveHourUsedLimit == 30,
            "a new production Store reloads 30 from the committed JSON")
        activate(reloaded)
        try await denied(reloaded, "reloaded request at exactly 30")
        reloadedUsage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 29.99
        reloadedUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        let belowLimit = await reloaded.handle(request(reloaded, "quota_recovery"))
        try expect(belowLimit.ok, "saved 30 limit still accepts fresh subscription evidence below 30")
        var refreshedProfiles = reloadedUsage.profiles
        refreshedProfiles[0].lastSnapshot?.fiveHour?.usedPercent = 31
        refreshedProfiles[0].lastSnapshot?.fetchedAt = Date()
        reloadedUsage.profiles = refreshedProfiles
        // Await the real Combine observation; do not hide a missing observer by
        // explicitly calling rebuildRows after the external profile update.
        for _ in 0..<100 {
            if reloaded.rows.first?.windows.first(where: { $0.id == "5h" })?.remaining == 69 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        reloaded.flushDisplayRows()
        try expect(reloaded.rows.first?.windows.first(where: { $0.id == "5h" })?.remaining == 69
            && reloaded.rows.first?.state == "usage_limit" && reloaded.displayRows.first?.policy.fiveHourUsedLimit == 30,
            "external quota observation refreshes rows without resetting the saved policy")
        try await denied(reloaded, "externally refreshed request above 30")
        reloadedUsage.onRefresh = { _ in
            reloadedUsage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 40
            reloadedUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        }
        reloaded.refreshStatus(displayFreshResultsImmediately: true); reloaded.flushDisplayRows()
        reloadedUsage.onRefresh = nil
        try expect(reloadedUsage.refreshCount == 1 && reloaded.displayRows.first?.windows.first(where: { $0.id == "5h" })?.remaining == 60
            && reloaded.displayRows.first?.policy.fiveHourUsedLimit == 30 && reloaded.displayRows.first?.state == "usage_limit"
            && Data(contentsOf: preferenceURL) == savedBytes,
            "explicit quota refresh preserves 30, its usage limit state and committed bytes")
        try await denied(reloaded, "request after explicit refresh")
        let failedSave = LocalProxyQueueStore(usageStore: reloadedUsage), revision = failedSave.policyRevision
        let blockedDestination = URL(fileURLWithPath: preferenceURL.path + ".blocked")
        let needsBlockedDestination = !FileManager.default.fileExists(atPath: blockedDestination.path)
        if needsBlockedDestination {
            try FileManager.default.createDirectory(at: blockedDestination, withIntermediateDirectories: false)
        }
        defer { if needsBlockedDestination { try? FileManager.default.removeItem(at: blockedDestination) } }
        LocalProxyFixtureRuntime.failPreferenceRename = true
        let accepted = failedSave.setAccountPolicy(id: profile.id, policy: LocalProxyAccountPolicy())
        LocalProxyFixtureRuntime.failPreferenceRename = false
        try expect(!accepted && failedSave.preferencesFailure == .save && failedSave.policyRevision == revision
            && failedSave.preferences.policy(for: profile.id).fiveHourUsedLimit == 30
            && failedSave.displayRows.first?.policy.fiveHourUsedLimit == 30 && Data(contentsOf: preferenceURL) == savedBytes,
            "failed replacement of 30 rolls policy and published rows back while preserving disk")
        let afterFailure = LocalProxyQueueStore(usageStore: reloadedUsage)
        try expect(afterFailure.preferencesFailure == nil && afterFailure.rows.first?.policy.fiveHourUsedLimit == 30,
            "another Store still reloads 30 after the refused save")
        try expect(!FileManager.default.fileExists(atPath: profile.codexHomeURL.path),
            "save, reload, refresh and denied admission create no credential home")
        print("PASS: \(checks) policy save and admission checks; production Store and isolated quota inputs only")
    }

    @MainActor static func cooldownRefreshFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("COOLDOWN_REFRESH_CHECK \(checks): \(label)")
        }
        let now = Date(), until = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 3600)
        let window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(7200))
        let profile = CodexProfile(id: "cooldown-refresh-fixture", lastSnapshot: CodexAccountSnapshot(planType: "plus",
            accountID: "cooldown-refresh-account", email: "cooldown-refresh@example.invalid", fetchedAt: now.addingTimeInterval(-2), fiveHour: window, sevenDay: window))
        let usage = UsageStore([profile]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), run = UUID().uuidString
        store.runID = run; store.activeIDs = [profile.id]; store.preferences.enabledIDs = [profile.id]
        func event(_ state: String, until: Date? = nil) throws {
            var object: [String: Any] = ["event": "account", "profileID": profile.id, "state": state]
            if let until { object["cooldownUntil"] = until.timeIntervalSince1970 }
            store.consume(try JSONSerialization.data(withJSONObject: object), run: run)
            store.flushDisplayRows()
        }
        func held() -> Bool {
            store.accountStates[profile.id] == "quota" && store.rows.first?.state == "quota"
                && store.displayRows.first?.state == "quota" && store.displayRows.first?.cooldownUntil == until
        }
        try event("quota", until: until)
        try expect(held(), "helper cooldown event establishes quota state and exact expiry")
        store.refreshStatus(displayFreshResultsImmediately: true); store.flushDisplayRows()
        if store.rows.first?.state == "ready", ProcessInfo.processInfo.environment["PROXY_COOLDOWN_EXPECT_FALSE_READY"] == "1" {
            print("COOLDOWN_NEGATIVE_REPRODUCED: refresh falsely reports ready during live helper cooldown")
            exit(43)
        }
        try expect(held(), "manual refresh never reports ready during live helper cooldown")
        usage.profiles[0].lastSnapshot?.fetchedAt = now.addingTimeInterval(-1)
        usage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 10
        store.rebuildRows(); store.flushDisplayRows()
        try expect(held() && store.displayRows.first?.windows.first?.remaining == 90,
            "fresh recovered quota updates remaining amount while helper cooldown stays visible")
        store.refreshStatus(); store.flushDisplayRows()
        try expect(held() && usage.refreshCount == 2, "periodic refresh preserves helper cooldown without an extra refresh")
        let revision = store.policyRevision
        store.policyChanged()
        try expect(held() && store.policyRevision == revision + 1, "policy change preserves helper cooldown")
        try event("ready")
        try expect(store.rows.first?.state == "ready" && store.displayRows.first?.state == "ready"
            && store.cooldowns[profile.id] == nil && store.displayRows.first?.cooldownUntil == nil,
            "explicit helper ready clears quota state and cooldown together")
        for state in ["quota", "usage_limit", "subscription_pending", "quota_unknown"] {
            try event(state)
            store.refreshStatus(); store.flushDisplayRows()
            try expect(store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
                "refresh clears \(state) admission error without a live cooldown")
            try event(state)
            store.policyChanged()
            try expect(store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
                "policy change clears \(state) admission error without a live cooldown")
        }
        try event("quota", until: until)
        store.cooldowns[profile.id] = now.addingTimeInterval(-1)
        store.refreshStatus(); store.flushDisplayRows()
        try expect(store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
            "expired helper cooldown does not retain quota state on refresh")
        try event("quota", until: until)
        store.cooldowns[profile.id] = now.addingTimeInterval(-1)
        store.policyChanged()
        try expect(store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
            "expired helper cooldown does not retain quota state on policy change")
        try event("quota", until: now.addingTimeInterval(9 * 86400))
        store.refreshStatus(); store.flushDisplayRows()
        try expect(store.cooldowns[profile.id] == nil && store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
            "invalid helper cooldown cannot pin quota state")
        try event("login_expired")
        store.refreshStatus(); store.policyChanged()
        try expect(store.displayRows.first?.state == "login_expired", "refresh and policy edits preserve unrelated helper failures")
        print("PASS: \(checks) cooldown refresh host checks; synthetic helper events only")
    }
}
