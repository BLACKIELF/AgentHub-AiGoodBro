#!/usr/bin/env python3
"""Compile production export module against production DTOs; isolated data only."""
import hashlib
import json
import argparse
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "Sources/CodexUsageWidget"
INPUTS = [BASE / value for value in [
    "Domain/UsageModels.swift", "Domain/CodexResetNotice.swift",
    "Domain/FeishuMessageOptions.swift", "Domain/MiniProgramAccountExport.swift",
]] + [ROOT / "tests/MiniProgramAccountExportFixture.swift"]


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
    parser = argparse.ArgumentParser()
    parser.add_argument('--server-root', type=Path, help='Optional explicit Mini Program source root, never its .runtime state')
    parser.add_argument('--receipt', type=Path, help='Save hashes and isolated verification status')
    args = parser.parse_args()
    frozen = {path: path.read_bytes() for path in INPUTS}
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for path, data in frozen.items()}
    with tempfile.TemporaryDirectory(prefix="agb-mini-export-") as raw:
        folder = Path(raw)
        support = folder / "Support.swift"
        support.write_text('''import Foundation
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
''')
        sources = [support]
        for path, content in frozen.items():
            target = folder / path.name
            if path.name == "FeishuMessageOptions.swift":
                content = ("import Foundation\n" + declaration(content.decode(), "struct CreditBalancePresentation:")).encode()
            target.write_bytes(content)
            sources.append(target)
        binary = folder / "checks"
        compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(folder / "modules"), *map(str, sources), "-o", str(binary)],
            capture_output=True, text=True, timeout=60)
        output = compiled.stdout + compiled.stderr
        result = None
        bridge = None
        server_hashes = {}
        if compiled.returncode == 0:
            result = subprocess.run([str(binary), str(folder / "v1-snapshots.json")], capture_output=True, text=True, timeout=20)
            output += result.stdout + result.stderr
        if result and result.returncode == 0 and args.server_root:
            # Freeze just the four source modules. No runtime config/data/env.
            server_dir = folder / 'server'
            server_dir.mkdir()
            for name in ['server.cjs', 'storage.cjs', 'notifications.cjs', 'public-feed.cjs']:
                source = args.server_root / 'server' / name
                data = source.read_bytes()
                (server_dir / name).write_bytes(data)
                server_hashes[name] = hashlib.sha256(data).hexdigest()
            fixture = ROOT / 'tests/MiniProgramBridgeContractFixture.cjs'
            data = fixture.read_bytes()
            target = folder / fixture.name
            target.write_bytes(data)
            hashes[str(fixture.relative_to(ROOT))] = hashlib.sha256(data).hexdigest()
            bridge = subprocess.run(['node', str(target), str(server_dir), str(folder / 'v1-snapshots.json'), str(folder / 'state')],
                capture_output=True, text=True, timeout=30)
            output += bridge.stdout + bridge.stderr
        print(output.replace(str(ROOT), "<workspace>").replace(raw, "<fixture>"), end="")
        receipt = {"version": "1013v1", "checkedAt": datetime.now(timezone.utc).isoformat(), "inputs": hashes, "compileExitCode": compiled.returncode,
            "testExitCode": result.returncode if result else None, "realAccountIO": False,
            "externalNetworkSends": 0, "packaged": False, "bridgeExitCode": bridge.returncode if bridge else None,
            "serverInputs": server_hashes, "output": output.replace(str(ROOT), "<workspace>").replace(raw, "<fixture>")}
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({key:value for key,value in receipt.items() if key!='output'}, sort_keys=True))
        return compiled.returncode or (result.returncode if result else 1) or (bridge.returncode if bridge else 0)


if __name__ == "__main__":
    raise SystemExit(main())
