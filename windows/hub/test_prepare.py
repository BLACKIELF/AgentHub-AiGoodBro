import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("hub_prepare", Path(__file__).with_name("prepare.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class HubResourcesTests(unittest.TestCase):
    def source(self, root):
        files = {"main.go": b"package main\n", "go.mod": b"module fixture\n", "go.sum": b"",
                 "LICENSE": b"MIT fixture", "LICENSE.x-sys": b"BSD fixture", "web/index.html": b"<html></html>"}
        for name, data in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (root / "SOURCE.json").write_text(json.dumps({"sourceFiles": [
            {"path": name, "sha256": prepare.sha(data)} for name, data in files.items()
        ]}))

    def test_source_mutation_and_unmanifested_code_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.source(root)
            self.assertIn("main.go", prepare.source_files(root))
            (root / "extra_windows.go").write_text("package main\n")
            with self.assertRaisesRegex(ValueError, "inventory_incomplete"):
                prepare.source_files(root)
            (root / "extra_windows.go").unlink()
            (root / "main.go").write_text("package changed\n")
            with self.assertRaisesRegex(ValueError, "source_changed"):
                prepare.source_files(root)

    def test_source_path_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.source(root)
            source = json.loads((root / "SOURCE.json").read_text())
            source["sourceFiles"][0]["path"] = "../main.go"
            (root / "SOURCE.json").write_text(json.dumps(source))
            with self.assertRaisesRegex(ValueError, "path_invalid"):
                prepare.source_files(root)

    def test_no_tests_or_skipped_windows_contract_is_not_acceptance(self):
        with self.assertRaisesRegex(ValueError, "not_executed"):
            prepare.native_result(b'{"Action":"pass","Package":"fixture"}\n')
        lines = [{"Action": action, "Test": name, "Package": "agent-remote-control"}
                 for name in prepare.NATIVE_TESTS for action in ["run", "pass"]]
        lines.append({"Action": "pass", "Package": "agent-remote-control"})
        data = lambda: ("\n".join(json.dumps(x) for x in lines) + "\n").encode()
        self.assertEqual(11, len(prepare.native_result(data())))
        lines[0]["Action"] = "skip"
        with self.assertRaisesRegex(ValueError, "not_executed"):
            prepare.native_result(data())
        lines[0]["Action"] = "fail"
        with self.assertRaisesRegex(ValueError, "test_failed"):
            prepare.native_result(data())

    def test_unrelated_or_fabricated_pass_lines_are_rejected(self):
        for package in ["unrelated", "agent-remote-control"]:
            lines = [{"Action": "pass", "Test": name, "Package": package} for name in prepare.NATIVE_TESTS]
            with self.assertRaisesRegex(ValueError, "not_executed"):
                prepare.native_result(("\n".join(json.dumps(x) for x in lines) + "\n").encode())

    def test_each_added_native_contract_must_actually_execute(self):
        for omitted in ("TestNativeWindowsDesktopBindingHoldsInputs",
                        "TestNativeWindowsDesktopSourceAllowsReadOnlyACL",
                        "TestNativeWindowsUncertainResolutionRequiresEmptyOwnedJob"):
            with self.subTest(omitted=omitted):
                self.assertIn(omitted, prepare.NATIVE_TESTS)
                lines = [{"Action": action, "Test": name, "Package": "agent-remote-control"}
                         for name in sorted(prepare.NATIVE_TESTS - {omitted})
                         for action in ("run", "pass")]
                lines.append({"Action": "pass", "Package": "agent-remote-control"})
                with self.assertRaisesRegex(ValueError, "not_executed"):
                    prepare.native_result(("\n".join(json.dumps(x) for x in lines) + "\n").encode())

    def test_staging_mutation_and_extra_go_input_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.source(root)
            inputs = prepare.source_files(root)
            prepare.verify_stage(root, inputs)
            (root / "injected.go").write_text("package main\n")
            with self.assertRaisesRegex(ValueError, "stage_changed"):
                prepare.verify_stage(root, inputs)
            (root / "injected.go").unlink()
            (root / "main.go").write_text("package changed\n")
            with self.assertRaisesRegex(ValueError, "stage_changed"):
                prepare.verify_stage(root, inputs)

    def test_wrong_architecture_does_not_become_an_x64_resource(self):
        binary = bytearray(512)
        binary[:2] = b"MZ"
        struct.pack_into("<I", binary, 0x3c, 128)
        binary[128:132] = b"PE\0\0"
        struct.pack_into("<H", binary, 132, 0xaa64)
        with self.assertRaisesRegex(ValueError, "architecture"):
            prepare.validate_pe(binary)
        struct.pack_into("<H", binary, 132, 0x8664)
        prepare.validate_pe(binary)


if __name__ == "__main__":
    unittest.main()
