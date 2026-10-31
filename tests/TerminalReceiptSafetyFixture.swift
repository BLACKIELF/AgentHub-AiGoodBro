import Foundation
import Darwin

// Application boundaries only. Production session, Store and monitor methods are compiled.
enum HubAccountTaskPhase { case maintenance, starting, running, cancelRequested, uncertain, awaitingAcceptance, succeeded, failed, cancelled, unavailable }
struct HubAccountTaskStatus { let phase: HubAccountTaskPhase; let updatedAt: Date? }
enum DispatchParticipationError: Error { case fileAccess }
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TERMINAL_FIXTURE_ROOT"]!) }
}
enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool) throws -> Data? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if allowMissing && errno == ENOENT { return nil }
            throw TerminalLauncherError.launchFailed
        }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_size <= maximumBytes else { throw TerminalLauncherError.launchFailed }
        return try Data(contentsOf: url)
    }
}
enum TerminalLauncherError: Error { case launchFailed, launchFileFailed; var errorDescription: String? { "fixture" } }
struct CodexExecutionPreference { static let defaultValue = Self() }
enum TerminalAppLauncher {
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func command(codexHome: URL, directory: URL, executable: String, preference: CodexExecutionPreference, homeDirectory: URL) throws -> String { throw TerminalLauncherError.launchFailed }
}
struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ zh: String, _ en: String) -> String { en }
}

