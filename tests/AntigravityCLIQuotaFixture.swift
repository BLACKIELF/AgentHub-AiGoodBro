import Foundation

// Standalone compilation seam: production process/network adapters are never
// invoked by these synthetic tests.
struct LocalCLIHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}
protocol LocalCLIQuotaTransport: Sendable {
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse
}
enum BoundedLocalProcess {
    static func run(
        executable: URL, arguments: [String], maximumOutputBytes: Int = 1_048_576,
        timeout: TimeInterval = 5, allowedExitCodes: Set<Int32> = [0]
    ) throws -> Data { fatalError("fixture must not run a real process") }
}
private enum Failure: Error { case test(String), noResponse }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.test(message) }
}
private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
private actor Transport: LocalCLIQuotaTransport {
    var responses: [Data]
    var requests: [URLRequest] = []
    init(_ responses: [Data]) { self.responses = responses }
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw Failure.noResponse }
        return LocalCLIHTTPResponse(statusCode: 200, headers: [:], data: responses.removeFirst())
    }
}
private final class CacheReads {
    var count = 0
}
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let endpoint = AntigravityCLIQuotaReader.Endpoint(
    pid: 991, birthSeconds: 100, executable: "/synthetic/Antigravity.app/Contents/language_server",
    port: 54123, csrf: "synthetic-csrf")
private func profile(defaultEnvironment: Bool = true) -> LocalCLIProfile {
    LocalCLIProfile(
        id: defaultEnvironment ? "local-antigravity" : "synthetic-linked",
        kind: .antigravity, displayName: "Synthetic Antigravity",
        configDirectory: defaultEnvironment
            ? LocalCLIKind.antigravity.defaultConfigDirectory(home: FileManager.default.homeDirectoryForCurrentUser).path
            : "/synthetic/linked-antigravity", isDefault: defaultEnvironment)
}
private func status(_ identity: String = "fixture@example.invalid", includeQuota: Bool = false) throws -> Data {
    var value: [String: Any] = ["email": identity, "userTier": ["name": "AI Pro"]]
    if includeQuota {
        value["cascadeModelConfigData"] = ["clientModelConfigs": [[
            "label": "Gemini Pro", "quotaInfo": ["remainingFraction": 0.65, "resetTime": "2030-01-02T03:04:05Z"],
        ]]]
    }
    return try json(["userStatus": value])
}
private func summary() throws -> Data {
    try json(["response": ["groups": [[
        "displayName": "Gemini Models", "buckets": [
            ["bucketId": "five-hour", "displayName": "5-hour", "remainingFraction": 0.72, "resetTime": "2030-01-02T03:04:05.123Z"],
            ["bucketId": "weekly", "displayName": "Weekly", "remaining": ["case": "remainingFraction", "value": 0.31]],
            ["bucketId": "missing", "displayName": "Unknown"],
            ["bucketId": "disabled", "displayName": "Disabled", "remainingFraction": 0.0, "disabled": true],
        ],
    ]]]])
}

private func liveSummary() async throws {
    let transport = Transport([try status(), try summary(), try status()])
    let reader = AntigravityCLIQuotaReader(transport: transport, endpoints: { [endpoint] }, verifier: { _ in true }, cacheReader: { _ in nil })
    let result = await reader.load(profile: profile(), now: now)
    try expect(result.state == .available, "live grouped quota available")
    try expect(result.windows.count == 2, "unknown and disabled buckets excluded")
    try expect(abs(result.windows[0].usedPercent - 28) < 0.001, "remaining fraction converted to used once")
    try expect(result.windows[1].usedPercent == 69, "oneof remaining parsed")
    try expect(result.windows[0].resetsAt != nil && result.windows[1].resetsAt == nil, "missing reset remains unknown")
    try expect(result.maskedIdentity == "f***@example.invalid", "identity masked")
    try expect(result.identityFingerprint?.count == 64, "stable fingerprint")
    try expect(result.planLabel == "AI Pro" && result.balance == nil, "no fictional balance")
    let requests = await transport.requests
    try expect(requests.count == 3, "identity verified both sides of summary")
    try expect(requests.allSatisfy { $0.url?.host == "127.0.0.1" && $0.url?.scheme == "https" && $0.url?.port == 54123 }, "fixed loopback only")
    try expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == "synthetic-csrf" }, "token scoped to verified endpoint")
}

