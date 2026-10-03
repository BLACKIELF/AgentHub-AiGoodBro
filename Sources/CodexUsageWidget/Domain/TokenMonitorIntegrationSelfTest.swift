import Foundation

@MainActor
enum TokenMonitorIntegrationSelfTest {
    private typealias Expect = @MainActor (Bool, String) -> Void

    static func run() async -> Bool {
        var failures: [String] = []
        let expect: Expect = { condition, message in
            if !condition { failures.append(message) }
        }

        await verifyDisabledStartup(expect: expect)
        await verifyReadAndPublishIsolation(expect: expect)
        await verifyStaleRevisionAndCancellation(expect: expect)
        await verifyStatusRetainsLastGood(expect: expect)
        await verifyTransportRejectsRedirectsAndSanitizesErrors(expect: expect)

        if failures.isEmpty {
            print(
                "token-monitor integration self-test passed: disabled startup, Hub read/publish gates, stale revision, cancellation, retained bilingual status, redirect and error handling"
            )
            return true
        }
        failures.forEach { print("token-monitor integration self-test failed: \($0)") }
        return false
    }

    private static func verifyDisabledStartup(expect: Expect) async {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let credentials = IntegrationCredentialSpy(secret: "fixture-only-secret")
        let transport = IntegrationMockTransport()
        let store = TokenMonitorHubSyncStore(
            defaults: fixture.defaults,
            credentialStore: credentials,
            transport: transport
        )

        expect(!store.isEnabled && !store.isPublishingThisDevice, "Hub sync and publishing default to off")
        expect(credentials.readCount == 0 && transport.requestCount == 0, "ordinary initialization does not read Keychain or contact the network")
        await store.refresh()
        expect(store.connectionState == .disabled, "refresh leaves an opted-out Hub disabled")
        expect(credentials.readCount == 0 && transport.requestCount == 0, "disabled refresh does not read Keychain or contact the network")
    }

    private static func verifyReadAndPublishIsolation(expect: Expect) async {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let credentials = IntegrationCredentialSpy(secret: "fixture-only-secret")
        let transport = IntegrationMockTransport()
        let store = TokenMonitorHubSyncStore(
            defaults: fixture.defaults,
            credentialStore: credentials,
            transport: transport
        )
        do {
            try store.saveConfiguration(serverURL: "https://hub.invalid/base", bearerSecret: "fixture-only-secret")
        } catch {
            expect(false, "fixture Hub configuration can be saved to injected stores")
            return
        }
        store.setEnabled(true)
        expect(store.isEnabled && !store.isPublishingThisDevice, "read access can be enabled independently of publishing")
        store.setPublishingThisDevice(true, confirmed: false)
        expect(!store.isPublishingThisDevice, "publishing requires a separate scope confirmation")
        expect(transport.requestCount == 0, "changing the publishing switch does not itself send a request")

        transport.enqueue(.response(IntegrationMockTransport.response(status: 200, body: Self.stats("device-before"))))
        transport.enqueue(.response(IntegrationMockTransport.response(status: 200, body: Self.history(tokens: 71))))
        await store.refresh()
        expect(store.connectionState == .connected, "enabled read-only sync can refresh Hub data")
        expect(transport.methods == ["GET", "GET"], "read-only sync makes only the two expected GET requests")

        let readsBeforeDisabledPublish = credentials.readCount
        await store.publishThisDevice(Self.uploadFixture(), now: Date(timeIntervalSince1970: 1_790_000_000))
        expect(transport.requestCount == 2, "local usage is not published while the separate publish switch is off")
        expect(credentials.readCount == readsBeforeDisabledPublish, "disabled publishing does not read the Hub secret")

        store.setPublishingThisDevice(true, confirmed: true)
        expect(store.isPublishingThisDevice, "explicit scope confirmation enables publishing")
        transport.enqueue(.response(IntegrationMockTransport.response(status: 204, body: Data())))
        await store.publishThisDevice(Self.uploadFixture(), now: Date(timeIntervalSince1970: 1_790_000_000))
        expect(transport.requestCount == 3 && transport.methods.last == "POST", "confirmed publishing sends one POST")
        expect(transport.paths.compactMap { $0 }.last?.hasSuffix("/api/ingest") == true, "publishing targets the Hub ingest endpoint")
        expect(transport.authorizationHeaders.compactMap { $0 }.last == "Bearer fixture-only-secret", "the Hub secret is sent only as the injected bearer header")
    }

