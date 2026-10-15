import Foundation

private enum FixtureFailure: Error { case check(String), synthetic }

private actor MockWire {
    var requests: [URLRequest] = []
    let status: Int
    let body: Data
    let throwsError: Bool
    let gated: Bool
    let differentURL: Bool
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(status: Int = 200, body: Data, throwsError: Bool = false, gated: Bool = false, differentURL: Bool = false) {
        self.status = status; self.body = body; self.throwsError = throwsError
        self.gated = gated; self.differentURL = differentURL
    }

    func response(_ request: URLRequest) async throws -> MiniProgramDesktopClient.HTTPResponse {
        requests.append(request)
        startWaiter?.resume(); startWaiter = nil
        if gated { await withCheckedContinuation { releaseWaiter = $0 } }
        if throwsError { throw FixtureFailure.synthetic }
        return .init(statusCode: status, body: body, url: differentURL ? URL(string: "https://other.synthetic.invalid/")! : request.url!)
    }

    func started() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func count() -> Int { requests.count }
    func firstRequest() -> URLRequest? { requests.first }
}

@main enum MiniProgramDesktopClientFixture {
    typealias Client = MiniProgramDesktopClient
    typealias Exporter = MiniProgramAccountExport
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let token = String(repeating: "synthetic-desktop-token-", count: 3)
    static let accountRef = String(repeating: "a", count: 64)
    static let scopeRef = String(repeating: "b", count: 64)
    static let cardRef = String(repeating: "c", count: 64)
    static var checks = 0

    static func expect(_ value: Bool, _ name: String) throws {
        checks += 1
        if !value { throw FixtureFailure.check(name) }
    }

