var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: " + name)
    }
}

let observed = Date(timeIntervalSince1970: 2_000_000)
let week: TimeInterval = 604_800
func snapshot(
    email: String? = "synthetic@example.invalid", accountID: String? = "synthetic-account",
    limit: String? = "codex", used: Double = 80, offset: TimeInterval = 0,
    resetOffset: TimeInterval = 604_800, succeeded: Bool? = true, duration: Int? = 10_080
) -> CodexAccountSnapshot {
    CodexAccountSnapshot(
        accountType: "chatgpt", planType: "plus", email: email, accountID: accountID,
        limitId: limit, limitName: nil, fiveHour: nil,
        sevenDay: .init(RateWindow(usedPercent: used, windowDurationMins: duration, resetsAt: observed.addingTimeInterval(resetOffset))),
        monthly: nil, fetchedAt: observed.addingTimeInterval(offset), appServerVersion: nil, quotaReadSucceeded: succeeded)
}
func profile(_ id: String, _ snapshot: CodexAccountSnapshot? = nil, system: Bool = false) -> CodexProfile {
    CodexProfile(
        id: id, name: "Synthetic account", codexHomePath: "/synthetic-profile/" + id,
        isSystemProfile: system, createdAt: observed, lastSnapshot: snapshot)
}
func credentials(_ profile: CodexProfile, email: String = "synthetic@example.invalid", accountID: String = "synthetic-account") {
    CodexOfficialProfileReader.identities[profile.codexHomePath] = .init(email: email, accountID: accountID)
}
func incoming(offset: TimeInterval = 0, succeeded: Bool = true) -> UsageSnapshot {
    UsageSnapshot(
        refreshedAt: observed.addingTimeInterval(offset),
        account: .init(type: "chatgpt", planType: "plus", emailPresent: true, email: "synthetic@example.invalid"),
        quotaReadSucceeded: succeeded,
        sevenDayQuota: .init(usedPercent: 30, windowDurationMins: 10_080, resetsAt: observed.addingTimeInterval(week)))
}

let system = profile("system", snapshot(), system: true)
credentials(system)
for (name, candidate) in [
    ("empty", profile("empty")),
    ("legacy email only", profile("legacy", snapshot(accountID: nil))),
    ("missing email", profile("missing-email", snapshot(email: nil))),
    ("empty account ID", profile("empty-id", snapshot(accountID: ""))),
    ("different email", profile("other-email", snapshot(email: "other@example.invalid"))),
    ("different account ID", profile("other-id", snapshot(accountID: "synthetic-other"))),
] {
    let store = ProfileFixtureStore([system, candidate])
    check(store.effectiveCredentialHome(for: candidate.id) == candidate.codexHomeURL, name + " keeps its own credential home")
}
let matched = profile("matched", snapshot(email: "  SYNTHETIC@example.invalid  "))
check(ProfileFixtureStore([system, matched]).effectiveCredentialHome(for: matched.id) == system.codexHomeURL, "verified mirror reuses system home")
let unboundSystem = profile("system", system: true)
let unboundManaged = profile("empty")
let unboundSelection = try ProfileFixtureStore([unboundSystem, unboundManaged]).selectMonitorForSystemAccount()
check(unboundSelection == "system", "unknown identities do not select an empty mirror")
let matchedSelection = try ProfileFixtureStore([system, matched]).selectMonitorForSystemAccount()
check(matchedSelection == matched.id, "verified system mirror remains selectable")

var unrelated = profile("unrelated")
unrelated.chromeProfile = "synthetic-chrome"
unrelated.automaticSwitchParticipation = false
unrelated.prioritizeDispatch = true
unrelated.proTierMultiplier = 20
unrelated.dispatchParticipationWindow = "synthetic-window"
let oldSystem = profile("system", snapshot(email: "old@example.invalid", accountID: "synthetic-old"), system: true)
let inheritance = ProfileFixtureStore([oldSystem, unrelated])
try inheritance.record(incoming(offset: 1), for: "system", allowSystemAccountChange: true)
let inherited = inheritance.state.profiles[0]
check(
    inherited.chromeProfile == nil && inherited.automaticSwitchParticipation == nil && inherited.prioritizeDispatch == nil
        && inherited.proTierMultiplier == nil && inherited.dispatchParticipationWindow == nil, "system change does not inherit an unbound profile's settings")
