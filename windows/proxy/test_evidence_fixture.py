import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


spec=importlib.util.spec_from_file_location("evidence_fixture",Path(__file__).with_name("evidence-fixture.py"))
driver=importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class EvidenceFixtureTests(unittest.TestCase):
    def test_missing_process_cache_uses_effective_go_defaults(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as temporary:
            root=Path(temporary).resolve();mod=root/"effective-mod";cache=root/"effective-build"
            mod.mkdir();cache.mkdir()
            response=subprocess.CompletedProcess([],0,json.dumps({"GOMODCACHE":str(mod),"GOCACHE":str(cache)}).encode(),b"")
            with mock.patch.dict(os.environ,{"GOMODCACHE":"","GOCACHE":"","GOTMPDIR":"","TMPDIR":"","TEMP":"","TMP":""}),mock.patch.object(driver.subprocess,"run",return_value=response) as query:
                environment=driver.fixture_environment(root,root/"input",root/"proof")
            self.assertEqual(query.call_args.args[0],["go","env","-json","GOMODCACHE","GOCACHE"])
            self.assertEqual(environment["GOMODCACHE"],str(mod));self.assertEqual(environment["GOCACHE"],str(cache))
            self.assertEqual(environment["GOPROXY"],"off");self.assertEqual(environment["GOTOOLCHAIN"],"local")
            self.assertFalse((root/"go-mod").exists());self.assertFalse((root/"go-build").exists())

    def test_explicit_task_caches_are_preserved_without_query(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as temporary:
            root=Path(temporary).resolve()
            with mock.patch.dict(os.environ,{"GOMODCACHE":str(root),"GOCACHE":str(root)}),mock.patch.object(driver.subprocess,"run") as query:
                environment=driver.fixture_environment(root,root/"input",root/"proof")
            query.assert_not_called();self.assertEqual(environment["GOMODCACHE"],str(root))

    def test_effective_relative_or_missing_cache_is_rejected(self):
        for value in ("relative",None):
            with self.subTest(value=value),tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as temporary:
                root=Path(temporary).resolve()
                response=subprocess.CompletedProcess([],0,json.dumps({"GOMODCACHE":value,"GOCACHE":str(root)}).encode(),b"")
                with mock.patch.dict(os.environ,{"GOMODCACHE":"","GOCACHE":""}),mock.patch.object(driver.subprocess,"run",return_value=response):
                    with self.assertRaises(driver.FixtureFailure) as failure:
                        driver.fixture_environment(root,root/"input",root/"proof")
                self.assertEqual(failure.exception.code,"cache_unavailable")

    def test_rejected_input_reports_only_fixed_stage_code(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as temporary:
            root=Path(temporary).resolve();source=root/"input.json"
            source.write_bytes(json.dumps({"syntheticFixture":False,"private":"not-for-diagnostics"}).encode())
            result=subprocess.run([sys.executable,str(Path(driver.__file__)),"--input",str(source),"--output",str(root/"proof"),"--build-root",str(root/"build")],capture_output=True,timeout=10)
            self.assertEqual(result.returncode,1);self.assertEqual(result.stdout,b"")
            self.assertEqual(result.stderr,b"AIGOODBRO_EVIDENCE_FIXTURE_ERROR=input_rejected\n")


if __name__=="__main__":
    unittest.main()
