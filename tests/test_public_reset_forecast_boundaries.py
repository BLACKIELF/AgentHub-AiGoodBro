#!/usr/bin/env python3
"""Compile the real forecast/cache/delivery paths with inert offline dependencies."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FORECAST = (ROOT / "Sources/CodexUsageWidget/Services/PublicResetForecast.swift").read_text()
LEDGER = (ROOT / "Sources/CodexUsageWidget/Services/PublicResetForecastDeliveryLedger.swift").read_text()
ANNOUNCEMENTS = (ROOT / "Sources/CodexUsageWidget/Services/PublicResetAnnouncements.swift").read_text()


def portion(source: str, start: str, end: str) -> str:
    return source[source.index(start) : source.index(end)]


MODEL = portion(FORECAST, "struct PublicResetForecast:", "/// Parses only the tracker page")
FORECAST_STORE = portion(FORECAST, "private struct PublicResetForecastCache:", "enum PublicResetForecastSelfTest {")
FORECAST_LEDGER = portion(LEDGER, "struct PublicResetForecastDeliveryLedger:", "/// The CLI compares")
COMPLETED_MODEL = portion(ANNOUNCEMENTS, "struct PublicResetAnnouncement:", "enum PublicResetFailure:")
COMPLETED_LEDGER = portion(ANNOUNCEMENTS, "struct PublicResetDeliveryLedger:", "struct PublicResetDeliveryLock {")
DELIVER = portion(
    ANNOUNCEMENTS,
    "    @MainActor\n    private func deliverForecast(",
    "    @MainActor\n    private func writableFeishuLedger()",
)
CHECK = portion(
    ANNOUNCEMENTS,
    "    @MainActor\n    func check() {",
    "    /// Separate durable ledger and lock per optional channel.",
)


def compile_and_run(name: str, source: str, optimized: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="forecast-boundary-") as temporary:
        directory = Path(temporary)
        swift = directory / "Fixture.swift"
        executable = directory / "fixture"
        swift.write_text(source)
        command = [
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "modules"),
        ]
        if optimized:
            command.append("-O")
        command += [str(swift), "-o", str(executable)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, result.stderr.replace(temporary, "<fixture>")
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, (result.stdout + result.stderr).replace(temporary, "<fixture>")
        print(f"PASS {name} {'-O' if optimized else 'debug'}: {result.stdout.strip()}")


CACHE_STUBS = r'''
import Foundation
import Combine
enum WidgetLanguage { case en
    static func storedOrAutomatic() -> Self { .en }
    var locale: Locale { Locale(identifier: "en_US") }
    func text(_ zh: String, _ en: String) -> String { en }
}
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL { fatalError("explicit fixture directory required") }
}
enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}
enum PrivateLocalFileStore {
    static func write(_ data: Data, to url: URL) throws { try data.write(to: url) }
}
struct PublicResetForecastClient {
    func fetch() async throws -> PublicResetForecastPageState { fatalError("network forbidden") }
}
'''

CACHE_FIXTURE = r'''
@main struct Main {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forecast-offline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let fetched = now.addingTimeInterval(-71 * 60 * 60)
        let announced = fetched.addingTimeInterval(-60)
        let id = PublicResetForecast.sourcePostID(at: announced)!
        let forecast = PublicResetForecast(id: id, latestBy: nil, announcedAt: announced,
            sourceURL: URL(string: "https://x.com/thsottiaux/status/" + id)!, fetchedAt: fetched)
        let cache = PublicResetForecastCache(checkedAt: fetched, forecast: forecast)
        try JSONEncoder().encode(cache).write(to: root.appendingPathComponent("public-reset-forecast-v1.json"))
        let store = PublicResetForecastStore(supportDirectory: root, fetchForecast: {
            throw PublicResetForecastFailure.retryLater(86_400)
        })
        precondition(store.forecast != nil)
        store.check()
        while store.checking { await Task.yield() }
        precondition(store.forecast != nil && store.isShowingCache)
        store.check(now: now.addingTimeInterval(2 * 60 * 60))
        precondition(store.forecast == nil && !store.isShowingCache)
        print("72-hour cache cleared during rate-limit cooldown")
    }
}
'''

DELIVERY_STUBS = r'''
import Foundation
enum WidgetLanguage { case en
    static func storedOrAutomatic() -> Self { .en }
    func text(_ zh: String, _ en: String) -> String { en }
    func dateTime(_ date: Date) -> String { "fixture-date" }
}
enum PublicResetTranslationModel { static func isForecast(_ text: String) -> Bool { false } }
enum PublicResetFailure: LocalizedError { case localState, queueFull, historyGap, invalidResponse }
enum FeishuWebhookError: LocalizedError { case transportFailed, invalidResponse, httpStatus(Int), cancelled }
struct PublicResetForecastNotification {
    let id: String
    init(_ event: PublicResetForecast) throws { id = event.id }
}
enum PublicResetHistoryRecovery { struct Checkpoint: Codable { var isValid: Bool { true } } }
struct PublicResetDeliveryLock {
    static func acquire(in directory: URL) throws -> Self? { Self() }
    func release() {}
}
'''

DELIVERY_MONITOR = r'''
@MainActor final class FixtureMonitor {
    var enabled = true
    var generation: UInt64 = 0
    var historyCheckSequence: UInt64 = 0
    var verifiedCompletedIDs: Set<String>?
    var status: String?
    var forecastLedger = PublicResetForecastDeliveryLedger()
    var completedLedger = PublicResetDeliveryLedger()
    var sent: [String] = []
    var canSend: () -> Bool = { true }
    var sendForecast: (@MainActor (PublicResetForecastNotification) async -> Result<Void, FeishuWebhookError>)?
    var forecastDeliveryDirectory = FileManager.default.temporaryDirectory
    init() {
        forecastLedger.initialized = true
        sendForecast = { [weak self] message in
            self?.sent.append(message.id)
            return .success(())
        }
    }
    func isCurrent(_ epoch: UInt64) -> Bool { epoch == generation }
    func load() throws -> PublicResetDeliveryLedger { completedLedger }
    func loadForecastLedger() throws -> PublicResetForecastDeliveryLedger { forecastLedger }
    func saveForecastLedger(_ value: PublicResetForecastDeliveryLedger) throws { forecastLedger = value }
    func run(_ state: PublicResetForecastPageState) async { await deliverForecast(state, epoch: generation) }
'''

DELIVERY_FIXTURE = r'''
}
@main struct Main {
    @MainActor static func main() async throws {
        let now = Date()
        let announced = now.addingTimeInterval(-60)
        let id = PublicResetForecast.sourcePostID(at: announced)!
        let url = URL(string: "https://x.com/thsottiaux/status/" + id)!
        let event = PublicResetForecast(id: id, latestBy: nil, announcedAt: announced,
            sourceURL: url, fetchedAt: now)
        let completed = PublicResetAnnouncement(id: id, resetType: .regular,
            announcedAt: announced, text: "fixture", source: .init(type: "x_post", author: "thsottiaux", url: url))

        let historyFirst = FixtureMonitor()
        historyFirst.verifiedCompletedIDs = [id]
        await historyFirst.run(.forecast(event))
        precondition(historyFirst.sent.isEmpty && historyFirst.forecastLedger.records[id] == .baseline)
        historyFirst.verifiedCompletedIDs = []
        await historyFirst.run(.forecast(event))
        precondition(historyFirst.sent.isEmpty)

        let forecastFirst = FixtureMonitor()
        await forecastFirst.run(.forecast(event))
        precondition(forecastFirst.sent.isEmpty && forecastFirst.forecastLedger.records[id] == .pending)
        forecastFirst.verifiedCompletedIDs = [id]
        await forecastFirst.run(.forecast(event))
        precondition(forecastFirst.sent.isEmpty && forecastFirst.forecastLedger.records[id] == .baseline)

        let persistedCompletion = FixtureMonitor()
        try persistedCompletion.completedLedger.reserveAuthorizedDelivery(completed)
        persistedCompletion.verifiedCompletedIDs = []
        await persistedCompletion.run(.forecast(event))
        precondition(persistedCompletion.sent.isEmpty && persistedCompletion.forecastLedger.records[id] == .baseline)

        let failedThenRecovered = FixtureMonitor()
        await failedThenRecovered.run(.forecast(event))
        precondition(failedThenRecovered.sent.isEmpty && failedThenRecovered.forecastLedger.records[id] == .pending)
        failedThenRecovered.verifiedCompletedIDs = []
        await failedThenRecovered.run(.forecast(event))
        precondition(failedThenRecovered.sent == [id] && failedThenRecovered.forecastLedger.records[id] == .sent)
        await failedThenRecovered.run(.forecast(event))
        precondition(failedThenRecovered.sent == [id])

        let forecastThenCompleted = FixtureMonitor()
        forecastThenCompleted.verifiedCompletedIDs = []
        await forecastThenCompleted.run(.forecast(event))
        precondition(forecastThenCompleted.sent == [id] && forecastThenCompleted.forecastLedger.records[id] == .sent)
        try forecastThenCompleted.completedLedger.reserveAuthorizedDelivery(completed)
        precondition(forecastThenCompleted.completedLedger.records[id] == .sending)

        print("same-ID completion wins in both orders; failed history retries; forecast then completion remains allowed")
    }
}
'''

INTEGRATION_STUBS = r'''
import Foundation
enum WidgetLanguage { case en
    static func storedOrAutomatic() -> Self { .en }
    func text(_ zh: String, _ en: String) -> String { en }
    func dateTime(_ date: Date) -> String { "fixture-date" }
}
enum PublicResetTranslationModel { static func isForecast(_ text: String) -> Bool { false } }
enum PublicResetFailure: LocalizedError {
    case localState, queueFull, historyGap, invalidResponse, unavailable, retryLater(Int)
}
enum FeishuWebhookError: LocalizedError { case transportFailed, invalidResponse, httpStatus(Int), cancelled }
struct PublicResetForecastNotification {
    let id: String
    init(_ event: PublicResetForecast) throws { id = event.id }
}
enum PublicResetHistoryRecovery { struct Checkpoint: Codable { var isValid: Bool { true } } }
struct PublicResetDeliveryLock {
    static func acquire(in directory: URL) throws -> Self? { Self() }
    func release() {}
}
enum MessageChannelKind: CaseIterable { case fixture }

@MainActor final class PublicResetForecastStore {
    static let shared = PublicResetForecastStore()
    var forecast: PublicResetForecast?
    private var callbacks: [(@MainActor (PublicResetForecastPageState) async -> Void)] = []
    func check(onSuccessfulFetch: (@MainActor (PublicResetForecastPageState) async -> Void)? = nil) {
        if let onSuccessfulFetch { callbacks.append(onSuccessfulFetch) }
    }
    func reset() { forecast = nil; callbacks = [] }
    func emit(_ state: PublicResetForecastPageState, callback index: Int, updateCache: Bool = true) async {
        if updateCache {
            if case .forecast(let event) = state { forecast = event } else { forecast = nil }
        }
        await callbacks[index](state)
    }
}

actor DeferredHistory {
    private var results: [Result<PublicResetPage, Error>] = []
    private var waiting: CheckedContinuation<PublicResetPage, Error>?
    func fetch() async throws -> PublicResetPage {
        if !results.isEmpty { return try results.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func complete(_ result: Result<PublicResetPage, Error>) {
        if let waiting {
            self.waiting = nil
            waiting.resume(with: result)
        } else {
            results.append(result)
        }
    }
}
'''

INTEGRATION_MONITOR = r'''
@MainActor final class FixtureMonitor {
    var enabled = true
    var preview = false
    var fixtureScheduling = false
    var stopped = false
    var checking = false
    var generation: UInt64 = 0
    var historyCheckSequence: UInt64 = 0
    var verifiedCompletedIDs: Set<String>?
    var status: String?
    var localStatus: String?
    var notBefore = Date.distantPast
    var announcements: [PublicResetAnnouncement] = []
    var announcementsHasMore: Bool?
    var latest: PublicResetAnnouncement?
    var checkedAt: Date?
    var task: Task<Void, Never>?
    var forecastLedger = PublicResetForecastDeliveryLedger()
    var completedLedger = PublicResetDeliveryLedger()
    var sentForecasts: [String] = []
    var canSend: () -> Bool = { true }
    var sendForecast: (@MainActor (PublicResetForecastNotification) async -> Result<Void, FeishuWebhookError>)?
    var forecastDeliveryDirectory = FileManager.default.temporaryDirectory
    let fetchPage: () async throws -> PublicResetPage
    init(history: DeferredHistory) {
        forecastLedger.initialized = true
        fetchPage = { try await history.fetch() }
        sendForecast = { [weak self] message in
            self?.sentForecasts.append(message.id)
            return .success(())
        }
    }
    func isCurrent(_ epoch: UInt64) -> Bool { epoch == generation && !stopped && !Task.isCancelled }
    func load() throws -> PublicResetDeliveryLedger { completedLedger }
    func loadForecastLedger() throws -> PublicResetForecastDeliveryLedger { forecastLedger }
    func saveForecastLedger(_ value: PublicResetForecastDeliveryLedger) throws { forecastLedger = value }
    func deliverChannel(_ page: PublicResetPage, kind: MessageChannelKind, epoch: UInt64) async {}
    func deliverExistingChannels(_ page: PublicResetPage, language: WidgetLanguage, epoch: UInt64) async {}
    func waitForCheck() async { let running = task; await running?.value }
'''

INTEGRATION_FIXTURE = r'''
}
@main struct Main {
    @MainActor static func main() async throws {
        let now = Date()
        let announced = now.addingTimeInterval(-60)
        let id = PublicResetForecast.sourcePostID(at: announced)!
        let url = URL(string: "https://x.com/thsottiaux/status/" + id)!
        let forecast = PublicResetForecast(id: id, latestBy: nil, announcedAt: announced,
            sourceURL: url, fetchedAt: now)
        let completed = PublicResetAnnouncement(id: id, resetType: .regular,
            announcedAt: announced, text: "fixture", source: .init(type: "x_post", author: "thsottiaux", url: url))
        func page(_ events: [PublicResetAnnouncement]) -> PublicResetPage {
            PublicResetPage(data: events, pagination: .init(hasMore: false, nextCursor: nil),
                meta: .init(apiVersion: "v1", generatedAt: now))
        }
        let store = PublicResetForecastStore.shared

        // The actual check() registers the forecast callback and launches the
        // completed-history fetch. Forecast may finish before history.
        store.reset()
        let firstHistory = DeferredHistory()
        let forecastFirst = FixtureMonitor(history: firstHistory)
        forecastFirst.check()
        await store.emit(.forecast(forecast), callback: 0)
        precondition(forecastFirst.sentForecasts.isEmpty && forecastFirst.forecastLedger.records[id] == .pending)
        await firstHistory.complete(.success(page([completed])))
        await forecastFirst.waitForCheck()
        precondition(forecastFirst.sentForecasts.isEmpty && forecastFirst.forecastLedger.records[id] == .baseline)

        // History may finish before the forecast callback. The same ID still
        // cannot be forecast after a confirmed completion.
        store.reset()
        let secondHistory = DeferredHistory()
        let historyFirst = FixtureMonitor(history: secondHistory)
        historyFirst.check()
        await secondHistory.complete(.success(page([completed])))
        await historyFirst.waitForCheck()
        await store.emit(.forecast(forecast), callback: 0)
        precondition(historyFirst.sentForecasts.isEmpty && historyFirst.forecastLedger.records[id] == .baseline)

        // A failed history read leaves a pending forecast. A later successful
        // check drains the cached event, and a delayed callback cannot replay it.
        store.reset()
        let retryHistory = DeferredHistory()
        let retry = FixtureMonitor(history: retryHistory)
        retry.check()
        await store.emit(.forecast(forecast), callback: 0)
        await retryHistory.complete(.failure(PublicResetFailure.unavailable))
        await retry.waitForCheck()
        precondition(retry.sentForecasts.isEmpty && retry.forecastLedger.records[id] == .pending)
        retry.check()
        await retryHistory.complete(.success(page([])))
        await retry.waitForCheck()
        precondition(retry.sentForecasts == [id] && retry.forecastLedger.records[id] == .sent)
        await store.emit(.forecast(forecast), callback: 1)
        precondition(retry.sentForecasts == [id])

        // Start a new check before invoking the old callback. Its captured
        // sequence is stale even while the new history request is unresolved.
        store.reset()
        let staleHistory = DeferredHistory()
        let stale = FixtureMonitor(history: staleHistory)
        stale.check()
        await staleHistory.complete(.failure(PublicResetFailure.unavailable))
        await stale.waitForCheck()
        stale.check()
        await store.emit(.forecast(forecast), callback: 0, updateCache: false)
        precondition(stale.sentForecasts.isEmpty && stale.forecastLedger.records[id] == nil)
        await staleHistory.complete(.success(page([])))
        await stale.waitForCheck()

        // A genuinely new forecast still uses the fake Feishu sender once.
        store.reset()
        let currentHistory = DeferredHistory()
        let current = FixtureMonitor(history: currentHistory)
        current.check()
        await currentHistory.complete(.success(page([])))
        await current.waitForCheck()
        await store.emit(.forecast(forecast), callback: 0)
        await store.emit(.forecast(forecast), callback: 0)
        precondition(current.sentForecasts == [id] && current.forecastLedger.records[id] == .sent)
        print("production check wiring: both callback orders, failed-history retry, stale callback, once-only send")
    }
}
'''


for optimized in (False, True):
    compile_and_run("cache", CACHE_STUBS + MODEL + FORECAST_STORE + CACHE_FIXTURE, optimized)
    compile_and_run(
        "delivery",
        DELIVERY_STUBS + MODEL + COMPLETED_MODEL + COMPLETED_LEDGER
        + FORECAST_LEDGER + DELIVERY_MONITOR + DELIVER + DELIVERY_FIXTURE,
        optimized,
    )
    compile_and_run(
        "check integration",
        INTEGRATION_STUBS + MODEL + COMPLETED_MODEL + COMPLETED_LEDGER
        + FORECAST_LEDGER + INTEGRATION_MONITOR + DELIVER + CHECK + INTEGRATION_FIXTURE,
        optimized,
    )
