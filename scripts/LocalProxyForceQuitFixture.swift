import Darwin
import Foundation

private final class FixtureCredentials: AntigravityProxyCredentialStore {
    var operations = 0
    func read(_ account: String) throws -> Data? { operations += 1; return nil }
    func save(_ data: Data, account: String) throws { operations += 1 }
    func remove(_ account: String) throws { operations += 1 }
}

@main struct LocalProxyForceQuitFixture {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label)
            checks += 1
            print("FORCE_QUIT_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let activity = DispatchActivityStore.live
        let now = Date()
        let window = CodexQuotaWindowSnapshot(usedPercent: 1, resetsAt: now.addingTimeInterval(3600))
        let profile = CodexProfile(id: "force-fixture", lastSnapshot: CodexAccountSnapshot(fetchedAt: now, fiveHour: window, sevenDay: window))
        let usage = UsageStore([profile]); usage.isPreview = false
        func child() throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["60"]
            try p.run()
            return p
        }
        func waitForExit(_ p: Process) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while p.isRunning {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "force-fixture", code: 1) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func fullPipe() throws -> (FileHandle, FileHandle) {
            let pipe = Pipe(), writer = pipe.fileHandleForWriting, reader = pipe.fileHandleForReading
            let fd = writer.fileDescriptor, flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NSError(domain: "force-fixture", code: 2) }
            let bytes = [UInt8](repeating: 65, count: 4096)
            var filled = 0
            while true {
                let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if count > 0 { filled += count; continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw NSError(domain: "force-fixture", code: 3) }
                break
            }
            guard filled > 0, fcntl(fd, F_SETFL, flags) == 0 else { throw NSError(domain: "force-fixture", code: 4) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = buffer.withUnsafeMutableBytes { Darwin.read(reader.fileDescriptor, $0.baseAddress, $0.count) }
            }
            return (writer, reader)
        }

        let local = LocalProxyQueueStore(usageStore: usage)
        local.setAccountEnabled(id: profile.id, enabled: true); local.setOptIn(true)
        let owned = try child(), foreign = try child()
        defer { if owned.isRunning { owned.terminate() }; if foreign.isRunning { foreign.terminate() } }
        let run = UUID().uuidString, request = UUID().uuidString
        local.process = owned; local.runID = run; local.phase = .running
        let lease = try activity.reserveProxy(account: "force-fixture", alias: "force-fixture", runID: run,
            requestID: request, profileID: profile.id, childPID: owned.processIdentifier)
        local.leases[lease] = LocalProxyQueueStore.Lease(id: lease, profileID: profile.id, requestID: request, runID: run)
        let stateURL = root.appendingPathComponent(DispatchActivityStore.stateName)
        let before = try Data(contentsOf: stateURL)
        let lock = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR | O_CLOEXEC)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "force-fixture", code: 5) }
        let (localWriter, localReader) = try fullPipe()
        local.input = localWriter
        var recoveryFired = false
        let recovery = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            recoveryFired = true
        }
        local.automaticRecoveryTask = recovery; local.isAutomaticallyRecovering = true
        local.startAttemptID = UUID()
        let began = ProcessInfo.processInfo.systemUptime
        local.forceStopForConfirmedTermination()
        expect(ProcessInfo.processInfo.systemUptime - began < 0.7,
            "Local force exit returns while its input pipe and registry lock are held")
        expect(local.forceTerminationRequested && local.startAttemptID == nil && !local.isAutomaticallyRecovering
                && local.leases[lease] != nil && local.exitCleanupID == nil && !local.canFinishTermination,
            "Local revokes startup and recovery while retaining its unresolved lease")
        expect((try? Data(contentsOf: stateURL)) == before, "Local force exit makes no registry mutation")
        await recovery.value
        expect(!recoveryFired, "Local pending recovery task is cancelled")
        try await waitForExit(owned)
        expect(foreign.isRunning, "Local signals only its own child")
        local.childExited(owned)
        local.consume(Data("{\"event\":\"error\",\"errorCode\":\"lease_heartbeat_failed\"}".utf8), run: run)
        local.forceStopForConfirmedTermination()
        await local.stop()
        expect(local.leases[lease] != nil && !local.canFinishTermination && (try? Data(contentsOf: stateURL)) == before,
            "Local late callbacks and repeated force/stop cannot claim or mutate lease cleanup")
        _ = flock(lock, LOCK_UN); Darwin.close(lock)

        let stopping = LocalProxyQueueStore(usageStore: usage)
        let stoppingChild = try child()
        defer { if stoppingChild.isRunning { stoppingChild.terminate() } }
        let stoppingRun = UUID().uuidString, stoppingRequest = UUID().uuidString
        stopping.process = stoppingChild; stopping.runID = stoppingRun; stopping.phase = .running
        let stoppingLease = try activity.reserveProxy(account: "force-stopping", alias: "force-stopping", runID: stoppingRun,
            requestID: stoppingRequest, profileID: profile.id, childPID: stoppingChild.processIdentifier)
        stopping.leases[stoppingLease] = LocalProxyQueueStore.Lease(id: stoppingLease, profileID: profile.id,
            requestID: stoppingRequest, runID: stoppingRun)
        let stoppingBefore = try Data(contentsOf: stateURL)
        let normalStop = Task { await stopping.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(stoppingChild.isRunning && stopping.phase == .stopping, "normal stop is waiting for its exact live child")
        let forceBegan = ProcessInfo.processInfo.systemUptime
        stopping.forceStopForConfirmedTermination()
        await normalStop.value
        try await waitForExit(stoppingChild)
        expect(ProcessInfo.processInfo.systemUptime - forceBegan < 0.7 && stopping.leases[stoppingLease] != nil
                && (try? Data(contentsOf: stateURL)) == stoppingBefore,
            "force exit interrupts normal stop's wait without clearing the outstanding lease")

        let pending = LocalProxyQueueStore(usageStore: usage)
        let pendingChild = try child()
        defer { if pendingChild.isRunning { pendingChild.terminate() } }
        let pendingRun = UUID().uuidString, pendingRequest = UUID().uuidString
        pending.process = pendingChild; pending.runID = pendingRun; pending.phase = .running
        let pendingLease = try activity.reserveProxy(account: "force-pending", alias: "force-pending", runID: pendingRun,
            requestID: pendingRequest, profileID: profile.id, childPID: pendingChild.processIdentifier)
        pending.leases[pendingLease] = LocalProxyQueueStore.Lease(id: pendingLease, profileID: profile.id,
            requestID: pendingRequest, runID: pendingRun)
        pendingChild.terminate(); try await waitForExit(pendingChild)
        let pendingBefore = try Data(contentsOf: stateURL)
        let pendingLock = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR | O_CLOEXEC)
        guard pendingLock >= 0, flock(pendingLock, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "force-fixture", code: 8) }
        let pendingStop = Task { await pending.stop() }
        let pendingDeadline = ProcessInfo.processInfo.systemUptime + 3
        while pending.exitCleanupID == nil {
            guard ProcessInfo.processInfo.systemUptime < pendingDeadline else { throw NSError(domain: "force-fixture", code: 9) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        pending.forceStopForConfirmedTermination()
        await pendingStop.value
        expect(pending.leases[pendingLease] != nil && pending.exitCleanupID != nil && !pending.canFinishTermination
                && (try? Data(contentsOf: stateURL)) == pendingBefore,
            "force exit revokes an in-progress normal stop without declaring its pending cleanup complete")
        _ = flock(pendingLock, LOCK_UN); Darwin.close(pendingLock)
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(pending.leases[pendingLease] != nil && pending.exitCleanupID != nil && (try? Data(contentsOf: stateURL)) == pendingBefore,
            "cancelled pending cleanup cannot later change the unresolved lease")

        let waiting = LocalProxyQueueStore(usageStore: usage)
        waiting.setAccountEnabled(id: profile.id, enabled: true); waiting.setOptIn(true)
        let startupLock = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR | O_CLOEXEC)
        guard startupLock >= 0, flock(startupLock, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "force-fixture", code: 6) }
        let start = Task { await waiting.start() }
        let startupDeadline = ProcessInfo.processInfo.systemUptime + 3
        while waiting.exitCleanupID == nil {
            guard ProcessInfo.processInfo.systemUptime < startupDeadline else { throw NSError(domain: "force-fixture", code: 7) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        waiting.forceStopForConfirmedTermination()
        await start.value
        expect(waiting.process == nil && waiting.startAttemptID == nil && waiting.forceTerminationRequested
                && waiting.exitCleanupID != nil && !waiting.canFinishTermination,
            "force exit revokes a startup waiting for registry access without clearing its gate")
        _ = flock(startupLock, LOCK_UN); Darwin.close(startupLock)
        try await Task.sleep(nanoseconds: 200_000_000)
        expect(waiting.process == nil && waiting.exitCleanupID != nil,
            "late startup completion cannot launch a helper or falsely finish cleanup")

        let unlaunchedLocal = LocalProxyQueueStore(usageStore: usage)
        unlaunchedLocal.process = Process(); unlaunchedLocal.forceStopForConfirmedTermination()
        expect(unlaunchedLocal.forceTerminationRequested, "Local safely handles an unlaunched Process")

        let creds = FixtureCredentials()
        let anti = AntigravityProxyStore(supportDirectory: root.appendingPathComponent("anti"), credentialStore: creds)
        let antiOwned = try child(), antiTerminating = try child()
        defer { if antiOwned.isRunning { antiOwned.terminate() }; if antiTerminating.isRunning { antiTerminating.terminate() } }
        let antiRun = UUID()
        anti.process = antiOwned; anti.terminatingProcess = antiTerminating; anti.runID = antiRun
        anti.phase = .running; anti.signInPending = true; anti.signInSession = "fixture-session"
        let (antiWriter, antiReader) = try fullPipe(); anti.input = antiWriter
        let antiBegan = ProcessInfo.processInfo.systemUptime
        anti.forceStopForConfirmedTermination()
        expect(ProcessInfo.processInfo.systemUptime - antiBegan < 0.7,
            "provider force exit returns when its input pipe is full")
        expect(anti.forceTerminationRequested && anti.runID == nil && !anti.signInPending
                && anti.process === antiOwned && anti.terminatingProcess === antiTerminating && creds.operations == 0,
            "provider revokes login and retains both exact child handles without credential I/O")
        try await waitForExit(antiOwned); try await waitForExit(antiTerminating)
        anti.exited(run: antiRun, child: antiOwned); anti.exited(run: antiRun, child: antiTerminating)
        anti.forceStopForConfirmedTermination(); anti.stop()
        expect(anti.process === antiOwned && anti.terminatingProcess === antiTerminating && foreign.isRunning && creds.operations == 0,
            "provider ignores stale exits and repeat calls; unrelated child and credentials remain untouched")

        let unlaunchedAnti = AntigravityProxyStore(supportDirectory: root.appendingPathComponent("anti-unlaunched"), credentialStore: creds)
        unlaunchedAnti.process = Process(); unlaunchedAnti.phase = .starting
        unlaunchedAnti.forceStopForConfirmedTermination()
        await unlaunchedAnti.start()
        expect(unlaunchedAnti.forceTerminationRequested && unlaunchedAnti.runID == nil && creds.operations == 0,
            "provider handles an unlaunched Process and refuses a late start")
        let exitedLocal = LocalProxyQueueStore(usageStore: usage)
        exitedLocal.process = owned
        let exitedAnti = AntigravityProxyStore(supportDirectory: root.appendingPathComponent("anti-exited"), credentialStore: creds)
        exitedAnti.terminatingProcess = antiTerminating
        exitedLocal.forceStopForConfirmedTermination(); exitedAnti.forceStopForConfirmedTermination()
        expect(!owned.isRunning && !antiTerminating.isRunning && foreign.isRunning && creds.operations == 0,
            "already-exited owned Process handles are safe and never affect an unrelated child")
        try await Task.sleep(nanoseconds: 1_600_000_000)
        try? localReader.close(); try? antiReader.close()
        foreign.terminate(); try await waitForExit(foreign)
        print("PASS: \(checks) forced termination checks; disposable children, synthetic state and held isolated locks")
    }
}
