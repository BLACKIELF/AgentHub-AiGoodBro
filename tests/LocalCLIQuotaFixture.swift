import Foundation
import Darwin

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// DispatchParticipationSync's user-facing errors depend on the app language type.
// The fixture supplies only that compile-time dependency while compiling the real
// bounded file reader and the real LocalCLI sources.
struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ chinese: String, _ english: String) -> String { english }
}

private final class MockTransport: LocalCLIQuotaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: LocalCLIHTTPResponse
    private(set) var request: URLRequest?

    init(status: Int = 200, data: Data) {
        reply = LocalCLIHTTPResponse(statusCode: status, headers: [:], data: data)
    }

    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        capture(request)
        return reply
    }

    private func capture(_ request: URLRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }
}

private enum FixtureFailure: Error { case assertion(String) }

@main
struct LocalCLIQuotaFixture {
    static func main() async throws {
        try testPublicModel()
        try testParsers()
        try testBoundedRegularFiles()
        try await testCredentialRenewal()
        try await testGrokLoad()
        try await testKimiLoadAndDeviceIsolation()
        try await testClaudeLoadAndProfileIsolation()
        try await testClaudeCredentialChangesDiscardQuota()
        try testCCSwitchSchema20()
        try await testClaudeRelay()
        try await testOpenCodeProviderIsolation()
        try await testOpenCodeAuthorizationStates()
        try await testUnsupportedKindsRemainUnknown()
        try await testHTTPStatesAndResponseBound()
        print("PASS local-cli-quota fixture")
    }

