import Foundation
import Darwin

struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ chinese: String, _ english: String) -> String { english }
}

private final class GrokMockTransport: LocalCLIQuotaTransport, @unchecked Sendable {
    let reply: LocalCLIHTTPResponse
    private(set) var requests: [URLRequest] = []
    init(status: Int = 200, body: String = #"{"config":{"creditUsagePercent":7,"prepaidBalance":{}}}"#) {
        reply = LocalCLIHTTPResponse(statusCode: status, headers: [:], data: Data(body.utf8))
    }
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        requests.append(request)
        return reply
    }
}

private enum ContractFailure: Error { case assertion }

@main
struct GrokCLIQuotaContractFixture {
    static let now = Date(timeIntervalSince1970: 1_790_985_600) // fixed synthetic clock
    static let scope = "https://auth.x.ai::synthetic-client"
    static let profile = LocalCLIProfile(
        id: "synthetic-grok", kind: .grok, displayName: "Synthetic",
        configDirectory: "/synthetic/grok", isDefault: false)
    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func expect(_ value: Bool) throws { if !value { throw ContractFailure.assertion } }
    static func entry() -> [String: Any] {
        ["key": "synthetic-access", "user_id": "synthetic-user",
         "oidc_issuer": "https://auth.x.ai", "oidc_client_id": "synthetic-client",
         "refresh_token": "synthetic-refresh", "create_time": stamp(now.addingTimeInterval(-60)),
         "auth_mode": "oidc"]
    }
    private static func load(_ entry: [String: Any], transport: GrokMockTransport = GrokMockTransport()) async throws -> (LocalCLIQuotaResult, GrokMockTransport) {
        let bytes = try json([scope: entry])
        let result = await LocalCLIQuotaReader(transport: transport, fileReader: { _, _, _ in bytes })
            .load(profile: profile, now: now)
        return (result, transport)
    }
    static func renew(_ reply: [String: Any]) throws -> [String: Any] {
        var original = entry()
        original["create_time"] = stamp(now.addingTimeInterval(-40 * 86400))
        original["expires_at"] = stamp(now.addingTimeInterval(-100))
        original["principal_type"] = "Team"
        original["principal_id"] = "synthetic-team"
        original["unknown_field"] = ["retained": true]
        let updated = try LocalCLIQuotaRefresh.renewedGrokCredential(
            json([scope: original, "synthetic-unrelated": ["keep": true]]), sessionKey: scope,
            response: json(reply), now: now)
        let root = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        try expect(root["synthetic-unrelated"] != nil)
        let saved = root[scope] as! [String: Any]
        try expect(saved["user_id"] as? String == "synthetic-user")
        try expect(saved["principal_id"] as? String == "synthetic-team")
        try expect(saved["unknown_field"] != nil)
        return saved
    }
    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw ContractFailure.assertion
    }
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("fallback-fresh-and-required-headers", {
                let (result, transport) = try await load(entry())
                try expect(result.state == .available && result.windows.first?.usedPercent == 7)
                let request = transport.requests.first
                try expect(request?.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
                try expect(request?.value(forHTTPHeaderField: "x-userid") == "synthetic-user")
                try expect(request?.value(forHTTPHeaderField: "x-grok-client-mode") == "cli")
                try expect(request?.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
                try expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            }),
            ("fallback-expired-at-exact-30-days", {
                var value = entry(); value["create_time"] = stamp(now.addingTimeInterval(-30 * 86400))
                let (result, transport) = try await load(value)
                try expect(result.state == .needsLogin && transport.requests.isEmpty)
            }),
            ("fallback-one-second-before-expiry", {
                var value = entry(); value["create_time"] = stamp(now.addingTimeInterval(-30 * 86400 + 1))
                let (result, transport) = try await load(value)
                try expect(result.state == .available && transport.requests.count == 1)
            }),
            ("null-expiry-uses-creation-time", {
                var value = entry(); value["expires_at"] = NSNull()
                let (result, _) = try await load(value)
                try expect(result.state == .available)
            }),
            ("unknown-lifetime-does-not-request", {
                var value = entry(); value.removeValue(forKey: "create_time")
                let (result, transport) = try await load(value)
                try expect(result.state == .needsLogin && transport.requests.isEmpty)
            }),
            ("explicit-expiry-precedes-old-creation-time", {
                var value = entry(); value["create_time"] = stamp(now.addingTimeInterval(-40 * 86400))
                value["expires_at"] = stamp(now.addingTimeInterval(60))
                let (result, _) = try await load(value)
                try expect(result.state == .available)
            }),
            ("malformed-or-expired-expiry-never-uses-fallback", {
                for expiry in ["not-a-date", true, stamp(now)] as [Any] {
                    var value = entry(); value["expires_at"] = expiry
                    let (result, transport) = try await load(value)
                    try expect(result.state == .needsLogin && transport.requests.isEmpty)
                }
            }),
            ("missing-user-id-does-not-use-email", {
                var value = entry(); value.removeValue(forKey: "user_id"); value["email"] = "synthetic@example.invalid"
                let (result, transport) = try await load(value)
                try expect(result.state == .unavailable && transport.requests.isEmpty)
            }),
            ("identity-header-must-not-be-sanitized", {
                for identity in ["synthetic\nuser", "synthetic用户"] {
                    var value = entry(); value["user_id"] = identity
                    let (result, transport) = try await load(value)
                    try expect(result.state == .unavailable && transport.requests.isEmpty)
                }
            }),
            ("api-key-scope-never-falls-back", {
                let transport = GrokMockTransport(); let bytes = try json(["xai::api_key": entry()])
                let result = await LocalCLIQuotaReader(transport: transport, fileReader: { _, _, _ in bytes })
                    .load(profile: profile, now: now)
                try expect(result.state == .unavailable && transport.requests.isEmpty)
            }),
            ("multiple-oauth-identities-stay-ambiguous", {
                let transport = GrokMockTransport(); let bytes = try json([scope: entry(), "https://auth.x.ai::synthetic-other": entry()])
                let result = await LocalCLIQuotaReader(transport: transport, fileReader: { _, _, _ in bytes })
                    .load(profile: profile, now: now)
                try expect(result.state == .unavailable && transport.requests.isEmpty)
            }),
            ("refresh-updates-issuance-and-preserves-identity", {
                let saved = try renew(["access_token": "synthetic-renewed", "expires_in": 3600,
                                       "id_token": "synthetic-ignored-id-token"])
                try expect(saved["create_time"] as? String == stamp(now))
                try expect(saved["expires_at"] as? String == stamp(now.addingTimeInterval(3600)))
                try expect(saved["refresh_token"] as? String == "synthetic-refresh")
            }),
            ("refresh-with-null-rotation-keeps-old-token", {
                let saved = try renew(["access_token": "synthetic-renewed", "expires_in": 3600, "refresh_token": NSNull()])
                try expect(saved["refresh_token"] as? String == "synthetic-refresh")
            }),
            ("refresh-without-expiry-removes-stale-expiry", {
                let saved = try renew(["access_token": "synthetic-renewed"])
                try expect(saved["expires_at"] == nil && saved["create_time"] as? String == stamp(now))
                let (result, _) = try await load(saved)
                try expect(result.state == .available)
            }),
            ("refresh-null-expiry-and-rotated-token", {
                let saved = try renew(["access_token": "synthetic-renewed", "expires_in": NSNull(), "refresh_token": "synthetic-rotated"])
                try expect(saved["expires_at"] == nil && saved["refresh_token"] as? String == "synthetic-rotated")
            }),
            ("malformed-refresh-is-rejected", {
                for value in [true, -1, 0, 1.5, "garbage"] as [Any] {
                    try rejects { _ = try renew(["access_token": "synthetic-renewed", "expires_in": value]) }
                }
                try rejects { _ = try renew(["access_token": "synthetic-renewed", "expires_in": 3600, "token_type": "Basic"]) }
            }),
            ("refresh-request-fixed-origin-and-principal", {
                var value = entry(); value["principal_type"] = "Team"; value["principal_id"] = "synthetic&team"
                let request = try LocalCLIQuotaRefresh.grokRefreshRequest(value, sessionKey: scope)
                try expect(request.url?.absoluteString == "https://auth.x.ai/oauth2/token")
                try expect(String(decoding: request.httpBody!, as: UTF8.self).contains("principal_id=synthetic%26team"))
                value["oidc_issuer"] = "https://synthetic.invalid"
                try rejects { _ = try LocalCLIQuotaRefresh.grokRefreshRequest(value, sessionKey: scope) }
            }),
            ("absent-percentage-zero-balance-remains-unknown-usage", {
                let parsed = try LocalCLIQuotaReader.parseGrok(json(["config": [
                    "prepaidBalance": [:], "onDemandCap": ["val": 100], "onDemandUsed": ["val": 30],
                    "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-11-01T00:00:00Z"]]]))
                try expect(parsed.windows.isEmpty && parsed.balanceUSD == 0 && parsed.periodResetsAt != nil && parsed.resetCards == nil)
                let unknown = try LocalCLIQuotaReader.parseGrok(json(["config": [:]]))
                try expect(unknown.balanceUSD == nil && unknown.windows.isEmpty)
            }),
            ("explicit-zero-and-exhaustion-stay-distinct", {
                for percent in [0, 100] {
                    let parsed = try LocalCLIQuotaReader.parseGrok(json(["config": ["creditUsagePercent": percent]]))
                    try expect(parsed.windows.first?.usedPercent == Double(percent))
                }
            }),
            ("http-errors-are-not-subscription-exhaustion", {
                for (status, expected) in [(401, LocalCLIQuotaState.unavailable), (429, .rateLimited)] {
                    let (result, transport) = try await load(entry(), transport: GrokMockTransport(status: status, body: "{}"))
                    try expect(result.state == expected && result.windows.isEmpty && transport.requests.count == 1)
                }
            }),
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                if ProcessInfo.processInfo.environment["GROK_CONTRACT_VERBOSE"] == "1" { print("PASS " + name) }
            }
            catch { failures += 1; print("FAIL " + name) }
        }
        print("GROK CONTRACT: \(tests.count - failures)/\(tests.count) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
