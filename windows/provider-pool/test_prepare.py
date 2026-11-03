import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

spec=importlib.util.spec_from_file_location('provider_prepare',Path(__file__).with_name('prepare.py'))
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class ProviderResources(unittest.TestCase):
    def space_fixture(self, root):
        build, resources = root / 'build', root / 'resources'
        build.mkdir()
        env = {key: str(root / key) for key in ('TMPDIR', 'GOTMPDIR', 'GOMODCACHE', 'GOCACHE')}
        return p.SpaceAudit(build, resources, env)
    def location(self, path, free=80, volume='fixture-volume'):
        return {'resolvedPath': str(path), 'existingAncestor': str(path.parent), 'volumeId': volume,
                'volumeAnchor': path.anchor, 'totalBytes': 100 * 1024**3, 'freeBytes': free * 1024**3}
    def test_shared_physical_volume_is_budgeted_once(self):
        with tempfile.TemporaryDirectory() as root:
            audit = self.space_fixture(Path(root).resolve())
            with mock.patch.object(p, 'space_location', side_effect=self.location), mock.patch('builtins.print'):
                audit.check('before-source-stage')
            receipt = json.loads(audit.path.read_bytes())
            volumes = receipt['checks'][0]['volumes']
            self.assertEqual(len(volumes), 1)
            self.assertEqual(next(iter(volumes.values()))['plannedIncrementalBudgetBytes'], 30 * 1024**3)
            self.assertEqual(receipt['minimumFreeBytes'], 50 * 1024**3)
            self.assertEqual(receipt['reserveBytes'], 20 * 1024**3)
            self.assertEqual(len(next(iter(volumes.values()))['roles']), 7)
    def test_low_cache_volume_is_retained_as_failed_evidence(self):
        with tempfile.TemporaryDirectory() as root:
            audit = self.space_fixture(Path(root).resolve())
            def location(path):
                cache = path.name == 'GOCACHE'
                return self.location(path, 49 if cache else 80, 'cache-volume' if cache else 'build-volume')
            with mock.patch.object(p, 'space_location', side_effect=location), mock.patch('builtins.print'):
                with self.assertRaisesRegex(ValueError, 'provider_pool_insufficient_space'):
                    audit.check('before-source-stage')
            receipt = json.loads(audit.path.read_bytes())
            self.assertEqual(receipt['checks'][0]['error'], 'provider_pool_insufficient_space')
            self.assertEqual(receipt['checks'][0]['volumes']['cache-volume']['freeBytes'], 49 * 1024**3)
    def test_readonly_source_does_not_require_write_headroom(self):
        with tempfile.TemporaryDirectory() as root:
            audit = self.space_fixture(Path(root).resolve())
            def location(path):
                return self.location(path, 1 if path == p.SOURCE else 80, 'source' if path == p.SOURCE else 'writes')
            with mock.patch.object(p, 'space_location', side_effect=location), mock.patch('builtins.print'):
                audit.check('before-source-stage')
            self.assertEqual(audit.records[0]['volumes']['source']['plannedIncrementalBudgetBytes'], 0)
    def test_phase_budget_and_volume_change_stop_further_work(self):
        with tempfile.TemporaryDirectory() as root:
            audit = self.space_fixture(Path(root).resolve())
            with mock.patch.object(p, 'space_location', side_effect=self.location), mock.patch('builtins.print'):
                audit.check('before-source-stage')
            with mock.patch.object(p, 'space_location', side_effect=lambda path: self.location(path, 48)), mock.patch('builtins.print'):
                with self.assertRaisesRegex(ValueError, 'provider_pool_space_budget_exceeded'):
                    audit.check('after-source-stage')
            self.assertEqual(audit.records[-1]['volumes']['fixture-volume']['observedNetUseBytes'], 32 * 1024**3)
            with mock.patch.object(p, 'space_location', side_effect=lambda path: self.location(path, volume='replacement')), mock.patch('builtins.print'):
                with self.assertRaisesRegex(ValueError, 'provider_pool_space_location_changed'):
                    audit.check('before-build')
    def test_go_and_python_temp_paths_are_explicit_and_reused(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve(); build = root / 'build'; build.mkdir()
            selected = {name: str(root / name) for name in ('GOMODCACHE', 'GOCACHE', 'GOPATH', 'GOTMPDIR')}
            with mock.patch.dict(os.environ, selected, clear=True), mock.patch.object(p.subprocess, 'check_output') as run:
                env = p.environment(build, False)
                for name, value in selected.items(): self.assertEqual(env[name], value)
                self.assertEqual(env['TMPDIR'], str(build / 'tmp'))
                self.assertEqual(env['TEMP'], env['TMPDIR'])
                self.assertEqual(env['TMP'], env['TMPDIR'])
                self.assertEqual(env['GOTOOLCHAIN'], 'local')
                self.assertEqual(env['GOPROXY'], 'off')
                self.assertTrue(Path(env['GOTMPDIR']).is_dir())
                run.assert_not_called()
            selected.pop('GOTMPDIR')
            with mock.patch.dict(os.environ, selected, clear=True):
                self.assertEqual(p.environment(build, False)['GOTMPDIR'], str(build / 'tmp'))
            with mock.patch.dict(os.environ, {**selected, 'GOTMPDIR': 'relative'}, clear=True):
                with self.assertRaisesRegex(ValueError, 'provider_pool_go_temp_invalid'): p.environment(build, False)
    def test_effective_go_paths_cannot_silently_fall_back(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve()
            env = {name: str(root / name) for name in ('GOMODCACHE', 'GOCACHE', 'GOTMPDIR')}
            with mock.patch.object(p.subprocess, 'check_output', return_value=json.dumps(env)) as run:
                p.verify_go_paths(env)
                self.assertEqual(run.call_args.args[0], ['go', 'env', '-json', 'GOMODCACHE', 'GOCACHE', 'GOTMPDIR'])
                self.assertEqual(run.call_args.kwargs['env'], env)
            with mock.patch.object(p.subprocess, 'check_output', return_value=json.dumps({**env, 'GOCACHE': str(root / 'other')})):
                with self.assertRaisesRegex(ValueError, 'provider_pool_go_path_changed'): p.verify_go_paths(env)
    def test_low_space_admission_precedes_source_and_go_build(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve()
            args = SimpleNamespace(build_root=root/'build', resource_dir=root/'resource', verify_only=False,
                                   run_native_tests=False, require_native=False, allow_dependency_download=False)
            env = {name: str(root / name) for name in ('TMPDIR', 'GOTMPDIR', 'GOMODCACHE', 'GOCACHE')}
            with mock.patch.object(p, 'source_inputs', return_value=({}, None, {}, set())), \
                 mock.patch.object(p, 'environment', return_value=env), \
                 mock.patch.object(p, 'space_location', side_effect=lambda path: self.location(path, 49)), \
                 mock.patch.object(p, 'source_stage') as stage, \
                 mock.patch.object(p, 'verify_go_paths') as go_env, mock.patch.object(p.subprocess, 'run') as build, \
                 mock.patch('builtins.print'):
                with self.assertRaisesRegex(ValueError, 'provider_pool_insufficient_space'): p.prepare(args)
                stage.assert_not_called(); go_env.assert_not_called(); build.assert_not_called()
            self.assertFalse((root/'build/WINDOWS-RESOURCES.json').exists())
    def test_space_location_uses_actual_volume_and_rejects_links(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve()
            data = p.space_location(root/'missing')
            self.assertEqual(data['volumeId'], str(root.stat().st_dev))
            self.assertEqual(data['resolvedPath'], str(root/'missing'))
            self.assertGreater(data['totalBytes'], 0)
            with self.assertRaises(ValueError): p.space_location(Path('relative'))
            if os.name != 'nt':
                (root/'link').symlink_to(root, target_is_directory=True)
                with self.assertRaises(ValueError): p.space_location(root/'link/output')
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
