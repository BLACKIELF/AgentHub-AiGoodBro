#!/usr/bin/env python3
import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ZCodeCLIQuotaTests(unittest.TestCase):
    def test_actual_production_source_with_synthetic_fixture(self):
        sources = [
            ROOT / "Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift",
            ROOT / "Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift",
            ROOT / "Sources/CodexUsageWidget/Services/TokenMonitorEngine.swift",
            ROOT / "Sources/CodexUsageWidget/Services/TokenMonitorLocalCLIQuotaReader.swift",
            ROOT / "Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift",
            ROOT / "Sources/CodexUsageWidget/Services/LocalCLIQuotaReader.swift",
            ROOT / "Sources/CodexUsageWidget/Services/ClaudeSubscriptionService.swift",
            ROOT / "Sources/CodexUsageWidget/Services/LocalCLIQuotaRefresh.swift",
            ROOT / "Sources/CodexUsageWidget/Services/CCSwitchClaudeRelay.swift",
            ROOT / "Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift",
            ROOT / "Sources/CodexUsageWidget/Services/ZCodeCLIQuotaReader.swift",
            ROOT / "tests/ZCodeCLIQuotaFixture.swift",
        ]
        with tempfile.TemporaryDirectory(prefix="zcode-cli-quota-") as directory:
            output = pathlib.Path(directory) / "fixture"
            sdk = subprocess.check_output(
                ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
            ).strip()
            guard = subprocess.run(
                ["python3", str(ROOT / "scripts/check-build-target-idle.py"), str(output)],
                cwd=ROOT, text=True, capture_output=True, timeout=30, check=False,
            )
            self.assertEqual(guard.returncode, 0, guard.stdout + guard.stderr)
            compiled = subprocess.run([
                "xcrun", "swiftc", "-target", f"{platform.machine()}-apple-macos13.0",
                "-sdk", str(sdk), "-module-cache-path", str(pathlib.Path(directory) / "ModuleCache"),
                "-o", str(output), *(str(source) for source in sources),
            ], cwd=ROOT, text=True, capture_output=True, timeout=120, check=False)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            ran = subprocess.run([str(output)], cwd=ROOT, text=True, capture_output=True,
                                 timeout=30, check=False)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertEqual(ran.stdout.strip(), "zcode-cli-quota-fixture: ok")

    def test_static_privacy_and_scope_contract(self):
        source = (ROOT / "Sources/CodexUsageWidget/Services/ZCodeCLIQuotaReader.swift").read_text()
        self.assertIn('"builtin:\\(family)-coding-plan"', source)
        self.assertIn('"open.bigmodel.cn", "api.z.ai"', source)
        self.assertIn('"/api/monitor/usage/quota/limit"', source)
        self.assertIn('identityFingerprint: fingerprint', source)
        self.assertIn('"credentials.json"', source)
        self.assertIn('"setting.json"', source)
        self.assertIn("credentialsUnreadable", source)
        self.assertIn('ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]', source)
        self.assertNotIn("Data(contentsOf:", source)
        self.assertNotIn("URLSession.shared", source)

    def test_static_expired_reset_is_not_a_window(self) -> None:
        source = (ROOT / "Sources/CodexUsageWidget/Services/ZCodeCLIQuotaReader.swift").read_text()
        fixture = (ROOT / "tests/ZCodeCLIQuotaFixture.swift").read_text()
        self.assertIn("parsed >= now", source)
        self.assertIn("1_700_000_000_000", fixture)
        self.assertIn("testAccountSwitchRefusesOldQuota", fixture)


if __name__ == "__main__":
    unittest.main()
