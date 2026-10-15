import Foundation

/// Explicit V1 companion transport. No account discovery, stored credentials,
/// background upload, retry, or production activation is performed here.
actor MiniProgramDesktopClient {
    struct Configuration: CustomStringConvertible, CustomDebugStringConvertible, Sendable {
        fileprivate let endpoint: URL
        fileprivate let token: String

        init(endpoint: URL, token: String) throws {
            guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
                let host = parts.host, !host.isEmpty,
                parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
                parts.port.map({ (1...65_535).contains($0) }) ?? true,
                parts.scheme == "https"
                    || (parts.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host)),
                (32...1_024).contains(token.utf8.count),
                token.utf8.allSatisfy({ (0x21...0x7e).contains($0) })
            else { throw Failure.invalidConfiguration }
            self.endpoint = endpoint
            self.token = token
        }

        var description: String { "MiniProgramDesktopClient.Configuration(redacted)" }
        var debugDescription: String { description }
    }

    struct HTTPResponse: Sendable {
        let statusCode: Int
        let body: Data
        let url: URL
    }

    struct Pairing: Decodable, Sendable {
        let code: String
        let expiresAt: String
    }

    struct Acknowledgement: Decodable, Sendable {
        let accepted: Bool
        let eventCount: Int
    }

    enum Failure: Error { case invalidConfiguration, notConfigured, busy, invalidSnapshot, cancelled }
    enum UnconfirmedReason: Sendable { case transport, configurationChanged, cancelled, invalidResponse, serverError }
    enum Outcome<Value: Sendable>: Sendable {
        case accepted(Value)
        /// A server refusal, including conflict; not permission to replay.
        case rejected(statusCode: Int)
        /// A write may already have occurred. Never retry this automatically.
        case unconfirmed(UnconfirmedReason)
    }

    typealias Transport = @Sendable (URLRequest) async throws -> HTTPResponse
    static let maximumBodyBytes = 32_768
    private var configuration: Configuration?
    private var generation = UUID()
    private var inFlight = false
    private let transport: Transport
    private let clock: @Sendable () -> Date

    init(
        transport: @escaping Transport = { request in try await MiniProgramDesktopClient.liveTransport(request) },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.clock = clock
    }

    /// Changes affect the next request. A response from an earlier connection
    /// is reported as unconfirmed, even if the old server accepted its write.
    func configure(_ value: Configuration?) {
        configuration = value
        generation = UUID()
    }

    func createPairing() async throws -> Outcome<Pairing> {
        let result = try await send(path: "/v1/desktop/pairings", body: Data("{}".utf8))
        switch result {
        case .accepted(let bytes):
            let now = clock()
            guard let pairing = try? JSONDecoder().decode(Pairing.self, from: bytes),
                pairing.code.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil,
                let expires = Self.date(pairing.expiresAt),
                expires > now, expires.timeIntervalSince(now) <= 600
            else { return .unconfirmed(.invalidResponse) }
            return .accepted(pairing)
        case .rejected(let code): return .rejected(statusCode: code)
        case .unconfirmed(let reason): return .unconfirmed(reason)
        }
    }

    /// Accept only the export's V1 allowlist. The separate internal overview
    /// (points, quota windows and token usage) is deliberately not an input.
    func upload(_ snapshot: MiniProgramAccountExport.ResetSnapshotV1) async throws -> Outcome<Acknowledgement> {
        let now = clock()
        guard now.timeIntervalSince1970.isFinite,
            Self.exportReference(snapshot.accountRef), Self.exportReference(snapshot.scope),
            snapshot.label == "账号 " + String(snapshot.accountRef.prefix(8)),
            let observed = Self.date(snapshot.observedAt), observed <= now,
            now.timeIntervalSince(observed) <= MiniProgramAccountExport.freshness,
            snapshot.status == .ok || snapshot.status == .failed,
            snapshot.resetCards.count <= 100,
            Set(snapshot.resetCards.map(\.id)).count == snapshot.resetCards.count,
            snapshot.resetCards.allSatisfy({
                Self.exportReference($0.id) && Self.date($0.expiresAt).map({ $0 > now }) == true
            }),
            snapshot.availableResetCredits.map({ (0...1_000_000).contains($0) && $0 >= snapshot.resetCards.count }) ?? true,
            snapshot.status != .failed || (snapshot.availableResetCredits == nil && snapshot.resetCards.isEmpty)
        else { throw Failure.invalidSnapshot }
        let bytes = try JSONEncoder().encode(snapshot)
        guard bytes.count <= Self.maximumBodyBytes else { throw Failure.invalidSnapshot }
        let result = try await send(path: "/v1/desktop/snapshots", body: bytes)
        switch result {
        case .accepted(let bytes):
            guard let acknowledgement = try? JSONDecoder().decode(Acknowledgement.self, from: bytes),
                acknowledgement.accepted, (0...10_000).contains(acknowledgement.eventCount)
            else { return .unconfirmed(.invalidResponse) }
            return .accepted(acknowledgement)
        case .rejected(let code): return .rejected(statusCode: code)
        case .unconfirmed(let reason): return .unconfirmed(reason)
        }
    }

    private func send(path: String, body: Data) async throws -> Outcome<Data> {
        guard !Task.isCancelled else { throw Failure.cancelled }
        guard let configuration else { throw Failure.notConfigured }
        guard !inFlight else { throw Failure.busy }
        let admittedGeneration = generation
        guard let url = URL(string: path, relativeTo: configuration.endpoint)?.absoluteURL else { throw Failure.invalidConfiguration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
        inFlight = true
        defer { inFlight = false }
        let response: HTTPResponse
        do { response = try await transport(request) } catch { return .unconfirmed(.transport) }
        guard generation == admittedGeneration else { return .unconfirmed(.configurationChanged) }
        guard !Task.isCancelled else { return .unconfirmed(.cancelled) }
        guard response.url == url, response.body.count <= Self.maximumBodyBytes else { return .unconfirmed(.invalidResponse) }
        if response.statusCode == 200 { return .accepted(response.body) }
        if [400, 401, 403, 404, 409, 413, 429].contains(response.statusCode) { return .rejected(statusCode: response.statusCode) }
        return .unconfirmed(response.statusCode >= 500 ? .serverError : .invalidResponse)
    }

    /// Match this desktop exporter's opaque SHA-256 letter encoding, not a raw
    /// account/card identifier. V1 is wider, but this adapter only sends our DTO.
    private static func exportReference(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x61...0x70).contains($0) }
    }

    private static func date(_ value: String) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|([+-])(\d{2}):(\d{2}))$"#
        guard value.utf8.count <= 35,
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else { return nil }
        func number(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
        guard let year = number(1), (2000...9999).contains(year), let month = number(2), let day = number(3),
            let hour = number(4), (0...23).contains(hour), let minute = number(5), (0...59).contains(minute),
            let second = number(6), (0...59).contains(second)
        else { return nil }
        if let offsetHour = number(10) {
            guard let offsetMinute = number(11), (0...14).contains(offsetHour), (0...59).contains(offsetMinute),
                offsetHour < 14 || offsetMinute == 0
            else { return nil }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let canonical = calendar.date(from: parts),
            calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: canonical) == parts
        else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }

    static func liveTransport(_ request: URLRequest) async throws -> HTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse, let url = response.url,
            response.expectedContentLength <= Int64(maximumBodyBytes)
        else { throw URLError(.cannotParseResponse) }
        var body = Data()
        for try await byte in stream {
            guard body.count < maximumBodyBytes else { throw URLError(.dataLengthExceedsMaximum) }
            body.append(byte)
        }
        return HTTPResponse(statusCode: response.statusCode, body: body, url: url)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
