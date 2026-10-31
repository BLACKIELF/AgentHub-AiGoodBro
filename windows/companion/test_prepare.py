import importlib.util
import io
import json
from pathlib import Path
import runpy
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('companion_prepare', Path(__file__).with_name('prepare.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class Resources(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='companion-resources-')
        self.root = Path(self.temp.name).resolve()
        self.output = self.root / 'stage'

    def tearDown(self):
        self.temp.cleanup()

    def test_actual_payload_hash_stage_readback_and_stable_manifest(self):
        first = prepare.stage(self.output)
        self.assertEqual(len(first['sourceFiles']), 16)
        self.assertEqual(len(first['resourceFiles']), 17)
        self.assertFalse(first['nativeExecuted'])
        manifest = json.loads((self.output / 'manifest.json').read_text(encoding='utf-8'))
        self.assertEqual(len(manifest['files']), 16)
        for item in manifest['files']:
            self.assertEqual(prepare.sha((self.output / item['path']).read_bytes()), item['sha256'])
        self.assertEqual((self.output / 'bin/next-dispatch.py').read_bytes(), (prepare.SOURCE / 'next-dispatch.py').read_bytes())
        self.assertFalse((self.output / 'config').exists())
        before = {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in self.output.rglob('*') if p.is_file()}
        self.assertEqual(prepare.stage(self.output, verify_only=True), first)
        self.assertEqual(prepare.stage(self.output), first)
        self.assertEqual(before, {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in before})

    def test_tampered_missing_or_extra_resource_cannot_verify(self):
        prepare.stage(self.output)
        path = self.output / 'bin/next-dispatch.py'
        original = path.read_bytes()
        path.write_bytes(original + b'\n# changed\n')
        with self.assertRaisesRegex(ValueError, 'output_changed'):
            prepare.stage(self.output, verify_only=True)
        path.write_bytes(original)
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'output_changed'):
            prepare.stage(self.output, verify_only=True)
        path.write_bytes(original)
        extra = self.output / 'unexpected.py'
        extra.write_text('untrusted')
        with self.assertRaisesRegex(ValueError, 'unexpected_file'):
            prepare.stage(self.output)
        self.assertEqual(extra.read_text(), 'untrusted')

    def test_source_hash_and_inventory_reject_before_any_output(self):
        source = self.root / 'source'
        shutil.copytree(prepare.SOURCE / 'payload', source / 'payload')
        for name in ('SOURCE.json', 'next-dispatch.py'):
            shutil.copyfile(prepare.SOURCE / name, source / name)
        p = source / 'payload/SKILL.md'
        original = p.read_bytes()
        p.write_bytes(original + b'\nmodified\n')
        with self.assertRaisesRegex(ValueError, 'source_hash_changed'):
            prepare.stage(self.output, source)
        self.assertFalse(self.output.exists())
        p.write_bytes(original)
        (source / 'payload/foreign.txt').write_text('foreign')
        with self.assertRaisesRegex(ValueError, 'inventory_changed'):
            prepare.stage(self.output, source)
        self.assertFalse(self.output.exists())

    def test_symlink_and_hardlink_are_rejected_without_touching_target(self):
        prepare.stage(self.output)
        p = self.output / 'SKILL.md'
        target = self.root / 'original'
        p.rename(target)
        try:
            p.symlink_to(target)
        except OSError as error:
            self.skipTest('OS does not permit a synthetic symlink: ' + type(error).__name__)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            prepare.stage(self.output, verify_only=True)
        p.unlink()
        import os
        os.link(target, p)
        with self.assertRaisesRegex(ValueError, 'source_invalid'):
            prepare.stage(self.output, verify_only=True)
        self.assertTrue(target.exists())

    def test_real_adapters_delegate_only_allowed_actions_to_installed_client(self):
        prepare.stage(self.output)
        methods = {'activity': 'status', 'preflight': 'preflight', 'invocation': 'run'}
        for leaf, method in methods.items():
            script = self.output / ('scripts/next_dispatch_' + leaf + '.py')
            entry = runpy.run_path(str(script), run_name='synthetic_adapter')
            observed = []
            def loaded(path, run_name):
                self.assertEqual(Path(path), self.output / 'bin/next-dispatch.py')
                self.assertEqual(run_name, 'companion_fixed_client')
                observed.append(tuple(sys.argv[1:]))
                return {'main': lambda: 3}
            with patch.object(sys, 'argv', [str(script), method, '--request-id', 'a'*64]), patch.object(entry['runpy'], 'run_path', loaded):
                self.assertEqual(entry['main'](), 3)
            self.assertEqual(len(observed), 1)
            with patch.object(sys, 'argv', [str(script), 'approve']), patch('sys.stdout', io.StringIO()) as out, patch.object(entry['runpy'], 'run_path', side_effect=AssertionError('must not load')):
                self.assertEqual(entry['main'](), 2)
                self.assertEqual(json.loads(out.getvalue())['issueCode'], 'companion_method_unsupported')

    def test_real_launcher_help_and_strict_methods_need_no_ipc(self):
        prepare.stage(self.output)
        import subprocess
        launcher = self.output / 'bin/next-dispatch.py'
        result = subprocess.run([sys.executable, '-I', '-B', str(launcher), '--help'], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b'cancel-reservation', result.stdout)
        result = subprocess.run([sys.executable, '-I', '-B', str(launcher), 'run', '--request-id', 'a'*64, '--model', 'unsupported'], capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'unrecognized arguments', result.stderr)
        self.assertFalse((self.output / 'config').exists())


if __name__ == '__main__':
    unittest.main()
