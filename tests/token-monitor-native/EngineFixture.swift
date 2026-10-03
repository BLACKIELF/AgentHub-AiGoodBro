import Darwin
import Foundation

@main struct EngineFixture {
    static func main() {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            do {
                try run()
                print("PASS all native engine fixtures")
            } catch {
                print("FAIL fixture \((error as? TokenMonitorFailure)?.rawValue ?? "assertion")")
                exit(1)
            }
            group.leave()
        }
        group.wait()
    }
    static func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else {
            print("FAIL " + name)
            throw TokenMonitorFailure.invalidResponse
        }
        print("PASS " + name)
    }
    static func rejects(_ name: String, _ work: () throws -> Void) throws {
        do { try work() } catch {
            print("PASS " + name)
            return
        }
        throw TokenMonitorFailure.invalidResponse
    }
    static func run() throws {
        try TokenMonitorJSON.object(["history": .object(["messages": .number(42)])]).validate()
        print("PASS original history numeric message count survives privacy validation")
        for value: TokenMonitorJSON in [.string("synthetic body"), .array([.string("synthetic body")]), .number(-1), .number(Decimal(string: "0.5")!)] {
            try rejects("non-count messages payload remains rejected") { try TokenMonitorJSON.object(["messages": value]).validate() }
        }
        try check(TokenMonitorQuotaRoute.select(refreshingMembership: true, choice: .upstream) == .membershipRPC, "membership bypasses engine")
        try check(TokenMonitorQuotaRoute.select(refreshingMembership: false, choice: .upstream) == .engine, "ordinary quota uses engine")
        let suite = "fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let oldRecords = Data("[{\"name\":\"fixture-custom\",\"tokens\":123}]".utf8)
        defaults.setVolatileDomain([CustomTokenSourceStore.storageKey: oldRecords], forName: UserDefaults.argumentDomain)
        try check(CustomTokenSourceStore.load(defaults: defaults).first?.tokens == 123, "old custom records decode")
        try check(defaults.data(forKey: CustomTokenSourceStore.storageKey) == oldRecords, "old custom bytes untouched")
        var generation = TokenMonitorGeneration()
        let first = generation.value
        generation.invalidate()
        try check(!generation.accepts(first) && generation.accepts(generation.value), "superseded completion rejected")
        let second = generation.value
        generation.invalidate()
        try check(!generation.accepts(second), "stop invalidates completion")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = [
            TokenMonitorSource(
                id: "card-a", providerId: "codex", kind: .managedAccount, canonicalPath: root.appendingPathComponent("a").path, pathRole: .codexHome, accountId: "card-a",
                toolId: "codex"),
            TokenMonitorSource(
                id: "card-b", providerId: "codex", kind: .managedAccount, canonicalPath: root.appendingPathComponent("b").path, pathRole: .codexHome, accountId: "card-b",
                toolId: "codex"),
            TokenMonitorSource(id: "grok", providerId: "grok", kind: .agentLogs, canonicalPath: root.appendingPathComponent("grok").path, pathRole: .logRoot, toolId: "grok"),
        ]
        var request = TokenMonitorRequest(operation: .collectUsage, timezone: "UTC", cacheDirectory: root.path, sources: sources)
        request.requestId = "fixture-request"
        var slowRequest = request
        slowRequest.options.timeoutMs = 180_000
        try check((try? slowRequest.validated()) != nil, "collectUsage accepts 180-second total deadline")
        slowRequest.options.timeoutMs = 180_001
        try rejects("collectUsage rejects deadline above 180 seconds") { _ = try slowRequest.validated() }
        for operation: TokenMonitorOperation in [.collectLimits, .capabilities] {
            slowRequest.operation = operation
            slowRequest.options.timeoutMs = 60_000
            try check((try? slowRequest.validated()) != nil, "non-usage operation accepts 60-second deadline")
            slowRequest.options.timeoutMs = 60_001
            try rejects("non-usage operation rejects deadline above 60 seconds") { _ = try slowRequest.validated() }
        }
        var response = TokenMonitorResponse(
            schemaVersion: 1, requestId: request.requestId, engine: .init(repository: "Javis603/token-monitor", commit: TokenMonitorResponse.commit, version: "fixture-1"),
            collectedAt: "2026-09-13T00:00:00.000Z", timezone: "UTC", status: .partial,
            sources: sources.map { .init(id: $0.id, providerId: $0.providerId, status: $0.id == "card-b" ? .unavailable : .ok, coverage: $0.id == "card-b" ? .unknown : .known) },
            payload: .object([
                "usage": .object([
                    "tools": .array([.string("codex"), .string("grok")]), "accounts": .array([.string("card-a"), .string("card-b")]),
                    "models": .object(["LongCat/任意新模型": .number(9_223_372_036_854_775_807)]),
                    "sessions": .array([.object(["workspace": .string("opaque-workspace"), "futureField": .bool(true)])]),
                ]), "history": .array([]), "aggregate": .object(["tokens": .number(0), "cost": .null]),
            ]),
            coverage: .init(
                entries: [.init(sourceId: "card-a", providerId: "codex", accountId: "card-a", date: "2026-09-13", metric: "tokens", status: .known)],
                days: [.init(date: "2026-09-13", status: .known)], cost: .unknown), errors: [])
        func encoded(_ value: TokenMonitorResponse) throws -> Data { try JSONEncoder().encode(value) }
        let decoded = try TokenMonitorResponse.decode(encoded(response), request: request)
        try check(decoded.payload == response.payload, "recursive roundtrip 2 tools 2 accounts arbitrary model Int64 unknown fields")
        try check(decoded.metricCoverage(sourceIDs: ["card-a", "card-b"], date: "2026-09-13", metric: "tokens") == .partial, "real zero plus unavailable is partial")
        try check(
            decoded.metricCoverage(sourceIDs: ["card-a"], date: "2026-09-12", metric: "tokens") == .unknown && decoded.coverage.days[0].status != .known,
            "missing coverage unknown and dishonest day downgraded")
        for mode in ["schema", "request", "commit", "operation"] {
            var bad = response
            switch mode {
            case "schema": bad.schemaVersion = 2
            case "request": bad.requestId = "wrong"
            case "commit": bad.engine.commit = "wrong"
            default: bad.operation = .collectLimits
            }
            try rejects("mismatched " + mode) { _ = try TokenMonitorResponse.decode(encoded(bad), request: request) }
        }
        for payload: TokenMonitorJSON in [.object(["prompt": .string("synthetic")]), .object(["tokens": .number(-1)]), .object(["path": .string("synthetic")])] {
            try rejects("forbidden payload or negative number") { try payload.validate() }
        }
        var badSource = sources[0]
        badSource.pathRole = .customFile
        try rejects("managedAccount invalid pathRole") { _ = try TokenMonitorSource.validated([badSource]) }
        badSource = sources[0]
        badSource.canonicalPath += "/auth.json"
        try rejects("auth file is not codex home") { _ = try TokenMonitorSource.validated([badSource]) }
        badSource = sources[1]
        badSource.canonicalPath = sources[0].canonicalPath + "/child"
        let forwardedParent = try TokenMonitorSource.validated([sources[0], badSource])
        try check(forwardedParent.count == 2, "shape-only host forwards overlap for provider-aware engine classification")
        try FileManager.default.createDirectory(atPath: sources[0].canonicalPath, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: sources[0].canonicalPath)
        badSource.canonicalPath = alias.path
        let forwardedAliases = try TokenMonitorSource.validated([sources[0], badSource])
        try check(forwardedAliases.count == 2 && forwardedAliases[0].canonicalPath == forwardedAliases[1].canonicalPath, "canonical alias evidence retained for engine dedup")
        let sharedHome = [
            TokenMonitorSource(id: "tool-codex", providerId: "codex", kind: .agentLogs, canonicalPath: root.path, pathRole: .userHome),
            TokenMonitorSource(id: "tool-claude", providerId: "claude", kind: .agentLogs, canonicalPath: root.path, pathRole: .userHome),
        ]
        let validatedHome = try TokenMonitorSource.validated(sharedHome)
        try check(validatedHome.count == 2, "two providers in approved shared userHome survive host validation")
        try TokenMonitorJSON.object(["models": .object(["longcat@meituan": .number(3), "openai/gpt-public": .number(4)])]).validate()
        print("PASS public model at-sign and provider slash retained")
        try rejects("email-shaped private string rejected") { try TokenMonitorJSON.string("person@example.invalid").validate() }
        try rejects("credential-shaped string rejected") { try TokenMonitorJSON.string("sk-" + String(repeating: "a", count: 20)).validate() }
        try rejects("private email field still rejected") { try TokenMonitorJSON.object(["email": .null]).validate() }
        var customRequest = request
        customRequest.sources.append(
            .init(
                id: "custom", providerId: "codex", kind: .custom, canonicalPath: root.appendingPathComponent("custom-input").path, pathRole: .customFile, toolId: "codex",
                authority: .custom))
        customRequest.customSources = [
            .init(sourceId: "custom", providerId: "codex", toolId: "codex", period: "allTime", tokens: 1, coverage: .known, provenance: "legacy", overlapsSourceIds: ["card-a"])
        ]
        try rejects("custom same-source exclusion") { _ = try customRequest.validated() }
        customRequest.sources = [customRequest.sources.last!]
        _ = try customRequest.validated()
        print("PASS explicit custom exclusive request retained")
        let provider: TokenMonitorJSON = .object([
            "provider": .string("codex"), "sourceId": .string("card-a"), "accountId": .string("card-a"), "status": .string("ok"), "credits": .object(["unlimited": .bool(true)]),
            "windows": .array([.object(["limitId": .string("codex"), "remainingPercent": .number(75), "windowMinutes": .number(10080), "resetsAt": .number(1_783_388_799)])]),
        ])
        let target: TokenMonitorJSON = .object([
            "sourceId": .string("card-a"), "providerId": .string("codex"), "accountId": .string("card-a"), "snapshot": .object(["providers": .array([provider])]),
        ])
        if case .object(var payload) = response.payload {
            payload["limits"] = .object(["targets": .array([target])])
            response.payload = .object(payload)
        }
        let limits = try TokenMonitorCodexLimits(provider: provider, sourceID: "card-a", accountID: "card-a", response: response)
        try check(limits.fiveHour == nil && limits.sevenDay?.usedPercent == 25, "real 7d missing 5h credits unlimited isolated")
        var auxiliary = CodexUsageReader.AppServerSnapshot()
        auxiliary.quotaReadSucceeded = true
        auxiliary.membershipRefreshSucceeded = true
        auxiliary.credits = CreditsInfo(
            hasCredits: true, unlimited: true, balance: "42", resetCredits: 2,
            resetCreditDetails: [ResetCreditDetail(id: "synthetic-card", expiresAt: nil)])
        auxiliary.cloudLifetimeTokens = 123
        let merged = auxiliary.replacingEngineQuota(limits, response: response)
        try check(merged.credits == auxiliary.credits && merged.cloudLifetimeTokens == 123, "native auxiliary cards balance cloud usage preserved")
        try check(!merged.membershipRefreshSucceeded && merged.fiveHourQuota == nil && merged.sevenDayQuota?.usedPercent == 25, "quota success never claims membership refresh")
        var limitsRequest = request
        limitsRequest.operation = .collectLimits
        var limitsResponse = response
        limitsResponse.payload = .object(["limits": .object(["providers": .array([provider])])])
        let limitsRoundtrip = try TokenMonitorResponse.decode(encoded(limitsResponse), request: limitsRequest)
        try check(limitsRoundtrip.payload == limitsResponse.payload, "collectLimits full envelope retained")
        var wrongLimitsResponse = limitsResponse
        wrongLimitsResponse.sources[0].id = "wrong-source"
        try rejects("collectLimits response wrong source rejected") { _ = try TokenMonitorResponse.decode(encoded(wrongLimitsResponse), request: limitsRequest) }
        try rejects("wrong limits source") { _ = try TokenMonitorCodexLimits(provider: provider, sourceID: "card-b", accountID: "card-b", response: response) }
        try rejects("wrong limits identity") { _ = try TokenMonitorCodexLimits(provider: provider, sourceID: "card-a", accountID: "card-b", response: response) }
        try check(
            TokenMonitorQuotaRoute.select(refreshingMembership: false, choice: .custom) == .engine
                && TokenMonitorQuotaRoute.select(refreshingMembership: false, choice: .nativeLegacy) == .engine,
            "statistics selection never changes ordinary managed quota route")
        var unattributed = sources[0]
        unattributed.accountId = nil
        let historyManifest = try TokenMonitorSource.validated([unattributed])
        try check(
            historyManifest[0].accountId == nil,
            "registered history needs no current login or account attribution")
        var oneRequest = request
        oneRequest.sources = [sources[0]]
        var oneResponse = response
        oneResponse.sources = [response.sources[0]]
        oneResponse.status = .ok
        let one = try TokenMonitorResponse.decode(encoded(oneResponse), request: oneRequest)
        try check(
            one.coverage.days[0].status == .known && one.coverage.cost == .unknown && one.status == .partial,
            "real decode known tokens unknown cost independent")
        oneResponse.coverage.days[0].status = .unknown
        let correctedDay = try TokenMonitorResponse.decode(encoded(oneResponse), request: oneRequest)
        try check(
            correctedDay.coverage.days[0].status == .known && correctedDay.coverage.cost == .unknown,
            "authoritative token rows determine compatibility day independently of supplied cost downgrade")
        var noProof = customRequest
        noProof.sources.append(sources[0])
        noProof.customSources?[0].overlapsSourceIds = []
        try rejects("empty legacy overlap list is not independence proof") { _ = try noProof.validated() }
        var pairRequest = request
        pairRequest.sources = Array(sources.prefix(2))
        var excluded = response
        excluded.sources = Array(response.sources.prefix(2))
        excluded.status = .ok
        excluded.sources[1].status = .excluded
        excluded.coverage.entries.append(.init(sourceId: "card-a", providerId: "codex", accountId: "card-a", date: "2026-09-13", metric: "cost", status: .known))
        excluded.coverage.entries.append(.init(sourceId: "card-b", providerId: "codex", accountId: "card-b", date: "2026-09-12", metric: "cost", status: .unknown))
        excluded.payload = .object(["usage": response.payload["usage"]!, "history": .array([]), "aggregate": .object(["tokens": .number(17), "cost": .number(2)])])
        let excludedDecoded = try TokenMonitorResponse.decode(encoded(excluded), request: pairRequest)
        try check(
            excludedDecoded.metricCoverage(sourceIDs: ["card-a", "card-b"], date: "2026-09-13", metric: "tokens") == .known
                && excludedDecoded.coverage.days[0].status == .known && excludedDecoded.coverage.cost == .known && excludedDecoded.status == .ok,
            "known A plus trusted duplicate excluded B has known tokens cost and status")
        try check(
            excludedDecoded.payload == excluded.payload && excludedDecoded.coverage.entries.count == excluded.coverage.entries.count
                && excludedDecoded.sources[1].status == .excluded,
            "excluded source and entries visible full dimensions and totals unchanged no duplicate summation")
        try check(
            excludedDecoded.metricCoverage(sourceIDs: ["card-b"], date: "2026-09-13", metric: "tokens") == .unknown
                && excludedDecoded.metricCoverage(sourceIDs: [], date: "2026-09-13", metric: "tokens") == .unknown,
            "explicit excluded-only and empty denominators unknown")
        var unavailable = excluded
        unavailable.sources[1].status = .unavailable
        let unavailableDecoded = try TokenMonitorResponse.decode(encoded(unavailable), request: pairRequest)
        try check(
            unavailableDecoded.coverage.days[0].status == .partial && unavailableDecoded.coverage.cost == .unknown && unavailableDecoded.status == .partial,
            "known A plus still unavailable B remains partial tokens unknown cost")
        unavailable.sources[1].status = .error
        let errorDecoded = try TokenMonitorResponse.decode(encoded(unavailable), request: pairRequest)
        try check(errorDecoded.coverage.days[0].status == .partial && errorDecoded.status == .partial, "error B remains partial")
        unavailable.sources[1].status = .ok
        unavailable.sources[1].coverage = .known
        let missingDecoded = try TokenMonitorResponse.decode(encoded(unavailable), request: pairRequest)
        try check(
            missingDecoded.coverage.days[0].status == .partial && missingDecoded.coverage.cost == .unknown,
            "ok B missing metric records remains partial unknown cost")
        var unknownCost = excluded
        unknownCost.coverage.entries.removeAll { $0.metric == "cost" }
        let independent = try TokenMonitorResponse.decode(encoded(unknownCost), request: pairRequest)
        try check(
            independent.coverage.days[0].status == .known && independent.coverage.cost == .unknown && independent.status == .partial,
            "excluded B does not couple known tokens to missing cost")
        var allExcluded = excluded
        allExcluded.sources[0].status = .excluded
        let empty = try TokenMonitorResponse.decode(encoded(allExcluded), request: pairRequest)
        try check(
            empty.coverage.days[0].status == .unknown && empty.coverage.cost == .unknown && empty.status == .partial,
            "all excluded remains unknown never known zero")
        var missingSource = excluded
        missingSource.sources.removeLast()
        try rejects("missing response source still rejected by binding") { _ = try TokenMonitorResponse.decode(encoded(missingSource), request: pairRequest) }
        for count in [64, 65, 256, 257] {
            var boundary = request
            boundary.sources = (0..<count).map { index in
                TokenMonitorSource(
                    id: "opaque-\(index)", providerId: "codex", kind: .managedAccount,
                    canonicalPath: root.appendingPathComponent("opaque-\(index)").path, pathRole: .codexHome)
            }
            if count == 257 {
                try rejects("Swift request rejects exact 257 sources") { _ = try boundary.validated() }
            } else {
                let validated = try boundary.validated()
                try check(validated.sources.count == count, "Swift request accepts exact \(count) sources")
            }
        }
        let state = TokenMonitorEngineState(phase: .ready, lastGood: decoded)
        let dashboard = try JSONDecoder().decode(TokenMonitorResponse.self, from: Data(state.dashboardJSON!.utf8))
        try check(
            dashboard.payload == decoded.payload && dashboard.schemaVersion == decoded.schemaVersion
                && dashboard.coverage.entries.count == decoded.coverage.entries.count,
            "dashboard full envelope two tools two accounts arbitrary dimensions Int64 unchanged")
        try check(TokenMonitorEngineState().dashboardJSON == nil, "no lastGood no synthetic dashboard")
        var stale = state
        stale.phase = .failed
        try check(stale.isStale && stale.dashboardJSON == state.dashboardJSON, "dashboard cache never changes freshness phase")
        func boundResponse(_ targets: [TokenMonitorJSON]) -> TokenMonitorResponse {
            var value = response
            value.payload = .object(["limits": .object(["targets": .array(targets)])])
            return value
        }
        try check(
            TokenMonitorCodexLimits.select(boundResponse([target]), sourceID: "card-a") == provider,
            "default selector accepts uniquely bound upstream summary")
        try check(
            TokenMonitorCodexLimits.select(boundResponse([target, target]), sourceID: "card-a") == nil,
            "duplicate target unavailable")
        var other: [String: TokenMonitorJSON] = [
            "sourceId": .string("card-b"), "providerId": .string("codex"), "accountId": .string("card-b"), "snapshot": .object(["providers": .array([provider])]),
        ]
        try check(
            TokenMonitorCodexLimits.select(boundResponse([.object(other), target]), sourceID: "card-a") == provider,
            "multiple targets select exact source never first")
        other["sourceId"] = .string("card-a")
        try check(
            TokenMonitorCodexLimits.select(boundResponse([.object(other)]), sourceID: "card-a") == nil,
            "mismatched opaque account unavailable")
        try check(
            TokenMonitorCodexLimits.select(limitsResponse, sourceID: "card-a") == nil,
            "absent target cannot relabel unbound summary")
        other["accountId"] = .string("card-a")
        other["snapshot"] = .object(["providers": .array([provider, provider])])
        try check(
            TokenMonitorCodexLimits.select(boundResponse([.object(other)]), sourceID: "card-a") == nil,
            "duplicate Codex provider unavailable")
        func mapProvider(_ value: TokenMonitorJSON) throws -> TokenMonitorCodexLimits {
            let binding: TokenMonitorJSON = .object([
                "sourceId": .string("card-a"), "providerId": .string("codex"), "accountId": .string("card-a"), "snapshot": .object(["providers": .array([value])]),
            ])
            return try TokenMonitorCodexLimits(provider: value, sourceID: "card-a", accountID: "card-a", response: boundResponse([binding]))
        }
        if case .object(var value) = provider {
            let normal: TokenMonitorJSON = .object([
                "kind": .string("session"), "limitId": .string("codex"), "windowMinutes": .number(300), "usedPercent": .number(0), "additional": .bool(false),
                "resetsAt": .string("2026-09-13T05:00:00Z"),
            ])
            let extra: TokenMonitorJSON = .object([
                "kind": .string("session"), "limitId": .string("codex"), "windowMinutes": .number(300), "usedPercent": .number(90), "additional": .bool(true),
            ])
            value["windows"] = .array([normal, extra])
            value["resetCredits"] = .object([
                "availableCount": .number(0), "nextExpiresAt": .string("2026-09-14T00:00:00Z"), "expirations": .array([.string("2026-09-14T00:00:00Z")]),
            ])
            let mapped = try mapProvider(.object(value))
            try check(
                mapped.fiveHour?.usedPercent == 0 && mapped.fiveHour?.resetsAt != nil && mapped.sevenDay == nil,
                "true zero canonical false additional with reset missing seven day")
            let snapshot = CodexUsageReader.AppServerSnapshot().replacingEngineQuota(mapped, response: response)
            try check(
                snapshot.quotaReadSucceeded && snapshot.credits?.resetCredits == 0
                    && snapshot.credits?.unlimited == true && snapshot.auxiliaryReadStatus == .upstreamResetCredits,
                "HTTP direct reset credits zero and balance unlimited independent of subscription")
            try check(mapped.original["resetCredits"] == value["resetCredits"], "all upstream reset expiry evidence retained")
            value["windows"] = .array([extra])
            try rejects("additional only cannot become main") { _ = try mapProvider(.object(value)) }
            value["windows"] = .array([.object(["kind": .string("weekly"), "limitId": .string("codex"), "windowMinutes": .number(300), "usedPercent": .number(0)])])
            try rejects("canonical kind cadence mismatch") { _ = try mapProvider(.object(value)) }
            value["windows"] = .array([.object(["kind": .string("session"), "limitId": .string("other"), "windowMinutes": .number(300), "usedPercent": .number(0)])])
            try rejects("noncanonical cannot become main") { _ = try mapProvider(.object(value)) }
        }
        var tooMany = customRequest
        tooMany.customSources = Array(repeating: customRequest.customSources![0], count: 256)
        let boundaryRequest = try tooMany.validated()
        try check(boundaryRequest.customSources?.count == 256, "custom source boundary matches bridge")
        tooMany.customSources = Array(repeating: customRequest.customSources![0], count: 257)
        try rejects("input collection bound") { _ = try tooMany.validated() }
        try rejects("missing packaged runtime is failure") { _ = try TokenMonitorEngine().collect(request: request, cancellation: TokenMonitorCancellation()) }
        setenv("TOKEN_MONITOR_FIXTURE_SENTINEL", "synthetic", 1)
        defer { unsetenv("TOKEN_MONITOR_FIXTURE_SENTINEL") }
        let unrelated = root.appendingPathComponent("unrelated")
        _ = FileManager.default.createFile(atPath: unrelated.path, contents: nil)
        let unrelatedHandle = try FileHandle(forWritingTo: unrelated)
        defer { try? unrelatedHandle.close() }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        // A large opaque model name forces multiple output chunks without private fixture data.
        if case .object(var p) = response.payload {
            p["futureDimension"] = .string(String(repeating: "x", count: 200_000))
            response.payload = .object(p)
        }
        let bytes = try encoded(response)
        for mode in ["normal", "overflow", "stderr", "timeout", "cancel", "held", "closed", "nonzero", "early"] {
            let bridge = root.appendingPathComponent(mode)
            try bytes.write(to: bridge)
            var r = request
            r.options.timeoutMs = ["normal", "overflow"].contains(mode) ? 5000 : 400
            let cancellation = TokenMonitorCancellation()
            if mode == "cancel" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { cancellation.cancel() } }
            let started = Date()
            do {
                let actual = try TokenMonitorEngine(fixture: .init(executable: executable, bridge: bridge)).collect(request: r, cancellation: cancellation)
                try check(mode == "normal" && actual.payload == response.payload, "multi-chunk process JSON roundtrip")
            } catch {
                guard mode != "normal" else { throw error }
                if mode == "overflow" { try check((error as? TokenMonitorFailure) == .outputTooLarge, "stdout overflow exact failure") }
                if mode == "cancel" { try check((error as? TokenMonitorFailure) == .cancelled, "cancel exact failure") }
                print("PASS process " + mode + " " + ((error as? TokenMonitorFailure)?.rawValue ?? "unexpected"))
            }
            try check(Date().timeIntervalSince(started) < (mode == "overflow" ? 6 : 3), "bounded completion " + mode)
            if ["held", "closed"].contains(mode), let text = try? String(contentsOf: URL(fileURLWithPath: bridge.path + ".pid"), encoding: .utf8), let pid = Int32(text) {
                try check(kill(pid, 0) != 0 && errno == ESRCH, "owned descendant gone " + mode)
            }
        }
        try unrelatedHandle.write(contentsOf: Data("still-open".utf8))
        try check((try? Data(contentsOf: unrelated)) == Data("still-open".utf8), "unrelated host descriptor intact")
        let cancellation = TokenMonitorCancellation()
        cancellation.cancel()
        try rejects("pre-cancel") { _ = try TokenMonitorEngine().collect(request: request, cancellation: cancellation) }
    }
}