private func identityAndIsolation() async throws {
    let switched = Transport([try status(), try summary(), try status("other@example.invalid")])
    let changed = await AntigravityCLIQuotaReader(transport: switched, endpoints: { [endpoint] }, verifier: { _ in true }, cacheReader: { _ in nil })
        .load(profile: profile(), now: now)
    try expect(changed.state == .unavailable && changed.windows.isEmpty, "account switch must discard quota")
    try expect(changed.messageCode == "local_cli_antigravity_account_changed", "switch diagnosed")

    let rejected = Transport([])
    let denied = await AntigravityCLIQuotaReader(transport: rejected, endpoints: { [endpoint] }, verifier: { _ in false }, cacheReader: { _ in nil })
        .load(profile: profile(), now: now)
    let deniedRequests = await rejected.requests
    try expect(deniedRequests.isEmpty && denied.state == .unavailable, "unverified process receives no request")

    let isolated = await AntigravityCLIQuotaReader(transport: rejected, endpoints: { fatalError("linked account cannot probe ambient server") }, verifier: { _ in false }, cacheReader: { root in
        try expect(root.path == "/synthetic/linked-antigravity", "only selected linked path is read")
        return nil
    }).load(profile: profile(defaultEnvironment: false), now: now)
    try expect(isolated.messageCode == "local_cli_antigravity_linked_cache_only", "linked profile remains read-only and isolated")

    let failingLive = Transport([try status("account-a@example.invalid")])
    let cacheReads = CacheReads()
    let cachedModelB = field(1, Data("Gemini Pro".utf8)) + field(15, fractionField(0.5))
    let cacheB = try json([
        "email": "account-b@example.invalid",
        "userStatusProtoBinaryBase64": (field(7, Data("account-b@example.invalid".utf8)) + field(33, field(1, cachedModelB))).base64EncodedString(),
    ])
    let failed = await AntigravityCLIQuotaReader(
        transport: failingLive, endpoints: { [endpoint] }, verifier: { _ in true },
        cacheReader: { _ in
            cacheReads.count += 1
            return .init(data: cacheB, modifiedAt: now)
        }).load(profile: profile(), now: now)
    try expect(cacheReads.count == 0, "failed live account A must not read account B cache")
    try expect(failed.messageCode == "local_cli_antigravity_live_unavailable", "live failure has specific diagnosis")
    try expect(failed.windows.isEmpty && failed.identityFingerprint == nil, "live failure carries no unbound historical identity or quota")
    let inspectionFailed = await AntigravityCLIQuotaReader(
        transport: failingLive, endpoints: { throw Failure.test("synthetic process inspection failure") }, verifier: { _ in false },
        cacheReader: { _ in cacheReads.count += 1; return .init(data: cacheB, modifiedAt: now) }
    ).load(profile: profile(), now: now)
    try expect(cacheReads.count == 0 && inspectionFailed.windows.isEmpty, "failed process inspection does not establish the absence of a live account")
}

