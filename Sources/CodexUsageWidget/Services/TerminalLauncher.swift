import AppKit
import Foundation

protocol TerminalLaunching {
    func launch(
        codexHome: URL,
        workingDirectory: URL?,
        preference: CodexExecutionPreference,
        leaseID: String
    ) async throws -> TerminalLaunchSession
}

enum TerminalLauncherError: LocalizedError {
    case invalidProfileID
    case invalidProfileDirectory
    case profileDirectoryMissing
    case codexExecutableMissing
    case terminalMissing
    case launchFileFailed
    case workingDirectoryMissing
    case launchFailed
    case presetCapabilityUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidProfileID:
            return WidgetLanguage.storedOrAutomatic().text("账号环境标识无效；仅允许字母和数字", "The account profile ID is invalid. Use letters and numbers only.")
        case .invalidProfileDirectory:
            return WidgetLanguage.storedOrAutomatic().text("账号环境不在 Next 的独立资料目录中", "This account is outside Next's isolated profile directory.")
        case .profileDirectoryMissing:
            return WidgetLanguage.storedOrAutomatic().text("账号环境目录不存在，请先重新登录该账号", "The account profile folder is missing. Sign in to this account again.")
        case .codexExecutableMissing:
            return WidgetLanguage.storedOrAutomatic().text(
                "未找到可执行的 Codex CLI。请先安装 Codex CLI，或确认独立安装路径可执行", "Codex CLI was not found. Install it or check that the standalone executable is available.")
        case .terminalMissing:
            return WidgetLanguage.storedOrAutomatic().text("未找到系统 Terminal 应用", "The system Terminal application was not found.")
        case .launchFileFailed:
            return WidgetLanguage.storedOrAutomatic().text("无法创建私有终端启动文件，请检查应用数据目录权限", "Could not create the private terminal launch file. Check app data permissions.")
        case .workingDirectoryMissing:
            return WidgetLanguage.storedOrAutomatic().text("所选工作目录不存在或不可访问，请重新选择", "The selected working directory is missing or inaccessible. Choose it again.")
        case .launchFailed:
            return WidgetLanguage.storedOrAutomatic().text(
                "Terminal 未接受启动请求，请检查系统 Terminal 是否可用", "Terminal did not accept the launch request. Check that the system Terminal app is available.")
        case .presetCapabilityUnavailable:
            return WidgetLanguage.storedOrAutomatic().text(
                "当前 Codex CLI 未通过执行档位能力检查；请在运行环境中更新至 0.154.0 或更新版本后重试。",
                "This Codex CLI did not pass the preset capability check. Update to 0.154.0 or newer in Runtime setup and retry.")
        }
    }
}

struct TerminalAppLauncher: TerminalLaunching {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func launch(
        codexHome: URL,
        workingDirectory: URL?,
        preference: CodexExecutionPreference,
        leaseID: String
    ) async throws -> TerminalLaunchSession {
        let command = try launchCommand(
            codexHome: codexHome,
            workingDirectory: workingDirectory,
            preference: preference
        )
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw TerminalLauncherError.terminalMissing
        }
        let session: TerminalLaunchSession
        do { session = try TerminalLaunchSession.create(command: command, fileManager: fileManager, identifier: leaseID) } catch { throw TerminalLauncherError.launchFileFailed }
        do {
            _ = try await NSWorkspace.shared.open(
                [session.scriptURL], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            // Launch Services may have delivered the file before reporting an error.
            // Keep the receipt so occupancy can still be reconciled.
            throw TerminalLaunchDeliveryError(session: session)
        }
        return session
    }

    func launchCommand(
        codexHome: URL,
        workingDirectory: URL?,
        preference: CodexExecutionPreference
    ) throws -> String {
        let preference = try preference.validated()
        let profileID = codexHome.lastPathComponent
        guard !profileID.isEmpty,
            profileID.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        else { throw TerminalLauncherError.invalidProfileID }

        let expectedHome = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-account-manager-next/profiles", isDirectory: true)
            .appendingPathComponent(profileID, isDirectory: true)
            .standardizedFileURL.path
        guard codexHome.standardizedFileURL.path == expectedHome,
            codexHome.resolvingSymlinksInPath().standardizedFileURL.path == expectedHome
        else {
            throw TerminalLauncherError.invalidProfileDirectory
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: codexHome.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalLauncherError.profileDirectoryMissing
        }
        guard let executable = Self.codexExecutable(fileManager: fileManager) else {
            throw TerminalLauncherError.codexExecutableMissing
        }
        let resolvedExecutable = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        try NativeExecutionPreset.validateCLI(executable: resolvedExecutable, codexHome: codexHome)

        let directory = workingDirectory ?? fileManager.homeDirectoryForCurrentUser
        var isWorkDirectory: ObjCBool = false
        guard directory.isFileURL,
            fileManager.fileExists(atPath: directory.path, isDirectory: &isWorkDirectory), isWorkDirectory.boolValue,
            fileManager.isReadableFile(atPath: directory.path)
        else { throw TerminalLauncherError.workingDirectoryMissing }
        let roleURL = try NativeExecutionPreset.freezeRole(preference)
        return try Self.command(
            codexHome: codexHome, directory: directory, executable: resolvedExecutable.path,
            preference: preference, homeDirectory: fileManager.homeDirectoryForCurrentUser, roleURL: roleURL)
    }

