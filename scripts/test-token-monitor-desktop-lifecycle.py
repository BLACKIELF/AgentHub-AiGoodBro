#!/usr/bin/env python3
"""Exercise the real desktop controller with an isolated short-lived fake Helper."""

from pathlib import Path
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
    with tempfile.TemporaryDirectory(prefix="agb-desktop-lifecycle-") as directory:
        executable = Path(directory) / "desktop-lifecycle-test"
        subprocess.run(
            ["swiftc", "-O", "-parse-as-library", str(MODELS), str(ENGINE), str(CONTROLLER), str(FIXTURE), "-o", str(executable)],
            cwd=ROOT,
            check=True,
        )
        subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=50)


if __name__ == "__main__":
    main()
