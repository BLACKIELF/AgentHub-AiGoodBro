#!/usr/bin/env python3
"""Run the tagged Go resolver test against a fixture emitted by Rust itself."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    env = os.environ.copy()
    with tempfile.TemporaryDirectory(prefix="aigb-windows-execution-") as temp:
        fixture = Path(temp) / "fixture.json"
        with fixture.open("w", encoding="utf-8", newline="\n") as output:
            subprocess.run(
                [
                    "cargo",
                    "run",
                    "--quiet",
                    "--locked",
                    "-p",
                    "codexu-core",
                    "--example",
                    "windows_execution_fixture",
                ],
                cwd=ROOT / "windows",
                stdout=output,
                check=True,
            )

        cases = json.loads(fixture.read_text(encoding="utf-8"))["cases"]
        if len(cases) != 4:
            raise RuntimeError(f"Rust emitted {len(cases)} cases; expected 4")
        env["AIGB_WINDOWS_EXECUTION_FIXTURE"] = str(fixture)
        subprocess.run(
            [
                "go",
                "test",
                "-tags",
                "windows_execution_integration",
                "./...",
                "-run",
                "^TestWindowsExecutionRustPayload$",
                "-count=1",
            ],
            cwd=ROOT / "Companion" / "Hub",
            env=env,
            check=True,
        )


if __name__ == "__main__":
    main()