    private static func verifyStaleRevisionAndCancellation(expect: Expect) async {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let credentials = IntegrationCredentialSpy(secret: "fixture-only-secret")
        let transport = IntegrationMockTransport()
        let store = TokenMonitorHubSyncStore(
            defaults: fixture.defaults,
            credentialStore: credentials,
            transport: transport
        )
        do {
            try store.saveConfiguration(serverURL: "https://hub.invalid", bearerSecret: "fixture-only-secret")
        } catch {
            expect(false, "fixture Hub configuration can be saved for revision tests")
            return
        }
        store.setEnabled(true)
        transport.enqueue(.response(IntegrationMockTransport.response(status: 200, body: Self.stats("device-before"))))
        transport.enqueue(.response(IntegrationMockTransport.response(status: 200, body: Self.history(tokens: 71))))
        await store.refresh()
        let oldLastRefresh = store.lastRefresh
        let oldHistory = store.history
        expect(store.connectionState == .connected && store.devices.first?.hostname == "device-before", "revision fixture starts from a successful snapshot")

        let delayedReply = IntegrationHTTPGate()
        transport.enqueue(.gated(delayedReply))
        let staleTask = Task { @MainActor in await store.refresh() }
        let requestStarted = await Self.waitUntil { transport.requestCount == 3 }
        expect(requestStarted, "revision fixture starts a delayed response")
        store.setEnabled(false)
        delayedReply.resume(with: IntegrationMockTransport.response(status: 200, body: Self.stats("device-after")))
        await staleTask.value
        expect(store.connectionState == .disabled && store.devices.first?.hostname == "device-before", "a response from an older configuration cannot replace current Hub state")
        expect(store.history == oldHistory && store.lastRefresh == oldLastRefresh, "stale response leaves last-good history and timestamp untouched")

        store.setEnabled(true)
        let cancelledReply = IntegrationHTTPGate()
        transport.enqueue(.gated(cancelledReply))
        let cancellationTask = Task { @MainActor in await store.refresh() }
        let cancellationStarted = await Self.waitUntil { transport.requestCount == 4 }
        expect(cancellationStarted, "cancellation fixture starts a delayed response")
        cancellationTask.cancel()
        await cancellationTask.value
        expect(store.connectionState == .idle && store.error == nil, "cancelled Hub refresh restores the prior state without reporting a failure")
        expect(store.devices.first?.hostname == "device-before" && store.history == oldHistory, "cancelled Hub refresh retains last-good data")
    }

    private static func verifyStatusRetainsLastGood(expect: Expect) async {
        let checkedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let priorEntry = TokenMonitorServiceStatusEntry(
            id: "claude",
            label: "Claude",
            pageURL: "https://status.claude.com",
            state: .degraded,
            indicator: .minor,
            description: "Synthetic degradation",
            checkedAt: checkedAt,
            updatedAt: checkedAt.addingTimeInterval(-60),
            componentIssues: [.init(name: "Synthetic component", status: "degraded")],
            incidentTitle: "Synthetic incident",
            incidentCount: 1,
            maintenanceCount: 0,
            error: nil,
            isStale: false
        )
        let transport = IntegrationMockTransport()
        transport.enqueue(.failure("Bearer fixture-only-secret"))
        transport.enqueue(.failure("Bearer fixture-only-secret"))
        let store = TokenMonitorServiceStatusStore(
            transport: transport,
            previewEntries: [.claude: priorEntry]
        )

        await store.refresh(force: true, now: checkedAt.addingTimeInterval(300))

        let retained = store.entries[.claude]
        expect(retained?.state == .degraded, "failed status refresh preserves the previous health")
        expect(retained?.description == priorEntry.description && retained?.incidentTitle == priorEntry.incidentTitle, "failed status refresh preserves last-good details")
        expect(retained?.isStale == true && retained?.error != nil, "preserved status is explicitly marked stale")
        expect(store.lastChecked == checkedAt.addingTimeInterval(300), "failed status refresh records its check time")
        let chinese = retained?.localizedError(.zh) ?? ""
        let english = retained?.localizedError(.en) ?? ""
        expect(chinese.contains("上次成功读取") && english.contains("last successful status"), "stale status error is localized in Chinese and English")
        expect(
            store.localizedError(.zh)?.contains("暂时无法读取") == true && store.localizedError(.en)?.contains("temporarily unavailable") == true,
            "aggregate status error is localized in both languages")
        expect(!(retained?.error ?? "").contains("fixture-only-secret"), "status errors do not expose transport details or credentials")
    }

