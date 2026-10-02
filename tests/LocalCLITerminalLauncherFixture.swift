import Darwin
import Foundation

private enum FixtureFailure: Error { case failed(String) }

enum TerminalLauncherError: Error {
    case terminalMissing
    case launchFileFailed
    case launchFailed
}

struct TerminalLaunchDeliveryError: Error {
    let session: TerminalLaunchSession
}

struct TerminalLaunchSession {
    enum State {
        case pending
        case exited(Int32)
    }
    let scriptURL = URL(fileURLWithPath: "/tmp/synthetic-terminal-script")

    static func create(command: String) throws -> Self { Self() }
    func readState() throws -> State { .pending }
    func verifiedExitCode() -> Int32? { nil }
    func removeAfterExit() {}
}

enum TerminalAppLauncher {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure.failed(message) }
}

private func makeExecutable(at url: URL, contents: String = "#!/bin/sh\nexit 0\n") throws {
    try Data(contents.utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else { throw FixtureFailure.failed("chmod executable") }
}

private func testGrokQuotingAndEnvironmentIsolation() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local-cli-launcher-grok-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profileDirectory = root.appendingPathComponent("profile dir ' one", isDirectory: true)
    let workingDirectory = root.appendingPathComponent("work dir ' $(touch INJECTED)", isDirectory: true)
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("grok ' fixture")
    try makeExecutable(at: executable)

    let profile = LocalCLIProfile(
        id: "fixture-grok", kind: .grok, displayName: "Synthetic",
        configDirectory: profileDirectory.path, isDefault: false)
    let command = try LocalCLITerminalLauncher.command(
        profile: profile, executable: executable.path, action: .signIn, workingDirectory: workingDirectory)
    try expect(command.contains("login"), "Grok login argument")
    try expect(command.contains("--oauth"), "Grok OAuth argument")
    try expect(
        command.contains("GROK_HOME=\(TerminalAppLauncher.shellQuote(profileDirectory.path))"),
        "Grok profile environment")
    try expect(
        command.contains(
            "GROK_AUTH_PATH=\(TerminalAppLauncher.shellQuote(profileDirectory.appendingPathComponent("auth.json").path))"),
        "Grok auth path")
    try expect(
        command.hasPrefix("cd -- \(TerminalAppLauncher.shellQuote(workingDirectory.path)) || exit 72;"),
        "working directory is shell quoted")
    try expect(command.contains("-u XAI_API_KEY") && command.contains("-u GROK_API_KEY"), "Grok API keys are cleared")
}

private func testOpenCodeXDGProviderIsolation() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local-cli-launcher-opencode-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dataDirectory = root.appendingPathComponent(".local/share/opencode", isDirectory: true)
    let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("opencode", isDirectory: false)
    try makeExecutable(at: executable)

    let profile = LocalCLIProfile(
        id: "fixture-opencode", kind: .openCode, displayName: "OpenCode",
        configDirectory: dataDirectory.path, isDefault: false)
    let command = try LocalCLITerminalLauncher.command(
        profile: profile, executable: executable.path, action: .signIn, workingDirectory: workingDirectory)
    try expect(command.contains("'auth' 'login'"), "OpenCode auth login argument")
    try expect(command.contains("XDG_DATA_HOME='\(root.appendingPathComponent(".local/share").path)"), "OpenCode XDG data root")
    try expect(command.contains("XDG_CONFIG_HOME='\(root.appendingPathComponent(".config").path)"), "OpenCode XDG config root")
    try expect(command.contains("XDG_STATE_HOME='\(root.appendingPathComponent(".local/state").path)"), "OpenCode XDG state root")
    try expect(command.contains("-u OPENCODE_CONFIG") && command.contains("-u OPENCODE_CONFIG_DIR"), "OpenCode explicit config overrides are cleared")
    try expect(
        command.contains("-u ANTHROPIC_API_KEY") && command.contains("-u OPENAI_API_KEY"),
        "OpenCode does not inherit paid provider API keys")
    try expect(!command.contains("opencode-go"), "OpenCode Go is not substituted for provider login")
    // Execute only a generated shell fixture, never an installed OpenCode CLI.
    try makeExecutable(at: executable, contents: "#!/bin/sh\ntest -z \"${OPENCODE_AUTH_CONTENT+x}\"\n")
    for action in [LocalCLITerminalLauncher.Action.signIn, .open] {
        let isolatedCommand = try LocalCLITerminalLauncher.command(
            profile: profile, executable: executable.path, action: action, workingDirectory: workingDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", isolatedCommand]
        process.environment = ["PATH": "/usr/bin:/bin", "OPENCODE_AUTH_CONTENT": "synthetic-other-profile"]
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "OpenCode cannot inherit credentials outside the selected profile")
    }

    let invalid = root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    let invalidProfile = LocalCLIProfile(
        id: "fixture-invalid", kind: .openCode, displayName: "Invalid",
        configDirectory: invalid.path, isDefault: false)
    do {
        _ = try LocalCLITerminalLauncher.command(
            profile: invalidProfile, executable: executable.path, action: .open, workingDirectory: workingDirectory)
        throw FixtureFailure.failed("arbitrary OpenCode directory accepted")
    } catch LocalCLITerminalLauncher.Failure.invalidDirectory {
        // Expected: a linked profile must use the XDG data/opencode shape.
    }
}

