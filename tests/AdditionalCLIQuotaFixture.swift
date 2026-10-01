import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// The production implementation is supplied when this standalone fixture is compiled. The body is
// intentionally unreachable because every test injects a synthetic file reader.
enum DispatchParticipationSync {
    static func readBoundedRegularFile(
        _ url: URL,
        maximumBytes: Int,
        allowMissing: Bool
    ) throws -> Data? {
        fatalError("real filesystem reads are forbidden in AdditionalCLIQuotaFixture")
    }
}

private actor FakeTransport: LocalCLIQuotaTransport {
    private var responses: [LocalCLIHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [LocalCLIHTTPResponse]) {
        self.responses = responses
    }

    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw FixtureError.missingResponse }
        return responses.removeFirst()
    }
}

private final class ReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var names: [String] = []

    func append(_ name: String) {
        lock.lock()
        names.append(name)
        lock.unlock()
    }
}

private enum FixtureError: Error {
    case missingResponse
    case failed(String)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureError.failed(message) }
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func response(_ value: Any, status: Int = 200) throws -> LocalCLIHTTPResponse {
    LocalCLIHTTPResponse(statusCode: status, headers: [:], data: try json(value))
}

private func profile(_ kind: LocalCLIKind) -> LocalCLIProfile {
    LocalCLIProfile(
        id: "synthetic-\(kind.rawValue)",
        kind: kind,
        displayName: kind.displayName,
        configDirectory: "/synthetic/\(kind.rawValue)",
        isDefault: false)
}

private func fixtureReader(
    _ files: [String: Data],
    recorder: ReadRecorder = ReadRecorder()
) -> (LocalCLIQuotaReader.FileReader, ReadRecorder) {
    (
        { url, maximumBytes, allowMissing in
            let name = url.lastPathComponent
            recorder.append(name)
            guard let data = files[name] else {
                if allowMissing { return nil }
                throw FixtureError.failed("missing synthetic file \(name)")
            }
            guard data.count <= maximumBytes else { throw FixtureError.failed("oversize synthetic file") }
            return data
        }, recorder
    )
}

private func geminiFiles(
    selectedType: String = "oauth-personal",
    token: String = "fixture-access-token",
    expiry: Double = 4_102_444_800_000,
    hostedDomain: String? = nil,
    refreshToken: String? = "fixture-refresh-token-must-not-be-used"
) throws -> [String: Data] {
    var claims = ["sub": "acct-fixture-1"]
    claims["hd"] = hostedDomain
    var payload = try json(claims).base64EncodedString()
    payload = payload.replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let idToken = "header.\(payload).signature"
    var credentials: [String: Any] = [
        "access_token": token,
        "id_token": idToken,
        "expiry_date": expiry,
    ]
    credentials["refresh_token"] = refreshToken
    return [
        "settings.json": try json([
            "security": ["auth": ["selectedType": selectedType]]
        ]),
        "oauth_creds.json": try json(credentials),
    ]
}

private func validGeminiStatus() throws -> LocalCLIHTTPResponse {
    try response([
        "cloudaicompanionProject": ["id": "fixture-project"],
        "currentTier": ["id": "standard-tier"],
    ])
}

private func testGeminiValid() async throws {
    let quota = try response([
        "buckets": [
            [
                "modelId": "gemini-2.5-pro",
                "remainingFraction": 0.75,
                "resetTime": "2030-01-02T03:04:05Z",
            ],
            [
                "modelId": "gemini-2.5-pro",
                "remainingFraction": 0.25,
                "resetTime": "2030-01-02T04:04:05Z",
            ],
            ["modelId": "gemini-2.5-flash", "remainingFraction": 1.0],
        ]
    ])
    let transport = FakeTransport([try validGeminiStatus(), quota])
    let (reader, reads) = fixtureReader(try geminiFiles())
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let result = await AdditionalCLIQuotaReader(transport: transport, fileReader: reader)
        .load(profile: profile(.gemini), now: now)

    try expect(result.state == .available, "Gemini valid state")
    try expect(result.planLabel == "Paid", "Gemini tier mapping")
    try expect(result.maskedIdentity == "ac***-1", "Gemini subject masking")
    try expect(result.identityFingerprint?.count == 64, "Gemini stable identity fingerprint")
    try expect(result.windows.count == 2, "Gemini model grouping")
    let pro = result.windows.first { $0.label == "gemini-2.5-pro" }
    try expect(pro?.usedPercent == 75, "Gemini lowest remaining bucket")
    try expect(pro?.resetsAt != nil, "Gemini reset parsing")
    try expect(reads.names == ["settings.json", "oauth_creds.json"], "Gemini bounded selected-profile reads")

    let requests = await transport.requests
    try expect(requests.count == 2, "Gemini request count")
    try expect(requests.allSatisfy { $0.url?.scheme == "https" }, "Gemini HTTPS only")
    try expect(requests.allSatisfy { $0.url?.host == "cloudcode-pa.googleapis.com" }, "Gemini fixed host")
    try expect(
        requests.map { $0.url?.path } == [
            "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuota",
        ], "Gemini fixed paths")
    try expect(
        requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access-token"
        }, "Gemini uses selected access token")
    let loadBody = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any]
    let metadata = loadBody?["metadata"] as? [String: Any]
    try expect(metadata?["ideType"] as? String == "GEMINI_CLI", "Gemini native IDE metadata")
    let quotaBody = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any]
    try expect(quotaBody?["project"] as? String == "fixture-project", "Gemini native project propagation")
}