    private static func verifyTransportRejectsRedirectsAndSanitizesErrors(expect: Expect) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [IntegrationStubURLProtocol.self]
        let transport = TokenMonitorURLSessionTransport(configuration: configuration)
        let request = URLRequest(
            url: URL(string: "https://hub.test/api/stats")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 3
        )
        RedirectFixtureState.configure(.redirect)
        do {
            let response = try await transport.send(request, maximumResponseBytes: 4096)
            expect(response.statusCode == 302, "the original redirect response is returned to the caller")
        } catch TokenMonitorHTTPTransportError.transport {
            // URLProtocol's wasRedirectedTo can finish as a sanitized transport
            // failure after the delegate rejects the redirect. Either result
            // is fail-closed; the recorded hosts below prove it was not followed.
        } catch {
            expect(false, "redirect fixture returns 302 or a sanitized transport rejection")
        }
        expect(RedirectFixtureState.requests == ["hub.test"], "bearer-authenticated transport does not follow redirects")

        let secret = "Bearer fixture-only-secret"
        RedirectFixtureState.configure(.failure(secret))
        do {
            _ = try await transport.send(request, maximumResponseBytes: 4096)
            expect(false, "transport error fixture fails")
        } catch {
            expect(error is TokenMonitorHTTPTransportError, "URLSession transport replaces raw errors with a fixed category")
            expect(!String(describing: error).contains(secret), "URLSession transport errors do not echo sensitive details")
        }
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private static func stats(_ hostname: String) -> Data {
        Data(
            #"{"devices":[{"deviceId":"fixture-device","hostname":"\#(hostname)","platform":"macOS","agentVersion":"test","agentRuntime":"fixture","periods":{"today":{"totalTokens":71}}}]}"#
                .utf8)
    }

    private static func history(tokens: Int64) -> Data {
        Data(#"{"daily":[],"monthly":[],"summary":{"totalTokens":\#(tokens)}}"#.utf8)
    }

    private static func uploadFixture() -> TokenMonitorResponse {
        let allTime: TokenMonitorJSON = .object([
            "totalTokens": .number(71),
            "clients": .object(["codex": .number(71)]),
        ])
        return TokenMonitorResponse(
            schemaVersion: 1,
            requestId: "integration-self-test",
            operation: .collectUsage,
            engine: .init(repository: "Javis603/token-monitor", commit: TokenMonitorResponse.commit, version: "fixture"),
            collectedAt: "2026-09-26T00:00:00Z",
            timezone: "UTC",
            status: .ok,
            sources: [],
            payload: .object([
                "aggregate": .object(["allTime": allTime]),
                "history": .object(["daily": .array([]), "monthly": .array([]), "summary": .object([:])]),
            ]),
            coverage: .init(entries: [], days: [], cost: .unknown),
            errors: []
        )
    }
}

private struct DefaultsFixture {
    let suiteName = "com.aigoodbro.token-monitor-test.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class IntegrationCredentialSpy: TokenMonitorHubCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?
    private var reads = 0
    private var saves = 0
    private var clears = 0

    init(secret: String?) {
        self.secret = secret
    }

    var readCount: Int { lock.withLock { reads } }
    var saveCount: Int { lock.withLock { saves } }
    var clearCount: Int { lock.withLock { clears } }

    func read() throws -> String? {
        lock.withLock {
            reads += 1
            return secret
        }
    }

    func save(_ secret: String) throws {
        lock.withLock {
            saves += 1
            self.secret = secret
        }
    }

