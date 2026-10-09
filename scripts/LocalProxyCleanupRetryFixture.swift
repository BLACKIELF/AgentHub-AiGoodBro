import Darwin
import Foundation

@main struct LocalProxyCleanupRetryFixture {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
            let result = try value()
            precondition(result, label)
            checks += 1
            print("CLEANUP_RETRY_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let activity = DispatchActivityStore.live
        let now = Date()
        let window = CodexQuotaWindowSnapshot(usedPercent: 1, resetsAt: now.addingTimeInterval(3600))
        let profile = CodexProfile(id: "cleanup-fixture", lastSnapshot: CodexAccountSnapshot(fetchedAt: now, fiveHour: window, sevenDay: window))
        let usage = UsageStore([profile]); usage.isPreview = false
        let lockURL = root.appendingPathComponent(DispatchActivityStore.lockName)
        let stateURL = root.appendingPathComponent(DispatchActivityStore.stateName)
        func lockRegistry() throws -> Int32 {
            let fd = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
            precondition(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "fixture owns only its isolated registry lock")
            return fd
        }
        func unlock(_ fd: Int32) { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        func makeStore() throws -> (LocalProxyQueueStore, Process, String, String) {
            let store = LocalProxyQueueStore(usageStore: usage)
            store.setAccountEnabled(id: profile.id, enabled: true)
            store.setOptIn(true)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
            try child.run()
            let run = UUID().uuidString, request = UUID().uuidString
            store.process = child; store.phase = .running; store.runID = run
            let id = try activity.reserveProxy(account: "fixture-\(run)", alias: "fixture-\(run)", runID: run,
                requestID: request, profileID: profile.id, childPID: child.processIdentifier)
            store.leases[id] = LocalProxyQueueStore.Lease(id: id, profileID: profile.id, requestID: request, runID: run)
            return (store, child, run, id)
        }
        func finish(_ child: Process) async {
            if child.isRunning { child.terminate() }
            await Task.detached { child.waitUntilExit() }.value
        }
        // A live unrelated run remains present throughout every batch retirement.
        let (foreign, foreignChild, foreignRun, foreignLease) = try makeStore()
        defer { if foreignChild.isRunning { foreignChild.terminate() } }
        let inactive = LocalProxyQueueStore(usageStore: usage)
        let idleFD = try lockRegistry()
        await inactive.stop()
        expect(inactive.exitCleanupID == nil && inactive.exitCleanupTask == nil && inactive.canFinishTermination,
            "unrelated busy registry cannot prevent a never-started store from quitting")
        unlock(idleFD)

        let (recovering, oldChild, _, oldLease) = try makeStore()
        await finish(oldChild)
        let transientFD = try lockRegistry()
        LocalProxyFixtureRuntime.cleanupAttemptCount = 0
        let stop = Task { await recovering.stop() }
        for _ in 0..<50 {
            if recovering.exitCleanupID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(recovering.exitCleanupID != nil && !recovering.canStart && !recovering.canFinishTermination,
            "busy cleanup retains its completion gate before stop returns")
        expect(recovering.leases[oldLease] != nil, "busy cleanup never discards the exact in-memory lease")
        unlock(transientFD)
        await stop.value
        expect(LocalProxyFixtureRuntime.cleanupAttemptCount == 2, "one bounded retry resolves transient lock contention")
        expect(recovering.leases.isEmpty && recovering.exitCleanupID == nil && recovering.exitCleanupTask == nil,
            "await stop returns after exact lease and cleanup task finish")
        expect(recovering.canStart && recovering.canFinishTermination, "same store can start or finish termination after recovery")
        try expect(activity.read().leases.first { $0.leaseId == oldLease }?.state == "cancelled", "confirmed dead helper lease is cancelled")
        try expect(activity.read().leases.first { $0.leaseId == foreignLease }?.occupied == true && foreignChild.isRunning,
            "batch retry preserves another live run and child")

        // A detached reservation may exist only on disk. The completion gate
        // must protect start/quit even when the UI lease mirror is already empty.
        let (orphaned, orphanChild, _, orphanLease) = try makeStore()
        orphaned.leases.removeAll()
        await finish(orphanChild)
        let orphanFD = try lockRegistry()
        let orphanStop = Task { await orphaned.stop() }
        for _ in 0..<50 {
            if orphaned.exitCleanupID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(orphaned.leases.isEmpty && orphaned.exitCleanupID != nil && !orphaned.canStart && !orphaned.canFinishTermination,
            "pending batch retirement blocks start and quit even without an in-memory lease")
        unlock(orphanFD)
        await orphanStop.value
        try expect(activity.read().leases.first { $0.leaseId == orphanLease }?.state == "cancelled",
            "batch retry retires the exact disk-only lease of the confirmed dead run")
        expect(orphaned.exitCleanupID == nil && orphaned.canStart && orphaned.canFinishTermination,
            "disk-only lease recovery clears the same store completion gate")

        let (exhausted, deadChild, _, heldLease) = try makeStore()
        await finish(deadChild)
        let heldFD = try lockRegistry()
        let beforeHeld = try Data(contentsOf: stateURL)
        LocalProxyFixtureRuntime.cleanupAttemptCount = 0
        let started = ProcessInfo.processInfo.systemUptime
        await exhausted.stop()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        expect(LocalProxyFixtureRuntime.cleanupAttemptCount == 4 && elapsed >= 0.5 && elapsed < 3,
            "persistent busy stops after initial attempt and three 200 ms retries")
        expect(exhausted.phase == .failed && exhausted.exitCleanupID != nil && exhausted.exitCleanupTask == nil,
            "retry exhaustion preserves failed pending state without a spinning task")
        expect(exhausted.leases[heldLease] != nil && !exhausted.canStart && !exhausted.canFinishTermination,
            "retry exhaustion retains ownership and blocks unsafe start or quit")
        try expect(Data(contentsOf: stateURL) == beforeHeld, "lock contention made no registry mutation")
        exhausted.isEnabled = false
        expect(exhausted.canStop && exhausted.requiresStopConfirmation, "manual cleanup remains available even when opt-in is off")
        let staleGeneration = exhausted.exitCleanupID!
        unlock(heldFD)
        await exhausted.stop()
        expect(exhausted.canFinishTermination && exhausted.exitCleanupID == nil, "manual stop retries safely after automatic budget expires")

        // Supply a later live run to the same store, then deliver an old callback.
        let (_, newChild, newRun, newLease) = try makeStore()
        defer { if newChild.isRunning { newChild.terminate() } }
        exhausted.process = newChild; exhausted.runID = newRun; exhausted.phase = .running
        let newRecord = try activity.read().leases.first { $0.leaseId == newLease }!
        exhausted.leases[newLease] = LocalProxyQueueStore.Lease(id: newLease, profileID: profile.id,
            requestID: newRecord.proxyRequestID!, runID: newRun)
        let beforeStale = try Data(contentsOf: stateURL)
        exhausted.cleanupConfirmedExit(retryID: staleGeneration, remainingRetries: 2)
        expect(exhausted.process === newChild && exhausted.runID == newRun && exhausted.phase == .running,
            "late old-generation cleanup cannot change a new live run")
        try expect(Data(contentsOf: stateURL) == beforeStale && exhausted.leases[newLease] != nil,
            "late cleanup cannot retire the new run lease")
        exhausted.cleanupConfirmedExit()
        try expect(newChild.isRunning && Data(contentsOf: stateURL) == beforeStale && exhausted.exitCleanupID == nil,
            "direct cleanup refuses a child that is still alive")
        await finish(newChild)
        exhausted.childExited(newChild)

        let (superseded, endedChild, _, _) = try makeStore()
        await finish(endedChild)
        let supersedeFD = try lockRegistry()
        superseded.cleanupConfirmedExit()
        let priorID = superseded.exitCleanupID!, priorTask = superseded.exitCleanupTask!
        superseded.cleanupConfirmedExit()
        let currentID = superseded.exitCleanupID!
        expect(currentID != priorID, "manual cleanup owns a fresh retry generation")
        superseded.cleanupConfirmedExit(retryID: priorID, remainingRetries: 2)
        expect(superseded.exitCleanupID == currentID, "stale callback cannot replace a newer pending cleanup")
        unlock(supersedeFD)
        await priorTask.value
        await superseded.exitCleanupTask?.value
        expect(superseded.canFinishTermination && superseded.exitCleanupID == nil, "new generation completes while cancelled generation stays inert")

        // Invalid state is not lock contention and must never be auto-retried.
        let (invalid, invalidChild, _, invalidLease) = try makeStore()
        await finish(invalidChild)
        let validState = try Data(contentsOf: stateURL)
        try Data("invalid-fixture".utf8).write(to: stateURL)
        LocalProxyFixtureRuntime.cleanupAttemptCount = 0
        await invalid.stop()
        expect(LocalProxyFixtureRuntime.cleanupAttemptCount == 1 && invalid.exitCleanupTask == nil,
            "invalid registry does not consume busy retries")
        expect(invalid.exitCleanupID != nil && invalid.leases[invalidLease] != nil && !invalid.canFinishTermination,
            "invalid state retains exact lease and remains fail-closed")
        try validState.write(to: stateURL)
        await invalid.stop()
        expect(invalid.canFinishTermination, "explicit retry can recover after external state is repaired")
        try expect(activity.read().leases.first { $0.leaseId == foreignLease }?.occupied == true && foreign.runID == foreignRun,
            "all cleanup attempts preserve the unrelated live run")
        await finish(foreignChild)
        foreign.childExited(foreignChild)
        try expect(activity.read().leases.filter(\.occupied).isEmpty, "fixture closes only its own remaining disposable run")
        print("PASS: \(checks) cleanup retry checks; isolated support, synthetic leases and disposable sleep children")
    }
}
