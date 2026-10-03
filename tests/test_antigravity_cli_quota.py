from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AntigravityQuotaTests(unittest.TestCase):
    def test_real_parser_and_read_only_routing_with_synthetic_data(self):
        sources = [
            ROOT / "Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift",
            ROOT / "Sources/CodexUsageWidget/Services/AntigravityCLIQuotaReader.swift",
            ROOT / "tests/AntigravityCLIQuotaFixture.swift",
        ]
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        with tempfile.TemporaryDirectory(prefix="antigravity-quota-fixture-") as temporary:
            binary = Path(temporary) / "fixture"
            build = subprocess.run([
                "xcrun", "swiftc", "-sdk", sdk,
                "-target", f"{platform.machine()}-apple-macos13.0",
                "-module-cache-path", str(Path(temporary) / "cache"),
                *map(str, sources), "-o", str(binary),
            ], cwd=ROOT, text=True, capture_output=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary)], cwd=ROOT, text=True, capture_output=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual(run.stdout.strip(), "antigravity-cli-quota-fixture: ok")


if __name__ == "__main__":
    unittest.main()
