import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool) throws -> Data? {
        fatalError("production filesystem access is not used by this synthetic fixture")
    }
}

private actor Transport: LocalCLIQuotaTransport {
    let responseValue: LocalCLIHTTPResponse
    private(set) var requests: [URLRequest] = []
    init(_ response: LocalCLIHTTPResponse) { responseValue = response }
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        requests.append(request); return responseValue
    }
}

private enum FixtureFailure: Error { case failed(String) }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure.failed(message) }
}
private func data(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
private func response(_ value: Any, status: Int = 200) throws -> LocalCLIHTTPResponse {
    LocalCLIHTTPResponse(statusCode: status, headers: [:], data: try data(value))
}
private func profile() -> LocalCLIProfile {
    LocalCLIProfile(id: "synthetic-zcode", kind: .zcode, displayName: "Synthetic ZCode",
                    configDirectory: LocalCLIKind.zcode.defaultConfigDirectory(
                        home: FileManager.default.homeDirectoryForCurrentUser).path, isDefault: true)
}
private func settings(family: String = "zai", kind: String = "individual-coding-plan") throws -> Data {
    try data(["providerFamilyDomain": family,
              "providerFamilyConnectionSelections": [family: ["kind": kind]]])
}
private func config(host: String = "https://api.z.ai/api/anthropic", family: String = "zai",
                    enabled: Bool = true, disabledReason: String? = nil,
                    extra: [String: Any] = [:]) throws -> Data {
    var providers = extra
    var selected: [String: Any] = ["enabled": enabled,
                                   "options": ["apiKey": "stale-mirror-must-not-be-used", "baseURL": host]]
    selected["systemDisabledReason"] = disabledReason
    providers["builtin:\(family)-coding-plan"] = selected
    return try data(["provider": providers])
}
private func store(family: String = "zai", account: String = "acct-fixture") throws -> Data {
    let key = "account-provider:coding-plan:account:\(family)-individual-coding-plan:account:\(account):api-key"
    return try data(["oauth:\(family):user_info": "encrypted-profile",
                     key: "encrypted-account-key"])
}
private func reader(
    config: Data?, transport: Transport,
    selected: Data? = try? settings(), credentials: Data? = try? store(),
    onRead: ((String, Int) -> Data?)? = nil
) -> ZCodeCLIQuotaReader {
    var counts: [String: Int] = [:]
    return ZCodeCLIQuotaReader(transport: transport, fileReader: { url, maximum, _ in
        let name = url.lastPathComponent
        counts[name, default: 0] += 1
        let value = onRead?(name, counts[name] ?? 0) ??
            (name == "setting.json" ? selected : name == "config.json" ? config : credentials)
        if let value { try expect(value.count <= maximum, "bounded native store") }
        return value
    }, decryptor: { value in
        switch value {
        case "encrypted-profile": return "{\"id\":\"acct-fixture\",\"username\":\"fixture\",\"displayName\":\"Fixture\"}"
        case "encrypted-account-key": return "synthetic-api-key"
        default: return nil
        }
    })
}
private func quota(_ limits: [[String: Any]], level: Any = "coding-plan-pro") throws -> LocalCLIHTTPResponse {
    try response(["code": 200, "success": true, "data": ["level": level, "limits": limits]])
}
private let normalLimits: [[String: Any]] = [
    ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100, "currentValue": 25,
     "percentage": 25, "nextResetTime": 1_900_000_000_000],
    ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 200, "currentValue": 40],
]

private func testNormalAndHostScope() async throws {
    for (family, host) in [("zai", "https://api.z.ai/api/anthropic"),
                           ("bigmodel", "https://open.bigmodel.cn/api/paas/v4")] {
        let transport = Transport(try quota(normalLimits))
        let result = await reader(config: try config(host: host, family: family), transport: transport,
                                  selected: try settings(family: family), credentials: try store(family: family))
            .load(profile: profile())
        try expect(result.state == .available, "normal state")
        try expect(result.planLabel == "coding-plan-pro", "bounded plan")
        try expect(result.windows.map(\.label) == ["5-hour", "Weekly"], "window labels")
        try expect(result.windows.map(\.usedPercent) == [25, 20], "quota percentages")
        try expect(result.identityFingerprint == nil && result.maskedIdentity == nil, "API key is not identity")
        try expect(result.balance == nil, "coding plan is not an unrelated balance")
        let requests = await transport.requests
        try expect(requests.count == 1, "one fixed request")
        try expect(requests[0].url?.scheme == "https", "https only")
        try expect(requests[0].url?.path == "/api/monitor/usage/quota/limit", "fixed quota path")
        try expect(requests[0].url?.host == URL(string: host)?.host, "official origin")
        try expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-api-key",
                   "configured key only")
    }
}