private func testWorkBuddyBundleAndProductIsolation() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local cli launcher workbuddy ' \(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("WorkBuddy.app", isDirectory: true)
    let cli = application.appendingPathComponent(
        "Contents/Resources/app.asar.unpacked/cli/bin/codebuddy")
    let electron = application.appendingPathComponent("Contents/MacOS/Electron")
    let product = application.appendingPathComponent(
        "Contents/Resources/app.asar.unpacked/cli/product.json")
    let profileDirectory = root.appendingPathComponent("account one/.workbuddy", isDirectory: true)
    let workingDirectory = root.appendingPathComponent("project ' one", isDirectory: true)
    try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: electron.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try makeExecutable(at: cli)
    try makeExecutable(at: electron)
    try Data("{}".utf8).write(to: product)

    let profile = LocalCLIProfile(
        id: "fixture-workbuddy",
        kind: .workBuddy,
        displayName: "WorkBuddy",
        configDirectory: profileDirectory.path,
        isDefault: false)
    let command = try LocalCLITerminalLauncher.command(
        profile: profile,
        executable: cli.path,
        action: .signIn,
        workingDirectory: workingDirectory)
    try expect(
        command.contains(
            "\(TerminalAppLauncher.shellQuote(electron.path)) \(TerminalAppLauncher.shellQuote(cli.path))"),
        "WorkBuddy runs its bundled CLI through its bundled Electron")
    try expect(
        command.contains("ACC_PRODUCT_CONFIG_PATH=\(TerminalAppLauncher.shellQuote(product.path))"),
        "WorkBuddy product config stays in the same bundle")
    try expect(
        command.contains("CODEBUDDY_CONFIG_DIR=\(TerminalAppLauncher.shellQuote(profileDirectory.path))")
            && command.contains("WORKBUDDY_CONFIG_DIR=\(TerminalAppLauncher.shellQuote(profileDirectory.path))"),
        "WorkBuddy config variables share the selected .workbuddy directory")
    try expect(command.contains("ELECTRON_RUN_AS_NODE='1'"), "WorkBuddy uses Electron as Node")
    try expect(command.contains("WORKBUDDY_DATA_FOLDER_NAME='.workbuddy'"), "WorkBuddy data folder name")
    try expect(command.contains("DISABLE_AUTOUPDATER='1'"), "WorkBuddy updater disabled")
    try expect(!command.contains("'login'"), "WorkBuddy sign-in does not become a model prompt")

    let international = root.appendingPathComponent("WorkBuddy AI.app", isDirectory: true)
    try FileManager.default.copyItem(at: application, to: international)
    let internationalCLI = international.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/bin/codebuddy")
    var internationalProfile = profile
    internationalProfile.configDirectory = root.appendingPathComponent("account two/.workbuddy-ai").path
    try FileManager.default.createDirectory(atPath: internationalProfile.configDirectory, withIntermediateDirectories: true)
    let internationalCommand = try LocalCLITerminalLauncher.command(
        profile: internationalProfile, executable: internationalCLI.path, action: .signIn, workingDirectory: workingDirectory)
    try expect(
        internationalCommand.contains("WORKBUDDY_DATA_FOLDER_NAME='.workbuddy-ai'"),
        "international edition keeps its own data folder")
    try expect(
        internationalCommand.contains(
            "ACC_PRODUCT_CONFIG_PATH="
                + TerminalAppLauncher.shellQuote(
                    international.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/product.json").path)),
        "international edition uses its own product metadata")
    for (candidate, bundleCLI) in [(profile, internationalCLI), (internationalProfile, cli)] {
        do {
            _ = try LocalCLITerminalLauncher.command(
                profile: candidate, executable: bundleCLI.path, action: .open, workingDirectory: workingDirectory)
            throw FixtureFailure.failed("cross-edition credentials accepted")
        } catch LocalCLITerminalLauncher.Failure.unsupported {
            // The UI must not silently change products for an existing account.
        }
    }

    let external = root.appendingPathComponent("codebuddy", isDirectory: false)
    try makeExecutable(at: external)
    do {
        _ = try LocalCLITerminalLauncher.command(
            profile: profile,
            executable: external.path,
            action: .open,
            workingDirectory: workingDirectory)
        throw FixtureFailure.failed("external codebuddy accepted")
    } catch LocalCLITerminalLauncher.Failure.unsupported {
        // Expected: only WorkBuddy.app's own codebuddy is accepted.
    }
}

private func testZCodeDefaultBundleCommands() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local cli launcher zcode ' \(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("ZCode.app", isDirectory: true)
    let cli = application.appendingPathComponent("Contents/Resources/glm/zcode.cjs")
    let electron = application.appendingPathComponent("Contents/MacOS/ZCode")
    let profileDirectory = root.appendingPathComponent("synthetic home/.zcode", isDirectory: true)
    let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: electron.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try Data("synthetic cjs".utf8).write(to: cli)
    try makeExecutable(at: electron)

    let profile = LocalCLIProfile(
        id: "local-zcode",
        kind: .zcode,
        displayName: "Local",
        configDirectory: profileDirectory.path,
        isDefault: true)
    for action: LocalCLITerminalLauncher.Action in [.signIn, .open] {
        do {
            _ = try LocalCLITerminalLauncher.command(profile: profile, executable: cli.path, action: action, workingDirectory: workingDirectory)
            throw FixtureFailure.failed("ZCode private CLI must not be launched")
        } catch LocalCLITerminalLauncher.Failure.unsupported {}
    }

}

