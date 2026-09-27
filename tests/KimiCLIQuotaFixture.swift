import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Compiles the real bounded file reader without the app's localization layer.
struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ chinese: String, _ english: String) -> String { english }
}

private final class KimiMockTransport: LocalCLIQuotaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responseValue: LocalCLIHTTPResponse
    private var captured: [URLRequest] = []

    init(status: Int = 200, body: String = #"{"usage":{"limit":"100","remaining":"75"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"80","remaining":"60"}}]}"#) {
        responseValue = LocalCLIHTTPResponse(statusCode: status, headers: [:], data: Data(body.utf8))
    }

    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        lock.lock()
        captured.append(request)
        lock.unlock()
        return responseValue
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

private enum KimiFixtureFailure: Error { case assertion(String) }

@main
struct KimiCLIQuotaFixture {
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "synthetic-kimi-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("credentials", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("synthetic-device".utf8).write(to: directory.appendingPathComponent("device_id"))
        let profile = LocalCLIProfile(
            id: "synthetic-kimi", kind: .kimi, displayName: "synthetic",
            configDirectory: directory.path, isDefault: false)

        // Real Kimi credentials carry the stable account ID in the JWT payload.
        let payload = Data(#"{"user_id":"kimi-synthetic-id"}"#.utf8)
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "synthetic.\(encoded).synthetic"
        func saveCredentials(expiry: Int, refreshToken: String?) throws {
            var credentials: [String: Any] = ["access_token": token, "expires_at": expiry]
            if let refreshToken { credentials["refresh_token"] = refreshToken }
            let data = try JSONSerialization.data(withJSONObject: credentials)
            try data.write(to: directory.appendingPathComponent("credentials/kimi-code.json"))
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw KimiFixtureFailure.assertion(message) }
        }

        // A token with 30 seconds left is still usable for a read-only quota GET.
        try saveCredentials(expiry: 1_800_000_030, refreshToken: "synthetic-refresh")
        let freshTransport = KimiMockTransport()
        let fresh = await LocalCLIQuotaReader(transport: freshTransport).load(profile: profile, now: now)
        try expect(fresh.state == .available, "near-expiry token was rejected")
        try expect(Set(fresh.windows.map(\.id)) == ["weekly", "session"], "canonical Kimi windows")
        try expect(fresh.identityFingerprint != nil, "JWT identity was not recovered")
        try expect(freshTransport.requests.count == 1, "expected one quota read")
        try expect(freshTransport.requests.first?.url?.absoluteString == "https://api.kimi.com/coding/v1/usages", "official Kimi endpoint")

        // The reader cannot refresh OAuth itself. A saved refresh token means
        // this is temporarily unavailable, not proof that sign-in was lost.
        try saveCredentials(expiry: 1_799_999_999, refreshToken: "synthetic-refresh")
        let expiredTransport = KimiMockTransport()
        let expired = await LocalCLIQuotaReader(transport: expiredTransport).load(profile: profile, now: now)
        try expect(expired.state == .unavailable, "refreshable expiry must not request sign-in")
        try expect(expired.messageCode == "local_cli_kimi_token_refresh_required", "refreshable expiry reason")
        try expect(expiredTransport.requests.isEmpty, "expired token must not be sent")

        try saveCredentials(expiry: 1_799_999_999, refreshToken: nil)
        let noRefresh = await LocalCLIQuotaReader(transport: KimiMockTransport()).load(profile: profile, now: now)
        try expect(noRefresh.state == .needsLogin, "expiry without refresh credential needs sign-in")

        try saveCredentials(expiry: 1_800_000_300, refreshToken: "synthetic-refresh")
        let unauthorized = await LocalCLIQuotaReader(transport: KimiMockTransport(status: 401)).load(profile: profile, now: now)
        try expect(unauthorized.state == .unavailable && unauthorized.messageCode == "local_cli_authorization_unverified", "401 is unverified, not sign-out")
        let limited = await LocalCLIQuotaReader(transport: KimiMockTransport(status: 429)).load(profile: profile, now: now)
        try expect(limited.state == .rateLimited, "429 remains rate limited")
        print("PASS kimi-cli-quota fixture")
    }
}
