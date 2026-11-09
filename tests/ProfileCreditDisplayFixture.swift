import Foundation

typealias LocalUsage = String
typealias TaskBoard = String
struct LowQuotaAlertThresholds {
    static let standard = Self()
    let fiveHour = 5
    let sevenDay = 10
}
struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ chinese: String, _ english: String) -> String { english }
}
enum CodexOfficialProfileReader {
    static func credentialIdentity(codexHomeURL: URL) -> CodexCredentialIdentity? {
        fatalError("A display projection must not read credentials")
    }
}

// PRODUCTION_TYPES

struct CodexProfile {
    let id: String
    var lastSnapshot: CodexAccountSnapshot?
}
struct RuntimeUsageSnapshot {
    let scope: RuntimeScope
    let snapshot: UsageSnapshot
}
struct MultiRuntimeUsageSnapshot {
    var runtimes: [RuntimeUsageSnapshot]
    var aggregate: UsageSnapshot = .empty
    static let empty = Self(runtimes: [])
    // PRODUCTION_RUNTIME_PROJECTION
}
struct FeishuMaskedAccount {
    let value: String
}
enum FeishuSwitchNotification {
    enum Event { case test }
}
final class SyntheticProfileStore {
    var profiles: [CodexProfile]
    var selectedMonitorProfileID: String
    init(_ profiles: [CodexProfile], selected: String) {
        self.profiles = profiles
        selectedMonitorProfileID = selected
    }
    func selectMonitor(_ id: String) throws { selectedMonitorProfileID = id }
}
final class ProfileCreditDisplayStore {
    let profileStore: SyntheticProfileStore
    var profiles: [CodexProfile]
    var selectedMonitorProfileID: String
    var selectedMonitorProfile: CodexProfile? { profiles.first { $0.id == selectedMonitorProfileID } }
    var selectedRuntimeScope: RuntimeScope = .codex
    var visibleRuntimeScopes = RuntimeScope.allCases
    var snapshot: UsageSnapshot
    var runtimeSnapshots: [RuntimeUsageSnapshot]
    var multiRuntimeSnapshot: MultiRuntimeUsageSnapshot
    var refreshGeneration: UInt64 = 0
    var refreshRequests = 0
    var accountManagerMessage: String?
    var feishuWebhookConfigured = true
    var feishuNotificationMessage: String?
    var captured: (source: FeishuMaskedAccount, quota: AutomaticSwitchQuotaState, facts: UsageSnapshot?)?

    init(_ profiles: [CodexProfile], selected: String, live: UsageSnapshot) {
        profileStore = SyntheticProfileStore(profiles, selected: selected)
        self.profiles = profiles
        selectedMonitorProfileID = selected
        snapshot = live
        runtimeSnapshots = [.init(scope: .codex, snapshot: live)]
        multiRuntimeSnapshot = .init(runtimes: runtimeSnapshots)
    }
    func captureCurrentProfile() -> Bool { true }
    func syncProfiles() {
        profiles = profileStore.profiles
        selectedMonitorProfileID = profileStore.selectedMonitorProfileID
    }
    func configureAuthMonitoring() {}
    func refresh(queueIfBusy: Bool) { refreshRequests += 1 }
    func updateLocalLifetimeHighWater() {}
    func maskedAccount(for profile: CodexProfile) -> FeishuMaskedAccount? { .init(value: "masked-" + profile.id) }
    func sendFeishuNotification(
        event: FeishuSwitchNotification.Event, source: FeishuMaskedAccount, target: FeishuMaskedAccount?,
        quota: AutomaticSwitchQuotaState, factsSnapshot: UsageSnapshot?, eventID: UUID, isTest: Bool
    ) {
        precondition(isTest && target == nil)
        captured = (source, quota, factsSnapshot)
    }
    // PRODUCTION_METHODS
}

var checks = 0
var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: " + description)
    }
}
let base = Date(timeIntervalSince1970: 2_000_000)
func saved(_ id: String, count: Int?, used: Double = 80, offset: TimeInterval = 0, identityKnown: Bool = true) -> CodexAccountSnapshot {
    CodexAccountSnapshot(
        accountType: "chatgpt", planType: "plus", email: id + "@example.invalid", accountID: identityKnown ? "synthetic-" + id : nil,
        limitId: "codex", limitName: nil, fiveHour: nil,
        sevenDay: .init(RateWindow(usedPercent: used, windowDurationMins: 10_080, resetsAt: base.addingTimeInterval(604_800))),
        monthly: nil, availableResetCredits: count,
        resetCreditExpiries: count.map { $0 > 0 ? [base.addingTimeInterval(offset + 600)] : [] },
        fetchedAt: base.addingTimeInterval(offset), appServerVersion: nil)
}
func live(_ saved: CodexAccountSnapshot) -> UsageSnapshot {
    CodexSwitchSnapshotProjection.snapshot(
        saved: saved, identity: .init(email: saved.email!, accountID: saved.accountID!))
}
let accountA = CodexProfile(id: "a", lastSnapshot: saved("a", count: 9))
let accountB = CodexProfile(id: "b", lastSnapshot: saved("b", count: 2, used: 25, offset: 60))
let store = ProfileCreditDisplayStore([accountA, accountB], selected: "a", live: live(accountA.lastSnapshot!))
store.selectMonitorProfile("b")
expect(
    store.snapshot.credits == nil && store.multiRuntimeSnapshot.runtimes.isEmpty && store.refreshGeneration == 1,
    "real monitor selection clears shared runtime state and invalidates old refreshes")
