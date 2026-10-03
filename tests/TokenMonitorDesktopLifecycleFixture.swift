import AppKit
import Darwin
import Foundation

// The runner compiles the real controller with these isolated host dependencies.
struct TokenMonitorHostRequest: Sendable { let id: String }
struct TokenMonitorHostReply: Sendable {
    static func failure(_ id: String, _ code: String) -> Self { Self() }
}
final class TokenMonitorHostServer {
    init(path: String, handler: @escaping @MainActor @Sendable (TokenMonitorHostRequest) async -> TokenMonitorHostReply) throws {}
    func stop() {}
}
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL { FileManager.default.temporaryDirectory }
}
struct WidgetLanguage {
    let isChinese = false
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ chinese: String, _ english: String) -> String { english }
}

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum TokenMonitorDesktopLifecycleFixture {
    static func main() async {
        if ProcessInfo.processInfo.environment["AIGOODBRO_TOKEN_MONITOR_EMBEDDED"] == "1",
            ProcessInfo.processInfo.environment["AIGOODBRO_TEST_HELPER"] == "1"
        {
            runFakeHelper()
            return
        }
        do {
            try await testConcurrentOpenAndRecovery()
            try await testTerminateFallback()
            try await testRefusedExit()
            try await testFailedStartupDoesNotBlockMainActor()
            try await testShutdownDuringStartup()
            try await testShutdownDuringStatusReply()
            print("desktop_helper_lifecycle=passed cases=6")
        } catch {
            fputs("desktop_helper_lifecycle=failed \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func testConcurrentOpenAndRecovery() async throws {
        let test = try TestDirectory()
        defer { test.remove() }
        test.configure(mode: "normal", startupDelayMilliseconds: 350)
        let controller = test.controller()
        defer { controller.shutdown() }

        for _ in 0..<8 { controller.open(.dashboard) }
        try await waitFor("first helper ready") { controller.isReady && test.pids.count == 1 }
        try await waitFor("all first opens complete") { controller.lastError == nil }
        let old = try ownedProcess(controller)
        try require(test.pids.count == 1, "concurrent opens launched more than one helper")

        try String(old.processIdentifier).write(to: test.failedPIDFile, atomically: true, encoding: .utf8)
        controller.open(.dashboard)
        try await waitFor("disconnection observed") { !controller.isReady && controller.lastError != nil }
        for _ in 0..<8 { controller.open(.dashboard) }
        try await waitFor("recovered helper ready", timeout: 6) { controller.isReady && test.pids.count == 2 }
        let replacement = try ownedProcess(controller)
        try require(old !== replacement, "recovery reused the disconnected process")
        try require(!old.isRunning, "replacement launched before old helper exited")
        controller.processDidTerminate(old)
        try require(controller.isReady, "old termination callback cleared replacement readiness")
        let ownedAfterOldCallback = try ownedProcess(controller)
        try require(ownedAfterOldCallback === replacement, "old callback displaced the new helper")
        controller.open(.dashboard)
        try await waitFor("replacement route succeeds") { controller.lastError == nil }
        try require(test.pids.count == 2, "recovery burst launched duplicate helpers")

        controller.shutdown()
        controller.open(.dashboard)
        try await sleep(milliseconds: 250)
        try require(test.pids.count == 2, "open after shutdown relaunched the helper")
    }

    @MainActor
    private static func testRefusedExit() async throws {
        let test = try TestDirectory()
        defer { test.remove() }
        test.configure(mode: "ignore-exit")
        let controller = test.controller(graceSeconds: 0.2)
        defer { controller.shutdown() }
        controller.startIfBundled()
        try await waitFor("refusing helper ready") { controller.isReady && test.pids.count == 1 }
        let old = try ownedProcess(controller)
        try String(old.processIdentifier).write(to: test.failedPIDFile, atomically: true, encoding: .utf8)
        controller.open(.dashboard)
        try await waitFor("refusing helper disconnected") { !controller.isReady }
        controller.open(.dashboard)
        try await sleep(milliseconds: 900)
        try require(old.isRunning, "refusal case did not keep old helper alive")
        try require(test.pids.count == 1, "second helper launched while old helper refused exit")
        controller.open(.dashboard)
        try await sleep(milliseconds: 900)
        try require(test.pids.count == 1, "retry launched a second helper after exit refusal")
        Darwin.kill(old.processIdentifier, SIGKILL)
        try await waitFor("refusing helper killed for cleanup") { !old.isRunning }
    }

    @MainActor
    private static func testTerminateFallback() async throws {
        let test = try TestDirectory()
        defer { test.remove() }
        test.configure(mode: "ignore-quit")
        let controller = test.controller(graceSeconds: 0.2)
        defer { controller.shutdown() }
        controller.startIfBundled()
        try await waitFor("terminate fallback helper ready") { controller.isReady && test.pids.count == 1 }
        let old = try ownedProcess(controller)
        try String(old.processIdentifier).write(to: test.failedPIDFile, atomically: true, encoding: .utf8)
        controller.open(.dashboard)
        try await waitFor("terminate fallback disconnected") { !controller.isReady }
        controller.open(.dashboard)
        try await waitFor("terminate fallback recovered", timeout: 6) { controller.isReady && test.pids.count == 2 }
        try require(!old.isRunning, "new helper launched before terminated helper exited")
    }

    @MainActor
    private static func testFailedStartupDoesNotBlockMainActor() async throws {
        let test = try TestDirectory()
        defer { test.remove() }
        test.configure(mode: "never-ready")
        let graceSeconds = 0.4
        let controller = test.controller(startupAttempts: 3, graceSeconds: graceSeconds)
        defer { controller.shutdown() }
        var actorTicks: [TimeInterval] = []
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return }
                actorTicks.append(ProcessInfo.processInfo.systemUptime)
            }
        }
        defer { ticker.cancel() }
        controller.open(.dashboard)
        try await waitFor("failed startup completed", timeout: 5) { controller.lastError != nil }
        ticker.cancel()
        let child = try ownedProcess(controller)
        defer { if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) } }
        let cleanupStartText = try String(contentsOf: test.quitEnteredFile, encoding: .utf8)
        guard let cleanupStart = TimeInterval(cleanupStartText) else {
            throw FixtureFailure(description: "failed helper did not record cleanup entry")
        }
        // Observe the exit-wait phase itself. Startup ticks cannot prove cleanup
        // yields, and a fixed total tick count depends on runner scheduling.
        let cleanupTicks = actorTicks.filter {
            $0 >= cleanupStart + graceSeconds && $0 < cleanupStart + 2 * graceSeconds
        }
        try require(!cleanupTicks.isEmpty, "startup cleanup blocked the main actor (cleanup ticks=0, total ticks=\(actorTicks.count))")
        try require(test.pids.count == 1, "failed startup launched duplicate helpers")
        try require(child.isRunning, "failure fixture did not exercise refusal to exit")
        controller.open(.dashboard)
        try await sleep(milliseconds: 900)
        try require(test.pids.count == 1, "failed startup left an old helper and launched another")
        Darwin.kill(child.processIdentifier, SIGKILL)
        try await waitFor("failed helper killed for cleanup") { !child.isRunning }
    }

    @MainActor
    private static func testShutdownDuringStartup() async throws {
        let test = try TestDirectory()
        defer { test.remove() }
        test.configure(mode: "normal", startupDelayMilliseconds: 600)
        let controller = test.controller()
        controller.startIfBundled()
        try await waitFor("starting helper spawned") { test.pids.count == 1 }
        controller.shutdown()
        controller.open(.dashboard)
        try await sleep(milliseconds: 900)
        try require(test.pids.count == 1, "shutdown or cancelled startup relaunched the helper")
    }

    @MainActor
    private static func testShutdownDuringStatusReply() async throws {
        let test = try TestDirectory()
        defer { test.remove() }
        test.configure(mode: "delay-status")
        let controller = test.controller()
        controller.startIfBundled()
        try await waitFor("status request in flight") { FileManager.default.fileExists(atPath: test.statusEnteredFile.path) }
        controller.shutdown()
        try await sleep(milliseconds: 500)
        try require(!controller.isReady && !controller.hasVisibleTray, "late status reply restored readiness after shutdown")
        try require(test.pids.count == 1, "late status reply relaunched a helper")
        controller.open(.dashboard)
        try await sleep(milliseconds: 200)
        try require(!controller.isReady && test.pids.count == 1, "shutdown allowed a late open to restart")
    }

    @MainActor
    private static func waitFor(
        _ label: String,
        timeout: Double = 5,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await sleep(milliseconds: 25) }
        try require(condition(), "timed out: \(label)")
    }

    private static func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FixtureFailure(description: message) }
    }

    @MainActor
    private static func ownedProcess(_ controller: TokenMonitorDesktopController) throws -> Process {
        guard let process = Mirror(reflecting: controller).children.first(where: { $0.label == "process" })?.value as? Process
        else { throw FixtureFailure(description: "controller does not own a helper process") }
        return process
    }

    private static func runFakeHelper() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["AIGOODBRO_TOKEN_MONITOR_SOCKET"],
            let launchLog = environment["AIGOODBRO_TEST_LAUNCH_LOG"],
            let failedPIDFile = environment["AIGOODBRO_TEST_FAILED_PID_FILE"],
            let statusEnteredFile = environment["AIGOODBRO_TEST_STATUS_ENTERED_FILE"],
            let quitEnteredFile = environment["AIGOODBRO_TEST_QUIT_ENTERED_FILE"]
        else { exit(2) }
        let mode = environment["AIGOODBRO_TEST_MODE"] ?? "normal"
        let logDescriptor = Darwin.open(launchLog, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if logDescriptor >= 0 {
            let line = "\(getpid())\n"
            _ = line.withCString { Darwin.write(logDescriptor, $0, line.utf8.count) }
            Darwin.close(logDescriptor)
        }
        if mode == "ignore-exit" || mode == "never-ready" { signal(SIGTERM, SIG_IGN) }
        let startupDelay = UInt32(environment["AIGOODBRO_TEST_STARTUP_DELAY_MS"] ?? "0") ?? 0
        usleep(startupDelay * 1_000)

        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { exit(3) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { exit(4) }
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { continue }
            var received = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !received.contains(10), received.count < 4096 {
                let count = Darwin.recv(client, &buffer, buffer.count, 0)
                if count <= 0 { break }
                received.append(contentsOf: buffer.prefix(count))
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(received.prefix(while: { $0 != 10 })))) as? [String: Any]
            let id = object?["id"] as? String ?? ""
            let command = object?["cmd"] as? String ?? ""
            if mode == "delay-status", command == "status" {
                _ = FileManager.default.createFile(atPath: statusEnteredFile, contents: Data())
                usleep(220_000)
            }
            if mode == "never-ready", command == "quit" {
                try? String(ProcessInfo.processInfo.systemUptime).write(toFile: quitEnteredFile, atomically: true, encoding: .utf8)
            }
            let failedPID = (try? String(contentsOf: URL(fileURLWithPath: failedPIDFile), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let disconnected = failedPID == String(getpid())
            let refusingQuit = command == "quit" && (mode == "ignore-quit" || mode == "ignore-exit" || mode == "never-ready")
            let ok = !disconnected && !refusingQuit
            let ready = mode != "never-ready" && !disconnected
            let reply: [String: Any] = ["id": id, "ok": ok, "ready": ready, "trayVisible": true]
            if var data = try? JSONSerialization.data(withJSONObject: reply) {
                data.append(10)
                _ = data.withUnsafeBytes { Darwin.send(client, $0.baseAddress!, $0.count, 0) }
            }
            Darwin.close(client)
            if command == "quit", !refusingQuit { exit(0) }
        }
    }
}

