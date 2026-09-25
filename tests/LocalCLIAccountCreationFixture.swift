import Darwin
import Foundation

enum WidgetLanguage {
    case zh
    static func storedOrAutomatic() -> Self { .zh }
    func text(_ zh: String, _ en: String) -> String { zh }
}

private enum FixtureFailure: Error { case failed(String) }

// Compile the real command builder, but prevent this fixture from delivering a
// terminal script, authenticating, or making a quota request.
enum TerminalLauncherError: Error { case terminalMissing, launchFileFailed, launchFailed }
struct TerminalLaunchDeliveryError: Error { let session: TerminalLaunchSession }
struct TerminalLaunchSession {
    enum State { case pending, exited(Int32) }
    let scriptURL = URL(fileURLWithPath: "/tmp/synthetic-terminal-script")
    static func create(command: String) throws -> Self {
        throw FixtureFailure.failed("account creation must not launch Terminal")
    }
    func readState() throws -> State { .pending }
    func verifiedExitCode() -> Int32? { nil }
    func removeAfterExit() {}
}
enum TerminalAppLauncher {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
private func forbiddenQuotaRequest() -> LocalCLIQuotaResult {
    fatalError("account creation must not request quota")
}
struct LocalCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { forbiddenQuotaRequest() }
}
struct AdditionalCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { forbiddenQuotaRequest() }
}
struct ZCodeCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { forbiddenQuotaRequest() }
}
struct AntigravityCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { forbiddenQuotaRequest() }
    static func hasLinkedCache(at directory: URL) -> Bool { false }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw FixtureFailure.failed(message) }
}

private struct Environment {
    let root: URL
    var home: URL { root.appendingPathComponent("h", isDirectory: true) }
    var support: URL { root.appendingPathComponent("s", isDirectory: true) }
    var applications: URL { root.appendingPathComponent("a", isDirectory: true) }
    var managed: URL { home.appendingPathComponent(".codex-account-manager-next", isDirectory: true) }
    var storage: URL { support.appendingPathComponent("local-cli-accounts-v1.json") }

    @MainActor func store() -> LocalCLIAccountStore {
        LocalCLIAccountStore(home: home, support: support, applicationsDirectory: applications)
    }
}

private func makeExecutable(_ file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file)
    guard chmod(file.path, 0o700) == 0 else { throw FixtureFailure.failed("fixture executable mode") }
}

