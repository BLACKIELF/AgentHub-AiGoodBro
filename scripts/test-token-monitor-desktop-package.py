#!/usr/bin/env python3
"""Focused ASAR format and integrity checks for the desktop helper packager."""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("prepare-token-monitor-desktop.py")
SPEC = importlib.util.spec_from_file_location("desktop_package", SCRIPT)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class AsarPackageTests(unittest.TestCase):
    def test_round_trip_and_integrity_detection(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "app.asar"
            unpacked = path.with_name("app.asar.unpacked") / "node_modules/native/addon.node"
            unpacked.parent.mkdir(parents=True)
            unpacked.write_bytes(b"native-binary")
            unpacked.with_name("empty.js").write_bytes(b"")
            members = {
                "package.json": (b'{"main":"aigoodbro/bootstrap.cjs"}', False, False),
                "aigoodbro/bootstrap.cjs": (b"require('../src/electron/main.js')", False, False),
                "node_modules/native/addon.node": (b"native-binary", True, True),
                "node_modules/native/empty.js": (b"", True, False),
            }
            header, count = PACKAGE.build_asar(path, members)
            result = PACKAGE.verify_asar(path, header)
            self.assertEqual((count, result["members"], result["unpacked"]), (4, 4, 2))
            tree, start, _ = PACKAGE.asar_header(path)
            self.assertEqual(PACKAGE.asar_content(path, tree, start, "package.json"), members["package.json"][0])
            self.assertEqual(PACKAGE.header_entry(tree, "node_modules/native/empty.js")["integrity"]["blocks"], [PACKAGE.sha256(b"")])
            data = bytearray(path.read_bytes())
            data[-1] ^= 1
            path.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                PACKAGE.verify_asar(path, header)

    def test_official_runtime_pin_and_package_entry(self):
        runtime = Path("/Applications/Token Monitor.app/Contents/Resources/app.asar")
        if not runtime.is_file():
            self.skipTest("Official local runtime is not installed")
        manifest = json.loads(PACKAGE.MANIFEST.read_text())
        tree, start, header = PACKAGE.asar_header(runtime)
        self.assertEqual(header, manifest["runtime"]["officialAsarHeaderSHA256"])
        self.assertEqual(PACKAGE.official_unpacked_tree_digest(runtime, tree), manifest["runtime"]["officialUnpackedTreeSHA256"])
        self.assertEqual(sum(path.startswith("node_modules/") for path, _ in PACKAGE.entries(tree)), manifest["runtime"]["officialNodeModulesMembers"])
        self.assertEqual(json.loads(PACKAGE.asar_content(runtime, tree, start, "package.json"))["version"], "0.62.0")

    def test_staging_keeps_original_assets_and_sets_companion_entry(self):
        manifest = json.loads(PACKAGE.MANIFEST.read_text())
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary) / "stage"
            result = PACKAGE.prepare_stage(stage, manifest)
            self.assertIn("src/electron/main.js", result["transformChanged"])
            self.assertEqual(json.loads((stage / "package.json").read_text())["main"], "aigoodbro/bootstrap.cjs")
            self.assertEqual((stage / "assets/icon.png").read_bytes(), (PACKAGE.ROOT / "Resources/AiGoodBro-icon.png").read_bytes())
            icon = "assets/icons/codex.svg"
            self.assertEqual((stage / icon).read_bytes(), (PACKAGE.VENDOR / "upstream" / icon).read_bytes())
            app_js = (stage / "src/electron/renderer/app.js").read_text()
            self.assertNotIn("../../../assets/icons/tray-token-monitor.png", app_js)
            self.assertIn("if (id === 'app') return '../../../assets/icon.png';", app_js)
            self.assertIn("sources.app = '../../../assets/icon.png';", app_js)
            self.assertIn("https://github.com/BLACKIELF/AgentHub-AiGoodBro", app_js)
            self.assertIn("https://aigoodbro.com/", app_js)
            self.assertIn("/blob/main/docs/usage-guide.md", app_js)
            self.assertNotIn("Javis603/token-monitor", app_js)
            self.assertNotIn("javis-ai.com/token-monitor", app_js)
            self.assertIn("https://status.openai.com", app_js)
            self.assertIn("https://github.com/junhoyeo/tokscale", app_js)
            index_html = (stage / "src/electron/renderer/index.html").read_text()
            self.assertIn('data-aigoodbro-host-action="checkForUpdates"', index_html)
            main_js = (stage / "src/electron/main.js").read_text()
            self.assertIn("['openWorkbench', 'openAccounts', 'openSettings', 'checkForUpdates'].includes(action)", main_js)
            self.assertNotIn("Javis603/token-monitor", main_js)
            self.assertNotIn("javis-ai.com", main_js)
            self.assertIn("parsed.hostname === 'claude.ai'", main_js)
            discord_rpc = (stage / "src/electron/discordRpc.js").read_text()
            self.assertIn("https://github.com/BLACKIELF/AgentHub-AiGoodBro", discord_rpc)
            self.assertNotIn("Javis603/token-monitor", discord_rpc)

    def test_packaged_visual_and_business_source_parity(self):
        helper = Path(os.environ.get("AIGOODBRO_TOKEN_CORE_APP", PACKAGE.DEFAULT_OUTPUT))
        if not helper.is_dir():
            self.skipTest("Packaged helper candidate is not present")
        packaged = helper / "Contents/Resources/app.asar"
        official = Path("/Applications/Token Monitor.app/Contents/Resources/app.asar")
        if not official.is_file():
            self.skipTest("Official local runtime is not installed")
        tree, start, _ = PACKAGE.asar_header(packaged)
        original, original_start, _ = PACKAGE.asar_header(official)
        vendor = PACKAGE.VENDOR / "upstream"
        source_paths = [file.relative_to(vendor).as_posix() for folder in ("src", "assets") for file in (vendor / folder).rglob("*") if file.is_file()]
        source_paths += ["package.json", "LICENSE"]
        changed_from_vendor = {
            relative for relative in source_paths
            if PACKAGE.asar_content(packaged, tree, start, relative) != (vendor / relative).read_bytes()
        }
        transformed = {
            "src/electron/main.js", "src/electron/discordRpc.js", "src/electron/preload.js", "src/shared/appUpdater.js", "src/electron/renderer/index.html",
            "src/electron/renderer/i18n.js", "src/electron/renderer/edgeDock/index.html",
            "src/electron/renderer/styles.css", "src/electron/renderer/app.js",
            "src/electron/renderer/trayComposer.js", "src/electron/tray.js",
            "src/electron/edgeDock/controller.js",
        }
        self.assertEqual(len(source_paths), 364)
        self.assertEqual(changed_from_vendor, transformed | {"assets/icon.png", "package.json"})
        official_paths = [relative for relative, _ in PACKAGE.entries(original) if relative.startswith(("src/", "assets/"))]
        changed_from_official = {
            relative for relative in official_paths
            if PACKAGE.asar_content(packaged, tree, start, relative) != PACKAGE.asar_content(official, original, original_start, relative)
        }
        self.assertEqual(len(official_paths), 358)
        self.assertEqual(changed_from_official, transformed | {
            "assets/icon.png",
            "src/electron/providers/antigravity/oauthLogin.js",
            "src/shared/providers/antigravity/oauth.js",
        })
        edge_files = [relative for relative in official_paths if relative.startswith("src/electron/renderer/edgeDock/")]
        self.assertEqual(len(edge_files), 8)
        self.assertEqual(changed_from_official.intersection(edge_files), {"src/electron/renderer/edgeDock/index.html"})
        self.assertEqual(
            (helper / "Contents/Resources/icon.icns").read_bytes(),
            (PACKAGE.ROOT / "Resources/AiGoodBro.icns").read_bytes(),
        )
        self.assertEqual(
            PACKAGE.asar_content(packaged, tree, start, "assets/icon.png"),
            (PACKAGE.ROOT / "Resources/AiGoodBro-icon.png").read_bytes(),
        )
        app_js = PACKAGE.asar_content(packaged, tree, start, "src/electron/renderer/app.js").decode()
        self.assertNotIn("../../../assets/icons/tray-token-monitor.png", app_js)
        self.assertIn("sources.app = '../../../assets/icon.png';", app_js)
        self.assertIn("https://github.com/BLACKIELF/AgentHub-AiGoodBro", app_js)
        self.assertIn("https://aigoodbro.com/", app_js)
        self.assertNotIn("Javis603/token-monitor", app_js)
        self.assertNotIn("javis-ai.com/token-monitor", app_js)
        self.assertIn("https://status.openai.com", app_js)
        main_js = PACKAGE.asar_content(packaged, tree, start, "src/electron/main.js").decode()
        preload_js = PACKAGE.asar_content(packaged, tree, start, "src/electron/preload.js").decode()
        index_html = PACKAGE.asar_content(packaged, tree, start, "src/electron/renderer/index.html").decode()
        discord_rpc = PACKAGE.asar_content(packaged, tree, start, "src/electron/discordRpc.js").decode()
        self.assertIn("openAiGoodBroHost: (action) => ipcRenderer.invoke('aigoodbro:openHost', action)", preload_js)
        self.assertIn("event.sender !== mainWindow?.webContents", main_js)
        self.assertIn("['openWorkbench', 'openAccounts', 'openSettings', 'checkForUpdates'].includes(action)", main_js)
        self.assertIn("parsed.hostname === 'aigoodbro.com'", main_js)
        self.assertNotIn("Javis603/token-monitor", main_js)
        self.assertNotIn("javis-ai.com", main_js)
        self.assertIn("parsed.hostname === 'claude.ai'", main_js)
        self.assertIn("https://github.com/BLACKIELF/AgentHub-AiGoodBro", discord_rpc)
        self.assertNotIn("Javis603/token-monitor", discord_rpc)
        self.assertIn("window.tokenMonitor.openAiGoodBroHost(button.dataset.aigoodbroHostAction)", app_js)
        for action in ("openWorkbench", "openAccounts", "openSettings", "checkForUpdates"):
            self.assertIn(f'data-aigoodbro-host-action="{action}"', index_html)
        for view in ("home", "tool", "status", "device", "model", "project", "session", "limits", "trends"):
            self.assertIn(f"{{ id: '{view}', labelKey: 'views.{view}' }}", app_js)
            self.assertIn(f"'{view}'", main_js.split("const TRAY_OPEN_VIEW_IDS =", 1)[1].split(";", 1)[0])
        self.assertIn("return !IS_AIGOODBRO_EMBEDDED && macWidgetRuntimeSupport({ platform, osRelease }).supported;", main_js)
        self.assertIn("const widgetRuntimeSupported = !IS_AIGOODBRO_EMBEDDED && widgetRuntime.supported;", main_js)
        self.assertEqual(PACKAGE.archived_widget_digest(helper / "Contents/Resources/DisabledOriginalWidget.zip"), json.loads(PACKAGE.MANIFEST.read_text())["widget"]["originalTreeSHA256"])
        self.assertFalse((helper / "Contents/PlugIns/TokenMonitorWidget.appex").exists())
        self.assertFalse((helper / "Contents/Resources/token-monitor-widget.json").exists())
        self.assertEqual(PACKAGE.digest_file(helper / "Contents/Resources/DisabledOriginalWidget-config.json"), json.loads(PACKAGE.MANIFEST.read_text())["widget"]["originalConfigSHA256"])


if __name__ == "__main__":
    unittest.main()
