#!/usr/bin/env python3
"""Exercise the real desktop controller with an isolated short-lived fake Helper."""

from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / "Sources/CodexUsageWidget/Services/TokenMonitorDesktopController.swift"
MODELS = ROOT / "Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift"
ENGINE = ROOT / "Sources/CodexUsageWidget/Services/TokenMonitorEngine.swift"
FIXTURE = ROOT / "tests/TokenMonitorDesktopLifecycleFixture.swift"


def main() -> None:
    if sys.platform != "darwin":
        raise SystemExit("macOS is required for desktop lifecycle fixture")
    parser = argparse.ArgumentParser()
    parser.add_argument("--boundaries-only", action="store_true")
    parser.add_argument("--controller-file", type=Path, default=CONTROLLER)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    controller = args.controller_file.resolve()
    paths = [MODELS, ENGINE, controller, FIXTURE, Path(__file__).resolve()]
    snapshots = {path: path.read_bytes() for path in paths}
    with tempfile.TemporaryDirectory(prefix="agb-desktop-lifecycle-") as directory:
        folder = Path(directory)
        executable = folder / "desktop-lifecycle-test"
        # Same-file private test access avoids exposing production socket/state APIs.
        combined = folder / "ControllerFixture.swift"
        combined.write_bytes(snapshots[controller] + b"\n" + snapshots[FIXTURE])
        sources = []
        for path in [MODELS, ENGINE]:
            frozen = folder / path.name
            frozen.write_bytes(snapshots[path])
            sources.append(frozen)
        compiled = subprocess.run(
            ["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(folder / "modules"), *map(str, sources), str(combined), "-o", str(executable)],
            cwd=ROOT,
            capture_output=True, text=True,
        )
        compiler_output = (compiled.stdout + compiled.stderr).replace(directory, "<isolated-temporary>")
        if compiler_output:
            print(compiler_output, end="")
        compiled.check_returncode()
        result = subprocess.run([str(executable), *(["--boundaries-only"] if args.boundaries_only else [])], cwd=ROOT, timeout=60, capture_output=True, text=True)
        output = (result.stdout + result.stderr).replace(directory, "<isolated-temporary>")
    unchanged = all(path.read_bytes() == data for path, data in snapshots.items())
    receipt = {"exitCode": result.returncode, "inputsUnchanged": unchanged, "output": output,
               "inputHashes": {str(path.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for path, data in snapshots.items()}}
    if args.receipt:
        args.receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(output, end="")
    print(json.dumps({key: value for key, value in receipt.items() if key != "output"}))
    raise SystemExit(result.returncode or (0 if unchanged else 2))


if __name__ == "__main__":
    main()