    /// A single copyable subshell: profile state never leaks into the caller's shell.
    static func command(
        codexHome: URL, directory: URL, executable: String,
        preference: CodexExecutionPreference, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        roleURL: URL? = nil
    ) throws -> String {
        let directoryCommand = "cd -- \(shellQuote(directory.path)) || exit 72"
        let managedHomeExpression =
            shellQuote(codexHome.path)
        return "( "
            + [
                directoryCommand,
                "exec /usr/bin/env -u OPENAI_API_KEY -u CODEX_API_KEY -u CODEX_ACCESS_TOKEN -u CODEX_THREAD_ID -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE CODEX_HOME=\(managedHomeExpression) "
                    + (try Self.configuredCodexCommand(executable: executable, preference: preference, roleURL: roleURL)),
            ].joined(separator: "; ") + " )"
    }

    static func configuredCodexCommand(
        executable: String,
        preference: CodexExecutionPreference,
        roleURL: URL? = nil
    ) throws -> String {
        let preference = try preference.validated()
        let strategy = preference.effectiveStrategy
        var arguments = [
            shellQuote(executable),
            "--model", shellQuote(strategy.mainModel.rawValue),
            "-c", shellQuote("model_reasoning_effort=\"\(strategy.mainReasoningEffort.rawValue)\""),
            "-c", shellQuote("agents.default_subagent_model=\"\((strategy.subagentModel ?? strategy.mainModel).rawValue)\""),
            "-c",
            shellQuote(
                "agents.default_subagent_reasoning_effort=\"\((strategy.subagentReasoningEffort ?? strategy.mainReasoningEffort).rawValue)\""
            ),
            "-c", shellQuote("service_tier=\"\(preference.serviceTier.rawValue)\""),
        ]
        arguments += ["-c", shellQuote("features.multi_agent_v2=false")]
        if strategy.maximumConcurrentSubagents > 0 {
            guard let roleURL, roleURL.isFileURL else { throw TerminalLauncherError.launchFileFailed }
            let encodedPath = String(decoding: try JSONEncoder().encode(roleURL.path), as: UTF8.self)
            arguments += [
                "-c", shellQuote("agents.enabled=true"),
                "-c", shellQuote("features.multi_agent=true"),
                "-c", shellQuote("agents.max_concurrent_threads_per_session=1"),
                "-c", shellQuote("agents.max_depth=1"),
                "-c", shellQuote("agents.\(NativeExecutionPreset.roleName).description=\"Next managed preset implementation worker\""),
                "-c", shellQuote("agents.\(NativeExecutionPreset.roleName).config_file=\(encodedPath)"),
            ]
        } else {
            arguments += ["-c", shellQuote("agents.enabled=false")]
        }
        arguments.append(preference.serviceTier == .fast ? "--enable fast_mode" : "--disable fast_mode")
        if strategy.maximumConcurrentSubagents > 0 { arguments.append(shellQuote(NativeExecutionPreset.initialPrompt)) }
        return arguments.joined(separator: " ")
    }