private func testGeminiAuthIsolation() async throws {
    let transport = FakeTransport([])
    let (reader, reads) = fixtureReader(try geminiFiles(selectedType: "gemini-api-key"))
    let result = await AdditionalCLIQuotaReader(transport: transport, fileReader: reader)
        .load(profile: profile(.gemini))
    try expect(result.state == .unsupported, "Gemini API-key scope rejected")
    try expect(result.messageCode == "local_cli_gemini_oauth_personal_required", "Gemini scope message")
    try expect(reads.names == ["settings.json"], "Gemini does not read OAuth file for other auth scopes")
    let requests = await transport.requests
    try expect(requests.isEmpty, "Gemini does not request for other auth scopes")
}

private func testGeminiExpiredDoesNotRefresh() async throws {
    let transport = FakeTransport([])
    let (reader, reads) = fixtureReader(try geminiFiles(expiry: 1_000))
    let result = await AdditionalCLIQuotaReader(transport: transport, fileReader: reader)
        .load(profile: profile(.gemini), now: Date(timeIntervalSince1970: 2_000))
    try expect(result.state == .unavailable, "Refreshable Gemini access expiry is not sign-out")
    try expect(result.messageCode == "local_cli_gemini_access_refresh_required", "Refresh is delegated to Gemini CLI")
    let requests = await transport.requests
    try expect(requests.isEmpty, "Expired Gemini credential is not refreshed")
    try expect(reads.names == ["settings.json", "oauth_creds.json"], "No credential mutation path")

    let noRefresh = await AdditionalCLIQuotaReader(
        transport: FakeTransport([]),
        fileReader: fixtureReader(try geminiFiles(expiry: 1_000, refreshToken: nil)).0
    ).load(profile: profile(.gemini), now: Date(timeIntervalSince1970: 2_000))
    try expect(noRefresh.state == .needsLogin, "Expired access without refresh credential needs sign-in")

    let missingAccess = await AdditionalCLIQuotaReader(
        transport: FakeTransport([]),
        fileReader: fixtureReader(try geminiFiles(token: "")).0
    ).load(profile: profile(.gemini))
    try expect(missingAccess.state == .unavailable, "Refresh token without access token is not sign-out")
    try expect(missingAccess.messageCode == "local_cli_gemini_access_refresh_required", "Missing access refresh code")
}

