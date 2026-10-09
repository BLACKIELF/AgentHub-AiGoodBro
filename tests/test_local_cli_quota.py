#!/usr/bin/env python3
import hashlib
import os
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DOMAIN = ROOT / "Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift"
READER = ROOT / "Sources/CodexUsageWidget/Services/LocalCLIQuotaReader.swift"
BOUNDED_READER = ROOT / "Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift"
FIXTURE = ROOT / "tests/LocalCLIQuotaFixture.swift"
KIMI_FIXTURE = ROOT / "tests/KimiCLIQuotaFixture.swift"
GROK_FIXTURE = ROOT / "tests/GrokCLIQuotaContractFixture.swift"
KIMI_RENEWAL_FIXTURE = ROOT / "tests/KimiRenewalFixture.swift"
MODELS = ROOT / "Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift"
ENGINE = ROOT / "Sources/CodexUsageWidget/Services/TokenMonitorEngine.swift"
UPSTREAM_READER = ROOT / "Sources/CodexUsageWidget/Services/TokenMonitorLocalCLIQuotaReader.swift"


class LocalCLIQuotaTests(unittest.TestCase):
    def test_actual_swift_sources_with_synthetic_fixture(self):
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip()
        self.assertTrue(Path(sdk).is_dir(), f"synthetic-test SDK missing: {sdk}")
        with tempfile.TemporaryDirectory(prefix="local-cli-quota-test-") as temporary:
            cache = Path(temporary) / "module-cache"
            cache.mkdir()
            for fixture, expected in (
                (FIXTURE, "PASS local-cli-quota fixture"),
                (KIMI_FIXTURE, "PASS kimi-cli-quota fixture"),
                (GROK_FIXTURE, "GROK CONTRACT: 20/20 passed"),
                (KIMI_RENEWAL_FIXTURE, "PASS kimi-renewal candidate fixture (4 scenarios)"),
            ):
                output = Path(temporary) / fixture.stem
                guard = subprocess.run(
                    ["python3", str(ROOT / "scripts/check-build-target-idle.py"), str(output)],
                    cwd=ROOT, text=True, capture_output=True, timeout=30, check=False,
                )
                self.assertEqual(guard.returncode, 0, guard.stdout + guard.stderr)
                compile_result = subprocess.run(
                    [
                        "xcrun", "swiftc",
                        "-sdk", sdk,
                        "-target", f"{platform.machine()}-apple-macos13.0",
                        "-module-cache-path", str(cache),
                        str(DOMAIN),
                        str(MODELS),
                        str(ENGINE),
                        str(UPSTREAM_READER),
                        str(BOUNDED_READER),
                        str(READER),
                        str(ROOT / "Sources/CodexUsageWidget/Services/ClaudeSubscriptionService.swift"),
                        str(ROOT / "Sources/CodexUsageWidget/Services/LocalCLIQuotaRefresh.swift"),
                        str(ROOT / "Sources/CodexUsageWidget/Services/CCSwitchClaudeRelay.swift"),
                        str(ROOT / "Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift"),
                        str(fixture),
                        "-o", str(output),
                    ],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    timeout=90,
                    check=False,
                )
                self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
                run_result = subprocess.run(
                    [str(output)],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    timeout=30,
                    check=False,
                    env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "KIMI_FIXTURE_ROOT": temporary},
                )
                self.assertEqual(run_result.returncode, 0, run_result.stderr)
                self.assertEqual(run_result.stdout.strip(), expected)

    def test_fixed_protocol_and_privacy_contracts(self):
        source = READER.read_text(encoding="utf-8")
        relay = (ROOT / "Sources/CodexUsageWidget/Services/CCSwitchClaudeRelay.swift").read_text(encoding="utf-8")
        self.assertIn("https://cli-chat-proxy.grok.com/v1/billing?format=credits", source)
        self.assertIn("https://api.kimi.com/coding/v1/usages", source)
        self.assertIn("https://api.anthropic.com/api/oauth/usage", source)
        self.assertIn("https://opencode.ai/zen/go/v1/usage", source)
        self.assertIn('root["opencode-go"]', source)
        self.assertNotIn("HTTPCookieStorage.shared", source)
        self.assertNotIn("security ", source)
        self.assertNotIn("Swift.print(", source)
        self.assertNotIn("DebugLogger", source)
        self.assertNotIn("Data(contentsOf:", source)
        self.assertIn("DispatchParticipationSync.readBoundedRegularFile", source)
        self.assertIn("completionHandler(nil)", source)
        self.assertIn("didReceive chunk: Data", source)
        self.assertIn("SecItemCopyMatching", source)
        self.assertIn("kSecUseAuthenticationUIFail", source)
        self.assertIn('kSecAttrService: "Claude Code-credentials"', source)
        self.assertNotIn("Process(", source)
        self.assertNotIn("BoundedLocalProcess.run", source)
        self.assertIn('"-init", "/dev/null", "-readonly", "-json"', relay)

    def test_fixture_contains_only_synthetic_credentials(self):
        for fixture in (FIXTURE, KIMI_FIXTURE, GROK_FIXTURE, KIMI_RENEWAL_FIXTURE):
            content = fixture.read_bytes()
            digest = hashlib.sha256(content).hexdigest()
            self.assertEqual(len(digest), 64)
            text = content.decode("utf-8")
            self.assertNotIn("sk-ant-", text)
            self.assertNotIn("sk-proj-", text)
            self.assertNotIn("/Users/", text)
            self.assertGreaterEqual(text.count("synthetic"), 10)


if __name__ == "__main__":
    unittest.main()
