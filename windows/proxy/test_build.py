import importlib.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

spec = importlib.util.spec_from_file_location("windows_proxy_build", Path(__file__).with_name("build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
resource_spec = importlib.util.spec_from_file_location("windows_proxy_resource", Path(__file__).with_name("prepare-resource.py"))
resource = importlib.util.module_from_spec(resource_spec)
resource_spec.loader.exec_module(resource)


class StagingIntegrity(unittest.TestCase):
    def test_real_staging_subprocess_uses_utf8_under_forced_cp1252_defaults(self):
        # The child disables UTF-8 mode and forces only omitted text encodings
        # to a real cp1252 TextIOWrapper, plus Windows newline translation.
        # Its control must fail on U+FF08, reproducing the native CI failure;
        # explicit UTF-8 file operations still use the normal I/O functions.
        program = textwrap.dedent(r'''
            import builtins, importlib.util, io, json, runpy, sys
            from pathlib import Path
            assert sys.flags.utf8_mode == 0
            real_open = io.open
            def ansi_open(file, mode="r", buffering=-1, encoding=None, errors=None,
                          newline=None, closefd=True, opener=None):
                if "b" not in mode:
                    if encoding is None or encoding == "locale": encoding = "cp1252"
                    if newline is None and any(flag in mode for flag in "wax+"): newline = "\r\n"
                return real_open(file, mode, buffering, encoding, errors, newline, closefd, opener)
            io.open = builtins.open = ansi_open
            script, root = Path(sys.argv[1]), Path(sys.argv[2])
            with (root / "ansi-control.txt").open("w") as control:
                assert control.encoding == "cp1252"
                try: control.write(chr(0xff08))
                except UnicodeEncodeError: pass
                else: raise AssertionError("cp1252 negative control did not reproduce")
            sys.argv = [str(script), "--build-root", str(root / "build"), "--target", "host", "stage"]
            try: runpy.run_path(str(script), run_name="__main__")
            except SystemExit as result: assert result.code == 0
            staged = root / "build" / "staged-source"
            repo = script.parent.parents[1]
            for name in ("main.go", "images.go", "quota_recovery.go", "go.mod", "go.sum"):
                assert (staged / name).read_bytes() == (repo / "Companion/LocalProxy" / name).read_bytes(), name
            assert any(any(b >= 128 for b in path.read_bytes()) for path in staged.glob("*.go"))
            receipt = json.loads((staged / "windows-source.json").read_text(encoding="utf-8"))
            assert receipt["stagedInputs"]
            spec = importlib.util.spec_from_file_location("cp1252_resource", script.with_name("prepare-resource.py"))
            resource = importlib.util.module_from_spec(spec); spec.loader.exec_module(resource)
            models, _ = resource.model_seed(resource.MODEL_SOURCE.read_bytes())
            assert models and models[0] == "gpt-6-astra"
            notice = resource.SHARED / "THIRD-PARTY-NOTICES.txt"
            assert resource.atomic_write(root / "notices-copy.txt", resource.regular_bytes(notice))
            assert (root / "notices-copy.txt").read_bytes() == notice.read_bytes()
            print("cp1252 negative control, actual staging and resource byte roundtrip passed")
        ''')
        with tempfile.TemporaryDirectory() as root:
            env = dict(os.environ, PYTHONUTF8="0", PYTHONCOERCECLOCALE="0")
            result = subprocess.run([sys.executable, "-c", program, str(Path(build.__file__).resolve()), root],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    encoding="utf-8", errors="strict", timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("actual staging", result.stdout)

    def test_all_owned_builder_path_text_io_declares_utf8(self):
        import ast
        for name in ("build.py", "prepare-resource.py", "evidence-fixture.py"):
            tree = ast.parse(Path(__file__).with_name(name).read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                    continue
                text_operation = node.func.attr in ("read_text", "write_text")
                if node.func.attr == "open":
                    mode = node.args[0].value if node.args and isinstance(node.args[0], ast.Constant) else "r"
                    text_operation = "b" not in mode
                if text_operation:
                    self.assertTrue(any(k.arg == "encoding" and isinstance(k.value, ast.Constant)
                                        and k.value.value == "utf-8" for k in node.keywords), (name, node.lineno))

    def test_original_router_and_upstream_inputs_are_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            staged = Path(root) / "source"
            build.stage(staged)
            receipt = json.loads((staged / "windows-source.json").read_text(encoding="utf-8"))
            for name in ("main.go", "images.go", "quota_recovery.go", "network_recovery.go", "egress_watchdog.go", "go.mod", "go.sum"):
                self.assertEqual((staged / name).read_bytes(), (build.SHARED / name).read_bytes(), name)
            for name, digest in receipt["sharedInputs"].items():
                self.assertEqual(hashlib.sha256((build.SHARED / name).read_bytes()).hexdigest(), digest)
            for name, digest in receipt["stagedInputs"].items():
                self.assertEqual(hashlib.sha256((staged / name).read_bytes()).hexdigest(), digest)
            self.assertIn("dialControl(ctx, b.socket)", (staged / "bridge.go").read_text(encoding="utf-8"))
            self.assertTrue((staged / "desktop.go").read_text(encoding="utf-8").startswith("//go:build !windows"))
            self.assertNotIn("syscall.O_NOFOLLOW", (staged / "cooldown.go").read_text(encoding="utf-8"))
            self.assertEqual((staged / "upstream-patches/manifest.json").read_bytes(), (build.SHARED / "upstream-patches/manifest.json").read_bytes())

    def test_platform_drift_aborts_before_a_success_receipt(self):
        original = build.PLATFORM_BOUNDARIES["bridge.go"]
        try:
            build.PLATFORM_BOUNDARIES["bridge.go"] = "0" * 64
            with tempfile.TemporaryDirectory() as root:
                staged = Path(root) / "source"
                with self.assertRaisesRegex(ValueError, "platform input changed"):
                    build.stage(staged)
                self.assertFalse((staged / "windows-source.json").exists())
        finally:
            build.PLATFORM_BOUNDARIES["bridge.go"] = original


class ModelSeedIntegrity(unittest.TestCase):
    def test_real_mac_case_order_is_complete(self):
        models, _ = resource.model_seed(resource.MODEL_SOURCE.read_bytes())
        self.assertEqual(models, ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.2"])

    def test_model_parser_ignores_nested_switch_cases_and_rejects_custom_allcases(self):
        source = b'''struct CodexExecutionPreference: Codable, Equatable {
    enum Model: String, Codable, CaseIterable {
        case first = "fixture-first"
        var displayName: String {
            switch self {
            case .first: return "not-a-model"
            case .second: return "not-a-model-either"
            }
        }
        case second = "fixture-second"
    }
}
'''
        self.assertEqual(resource.model_seed(source)[0], ["fixture-first", "fixture-second"])
        with self.assertRaisesRegex(ValueError, "custom Mac allCases"):
            resource.model_seed(source.replace(b'        var displayName', b'        static var allCases = [Model.first]\n        var displayName'))
        with self.assertRaises(ValueError):
            resource.model_seed(source.replace(b'"fixture-second"', b'"fixture-first"'))

    def test_pe_architecture_mismatch_is_rejected(self):
        import struct
        data=bytearray(512);data[:2]=b'MZ';struct.pack_into('<I',data,0x3c,128);data[128:132]=b'PE\0\0';struct.pack_into('<H',data,132,0x8664)
        resource.pe_machine(data,"windows-amd64")
        with self.assertRaisesRegex(ValueError,"architecture"):
            resource.pe_machine(data,"windows-arm64")


if __name__ == "__main__":
    unittest.main()
