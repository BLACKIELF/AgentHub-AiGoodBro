#!/usr/bin/env python3
"""Exercise production notification configuration with an in-memory quota tracker.

Only production declarations and synthetic dependencies are compiled. No real app,
account, UserDefaults, notification, webhook, or Keychain operation is performed.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "Sources/CodexUsageWidget"


def block(source, needle):
    begin = source.index(needle)
    opening = source.index("{", begin)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[begin:index + 1]
    raise ValueError(needle)


def main():
    paths = [
        BASE / "Services/UsageStore.swift",
        BASE / "Domain/CodexQuotaEventTracker.swift",
        BASE / "Domain/UsageModels.swift",
        BASE / "Domain/FeishuMessageOptions.swift",
        BASE / "Domain/CodexResetNotice.swift",
    ]
    inputs = {path: path.read_text() for path in paths}
    store, tracker, models, options, notices = (inputs[path] for path in paths)
    helper_name = "resetQuotaEventTrackerForNotificationConfiguration()"
    helper = block(store, "    private func " + helper_name)
    methods = [block(store, needle) for needle in [
        "    func setLocalNotificationsEnabled(",
        "    func setFeishuNotificationsEnabled(",
        "    func setFeishuQuotaResetEnabled(",
        "    func setFeishuResetCreditEnabled(",
        "    func setFeishuMessageOptions(",
        "    private func refreshFeishuWebhookConfiguration()",
        "    private func finishFeishuConnectionUpdate(",
        "    func removeFeishuWebhook()",
    ]]
    callback = block(store, "        messageChannels.onConfigurationChanged = {")
    sites = methods + [callback]
    assert all(site.count(helper_name) == 1 for site in sites), "all nine configuration paths must use the helper"
    assert store.count(helper_name) == 10, "expected nine calls plus the helper declaration"
    resets = re.findall(r"\bquotaEventTracker\s*\.\s*reset\s*\(\s*\)", store)
    assert len(resets) == 1 and "quotaEventTracker.reset()" in helper, "configuration must not bypass the helper"
    assert all("Foundation.UserDefaults" not in site for site in sites), "fixture defaults shadow must cover every extracted call"

    declarations = [
        "import Foundation",
        block(models, "struct RateWindow:"),
        block(notices, "struct CodexResetCreditExpiryBatch:"),
        block(tracker, "enum CodexQuotaEvent:"),
        block(tracker, "struct CodexQuotaEventTracker {"),
        block(options, "struct FeishuMessageOptions:"),
    ]
    support = r'''
// Deliberately shadows Foundation.UserDefaults; setters only record memory writes.
final class UserDefaults {
    static let standard = UserDefaults()
    var writes = 0
    func set(_ value: Any?, forKey key: String) { writes += 1 }
}
enum Feature: Hashable { case localNotification, feishu }
enum WidgetLanguage {
    case fixture
    static func storedOrAutomatic() -> Self { .fixture }
    func text(_ chinese: String, _ english: String) -> String { english }
}
struct FeishuTaskCompletionObserver {}
enum FeishuWebhookError: Error {
    case keychainAuthorizationRequired, keychainTimedOut, keychainBusy, missingWebhook, transportFailed
}
final class FixtureWebhookService {
    var reads = 0, removes = 0, cacheInvalidations = 0
    func invalidateCredentialCache() { cacheInvalidations += 1 }
    func hasStoredWebhook(_ completion: (Result<Bool, FeishuWebhookError>) -> Void) {
        reads += 1
        completion(.success(true))
    }
    func removeStoredWebhook(_ completion: (Result<Void, FeishuWebhookError>) -> Void) {
        removes += 1
        completion(.success(()))
    }
}
final class NextLocalNotificationService {
    struct AuthorizationState {}
    enum ServiceError: Error { case fixture }
    static let shared = NextLocalNotificationService()
    var authorizationRequests = 0
    func requestAlertAuthorization(userInitiated: Bool, completion: (Result<AuthorizationState, ServiceError>) -> Void) {
        authorizationRequests += 1
        completion(.success(AuthorizationState()))
    }
}
final class FixtureMessageChannels {
    var telegramEnabled = false, weChatEnabled = false, personalWeChatEnabled = false
    var onConfigurationChanged: (() -> Void)?
}
final class Harness {
    static let localNotificationsEnabledKey = "fixture.local"
    static let feishuNotificationsEnabledKey = "fixture.feishu"
    static let feishuQuotaResetEnabledKey = "fixture.feishu.quota"
    static let feishuResetCreditEnabledKey = "fixture.feishu.cards"
    static let feishuMessageOptionsKey = "fixture.feishu.options"
    var proxyQuotaResetObservationEnabled = false
    var quotaEventTracker = CodexQuotaEventTracker()
    var localNotificationsEnabled = false, isRequestingLocalNotificationPermission = false
    var localNotificationPermissionRequestID: UUID?, localNotificationAuthorization: NextLocalNotificationService.AuthorizationState?
    var resetNoticeLocalRevision = UUID(), localNotificationMessage: String?
    var isPreview = false, hasStarted = true, isUpdatingFeishuConnection = false
    var feishuNotificationsEnabled = false, feishuQuotaResetEnabled = false, feishuResetCreditEnabled = false
    var feishuWebhookConfigured = true, feishuNeedsAuthorization = false
    var feishuConfigurationRevision = 0, maintenanceSchedules = 0, authorizationRefreshes = 0
    var feishuNotificationMessage = ""
    var pausedAutomationFeatures: Set<Feature> = []
    var feishuTaskCompletionObserver = FeishuTaskCompletionObserver()
    var feishuMessageOptions = FeishuMessageOptions.standard
    let feishuWebhookService = FixtureWebhookService(), messageChannels = FixtureMessageChannels()
    func scheduleWarmUpMaintenanceTimer() { maintenanceSchedules += 1 }
    func refreshLocalNotificationAuthorization() { authorizationRefreshes += 1 }
    func localNotificationErrorMessage(_ error: NextLocalNotificationService.ServiceError) -> String { "fixture error" }
__METHODS__
__HELPER__
__OBSERVES__
__BEGIN__
__CREDENTIAL_FAILURE__
    func bindConfigurationCallback() {
__CALLBACK__
    }
    func refreshWebhook() { refreshFeishuWebhookConfiguration() }
    func completeConnection() {
        beginFeishuConnectionUpdate()
        check(finishFeishuConnectionUpdate(.success(())), "synthetic connection completion succeeds")
    }
    var observationEnabled: Bool { observesOfficialQuotaEvents }
}
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { print("FAIL " + message); exit(1) }
}
let now = Date(timeIntervalSince1970: 100_000)
func observation(_ capturedOffset: TimeInterval, used: Double, sevenDay: Bool) -> CodexQuotaEventTracker.Observation {
    let changed = RateWindow(usedPercent: used, windowDurationMins: sevenDay ? 10_080 : 300, resetsAt: now.addingTimeInterval(600))
    let steady = RateWindow(usedPercent: 40, windowDurationMins: sevenDay ? 300 : 10_080, resetsAt: now.addingTimeInterval(600))
    return .init(capturedAt: now.addingTimeInterval(capturedOffset), limitID: "fixture-codex",
        fiveHour: sevenDay ? steady : changed, sevenDay: sevenDay ? changed : steady, resetCredits: nil)
}
typealias Configuration = (Harness) -> Void
let configurations: [(String, Configuration)] = [
    ("local notifications", { h in
        h.setLocalNotificationsEnabled(true, requestAuthorization: false)
        h.setLocalNotificationsEnabled(false, requestAuthorization: false)
        check(!h.localNotificationsEnabled, "local notification toggle executes")
    }),
    ("Feishu notifications", { h in
        h.setFeishuNotificationsEnabled(true)
        check(h.feishuWebhookService.cacheInvalidations == 0, "enabling Feishu retains the authorized cache")
        h.setFeishuNotificationsEnabled(false)
        check(!h.feishuNotificationsEnabled && h.feishuConfigurationRevision == 2, "Feishu notification toggles execute")
        check(h.feishuWebhookService.cacheInvalidations == 1 && !h.feishuWebhookConfigured,
            "disabling Feishu invalidates its credential cache and clears configured state")
    }),
    ("Feishu quota alerts", { h in
        h.setFeishuQuotaResetEnabled(true); h.setFeishuQuotaResetEnabled(false)
        check(!h.feishuQuotaResetEnabled && h.feishuConfigurationRevision == 2, "Feishu quota toggles execute")
    }),
    ("Feishu card alerts", { h in
        h.setFeishuResetCreditEnabled(true); h.setFeishuResetCreditEnabled(false)
        check(!h.feishuResetCreditEnabled && h.feishuConfigurationRevision == 2, "Feishu card toggles execute")
    }),
    ("Feishu window options", { h in
        var options = h.feishuMessageOptions
        options.notifiesFiveHourReset = false; options.notifiesSevenDayReset = false
        h.setFeishuMessageOptions(options)
        check(h.feishuMessageOptions == options && h.feishuConfigurationRevision == 1, "quota-related message options execute")
    }),
    ("webhook refresh callback", { h in
        h.refreshWebhook()
        check(h.feishuWebhookService.reads == 1 && h.feishuWebhookConfigured, "synthetic refresh callback executes")
    }),
    ("webhook connection completion", { h in
        h.completeConnection()
        check(h.feishuWebhookConfigured && !h.isUpdatingFeishuConnection, "connection success executes")
    }),
    ("webhook removal callback", { h in
        h.removeFeishuWebhook()
        check(h.feishuWebhookService.removes == 1 && !h.feishuWebhookConfigured, "synthetic removal callback executes")
    }),
    ("message-channel configuration callback", { h in
        h.bindConfigurationCallback(); h.messageChannels.onConfigurationChanged?()
    }),
]
var scenarios = 0
for (name, configure) in configurations {
    for sevenDay in [false, true] {
        let before = observation(-10, used: 80, sevenDay: sevenDay)
        let restored = observation(-5, used: 20, sevenDay: sevenDay)
        let nextReset = observation(-1, used: 0, sevenDay: sevenDay)
        let event = CodexQuotaEvent.quotaReset(fiveHour: !sevenDay, sevenDay: sevenDay)
        for armed in [true, false] {
            let h = Harness()
            check(h.quotaEventTracker.observe(before, verifiedAccountID: "fixture-account", now: now).isEmpty, "initial official read only establishes baseline")
            h.proxyQuotaResetObservationEnabled = true
            if !armed { h.proxyQuotaResetObservationEnabled = false }
            configure(h)
            check(h.maintenanceSchedules > 0, name + " configuration path is active")
            let changes = h.quotaEventTracker.observe(restored, verifiedAccountID: "fixture-account", now: now)
            if armed {
                check(changes == [event], name + ": armed proxy must retain the official pre-reset baseline")
                check(h.observationEnabled, "armed rule observes official changes with all notification channels off")
            } else {
                check(changes.isEmpty, name + ": disabled proxy configuration must establish a fresh baseline")
                check(h.quotaEventTracker.observe(nextReset, verifiedAccountID: "fixture-account", now: now) == [event],
                    name + ": the new baseline still detects the next official restoration")
            }
            check(h.quotaEventTracker.observe(restored, verifiedAccountID: "fixture-account", now: now).isEmpty,
                name + ": duplicate or older official observations do not repeat a reset")
            scenarios += 1
        }
    }
}
let displayOnly = Harness()
let before = observation(-10, used: 80, sevenDay: false)
let restored = observation(-5, used: 20, sevenDay: false)
_ = displayOnly.quotaEventTracker.observe(before, verifiedAccountID: "fixture-account", now: now)
var options = displayOnly.feishuMessageOptions
options.includesAgentName.toggle()
displayOnly.setFeishuMessageOptions(options)
check(displayOnly.quotaEventTracker.observe(restored, verifiedAccountID: "fixture-account", now: now) == [.quotaReset(fiveHour: true, sevenDay: false)],
    "display-only message options do not reset the tracker when the proxy is disabled")
let stopped = Harness()
_ = stopped.quotaEventTracker.observe(before, verifiedAccountID: "fixture-account", now: now)
stopped.bindConfigurationCallback(); stopped.hasStarted = false
stopped.messageChannels.onConfigurationChanged?()
check(stopped.maintenanceSchedules == 0, "stopped message callback retains its lifecycle guard")
check(stopped.quotaEventTracker.observe(restored, verifiedAccountID: "fixture-account", now: now) == [.quotaReset(fiveHour: true, sevenDay: false)],
    "stopped callback does not clear observations")
check(NextLocalNotificationService.shared.authorizationRequests == 0, "configuration tests do not request system authorization")
check(UserDefaults.standard.writes > 0, "production persistence calls were handled by memory-only defaults")
print("PASS production proxy reset observation: \(scenarios) scenarios, \(checks) behavior checks, 9 reset-site wiring guards")
'''
    substitutions = {
        "METHODS": "\n\n".join(methods),
        "HELPER": helper,
        "OBSERVES": block(store, "    private var observesOfficialQuotaEvents:"),
        "BEGIN": block(store, "    private func beginFeishuConnectionUpdate()"),
        "CREDENTIAL_FAILURE": block(store, "    private func handleFeishuCredentialFailure("),
        "CALLBACK": callback,
    }
    for name, value in substitutions.items():
        support = support.replace("__" + name + "__", value)
    frozen = "\n\n".join(declarations + [support])
    with tempfile.TemporaryDirectory(prefix="aigoodbro-proxy-reset-observation-") as temporary:
        folder = Path(temporary)

        def run(name, source):
            fixture = folder / (name + ".swift")
            fixture.write_text(source)
            result = subprocess.run([
                "/usr/bin/xcrun", "swift", "-swift-version", "5", "-module-cache-path", str(folder / "modules"), str(fixture),
            ], cwd=ROOT, capture_output=True, text=True, timeout=60)
            output = (result.stdout + result.stderr).replace(temporary, "<fixture>").replace(str(ROOT), "<worktree>")
            return result.returncode, output

        code, output = run("production", frozen)
        print(output, end="")
        if code == 0:
            # Restore only the former unconditional reset inside the frozen helper.
            old_helper = re.sub(r"if !proxyQuotaResetObservationEnabled\s*\{\s*quotaEventTracker.reset\(\)\s*\}",
                                "quotaEventTracker.reset()", helper)
            assert old_helper != helper, "negative control must restore the old reset policy"
            negative_code, negative_output = run("unconditional-reset", frozen.replace(helper, old_helper, 1))
            assert negative_code == 1 and "armed proxy must retain the official pre-reset baseline" in negative_output, negative_output
            print("PASS negative control: unconditional configuration reset loses the armed proxy recovery event")
        unchanged = all(path.read_text() == value for path, value in inputs.items())
        print(json.dumps({
            "exitCode": code,
            "inputs": {str(path.relative_to(ROOT)): hashlib.sha256(value.encode()).hexdigest() for path, value in inputs.items()},
            "inputsUnchangedDuringRun": unchanged,
            "scope": "Extracted production helper, eight configuration methods, message callback, observer gate, RateWindow and quota tracker; synthetic synchronous services and memory-only defaults; no full UsageStore or real identity admission",
            "realAccountIO": False, "userDefaultsIO": False, "keychainIO": False,
            "networkSends": 0, "notificationSubmissions": 0,
        }, sort_keys=True))
        return code if unchanged else 2


if __name__ == "__main__":
    raise SystemExit(main())
