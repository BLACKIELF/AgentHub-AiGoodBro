#!/usr/bin/env python3
"""Pure notice formatting fixtures; no account, notification or network access."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
stubs = """import Foundation
enum WidgetLanguage { case zh, en
func text(_ zh: String, _ en: String) -> String { self == .zh ? zh : en }
}
enum MessageTaskStatus {
enum TaskState { case idle, running, waitingInput, completed, failed, interrupted, disconnected }
enum FailureReason { case noEligibleAccount, appBusy, validationFailed, restartFailed, networkUnavailable, unknown }
}
struct CodexResetCreditExpiryBatch: Codable, Equatable { let expiresAt: Date; let count: Int }
"""
with tempfile.TemporaryDirectory(prefix="next-notice-format-") as temporary:
    directory = pathlib.Path(temporary)
    source = directory / "main.swift"
    quota = (root / "Sources/CodexUsageWidget/Domain/CodexQuotaEventTracker.swift").read_text().split("/// Compares", 1)[0]
    countdown = (root / "Sources/CodexUsageWidget/UI/ResetCountdownText.swift").read_text().split("/// Only this small label ticks.", 1)[0]
    ui_tests = (root / "Sources/CodexUsageWidget/Domain/TokenMonitorUISelfTest.swift").read_text()
    countdown_test = ui_tests.split("    private static func reproduceResetCountdown(", 1)[1].split("    private static func reproduceResetDashboardLayout(", 1)[0]
    countdown_test = "func reproduceResetCountdown(" + countdown_test
    source.write_text(stubs + quota + (root / "Sources/CodexUsageWidget/Domain/MessageNoticeFormat.swift").read_text()
                      + countdown + countdown_test + """
var countdownChecks = 0
var countdownFailures = 0
reproduceResetCountdown { value, message in
    countdownChecks += 1
    if !value {
        countdownFailures += 1
        print("FAIL reset countdown: " + message)
    }
}
print("Reset countdown presentation and production schedule: \(countdownChecks) assertions, \(countdownFailures) failures")
exit(MessageNoticeFormatSelfTest.run() && countdownFailures == 0 ? 0 : 1)
""")
    result = subprocess.run(["xcrun", "swift", "-module-cache-path", str(directory / "modules"), str(source)], capture_output=True, text=True)
    print((result.stdout + result.stderr).replace(str(root), "<workspace>").replace(temporary, "<fixture>"), end="")
    raise SystemExit(result.returncode)
