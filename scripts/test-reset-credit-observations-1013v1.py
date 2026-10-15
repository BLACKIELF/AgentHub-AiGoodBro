#!/usr/bin/env python3
"""Run receipt/tracker/presentation rules with synthetic types and no live I/O."""

import pathlib
import subprocess
import tempfile


def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


def main():
    repo = pathlib.Path(__file__).resolve().parent.parent
    domain = repo / "Sources/CodexUsageWidget/Domain"
    store = (repo / "Sources/CodexUsageWidget/Services/CodexProfileStore.swift").read_text()
    ui = (repo / "Sources/CodexUsageWidget/UI/ResetUpdatesBanner.swift").read_text()
    parts = [
        "import Foundation",
        between((domain / "UsageModels.swift").read_text(), "struct RateWindow:", "struct CreditsInfo:"),
        between(store, "struct CodexQuotaWindowSnapshot:", "struct CodexCredentialIdentity:"),
        """
enum WidgetLanguage { case zh, en
    func text(_ chinese: String, _ english: String) -> String { self == .zh ? chinese : english }
}
struct CodexProfile {
    let id: String
    var lastSnapshot: CodexAccountSnapshot?
    var lastQuotaReadFailureAt: Date? = nil
    var resetCreditHistory: [CodexResetCreditReceipt]? = nil
}
enum AccountDisplay {
    static func planLabel(_ profile: CodexProfile, empty: String) -> String {
        profile.lastSnapshot?.planType?.uppercased() ?? empty
    }
}
// Only enum payload shape is stubbed; expiry admission belongs to host tests.
struct CodexResetCreditExpiryBatch: Equatable { let expiresAt: Date; let count: Int }
struct MessageTaskStatus {
    enum TaskState { case idle, running, waitingInput, completed, failed, interrupted, disconnected }
    enum FailureReason { case noEligibleAccount, appBusy, validationFailed, restartFailed, networkUnavailable, unknown }
}
""",
        (domain / "CodexQuotaEventTracker.swift").read_text(),
        (domain / "MessageNoticeFormat.swift").read_text(),
        "enum PublicResetAnnouncementPresentation {\n"
        + between(ui, "    static func eventTime(", "    static func forecastTime(") + "\n}",
        between(ui, "enum ResetCreditChangePresentation", "/// Account mirrors contribute only"),
        (repo / "tests/ResetCreditObservation1013v1Tests.swift").read_text(),
    ]
    with tempfile.TemporaryDirectory(prefix="aigoodbro-credit-observation-") as temporary:
        path = pathlib.Path(temporary)
        fixture = path / "rules.swift"
        fixture.write_text("\n\n".join(parts))
        result = subprocess.run(
            ["/usr/bin/xcrun", "swift", "-module-cache-path", str(path / "ModuleCache"), str(fixture)],
            cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
        )
        print(result.stdout.replace(temporary, "<isolated-temporary>").replace(str(repo), "<worktree>"), end="")
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
