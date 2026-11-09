import Foundation

final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

struct CodexProfile {
    let id: String
    let isSystemProfile: Bool
    let codexHomeURL: URL
}

struct RuntimeLoadContext {
    let cacheDirectory = URL(fileURLWithPath: "/synthetic/statistics-cache")
    static func live(statisticsPreference: StatisticsTimeZonePreference) -> Self { Self() }
}

struct TokenMonitorEngine {
    static let maximumOutputBytes = 32 * 1024 * 1024
    struct Plan {
        let marker: String
        var failure: TokenMonitorFailure? = nil
        var status = TokenMonitorResponse.Status.ok
        var gate: DispatchSemaphore? = nil
    }
    private static let lock = NSLock()
    private static var plans: [Plan] = []
    private static var started = 0
    private static var finished = 0

    static func enqueue(_ plan: Plan) {
        lock.lock()
        plans.append(plan)
        lock.unlock()
    }
    static var starts: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
    static var completions: Int {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
    func collect(request: TokenMonitorRequest, cancellation: TokenMonitorCancellation) throws -> TokenMonitorResponse {
        Self.lock.lock()
        guard !Self.plans.isEmpty else { fatalError("Unplanned collector access") }
        let plan = Self.plans.removeFirst()
        Self.started += 1
        Self.lock.unlock()
        defer {
            Self.lock.lock()
            Self.finished += 1
            Self.lock.unlock()
        }
        if let gate = plan.gate { precondition(gate.wait(timeout: .now() + 5) == .success) }
        if let failure = plan.failure { throw failure }
        return TokenMonitorResponse(
            schemaVersion: 1, requestId: plan.marker, operation: .collectUsage,
            engine: .init(repository: "synthetic", commit: TokenMonitorResponse.commit, version: "fixture"),
            collectedAt: "2026-11-09T00:00:00Z", timezone: request.timezone,
            status: plan.status, sources: [], payload: .object([:]),
            coverage: .init(entries: [], days: [], cost: .unknown), errors: [])
    }
}

final class StatisticsEngineCacheFixture {
    var engineState = TokenMonitorEngineState()
    var statisticsEngineChoice = StatisticsEngineChoice.upstream
    var statisticsPreference = StatisticsTimeZonePreference(selection: .utc, fixedIdentifier: "UTC")
    var profiles: [CodexProfile] = []
    var publications: [String] = []
    var engineLimitsByProfileID: [String: TokenMonitorResponse] = [:]
    var refreshGeneration: UInt64 = 0
    var isRefreshing = false
    var hasPendingRefresh = false
    var isLaunchingCodex = false
    var isAccountSwitchTransactionActive = false
    var fullRefreshCancellation: TokenMonitorCancellation?
    var identityRefreshCancellation: TokenMonitorCancellation?
    var engineQuotaCancellation: TokenMonitorCancellation?
    var warmUpCallbacksApplied = 0
    func refresh(queueIfBusy: Bool) {}
    func updateTokenMonitorHubAfterLocalCollection(_ response: TokenMonitorResponse) { publications.append(response.requestId) }

    // PRODUCTION_ENGINE_FIELDS
    // PRODUCTION_ENGINE_METHODS

    func stopRefreshWork() {
        // PRODUCTION_STOP_REFRESH
    }

    func completeWarmUp(generation: UInt64) {
        // PRODUCTION_WARMUP_GUARD
        warmUpCallbacksApplied += 1
    }

    func completeFullRefresh(cancellation: TokenMonitorCancellation) {
        // PRODUCTION_FULL_REFRESH_GUARD
        fullRefreshCancellation = nil
        isRefreshing = false
        hasPendingRefresh = false
    }

