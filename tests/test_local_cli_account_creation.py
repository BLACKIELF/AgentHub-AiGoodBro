#!/usr/bin/env python3
import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class LocalCLIAccountCreationTests(unittest.TestCase):
    def test_isolated_creation_persistence_and_failure_rollback(self):
        sources = [
            ROOT / "Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift",
            ROOT / "Sources/CodexUsageWidget/Services/LocalCLIAuthenticationReader.swift",
            ROOT / "Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift",
            ROOT / "Sources/CodexUsageWidget/Services/GrokResetStatusObservationReader.swift",
            ROOT / "Sources/CodexUsageWidget/Services/LocalCLIAccountStore.swift",
            ROOT / "Sources/CodexUsageWidget/Services/LocalCLITerminalLauncher.swift",
            ROOT / "tests/LocalCLIAccountCreationFixture.swift",
        ]
        with tempfile.TemporaryDirectory(prefix="local-cli-account-creation-") as directory:
            output = pathlib.Path(directory) / "fixture"
            sdk = pathlib.Path("/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk")
            if not sdk.is_dir():
                sdk = pathlib.Path(subprocess.check_output(
                    ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
            compiled = subprocess.run([
                "xcrun", "swiftc", "-target", f"{platform.machine()}-apple-macos13.0",
                "-sdk", str(sdk), "-module-cache-path", str(pathlib.Path(directory) / "ModuleCache"),
                "-o", str(output), *(str(source) for source in sources),
            ], cwd=ROOT, text=True, capture_output=True, timeout=180, check=False)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            ran = subprocess.run([str(output)], cwd=ROOT, text=True, capture_output=True,
                                 timeout=30, check=False)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertEqual(ran.stdout.strip(), "local-cli-account-creation-fixture: ok")


if __name__ == "__main__":
    unittest.main()
