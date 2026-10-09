from __future__ import annotations

import os
import pathlib
import platform
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class AdditionalCLIQuotaTests(unittest.TestCase):
    def test_synthetic_swift_fixture(self) -> None:
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
            ROOT / "Sources/CodexUsageWidget/Services/AdditionalCLIQuotaReader.swift",
            ROOT / "Sources/CodexUsageWidget/Services/TraeCLIQuotaReader.swift",
            ROOT / "tests/AdditionalCLIQuotaFixture.swift",
        ]
        for source in sources:
            self.assertTrue(source.is_file(), source)

        with tempfile.TemporaryDirectory(prefix="additional-cli-quota-") as directory:
            executable = pathlib.Path(directory) / "fixture"
            sdk = subprocess.check_output(
                ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
            ).strip()
            guard = subprocess.run(
                ["python3", str(ROOT / "scripts/check-build-target-idle.py"), str(executable)],
                cwd=ROOT, text=True, capture_output=True, timeout=30, check=False,
            )
            self.assertEqual(guard.returncode, 0, guard.stdout + guard.stderr)
            compile_result = subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-target",
                    f"{platform.machine()}-apple-macos13.0",
                    "-sdk",
                    sdk,
                    "-module-cache-path",
                    str(pathlib.Path(directory) / "ModuleCache"),
                    "-o",
                    str(executable),
                    *(str(source) for source in sources),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=120,
                check=False,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                f"swiftc failed:\n{compile_result.stdout}\n{compile_result.stderr}",
            )
            fixture_home = pathlib.Path(directory) / "synthetic-home"
            fixture_home.mkdir()
            fixture_env = {**os.environ, "CFFIXED_USER_HOME": str(fixture_home)}
            run_result = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
                env=fixture_env,
            )
            self.assertEqual(
                run_result.returncode,
                0,
                f"fixture failed:\n{run_result.stdout}\n{run_result.stderr}",
            )
            self.assertEqual(run_result.stdout.strip(), "additional-cli-quota-fixture: ok")

    def test_static_workbuddy_trae_and_privacy_contract(self) -> None:
        source = (
            ROOT / "Sources/CodexUsageWidget/Services/AdditionalCLIQuotaReader.swift"
        ).read_text(encoding="utf-8")
        fixture = (ROOT / "tests/AdditionalCLIQuotaFixture.swift").read_text(encoding="utf-8")
        self.assertIn("case .workBuddy:", source)
        self.assertIn("case .trae:", source)
        self.assertIn('messageCode: "local_cli_workbuddy_app_session_read_limited"', source)
        self.assertIn('TraeCLIQuotaReader(transport: transport, fileReader: fileReader)', source)
        self.assertIn("case .workBuddy: \"WorkBuddy CLI\"", source)
        self.assertIn("case .trae: \"TRAE SOLO\"", source)
        self.assertNotIn("ProcessInfo.processInfo.environment", source)
        self.assertNotIn("Data(contentsOf:", source)
        self.assertNotIn("URLSession.shared", source)
        self.assertNotIn("credentials.json", source)
        self.assertNotIn("/api/v1/zcode-plan/billing", source)
        self.assertIn("testWorkBuddyAndTraeUnsupportedWithoutIO", fixture)
        self.assertIn("LocalCLIKind.workBuddy, .trae", fixture)
        self.assertIn("local_cli_workbuddy_app_session_read_limited", fixture)
        self.assertIn("local_cli_trae_default_required", fixture)
        self.assertIn("testGeminiExhaustedRemainsAvailable", fixture)
        self.assertIn("remainingFraction\": 0.0", fixture)
        self.assertNotIn("sk-ant-", fixture)
        self.assertNotIn("sk-or-", fixture)


if __name__ == "__main__":
    unittest.main()
