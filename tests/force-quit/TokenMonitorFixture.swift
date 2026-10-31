import AppKit
import Darwin
import Foundation

struct WidgetLanguage {
    let isChinese = false
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ zh: String, _ en: String) -> String { en }
}
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["FORCE_QUIT_FIXTURE_ROOT"]!) }
}
struct TokenMonitorHostRequest: Sendable { let id: String }
struct TokenMonitorHostReply: Sendable {
    static func failure(_ id: String, _ reason: String) -> Self { Self() }
}
final class TokenMonitorHostServer {
    init(path: String, handler: @escaping @MainActor @Sendable (TokenMonitorHostRequest) async -> TokenMonitorHostReply) throws {}
    func stop() {}
}
enum TokenMonitorEngine { static let maximumOutputBytes = 32 * 1024 * 1024 }

enum FixtureError: Error { case failure(String) }
@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureError.failure(message) }
}
@MainActor func wait(_ condition: () -> Bool, seconds: Double = 5) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try require(condition(), "timed out waiting for owned synthetic helper")
}
@MainActor func ownedChild(_ controller: TokenMonitorDesktopController) -> Process? {
    Mirror(reflecting: controller).children.first { $0.label == "process" }?.value as? Process
}
@MainActor func launchCount(_ log: URL) -> Int {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix("launch:") }.count
}

@main enum Fixture {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FORCE_QUIT_FIXTURE_ROOT"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("fixture-helper.py")
        let log = root.appendingPathComponent("fixture-events.log")
        let script = """
            #!/usr/bin/python3
            import json, os, socket, time
            def record(text):
                with open(os.environ['FORCE_QUIT_FIXTURE_LOG'], 'a') as out:
                    out.write(text + '\\n'); out.flush()
            record('launch:' + os.environ['FORCE_QUIT_FIXTURE_MODE'])
            if os.environ['FORCE_QUIT_FIXTURE_MODE'] == 'slow': time.sleep(20)
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(os.environ['AIGOODBRO_TOKEN_MONITOR_SOCKET'])
            os.chmod(os.environ['AIGOODBRO_TOKEN_MONITOR_SOCKET'], 0o600)
            server.listen(4)
            while True:
                connection, _ = server.accept()
                with connection:
                    data = b''
                    while b'\\n' not in data:
                        chunk = connection.recv(4096)
                        if not chunk: break
                        data += chunk
                    request = json.loads(data.split(b'\\n')[0])
                    record('command:' + request['cmd'])
                    if request['cmd'] == 'quit':
                        # A slow-drip peer could keep a per-read timeout alive.
                        while True: connection.sendall(b'x'); time.sleep(0.1)
                    reply = {'id': request['id'], 'ok': True, 'ready': True, 'trayVisible': False}
                    connection.sendall((json.dumps(reply) + '\\n').encode())
            """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        setenv("FORCE_QUIT_FIXTURE_LOG", log.path, 1)
        let sentinel = Process(); sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep"); sentinel.arguments = ["30"]
        try sentinel.run()
        defer { if sentinel.isRunning { sentinel.terminate() } }

        setenv("FORCE_QUIT_FIXTURE_MODE", "never", 1)
        let never = TokenMonitorDesktopController(executableOverride: helper, supportDirectoryOverride: root.appendingPathComponent("never"))
        never.forceStopForConfirmedTermination()
        never.forceStopForConfirmedTermination()
        never.startIfBundled(); never.open(.home)
        try await Task.sleep(nanoseconds: 400_000_000)
        try require(launchCount(log) == 0 && ownedChild(never) == nil && sentinel.isRunning, "never-started controller or unrelated child")
        print("PASS no child: confirmation cannot launch a helper or touch another child")

        setenv("FORCE_QUIT_FIXTURE_MODE", "slow", 1)
        let starting = TokenMonitorDesktopController(executableOverride: helper, supportDirectoryOverride: root.appendingPathComponent("starting"))
        starting.startIfBundled()
        try await wait { launchCount(log) == 1 && ownedChild(starting) != nil }
        guard let first = ownedChild(starting) else { throw FixtureError.failure("missing starting child") }
        starting.forceStopForConfirmedTermination()
        starting.forceStopForConfirmedTermination()
        starting.open(.home); starting.startIfBundled()
        try await wait({ !first.isRunning }, seconds: 3)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try require(launchCount(log) == 1 && !starting.isReady && sentinel.isRunning, "cancelled starting callback revived helper")
        print("PASS starting child exits and late callbacks cannot launch a replacement")

        setenv("FORCE_QUIT_FIXTURE_MODE", "ready", 1)
        let ready = TokenMonitorDesktopController(executableOverride: helper, supportDirectoryOverride: root.appendingPathComponent("ready"))
        ready.startIfBundled()
        try await wait { ready.isReady && launchCount(log) == 2 }
        guard let second = ownedChild(ready) else { throw FixtureError.failure("missing ready child") }
        let before = ProcessInfo.processInfo.systemUptime
        ready.forceStopForConfirmedTermination()
        try require(ProcessInfo.processInfo.systemUptime - before < 0.3, "force stop blocked on helper socket")
        try await wait({ !second.isRunning }, seconds: 3)
        let eventText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try require(!eventText.contains("command:quit") && sentinel.isRunning, "force stop contacted socket or touched unrelated child")
        ready.open(.home); ready.startIfBundled()
        try await Task.sleep(nanoseconds: 400_000_000)
        try require(launchCount(log) == 2 && !second.isRunning && sentinel.isRunning, "late ready callback relaunched helper")
        print("PASS ready child is killed without socket I/O; unrelated child stays alive")
        if sentinel.isRunning { sentinel.terminate() }
        await Task.detached { sentinel.waitUntilExit() }.value
    }
}
