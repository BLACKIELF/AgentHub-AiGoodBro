#!/usr/bin/env python3
"""Exercise the production value types without launching an app or a CLI."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="agb-launch-library-") as directory:
    binary = Path(directory) / "fixture"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library",
        str(ROOT / "Sources/CodexUsageWidget/Domain/AntigravityProxyAccount.swift"),
        str(ROOT / "Sources/CodexUsageWidget/Domain/PrivacyPreview.swift"),
        str(ROOT / "Sources/CodexUsageWidget/Domain/ProviderLaunchLibrary.swift"),
        str(ROOT / "tests/ProviderLaunchLibraryFixture.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
