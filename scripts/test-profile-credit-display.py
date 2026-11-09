#!/usr/bin/env python3
"""Offline production getter/selection/Feishu-test projection checks; never sends."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/CodexUsageWidget"


def declaration(source, needle):
    start = source.index(needle)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise ValueError(needle)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-file", type=Path, default=SOURCE / "Services/UsageStore.swift")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    files = [args.source_file.resolve(), SOURCE / "Services/CodexProfileStore.swift",
             SOURCE / "Domain/UsageModels.swift", SOURCE / "Domain/AgentRuntime.swift",
             SOURCE / "Domain/AutomaticAccountSwitch.swift", SOURCE / "Domain/CodexSwitchSnapshotProjection.swift",
             ROOT / "tests/ProfileCreditDisplayFixture.swift", Path(__file__).resolve()]
    snapshots = {path: path.read_bytes() for path in files}
    usage, profiles, models, runtimes, policy, projection, fixture = [snapshots[p].decode() for p in files[:7]]
    usage_model = declaration(models, "struct UsageSnapshot:")
    usage_model = usage_model[:usage_model.index("    func replacingTaskBoard(")] + "\n}"
    types = "\n".join([
        *[declaration(models, needle) for needle in ["struct RateWindow:", "struct CreditsInfo:", "struct ResetCreditDetail:", "struct AccountInfo:"]],
        *[declaration(profiles, needle) for needle in ["struct CodexQuotaWindowSnapshot:", "struct CodexAccountSnapshot:", "struct CodexCredentialIdentity:"]],
        usage_model, declaration(runtimes, "enum RuntimeScope:"),
        declaration(policy, "enum AutomaticQuotaWindow:"), declaration(policy, "struct AutomaticSwitchQuotaState:"), projection,
    ])
    methods = "\n".join(declaration(usage, needle) for needle in [
        "func availableResetCredits(", "func resetCreditExpiries(", "func selectMonitorProfile(",
        "private func clearDisplayedAccount()", "func selectRuntime(", "func sendFeishuTestNotification()",
    ])
    code = fixture.replace("// PRODUCTION_TYPES", types).replace("// PRODUCTION_METHODS", methods)
    code = code.replace("// PRODUCTION_RUNTIME_PROJECTION", "\n".join(declaration(runtimes, needle) for needle in ["func runtime(for", "func displaySnapshot(for"]))
    with tempfile.TemporaryDirectory(prefix="aigoodbro-profile-credit-") as temporary:
        folder = Path(temporary)
        swift = folder / "checks.swift"
        swift.write_text(code)
        result = subprocess.run(
            ["xcrun", "swift", "-swift-version", "5", "-module-cache-path", str(folder / "modules"), str(swift)],
            cwd=ROOT, capture_output=True, text=True, timeout=120)
        output = (result.stdout + result.stderr).replace(temporary, "<isolated-temporary>")
    unchanged = all(path.read_bytes() == data for path, data in snapshots.items())
    receipt = {"exitCode": result.returncode, "inputsUnchanged": unchanged,
               "inputHashes": {str(path.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for path, data in snapshots.items()},
               "output": output, "boundaries": {"credentialReads": 0, "networkCalls": 0, "notificationsSent": 0, "accountStateWrites": 0}}
    if args.receipt:
        args.receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(output, end="")
    raise SystemExit(result.returncode or (0 if unchanged else 2))


if __name__ == "__main__":
    main()