expect(store.refreshRequests == 1 && store.selectedMonitorProfileID == "b", "selection queues the new read without changing Desktop credentials")
expect(store.availableResetCredits(for: accountB) == 2, "empty shared snapshot cannot hide selected account's verified cached credits")
expect(store.resetCreditExpiries(for: accountB) == accountB.lastSnapshot?.resetCreditExpiries, "empty shared snapshot cannot hide selected account expiries")
store.selectRuntime(.codex)
expect(store.availableResetCredits(for: accountB) == 2, "reselecting the visible Codex runtime keeps account-bound credits")
store.sendFeishuTestNotification()
expect(store.captured?.source.value == "masked-b", "captured test notification labels the selected account")
expect(
    store.captured?.facts?.credits?.resetCredits == 2 && store.captured?.quota.sevenDayRemaining == 75,
    "captured test notification uses the selected account's saved quota and credits")
expect(store.captured?.facts?.refreshedAt == accountB.lastSnapshot?.fetchedAt, "notification retains the observation's actual timestamp")

store.snapshot = live(accountB.lastSnapshot!)
store.multiRuntimeSnapshot = .init(runtimes: [.init(scope: .codex, snapshot: store.snapshot)])
let refreshedB = CodexProfile(id: "b", lastSnapshot: saved("b", count: 4, used: 10, offset: 120))
store.profileStore.profiles[1] = refreshedB
store.syncProfiles()
expect(store.snapshot.credits?.resetCredits == 2, "isolated profile refresh can leave the full runtime snapshot unchanged")
expect(store.availableResetCredits(for: refreshedB) == 4, "per-profile refresh exposes its new bound credit count immediately")
expect(store.resetCreditExpiries(for: refreshedB) == refreshedB.lastSnapshot?.resetCreditExpiries, "per-profile refresh exposes its bound expiry list")
store.sendFeishuTestNotification()
expect(
    store.captured?.facts?.credits?.resetCredits == 4 && store.captured?.quota.sevenDayRemaining == 90,
    "test notification follows the refreshed selected profile instead of stale runtime quota")

// A deliberately mismatched shared snapshot is an isolation boundary, not a
// claim that the current UI exposes another runtime or bypasses refresh guards.
store.snapshot = live(accountA.lastSnapshot!)
expect(store.availableResetCredits(for: refreshedB) == 4, "unbound shared credits cannot replace the selected profile's count")
expect(store.resetCreditExpiries(for: refreshedB) == refreshedB.lastSnapshot?.resetCreditExpiries, "unbound shared expiries cannot replace the selected profile's list")
store.sendFeishuTestNotification()
expect(
    store.captured?.source.value == "masked-b" && store.captured?.facts?.credits?.resetCredits == 4,
    "test source label and facts remain on one profile despite a mismatched shared snapshot")
expect(store.availableResetCredits(for: accountA) == 9, "unselected profile still uses its own saved observation")
let unknown = CodexProfile(id: "unknown", lastSnapshot: nil)
let unknownStore = ProfileCreditDisplayStore([unknown], selected: unknown.id, live: live(accountA.lastSnapshot!))
expect(
    unknownStore.availableResetCredits(for: unknown) == nil && unknownStore.resetCreditExpiries(for: unknown).isEmpty,
    "missing profile observation remains unknown without live fallback")
unknownStore.sendFeishuTestNotification()
expect(
    unknownStore.captured?.facts?.credits?.resetCredits == nil && unknownStore.captured?.quota.sevenDayRemaining == nil,
    "unknown profile sends no borrowed quota facts to the capture boundary")
let legacy = CodexProfile(id: "legacy", lastSnapshot: saved("legacy", count: 3, identityKnown: false))
let legacyStore = ProfileCreditDisplayStore([legacy], selected: legacy.id, live: live(accountA.lastSnapshot!))
legacyStore.sendFeishuTestNotification()
expect(
    legacyStore.captured?.facts?.credits?.resetCredits == nil && legacyStore.captured?.quota.sevenDayRemaining == nil,
    "missing saved account ID cannot produce account-attributed notification facts")
let zero = CodexProfile(id: "zero", lastSnapshot: saved("zero", count: 0))
expect(store.availableResetCredits(for: zero) == 0 && store.resetCreditExpiries(for: zero).isEmpty, "confirmed zero stays distinct from unknown")
store.feishuWebhookConfigured = false
store.captured = nil
store.sendFeishuTestNotification()
expect(store.captured == nil, "notification route guard remains required")
print("Profile credit display: \(checks) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)
