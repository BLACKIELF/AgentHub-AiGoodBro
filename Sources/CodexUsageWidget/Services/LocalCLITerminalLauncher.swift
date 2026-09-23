import AppKit
import Darwin
import Foundation

/// Opens an installed, provider-owned CLI in Terminal.
///
/// Authentication remains in the provider's own CLI/browser. The command only
/// carries a profile directory and fixed, public launcher arguments; it never
/// reads or copies a credential file.
enum LocalCLITerminalLauncher {
    enum Action: Equatable { case signIn, open }
    enum Failure: Error { case unsupported, invalidDirectory, executableMissing, timedOut }

    private struct OpenCodeXDGPaths {
        let configHome: URL
        let dataHome: URL
        let stateHome: URL
        let cacheHome: URL
    }

    private struct WorkBuddyBundle {
        let cli: URL
        let electron: URL
        let productConfig: URL
        let configDirectory: URL
        let edition: WorkBuddyEdition
    }

    /// Build the exact command that will be written to the private Terminal
    /// wrapper. This method is intentionally side-effect free and is the seam
    /// used by offline launcher tests.
    static func command(
        profile: LocalCLIProfile,
        executable: String,
        action: Action,
        workingDirectory: URL
    ) throws -> String {
        let profileDirectory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
        guard lexicallyValidInput(profile.configDirectory), validDirectory(profileDirectory),
            validDirectory(workingDirectory)
        else {
            throw Failure.invalidDirectory
        }

        switch profile.kind {
        case .claudeCode, .gemini:
            guard profile.isDefault,
                profile.id == "local-" + profile.kind.rawValue,
                profileDirectory.lastPathComponent == (profile.kind == .claudeCode ? ".claude" : ".gemini")
            else { throw Failure.unsupported }
            guard lexicallyValidInput(executable), validExecutable(URL(fileURLWithPath: executable)) else {
                throw executableFailure(for: executable)
            }
            if profile.kind == .claudeCode {
                return shellCommand(
                    workingDirectory: workingDirectory,
                    executableParts: [executable] + (action == .signIn ? ["auth", "login"] : []),
                    unsetEnvironment: [
                        "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
                        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                        "CLAUDE_CODE_USE_MANTLE", "DISABLE_LOGIN_COMMAND",
                    ],
                    environment: ["CLAUDE_CONFIG_DIR": profileDirectory.path, "DISABLE_AUTOUPDATER": "1"])
            }
            // Gemini uses its interactive authentication selector. A positional
            // "login" would instead become a model prompt.
            return shellCommand(
                workingDirectory: workingDirectory, executableParts: [executable],
                unsetEnvironment: [
                    "GEMINI_CLI_HOME", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS",
                    "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION",
                    "GOOGLE_GEMINI_BASE_URL", "GEMINI_API_KEY_AUTH_HEADER",
                ], environment: [:])

        case .kimi:
            guard lexicallyValidInput(executable), validExecutable(URL(fileURLWithPath: executable)) else {
                throw executableFailure(for: executable)
            }
            return shellCommand(
                workingDirectory: workingDirectory,
                executableParts: [executable] + (action == .signIn ? ["login"] : []),
                unsetEnvironment: [
                    "KIMI_CODE_HOME", "KIMI_SHARE_DIR", "KIMI_API_KEY", "KIMI_CODE_API_KEY", "KIMI_BASE_URL",
                    "OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL",
                ],
                // New Kimi Code and the older Python CLI use different names.
                // Both are explicitly bound to the directory the card reads.
                environment: [
                    "KIMI_CODE_HOME": profileDirectory.path, "KIMI_SHARE_DIR": profileDirectory.path,
                    "KIMI_CLI_NO_AUTO_UPDATE": "1",
                ])

        case .grok:
            guard lexicallyValidInput(executable), validExecutable(URL(fileURLWithPath: executable)) else {
                throw executableFailure(for: executable)
            }
            let arguments = action == .signIn ? ["login", "--oauth"] : []
            return shellCommand(
                workingDirectory: workingDirectory,
                executableParts: [executable] + arguments,
                unsetEnvironment: [
                    "GROK_HOME", "GROK_AUTH_PATH", "XAI_API_KEY", "GROK_API_KEY", "GROK_OAUTH_TOKEN",
                ],
                environment: [
                    "GROK_HOME": profileDirectory.path,
                    "GROK_AUTH_PATH": profileDirectory.appendingPathComponent("auth.json").path,
                    "GROK_DISABLE_AUTOUPDATER": "1",
                ])

        case .openCode:
            guard lexicallyValidInput(executable), validExecutable(URL(fileURLWithPath: executable)) else {
                throw executableFailure(for: executable)
            }
            let paths = try openCodeXDGPaths(for: profileDirectory)
            let arguments = action == .signIn ? ["auth", "login"] : []
            return shellCommand(
                workingDirectory: workingDirectory,
                executableParts: [executable] + arguments,
                unsetEnvironment: [
                    "ANTHROPIC_API_KEY", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                    "AZURE_OPENAI_API_KEY", "COHERE_API_KEY", "DASHSCOPE_API_KEY", "DEEPSEEK_API_KEY", "GEMINI_API_KEY",
                    "GOOGLE_GENERATIVE_AI_API_KEY", "GROQ_API_KEY", "MISTRAL_API_KEY", "OPENAI_API_KEY",
                    "OPENROUTER_API_KEY", "XAI_API_KEY",
                    "OPENCODE_AUTH_JSON", "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG_CONTENT", "OPENCODE_TUI_CONFIG",
                    "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR",
                ],
                environment: [
                    // OpenCode stores provider credentials at
                    // $XDG_DATA_HOME/opencode/auth.json. Keep this profile's
                    // provider list separate from the default account.
                    "XDG_CONFIG_HOME": paths.configHome.path,
                    "XDG_DATA_HOME": paths.dataHome.path,
                    "XDG_STATE_HOME": paths.stateHome.path,
                    "XDG_CACHE_HOME": paths.cacheHome.path,
                ])

        case .workBuddy:
            let bundle = try workBuddyBundle(for: executable, profileDirectory: profileDirectory)
            return shellCommand(
                workingDirectory: workingDirectory,
                // The bundled 2.137.1 documentation exposes login as the
                // interactive /login command. A positional "login" could be
                // treated as a model prompt, so both actions open the TUI and
                // the sign-in guidance tells the user to choose /login.
                executableParts: [bundle.electron.path, bundle.cli.path],
                unsetEnvironment: [
                    "ACC_PRODUCT_CONFIG", "ACC_PRODUCT_CONFIG_PATH", "ACC_PRODUCT_CONFIG_V2", "ACC_PRODUCT_CONFIG_V3",
                    "CODEBUDDY_CONFIG_DIR", "WORKBUDDY_CONFIG_DIR", "CODEBUDDY_API_KEY", "CODEBUDDY_AUTH_TOKEN",
                    "ELECTRON_RUN_AS_NODE",
                ],
                environment: [
                    "ELECTRON_RUN_AS_NODE": "1",
                    "ACC_PRODUCT_CONFIG_PATH": bundle.productConfig.path,
                    "CODEBUDDY_CONFIG_DIR": bundle.configDirectory.path,
                    "WORKBUDDY_CONFIG_DIR": bundle.configDirectory.path,
                    "WORKBUDDY_DATA_FOLDER_NAME": bundle.edition.directoryName,
                    "DISABLE_AUTOUPDATER": "1",
                ])

        case .zcode:
            // ZCode is a desktop product; never run its private bundled script.
            throw Failure.unsupported

        case .trae, .mimo, .antigravity:
            throw Failure.unsupported
        }
    }

