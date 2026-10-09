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
    var writeCount = 0
    func key(_ service: String, _ account: String) -> String { service + "|" + account }
    func read(_ service: String, _ account: String) throws -> Data? { items[key(service,account)] }
    func write(_ service: String, _ account: String, _ data: Data?) throws {
        writeCount += 1
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
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        calls.append(request.url!.path)
        if fail { throw TestFailure.synthetic }
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let name = auth.contains("synthetic-b") ? "b" : "a"
        if request.url!.path.hasSuffix("profile") {
            afterProfile?()
            return LocalCLIHTTPResponse(statusCode: 200, headers: [:], data: Data("{\"account\":{\"uuid\":\"synthetic-\(name)\",\"email\":\"\(name)@synthetic.invalid\"},\"organization\":{\"uuid\":\"synthetic-org\"}}".utf8))
        }
        afterUsage?()
        return LocalCLIHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":50,"resets_at":"2030-01-07T00:00:00Z"},"limits":[{"is_active":true,"percent":70,"scope":{"model":{"display_name":"Synthetic Model"}},"resets_at":"2030-01-07T00:00:00Z"}]}"#.utf8))
    }
}
@main struct ClaudeSubscriptionFixture {
    static func main() async throws {
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
        func expectFailure(_ expected: ClaudeSubscriptionService.Failure, _ label: String, operation: () async throws -> Void) async throws {
            do { try await operation(); throw TestFailure.failed(label + " accepted") }
            catch let failure as ClaudeSubscriptionService.Failure { guard failure == expected else { throw TestFailure.failed(label + " wrong failure: \(failure)") } }
        }
        let liveKey = keychain.key("Claude Code-credentials", ClaudeSubscriptionService.keychainAccount)
        keychain.items[liveKey] = credential("a"); try config("a").write(to: configURL)
        let a = try await service.capture(slot: UUID().uuidString)
        keychain.items[liveKey] = credential("b"); try config("b").write(to: configURL)
        let b = try await service.capture(slot: UUID().uuidString)
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
        let beforeKeychain = keychain.items, beforeConfig = try Data(contentsOf: configURL)
        keychain.failWrite = "Claude Code-credentials"
        do { try await service.switchTo(b, allReferences: [a,b]); throw TestFailure.failed("write failure accepted") }
        catch ClaudeSubscriptionService.Failure.rolledBack {}
        try expect(keychain.items == beforeKeychain && (try Data(contentsOf: configURL)) == beforeConfig, "failed keychain write fully rolls back")
        keychain.failAfterWrite = "Claude Code-credentials"
        do { try await service.switchTo(b, allReferences: [a,b]); throw TestFailure.failed("post-write failure accepted") }
        catch ClaudeSubscriptionService.Failure.rolledBack {}
        try expect(keychain.items == beforeKeychain && (try Data(contentsOf: configURL)) == beforeConfig, "post-write keychain failure fully rolls back")

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
        let changed = await service.loadQuota(a, now: now)
        try expect(changed.messageCode == "local_cli_claude_credentials_changed" && changed.windows.isEmpty, "inflight credential change discards quota")
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
        print("PASS claude-subscription fixture (26 baseline + verified-current and cswap-lock guards)")
    }
}