var exact = profile("exact", snapshot())
exact.chromeProfile = "synthetic-correct"
exact.automaticSwitchParticipation = false
exact.prioritizeDispatch = true
exact.proTierMultiplier = 10
exact.dispatchParticipationWindow = "synthetic-correct-window"
let exactInheritance = ProfileFixtureStore([oldSystem, unrelated, exact])
try exactInheritance.record(incoming(offset: 1), for: "system", allowSystemAccountChange: true)
check(
    exactInheritance.state.profiles[0].chromeProfile == exact.chromeProfile
        && exactInheritance.state.profiles[0].proTierMultiplier == exact.proTierMultiplier
        && exactInheritance.state.profiles[0].automaticSwitchParticipation == exact.automaticSwitchParticipation
        && exactInheritance.state.profiles[0].prioritizeDispatch == exact.prioritizeDispatch
        && exactInheritance.state.profiles[0].dispatchParticipationWindow == exact.dispatchParticipationWindow, "system change inherits only the verified matching profile")

let fresh = profile("fresh")
credentials(fresh)
let firstRead = ProfileFixtureStore([fresh])
try firstRead.record(incoming(), for: fresh.id, requestDispatchRegistration: true)
check(
    firstRead.state.profiles[0].lastSnapshot?.accountID == "synthetic-account"
        && firstRead.state.profiles[0].lastSnapshot?.quotaReadSucceeded == true
        && firstRead.state.profiles[0].dispatchRegistrationPending == true, "first local credential read still binds and registers")
let legacy = profile("legacy-local", snapshot(accountID: nil))
credentials(legacy)
let legacyRead = ProfileFixtureStore([legacy])
try legacyRead.record(incoming(offset: 1), for: legacy.id)
check(legacyRead.state.profiles[0].lastSnapshot?.accountID == "synthetic-account", "legacy profile binds from its own matching credential")

for previous in [nil, false, true] as [Bool?] {
    let candidate = profile("merge", snapshot(succeeded: previous))
    credentials(candidate)
    let store = ProfileFixtureStore([candidate])
    try store.record(incoming(succeeded: false), for: candidate.id, allowAccountOnly: true)
    check(store.state.profiles[0].lastSnapshot?.quotaReadSucceeded == (previous == true), "account-only merge preserves confirmed-success state " + String(describing: previous))
    try store.record(incoming(offset: 1), for: candidate.id)
    check(store.state.profiles[0].lastSnapshot?.quotaReadSucceeded == true, "later verified quota read succeeds " + String(describing: previous))
}
let unknown = profile("failure", snapshot(succeeded: nil))
credentials(unknown)
let failedRead = ProfileFixtureStore([unknown])
try failedRead.record(incoming(succeeded: false), for: unknown.id)
check(failedRead.state.profiles[0].lastQuotaReadFailureAt == observed, "unknown equal-time snapshot does not suppress a failure")
let verified = profile("verified", snapshot())
credentials(verified)
let duplicateFailure = ProfileFixtureStore([verified])
try duplicateFailure.record(incoming(succeeded: false), for: verified.id)
check(duplicateFailure.state.profiles[0].lastQuotaReadFailureAt == nil, "confirmed equal-time success is not downgraded")