private func testRejectsSymlinkAndLinkedZCode() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local-cli-launcher-safety-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real", isDirectory: true)
    let link = root.appendingPathComponent("link", isDirectory: true)
    let working = root.appendingPathComponent("working", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let executable = root.appendingPathComponent("grok", isDirectory: false)
    try makeExecutable(at: executable)
    let profile = LocalCLIProfile(
        id: "fixture-symlink", kind: .grok, displayName: "Symlink",
        configDirectory: link.path, isDefault: false)
    do {
        _ = try LocalCLITerminalLauncher.command(
            profile: profile, executable: executable.path, action: .open, workingDirectory: working)
        throw FixtureFailure.failed("symlink profile accepted")
    } catch LocalCLITerminalLauncher.Failure.invalidDirectory {
        // Expected.
    }

    let zcodeProfile = LocalCLIProfile(
        id: "fixture-zcode", kind: .zcode, displayName: "Linked ZCode",
        configDirectory: real.path, isDefault: false)
    do {
        _ = try LocalCLITerminalLauncher.command(
            profile: zcodeProfile, executable: executable.path, action: .open, workingDirectory: working)
        throw FixtureFailure.failed("linked ZCode environment accepted")
    } catch LocalCLITerminalLauncher.Failure.unsupported {
        // Expected: only the default ZCode environment can be launched.
    }
}

