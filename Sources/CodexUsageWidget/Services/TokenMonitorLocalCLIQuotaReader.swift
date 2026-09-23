import CryptoKit
import Darwin
import Foundation

/// API-only, selected local profile observation. A local ID is not a remote identity.
struct TokenMonitorLocalCLIQuotaReader: Sendable {
    typealias Collector = @Sendable (TokenMonitorRequest, TokenMonitorCancellation) throws -> TokenMonitorResponse
    static let sourceLabel = "token-monitor ef079b6 OpenCode Go"
    enum Reason: String, Sendable {
        case authMissing = "auth_missing"
        case providerMissing = "provider_missing"
        case malformedBundle = "malformed_bundle"
        case ambiguousJSON = "ambiguous_json"
        case invalidAuthFile = "invalid_auth_file"
        case authChanged = "auth_changed"
        case targetChanged = "target_changed"
        case identityMismatch = "identity_mismatch"
        case invalidResponse = "invalid_response"
        case bodyLimit = "body_limit"
        case timeout, unavailable
        case transportFailed = "transport_failed"
        case collectionFailed = "collection_failed"
        case networkDisabled = "network_disabled"
        case endpointRejected = "endpoint_rejected"
        case redirectRejected = "redirect_rejected"
    }
    enum Failure: Error {
        case unavailable(Reason)
        case rejected(Reason)
    }
    private let collector: Collector

    init(
        collector: @escaping Collector = { request, cancellation in
            try TokenMonitorEngine().collect(request: request, cancellation: cancellation)
        }
    ) {
        self.collector = collector
    }