    static func timestamp(_ date: Date) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.string(from: date)
    }

    static func snapshot(age: Double = 0, status: Exporter.Status = .ok, count: Int? = 2, cards: [Exporter.Card] = []) -> Exporter.ResetSnapshotV1 {
        .init(accountRef: accountRef, label: "账号 " + String(accountRef.prefix(8)), scope: scopeRef,
              observedAt: timestamp(now.addingTimeInterval(-age)), status: status, availableResetCredits: count, resetCards: cards)
    }

    static func configuration(_ endpoint: String = "https://desktop.synthetic.invalid/") throws -> Client.Configuration {
        try .init(endpoint: URL(string: endpoint)!, token: token)
    }

    static func pairingBody(code: String = "synthetic-pairing-code", expiry: Date = now.addingTimeInterval(600)) -> Data {
        try! JSONSerialization.data(withJSONObject: ["code": code, "expiresAt": timestamp(expiry)])
    }

    static func acknowledgement(_ accepted: Bool = true, count: Int = 0) -> Data {
        try! JSONSerialization.data(withJSONObject: ["accepted": accepted, "eventCount": count])
    }

    static func same(_ first: Client.Failure, _ second: Client.Failure) -> Bool {
        switch (first, second) {
        case (.invalidConfiguration, .invalidConfiguration), (.notConfigured, .notConfigured),
             (.busy, .busy), (.invalidSnapshot, .invalidSnapshot), (.cancelled, .cancelled): return true
        default: return false
        }
    }

    static func expectFailure(_ expected: Client.Failure, _ name: String, operation: () async throws -> Void) async throws {
        do { try await operation(); throw FixtureFailure.check(name + " accepted") }
        catch let actual as Client.Failure { try expect(same(actual, expected), name) }
    }

    static func accepted<Value>(_ result: Client.Outcome<Value>, _ name: String) throws -> Value {
        if case .accepted(let value) = result { try expect(true, name); return value }
        throw FixtureFailure.check(name)
    }

    static func unconfirmed<Value>(_ result: Client.Outcome<Value>, _ reason: Client.UnconfirmedReason, _ name: String) throws {
        if case .unconfirmed(let actual) = result {
            try expect(String(describing: actual) == String(describing: reason), name)
        } else { throw FixtureFailure.check(name) }
    }

    private static func mocked(_ wire: MockWire) -> Client {
        Client(transport: { try await wire.response($0) }, clock: { now })
    }

    static func unitChecks() async throws {
        for endpoint in ["http://desktop.synthetic.invalid/", "http://localhost/", "file:///tmp/synthetic",
                         "https://desktop.synthetic.invalid/subpath", "https://desktop.synthetic.invalid/?query=1",
                         "https://desktop.synthetic.invalid/#fragment", "https://user@desktop.synthetic.invalid/",
                         "https://user:password@desktop.synthetic.invalid/", "https://desktop.synthetic.invalid:0/",
                         "https://desktop.synthetic.invalid:65536/"] {
            do { _ = try configuration(endpoint); throw FixtureFailure.check("invalid endpoint accepted") }
            catch Client.Failure.invalidConfiguration { try expect(true, "invalid endpoint rejected") }
        }
        for value in [String(repeating: "a", count: 31), String(repeating: "a", count: 1025),
                      token + "\r\nAuthorization: injected", token + "\n", token + "\t", token + " ", token + "字"] {
            do { _ = try Client.Configuration(endpoint: URL(string: "https://desktop.synthetic.invalid/")!, token: value); throw FixtureFailure.check("invalid token accepted") }
            catch Client.Failure.invalidConfiguration { try expect(true, "unsafe token rejected") }
        }
        for endpoint in ["http://127.0.0.1:8799/", "http://[::1]:8799/", "https://desktop.synthetic.invalid/"] {
            let config = try configuration(endpoint)
            try expect(!String(describing: config).contains(token) && !String(reflecting: config).contains(token), "configuration descriptions redact credentials")
            try expect(!String(describing: config).contains(endpoint), "configuration description does not reveal endpoint")
        }

        let wire = MockWire(body: acknowledgement())
        let client = mocked(wire)
        try await expectFailure(.notConfigured, "unconfigured pairing") { _ = try await client.createPairing() }
        try await expectFailure(.notConfigured, "unconfigured upload") { _ = try await client.upload(snapshot()) }
        try expect(await wire.count() == 0, "unconfigured client does not send")
        await client.configure(try configuration())
        let oneCard = Exporter.Card(id: cardRef, expiresAt: timestamp(now.addingTimeInterval(3600)))
        let invalid = [snapshot(age: 301), snapshot(age: -1), snapshot(status: .stale), snapshot(status: .unknown),
                       snapshot(count: -1), snapshot(count: 1_000_001), snapshot(count: 0, cards: [oneCard]),
                       snapshot(cards: Array(repeating: oneCard, count: 101)), snapshot(status: .failed, count: 0),
                       snapshot(status: .failed, count: nil, cards: [oneCard]), snapshot(cards: [oneCard, oneCard]),
                       snapshot(cards: [.init(id: "raw-card-id", expiresAt: timestamp(now.addingTimeInterval(3600)))]),
                       snapshot(cards: [.init(id: cardRef, expiresAt: timestamp(now))]),
                       snapshot(cards: [.init(id: cardRef, expiresAt: "2027-02-31T12:00:00.000Z")])]
        for value in invalid {
            try await expectFailure(.invalidSnapshot, "invalid V1 snapshot refused before transport") { _ = try await client.upload(value) }
        }
        let invalidDate = Exporter.ResetSnapshotV1(accountRef: accountRef, label: "账号 " + String(accountRef.prefix(8)), scope: scopeRef,
            observedAt: "not-a-date", status: .ok, availableResetCredits: nil, resetCards: [])
        try await expectFailure(.invalidSnapshot, "invalid source time") { _ = try await client.upload(invalidDate) }
        let oversized = Exporter.ResetSnapshotV1(accountRef: accountRef, label: String(repeating: "x", count: 40_000), scope: scopeRef,
            observedAt: timestamp(now), status: .ok, availableResetCredits: nil, resetCards: [])
        try await expectFailure(.invalidSnapshot, "oversized V1 request") { _ = try await client.upload(oversized) }
        for (reference, label, scope) in [
            ("private-account@example.invalid", "账号 aaaaaaaa", scopeRef),
            (accountRef, "private-account@example.invalid", scopeRef),
            (accountRef, "Bearer synthetic-secret", scopeRef),
            (accountRef, "账号 aaaaaaaa", "private-provider-raw-scope"),
            (String(repeating: "q", count: 64), "账号 qqqqqqqq", scopeRef),
        ] {
            let sensitive = Exporter.ResetSnapshotV1(accountRef: reference, label: label, scope: scope,
                observedAt: timestamp(now), status: .ok, availableResetCredits: nil, resetCards: [])
            try await expectFailure(.invalidSnapshot, "sensitive or non-export identity refused") { _ = try await client.upload(sensitive) }
        }
        for date in ["2027-01-15T08:00:00", "2027-02-31T00:00:00.000Z", "2027-01-15T08:00:00.000+15:00", "2027-01-15T08:00:60.000Z"] {
            let fakeDate = Exporter.ResetSnapshotV1(accountRef: accountRef, label: "账号 " + String(accountRef.prefix(8)), scope: scopeRef,
                observedAt: date, status: .ok, availableResetCredits: nil, resetCards: [])
            try await expectFailure(.invalidSnapshot, "fake source date refused") { _ = try await client.upload(fakeDate) }
        }
        try expect(await wire.count() == 0, "invalid snapshots never reach transport")
        _ = try accepted(await client.upload(snapshot(age: 300)), "freshness boundary accepted")
        _ = try accepted(await client.upload(snapshot(status: .failed, count: nil)), "fresh failure invalidation accepted")
        let request = await wire.firstRequest()!
        try expect(request.httpMethod == "POST" && request.url?.path == "/v1/desktop/snapshots", "V1 POST route")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token, "credential belongs only in authorization header")
        let keys = Set((try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]).keys)
        try expect(keys == ["accountRef", "label", "scope", "observedAt", "status", "availableResetCredits", "resetCards"], "wire body uses exact V1 allowlist")
        try expect(!String(decoding: request.httpBody!, as: UTF8.self).contains(token), "wire body excludes bearer")
        try expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store", "private request not cached")
        let source = UsageSnapshot(
            refreshedAt: now, account: .init(type: "chatgpt", planType: "plus", emailPresent: true, email: "never-export@example.invalid"),
            limitId: "synthetic-export-scope", limitName: "never-export-source-name", quotaReadSucceeded: true,
            fiveHourQuota: nil, sevenDayQuota: nil, monthlyQuota: nil,
            credits: .init(hasCredits: true, unlimited: false, balance: "42", resetCredits: 2,
                resetCreditDetails: [.init(id: "synthetic-source-card", expiresAt: now.addingTimeInterval(3600))]),
            cloudLifetimeTokens: 123, local: nil, taskBoard: nil, messages: ["never-export-source-message"])
        let exported = try Exporter.build(observations: [.init(accountID: "synthetic-export-account", snapshot: source,
            origin: .official, identityVerified: true, lastFailureAt: nil)], now: now)
        try expect(exported.resetSnapshots.count == 1, "actual exporter produces one V1 DTO")
        _ = try accepted(await client.upload(exported.resetSnapshots[0]), "actual exporter V1 DTO is accepted by the client")

        for status in [400, 401, 403, 404, 409, 413, 429] {
            let item = MockWire(status: status, body: acknowledgement())
            let api = mocked(item); await api.configure(try configuration())
            let result = try await api.upload(snapshot())
            if case .rejected(let actual) = result { try expect(actual == status, "server refusal preserved") }
            else { throw FixtureFailure.check("server refusal changed") }
            try expect(await item.count() == 1, "server refusal is never retried")
        }
        for (status, body, shouldThrow, differentURL, reason) in [
            (500, acknowledgement(), false, false, Client.UnconfirmedReason.serverError),
            (200, Data("not-json".utf8), false, false, .invalidResponse),
            (200, acknowledgement(false), false, false, .invalidResponse),
            (200, acknowledgement(true, count: -1), false, false, .invalidResponse),
            (200, acknowledgement(), true, false, .transport),
            (200, acknowledgement(), false, true, .invalidResponse),
            (200, Data(repeating: 0x20, count: Client.maximumBodyBytes + 1), false, false, .invalidResponse),
        ] {
            let item = MockWire(status: status, body: body, throwsError: shouldThrow, differentURL: differentURL)
            let api = mocked(item); await api.configure(try configuration())
            try unconfirmed(await api.upload(snapshot()), reason, "ambiguous write never reports success")
            try expect(await item.count() == 1, "ambiguous write never retries")
        }
        for body in [pairingBody(code: "bad code"), pairingBody(expiry: now), pairingBody(expiry: now.addingTimeInterval(601)), Data("{}".utf8)] {
            let item = MockWire(body: body); let api = mocked(item); await api.configure(try configuration())
            try unconfirmed(await api.createPairing(), .invalidResponse, "invalid pairing response")
        }
        let pairWire = MockWire(body: pairingBody()); let pairClient = mocked(pairWire); await pairClient.configure(try configuration())
        let pairing = try accepted(await pairClient.createPairing(), "valid pairing accepted")
        try expect(pairing.code == "synthetic-pairing-code", "pairing parsed")

        for disconnect in [false, true] {
            let pending = MockWire(body: pairingBody(), gated: true)
            let api = mocked(pending); await api.configure(try configuration())
            let task = Task { try await api.createPairing() }
            await pending.started()
            try await expectFailure(.busy, "single client overlap is busy") { _ = try await api.upload(snapshot()) }
            await api.configure(disconnect ? nil : try configuration("https://changed.synthetic.invalid/"))
            await pending.release()
            try unconfirmed(await task.value, .configurationChanged, "obsolete connection result unconfirmed")
            try expect(await pending.count() == 1, "overlap and configuration change do not create another send")
            if disconnect {
                try await expectFailure(.notConfigured, "disconnected next request") { _ = try await api.createPairing() }
            }
        }
        let cancelledWire = MockWire(body: pairingBody()); let cancelledClient = mocked(cancelledWire)
        await cancelledClient.configure(try configuration())
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelledClient.createPairing()
        }
        try await expectFailure(.cancelled, "cancelled before admission") { _ = try await cancelled.value }
        try expect(await cancelledWire.count() == 0, "cancellation before admission sends nothing")
        print("PASS desktop-client mock checks: \(checks)")
        try emit(["ok": true, "checks": checks, "realAccountIO": false, "externalNetworkSends": 0])
    }

    private struct HTTPInput: Decodable {
        struct Card: Decodable { let id: String; let expiresAt: String }
        struct Snapshot: Decodable {
            let accountRef: String; let label: String; let scope: String; let observedAt: String; let status: String
            let availableResetCredits: Int?; let resetCards: [Card]
        }
        let endpoint: String; let token: String; let action: String; let now: Double; let snapshot: Snapshot?
    }

    static func emit(_ value: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
    }

    static func liveCheck(_ inputPath: String) async throws {
        let input = try JSONDecoder().decode(HTTPInput.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
        guard let endpoint = URL(string: input.endpoint), let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
            parts.scheme == "http", parts.host == "127.0.0.1"
        else { throw FixtureFailure.check("loopback endpoint required") }
        let client = Client(clock: { Date(timeIntervalSince1970: input.now) })
        await client.configure(try .init(endpoint: endpoint, token: input.token))
        do {
            if input.action == "pairing" {
                switch try await client.createPairing() {
                case .accepted(let pair): try emit(["kind": "accepted", "code": pair.code, "expiresAt": pair.expiresAt])
                case .rejected(let code): try emit(["kind": "rejected", "statusCode": code])
                case .unconfirmed(let reason): try emit(["kind": "unconfirmed", "reason": String(describing: reason)])
                }
            } else if input.action == "upload", let value = input.snapshot, let status = Exporter.Status(rawValue: value.status) {
                let snapshot = Exporter.ResetSnapshotV1(accountRef: value.accountRef, label: value.label, scope: value.scope,
                    observedAt: value.observedAt, status: status, availableResetCredits: value.availableResetCredits,
                    resetCards: value.resetCards.map { .init(id: $0.id, expiresAt: $0.expiresAt) })
                switch try await client.upload(snapshot) {
                case .accepted(let response): try emit(["kind": "accepted", "accepted": response.accepted, "eventCount": response.eventCount])
                case .rejected(let code): try emit(["kind": "rejected", "statusCode": code])
                case .unconfirmed(let reason): try emit(["kind": "unconfirmed", "reason": String(describing: reason)])
                }
            } else { throw FixtureFailure.check("unknown fixture action") }
        } catch let error as Client.Failure { try emit(["kind": "failure", "failure": String(describing: error)]) }
    }

    static func main() async throws {
        if CommandLine.arguments.count == 1 { try await unitChecks() }
        else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "http" { try await liveCheck(CommandLine.arguments[2]) }
        else { throw FixtureFailure.check("invalid fixture arguments") }
    }
}
