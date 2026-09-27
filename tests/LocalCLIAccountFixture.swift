import Darwin
import Foundation

enum WidgetLanguage {
    case zh
    static func storedOrAutomatic() -> WidgetLanguage { .zh }
    func text(_ zh: String, _ en: String) -> String { zh }
}

private enum FixtureFailure: Error { case failed(String) }

// These persistence tests never open Terminal or perform authentication.
enum LocalCLITerminalLauncher {
    @MainActor static var permitsSyntheticSession = false
    @MainActor static var launchCount = 0
    enum Action { case signIn, open }
    struct Session {}
    @MainActor static func launch(profile: LocalCLIProfile, executable: String, action: Action, workingDirectory: URL) async throws -> Session {
        if permitsSyntheticSession {
            launchCount += 1
            return Session()
        }
        throw FixtureFailure.failed("interactive launcher must not run in the persistence fixture")
    }
    @MainActor static func waitForExit(_ session: Session) async throws -> Int32 {
        if permitsSyntheticSession {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return 0
        }
        throw FixtureFailure.failed("interactive launcher must not run in the persistence fixture")
    }
}

private func unsupportedQuota(_ profile: LocalCLIProfile) -> LocalCLIQuotaResult {
    LocalCLIQuotaResult(
        state: .unsupported,
        fetchedAt: Date(),
        maskedIdentity: nil,
        identityFingerprint: nil,
        planLabel: nil,
        windows: [],
        balance: nil,
        balanceCurrency: nil,
        sourceLabel: profile.kind.displayName,
        messageCode: "synthetic_unsupported")
}

struct LocalCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { unsupportedQuota(profile) }
}

struct AdditionalCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { unsupportedQuota(profile) }
}

struct ZCodeCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { unsupportedQuota(profile) }
}

struct AntigravityCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { unsupportedQuota(profile) }
    static func hasLinkedCache(at root: URL) -> Bool { false }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure.failed(message) }
}