private func testStrictProviderSelectionAndNoFallback() async throws {
    let emptyTransport = Transport(try quota(normalLimits))
    for candidate in [
        nil,
        try data(["provider": ["custom": ["enabled": true, "options": ["apiKey": "synthetic", "baseURL": "https://api.z.ai"]]]]),
        try config(host: "https://unknown.invalid/api/anthropic"),
        try config(host: "http://api.z.ai/api/anthropic"),
        try config(host: "https://api.z.ai:443/api/anthropic"),
    ] {
        let result = await reader(config: candidate, transport: emptyTransport).load(profile: profile())
        try expect(result.state == .unsupported, "non-matching configuration unsupported")
    }
    for selected in [try settings(kind: "start-plan"), try settings(kind: "team-coding-plan"),
                     try settings(family: "other")] {
        let result = await reader(config: try config(), transport: emptyTransport, selected: selected)
            .load(profile: profile())
        try expect(result.state == .unsupported, "only the active individual coding-plan is queried")
    }
    let staleLegacy = try data([
        "providerFamilyDomain": "zai",
        "providerFamilyConnectionSelections": ["zai": ["kind": "start-plan"]],
        "modelProviderFamilySelectedKeys": ["zai": "coding-plan:builtin:zai-coding-plan"],
    ])
    let staleLegacyResult = await reader(config: try config(), transport: emptyTransport,
                                         selected: staleLegacy).load(profile: profile())
    try expect(staleLegacyResult.state == .unsupported, "current kind outranks stale legacy selection")
    let inactive = await reader(config: try config(enabled: false, disabledReason: "oauth_provider_inactive"),
                                transport: emptyTransport).load(profile: profile())
    try expect(inactive.state == .unsupported && inactive.messageCode == "local_cli_zcode_inactive_provider",
               "inactive native provider is not queried")
    let staleMirror = await reader(config: try config(), transport: emptyTransport, credentials: nil)
        .load(profile: profile())
    try expect(staleMirror.state != .available, "config mirror alone never supplies quota")
    let knownIdentityWithoutKey = await reader(config: try config(), transport: emptyTransport,
                                               credentials: try store(account: "old-account"))
        .load(profile: profile())
    try expect(knownIdentityWithoutKey.state == .unavailable, "known account without own key rejects mirror")
    try expect(knownIdentityWithoutKey.messageCode == "local_cli_zcode_account_unverified",
               "missing own key is an identity failure, not local sign-out")
    var linked = profile()
    linked.isDefault = false
    let linkedResult = await reader(config: try config(), transport: emptyTransport).load(profile: linked)
    try expect(linkedResult.state == .unsupported, "linked profile never reads the default native store")
    let recordedRequests = await emptyTransport.requests
    try expect(recordedRequests.isEmpty, "no arbitrary-provider or host fallback")
}

private func testInvalidQuotaShapes() async throws {
    let invalidLimits: [[[String: Any]]] = [
        [["type": "CREDIT_LIMIT", "unit": 9_223_372_036_854_775_808.0, "number": 5, "usage": 10, "currentValue": 1]],
        [["type": "CREDIT_LIMIT", "unit": true, "number": 5, "usage": 10, "currentValue": 1]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5.5, "usage": 10, "currentValue": 1]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": true, "currentValue": 1]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 0, "currentValue": 0]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 11]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 1, "percentage": 101]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 1, "nextResetTime": false]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 1, "nextResetTime": 1_700_000_000_000]],
        [["type": "UNKNOWN_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 1]],
    ]
    for limits in invalidLimits {
        let transport = Transport(try quota(limits))
        let result = await reader(config: try config(), transport: transport).load(profile: profile())
        try expect(result.state == .unavailable && result.windows.isEmpty, "invalid limit unavailable")
    }
}

private func testHTTPStates() async throws {
    for (status, expected, code) in [
        (401, LocalCLIQuotaState.unavailable, "local_cli_remote_unauthorized"),
        (403, .unavailable, "local_cli_remote_forbidden"),
        (429, .rateLimited, "local_cli_rate_limited"),
    ] {
        let transport = Transport(try response([:], status: status))
        let result = await reader(config: try config(), transport: transport).load(profile: profile())
        try expect(result.state == expected, "HTTP state mapping")
        try expect(result.messageCode == code, "HTTP reason keeps local login distinct")
    }
}

private func testAccountSwitchRefusesOldQuota() async throws {
    let transport = Transport(try quota(normalLimits))
    let result = await reader(config: try config(), transport: transport, onRead: { name, count in
        name == "credentials.json" && count == 2 ? try? store(account: "other-account") : nil
    }).load(profile: profile())
    try expect(result.state == .unavailable, "account change invalidates the in-flight response")
    try expect(result.messageCode == "local_cli_zcode_account_changed", "account change reason")
    let requests = await transport.requests
    try expect(requests.count == 1, "the selected account was queried once")
}

private func testNativeCredentialEnvelope() throws {
    let secret = "zcode-credential-fallback:darwin:\(FileManager.default.homeDirectoryForCurrentUser.path):\(NSUserName())"
    let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
    let plain = "synthetic-account-key"
    let sealed = try AES.GCM.seal(Data(plain.utf8), using: key)
    func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let envelope = "enc:v1:\(base64URL(Data(sealed.nonce))).\(base64URL(sealed.tag)).\(base64URL(sealed.ciphertext))"
    try expect(ZCodeCLIQuotaReader.decryptStoredCredential(envelope, secretOverride: secret) == plain,
               "same-machine native envelope decrypts in memory")
    try expect(ZCodeCLIQuotaReader.decryptStoredCredential("enc:v1:invalid") == nil,
               "malformed native envelope is rejected")
}

@main enum Main {
    static func main() async throws {
        try testNativeCredentialEnvelope()
        try await testNormalAndHostScope()
        try await testStrictProviderSelectionAndNoFallback()
        try await testInvalidQuotaShapes()
        try await testHTTPStates()
        try await testAccountSwitchRefusesOldQuota()
        print("zcode-cli-quota-fixture: ok")
    }
}
