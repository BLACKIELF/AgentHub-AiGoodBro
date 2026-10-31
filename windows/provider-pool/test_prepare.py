import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('provider_prepare',Path(__file__).with_name('prepare.py'))
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class ProviderResources(unittest.TestCase):
    def events(self, required, alter=None):
        rows=[]
        for name in sorted(required):
            rows.extend([{'Package':p.PACKAGE,'Test':name,'Action':'run'}, {'Package':p.PACKAGE,'Test':name,'Action':'pass'}])
        rows.append({'Package':p.PACKAGE,'Action':'pass'})
        if alter:rows=alter(rows)
        return ('\n'.join(json.dumps(row) for row in rows)+'\n').encode()
    def test_real_reviewed_source_and_patch_contract_is_complete(self):
        files,_,manifest,tests=p.source_inputs()
        self.assertGreaterEqual(len(tests),30)
        self.assertEqual(manifest['upstreamVersion'],'v8.0.38')
        self.assertIn('TestRefreshRequiresDurableAckAndSerializes',tests)
        self.assertIn('TestRemovedAccountCannotPersistLateRefresh',tests)
        self.assertIn('TestDeviceFlowCancellationStopsPolling',tests)
        self.assertIn('upstream-patches/manifest.json',files)
    def test_native_pass_requires_every_actual_test_and_package(self):
        tests={'TestOne','TestTwo'}
        self.assertEqual(p.native_result(self.events(tests),tests),sorted(tests))
        for alter in (lambda rows:rows[:-1],lambda rows:rows[:-3]+rows[-1:],lambda rows:[r for r in rows if r['Action']!='run'],lambda rows:rows+[rows[1]],lambda rows:rows+[{'Action':'fail','Package':'other'}]):
            with self.assertRaises(ValueError):p.native_result(self.events(tests,alter),tests)
    def test_skip_cannot_satisfy_required_native_gate(self):
        tests={'TestOne'}
        with self.assertRaises(ValueError):p.native_result(self.events(tests,lambda rows:[{**r,'Action':'skip'}if r.get('Test')else r for r in rows]),tests)
    def test_foreign_package_does_not_count(self):
        tests={'TestOne'}
        with self.assertRaises(ValueError):p.native_result(self.events(tests,lambda rows:[{**r,'Package':'other'}for r in rows]),tests)
    def receipt(self):
        inputs={'upstream-patches/manifest.json':'a'*64,'go.mod':'b'*64};stage={'adapter/main.go':'c'*64};tests={'TestOne'};log=self.events(tests)
        receipt={'schemaVersion':1,'target':'windows-amd64','sourceFiles':inputs,'stagedSourceFiles':stage,'upstreamPatchManifestSHA256':'a'*64,'syntheticOnly':True,'realAccountsRead':False,'nativeTests':sorted(tests),'nativeLogSHA256':p.sha(log)}
        return receipt,inputs,stage,tests,log
    def test_reuse_binds_source_patch_target_and_real_native_log(self):
        args=self.receipt();p.verify_receipt(*args)
        for field,value in [('schemaVersion',2),('target','darwin-arm64'),('sourceFiles',{}),('stagedSourceFiles',{}),('upstreamPatchManifestSHA256','d'*64),('nativeLogSHA256','e'*64),('nativeTests',[]),('realAccountsRead',True),('syntheticOnly',False)]:
            receipt=copy.deepcopy(args[0]);receipt[field]=value
            with self.assertRaises(ValueError):p.verify_receipt(receipt,*args[1:])
    def test_source_inventory_detects_extra_and_changed_files(self):
        with tempfile.TemporaryDirectory()as root:
            root=Path(root).resolve();(root/'adapter').mkdir();(root/'adapter/main.go').write_text('package main\n')
            original=p.inventory(root);(root/'adapter/extra.go').write_text('package main\n')
            self.assertNotEqual(p.inventory(root),original);(root/'adapter/extra.go').unlink();(root/'adapter/main.go').write_text('package changed\n')
            self.assertNotEqual(p.inventory(root),original)
    def test_linked_input_is_rejected(self):
        with tempfile.TemporaryDirectory()as root:
            root=Path(root).resolve();original=root/'original';original.write_bytes(b'fixture');alias=root/'alias'
            import os
            os.link(original,alias)
            with self.assertRaises(ValueError):p.regular(alias)
    def test_existing_interrupted_source_is_not_replaced(self):
        with tempfile.TemporaryDirectory()as root:
            root=Path(root).resolve();(root/'source').mkdir();sentinel=root/'source/preserved';sentinel.write_bytes(b'failed stage')
            with self.assertRaises(ValueError):p.source_stage(root,{},None,{})
            self.assertEqual(sentinel.read_bytes(),b'failed stage')
    def test_paths_cannot_overlap_source_or_escape_through_parent(self):
        with tempfile.TemporaryDirectory()as root:
            root=Path(root).resolve()
            self.assertEqual(p.locations(root/'build',root/'resources'),(root/'build',root/'resources'))
            for build,resources in [(p.SOURCE,root/'r'),(root/'b',p.SOURCE),(root/'b',root/'b/r'),(root/'b/../c',root/'r'),(Path('relative'),root/'r')]:
                with self.assertRaises(ValueError):p.locations(build,resources)
    def test_pe_abi_matches_native_host_amd64_pe32plus(self):
        data=bytearray(300);data[:2]=b'MZ';data[60:64]=(64).to_bytes(4,'little');data[64:68]=b'PE\0\0';data[68:70]=b'\x64\x86';data[88:90]=b'\x0b\x02'
        p.validate_pe(bytes(data));data[88:90]=b'\x0b\x01'
        with self.assertRaises(ValueError):p.validate_pe(bytes(data))
    def test_ps_entry_requires_windows_and_preserves_native_modes(self):
        text=(p.REPO/'windows/scripts/Prepare-ProviderPool.ps1').read_text()
        self.assertIn('Win32NT',text);self.assertIn('$RunNativeTests -and $VerifiedReuse',text)
        self.assertIn("'--verify-only', '--require-native'",text)
        self.assertIn("if ($AllowDependencyDownload)",text)
        self.assertEqual(text.count('if ($LASTEXITCODE -ne 0)'),2)

if __name__=='__main__':unittest.main()