private func testGeminiInvalidQuotas() async throws {
    let invalidBuckets: [[String: Any]] = [
        ["modelId": "gemini-pro", "remainingFraction": "0.5"],
        ["modelId": "gemini-pro", "remainingFraction": true],
        ["modelId": "gemini-pro", "remainingFraction": -0.1],
        ["modelId": "gemini-pro", "remainingFraction": 1.1],
        ["modelId": "gemini-pro", "remainingFraction": "NaN"],
        ["modelId": "gemini-pro"],
        ["remainingFraction": 0.5],
        ["modelId": "", "remainingFraction": 0.5],
        ["modelId": "gemini-pro", "remainingFraction": 0.5, "resetTime": "not-a-date"],
        ["modelId": "gemini-pro", "remainingFraction": 0.4, "resetTime": "2020-01-01T00:00:00Z"],
    ]
    for bucket in invalidBuckets {
        let transport = FakeTransport([
            try validGeminiStatus(),
            try response(["buckets": [bucket]]),
        ])
        let result = await AdditionalCLIQuotaReader(
            transport: transport,
            fileReader: fixtureReader(try geminiFiles()).0
        )
        .load(profile: profile(.gemini))
        try expect(result.state == .unavailable, "Invalid Gemini bucket rejected")
        try expect(result.messageCode == "local_cli_invalid_response", "Invalid Gemini response code")
        try expect(result.windows.isEmpty, "Invalid Gemini bucket is not represented as zero")
    }

    let emptyTransport = FakeTransport([try validGeminiStatus(), try response(["buckets": []])])
    let empty = await AdditionalCLIQuotaReader(
        transport: emptyTransport,
        fileReader: fixtureReader(try geminiFiles()).0
    )
    .load(profile: profile(.gemini))
    try expect(empty.state == .unavailable && empty.windows.isEmpty, "Empty Gemini limits rejected")
}

private func testGeminiHTTPStates() async throws {
    let unauthorized = FakeTransport([try response([:], status: 401)])
    let denied = await AdditionalCLIQuotaReader(
        transport: unauthorized,
        fileReader: fixtureReader(try geminiFiles()).0
    )
    .load(profile: profile(.gemini))
    try expect(denied.state == .unavailable, "Gemini remote 401 does not assert local sign-out")
    try expect(denied.messageCode == "local_cli_remote_unauthorized", "Gemini remote 401 reason")

    let forbidden = await AdditionalCLIQuotaReader(
        transport: FakeTransport([try response([:], status: 403)]),
        fileReader: fixtureReader(try geminiFiles()).0
    ).load(profile: profile(.gemini))
    try expect(forbidden.state == .unavailable, "Gemini remote 403 does not assert local sign-out")
    try expect(forbidden.messageCode == "local_cli_remote_forbidden", "Gemini remote 403 reason")

    let limited = FakeTransport([try response([:], status: 429)])
    let rate = await AdditionalCLIQuotaReader(
        transport: limited,
        fileReader: fixtureReader(try geminiFiles()).0
    )
    .load(profile: profile(.gemini))
    try expect(rate.state == .rateLimited, "Gemini rate-limit mapping")

    let failed = FakeTransport([try response([:], status: 500)])
    let unavailable = await AdditionalCLIQuotaReader(
        transport: failed,
        fileReader: fixtureReader(try geminiFiles()).0
    )
    .load(profile: profile(.gemini))
    try expect(unavailable.state == .unavailable, "Gemini other HTTP is unavailable, not login")
    try expect(unavailable.windows.isEmpty, "Gemini HTTP failure does not forge windows")
}

private func testGeminiWorkspaceTier() async throws {
    let transport = FakeTransport([
        try response(["currentTier": ["id": "free-tier"]]),
        try response(["buckets": [["modelId": "gemini-flash", "remainingFraction": 0.5]]]),
    ])
    let result = await AdditionalCLIQuotaReader(
        transport: transport,
        fileReader: fixtureReader(try geminiFiles(hostedDomain: "fixture.invalid")).0
    ).load(profile: profile(.gemini))
    try expect(result.state == .available && result.planLabel == "Workspace", "Gemini hosted-domain tier")
}

private func testGeminiExhaustedRemainsAvailable() async throws {
    let transport = FakeTransport([
        try validGeminiStatus(),
        try response(["buckets": [["modelId": "gemini-2.5-pro", "remainingFraction": 0.0]]]),
    ])
    let result = await AdditionalCLIQuotaReader(
        transport: transport,
        fileReader: fixtureReader(try geminiFiles()).0
    ).load(profile: profile(.gemini))
    try expect(result.state == .available, "Gemini exhausted is available, not unknown/login")
    try expect(result.messageCode == nil, "Gemini exhausted is not an error code")
    try expect(result.windows.count == 1, "Gemini exhausted keeps the official window")
    try expect(result.windows.first?.usedPercent == 100, "Gemini remainingFraction 0 is 100% used")
}

