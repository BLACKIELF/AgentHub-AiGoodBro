import Foundation

struct StatisticsTimeZonePreference: Equatable {
    let identifier: String
    func repaired() -> Self { self }
}
enum StatisticsTimeZonePreferenceStore { static func save(_ value: StatisticsTimeZonePreference) {} }
struct StatisticsContext {
    let resolvedIdentifier: String
    init(preference: StatisticsTimeZonePreference, now: Date) { resolvedIdentifier = preference.identifier }
}
struct StatisticsIdentity {
    let resolvedIdentifier: String
    init(resolvedIdentifier: String) { self.resolvedIdentifier = resolvedIdentifier }
    init(preference: StatisticsTimeZonePreference, resolvedIdentifier: String, generation: UInt64, now: Date) {
        self.resolvedIdentifier = resolvedIdentifier
    }
}
struct MultiRuntimeUsageSnapshot {
    let statisticsIdentity: StatisticsIdentity
    let quotaOwner: String
    let refreshedAt = Date()
    var runtimes: String { quotaOwner }
    var aggregate: String { quotaOwner }
    var leadership: String { quotaOwner }
    init(statisticsIdentity: StatisticsIdentity, quotaOwner: String) {
        self.statisticsIdentity = statisticsIdentity
        self.quotaOwner = quotaOwner
    }
    init(refreshedAt: Date, runtimes: String, aggregate: String, leadership: String, statisticsIdentity: StatisticsIdentity) {
        self.statisticsIdentity = statisticsIdentity
        quotaOwner = runtimes
    }
}
struct CachedProfileSnapshot { let accountID: String? }
struct CodexProfile {
    let id: String
    let recordedAccountKey: String
    let lastSnapshot: CachedProfileSnapshot?
}

final class CacheFixture {
    var refreshGeneration: UInt64 = 0
    var statisticsPreference = StatisticsTimeZonePreference(identifier: "UTC")
    var isSwitchingStatisticsTimeZone = false
    var statisticsTransitionMessage = ""
    var hasStarted = false
    var isRefreshing = false
    var hasPendingRefresh = false
    var appliedOwner: String?
    var refreshRequests = 0
    func scheduleStatisticsRollover() {}
    func refreshStatisticsEngine() {}
    func cancelStatisticsEngine() {}
    func statisticsSwitchingMessage(for preference: StatisticsTimeZonePreference) -> String { "switching" }
    func finishStatisticsTimeZoneSwitch(cached: Bool) { isSwitchingStatisticsTimeZone = false }
    func apply(_ snapshot: MultiRuntimeUsageSnapshot) { appliedOwner = snapshot.quotaOwner }
    func refresh(queueIfBusy: Bool) { refreshRequests += 1 }
    var selectedMonitorProfileID = "profile-A"
    var selectedMonitorProfile: CodexProfile? = CodexProfile(
        id: "profile-A", recordedAccountKey: "synthetic-a", lastSnapshot: CachedProfileSnapshot(accountID: "account-A"))

    // PRODUCTION_CACHE

