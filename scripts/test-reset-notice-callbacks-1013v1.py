#!/usr/bin/env python3
"""Extract production revision/callback/completion policy; synthetic state, no I/O."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/CodexUsageWidget/Services/UsageStore.swift"
LEDGER = ROOT / "Sources/CodexUsageWidget/Services/CodexResetNoticeDeliveryStore.swift"


def block(text, needle, start=0):
    begin = text.index(needle, start)
    opening = text.index("{", begin)
    depth = 0
    for index in range(opening, len(text)):
        depth += (text[index] == "{") - (text[index] == "}")
        if depth == 0:
            return text[begin:index + 1]
    raise ValueError(needle)


def main():
    source, ledger = SOURCE.read_text(), LEDGER.read_text()
    submit = block(source, "    private func submitResetNotice(")
    local = block(submit, ") { [weak self] result in")
    local = local[local.index("\n") + 1:-1]
    feishu = block(submit, "DispatchQueue.main.async {")
    feishu = feishu[feishu.index("\n") + 1:-1]
    completion = block(source, "if self.resetNoticeRunRevision == runRevision,", source.index("let receipt = await self.submitResetNotice("))
    after = source[source.index(completion) + len(completion):]
    alternate = block(after, "else {")
    completion += " " + alternate
    revision = block(source, "    private func resetNoticeRevision(")
    handler = block(source, "    private func handleFeishuCredentialFailure(")
    phase = block(ledger, "    var phase: CodexResetNoticeDeliveryPhase {")
    membership = block(source, "    private func refreshExpiredMembershipDates()")
    # This is a wiring check, not a synthetic execution of RPC/account loading.
    compact = lambda value: re.sub(r"\s+", "", value)
    assert compact("if let official = result.1 { try? self.profileStore.recordOfficialProfile(official, for: profile.id) } try? self.recordOfficialSnapshot(result.2, for: profile.id)") in compact(membership).replace("_=", "")
    wrapper = block(source, "    private func recordOfficialSnapshot(")
    assert compact("noticeChannels: resetNoticeChannels(expiry: false).map(\\.rawValue)") in compact(wrapper)
    assert compact("observeOfficialQuotaChanges(snapshot, profileID: profileID, newReceipt: receipt)") in compact(wrapper)
    queue = block(source, "    private func enqueueResetNotices(")
    assert compact("let revision = resetNoticeRevision(delivery.channel, expiry: expiry),") in compact(queue)
    assert compact("&& self.resetNoticeRevision(delivery.channel, expiry: expiry) == revision") in compact(queue)
    assert compact("requiringReadiness: false) == revision") in compact(queue)
    dispatch = block(source, "    private func queueResetNotices(")
    assert "Task { @MainActor" in dispatch and "self?.enqueueResetNotices(" in dispatch
    support = r'''
import Foundation
enum CodexResetNoticeChannel: String { case local, feishu, telegram, weChat, personalWeChat }
enum Feature: Hashable { case localNotification, feishu }
enum Detail { case none, all }
struct Options { var includesResetCredits = true; var resetExpiryDetail = Detail.all }
final class Channels { var weChatMessageOptions = Options(); func publicResetRevision(_ kind: CodexResetNoticeChannel) -> UUID? { nil } }
enum FeishuWebhookError: Error { case keychainAuthorizationRequired, keychainTimedOut, keychainBusy, missingWebhook, transportFailed, invalidResponse, cancelled, httpStatus(Int), rejected }
enum LocalError: Error { case notificationSubmissionFailed, disabled }
enum CodexResetNoticeDeliveryPhase: String { case pending, sent, uncertain }
enum CodexResetNoticeDeliveryReceipt: String { case accepted, notSent, rejected, uncertain
__PHASE__
}
enum WidgetLanguage { case fixture; static func storedOrAutomatic() -> Self { .fixture }; func text(_ zh: String, _ en: String) -> String { en } }
final class Continuation { var value: CodexResetNoticeDeliveryReceipt?; func resume(returning value: CodexResetNoticeDeliveryReceipt) { self.value = value } }
struct Delivery { let channel: CodexResetNoticeChannel }
struct Reservation {}
final class Ledger { var recorded: CodexResetNoticeDeliveryReceipt?; var uncertain = false, releasedUnsent = false
 func record(_ reservation: Reservation, receipt: CodexResetNoticeDeliveryReceipt, currentRevision: UUID) throws -> Bool { recorded = receipt; return true }
 func releaseUnsent(_ reservation: Reservation) throws -> Bool { releasedUnsent = true; return true }
 func markUncertain(_ reservation: Reservation) throws { uncertain = true }
}
final class Harness {
 var hasStarted = true, isPreview = false, localNotificationsEnabled = true
 var feishuNotificationsEnabled = true, feishuResetCreditEnabled = true, feishuWebhookConfigured = true, isUpdatingFeishuConnection = false, feishuNeedsAuthorization = false
 var pausedAutomationFeatures: Set<Feature> = []
 var resetNoticeRunRevision = UUID(), resetNoticeLocalRevision = UUID(), feishuConfigurationRevision = 1
 var feishuMessageOptions = Options(), messageChannels = Channels()
 var localNotificationMessage: String? = "new local", feishuNotificationMessage = "new feishu"
 var resetNoticeDeliveryStore = Ledger()
 static var ids: [String: UUID] = [:]
 static func resetNoticeUUID(_ value: String) -> UUID { if let id = ids[value] { return id }; let id = UUID(); ids[value] = id; return id }
 func localNotificationErrorMessage(_ error: LocalError) -> String { "local failure" }
__REVISION__
__HANDLER__
 func revision(_ channel: CodexResetNoticeChannel, ready: Bool = true, expiry: Bool = false) -> UUID? { resetNoticeRevision(channel, expiry: expiry, requiringReadiness: ready) }
 func localResult(_ result: Result<Void, LocalError>, runRevision: UUID, localRevision: UUID) -> CodexResetNoticeDeliveryReceipt {
  let continuation = Continuation()
__LOCAL__
  return continuation.value!
 }
 func feishuResult(_ result: Result<Void, FeishuWebhookError>, runRevision: UUID, configurationRevision: Int) -> CodexResetNoticeDeliveryReceipt {
  let continuation = Continuation()
__FEISHU__
  return continuation.value!
 }
 func complete(_ receipt: CodexResetNoticeDeliveryReceipt, runRevision: UUID, revision: UUID) throws {
  let delivery = Delivery(channel: .feishu), reservation = Reservation(), expiry = false
__COMPLETION__
 }
}
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; if !value() { fatalError("FAIL " + message) } }
let h = Harness(), run = UUID()
h.resetNoticeRunRevision = run
let localRevision = h.resetNoticeLocalRevision
_ = h.localResult(.success(()), runRevision: UUID(), localRevision: localRevision)
check(h.localNotificationMessage == "new local", "old local run success cannot mutate new state")
_ = h.localResult(.failure(.disabled), runRevision: run, localRevision: UUID())
check(h.localNotificationMessage == "new local", "old local revision failure cannot mutate new state")
_ = h.localResult(.success(()), runRevision: run, localRevision: localRevision)
check(h.localNotificationMessage != "new local", "current local callback updates state")
let revision = h.revision(.feishu)!
_ = h.feishuResult(.success(()), runRevision: UUID(), configurationRevision: 1)
check(h.feishuNotificationMessage == "new feishu", "old Feishu run success cannot mutate new state")
_ = h.feishuResult(.failure(.missingWebhook), runRevision: run, configurationRevision: 0)
check(h.feishuWebhookConfigured && h.feishuNotificationMessage == "new feishu", "old Feishu config failure cannot revoke current readiness")
h.feishuConfigurationRevision = 2
check(h.revision(.feishu) != revision, "Feishu configuration change changes revision")
h.feishuConfigurationRevision = 1
let missing = h.feishuResult(.failure(.missingWebhook), runRevision: run, configurationRevision: 1)
check(missing == .notSent && !h.feishuWebhookConfigured, "current missing webhook is proven not sent and clears readiness")
check(h.revision(.feishu) == nil, "readiness false blocks new send admission")
check(h.revision(.feishu, ready: false) == revision, "readiness false retains same config result attribution")
try h.complete(missing, runRevision: run, revision: revision)
check(h.resetNoticeDeliveryStore.recorded == .notSent && !h.resetNoticeDeliveryStore.uncertain, "current missing webhook records notSent rather than uncertain")
check(missing.phase == .pending, "production receipt phase keeps missing webhook pending")
h.resetNoticeDeliveryStore = Ledger()
try h.complete(.accepted, runRevision: UUID(), revision: revision)
check(h.resetNoticeDeliveryStore.recorded == nil && h.resetNoticeDeliveryStore.uncertain, "old run completion cannot accept new state")
h.resetNoticeDeliveryStore = Ledger(); h.feishuConfigurationRevision = 2
try h.complete(.accepted, runRevision: run, revision: revision)
check(h.resetNoticeDeliveryStore.recorded == nil && h.resetNoticeDeliveryStore.uncertain, "old configuration completion cannot accept new state")
h.feishuConfigurationRevision = 1; h.feishuWebhookConfigured = true
let cancelled = h.feishuResult(.failure(.cancelled), runRevision: run, configurationRevision: 1)
check(cancelled == .notSent && cancelled.phase == .pending, "Feishu pre-transport cancellation stays retryable")
h.resetNoticeDeliveryStore = Ledger()
try h.complete(cancelled, runRevision: run, revision: revision)
check(h.resetNoticeDeliveryStore.recorded == .notSent && !h.resetNoticeDeliveryStore.uncertain, "same-revision cancellation records a proven no-send result")
h.resetNoticeDeliveryStore = Ledger()
try h.complete(cancelled, runRevision: UUID(), revision: revision)
check(h.resetNoticeDeliveryStore.releasedUnsent && !h.resetNoticeDeliveryStore.uncertain, "old run can release only its proven unsent reservation")
h.resetNoticeDeliveryStore = Ledger(); h.feishuConfigurationRevision = 2
try h.complete(cancelled, runRevision: run, revision: revision)
check(h.resetNoticeDeliveryStore.releasedUnsent && !h.resetNoticeDeliveryStore.uncertain, "rebind cancellation releases the unsent attempt without accepting the old config")
h.feishuConfigurationRevision = 1
let failed = h.feishuResult(.failure(.transportFailed), runRevision: run, configurationRevision: 1)
check(failed == .uncertain && h.feishuWebhookConfigured, "ambiguous transport preserves readiness and requires verification")
h.hasStarted = false
check(h.revision(.feishu, ready: false) == nil && h.revision(.local) == nil, "stopped run rejects all revision attribution")
print("PASS production revision/callback/completion: \(checks) behavior checks; 7 wiring guards")
'''
    for key, value in {"PHASE": phase, "REVISION": revision, "HANDLER": handler, "LOCAL": local, "FEISHU": feishu, "COMPLETION": completion}.items():
        support = support.replace("__" + key + "__", value)
    # Callback bodies are unchanged; their weak captures become Optional aliases.
    support = support.replace("  let continuation = Continuation()", "  let continuation = Continuation()\n  let optionalSelf: Harness? = self")
    support = support.replace("self?.", "optionalSelf?.")
    with tempfile.TemporaryDirectory(prefix="reset-callback-1013v1-") as temporary:
        fixture = Path(temporary) / "main.swift"
        fixture.write_text(support)
        result = subprocess.run(["/usr/bin/xcrun", "swift", "-module-cache-path", temporary + "/modules", str(fixture)], capture_output=True, text=True, timeout=60)
        print((result.stdout + result.stderr).replace(temporary, "<fixture>"), end="")
        unchanged = SOURCE.read_text() == source and LEDGER.read_text() == ledger
        print(json.dumps({"version": "1013v1", "behaviorChecks": 19, "wiringGuards": 7, "exitCode": result.returncode,
            "inputs": {str(path.relative_to(ROOT)): hashlib.sha256(value.encode()).hexdigest() for path, value in [(SOURCE, source), (LEDGER, ledger)]},
            "inputsUnchangedDuringRun": unchanged,
            "scope": "Actual extracted revision, credential handler, callback bodies, completion branch and receipt phase; synthetic dependencies; actor scheduling, full sender and disk ledger are not executed; membership is source wiring only",
            "realAccountIO": False, "networkSends": 0, "notificationSubmissions": 0}, sort_keys=True))
        return result.returncode if unchanged else 2


if __name__ == "__main__":
    raise SystemExit(main())