private func testMiMoMetadataOnly() async throws {
    func files(key: String) throws -> [String: Data] {
        [
            "auth.json": try json([
                "xiaomi": [
                    "type": "api",
                    "key": key,
                    "metadata": ["uid": "mimo-user-42"],
                ]
            ])
        ]
    }
    let transport = FakeTransport([])
    let first = await AdditionalCLIQuotaReader(
        transport: transport,
        fileReader: fixtureReader(try files(key: "fixture-key-a")).0
    )
    .load(profile: profile(.mimo))
    let second = await AdditionalCLIQuotaReader(
        transport: transport,
        fileReader: fixtureReader(try files(key: "fixture-key-b")).0
    )
    .load(profile: profile(.mimo))
    try expect(first.state == .unsupported, "MiMo native quota limitation")
    try expect(first.messageCode == "local_cli_mimo_native_quota_unsupported", "MiMo limitation message")
    try expect(first.maskedIdentity == "mi***42", "MiMo UID masking")
    try expect(first.identityFingerprint == second.identityFingerprint, "MiMo fingerprint uses UID, not API key")
    try expect(first.windows.isEmpty && first.balance == nil, "MiMo does not mislabel inference/local usage")
    let requests = await transport.requests
    try expect(requests.isEmpty, "MiMo makes no speculative platform request")
}

private func testZCodeSafeBoundary() async throws {
    let transport = FakeTransport([])
    let (reader, reads) = fixtureReader([:])
    let result = await AdditionalCLIQuotaReader(transport: transport, fileReader: reader)
        .load(profile: profile(.zcode))
    try expect(result.state == .unsupported, "ZCode source boundary")
    try expect(result.messageCode == "local_cli_zcode_native_quota_unsupported", "ZCode limitation message")
    try expect(result.windows.isEmpty && result.balance == nil, "ZCode does not conflate Z.AI subscription")
    try expect(reads.names.isEmpty, "ZCode encrypted credential store is not read")
    let requests = await transport.requests
    try expect(requests.isEmpty, "ZCode unverified billing endpoints are not called")
}

private func testWorkBuddyAndTraeUnsupportedWithoutIO() async throws {
    let transport = FakeTransport([])
    let (reader, reads) = fixtureReader([
        "auth.json": try json(["must-not-be-read": true]),
        "settings.json": try json(["security": ["auth": ["selectedType": "oauth-personal"]]]),
        "oauth_creds.json": try json(["access_token": "fixture-must-not-be-used"]),
        "credentials.json": try json(["must-not-be-read": true]),
    ])
    for kind in [LocalCLIKind.workBuddy, .trae] {
        let result = await AdditionalCLIQuotaReader(transport: transport, fileReader: reader)
            .load(profile: profile(kind))
        try expect(result.state == .unsupported, "\(kind.rawValue) lacks a supported selected-session reader")
        try expect(result.state != .needsLogin, "\(kind.rawValue) is not classified as needsLogin")
        let expectedCode = kind == .workBuddy
            ? "local_cli_workbuddy_app_session_read_limited" : "local_cli_trae_default_required"
        try expect(result.messageCode == expectedCode, "\(kind.rawValue) explains its app-session boundary")
        try expect(result.windows.isEmpty, "\(kind.rawValue) does not forge windows")
        try expect(result.balance == nil, "\(kind.rawValue) does not report a balance")
        try expect(result.maskedIdentity == nil, "\(kind.rawValue) does not derive identity")
        try expect(result.identityFingerprint == nil, "\(kind.rawValue) does not fingerprint tokens")
        try expect(result.planLabel == nil, "\(kind.rawValue) does not invent a plan")
        try expect(
            result.windows.contains { $0.usedPercent == 0 || $0.usedPercent == 100 } == false,
            "\(kind.rawValue) does not fill 0% or 100%")
    }
    try expect(reads.names.isEmpty, "WorkBuddy/TRAE do not read credentials or config files")
    let requests = await transport.requests
    try expect(requests.isEmpty, "WorkBuddy/TRAE do not probe billing or transport")
}

