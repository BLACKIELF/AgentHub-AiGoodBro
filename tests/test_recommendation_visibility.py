#!/usr/bin/env python3
"""Compile the production store only; never launch an app or inspect real skills."""
import pathlib
import platform
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="recommendation-visibility-") as directory:
    temporary = pathlib.Path(directory)
    sdk = pathlib.Path("/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk")
    if not sdk.is_dir():
        sdk = pathlib.Path(subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
    binary = temporary / "fixture"
    command = [
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-target", f"{platform.machine()}-apple-macos13.0", "-sdk", str(sdk),
        "-module-cache-path", str(temporary / "modules"),
        str(ROOT / "Sources/CodexUsageWidget/Services/RecommendationVisibilityStore.swift"),
        str(ROOT / "tests/RecommendationVisibilityFixture.swift"),
        "-o", str(binary),
    ]
    subprocess.run(command, cwd=ROOT, check=True, timeout=120)
    subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=20)