    static func selfTest() -> Bool {
        guard TerminalLaunchSession.selfTest() else { return false }
        let roleDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("next-preset-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: roleDirectory) }
        do {
            guard NativeExecutionPreset.supports(version: "codex-cli 0.154.0", features: "multi_agent stable true\n"),
                !NativeExecutionPreset.supports(version: "codex-cli 0.139.0", features: "multi_agent stable true\n"),
                !NativeExecutionPreset.supports(version: "codex-cli 0.154.0", features: "unrelated stable true\n")
            else { return false }
            let middle = CodexExecutionPreference(model: .astra, reasoningEffort: .low, serviceTier: .standard, subagentMode: .solLuna)
            guard let role = try NativeExecutionPreset.freezeRole(middle, base: roleDirectory),
                try NativeExecutionPreset.freezeRole(middle, base: roleDirectory) == role,
                try DispatchParticipationSync.readBoundedRegularFile(role, maximumBytes: 1024, allowMissing: false)
                    == Data("model = \"gpt-6-luna\"\nmodel_reasoning_effort = \"max\"\n".utf8)
            else { return false }
            let middleCommand = try configuredCodexCommand(executable: "/fixture/codex", preference: middle, roleURL: role)
            let direct = CodexExecutionPreference(model: .astra, reasoningEffort: .low, serviceTier: .standard, subagentMode: .lunaDirect)
            let directCommand = try configuredCodexCommand(executable: "/fixture/codex", preference: direct)
            guard middleCommand.contains("--model 'gpt-6.1-sol'"), middleCommand.contains("model_reasoning_effort=\"high\""),
                middleCommand.contains("agents.max_concurrent_threads_per_session=1"),
                middleCommand.contains("agents.next_preset_worker.config_file="),
                !middleCommand.contains("developer_instructions="),
                directCommand.contains("--model 'gpt-6-luna'"), directCommand.contains("agents.enabled=false"),
                directCommand.contains("features.multi_agent_v2=false"), !directCommand.contains("next_preset_worker")
            else { return false }
            do {
                _ = try configuredCodexCommand(executable: "/fixture/codex", preference: middle)
                return false
            } catch TerminalLauncherError.launchFileFailed {}
            var customized = middle
            customized.customPresets["sol_luna"] = .init(
                name: "fixture-name", useSavedModel: false, model: .terra,
                reasoningEffort: .medium, subagentsEnabled: true, subagentModel: .sol, subagentReasoningEffort: .high)
            guard let customRole = try NativeExecutionPreset.freezeRole(customized, base: roleDirectory), customRole != role else { return false }
            let customCommand = try configuredCodexCommand(executable: "/fixture/codex", preference: customized, roleURL: customRole)
            guard customCommand.contains("--model 'gpt-5.6-terra'"), customCommand.contains("agents.default_subagent_model=\"gpt-5.6-sol\""),
                !customCommand.contains("fixture-name")
            else { return false }
            let standard = try configuredCodexCommand(
                executable: "/Applications/ChatGPT.app/Contents/Resources/codex",
                preference: .init(model: .sol, reasoningEffort: .high, serviceTier: .standard)
            )
            let fast = try configuredCodexCommand(
                executable: "/Applications/ChatGPT.app/Contents/Resources/codex",
                preference: .init(model: .terra, reasoningEffort: .xhigh, serviceTier: .fast)
            )
            guard standard.contains("--model 'gpt-5.6-sol'"), standard.contains("agents.enabled=false"),
                try CodexExecutionPreference.Model.astra.supportedReasoningEfforts.allSatisfy({ effort in
                    try CodexExecutionPreference.ServiceTier.allCases.allSatisfy { tier in
                        let command = try configuredCodexCommand(
                            executable: "/usr/local/bin/codex",
                            preference: .init(model: .astra, reasoningEffort: effort, serviceTier: tier)
                        )
                        return command.contains("--model 'gpt-6-astra'")
                            && command.contains("model_reasoning_effort=\"\(effort.rawValue)\"")
                            && command.contains("agents.default_subagent_model=\"gpt-6-astra\"")
                            && command.contains("agents.default_subagent_reasoning_effort=\"\(effort.rawValue)\"")
                            && command.contains("service_tier=\"\(tier.rawValue)\"")
                            && command.contains(tier == .fast ? "--enable fast_mode" : "--disable fast_mode")
                    }
                }),
                standard.contains("model_reasoning_effort=\"high\""),
                standard.contains("agents.default_subagent_model=\"gpt-5.6-sol\""),
                standard.contains("agents.default_subagent_reasoning_effort=\"high\""),
                standard.contains("service_tier=\"default\""),
                standard.contains("--disable fast_mode"),
                fast.contains("--model 'gpt-5.6-terra'"),
                fast.contains("model_reasoning_effort=\"xhigh\""),
                fast.contains("agents.default_subagent_model=\"gpt-5.6-terra\""),
                fast.contains("agents.default_subagent_reasoning_effort=\"xhigh\""),
                fast.contains("service_tier=\"fast\""),
                fast.contains("--enable fast_mode")
            else {
                print("Terminal launcher self-test failed: CLI preference arguments")
                return false
            }
            print("Terminal launcher self-test passed")
            return true
        } catch {
            print("Terminal launcher self-test failed: \(error)")
            return false
        }
    }

    static func codexExecutable(fileManager: FileManager = .default) -> String? {
        CodexExecutable.path(fileManager: fileManager)
    }

    static func socketPathUTF8Length(codexHome: URL) -> Int {
        codexHome
            .appendingPathComponent("app-server-control/app-server-control.sock")
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .lengthOfBytes(using: .utf8)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellPathExpression(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
        if standardizedPath == homePath { return "\"$HOME\"" }
        let homePrefix = homePath + "/"
        if standardizedPath.hasPrefix(homePrefix) {
            return "\"$HOME\"/" + shellQuote(String(standardizedPath.dropFirst(homePrefix.count)))
        }
        return shellQuote(standardizedPath)
    }

}
