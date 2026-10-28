"""Offline provenance checks for the provider-specific SDK patch packaging."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Companion/AntigravityProxy'
spec = importlib.util.spec_from_file_location('provider_packager', ROOT / 'scripts/prepare-antigravity-proxy-resources.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


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
        expected = str(self.root / 'helper')
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