    func run() {
        let utc = StatisticsTimeZonePreference(identifier: "UTC")
        let a = selectedMonitorProfile
        cacheStatisticsSnapshot(MultiRuntimeUsageSnapshot(statisticsIdentity: StatisticsIdentity(resolvedIdentifier: "UTC"), quotaOwner: "A"))
        precondition(validCachedStatisticsSnapshot(forKey: statisticsCacheKey(for: utc))?.quotaOwner == "A")

        selectedMonitorProfileID = "profile-B"
        selectedMonitorProfile = CodexProfile(id: "profile-B", recordedAccountKey: "synthetic-b", lastSnapshot: CachedProfileSnapshot(accountID: "account-B"))
        precondition(validCachedStatisticsSnapshot(forKey: statisticsCacheKey(for: utc)) == nil, "profile B must not restore profile A quota")
        cacheStatisticsSnapshot(MultiRuntimeUsageSnapshot(statisticsIdentity: StatisticsIdentity(resolvedIdentifier: "UTC"), quotaOwner: "B"))
        precondition(validCachedStatisticsSnapshot(forKey: statisticsCacheKey(for: utc))?.quotaOwner == "B")

        selectedMonitorProfileID = "profile-A"
        selectedMonitorProfile = a
        precondition(validCachedStatisticsSnapshot(forKey: statisticsCacheKey(for: utc))?.quotaOwner == "A")
        selectedMonitorProfile = CodexProfile(id: "profile-A", recordedAccountKey: "synthetic-a", lastSnapshot: CachedProfileSnapshot(accountID: "account-C"))
        precondition(validCachedStatisticsSnapshot(forKey: statisticsCacheKey(for: utc)) == nil, "same profile with new account ID must miss")
        selectedMonitorProfile = CodexProfile(id: "profile-A", recordedAccountKey: "synthetic-c", lastSnapshot: a?.lastSnapshot)
        precondition(validCachedStatisticsSnapshot(forKey: statisticsCacheKey(for: utc)) == nil, "same profile with new account key must miss")
        selectedMonitorProfile = CodexProfile(id: "profile-A", recordedAccountKey: "synthetic-a", lastSnapshot: nil)
        precondition(validCachedStatisticsSnapshot(forKey: statisticsCacheKey(for: utc)) == nil, "missing identity must not inherit recorded identity")
        selectedMonitorProfile = a
        let expiredKey = statisticsCacheKey(for: utc)
        statisticsSnapshotCache[expiredKey] = StatisticsSnapshotCacheEntry(
            snapshot: MultiRuntimeUsageSnapshot(statisticsIdentity: StatisticsIdentity(resolvedIdentifier: "UTC"), quotaOwner: "A"),
            cachedAt: Date().addingTimeInterval(-statisticsSnapshotCacheTTL - 1))
        precondition(validCachedStatisticsSnapshot(forKey: expiredKey) == nil, "expired quota must miss")
        precondition(!statisticsSnapshotCacheOrder.contains(expiredKey))

        for zone in ["UTC", "Asia/Shanghai", "Europe/London", "America/New_York", "Asia/Tokyo"] {
            cacheStatisticsSnapshot(MultiRuntimeUsageSnapshot(statisticsIdentity: StatisticsIdentity(resolvedIdentifier: zone), quotaOwner: "A"))
        }
        precondition(statisticsSnapshotCache.count == statisticsSnapshotCacheLimit)
        precondition(statisticsSnapshotCacheOrder.count == statisticsSnapshotCacheLimit)
        precondition(validCachedStatisticsSnapshot(forKey: statisticsCacheKey(for: utc)) == nil, "LRU still evicts oldest timezone")

        let tokyo = StatisticsTimeZonePreference(identifier: "Asia/Tokyo")
        let tokyoKey = statisticsCacheKey(for: tokyo)
        let originalCacheDate = Date().addingTimeInterval(-60)
        statisticsSnapshotCache[tokyoKey] = StatisticsSnapshotCacheEntry(
            snapshot: MultiRuntimeUsageSnapshot(statisticsIdentity: StatisticsIdentity(resolvedIdentifier: tokyo.identifier), quotaOwner: "A"),
            cachedAt: originalCacheDate)
        isRefreshing = true
        updateStatisticsTimeZone(tokyo)
        precondition(appliedOwner == "A")
        precondition(statisticsSnapshotCache[tokyoKey]?.cachedAt == originalCacheDate, "cache hit must not renew stale quota TTL")
        precondition(hasPendingRefresh, "invalidated in-flight generation must be followed by another refresh")
        precondition(refreshRequests == 0, "usable cached snapshot does not duplicate in-flight work")

        selectedMonitorProfileID = "profile-B"
        selectedMonitorProfile = CodexProfile(id: "profile-B", recordedAccountKey: "synthetic-b", lastSnapshot: CachedProfileSnapshot(accountID: "account-B"))
        appliedOwner = nil
        updateStatisticsTimeZone(StatisticsTimeZonePreference(identifier: "Europe/London"))
        precondition(appliedOwner == nil, "real timezone switch must not apply another profile's cache")
        precondition(refreshRequests == 1, "cache miss requests new data")
        print("Statistics cache identity: 18 assertions passed")
    }
}

CacheFixture().run()