@main struct Fixture {
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
        guard value() else { throw NSError(domain: label, code: 1) }
    }
    static func spawn(_ script: URL) throws -> pid_t {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { throw TerminalLauncherError.launchFailed }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attr, 0) == 0 else { throw TerminalLauncherError.launchFailed }
        let arguments: [String] = ["/bin/zsh", "-f", script.path]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { value in
            value.withCString { strdup($0) }
        }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = argv.withUnsafeMutableBufferPointer { posix_spawn(&pid, "/bin/zsh", nil, &attr, $0.baseAddress!, environ) }
        guard rc == 0 else { throw TerminalLauncherError.launchFailed }
        return pid
    }
    static func reap(_ pid: pid_t) throws {
        var status: Int32 = 0
        for _ in 0..<500 {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return }
            if result < 0 && errno != EINTR { throw TerminalLauncherError.launchFailed }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // No force kill: fixture owner reports failure and leaves evidence for host.
        throw NSError(domain: "owned-child-timeout", code: 1)
    }
    @MainActor static func main() async {
        do {
            let fm = FileManager.default
            let root = DispatchParticipationPaths.supportDirectory()
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let session = try TerminalLaunchSession.create(command: ":", base: root.appendingPathComponent("parser"))
            func write(_ value: String) throws {
                try Data(value.utf8).write(to: session.receiptURL)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.receiptURL.path)
            }
            for line in ["exited 0", "started 123", "v2 exited 0 12 10 0", "v2 exited 12 0 10 0", "v2 exited 12 12 0 0", "v2 exited 12 12 10 256", "v2 started 12 12 10 1"] {
                do { _ = try TerminalLaunchSession.parse(line); throw NSError(domain: "accepted-invalid-receipt", code: 1) }
                catch TerminalLauncherError.launchFailed {}
            }
            try write("v2 exited 12345 12345 100 0\n")
            try expect(session.verifiedExitCode(probe: { _ in .absent }) == 0, "clear-probe")
            try expect(session.verifiedExitCode(probe: { _ in .unknown }) == nil, "query-failure")
            try expect(session.verifiedExitCode(probe: { $0 > 0 ? .present : .absent }) == nil, "writer-live-or-reused-pid")
            try expect(session.verifiedExitCode(probe: { $0 < 0 ? .present : .absent }) == nil, "derived-process-live")
            try Data().write(to: URL(fileURLWithPath: session.receiptURL.path + ".tmp"))
            try expect(session.verifiedExitCode(probe: { _ in .absent }) == nil, "write-in-progress")
            try fm.removeItem(atPath: session.receiptURL.path + ".tmp")
            var changed = false
            try expect(session.verifiedExitCode(probe: { _ in
                if !changed { changed = true; try? write("v2 exited 12345 12345 100 7\n") }
                return .absent
            }) == nil, "receipt-changed")
            try write("v2 exited 12345 12345 100 143\n")
            try expect(session.verifiedExitCode(probe: { _ in .absent }) == nil, "signal-exit")
            print("PASS: version, identity, query failure, PID reuse, group presence, in-flight and changed receipt")

            let store = DispatchActivityStore.live
            let monitor = MonitorHarness()
            for (label, command, expected) in [("clean", ":", "awaiting_acceptance"), ("failure", "false", "failed")] {
                let lease = try store.reserveTerminal(account: label, alias: label, workingDirectory: root.appendingPathComponent(label))
                let real = try TerminalLaunchSession.create(command: command, identifier: lease)
                let pid = try spawn(real.scriptURL)
                try reap(pid)
                try expect(real.verifiedExitCode() == (label == "clean" ? 0 : 1), "real-group-clear")
                monitor.begin(real, lease: lease)
                try await monitor.waitFor(lease, expected: expected)
                try expect(!fm.fileExists(atPath: real.directory.path), "receipt-cleaned-after-store-success")
            }
            let live = try TerminalLaunchSession.create(command: "/bin/sleep 1", base: root.appendingPathComponent("live"))
            let livePID = try spawn(live.scriptURL)
            for _ in 0..<100 {
                if (try? live.readState()) == .started(livePID) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(live.hasMatchingLiveProcess(livePID), "kernel-birth-and-group-match")
            try expect(!live.hasMatchingLiveProcess(getpid()), "unrelated-pid-rejected")
            let liveBytes = try Data(contentsOf: live.receiptURL)
            let identity = try TerminalLaunchSession.parseReceipt(String(decoding: liveBytes, as: UTF8.self))
            try Data("v2 started \(livePID) \(identity.group) \(identity.birthSeconds + 1) 0\n".utf8).write(to: live.receiptURL)
            try expect(!live.hasMatchingLiveProcess(livePID), "birth-mismatch-rejected")
            try liveBytes.write(to: live.receiptURL)
            try reap(livePID)
            try expect(live.verifiedExitCode() == 0, "live-fixture-group-ended")
            let completedCode = try await LocalCLITerminalLauncher.waitForExit(live, timeout: 0.1)
            try expect(completedCode == 0 && !fm.fileExists(atPath: live.directory.path), "caller-completes-after-group-exit")
            // A real background child closes stdio and outlives the EXIT writer.
            let lease = try store.reserveTerminal(account: "derived", alias: "derived", workingDirectory: root.appendingPathComponent("derived"))
            let real = try TerminalLaunchSession.create(command: "/bin/sleep 3 </dev/null >/dev/null 2>&1 &", identifier: lease)
            let pid = try spawn(real.scriptURL)
            try reap(pid)
            try expect(TerminalLaunchSession.presence(pid) == .absent, "writer-gone")
            try expect(TerminalLaunchSession.presence(-pid) == .present, "owned-group-remains")
            try expect(real.verifiedExitCode() == nil, "real-child-blocks-release")
            do {
                _ = try await LocalCLITerminalLauncher.waitForExit(real, timeout: 0.05)
                throw NSError(domain: "caller-completed-with-live-child", code: 1)
            } catch LocalCLITerminalLauncher.Failure.timedOut {}
            try expect(fm.fileExists(atPath: real.receiptURL.path), "caller-timeout-preserves-live-child-receipt")
            monitor.begin(real, lease: lease)
            try await monitor.waitFor(lease, expected: "uncertain")
            try expect(fm.fileExists(atPath: real.receiptURL.path), "uncertain-keeps-receipt")
            try await monitor.waitFor(lease, expected: "awaiting_acceptance")
            try expect(TerminalLaunchSession.presence(-pid) == .absent, "owned-group-ended-naturally")
            let oldLease = try store.reserveTerminal(account: "old", alias: "old", workingDirectory: root.appendingPathComponent("old"))
            let old = try TerminalLaunchSession.create(command: ":", identifier: oldLease)
            try Data("exited 0\n".utf8).write(to: old.receiptURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: old.receiptURL.path)
            monitor.begin(old, lease: oldLease)
            try await monitor.waitFor(oldLease, expected: "uncertain")
            old.removeAfterExit()
            try expect(fm.fileExists(atPath: old.receiptURL.path), "legacy-kept")
            print("PASS: actual shell EXIT, owned process group, surviving child, production Store and monitor, legacy recovery")
        } catch {
            print("FAIL: \((error as NSError).domain)")
            exit(1)
        }
    }
}
