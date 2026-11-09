#!/usr/bin/env python3
"""Exercise production profile matching/record/backfill with in-memory boundaries.

Credential lookup is an injected dictionary of synthetic homes; no auth file,
network, process launch, defaults, or account-state write is permitted.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / "Sources/CodexUsageWidget/Services/CodexProfileStore.swift"
MODELS = ROOT / "Sources/CodexUsageWidget/Domain/UsageModels.swift"
COMPARISON = ROOT / "Sources/CodexUsageWidget/Domain/CodexQuotaEventTracker.swift"
TEST = ROOT / "tests/ProfileIdentityObservationTests.swift"


def declaration(source, needle):
    start = source.index(needle)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise ValueError(needle)


STUBS = r'''
import Foundation
typealias OfficialResetHistory = String
typealias ChromeProfileBinding = String
typealias CodexExecutionPreference = String
typealias DispatchParticipationWindow = String
struct CodexOfficialProfileSnapshot: Codable, Equatable { var planType: String? }
enum CodexExecutable { static func version() -> String? { "synthetic-version" } }
enum CodexOfficialProfileReader {
    static var identities: [String: CodexCredentialIdentity] = [:]
    static func credentialIdentity(codexHomeURL: URL) -> CodexCredentialIdentity? {
        precondition(codexHomeURL.path.hasPrefix("/synthetic-profile/"))
        return identities[codexHomeURL.path]
    }
}
enum CreditBalancePresentation {
    static func normalizedBalance(_ value: String?) -> String? { value }
}
enum DispatchParticipationSync {
    static func registrationIdentityHash(_ value: String) -> String { "synthetic-" + value }
}
struct UsageSnapshot {
    var refreshedAt: Date
    var account: AccountInfo?
    var limitId: String? = "codex"
    var limitName: String? = nil
    var quotaReadSucceeded: Bool = true
    var fiveHourQuota: RateWindow? = nil
    var sevenDayQuota: RateWindow? = nil
    var monthlyQuota: RateWindow? = nil
    var credits: CreditsInfo? = nil
    var messages: [String] = []
}
'''


def fixture(store, models, comparison, tests):
    profile = declaration(store, "struct CodexProfile:")
    fields = profile[:profile.index("    var participatesInAutomaticSwitch:")]
    flags = "\n".join(declaration(profile, needle) for needle in ["var participatesInAutomaticSwitch:", "var isDispatchPriorityEnabled:"])
    identity = profile[profile.index("    var codexHomeURL:"):]
    policy = "enum CodexWarmUpPolicy {\n" + "\n".join(
        declaration(store, needle) for needle in ["static func didConsumeReset("]
    ) + "\nstatic let unexpectedResetDrop = 8.0\nstatic let resetStartTolerance: TimeInterval = 600\n}\n"
    wrapper = r'''
final class ProfileFixtureStore {
    enum WarmUpStateError: Error { case unverifiedIdentityOrState }
    struct State {
        var profiles: [CodexProfile]
        var selectedMonitorProfileID: String = "system"
        var resetCounters: [String: CodexAccountResetCounter]? = nil
    }
    var state: State
    var persistedChanges = 0
    init(_ profiles: [CodexProfile]) { state = State(profiles: profiles) }
    private func mutateState(_ mutation: () throws -> Bool) throws {
        if try mutation() { persistedChanges += 1 }
    }
'''
    methods = "\n".join(("@discardableResult\n" if needle == "func record(\n" else "") + declaration(store, needle) for needle in [
        "func effectiveCredentialHome(for",
        "func selectMonitorForSystemAccount()",
        "func record(\n",
        "static func quotaFailureReason(",
        "private func resetCountingBaseline(" if "private func resetCountingBaseline(" in store else "private func resetAlreadyObservedInGroup(",
        "func backfillResetCountersFromHistory()",
        "private static func backfillResetCountersFromHistory(in",
        "func recordWarmUp(\n",
        "static func safeWarmUpFailureCode(",
    ])
    return "\n".join([
        STUBS,
        *[declaration(models, needle) for needle in [
            "struct RateWindow:", "struct CreditsInfo:", "struct ResetCreditDetail:", "struct AccountInfo:",
        ]],
        declaration(comparison, "struct CodexResetCreditComparison:"),
        *[declaration(store, needle) for needle in [
            "struct CodexQuotaWindowSnapshot:", "struct CodexAccountSnapshot:",
            "struct CodexResetCreditReceipt:", "struct CodexCredentialIdentity:", "struct CodexAccountResetCounter:",
            "struct CodexWarmUpAttempt:", "struct CodexWarmUpRequest:",
        ]],
        fields + flags + "\n" + identity, policy, wrapper + methods + "\n}", tests,
    ])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-file", type=Path, default=STORE)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    args.source_file = args.source_file.resolve()
    files = [args.source_file, MODELS, COMPARISON, TEST, Path(__file__).resolve()]
    inputs = {path: path.read_bytes() for path in files}
    source = fixture(*(inputs[path].decode() for path in files[:4]))
    with tempfile.TemporaryDirectory(prefix="aigoodbro-profile-observations-") as temporary:
        folder = Path(temporary)
        swift = folder / "checks.swift"
        swift.write_text(source)
        run = subprocess.run(
            ["xcrun", "swift", "-swift-version", "5", "-module-cache-path", str(folder / "modules"), str(swift)],
            cwd=ROOT, capture_output=True, text=True, timeout=120,
        )
        output = (run.stdout + run.stderr).replace(temporary, "<isolated-temporary>")
    unchanged = all(path.read_bytes() == data for path, data in inputs.items())
    receipt = {
        "exitCode": run.returncode,
        "inputsUnchanged": unchanged,
        "inputHashes": {str(path.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for path, data in inputs.items()},
        "output": output,
        "boundaries": {"credentials": "in-memory synthetic dictionary", "accountState": "in-memory", "networkCalls": 0, "appLaunches": 0},
    }
    if args.receipt:
        args.receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(output, end="")
    if not unchanged:
        raise SystemExit("Source changed during verification")
    raise SystemExit(run.returncode)


if __name__ == "__main__":
    main()