    func load(profile: LocalCLIProfile, now: Date) async throws -> LocalCLIQuotaResult {
        try Task.checkCancellation()
        let cancellation = TokenMonitorCancellation()
        return try await withTaskCancellationHandler {
            let value: LocalCLIQuotaResult = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        guard !cancellation.isCancelled else { throw TokenMonitorFailure.cancelled }
                        guard profile.kind == .openCode else { throw TokenMonitorFailure.invalidSource }
                        let before = try Self.generation(profile: profile)
                        let cache = FileManager.default.temporaryDirectory
                            .appendingPathComponent("codex-usage-next-opencode-" + UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        defer { try? FileManager.default.removeItem(at: cache) }
                        let source = TokenMonitorSource(
                            id: profile.id, providerId: "opencode", kind: .managedAccount,
                            canonicalPath: profile.configDirectory, pathRole: .configDirectory,
                            accountId: profile.id, toolId: "openCode")
                        let request = try TokenMonitorRequest(
                            operation: .collectLimits, now: ISO8601DateFormatter().string(from: now),
                            timezone: TimeZone.current.identifier, cacheDirectory: cache.path, sources: [source]
                        ).validated()
                        let response = try collector(request, cancellation)
                        guard !cancellation.isCancelled else { throw TokenMonitorFailure.cancelled }
                        let after: String
                        do { after = try Self.generation(profile: profile) } catch { throw Failure.rejected(.authChanged) }
                        guard before == after else { throw Failure.rejected(.authChanged) }
                        // Apply normal response validation to injected collectors as well.
                        let checked = try TokenMonitorResponse.decode(JSONEncoder().encode(response), request: request)
                        continuation.resume(returning: try Self.map(checked, sourceID: profile.id, accountID: profile.id, now: now))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func generation(profile: LocalCLIProfile) throws -> String {
        let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let file = directory.appendingPathComponent("auth.json")
        guard file.resolvingSymlinksInPath().standardizedFileURL == file else { throw Failure.rejected(.invalidAuthFile) }
        do {
            func signature(_ url: URL) throws -> String {
                var value = stat()
                guard lstat(url.path, &value) == 0 else { throw Failure.unavailable(.authMissing) }
                return
                    "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
            }
            let directoryBefore = try signature(directory)
            let before = try signature(file)
            guard let bytes = try DispatchParticipationSync.readBoundedRegularFile(file, maximumBytes: 1_048_576, allowMissing: true) else {
                throw Failure.unavailable(.authMissing)
            }
            let after = try signature(file)
            guard before == after, directoryBefore == (try signature(directory)) else { throw Failure.rejected(.authChanged) }
            return directory.path + ":" + directoryBefore + ":" + after + ":" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.rejected(.invalidAuthFile)
        }
    }

    static func map(_ response: TokenMonitorResponse, sourceID: String, accountID: String, now: Date) throws -> LocalCLIQuotaResult {
        // The pinned bridge omits operation. The response decoder already binds
        // it to the request; reject an explicitly different operation here too.
        guard response.status != .error, response.operation == nil || response.operation == .collectLimits,
            response.sources.count == 1, response.sources[0].id == sourceID, response.sources[0].providerId == "opencode",
            response.sources[0].status == .ok || response.sources[0].status == .unavailable,
            let targets = response.payload["limits"]?["targets"]?.array, targets.count == 1,
            let target = targets.first, target["sourceId"]?.string == sourceID,
            target["providerId"]?.string == "opencode", target["accountId"]?.string == accountID,
            let snapshot = target["snapshot"], let providers = snapshot["providers"]?.array, providers.count == 1,
            let provider = providers.first, provider["provider"]?.string == "opencode",
            provider["source"]?.string == sourceLabel, provider["accountIdentity"] == nil,
            provider["credentialFingerprint"] == nil, provider["accountKey"] == nil,
            provider["balanceUsd"] == .null, let status = provider["status"]?.string
        else { throw Failure.rejected(.identityMismatch) }
        var windows: [LocalCLIQuotaWindow] = []
        let state: LocalCLIQuotaState
        switch status {
        case "ok":
            guard response.sources[0].status == .ok, let raw = provider["windows"]?.array, !raw.isEmpty else {
                throw Failure.rejected(.invalidResponse)
            }
            for window in raw {
                guard let kind = window["kind"]?.string, ["session", "weekly", "monthly"].contains(kind),
                    let percent = window["usedPercent"]?.double, percent.isFinite, (0...100).contains(percent)
                else { throw Failure.rejected(.invalidResponse) }
                let reset: Date?
                if let rawReset = window["resetsAt"]?.string, !rawReset.isEmpty {
                    guard let date = TokenMonitorResponse.timestamp(rawReset) else { throw Failure.rejected(.invalidResponse) }
                    reset = date
                } else {
                    guard window["resetsAt"] == nil || window["resetsAt"] == .null || window["resetsAt"] == .string("") else {
                        throw Failure.rejected(.invalidResponse)
                    }
                    reset = nil
                }
                let label = kind == "session" ? "Rolling" : kind == "weekly" ? "Weekly" : "Monthly"
                windows.append(LocalCLIQuotaWindow(id: kind, label: label, usedPercent: percent, resetsAt: reset))
            }
            guard LocalCLIQuotaPresentation.validWindows(windows) else { throw Failure.rejected(.invalidResponse) }
            state = .available
        case "unauthorized": state = .needsLogin
        case "sourceRateLimited": state = .rateLimited
        case "notConfigured":
            guard snapshot["reasonCode"]?.string == "unsupported_go_plan" else { throw Failure.rejected(.invalidResponse) }
            state = .unsupported
        case "unavailable":
            let reason = (snapshot["reasonCode"]?.string).flatMap(Reason.init(rawValue:)) ?? .unavailable
            switch reason {
            case .providerMissing: state = .unsupported
            case .authMissing: state = .needsLogin
            case .authChanged, .targetChanged, .identityMismatch, .invalidAuthFile, .malformedBundle, .ambiguousJSON, .invalidResponse, .bodyLimit, .endpointRejected,
                .redirectRejected:
                throw Failure.rejected(reason)
            default: throw Failure.unavailable(reason)
            }
        default: throw Failure.rejected(.invalidResponse)
        }
        let reason =
            (snapshot["reasonCode"]?.string).flatMap(Reason.init(rawValue:))?.rawValue
            ?? (status == "notConfigured" ? "unsupported_go_plan" : status)
        return LocalCLIQuotaResult(
            state: state, fetchedAt: now, maskedIdentity: nil, identityFingerprint: nil,
            planLabel: nil, windows: windows, balance: nil, balanceCurrency: nil,
            sourceLabel: sourceLabel, messageCode: state == .available ? nil : "local_cli_upstream_" + reason)
    }
}
