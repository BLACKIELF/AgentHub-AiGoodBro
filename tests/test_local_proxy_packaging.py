"""Offline integrity checks for the stock SDK and its exact upstream JSON dependency."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Companion/LocalProxy"
spec = importlib.util.spec_from_file_location("local_proxy_pins", SOURCE / "go.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


class LocalProxyIntegrityTests(unittest.TestCase):
    def test_stock_sdk_contains_metadata_fix_without_a_duplicate_patch(self):
        manifest = support.load_manifest()
        self.assertEqual(manifest["upstreamVersion"], "v8.0.58")
        self.assertEqual(manifest["patches"], [])
        self.assertEqual(manifest["includedUpstreamFixes"][0]["commit"],
                         "9e79552fb79461b3ee475c0b30ef33408392db5a")
        self.assertFalse((SOURCE / "upstream-patches/codex-response-metadata-1026v1.patch").exists())

    def test_rewriting_manifest_and_listed_hash_cannot_authorize_another_dependency(self):
        with tempfile.TemporaryDirectory(prefix="local-proxy-integrity-") as temporary:
            source = Path(temporary)
            shutil.copytree(SOURCE / "upstream-patches", source / "upstream-patches")
            path = source / support.MANIFEST
            data = json.loads(path.read_text())
            data["dependencyReplacements"][0]["replacementVersion"] = "v99.0.0"
            data["dependencyReplacements"][0]["moduleSum"] = "h1:changed"
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                support.load_manifest(source)

    def test_only_the_exact_versioned_upstream_replacement_is_allowed(self):
        pin = support.load_manifest()["dependencyReplacements"][0]
        valid = {"Path": pin["module"], "Version": pin["version"], "Replace": {
            "Path": pin["replacementModule"], "Version": pin["replacementVersion"],
            "Sum": pin["moduleSum"], "GoModSum": pin["moduleGoModSum"], "Dir": "/synthetic-module"}}
        self.assertEqual(support.check_dependency_replacement(valid, pin), Path("/synthetic-module"))
        for field, value in (("Path", "example.invalid/other"), ("Version", ""),
                             ("Sum", "h1:changed"), ("GoModSum", "h1:changed"),
                             ("Dir", ""), ("Replace", {"Dir": "/another-source"})):
            with self.subTest(field=field):
                changed = dict(valid, Replace=dict(valid["Replace"], **{field: value}))
                with self.assertRaises(ValueError):
                    support.check_dependency_replacement(changed, pin)

    def test_dependency_tree_tampering_cannot_hide_behind_cached_metadata(self):
        with tempfile.TemporaryDirectory(prefix="local-proxy-tree-") as temporary:
            directory = Path(temporary)
            source = directory / "fixture.go"
            source.write_bytes(b"package fixture\n")
            item = hashlib.sha256(source.read_bytes()).hexdigest() + "  example.invalid/fixture@v1.0.0/fixture.go\n"
            expected = "h1:" + base64.b64encode(hashlib.sha256(item.encode()).digest()).decode()
            support.verify_module_tree(directory, expected, "example.invalid/fixture", "v1.0.0")
            source.write_bytes(b"package different\n")
            with self.assertRaises(ValueError):
                support.verify_module_tree(directory, expected, "example.invalid/fixture", "v1.0.0")

    def test_source_override_flags_remain_blocked(self):
        for flag in ("-overlay=other", "--modfile=other", "-C=other", "-overlay", "-modfile"):
            with self.subTest(flag=flag):
                self.assertTrue(support.has_source_override([flag]))
        self.assertFalse(support.has_source_override(["-race", "-mod=readonly", "./..."]))


if __name__ == "__main__":
    unittest.main()