@MainActor
private func makeRoot(_ label: String) throws -> (root: URL, home: URL, support: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "local-cli-account-\(label)-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/bin"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let zcode = applications.appendingPathComponent("ZCode.app", isDirectory: true)
    let zcodeElectron = zcode.appendingPathComponent("Contents/MacOS/ZCode")
    try FileManager.default.createDirectory(at: zcodeElectron.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.zcode.app", "CFBundleExecutable": "ZCode"], format: .xml, options: 0).write(to: zcode.appendingPathComponent("Contents/Info.plist"))
    try Data("synthetic electron".utf8).write(to: zcodeElectron)
    guard chmod(zcodeElectron.path, 0o700) == 0 else { throw FixtureFailure.failed("chmod ZCode runner") }

    let workBuddy = applications.appendingPathComponent("WorkBuddy.app", isDirectory: true)
    let workBuddyCLI = workBuddy.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/bin/codebuddy")
    let workBuddyProduct = workBuddy.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/product.json")
    let workBuddyElectron = workBuddy.appendingPathComponent("Contents/MacOS/Electron")
    try FileManager.default.createDirectory(at: workBuddyCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workBuddyElectron.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("synthetic workbuddy entry".utf8).write(to: workBuddyCLI)
    try Data("{}".utf8).write(to: workBuddyProduct)
    try Data("synthetic electron".utf8).write(to: workBuddyElectron)
    guard chmod(workBuddyCLI.path, 0o700) == 0, chmod(workBuddyElectron.path, 0o700) == 0 else {
        throw FixtureFailure.failed("chmod WorkBuddy bundle")
    }

    try FileManager.default.copyItem(at: workBuddy, to: applications.appendingPathComponent("WorkBuddy AI.app"))

    let externalCodeBuddy = home.appendingPathComponent(".local/bin/codebuddy")
    try Data("synthetic external product".utf8).write(to: externalCodeBuddy)
    guard chmod(externalCodeBuddy.path, 0o700) == 0 else { throw FixtureFailure.failed("chmod external codebuddy") }
    return (root, home, support)
}

@MainActor
private func makeStore(home: URL, support: URL,
                       loader: @escaping LocalCLIAccountStore.QuotaLoader = { profile in
                           LocalCLIQuotaResult(state: .unsupported, fetchedAt: Date(), maskedIdentity: nil,
                                               identityFingerprint: nil, planLabel: nil, windows: [],
                                               balance: nil, balanceCurrency: nil,
                                               sourceLabel: profile.kind.displayName, messageCode: nil)
                       },
                       clock: @escaping @Sendable () -> Date = { Date() }) -> LocalCLIAccountStore {
    LocalCLIAccountStore(
        home: home,
        support: support,
        applicationsDirectory: home.appendingPathComponent("empty-system-applications", isDirectory: true),
        quotaLoader: loader,
        clock: clock)
}

private func storage(_ support: URL) -> URL {
    support.appendingPathComponent("local-cli-accounts-v1.json")
}

@MainActor
private func testDiscoveryLinkRenameUnlinkAndPermissions() async throws {
    let paths = try makeRoot("lifecycle")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = makeStore(home: paths.home, support: paths.support)
    store.discover()
    let applications = paths.home.appendingPathComponent("Applications", isDirectory: true)
    try expect(
        store.installed[.zcode] == applications.appendingPathComponent(
            "ZCode.app").path,
        "bundled ZCode discovery")
    try expect(
        store.installed[.workBuddy] == applications.appendingPathComponent(
            "WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy").path,
        "bundled WorkBuddy discovery does not substitute external codebuddy")
    let workBuddyProfiles = store.profiles(for: .workBuddy)
    try expect(
        workBuddyProfiles.count == 2 && Set(workBuddyProfiles.map(\.id)).count == 2,
        "domestic and international defaults remain distinct")
    for edition in WorkBuddyEdition.allCases {
        guard let profile = workBuddyProfiles.first(where: { $0.id == edition.defaultProfileID }) else {
            throw FixtureFailure.failed("WorkBuddy edition profile missing")
        }
        try expect(
            profile.configDirectory == paths.home.appendingPathComponent(edition.directoryName).path,
            "each edition owns its config directory")
        try expect(
            store.executable(for: profile)
                == applications.appendingPathComponent(
                    edition.applicationName + "/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"
                ).path,
            "each edition launches its own bundle")
    }
    let defaults = store.profiles(for: .zcode)
    try expect(defaults.count == 1 && defaults[0].isDefault, "default profile discovery")

    let account = paths.root.appendingPathComponent("linked z'code", isDirectory: true)
    let credential = account.appendingPathComponent("v2/config.json")
    try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let credentialBytes = Data("{\"synthetic\":true}".utf8)
    try credentialBytes.write(to: credential)
    store.link(kind: .zcode, directory: account, name: "Plan A")
    guard let linked = store.profiles(for: .zcode).first(where: { !$0.isDefault }) else {
        throw FixtureFailure.failed("linked profile")
    }
    try expect(!store.canSignIn(defaults[0]) && store.canOpen(defaults[0]),
               "default ZCode opens desktop only without any bundled CLI")
    try expect(!store.canSignIn(linked) && !store.canOpen(linked),
               "linked ZCode remains quota-only")

    let symlink = paths.root.appendingPathComponent("linked-zcode-symlink", isDirectory: true)
    guard Darwin.symlink(account.path, symlink.path) == 0 else {
        throw FixtureFailure.failed("create synthetic directory symlink")
    }
    let countBeforeSymlink = store.profiles(for: .zcode).count
    store.link(kind: .zcode, directory: symlink, name: "Symlink")
    try expect(store.profiles(for: .zcode).count == countBeforeSymlink,
               "linked directory symlink is rejected")
    try expect(UUID(uuidString: linked.id) != nil, "generated UUID profile ID")
    store.rename(linked, name: "Plan Renamed")
    guard let renamed = store.profiles(for: .zcode).first(where: { !$0.isDefault }) else {
        throw FixtureFailure.failed("renamed profile")
    }
    try expect(renamed.displayName == "Plan Renamed" && renamed.id == linked.id, "rename persistence")

    var info = stat()
    try expect(lstat(storage(paths.support).path, &info) == 0 && info.st_mode & 0o077 == 0,
               "account-link file is private")
    let persisted = try JSONDecoder().decode([LocalCLIProfile].self,
                                              from: Data(contentsOf: storage(paths.support)))
    try expect(persisted == [renamed], "only explicit links are persisted")

    store.unlink(renamed)
    try expect(store.profiles(for: .zcode).allSatisfy(\.isDefault), "unlink keeps default only")
    let retainedCredential = try Data(contentsOf: credential)
    try expect(retainedCredential == credentialBytes, "unlink does not delete credentials")
    let afterUnlink = try JSONDecoder().decode([LocalCLIProfile].self,
                                                from: Data(contentsOf: storage(paths.support)))
    try expect(afterUnlink.isEmpty, "unlink persistence")
}

@MainActor
private func testWorkBuddyInternationalOnlyDiscovery() throws {
    let paths = try makeRoot("international-only")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try FileManager.default.removeItem(at: paths.home.appendingPathComponent("Applications/WorkBuddy.app"))
    let store = makeStore(home: paths.home, support: paths.support)
    store.discover()
    let profiles = store.profiles(for: .workBuddy)
    try expect(
        profiles.count == 1 && profiles[0].id == "local-workBuddy-ai",
        "international-only installation has no false domestic profile")
    try expect(
        store.installed[.workBuddy] == store.executable(for: profiles[0]),
        "international bundle remains accessible from workspace navigation")
    try expect(
        store.canOpen(profiles[0]) && store.canSignIn(profiles[0]),
        "international login and TUI are exposed")
}

@MainActor
private func testStaleWriterConflictPreservesWinner() async throws {
    let paths = try makeRoot("conflict")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let first = makeStore(home: paths.home, support: paths.support)
    let stale = makeStore(home: paths.home, support: paths.support)
    first.discover(); stale.discover()
    let one = paths.root.appendingPathComponent("one", isDirectory: true)
    let two = paths.root.appendingPathComponent("two", isDirectory: true)
    try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
    first.link(kind: .zcode, directory: one, name: "Winner")
    let winningBytes = try Data(contentsOf: storage(paths.support))
    stale.link(kind: .zcode, directory: two, name: "Stale")
    try expect(stale.message != nil, "stale writer reports conflict")
    let afterConflict = try Data(contentsOf: storage(paths.support))
    try expect(afterConflict == winningBytes, "stale writer preserves winner bytes")
}

@MainActor
private func testInvalidStoredProfilesRemainUntouched() async throws {
    for (label, profile) in [
        ("invalid-id", LocalCLIProfile(id: "not-a-uuid", kind: .zcode, displayName: "Invalid",
                                       configDirectory: "/synthetic/independent", isDefault: false)),
        ("default-collision", LocalCLIProfile(id: UUID().uuidString, kind: .zcode, displayName: "Collision",
                                              configDirectory: "/placeholder", isDefault: false)),
    ] {
        let paths = try makeRoot(label)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var seeded = profile
        if label == "default-collision" {
            seeded.configDirectory = LocalCLIKind.zcode.defaultConfigDirectory(home: paths.home).path
        }
        let bytes = try JSONEncoder().encode([seeded])
        try bytes.write(to: storage(paths.support), options: .atomic)
        guard chmod(storage(paths.support).path, 0o600) == 0 else {
            throw FixtureFailure.failed("chmod seed")
        }
        let store = makeStore(home: paths.home, support: paths.support)
        store.discover()
        try expect(store.message != nil, "invalid stored profile rejected")
        let discoveredBytes = try Data(contentsOf: storage(paths.support))
        try expect(discoveredBytes == bytes, "invalid source preserved")
        let newDirectory = paths.root.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        store.link(kind: .zcode, directory: newDirectory, name: "Must Not Save")
        let finalBytes = try Data(contentsOf: storage(paths.support))
        try expect(finalBytes == bytes, "invalid storage blocks later mutation")
    }
}

@MainActor
private func testUnlinkRejectsLateRefresh() async throws {
    let paths = try makeRoot("late-refresh")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = makeStore(home: paths.home, support: paths.support, loader: { _ in
        try? await Task.sleep(nanoseconds: 150_000_000)
        return LocalCLIQuotaResult(state: .available, fetchedAt: Date(), maskedIdentity: nil,
                                   identityFingerprint: nil, planLabel: "Synthetic", windows: [],
                                   balance: nil, balanceCurrency: nil, sourceLabel: "Synthetic", messageCode: nil)
    })
    store.discover()
    let account = paths.root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
    store.link(kind: .zcode, directory: account, name: "Late")
    guard let linked = store.profiles(for: .zcode).first(where: { !$0.isDefault }) else {
        throw FixtureFailure.failed("late profile")
    }
    store.refresh(linked)
    store.unlink(linked)
    try await Task.sleep(nanoseconds: 250_000_000)
    try expect(store.quotas[linked.id] == nil && !store.refreshing.contains(linked.id),
               "unlinked profile rejects late refresh")
}

@MainActor
private func testRediscoveryRemovesOtherWritersAccountState() async throws {
    let paths = try makeRoot("rediscovery")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = makeStore(home: paths.home, support: paths.support, loader: { _ in
        LocalCLIQuotaResult(state: .available, fetchedAt: Date(), maskedIdentity: nil,
                            identityFingerprint: nil, planLabel: "Synthetic", windows: [],
                            balance: nil, balanceCurrency: nil, sourceLabel: "Synthetic", messageCode: nil)
    })
    store.discover()
    let directory = paths.root.appendingPathComponent("shared-link", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store.link(kind: .zcode, directory: directory, name: "Shared")
    guard let linked = store.profiles(for: .zcode).first(where: { !$0.isDefault }) else {
        throw FixtureFailure.failed("shared profile")
    }
    store.refresh(linked)
    for _ in 0..<100 where store.refreshing.contains(linked.id) {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try expect(store.quotas[linked.id]?.state == .available, "original account has loaded quota")
    let other = makeStore(home: paths.home, support: paths.support)
    other.discover()
    other.unlink(linked)
    store.discover()
    try expect(!store.profiles.contains(where: { $0.id == linked.id })
               && store.quotas[linked.id] == nil && !store.refreshing.contains(linked.id)
               && !store.stale.contains(linked.id), "rediscovery clears removed account runtime state")
}

@MainActor
private func testManagedGrokIsolationAndStaleWriter() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/tmp/ng" + String(UUID().uuidString.prefix(7)), isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let home = root.appendingPathComponent("h", isDirectory: true)
    let support = root.appendingPathComponent("s", isDirectory: true)
    let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    try fm.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let executable = bin.appendingPathComponent("grok")
    try Data("synthetic executable".utf8).write(to: executable)
    guard chmod(executable.path, 0o700) == 0 else { throw FixtureFailure.failed("Grok executable mode") }
    let first = makeStore(home: home, support: support)
    let stale = makeStore(home: home, support: support)
    first.discover(); stale.discover()
    guard let account = first.createGrokAccount(name: "Work") else {
        let expected = home.appendingPathComponent(".codex-account-manager-next/grok")
        throw FixtureFailure.failed("create Grok environment: installed=\(first.installed[.grok] != nil), normalized=\(expected.standardizedFileURL.path == expected.path), resolved=\(expected.resolvingSymlinksInPath().path == expected.path), message=\(first.message ?? "none")")
    }
    let directory = URL(fileURLWithPath: account.configDirectory)
    let attributes = try fm.attributesOfItem(atPath: directory.path)
    try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Grok private directory mode")
    try expect(account.configDirectory != LocalCLIKind.grok.defaultConfigDirectory(home: home).path, "Grok default login stays separate")
    let winner = try Data(contentsOf: storage(support))
    try expect(stale.createGrokAccount(name: "Stale") == nil, "stale Grok create rejected")
    let after = try Data(contentsOf: storage(support))
    try expect(after == winner, "stale Grok create preserves saved accounts")
    let auth = directory.appendingPathComponent("auth.json")
    try Data("synthetic retained credential".utf8).write(to: auth)
    first.unlink(account)
    try expect(fm.fileExists(atPath: auth.path), "unlink preserves Grok CLI-owned credentials")
}

private actor QuotaReadSequence {
    private var states: [LocalCLIQuotaState] = [.available, .unavailable, .needsLogin, .available]
    func next() -> LocalCLIQuotaResult {
        LocalCLIQuotaResult(state: states.removeFirst(), fetchedAt: Date(), maskedIdentity: nil,
                            identityFingerprint: nil, planLabel: "Synthetic", windows: [],
                            balance: nil, balanceCurrency: nil, sourceLabel: "Synthetic", messageCode: nil)
    }
}

@MainActor
private func testTransientFailureAndConfirmedSignOut() async throws {
    let paths = try makeRoot("read-state")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let sequence = QuotaReadSequence()
    let store = makeStore(home: paths.home, support: paths.support, loader: { _ in await sequence.next() })
    store.discover()
    let directory = paths.root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store.link(kind: .zcode, directory: directory, name: "Synthetic")
    guard let linked = store.profiles(for: .zcode).first(where: { !$0.isDefault }) else {
        throw FixtureFailure.failed("synthetic linked profile")
    }
    for (expected, isStale) in [(LocalCLIQuotaState.available, false), (.available, true), (.needsLogin, false), (.available, false)] {
        store.refresh(linked)
        for _ in 0..<100 where store.refreshing.contains(linked.id) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(store.quotas[linked.id]?.state == expected, "read state updates without retaining a false login")
        try expect(store.stale.contains(linked.id) == isStale, "only temporary failure retains stale quota")
        try expect(store.profiles.contains(where: { $0.id == linked.id }), "sign-out preserves saved account identity")
    }
}

@MainActor
private func testAuthenticationWithoutQuotaOrTerminalExit() async throws {
    let paths = try makeRoot("authentication")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let directory = paths.home.appendingPathComponent(".gemini", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = paths.home.appendingPathComponent(".local/bin/gemini")
    try Data("synthetic executable".utf8).write(to: executable)
    _ = chmod(executable.path, 0o700)
    try Data(#"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#.utf8).write(to: directory.appendingPathComponent("settings.json"))
    let store = makeStore(home: paths.home, support: paths.support)
    store.discover()
    guard let profile = store.profiles(for: .gemini).first else { throw FixtureFailure.failed("Gemini profile") }
    try expect(!store.hasConfiguredAuthentication(profile), "selected API mode alone cannot prove a saved key")
    LocalCLITerminalLauncher.permitsSyntheticSession = true
    defer { LocalCLITerminalLauncher.permitsSyntheticSession = false }
    store.signIn(profile)
    for _ in 0..<8 { await Task.yield() }
    try expect(store.signingIn.contains(profile.id), "interactive terminal remains open before credentials exist")
    let credentials = Data("GEMINI_API_KEY=synthetic-local-key\n".utf8)
    let env = directory.appendingPathComponent(".env")
    try credentials.write(to: env)
    for _ in 0..<60 where store.signingIn.contains(profile.id) { try await Task.sleep(nanoseconds: 50_000_000) }
    try expect(!store.signingIn.contains(profile.id), "saved Gemini API key ends authorization waiting without terminal exit")
    try expect(store.authentication[profile.id] == .apiKey, "API auth is recognized independently of Google quota")
    try expect(store.canOpen(profile), "configured CLI can open without quota")
    let after = try Data(contentsOf: env)
    try expect(after == credentials, "credential checks never change the user's key")
    var reader = LocalCLIAuthenticationReader()
    reader.keychainReader = { _, _ in nil }
    reader.fileReader = { url in
        if url.lastPathComponent == "settings.json" { return Data(#"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#.utf8) }
        if url.lastPathComponent == "oauth_creds.json" { return Data(#"{"refresh_token":"old-oauth"}"#.utf8) }
        return nil
    }
    try expect(reader.read(profile) == .unknown, "API selection cannot borrow an old Google OAuth credential")
    let opencode = LocalCLIProfile(id: "synthetic", kind: .openCode, displayName: "Synthetic", configDirectory: directory.path, isDefault: false)
    reader.fileReader = { _ in Data(#"{"anthropic":{"type":"oauth","refresh":"synthetic"},"provider":{"type":"api","key":"synthetic"},"invalid":{"type":"api","key":""}}"#.utf8) }
    try expect(reader.read(opencode) == .providers(2), "OpenCode provider credentials do not require OpenCode Go")
    try expect(!LocalCLIAuthenticationReader.hasEnvironmentValue("GEMINI_API_KEY=''\n# GEMINI_API_KEY=x", names: ["GEMINI_API_KEY"]), "empty or commented API keys stay unknown")
}

@MainActor
private func testOpenCodeReusesSavedProviderUnlessUpdateRequested() async throws {
    let paths = try makeRoot("opencode-reuse")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let directory = LocalCLIKind.openCode.defaultConfigDirectory(home: paths.home)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = paths.home.appendingPathComponent(".local/bin/opencode")
    try Data("synthetic executable".utf8).write(to: executable)
    _ = chmod(executable.path, 0o700)
    let auth = directory.appendingPathComponent("auth.json")
    let credentials = Data(#"{"provider":{"type":"api","key":"synthetic-saved-provider"}}"#.utf8)
    try credentials.write(to: auth)
    let store = makeStore(home: paths.home, support: paths.support)
    store.discover()
    guard let profile = store.profiles(for: .openCode).first else { throw FixtureFailure.failed("OpenCode profile") }
    try expect(store.authentication[profile.id] == .providers(1), "saved provider is recognized without OpenCode Go quota")
    LocalCLITerminalLauncher.permitsSyntheticSession = true
    LocalCLITerminalLauncher.launchCount = 0
    defer { LocalCLITerminalLauncher.permitsSyntheticSession = false }
    store.signIn(profile)
    for _ in 0..<8 { await Task.yield() }
    try expect(LocalCLITerminalLauncher.launchCount == 0 && store.signingIn.isEmpty,
               "default sign-in reuses saved providers without reopening authentication")
    try expect(store.canOpen(profile) && store.loginMessages[profile.id]?.contains("已复用") == true,
               "reused provider remains openable even when quota is unavailable")
    store.signIn(profile, updateProvider: true)
    for _ in 0..<100 where LocalCLITerminalLauncher.launchCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
    try expect(LocalCLITerminalLauncher.launchCount == 1,
               "an explicit provider update still opens the official authentication entry")
    store.checkLocalSignIns()
    try expect(store.signingIn.isEmpty, "an existing credential never leaves the checklist waiting for terminal exit")
    let after = try Data(contentsOf: auth)
    try expect(after == credentials, "reuse and provider-update launch never rewrite stored credentials")
}

@MainActor
private func testRenameKeepsOrderAndReportsFailure() throws {
    let paths = try makeRoot("rename-order")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = makeStore(home: paths.home, support: paths.support)
    store.discover()
    for name in ["first", "second"] {
        let directory = paths.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store.link(kind: .zcode, directory: directory, name: name)
    }
    let before = store.profiles(for: .zcode).filter { !$0.isDefault }
    guard before.count == 2 else { throw FixtureFailure.failed("rename fixtures missing") }
    try expect(store.rename(before[0], name: "renamed"), "successful rename reports success")
    let after = store.profiles(for: .zcode).filter { !$0.isDefault }
    try expect(after.map(\.id) == before.map(\.id), "renaming first account cannot move it to the end")
    let saved = try Data(contentsOf: storage(paths.support))
    try expect(!store.rename(after[0], name: ""), "invalid rename reports failure")
    try expect(tryData(storage(paths.support)) == saved, "invalid rename leaves persisted bytes unchanged")
    try Data("corrupt".utf8).write(to: storage(paths.support))
    try expect(!store.rename(after[0], name: "must-not-save"), "write conflict reports failure")
    try expect(store.profiles(for: .zcode).filter { !$0.isDefault } == after, "failed rename cannot change visible state")
}

private func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private actor VisibleQuotaProbe {
    enum Mode { case credentialDriven, alwaysAvailable, availableThenUnavailable, rateLimited }
    private let mode: Mode
    private var reads: [String: Int] = [:]

    init(mode: Mode) { self.mode = mode }

    func count(_ id: String) -> Int { reads[id, default: 0] }

    func load(_ profile: LocalCLIProfile, now: Date) async -> LocalCLIQuotaResult {
        reads[profile.id, default: 0] += 1
        let readNumber = reads[profile.id, default: 0]
        try? await Task.sleep(nanoseconds: 20_000_000)
        let credential = URL(fileURLWithPath: profile.configDirectory)
            .appendingPathComponent("credentials/kimi-code.json")
        let state: LocalCLIQuotaState = switch mode {
        case .credentialDriven: FileManager.default.fileExists(atPath: credential.path) ? .available : .needsLogin
        case .alwaysAvailable: .available
        case .availableThenUnavailable: readNumber == 1 ? .available : .unavailable
        case .rateLimited: .rateLimited
        }
        return LocalCLIQuotaResult(
            state: state, fetchedAt: now, maskedIdentity: nil,
            identityFingerprint: state == .available ? "synthetic-\(profile.id)" : nil,
            planLabel: nil,
            windows: state == .available
                ? [LocalCLIQuotaWindow(id: "weekly", label: "7-day", usedPercent: 12, resetsAt: nil)] : [],
            balance: nil, balanceCurrency: nil, sourceLabel: "Synthetic", messageCode: nil)
    }
}

@MainActor
private func syntheticKimiStore(_ paths: (root: URL, home: URL, support: URL),
                                clock: FixtureClock, probe: VisibleQuotaProbe) throws -> LocalCLIAccountStore {
    let executable = paths.home.appendingPathComponent(".local/bin/kimi")
    try Data("synthetic executable".utf8).write(to: executable)
    guard chmod(executable.path, 0o700) == 0 else { throw FixtureFailure.failed("Kimi executable mode") }
    let store = makeStore(home: paths.home, support: paths.support,
                          loader: { profile in await probe.load(profile, now: clock.now()) },
                          clock: { clock.now() })
    store.discover()
    return store
}

private func writeSyntheticKimiCredential(_ directory: URL, marker: String = "one") throws {
    let credentials = directory.appendingPathComponent("credentials", isDirectory: true)
    try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
    let body = ["access_token": "synthetic-\(marker)", "refresh_token": "synthetic-refresh"]
    try JSONSerialization.data(withJSONObject: body).write(
        to: credentials.appendingPathComponent("kimi-code.json"), options: .atomic)
}

@MainActor
private func waitForVisibleRefresh(_ store: LocalCLIAccountStore, ids: [String]) async throws {
    for _ in 0..<100 {
        if ids.allSatisfy({ !store.refreshing.contains($0) }) { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw FixtureFailure.failed("visible quota refresh did not finish")
}

@MainActor
private func testVisibleKimiRefreshAfterExternalLogin() async throws {
    let paths = try makeRoot("visible-kimi")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = VisibleQuotaProbe(mode: .credentialDriven)
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    guard let profile = store.profiles(for: .kimi).first else { throw FixtureFailure.failed("Kimi profile") }

    store.refreshIfNeeded(kind: .kimi)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let firstReadCount = await probe.count(profile.id)
    try expect(store.quotas[profile.id]?.state == .needsLogin && firstReadCount == 1,
               "repeated focus shares the first quota read")
    store.refreshIfNeeded(kind: .kimi)
    let unchangedReadCount = await probe.count(profile.id)
    try expect(unchangedReadCount == 1, "unchanged sign-in failure is throttled")

    try writeSyntheticKimiCredential(URL(fileURLWithPath: profile.configDirectory))
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    try expect(store.authentication[profile.id] == .oauth && store.quotas[profile.id]?.state == .available,
               "external CLI credentials replace stale needsLogin on the next visible check")
    let recoveredReadCount = await probe.count(profile.id)
    try expect(recoveredReadCount == 2, "credential change bypasses failure retry delay")
    clock.advance(299)
    store.refreshIfNeeded(kind: .kimi)
    let freshReadCount = await probe.count(profile.id)
    try expect(freshReadCount == 2, "fresh success is reused for five minutes")
    clock.advance(1)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let agedReadCount = await probe.count(profile.id)
    try expect(agedReadCount == 3, "success is refreshed after five minutes")
}

@MainActor
private func testVisibleKimiLinkedProfilesStayIsolated() async throws {
    let paths = try makeRoot("visible-linked-kimi")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = VisibleQuotaProbe(mode: .credentialDriven)
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    let firstDirectory = paths.root.appendingPathComponent("first", isDirectory: true)
    let secondDirectory = paths.root.appendingPathComponent("second", isDirectory: true)
    try writeSyntheticKimiCredential(firstDirectory)
    try writeSyntheticKimiCredential(secondDirectory)
    store.link(kind: .kimi, directory: firstDirectory, name: "First")
    store.link(kind: .kimi, directory: secondDirectory, name: "Second")
    guard let first = store.profiles(for: .kimi).first(where: { $0.configDirectory == firstDirectory.path }),
        let second = store.profiles(for: .kimi).first(where: { $0.configDirectory == secondDirectory.path })
    else { throw FixtureFailure.failed("linked Kimi profiles") }

    store.refreshIfNeeded()
    try await waitForVisibleRefresh(store, ids: [first.id, second.id])
    let firstInitialCount = await probe.count(first.id)
    let secondInitialCount = await probe.count(second.id)
    try expect(firstInitialCount == 1 && secondInitialCount == 1,
               "all-provider check reads both selected linked directories")
    try writeSyntheticKimiCredential(firstDirectory, marker: "updated-longer")
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [first.id])
    let firstChangedCount = await probe.count(first.id)
    let secondUnchangedCount = await probe.count(second.id)
    try expect(firstChangedCount == 2 && secondUnchangedCount == 1,
               "one linked credential change cannot refresh another profile")
    store.unlink(first)
    store.refreshIfNeeded(kind: .kimi)
    let unlinkedReadCount = await probe.count(first.id)
    try expect(unlinkedReadCount == 2 && store.quotas[first.id] == nil,
               "unlink removes pending refresh evidence and cached quota")
}

@MainActor
private func testVisibleKimiRateLimitBackoff() async throws {
    let paths = try makeRoot("visible-rate-limit")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = VisibleQuotaProbe(mode: .rateLimited)
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    guard let profile = store.profiles(for: .kimi).first else { throw FixtureFailure.failed("Kimi profile") }
    try writeSyntheticKimiCredential(URL(fileURLWithPath: profile.configDirectory))
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let firstRateLimitCount = await probe.count(profile.id)
    try expect(store.quotas[profile.id]?.state == .rateLimited && firstRateLimitCount == 1,
               "first rate limit is retained")
    clock.advance(60)
    try writeSyntheticKimiCredential(URL(fileURLWithPath: profile.configDirectory), marker: "rotated")
    store.refreshIfNeeded(kind: .kimi)
    let heldRateLimitCount = await probe.count(profile.id)
    try expect(heldRateLimitCount == 1, "page focus and credential rotation respect 429 backoff")
    clock.advance(840)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let retriedRateLimitCount = await probe.count(profile.id)
    try expect(retriedRateLimitCount == 2, "429 retry resumes after fifteen minutes")
}

@MainActor
private func testCredentialRotationDuringReadDropsOldQuota() async throws {
    let paths = try makeRoot("rotating-kimi")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = VisibleQuotaProbe(mode: .credentialDriven)
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    guard let profile = store.profiles(for: .kimi).first else { throw FixtureFailure.failed("Kimi profile") }
    let directory = URL(fileURLWithPath: profile.configDirectory)
    try writeSyntheticKimiCredential(directory)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    try expect(store.quotas[profile.id]?.state == .available, "first account quota loaded")

    clock.advance(300)
    store.refreshIfNeeded(kind: .kimi)
    var secondReadStarted = false
    for _ in 0..<100 {
        if await probe.count(profile.id) == 2 {
            secondReadStarted = true
            break
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    try expect(secondReadStarted, "second request entered loader")
    try writeSyntheticKimiCredential(directory, marker: "replacement-longer")
    try await waitForVisibleRefresh(store, ids: [profile.id])
    try expect(store.quotas[profile.id] == nil && !store.stale.contains(profile.id),
               "credential rotation discards both in-flight result and old account cache")
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let recoveredCount = await probe.count(profile.id)
    try expect(recoveredCount == 3 && store.quotas[profile.id]?.state == .available,
               "next visible check reads the replacement credential")
}

@MainActor
private func testFailedNewAccountReadNeverKeepsOldQuota() async throws {
    let paths = try makeRoot("changed-kimi-failure")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = VisibleQuotaProbe(mode: .availableThenUnavailable)
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    guard let profile = store.profiles(for: .kimi).first else { throw FixtureFailure.failed("Kimi profile") }
    let directory = URL(fileURLWithPath: profile.configDirectory)
    try writeSyntheticKimiCredential(directory, marker: "account-a")
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    try expect(store.quotas[profile.id]?.state == .available
               && store.quotas[profile.id]?.identityFingerprint != nil,
               "account A has a verified quota before rotation")

    try writeSyntheticKimiCredential(directory, marker: "account-b-longer")
    store.refreshIfNeeded(kind: .kimi)
    try expect(store.quotas[profile.id] == nil && !store.stale.contains(profile.id),
               "account A quota is cleared before querying account B")
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let readCount = await probe.count(profile.id)
    try expect(readCount == 2 && store.quotas[profile.id]?.state == .unavailable
               && store.quotas[profile.id]?.identityFingerprint == nil,
               "failed account B query cannot restore account A quota or identity")
}

@MainActor
private func testZCodeCredentialFilesInvalidateFreshQuota() async throws {
    let paths = try makeRoot("visible-zcode")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = VisibleQuotaProbe(mode: .alwaysAvailable)
    let store = makeStore(home: paths.home, support: paths.support,
                          loader: { profile in await probe.load(profile, now: clock.now()) },
                          clock: { clock.now() })
    store.discover()
    guard let profile = store.profiles(for: .zcode).first else { throw FixtureFailure.failed("ZCode profile") }
    store.refreshIfNeeded(kind: .zcode)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    for (index, name) in ["setting.json", "config.json", "credentials.json"].enumerated() {
        let file = URL(fileURLWithPath: profile.configDirectory).appendingPathComponent("v2/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic \(index)".utf8).write(to: file)
        store.refreshIfNeeded(kind: .zcode)
        try await waitForVisibleRefresh(store, ids: [profile.id])
        let count = await probe.count(profile.id)
        try expect(count == index + 2, "ZCode \(name) invalidates fresh quota")
    }
    let preview = LocalCLIAccountStore.preview(profiles: [profile], quotas: [:], root: paths.root)
    preview.refreshIfNeeded(kind: .zcode)
    try expect(preview.refreshing.isEmpty && preview.quotas.isEmpty, "preview never schedules a quota read")
}

@main enum Main {
    @MainActor static func main() async throws {
        try await testDiscoveryLinkRenameUnlinkAndPermissions()
        try testRenameKeepsOrderAndReportsFailure()
        try testWorkBuddyInternationalOnlyDiscovery()
        try await testStaleWriterConflictPreservesWinner()
        try await testInvalidStoredProfilesRemainUntouched()
        try await testUnlinkRejectsLateRefresh()
        try await testRediscoveryRemovesOtherWritersAccountState()
        try testManagedGrokIsolationAndStaleWriter()
        try await testTransientFailureAndConfirmedSignOut()
        try await testAuthenticationWithoutQuotaOrTerminalExit()
        try await testOpenCodeReusesSavedProviderUnlessUpdateRequested()
        try await testVisibleKimiRefreshAfterExternalLogin()
        try await testVisibleKimiLinkedProfilesStayIsolated()
        try await testVisibleKimiRateLimitBackoff()
        try await testCredentialRotationDuringReadDropsOldQuota()
        try await testFailedNewAccountReadNeverKeepsOldQuota()
        try await testZCodeCredentialFilesInvalidateFreshQuota()
        print("local-cli-account-fixture: ok")
    }
}