    @MainActor
    static func launch(
        profile: LocalCLIProfile,
        executable: String,
        action: Action,
        workingDirectory: URL
    ) async throws -> TerminalLaunchSession {
        let command = try command(profile: profile, executable: executable, action: action, workingDirectory: workingDirectory)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw TerminalLauncherError.terminalMissing
        }
        let session = try TerminalLaunchSession.create(command: command)
        do {
            _ = try await NSWorkspace.shared.open(
                [session.scriptURL],
                withApplicationAt: terminal,
                configuration: NSWorkspace.OpenConfiguration())
        } catch {
            // Launch Services may have delivered the script before reporting
            // an error. Keep the receipt so the caller can reconcile it.
            throw TerminalLaunchDeliveryError(session: session)
        }
        return session
    }

    static func waitForExit(_ session: TerminalLaunchSession, timeout: TimeInterval = 600) async throws -> Int32 {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if case .exited(let code) = try session.readState(), session.verifiedExitCode() == code {
                session.removeAfterExit()
                return code
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // Leave both the user-owned terminal and receipt in place on uncertainty.
        throw Failure.timedOut
    }

    private static func shellCommand(
        workingDirectory: URL,
        executableParts: [String],
        unsetEnvironment: [String],
        environment: [String: String]
    ) -> String {
        let quote = TerminalAppLauncher.shellQuote
        let unset = unsetEnvironment.sorted().map { "-u \($0)" }
        let assignments = environment.keys.sorted().map { key in
            "\(key)=\(quote(environment[key] ?? ""))"
        }
        let command = executableParts.map(quote).joined(separator: " ")
        let envCommand = (["exec", "/usr/bin/env"] + unset + assignments + [command]).joined(separator: " ")
        return "cd -- \(quote(workingDirectory.path)) || exit 72; \(envCommand)"
    }

    private static func openCodeXDGPaths(for profileDirectory: URL) throws -> OpenCodeXDGPaths {
        // LocalCLIKind.openCode uses ~/.local/share/opencode. Requiring this
        // suffix avoids silently mapping a selected arbitrary directory onto
        // the user's default XDG roots.
        let dataDirectory = profileDirectory.deletingLastPathComponent()
        let localDirectory = dataDirectory.deletingLastPathComponent()
        let rootDirectory = localDirectory.deletingLastPathComponent()
        guard profileDirectory.lastPathComponent == "opencode",
            dataDirectory.lastPathComponent == "share",
            localDirectory.lastPathComponent == ".local",
            validPath(dataDirectory, mustExist: true),
            validPath(localDirectory, mustExist: true),
            validPath(rootDirectory, mustExist: true)
        else { throw Failure.invalidDirectory }

        let paths = OpenCodeXDGPaths(
            configHome: rootDirectory.appendingPathComponent(".config", isDirectory: true),
            dataHome: dataDirectory,
            stateHome: localDirectory.appendingPathComponent("state", isDirectory: true),
            cacheHome: rootDirectory.appendingPathComponent(".cache", isDirectory: true))
        guard validPath(paths.configHome, mustExist: false),
            validPath(paths.dataHome, mustExist: true),
            validPath(paths.stateHome, mustExist: false),
            validPath(paths.cacheHome, mustExist: false)
        else { throw Failure.invalidDirectory }
        return paths
    }

    private static func workBuddyBundle(for executable: String, profileDirectory: URL) throws -> WorkBuddyBundle {
        guard lexicallyValidInput(executable) else { throw Failure.invalidDirectory }
        let cli = URL(fileURLWithPath: executable)
        guard
            let edition = WorkBuddyEdition.allCases.first(where: {
                cli.path.hasSuffix("/\($0.applicationName)/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy")
            })
        else { throw Failure.unsupported }
        let marker = "/\(edition.applicationName)/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"
        let applicationPath = String(cli.path.dropLast(marker.count)) + "/" + edition.applicationName
        let application = URL(fileURLWithPath: applicationPath, isDirectory: true)
        let expectedCLI = application.appendingPathComponent(
            "Contents/Resources/app.asar.unpacked/cli/bin/codebuddy")
        let electron = application.appendingPathComponent("Contents/MacOS/Electron")
        let product = application.appendingPathComponent(
            "Contents/Resources/app.asar.unpacked/cli/product.json")
        guard cli.path == expectedCLI.path,
            validDirectory(application),
            validExecutable(cli),
            validExecutable(electron),
            validRegularFile(product)
        else { throw Failure.invalidDirectory }

        // The default profile is already ~/.workbuddy. A linked profile may
        // represent a parent folder; in that case the product-specific config
        // directory is its child named .workbuddy.
        if WorkBuddyEdition.allCases.contains(where: { $0.directoryName == profileDirectory.lastPathComponent }),
            profileDirectory.lastPathComponent != edition.directoryName
        {
            throw Failure.unsupported
        }
        let configDirectory =
            profileDirectory.lastPathComponent == edition.directoryName
            ? profileDirectory
            : profileDirectory.appendingPathComponent(edition.directoryName, isDirectory: true)
        guard validPath(configDirectory, mustExist: false) else { throw Failure.invalidDirectory }
        return WorkBuddyBundle(cli: cli, electron: electron, productConfig: product, configDirectory: configDirectory, edition: edition)
    }

    private static func executableFailure(for path: String) -> Failure {
        let url = URL(fileURLWithPath: path)
        return validPath(url, mustExist: false) ? .executableMissing : .invalidDirectory
    }

    private static func validDirectory(_ directory: URL) -> Bool {
        guard validPath(directory, mustExist: true) else { return false }
        var info = stat()
        return lstat(directory.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && FileManager.default.isReadableFile(atPath: directory.path)
    }

    private static func validExecutable(_ file: URL) -> Bool {
        guard validPath(file, mustExist: true), validRegularFile(file) else { return false }
        return file.path.utf8.count <= 4096 && FileManager.default.isExecutableFile(atPath: file.path)
    }

    private static func validRegularFile(_ file: URL) -> Bool {
        guard validPath(file, mustExist: true) else { return false }
        var info = stat()
        return lstat(file.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// Validate a path lexically and reject symlink components. When a path is
    /// intended for a CLI to create later, only its existing ancestors need to
    /// be checked; no file is read or created here.
    private static func validPath(_ url: URL, mustExist: Bool) -> Bool {
        let path = url.path
        guard url.isFileURL,
            path.hasPrefix("/"),
            path.utf8.count <= 4096,
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            noSymlinkComponents(path)
        else { return false }

        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT != S_IFLNK else { return false }
            return true
        }
        return !mustExist && errno == ENOENT
    }

    private static func lexicallyValidInput(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            URL(fileURLWithPath: path).path == path
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func noSymlinkComponents(_ path: String) -> Bool {
        var current = "/"
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current = current == "/" ? "/\(component)" : current + "/\(component)"
            var info = stat()
            guard lstat(current, &info) == 0 else {
                // Once the first component is missing, all remaining
                // components are necessarily missing from this path. A CLI
                // may create them later, but there is no existing symlink to
                // cross.
                guard errno == ENOENT else { return false }
                break
            }
            guard info.st_mode & S_IFMT != S_IFLNK else { return false }
        }
        return true
    }
}
