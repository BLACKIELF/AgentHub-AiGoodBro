#!/usr/bin/env python3
"""Check actual pure notice payload builders without notification, account or network I/O."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
base = root / "Sources/CodexUsageWidget"


def read(path):
    return (base / path).read_text()


def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


feishu = read("Services/FeishuWebhookService.swift")
# Include only DTOs and pure builders: no sender, URLSession or Keychain code
# can execute in this fixture.
feishu_types = feishu.split("private final class FeishuRedirectGuard", 1)[0]
feishu_builders = (
    between(feishu, "    static func manualResetPayload(", "    func sendPublicResetAnnouncement(")
    +     between(feishu, "    static func publicResetPayload(", "    /// Sends an observer-confirmed")
    + between(feishu, "    static func taskCompletionPayload(", "    private func send(")
    + between(feishu, "    static func payloadData(", "    static func parseResponse(")
    + between(feishu, "    private struct NoticeInput {", "\n}\n\nprivate final class FeishuWebhookTestProtocol")
)
# Keep the production expiry admission rule, with a controllable clock only in
# this extracted offline fixture so the fixed 16:00 gallery stays reproducible.
expiry_guard = "!MessageNoticeFormat.validExpiry(batches, observedAt: Date())"
assert feishu_builders.count(expiry_guard) == 1
feishu_builders = feishu_builders.replace(expiry_guard,
    "!MessageNoticeFormat.validExpiry(batches, observedAt: noticeFixtureClock)")
announcement = between(read("Services/PublicResetAnnouncements.swift"), "struct PublicResetAnnouncement:", "struct PublicResetPage:")
public_source = read("Services/PublicResetAnnouncements.swift")
public_delivery = (
    between(public_source, "struct PublicResetPage:", "final class PublicResetRedirectGuard:")
    + between(public_source, "enum PublicResetHistoryRecovery {", "struct PublicResetDeliveryLock {")
)
public_client_values = between(public_source, "    static let siteURL =", "    func fetch(cursor:")
forecast = read("Services/PublicResetForecast.swift").split("/// An unsourced", 1)[0]
options = read("Domain/FeishuMessageOptions.swift").split("\nstruct CreditBalancePresentation", 1)[0]
batch = read("Domain/CodexResetNotice.swift").split("\nenum CodexResetNoticeChannel", 1)[0]
quota = read("Domain/CodexQuotaEventTracker.swift").split("/// Compares", 1)[0]
message = read("Domain/MessageChannel.swift")
message = message.split("/// Credentials are provided", 1)[0] + "\n" + message[message.index("/// Receipt of an accepted send."):]
publisher = between(read("Services/PublisherMessages.swift"), "struct PublisherMessage:", "struct PublisherMessageFeed:")
local_service = read("Services/NextLocalNotificationService.swift")
# Expose private pure values in the temporary fixture only. The production
# class is not instantiated; its lazy shared instance is never evaluated.
local_service = local_service.replace("private static func officialPayload(", "static func officialPayload(")
local_service = local_service.replace("private struct Payload:", "struct Payload:")
stubs = """import Foundation
enum WidgetLanguage { case zh, en
static func storedOrAutomatic() -> Self { .en }
func text(_ zh: String, _ en: String) -> String { self == .zh ? zh : en }
func dateTime(_ date: Date) -> String { "unused-fixture-date" }
}
struct RateWindow { let remainingPercent: Double; let resetsAt: Date? }
struct UsageSnapshot {
 struct Account { let planType: String? }
 struct Credits { struct Detail { let expiresAt: Date? }; let resetCredits: Int?; let resetCreditDetails: [Detail]? }
 let fiveHourQuota: RateWindow?; let sevenDayQuota: RateWindow?
 let account: Account?; let credits: Credits?
}
"""
stubs += "struct PublicResetClient {\n" + public_client_values + """
func fetch(cursor: String? = nil, timeout: TimeInterval = 20) async throws -> PublicResetPage {
    preconditionFailure("Network I/O is forbidden in this fixture")
}
}
"""
tests = r"""
var noticeFixtureClock = Date()
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func card(_ data: Data) throws -> (title: String, body: String) {
    let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let card = payload["card"] as! [String: Any]
    let header = card["header"] as! [String: Any]
    let title = (header["title"] as! [String: Any])["content"] as! String
    let elements = (card["body"] as! [String: Any])["elements"] as! [[String: Any]]
    return (title, elements.compactMap { $0["content"] as? String }.joined(separator: "\n"))
}
func hasOneFooter(_ body: String) -> Bool {
    let source = "消息来源：aigoodbro.com"
    return body.components(separatedBy: "\n").filter { $0 == source }.count == 1
        && body.hasSuffix(source)
}
func hasOneLocalFooter(_ body: String) -> Bool {
    body.components(separatedBy: "\n").filter { $0 == MessageNoticeFormat.footer }.count == 1
        && body.hasSuffix(MessageNoticeFormat.footer)
}
let now = Date()
var previews: [String: Data] = [:]
let previousAt = now.addingTimeInterval(-1800)
let account = try FeishuMaskedAccount(displayName: "Work account")

