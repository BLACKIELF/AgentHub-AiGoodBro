import Darwin
import Foundation

struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ chinese: String, _ english: String) -> String { english }
}
private enum TestFailure: Error { case failed(String), synthetic }
private func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw TestFailure.failed(label) } }
private final class FakeKeychain {
    var items: [String: Data] = [:]
    var failWrite: String?
    var failAfterWrite: String?
    var rejectWrite: ((String, String, Data?) -> Bool)?
    var beforeRead: ((String, String) -> Void)?
    var writeCount = 0
    func key(_ service: String, _ account: String) -> String { service + "|" + account }
    func read(_ service: String, _ account: String) throws -> Data? {
        beforeRead?(service, account)
        return items[key(service,account)]
    }
    func write(_ service: String, _ account: String, _ data: Data?) throws {
        writeCount += 1
        if rejectWrite?(service, account, data) == true { throw TestFailure.synthetic }
        if failWrite == service { failWrite = nil; throw TestFailure.synthetic }
        items[key(service,account)] = data
        if failAfterWrite == service { failAfterWrite = nil; throw TestFailure.synthetic }
    }
}
private final class MockTransport: LocalCLIQuotaTransport, @unchecked Sendable {
    var calls: [String] = []
    var afterUsage: (() -> Void)?
    var afterProfile: (() -> Void)?
    var fail = false
    var tokenStatus = 200
    var tokenThrows = false
    var tokenHook: (() async throws -> Void)?
    var tokenRequests: [URLRequest] = []
    var usageStatus = 200
    var usageHeaders: [String: String] = [:]
    var profileIdentityOverride: String?
    var tokenReply = Data(#"{"access_token":"synthetic-b-renewed","refresh_token":"synthetic-b-successor","expires_in":3600,"scope":"user:profile user:inference","refresh_token_expires_in":7200}"#.utf8)
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        calls.append(request.url!.path)
        if request.url?.path == "/v1/oauth/token" {
            tokenRequests.append(request)
            try await tokenHook?()
            if tokenThrows { throw TestFailure.synthetic }
            return .init(statusCode: tokenStatus, headers: [:], data: tokenReply)
        }
        if fail { throw TestFailure.synthetic }
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let name = profileIdentityOverride ?? (auth.contains("synthetic-b") ? "b" : "a")
        if request.url!.path.hasSuffix("profile") {
            afterProfile?()
            return LocalCLIHTTPResponse(statusCode: 200, headers: [:], data: Data("{\"account\":{\"uuid\":\"synthetic-\(name)\",\"email\":\"\(name)@synthetic.invalid\"},\"organization\":{\"uuid\":\"synthetic-org\"}}".utf8))
        }
        afterUsage?()
        return LocalCLIHTTPResponse(statusCode: usageStatus, headers: usageHeaders, data: Data(#"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":50,"resets_at":"2030-01-07T00:00:00Z"},"limits":[{"is_active":true,"percent":70,"scope":{"model":{"display_name":"Synthetic Model"}},"resets_at":"2030-01-07T00:00:00Z"}]}"#.utf8))
    }
}
@main struct ClaudeSubscriptionFixture {
    private static func testQuotaRetryAfter() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            let header = formatter.string(from: now.addingTimeInterval(3600))
            try expect(ClaudeSubscriptionService.quotaRetryAfter(["retry-after": header], now: now) == now.addingTimeInterval(3600), "valid HTTP Retry-After date")
        }
        try expect(ClaudeSubscriptionService.quotaRetryAfter(["ReTrY-AfTeR": " 120 "], now: now) == now.addingTimeInterval(120), "case insensitive delay seconds")
        try expect(ClaudeSubscriptionService.quotaRetryAfter(["Retry-After": "604800"], now: now) == now.addingTimeInterval(604800), "maximum accepted delay is not shortened")
        for raw in ["", "0", "-1", "+1", "1.5", "NaN", "inf", "1e3", "604801", String(repeating: "9", count: 200), "120\n", "not a date"] {
            try expect(ClaudeSubscriptionService.quotaRetryAfter(["Retry-After": raw], now: now) == nil, "invalid Retry-After falls back: " + raw.prefix(16))
        }
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for offset: TimeInterval in [-1, 0, 604801] {
            try expect(ClaudeSubscriptionService.quotaRetryAfter(["Retry-After": formatter.string(from: now.addingTimeInterval(offset))], now: now) == nil, "expired or excessive HTTP date rejected")
        }
        try expect(ClaudeSubscriptionService.quotaRetryAfter([:], now: now) == nil, "missing Retry-After falls back")
        try expect(ClaudeSubscriptionService.quotaRetryAfter(["Retry-After": "120", "retry-after": "240"], now: now) == nil, "ambiguous duplicate Retry-After rejected")
        print("PASS claude-quota Retry-After parsing")
    }
    private enum ConfigFile {
        case absent, regular(Data, mode_t), directory, fifo
        case symlinkRegular(Data, mode_t), symlinkDirectory, danglingSymlink
    }
    private static func testGlobalConfigSelection(root: URL) throws {
        let empty = Data(), nonempty = Data("{}".utf8)
        let cases: [(String, ConfigFile, ConfigFile, Bool)] = [
            ("both absent", .absent, .absent, false),
            ("only global", .absent, .regular(nonempty, 0o600), false),
            ("empty legacy and global", .regular(empty, 0o600), .regular(nonempty, 0o600), false),
            ("empty writable legacy only", .regular(empty, 0o600), .absent, true),
            ("empty readonly legacy only", .regular(empty, 0o444), .absent, false),
            ("empty readonly legacy and global", .regular(empty, 0o444), .regular(nonempty, 0o600), false),
            ("empty no permission bits", .regular(empty, 0), .absent, false),
            ("empty owner write bit", .regular(empty, 0o200), .absent, true),
            ("empty group write bit", .regular(empty, 0o020), .absent, true),
            ("empty other write bit", .regular(empty, 0o002), .absent, true),
            ("empty group writable and global", .regular(empty, 0o020), .regular(nonempty, 0o600), false),
            ("nonempty legacy only", .regular(nonempty, 0o600), .absent, true),
            ("both nonempty", .regular(nonempty, 0o600), .regular(nonempty, 0o600), true),
            ("nonempty readonly legacy", .regular(nonempty, 0o444), .regular(nonempty, 0o600), true),
            ("nonempty unreadable legacy", .regular(nonempty, 0), .regular(nonempty, 0o600), true),
            ("legacy directory only", .directory, .absent, false),
            ("legacy directory and global", .directory, .regular(nonempty, 0o600), false),
            ("legacy fifo only", .fifo, .absent, false),
            ("legacy fifo and global", .fifo, .regular(nonempty, 0o600), false),
            ("nonempty legacy symlink", .symlinkRegular(nonempty, 0o600), .regular(nonempty, 0o600), true),
            ("empty writable legacy symlink only", .symlinkRegular(empty, 0o600), .absent, true),
            ("empty legacy symlink and global", .symlinkRegular(empty, 0o600), .regular(nonempty, 0o600), false),
            ("empty readonly legacy symlink only", .symlinkRegular(empty, 0o444), .absent, false),
            ("legacy symlink to directory", .symlinkDirectory, .regular(nonempty, 0o600), false),
            ("dangling legacy symlink only", .danglingSymlink, .absent, false),
            ("dangling legacy symlink and global", .danglingSymlink, .regular(nonempty, 0o600), false),
            ("empty legacy and global directory", .regular(empty, 0o600), .directory, false),
            ("empty legacy and global symlink", .regular(empty, 0o600), .symlinkRegular(nonempty, 0o600), false),
            ("empty legacy and dangling global symlink", .regular(empty, 0o600), .danglingSymlink, true),
            ("nonempty legacy and global directory", .regular(nonempty, 0o600), .directory, true),
        ]
        func create(_ kind: ConfigFile, at url: URL) throws {
            switch kind {
            case .absent: break
            case let .regular(data, mode):
                try data.write(to: url)
                try expect(chmod(url.path, mode) == 0, "fixture sets file mode")
            case .directory:
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            case .fifo:
                try expect(mkfifo(url.path, 0o600) == 0, "fixture creates fifo")
            case let .symlinkRegular(data, mode):
                let target = url.appendingPathExtension("target")
                try create(.regular(data, mode), at: target)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            case .symlinkDirectory:
                let target = url.appendingPathExtension("target")
                try create(.directory, at: target)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            case .danglingSymlink:
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: url.appendingPathExtension("absent"))
            }
        }
        for (index, item) in cases.enumerated() {
            let (label, legacyKind, globalKind, expectLegacy) = item
            let home = root.appendingPathComponent("config-path-\(index)")
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            let legacy = home.appendingPathComponent(".claude/.config.json"), global = home.appendingPathComponent(".claude.json")
            try create(legacyKind, at: legacy); try create(globalKind, at: global)
            let selected = ClaudeSubscriptionService.globalConfigURL(legacy: legacy, global: global)
            try expect(selected == (expectLegacy ? legacy : global), label)
            if expectLegacy {
                let service = ClaudeSubscriptionService(home: home, support: home.appendingPathComponent("support"))
                switch legacyKind {
                case .symlinkRegular:
                    do { _ = try service.activeFingerprint(); throw TestFailure.failed("selected symlink was read") }
                    catch ClaudeSubscriptionService.Failure.invalid {}
                case .regular(_, 0) where geteuid() != 0:
                    do { _ = try service.activeFingerprint(); throw TestFailure.failed("unreadable legacy was read") }
                    catch DispatchParticipationError.fileAccess {}
                default: break
                }
            }
        }
        if geteuid() != 0 {
            let home = root.appendingPathComponent("config-stat-denied")
            let directory = home.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacy = directory.appendingPathComponent(".config.json"), global = home.appendingPathComponent(".claude.json")
            try nonempty.write(to: legacy)
            try expect(chmod(directory.path, 0) == 0, "fixture denies stat traversal")
            defer { _ = chmod(directory.path, 0o700) }
            var metadata = stat()
            try expect(stat(legacy.path, &metadata) != 0 && errno == EACCES, "fixture reaches stat error")
            try expect(ClaudeSubscriptionService.globalConfigURL(legacy: legacy, global: global) == global, "legacy stat error chooses global")
        }
        print("PASS claude-global-config selection (\(cases.count) cases; guarded symlink/unreadable reads; stat error \(geteuid() == 0 ? "skipped under root" : "passed"))")
    }
    static func main() async throws {
        try testQuotaRetryAfter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-synthetic-" + UUID().uuidString)
        let home = root.appendingPathComponent("home"), support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = FakeKeychain(), transport = MockTransport()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var service = ClaudeSubscriptionService(home: home, support: support)
        service.dependencies = .init(readKeychain: keychain.read, writeKeychain: keychain.write, idle: { true }, transport: transport, now: { now })
        func credential(_ name: String) -> Data {
            Data("{\"claudeAiOauth\":{\"accessToken\":\"synthetic-\(name)\",\"refreshToken\":\"synthetic-rotating-\(name)\",\"expiresAt\":2000000000000,\"subscriptionType\":\"synthetic-pro\"},\"mcpOAuth\":{\"synthetic\":\"keep\"}}".utf8)
        }
        let configURL = home.appendingPathComponent(".claude.json")
        func config(_ name: String) -> Data {
            Data("{\"oauthAccount\":{\"accountUuid\":\"synthetic-\(name)\",\"emailAddress\":\"\(name)@synthetic.invalid\",\"organizationUuid\":\"synthetic-org\"},\"syntheticKeep\":42}".utf8)
        }
        let legacyConfigURL = home.appendingPathComponent(".claude/.config.json")
        try Data().write(to: legacyConfigURL)
        func expectFailure(_ expected: ClaudeSubscriptionService.Failure, _ label: String, operation: () async throws -> Void) async throws {
            do { try await operation(); throw TestFailure.failed(label + " accepted") }
            catch let failure as ClaudeSubscriptionService.Failure { guard failure == expected else { throw TestFailure.failed(label + " wrong failure: \(failure)") } }
        }
        let liveKey = keychain.key("Claude Code-credentials", ClaudeSubscriptionService.keychainAccount)
        keychain.items[liveKey] = credential("a"); try config("a").write(to: configURL)
        let a = try await service.capture(slot: UUID().uuidString)
        keychain.items[liveKey] = credential("b"); try config("b").write(to: configURL)
        let b = try await service.capture(slot: UUID().uuidString)
        let captureBaseline = keychain.items, captureGlobal = try Data(contentsOf: configURL)
        let pathRaceSlot = UUID().uuidString
        var pathRaceInjected = false
        keychain.rejectWrite = { serviceName, account, data in
            if serviceName == ClaudeSubscriptionService.nativeService, account == pathRaceSlot, data != nil, !pathRaceInjected {
                pathRaceInjected = true
                try? config("b").write(to: legacyConfigURL)
            }
            return false
        }
        try await expectFailure(.identityChanged, "capture rechecks the resolved config path after slot write") {
            _ = try await service.capture(slot: pathRaceSlot)
        }
        try expect(pathRaceInjected && keychain.items[keychain.key(ClaudeSubscriptionService.nativeService, pathRaceSlot)] == nil,
            "path race restores the owned native slot")
        try expect(keychain.items == captureBaseline && (try Data(contentsOf: configURL)) == captureGlobal &&
            (try Data(contentsOf: legacyConfigURL)) == config("b"),
            "path race preserves the external legacy config and global bytes")
        keychain.rejectWrite = nil
        try Data().write(to: legacyConfigURL)

        let liveRaceSlot = UUID().uuidString
        var liveRaceInjected = false
        keychain.rejectWrite = { serviceName, account, data in
            if serviceName == ClaudeSubscriptionService.nativeService, account == liveRaceSlot, data != nil, !liveRaceInjected {
                liveRaceInjected = true
                keychain.items[liveKey] = credential("a")
            }
            return false
        }
        try await expectFailure(.identityChanged, "capture rechecks the live credential after slot write") {
            _ = try await service.capture(slot: liveRaceSlot)
        }
        try expect(liveRaceInjected && keychain.items[keychain.key(ClaudeSubscriptionService.nativeService, liveRaceSlot)] == nil,
            "live credential race restores the owned native slot")
        try expect(keychain.items[liveKey] == credential("a") && (try Data(contentsOf: configURL)) == captureGlobal,
            "live credential race preserves the external credential and config")
        keychain.items[liveKey] = credential("b")
        keychain.rejectWrite = nil

        let lockRaceSlot = UUID().uuidString
        var lockRaceInjected = false
        keychain.rejectWrite = { serviceName, account, data in
            if serviceName == ClaudeSubscriptionService.nativeService, account == lockRaceSlot, data != nil, !lockRaceInjected {
                lockRaceInjected = true
                try? FileManager.default.removeItem(at: home.appendingPathComponent(".claude/.oauth_refresh.lock"))
            }
            return false
        }
        try await expectFailure(.identityChanged, "capture rechecks the mutation lock after slot write") {
            _ = try await service.capture(slot: lockRaceSlot)
        }
        try expect(lockRaceInjected && keychain.items[keychain.key(ClaudeSubscriptionService.nativeService, lockRaceSlot)] == nil,
            "lock race restores the owned native slot")
        try expect(keychain.items == captureBaseline && (try Data(contentsOf: configURL)) == captureGlobal,
            "lock race preserves all external storage")
        keychain.rejectWrite = nil

        let conflictSlot = UUID().uuidString, externalSlot = Data(#"{"syntheticExternalSlot":true}"#.utf8)
        let conflictKey = keychain.key(ClaudeSubscriptionService.nativeService, conflictSlot)
        var matchingSlotReads = 0
        keychain.rejectWrite = { serviceName, account, data in
            if serviceName == ClaudeSubscriptionService.nativeService, account == conflictSlot, data != nil {
                try? config("b").write(to: legacyConfigURL)
            }
            return false
        }
        keychain.beforeRead = { serviceName, account in
            if serviceName == ClaudeSubscriptionService.nativeService, account == conflictSlot, keychain.items[conflictKey] != nil {
                matchingSlotReads += 1
                if matchingSlotReads == 2 { keychain.items[conflictKey] = externalSlot }
            }
        }
        try await expectFailure(.rollbackFailed, "capture rollback refuses a concurrent slot revision") {
            _ = try await service.capture(slot: conflictSlot)
        }
        try expect(matchingSlotReads == 2 && keychain.items[conflictKey] == externalSlot && (try Data(contentsOf: legacyConfigURL)) == config("b"),
            "capture rollback preserves both external slot bytes and config")
        keychain.beforeRead = nil
        keychain.rejectWrite = nil
        keychain.items[conflictKey] = nil
        try Data().write(to: legacyConfigURL)

        let beforePathRace = keychain.items, beforePathRaceConfig = try Data(contentsOf: configURL)
        transport.afterProfile = { try? beforePathRaceConfig.write(to: legacyConfigURL) }
        try await expectFailure(.identityChanged, "capture refuses identical config at a newly selected path") {
            _ = try await service.capture(slot: UUID().uuidString)
        }
        try expect(keychain.items == beforePathRace && (try Data(contentsOf: configURL)) == beforePathRaceConfig,
            "capture path change preserves all storage")
        try Data().write(to: legacyConfigURL)
        try await expectFailure(.identityChanged, "switch refuses identical config at a newly selected path") {
            try await service.switchTo(a, allReferences: [a,b])
        }
        try expect(keychain.items == beforePathRace && (try Data(contentsOf: configURL)) == beforePathRaceConfig,
            "switch path change rejects before mutation")
        transport.afterProfile = nil
        try Data().write(to: legacyConfigURL)
        let cswapRoot = home.appendingPathComponent(".claude-swap-backup")
        try FileManager.default.createDirectory(at: cswapRoot.appendingPathComponent("credentials"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: cswapRoot.appendingPathComponent("configs"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(#"{"accounts":{"2":{"uuid":"synthetic-b","email":"b@synthetic.invalid","organizationUuid":"synthetic-org"},"3":{"uuid":"synthetic-c","email":"c@synthetic.invalid","organizationUuid":"synthetic-org"}}}"#.utf8).write(to: cswapRoot.appendingPathComponent("sequence.json"))
        try config("b").write(to: cswapRoot.appendingPathComponent("configs/.claude-config-2-b@synthetic.invalid.json"))
        try config("c").write(to: cswapRoot.appendingPathComponent("configs/.claude-config-3-c@synthetic.invalid.json"))
        keychain.items[keychain.key("claude-swap", "account-2-b@synthetic.invalid")] = credential("b")
        keychain.items[keychain.key("claude-swap", "account-3-c@synthetic.invalid")] = credential("c")
        let unrelated = try service.reference(candidateID: "3")
        try await service.switchTo(a, allReferences: [a,b,unrelated])
        try expect(try service.activeFingerprint() == a.identityFingerprint, "native switch changes actual identity")
        try expect(try ClaudeSubscriptionService.object(Data(contentsOf: configURL))["syntheticKeep"] as? Int == 42, "global config fields preserved")
        try expect(try ClaudeSubscriptionService.object(keychain.items[liveKey]!)["mcpOAuth"] != nil, "live shared credential fields preserved")
        try expect(try ClaudeSubscriptionService.oauth(service.credential(b).credential, now: now)["accessToken"] as? String == "synthetic-b", "switched-out current lineage preserved")
        let quota = await service.loadQuota(a, now: now)
        try expect(quota.state == .available && quota.identityFingerprint == a.identityFingerprint && quota.windows.count == 3, "identity bound 5h 7d model quota")
        let quotaWrites = keychain.writeCount
        transport.usageStatus = 429
        transport.usageHeaders = ["Retry-After": "3600"]
        let limitedQuota = await service.loadQuota(a, now: now)
        try expect(limitedQuota.state == .rateLimited && limitedQuota.serverRetryAt == now.addingTimeInterval(3600)
            && limitedQuota.windows.isEmpty && limitedQuota.messageCode == "local_cli_rate_limited", "HTTP 429 carries validated retry deadline without quota")
        transport.usageHeaders = ["Retry-After": "NaN"]
        let invalidRetry = await service.loadQuota(a, now: now)
        try expect(invalidRetry.state == .rateLimited && invalidRetry.serverRetryAt == nil, "invalid header retains ordinary rate-limit result")
        transport.usageStatus = 500; transport.usageHeaders = ["Retry-After": "3600"]
        let non429Retry = await service.loadQuota(a, now: now)
        try expect(non429Retry.state == .unavailable && non429Retry.serverRetryAt == nil, "non-429 does not gain retry metadata")
        transport.usageStatus = 200
        let recoveredQuota = await service.loadQuota(a, now: now)
        try expect(recoveredQuota.state == .available && recoveredQuota.serverRetryAt == nil && keychain.writeCount == quotaWrites, "success clears metadata and quota reads never write credentials")
        transport.usageHeaders = [:]
        let beforeKeychain = keychain.items, beforeConfig = try Data(contentsOf: configURL)
        keychain.failWrite = "Claude Code-credentials"
        do { try await service.switchTo(b, allReferences: [a,b]); throw TestFailure.failed("write failure accepted") }
        catch ClaudeSubscriptionService.Failure.rolledBack {}
        try expect(keychain.items == beforeKeychain && (try Data(contentsOf: configURL)) == beforeConfig, "failed keychain write fully rolls back")
        keychain.failAfterWrite = "Claude Code-credentials"
        do { try await service.switchTo(b, allReferences: [a,b]); throw TestFailure.failed("post-write failure accepted") }
        catch ClaudeSubscriptionService.Failure.rolledBack {}
        try expect(keychain.items == beforeKeychain && (try Data(contentsOf: configURL)) == beforeConfig, "post-write keychain failure fully rolls back")
        keychain.rejectWrite = { service, _, _ in
            if service == "Claude Code-credentials" { try? beforeConfig.write(to: legacyConfigURL) }
            return false
        }
        try await expectFailure(.rollbackFailed, "config path changes after live Keychain write") {
            try await service.switchTo(b, allReferences: [a,b])
        }
        keychain.rejectWrite = nil
        try expect(keychain.items == beforeKeychain && (try Data(contentsOf: configURL)) == beforeConfig && (try Data(contentsOf: legacyConfigURL)) == beforeConfig,
            "path conflict restores owned storage and never overwrites the newly selected legacy config")
        try Data().write(to: legacyConfigURL)

        let verified = try await service.verifyCurrent(expectedFingerprint: a.identityFingerprint)
        try expect(verified.fingerprint == a.identityFingerprint && verified.credentialRevision.count == 64 && verified.configDigest.count == 64 && verified.configPath == configURL.standardizedFileURL.path, "verified current binds identity credential and config snapshot")
        try expect(try service.isCurrent(verified), "current observation passes synchronous recheck")
        keychain.items[liveKey] = credential("b")
        try await expectFailure(.identityChanged, "config A live credential B") { _ = try await service.verifyCurrent() }
        keychain.items[liveKey] = credential("a")
        transport.afterProfile = { try? Data(#"{"env":{"ANTHROPIC_API_KEY":"synthetic-api"}}"#.utf8).write(to: home.appendingPathComponent(".claude/settings.json")) }
        try await expectFailure(.readOnly, "API route changes during identity request") { _ = try await service.verifyCurrent() }
        transport.afterProfile = nil
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/settings.json"))
        transport.afterProfile = { keychain.items[liveKey] = credential("b") }
        try await expectFailure(.identityChanged, "credential changes during identity request") { _ = try await service.verifyCurrent() }
        transport.afterProfile = nil
        keychain.items[liveKey] = credential("a")
        let stable = try await service.verifyCurrent()
        try expect(try service.isCurrent(stable), "restored verified snapshot remains current")
        keychain.items[liveKey] = credential("b")
        try expect(try !service.isCurrent(stable), "final synchronous check rejects credential revision change")
        keychain.items[liveKey] = credential("a")
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://synthetic.invalid"}}"#.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
        try await expectFailure(.readOnly, "API route refused") { _ = try await service.verifyCurrent() }
        try await expectFailure(.readOnly, "synchronous final check refuses API route") { _ = try service.isCurrent(stable) }
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/settings.json"))

        let registry = cswapRoot.appendingPathComponent("sequence.json")
        let beforeSwitchKeychain = keychain.items, beforeSwitchConfig = try Data(contentsOf: configURL), beforeSequence = try Data(contentsOf: registry)
        let globalLockPath = cswapRoot.appendingPathComponent(".lock")
        let globalLockFD = open(globalLockPath.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try expect(globalLockFD >= 0 && flock(globalLockFD, LOCK_EX | LOCK_NB) == 0, "test acquires external cswap global lock")
        try await expectFailure(.busy, "native switch with unrelated cswap lock held") { try await service.switchTo(b, allReferences: [a,b,unrelated]) }
        try expect(keychain.items == beforeSwitchKeychain && (try Data(contentsOf: configURL)) == beforeSwitchConfig && (try Data(contentsOf: registry)) == beforeSequence, "busy unrelated cswap global lock leaves all storage unchanged")
        _ = flock(globalLockFD, LOCK_UN); close(globalLockFD)
        try await service.switchTo(b, allReferences: [a,b,unrelated])
        try expect(try service.activeFingerprint() == b.identityFingerprint, "native-to-native switch succeeds with unrelated cswap global protocol lock")
        try await service.switchTo(a, allReferences: [a,b,unrelated])
        var blocked = service; blocked.dependencies.idle = { false }
        let writes = keychain.writeCount
        do { try await blocked.switchTo(b, allReferences: [a,b]); throw TestFailure.failed("busy accepted") }
        catch ClaudeSubscriptionService.Failure.busy {}
        try expect(writes == keychain.writeCount, "busy rejects before mutations")
        let lock = home.appendingPathComponent(".claude/.oauth_refresh.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        do { try await service.switchTo(b, allReferences: [a,b]); throw TestFailure.failed("lock accepted") }
        catch ClaudeSubscriptionService.Failure.busy {}
        try FileManager.default.removeItem(at: lock)
        try expect(writes == keychain.writeCount, "external official lock rejects mutations")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try Data(#"{"env":{"ANTHROPIC_API_KEY":"synthetic-api"}}"#.utf8).write(to: settings)
        do { try await service.switchTo(b, allReferences: [a,b]); throw TestFailure.failed("API accepted") }
        catch ClaudeSubscriptionService.Failure.readOnly {}
        try FileManager.default.removeItem(at: settings)
        transport.afterUsage = { keychain.items[liveKey] = credential("b") }
        transport.usageStatus = 429; transport.usageHeaders = ["Retry-After": "3600"]
        let changed = await service.loadQuota(a, now: now)
        try expect(changed.messageCode == "local_cli_claude_credentials_changed" && changed.windows.isEmpty && changed.serverRetryAt == nil, "inflight credential change discards quota and retry deadline")
        transport.usageStatus = 200; transport.usageHeaders = [:]
        transport.afterUsage = nil; keychain.items[liveKey] = credential("a"); transport.fail = true
        let failed = await service.loadQuota(a, now: now)
        try expect(failed.messageCode == "local_cli_unavailable", "network failure ordinary stale signal")
        try expect(!ClaudeSubscriptionService.processEvidenceIsIdle("/synthetic/.local/share/claude/versions/2.1.220 /synthetic/.local/share/claude/versions/2.1.220"), "native versions Claude busy")
        try expect(!ClaudeSubscriptionService.processEvidenceIsIdle(""), "missing process evidence refused")
        try expect(ClaudeSubscriptionService.processEvidenceIsIdle("/bin/launchd /bin/launchd"), "known idle process evidence")
        try expect(ClaudeSubscriptionService.directoryKeychainService("/synthetic/café") == ClaudeSubscriptionService.directoryKeychainService("/synthetic/cafe\u{301}"), "NFC hash identity")
        try expect(ClaudeSubscriptionService.directoryKeychainService("/synthetic/c") != ClaudeSubscriptionService.directoryKeychainService("/synthetic/c/"), "raw export hash preserves trailing slash")
        transport.fail = false
        let imported = try service.reference(candidateID: "2")
        try expect(try service.candidates().first?.maskedIdentity == "b***@synthetic.invalid", "discovered slots are masked")
        try await service.switchTo(imported, allReferences: [a,imported])
        try expect(try service.activeFingerprint() == imported.identityFingerprint, "cswap imported slot switches actual default")
        // Simulate the official CLI rotating only the currently active token.
        let rotated = Data(String(decoding: credential("b"), as: UTF8.self).replacingOccurrences(of: "synthetic-rotating-b", with: "synthetic-successor-b").utf8)
        keychain.items[liveKey] = rotated
        try await service.switchTo(a, allReferences: [a,imported])
        let cswapSaved = keychain.items[keychain.key("claude-swap", "account-2-b@synthetic.invalid")]!
        try expect(try ClaudeSubscriptionService.oauth(cswapSaved, now: now)["refreshToken"] as? String == "synthetic-successor-b", "switch-out updates original cswap rotating lineage")
        let oldNative = keychain.items[keychain.key(ClaudeSubscriptionService.nativeService,a.slot)]!
        keychain.items[liveKey] = Data(String(decoding: credential("a"), as: UTF8.self).replacingOccurrences(of: "synthetic-rotating-a", with: "synthetic-new-login-a").utf8)
        _ = try await service.capture(slot: a.slot, replacing: a)
        try expect(keychain.items[keychain.key(ClaudeSubscriptionService.nativeService,a.slot)] != oldNative, "official relogin updates same native slot")
        let credentialFile = home.appendingPathComponent(".claude/.credentials.json")
        let fileOnly = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-a","expiresAt":2000000000000},"fileOnlyMCP":{"synthetic":"retain"}}"#.utf8)
        try fileOnly.write(to: credentialFile)
        try await service.switchTo(imported, allReferences: [a,imported])
        try expect(try ClaudeSubscriptionService.object(Data(contentsOf: credentialFile))["fileOnlyMCP"] != nil, "fallback file preserves its own shared fields")
        let encodedFile = cswapRoot.appendingPathComponent("credentials/.creds-2-b@synthetic.invalid.enc")
        try Data(cswapSaved.base64EncodedString().utf8).write(to: encodedFile)
        _ = chmod(encodedFile.path, 0o600)
        keychain.items[liveKey] = rotated
        try await service.switchTo(a, allReferences: [a,imported])
        let encodedSaved = try Data(contentsOf: encodedFile)
        let decodedSaved = Data(base64Encoded: String(decoding: encodedSaved, as: UTF8.self))!
        try expect(try ClaudeSubscriptionService.oauth(decodedSaved, now: now)["refreshToken"] as? String == "synthetic-successor-b", "base64 credential writer preserves cswap rotating successor")
        let sequence = try ClaudeSubscriptionService.object(Data(contentsOf: cswapRoot.appendingPathComponent("sequence.json")))
        try expect(sequence["activeAccountNumber"] is NSNull, "cswap rotation anchor clears for unmanaged native active")
        let session = cswapRoot.appendingPathComponent("sessions/2-b_synthetic.invalid")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        do { try await service.switchTo(imported, allReferences: [a,imported]); throw TestFailure.failed("session lineage accepted") }
        catch ClaudeSubscriptionService.Failure.busy {}
        try FileManager.default.removeItem(at: session)
        let renewalBaseline = keychain.items, renewalConfig = try Data(contentsOf: configURL), tokenReply = transport.tokenReply
        let bKey = keychain.key(ClaudeSubscriptionService.nativeService, b.slot)
        func recoveryRecords() throws -> [[String: Any]] {
            try keychain.items.filter { $0.key.hasPrefix(ClaudeSubscriptionService.nativeService + "|renewal-") }.values.map(ClaudeSubscriptionService.object)
        }
        func resetExpiredTarget() throws {
            keychain.items = renewalBaseline
            keychain.rejectWrite = nil
            keychain.failWrite = nil
            keychain.failAfterWrite = nil
            try renewalConfig.write(to: configURL)
            var root = try ClaudeSubscriptionService.object(keychain.items[bKey]!)
            var payload = root["credential"] as! [String: Any]
            var oauth = payload["claudeAiOauth"] as! [String: Any]
            oauth["expiresAt"] = now.timeIntervalSince1970 * 1000 - 1
            oauth["scopes"] = ["synthetic-preserved-scope"]
            payload["claudeAiOauth"] = oauth
            root["credential"] = payload
            keychain.items[bKey] = try ClaudeSubscriptionService.bytes(root)
            transport.calls = []; transport.tokenRequests = []; transport.tokenStatus = 200; transport.tokenThrows = false
            transport.tokenHook = nil; transport.afterProfile = nil; transport.afterUsage = nil; transport.profileIdentityOverride = nil; transport.tokenReply = tokenReply
        }
        try resetExpiredTarget()
        let expiredQuota = await service.loadQuota(b, now: now)
        try expect(expiredQuota.messageCode == "local_cli_credentials_expired" && transport.calls.isEmpty, "quota reads never renew expired subscription")
        transport.tokenHook = {
            let records = try recoveryRecords()
            try expect(records.count == 1 && (records[0]["pendingDigest"] as? String)?.count == 64 && records[0]["credential"] == nil,
                "pending digest is durable before the refresh POST")
        }
        try await service.switchTo(b, allReferences: [a,b])
        let renewed = try ClaudeSubscriptionService.oauth(service.credential(b).credential, now: now)
        try expect(renewed["refreshToken"] as? String == "synthetic-b-successor" && renewed["expiresAt"] as? Double == (now.timeIntervalSince1970 + 3600) * 1000,
            "expired target rotates and persists its successor before switching")
        try expect(renewed["refreshTokenExpiresAt"] as? Double == (now.timeIntervalSince1970 + 7200) * 1000 && renewed["scopes"] as? [String] == ["user:profile", "user:inference"], "renewal expiry units and optional scope metadata")
        try expect(transport.tokenRequests.count == 1 && (try recoveryRecords()).isEmpty, "successful renewal clears recovery after slot readback")
        let request = transport.tokenRequests[0], requestBody = try ClaudeSubscriptionService.object(request.httpBody!)
        try expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token" && request.httpMethod == "POST"
            && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
            && Set(requestBody.keys) == Set(["grant_type", "refresh_token", "client_id"])
            && requestBody["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "renewal uses the verified fixed OAuth request contract")

        try resetExpiredTarget()
        transport.tokenReply = Data(#"{"access_token":"synthetic-b-renewed","expires_in":3600}"#.utf8)
        try await service.switchTo(b, allReferences: [a,b])
        let retained = try ClaudeSubscriptionService.oauth(service.credential(b).credential, now: now)
        try expect(retained["refreshToken"] as? String == "synthetic-rotating-b" && retained["scopes"] as? [String] == ["synthetic-preserved-scope"], "missing refresh and scope preserve the verified upstream fallback")

        for unknown in [false, true] {
            try resetExpiredTarget()
            transport.tokenStatus = 400; transport.tokenThrows = unknown
            let expiredBytes = keychain.items[bKey]
            try await expectFailure(.reauthenticationRequired, "denied or unknown renewal") { try await service.switchTo(b, allReferences: [a,b]) }
            try await expectFailure(.reauthenticationRequired, "uncertain grant never retried") { try await service.switchTo(b, allReferences: [a,b]) }
            try expect(transport.tokenRequests.count == 1 && keychain.items[bKey] == expiredBytes
                && keychain.items[liveKey] == renewalBaseline[liveKey] && (try Data(contentsOf: configURL)) == renewalConfig,
                "denied/unknown renewal preserves target and active credentials")
        }

        try resetExpiredTarget()
        keychain.rejectWrite = { _, account, _ in account.hasPrefix("renewal-") }
        try await expectFailure(.unavailable, "pending marker write failure") { try await service.switchTo(b, allReferences: [a,b]) }
        try expect(transport.tokenRequests.isEmpty, "no refresh POST until pending marker readback succeeds")
        keychain.rejectWrite = nil
        keychain.failAfterWrite = ClaudeSubscriptionService.nativeService
        try await service.switchTo(b, allReferences: [a,b])
        try expect(transport.tokenRequests.count == 1, "verified post-write success does not discard the persisted marker")

        try resetExpiredTarget()
        keychain.rejectWrite = { _, account, data in
            account.hasPrefix("renewal-") && data.flatMap { try? ClaudeSubscriptionService.object($0)["credential"] } != nil
        }
        try await expectFailure(.reauthenticationRequired, "successor persistence failure") { try await service.switchTo(b, allReferences: [a,b]) }
        keychain.rejectWrite = nil
        try await expectFailure(.reauthenticationRequired, "lost successor requires official login") { try await service.switchTo(b, allReferences: [a,b]) }
        try expect(transport.tokenRequests.count == 1 && (try recoveryRecords()).first?["credential"] == nil,
            "unpersisted successor leaves pending digest and never reuses old grant")

        try resetExpiredTarget()
        var rejectedSlot = false
        keychain.rejectWrite = { _, account, _ in
            if account == b.slot && !rejectedSlot { rejectedSlot = true; return true }
            return false
        }
        try await expectFailure(.unavailable, "renewal slot write failure") { try await service.switchTo(b, allReferences: [a,b]) }
        try expect((try recoveryRecords()).first?["credential"] != nil && keychain.items[liveKey] == renewalBaseline[liveKey],
            "rotated grant survives a failed target slot CAS without changing active account")
        keychain.rejectWrite = nil
        try await service.switchTo(b, allReferences: [a,b])
        try expect(transport.tokenRequests.count == 1 && (try recoveryRecords()).isEmpty, "next explicit switch recovers successor without another POST")

        try resetExpiredTarget()
        transport.profileIdentityOverride = "a"
        try await expectFailure(.identityChanged, "renewed target identity mismatch") { try await service.switchTo(b, allReferences: [a,b]) }
        try expect((try recoveryRecords()).first?["credential"] != nil && keychain.items[liveKey] == renewalBaseline[liveKey],
            "identity failure keeps successor and never installs it")
        transport.profileIdentityOverride = nil
        try await service.switchTo(b, allReferences: [a,b])
        try expect(transport.tokenRequests.count == 1, "identity retry uses saved successor")

        try resetExpiredTarget()
        transport.afterProfile = {
            guard transport.tokenRequests.count == 1,
                let key = keychain.items.keys.first(where: { $0.hasPrefix(ClaudeSubscriptionService.nativeService + "|renewal-") }),
                var record = try? ClaudeSubscriptionService.object(keychain.items[key]!) else { return }
            record["syntheticConcurrentWriter"] = true
            keychain.items[key] = try? ClaudeSubscriptionService.bytes(record)
        }
        try await expectFailure(.identityChanged, "recovery changes during identity request") { try await service.switchTo(b, allReferences: [a,b]) }
        try expect(keychain.items[liveKey] == renewalBaseline[liveKey] && transport.tokenRequests.count == 1,
            "concurrently replaced recovery is never silently installed")

        try resetExpiredTarget()
        transport.tokenHook = { try config("b").write(to: configURL) }
        try await expectFailure(.identityChanged, "active config changes during renewal") { try await service.switchTo(b, allReferences: [a,b]) }
        try expect((try Data(contentsOf: configURL)) == config("b") && (try recoveryRecords()).first?["credential"] != nil,
            "source conflict preserves external config and recovered grant")
        try renewalConfig.write(to: configURL); transport.tokenHook = nil
        try await service.switchTo(b, allReferences: [a,b])
        try expect(transport.tokenRequests.count == 1, "source conflict recovery does not repeat grant consumption")

        try resetExpiredTarget()
        var concurrentBytes = Data()
        transport.tokenHook = {
            var root = try ClaudeSubscriptionService.object(keychain.items[bKey]!)
            root["syntheticConcurrentWriter"] = true
            concurrentBytes = try ClaudeSubscriptionService.bytes(root)
            keychain.items[bKey] = concurrentBytes
        }
        try await expectFailure(.identityChanged, "target changes during renewal") { try await service.switchTo(b, allReferences: [a,b]) }
        transport.tokenHook = nil
        try await expectFailure(.identityChanged, "conflicting slot is not overwritten by recovery") { try await service.switchTo(b, allReferences: [a,b]) }
        try expect(transport.tokenRequests.count == 1 && keychain.items[bKey] == concurrentBytes && (try recoveryRecords()).first?["credential"] != nil,
            "concurrent target revision preserves both external bytes and recovery")
        keychain.items[liveKey] = credential("b")
        try config("b").write(to: configURL)
        try await expectFailure(.reauthenticationRequired, "same refresh grant cannot clear uncertain recovery") {
            _ = try await service.capture(slot: b.slot, replacing: b)
        }
        try expect((try recoveryRecords()).first?["credential"] != nil && keychain.items[bKey] == concurrentBytes, "same-grant capture preserves recovery and target slot")
        let exactRecovery = (try recoveryRecords()).first!["credential"] as! [String: Any]
        keychain.items[liveKey] = try ClaudeSubscriptionService.bytes(exactRecovery)
        _ = try await service.capture(slot: b.slot, replacing: b)
        try expect((try recoveryRecords()).isEmpty, "exact persisted successor permits explicit recovery save")

        try resetExpiredTarget()
        transport.tokenStatus = 400
        try await expectFailure(.reauthenticationRequired, "seed pending marker for fresh-grant capture") {
            try await service.switchTo(b, allReferences: [a, b])
        }
        transport.tokenStatus = 200
        let pendingSlot = keychain.items[bKey], pendingRecord = try ClaudeSubscriptionService.bytes(recoveryRecords().first!)
        keychain.items[liveKey] = credential("b"); try config("b").write(to: configURL)
        try await expectFailure(.reauthenticationRequired, "same grant with pending-only marker cannot be recaptured") {
            _ = try await service.capture(slot: b.slot, replacing: b)
        }
        try expect(keychain.items[bKey] == pendingSlot && (try ClaudeSubscriptionService.bytes(recoveryRecords().first!)) == pendingRecord,
            "same-grant capture never changes a pending-only marker or saved slot")
        keychain.items[liveKey] = renewalBaseline[liveKey]; try renewalConfig.write(to: configURL)
        try await expectFailure(.reauthenticationRequired, "capture cannot re-enable consumed refresh POST") {
            try await service.switchTo(b, allReferences: [a, b])
        }
        try expect(transport.tokenRequests.count == 1, "same-grant capture cannot reopen renewal admission")
        let freshGrant = Data(String(decoding: credential("b"), as: UTF8.self).replacingOccurrences(of: "synthetic-rotating-b", with: "synthetic-fresh-official-b").utf8)
        keychain.items[liveKey] = freshGrant
        try config("b").write(to: configURL)
        _ = try await service.capture(slot: b.slot, replacing: b)
        try expect((try recoveryRecords()).isEmpty, "independent fresh grant permits explicit recovery save")

        for mode in ["read-path", "delete-path", "delete-live", "record-conflict", "delete-before-failure", "delete-after-failure", "restore-marker-conflict"] {
            try resetExpiredTarget()
            transport.tokenStatus = 400
            try await expectFailure(.reauthenticationRequired, "seed marker for capture finalization \(mode)") {
                try await service.switchTo(b, allReferences: [a,b])
            }
            transport.tokenStatus = 200
            keychain.items[liveKey] = freshGrant
            try config("b").write(to: configURL)
            let oldSlot = keychain.items[bKey]
            let recoveryKey = keychain.items.keys.first { $0.hasPrefix(ClaudeSubscriptionService.nativeService + "|renewal-") }!
            let oldMarker = keychain.items[recoveryKey]!
            var externalRoot = try ClaudeSubscriptionService.object(oldMarker)
            externalRoot["syntheticConcurrentRecovery"] = true
            let externalMarker = try ClaudeSubscriptionService.bytes(externalRoot)
            var injected = false
            keychain.beforeRead = { serviceName, account in
                guard serviceName == ClaudeSubscriptionService.nativeService, keychain.key(serviceName, account) == recoveryKey,
                    !injected, keychain.items[bKey] != oldSlot
                else { return }
                if mode == "read-path" {
                    injected = true; try? config("a").write(to: legacyConfigURL)
                } else if mode == "record-conflict" {
                    injected = true; keychain.items[recoveryKey] = externalMarker
                }
            }
            keychain.rejectWrite = { serviceName, account, data in
                guard serviceName == ClaudeSubscriptionService.nativeService, keychain.key(serviceName, account) == recoveryKey else { return false }
                if data == nil, !injected {
                    switch mode {
                    case "delete-path", "restore-marker-conflict":
                        injected = true; try? config("a").write(to: legacyConfigURL)
                    case "delete-live":
                        injected = true; keychain.items[liveKey] = credential("a")
                    case "delete-before-failure":
                        injected = true; return true
                    case "delete-after-failure":
                        injected = true; keychain.failAfterWrite = ClaudeSubscriptionService.nativeService
                    default: break
                    }
                } else if mode == "restore-marker-conflict", data != nil, injected {
                    keychain.items[recoveryKey] = externalMarker
                    return true
                }
                return false
            }
            let expected: ClaudeSubscriptionService.Failure = mode == "restore-marker-conflict" ? .rollbackFailed :
                (mode.hasSuffix("failure") ? .rolledBack : .identityChanged)
            try await expectFailure(expected, "capture finalization \(mode)") {
                _ = try await service.capture(slot: b.slot, replacing: b)
            }
            keychain.beforeRead = nil
            keychain.rejectWrite = nil
            try expect(injected && keychain.items[bKey] == oldSlot, "capture finalization restores owned slot \(mode)")
            try expect(keychain.items[recoveryKey] == (mode == "record-conflict" || mode == "restore-marker-conflict" ? externalMarker : oldMarker),
                "capture finalization preserves the correct marker \(mode)")
            try expect((try Data(contentsOf: configURL)) == config("b"), "capture finalization leaves global config \(mode)")
            if mode == "read-path" || mode == "delete-path" || mode == "restore-marker-conflict" {
                try expect((try Data(contentsOf: legacyConfigURL)) == config("a"), "capture finalization preserves external legacy \(mode)")
            }
            if mode == "delete-live" { try expect(keychain.items[liveKey] == credential("a"), "capture finalization preserves external live credential") }
            try Data().write(to: legacyConfigURL)
        }

        try resetExpiredTarget()
        transport.tokenStatus = 400
        try await expectFailure(.reauthenticationRequired, "seed pending marker for capture race") { try await service.switchTo(b, allReferences: [a,b]) }
        keychain.items[liveKey] = freshGrant; try config("b").write(to: configURL)
        keychain.rejectWrite = { _, account, _ in
            if account == b.slot, let key = keychain.items.keys.first(where: { $0.hasPrefix(ClaudeSubscriptionService.nativeService + "|renewal-") }),
                var record = try? ClaudeSubscriptionService.object(keychain.items[key]!) {
                record["syntheticConcurrentWriter"] = true
                keychain.items[key] = try? ClaudeSubscriptionService.bytes(record)
            }
            return false
        }
        try await expectFailure(.identityChanged, "capture cleanup must retain concurrent recovery") { _ = try await service.capture(slot: b.slot, replacing: b) }
        try expect((try recoveryRecords()).first?["syntheticConcurrentWriter"] as? Bool == true, "capture cleanup never deletes a different recovery snapshot")
        keychain.rejectWrite = nil

        try resetExpiredTarget()
        transport.tokenHook = {
            try await expectFailure(.busy, "concurrent explicit switch") { try await service.switchTo(b, allReferences: [a,b]) }
        }
        try await service.switchTo(b, allReferences: [a,b])
        try expect(transport.tokenRequests.count == 1, "existing mutation locks serialize renewal without duplicate POST")

        try resetExpiredTarget()
        var encodedCredential = try ClaudeSubscriptionService.object(credential("b"))
        var encodedOAuth = encodedCredential["claudeAiOauth"] as! [String: Any]
        encodedOAuth["expiresAt"] = now.timeIntervalSince1970 * 1000 - 1
        encodedCredential["claudeAiOauth"] = encodedOAuth
        let expiredCSWAP = try ClaudeSubscriptionService.bytes(encodedCredential)
        try Data(expiredCSWAP.base64EncodedString().utf8).write(to: encodedFile)
        try await service.switchTo(imported, allReferences: [a,imported])
        let encodedRenewed = Data(base64Encoded: String(decoding: try Data(contentsOf: encodedFile), as: UTF8.self))!
        try expect(try ClaudeSubscriptionService.oauth(encodedRenewed, now: now)["refreshToken"] as? String == "synthetic-b-successor",
            "explicit renewal preserves the imported slot base64 storage contract")

        try resetExpiredTarget()
        try Data(expiredCSWAP.base64EncodedString().utf8).write(to: encodedFile)
        transport.tokenThrows = true
        try await expectFailure(.reauthenticationRequired, "imported grant response unknown") { try await service.switchTo(imported, allReferences: [a,imported]) }
        let newOfficialCredential = Data(String(decoding: credential("b"), as: UTF8.self).replacingOccurrences(of: "synthetic-rotating-b", with: "synthetic-official-relogin-b").utf8)
        try Data(newOfficialCredential.base64EncodedString().utf8).write(to: encodedFile)
        transport.tokenThrows = false
        try await service.switchTo(imported, allReferences: [a,imported])
        try expect(transport.tokenRequests.count == 1 && (try recoveryRecords()).isEmpty,
            "verified external official re-login supersedes an imported uncertain grant without another POST")

        let globalObservation = try await service.verifyCurrent()
        try expect(globalObservation.configPath == configURL.standardizedFileURL.path && (try Data(contentsOf: legacyConfigURL)).isEmpty,
            "empty legacy remains empty through native capture switch quota and rollback")
        try Data(contentsOf: configURL).write(to: legacyConfigURL)
        let legacyObservation = try await service.verifyCurrent()
        try expect(legacyObservation.configPath == legacyConfigURL.standardizedFileURL.path, "nonempty legacy wins when both files exist")
        try expect(try !service.isCurrent(globalObservation), "existing observation rejects changed config path")
        try Data().write(to: legacyConfigURL)
        try expect(try !service.isCurrent(legacyObservation) && service.isCurrent(globalObservation), "observations track the resolved path")
        let beforeLegacySwitchGlobal = try Data(contentsOf: configURL)
        try beforeLegacySwitchGlobal.write(to: legacyConfigURL)
        try await service.switchTo(a, allReferences: [a,imported])
        try expect(try service.activeFingerprint() == a.identityFingerprint && (try Data(contentsOf: configURL)) == beforeLegacySwitchGlobal,
            "nonempty legacy switch updates only the selected config")
        try expect(try ClaudeSubscriptionService.object(Data(contentsOf: legacyConfigURL))["syntheticKeep"] as? Int == 42,
            "legacy switch preserves shared config fields")
        try testGlobalConfigSelection(root: root)

        print("PASS claude-subscription fixture (baseline, explicit renewal recovery, identity and concurrency guards)")
    }
}
