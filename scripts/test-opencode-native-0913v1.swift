import Foundation

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
private struct FakeTransport: LocalCLIQuotaTransport {
    let calls: Calls
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        calls.increment()
        precondition(request.url?.absoluteString == "https://opencode.ai/zen/go/v1/usage")
        return LocalCLIHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{"usage":{"rolling":{"percent":0},"weekly":{"percent":25}}}"#.utf8))
    }
}

@main
struct OpenCodeNativeFixture {
    static func response(_ request: TokenMonitorRequest, account: String? = nil, duplicate: Bool = false, operation: TokenMonitorOperation? = .collectLimits) -> TokenMonitorResponse {
        let source = request.sources[0]
        let row: TokenMonitorJSON = .object([
            "provider": .string("opencode"), "source": .string(TokenMonitorLocalCLIQuotaReader.sourceLabel), "status": .string("ok"), "balanceUsd": .null,
            "windows": .array([
                .object(["kind": .string("session"), "usedPercent": .number(0), "resetsAt": .string("")]), .object(["kind": .string("weekly"), "usedPercent": .number(25)]),
            ]),
        ])
        let target: TokenMonitorJSON = .object([
            "sourceId": .string(source.id), "providerId": .string("opencode"), "accountId": .string(account ?? source.accountId!),
            "snapshot": .object(["providers": .array([row]), "reasonCode": .string("ok")]),
        ])
        return TokenMonitorResponse(
            schemaVersion: 1, requestId: request.requestId, operation: operation,
            engine: .init(repository: "Javis603/token-monitor", commit: TokenMonitorResponse.commit, version: "1"),
            collectedAt: request.now, timezone: request.timezone, status: .ok,
            sources: [.init(id: source.id, providerId: "opencode", status: .ok, coverage: .known)],
            payload: .object(["limits": .object(["targets": .array(duplicate ? [target, target] : [target])])]),
            coverage: .init(entries: [], days: [], cost: .unknown), errors: [])
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-next-opencode-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = Data(#"{"opencode-go":{"type":"api","key":"synthetic-only"}}"#.utf8)
        let file = directory.appendingPathComponent("auth.json")
        try auth.write(to: file)
        let profile = LocalCLIProfile(id: "selected", kind: .openCode, displayName: "Synthetic", configDirectory: directory.path, isDefault: false)
        let now = Date(timeIntervalSince1970: 1_789_257_600)
        let engineCalls = Calls()
        let reader = TokenMonitorLocalCLIQuotaReader(collector: { request, _ in
            engineCalls.increment()
            precondition(!Thread.isMainThread)
            precondition(request.sources[0].canonicalPath == directory.resolvingSymlinksInPath().path)
            precondition(request.sources[0].accountId == "selected")
            precondition(!request.options.allowCredentialRefresh && !request.options.allowSelfSync)
            return response(request)
        })
        let mapped = try await reader.load(profile: profile, now: now)
        precondition(mapped.state == .available && mapped.windows[0].usedPercent == 0 && mapped.windows[0].label == "Rolling")
        precondition(mapped.identityFingerprint == nil && mapped.maskedIdentity == nil && mapped.balance == nil)
        precondition(engineCalls.value == 1)
        // The actual pinned Node bridge omits operation, unlike the older mock.
        let bridgeShape = TokenMonitorLocalCLIQuotaReader(collector: { request, _ in response(request, operation: nil) })
        let bridgeValue = try await bridgeShape.load(profile: profile, now: now)
        precondition(bridgeValue.windows == mapped.windows)
        let wrongOperation = TokenMonitorLocalCLIQuotaReader(collector: { request, _ in response(request, operation: .collectUsage) })
        do {
            _ = try await wrongOperation.load(profile: profile, now: now)
            preconditionFailure("wrong response operation accepted")
        } catch TokenMonitorFailure.requestMismatch {}
        for duplicate in [false, true] {
            let mismatch = TokenMonitorLocalCLIQuotaReader(collector: { request, _ in response(request, account: duplicate ? nil : "other", duplicate: duplicate) })
            do {
                _ = try await mismatch.load(profile: profile, now: now)
                preconditionFailure("binding accepted")
            } catch TokenMonitorLocalCLIQuotaReader.Failure.rejected {}
        }
        for remove in [false, true] {
            let rotated = TokenMonitorLocalCLIQuotaReader(collector: { request, _ in
                if remove { try FileManager.default.removeItem(at: file) } else { try Data(#"{"opencode-go":{"type":"api","key":"rotated-synthetic"}}"#.utf8).write(to: file) }
                return response(request)
            })
            do {
                _ = try await rotated.load(profile: profile, now: now)
                preconditionFailure("rotated accepted")
            } catch TokenMonitorLocalCLIQuotaReader.Failure.rejected {}
            try auth.write(to: file)
        }
        let transportCalls = Calls()
        let files: LocalCLIQuotaReader.FileReader = { _, _, _ in auth }
        let native = LocalCLIQuotaReader(transport: FakeTransport(calls: transportCalls), fileReader: files, claudeKeychainReader: { nil })
        let old = await native.load(profile: profile, now: now)
        precondition(old.state == .available && old.sourceLabel == "OpenCode Go API" && transportCalls.value == 1)
        // All historical initializer labels remain accepted; injected readers do not select production engine.
        _ = LocalCLIQuotaReader()
        _ = LocalCLIQuotaReader(fileReader: files)
        _ = LocalCLIQuotaReader(claudeKeychainReader: { nil })
        _ = LocalCLIQuotaReader(transport: FakeTransport(calls: transportCalls))
        let fallback = LocalCLIQuotaReader(
            transport: FakeTransport(calls: transportCalls), fileReader: files,
            upstreamReader: { _, _ in throw TokenMonitorFailure.missingBundle })
        let recovered = await fallback.load(profile: profile, now: now)
        precondition(recovered.windows == old.windows && recovered.sourceLabel == "OpenCode Go native fallback (missing_bundle)")
        let count = transportCalls.value
        for failure in [TokenMonitorFailure.cancelled, .requestMismatch, .invalidResponse] {
            let blocked = LocalCLIQuotaReader(transport: FakeTransport(calls: transportCalls), fileReader: files, upstreamReader: { _, _ in throw failure })
            let value = await blocked.load(profile: profile, now: now)
            precondition(value.state == .unavailable && transportCalls.value == count)
        }
        let gate = Calls()
        let cancellationReader = TokenMonitorLocalCLIQuotaReader(collector: { request, cancellation in
            gate.increment()
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
            throw TokenMonitorFailure.cancelled
        })
        let task = Task { try await cancellationReader.load(profile: profile, now: now) }
        while gate.value == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("cancelled accepted")
        } catch {}
        let source = TokenMonitorSource(
            id: profile.id, providerId: "opencode", kind: .managedAccount, canonicalPath: directory.path, pathRole: .configDirectory, accountId: profile.id)
        for operation in [TokenMonitorOperation.collectUsage, .capabilities] {
            do {
                _ = try TokenMonitorSource.validated([source], operation: operation)
                preconditionFailure("wrong operation accepted")
            } catch TokenMonitorFailure.invalidSource {}
        }
        if CommandLine.arguments.count == 2 {
            // Exercise the shipped JS -> JSON -> Swift boundary, without a Go
            // credential or any provider network call. Synthetic Zen-only auth
            // must map to a precise unsupported-Go result, not identityMismatch.
            let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let engine = TokenMonitorEngine(fixture: .init(
                executable: resources.appendingPathComponent("runtime/node"),
                bridge: resources.appendingPathComponent("bridge.cjs")))
            try Data(#"{"opencode":{"type":"api","key":"synthetic-zen-only"}}"#.utf8).write(to: file)
            let packaged = TokenMonitorLocalCLIQuotaReader(collector: { request, cancellation in
                let decoded = try engine.collect(request: request, cancellation: cancellation)
                precondition(decoded.operation == nil)
                return decoded
            })
            let unsupported = try await packaged.load(profile: profile, now: now)
            precondition(unsupported.state == .unsupported && unsupported.messageCode == "local_cli_upstream_provider_missing")
            print("PASS packaged Node bridge -> Swift decoder -> quota mapper (synthetic Zen-only, no network)")
        }
        print("PASS compiled Swift synthetic: exact mapping, nil identity/balance, background collection, rotation/deletion, native injection/fallback, cancellation, role")
    }
}
