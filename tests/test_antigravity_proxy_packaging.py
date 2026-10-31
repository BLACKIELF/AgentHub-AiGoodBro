"""Offline provenance checks for the provider-specific SDK patch packaging."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Companion/AntigravityProxy'
spec = importlib.util.spec_from_file_location('provider_packager', ROOT / 'scripts/prepare-antigravity-proxy-resources.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class ColdModuleCacheTests(unittest.TestCase):
    def test_both_builders_download_only_missing_pinned_source(self):
        for name in ('LocalProxy', 'AntigravityProxy'):
            for cold in (False, True):
                with self.subTest(adapter=name, cold=cold):
                    self.exercise(name, cold=cold)

    def test_changed_identity_after_download_is_rejected(self):
        for name in ('LocalProxy', 'AntigravityProxy'):
            for field, value in (('Version', 'v8.0.39'), ('Sum', 'h1:wrong'),
                                 ('GoModSum', 'h1:wrong'), ('Replace', {'Dir': 'other'})):
                with self.subTest(adapter=name, field=field):
                    self.exercise(name, cold=True, changed={field: value})

    def test_missing_directory_after_download_fails_without_retry_loop(self):
        for name in ('LocalProxy', 'AntigravityProxy'):
            with self.subTest(adapter=name):
                self.exercise(name, cold=True, unavailable=True)

    def test_download_failure_is_not_accepted_as_source(self):
        for name in ('LocalProxy', 'AntigravityProxy'):
            with self.subTest(adapter=name):
                self.exercise(name, cold=True, download_error=True)

    def exercise(self, name, *, cold, changed=None, unavailable=False, download_error=False):
        spec = importlib.util.spec_from_file_location('cold_' + name, ROOT / 'Companion' / name / 'go.py')
        support = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(support)
        pin = support.load_manifest()
        metadata = {'Path': support.MODULE, 'Version': support.VERSION,
                    'Sum': pin['moduleSum'], 'GoModSum': pin['moduleGoModSum']}
        with tempfile.TemporaryDirectory(prefix='cold-module-') as temporary:
            directory = Path(temporary)
            ready = dict(metadata, Dir=str(directory / 'sdk'))
            ready.update(changed or {})
            if unavailable:
                ready.pop('Dir')
            responses = [json.dumps(metadata), json.dumps(ready)] if cold else [json.dumps(ready)]
            target = directory / 'sdk' / pin['patches'][0]['target']
            original_read = support.regular_bytes

            class ReachedVerifiedSource(Exception):
                pass

            def read(path):
                if path == target:
                    raise ReachedVerifiedSource()
                return original_read(path)

            expected = subprocess.CalledProcessError if download_error else (
                ValueError if changed or unavailable else ReachedVerifiedSource)
            with mock.patch.object(support.subprocess, 'check_output', side_effect=responses) as query, \
                    mock.patch.object(support.subprocess, 'run') as download, \
                    mock.patch.object(support, 'regular_bytes', side_effect=read), \
                    mock.patch.object(support, 'verify_module_tree', side_effect=ReachedVerifiedSource):
                if download_error:
                    download.side_effect = subprocess.CalledProcessError(1, ['go', 'mod', 'download'])
                with self.assertRaises(expected):
                    support.prepare_source(directory / 'build', {'GOWORK': 'off'})
                self.assertEqual(query.call_count, 2 if cold and not download_error else 1)
                if cold:
                    download.assert_called_once_with(
                        ['go', 'mod', 'download', support.MODULE + '@' + support.VERSION],
                        cwd=support.SOURCE, env={'GOWORK': 'off'}, check=True)
                else:
                    download.assert_not_called()


class ProviderPatchPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='provider-packaging-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.support, self.patches = packager.provider_patch_support()

    def fake_resources(self):
        directory = self.root / 'AntigravityProxy'
        directory.mkdir()
        for name in ('SOURCE.json', 'LICENSE.CLIProxyAPI', 'LICENSE.Hazmat',
                     'upstream-patches/manifest.json', *[p['file'] for p in self.patches['patches']]):
            dest = directory / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / name, dest)
        (directory / packager.builder.EXECUTABLE).write_bytes(b'synthetic fixture executable')
        os.chmod(directory / packager.builder.EXECUTABLE, 0o755)
        (directory / 'THIRD_PARTY_NOTICES.txt').write_text('synthetic notices\n')
        files = [packager.builder.EXECUTABLE, 'LICENSE.CLIProxyAPI', 'LICENSE.Hazmat', 'SOURCE.json',
                 'THIRD_PARTY_NOTICES.txt', 'upstream-patches/manifest.json', *[p['file'] for p in self.patches['patches']]]
        manifest = {
            'schemaVersion': 1, 'architecture': 'arm64',
            'upstreamModule': self.patches['upstreamModule'], 'upstreamVersion': self.patches['upstreamVersion'],
            'upstreamCommit': self.patches['upstreamCommit'], 'upstreamPatches': self.patches,
            'upstreamPatchManifestSHA256': packager.builder.digest(SOURCE / 'upstream-patches/manifest.json'),
            'files': {name: packager.builder.digest(directory / name) for name in files},
        }
        (directory / 'manifest.json').write_text(json.dumps(manifest))
        return directory, manifest

    def verify_fixture(self):
        # Resource integrity is exercised here; the fixture is not a real signed binary.
        with mock.patch.object(packager.builder, 'architecture'), mock.patch.object(packager.builder.subprocess, 'run'):
            packager.verify_provider(self.root, 'arm64')

    def test_provider_hook_loads_only_reviewed_claude_patches(self):
        self.assertEqual(len(self.patches['patches']), 3)
        self.assertEqual({p['upstreamCommit'] for p in self.patches['patches']}, {
            'c2dfec28d57221be9e042d33e2e1e0da58b16542',
            'd495e24cbc3965a28afd1ebdd4160eb2b7febb0e',
        })
        self.assertEqual(self.patches['upstreamVersion'], 'v8.0.38')
        self.assertEqual(self.patches['license'], 'MIT')

    def test_tampered_source_inputs_and_overrides_fail_closed(self):
        fake = self.root / 'source'
        shutil.copytree(SOURCE / 'upstream-patches', fake / 'upstream-patches')
        self.support.load_manifest(fake)
        patch = fake / self.patches['patches'][0]['file']
        patch.write_bytes(patch.read_bytes() + b'tamper\n')
        with self.assertRaises(ValueError):
            self.support.load_manifest(fake)
        manifest = fake / 'upstream-patches/manifest.json'
        obj = json.loads(manifest.read_text())
        obj['patches'][0]['patchSHA256'] = self.support.sha256(patch.read_bytes())
        manifest.write_text(json.dumps(obj))
        with self.assertRaises(ValueError):
            self.support.load_manifest(fake)
        for flag in ('-overlay=bad', '--modfile=bad', '-C=bad'):
            self.assertTrue(self.support.has_source_override([flag]))

    def test_indented_go_module_replacement_is_rejected(self):
        fake = self.root / 'source'
        shutil.copytree(SOURCE / 'upstream-patches', fake / 'upstream-patches')
        (fake / 'go.mod').write_bytes((SOURCE / 'go.mod').read_bytes()
                                      + b'\n  replace example.test/unrelated => ../other\n')
        with self.assertRaises(ValueError):
            self.support.prepare_source(self.root / 'build', dict(os.environ, GOWORK='off'), fake)

    def test_build_output_is_not_lost_with_disposable_sources(self):
        expected = str((self.root / 'helper').resolve())
        self.assertEqual(self.support.resolve_output_flags('build', ['-o', 'helper', '.'], self.root),
                         ['-o', expected, '.'])
        self.assertEqual(self.support.resolve_output_flags('build', ['-o=helper', '.'], self.root),
                         ['-o=' + expected, '.'])
        for command, flags in [('build', ['.']), ('test', ['-c']), ('test', ['-c=true']), ('build', ['-o='])]:
            with self.assertRaises(ValueError):
                self.support.resolve_output_flags(command, flags, self.root)
        self.assertEqual(self.support.resolve_output_flags('test', ['-args', '-c'], self.root), ['-args', '-c'])

    def test_packaged_integrity_and_recomputed_metadata_tampering(self):
        directory, manifest = self.fake_resources()
        self.verify_fixture()
        source = directory / 'SOURCE.json'
        before = source.read_bytes()
        source.write_bytes(before + b' ')
        manifest['files']['SOURCE.json'] = packager.builder.digest(source)
        (directory / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            self.verify_fixture()
        source.write_bytes(before)
        manifest['files']['SOURCE.json'] = packager.builder.digest(source)
        patch_name = self.patches['patches'][0]['file']
        patch = directory / patch_name
        patch.write_bytes(patch.read_bytes() + b'tamper\n')
        manifest['files'][patch_name] = packager.builder.digest(patch)
        (directory / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            self.verify_fixture()
        patch.unlink()
        with self.assertRaises((ValueError, OSError)):
            self.verify_fixture()


if __name__ == '__main__':
    unittest.main()