    private static func testCredentialRenewal() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = data(#"{"access_token":"old","refresh_token":"refresh","user_id":"same-user","custom":7}"#)
        let reply = data(#"{"access_token":"new","refresh_token":"rotated","expires_in":"3600"}"#)
        let updated = try LocalCLIQuotaRefresh.renewedKimiCredential(original, response: reply, now: now)
        let kimi = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        try expect(kimi["user_id"] as? String == "same-user" && kimi["custom"] as? Int == 7, "Kimi refresh preserves account and unknown fields")
        try expect(kimi["expires_at"] as? Double == now.timeIntervalSince1970 + 3600, "Kimi computes expiry")
        let request = try LocalCLIQuotaRefresh.kimiRefreshRequest(refreshToken: "a+b&c", deviceID: "synthetic-device")
        try expect(request.url?.absoluteString == "https://auth.kimi.com/api/oauth/token", "Kimi fixed refresh origin")
        try expect(String(decoding: request.httpBody!, as: UTF8.self).contains("refresh_token=a%2Bb%26c"), "form secrets cannot add parameters")
        for invalid in [#"{"access_token":"a","refresh_token":"b","expires_in":true}"#,
                        #"{"access_token":"a","refresh_token":"b","expires_in":-1}"#,
                        #"{"access_token":"a","expires_in":3600}"#] {
            try expectThrows("invalid refresh must not alter credentials") {
                _ = try LocalCLIQuotaRefresh.renewedKimiCredential(original, response: data(invalid), now: now)
            }
        }
        try withDirectory { directory in
            let file = directory.appendingPathComponent("credential.json")
            try original.write(to: file)
            try LocalCLIQuotaRefresh.replaceCredential(file, expected: original, updated: updated)
            let persisted = try Data(contentsOf: file)
            try expect(persisted == updated, "atomic credential replacement")
            try expectThrows("concurrent account changes prevent overwrite") {
                try LocalCLIQuotaRefresh.replaceCredential(file, expected: original, updated: data("{}"))
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            try expect(attributes[.posixPermissions] as? Int == 0o600, "refreshed credentials remain private")
        }
        let sessionKey = "https://auth.x.ai::fixture-client"
        let entry: [String: Any] = ["key":"old", "refresh_token":"refresh", "user_id":"same-user",
            "oidc_issuer":"https://auth.x.ai", "oidc_client_id":"fixture-client", "principal_type":"team", "principal_id":"fixture-team"]
        let grokOriginal = try JSONSerialization.data(withJSONObject: [sessionKey:entry,"unrelated":["retained":true]])
        let grokReply = data(#"{"access_token":"renewed","expires_in":3600,"token_type":"Bearer"}"#)
        let grokUpdated = try LocalCLIQuotaRefresh.renewedGrokCredential(grokOriginal, sessionKey: sessionKey, response: grokReply, now: now)
        let grok = try JSONSerialization.jsonObject(with: grokUpdated) as! [String: Any]
        let saved = grok[sessionKey] as! [String: Any]
        try expect(saved["refresh_token"] as? String == "refresh" && saved["user_id"] as? String == "same-user" && saved["principal_id"] as? String == "fixture-team", "Grok preserves session when refresh token is not rotated")
        try expect(grok["unrelated"] != nil, "other credentials retained")
        var wrongIssuer = entry; wrongIssuer["oidc_issuer"] = "https://other.invalid"
        try expectThrows("Grok token never sent to arbitrary issuer") {
            _ = try LocalCLIQuotaRefresh.grokRefreshRequest(wrongIssuer, sessionKey: sessionKey)
        }
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("auth.json")
            try grokOriginal.write(to: file)
            let transport = MockTransport(data: grokReply)
            try await LocalCLIQuotaRefresh.renewGrokCredential(directory: directory, transport: transport)
            let renewed = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            try expect((renewed[sessionKey] as? [String: Any])?["key"] as? String == "renewed", "Grok refresh persisted")
            try expect(transport.request?.url?.absoluteString == "https://auth.x.ai/oauth2/token", "official Grok refresh endpoint")
            let body = String(decoding: transport.request!.httpBody!, as: UTF8.self)
            try expect(body.contains("principal_id=fixture-team"), "principal selection preserved")
            let lockURL = directory.appendingPathComponent("auth.json.lock")
            let descriptor = open(lockURL.path, O_RDWR)
            try expect(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0, "fixture holds official lock")
            defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
            let unused = MockTransport(data: grokReply)
            do {
                try await LocalCLIQuotaRefresh.renewGrokCredential(directory: directory, transport: unused)
                throw FixtureFailure.assertion("must not break Grok lock")
            } catch is FixtureFailure { throw FixtureFailure.assertion("must not break Grok lock") }
            catch {}
            try expect(unused.request == nil && FileManager.default.fileExists(atPath: lockURL.path), "held lock prevents network and stays on disk")
        }
    }

    private static func testPublicModel() throws {
        let home = URL(fileURLWithPath: "/synthetic-home", isDirectory: true)
        try expect(LocalCLIKind.allCases.count == 10, "kind count")
        try expect(LocalCLIKind.openCode.commandName == "opencode", "OpenCode command")
        try expect(
            LocalCLIKind.openCode.defaultConfigDirectory(home: home).path == "/synthetic-home/.local/share/opencode",
            "OpenCode config path")
        try expect(
            LocalCLIKind.mimo.defaultConfigDirectory(home: home).path == "/synthetic-home/.local/share/mimocode",
            "MiMo data path")
        try expect(LocalCLIKind.workBuddy.supportsTerminalSignIn, "WorkBuddy native sign-in")
        try expect(LocalCLIKind.zcode.isDesktopApplication && LocalCLIKind.zcode.supportsNativeOpen && !LocalCLIKind.zcode.supportsTerminalSignIn,
                   "ZCode opens its desktop application without a CLI sign-in")
        try expect(LocalCLIKind.trae.supportsNativeOpen && !LocalCLIKind.trae.supportsTerminalSignIn,
                   "TRAE desktop-only capability")
        let profile = LocalCLIProfile(
            id: "p1", kind: .grok, displayName: "Synthetic", configDirectory: "/synthetic", isDefault: false)
        let roundTrip = try JSONDecoder().decode(
            LocalCLIProfile.self,
            from: JSONEncoder().encode(profile))
        try expect(roundTrip == profile, "profile Codable")
    }

    private static func testCCSwitchSchema20() throws {
        try withDirectory { directory in
            let database = directory.appendingPathComponent("synthetic-cc-switch.db")
            let missing = directory.appendingPathComponent("synthetic-missing.db")
            let absent = try CCSwitchClaudeRelay.currentCredential(databaseURL: missing)
            try expect(absent == nil && !FileManager.default.fileExists(atPath: missing.path), "missing relay DB is not created")
            let settings = #"{"env":{"ANTHROPIC_BASE_URL":"https://claude.moylor.com/v1/","ANTHROPIC_AUTH_TOKEN":"synthetic-schema20-token"}}"#
            let meta = #"{"usage_script":{"enabled":true,"code":"throw new Error('synthetic script must never execute')"},"future_field":{"retained":true}}"#
            func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
            func execute(_ sql: String) throws {
                _ = try BoundedLocalProcess.run(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                    arguments: ["-init", "/dev/null", database.path, sql])
            }
            // Exact providers columns from CC Switch v4.0.4. Its schema-20
            // migration only adds enabled_pi to the separate MCP table.
            try execute("""
                PRAGMA user_version=20;
                CREATE TABLE providers (
                    id TEXT NOT NULL, app_type TEXT NOT NULL, name TEXT NOT NULL,
                    settings_config TEXT NOT NULL, website_url TEXT, category TEXT,
                    created_at INTEGER, sort_index INTEGER, notes TEXT, icon TEXT,
                    icon_color TEXT, meta TEXT NOT NULL DEFAULT '{}',
                    is_current BOOLEAN NOT NULL DEFAULT 0,
                    in_failover_queue BOOLEAN NOT NULL DEFAULT 0,
                    PRIMARY KEY (id, app_type)
                );
                CREATE TABLE mcp_servers (id TEXT PRIMARY KEY, enabled_pi BOOLEAN NOT NULL DEFAULT 0);
                INSERT INTO providers (id, app_type, name, settings_config, meta, is_current)
                VALUES ('synthetic-active', 'claude', 'synthetic', \(quoted(settings)), \(quoted(meta)), 1),
                       ('synthetic-other', 'codex', 'synthetic', '{}', '{}', 1);
                """)
            let before = try Data(contentsOf: database)
            let credential = try CCSwitchClaudeRelay.currentCredential(databaseURL: database)
            try expect(credential?.token == "synthetic-schema20-token" && credential?.fingerprint.count == 64, "actual schema-20 SQLite relay is compatible")
            let after = try Data(contentsOf: database)
            try expect(before == after && !FileManager.default.fileExists(atPath: database.path + "-journal"), "relay DB remains unchanged after background read")
            try execute("INSERT INTO providers (id, app_type, name, settings_config, meta, is_current) VALUES ('synthetic-second', 'claude', 'synthetic', \(quoted(settings)), \(quoted(meta)), 1);")
            try expectThrows("ambiguous current providers fail closed") { _ = try CCSwitchClaudeRelay.currentCredential(databaseURL: database) }
            try execute("UPDATE providers SET is_current=0 WHERE app_type='claude';")
            let inactive = try CCSwitchClaudeRelay.currentCredential(databaseURL: database)
            try expect(inactive == nil, "inactive relay never becomes current")
        }
    }

    private static func testClaudeRelay() async throws {
        try expect(CCSwitchClaudeRelay.selfTest(), "relay parser and fixed endpoint")
        let profile = LocalCLIProfile(id: "relay", kind: .claudeCode, displayName: "Synthetic", configDirectory: LocalCLIKind.claudeCode.defaultConfigDirectory(home: FileManager.default.homeDirectoryForCurrentUser).path, isDefault: true)
        let transport = MockTransport(data: Data("{\"remaining\":46.72,\"unit\":\"USD\"}".utf8))
        var keychainReads = 0
        let reader = LocalCLIQuotaReader(transport: transport, fileReader: { _,_,_ in nil }, claudeKeychainReader: { keychainReads += 1; return nil },
            claudeRelayReader: { CCSwitchClaudeRelay.Credential(token: "synthetic-only", fingerprint: "synthetic-moylor") })
        let value = await reader.load(profile: profile)
        try expect(value.state == .available && value.balance == 46.72 && value.balanceCurrency == "USD", "relay balance result")
        try expect(value.sourceLabel == "CC Switch · moylor" && value.windows.isEmpty && value.identityFingerprint == "synthetic-moylor", "relay separate from subscription")
        try expect(transport.request?.url?.absoluteString == "https://claude.moylor.com/v1/usage" && keychainReads == 0, "relay cannot use Anthropic OAuth")
        var generation = 0
        let changed = LocalCLIQuotaReader(transport: transport, fileReader: { _,_,_ in nil }, claudeKeychainReader: { nil },
            claudeRelayReader: { generation += 1; return CCSwitchClaudeRelay.Credential(token: "synthetic-only", fingerprint: "synthetic-\(generation)") })
        let stale = await changed.load(profile: profile)
        try expect(stale.state == .unavailable && stale.balance == nil, "provider switch rejects stale relay balance")
    }

    private static func testParsers() throws {
        let grok = try LocalCLIQuotaReader.parseGrok(data(#"""
        {
          "config":{"creditUsagePercent":12.5,"currentPeriod":{"end":"2026-09-11T00:00:00Z"},"subscriptionTier":"super"}
        }
        """#))
        try expect(grok.windows.first?.usedPercent == 12.5, "Grok percent")
        try expect(grok.plan == "super", "Grok plan")
        let disabledOnDemand = try LocalCLIQuotaReader.parseGrok(data(#"{"config":{"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"currentPeriod":{"end":"2026-10-01T00:00:00Z"}}}"#))
        try expect(disabledOnDemand.windows.isEmpty, "Grok disabled on-demand is valid unknown subscription usage")
        try expect(disabledOnDemand.periodResetsAt != nil, "Grok period date survives missing percentage")
        let separateOnDemand = try LocalCLIQuotaReader.parseGrok(data(#"{"config":{"onDemandCap":{"val":100},"onDemandUsed":{"val":30}}}"#))
        try expect(separateOnDemand.windows.isEmpty, "Grok on-demand is not subscription percentage")
        let legacyGrok = try LocalCLIQuotaReader.parseGrok(data(#"{"config":{"monthlyLimit":{"val":2000},"used":{"val":500},"prepaidBalance":{"val":-500}}}"#))
        try expect(legacyGrok.windows.first?.usedPercent == 25 && legacyGrok.balanceUSD == 5, "Grok included budget and USD ledger cents")
        let zeroBalance = try LocalCLIQuotaReader.parseGrok(data(#"{"config":{"prepaidBalance":{}}}"#))
        try expect(zeroBalance.balanceUSD == 0 && zeroBalance.windows.isEmpty, "Grok proto3 zero is known without inferred usage")
        try expect(grok.balanceUSD == nil, "Grok omitted balance stays unknown")
        try expectThrows("invalid money is not a balance") {
            _ = try LocalCLIQuotaReader.parseGrok(data(#"{"config":{"prepaidBalance":{"val":true}}}"#))
        }

        let kimi = try LocalCLIQuotaReader.parseKimi(data(#"""
        {
          "usage":{"limit":"100","remaining":"75","resetTime":"2026-09-17T00:00:00Z"},
          "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"80","used":"20"}}]
        }
        """#))
        try expect(kimi.windows.map(\.usedPercent) == [25, 25], "Kimi windows")
        try expect(kimi.windows[1].label == "5-hour", "Kimi window label")
        let pools = try LocalCLIQuotaReader.parseKimi(data(#"{"usages":{"limit_5h":{"used_ratio":0.625,"reset_time":"2026-09-24T00:00:00Z"},"limit_7d":{"used_ratio":0.125},"limit_month_total":{"used_ratio":0.0056}}}"#))
        try expect(pools.windows.count == 3 && zip(pools.windows.map(\.usedPercent), [62.5, 12.5, 0.56]).allSatisfy { abs($0 - $1) < 0.000001 }, "Kimi ratio pools use percentages and keep monthly")
        try expect(pools.windows.first?.resetsAt != nil, "Kimi ratio pool reset date")
        let partialPools = try LocalCLIQuotaReader.parseKimi(data(#"{"usages":{"limit_5h":{"used_ratio":0},"limit_7d":{"reset_time":"2026-09-24T00:00:00Z"}}}"#))
        try expect(partialPools.windows.count == 1 && partialPools.windows[0].usedPercent == 0, "Kimi distinguishes missing from zero")
        let mixedPools = try LocalCLIQuotaReader.parseKimi(data(#"{"usages":{"limit_month_total":{"used_ratio":0.25},"limit_7d":{"used_ratio":0.3}},"usage":{"limit":100,"used":75},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"used":10}},{"window":{"duration":10080,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"used":75}}]}"#))
        let mixedByID = Dictionary(uniqueKeysWithValues: mixedPools.windows.map { ($0.id, $0.usedPercent) })
        try expect(mixedByID == ["session":10, "weekly":30, "monthly":25], "Kimi mixed schemas retain missing legacy pools and prefer new kinds without duplicates")
        try expectThrows("empty Kimi pools are not a successful refresh") {
            _ = try LocalCLIQuotaReader.parseKimi(data(#"{"usages":{}}"#))
        }
        try expectThrows("invalid Kimi ratio") {
            _ = try LocalCLIQuotaReader.parseKimi(data(#"{"usages":{"limit_5h":{"used_ratio":true}}}"#))
        }
        do {
            _ = try LocalCLIQuotaReader.parseKimi(data(#"{"limits":[{"window":{"duration":9223372036854775808,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":10,"used":1}}]}"#))
            throw FixtureFailure.assertion("Kimi overflowing window accepted")
        } catch is FixtureFailure { throw FixtureFailure.assertion("Kimi overflowing window accepted") }
        catch { }

        let claude = try LocalCLIQuotaReader.parseClaude(data(#"""
        {
          "five_hour":{"utilization":10,"resets_at":"2026-09-10T12:00:00Z"},
          "seven_day":{"utilization":20},
          "limits":[{"kind":"weekly_scoped","percent":30,"is_active":true,"scope":{"model":{"display_name":"Synthetic model"}}}]
        }
        """#))
        try expect(claude.map(\.usedPercent) == [10, 20, 30], "Claude windows")
        let partialClaude = try LocalCLIQuotaReader.parseClaude(data(#"{"five_hour":{"utilization":10},"seven_day":{"resets_at":"2026-09-24T00:00:00Z"},"seven_day_opus":{"utilization":null}}"#))
        try expect(partialClaude.count == 1 && partialClaude[0].usedPercent == 10, "missing Claude window does not discard valid usage")

        let openCode = try LocalCLIQuotaReader.parseOpenCode(data(#"""
        {
          "usage":{"rolling":{"status":"ok","percent":4},"weekly":{"status":"rate-limited","percent":100},"monthly":{"percent":1}}
        }
        """#))
        try expect(openCode.map(\.usedPercent) == [4, 100, 1], "OpenCode windows")
        let absentClaude = try LocalCLIQuotaReader.parseClaude(data("{}"))
        try expect(absentClaude.isEmpty, "absent Claude windows stay absent")
        let absentOpenCode = try LocalCLIQuotaReader.parseOpenCode(data(#"{"usage":{}}"#))
        try expect(absentOpenCode.isEmpty, "absent OpenCode windows stay absent")

        try expectThrows("Bool percent") {
            _ = try LocalCLIQuotaReader.parseGrok(data(#"{"config":{"creditUsagePercent":true}}"#))
        }
        try expectThrows("negative usage") {
            _ = try LocalCLIQuotaReader.parseKimi(data(#"{"usage":{"limit":"10","used":"-1"}}"#))
        }
        try expectThrows("zero denominator") {
            _ = try LocalCLIQuotaReader.parseKimi(data(#"{"usage":{"limit":"0","used":"0"}}"#))
        }
        try expectThrows("nonfinite string") {
            _ = try LocalCLIQuotaReader.parseKimi(data(#"{"usage":{"limit":"10","used":"nan"}}"#))
        }
        try expectThrows("percent above range") {
            _ = try LocalCLIQuotaReader.parseOpenCode(data(#"{"usage":{"rolling":{"percent":101}}}"#))
        }
    }

    private static func testBoundedRegularFiles() throws {
        try withDirectory { directory in
            let normal = directory.appendingPathComponent("normal")
            try Data("bounded".utf8).write(to: normal)
            let read = try DispatchParticipationSync.readBoundedRegularFile(normal, maximumBytes: 7)
            try expect(read == Data("bounded".utf8), "bounded regular read")

            let oversized = directory.appendingPathComponent("oversized")
            try Data(repeating: 0x41, count: 33).write(to: oversized)
            try expectThrows("oversized file") {
                _ = try DispatchParticipationSync.readBoundedRegularFile(oversized, maximumBytes: 32)
            }

            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: normal)
            try expectThrows("symbolic link") {
                _ = try DispatchParticipationSync.readBoundedRegularFile(link, maximumBytes: 32)
            }
        }
    }

    private static func testGrokLoad() async throws {
        try await withDirectory { directory in
            try data(#"""
            {
              "https://auth.x.ai::synthetic":{"key":"synthetic-grok-token","user_id":"synthetic-user-123","expires_at":"2030-01-01T00:00:00Z"}
            }
            """#).write(to: directory.appendingPathComponent("auth.json"))
            let transport = MockTransport(data: data(#"{"config":{"creditUsagePercent":22,"subscriptionTier":"SuperGrok"}}"#))
            let result = await LocalCLIQuotaReader(transport: transport).load(
                profile: profile(.grok, directory),
                now: Date(timeIntervalSince1970: 1_800_000_000))
            try expect(result.state == .available, "Grok available")
            try expect(result.maskedIdentity == "sy***23", "Grok masked identity")
            try expect(result.identityFingerprint?.count == 64, "Grok identity fingerprint")
            try expect(transport.request?.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits", "Grok endpoint")
            try expect(transport.request?.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli", "Grok auth header")

            let currentShape = MockTransport(data: data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-29T09:55:31.379657+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},"isUnifiedBillingUser":true}}"#))
            let current = await LocalCLIQuotaReader(transport: currentShape).load(profile: profile(.grok, directory))
            try expect(current.state == .available && current.balance == 0 && current.balanceCurrency == "USD", "current Grok response keeps purchased USD balance")
            try expect(current.periodResetsAt != nil && current.windows.isEmpty, "current Grok period survives absent usage")
            try expect(current.messageCode == "local_cli_usage_not_reported" && current.resetCards == nil, "Grok unavailable usage and reset card stay distinct")

            try data(#"{"https://unofficial.example/sign-in":{"key":"synthetic-token"}}"#)
                .write(to: directory.appendingPathComponent("auth.json"))
            let unofficial = await LocalCLIQuotaReader(transport: transport).load(profile: profile(.grok, directory))
            try expect(unofficial.state == .unavailable, "Grok unofficial scope rejected")

            try data(#"{"https://auth.x.ai::one":{"key":"synthetic-one"},"https://auth.x.ai::two":{"key":"synthetic-two"}}"#)
                .write(to: directory.appendingPathComponent("auth.json"))
            let ambiguous = await LocalCLIQuotaReader(transport: transport).load(profile: profile(.grok, directory))
            try expect(ambiguous.state == .unavailable, "Grok ambiguous identities rejected")
        }
    }

    private static func testKimiLoadAndDeviceIsolation() async throws {
        try await withDirectory { directory in
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("credentials"),
                withIntermediateDirectories: true)
            try data(#"{"access_token":"synthetic-kimi-token","expires_at":2000000000,"user_id":"kimi-synthetic-id"}"#)
                .write(to: directory.appendingPathComponent("credentials/kimi-code.json"))
            let transport = MockTransport(data: data(#"{"usage":{"limit":"100","used":"5"}}"#))
            var result = await LocalCLIQuotaReader(transport: transport).load(
                profile: profile(.kimi, directory),
                now: Date(timeIntervalSince1970: 1_800_000_000))
            try expect(result.state == .unavailable, "Kimi missing device fails closed")
            try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("device_id").path), "Kimi device is not created")

            try Data("synthetic-device".utf8).write(to: directory.appendingPathComponent("device_id"))
            result = await LocalCLIQuotaReader(transport: transport).load(
                profile: profile(.kimi, directory),
                now: Date(timeIntervalSince1970: 1_800_000_000))
            try expect(result.state == .available, "Kimi available")
            try expect(transport.request?.url?.absoluteString == "https://api.kimi.com/coding/v1/usages", "Kimi endpoint")
            try expect(transport.request?.value(forHTTPHeaderField: "X-Msh-Platform") == "kimi_code_cli", "Kimi platform header")
            try expect(transport.request?.value(forHTTPHeaderField: "X-Msh-Os-Version") != nil, "Kimi OS header")
            try expect(transport.request?.value(forHTTPHeaderField: "X-Msh-Device-Id") == "synthetic-device", "Kimi existing device header")
        }
    }

    private static func testClaudeLoadAndProfileIsolation() async throws {
        try await withDirectory { directory in
            let transport = MockTransport(data: data(#"{"five_hour":{"utilization":17}}"#))
            var keychainReads = 0
            let reader = LocalCLIQuotaReader(transport: transport, claudeKeychainReader: {
                keychainReads += 1
                return nil
            })
            var result = await reader.load(
                profile: profile(.claudeCode, directory),
                now: Date(timeIntervalSince1970: 1_800_000_000))
            try expect(result.state == .needsLogin, "Claude selected directory does not use Keychain fallback")
            try expect(keychainReads == 0, "Claude nondefault directory does not query Keychain")

            try data(#"{"claudeAiOauth":{"accessToken":"synthetic-claude-token","expiresAt":2000000000000,"subscriptionType":"pro"}}"#)
                .write(to: directory.appendingPathComponent(".credentials.json"))
            result = await reader.load(
                profile: profile(.claudeCode, directory),
                now: Date(timeIntervalSince1970: 1_800_000_000))
            try expect(result.state == .available, "Claude available")
            try expect(result.planLabel == "pro", "Claude plan")
            try expect(transport.request?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20", "Claude beta header")
            try expect(result.identityFingerprint == nil, "Claude token is not fingerprinted")
        }

        let defaultDirectory = LocalCLIKind.claudeCode.defaultConfigDirectory(
            home: FileManager.default.homeDirectoryForCurrentUser)
        var keychainReads = 0
        let transport = MockTransport(data: data(#"{"five_hour":{"utilization":19}}"#))
        let reader = LocalCLIQuotaReader(
            transport: transport,
            fileReader: { _, _, _ in nil },
            claudeKeychainReader: {
                keychainReads += 1
                return data(#"{"claudeAiOauth":{"accessToken":"synthetic-keychain-token","expiresAt":2000000000000}}"#)
            })
        let defaultProfile = LocalCLIProfile(
            id: "synthetic-default-claude",
            kind: .claudeCode,
            displayName: "Synthetic default",
            configDirectory: defaultDirectory.path,
            isDefault: true)
        let keychainResult = await reader.load(
            profile: defaultProfile,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        try expect(keychainResult.state == .available, "Claude default noninteractive Keychain fixture")
        try expect(keychainReads == 2, "Claude default Keychain is rechecked in the same scope")

        var recoveryReads = 0
        let recoveryTransport = MockTransport(data: data(#"{"five_hour":{"utilization":29}}"#))
        let recoveryReader = LocalCLIQuotaReader(
            transport: recoveryTransport,
            fileReader: { _, _, _ in data(#"{"claudeAiOauth":{"accessToken":"synthetic-expired-file","expiresAt":1000}}"#) },
            claudeKeychainReader: {
                recoveryReads += 1
                return data(#"{"claudeAiOauth":{"accessToken":"synthetic-fresh-keychain","expiresAt":2000000000000}}"#)
            })
        let recovered = await recoveryReader.load(profile: defaultProfile, now: Date(timeIntervalSince1970: 1_800_000_000))
        try expect(recovered.state == .available && recoveryReads == 2, "expired default Claude file recovers current Keychain login")
        try expect(recoveryTransport.request?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-fresh-keychain", "recovery uses the fresh same-scope token")
        let isolated = await recoveryReader.load(profile: profile(.claudeCode, URL(fileURLWithPath: "/synthetic-linked")), now: Date(timeIntervalSince1970: 1_800_000_000))
        try expect(isolated.state == .needsLogin && recoveryReads == 2, "expired linked Claude account never reads global Keychain")
    }

    private static func testClaudeCredentialChangesDiscardQuota() async throws {
        let original = data(#"{"claudeAiOauth":{"accessToken":"synthetic-original","expiresAt":2000000000000}}"#)
        let replacement = data(#"{"claudeAiOauth":{"accessToken":"synthetic-replacement","expiresAt":2000000000000}}"#)
        let expired = data(#"{"claudeAiOauth":{"accessToken":"synthetic-expired","expiresAt":1000}}"#)
        let defaultDirectory = LocalCLIKind.claudeCode.defaultConfigDirectory(
            home: FileManager.default.homeDirectoryForCurrentUser)
        let defaultProfile = LocalCLIProfile(
            id: "synthetic-default-claude", kind: .claudeCode, displayName: "Synthetic",
            configDirectory: defaultDirectory.path, isDefault: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // All reads and transport responses below are synthetic. The second
        // source read happens only after the mocked usage request has returned.
        for changesTo in [replacement, nil] as [Data?] {
            var fileReads = 0
            var keychainReads = 0
            let transport = MockTransport(data: data(#"{"five_hour":{"utilization":21}}"#))
            let reader = LocalCLIQuotaReader(
                transport: transport,
                fileReader: { _, _, _ in
                    fileReads += 1
                    return fileReads == 1 ? original : changesTo
                },
                claudeKeychainReader: { keychainReads += 1; return replacement })
            let result = await reader.load(
                profile: profile(.claudeCode, URL(fileURLWithPath: "/synthetic-linked")), now: now)
            try expect(transport.request != nil && fileReads == 2, "Claude rechecks file after usage")
            try expect(result.state == .unavailable && result.windows.isEmpty && result.identityFingerprint == nil
                       && result.messageCode == "local_cli_claude_credentials_changed",
                       "changed or removed Claude file cannot publish old quota")
            try expect(keychainReads == 0, "linked Claude profile never reads default Keychain")
        }
        for fileSeed in [nil, expired] as [Data?] {
            for changesTo in [replacement, nil] as [Data?] {
                var keychainReads = 0
                let transport = MockTransport(data: data(#"{"five_hour":{"utilization":22}}"#))
                let reader = LocalCLIQuotaReader(
                    transport: transport, fileReader: { _, _, _ in fileSeed },
                    claudeKeychainReader: {
                        keychainReads += 1
                        return keychainReads == 1 ? original : changesTo
                    })
                let result = await reader.load(profile: defaultProfile, now: now)
                try expect(transport.request != nil && keychainReads == 2, "Claude selected Keychain is rechecked")
                try expect(result.state == .unavailable && result.windows.isEmpty && result.identityFingerprint == nil
                       && result.messageCode == "local_cli_claude_credentials_changed",
                           "changed or missing Keychain discards direct and expired-file recovery quota")
            }
        }
        var fileReads = 0
        let appearingFile = LocalCLIQuotaReader(
            transport: MockTransport(data: data(#"{"five_hour":{"utilization":23}}"#)),
            fileReader: { _, _, _ in
                fileReads += 1
                return fileReads == 1 ? nil : replacement
            }, claudeKeychainReader: { original })
        let appeared = await appearingFile.load(profile: defaultProfile, now: now)
        try expect(appeared.state == .unavailable && appeared.windows.isEmpty
                   && appeared.messageCode == "local_cli_claude_credentials_changed",
                   "new file source cannot inherit in-flight Keychain quota")
        var keychainReads = 0
        let deniedKeychain = LocalCLIQuotaReader(
            transport: MockTransport(data: data(#"{"five_hour":{"utilization":24}}"#)),
            fileReader: { _, _, _ in nil }, claudeKeychainReader: {
                keychainReads += 1
                if keychainReads > 1 { throw CocoaError(.fileReadNoPermission) }
                return original
            })
        let denied = await deniedKeychain.load(profile: defaultProfile, now: now)
        try expect(denied.state == .unavailable && denied.windows.isEmpty
                   && denied.messageCode == "local_cli_keychain_unavailable",
                   "Keychain recheck denial fails closed without credential fallback")
    }

    private static func testOpenCodeProviderIsolation() async throws {
        try await withDirectory { directory in
            try data(#"""
            {
              "anthropic":{"type":"oauth","access":"synthetic-underlying-token"},
              "openai":{"type":"api","key":"synthetic-underlying-key"},
              "opencode-go":{"type":"api","key":"synthetic-go-key"}
            }
            """#).write(to: directory.appendingPathComponent("auth.json"))
            let transport = MockTransport(data: data(#"{"usage":{"rolling":{"percent":9}}}"#))
            let result = await LocalCLIQuotaReader(transport: transport).load(
                profile: profile(.openCode, directory))
            try expect(result.state == .available, "OpenCode available")
            try expect(result.windows.count == 1, "OpenCode no duplicate provider totals")
            try expect(transport.request?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-go-key", "OpenCode Go key only")
            try expect(result.sourceLabel == "OpenCode Go API", "OpenCode source")

            try data(#"{"anthropic":{"type":"oauth","access":"synthetic-provider-token"}}"#)
                .write(to: directory.appendingPathComponent("auth.json"))
            let providerOnly = await LocalCLIQuotaReader(transport: transport).load(
                profile: profile(.openCode, directory))
            try expect(providerOnly.state == .unsupported,
                       "provider identity without OpenCode Go is not reported as signed out")
            try expect(providerOnly.messageCode == "local_cli_opencode_go_not_connected",
                       "provider-only OpenCode has a specific quota status")

            try data("{}").write(to: directory.appendingPathComponent("auth.json"))
            let empty = await LocalCLIQuotaReader(transport: transport).load(
                profile: profile(.openCode, directory))
            try expect(empty.state == .needsLogin, "empty OpenCode auth remains signed out")
        }
    }

    private static func testOpenCodeAuthorizationStates() async throws {
        try await withDirectory { directory in
            let selected = profile(.openCode, directory)
            try data(#"{"opencode-go":{"type":"api","key":"synthetic-go-key"}}"#)
                .write(to: directory.appendingPathComponent("auth.json"))
            func upstreamResponse(status: String, reason: String? = nil) -> TokenMonitorResponse {
                var snapshot: [String: TokenMonitorJSON] = [
                    "providers": .array([.object([
                        "provider": .string("opencode"),
                        "source": .string(TokenMonitorLocalCLIQuotaReader.sourceLabel),
                        "balanceUsd": .null,
                        "status": .string(status),
                    ])]),
                ]
                if let reason { snapshot["reasonCode"] = .string(reason) }
                return TokenMonitorResponse(
                    schemaVersion: 1, requestId: "synthetic", operation: .collectLimits,
                    engine: .init(repository: "synthetic", commit: "synthetic", version: "synthetic"),
                    collectedAt: ISO8601DateFormatter().string(from: Date()), timezone: "UTC", status: .partial,
                    sources: [.init(id: selected.id, providerId: "opencode", status: .unavailable,
                                    coverage: .unknown, reasonCode: nil)],
                    payload: .object(["limits": .object(["targets": .array([.object([
                        "sourceId": .string(selected.id), "providerId": .string("opencode"),
                        "accountId": .string(selected.id), "snapshot": .object(snapshot),
                    ])])])]),
                    coverage: .init(entries: [], days: [], cost: .unknown), errors: [])
            }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let unauthorized = try TokenMonitorLocalCLIQuotaReader.map(
                upstreamResponse(status: "unauthorized"), sourceID: selected.id, accountID: selected.id, now: now)
            let upstreamTransport = MockTransport(status: 401, data: Data())
            let upstream = await LocalCLIQuotaReader(
                transport: upstreamTransport, upstreamReader: { _, _ in unauthorized })
                .load(profile: selected, now: now)
            try expect(upstream.state == .unavailable && upstream.messageCode == "local_cli_authorization_unverified",
                       "upstream OpenCode 401 is unverified quota access")
            try expect(upstreamTransport.request == nil, "accepted upstream 401 does not call native fallback")
            let native = await LocalCLIQuotaReader(transport: MockTransport(status: 401, data: Data()))
                .load(profile: selected, now: now)
            try expect(native.state == .unavailable && native.messageCode == upstream.messageCode,
                       "upstream and native OpenCode 401 agree")
            let noGoPlan = try TokenMonitorLocalCLIQuotaReader.map(
                upstreamResponse(status: "notConfigured", reason: "unsupported_go_plan"),
                sourceID: selected.id, accountID: selected.id, now: now)
            try expect(noGoPlan.state == .unsupported, "confirmed absence of Go subscription remains unsupported")
            let forbidden = await LocalCLIQuotaReader(transport: MockTransport(status: 403, data: Data()))
                .load(profile: selected, now: now)
            try expect(forbidden.state == .unavailable, "generic OpenCode 403 does not imply sign-out")
        }
    }

    private static func testHTTPStatesAndResponseBound() async throws {
        try await withDirectory { directory in
            try data(#"{"https://auth.x.ai::synthetic":{"key":"synthetic-token","user_id":"synthetic-user","expires_at":"2030-01-01T00:00:00Z"}}"#)
                .write(to: directory.appendingPathComponent("auth.json"))
            let unauthorized = await LocalCLIQuotaReader(
                transport: MockTransport(status: 401, data: Data())).load(profile: profile(.grok, directory))
            try expect(unauthorized.state == .unavailable, "generic 401 does not prove permanent sign-out")
            try expect(unauthorized.messageCode == "local_cli_authorization_unverified", "401 remains a verification failure")
            let limited = await LocalCLIQuotaReader(
                transport: MockTransport(status: 429, data: Data())).load(profile: profile(.grok, directory))
            try expect(limited.state == .rateLimited, "429 mapping")
            let oversized = await LocalCLIQuotaReader(
                transport: MockTransport(data: Data(repeating: 0x20, count: 1_048_577)))
                .load(profile: profile(.grok, directory))
            try expect(oversized.state == .unavailable, "injected oversized response mapping")
            try expect(oversized.messageCode == "local_cli_invalid_response", "oversized fixed message")
        }
    }

    private static func testUnsupportedKindsRemainUnknown() async throws {
        let directory = URL(fileURLWithPath: "/synthetic/isolated", isDirectory: true)
        let transport = MockTransport(data: Data())
        for kind in [LocalCLIKind.trae, .workBuddy] {
            let value = await LocalCLIQuotaReader(transport: transport).load(
                profile: profile(kind, directory))
            try expect(value.state == .unsupported, "\(kind.rawValue) quota remains unsupported")
            try expect(value.state != .available, "\(kind.rawValue) unknown state is not success")
        }
    }

    private static func profile(_ kind: LocalCLIKind, _ directory: URL) -> LocalCLIProfile {
        LocalCLIProfile(
            id: "synthetic-\(kind.rawValue)",
            kind: kind,
            displayName: "Synthetic",
            configDirectory: directory.path,
            isDefault: false)
    }

    private static func data(_ value: String) -> Data { Data(value.utf8) }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FixtureFailure.assertion(message) }
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw FixtureFailure.assertion("expected rejection: \(message)")
        } catch is FixtureFailure {
            throw FixtureFailure.assertion("expected rejection: \(message)")
        } catch {}
    }

    private static func withDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-cli-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    private static func withDirectory(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-cli-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}