func count(_ profiles: [CodexProfile]) -> Int {
    let store = ProfileFixtureStore(profiles)
    store.backfillResetCountersFromHistory()
    let count = store.state.resetCounters?["synthetic@example.invalid"]?.automaticCount ?? 0
    store.backfillResetCountersFromHistory()
    check((store.state.resetCounters?["synthetic@example.invalid"]?.automaticCount ?? 0) == count, "history backfill stays idempotent")
    return count
}
let before = profile("before", snapshot())
let after = profile("after", snapshot(used: 5, offset: 60, resetOffset: week + 60))
check(count([before, after]) == 1, "verified same-window quota drop backfills once")
check(count([before, profile("shifted", snapshot(used: 5, offset: 1_000, resetOffset: week + 1_000))]) == 1, "verified early new window backfills once")
check(count([before, profile("natural", snapshot(used: 5, offset: week + 60, resetOffset: week * 2))]) == 0, "natural window rollover is not a reset")
check(count([before, profile("copy", snapshot(offset: 60))]) == 0, "identical mirror readings are not resets")
check(count([before, profile("different-id", snapshot(accountID: "synthetic-other", used: 5, offset: 60))]) == 0, "different account IDs never form a history series")
check(count([before, profile("different-limit", snapshot(limit: "synthetic-other-limit", used: 5, offset: 60))]) == 0, "different quota limits never form a history series")
check(count([before, profile("missing-id", snapshot(accountID: nil, used: 5, offset: 60))]) == 0, "unknown identity cannot supply reset history")
check(count([before, profile("missing-limit", snapshot(limit: nil, used: 5, offset: 60))]) == 0, "unknown limit cannot supply reset history")
check(count([before, profile("failed", snapshot(used: 5, offset: 60, succeeded: false))]) == 0, "failed quota snapshot cannot supply reset history")
check(count([before, profile("unknown", snapshot(used: 5, offset: 60, succeeded: nil))]) == 0, "unknown quota snapshot cannot supply reset history")
var failedMirror = after
failedMirror.lastQuotaReadFailureAt = observed.addingTimeInterval(70)
check(count([before, failedMirror]) == 0, "failure after a mirror observation invalidates history")
check(count([before, profile("same-time-conflict", snapshot(used: 5))]) == 0, "conflicting same-time mirrors cannot infer order")
check(count([before, profile("same-time-copy", snapshot()), after]) == 1, "identical same-time mirrors collapse without losing a real drop")
check(count([before, profile("different-duration", snapshot(used: 5, offset: 60, duration: 300))]) == 0, "different quota durations cannot form a history series")

func liveStore(_ first: CodexAccountSnapshot = snapshot(), _ second: CodexAccountSnapshot = snapshot()) -> ProfileFixtureStore {
    let a = profile("live-a", first)
    let b = profile("live-b", second)
    credentials(a)
    credentials(b)
    return ProfileFixtureStore([a, b])
}
func recordReading(_ store: ProfileFixtureStore, _ id: String, used: Double, offset: TimeInterval, resetOffset: TimeInterval = 604_800) throws {
    var value = incoming(offset: offset)
    value.sevenDayQuota = RateWindow(usedPercent: used, windowDurationMins: 10_080, resetsAt: observed.addingTimeInterval(resetOffset))
    try store.record(value, for: id)
}
func automaticCount(_ store: ProfileFixtureStore) -> Int {
    store.state.resetCounters?["synthetic@example.invalid"]?.automaticCount ?? 0
}
let mirroredRollover = liveStore()
try recordReading(mirroredRollover, "live-a", used: 70, offset: week + 60, resetOffset: week * 2)
check(automaticCount(mirroredRollover) == 0, "natural rollover establishes a baseline without counting")
try recordReading(mirroredRollover, "live-b", used: 5, offset: week + 120, resetOffset: week * 2)
try recordReading(mirroredRollover, "live-a", used: 5, offset: week + 180, resetOffset: week * 2)
check(automaticCount(mirroredRollover) == 1, "verified drop after natural rollover counts once across mirrors")

let repeated = liveStore()
repeated.state.resetCounters = ["synthetic@example.invalid": CodexAccountResetCounter(automaticCount: 7, manualOffset: -2)]
try recordReading(repeated, "live-a", used: 5, offset: 60)
try recordReading(repeated, "live-b", used: 5, offset: 120)
check(automaticCount(repeated) == 8, "delayed mirror of one event does not count twice")
try recordReading(repeated, "live-a", used: 70, offset: 180)
try recordReading(repeated, "live-b", used: 5, offset: 240)
try recordReading(repeated, "live-a", used: 5, offset: 300)
check(automaticCount(repeated) == 9, "a later high-usage baseline permits a second real same-window drop")
check(repeated.state.resetCounters?["synthetic@example.invalid"]?.manualOffset == -2, "live observation preserves existing manual correction")

