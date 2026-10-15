// Executed by test-reset-credit-observations-1013v1.py with production rules.
var failures = 0
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL " + name) }
}
func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
let now = date("2026-10-13T02:00:00Z")
func snapshot(
    _ count: Int?, at: Date, account: String? = "fixture-account",
    limit: String? = "codex", successful: Bool? = true
) -> CodexAccountSnapshot {
    CodexAccountSnapshot(
        accountType: "chatgpt", planType: "plus", email: nil, accountID: account,
        limitId: limit, limitName: nil, fiveHour: nil, sevenDay: nil, monthly: nil,
        availableResetCredits: count, fetchedAt: at, appServerVersion: nil,
        quotaReadSucceeded: successful)
}
func change(_ before: Int?, _ after: Int?) -> CodexResetCreditReceipt? {
    CodexResetCreditReceipt.change(
        previous: snapshot(before, at: now.addingTimeInterval(-60)),
        current: snapshot(after, at: now))
}
let increase = change(1, 3)!
let decrease = change(3, 1)!
let zero = change(1, 0)!
expect(increase.delta == 2 && increase.added == 2, "positive delta and old added projection")
expect(decrease.delta == -2 && decrease.added == 0 && decrease.isValid(at: now), "negative receipt remains valid")
expect(zero.delta == -1 && zero.available == 0, "confirmed zero count produces a decline")
expect(change(1, 1) == nil && change(nil, 3) == nil && change(3, nil) == nil, "unchanged and unknown counts")
expect(change(-1, 3) == nil && change(3, -1) == nil, "negative counts fail closed")
expect(change(Int.max, 0)?.delta == -Int.max && change(0, Int.max)?.delta == Int.max, "nonnegative extreme subtraction is safe")
let previous = snapshot(1, at: now.addingTimeInterval(-60))
expect(CodexResetCreditReceipt.change(previous: nil, current: snapshot(3, at: now)) == nil, "first snapshot establishes baseline")
for limit in [nil, "", "   "] as [String?] {
    expect(CodexResetCreditReceipt.change(
        previous: snapshot(1, at: previous.fetchedAt, limit: limit),
        current: snapshot(3, at: now, limit: limit)) == nil, "missing quota identity must not compare")
}
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now, limit: "other")) == nil, "changed quota identity")
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now, limit: " codex "))?.delta == 2, "quota identity normalization")
for success in [nil, false] as [Bool?] {
    expect(CodexResetCreditReceipt.change(previous: snapshot(1, at: previous.fetchedAt, successful: success), current: snapshot(3, at: now)) == nil, "legacy or failed previous read")
    expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now, successful: success)) == nil, "legacy or failed current read")
}
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now, account: "other-account")) == nil, "different verified accounts")
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now, account: nil)) == nil, "missing verified identity")
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: previous.fetchedAt)) == nil, "duplicate time")
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: previous.fetchedAt.addingTimeInterval(-1))) == nil, "older time")
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: Date(timeIntervalSince1970: .nan))) == nil, "nonfinite time")
expect(CodexResetCreditReceipt.increase(previous: previous, current: snapshot(3, at: now))?.delta == 2, "increase compatibility")
expect(CodexResetCreditReceipt.increase(previous: snapshot(3, at: previous.fetchedAt), current: snapshot(1, at: now)) == nil, "increase stays positive only")
let longChange = CodexResetCreditReceipt.change(previous: snapshot(3, at: now.addingTimeInterval(-7 * 86_400)), current: snapshot(1, at: now))
expect(longChange?.delta == -2, "trusted persistent snapshots can compare across long intervals")