private func parserBoundaries() throws {
    let bytes = try json(["groups": [["name": "Models", "buckets": [
        ["id": "zero", "name": "Empty", "remainingFraction": 0.0],
        ["id": "full", "name": "Full", "remaining": ["remainingFraction": 1.0]],
        ["id": "negative", "name": "Bad", "remainingFraction": -0.2],
        ["id": "high", "name": "Bad", "remainingFraction": 2.0],
        ["id": "bool", "name": "Bad", "remainingFraction": true],
        ["id": "past", "name": "Old", "remainingFraction": 0.3, "resetTime": "2020-01-01T00:00:00Z"],
    ]]]])
    let windows = try AntigravityCLIQuotaReader.parseSummary(bytes, now: now)
    try expect(windows.map(\.usedPercent) == [100, 0], "invalid values are not clamped or invented; explicit zero survives")
    try expect(AntigravityCLIQuotaReader.csrfArgument("/synthetic --csrf_token=abc-123 --other") == "abc-123", "equal flag")
    try expect(AntigravityCLIQuotaReader.csrfArgument("--csrf_token abc_123") == "abc_123", "separate flag")
    try expect(AntigravityCLIQuotaReader.csrfArgument("--csrf_token abc;evil") == nil, "control syntax rejected")
    try expect(AntigravityCLIQuotaReader.csrfArgument("--different_csrf_token abc") == nil, "exact flag")
}

private func varint(_ input: UInt64) -> Data {
    var value = input, bytes = Data()
    repeat {
        let byte = UInt8(value & 0x7f); value >>= 7
        bytes.append(byte | (value > 0 ? 0x80 : 0))
    } while value > 0
    return bytes
}
private func field(_ number: Int, _ data: Data) -> Data {
    var output = varint(UInt64(number * 8 + 2)); output.append(varint(UInt64(data.count))); output.append(data)
    return output
}
private func fractionField(_ value: Float) -> Data {
    var output = Data([13]); let bits = value.bitPattern
    for index in 0..<4 { output.append(UInt8(truncatingIfNeeded: bits >> (index * 8))) }
    return output
}
private func cacheTest() throws {
    let expiry = varint(8) + varint(1_893_553_200)
    let quota = fractionField(0.75) + field(2, expiry)
    let model = field(1, Data("Gemini Pro".utf8)) + field(15, quota)
    let missing = field(1, Data("No Quota".utf8))
    let payload = field(7, Data("fixture@example.invalid".utf8)) + field(33, field(1, model) + field(1, missing))
    let data = try json(["email": "fixture@example.invalid", "userStatusProtoBinaryBase64": payload.base64EncodedString()])
    let saved = now.addingTimeInterval(-3_600)
    let result = try AntigravityCLIQuotaReader.parseCache(.init(data: data, modifiedAt: saved), now: now)
    try expect(result.windows.count == 1 && result.windows[0].usedPercent == 25, "protobuf model remaining decoded")
    try expect(result.state == .unavailable, "cache cannot prove fresh quota or login")
    try expect(result.fetchedAt == saved, "cache timestamp not relabelled as refresh time")
    try expect(result.sourceLabel.contains("cached") && result.messageCode == "local_cli_antigravity_cached_quota", "cache provenance explicit")
    let wrongIdentity = try json(["email": "other@example.invalid", "userStatusProtoBinaryBase64": payload.base64EncodedString()])
    do {
        _ = try AntigravityCLIQuotaReader.parseCache(.init(data: wrongIdentity, modifiedAt: saved), now: now)
        throw Failure.test("mismatched cache identity accepted")
    } catch Failure.test(let message) { throw Failure.test(message) } catch {}
    let truncated = try json(["userStatusProtoBinaryBase64": Data([0x8a, 0xff]).base64EncodedString()])
    do {
        _ = try AntigravityCLIQuotaReader.parseCache(.init(data: truncated, modifiedAt: saved), now: now)
        throw Failure.test("malformed protobuf accepted")
    } catch Failure.test(let message) { throw Failure.test(message) } catch {}
    let anonymousPayload = field(33, field(1, model))
    let anonymous = try json(["userStatusProtoBinaryBase64": anonymousPayload.base64EncodedString()])
    do {
        _ = try AntigravityCLIQuotaReader.parseCache(.init(data: anonymous, modifiedAt: saved), now: now)
        throw Failure.test("anonymous cached quota accepted")
    } catch Failure.test(let message) { throw Failure.test(message) } catch {}
}

@main private enum Fixture {
    static func main() async throws {
        try await liveSummary()
        try await identityAndIsolation()
        try parserBoundaries()
        try cacheTest()
        print("antigravity-cli-quota-fixture: ok")
    }
}
