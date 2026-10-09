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
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw KimiFixtureFailure.assertion(message) }
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

        let monthlyCode = await LocalCLIQuotaReader(transport: KimiMockTransport(body:
            #"{"usages":{"limit_month_total":{"used_ratio":0.25},"limit_month_code":{"used_ratio":0,"reset_time":"2026-10-31T16:00:00Z"}},"limits":null}"#
        )).load(profile: profile, now: now)
        try expect(monthlyCode.state == .available, "monthly code pool is usable quota evidence")
        try expect(monthlyCode.windows.map(\.id) == ["monthly", "monthly-code"], "monthly code is independent of total")
        try expect(monthlyCode.windows.map(\.usedPercent) == [25, 0], "monthly code actual zero is preserved")
        try expect(monthlyCode.windows[1].resetsAt != nil, "monthly code reset is preserved")
        let codeOnly = try LocalCLIQuotaReader.parseKimi(Data(
            #"{"usages":{"limit_month_code":{"used_ratio":0.5}}}"#.utf8))
        try expect(codeOnly.windows.count == 1 && codeOnly.windows[0].usedPercent == 50, "code-only pool accepted")
        let stringRatio = try LocalCLIQuotaReader.parseKimi(Data(
            #"{"usages":{"limit_month_code":{"used_ratio":"0.125"}}}"#.utf8))
        try expect(stringRatio.windows[0].usedPercent == 12.5, "official numeric-string ratio is accepted")
        let contradictory = await LocalCLIQuotaReader(transport: KimiMockTransport(body:
            #"{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"100","resetTime":"2026-10-06T13:23:46.915474Z"}}],"usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-10-06T13:23:46Z"},"limit_month_total":{"used_ratio":0.5531,"reset_time":"2026-10-22T14:26:29Z"},"limit_month_code":{"used_ratio":0,"reset_time":"2026-10-22T14:26:29Z"}}}"#
        )).load(profile: profile, now: now)
        try expect(contradictory.state == .available, "contradictory matching Kimi windows remain readable")
        try expect(contradictory.windows.map(\.id) == ["session", "monthly", "monthly-code"], "actual returned monthly pools remain independent and no weekly pool is invented")
        try expect(contradictory.windows[0].usedPercent == 100, "matching exhausted legacy session wins over zero ratio")
        try expect(abs(contradictory.windows[1].usedPercent - 55.31) < 0.000001, "actual monthly total retained")
        let counterResetFormatter = ISO8601DateFormatter()
        counterResetFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try expect(contradictory.windows[0].resetsAt == counterResetFormatter.date(from: "2026-10-06T13:23:46.915474Z"), "selected counter keeps its actual reset")

        func sessionPercent(ratio: Double, used: String = "90", reset: String?, duration: Int = 300) throws -> Double {
            var detail: [String: Any] = ["limit": "100", "used": used]
            if let reset { detail["resetTime"] = reset }
            let payload: [String: Any] = [
                "usages": ["limit_5h": ["used_ratio": ratio, "reset_time": "2026-10-06T13:23:46Z"]],
                "limits": [["window": ["duration": duration, "timeUnit": "TIME_UNIT_MINUTE"], "detail": detail]],
            ]
            return try LocalCLIQuotaReader.parseKimi(JSONSerialization.data(withJSONObject: payload)).windows.first { $0.id == "session" }!.usedPercent
        }
        try expect(try sessionPercent(ratio: 0.1, reset: "2026-10-06T13:23:48Z") == 90, "two-second reset drift is the same period")
        try expect(try sessionPercent(ratio: 0.1, reset: "2026-10-06T13:23:48.001Z") == 10, "greater reset drift keeps the ratio period")
        try expect(try sessionPercent(ratio: 0.1, reset: nil) == 10, "unknown counter period cannot replace ratio evidence")
        try expect(try sessionPercent(ratio: 0.95, reset: "2026-10-06T13:23:46Z") == 95, "higher ratio reading wins")
        try expect(try sessionPercent(ratio: 0.1, used: "invalid", reset: "2026-10-06T13:23:46Z") == 10, "invalid counter cannot erase a valid ratio")
        try expect(try sessionPercent(ratio: 0, used: "130", reset: "2026-10-06T13:23:46Z") == 100, "authoritative overage remains exhausted when the ratio says zero")
        try expect(try sessionPercent(ratio: 0.1, reset: "2026-10-06T13:23:46Z", duration: 60) == 10, "different window duration cannot replace session")
        let weeklyConflict = try LocalCLIQuotaReader.parseKimi(Data(
            #"{"usages":{"limit_7d":{"used_ratio":0.1,"reset_time":"2026-10-08T00:00:00Z"}},"usage":{"limit":"100","remaining":"25","resetTime":"2026-10-08T00:00:01Z"}}"#.utf8))
        try expect(weeklyConflict.windows.count == 1 && weeklyConflict.windows[0].usedPercent == 75, "weekly remaining counters reconcile the same reset period")
        let remainingFallback = try LocalCLIQuotaReader.parseKimi(Data(
            #"{"usages":{"limit_7d":{"used_ratio":0.1,"reset_time":"2026-10-08T00:00:00Z"}},"usage":{"limit":100,"used":"invalid","remaining":30,"resetTime":"2026-10-08T00:00:01Z"}}"#.utf8))
        try expect(remainingFallback.windows[0].usedPercent == 70, "a valid remaining counter survives an unusable used counter")
        let multipleCounters = try LocalCLIQuotaReader.parseKimi(Data(
            #"{"usages":{"limit_7d":{"used_ratio":0.1,"reset_time":"2026-10-08T00:00:00Z"}},"usage":{"limit":100,"used":75,"resetTime":"2026-10-08T00:00:02Z"},"limits":[{"window":{"duration":10080,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"used":95,"resetTime":"2026-10-07T23:59:58Z"}}]}"#.utf8))
        try expect(multipleCounters.windows.count == 1 && multipleCounters.windows[0].usedPercent == 95, "all comparisons use the original ratio period after one counter wins")
        for body in [
            #"{"usage":null}"#, #"{"limits":null}"#, #"{"limits":[]}"#,
            #"{"usages":{},"limits":[]}"#,
            #"{"usages":{"limit_month_code":{"reset_time":"2026-10-31T16:00:00Z"}},"usage":null}"#,
            #"{"usages":{"limit_month_code":{"used_ratio":true}}}"#,
            #"{"usages":{"limit_month_code":{"used_ratio":""}}}"#,
            #"{"usages":{"limit_month_code":{"used_ratio":"nan"}}}"#,
            #"{"usages":{"limit_month_code":{"used_ratio":"-0.1"}}}"#,
        ] {
            let empty = await LocalCLIQuotaReader(transport: KimiMockTransport(body: body))
                .load(profile: profile, now: now)
            try expect(empty.state == .unavailable && empty.windows.isEmpty, "empty or invalid quota is unavailable")
        }

        // The reader cannot refresh OAuth itself. A saved refresh token means
        // this is temporarily unavailable, not proof that sign-in was lost.
        try saveCredentials(expiry: 1_799_999_999, refreshToken: "synthetic-refresh")
        let expiredTransport = KimiMockTransport()
        let expired = await LocalCLIQuotaReader(transport: expiredTransport).load(profile: profile, now: now)
        try expect(expired.state == .unavailable, "refreshable expiry must not request sign-in")
        try expect(expired.messageCode == "local_cli_kimi_token_refresh_required", "refreshable expiry reason")
        try expect(expiredTransport.requests.isEmpty, "expired token must not be sent")

        try Data(#"{"refresh_token":"synthetic-refresh","expires_at":1799999999}"#.utf8)
            .write(to: directory.appendingPathComponent("credentials/kimi-code.json"))
        let refreshOnlyTransport = KimiMockTransport()
        let refreshOnly = await LocalCLIQuotaReader(transport: refreshOnlyTransport).load(profile: profile, now: now)
        try expect(refreshOnly.state == .unavailable, "refresh-only credentials must not request sign-in")
        try expect(refreshOnly.messageCode == "local_cli_kimi_token_refresh_required", "refresh-only reason")
        try expect(refreshOnlyTransport.requests.isEmpty, "refresh-only credentials must not send a quota request")

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