let first = CodexProfile(id: "first", lastSnapshot: previous)
let latest = CodexProfile(id: "latest", lastSnapshot: snapshot(3, at: now.addingTimeInterval(-30)))
let current = snapshot(1, at: now)
expect(CodexResetCreditReceipt.change(previousProfiles: [first, latest], current: current)?.delta == -2, "account mirrors use latest observation once")
let unknown = CodexProfile(id: "unknown", lastSnapshot: snapshot(nil, at: now.addingTimeInterval(-10)))
expect(CodexResetCreditReceipt.change(previousProfiles: [first, latest, unknown], current: current) == nil, "latest unknown mirror blocks old successful counts")
let failed = CodexProfile(id: "failed", lastSnapshot: snapshot(3, at: now.addingTimeInterval(-10), successful: false))
expect(CodexResetCreditReceipt.change(previousProfiles: [first, latest, failed], current: current) == nil, "latest failed snapshot blocks mirror comparison")
var failureMirror = first
failureMirror.lastQuotaReadFailureAt = now.addingTimeInterval(-20)
expect(CodexResetCreditReceipt.change(previousProfiles: [failureMirror, latest], current: current) == nil, "failure after baseline blocks mirror comparison")
failureMirror.lastQuotaReadFailureAt = latest.lastSnapshot!.fetchedAt
expect(CodexResetCreditReceipt.change(previousProfiles: [failureMirror, latest], current: current) == nil, "failure at baseline time blocks comparison")
failureMirror.lastQuotaReadFailureAt = now.addingTimeInterval(-40)
expect(CodexResetCreditReceipt.change(previousProfiles: [failureMirror, latest], current: current)?.delta == -2, "successful recovery newer than failure resumes comparison")
var otherFailure = CodexProfile(id: "other", lastSnapshot: snapshot(99, at: now.addingTimeInterval(-1), account: "other-account"))
otherFailure.lastQuotaReadFailureAt = now
expect(CodexResetCreditReceipt.change(previousProfiles: [first, latest, otherFailure], current: current)?.delta == -2, "different account failures do not cross the identity boundary")
let tiedUnknown = CodexProfile(id: "tied", lastSnapshot: snapshot(nil, at: latest.lastSnapshot!.fetchedAt))
let tiedConflict = CodexProfile(id: "conflict", lastSnapshot: snapshot(99, at: latest.lastSnapshot!.fetchedAt))
expect(CodexResetCreditReceipt.change(previousProfiles: [first, latest, tiedUnknown], current: current) == nil, "same-time unknown cannot borrow another mirror")
expect(CodexResetCreditReceipt.change(previousProfiles: [first, latest, tiedConflict], current: current) == nil, "same-time conflicting counts cannot compare")
expect(CodexResetCreditReceipt.change(previousProfiles: [latest, first, tiedConflict], current: current) == nil, "mirror order does not change conflict handling")
let restoredBaseline = CodexProfile(id: "recovery", lastSnapshot: current)
expect(CodexResetCreditReceipt.change(previousProfiles: [unknown, failureMirror, restoredBaseline], current: snapshot(2, at: now.addingTimeInterval(1)))?.delta == 1, "recovery establishes the next baseline")

let encoded = try JSONEncoder().encode(increase)
let legacy = try JSONDecoder().decode(CodexResetCreditReceipt.self, from: encoded)
expect(legacy == increase && legacy.added == 2 && legacy.noticeChannels == nil, "original five stored fields decode unchanged")
let storedReceipt = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
expect(Set(storedReceipt.keys) == Set(["id", "previousObservedAt", "observedAt", "previousAvailable", "available"]), "computed delta does not change receipt schema")
let restoredDecrease = try JSONDecoder().decode(CodexResetCreditReceipt.self, from: JSONEncoder().encode(decrease))
expect(restoredDecrease == decrease, "signed receipt persists and reloads")
let intendedChannels = ["local", "feishu", "telegram", "wechat", "personal-wechat"]
let intended = CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now), noticeChannels: intendedChannels)!
let intendedReloaded = try JSONDecoder().decode(CodexResetCreditReceipt.self, from: JSONEncoder().encode(intended))
expect(intendedReloaded == intended && Set(intendedReloaded.noticeChannels!) == Set(intendedChannels), "enabled intent survives receipt reload")
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now), noticeChannels: ["telegram", "telegram"])?.noticeChannels == ["telegram"], "legal duplicate intent is deduplicated")
let disabledIntent = CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now), noticeChannels: [])!
let disabledReloaded = try JSONDecoder().decode(CodexResetCreditReceipt.self, from: JSONEncoder().encode(disabledIntent))
expect(disabledReloaded.noticeChannels == [], "no enabled channels stays distinct from legacy nil")
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now), noticeChannels: ["unknown"]) == nil, "unknown channel fails closed")
expect(CodexResetCreditReceipt.change(previous: previous, current: snapshot(3, at: now), noticeChannels: Array(repeating: "local", count: 6)) == nil, "channel input is bounded to five")
var unknownIntentJSON = storedReceipt
unknownIntentJSON["noticeChannels"] = ["unknown"]
expect((try? JSONDecoder().decode(CodexResetCreditReceipt.self, from: JSONSerialization.data(withJSONObject: unknownIntentJSON))) == nil, "unknown channel cannot enter persisted history")
unknownIntentJSON["noticeChannels"] = Array(repeating: "local", count: 6)
expect((try? JSONDecoder().decode(CodexResetCreditReceipt.self, from: JSONSerialization.data(withJSONObject: unknownIntentJSON))) == nil, "oversized channel list cannot enter persisted history")
var missingDate = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
missingDate.removeValue(forKey: "previousObservedAt")
expect((try? JSONDecoder().decode(CodexResetCreditReceipt.self, from: JSONSerialization.data(withJSONObject: missingDate))) == nil, "missing old date never gets fabricated")