let naturalOnly = liveStore()
try recordReading(naturalOnly, "live-a", used: 5, offset: week + 60, resetOffset: week * 2)
try recordReading(naturalOnly, "live-b", used: 5, offset: week + 120, resetOffset: week * 2)
check(automaticCount(naturalOnly) == 0, "natural rollover on every mirror stays at zero")
let outOfOrder = liveStore()
try recordReading(outOfOrder, "live-a", used: 80, offset: 180)
try recordReading(outOfOrder, "live-b", used: 5, offset: 60)
check(automaticCount(outOfOrder) == 0, "older mirror result cannot count against a newer group baseline")
let conflict = liveStore(snapshot(offset: 60), snapshot(used: 5, offset: 60))
try recordReading(conflict, "live-a", used: 5, offset: 120)
check(automaticCount(conflict) == 0, "conflicting latest same-time observations do not infer a live reset")
for incompatible in [snapshot(accountID: "synthetic-other"), snapshot(accountID: nil), snapshot(limit: "other-limit"), snapshot(limit: nil)] {
    let store = liveStore(snapshot(), incompatible)
    try recordReading(store, "live-a", used: 5, offset: 60)
    check(automaticCount(store) == 0, "unknown or different identity/limit cannot supply a live group baseline")
}
let brokenInterval = liveStore()
brokenInterval.state.profiles[1].lastQuotaReadFailureAt = observed.addingTimeInterval(30)
try recordReading(brokenInterval, "live-a", used: 5, offset: 60)
check(automaticCount(brokenInterval) == 0, "a failure after the latest group observation breaks reset evidence")
let unknownLatest = liveStore(snapshot(), snapshot(offset: 30, succeeded: nil))
try recordReading(unknownLatest, "live-a", used: 5, offset: 60)
check(automaticCount(unknownLatest) == 0, "an unknown latest group observation cannot infer a live reset")
let firstMirror = profile("new-mirror")
credentials(firstMirror)
let firstMirrorStore = ProfileFixtureStore([profile("old-mirror", snapshot()), firstMirror])
try recordReading(firstMirrorStore, firstMirror.id, used: 5, offset: 60)
check(automaticCount(firstMirrorStore) == 0, "first observation on a new profile does not replay group history")

let warmupRequest = CodexWarmUpRequest(
    id: "synthetic-warmup-request", accountID: "synthetic-account", startedAt: observed,
    limitID: "codex", fiveHourResetAt: nil, sevenDayResetAt: observed.addingTimeInterval(week), source: "manual")
func pendingProfile(_ id: String) -> CodexProfile {
    var value = profile(id, snapshot())
    value.warmUpRequest = warmupRequest
    value.lastWarmUpAt = observed
    value.lastWarmUpSucceeded = false
    value.lastWarmUpFailureReason = "pending"
    credentials(value)
    return value
}
for succeeded in [false, true] {
    let primary = pendingProfile("warmup-primary")
    let validMirror = pendingProfile("warmup-valid")
    let changedMirror = pendingProfile("warmup-changed")
    let missingMirror = pendingProfile("warmup-missing")
    credentials(changedMirror, accountID: "synthetic-replaced")
    CodexOfficialProfileReader.identities.removeValue(forKey: missingMirror.codexHomePath)
    let store = ProfileFixtureStore([primary, validMirror, changedMirror, missingMirror])
    try store.recordWarmUp(
        at: observed.addingTimeInterval(10), succeeded: succeeded, failureReason: succeeded ? nil : "network",
        for: primary.id, requestID: warmupRequest.id, expectedAccountID: warmupRequest.accountID)
    check(
        store.state.profiles[0].lastWarmUpSucceeded == succeeded
            && store.state.profiles[0].lastWarmUpAt == observed.addingTimeInterval(10), "request owner records its confirmed result")
    check(
        store.state.profiles[1].lastWarmUpSucceeded == succeeded
            && store.state.profiles[1].lastWarmUpAt == observed.addingTimeInterval(10), "verified mirror records the same-account result")
    check(store.state.profiles[2] == changedMirror, "changed sibling credential cannot receive an old-account warmup result")
    check(store.state.profiles[3] == missingMirror, "unverified sibling credential cannot receive a warmup result")
}
let changedOwner = pendingProfile("changed-owner")
credentials(changedOwner, accountID: "synthetic-replaced")
let ownerStore = ProfileFixtureStore([changedOwner])
do {
    try ownerStore.recordWarmUp(
        at: observed.addingTimeInterval(10), succeeded: true, for: changedOwner.id,
        requestID: warmupRequest.id, expectedAccountID: warmupRequest.accountID)
    check(false, "changed owner must reject completion")
} catch { check(ownerStore.state.profiles[0] == changedOwner, "changed owner rejects completion without mutation") }

print("Profile identity/observation checks: \(checks); failures: \(failures)")
exit(failures == 0 ? 0 : 1)
