#!/usr/bin/env python3
"""Refuse an overwrite that would change the identity trusted by macOS Keychain.

Only code-signing metadata is read. Credentials and Keychain ACLs are untouched.
Apple TN2206 defines upgrade identity by the installed designated requirement.
"""
from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path


def check_upgrade(installed: Path, candidate: Path) -> None:
    def signed(*args: str) -> str:
        result = subprocess.run(["/usr/bin/codesign", *args], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise ValueError("signature verification failed")
        return result.stdout + result.stderr

    identifiers = []
    for bundle in (installed, candidate):
        if bundle.is_symlink() or not bundle.is_dir():
            raise ValueError("expected a real app bundle")
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        identifier = info.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not identifier:
            raise ValueError("missing bundle identifier")
        identifiers.append(identifier)
        signed("--verify", "--deep", "--strict", str(bundle))
    if identifiers[0] != identifiers[1]:
        raise ValueError("bundle identifier changed")
    description = signed("--display", "--requirements", "-", str(installed))
    requirements = [line.removeprefix("designated => ") for line in description.splitlines() if line.startswith("designated => ")]
    if len(requirements) != 1 or not requirements[0].strip():
        raise ValueError("installed signing identity is unavailable")
    # Evaluate the old requirement against the new signed code. Text equality
    # would incorrectly reject valid certificate renewals or accept a spoof.
    signed("--verify", "--strict", "--test-requirement", "=" + requirements[0], str(candidate))


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: check-upgrade-identity.py INSTALLED_APP CANDIDATE_APP", file=sys.stderr)
        return 2
    try:
        check_upgrade(Path(sys.argv[1]), Path(sys.argv[2]))
    except (ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException):
        print("install: upgrade identity is incompatible or unverifiable; keeping the current app and its saved connections.", file=sys.stderr)
        return 1
    print("install: upgrade satisfies the installed signing identity; saved Keychain access can be retained.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