let priorIncrease = CodexResetCreditReceipt(
    id: increase.id, previousObservedAt: increase.previousObservedAt,
    observedAt: now.addingTimeInterval(-30), previousAvailable: 1, available: 3)
var displayed = CodexProfile(id: "displayed", lastSnapshot: current, resetCreditHistory: [priorIncrease, decrease])
let summary = ResetCreditLocalSummary(profiles: [displayed], now: now)
expect(summary.latestChange?.delta == -2 && summary.latestIncrease?.added == 2, "latest signed history and old increase projection")
expect(summary.availableCards == 1, "receipt does not replace the latest snapshot count")
displayed.resetCreditHistory = [CodexResetCreditReceipt(id: UUID(), previousObservedAt: now, observedAt: now.addingTimeInterval(1), previousAvailable: 1, available: 3)]
expect(ResetCreditLocalSummary(profiles: [displayed], now: now).latestChange == nil, "future history cannot claim a current change")
expect(ResetCreditLocalSummary(profiles: [latest, unknown], now: now).availableCards == nil, "newest unknown summary does not reuse a mirror count")
expect(ResetCreditChangePresentation.title(increase, language: .zh) == "重置卡净变化 +2", "positive title")
expect(ResetCreditChangePresentation.title(decrease, language: .zh) == "重置卡净变化 -2", "negative title")
expect(ResetCreditChangePresentation.countLine(decrease, language: .zh) == "可用 3→1 次", "before and after count exactly once")
expect(ResetCreditChangePresentation.reasonLine(decrease, language: .zh) == "原因待核实", "decrease does not claim use or expiry")
expect(ResetCreditChangePresentation.reasonLine(increase, language: .zh) == nil, "increase does not infer a grant reason")
expect(ResetCreditChangePresentation.intervalLine(decrease, now: now, language: .zh) == "快照 09:59→10:00", "short same-day evidence interval")
expect(ResetCreditChangePresentation.intervalLine(longChange!, now: now, language: .zh) == "快照 10/06 10:00→10/13 10:00", "long evidence interval retains both dates")
let crossing = CodexResetCreditReceipt(id: UUID(), previousObservedAt: date("2026-12-31T15:50:00Z"), observedAt: date("2026-12-31T16:10:00Z"), previousAvailable: 3, available: 1)
expect(ResetCreditChangePresentation.intervalLine(crossing, now: now, language: .zh) == "快照 26/12/31 23:50→27/01/01 00:10", "cross-year evidence is unambiguous")
expect(PublicResetAnnouncementPresentation.eventTime(now, language: .zh, now: now) == "10:00", "announcement today uses short Beijing clock")
expect(PublicResetAnnouncementPresentation.compactEventTime(now, language: .en, now: now) == "10:00", "compact announcement shares short clock")
expect(PublicResetAnnouncementPresentation.eventTime(now.addingTimeInterval(-86_400), language: .zh, now: now) == "10/12 10:00", "older announcement keeps month and date")
let lastYear = date("2025-10-13T02:00:00Z")
expect(PublicResetAnnouncementPresentation.compactEventTime(lastYear, language: .zh, now: now) == "25/10/13 10:00", "cross-year announcement keeps abbreviated year")
expect(CodexQuotaEventTrackerSelfTest.run(), "existing tracker guards")
expect(MessageNoticeFormatSelfTest.run(), "shared formatter guards")

var tracker = CodexQuotaEventTracker()
func observation(_ at: Date, _ count: Int?) -> CodexQuotaEventTracker.Observation {
    .init(capturedAt: at, limitID: "codex", fiveHour: nil, sevenDay: nil, resetCredits: count)
}
_ = tracker.observe(observation(now.addingTimeInterval(-2701), 1), verifiedAccountID: "fixture-account", now: now.addingTimeInterval(-2701))
expect(tracker.observe(observation(now, 3), verifiedAccountID: "fixture-account", now: now).isEmpty, "45-minute tracker protection remains")
tracker.reset()
_ = tracker.observe(observation(now.addingTimeInterval(-2700), 1), verifiedAccountID: "fixture-account", now: now.addingTimeInterval(-2700))
expect(tracker.observe(observation(now, 3), verifiedAccountID: "fixture-account", now: now) == [.resetCreditsAdded(added: 2, available: 3)], "45-minute inclusive boundary stays compatible")
print("Receipt/tracker/UI observation rules: \(checks) checks; \(failures) failures")
exit(failures == 0 ? 0 : 1)
