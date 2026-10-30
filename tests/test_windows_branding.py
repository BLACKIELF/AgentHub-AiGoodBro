"""Release identity contracts: new labels must not create a second installation."""

import hashlib
import json
import pathlib
import re
import subprocess
import tempfile
import unittest
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
TAURI = ROOT / "windows/apps/codexu-tauri/src-tauri"
UPGRADE_CODE = "6cd62ac1-9ad0-5e9e-a4e1-c78c6a73fd03"


class WindowsBranding(unittest.TestCase):
    def test_display_brand_keeps_upgrade_and_storage_identity(self):
        config = json.loads((TAURI / "tauri.conf.json").read_text(encoding="utf-8"))
        self.assertEqual(config["productName"], "AiGoodBro")
        self.assertEqual(config["app"]["windows"][0]["title"], "AiGoodBro")
        self.assertEqual(config["identifier"], "com.blackielf.codex-account-manager-next.windows")
        wix = config["bundle"]["windows"]["wix"]
        self.assertEqual(wix["upgradeCode"], UPGRADE_CODE)
        self.assertEqual(str(uuid.uuid5(uuid.NAMESPACE_DNS, "Codex Account Manager Next.exe.app.x64")), UPGRADE_CODE)
        self.assertNotEqual(str(uuid.uuid5(uuid.NAMESPACE_DNS, "AiGoodBro.exe.app.x64")), UPGRADE_CODE)
        self.assertEqual(wix["template"], "installer/wix-main.wxs")
        self.assertEqual(config["bundle"]["windows"]["nsis"]["template"], "installer/nsis-installer.nsi")
        self.assertEqual(config["bundle"]["windows"]["nsis"]["installMode"], "currentUser")
        self.assertIn('.join("CodexAccountManagerNext")', (TAURI / "src/app_state.rs").read_text(encoding="utf-8"))
        self.assertIn('<title>AiGoodBro</title>', (TAURI.parent / "web/index.html").read_text(encoding="utf-8"))
        settings = (TAURI / "src/commands/settings.rs").read_text(encoding="utf-8")
        self.assertIn('"设置 — AiGoodBro"', settings)
        self.assertIn('"Settings — AiGoodBro"', settings)

    def test_installer_changes_reconstruct_exact_pinned_upstream(self):
        directory = TAURI / "installer"
        receipt = json.loads((directory / "SOURCE.json").read_text(encoding="utf-8"))
        expected = {
            "nsis-installer.nsi": "fb8e9bb406dc6862a939f71258c14a08c4aa5361",
            "wix-main.wxs": "a11b2ec4381cb05fb0d340b17ef5197ad951529c",
        }
        self.assertEqual(receipt["ref"], "tauri-cli-v2.6.2")
        for name, blob in expected.items():
            with self.subTest(name=name):
                local = (directory / name).read_bytes()
                record = receipt["files"][name]
                self.assertEqual(hashlib.sha256(local).hexdigest(), record["local_sha256"])
                source = local.decode()
                for change in reversed(record["replacements"]):
                    self.assertEqual(source.count(change["after"]), change["count"])
                    source = source.replace(change["after"], change["before"])
                raw = source.encode()
                self.assertEqual(hashlib.sha256(raw).hexdigest(), record["upstream_sha256"])
                self.assertEqual(hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(), blob)

    def test_new_and_old_update_asset_names_remain_supported(self):
        source = (ROOT / "windows/crates/codexu-core/src/updates.rs").read_text(encoding="utf-8")
        for prefix in ("AiGoodBro", "CodexAccountManagerNext"):
            for suffix in (".msi", "-setup.exe"):
                self.assertIn(prefix + '-{version}-windows-x86_64' + suffix, source)

    def test_wix_registry_paths_have_no_empty_segments(self):
        source = (TAURI / "installer/wix-main.wxs").read_text(encoding="utf-8")
        keys = re.findall(r'<Registry(?:Search|Key|Value)\b[^>]*\bKey="([^"]+)"', source)
        # Dynamic Handlebars paths retain the upstream escaping contract.
        keys = [key for key in keys if "{{" not in key]
        self.assertGreaterEqual(len(keys), 10)
        for key in keys:
            with self.subTest(key=key):
                self.assertNotIn("", key.split("\\"), "WiX registry keys use literal single separators")
        legacy = "Software\\Codex Account Manager Next contributors\\Codex Account Manager Next"
        self.assertEqual(keys.count(legacy), 6)

    @unittest.skipUnless(__import__("os").name != "nt", "Bash checksum contract runs on Unix; native package contracts run on Windows")
    def test_cross_platform_assets_require_new_names_and_real_checksums(self):
        with tempfile.TemporaryDirectory(prefix="aigoodbro-brand-") as temporary:
            folder = pathlib.Path(temporary)
            names = ["AiGoodBro-9.6.9-mac-arm64.dmg", "AiGoodBro-9.6.9-mac-x86_64.dmg",
                     "AiGoodBro-9.6.9-windows-x86_64.msi", "AiGoodBro-9.6.9-windows-x86_64-setup.exe"]
            for name in names:
                data = ("synthetic checksum fixture: " + name).encode()
                (folder / name).write_bytes(data)
                (folder / (name + ".sha256")).write_text(hashlib.sha256(data).hexdigest() + "  " + name + "\n")
            command = ["bash", str(ROOT / "scripts/check-cross-platform-release-assets.sh"), "9.6.9", str(folder)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (folder / names[2]).rename(folder / names[2].replace("AiGoodBro", "CodexAccountManagerNext"))
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (folder / names[2].replace("AiGoodBro", "CodexAccountManagerNext")).rename(folder / names[2])
            (folder / names[2]).write_bytes(b"tampered")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