    func clear() throws {
        lock.withLock {
            clears += 1
            secret = nil
        }
    }
}

private final class IntegrationMockTransport: TokenMonitorHTTPTransport, @unchecked Sendable {
    enum Step {
        case response(TokenMonitorHTTPResponse)
        case failure(String)
        case gated(IntegrationHTTPGate)
    }

    private struct RecordedRequest {
        let method: String?
        let path: String?
        let authorization: String?
    }

    private let lock = NSLock()
    private var steps: [Step] = []
    private var recordedRequests: [RecordedRequest] = []

    var requestCount: Int { lock.withLock { recordedRequests.count } }
    var methods: [String?] { lock.withLock { recordedRequests.map(\.method) } }
    var paths: [String?] { lock.withLock { recordedRequests.map(\.path) } }
    var authorizationHeaders: [String?] { lock.withLock { recordedRequests.map(\.authorization) } }

    func enqueue(_ step: Step) {
        lock.withLock { steps.append(step) }
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> TokenMonitorHTTPResponse {
        let step: Step = lock.withLock {
            recordedRequests.append(
                RecordedRequest(
                    method: request.httpMethod,
                    path: request.url?.path,
                    authorization: request.value(forHTTPHeaderField: "Authorization")
                ))
            return steps.isEmpty ? .failure("Unexpected fixture request") : steps.removeFirst()
        }
        switch step {
        case .response(let response): return response
        case .failure(let detail): throw IntegrationSensitiveFailure(detail: detail)
        case .gated(let gate): return try await gate.wait()
        }
    }

    static func response(status: Int, body: Data) -> TokenMonitorHTTPResponse {
        TokenMonitorHTTPResponse(statusCode: status, body: body)
    }
}

private struct IntegrationSensitiveFailure: Error {
    let detail: String

    var localizedDescription: String { detail }
}

private final class IntegrationHTTPGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TokenMonitorHTTPResponse, Error>?
    private var cancellationRequested = false

    func wait() async throws -> TokenMonitorHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.install(continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    func resume(with response: TokenMonitorHTTPResponse) {
        let continuation = lock.withLock { () -> CheckedContinuation<TokenMonitorHTTPResponse, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: response)
    }

    private func install(_ continuation: CheckedContinuation<TokenMonitorHTTPResponse, Error>) {
        let resumeCancelled = lock.withLock { () -> Bool in
            guard !cancellationRequested else { return true }
            self.continuation = continuation
            return false
        }
        if resumeCancelled { continuation.resume(throwing: CancellationError()) }
    }

    private func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<TokenMonitorHTTPResponse, Error>? in
            cancellationRequested = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class IntegrationStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        ["hub.test", "redirect.invalid"].contains(request.url?.host?.lowercased() ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        RedirectFixtureState.record(url.host?.lowercased() ?? "")
        switch RedirectFixtureState.mode {
        case .redirect where url.host?.lowercased() == "hub.test":
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://redirect.invalid/next"]
            )!
            let redirectedRequest = URLRequest(url: URL(string: "https://redirect.invalid/next")!)
            client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: response)
        case .redirect:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let detail):
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "TokenMonitorIntegrationSelfTest",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: detail]
                ))
        }
    }

    override func stopLoading() {}
}

private enum RedirectFixtureState {
    private static let storage = RedirectFixtureStorage()

    static var mode: RedirectFixtureStorage.Mode { storage.mode }
    static var requests: [String] { storage.requests }

    static func configure(_ mode: RedirectFixtureStorage.Mode) {
        storage.configure(mode)
    }

    static func record(_ host: String) {
        storage.record(host)
    }
}

private final class RedirectFixtureStorage: @unchecked Sendable {
    enum Mode: Sendable {
        case redirect
        case failure(String)
    }

    private let lock = NSLock()
    private var currentMode: Mode = .redirect
    private var hosts: [String] = []

    var mode: Mode { lock.withLock { currentMode } }
    var requests: [String] { lock.withLock { hosts } }

    func configure(_ mode: Mode) {
        lock.withLock {
            currentMode = mode
            hosts.removeAll()
        }
    }

    func record(_ host: String) {
        lock.withLock { hosts.append(host) }
    }
}
