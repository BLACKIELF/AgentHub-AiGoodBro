import AppKit
import Darwin
import Foundation

/// Terminal commands contain only a signed app path and working directory.
/// The app reads its own local gateway key and passes it to the child process;
/// provider OAuth credentials never enter a command, script or client profile.
enum ProviderProxyClientLauncher {
    @MainActor static func launchCodex(provider: AntigravityProxyProvider, model: String, workingDirectory: URL) async throws {
        guard let executable = Bundle.main.executableURL,
            let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { throw TerminalLauncherError.launchFailed }
        let command = [executable.path, "--launch-provider-codex", provider.rawValue, model, workingDirectory.path]
            .map(TerminalAppLauncher.shellQuote).joined(separator: " ")
        let session = try TerminalLaunchSession.create(command: command)
        _ = try await NSWorkspace.shared.open([session.scriptURL], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func runCodex(provider: AntigravityProxyProvider, model: String, workingDirectory: URL) async -> Int32 {
        do {
            guard let executable = [CodexExecutable.bundledPath(), CodexExecutable.path()].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
                (try workingDirectory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                let data = try AntigravityProxyKeychain().read("client-key"), let key = String(data: data, encoding: .utf8), (32...256).contains(key.utf8.count)
            else { throw AntigravityProxyFailure.unavailable }
            let endpoint = "http://127.0.0.1:18081/providers/" + provider.rawValue
            guard try await catalog(endpoint: endpoint, key: key).contains(model) else { throw AntigravityProxyFailure.unavailable }
            let profile = DispatchParticipationPaths.supportDirectory().appendingPathComponent("proxy-clients/codex-" + provider.rawValue, isDirectory: true)
            try preparePrivateDirectory(profile)
            let home = FileManager.default.homeDirectoryForCurrentUser
            let child = Process()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = ["-m", model, "-c", "model_provider=\"aigoodbro_local\"", "-c",
                "model_providers.aigoodbro_local={name=\"AiGoodBro\",base_url=\"\(endpoint)/v1\",env_key=\"AIGOODBRO_PROXY_KEY\",wire_api=\"responses\",requires_openai_auth=false,supports_websockets=false}",
                "-c", "features.enable_request_compression=false"]
            child.environment = ["HOME": home.path, "CODEX_HOME": profile.path, "AIGOODBRO_PROXY_KEY": key,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + home.appendingPathComponent(".local/bin").path,
                "LANG": "en_US.UTF-8", "TERM": ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"]
            child.currentDirectoryURL = workingDirectory
            child.standardInput = FileHandle.standardInput; child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
            try child.run(); child.waitUntilExit()
            return child.terminationStatus
        } catch {
            print("AiGoodBro: unable to connect Codex CLI. Verify the selected provider pool and model first.")
            return 1
        }
    }
    @MainActor static func launchNative(provider: AntigravityProxyProvider, model: String, workingDirectory: URL) async throws {
        guard provider != .antigravity, let executable = Bundle.main.executableURL,
            let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { throw TerminalLauncherError.launchFailed }
        let command = [executable.path, "--launch-provider-native", provider.rawValue, model, workingDirectory.path]
            .map(TerminalAppLauncher.shellQuote).joined(separator: " ")
        let session = try TerminalLaunchSession.create(command: command)
        _ = try await NSWorkspace.shared.open([session.scriptURL], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func runNative(provider: AntigravityProxyProvider, model: String, workingDirectory: URL) async -> Int32 {
        do {
            let name: String
            switch provider {
            case .claude: name = "claude"
            case .kimi: name = "kimi"
            case .xai: name = "grok"
            case .antigravity: throw AntigravityProxyFailure.unavailable
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let candidates = [home.appendingPathComponent(".local/bin/" + name), home.appendingPathComponent(".grok/bin/" + name), URL(fileURLWithPath: "/opt/homebrew/bin/" + name), URL(fileURLWithPath: "/usr/local/bin/" + name)]
            guard let executable = candidates.map({ $0.resolvingSymlinksInPath() }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
                (try workingDirectory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                let data = try AntigravityProxyKeychain().read("client-key"), let key = String(data: data, encoding: .utf8), (32...256).contains(key.utf8.count)
            else { throw AntigravityProxyFailure.unavailable }
            let endpoint = "http://127.0.0.1:18081/providers/" + provider.rawValue
            guard try await catalog(endpoint: endpoint, key: key).contains(model) else { throw AntigravityProxyFailure.unavailable }
            let profile = DispatchParticipationPaths.supportDirectory().appendingPathComponent("proxy-clients/native-" + provider.rawValue, isDirectory: true)
            try preparePrivateDirectory(profile)
            var environment = ["HOME": home.path,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + home.appendingPathComponent(".local/bin").path,
                "LANG": "en_US.UTF-8", "TERM": ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"]
            var arguments: [String] = []
            switch provider {
            case .claude:
                environment.merge(["CLAUDE_CONFIG_DIR": profile.path, "ANTHROPIC_BASE_URL": endpoint,
                    "ANTHROPIC_AUTH_TOKEN": key, "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1", "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST": "1"], uniquingKeysWith: { _, new in new })
                arguments = ["--model", model]
            case .kimi:
                environment.merge(["KIMI_CODE_HOME": profile.path, "KIMI_MODEL_NAME": model,
                    "KIMI_MODEL_API_KEY": key, "KIMI_MODEL_PROVIDER_TYPE": "kimi", "KIMI_MODEL_BASE_URL": endpoint + "/v1"], uniquingKeysWith: { _, new in new })
            case .xai:
                let config: [String: Any] = ["models": ["default": model], "model": [model: [
                    "model": model, "base_url": endpoint + "/v1", "env_key": "AIGOODBRO_PROXY_KEY", "api_backend": "responses"]]]
                environment.merge(["GROK_HOME": profile.path, "GROK_AUTH_PATH": profile.appendingPathComponent("auth.json").path,
                    "GROK_CONFIG": String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self),
                    "AIGOODBRO_PROXY_KEY": key], uniquingKeysWith: { _, new in new })
                arguments = ["--model", model]
            case .antigravity: throw AntigravityProxyFailure.unavailable
            }
            let child = Process()
            child.executableURL = executable; child.arguments = arguments
            child.environment = environment; child.currentDirectoryURL = workingDirectory
            child.standardInput = FileHandle.standardInput; child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
            try child.run(); child.waitUntilExit()
            return child.terminationStatus
        } catch {
            print("AiGoodBro: unable to connect the official CLI. Verify its installation, authorized pool and selected model.")
            return 1
        }
    }

    @MainActor static func launchAgy(workingDirectory: URL) async throws {
        guard let executable = Bundle.main.executableURL,
            let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal"),
            workingDirectory.isFileURL, (try workingDirectory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        else { throw TerminalLauncherError.launchFailed }
        let command = [executable.path, "--launch-agy-proxy", workingDirectory.path].map(TerminalAppLauncher.shellQuote).joined(separator: " ")
        let session = try TerminalLaunchSession.create(command: command)
        _ = try await NSWorkspace.shared.open([session.scriptURL], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func runAgy(workingDirectory: URL) async -> Int32 {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let candidates = [home.appendingPathComponent(".local/bin/agy"), URL(fileURLWithPath: "/opt/homebrew/bin/agy"), URL(fileURLWithPath: "/usr/local/bin/agy")]
            guard let executable = candidates.map({ $0.resolvingSymlinksInPath() }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
                workingDirectory.path.hasPrefix("/"), (try workingDirectory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                let data = try AntigravityProxyKeychain().read("client-key"), let key = String(data: data, encoding: .utf8),
                (32...256).contains(key.utf8.count)
            else { throw AntigravityProxyFailure.unavailable }
            let endpoint = "http://127.0.0.1:18081/providers/antigravity"
            let models = try await catalog(endpoint: endpoint, key: key)
            guard models.contains(where: { $0.hasPrefix("gemini-") }) else { throw AntigravityProxyFailure.unavailable }
            let profile = DispatchParticipationPaths.supportDirectory().appendingPathComponent("proxy-clients/antigravity", isDirectory: true)
            try prepareAgyProfile(profile)
            var environment = [
                "HOME": home.path, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + home.appendingPathComponent(".local/bin").path,
                "LANG": "en_US.UTF-8", "TERM": ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color",
                "GEMINI_API_KEY": key, "GOOGLE_GEMINI_BASE_URL": endpoint,
            ]
            for name in ["TMPDIR", "SSH_AUTH_SOCK"] {
                if let value = ProcessInfo.processInfo.environment[name] { environment[name] = value }
            }
            let child = Process()
            child.executableURL = executable
            child.arguments = ["--gemini_dir=" + profile.path]
            child.currentDirectoryURL = workingDirectory
            child.environment = environment
            child.standardInput = FileHandle.standardInput
            child.standardOutput = FileHandle.standardOutput
            child.standardError = FileHandle.standardError
            if !models.contains("gemini-3.1-flash-lite-preview") {
                print("AiGoodBro: the pool has not confirmed agy's auxiliary flash-lite model; features that require it may be unavailable.")
            }
            try child.run()
            child.waitUntilExit()
            return child.terminationStatus
        } catch {
            print("AiGoodBro: unable to connect agy. Start the authorized Antigravity pool, verify available models, and confirm agy is installed.")
            return 1
        }
    }

    static func catalog(endpoint: String, key: String) async throws -> [String] {
        guard let url = URL(string: endpoint + "/v1/models"), url.scheme == "http", url.host == "127.0.0.1", url.port == 18081,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            AntigravityProxyProvider.allCases.contains(where: { url.path == "/providers/" + $0.rawValue + "/v1/models" })
        else { throw AntigravityProxyFailure.connection }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let response = try await TokenMonitorURLSessionTransport(configuration: configuration).send(request, maximumResponseBytes: 262144)
        guard response.statusCode == 200,
            let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any], object["object"] as? String == "list",
            let rows = object["data"] as? [[String: Any]], rows.count <= 512
        else { throw AntigravityProxyFailure.connection }
        let models = rows.compactMap { $0["id"] as? String }
        guard models.count == rows.count, models.allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil }) else {
            throw AntigravityProxyFailure.connection
        }
        return models
    }

    static func prepareAgyProfile(_ directory: URL) throws {
        let fm = FileManager.default
        try preparePrivateDirectory(directory)
        let settingsDirectory = directory.appendingPathComponent("antigravity-cli", isDirectory: true)
        try fm.createDirectory(at: settingsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for candidate in [directory.deletingLastPathComponent(), directory, settingsDirectory] {
            var info = stat()
            guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == geteuid(), info.st_mode & 0o077 == 0
            else { throw AntigravityProxyFailure.storage }
        }
        let file = settingsDirectory.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try DispatchParticipationSync.readBoundedRegularFile(file, maximumBytes: 65536, allowMissing: true) {
            guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AntigravityProxyFailure.storage }
            settings = saved
        }
        settings["modelProvider"] = "gemini"
        try DispatchParticipationSync.writePrivateProxyPreferences(JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), at: file)
    }

    static func preparePrivateDirectory(_ directory: URL) throws {
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw AntigravityProxyFailure.storage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for candidate in [directory.deletingLastPathComponent(), directory] {
            var info = stat()
            guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw AntigravityProxyFailure.storage }
        }
    }
}