private func testAdditionalProviderLaunches() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local-cli-launcher-providers-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let working = root.appendingPathComponent("work ' $(touch INJECTED)", isDirectory: true)
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("official ' fixture")
    try makeExecutable(
        at: executable,
        contents: """
            #!/bin/sh
            printf 'argc=%s\n' "$#"
            for arg do printf 'arg=%s\n' "$arg"; done
            printf 'claude_dir=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
            printf 'kimi_code=%s\n' "${KIMI_CODE_HOME-unset}"
            printf 'kimi_share=%s\n' "${KIMI_SHARE_DIR-unset}"
            printf 'gemini_home=%s\n' "${GEMINI_CLI_HOME-unset}"
            printf 'anthropic_key=%s\n' "${ANTHROPIC_API_KEY-unset}"
            printf 'gemini_key=%s\n' "${GEMINI_API_KEY-unset}"
            """)

    for kind in [LocalCLIKind.claudeCode, .kimi, .gemini] {
        let directory = kind.defaultConfigDirectory(home: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = LocalCLIProfile(
            id: "local-" + kind.rawValue, kind: kind, displayName: "Synthetic",
            configDirectory: directory.path, isDefault: true)
        let command = try LocalCLITerminalLauncher.command(
            profile: profile, executable: executable.path, action: .signIn, workingDirectory: working)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "synthetic-unrelated",
            "KIMI_CODE_HOME": "synthetic-unrelated", "KIMI_SHARE_DIR": "synthetic-unrelated",
            "GEMINI_CLI_HOME": "synthetic-unrelated", "ANTHROPIC_API_KEY": "synthetic-unrelated",
            "GEMINI_API_KEY": "synthetic-unrelated",
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try expect(process.terminationStatus == 0, "synthetic CLI executes")
        switch kind {
        case .claudeCode:
            try expect(result.hasPrefix("argc=2\narg=auth\narg=login\n"), "Claude opens subscription login")
            try expect(result.contains("claude_dir=\(directory.path)\n"), "Claude uses selected default config")
            try expect(result.contains("anthropic_key=unset\n"), "Claude removes inherited API key")
        case .kimi:
            try expect(result.hasPrefix("argc=1\narg=login\n"), "Kimi opens login")
            try expect(result.contains("kimi_code=\(directory.path)\n"), "new Kimi uses selected config")
            try expect(result.contains("kimi_share=\(directory.path)\n"), "older Kimi uses selected config")
            try expect(result.contains("anthropic_key=unset\n"), "Kimi removes unrelated provider override")
        case .gemini:
            try expect(result.hasPrefix("argc=0\n"), "Gemini opens auth selector without sending a prompt")
            try expect(result.contains("gemini_home=unset\n"), "Gemini uses its default environment")
            try expect(result.contains("gemini_key=unset\n"), "Gemini removes inherited API key")
        default: throw FixtureFailure.failed("unexpected provider")
        }
        if kind.requiresDefaultEnvironmentForLaunch {
            var linked = profile
            linked.isDefault = false
            linked.id = "linked-" + kind.rawValue
            for action in [LocalCLITerminalLauncher.Action.signIn, .open] {
                do {
                    _ = try LocalCLITerminalLauncher.command(
                        profile: linked, executable: executable.path, action: action, workingDirectory: working)
                    throw FixtureFailure.failed("linked environment accepted")
                } catch LocalCLITerminalLauncher.Failure.unsupported {
                    // Incomplete credential isolation must not launch another identity.
                }
            }
        }
    }
    try expect(!FileManager.default.fileExists(atPath: working.appendingPathComponent("INJECTED").path), "path is not shell code")
}

@main enum Main {
    static func main() throws {
        try testGrokQuotingAndEnvironmentIsolation()
        try testOpenCodeXDGProviderIsolation()
        try testWorkBuddyBundleAndProductIsolation()
        try testZCodeDefaultBundleCommands()
        try testRejectsSymlinkAndLinkedZCode()
        try testAdditionalProviderLaunches()
        print("local-cli-terminal-launcher-fixture: ok")
    }
}
