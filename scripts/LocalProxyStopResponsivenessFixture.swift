import Darwin
import Foundation

// Isolated support root, synthetic leases and disposable children only.
@main struct LocalProxyStopResponsivenessFixture {
    static func hasEntered(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let activity = DispatchActivityStore.live
        let now = Date()
        let window = CodexQuotaWindowSnapshot(usedPercent: 1, resetsAt: now.addingTimeInterval(3600))
        let profile = CodexProfile(id: "fixture", lastSnapshot: CodexAccountSnapshot(fetchedAt: now, fiveHour: window, sevenDay: window))
        let usage = UsageStore([profile]); usage.isPreview = false
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if !value { failures += 1 }
        }
        func makeStore() async throws -> (LocalProxyQueueStore, Process, String, String) {
            LocalProxyQueueStore.issueQueue.sync {}
            let store = LocalProxyQueueStore(usageStore: usage)
            store.setAccountEnabled(id: profile.id, enabled: true)
            store.setOptIn(true)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
            try child.run()
            let run = UUID().uuidString, request = UUID().uuidString
            store.process = child; store.phase = .running; store.runID = run
            var lease: String?
            for _ in 0..<100 {
                do {
                    lease = try activity.reserveProxy(account: "fixture-\(run)", alias: "fixture-\(run)",
                        runID: run, requestID: request, profileID: profile.id, childPID: child.processIdentifier)
                    break
                } catch DispatchActivityStore.Failure.busy {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            guard let lease else { throw DispatchActivityStore.Failure.busy }
            store.leases[lease] = LocalProxyQueueStore.Lease(id: lease, profileID: profile.id, requestID: request, runID: run)
            return (store, child, run, lease)
        }
        func finish(_ child: Process) async {
            if child.isRunning { child.terminate() }
            await Task.detached { child.waitUntilExit() }.value
        }
        func exercise(hold: Double) async throws {
            let (store, child, run, firstLease) = try await makeStore()
            let childPID = child.processIdentifier
            await finish(child)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            LocalProxyFixtureRuntime.setReserveHook(run: run) {
                entered.signal()
                release.wait()
            }
            let reservation = Task.detached {
                try? activity.reserveProxy(account: "fixture-late-\(run)", alias: "fixture-late-\(run)",
                    runID: run, requestID: UUID().uuidString, profileID: "fixture-late", childPID: childPID)
            }
            let entryDeadline = ProcessInfo.processInfo.systemUptime + 3
            while !hasEntered(entered) {
                guard ProcessInfo.processInfo.systemUptime < entryDeadline else { throw NSError(domain: "fixture", code: 1) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + hold) { release.signal() }
            let began = ProcessInfo.processInfo.systemUptime
            let stopping = Task { await store.stop() }
            try await Task.sleep(nanoseconds: 100_000_000)
            let tick = ProcessInfo.processInfo.systemUptime - began
            check(tick < 0.7, "main actor remains responsive while the exact run fence is held")
            check(!store.canFinishTermination && !store.canStart, "unconfirmed cleanup blocks quit and a new run")
            await stopping.value
            let stoppedAt = ProcessInfo.processInfo.systemUptime - began
            if hold > 3.5 {
                check(stoppedAt < hold - 0.5, "a stalled registry returns an explicit failure within its bound")
                check(store.phase == .failed && !store.canFinishTermination && store.leases[firstLease] != nil,
                    "timed-out cleanup retains the lease and fails closed")
                let retry = Task { await store.stop() }
                try await Task.sleep(nanoseconds: 100_000_000)
                check(!store.canFinishTermination && !store.canStart && store.leases[firstLease] != nil,
                    "overlapping retry cannot claim success while the old worker holds its gate")
                await retry.value
                check(!store.canFinishTermination && !store.canStart,
                    "exhausted retries keep the old worker fenced until a later manual retry")
                _ = await reservation.value
                LocalProxyFixtureRuntime.clearReserveHook()
            } else {
                _ = await reservation.value
                LocalProxyFixtureRuntime.clearReserveHook()
            }
            if !store.canFinishTermination { await store.stop() }
            check(store.canFinishTermination && store.leases.isEmpty, "retry succeeds only after exact retirement")
            let snapshot = try activity.read()
            check(snapshot.leases.filter { $0.proxyRunID == run && $0.occupied }.isEmpty,
                "batch retirement includes a reservation that was in flight at stop")
        }
        func unexpectedExit() async throws {
            let (store, child, run, _) = try await makeStore()
            let pid = child.processIdentifier
            await finish(child)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            LocalProxyFixtureRuntime.setReserveHook(run: run) { entered.signal(); release.wait() }
            let reservation = Task.detached {
                try? activity.reserveProxy(account: "fixture-unexpected-\(run)", alias: "fixture-unexpected-\(run)",
                    runID: run, requestID: UUID().uuidString, profileID: "fixture-unexpected", childPID: pid)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !hasEntered(entered) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "fixture", code: 2) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { release.signal() }
            store.childExited(child)
            let cleanupID = store.exitCleanupID
            check(store.phase == .stopping && cleanupID != nil, "unexpected exit remains in cleanup while the run fence is held")
            let stop = Task { await store.stop() }
            try await Task.sleep(nanoseconds: 100_000_000)
            check(store.exitCleanupID == cleanupID && !store.canStart && !store.canFinishTermination,
                "stop joins unexpected-exit cleanup without superseding its generation")
            _ = await reservation.value
            LocalProxyFixtureRuntime.clearReserveHook()
            await stop.value
            if !store.canFinishTermination { await store.stop() }
            check(store.canFinishTermination && store.canStart && store.leases.isEmpty,
                "unexpected-exit cleanup eventually permits a safe manual restart")
        }
        func cancelledStart() async throws {
            let (holder, child, run, _) = try await makeStore()
            let pid = child.processIdentifier
            await finish(child)
            let startingStore = LocalProxyQueueStore(usageStore: usage)
            startingStore.setAccountEnabled(id: profile.id, enabled: true)
            startingStore.setOptIn(true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            LocalProxyFixtureRuntime.setReserveHook(run: run) { entered.signal(); release.wait() }
            let reservation = Task.detached {
                try? activity.reserveProxy(account: "fixture-start-\(run)", alias: "fixture-start-\(run)",
                    runID: run, requestID: UUID().uuidString, profileID: "fixture-start", childPID: pid)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !hasEntered(entered) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "fixture", code: 3) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4.0) { release.signal() }
            LocalProxyFixtureRuntime.helperLaunches = 0
            let began = ProcessInfo.processInfo.systemUptime
            let start = Task { await startingStore.start() }
            try await Task.sleep(nanoseconds: 100_000_000)
            check(ProcessInfo.processInfo.systemUptime - began < 0.7,
                "startup registry cleanup does not block the main actor")
            let stop = Task { await startingStore.stop() }
            try await Task.sleep(nanoseconds: 100_000_000)
            check(!startingStore.canStart && !startingStore.canFinishTermination,
                "stop during startup retains the cleanup gate while the old worker is pending")
            await start.value
            check(startingStore.exitCleanupID != nil && !startingStore.canStart && !startingStore.canFinishTermination,
                "timed-out old startup worker cannot open the gate during stop")
            _ = await reservation.value
            LocalProxyFixtureRuntime.clearReserveHook()
            await stop.value
            if !startingStore.canFinishTermination { await startingStore.stop() }
            check(startingStore.canFinishTermination && startingStore.process == nil && startingStore.runID == nil
                    && LocalProxyFixtureRuntime.helperLaunches == 0,
                "cancelled startup cannot launch a late helper and stop completes after the gate releases")
            holder.childExited(child)
            await holder.exitCleanupTask?.value
        }
        func timedOutStart() async throws {
            let (holder, child, run, _) = try await makeStore()
            let pid = child.processIdentifier
            await finish(child)
            let store = LocalProxyQueueStore(usageStore: usage)
            store.setAccountEnabled(id: profile.id, enabled: true)
            store.setOptIn(true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            LocalProxyFixtureRuntime.setReserveHook(run: run) { entered.signal(); release.wait() }
            let reservation = Task.detached {
                try? activity.reserveProxy(account: "fixture-start-timeout-\(run)", alias: "fixture-start-timeout-\(run)",
                    runID: run, requestID: UUID().uuidString, profileID: "fixture-start-timeout", childPID: pid)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !hasEntered(entered) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "fixture", code: 4) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { release.signal() }
            LocalProxyFixtureRuntime.helperLaunches = 0
            let began = ProcessInfo.processInfo.systemUptime
            await store.start()
            check(ProcessInfo.processInfo.systemUptime - began < 4.5 && store.process == nil
                    && store.exitCleanupID != nil && !store.canStart && !store.canFinishTermination,
                "timed-out startup returns without launching and retains its worker gate")
            _ = await reservation.value
            LocalProxyFixtureRuntime.clearReserveHook()
            if !store.canFinishTermination { await store.stop() }
            check(store.canFinishTermination && store.canStart && LocalProxyFixtureRuntime.helperLaunches == 0,
                "timed-out startup becomes recoverable after the old worker releases its gate")
            holder.childExited(child)
            await holder.exitCleanupTask?.value
        }
        func lateWorker() async throws {
            let (store, child, run, _) = try await makeStore()
            await finish(child)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            LocalProxyFixtureRuntime.setWorkerHook(run: run, before: {
                entered.signal()
                release.wait()
            }, done: { done.signal() })
            let stop = Task { await store.stop() }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !hasEntered(entered) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "fixture", code: 5) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await stop.value
            check(store.exitCleanupID != nil && !store.canStart && !store.canFinishTermination,
                "a worker whose reply times out cannot declare cleanup successful")
            LocalProxyFixtureRuntime.clearWorkerHook()
            await store.stop()
            check(store.canFinishTermination && store.leases.isEmpty,
                "manual retry confirms retirement after the old worker has released the gate")
            let (_, newChild, newRun, newLease) = try await makeStore()
            let newRecord = try activity.read().leases.first { $0.leaseId == newLease }!
            store.process = newChild; store.runID = newRun; store.phase = .running
            store.leases[newLease] = LocalProxyQueueStore.Lease(id: newLease, profileID: profile.id,
                requestID: newRecord.proxyRequestID!, runID: newRun)
            release.signal()
            let doneDeadline = ProcessInfo.processInfo.systemUptime + 3
            while !hasEntered(done) {
                guard ProcessInfo.processInfo.systemUptime < doneDeadline else { throw NSError(domain: "fixture", code: 12) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let active = try activity.read().leases.first { $0.leaseId == newLease }
            check(store.process === newChild && store.runID == newRun && store.phase == .running
                    && store.leases[newLease] != nil && active?.occupied == true && newChild.isRunning,
                "late completion from the timed-out worker cannot affect a new live run or lease")
            await finish(newChild)
            store.childExited(newChild)
            await store.exitCleanupTask?.value
        }
        func prunedLateWorker() async throws {
            let (store, child, run, _) = try await makeStore()
            let pid = child.processIdentifier
            for index in 1..<105 {
                let request = UUID().uuidString
                var id: String?
                for _ in 0..<100 {
                    do {
                        id = try activity.reserveProxy(account: "fixture-many-\(index)-\(run)", alias: "fixture-many-\(index)-\(run)",
                            runID: run, requestID: request, profileID: "fixture-many-\(index)", childPID: pid)
                        break
                    } catch DispatchActivityStore.Failure.busy {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                guard let id else { throw DispatchActivityStore.Failure.busy }
                store.leases[id] = LocalProxyQueueStore.Lease(id: id, profileID: "fixture-many-\(index)", requestID: request, runID: run)
            }
            await finish(child)
            let oldLeaseIDs = Set(store.leases.keys)
            LocalProxyQueueStore.issueQueue.sync {}
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            LocalProxyFixtureRuntime.setWorkerHook(run: run, before: { entered.signal(); release.wait() }, done: { done.signal() })
            let stop = Task { await store.stop() }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !hasEntered(entered) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "fixture", code: 9) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await stop.value
            let snapshot = try activity.read()
            let missing = oldLeaseIDs.subtracting(Set(snapshot.leases.map(\.leaseId)))
            check(!missing.isEmpty && !store.canFinishTermination,
                "timed-out completed worker can precede terminal-history pruning")
            LocalProxyFixtureRuntime.clearWorkerHook()
            release.signal()
            let doneDeadline = ProcessInfo.processInfo.systemUptime + 3
            while !hasEntered(done) {
                guard ProcessInfo.processInfo.systemUptime < doneDeadline else { throw NSError(domain: "fixture", code: 13) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            check(store.exitCleanupID != nil && !store.canStart && !store.canFinishTermination && !store.isAutomaticallyRecovering,
                "late retirement evidence alone cannot claim stop or start recovery")
            await store.stop()
            check(store.canFinishTermination && store.leases.isEmpty && store.canStart,
                "exact late retirement evidence allows recovery after terminal rows are pruned")
        }
        func launchFailure() async throws {
            let store = LocalProxyQueueStore(usageStore: usage)
            store.setAccountEnabled(id: profile.id, enabled: true)
            store.setOptIn(true)
            LocalProxyFixtureRuntime.helperLaunches = 0
            await store.start()
            await store.exitCleanupTask?.value
            check(LocalProxyFixtureRuntime.helperLaunches == 1 && store.process == nil && store.phase == .failed
                    && store.canFinishTermination,
                "helper launch failure reports failure without reading an unlaunched child's exit status")
        }
        func busyStartup() async throws {
            LocalProxyQueueStore.issueQueue.sync {}
            let store = LocalProxyQueueStore(usageStore: usage)
            store.setAccountEnabled(id: profile.id, enabled: true)
            store.setOptIn(true)
            let lockPath = root.appendingPathComponent(DispatchActivityStore.lockName).path
            let fd = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "fixture", code: 10) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
            LocalProxyFixtureRuntime.helperLaunches = 0
            await store.start()
            await store.exitCleanupTask?.value
            check(LocalProxyFixtureRuntime.helperLaunches == 1 && store.canFinishTermination,
                "transient registry contention during startup is retried within the bound")
        }
        func cancelBusyStartup() async throws {
            LocalProxyQueueStore.issueQueue.sync {}
            let store = LocalProxyQueueStore(usageStore: usage)
            store.setAccountEnabled(id: profile.id, enabled: true)
            store.setOptIn(true)
            let lockPath = root.appendingPathComponent(DispatchActivityStore.lockName).path
            let fd = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "fixture", code: 11) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
            LocalProxyFixtureRuntime.helperLaunches = 0
            LocalProxyFixtureRuntime.startupAttempts = 0
            let start = Task { await store.start() }
            try await Task.sleep(nanoseconds: 150_000_000)
            let attemptsBeforeStop = LocalProxyFixtureRuntime.startupAttempts
            let stop = Task { await store.stop() }
            await start.value
            check(attemptsBeforeStop > 0 && LocalProxyFixtureRuntime.startupAttempts == attemptsBeforeStop
                    && store.exitCleanupID != nil && !store.canStart && !store.canFinishTermination && LocalProxyFixtureRuntime.helperLaunches == 0,
                "stop during busy startup retry revokes the old attempt and retains cleanup")
            await stop.value
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if !store.canFinishTermination { await store.stop() }
            check(store.canFinishTermination && LocalProxyFixtureRuntime.helperLaunches == 0,
                "busy startup cancellation can be confirmed after the registry unlocks")
        }
        func fullPipe() async throws {
            let (store, child, _, _) = try await makeStore()
            await finish(child)
            let pipe = Pipe(), writer = pipe.fileHandleForWriting, reader = pipe.fileHandleForReading
            let fd = writer.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NSError(domain: "fixture", code: 6) }
            let bytes = [UInt8](repeating: 65, count: 4096)
            var filled = 0
            while true {
                let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if count > 0 { filled += count; continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw NSError(domain: "fixture", code: 7) }
                break
            }
            guard filled > 0, fcntl(fd, F_SETFL, flags) == 0 else { throw NSError(domain: "fixture", code: 8) }
            store.input = writer
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                var drained = [UInt8](repeating: 0, count: 4096)
                _ = drained.withUnsafeMutableBytes { Darwin.read(reader.fileDescriptor, $0.baseAddress, $0.count) }
            }
            let began = ProcessInfo.processInfo.systemUptime
            let stop = Task { await store.stop() }
            try await Task.sleep(nanoseconds: 100_000_000)
            check(ProcessInfo.processInfo.systemUptime - began < 0.7,
                "stop remains responsive when the helper input pipe is full")
            await stop.value
            check(store.canFinishTermination && store.leases.isEmpty,
                "full input pipe never bypasses exact cleanup after confirmed child exit")
            try await Task.sleep(nanoseconds: 1_500_000)
            try? reader.close()
        }
        if ProcessInfo.processInfo.environment["PROXY_PIPE_ONLY"] == "1" {
            try await fullPipe()
            if failures != 0 { exit(2) }
            return
        }
        if ProcessInfo.processInfo.environment["PROXY_PRUNED_ONLY"] == "1" {
            try await prunedLateWorker()
            if failures != 0 { exit(2) }
            return
        }
        if ProcessInfo.processInfo.environment["PROXY_START_BUSY_ONLY"] == "1" {
            try await busyStartup()
            try await cancelBusyStartup()
            if failures != 0 { exit(2) }
            return
        }
        if ProcessInfo.processInfo.environment["PROXY_STOP_RESPONSIVENESS_NEGATIVE"] == "1" {
            try await cancelledStart()
            if failures != 0 { exit(2) }
            return
        }
        try await exercise(hold: 1.5)
        try await exercise(hold: 5)
        try await unexpectedExit()
        try await cancelledStart()
        try await timedOutStart()
        try await lateWorker()
        try await prunedLateWorker()
        try await launchFailure()
        try await busyStartup()
        try await cancelBusyStartup()
        try await fullPipe()
        if failures != 0 { exit(2) }
        print("PASS: stop responsiveness, timeout, exact retirement and fail-closed retry")
    }
}
