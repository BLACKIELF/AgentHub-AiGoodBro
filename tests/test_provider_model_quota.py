#!/usr/bin/env python3
"""Compile the production DTO/projection and exercise isolated synthetic readings."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="agb-model-quota-") as directory:
    output = Path(directory) / "fixture"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(Path(directory) / "ModuleCache"),
        str(ROOT / "Sources/CodexUsageWidget/Domain/AntigravityProxyAccount.swift"),
        str(ROOT / "Sources/CodexUsageWidget/Domain/ProviderModelQuotaPresentation.swift"),
        str(ROOT / "tests/ProviderModelQuotaFixture.swift"), "-o", str(output),
    ], check=True, timeout=180)
    subprocess.run([str(output)], check=True, timeout=30)