private func makeEnvironment(editions: [WorkBuddyEdition] = WorkBuddyEdition.allCases) throws -> Environment {
    // Grok needs a short socket path. /Users/Shared also avoids the macOS
    // /tmp symlink: the real launcher intentionally rejects symlink ancestors.
    let root = URL(fileURLWithPath: "/Users/Shared/a" + String(UUID().uuidString.prefix(6)), isDirectory: true)
    guard mkdir(root.path, 0o700) == 0 else { throw FixtureFailure.failed("fixture root") }
    let env = Environment(root: root)
    do {
        for directory in [env.home, env.support, env.applications] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        for kind: LocalCLIKind in [.grok, .openCode, .kimi, .claudeCode, .gemini] {
            try makeExecutable(env.home.appendingPathComponent(".local/bin/" + kind.commandName))
        }
        for edition in editions {
            let app = env.applications.appendingPathComponent(edition.applicationName, isDirectory: true)
            let cli = app.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/bin/codebuddy")
            try makeExecutable(cli)
            try makeExecutable(app.appendingPathComponent("Contents/MacOS/Electron"))
            try Data("{}".utf8).write(to: app.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/product.json"))
        }
        return env
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func privateDirectory(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        && info.st_uid == geteuid() && info.st_mode & 0o777 == 0o700
}

private func children(_ url: URL) throws -> Set<String> {
    if !FileManager.default.fileExists(atPath: url.path) { return [] }
    return Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
}

private func accountRoot(_ profile: LocalCLIProfile) -> URL {
    let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
    switch profile.kind {
    case .openCode: return directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    case .workBuddy: return directory.deletingLastPathComponent()
    default: return directory
    }
}

@MainActor
private func verifyLaunchContract(_ profile: LocalCLIProfile, in store: LocalCLIAccountStore, env: Environment) throws {
    guard let executable = store.executable(for: profile) else { throw FixtureFailure.failed("new account executable") }
    let command = try LocalCLITerminalLauncher.command(
        profile: profile, executable: executable, action: .signIn, workingDirectory: env.home)
    let quote = TerminalAppLauncher.shellQuote
    try expect(store.canSignIn(profile) && store.canOpen(profile), "new account can use the isolated launcher")
    try expect(!command.contains(" HOME=") && !command.contains(" -u HOME "), "default HOME is preserved")
    switch profile.kind {
    case .grok:
        try expect(command.contains("GROK_HOME=" + quote(profile.configDirectory)), "Grok isolated home")
        try expect(command.contains("GROK_AUTH_PATH=" + quote(profile.configDirectory + "/auth.json")), "Grok isolated auth")
        try expect(command.contains("'login' '--oauth'"), "Grok uses official OAuth login")
        try expect((profile.configDirectory + "/leader.sock").utf8.count < 104, "Grok socket path bound")
    case .kimi:
        try expect(command.contains("KIMI_CODE_HOME=" + quote(profile.configDirectory)), "Kimi Code isolated home")
        try expect(command.contains("KIMI_SHARE_DIR=" + quote(profile.configDirectory)), "legacy Kimi isolated home")
        try expect(command.contains("'login'"), "Kimi uses official login")
    case .openCode:
        let root = accountRoot(profile)
        for (key, relative) in [("XDG_CONFIG_HOME", ".config"), ("XDG_DATA_HOME", ".local/share"),
                                ("XDG_STATE_HOME", ".local/state"), ("XDG_CACHE_HOME", ".cache")] {
            let directory = root.appendingPathComponent(relative, isDirectory: true)
            try expect(privateDirectory(directory), "OpenCode private XDG directory")
            try expect(command.contains(key + "=" + quote(directory.path)), "OpenCode isolated XDG environment")
        }
        try expect(command.contains("'auth' 'login'"), "OpenCode uses provider login")
    case .workBuddy:
        let edition = WorkBuddyEdition.forProfile(profile)
        try expect(command.contains("CODEBUDDY_CONFIG_DIR=" + quote(profile.configDirectory)), "WorkBuddy isolated config")
        try expect(command.contains("WORKBUDDY_CONFIG_DIR=" + quote(profile.configDirectory)), "WorkBuddy matching config")
        try expect(command.contains("WORKBUDDY_DATA_FOLDER_NAME=" + quote(edition.directoryName)), "WorkBuddy edition directory")
        try expect(executable.contains("/" + edition.applicationName + "/"), "WorkBuddy edition executable")
        try expect(!command.contains("'login'"), "WorkBuddy login is not sent as a model prompt")
    default: throw FixtureFailure.failed("unsupported account was created")
    }
}

@MainActor
private func testMultipleAccountsPersistWithIndependentLaunchEnvironments() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let kinds: [LocalCLIKind] = [.grok, .openCode, .kimi, .workBuddy]
    let sentinel = Data("synthetic default state; must not change".utf8)
    var sentinels: [URL] = []
    for kind in kinds {
        let directory = kind.defaultConfigDirectory(home: env.home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture-default-state.json")
        try sentinel.write(to: file)
        sentinels.append(file)
    }
    let store = env.store()
    store.discover()
    var created: [LocalCLIProfile] = []
    for kind in kinds {
        try expect(store.canCreateAccount(kind: kind), "installed isolated provider exposes creation")
        for name in ["Work", "Personal"] {
            guard let profile = store.createAccount(kind: kind, name: name) else {
                throw FixtureFailure.failed("create isolated account for " + kind.rawValue)
            }
            try expect(!profile.isDefault && UUID(uuidString: profile.id) != nil, "independent profile identity")
            try expect(privateDirectory(URL(fileURLWithPath: profile.configDirectory)), "new profile directory is private")
            try expect(privateDirectory(accountRoot(profile)), "new account root is private")
            try expect(profile.configDirectory != kind.defaultConfigDirectory(home: env.home).path, "default profile path is preserved")
            try verifyLaunchContract(profile, in: store, env: env)
            created.append(profile)
        }
    }
    guard let international = store.createAccount(kind: .workBuddy, name: "International", workBuddyEdition: .international) else {
        throw FixtureFailure.failed("create international WorkBuddy account")
    }
    try expect(WorkBuddyEdition.forProfile(international) == .international, "explicit WorkBuddy edition is saved")
    try verifyLaunchContract(international, in: store, env: env)
    created.append(international)
    try expect(Set(created.map(\.id)).count == created.count, "multiple accounts have unique IDs")
    try expect(Set(created.map(\.configDirectory)).count == created.count, "multiple accounts have unique directories")
    try expect(store.quotas.isEmpty && store.refreshing.isEmpty && store.signingIn.isEmpty,
               "creation does not log in or request quota")
    for file in sentinels {
        let data = try Data(contentsOf: file)
        try expect(data == sentinel, "default state is unchanged")
        try expect(try children(file.deletingLastPathComponent()) == [file.lastPathComponent], "default directory has no new files")
    }
    let persisted = try JSONDecoder().decode([LocalCLIProfile].self, from: Data(contentsOf: env.storage))
    try expect(persisted == created, "all created accounts persist in creation order")
    let reloaded = env.store()
    reloaded.discover()
    for profile in created { try expect(reloaded.profiles.contains(profile), "account survives reload") }
}

@MainActor
private func testNamesAndSupportedProviders() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let store = env.store()
    store.discover()
    guard store.createAccount(kind: .openCode, name: "Work") != nil else { throw FixtureFailure.failed("first named account") }
    let before = try Data(contentsOf: env.storage)
    let root = env.managed.appendingPathComponent(LocalCLIKind.openCode.rawValue)
    let slots = try children(root)
    for name in ["Work", "work", "", " Work", "Work ", "a@b", "line\nbreak", String(repeating: "a", count: 65)] {
        try expect(store.createAccount(kind: .openCode, name: name) == nil, "duplicate or invalid name is rejected")
    }
    for kind in LocalCLIKind.allCases where ![LocalCLIKind.grok, .openCode, .kimi, .workBuddy].contains(kind) {
        try expect(!store.canCreateAccount(kind: kind), "non-isolated provider hides creation")
        try expect(store.createAccount(kind: kind, name: "Unsupported") == nil, "non-isolated provider cannot create")
    }
    try expect(store.createAccount(kind: .openCode, name: "Wrong Edition", workBuddyEdition: .international) == nil,
               "WorkBuddy edition cannot leak into other providers")
    let after = try Data(contentsOf: env.storage)
    try expect(after == before, "rejected creation leaves persistence unchanged")
    try expect(try children(root) == slots, "rejected creation leaves no extra slots")
    try expect(store.createAccount(kind: .kimi, name: "Work") != nil, "same name across separate providers is allowed")
    let preview = LocalCLIAccountStore.preview(profiles: store.profiles, quotas: [:], root: env.root)
    try expect(!preview.canCreateAccount(kind: .openCode), "preview does not expose creation")
    try expect(preview.createAccount(kind: .openCode, name: "Preview") == nil, "preview cannot write an account")
}

@MainActor
private func testWorkBuddyInstalledEditionOnly() throws {
    let env = try makeEnvironment(editions: [.international])
    defer { try? FileManager.default.removeItem(at: env.root) }
    let store = env.store()
    store.discover()
    try expect(store.createAccount(kind: .workBuddy, name: "Wrong Edition", workBuddyEdition: .domestic) == nil,
               "uninstalled WorkBuddy edition cannot be created")
    guard let profile = store.createAccount(kind: .workBuddy, name: "Work") else {
        throw FixtureFailure.failed("single installed WorkBuddy edition")
    }
    try expect(WorkBuddyEdition.forProfile(profile) == .international, "default creation selects the installed edition")
    try verifyLaunchContract(profile, in: store, env: env)

    let absent = try makeEnvironment(editions: [])
    defer { try? FileManager.default.removeItem(at: absent.root) }
    let absentStore = absent.store()
    absentStore.discover()
    try expect(!absentStore.canCreateAccount(kind: .workBuddy), "missing WorkBuddy does not expose creation")
    try expect(absentStore.createAccount(kind: .workBuddy, name: "Missing") == nil, "missing WorkBuddy cannot create a false account")
}

@MainActor
private func testFailedSaveRemovesOnlyNewAccountTree() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let winner = env.store()
    let stale = env.store()
    winner.discover()
    stale.discover()
    guard let existing = winner.createAccount(kind: .openCode, name: "Winner") else { throw FixtureFailure.failed("winner account") }
    let root = accountRoot(existing).deletingLastPathComponent()
    let slots = try children(root)
    let bytes = try Data(contentsOf: env.storage)
    let marker = accountRoot(existing).appendingPathComponent("existing-owned-file")
    try Data("preserved synthetic state".utf8).write(to: marker)
    try expect(stale.createAccount(kind: .openCode, name: "Stale") == nil, "stale writer must fail")
    try expect(try children(root) == slots, "failed save removes the full nested XDG account tree")
    let after = try Data(contentsOf: env.storage)
    try expect(after == bytes && FileManager.default.fileExists(atPath: marker.path), "failed save preserves winner and old account files")
    try expect(stale.profiles.allSatisfy(\.isDefault), "failed creation does not add an in-memory account")
}

@MainActor
private func testInvalidRootAndCorruptStorageRemainUntouched() throws {
    for useSymlink in [false, true] {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try FileManager.default.createDirectory(at: env.managed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = env.managed.appendingPathComponent(LocalCLIKind.kimi.rawValue)
        let external = env.root.appendingPathComponent("untouched", isDirectory: true)
        if useSymlink {
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            guard Darwin.symlink(external.path, root.path) == 0 else { throw FixtureFailure.failed("fixture symlink") }
        } else {
            try Data("existing non-directory".utf8).write(to: root)
        }
        let store = env.store()
        store.discover()
        try expect(store.createAccount(kind: .kimi, name: "Cannot Create") == nil, "unsafe provider root cannot be adopted")
        try expect(!FileManager.default.fileExists(atPath: env.storage.path), "failed directory creation is not persisted")
        if useSymlink {
            try expect(try children(external).isEmpty, "symlink target remains untouched")
        } else {
            let bytes = try Data(contentsOf: root)
            try expect(bytes == Data("existing non-directory".utf8), "existing file remains untouched")
        }
    }
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let corrupt = Data("not account JSON".utf8)
    try corrupt.write(to: env.storage)
    let store = env.store()
    store.discover()
    try expect(!store.canCreateAccount(kind: .openCode), "corrupt storage disables new writes")
    try expect(store.createAccount(kind: .openCode, name: "Cannot Create") == nil, "corrupt storage cannot be replaced by creation")
    let preserved = try Data(contentsOf: env.storage)
    try expect(preserved == corrupt && !FileManager.default.fileExists(atPath: env.managed.path), "corrupt storage and filesystem are preserved")
}

@main
struct LocalCLIAccountCreationFixture {
    @MainActor static func main() throws {
        try testMultipleAccountsPersistWithIndependentLaunchEnvironments()
        try testNamesAndSupportedProviders()
        try testWorkBuddyInstalledEditionOnly()
        try testFailedSaveRemovesOnlyNewAccountTree()
        try testInvalidRootAndCorruptStorageRemainUntouched()
        print("local-cli-account-creation-fixture: ok")
    }
}
