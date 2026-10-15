#!/usr/bin/env python3
"""Offline reset-notice evaluator/ledger checks; no account, sender or Keychain I/O."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "Sources/CodexUsageWidget"
INPUTS = [BASE / value for value in [
    "Domain/UsageModels.swift", "Domain/MessageChannel.swift",
    "Domain/CodexResetNotice.swift", "Services/CodexResetNoticeDeliveryStore.swift",
]] + [ROOT / "tests/ResetNoticeFixture.swift"]


def declaration(source, needle):
    start = source.index(needle)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(needle)


def main():
    frozen = {path: path.read_bytes() for path in INPUTS}
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for path, data in frozen.items()}
    with tempfile.TemporaryDirectory(prefix="next-reset-notice-fixture-") as temporary:
        folder = Path(temporary)
        os.chmod(folder, 0o700)
        channel = frozen[BASE / "Domain/MessageChannel.swift"].decode()
        stubs = '''import Foundation
struct ModelInferencePerformanceHistory: Equatable {}
struct AgentTokenShare: Equatable {}
enum TaskRuntimeState { case recorded }
enum TaskSourceKind { case fixture }
enum TaskDisplayState { case fixture }
enum TaskStateBasis { case fixture }
enum WidgetLanguage {
    case fixture
    static func storedOrAutomatic() -> Self { .fixture }
    func text(_ zh: String, _ en: String) -> String { en }
}
'''
        # Compile actual DTO/error declarations, not a mirrored transport policy.
        stubs += "\n".join(declaration(channel, needle) for needle in [
            "enum MessageChannelError:", "struct MessageDeliveryReceipt:", "enum MessageDeliveryOutcome:",
        ])
        support = folder / "Support.swift"
        support.write_text(stubs)
        sources = [support]
        for path, data in frozen.items():
            if path.name == "MessageChannel.swift":
                continue
            target = folder / path.name
            target.write_bytes(data)
            sources.append(target)
        binary = folder / "checks"
        command = ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(folder / "modules"), *map(str, sources), "-o", str(binary)]
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
        output = compiled.stdout + compiled.stderr
        run = None
        races = []
        if compiled.returncode == 0:
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            output += run.stdout + run.stderr
        if run and run.returncode == 0:
            race = folder / "race"
            race.mkdir(mode=0o700)
            prepared = subprocess.run([str(binary), "--race-prepare", str(race)], capture_output=True, text=True, timeout=10)
            if prepared.returncode:
                output += prepared.stdout + prepared.stderr
                raise RuntimeError("Cross-process fixture preparation failed")
            children = [subprocess.Popen([str(binary), "--race-reserve", str(race), str(index)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for index in range(2)]
            deadline = time.monotonic() + 5
            while not all((race / ("ready-" + str(index))).exists() for index in range(2)) and time.monotonic() < deadline:
                time.sleep(0.01)
            if not all((race / ("ready-" + str(index))).exists() for index in range(2)):
                for child in children:
                    child.kill()
                raise RuntimeError("Cross-process fixture did not reach barrier")
            (race / "start").touch()
            for child in children:
                stdout, stderr = child.communicate(timeout=10)
                races.append({"exitCode": child.returncode, "stdout": stdout.strip(), "stderr": stderr.strip()})
            if not (all(item["exitCode"] == 0 for item in races)
                    and sum(item["stdout"] == "RESERVED=1" for item in races) == 1
                    and sum(item["stdout"] in ["RESERVED=0", "RESERVED=BUSY"] for item in races) == 1):
                raise RuntimeError("Cross-process reserve did not have exactly one winner")
            output += "PASS cross-process reserve: exactly one winner\n"
        output = output.replace(str(ROOT), "<workspace>").replace(temporary, "<fixture>")
        print(output, end="")
        print(json.dumps({"version": "1013v1", "inputs": hashes, "compileExitCode": compiled.returncode,
            "testExitCode": run.returncode if run else None, "crossProcess": races,
            "realAccountIO": False, "networkSends": 0, "redemptionCalls": 0}, sort_keys=True))
        if compiled.returncode:
            return compiled.returncode
        return run.returncode if run else 1


if __name__ == "__main__":
    raise SystemExit(main())