    func sources(_ id: String) {
        engineLocalSources = [
            TokenMonitorSource(id: id, providerId: "codex", kind: .agentLogs, canonicalPath: "/synthetic/" + id, pathRole: .logRoot, toolId: "codex")
        ]
        statisticsIncludesManagedCodex = false
    }
}

@main
struct StatisticsEngineCacheChecks {
    @MainActor static var assertions = 0
    @MainActor static var failures = 0
    @MainActor static func expect(_ passed: Bool, _ message: String) {
        assertions += 1
        if !passed {
            failures += 1
            print("FAIL: \(message)")
        }
    }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Synthetic collector did not settle")
    }
    @MainActor static func ready(_ fixture: StatisticsEngineCacheFixture, marker: String, status: TokenMonitorResponse.Status = .ok) async {
        TokenMonitorEngine.enqueue(.init(marker: marker, status: status))
        fixture.refreshStatisticsEngine()
        await wait { fixture.engineState.phase == .ready || fixture.engineState.phase == .partial }
        expect(fixture.engineState.lastGood?.requestId == marker, "successful collection publishes its own source snapshot")
    }
    @MainActor static func main() async {
        let fixture = StatisticsEngineCacheFixture()
        fixture.sources("source-a")
        await ready(fixture, marker: "source-a")
        TokenMonitorEngine.enqueue(.init(marker: "same-a", failure: .processFailed))
        fixture.refreshStatisticsEngine()
        await wait { fixture.engineState.phase == .failed }
        expect(fixture.engineState.lastGood?.requestId == "source-a" && fixture.engineState.isStale, "same-key failure keeps the prior good snapshot as stale")

        fixture.sources("source-b")
        TokenMonitorEngine.enqueue(.init(marker: "failed-b", failure: .invalidResponse))
        fixture.refreshStatisticsEngine()
        expect(fixture.engineState.lastGood == nil && fixture.engineState.dashboardJSON == nil, "source change clears prior dashboard before collection completes")
        await wait { fixture.engineState.phase == .failed }
        expect(fixture.engineState.lastGood == nil && !fixture.engineState.isStale, "failed new source cannot inherit another source's snapshot")

        await ready(fixture, marker: "source-b", status: .partial)
        fixture.statisticsPreference = .init(selection: .fixed, fixedIdentifier: "Asia/Shanghai")
        TokenMonitorEngine.enqueue(.init(marker: "wrong-timezone", failure: .processFailed))
        fixture.refreshStatisticsEngine()
        await wait { fixture.engineState.phase == .failed }
        expect(fixture.engineState.lastGood == nil, "preference and timezone change invalidate the successful key")

        await ready(fixture, marker: "shanghai-b")
        fixture.cancelStatisticsEngine()
        expect(fixture.engineState.lastGood?.requestId == "shanghai-b" && fixture.engineState.isStale, "same-key cancellation preserves stale history")
        fixture.sources("source-c")
        fixture.cancelStatisticsEngine()
        expect(fixture.engineState.lastGood == nil && fixture.engineState.dashboardJSON == nil, "stopped configuration changes clear the old source too")

        fixture.statisticsIncludesManagedCodex = true
        fixture.profiles = [.init(id: "managed", isSystemProfile: false, codexHomeURL: URL(fileURLWithPath: "/synthetic/managed-a"))]
        await ready(fixture, marker: "managed-a")
        fixture.profiles = [.init(id: "managed", isSystemProfile: false, codexHomeURL: URL(fileURLWithPath: "/synthetic/managed-b"))]
        TokenMonitorEngine.enqueue(.init(marker: "managed-b", failure: .processFailed))
        fixture.refreshStatisticsEngine()
        await wait { fixture.engineState.phase == .failed }
        expect(fixture.engineState.lastGood == nil, "same profile with a changed log source does not retain the old source")

        await ready(fixture, marker: "before-delayed")
        let delayed = DispatchSemaphore(value: 0)
        let starts = TokenMonitorEngine.starts
        let completions = TokenMonitorEngine.completions
        TokenMonitorEngine.enqueue(.init(marker: "old-delayed", gate: delayed))
        fixture.refreshStatisticsEngine()
        await wait { TokenMonitorEngine.starts == starts + 1 }
        fixture.sources("source-d")
        await ready(fixture, marker: "new-current")
        delayed.signal()
        await wait { TokenMonitorEngine.completions == completions + 2 }
        for _ in 0..<3 { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
        expect(
            fixture.engineState.lastGood?.requestId == "new-current" && !fixture.publications.contains("old-delayed"),
            "late cancelled source cannot replace or publish the current source")

        UserDefaults.standard.set(StatisticsEngineChoice.custom.rawValue, forKey: StatisticsEngineChoice.storageKey)
        fixture.refreshStatisticsEngine()
        expect(fixture.engineState.phase == .custom && fixture.engineState.lastGood == nil, "engine authority changes clear previous-mode history")
        UserDefaults.standard.set(StatisticsEngineChoice.upstream.rawValue, forKey: StatisticsEngineChoice.storageKey)
        TokenMonitorEngine.enqueue(.init(marker: "returned-upstream", failure: .engineError))
        fixture.refreshStatisticsEngine()
        await wait { fixture.engineState.phase == .failed }
        expect(fixture.engineState.lastGood == nil, "returning to upstream after mode change cannot revive old history")

        let stopped = StatisticsEngineCacheFixture()
        let priorGeneration = stopped.refreshGeneration
        let priorFullRefresh = TokenMonitorCancellation()
        stopped.fullRefreshCancellation = priorFullRefresh
        stopped.identityRefreshCancellation = TokenMonitorCancellation()
        stopped.engineQuotaCancellation = TokenMonitorCancellation()
        stopped.isRefreshing = true
        stopped.hasPendingRefresh = true
        stopped.stopRefreshWork()
        expect(
            stopped.refreshGeneration != priorGeneration && !stopped.isRefreshing && !stopped.hasPendingRefresh && priorFullRefresh.isCancelled,
            "stop invalidates in-flight refresh generation and clears busy/pending flags")
        stopped.completeWarmUp(generation: priorGeneration)
        expect(stopped.warmUpCallbacksApplied == 0, "a late pre-stop warmup result cannot publish after stop")
        let currentFullRefresh = TokenMonitorCancellation()
        stopped.fullRefreshCancellation = currentFullRefresh
        stopped.isRefreshing = true
        stopped.hasPendingRefresh = true
        stopped.completeFullRefresh(cancellation: priorFullRefresh)
        expect(
            stopped.fullRefreshCancellation === currentFullRefresh && stopped.isRefreshing && stopped.hasPendingRefresh,
            "the existing full-refresh ownership guard keeps a late old callback from clearing a newer run")
        print("Statistics engine cache: \(assertions) assertions, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
