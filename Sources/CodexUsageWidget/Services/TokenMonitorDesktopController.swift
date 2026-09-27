import AppKit
import Darwin
import Foundation

/// Owns the bundled upstream desktop runtime. Its renderer, layouts and tools
/// remain upstream code; the native workspace only controls its lifecycle.
@MainActor
final class TokenMonitorDesktopController: ObservableObject {
    static let shared = TokenMonitorDesktopController()

    enum Route: String, CaseIterable {
        case home, tool, status, device, model, project, session, limits, trends
        case dashboard, settings

        var command: String {
            switch self {
            case .home: return "showHome"
            case .dashboard: return "showDashboard"
            case .settings: return "showSettings"
            default: return "showView"
            }
        }
    }

    @Published private(set) var isReady = false
    @Published private(set) var hasVisibleTray = false
    @Published private(set) var lastError: String?
    var hostAction: (@MainActor (TokenMonitorHostRequest) async -> TokenMonitorHostReply)?
    private var process: Process?
    private var hostServer: TokenMonitorHostServer?
    private var starting: Task<Void, Error>?
    private var statusPolling: Task<Void, Never>?
    private var socketDirectory: URL?
    private var socketPath: String?

    var isBundled: Bool { executableURL != nil }

    private var executableURL: URL? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AiGoodBro Token Core.app", isDirectory: true)
        guard let bundle = Bundle(url: helper), let executable = bundle.executableURL,
            executable.standardizedFileURL.path.hasPrefix(helper.standardizedFileURL.path + "/Contents/MacOS/"),
            FileManager.default.isExecutableFile(atPath: executable.path)
        else { return nil }
        return executable
    }

    func open(_ route: Route) {
        Task { await openAndWait(route) }
    }

    func startIfBundled() {
        guard isBundled else { return }
        Task {
            do { try await ensureStarted() } catch { recordFailure() }
        }
    }

    private func openAndWait(_ route: Route) async {
        do {
            try await ensureStarted()
            guard let socketPath else { throw DesktopError.unavailable }
            let request = DesktopRequest(cmd: route.command, view: route.command == "showView" ? route.rawValue : nil)
            let reply = try await Task.detached(priority: .userInitiated) {
                try DesktopSocket.request(request, path: socketPath)
            }.value
            guard reply.ok else { throw DesktopError.unavailable }
            lastError = nil
        } catch { recordFailure() }
    }

    private func ensureStarted() async throws {
        if isReady, process?.isRunning == true { return }
        if let starting { return try await starting.value }
        if process?.isRunning == true, let socketPath {
            let reply = try await Task.detached {
                try DesktopSocket.request(DesktopRequest(cmd: "status"), path: socketPath)
            }.value
            guard reply.ok, reply.ready == true else { throw DesktopError.unavailable }
            isReady = true
            hasVisibleTray = reply.trayVisible == true
            return
        }
        let task = Task { @MainActor in try await launchAndWait() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launchAndWait() async throws {
        guard let executableURL else { throw DesktopError.unavailable }
        let manager = FileManager.default
        cleanupSocketDirectory()
        let support = DispatchParticipationPaths.supportDirectory().appendingPathComponent("TokenMonitorDesktop", isDirectory: true)
        let shared = support.appendingPathComponent("shared", isDirectory: true)
        for directory in [support, shared] {
            var before = stat()
            if lstat(directory.path, &before) == 0 {
                guard before.st_mode & S_IFMT == S_IFDIR, before.st_uid == getuid() else { throw DesktopError.unavailable }
            } else if errno != ENOENT {
                throw DesktopError.unavailable
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var after = stat()
            guard lstat(directory.path, &after) == 0, after.st_mode & S_IFMT == S_IFDIR,
                after.st_uid == getuid()
            else { throw DesktopError.unavailable }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let ipc = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("agb-tm-\(getuid())-\(UUID().uuidString.prefix(12))", isDirectory: true)
        try manager.createDirectory(at: ipc, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = ipc.appendingPathComponent("control.sock").path
        guard path.utf8.count < 104 else { throw DesktopError.unavailable }
        socketDirectory = ipc
        socketPath = path
        let hostPath = ipc.appendingPathComponent("host.sock").path
        do {
            hostServer = try TokenMonitorHostServer(path: hostPath) { [weak self] request in
                guard let self, self.process?.isRunning == true, let action = self.hostAction else {
                    return .failure(request.id, "host-unavailable")
                }
                return await action(request)
            }
        } catch {
            cleanupSocketDirectory()
            throw DesktopError.unavailable
        }

        let idURL = support.appendingPathComponent("device-id")
        let existingID = try? String(contentsOf: idURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = existingID.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        if existingID != deviceID {
            try deviceID.write(to: idURL, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: idURL.path)
        }

        let child = Process()
        child.executableURL = executableURL
        var environment = ProcessInfo.processInfo.environment
        // Electron must not inherit a developer terminal's Node startup hooks.
        for key in ["NODE_OPTIONS", "NODE_PATH", "ELECTRON_RUN_AS_NODE"] { environment.removeValue(forKey: key) }
        environment["AIGOODBRO_TOKEN_MONITOR_EMBEDDED"] = "1"
        environment["AIGOODBRO_TOKEN_MONITOR_USER_DATA"] = support.path
        environment["AIGOODBRO_TOKEN_MONITOR_SOCKET"] = path
        environment["AIGOODBRO_TOKEN_MONITOR_HOST_SOCKET"] = hostPath
        environment["TOKEN_MONITOR_SHARED_DIR"] = shared.path
        environment["TOKEN_MONITOR_DEVICE_ID"] = "aigoodbro-" + deviceID.lowercased()
        environment["AIGOODBRO_TOKEN_MONITOR_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["AIGOODBRO_TOKEN_MONITOR_LANGUAGE"] = WidgetLanguage.storedOrAutomatic().isChinese ? "zh-CN" : "en"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            Task { @MainActor [weak self] in
                guard let self, self.process === child else { return }
                self.isReady = false
                self.hasVisibleTray = false
                self.statusPolling?.cancel()
                self.statusPolling = nil
                self.process = nil
                self.cleanupSocketDirectory()
                self.recordFailure()
            }
        }
        process = child
        do { try child.run() } catch {
            process = nil
            cleanupSocketDirectory()
            throw DesktopError.unavailable
        }

        for _ in 0..<100 {
            try Task.checkCancellation()
            guard child.isRunning else { throw DesktopError.unavailable }
            if manager.fileExists(atPath: path) {
                let response = try? await Task.detached {
                    try DesktopSocket.request(DesktopRequest(cmd: "status"), path: path, timeout: 0.3)
                }.value
                if response?.ok == true, response?.ready == true {
                    isReady = true
                    hasVisibleTray = response?.trayVisible == true
                    lastError = nil
                    startStatusPolling(path: path, child: child)
                    return
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        // Do not strand a second desktop runtime after an unsuccessful launch.
        shutdown()
        throw DesktopError.unavailable
    }

    func shutdown() {
        starting?.cancel()
        starting = nil
        statusPolling?.cancel()
        statusPolling = nil
        if let socketPath {
            _ = try? DesktopSocket.request(DesktopRequest(cmd: "quit"), path: socketPath, timeout: 0.4)
        }
        // Let upstream persist settings and stop collectors before terminating
        // an unresponsive child. Only the process owned by this host is touched.
        let deadline = Date().addingTimeInterval(2)
        while process?.isRunning == true, Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if let process, process.isRunning { process.terminate() }
        process = nil
        isReady = false
        hasVisibleTray = false
        cleanupSocketDirectory()
    }

    private func startStatusPolling(path: String, child: Process) {
        statusPolling?.cancel()
        statusPolling = Task { @MainActor [weak self] in
            var missed = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.process === child, child.isRunning else { return }
                let reply = try? await Task.detached {
                    try DesktopSocket.request(DesktopRequest(cmd: "status"), path: path, timeout: 1)
                }.value
                guard !Task.isCancelled else { return }
                if reply?.ok == true, reply?.ready == true {
                    missed = 0
                    self.isReady = true
                    self.hasVisibleTray = reply?.trayVisible == true
                } else {
                    missed += 1
                    if missed >= 3 {
                        self.isReady = false
                        self.hasVisibleTray = false
                    }
                }
            }
        }
    }

    private func cleanupSocketDirectory() {
        hostServer?.stop()
        hostServer = nil
        guard let directory = socketDirectory else { return }
        // Only this launch's randomly named, private IPC directory is owned here.
        try? FileManager.default.removeItem(at: directory)
        socketDirectory = nil
        socketPath = nil
    }

    private func recordFailure() {
        lastError = WidgetLanguage.storedOrAutomatic().text("无法打开用量界面，请重试。", "Unable to open usage. Please try again.")
    }
}

private enum DesktopError: Error { case unavailable, invalidReply }

private struct DesktopRequest: Encodable, Sendable {
    let id = UUID().uuidString
    let cmd: String
    var view: String? = nil
}

private struct DesktopReply: Decodable, Sendable {
    let id: String
    let ok: Bool
    let ready: Bool?
    let trayVisible: Bool?
}

private enum DesktopSocket {
    static func request(_ request: DesktopRequest, path: String, timeout: Double = 2) throws -> DesktopReply {
        guard path.utf8.count < 104 else { throw DesktopError.unavailable }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DesktopError.unavailable }
        defer { Darwin.close(descriptor) }
        var duration = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        withUnsafePointer(to: &duration) {
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: Array(path.utf8) + [0])
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw DesktopError.unavailable }
        var payload = try JSONEncoder().encode(request)
        payload.append(10)
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { throw DesktopError.unavailable }
                offset += sent
            }
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while received.count < 16_384 {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw DesktopError.unavailable }
            received.append(contentsOf: buffer.prefix(count))
            if let newline = received.firstIndex(of: 10) {
                let reply = try JSONDecoder().decode(DesktopReply.self, from: received.prefix(upTo: newline))
                guard reply.id == request.id else { throw DesktopError.invalidReply }
                return reply
            }
        }
        throw DesktopError.invalidReply
    }
}