let manual = CodexManualResetNotice(eventHash: String(repeating: "a", count: 64), profileHash: String(repeating: "b", count: 64), confirmedAt: now)
for language in [WidgetLanguage.zh, .en] {
    let data = try FeishuWebhookService.manualResetPayload(manual, sourceAccount: account, language: language)
    let parsed = try card(data)
    expect(parsed.title.contains(language.text("手动使用成功", "Manual use succeeded")), "manual success title")
    expect(parsed.body.contains(language.text("手动使用 1 张", "Manually used 1")), "explicit manual action")
    expect(parsed.body.contains(language.text("官方已确认重置成功", "Official service confirmed")), "official success truth")
    expect(!parsed.body.contains("未核实") && !parsed.body.contains("unverified"), "confirmed action not mislabeled unknown")
    expect(!parsed.body.contains(manual.eventHash) && !parsed.body.contains(manual.profileHash), "internal hashes not rendered")
    expect(!parsed.body.contains("5h") && !parsed.body.contains("7d"), "no fabricated quota window")
    expect(hasOneFooter(parsed.body), "manual notice source footer")
    previews[language == .zh ? "manual-reset-zh" : "manual-reset-en"] = data
}
var hiddenManualOptions = FeishuMessageOptions.standard
hiddenManualOptions.includesAccountLabel = false
hiddenManualOptions.includesAgentName = false
let hiddenManual = try card(FeishuWebhookService.manualResetPayload(manual, sourceAccount: account, messageOptions: hiddenManualOptions, language: .en)).body
expect(!hiddenManual.contains("Work account") && !hiddenManual.contains("Agent"), "manual options hide account and agent")
do {
    _ = try FeishuWebhookService.manualResetPayload(.init(eventHash: "raw-id", profileHash: manual.profileHash, confirmedAt: now), sourceAccount: account)
    preconditionFailure("invalid manual metadata accepted")
} catch FeishuWebhookError.invalidNotification {}
let yearBefore = ISO8601DateFormatter().date(from: "2026-12-31T15:50:00Z")!
let yearAfter = ISO8601DateFormatter().date(from: "2026-12-31T16:10:00Z")!
let yearFacts = try FeishuAccountFacts(fiveHour: .finite(remainingPercent: 100, resetsAt: yearAfter.addingTimeInterval(3600)),
    sevenDay: .unknown, availableResetCredits: 2, resetCreditExpiries: [])
let yearComparison = CodexResetCreditComparison(previousAvailable: 3, available: 2, previousObservedAt: yearBefore, observedAt: yearAfter)
let yearNotice = try FeishuSwitchNotification(event: .quotaChange(.quotaReset(fiveHour: true, sevenDay: false)),
    sourceAccount: account, triggerThresholdPercent: 15, fiveHourRemainingPercent: 100, sevenDayRemainingPercent: nil,
    accountFacts: yearFacts, resetCreditComparison: yearComparison, occurredAt: yearAfter)
