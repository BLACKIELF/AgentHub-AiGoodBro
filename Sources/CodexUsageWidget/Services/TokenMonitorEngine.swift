import Darwin
import Foundation

final class TokenMonitorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Blocking supervision: call only from an existing utility queue, never MainActor.
struct TokenMonitorEngine: Sendable {
    static let maximumInputBytes = 1_048_576
    static let maximumOutputBytes = 16_777_216
    static let maximumErrorBytes = 65_536
    struct Fixture: Sendable {
        let executable: URL
        let bridge: URL
        var electronNode = false
    }
    private struct SharedRuntime: Decodable {
        let schemaVersion: Int
        let mode: String
        let executable: String
        let runAsNodeFuse: Bool
    }
    private static let sharedExecutable = "Contents/Helpers/AiGoodBro Token Core.app/Contents/MacOS/AiGoodBro Token Core"
    private let fixture: Fixture?
    init(fixture: Fixture? = nil) { self.fixture = fixture }

    func collect(request: TokenMonitorRequest, cancellation: TokenMonitorCancellation) throws -> TokenMonitorResponse {
        guard !Thread.isMainThread else { throw TokenMonitorFailure.invalidRequest }
        guard !cancellation.isCancelled else { throw TokenMonitorFailure.cancelled }
        let request = try request.validated()
        let input = try JSONEncoder().encode(request)
        guard input.count <= Self.maximumInputBytes else { throw TokenMonitorFailure.inputTooLarge }
        let runtime: URL
        let bridge: URL
        var electronNode = false
        if let fixture {
            runtime = fixture.executable
            bridge = fixture.bridge
            electronNode = fixture.electronNode
        } else {
            guard let resources = Bundle.main.resourceURL else { throw TokenMonitorFailure.missingBundle }
            let root = resources.appendingPathComponent("TokenMonitorEngine", isDirectory: true)
            let descriptor = root.appendingPathComponent("RUNTIME.json")
            if FileManager.default.fileExists(atPath: descriptor.path) {
                guard let data = try? Data(contentsOf: descriptor), data.count <= 16_384,
                    let shared = try? JSONDecoder().decode(SharedRuntime.self, from: data),
                    shared.schemaVersion == 1, shared.mode == "shared-electron-node",
                    shared.executable == Self.sharedExecutable, shared.runAsNodeFuse
                else { throw TokenMonitorFailure.missingBundle }
                let bundleRoot = resources.deletingLastPathComponent().deletingLastPathComponent()
                let candidate = bundleRoot.appendingPathComponent(Self.sharedExecutable)
                guard candidate.resolvingSymlinksInPath().path.hasPrefix(bundleRoot.resolvingSymlinksInPath().path + "/")
                else { throw TokenMonitorFailure.missingBundle }
                runtime = candidate
                electronNode = true
            } else {
                runtime = root.appendingPathComponent("runtime/node")
            }
            bridge = root.appendingPathComponent("bridge.cjs")
        }
        guard FileManager.default.isExecutableFile(atPath: runtime.path),
            FileManager.default.fileExists(atPath: bridge.path)
        else { throw TokenMonitorFailure.missingBundle }
        // Isolated HOME prevents os.homedir()/implicit provider defaults finding developer data.
        let scratch = URL(fileURLWithPath: request.cacheDirectory, isDirectory: true)
            .appendingPathComponent("native-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch {
            throw TokenMonitorFailure.spawnFailed
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        var environment = [
            "HOME": scratch.path, "TMPDIR": scratch.path, "LANG": "en_US.UTF-8", "TZ": request.timezone,
            "PATH": runtime.deletingLastPathComponent().path,
        ]
        // Build-selected mode only. Caller/global ELECTRON_RUN_AS_NODE and NODE_OPTIONS never enter.
        if electronNode { environment["ELECTRON_RUN_AS_NODE"] = "1" }
        let output = try Self.run(
            executable: runtime, arguments: [bridge.path], environment: environment,
            input: input, timeoutMs: request.options.timeoutMs, cancellation: cancellation)
        guard !cancellation.isCancelled else { throw TokenMonitorFailure.cancelled }
        return try TokenMonitorResponse.decode(output, request: request)
    }

    private static func run(
        executable: URL, arguments: [String], environment: [String: String], input: Data,
        timeoutMs: Int, cancellation: TokenMonitorCancellation
    ) throws -> Data {
        var descriptors: [Int32] = []
        defer { descriptors.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) } }
        // Socket input supports per-descriptor SIGPIPE suppression without changing host signal policy.
        var socket: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &socket) == 0 else { throw TokenMonitorFailure.spawnFailed }
        descriptors += socket
        for _ in 0..<2 {
            var pipe: [Int32] = [0, 0]
            guard Darwin.pipe(&pipe) == 0 else { throw TokenMonitorFailure.spawnFailed }
            descriptors += pipe
        }
        for fd in descriptors {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw TokenMonitorFailure.spawnFailed }
        }
        var noSignal: Int32 = 1
        guard setsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw TokenMonitorFailure.spawnFailed }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw TokenMonitorFailure.spawnFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw TokenMonitorFailure.spawnFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        for (fd, target) in [(descriptors[1], STDIN_FILENO), (descriptors[3], STDOUT_FILENO), (descriptors[5], STDERR_FILENO)] {
            guard posix_spawn_file_actions_adddup2(&actions, fd, target) == 0 else { throw TokenMonitorFailure.spawnFailed }
        }
        guard let scratch = environment["HOME"],
            posix_spawn_file_actions_addchdir_np(&actions, scratch) == 0
        else { throw TokenMonitorFailure.spawnFailed }
        for fd in descriptors { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw TokenMonitorFailure.spawnFailed } }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else { throw TokenMonitorFailure.spawnFailed }
        let args = [executable.path] + arguments
        let env = environment.map { "\($0.key)=\($0.value)" }
        guard (args + env).allSatisfy({ !$0.contains("\0") }) else { throw TokenMonitorFailure.invalidRequest }
        var argv = args.map { strdup($0) } + [nil]
        var envp = env.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { if let p = $0 { free(p) } } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw TokenMonitorFailure.spawnFailed }
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { a in
            envp.withUnsafeMutableBufferPointer { e in
                posix_spawn(&pid, executable.path, &actions, &attributes, a.baseAddress!, e.baseAddress!)
            }
        }
        guard result == 0 else { throw TokenMonitorFailure.spawnFailed }
        for index in [1, 3, 5] {
            Darwin.close(descriptors[index])
            descriptors[index] = -1
        }
        var reaped = false
        var status: Int32 = -1
        func groupExists() -> Bool {
            if kill(-pid, 0) == 0 { return true }
            return errno != ESRCH
        }
        func reap() {
            guard !reaped else { return }
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid {
                reaped = true
            } else if r < 0 && errno != EINTR {
                reaped = true
                status = -1
            }
        }
        func cleanup() -> Bool {
            _ = kill(-pid, SIGTERM)
            for signal in [SIGTERM, SIGKILL] {
                _ = kill(-pid, signal)
                let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
                repeat {
                    reap()
                    if reaped && !groupExists() { return status != -1 }
                    Thread.sleep(forTimeInterval: 0.005)
                } while DispatchTime.now().uptimeNanoseconds < deadline
            }
            return false
        }
        do {
            for index in [0, 2, 4] {
                let flags = fcntl(descriptors[index], F_GETFL)
                guard flags >= 0, fcntl(descriptors[index], F_SETFL, flags | O_NONBLOCK) == 0 else { throw TokenMonitorFailure.processFailed }
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
            var offset = 0
            var output = Data()
            var errorBytes = 0
            var stdoutEOF = false
            var stderrEOF = false
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                guard !cancellation.isCancelled else { throw TokenMonitorFailure.cancelled }
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw TokenMonitorFailure.timedOut }
                var progressed = false
                if descriptors[0] >= 0 {
                    if offset < input.count {
                        let n = input.withUnsafeBytes { Darwin.write(descriptors[0], $0.baseAddress!.advanced(by: offset), min(16_384, input.count - offset)) }
                        if n > 0 {
                            offset += n
                            progressed = true
                        } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                            throw TokenMonitorFailure.processFailed
                        }
                    }
                    if offset == input.count {
                        Darwin.close(descriptors[0])
                        descriptors[0] = -1
                    }
                }
                // One bounded chunk per stream per turn prevents a busy stream starving the deadline.
                for index in [2, 4] {
                    if (index == 2 && stdoutEOF) || (index == 4 && stderrEOF) { continue }
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(descriptors[index], $0.baseAddress, $0.count) }
                    if n > 0 {
                        progressed = true
                        if index == 2 {
                            guard n <= maximumOutputBytes - output.count else { throw TokenMonitorFailure.outputTooLarge }
                            buffer.withUnsafeBufferPointer { output.append($0.baseAddress!, count: n) }
                        } else {
                            guard n <= maximumErrorBytes - errorBytes else { throw TokenMonitorFailure.outputTooLarge }
                            errorBytes += n  // Never retain or log untrusted stderr.
                        }
                    } else if n == 0 {
                        if index == 2 { stdoutEOF = true } else { stderrEOF = true }
                    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        throw TokenMonitorFailure.processFailed
                    }
                }
                reap()
                if reaped && stdoutEOF && stderrEOF {
                    guard status == 0, offset == input.count else { throw TokenMonitorFailure.processFailed }
                    guard !groupExists() else { throw TokenMonitorFailure.processFailed }
                    return output
                }
                if !progressed { Thread.sleep(forTimeInterval: 0.001) }
            }
        } catch {
            guard cleanup() else { throw TokenMonitorFailure.cleanupUnknown }
            throw error
        }
    }
}