private final class TestDirectory {
    let root: URL
    let launchLog: URL
    let failedPIDFile: URL
    let statusEnteredFile: URL
    let quitEnteredFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agb-helper-test-\(UUID().uuidString)", isDirectory: true)
        launchLog = root.appendingPathComponent("launches")
        failedPIDFile = root.appendingPathComponent("failed-pid")
        statusEnteredFile = root.appendingPathComponent("status-entered")
        quitEnteredFile = root.appendingPathComponent("quit-entered")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    var pids: [pid_t] {
        let content = (try? String(contentsOf: launchLog, encoding: .utf8)) ?? ""
        return content.split(separator: "\n").compactMap { pid_t($0) }
    }

    func configure(mode: String, startupDelayMilliseconds: Int = 0) {
        setenv("AIGOODBRO_TEST_HELPER", "1", 1)
        setenv("AIGOODBRO_TEST_MODE", mode, 1)
        setenv("AIGOODBRO_TEST_LAUNCH_LOG", launchLog.path, 1)
        setenv("AIGOODBRO_TEST_FAILED_PID_FILE", failedPIDFile.path, 1)
        setenv("AIGOODBRO_TEST_STATUS_ENTERED_FILE", statusEnteredFile.path, 1)
        setenv("AIGOODBRO_TEST_QUIT_ENTERED_FILE", quitEnteredFile.path, 1)
        setenv("AIGOODBRO_TEST_STARTUP_DELAY_MS", String(startupDelayMilliseconds), 1)
    }

    @MainActor
    func controller(startupAttempts: Int = 100, graceSeconds: Double = 1) -> TokenMonitorDesktopController {
        TokenMonitorDesktopController(
            executableOverride: URL(fileURLWithPath: CommandLine.arguments[0]),
            supportDirectoryOverride: root,
            startupAttempts: startupAttempts,
            childExitGraceSeconds: graceSeconds
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
