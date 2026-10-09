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
    @MainActor static var syntheticExitCode: Int32?
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
            while true {
                try Task.checkCancellation()
                if let code = syntheticExitCode { return code }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
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

private actor ClaudeCredentialReadSequence {
    private var calls = 0
    func next() -> LocalCLIQuotaResult {
        calls += 1
        let available = calls == 1
        return LocalCLIQuotaResult(
            state: available ? .available : .unavailable, fetchedAt: Date(), maskedIdentity: nil,
            identityFingerprint: available ? "synthetic-previous-identity" : nil, planLabel: nil,
            windows: available ? [.init(id: "session", label: "5-hour", usedPercent: 20, resetsAt: nil)] : [],
            balance: nil, balanceCurrency: nil, sourceLabel: "Synthetic",
            messageCode: available ? nil : "local_cli_claude_credentials_changed")
    }
}

@MainActor
private func testClaudeKeychainChangeClearsCachedIdentity() async throws {
    let paths = try makeRoot("claude-keychain-change")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let executable = paths.home.appendingPathComponent(".local/bin/claude")
    try Data("synthetic executable".utf8).write(to: executable)
    guard chmod(executable.path, 0o700) == 0 else { throw FixtureFailure.failed("synthetic Claude chmod") }
    let directory = paths.home.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // This synthetic home is not the system home, so no real Keychain is queried.
    try Data(#"{"claudeAiOauth":{"accessToken":"synthetic-local-token"}}"#.utf8)
        .write(to: directory.appendingPathComponent(".credentials.json"))
    let sequence = ClaudeCredentialReadSequence()
    let store = makeStore(home: paths.home, support: paths.support, loader: { _ in await sequence.next() })
    store.discover()
    guard let profile = store.profiles(for: .claudeCode).first else {
        throw FixtureFailure.failed("synthetic Claude profile missing")
    }
    store.refresh(profile)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    try expect(store.quotas[profile.id]?.identityFingerprint == "synthetic-previous-identity",
               "baseline synthetic identity is cached")
    store.refresh(profile)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    try expect(store.quotas[profile.id]?.state == .unavailable && store.quotas[profile.id]?.windows.isEmpty == true
               && store.quotas[profile.id]?.identityFingerprint == nil && !store.stale.contains(profile.id),
               "Keychain change clears the old quota and identity even without a file metadata change")
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
    for (env, expected) in [
        ("GOOGLE_API_KEY=synthetic-vertex-key\n", LocalCLIAuthentication.unknown),
        ("GEMINI_API_KEY=synthetic-gemini-key\n", LocalCLIAuthentication.apiKey),
    ] {
        reader.fileReader = { url in
            if url.lastPathComponent == "settings.json" { return Data(#"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#.utf8) }
            if url.lastPathComponent == ".env" { return Data(env.utf8) }
            return nil
        }
        try expect(reader.read(profile) == expected, "Gemini API mode does not borrow a Vertex-only key")
    }
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

private actor SuspendedQuotaProbe {
    private var observations: [String: [String?]] = [:]
    private var held: [String: [Int: CheckedContinuation<Void, Never>]] = [:]
    private let rateLimitedReads: Set<Int>

    init(rateLimitedReads: Set<Int> = []) { self.rateLimitedReads = rateLimitedReads }

    func count(_ id: String) -> Int { observations[id]?.count ?? 0 }
    func token(_ id: String, read: Int) -> String? { observations[id]?[read - 1] ?? nil }
    func release(_ id: String, read: Int) { held[id]?.removeValue(forKey: read)?.resume() }

    func load(_ profile: LocalCLIProfile, now: Date) async -> LocalCLIQuotaResult {
        let credential = URL(fileURLWithPath: profile.configDirectory)
            .appendingPathComponent("credentials/kimi-code.json")
        let data = try? Data(contentsOf: credential)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let token = object?["access_token"] as? String
        let readNumber = (observations[profile.id]?.count ?? 0) + 1
        observations[profile.id, default: []].append(token)
        await withCheckedContinuation { continuation in
            held[profile.id, default: [:]][readNumber] = continuation
        }
        let state: LocalCLIQuotaState = rateLimitedReads.contains(readNumber)
            ? .rateLimited : token == nil ? .needsLogin : .available
        return LocalCLIQuotaResult(
            state: state, fetchedAt: now, maskedIdentity: nil,
            identityFingerprint: state == .available ? token : nil,
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

@MainActor
private func syntheticKimiStore(_ paths: (root: URL, home: URL, support: URL),
                                clock: FixtureClock, probe: SuspendedQuotaProbe) throws -> LocalCLIAccountStore {
    let executable = paths.home.appendingPathComponent(".local/bin/kimi")
    try Data("synthetic executable".utf8).write(to: executable)
    guard chmod(executable.path, 0o700) == 0 else { throw FixtureFailure.failed("Kimi executable mode") }
    let store = makeStore(home: paths.home, support: paths.support,
                          loader: { profile in await probe.load(profile, now: clock.now()) },
                          clock: { clock.now() })
    store.discover()
    return store
}

private func waitForProbeRead(_ probe: SuspendedQuotaProbe, id: String, count: Int) async throws {
    for _ in 0..<200 {
        if await probe.count(id) >= count { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw FixtureFailure.failed("synthetic quota read did not start")
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
    let probe = SuspendedQuotaProbe()
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    guard let profile = store.profiles(for: .kimi).first else { throw FixtureFailure.failed("Kimi profile") }
    let directory = URL(fileURLWithPath: profile.configDirectory)
    try writeSyntheticKimiCredential(directory)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForProbeRead(probe, id: profile.id, count: 1)
    await probe.release(profile.id, read: 1)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    try expect(store.quotas[profile.id]?.identityFingerprint == "synthetic-one", "first account quota loaded")

    clock.advance(300)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForProbeRead(probe, id: profile.id, count: 2)
    try writeSyntheticKimiCredential(directory, marker: "replacement-longer")
    await probe.release(profile.id, read: 2)
    try await waitForProbeRead(probe, id: profile.id, count: 3)
    try expect(store.quotas[profile.id] == nil && !store.stale.contains(profile.id),
               "credential rotation discards both in-flight result and old account cache")
    let replacementToken = await probe.token(profile.id, read: 3)
    try expect(replacementToken == "synthetic-replacement-longer", "automatic reread uses replacement credential")
    await probe.release(profile.id, read: 3)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let recoveredCount = await probe.count(profile.id)
    try expect(recoveredCount == 3
               && store.quotas[profile.id]?.state == .available
               && store.quotas[profile.id]?.identityFingerprint == "synthetic-replacement-longer",
               "credential rotation clears the old cache and automatically reads the replacement")
}

@MainActor
private func testInFlightCredentialChangesClearVisibleQuotaAndCoalesce() async throws {
    let paths = try makeRoot("inflight-kimi")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = SuspendedQuotaProbe()
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    guard let profile = store.profiles(for: .kimi).first else { throw FixtureFailure.failed("Kimi profile") }
    let directory = URL(fileURLWithPath: profile.configDirectory)
    try writeSyntheticKimiCredential(directory, marker: "account-a")
    store.refreshIfNeeded(kind: .kimi)
    try await waitForProbeRead(probe, id: profile.id, count: 1)
    await probe.release(profile.id, read: 1)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    try expect(store.quotas[profile.id]?.identityFingerprint == "synthetic-account-a", "account A quota loaded")

    clock.advance(300)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForProbeRead(probe, id: profile.id, count: 2)
    try writeSyntheticKimiCredential(directory, marker: "account-b-longer")
    store.refresh(profile)
    try expect(store.quotas[profile.id] == nil, "manual refresh clears A during in-flight B switch")
    try writeSyntheticKimiCredential(directory, marker: "account-c-longest")
    store.refreshIfNeeded(kind: .kimi)
    store.refreshIfNeeded(kind: .kimi)
    let heldCount = await probe.count(profile.id)
    try expect(store.quotas[profile.id] == nil && heldCount == 2,
               "focus retains no A quota and does not overlap the in-flight read")
    await probe.release(profile.id, read: 2)
    try await waitForProbeRead(probe, id: profile.id, count: 3)
    let queuedToken = await probe.token(profile.id, read: 3)
    try expect(queuedToken == "synthetic-account-c-longest",
               "one queued read uses latest C credential")
    await probe.release(profile.id, read: 3)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let finalReadCount = await probe.count(profile.id)
    try expect(finalReadCount == 3
               && store.quotas[profile.id]?.identityFingerprint == "synthetic-account-c-longest",
               "C quota replaces A without a duplicate B read")
}

@MainActor
private func testInFlightCredentialRemovalNeverReusesOldQuota() async throws {
    let paths = try makeRoot("inflight-kimi-removal")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = SuspendedQuotaProbe()
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    guard let profile = store.profiles(for: .kimi).first else { throw FixtureFailure.failed("Kimi profile") }
    let directory = URL(fileURLWithPath: profile.configDirectory)
    let credential = directory.appendingPathComponent("credentials/kimi-code.json")
    try writeSyntheticKimiCredential(directory, marker: "account-a")
    store.refreshIfNeeded(kind: .kimi)
    try await waitForProbeRead(probe, id: profile.id, count: 1)
    await probe.release(profile.id, read: 1)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    try expect(store.quotas[profile.id]?.identityFingerprint == "synthetic-account-a", "account A initially visible")

    clock.advance(300)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForProbeRead(probe, id: profile.id, count: 2)
    try FileManager.default.removeItem(at: credential)
    store.refreshIfNeeded(kind: .kimi)
    try expect(store.quotas[profile.id] == nil, "foreground focus clears A before old request finishes")
    await probe.release(profile.id, read: 2)
    try await waitForProbeRead(probe, id: profile.id, count: 3)
    let queuedToken = await probe.token(profile.id, read: 3)
    try expect(queuedToken == nil, "queued read observes missing B credential")
    await probe.release(profile.id, read: 3)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let finalReadCount = await probe.count(profile.id)
    try expect(finalReadCount == 3 && store.quotas[profile.id]?.state == .needsLogin
               && store.quotas[profile.id]?.identityFingerprint == nil,
               "missing B credential cannot restore A quota or identity")
}

@MainActor
private func testQueuedCredentialRefreshCannotReviveDeletedProfile() async throws {
    let paths = try makeRoot("inflight-kimi-unlink")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = SuspendedQuotaProbe()
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    let directory = paths.root.appendingPathComponent("linked-kimi", isDirectory: true)
    try writeSyntheticKimiCredential(directory, marker: "account-a")
    store.link(kind: .kimi, directory: directory, name: "Linked")
    guard let profile = store.profiles(for: .kimi).first(where: { $0.configDirectory == directory.path })
    else { throw FixtureFailure.failed("linked Kimi profile") }
    store.refresh(profile)
    try await waitForProbeRead(probe, id: profile.id, count: 1)
    try writeSyntheticKimiCredential(directory, marker: "account-b-longer")
    store.refresh(profile)
    store.unlink(profile)
    await probe.release(profile.id, read: 1)
    try await Task.sleep(nanoseconds: 50_000_000)
    let readCount = await probe.count(profile.id)
    try expect(readCount == 1 && !store.profiles.contains(where: { $0.id == profile.id })
               && store.quotas[profile.id] == nil && !store.refreshing.contains(profile.id),
               "unlinked profile cannot publish or start a queued read")
}

@MainActor
private func testInFlightRateLimitPreservesBackoffAfterCredentialChange() async throws {
    let paths = try makeRoot("inflight-kimi-rate-limit")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = SuspendedQuotaProbe(rateLimitedReads: [2])
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    guard let profile = store.profiles(for: .kimi).first else { throw FixtureFailure.failed("Kimi profile") }
    let directory = URL(fileURLWithPath: profile.configDirectory)
    try writeSyntheticKimiCredential(directory, marker: "account-a")
    store.refreshIfNeeded(kind: .kimi)
    try await waitForProbeRead(probe, id: profile.id, count: 1)
    await probe.release(profile.id, read: 1)
    try await waitForVisibleRefresh(store, ids: [profile.id])

    clock.advance(300)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForProbeRead(probe, id: profile.id, count: 2)
    try writeSyntheticKimiCredential(directory, marker: "account-b-longer")
    store.refreshIfNeeded(kind: .kimi)
    try expect(store.quotas[profile.id] == nil, "rate-limited in-flight change clears old account quota")
    await probe.release(profile.id, read: 2)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let heldReadCount = await probe.count(profile.id)
    try expect(heldReadCount == 2, "429 response does not launch queued B read")
    clock.advance(899)
    store.refreshIfNeeded(kind: .kimi)
    let beforeDeadline = await probe.count(profile.id)
    try expect(beforeDeadline == 2, "focus cannot bypass the 429 backoff")
    clock.advance(1)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForProbeRead(probe, id: profile.id, count: 3)
    await probe.release(profile.id, read: 3)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let finalReadCount = await probe.count(profile.id)
    try expect(finalReadCount == 3 && store.quotas[profile.id]?.identityFingerprint == "synthetic-account-b-longer",
               "B refresh resumes once after the 429 deadline")
}

@MainActor
private func testKimiDeviceIDInvalidatesFreshQuota() async throws {
    let paths = try makeRoot("kimi-device-change")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let clock = FixtureClock()
    let probe = VisibleQuotaProbe(mode: .credentialDriven)
    let store = try syntheticKimiStore(paths, clock: clock, probe: probe)
    guard let profile = store.profiles(for: .kimi).first else { throw FixtureFailure.failed("Kimi profile") }
    let directory = URL(fileURLWithPath: profile.configDirectory)
    try writeSyntheticKimiCredential(directory)
    let deviceID = directory.appendingPathComponent("device_id")
    try Data("synthetic-device-a".utf8).write(to: deviceID, options: .atomic)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let initialReadCount = await probe.count(profile.id)
    try expect(initialReadCount == 1, "initial Kimi device input read")
    try Data("synthetic-device-b-longer".utf8).write(to: deviceID, options: .atomic)
    store.refreshIfNeeded(kind: .kimi)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let readCount = await probe.count(profile.id)
    try expect(readCount == 2, "device ID change invalidates fresh Kimi quota cache")
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

@MainActor
private func testConfiguredClaudeWithoutExecutable() async throws {
    let paths = try makeRoot("claude-api-discovery")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let directory = paths.home.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let settings = directory.appendingPathComponent("settings.json")
    let clock = FixtureClock()
    let probe = VisibleQuotaProbe(mode: .alwaysAvailable)
    let store = makeStore(home: paths.home, support: paths.support,
        loader: { profile in await probe.load(profile, now: clock.now()) }, clock: { clock.now() })
    try Data("{\"env\":{}}".utf8).write(to: settings)
    store.discover()
    try expect(store.profiles(for: .claudeCode).isEmpty, "empty settings do not invent a Claude account")
    try Data("{\"env\":{\"ANTHROPIC_AUTH_TOKEN\":\"synthetic-relay\"}}".utf8).write(to: settings, options: .atomic)
    store.discover()
    guard let profile = store.profiles(for: .claudeCode).first else { throw FixtureFailure.failed("configured Claude was hidden") }
    try expect(store.executable(for: profile) == nil && !store.canOpen(profile) && !store.canSignIn(profile),
               "balance discovery must not claim an installed CLI or enable launch")
    store.refreshIfNeeded(kind: .claudeCode)
    try await waitForVisibleRefresh(store, ids: [profile.id])
    let initialReads = await probe.count(profile.id)
    try expect(initialReads == 1, "configured Claude can refresh without its executable")
    let relay = paths.home.appendingPathComponent(".cc-switch", isDirectory: true)
    try FileManager.default.createDirectory(at: relay, withIntermediateDirectories: true)
    for (index, name) in ["cc-switch.db", "cc-switch.db-wal"].enumerated() {
        try Data("synthetic metadata \(index)".utf8).write(to: relay.appendingPathComponent(name))
        store.refreshIfNeeded(kind: .claudeCode)
        try expect(store.quotas[profile.id] == nil, "relay change immediately hides old account balance")
        try await waitForVisibleRefresh(store, ids: [profile.id])
        let reads = await probe.count(profile.id)
        try expect(reads == index + 2, "relay database and WAL changes invalidate fresh quota")
    }
    try expect(store.rename(profile, name: "My Claude CLI"), "configured-only profile preserves custom name")
    let executable = paths.home.appendingPathComponent(".local/bin/claude")
    try Data("synthetic executable".utf8).write(to: executable)
    guard chmod(executable.path, 0o700) == 0 else { throw FixtureFailure.failed("synthetic Claude chmod") }
    store.discover()
    guard let installed = store.profiles(for: .claudeCode).first else { throw FixtureFailure.failed("installed Claude profile") }
    try expect(installed.id == profile.id && installed.displayName == "My Claude CLI" && store.canOpen(installed),
               "installing the CLI keeps the same profile and custom name")
    var keychainReads = 0
    var reader = LocalCLIAuthenticationReader()
    reader.fileReader = { url in
        url.lastPathComponent == "settings.json"
            ? Data("{\"env\":{\"ANTHROPIC_AUTH_TOKEN\":\"synthetic-api\"}}".utf8) : nil
    }
    reader.keychainReader = { _, _ in keychainReads += 1; return nil }
    let systemProfile = LocalCLIProfile(id: "synthetic-system-claude", kind: .claudeCode,
        displayName: "Synthetic", configDirectory: LocalCLIKind.claudeCode.defaultConfigDirectory(
            home: FileManager.default.homeDirectoryForCurrentUser).path, isDefault: true)
    try expect(reader.read(systemProfile) == .apiKey && keychainReads == 0,
               "explicit API configuration is detected without a subscription Keychain request")
}


private enum ClaudeStoreTestFailure: Error { case synthetic, failed(String) }
private final class ClaudeStoreKeychain {
    var items: [String: Data] = [:]
    var breaksRollback = false
    func key(_ service: String, _ account: String) -> String { service + "|" + account }
    func read(_ service: String, _ account: String) throws -> Data? { items[key(service, account)] }
    func write(_ service: String, _ account: String, _ data: Data?) throws {
        if service == "Claude Code-credentials", breaksRollback {
            if String(decoding: data ?? Data(), as: UTF8.self).contains("synthetic-b") { items[key(service, account)] = data }
            throw ClaudeStoreTestFailure.synthetic
        }
        items[key(service, account)] = data
    }
}
private final class ClaudeStoreTransport: LocalCLIQuotaTransport, @unchecked Sendable {
    var calls = 0
    var profileCalls = 0
    var blocksProfileResponse = false
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        calls += 1
        let name = (request.value(forHTTPHeaderField: "Authorization") ?? "").contains("synthetic-b") ? "b" : "a"
        let body: String
        if request.url?.path.hasSuffix("profile") == true {
            profileCalls += 1
            while blocksProfileResponse { try await Task.sleep(nanoseconds: 5_000_000) }
            body = "{\"account\":{\"uuid\":\"synthetic-\(name)\",\"email\":\"\(name)@synthetic.invalid\"},\"organization\":{\"uuid\":\"synthetic-org\"}}"
        } else {
            body = #"{"five_hour":{"utilization":7,"resets_at":null},"seven_day":{"utilization":72,"resets_at":null},"limits":[{"kind":"weekly_all","group":"weekly","percent":72,"scope":null},{"kind":"weekly_scoped","group":"weekly","percent":41,"scope":{"model":{"id":null,"display_name":"Fable"}},"resets_at":"2030-01-02T00:00:00Z","is_active":true}]}"#
        }
        return .init(statusCode: 200, headers: [:], data: Data(body.utf8))
    }
}
@MainActor private func testClaudeSubscriptionStoreIdentityAndReaderIsolation() async throws {
    let paths = try makeRoot("claude-subscription-integration")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let claude = paths.home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let executable = paths.home.appendingPathComponent(".local/bin/claude")
    try Data("synthetic CLI".utf8).write(to: executable); _ = chmod(executable.path, 0o700)
    let keychain = ClaudeStoreKeychain(), transport = ClaudeStoreTransport()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var service = ClaudeSubscriptionService(home: paths.home, support: paths.support)
    service.dependencies = .init(readKeychain: keychain.read, writeKeychain: keychain.write, idle: { true }, transport: transport, now: { now })
    func credential(_ name: String) -> Data { Data("{\"claudeAiOauth\":{\"accessToken\":\"synthetic-\(name)\",\"expiresAt\":2000000000000}}".utf8) }
    let config = paths.home.appendingPathComponent(".claude.json")
    func setCurrent(_ name: String) throws {
        keychain.items[keychain.key("Claude Code-credentials", ClaudeSubscriptionService.keychainAccount)] = credential(name)
        try Data("{\"oauthAccount\":{\"accountUuid\":\"synthetic-\(name)\",\"organizationUuid\":\"synthetic-org\",\"emailAddress\":\"\(name)@synthetic.invalid\"}}".utf8).write(to: config, options: .atomic)
    }
    try setCurrent("a")
    var launches = 0
    var blocksOpen = false
    defer { blocksOpen = false }
    let store = LocalCLIAccountStore(home: paths.home, support: paths.support,
        applicationsDirectory: paths.home.appendingPathComponent("empty-system-applications"),
        claudeSubscriptionService: service,
        terminalOpener: { profile, _, _ in
            try expect(profile.isDefault && profile.kind == .claudeCode, "subscription launches verified official default")
            launches += 1
            while blocksOpen { try await Task.sleep(nanoseconds: 5_000_000) }
        }, clock: { now })
    store.discover()
    guard let a = await store.captureClaudeSubscription(name: "Synthetic A") else { throw ClaudeStoreTestFailure.failed("capture A") }
    try setCurrent("b")
    guard let b = await store.captureClaudeSubscription(name: "Synthetic B") else { throw ClaudeStoreTestFailure.failed("capture B") }
    func waitForActive(_ id: String) async throws {
        for _ in 0..<200 {
            store.discoverClaudeSubscriptions()
            if store.claudeActiveProfileID == id && !store.claudeIdentityUnavailable { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ClaudeStoreTestFailure.failed("active identity not reconciled")
    }
    try await waitForActive(b.id)
    try expect(store.canSwitchClaudeSubscription(a), "captured current identity permits switching")
    try setCurrent("a")
    store.refreshIfNeeded(kind: .claudeCode)
    try await waitForActive(a.id)
    try expect(store.canOpen(a) && !store.canOpen(b), "external sign-in refresh updates active subscription")
    let beforeReader = transport.calls
    let isolated = await LocalCLIQuotaReader(transport: transport).load(profile: a, now: now)
    try expect(isolated.state != .available && transport.calls == beforeReader, "injected reader never constructs real subscription service")
    try expect(LocalCLIAuthenticationReader().read(a) == .unknown, "uninjected auth reader never consults real subscription Keychain")
    let routed = await LocalCLIQuotaReader(transport: transport, claudeSubscriptionService: service).load(profile: a, now: now)
    try expect(routed.state == .available && routed.windows.count == 3 && routed.windows.last?.label == "Fable", "injected service reads separate 5h 7d and Fable without duplicated aggregate")
    try expect(LocalCLIAuthenticationReader(claudeSubscriptionService: service).read(a) == .oauth, "authentication uses injected native storage")
    store.refresh(a)
    for _ in 0..<200 {
        if !store.refreshing.contains(a.id) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try expect(store.quotas[a.id]?.windows.last?.label == "Fable", "store default reader retains explicit service dependency")
    let cswap = paths.home.appendingPathComponent(".claude-swap-backup")
    try FileManager.default.createDirectory(at: cswap, withIntermediateDirectories: true)
    try Data("broken synthetic sequence".utf8).write(to: cswap.appendingPathComponent("sequence.json"))
    store.discoverClaudeSubscriptions()
    try expect(store.claudeActiveProfileID == a.id && store.claudeSubscriptionCandidates.isEmpty, "damaged import list does not erase valid native identity")
    store.openCLI(a, workingDirectory: paths.home)
    try await Task.sleep(nanoseconds: 30_000_000)
    try expect(launches == 1, "verified active subscription can open once; " + (store.message ?? "no store error"))
    let globalSettings = claude.appendingPathComponent("settings.json")
    try Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"synthetic-route"}}"#.utf8).write(to: globalSettings)
    store.openCLI(a, workingDirectory: paths.home)
    try await Task.sleep(nanoseconds: 30_000_000)
    try expect(launches == 1, "API route introduced after discovery blocks subscription launcher")
    try FileManager.default.removeItem(at: globalSettings)
    try await waitForActive(a.id)
    let project = paths.home.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    let projectSettings = project.appendingPathComponent(".claude/settings.local.json")
    try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://synthetic.invalid"}}"#.utf8).write(to: projectSettings)
    store.openCLI(a, workingDirectory: project)
    try await Task.sleep(nanoseconds: 30_000_000)
    try expect(launches == 1, "project API route blocks subscription launcher")
    try FileManager.default.removeItem(at: projectSettings)
    try await waitForActive(a.id)
    keychain.breaksRollback = true
    let switched = await store.switchClaudeSubscription(b)
    try expect(!switched && store.claudeIdentityUnavailable && store.claudeActiveProfileID == nil && store.quotas[a.id] == nil, "rollback failure quarantines active identity and quota")
    store.openCLI(a, workingDirectory: paths.home)
    store.discoverClaudeSubscriptions()
    try await Task.sleep(nanoseconds: 30_000_000)
    try expect(launches == 1 && store.claudeIdentityUnavailable && !store.canSwitchClaudeSubscription(b), "config A live B cannot recover via ordinary discovery or open")
    keychain.breaksRollback = false
    try setCurrent("a")
    try await waitForActive(a.id)
    try expect(store.canOpen(a) && store.canSwitchClaudeSubscription(b), "fresh official identity validation recovers reconciled state")

    guard let localDefault = store.profiles(for: .claudeCode).first(where: \.isDefault) else {
        throw FixtureFailure.failed("Claude default profile for opening lock")
    }
    blocksOpen = true
    store.openCLI(localDefault, workingDirectory: paths.home)
    store.openCLI(localDefault, workingDirectory: paths.home)
    for _ in 0..<200 where launches == 1 { try await Task.sleep(nanoseconds: 5_000_000) }
    try expect(launches == 2 && !store.canOpen(localDefault) && !store.canBeginClaudeSubscriptionSignIn,
        "two concurrent default Claude opens launch once and hold the sign-in lock")
    let countWhileOpening = store.profiles.count
    let captureWhileOpening = await store.captureClaudeSubscription(name: "Blocked while opening")
    let switchWhileOpening = await store.switchClaudeSubscription(b)
    try expect(captureWhileOpening == nil && !switchWhileOpening
        && !store.canSwitchClaudeSubscription(b) && store.profiles.count == countWhileOpening,
        "pending default Claude open blocks capture and subscription switching")
    blocksOpen = false
    for _ in 0..<200 where !store.canOpen(localDefault) { try await Task.sleep(nanoseconds: 5_000_000) }
    try expect(launches == 2 && store.canOpen(localDefault) && store.canBeginClaudeSubscriptionSignIn
        && store.canSwitchClaudeSubscription(b), "finishing the single default open restores account actions")
    let captureAfterOpening = await store.captureClaudeSubscription(name: "Synthetic A Again")
    try expect(captureAfterOpening?.id == a.id && store.profiles.count == countWhileOpening,
        "capture resumes after the default open finishes without duplicating the current subscription")
}

@MainActor private func testClaudeSubscriptionSignInRequiresExitVerificationAndExplicitCapture() async throws {
    let paths = try makeRoot("claude-subscription-sign-in")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try FileManager.default.createDirectory(at: paths.home.appendingPathComponent(".claude"),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let executable = paths.home.appendingPathComponent(".local/bin/claude")
    try Data("synthetic CLI".utf8).write(to: executable)
    guard chmod(executable.path, 0o700) == 0 else { throw FixtureFailure.failed("chmod synthetic Claude") }
    let keychain = ClaudeStoreKeychain(), transport = ClaudeStoreTransport()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var idle = true
    var service = ClaudeSubscriptionService(home: paths.home, support: paths.support)
    service.dependencies = .init(readKeychain: keychain.read, writeKeychain: keychain.write,
        idle: { idle }, transport: transport, now: { now })
    func setCurrent(_ name: String) throws {
        keychain.items[keychain.key("Claude Code-credentials", ClaudeSubscriptionService.keychainAccount)] =
            Data("{\"claudeAiOauth\":{\"accessToken\":\"synthetic-\(name)\",\"expiresAt\":2000000000000}}".utf8)
        try Data("{\"oauthAccount\":{\"accountUuid\":\"synthetic-\(name)\",\"organizationUuid\":\"synthetic-org\"}}".utf8)
            .write(to: paths.home.appendingPathComponent(".claude.json"), options: .atomic)
    }
    @MainActor func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw FixtureFailure.failed(message)
    }
    try setCurrent("a")
    var opens = 0
    let store = LocalCLIAccountStore(home: paths.home, support: paths.support,
        applicationsDirectory: paths.home.appendingPathComponent("empty-system-applications"),
        claudeSubscriptionService: service, terminalOpener: { _, _, _ in opens += 1 }, clock: { now })
    store.discover()
    guard let profile = store.profiles(for: .claudeCode).first(where: \.isDefault),
        let a = await store.captureClaudeSubscription(name: "Synthetic A")
    else { throw FixtureFailure.failed("seed synthetic Claude subscription") }
    try await waitUntil("seeded Claude identity not reconciled") { store.claudeActiveProfileID == a.id }
    let countBeforeLogin = store.profiles.count
    let savedBeforeLogin = try Data(contentsOf: storage(paths.support))
    let keychainBeforeLogin = keychain.items
    LocalCLITerminalLauncher.permitsSyntheticSession = true
    LocalCLITerminalLauncher.launchCount = 0
    LocalCLITerminalLauncher.syntheticExitCode = nil
    defer {
        transport.blocksProfileResponse = false
        LocalCLITerminalLauncher.syntheticExitCode = nil
        LocalCLITerminalLauncher.permitsSyntheticSession = false
    }

    idle = false
    store.startClaudeSubscriptionSignIn()
    store.signIn(profile)
    for _ in 0..<8 { await Task.yield() }
    try expect(LocalCLITerminalLauncher.launchCount == 0 && store.signingIn.isEmpty,
        "busy Claude sessions cannot launch authentication")
    idle = true
    let preview = LocalCLIAccountStore.preview(profiles: [profile, a], quotas: [:], root: paths.root,
        activeClaudeProfileID: a.id)
    try expect(preview.isPreview && !preview.canSignIn(profile) && !preview.canBeginClaudeSubscriptionSignIn,
        "preview disables Claude login even with an installed descriptor")
    preview.startClaudeSubscriptionSignIn()
    preview.signIn(profile)
    for _ in 0..<8 { await Task.yield() }
    try expect(LocalCLITerminalLauncher.launchCount == 0 && preview.signingIn.isEmpty,
        "preview never launches Claude authentication")

    store.startClaudeSubscriptionSignIn()
    try await waitUntil("Claude synthetic login did not launch") { LocalCLITerminalLauncher.launchCount == 1 }
    store.checkLocalSignIns()
    store.checkInteractiveSignIn(profile)
    try expect(store.signingIn.contains(profile.id) && !store.canBeginClaudeSubscriptionSignIn,
        "old Claude credentials cannot finish login through either public credential check")
    store.startClaudeSubscriptionSignIn()
    store.openCLI(profile, workingDirectory: paths.home)
    store.openCLI(a, workingDirectory: paths.home)
    let switchedDuringLogin = await store.switchClaudeSubscription(a)
    let capturedDuringLogin = await store.captureClaudeSubscription(name: "Premature")
    for _ in 0..<8 { await Task.yield() }
    try expect(!store.canOpen(profile) && !store.canOpen(a) && !store.canSwitchClaudeSubscription(a)
        && !switchedDuringLogin && capturedDuringLogin == nil && opens == 0
        && LocalCLITerminalLauncher.launchCount == 1,
        "pending Claude login blocks duplicate login, opening, switching and capture")
    let savedWhileWaiting = try Data(contentsOf: storage(paths.support))
    try expect(store.profiles.count == countBeforeLogin && savedWhileWaiting == savedBeforeLogin
        && keychain.items == keychainBeforeLogin,
        "pending login never saves a subscription or rewrites synthetic credentials")

    try setCurrent("b")
    transport.blocksProfileResponse = true
    let profileCallsBeforeExit = transport.profileCalls
    LocalCLITerminalLauncher.syntheticExitCode = 0
    try await waitUntil("successful Claude exit did not request fresh identity") {
        transport.profileCalls > profileCallsBeforeExit
    }
    store.checkLocalSignIns()
    store.checkInteractiveSignIn(profile)
    try expect(store.signingIn.contains(profile.id) && store.claudeActiveProfileID == nil
        && store.profiles.count == countBeforeLogin,
        "exit zero and changed credentials still wait for the fresh official identity response")
    transport.blocksProfileResponse = false
    try await waitUntil("verified Claude login remained waiting") { !store.signingIn.contains(profile.id) }
    try expect(store.claudeSubscriptionSignInMessage?.contains("订阅身份已核验") == true
        && !store.claudeIdentityUnavailable && store.claudeActiveProfileID == nil,
        "fresh B identity is verified without claiming the saved A card is current")
    let savedAfterVerification = try Data(contentsOf: storage(paths.support))
    try expect(store.profiles.count == countBeforeLogin && savedAfterVerification == savedBeforeLogin,
        "verified new login creates no card before explicit capture")
    guard let b = await store.captureClaudeSubscription(name: "Synthetic B") else {
        throw FixtureFailure.failed("explicit capture after verified login")
    }
    try await waitUntil("captured B identity not active") { store.claudeActiveProfileID == b.id }
    try expect(b.id != a.id && store.profiles.count == countBeforeLogin + 1,
        "explicit capture creates exactly one new subscription card")
    let capturedAgain = await store.captureClaudeSubscription(name: "Synthetic B Again")
    try expect(capturedAgain?.id == b.id && store.profiles.count == countBeforeLogin + 1,
        "saving the same current subscription updates its credentials without duplicating a card")

    LocalCLITerminalLauncher.syntheticExitCode = nil
    store.startClaudeSubscriptionSignIn()
    try await waitUntil("second Claude synthetic login did not launch") { LocalCLITerminalLauncher.launchCount == 2 }
    store.checkLocalSignIns()
    store.checkInteractiveSignIn(profile)
    try expect(store.signingIn.contains(profile.id), "existing B credentials also cannot finish a new login")
    LocalCLITerminalLauncher.syntheticExitCode = 1
    try await waitUntil("failed Claude exit remained waiting") { !store.signingIn.contains(profile.id) }
    try expect(store.claudeSubscriptionSignInMessage?.contains("登录未完成") == true
        && store.claudeActiveProfileID == nil && store.profiles.count == countBeforeLogin + 1,
        "nonzero Claude exit never reports verified success or saves existing credentials")

    LocalCLITerminalLauncher.syntheticExitCode = nil
    store.startClaudeSubscriptionSignIn()
    try await waitUntil("Claude login cannot retry after nonzero exit") { LocalCLITerminalLauncher.launchCount == 3 }
    transport.blocksProfileResponse = true
    let profileCallsBeforeRetry = transport.profileCalls
    LocalCLITerminalLauncher.syntheticExitCode = 0
    try await waitUntil("retried Claude login did not verify identity") {
        transport.profileCalls > profileCallsBeforeRetry
    }
    try expect(store.rename(profile, name: "Renamed during verification"),
        "Claude default profile can be renamed while identity verification is pending")
    guard let renamedProfile = store.profiles.first(where: { $0.id == profile.id }) else {
        throw FixtureFailure.failed("renamed Claude profile missing")
    }
    try expect(renamedProfile.displayName == "Renamed during verification"
        && store.signingIn.contains(profile.id), "rename preserves the pending Claude login attempt")
    transport.blocksProfileResponse = false
    try await waitUntil("renamed Claude login remained waiting") { !store.signingIn.contains(profile.id) }
    try expect(store.claudeSubscriptionSignInMessage?.contains("订阅身份已核验") == true
        && store.claudeActiveProfileID == b.id && store.profiles.count == countBeforeLogin + 1,
        "retry verifies successfully after a profile rename without adding a subscription")

    LocalCLITerminalLauncher.syntheticExitCode = nil
    store.startClaudeSubscriptionSignIn()
    try await waitUntil("Claude drift attempt did not launch") { LocalCLITerminalLauncher.launchCount == 4 }
    transport.blocksProfileResponse = true
    let profileCallsBeforeDrift = transport.profileCalls
    LocalCLITerminalLauncher.syntheticExitCode = 0
    try await waitUntil("Claude drift attempt did not verify identity") {
        transport.profileCalls > profileCallsBeforeDrift
    }
    try setCurrent("a")
    transport.blocksProfileResponse = false
    try await waitUntil("credential drift stranded the Claude login attempt") { !store.signingIn.contains(profile.id) }
    try expect(store.claudeSubscriptionSignInMessage?.contains("当前订阅身份尚未核验") == true
        && store.claudeActiveProfileID == nil && store.canBeginClaudeSubscriptionSignIn
        && store.profiles.count == countBeforeLogin + 1,
        "credential drift during fresh verification clears waiting and permits a new attempt without claiming success")
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
        try await testClaudeKeychainChangeClearsCachedIdentity()
        try await testAuthenticationWithoutQuotaOrTerminalExit()
        try await testOpenCodeReusesSavedProviderUnlessUpdateRequested()
        try await testVisibleKimiRefreshAfterExternalLogin()
        try await testVisibleKimiLinkedProfilesStayIsolated()
        try await testVisibleKimiRateLimitBackoff()
        try await testCredentialRotationDuringReadDropsOldQuota()
        try await testInFlightCredentialChangesClearVisibleQuotaAndCoalesce()
        try await testInFlightCredentialRemovalNeverReusesOldQuota()
        try await testQueuedCredentialRefreshCannotReviveDeletedProfile()
        try await testInFlightRateLimitPreservesBackoffAfterCredentialChange()
        try await testKimiDeviceIDInvalidatesFreshQuota()
        try await testFailedNewAccountReadNeverKeepsOldQuota()
        try await testZCodeCredentialFilesInvalidateFreshQuota()
        try await testConfiguredClaudeWithoutExecutable()
        try await testClaudeSubscriptionStoreIdentityAndReaderIsolation()
        try await testClaudeSubscriptionSignInRequiresExitVerificationAndExplicitCapture()
        print("local-cli-account-fixture: ok")
    }
}
