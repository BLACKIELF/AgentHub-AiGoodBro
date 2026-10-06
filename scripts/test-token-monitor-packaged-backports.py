#!/usr/bin/env python3
"""Run synthetic backport checks inside a supplied Electron helper ASAR.

The helper is used only as ELECTRON_RUN_AS_NODE. No bootstrap, GUI, account,
credentials, or real user paths are opened.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import subprocess
import tempfile
from pathlib import Path


CHECK_JS = Path(__file__).resolve().parents[1] / "tests/token-monitor-packaged-backports-1006v1.cjs"


def helper_binary(helper_app: Path) -> Path:
    macos = helper_app / "Contents" / "MacOS"
    candidates = [p for p in macos.iterdir() if p.is_file() and os.access(p, os.X_OK)] if macos.is_dir() else []
    if len(candidates) != 1:
        raise ValueError(f"expected one executable in {macos}, found {len(candidates)}")
    binary = candidates[0]
    with binary.open("rb") as stream:
        magic = stream.read(4)
    if magic not in (bytes.fromhex("feedface"), bytes.fromhex("cefaedfe"), bytes.fromhex("feedfacf"), bytes.fromhex("cffaedfe"), bytes.fromhex("cafebabe"), bytes.fromhex("bebafeca")):
        raise ValueError("helper executable is not Mach-O")
    return binary


def sha256_file(file: Path) -> str:
    digest = hashlib.sha256()
    with file.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(helper_app: Path) -> dict:
    helper_app = helper_app.expanduser().resolve()
    binary = helper_binary(helper_app)
    asar = helper_app / "Contents" / "Resources" / "app.asar"
    if not asar.is_file():
        raise ValueError(f"missing helper ASAR: {asar}")
    with tempfile.TemporaryDirectory(prefix="tm-packaged-home-") as isolated_home:
        env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL") if key in os.environ}
        env.update({"ELECTRON_RUN_AS_NODE": "1", "HOME": isolated_home, "CODEX_HOME": str(Path(isolated_home) / ".codex"), "TMPDIR": isolated_home})
        process = subprocess.Popen([str(binary), str(CHECK_JS), str(asar)], env=env, cwd=isolated_home, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=120)
        finally:
            # The dedicated process group contains only this test's owner/children.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if process.poll() is None:
                process.wait(timeout=10)
        completed = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
    if completed.returncode:
        raise RuntimeError(f"packaged helper check failed ({completed.returncode}): {completed.stderr[-4000:]}")
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("packaged helper emitted no result")
    result = json.loads(lines[-1])
    if not result.get("ok"):
        raise RuntimeError(json.dumps(result, ensure_ascii=False))
    result.update({"helperApp": str(helper_app), "helperBinary": str(binary), "asar": str(asar), "asarSha256": sha256_file(asar), "helperBinarySha256": sha256_file(binary)})
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper-app", required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.helper_app), ensure_ascii=False))
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
