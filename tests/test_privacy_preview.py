#!/usr/bin/env python3
"""Compile the pure preview and its native editor using synthetic input only."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOMAIN = ROOT / "Sources/CodexUsageWidget/Domain/PrivacyPreview.swift"
VIEW = ROOT / "Sources/CodexUsageWidget/UI/PrivacyPreviewView.swift"


class PrivacyPreviewTests(unittest.TestCase):
    def test_preview_behavior_and_native_editor(self):
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        with tempfile.TemporaryDirectory(prefix="privacy-preview-test-") as temporary:
            folder = Path(temporary)
            cache = folder / "module-cache"
            cache.mkdir()
            binary = folder / "preview-fixture"
            compiler = ["xcrun", "swiftc", "-sdk", sdk, "-target", f"{platform.machine()}-apple-macos13.0", "-module-cache-path", str(cache)]
            result = subprocess.run(compiler + [str(DOMAIN), str(ROOT / "tests/PrivacyPreviewFixture.swift"), "-o", str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10, env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "PASS privacy-preview 42 assertions")
            support = folder / "Language.swift"
            support.write_text("enum WidgetLanguage { case zh, en; func text(_ zh: String, _ en: String) -> String { self == .zh ? zh : en } }\n")
            result = subprocess.run(compiler + ["-typecheck", str(DOMAIN), str(VIEW), str(support)], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_local_only_boundary(self):
        for path in (DOMAIN, VIEW):
            source = path.read_text()
            for forbidden in ("URLSession", "UserDefaults", "FileManager", "Data(contentsOf:", "Process(", "DebugLogger", "print(", "string(forType:"):
                self.assertNotIn(forbidden, source)
        source = VIEW.read_text()
        self.assertIn("editor.allowsUndo = false", source)
        self.assertIn(".onDisappear(perform: clear)", source)
        self.assertIn('editor.writingToolsBehavior = .none', source)
        details = (ROOT / "Sources/CodexUsageWidget/UI/AccountInformationView.swift").read_text()
        self.assertNotIn("masked: false", details)


if __name__ == "__main__":
    unittest.main()