for language in [WidgetLanguage.zh, .en] {
    let body = try card(FeishuWebhookService.payloadData(for: yearNotice, language: language)).body
    expect(body.contains("12/31 23:50 → 01/01 00:10") && body.contains("01/01 01:10"), "Feishu cross-year dates lost month/day")
    expect(body.range(of: #"\b(?:\d{4}|\d{2})/\d{2}/\d{2} \d{2}:\d{2}\b"#, options: .regularExpression) == nil, "Feishu generated dates still include a year")
}
expect(yearNotice.occurredAt == yearAfter && yearNotice.resetCreditComparison == yearComparison, "date presentation changed stored Feishu fact timestamps")
print("PASS no-year Feishu dates: bilingual cross-year comparisons/resets; stored dates preserved")
func notification(_ event: CodexQuotaEvent, options: FeishuMessageOptions = .standard) throws -> FeishuSwitchNotification {
    let available: Int?
    switch event {
    case .resetCreditsAdded(_, let count), .resetCreditsChanged(_, let count, _, _): available = count
    default: available = nil
    }
    let facts = try FeishuAccountFacts(fiveHour: .finite(remainingPercent: 30, resetsAt: now.addingTimeInterval(60)),
        sevenDay: .unknown, availableResetCredits: available, resetCreditExpiries: [])
    return try FeishuSwitchNotification(event: .quotaChange(event), sourceAccount: account,
        triggerThresholdPercent: 15, fiveHourRemainingPercent: 30, sevenDayRemainingPercent: nil,
        accountFacts: facts, messageOptions: options, occurredAt: now)
}
for (before, after, sign) in [(1, 3, "+2"), (3, 1, "-2"), (1, 0, "-1")] {
    let event = CodexQuotaEvent.resetCreditsChanged(previous: before, available: after, previousObservedAt: previousAt, observedAt: now)
    let payload = try card(FeishuWebhookService.payloadData(for: notification(event), language: .zh))
    expect(payload.title.contains(sign), "Feishu signed delta missing")
    expect(payload.body.contains("\(before)→\(after) 张") && payload.body.contains(MessageNoticeFormat.fullDate(previousAt))
        && payload.body.contains(MessageNoticeFormat.fullDate(now)), "Feishu snapshot balance or full evidence times missing")
    expect(payload.body.contains("减少原因未确认") == (after < before), "Feishu decrease reason misstated")
    expect(!payload.body.contains("已到账") && !payload.body.contains("已使用") && hasOneFooter(payload.body), "Feishu cause or footer incorrect")
    let local = NextLocalNotificationService.officialPayload(event, language: .zh, now: now)!
    expect(local.title.contains(sign) && local.body.contains("\(before)→\(after)") && hasOneLocalFooter(local.body), "local delta or footer missing")
    expect(!local.body.contains("Work account") && !local.body.contains("已使用"), "local notification leaks account or assumes usage")
}
let batches = [
    CodexResetCreditExpiryBatch(expiresAt: now.addingTimeInterval(23 * 3600), count: 2),
    CodexResetCreditExpiryBatch(expiresAt: now.addingTimeInterval(90 * 60), count: 1)
]
let expiry = CodexQuotaEvent.resetCreditsExpiring(batches: batches, observedAt: now)
var allExpiryOptions = FeishuMessageOptions.standard
allExpiryOptions.resetExpiryDetail = .all
let expiring = try card(FeishuWebhookService.payloadData(for: notification(expiry, options: allExpiryOptions), language: .zh))
for batch in batches {
    expect(expiring.body.contains(MessageNoticeFormat.fullDate(batch.expiresAt)) && expiring.body.contains("\(batch.count) 张"), "Feishu expiry batch missing")
}
let nearestExpiring = try card(FeishuWebhookService.payloadData(for: notification(expiry), language: .zh))
expect(nearestExpiring.body.contains(MessageNoticeFormat.fullDate(batches[1].expiresAt))
    && !nearestExpiring.body.contains(MessageNoticeFormat.fullDate(batches[0].expiresAt)), "nearest expiry option disclosed another batch")
expect(hasOneFooter(expiring.body) && !expiring.body.contains("已到账") && !expiring.body.contains("已使用"), "Feishu expiry claims or footer incorrect")
let localExpiry = NextLocalNotificationService.officialPayload(expiry, language: .zh, now: now)!
expect(localExpiry.body.contains("余23h") && localExpiry.body.contains("余1h30m") && hasOneLocalFooter(localExpiry.body), "local exact expiry facts missing")
let expired = CodexQuotaEvent.resetCreditsExpiring(batches: [.init(expiresAt: now.addingTimeInterval(-1), count: 1)], observedAt: now.addingTimeInterval(-60))
let expiredNotice = try notification(expired)
do { _ = try FeishuWebhookService.payloadData(for: expiredNotice, language: .zh); preconditionFailure("expired Feishu notice accepted") }
catch FeishuWebhookError.invalidNotification {}
expect(NextLocalNotificationService.officialPayload(expired, language: .zh, now: now) == nil, "expired local notice accepted")
let observedEarlier = now.addingTimeInterval(-60)
let crossing = CodexQuotaEvent.resetCreditsExpiring(batches: [.init(expiresAt: observedEarlier.addingTimeInterval(24 * 3600 + 30), count: 1)], observedAt: observedEarlier)
let crossingCard = try card(FeishuWebhookService.payloadData(for: notification(crossing), language: .zh))
expect(crossingCard.body.contains("1 张") && hasOneFooter(crossingCard.body), "Feishu rejected a cached expiry entering the 24h window")
expect(crossingCard.body.contains("**核对时间（北京时间）**：" + MessageNoticeFormat.fullDate(observedEarlier)), "Feishu replaced original check time with dispatch time")
expect(NextLocalNotificationService.officialPayload(crossing, language: .zh, now: now) != nil, "local rejected a cached expiry entering the 24h window")
let outside = CodexQuotaEvent.resetCreditsExpiring(batches: [.init(expiresAt: now.addingTimeInterval(24 * 3600 + 30), count: 1)], observedAt: now)
do { _ = try FeishuWebhookService.payloadData(for: notification(outside), language: .zh); preconditionFailure("Feishu expiry beyond 24h accepted") }
catch FeishuWebhookError.invalidNotification {}
expect(NextLocalNotificationService.officialPayload(outside, language: .zh, now: now) == nil, "local expiry beyond 24h accepted")
expect(NextLocalNotificationService.officialPayload(.quotaReset(fiveHour: false, sevenDay: false), language: .zh, now: now) == nil, "empty window accepted")

let added = try card(FeishuWebhookService.payloadData(for: notification(.resetCreditsAdded(added: 2, available: 3)), language: .zh))
expect(added.title.contains("+2") && added.body.contains("1→3") && hasOneFooter(added.body), "legacy reset-added compatibility failed")
var hidden = FeishuMessageOptions.standard
hidden.includesResetCredits = false
let hiddenCard = try card(FeishuWebhookService.payloadData(for: notification(.resetCreditsChanged(previous: 1, available: 3, previousObservedAt: previousAt, observedAt: now), options: hidden), language: .zh))
expect(!hiddenCard.title.contains("+2") && !hiddenCard.body.contains("1→3"), "hidden reset balance rendered")

let ordinary: [FeishuSwitchNotification.Event] = [.test, .lowQuotaDetected, .switchSucceeded, .switchFailed(.unknown), .quotaChange(.quotaReset(fiveHour: true, sevenDay: false))]
for event in ordinary {
    let dto = try FeishuSwitchNotification(event: event, sourceAccount: account, targetAccount: account,
        triggerThresholdPercent: 15, fiveHourRemainingPercent: 4, sevenDayRemainingPercent: 12, occurredAt: now)
    let payload = try card(FeishuWebhookService.payloadData(for: dto, language: .zh))
    expect(hasOneFooter(payload.body) && payload.body.contains(MessageNoticeFormat.fullDate(now)), "ordinary Feishu full time or footer missing")
}
func windowNotification(
    before: Int?, after: Int, options: FeishuMessageOptions = .standard,
    fiveHour: Bool = true, sevenDay: Bool = false,
    suppressRepeatedManualComparison: Bool = false
) throws -> FeishuSwitchNotification {
    let facts = try FeishuAccountFacts(
        fiveHour: .finite(remainingPercent: 100, resetsAt: now.addingTimeInterval(18000)),
        sevenDay: .finite(remainingPercent: 82, resetsAt: now.addingTimeInterval(259200)),
        availableResetCredits: after, resetCreditExpiries: [now.addingTimeInterval(7 * 86400)])
    let comparison = before.map { CodexResetCreditComparison(
        previousAvailable: $0, available: after, previousObservedAt: previousAt, observedAt: now) }
    return try FeishuSwitchNotification(
        event: .quotaChange(.quotaReset(fiveHour: fiveHour, sevenDay: sevenDay)), sourceAccount: account,
        triggerThresholdPercent: 15, fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 82,
        accountFacts: facts, resetCreditComparison: comparison,
        suppressResetCreditComparison: suppressRepeatedManualComparison,
        messageOptions: options, occurredAt: now)
}
for (before, after, expected) in [(3, 2, "减少 1 张"), (2, 2, "无变化"), (0, 1, "增加 1 张"), (1, 0, "减少 1 张"), (0, 0, "无变化")] {
    let data = try FeishuWebhookService.payloadData(for: windowNotification(before: before, after: after), language: .zh)
    let payload = try card(data)
    expect(payload.title.contains("5小时额度变化") && !payload.title.contains("7天"), "window title missing selected type")
    expect(payload.body.contains("\(before)→\(after) 张（\(expected)）"), "window net comparison missing")
    expect(payload.body.contains(MessageNoticeFormat.fullDate(previousAt)) && payload.body.contains(MessageNoticeFormat.fullDate(now)), "comparison evidence dates missing")
    expect(payload.body.contains("减少原因未确认") == (after < before), "window decrease cause misstated")
    expect(!payload.body.contains("另行核对") && !payload.body.contains("打开 AiGoodBro") && !payload.body.contains("已核实"), "window generic filler survived")
    expect(!payload.body.contains("已使用") && !payload.body.contains("已到账") && hasOneFooter(payload.body), "window overclaims cause or repeats footer")
    previews["window-\(before)-to-\(after)"] = data
}
let noPrevious = try FeishuWebhookService.payloadData(for: windowNotification(before: nil, after: 2), language: .zh)
let noPreviousCard = try card(noPrevious)
expect(noPreviousCard.body.contains("上次有效数量缺失，净变化未知"), "missing baseline invented a delta")
previews["window-no-previous"] = noPrevious
for language in [WidgetLanguage.zh, .en] {
    let dto = try windowNotification(before: 1, after: 0, fiveHour: false, sevenDay: true,
        suppressRepeatedManualComparison: true)
    expect(dto.resetCreditComparison?.previousAvailable == 1 && dto.resetCreditComparison?.available == 0,
        "manual follow-up erased the actual count evidence")
    let data = try FeishuWebhookService.payloadData(for: dto, language: language)
    let payload = try card(data)
    expect(!payload.body.contains("上次有效数量缺失") && !payload.body.contains("net change unknown")
        && !payload.body.contains("减少原因未确认") && !payload.body.lowercased().contains("unconfirmed")
        && !payload.body.contains("1→0"), "confirmed manual follow-up rendered a duplicate or false unknown")
    expect(payload.body.contains(language.text("0 张", "0")) && payload.body.contains("82%")
        && payload.body.contains(MessageNoticeFormat.fullDate(now)) && hasOneFooter(payload.body),
        "manual follow-up lost current balance, quota, check time or footer")
    expect(!payload.body.contains("手动使用成功") && !payload.body.contains("Manual use succeeded"),
        "quota follow-up duplicated manual operation success")
    previews[language == .zh ? "manual-followup-zh" : "manual-followup-en"] = data
}
let partialFacts = try FeishuAccountFacts(fiveHour: .unknown,
    sevenDay: .finite(remainingPercent: 100, resetsAt: now.addingTimeInterval(7 * 86400)),
    availableResetCredits: 0, resetCreditExpiries: [])
let partialFollowup = try FeishuSwitchNotification(
    event: .quotaChange(.quotaReset(fiveHour: false, sevenDay: true)), sourceAccount: account,
    triggerThresholdPercent: 15, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: 100,
    accountFacts: partialFacts,
    resetCreditComparison: .init(previousAvailable: 1, available: 0, previousObservedAt: previousAt, observedAt: now),
    suppressResetCreditComparison: true, occurredAt: now)
let partialCard = try card(FeishuWebhookService.payloadData(for: partialFollowup, language: .zh))
expect(partialCard.body.contains("**5h**：未知") && partialCard.body.contains("100%")
    && !partialCard.body.contains("上次有效数量缺失"), "manual follow-up invented missing quota or count evidence")
for (before, after) in [(nil as Int?, 0), (1, 1), (2, 0), (0, 1)] {
    do {
        _ = try windowNotification(before: before, after: after, suppressRepeatedManualComparison: true)
        preconditionFailure("manual comparison suppression accepted missing or unrelated evidence")
    } catch FeishuWebhookError.invalidNotification {}
}
let hiddenManualFollowup = try card(FeishuWebhookService.payloadData(
    for: windowNotification(before: 1, after: 0, options: hidden, suppressRepeatedManualComparison: true), language: .zh))
expect(!hiddenManualFollowup.body.contains("重置卡") && !hiddenManualFollowup.body.contains("1→0"),
    "manual follow-up ignored reset-credit privacy")
for (fiveHour, sevenDay, title) in [(false, true, "7天额度变化"), (true, true, "5小时 + 7天额度变化")] {
    let data = try FeishuWebhookService.payloadData(for: windowNotification(before: 2, after: 2, fiveHour: fiveHour, sevenDay: sevenDay), language: .zh)
    let payload = try card(data)
    expect(payload.title == title && payload.body.contains("2→2 张（无变化）"), "selected window title or zero comparison lost")
    previews[fiveHour ? "window-both" : "window-7d"] = data
}
let hiddenWindow = try card(FeishuWebhookService.payloadData(for: windowNotification(before: 3, after: 2, options: hidden), language: .zh))
expect(!hiddenWindow.body.contains("3→2") && !hiddenWindow.body.contains("重置卡") && !hiddenWindow.body.contains("减少原因"), "window reset-credit opt-out ignored")
var minimalOptions = FeishuMessageOptions.standard
minimalOptions.includesAccountLabel = false
minimalOptions.includesAgentName = false
minimalOptions.includesQuotas = false
minimalOptions.includesResetTimes = false
minimalOptions.includesResetCredits = false
let minimal = try card(FeishuWebhookService.payloadData(for: windowNotification(before: 3, after: 2, options: minimalOptions), language: .zh))
expect(minimal.title == "5小时额度变化" && !minimal.body.contains("Work account") && !minimal.body.contains("Codex") && !minimal.body.contains("100%"), "window privacy/display switches ignored")
var agentOptions = FeishuMessageOptions.standard
agentOptions.includesAgentName = true
let agentCard = try card(FeishuWebhookService.payloadData(for: windowNotification(before: 2, after: 2, options: agentOptions), language: .zh))
expect(agentCard.title == "5小时额度变化" && agentCard.body.components(separatedBy: "**Agent**").count == 2
    && agentCard.body.contains("Codex"), "Agent option missing or duplicated")
do { _ = try windowNotification(before: -1, after: 2); preconditionFailure("negative comparison accepted") }
catch FeishuWebhookError.invalidNotification {}
let conflictFacts = try FeishuAccountFacts(fiveHour: .unknown, sevenDay: .unknown, availableResetCredits: 99, resetCreditExpiries: [])
do {
    _ = try FeishuSwitchNotification(event: .quotaChange(.quotaReset(fiveHour: true, sevenDay: false)), sourceAccount: account,
        triggerThresholdPercent: 15, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: nil, accountFacts: conflictFacts,
        resetCreditComparison: .init(previousAvailable: 3, available: 2, previousObservedAt: previousAt, observedAt: now), occurredAt: now)
    preconditionFailure("comparison conflicts with official current facts")
} catch FeishuWebhookError.invalidNotification {}
let publicEvent = PublicResetAnnouncement(id: "123", resetType: .banked, announcedAt: now,
    text: "Day 15/ Synthetic reset announcement. Enjoy. evil.invalid /private [label](https://evil.invalid)", source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/123")))
let publicData = try FeishuWebhookService.publicResetPayload(publicEvent, language: .zh)
let publicCard = try card(publicData)
expect(publicCard.body.contains("Day 15/ Synthetic reset announcement. Enjoy.") && !publicCard.body.contains("evil.invalid") && !publicCard.body.contains("/private"), "safe public wording lost or unsafe destination retained")
expect(publicCard.body.contains(MessageNoticeFormat.fullDate(now)) && publicCard.body.contains("北京时间") && !publicCard.body.contains("https:") && !publicCard.body.contains("x.com") && hasOneFooter(publicCard.body), "public announcement complete time or brand source incorrect")
expect(!publicCard.body.contains("接下来") && !publicCard.body.contains("公告类型") && !publicCard.body.contains("public-announcement"), "public filler survived")
previews["public-announcement"] = publicData
let literalDatedSource = "Original 2026年12月31日 23:50.\n\nKeep 2027年1月1日 00:10."
let literalEvent = PublicResetAnnouncement(id: publicEvent.id, resetType: .regular, announcedAt: now,
    text: literalDatedSource, source: publicEvent.source)
let literalContext = try PublicResetContext(announcement: literalEvent, now: now)
let literalCard = try card(FeishuWebhookService.publicResetPayload(literalEvent, language: .zh))
expect(literalContext.publicText.contains("2026年12月31日") && literalContext.publicText.contains("2027年1月1日")
    && literalCard.body.contains(literalContext.publicText + "\n\n") && literalCard.body.contains(MessageNoticeFormat.fullDate(now)), "Feishu date display rewrote the accepted source paragraph")
print("PASS dated public source paragraphs preserved verbatim")
let marker = PublicResetAnnouncement(id: publicEvent.id, resetType: publicEvent.resetType,
    announcedAt: publicEvent.announcedAt, text: "public-announcement", source: publicEvent.source)
do { _ = try FeishuWebhookService.publicResetPayload(marker, language: .zh); preconditionFailure("marker sent as announcement") }
catch FeishuWebhookError.invalidNotification {}
var publicLedger = PublicResetDeliveryLedger()
publicLedger.initialized = true
publicLedger.records = [publicEvent.id: .pending, "124": .baseline]
publicLedger.hydrate([publicEvent])
let durable = try JSONEncoder().encode(publicLedger)
expect(!String(data: durable, encoding: .utf8)!.contains("Synthetic reset"), "original announcement text persisted")
publicLedger = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: durable)
expect(publicLedger.pendingAnnouncements(from: [publicEvent], now: now) == [publicEvent], "pending marker failed to rebind validated original")
expect(publicLedger.pendingAnnouncements(from: [], now: now).isEmpty && publicLedger.records[publicEvent.id] == .pending, "unresolved marker consumed a send reservation")
expect(publicLedger.pendingAnnouncements(from: [marker], now: now).isEmpty, "source marker treated as original text")
let mismatch = PublicResetAnnouncement(id: publicEvent.id, resetType: .regular, announcedAt: publicEvent.announcedAt, text: "changed", source: publicEvent.source)
expect(publicLedger.pendingAnnouncements(from: [mismatch], now: now).isEmpty, "stored tuple mismatch accepted")
let head = PublicResetAnnouncement(id: "124", resetType: .regular, announcedAt: now.addingTimeInterval(1), text: "Synthetic head",
    source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/124")))
func publicPage(_ data: [PublicResetAnnouncement], cursor: String? = nil) -> PublicResetPage {
    .init(data: data, pagination: .init(hasMore: cursor != nil, nextCursor: cursor), meta: .init(apiVersion: "v1", generatedAt: now))
}
var recoveredCursors: [String] = []
let recovered = await PublicResetHistoryRecovery.recover(first: publicPage([head], cursor: "older"), ledgers: [publicLedger]) { cursor, _ in
    recoveredCursors.append(cursor)
    return publicPage([publicEvent])
}
expect(recoveredCursors == ["older"] && publicLedger.pendingAnnouncements(from: recovered.recoveredRows, now: now) == [publicEvent], "existing stored marker skipped source recovery")
publicLedger.records[publicEvent.id] = .uncertain
expect(publicLedger.pendingAnnouncements(from: [publicEvent], now: now).isEmpty, "uncertain announcement replayed")
let postID = PublicResetForecast.sourcePostID(at: now.addingTimeInterval(-60))!
let postTime = PublicResetForecast.sourcePostDate(for: postID)!
let forecast = PublicResetForecast(id: postID, latestBy: now.addingTimeInterval(3600), announcedAt: postTime,
    sourceURL: URL(string: "https://x.com/thsottiaux/status/" + postID)!, fetchedAt: now)
let forecastCard = try card(FeishuWebhookService.publicResetForecastPayload(PublicResetForecastNotification(forecast, referenceDate: now), language: .zh))
expect(forecastCard.body.contains(MessageNoticeFormat.fullDate(forecast.latestBy!)) && hasOneFooter(forecastCard.body), "forecast expiry time or footer missing")
expect(forecastCard.title == "Codex 重置预告" && forecastCard.body.contains("尚未确认重置完成"), "forecast identity or confirmation boundary missing")
expect(forecastCard.body.contains("北京时间") && !forecastCard.body.contains("https:") && !forecastCard.body.contains("x.com") && !forecastCard.body.contains("codex-resets.com"), "forecast leaks external source or lost time zone")
expect(!forecastCard.body.contains("到账") && !forecastCard.body.contains("Reset 卡") && forecastCard.body.contains("重置卡"), "forecast wording confuses preannouncement with account changes")
let undatedForecast = PublicResetForecast(id: postID, latestBy: nil, announcedAt: postTime,
    sourceURL: forecast.sourceURL, fetchedAt: now)
let undatedForecastCard = try card(FeishuWebhookService.publicResetForecastPayload(PublicResetForecastNotification(undatedForecast, referenceDate: now), language: .zh))
expect(undatedForecastCard.body.contains("预告时间**：尚未确定") && undatedForecastCard.body.contains("尚未确认重置完成"), "undated forecast invents a schedule or confirmation")
let englishForecastCard = try card(FeishuWebhookService.publicResetForecastPayload(PublicResetForecastNotification(forecast, referenceDate: now), language: .en))
expect(englishForecastCard.body.contains("UTC+8") && hasOneFooter(englishForecastCard.body) && englishForecastCard.body.contains("has not been confirmed"), "English forecast loses brand source or confirmation boundary")
let completion = try FeishuTaskCompletionNotification(eventID: UUID(), proof: .confirmedByTaskObserver,
    category: .dispatchedAgent, occurredAt: now, now: now)
let completed = try card(FeishuWebhookService.taskCompletionPayload(completion, language: .zh))
expect(completed.title == "Codex 运行结束" && !completed.body.contains("完成验收") && hasOneFooter(completed.body), "task ended overclaims acceptance or footer missing")
expect(NextLocalNotificationService.selfTest(), "local privacy and authorization policy self-test failed")
if let flag = CommandLine.arguments.firstIndex(of: "--preview-dir"), flag + 1 < CommandLine.arguments.count {
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sampleAt = ISO8601DateFormatter().date(from: "2026-10-20T08:00:00Z")!
    noticeFixtureClock = sampleAt
    let samplePreviousAt = sampleAt.addingTimeInterval(-1800)
    let sampleAccount = try FeishuMaskedAccount(displayName: "示例账号 01")
    let sampleTarget = try FeishuMaskedAccount(displayName: "示例账号 02")
    func sampleFacts(_ available: Int, fiveHour: Double = 100, sevenDay: Double = 82) throws -> FeishuAccountFacts {
        try .init(
            fiveHour: .finite(remainingPercent: fiveHour, resetsAt: sampleAt.addingTimeInterval(5 * 3600)),
            sevenDay: .finite(remainingPercent: sevenDay, resetsAt: sampleAt.addingTimeInterval(3 * 86400)),
            availableResetCredits: available,
            resetCreditExpiries: available == 0 ? [] : [sampleAt.addingTimeInterval(3 * 3600), sampleAt.addingTimeInterval(23 * 3600)])
    }
    func sampleNotice(
        _ event: FeishuSwitchNotification.Event, target: FeishuMaskedAccount? = nil,
        available: Int = 2, fiveHour: Double = 100, sevenDay: Double = 82,
        comparison: CodexResetCreditComparison? = nil
    ) throws -> Data {
        let value = try FeishuSwitchNotification(
            event: event, sourceAccount: sampleAccount, targetAccount: target,
            triggerThresholdPercent: 15, fiveHourTriggerThresholdPercent: 5,
            fiveHourRemainingPercent: fiveHour, sevenDayRemainingPercent: sevenDay,
            accountFacts: sampleFacts(available, fiveHour: fiveHour, sevenDay: sevenDay),
            resetCreditComparison: comparison, occurredAt: sampleAt)
        return try FeishuWebhookService.payloadData(for: value, language: .zh)
    }
    var samples: [[String: Any]] = []
    var sampleMarkdown = "# 飞书消息样例 · 1020v3\n\n以下均为演示，不是真实账号或真实通知。账号固定为示例账号 01/02；核对时间固定为北京时间 10/20 16:00。公告正文引用本次会话已核对的原句，公告日期和内部 ID 为模拟，不代表实时公告或个人到账。JSON 由生产 payload builder 生成；未读取账号、未调用钥匙串、未发送飞书。\n\n单独的重置卡零变化不是现有事件类型；样例通过额度窗口卡中的前后快照展示“无变化”。任务结束仅列实际支持的三类。\n"
    let payloadDirectory = directory.appendingPathComponent("feishu-payloads", isDirectory: true)
    try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
    func addSample(_ id: String, _ category: String, _ data: Data) throws {
        let value = try card(data)
        expect(hasOneFooter(value.body), "sample source footer missing or duplicated: " + id)
        expect(!value.body.contains("https:") && !value.body.contains("x.com") && !value.body.contains("codex-resets.com"), "sample contains external destination: " + id)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        samples.append(["id": id, "title": value.title, "category": category, "payload": object])
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try pretty.write(to: payloadDirectory.appendingPathComponent(id + ".json"), options: .atomic)
        sampleMarkdown += "\n## " + id + " · 模拟\n\n" + value.title + "\n\n" + value.body + "\n"
    }
    let sampleManual = CodexManualResetNotice(eventHash: String(repeating: "a", count: 64), profileHash: String(repeating: "b", count: 64), confirmedAt: sampleAt)
    try addSample("manual-reset-zh", "手动使用成功", FeishuWebhookService.manualResetPayload(sampleManual, sourceAccount: sampleAccount, language: .zh))
    try addSample("manual-reset-en", "手动使用成功", FeishuWebhookService.manualResetPayload(sampleManual, sourceAccount: sampleAccount, language: .en))
    try addSample("test", "连接与切换", sampleNotice(.test))
    try addSample("low-quota", "连接与切换", sampleNotice(.lowQuotaDetected, target: sampleTarget, fiveHour: 4, sevenDay: 12))
    try addSample("switch-success", "连接与切换", sampleNotice(.switchSucceeded, target: sampleTarget))
    for reason in [FeishuSwitchNotification.FailureReason.noEligibleAccount, .appBusy, .validationFailed, .restartFailed, .networkUnavailable, .unknown] {
        try addSample("switch-failure-" + reason.rawValue, "连接与切换", sampleNotice(.switchFailed(reason), target: reason == .noEligibleAccount ? nil : sampleTarget))
    }
    let unchanged = CodexResetCreditComparison(previousAvailable: 2, available: 2,
        previousObservedAt: samplePreviousAt, observedAt: sampleAt)
    for (id, fiveHour, sevenDay) in [("window-5h", true, false), ("window-7d", false, true), ("window-both", true, true)] {
        try addSample(id, "额度与重置卡", sampleNotice(.quotaChange(.quotaReset(fiveHour: fiveHour, sevenDay: sevenDay)), comparison: unchanged))
    }
    for (id, before, after) in [("window-increase", 1, 3), ("window-decrease", 3, 2), ("window-unchanged", 2, 2),
                               ("window-to-zero", 1, 0), ("window-zero", 0, 0)] {
        let comparison = CodexResetCreditComparison(previousAvailable: before, available: after,
            previousObservedAt: samplePreviousAt, observedAt: sampleAt)
        try addSample(id, "额度与重置卡", sampleNotice(.quotaChange(.quotaReset(fiveHour: true, sevenDay: false)), available: after, comparison: comparison))
    }
    try addSample("window-no-previous", "额度与重置卡", sampleNotice(.quotaChange(.quotaReset(fiveHour: true, sevenDay: false))))
    try addSample("reset-added", "额度与重置卡", sampleNotice(.quotaChange(.resetCreditsAdded(added: 2, available: 3)), available: 3))
    for (id, before, after) in [("reset-increase", 1, 3), ("reset-decrease", 3, 2)] {
        let event = CodexQuotaEvent.resetCreditsChanged(previous: before, available: after,
            previousObservedAt: samplePreviousAt, observedAt: sampleAt)
        try addSample(id, "额度与重置卡", sampleNotice(.quotaChange(event), available: after))
    }
    let sampleBatches = [CodexResetCreditExpiryBatch(expiresAt: sampleAt.addingTimeInterval(3 * 3600), count: 1),
        CodexResetCreditExpiryBatch(expiresAt: sampleAt.addingTimeInterval(23 * 3600), count: 1)]
    try addSample("reset-expiring", "额度与重置卡", sampleNotice(.quotaChange(.resetCreditsExpiring(batches: sampleBatches, observedAt: sampleAt))))
    for (id, kind, wording) in [
        ("public-regular", PublicResetAnnouncement.Kind.regular, "Day 15/ Nevermind, we're still cooking... and reset. Enjoy."),
        ("public-banked", .banked, "Confirmed landed across all accounts. How are we doing so far?")
    ] {
        let announcedAt = sampleAt.addingTimeInterval(-2 * 3600)
        let postID = PublicResetForecast.sourcePostID(at: announcedAt)!
        let source = PublicResetAnnouncement.Source(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/" + postID))
        try addSample(id, "公共公告与预告", FeishuWebhookService.publicResetPayload(.init(
            id: postID, resetType: kind, announcedAt: announcedAt, text: wording, source: source), language: .zh))
    }
    let sampleForecastAt = sampleAt.addingTimeInterval(-3600)
    let samplePostID = PublicResetForecast.sourcePostID(at: sampleForecastAt)!
    for (id, latestBy) in [("forecast-dated", sampleAt.addingTimeInterval(2 * 3600) as Date?), ("forecast-undated", nil)] {
        let forecast = PublicResetForecast(id: samplePostID, latestBy: latestBy, announcedAt: sampleForecastAt,
            sourceURL: URL(string: "https://x.com/thsottiaux/status/" + samplePostID)!, fetchedAt: sampleAt)
        try addSample(id, "公共公告与预告", FeishuWebhookService.publicResetForecastPayload(
            PublicResetForecastNotification(forecast, referenceDate: sampleAt), language: .zh))
    }
    for category in FeishuTaskCompletionNotification.Category.allCases {
        let notification = try FeishuTaskCompletionNotification(eventID: UUID(),
            source: category == .codexConversation ? .codexTaskObserver : .hubTaskObserver,
            proof: .confirmedByTaskObserver, category: category, attemptCount: 1,
            accountLabel: sampleAccount, occurredAt: sampleAt, now: sampleAt)
        try addSample("task-" + category.rawValue, "任务结束", FeishuWebhookService.taskCompletionPayload(notification, language: .zh))
    }
    expect(samples.count == 31 && Set(samples.compactMap { $0["id"] as? String }).count == 31, "Feishu example inventory incomplete or duplicated")
    let manifest = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try manifest.write(to: directory.appendingPathComponent("feishu-examples-1020v3.json"), options: .atomic)
    try sampleMarkdown.write(to: directory.appendingPathComponent("飞书消息样例-1020v3.md"), atomically: true, encoding: .utf8)
    print("PASS 31 synthetic Feishu examples: fixed account/date, production payload objects, all source lines exactly once and no external URLs")
}
print("PASS notice payloads: signed/zero window comparisons, privacy switches, complete public source recovery, marker rejection, expiry and local policy; no account or network I/O")
"""
parts = [stubs, batch, quota, options, read("Services/PublicResetTranslation.swift"), announcement, public_delivery, forecast,
         read("Domain/PublicResetForecastNotification.swift"), read("Domain/MessageNoticeFormat.swift"),
         message, feishu_types, read("Domain/FeishuTaskCompletionNotification.swift"),
         "enum FeishuWebhookService {\n" + feishu_builders + "\n}\n", publisher, local_service, tests]
typecheck = "--typecheck-only" in sys.argv
if typecheck:
    parts = [stubs, batch, quota, options, read("Services/PublicResetTranslation.swift"), announcement, public_delivery, forecast,
             read("Domain/PublicResetForecastNotification.swift"), read("Domain/MessageNoticeFormat.swift"), message,
             feishu.split("private final class FeishuWebhookTestProtocol", 1)[0],
             read("Domain/FeishuTaskCompletionNotification.swift"), publisher,
             read("Services/NextLocalNotificationService.swift")]
with tempfile.TemporaryDirectory(prefix="next-notice-payloads-") as temporary:
    directory = pathlib.Path(temporary)
    source = directory / "main.swift"
    source.write_text("\n".join(parts))
    command = ["xcrun", "swift", "-module-cache-path", str(directory / "modules"), str(source)]
    if "--preview-dir" in sys.argv:
        index = sys.argv.index("--preview-dir")
        command += ["--preview-dir", sys.argv[index + 1]]
    if typecheck:
        command = ["xcrun", "swiftc", "-typecheck", "-parse-as-library", "-module-cache-path", str(directory / "modules"), str(source)]
    result = subprocess.run(command,
                            capture_output=True, text=True)
    print((result.stdout + result.stderr).replace(str(root), "<workspace>").replace(temporary, "<fixture>"), end="")
    if typecheck and result.returncode == 0:
        print("PASS full Feishu/Next service typecheck; no app build, instantiation or I/O")
    raise SystemExit(result.returncode)
