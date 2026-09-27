#!/usr/bin/env python3
"""Offline synthetic packaging proofs. No engine code, runtime or codesign executed."""
import base64
import copy
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('packaging', Path(__file__).resolve().parents[1] / 'scripts/prepare-token-monitor-resources.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def macho(arch='arm64'):
    return b'\xcf\xfa\xed\xfe' + struct.pack('<I', 0x100000c if arch == 'arm64' else 0x1000007) + bytes(100)


def archive(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as tf:
        for name, data, kind in entries:
            item = tarfile.TarInfo(name)
            item.type = kind
            item.mode = 0o644
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                item.linkname = data
            elif kind == tarfile.REGTYPE:
                item.size = len(data)
            tf.addfile(item, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
    return stream.getvalue()


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='token-monitor-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.cache = self.root / 'cache'
        self.cache.mkdir()
        self.source = self.root / 'source'
        self.source.mkdir()
        self.lock = {'lockfileVersion': 3, 'packages': {}}
        self.package('demo', {'optionalDependencies': {'native-arm': '1', 'native-x64': '1'}})
        self.package('native-arm', {'cpu': ['arm64'], 'os': ['darwin']}, {'binding.node': macho()})
        self.package('native-x64', {'cpu': ['x64'], 'os': ['darwin']}, {'binding.node': macho('x64')})
        self.package('@tokscale/cli-darwin-arm64', {'cpu': ['arm64'], 'os': ['darwin']}, {'bin/tokscale': macho()})
        node = archive([(f'node-v22.23.2-darwin-arm64/{rel}', data, tarfile.REGTYPE)
                        for rel, data in [('bin/node', macho()), ('LICENSE', b'Node license')]])
        self.put(node)
        binary = macho() + b'fork'
        self.put(binary)
        self.pin = {'schemaVersion': 1, 'dependencyRoots': ['demo'],
                    'finalSource': {'files': {}},
                    'node': {'platforms': {'darwin-arm64': {'url': 'https://nodejs.org/dist/v22.23.2/node-v22.23.2-darwin-arm64.tar.gz', 'archiveSHA256': m.digest(node), 'binaryPreSignSHA256': m.digest(macho())}}},
                    'tokscale': {'platforms': {'darwin-arm64': {'url': 'https://github.com/Javis603/tokscale/releases/download/token-monitor-06a9f162/tokscale-darwin-arm64', 'sha256': m.digest(binary), 'package': '@tokscale/cli-darwin-arm64'}}}}
        files = {'bridge.cjs': b'"use strict";', 'client-catalog.json': b'{"clients":[]}', 'provenance.json': b'{"license":"MIT"}', 'lib/index.cjs': b'module.exports = {};',
                 'hooks/index.cjs': b'module.exports = {};', 'upstream/LICENSE': b'Original MIT license',
                 'upstream/package-lock.json': m.canonical(self.lock)}
        for rel, data in files.items():
            p = self.source / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            self.pin['finalSource']['files'][rel] = m.digest(data)

    def put(self, blob, algorithm='sha256'):
        path = self.cache / (algorithm + '-' + m.digest(blob, algorithm))
        path.write_bytes(blob)
        return path

    def package(self, name, extra=None, files=None):
        meta = {'name': name, 'version': '1.0.0', **(extra or {})}
        data = {'package.json': m.canonical(meta), **(files or {'index.js': b'module.exports = {};'})}
        blob = archive([('package/' + rel, value, tarfile.REGTYPE) for rel, value in data.items()])
        self.put(blob, 'sha512')
        self.lock['packages']['node_modules/' + name] = {
            'version': '1.0.0', 'resolved': 'https://registry.npmjs.org/' + name + '/-/' + name.split('/')[-1] + '-1.0.0.tgz',
            'integrity': 'sha512-' + base64.b64encode(bytes.fromhex(m.digest(blob, 'sha512'))).decode(), **(extra or {})}

    def stage(self, name='TokenMonitorEngine'):
        path = self.root / name
        with patch.object(m.subprocess, 'run', side_effect=AssertionError('unexpected subprocess/network')):
            manifest = m.assemble(self.source, path, self.pin, 'arm64', self.cache, True)
        return path, manifest

    def signed_fixture(self):
        tree, manifest = self.stage()
        # Simulate signature mutation without executing native tools or binaries.
        for rel in manifest['nativeFiles']:
            p = tree / rel
            p.write_bytes(p.read_bytes() + b'SIGNATURE')
        full = {**manifest, 'postSignFiles': m.inventory(tree)}
        (tree / m.MANIFEST).write_bytes(m.canonical(full))
        return tree, manifest

    def test_deterministic_success_and_original_license(self):
        a, first = self.stage()
        b, second = self.stage('second')
        self.assertEqual(first, second)
        self.assertEqual(m.inventory(a), m.inventory(b))
        self.assertEqual((a / 'upstream/LICENSE').read_bytes(), b'Original MIT license')
        self.assertEqual((a / 'provenance.json').read_bytes(), b'{"license":"MIT"}')
        self.assertIn('node_modules/native-arm', first['packages'])
        self.assertNotIn('node_modules/native-x64', first['packages'])
        self.assertEqual(len(first['nativeFiles']), 3)

    def test_catalog_required_and_copied(self):
        tree, _ = self.stage()
        self.assertEqual((tree / 'client-catalog.json').read_bytes(), b'{"clients":[]}')
        (tree / 'client-catalog.json').unlink()
        with self.assertRaisesRegex(m.PackagingError, 'missing_engine_resource'):
            m.validate_layout(tree, {})

    def test_node_signing_reviewed_entitlements_only(self):
        def sign(cmd, **kwargs):
            self.assertIn('--options', cmd)
            path = Path(cmd[cmd.index('--entitlements') + 1])
            self.assertEqual(m.plistlib.loads(path.read_bytes()), m.NODE_ENTITLEMENTS)
            self.assertNotIn('com.apple.security.get-task-allow', m.NODE_ENTITLEMENTS)
            self.assertNotIn('com.apple.security.cs.allow-dyld-environment-variables', m.NODE_ENTITLEMENTS)
            return subprocess.CompletedProcess(cmd, 0)
        with patch.object(m.subprocess, 'run', side_effect=sign):
            m.codesign(self.root / 'runtime/node', 'REVIEWED-TEST-IDENTITY')

    def test_runtime_smoke_clean_environment_and_failure(self):
        def run(cmd, **kwargs):
            self.assertEqual(set(kwargs['env']), {'HOME', 'TMPDIR', 'PATH'})
            self.assertNotIn('NODE_OPTIONS', kwargs['env'])
            self.assertIn('--allow-natives-syntax', cmd)
            self.assertIn('vendor/node_modules/koffi', cmd[3])
            self.assertEqual(kwargs['timeout'], 30)
            return subprocess.CompletedProcess(cmd, 0, b'TOKEN_MONITOR_RUNTIME_OK')
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.platform, 'machine', return_value='arm64'):
            with patch.object(m.subprocess, 'run', side_effect=run):
                self.assertEqual(m.runtime_smoke(self.root, 'arm64')['status'], 'passed')
            with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, b'')):
                with self.assertRaisesRegex(m.PackagingError, 'runtime_smoke_failed'):
                    m.runtime_smoke(self.root, 'arm64')

    def test_cross_arch_smoke_explicitly_deferred(self):
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.platform, 'machine', return_value='arm64'):
            with patch.object(m.subprocess, 'run', side_effect=AssertionError('must not execute wrong architecture')):
                self.assertEqual(m.runtime_smoke(self.root, 'x64')['status'], 'deferred-target-host')

    def test_unchanged_version_tampered_archive(self):
        key = 'node_modules/demo'
        path = self.cache / ('sha512-' + m.integrity_hex(self.lock['packages'][key]['integrity']))
        path.write_bytes(archive([('package/package.json', b'{"version":"1.0.0"}', tarfile.REGTYPE)]))
        with self.assertRaisesRegex(m.PackagingError, 'cache_integrity_mismatch'):
            self.stage()

    def test_extracted_cache_never_used(self):
        stale = self.cache / 'node_modules/demo'
        stale.mkdir(parents=True)
        (stale / 'package.json').write_text('{"version":"1.0.0"}')
        (stale / 'index.js').write_text('TAMPERED')
        tree, _ = self.stage()
        self.assertNotIn(b'TAMPERED', (tree / 'vendor/node_modules/demo/index.js').read_bytes())

    def test_offline_missing_cache(self):
        for p in self.cache.iterdir():
            p.unlink()
        with self.assertRaisesRegex(m.PackagingError, 'offline_cache_missing'):
            self.stage()

    def test_missing_dependency_in_lock(self):
        lock = copy.deepcopy(self.lock)
        del lock['packages']['node_modules/native-arm']
        with self.assertRaisesRegex(m.PackagingError, 'missing_lock_dependency'):
            m.closure(lock, ['demo'], 'arm64')

    def test_target_selection_not_host_and_intel_alias(self):
        self.assertEqual(m.arch_name('x86_64'), 'x64')
        selected = m.closure(self.lock, ['demo'], 'x64')
        self.assertIn('node_modules/native-x64', selected)
        self.assertNotIn('node_modules/native-arm', selected)

    def test_wrong_architecture(self):
        with self.assertRaisesRegex(m.PackagingError, 'wrong_native_architecture'):
            m.check_arch(macho('x64'), 'arm64')

    def test_traversal_absolute_link_special_and_duplicates(self):
        cases = [
            [('package/../../escape', b'x', tarfile.REGTYPE)],
            [('/escape', b'x', tarfile.REGTYPE)],
            [('package/link', '../../escape', tarfile.SYMTYPE)],
            [('package/link', '/escape', tarfile.LNKTYPE)],
            [('package/fifo', b'', tarfile.FIFOTYPE)],
            [('package/a', b'x', tarfile.REGTYPE), ('package/a', b'y', tarfile.REGTYPE)],
            [('package/A', b'x', tarfile.REGTYPE), ('package/a', b'y', tarfile.REGTYPE)],
            [('package/a', b'x', tarfile.REGTYPE), ('package/a/b', b'y', tarfile.REGTYPE)],
            [('package/a', 'b', tarfile.SYMTYPE)],
        ]
        for entries in cases:
            with self.subTest(entries=entries), self.assertRaises(m.PackagingError):
                m.extract_package(archive(entries), self.root / 'extract')
        self.assertFalse((self.root / 'escape').exists())

    def test_valid_node_internal_link_is_not_materialized(self):
        blob = archive([('node-v22.23.2-darwin-arm64/bin/node', macho(), tarfile.REGTYPE),
                        ('node-v22.23.2-darwin-arm64/LICENSE', b'license', tarfile.REGTYPE),
                        ('node-v22.23.2-darwin-arm64/bin/npm', '../lib/npm.js', tarfile.SYMTYPE)])
        self.assertEqual(set(m.node_payload(blob, 'arm64')), {'node', 'LICENSE'})

    def test_registry_url_and_integrity_restrictions(self):
        for value in ['http://registry.npmjs.org/a/-/a.tgz', 'https://evil.example/a.tgz',
                      'https://registry.npmjs.org@evil.example/a.tgz', 'https://registry.npmjs.org/a/-/a.tgz?x=1']:
            with self.subTest(url=value), self.assertRaises(m.PackagingError):
                m.registry_url(value)
        with self.assertRaises(m.PackagingError):
            m.integrity_hex('sha1-abcd')

    def test_extraneous_node_modules(self):
        tree, manifest = self.stage()
        (tree / 'vendor/node_modules/unreviewed').mkdir()
        with self.assertRaisesRegex(m.PackagingError, 'extraneous_dependency'):
            m.validate_layout(tree, manifest['packages'])

    def test_node_modules_outside_vendor(self):
        tree, manifest = self.stage()
        (tree / 'upstream/node_modules').mkdir()
        with self.assertRaisesRegex(m.PackagingError, 'unverified_node_modules'):
            m.validate_layout(tree, manifest['packages'])

    def test_private_runtime_path(self):
        tree, manifest = self.stage()
        (tree / 'lib/leak.cjs').write_text('require("/Users/fixture/runtime")')
        with self.assertRaisesRegex(m.PackagingError, 'private_runtime_path'):
            m.validate_layout(tree, manifest['packages'])

    def test_wrong_nested_layout(self):
        tree, manifest = self.stage()
        (tree / 'engine').mkdir()
        with self.assertRaisesRegex(m.PackagingError, 'nested_engine_layout'):
            m.validate_layout(tree, manifest['packages'])

    def test_manifest_success_distinguishes_signing_hashes(self):
        tree, manifest = self.signed_fixture()
        observed = []
        m.check_manifest(tree, manifest, lambda p: observed.append(p.name))
        self.assertEqual(len(observed), 3)
        full = m.read_json(tree / m.MANIFEST)
        self.assertNotEqual(full['preSignFiles']['runtime/node'], full['postSignFiles']['runtime/node'])

    def test_post_sign_tamper(self):
        tree, manifest = self.signed_fixture()
        (tree / 'runtime/node').write_bytes(macho() + b'TAMPER')
        with self.assertRaisesRegex(m.PackagingError, 'manifest_content_mismatch'):
            m.check_manifest(tree, manifest, lambda _: None)

    def test_forged_unsigned_manifest(self):
        tree, manifest = self.signed_fixture()
        (tree / 'bridge.cjs').write_bytes(b'tamper')
        full = m.read_json(tree / m.MANIFEST)
        full['postSignFiles']['bridge.cjs'] = m.inventory(tree)['bridge.cjs']
        (tree / m.MANIFEST).write_bytes(m.canonical(full))
        with self.assertRaisesRegex(m.PackagingError, 'unsigned_content_changed'):
            m.check_manifest(tree, manifest, lambda _: None)

    def test_missing_packaged_dependency(self):
        tree, manifest = self.signed_fixture()
        (tree / 'vendor/node_modules/demo/index.js').unlink()
        with self.assertRaisesRegex(m.PackagingError, 'manifest_content_mismatch'):
            m.check_manifest(tree, manifest, lambda _: None)

    def test_signature_failure(self):
        tree, manifest = self.signed_fixture()
        def reject(_):
            raise m.PackagingError('signature_verification_failed')
        with self.assertRaisesRegex(m.PackagingError, 'signature_verification_failed'):
            m.check_manifest(tree, manifest, reject)

    def test_provenance_manifest_tamper(self):
        tree, manifest = self.signed_fixture()
        full = m.read_json(tree / m.MANIFEST)
        full['packages'] = {}
        (tree / m.MANIFEST).write_bytes(m.canonical(full))
        with self.assertRaisesRegex(m.PackagingError, 'manifest_provenance_mismatch'):
            m.check_manifest(tree, manifest, lambda _: None)

    def test_real_unfrozen_source_fails_closed(self):
        with self.assertRaisesRegex(m.PackagingError, 'final_source_not_frozen'):
            pin = m.read_json(m.SOURCE / 'SOURCE.json')
            pin['finalSource']['status'] = 'pending'
            (self.source / 'SOURCE.json').write_bytes(m.canonical(pin))
            m.load_production(self.source, 'arm64')

    def test_no_fixture_or_source_cli_switch(self):
        result = subprocess.run([sys.executable, '-B', str(m.ROOT / 'scripts/prepare-token-monitor-resources.py'), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('--fixture', result.stdout)
        self.assertNotIn('--source', result.stdout)

    def test_literal_outside_import_rejected(self):
        tree, _ = self.stage()
        (tree / 'lib/index.cjs').write_text('require("../../outside.cjs")')
        with self.assertRaisesRegex(m.PackagingError, 'outside_runtime_import'):
            m.validate_import_boundaries(tree)

    def test_empty_directory_manifest_mismatch(self):
        tree, manifest = self.signed_fixture()
        (tree / 'unexpected').mkdir()
        with self.assertRaisesRegex(m.PackagingError, 'manifest_directory_set_mismatch'):
            m.check_manifest(tree, manifest, lambda _: None)

    def test_download_is_bounded_and_rehashes_cache(self):
        blob = b'archive fixture'
        url = 'https://registry.npmjs.org/demo/-/demo-1.tgz'
        def download(argv, **kwargs):
            self.assertEqual(argv[:2], ['/usr/bin/curl', '--disable'])
            self.assertNotIn('--location', argv)
            self.assertEqual(kwargs['timeout'], 35)
            self.assertIn('--max-time', argv)
            Path(argv[argv.index('--output') + 1]).write_bytes(blob)
            return subprocess.CompletedProcess(argv, 0, b'200\n', b'')
        with patch.object(m.subprocess, 'run', side_effect=download) as run:
            self.assertEqual(m.fetch(url, self.cache, m.digest(blob), 'sha256', False), blob)
            self.assertEqual(m.fetch(url, self.cache, m.digest(blob), 'sha256', True), blob)
            self.assertEqual(run.call_count, 1)

    def test_redirect_to_unapproved_host_rejected(self):
        url = 'https://github.com/Javis603/tokscale/releases/download/token-monitor-06a9f162/tokscale-darwin-arm64'
        result = subprocess.CompletedProcess([], 0, b'302\nhttps://evil.example/binary', b'')
        with patch.object(m.subprocess, 'run', return_value=result), self.assertRaisesRegex(m.PackagingError, 'download_redirect_forbidden'):
            m.fetch(url, self.cache, '0' * 64, 'sha256', False)

    def test_node_archive_tamper(self):
        pin = self.pin['node']['platforms']['darwin-arm64']
        (self.cache / ('sha256-' + pin['archiveSHA256'])).write_bytes(b'changed')
        with self.assertRaisesRegex(m.PackagingError, 'cache_integrity_mismatch'):
            self.stage()

    def trusted_fixture(self):
        tree, expected = self.signed_fixture()
        receipt = self.root / 'trusted.json'
        receipt.write_bytes(m.canonical(m.native_receipt(expected, m.inventory(tree), '-')))
        return tree, expected, receipt

    def test_correct_fixed_source_resign_receipt(self):
        tree, expected, receipt = self.trusted_fixture()
        m.check_receipt(tree, expected, receipt, '-')
        rebuilt = self.stage('rebuilt')[1]
        self.assertEqual(expected, rebuilt)
        m.check_receipt(tree, rebuilt, receipt, '-')

    def test_substituted_native_synchronized_manifest_rejected(self):
        tree, expected, receipt = self.trusted_fixture()
        (tree / 'runtime/node').write_bytes(macho() + b'SUBSTITUTE-SIGNED')
        full = m.read_json(tree / m.MANIFEST)
        full['postSignFiles'] = {k: v for k, v in m.inventory(tree).items() if k != m.MANIFEST}
        (tree / m.MANIFEST).write_bytes(m.canonical(full))
        m.check_manifest(tree, expected, lambda _: None)
        with self.assertRaisesRegex(m.PackagingError, 'trusted_receipt_mismatch'):
            m.check_receipt(tree, expected, receipt, '-')

    def test_receipt_wrong_provenance_arch_identity_and_pre_hash(self):
        tree, expected, receipt = self.trusted_fixture()
        good = m.read_json(receipt)
        for field, value in [('sourceSHA256', '0'*64), ('architecture', 'x64'),
                             ('fixedInputsSHA256', '0'*64), ('signingIdentity', 'OTHER')]:
            with self.subTest(field=field):
                receipt.write_bytes(m.canonical({**good, field: value}))
                with self.assertRaisesRegex(m.PackagingError, 'trusted_receipt_mismatch'):
                    m.check_receipt(tree, expected, receipt, '-')
        good['nativeFiles']['runtime/node']['pre']['sha256'] = '0'*64
        receipt.write_bytes(m.canonical(good))
        with self.assertRaisesRegex(m.PackagingError, 'trusted_receipt_mismatch'):
            m.check_receipt(tree, expected, receipt, '-')

    def test_receipt_missing_symlink_and_inside_bundle(self):
        tree, expected, receipt = self.trusted_fixture()
        receipt.unlink()
        with self.assertRaisesRegex(m.PackagingError, 'trusted_receipt_missing'):
            m.check_receipt(tree, expected, receipt, '-')
        with self.assertRaisesRegex(m.PackagingError, 'trusted_receipt_required'):
            m.receipt_path(None, tree)
        receipt.symlink_to(self.root / 'absent')
        with self.assertRaisesRegex(m.PackagingError, 'receipt_symlink_forbidden'):
            m.receipt_path(receipt, tree)
        bundle = self.root / 'App.app'
        with self.assertRaisesRegex(m.PackagingError, 'receipt_inside_bundle'):
            m.receipt_path(bundle / 'receipt.json', tree, bundle)
        with self.assertRaisesRegex(m.PackagingError, 'receipt_inside_bundle'):
            m.receipt_path(tree / 'receipt.json', tree)

    def test_final_verify_cross_arch_rejects_bundled_smoke_claim(self):
        tree, expected, receipt = self.trusted_fixture()
        bundle = self.root / 'App.app'
        resources = bundle / 'Contents/Resources'
        resources.mkdir(parents=True)
        tree.rename(resources / 'TokenMonitorEngine')
        tree = resources / 'TokenMonitorEngine'
        full = m.read_json(tree / m.MANIFEST)
        full['runtimeSmoke'] = {'status': 'passed', 'architecture': 'arm64'}
        (tree / m.MANIFEST).write_bytes(m.canonical(full))
        with patch.object(m, 'load_production', return_value=self.pin), \
             patch.object(m, 'assemble', return_value=expected), \
             patch.object(m, 'codesign'), patch.object(m.sys, 'platform', 'darwin'), \
             patch.object(m.platform, 'machine', return_value='x86_64'):
            with self.assertRaisesRegex(m.PackagingError, 'runtime_smoke_incomplete'):
                m.verify_resources(resources, 'arm64', self.cache, bundle=bundle, receipt=receipt)

    def test_final_smoke_requires_actual_success(self):
        for status in ('deferred-target-host', 'failed'):
            with patch.object(m, 'runtime_smoke', return_value={'status': status, 'architecture': 'arm64'}):
                with self.assertRaisesRegex(m.PackagingError, 'runtime_smoke_incomplete'):
                    m.final_runtime_smoke(self.root, 'arm64')
        with patch.object(m, 'runtime_smoke', return_value={'status': 'passed', 'architecture': 'arm64'}):
            self.assertEqual(m.final_runtime_smoke(self.root, 'arm64')['status'], 'passed')

    def test_clean_dist_default_cache_independent(self):
        suffix = 'Library/Caches/AiGoodBro/Next/token-monitor-downloads'
        self.assertEqual(m.DEFAULT_CACHE, Path.home() / suffix)
        make = (m.ROOT / 'Makefile').read_text()
        release = (m.ROOT / 'scripts/build-release-artifacts.sh').read_text()
        self.assertIn('TOKEN_MONITOR_CACHE ?= $(HOME)/' + suffix, make)
        self.assertIn('${TOKEN_MONITOR_CACHE:-$HOME/' + suffix + '}', release)
        # Exercise the real clean-dist recipe in isolation, without touching user caches.
        isolated = self.root / 'clean-test'
        isolated.mkdir()
        cache = isolated / suffix
        cache.mkdir(parents=True)
        sentinel = cache / 'sha256-fixture'
        sentinel.write_bytes(b'cached')
        (isolated / 'dist').mkdir()
        recipe = make.split('\nclean-dist:\n', 1)[1].split('\n\n', 1)[0]
        (isolated / 'Makefile').write_text('DIST_DIR := dist\nclean-dist:\n' + recipe)
        result = subprocess.run(['make', 'clean-dist'], cwd=isolated, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse((isolated / 'dist').exists())
        self.assertEqual(sentinel.read_bytes(), b'cached')

    def test_preserved_guard_and_signing_order(self):
        text = (m.ROOT / 'Makefile').read_text()
        build = text.split('\nbuild:\n')[1].split('\ndebug:')[0]
        self.assertLess(build.index('check-build-target-idle.py'), build.index('rm -rf'))
        self.assertLess(build.index('prepare-token-monitor-resources.py'), build.index('codesign $(filter-out --deep,$(CODESIGN_FLAGS))'))
        self.assertGreater(build.index('prepare-token-monitor-resources.py --verify'), build.index('codesign --verify'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