private func testTraeOfficialCredits() async throws {
    let encoded = "dGMFEAAAAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh/FbtdOeI2U9dFDAosMMUvYih5VTbf3fRPwHGBxTiq1fz5fT3UkW1Tazy+rgoiQwNd1IP5mhe91fyn15FJi5hwy/I3G70YK2fQ1J7KkSd8lXs0ZvLxlOdqIYlUzxThEmzIUc79elQMe3Pu//f0T44++mHjQ6y2HnY82UycvJYxGpg=="
    let changed = "dGMFEAAAAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh+jNRYRW/YKsi93Y1NrYIpA1Srg37yWxjAdSMLPqL+eMEdyWz1m1ZWv5b/LNfY6hmH0N0zHGYtUrSASixvHaT3ORNqfECY03Q3Ro5caShDlFcIsoko9h0e/7stEd6I1ZCqs18C/YA1jkdlsrsXg4yULtg5gmqA4FFvVlSQdnEPqFQ=="
    let native = LocalCLIProfile(id: "fixture-trae", kind: .trae, displayName: "Fixture", configDirectory: LocalCLIKind.trae.defaultConfigDirectory(home: FileManager.default.homeDirectoryForCurrentUser).path, isDefault: true)
    let packs: [String: Any] = ["code":0, "user_entitlement_pack_list":[
        ["entitlement_base_info":["quota":["credits_limit":"4800"]], "usage":["credits_amount":"97.2"]]]]
    let transport = FakeTransport([try response(packs)])
    let storage = try json(["iCubeAuthInfo://icube.cloudide":encoded])
    let value = await TraeCLIQuotaReader(transport: transport, fileReader: { _,_,_ in storage }).load(profile: native)
    try expect(value.state == .available && abs((value.balance ?? 0) - 4702.8) < 0.001 && value.balanceCurrency == "CREDITS", "TRAE reads official credit packs")
    try expect(value.identityFingerprint?.count == 64 && value.windows.count == 1, "TRAE account-bound quota")
    let requests = await transport.requests
    try expect(requests.count == 1 && requests[0].url?.absoluteString == "https://api.trae.cn/trae/api/v2/pay/ide_user_ent_usage", "fixed TRAE origin")
    try expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Cloud-IDE-JWT fixture-token", "selected TRAE session")
    var linked = native
    linked.configDirectory = "/synthetic/trae-linked"
    var linkedReads = 0
    let linkedTransport = FakeTransport([])
    let linkedValue = await TraeCLIQuotaReader(transport: linkedTransport, fileReader: { _,_,_ in
        linkedReads += 1; return storage
    }).load(profile: linked)
    let linkedRequests = await linkedTransport.requests
    try expect(linkedValue.state == .unsupported && linkedReads == 0 && linkedRequests.isEmpty, "TRAE linked path stays outside default-session reader")
    var reads = 0
    let changedStorage = try json(["iCubeAuthInfo://icube.cloudide":changed])
    let switching = await TraeCLIQuotaReader(transport: FakeTransport([try response(packs)]), fileReader: { _,_,_ in
        reads += 1; return reads == 1 ? storage : changedStorage
    }).load(profile: native)
    try expect(switching.state == .unavailable && switching.balance == nil, "TRAE account switch invalidates response")
    var corrupted = Data(base64Encoded: encoded)!; corrupted[corrupted.count - 17] ^= 1
    try expect(TraeCLIQuotaReader.decodeSession(corrupted.base64EncodedString()) == nil, "TRAE digest detects tampered session")
    let overused = try TraeCLIQuotaReader.parse(json(["userEntitlementPackList":[["entitlementBaseInfo":["quota":["creditsLimit":10]],"usage":["creditsAmount":12]]]]))
    try expect(overused.remaining == 0 && overused.usedPercent == 100, "credits cannot be negative")
    for invalid in [try json(["code":false,"user_entitlement_pack_list":[]]), try json(["user_entitlement_pack_list":[["entitlement_base_info":["quota":["credits_limit":true]]]]])] {
        do { _ = try TraeCLIQuotaReader.parse(invalid); throw FixtureError.failed("invalid credit response accepted") }
        catch is FixtureError { throw FixtureError.failed("invalid credit response accepted") }
        catch {}
    }
}

@main
private enum AdditionalCLIQuotaFixture {
    static func main() async throws {
        try await testTraeOfficialCredits()
        try await testGeminiValid()
        try await testGeminiAuthIsolation()
        try await testGeminiExpiredDoesNotRefresh()
        try await testGeminiInvalidQuotas()
        try await testGeminiHTTPStates()
        try await testGeminiWorkspaceTier()
        try await testGeminiExhaustedRemainsAvailable()
        try await testMiMoMetadataOnly()
        try await testZCodeSafeBoundary()
        try await testWorkBuddyAndTraeUnsupportedWithoutIO()
        print("additional-cli-quota-fixture: ok")
    }
}
