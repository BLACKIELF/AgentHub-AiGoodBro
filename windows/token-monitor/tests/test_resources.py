import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

SCRIPTS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(SCRIPTS))
import prepare
import scanner_source
import build_scanner

class ResourceBoundaries(unittest.TestCase):
    def test_reused_scanner_requires_its_exact_tested_bytes_and_receipts(self):
        # Stop at the first fixed-asset fetch: this exercises the real reuse
        # validation without network access or claiming a synthetic PE runs.
        with tempfile.TemporaryDirectory(prefix='tm-reused-scanner-') as temporary:
            root = Path(temporary)
            scanner = root / 'scanner'
            scanner.mkdir()
            binary = bytearray(128)
            binary[:2] = b'MZ'
            struct.pack_into('<I', binary, 60, 64)
            binary[64:68] = b'PE\0\0'
            struct.pack_into('<H', binary, 68, 0x8664)
            binary = bytes(binary)
            (scanner / 'tokscale.exe').write_bytes(binary)
            regression = {'binarySHA256': prepare.digest(binary), 'syntheticOnly': True,
                          'realAccountsRead': False, 'realHistoryScanned': False,
                          'cases': [{'sourceUnchanged': True}] * 15}
            regression_dir = scanner / 'synthetic-regression'
            regression_dir.mkdir()
            regression_bytes = prepare.canonical(regression)
            (regression_dir / 'receipt.json').write_bytes(regression_bytes)
            receipt = {'schemaVersion': 1, 'baseCommit': prepare.BASE,
                       'patchSHA256': prepare.PATCH, 'sourceInventorySHA256': prepare.INVENTORY,
                       'sourceArchiveSHA256': '5f7fcc2872b40d61319ef88a847c9ef4bb0ef240cfd16139a4fa65de03f47503',
                       'target': 'x86_64-pc-windows-msvc', 'binarySHA256': prepare.digest(binary),
                       'syntheticRegressionPassed': True, 'syntheticCases': 15,
                       'unitTests': [{'passed': 1}] * 4,
                       'syntheticRegressionReceiptSHA256': prepare.digest(regression_bytes)}
            receipt_path = scanner / 'SCANNER-RECEIPT.json'
            receipt_path.write_bytes(prepare.canonical(receipt))
            args = SimpleNamespace(output=root / 'resources', cache=root / 'cache',
                                   scanner=scanner / 'tokscale.exe', scanner_receipt=receipt_path,
                                   arch='x64', download=False)
            with mock.patch.object(prepare, 'fetch', side_effect=RuntimeError('asset_boundary')) as fetch:
                with self.assertRaisesRegex(RuntimeError, 'asset_boundary'):
                    prepare.stage(args)
                self.assertEqual(fetch.call_count, 1)
            self.assertEqual(args.scanner.read_bytes(), binary)
            self.assertFalse(args.output.exists())
            for broken in ('bytes', 'receipt', 'regression', 'missing'):
                args.scanner.write_bytes(binary)
                receipt_path.write_bytes(prepare.canonical(receipt))
                (regression_dir / 'receipt.json').write_bytes(regression_bytes)
                if broken == 'bytes':
                    args.scanner.write_bytes(binary + b'tampered')
                elif broken == 'receipt':
                    receipt_path.write_bytes(prepare.canonical({**receipt, 'binarySHA256': '0' * 64}))
                elif broken == 'regression':
                    (regression_dir / 'receipt.json').write_bytes(b'{}')
                else:
                    receipt_path.unlink()
                with mock.patch.object(prepare, 'fetch') as fetch:
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        prepare.stage(args)
                    fetch.assert_not_called()
                self.assertFalse(args.output.exists())

    def test_toolchain_homes_are_resolved_before_fixture_userprofile(self):
        with tempfile.TemporaryDirectory(prefix='tm-tool-homes-')as temporary:
            home=Path(temporary);(home/'.cargo').mkdir();(home/'.rustup').mkdir()
            defaults=build_scanner.tool_homes({},home)
            self.assertEqual(defaults['CARGO_HOME'],str((home/'.cargo').resolve()))
            custom=home/'public-tool-cache';custom.mkdir()
            explicit=build_scanner.tool_homes({'CARGO_HOME':str(custom),'RUSTUP_HOME':str(home/'.rustup')},home)
            self.assertEqual(explicit['CARGO_HOME'],str(custom.resolve()))
    def test_paths_and_architectures_are_not_guessed(self):
        for name in ('../escape','C:/escape','/escape','a\\b','a//b','a/./b'):
            with self.assertRaises(ValueError):prepare.relative(name)
        blob=bytearray(72);blob[:2]=b'MZ';struct.pack_into('<I',blob,60,64);blob[64:68]=b'PE\0\0';struct.pack_into('<H',blob,68,0x8664)
        prepare.pe(blob,'x64')
        with self.assertRaises(ValueError):prepare.pe(blob,'arm64')
    def test_locked_closure_includes_actual_target_modules_and_no_electron(self):
        lock=json.loads((prepare.ENGINE/'upstream/package-lock.json').read_bytes());closure=prepare.closure(lock,'x64')
        self.assertIn('node_modules/@koromix/koffi-win32-x64',closure)
        self.assertIn('node_modules/@tokscale/cli-win32-x64-msvc',closure)
        self.assertNotIn('node_modules/electron',closure)
        self.assertEqual(closure['node_modules/koffi']['version'],'3.1.5')
    def test_archive_links_and_duplicate_case_names_are_rejected(self):
        for entries in [ [('package/link',tarfile.SYMTYPE),], [('package/A',tarfile.REGTYPE),('package/a',tarfile.REGTYPE)] ]:
            blob=io.BytesIO()
            with tarfile.open(fileobj=blob,mode='w:gz')as archive:
                for name,kind in entries:
                    info=tarfile.TarInfo(name);info.type=kind;info.size=1 if kind==tarfile.REGTYPE else 0;info.linkname='../../outside'
                    archive.addfile(info,io.BytesIO(b'x')if kind==tarfile.REGTYPE else None)
            with tempfile.TemporaryDirectory(prefix='tm-package-negative-')as temporary:
                with self.assertRaises(ValueError):prepare.extract_package(blob.getvalue(),Path(temporary)/'package')
    def test_patch_context_is_exact_and_not_fuzzy(self):
        patch=b'--- a/source.rs\n+++ b/source.rs\n@@ -1 +1 @@\n-old\n+new\n'
        self.assertEqual(scanner_source.apply_patch({'source.rs':b'old\n'},patch)['source.rs'],b'new\n')
        with self.assertRaises(ValueError):scanner_source.apply_patch({'source.rs':b'changed\n'},patch)
    def test_bad_cached_asset_is_not_reused(self):
        with tempfile.TemporaryDirectory(prefix='tm-cache-negative-')as temporary:
            cache=Path(temporary);digest='0'*64;(cache/('sha256-'+digest)).write_bytes(b'wrong')
            with self.assertRaises(ValueError):prepare.fetch('https://nodejs.org/dist/v22.23.2/SHASUMS256.txt',cache,digest,'sha256',False)
    @unittest.skipUnless(os.environ.get('TOKEN_MONITOR_TEST_ARCHIVE'),'explicit fixed public archive required')
    def test_all_frozen_scanner_files_are_reconstructed(self):
        with tempfile.TemporaryDirectory(prefix='tm-source-positive-')as temporary:
            output=Path(temporary)/'source';receipt=scanner_source.reconstruct(Path(os.environ['TOKEN_MONITOR_TEST_ARCHIVE']),output)
            self.assertEqual(receipt['sourceFiles'],797)
            inventory=json.loads((scanner_source.BACKPORT/'source-inventory.json').read_bytes())
            self.assertTrue(all(scanner_source.sha((output/name).read_bytes())==digest for name,digest in inventory.items()))
if __name__=='__main__':unittest.main()
