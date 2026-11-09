#!/usr/bin/env python3
"""Exercise the actual finishingLoad branch with offline optional-source doubles."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/CodexUsageWidget"


def between(text, start, end):
    first = text.index(start)
    return text[first:text.index(end, first)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reader", type=Path, default=SOURCE / "Services/CodexUsageReader.swift")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    paths = [args.reader, SOURCE / "Services/CCSwitchUsageReader.swift",
             SOURCE / "Domain/UsageModels.swift", ROOT / "tests/CCSwitchOptionalUsageFixture.swift"]
    frozen = {str(path): path.read_bytes() for path in paths}
    reader, cc, models, fixture = [frozen[str(path)].decode() for path in paths]
    finishing = between(reader, "    func finishingLoad(", "    func loadTaskBoard(")
    total = between(reader, "private func summedTokenCounts(", "private func intValue(")
    shares = between(cc, "struct AgentTokenShare:", "func customTokenCount(")
    local = between(models, "enum LocalUsageCoverage:", "enum TaskColumnKind:")
    zcode = between(cc, "enum ZCodeUsageReader {", "/// 用户手动录入").replace(
        "enum ZCodeUsageReader {", "enum ActualZCodeUsageReader {", 1)
    code = fixture.replace("// ACTUAL_PRODUCTION_TYPES", shares + local + total + zcode).replace(
        "// ACTUAL_FINISHING_LOAD", finishing)
    with tempfile.TemporaryDirectory(prefix="ccswitch-optional-usage-") as directory:
        work = Path(directory)
        source = work / "main.swift"
        source.write_text(code)
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        binary = work / "fixture"
        compiled = subprocess.run(
            ["xcrun", "swiftc", "-target", f"{platform.machine()}-apple-macos13.0", "-sdk", sdk,
             "-module-cache-path", str(work / "modules"), str(source), "-o", str(binary)],
            capture_output=True, text=True, timeout=120)
        if compiled.returncode:
            raise RuntimeError(compiled.stderr)
        ran = subprocess.run([str(binary), str(work / "empty-home")], capture_output=True, text=True, timeout=10)
    unchanged = all(path.read_bytes() == frozen[str(path)] for path in paths)
    receipt = {"sourceHashes": {path: hashlib.sha256(data).hexdigest() for path, data in frozen.items()},
               "inputsUnchanged": unchanged, "exitCode": ran.returncode, "output": ran.stdout.strip()}
    if args.receipt:
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(ran.stdout.strip())
    if ran.returncode or not unchanged:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
