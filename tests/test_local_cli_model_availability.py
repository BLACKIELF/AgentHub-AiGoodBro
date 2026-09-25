#!/usr/bin/env python3
import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOMAIN_ACCOUNT = ROOT / "Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift"
DOMAIN = ROOT / "Sources/CodexUsageWidget/Domain/LocalCLIModelAvailability.swift"
BRIDGE = ROOT / "Sources/CodexUsageWidget/Domain/LocalCLIModelReceiptBridge.swift"
STORE = ROOT / "Sources/CodexUsageWidget/Services/LocalCLIModelAvailabilityStore.swift"
VIEW = ROOT / "Sources/CodexUsageWidget/UI/LocalCLIModelAvailabilityView.swift"
PALETTE = ROOT / "Sources/CodexUsageWidget/DesignSystem/FixedVisualPalette.swift"
FIXTURE = ROOT / "tests/LocalCLIModelAvailabilityFixture.swift"
SDK = pathlib.Path("/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk")


class LocalCLIModelAvailabilityTests(unittest.TestCase):
    def test_actual_store_and_domain_with_synthetic_fixture(self):
        sources = [DOMAIN_ACCOUNT, DOMAIN, BRIDGE, STORE, FIXTURE]
        with tempfile.TemporaryDirectory(prefix="local-cli-model-availability-") as directory:
            output = pathlib.Path(directory) / "fixture"
            sdk = SDK if SDK.is_dir() else pathlib.Path(
                subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
            compiled = subprocess.run(
                [
                    "xcrun", "swiftc", "-target", f"{platform.machine()}-apple-macos13.0",
                    "-sdk", str(sdk), "-module-cache-path", str(pathlib.Path(directory) / "ModuleCache"),
                    "-o", str(output), *(str(source) for source in sources),
                ],
                cwd=ROOT, text=True, capture_output=True, timeout=180, check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            ran = subprocess.run(
                [str(output)], cwd=ROOT, text=True, capture_output=True, timeout=30, check=False)
            self.assertEqual(ran.returncode, 0, ran.stderr + ran.stdout)
            self.assertEqual(ran.stdout.strip(), "local-cli-model-availability-fixture: ok")

    def test_view_typechecks_against_domain(self):
        stub = """
        import Foundation
        enum WidgetLanguage {
            case zh
            case en
            var isChinese: Bool { self == .zh }
            func text(_ zh: String, _ en: String) -> String { zh }
            func dateTime(_ date: Date) -> String { "" }
        }
        """
        with tempfile.TemporaryDirectory(prefix="local-cli-model-availability-view-") as directory:
            stub_path = pathlib.Path(directory) / "WidgetLanguageStub.swift"
            stub_path.write_text(stub)
            sdk = SDK if SDK.is_dir() else pathlib.Path(
                subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
            compiled = subprocess.run(
                [
                    "xcrun", "swiftc", "-typecheck", "-target", f"{platform.machine()}-apple-macos13.0",
                    "-sdk", str(sdk), "-module-cache-path", str(pathlib.Path(directory) / "ModuleCache"),
                    str(DOMAIN_ACCOUNT), str(DOMAIN), str(VIEW), str(PALETTE), str(stub_path),
                ],
                cwd=ROOT, text=True, capture_output=True, timeout=180, check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

    def test_static_privacy_and_scope_contract(self):
        domain = DOMAIN.read_text()
        bridge = BRIDGE.read_text()
        store = STORE.read_text()
        view = VIEW.read_text()
        for source in (domain, bridge, store, view):
            self.assertNotIn("URLSession", source)
            self.assertNotIn("ProcessInfo.processInfo.environment", source)
            self.assertNotIn("Data(contentsOf:", source)
            self.assertNotIn("SecItem", source)
            self.assertNotIn("LocalCLIAccountStore", source)
            self.assertNotIn("LocalCLIWorkspaceView", source)
            self.assertNotIn("removeItem", source)
            self.assertNotIn("unlink(", source)
        self.assertNotIn("usedPercent", domain)
        self.assertNotIn("@example.com", domain)
        self.assertNotIn('language.text("永久"', domain)
        self.assertNotIn('language.text("未知"', domain)
        self.assertIn("未注明", domain)
        self.assertIn("example.invalid", FIXTURE.read_text())
        self.assertIn("synthetic-acct-", FIXTURE.read_text())
        self.assertIn("WidgetLanguage", view)
        self.assertIn("userConfirmed", domain)
        self.assertIn("2026-09-15 23:59", domain)
        self.assertIn("mimo-v2.5-free", domain)
        self.assertIn("DeepSeek 4 Flash", domain)
        self.assertIn("grok-4.6-build", domain)
        self.assertIn("alias_not_admitted", bridge)
        self.assertIn("randomMarker", bridge)
        self.assertIn("never deletes", store)


if __name__ == "__main__":
    unittest.main()
