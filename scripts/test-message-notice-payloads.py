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
    between(feishu, "    static func publicResetPayload(", "    /// Sends an observer-confirmed")
    + between(feishu, "    static func taskCompletionPayload(", "    private func send(")
    + between(feishu, "    static func payloadData(", "    static func parseResponse(")
    + between(feishu, "    private static func percentText(", "\n}\n\nprivate final class FeishuWebhookTestProtocol")
)
announcement = between(read("Services/PublicResetAnnouncements.swift"), "struct PublicResetAnnouncement:", "struct PublicResetPage:")
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
enum PublicResetClient { static let siteURL = URL(string: "https://codex-resets.com/")! }
"""
tests = r"""
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
    body.components(separatedBy: "\n").filter { $0 == MessageNoticeFormat.footer }.count == 1
        && body.hasSuffix(MessageNoticeFormat.footer)
}
let now = Date()
let previousAt = now.addingTimeInterval(-1800)
let account = try FeishuMaskedAccount(displayName: "Work account")
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
    expect(payload.body.contains("\(before)→\(after)") && payload.body.contains("净变化") && payload.body.contains("快照"), "Feishu snapshot facts missing")
    expect(payload.body.contains("原因待核实") == (after < before), "Feishu decrease reason misstated")
    expect(!payload.body.contains("已到账") && !payload.body.contains("已使用") && hasOneFooter(payload.body), "Feishu cause or footer incorrect")
    let local = NextLocalNotificationService.officialPayload(event, language: .zh, now: now)!
    expect(local.title.contains(sign) && local.body.contains("\(before)→\(after)") && hasOneFooter(local.body), "local delta or footer missing")
    expect(!local.body.contains("Work account") && !local.body.contains("已使用"), "local notification leaks account or assumes usage")
}
let batches = [
    CodexResetCreditExpiryBatch(expiresAt: now.addingTimeInterval(23 * 3600), count: 2),
    CodexResetCreditExpiryBatch(expiresAt: now.addingTimeInterval(90 * 60), count: 1)
]
let expiry = CodexQuotaEvent.resetCreditsExpiring(batches: batches, observedAt: now)
let expiring = try card(FeishuWebhookService.payloadData(for: notification(expiry), language: .zh))
for batch in batches {
    expect(expiring.body.contains(MessageNoticeFormat.shortDate(batch.expiresAt)) && expiring.body.contains("\(batch.count)次"), "Feishu expiry batch missing")
}
expect(hasOneFooter(expiring.body) && !expiring.body.contains("已到账") && !expiring.body.contains("已使用"), "Feishu expiry claims or footer incorrect")
let localExpiry = NextLocalNotificationService.officialPayload(expiry, language: .zh, now: now)!
expect(localExpiry.body.contains("余23h") && localExpiry.body.contains("余1h30m") && hasOneFooter(localExpiry.body), "local exact expiry facts missing")
let expired = CodexQuotaEvent.resetCreditsExpiring(batches: [.init(expiresAt: now.addingTimeInterval(-1), count: 1)], observedAt: now.addingTimeInterval(-60))
let expiredNotice = try notification(expired)
do { _ = try FeishuWebhookService.payloadData(for: expiredNotice, language: .zh); preconditionFailure("expired Feishu notice accepted") }
catch FeishuWebhookError.invalidNotification {}
expect(NextLocalNotificationService.officialPayload(expired, language: .zh, now: now) == nil, "expired local notice accepted")
let observedEarlier = now.addingTimeInterval(-60)
let crossing = CodexQuotaEvent.resetCreditsExpiring(batches: [.init(expiresAt: observedEarlier.addingTimeInterval(24 * 3600 + 30), count: 1)], observedAt: observedEarlier)
let crossingCard = try card(FeishuWebhookService.payloadData(for: notification(crossing), language: .zh))
expect(crossingCard.body.contains("1次") && hasOneFooter(crossingCard.body), "Feishu rejected a cached expiry entering the 24h window")
expect(crossingCard.body.contains("**发现时间**：" + MessageNoticeFormat.shortTime(observedEarlier)), "Feishu replaced original check time with dispatch time")
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
    expect(hasOneFooter(payload.body) && payload.body.contains(MessageNoticeFormat.shortTime(now)), "ordinary Feishu time or footer missing")
}
let publicEvent = PublicResetAnnouncement(id: "123", resetType: .banked, announcedAt: now,
    text: "Public fixture wording evil.invalid", source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/123")))
let publicCard = try card(FeishuWebhookService.publicResetPayload(publicEvent, language: .zh))
expect(publicCard.body.contains("Public fixture wording") && !publicCard.body.contains("evil.invalid"), "safe public wording lost or unsafe destination retained")
expect(publicCard.body.contains(MessageNoticeFormat.shortTime(now)) && hasOneFooter(publicCard.body), "public announcement time or footer missing")
let postID = PublicResetForecast.sourcePostID(at: now.addingTimeInterval(-60))!
let postTime = PublicResetForecast.sourcePostDate(for: postID)!
let forecast = PublicResetForecast(id: postID, latestBy: now.addingTimeInterval(3600), announcedAt: postTime,
    sourceURL: URL(string: "https://x.com/thsottiaux/status/" + postID)!, fetchedAt: now)
let forecastCard = try card(FeishuWebhookService.publicResetForecastPayload(PublicResetForecastNotification(forecast, referenceDate: now), language: .zh))
expect(forecastCard.body.contains(MessageNoticeFormat.shortDate(forecast.latestBy!)) && hasOneFooter(forecastCard.body), "forecast expiry time or footer missing")
let completion = try FeishuTaskCompletionNotification(eventID: UUID(), proof: .confirmedByTaskObserver,
    category: .dispatchedAgent, occurredAt: now, now: now)
let completed = try card(FeishuWebhookService.taskCompletionPayload(completion, language: .zh))
expect(completed.title == "Codex 运行结束" && !completed.body.contains("完成验收") && hasOneFooter(completed.body), "task ended overclaims acceptance or footer missing")
expect(NextLocalNotificationService.selfTest(), "local privacy and authorization policy self-test failed")
print("PASS notice payloads: signed snapshot deltas, exact expiry batches, stale rejection, privacy options, public sanitizer, footer and local authorization policy; no I/O")
"""
parts = [stubs, batch, quota, options, read("Services/PublicResetTranslation.swift"), announcement, forecast,
         read("Domain/PublicResetForecastNotification.swift"), read("Domain/MessageNoticeFormat.swift"),
         message, feishu_types, read("Domain/FeishuTaskCompletionNotification.swift"),
         "enum FeishuWebhookService {\n" + feishu_builders + "\n}\n", publisher, local_service, tests]
typecheck = "--typecheck-only" in sys.argv
if typecheck:
    parts = [stubs, batch, quota, options, read("Services/PublicResetTranslation.swift"), announcement, forecast,
             read("Domain/PublicResetForecastNotification.swift"), read("Domain/MessageNoticeFormat.swift"), message,
             feishu.split("private final class FeishuWebhookTestProtocol", 1)[0],
             read("Domain/FeishuTaskCompletionNotification.swift"), publisher,
             read("Services/NextLocalNotificationService.swift")]
with tempfile.TemporaryDirectory(prefix="next-notice-payloads-") as temporary:
    directory = pathlib.Path(temporary)
    source = directory / "main.swift"
    source.write_text("\n".join(parts))
    command = ["xcrun", "swift", "-module-cache-path", str(directory / "modules"), str(source)]
    if typecheck:
        command = ["xcrun", "swiftc", "-typecheck", "-parse-as-library", "-module-cache-path", str(directory / "modules"), str(source)]
    result = subprocess.run(command,
                            capture_output=True, text=True)
    print((result.stdout + result.stderr).replace(str(root), "<workspace>").replace(temporary, "<fixture>"), end="")
    if typecheck and result.returncode == 0:
        print("PASS full Feishu/Next service typecheck; no app build, instantiation or I/O")
    raise SystemExit(result.returncode)
