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
    source.write_text(stubs + quota + (root / "Sources/CodexUsageWidget/Domain/MessageNoticeFormat.swift").read_text()
                      + "\nexit(MessageNoticeFormatSelfTest.run() ? 0 : 1)\n")
    result = subprocess.run(["xcrun", "swift", "-module-cache-path", str(directory / "modules"), str(source)], capture_output=True, text=True)
    print((result.stdout + result.stderr).replace(str(root), "<workspace>").replace(temporary, "<fixture>"), end="")
    raise SystemExit(result.returncode)
