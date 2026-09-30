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
    let billingResponse: LocalCLIHTTPResponse?
    private(set) var requests: [URLRequest] = []
    init(_ response: LocalCLIHTTPResponse, billing: LocalCLIHTTPResponse? = nil) {
        responseValue = response
        billingResponse = billing
    }
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        requests.append(request)
        return request.url?.host == "zcode.z.ai" ? (billingResponse ?? responseValue) : responseValue
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
private func store(family: String = "zai", account: String = "acct-fixture", active: String? = nil,
                   billing: Bool = false) throws -> Data {
    let key = "account-provider:coding-plan:account:\(family)-individual-coding-plan:account:\(account):api-key"
    var values = ["oauth:\(family):user_info": "encrypted-profile", key: "encrypted-account-key"]
    if let active { values["oauth:active_provider"] = "encrypted-active-" + active }
    if billing { values["zcodejwttoken"] = "encrypted-billing-jwt" }
    return try data(values)
}
private func reader(
    config: Data?, transport: Transport,
    selected: Data? = try? settings(), credentials: Data? = try? store(),
    telemetry: Data? = try? data(["deviceMid": "synthetic-device"]),
    onRead: ((String, Int) -> Data?)? = nil
) -> ZCodeCLIQuotaReader {
    var counts: [String: Int] = [:]
    return ZCodeCLIQuotaReader(transport: transport, fileReader: { url, maximum, _ in
        let name = url.lastPathComponent
        counts[name, default: 0] += 1
        let value = onRead?(name, counts[name] ?? 0) ??
            (name == "setting.json" ? selected : name == "config.json" ? config
                : name == "telemetry-state.json" ? telemetry : credentials)
        if let value { try expect(value.count <= maximum, "bounded native store") }
        return value
    }, decryptor: { value in
        switch value {
        case "encrypted-profile": return "{\"id\":\"acct-fixture\",\"username\":\"fixture\",\"displayName\":\"Fixture\"}"
        case "encrypted-account-key": return "synthetic-api-key"
        case "encrypted-billing-jwt": return "synthetic-billing-jwt"
        case "encrypted-active-zai": return "zai"
        case "encrypted-active-bigmodel": return "bigmodel"
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
        try expect(result.identityFingerprint?.count == 64 && result.maskedIdentity == nil, "verified selected account has a private stable identity")
        try expect(result.balance == nil, "coding plan is not an unrelated balance")
        let requests = await transport.requests
        try expect(requests.count == 1, "one fixed request")
        try expect(requests[0].url?.scheme == "https", "https only")
        try expect(requests[0].url?.path == "/api/monitor/usage/quota/limit", "fixed quota path")
        try expect(requests[0].url?.host == (family == "bigmodel" ? "bigmodel.cn" : "api.z.ai"), "official monitoring origin")
        try expect(requests[0].value(forHTTPHeaderField: "Authorization") == "synthetic-api-key",
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
    for selected in [try settings(kind: "team-coding-plan"),
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
    try expect(staleLegacyResult.state == .unavailable, "Start Plan cannot use the stale Coding Plan key")
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

private func testStaleRegistryUsesVerifiedActiveSession() async throws {
    let transport = Transport(try quota(normalLimits))
    let stale = try config(enabled: false, disabledReason: "oauth_provider_inactive")
    let result = await reader(config: stale, transport: transport,
                              credentials: try store(active: "zai")).load(profile: profile())
    try expect(result.state == .available && result.windows.count == 2,
               "current active session outranks stale registry inactivity")
    for registry in [stale, try config()] {
        let mismatched = await reader(config: registry, transport: transport,
                                       credentials: try store(active: "bigmodel")).load(profile: profile())
        try expect(mismatched.state == .unsupported, "another family's saved key is never queried")
    }
    let switched = await reader(config: stale, transport: transport,
        credentials: try store(active: "zai"), onRead: { name, count in
            name == "credentials.json" && count == 2 ? try? store(active: "bigmodel") : nil
        }).load(profile: profile())
    try expect(switched.messageCode == "local_cli_zcode_account_changed", "active family is rechecked after request")
    let requests = await transport.requests
    try expect(requests.count == 2, "only verified selected sessions were queried")
}

private func testNoPlanKeepsKnownAccountWithoutInventingQuota() async throws {
    let transport = Transport(try response(["code": 500, "success": false, "msg": "当前用户不存在coding plan"]))
    let result = await reader(config: try config(), transport: transport).load(profile: profile())
    try expect(result.state == .unsupported && result.messageCode == "local_cli_zcode_no_coding_plan", "no plan is distinct from a broken reader")
    try expect(result.identityFingerprint?.count == 64 && result.windows.isEmpty && result.balance == nil, "known account remains visible without false zero quota")
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

private let billingNow = Date(timeIntervalSince1970: 1_800_000_000)
private func billingPayload(status: String = "active", end: Int = 1_800_086_400,
                            total: Any = 100_000_000, remaining: Any = 100_000_000,
                            unit: String = "token", effective: Int = 0,
                            duplicate: Bool = false) -> [String: Any] {
    let bucket: [String: Any] = [
        "plan_id": "trust-plan", "user_plan_id": "user-grant", "entitlement_id": "flash",
        "bucket_id": "grant-bucket", "show_name": "GLM-5.3-Flash", "unit_type": unit,
        "total_units": total, "remaining_units": remaining, "expires_at": end,
    ]
    return ["code": 0, "data": [
        "server_time": 1_800_000_000,
        "plans": [["plan_id": "trust-plan", "user_plan_id": "user-grant", "name": "ZCode Trust Build",
                   "status": status, "ends_at": end,
                   "entitlements": [["entitlement_id": "flash", "period": "one_time", "unit_type": unit,
                                     "effective_at": effective]]]],
        "balances": duplicate ? [bucket, bucket] : [bucket],
    ]]
}

private func testStartPlanIsIndependentFromCodingPlan() async throws {
    for codingStatus in [200, 403, 429] {
        let coding = try response(["code": 500, "msg": "当前用户不存在coding plan"], status: codingStatus)
        let transport = Transport(coding, billing: try response(billingPayload(duplicate: true)))
        let result = await reader(config: try config(), transport: transport,
                                  credentials: try store(active: "zai", billing: true))
            .load(profile: profile(), now: billingNow)
        try expect(result.state == .available && result.windows.count == 1, "Start Plan survives missing or failed Coding Plan; duplicate grant is counted once")
        let window = result.windows[0]
        try expect(result.planLabel == "ZCode Trust Build" && window.label == "GLM-5.3-Flash", "official grant and model names")
        try expect(window.remainingTokens == 100_000_000 && window.totalTokens == 100_000_000 && window.usedPercent == 0, "exact 100 million token allowance")
        try expect(window.tokenAmountText == "100,000,000 / 100,000,000 Tokens", "home/detail counts are not rounded to millions or money")
        try expect(window.isExpiry && window.resetsAt == Date(timeIntervalSince1970: 1_800_086_400), "one-time grant expires; it does not replenish")
        try expect(result.identityFingerprint?.count == 64 && result.balance == nil, "token grant stays separate from monetary balance")
        let requests = await transport.requests
        try expect(requests.count == 2, "both account quota endpoints are checked")
        let billing = requests.first { $0.url?.host == "zcode.z.ai" }!
        try expect(billing.url?.absoluteString == "https://zcode.z.ai/api/v1/zcode-plan/billing/balance", "billing uses its fixed official origin")
        try expect(billing.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-billing-jwt"
                   && billing.value(forHTTPHeaderField: "X-Device-Mid") == "synthetic-device", "billing uses the active OAuth JWT and native device id")
    }
    let healthyCoding = Transport(try quota(normalLimits), billing: try response([:], status: 503))
    let partial = await reader(config: try config(), transport: healthyCoding,
                               credentials: try store(active: "zai", billing: true))
        .load(profile: profile(), now: billingNow)
    try expect(partial.state == .available && partial.windows.count == 2
               && partial.messageCode == "local_cli_zcode_partial_quota", "billing failure preserves healthy Coding Plan with a partial-data note")
}

private func testStartSelectionAndAccountScope() async throws {
    let transport = Transport(try response(billingPayload(total: "100000000", remaining: "99000000")))
    let selected = try settings(kind: "start-plan")
    let credentials = try store(account: "old-key-owner", active: "zai", billing: true)
    let result = await reader(config: try config(), transport: transport, selected: selected, credentials: credentials)
        .load(profile: profile(), now: billingNow)
    try expect(result.state == .available && result.windows.first?.remainingTokens == 99_000_000,
               "Start Plan selection needs no Coding Plan key and accepts numeric strings")
    try expect(abs((result.windows.first?.usedPercent ?? -1) - 1) < 0.00001, "billing percentage uses exact allowance")
    let requests = await transport.requests
    try expect(requests.count == 1 && requests[0].url?.host == "zcode.z.ai", "Start Plan never calls the unrelated coding endpoint")
    let withoutKey = await reader(config: try config(), transport: transport, credentials: credentials)
        .load(profile: profile(), now: billingNow)
    try expect(withoutKey.state == .available, "Coding selection without its account-bound key still has independent Start Plan")
    let changed = await reader(config: try config(), transport: transport, selected: selected, credentials: credentials,
        onRead: { name, count in
            name == "credentials.json" && count == 2 ? try? store(active: "bigmodel", billing: true) : nil
        }).load(profile: profile(), now: billingNow)
    try expect(changed.messageCode == "local_cli_zcode_account_changed" && changed.windows.isEmpty, "in-flight billing never survives an account switch")
    let blocked = Transport(try response(billingPayload()))
    for credentials in [try store(billing: true), try store(active: "bigmodel", billing: true)] {
        let result = await reader(config: try config(), transport: blocked, selected: selected, credentials: credentials)
            .load(profile: profile(), now: billingNow)
        try expect(result.windows.isEmpty, "unbound global JWT never supplies an account quota")
    }
    let noDevice = await reader(config: try config(), transport: blocked, selected: selected,
                               credentials: try store(active: "zai", billing: true), telemetry: nil)
        .load(profile: profile(), now: billingNow)
    try expect(noDevice.state == .unavailable, "missing device id does not issue an invalid request")
    let blockedRequests = await blocked.requests
    try expect(blockedRequests.isEmpty, "unverified billing credentials never reach the network")
}

private func testExpiredAndInvalidBillingGrants() async throws {
    let selected = try settings(kind: "start-plan")
    let credentials = try store(active: "zai", billing: true)
    for payload in [billingPayload(status: "expired"), billingPayload(end: 1_799_999_999),
                    billingPayload(effective: 1_800_000_001)] {
        let transport = Transport(try response(payload))
        let result = await reader(config: try config(), transport: transport, selected: selected, credentials: credentials)
            .load(profile: profile(), now: billingNow)
        try expect(result.windows.isEmpty && result.messageCode == "local_cli_zcode_no_quota", "expired or not-effective grants cannot appear spendable")
    }
    for payload in [billingPayload(total: true), billingPayload(remaining: -1),
                    billingPayload(remaining: 100_000_001), billingPayload(remaining: "NaN"),
                    billingPayload(total: 100_000_000.5)] {
        let transport = Transport(try response(payload))
        let result = await reader(config: try config(), transport: transport, selected: selected, credentials: credentials)
            .load(profile: profile(), now: billingNow)
        try expect(result.state == .unavailable && result.windows.isEmpty, "invalid billing counts never produce fabricated token amounts")
    }
    let transport = Transport(try response(billingPayload(unit: "credit")))
    let result = await reader(config: try config(), transport: transport, selected: selected, credentials: credentials)
        .load(profile: profile(), now: billingNow)
    try expect(result.state == .available && result.windows.first?.tokenAmountText == nil, "other units are never mislabeled as Tokens")
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
        try await testStaleRegistryUsesVerifiedActiveSession()
        try await testNoPlanKeepsKnownAccountWithoutInventingQuota()
        try await testStrictProviderSelectionAndNoFallback()
        try await testInvalidQuotaShapes()
        try await testHTTPStates()
        try await testAccountSwitchRefusesOldQuota()
        try await testStartPlanIsIndependentFromCodingPlan()
        try await testStartSelectionAndAccountScope()
        try await testExpiredAndInvalidBillingGrants()
        print("zcode-cli-quota-fixture: ok")
    }
}
