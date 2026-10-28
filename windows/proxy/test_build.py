import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("windows_proxy_build", Path(__file__).with_name("build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
resource_spec = importlib.util.spec_from_file_location("windows_proxy_resource", Path(__file__).with_name("prepare-resource.py"))
resource = importlib.util.module_from_spec(resource_spec)
resource_spec.loader.exec_module(resource)


class StagingIntegrity(unittest.TestCase):
    def test_original_router_and_upstream_inputs_are_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            staged = Path(root) / "source"
            build.stage(staged)
            receipt = json.loads((staged / "windows-source.json").read_text())
            for name in ("main.go", "images.go", "quota_recovery.go", "network_recovery.go", "egress_watchdog.go", "go.mod", "go.sum"):
                self.assertEqual((staged / name).read_bytes(), (build.SHARED / name).read_bytes(), name)
            for name, digest in receipt["sharedInputs"].items():
                self.assertEqual(hashlib.sha256((build.SHARED / name).read_bytes()).hexdigest(), digest)
            for name, digest in receipt["stagedInputs"].items():
                self.assertEqual(hashlib.sha256((staged / name).read_bytes()).hexdigest(), digest)
            self.assertIn("dialControl(ctx, b.socket)", (staged / "bridge.go").read_text())
            self.assertTrue((staged / "desktop.go").read_text().startswith("//go:build !windows"))
            self.assertNotIn("syscall.O_NOFOLLOW", (staged / "cooldown.go").read_text())
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
