#!/usr/bin/env python3
"""Exercise release shell wrappers with synthetic bundles and mocked native tools.

No Swift compilation, app execution, install, signing, mount, or GitHub access.
The wrappers, DMG staging script, plist checks, cmp checks and SHA-256 run normally.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import shlex
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
REAL_MAKE = '/usr/bin/make'
VERSION, BUILD, RELEASE = '9.6.80', '130', '1006v3'
EVIDENCE_KEYS = ('HOST_PIPE_EVIDENCE_PREFIX', 'APP_UPDATE_EVIDENCE_PREFIX', 'RESET_AUTO_EVIDENCE_PREFIX')

MOCK_TOOL = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(os.environ['RELEASE_FIXTURE_ROOT'])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
keys = ('BUILD_DIR', 'DIST_DIR', 'TOKEN_MONITOR_CACHE', 'TOKEN_MONITOR_RECEIPT_DIR',
        'TOKEN_MONITOR_OFFLINE', 'TOKEN_MONITOR_NODE_ARCHIVE', 'SIGN_IDENTITY',
        'HOST_PIPE_EVIDENCE_PREFIX', 'APP_UPDATE_EVIDENCE_PREFIX', 'RESET_AUTO_EVIDENCE_PREFIX')
with (root / 'events.jsonl').open('a') as stream:
    stream.write(json.dumps({'tool': name, 'args': args, 'env': {k: os.environ.get(k) for k in keys}}) + '\n')
def option(key):
    return args[args.index(key) + 1]
if name == 'uname':
    print('arm64')
elif name == 'make':
    values = dict(os.environ)
    values.update(item.split('=', 1) for item in args if '=' in item)
    target = args[0]
    if target == 'memory-risk-check' and os.environ.get('FAIL_MEMORY_GATE'):
        raise SystemExit('mock memory gate blocked')
    if target == 'memory-risk-check' and os.environ.get('LATE_RESET_EVIDENCE_SUFFIX'):
        evidence = root / '.local-artifacts/theme-upstream-1004v1'
        evidence.mkdir(parents=True, exist_ok=True)
        path = evidence / (values['RESET_AUTO_EVIDENCE_PREFIX'] + '.' + os.environ['LATE_RESET_EVIDENCE_SUFFIX'])
        kind = os.environ.get('LATE_RESET_EVIDENCE_KIND', 'file')
        if kind == 'directory':
            path.mkdir()
        elif kind == 'symlink':
            path.symlink_to(evidence / 'absent-late-target')
        else:
            path.write_bytes(b'late synthetic evidence must survive')
    if target in ('clean', 'clean-dist', 'release', 'release-arm64', 'release-intel'):
        raise SystemExit('unexpected destructive/repeated release target')
    if target == 'test':
        if os.environ.get('FAIL_TEST_GATE'):
            print('mock test gate blocked', file=sys.stderr)
            raise SystemExit(2)
        evidence = root / '.local-artifacts/theme-upstream-1004v1'
        evidence.mkdir(parents=True, exist_ok=True)
        for key, suffixes in (('HOST_PIPE_EVIDENCE_PREFIX', ('json',)),
                              ('APP_UPDATE_EVIDENCE_PREFIX', ('log', 'json'))):
            for suffix in suffixes:
                path = evidence / (values[key] + '.' + suffix)
                output = json.dumps({'fixture': key, 'suffix': suffix}) + '\n'
                with path.open('x') as stream:
                    stream.write(output)
        subprocess.run([sys.executable, str(root / 'scripts/reset-evidence-writes.py'),
                        str(evidence), values['RESET_AUTO_EVIDENCE_PREFIX']], check=True)
    if target in ('test', 'build'):
        assert values['SWIFT_OPTIMIZATION'] == '-O'
        assert values['BUNDLE_COMPANION'] == values['BUNDLE_TOKEN_MONITOR_DESKTOP'] == '1'
        arch = values['TARGET_TRIPLE'].split('-')[0]
        assert pathlib.Path(values['TOKEN_MONITOR_DESKTOP_RUNTIME']).is_dir()
        assert pathlib.Path(values['TOKEN_MONITOR_DESKTOP_DMG']).is_file()
        app = pathlib.Path(values['BUILD_DIR']) / 'AiGoodBro.app'
        if app.exists():
            shutil.rmtree(app)
        resources = app / 'Contents/Resources'
        resources.mkdir(parents=True)
        metadata = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
        if os.environ.get('BAD_BUILD_METADATA'):
            metadata['CFBundleVersion'] = '129'
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
        binary = app / 'Contents/MacOS/AiGoodBro'
        binary.parent.mkdir(parents=True)
        binary.write_text(arch)
        hub = resources / 'CompanionHub/agent-remote-control'
        hub.parent.mkdir()
        hub.write_text(arch)
        hub.chmod(0o755)
        manifest = {'schemaVersion': 1, 'architecture': arch, 'version': '0910v2-next',
                    'executable': 'agent-remote-control', 'sha256': hashlib.sha256(hub.read_bytes()).hexdigest(),
                    'sourceManifestSHA256': hashlib.sha256((root / 'Companion/Hub/SOURCE.json').read_bytes()).hexdigest()}
        (hub.parent / 'manifest.json').write_text(json.dumps(manifest))
        support = resources / 'SupportTools'
        support.mkdir()
        shutil.copy2(root / 'scripts/next_runtime_setup.py', support)
        shutil.copytree(root / '.agents/skills/multi-agent-management', resources / 'CompanionSkill')
        (app / 'Contents/Helpers/AiGoodBro Token Core.app').mkdir(parents=True)
elif name == 'ditto':
    shutil.copytree(args[0], args[1], symlinks=True)
elif name == 'hdiutil':
    if args[0] == 'create':
        snapshot = pathlib.Path(tempfile.mkdtemp(dir=root / 'snapshots'))
        shutil.copytree(option('-srcfolder'), snapshot, dirs_exist_ok=True, symlinks=True)
        pathlib.Path(args[-1]).write_text(json.dumps({'snapshot': str(snapshot)}))
    elif args[0] == 'verify':
        json.loads(pathlib.Path(args[-1]).read_text())
        if os.environ.get('FAIL_DMG_VERIFY'):
            raise SystemExit('mock DMG verify failed')
    elif args[0] == 'attach':
        snapshot = pathlib.Path(json.loads(pathlib.Path(args[-1]).read_text())['snapshot'])
        mount = pathlib.Path(option('-mountpoint'))
        shutil.copytree(snapshot, mount, dirs_exist_ok=True, symlinks=True)
        if os.environ.get('BAD_MOUNT_METADATA'):
            plist = mount / 'AiGoodBro.app/Contents/Info.plist'
            metadata = plistlib.loads(plist.read_bytes())
            metadata['CFBundleVersion'] = '129'
            plist.write_bytes(plistlib.dumps(metadata))
    elif args[0] == 'detach':
        for path in pathlib.Path(args[-1]).iterdir():
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
elif name == 'lipo':
    print(pathlib.Path(args[-1]).read_text())
elif name == 'codesign':
    assert pathlib.Path(args[-1]).exists()
    if os.environ.get('FAIL_CODESIGN'):
        raise SystemExit('mock codesign failed')
elif name == 'git':
    if args[0] in ('rev-parse', 'ls-remote'):
        raise SystemExit(0 if os.environ.get('EXISTING_TAG') == args[0] else 1)
elif name == 'gh':
    raise SystemExit(0 if os.environ.get('EXISTING_TAG') == 'gh' else 1)
'''


class ReleaseWrapperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='release wrappers ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ('scripts', 'tests', 'docs', 'Resources', 'Companion/Hub',
                       '.agents/skills/multi-agent-management', 'mockbin', 'snapshots'):
            (self.root / folder).mkdir(parents=True)
        for name in ('build-release-artifacts.sh', 'check-release-ready.sh', 'package-dmg.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        shutil.copy2(ROOT / 'Makefile', self.root / 'Makefile')
        # Run the two real evidence-write statements, with only their input data synthetic.
        # This also keeps the regression sensitive to a write_text / open('w') reversion.
        source = (ROOT / 'scripts/test-reset-credit-auto.py').read_text()
        tree = ast.parse(source)
        writes = []
        for suffix in ('.log', '.json'):
            matches = []
            for node in ast.walk(tree):
                if not isinstance(node, (ast.With, ast.Expr)):
                    continue
                expression = node.items[0].context_expr if isinstance(node, ast.With) else node.value
                parts = list(ast.walk(expression))
                if (any(isinstance(part, ast.Name) and part.id == 'q' for part in parts)
                        and any(isinstance(part, ast.Constant) and part.value == suffix for part in parts)):
                    matches.append(node)
            self.assertEqual(len(matches), 1, suffix)
            writes.append(ast.get_source_segment(source, matches[0]))
        (self.root / 'scripts/reset-evidence-writes.py').write_text(
            'import json, sys\nfrom pathlib import Path\n'
            'q = Path(sys.argv[1]); prefix = sys.argv[2]\n'
            'output = "synthetic reset evidence\\n"; receipt = {"fixture": "reset-auto"}\n'
            + '\n'.join(writes) + '\n')
        metadata = {'CFBundleShortVersionString': VERSION, 'CFBundleVersion': BUILD,
                    'CodexAccountManagerNextReleaseName': RELEASE}
        (self.root / 'Resources/Info.plist').write_bytes(plistlib.dumps(metadata))
        (self.root / 'Companion/Hub/SOURCE.json').write_text('{}')
        (self.root / 'LICENSE').write_text('Fixture license\n')
        (self.root / 'scripts/next_runtime_setup.py').write_text('# reviewed support fixture\n')
        for name in ('SKILL.md', '使用说明.md'):
            (self.root / '.agents/skills/multi-agent-management' / name).write_text('Reviewed fixture\n')
        (self.root / 'scripts/prepare-companion-resources.py').write_text(textwrap.dedent('''\
            import pathlib
            ROOT = pathlib.Path(__file__).resolve().parents[1]
            SKILL_FILES = ('SKILL.md', '使用说明.md')
            SKILL_SOURCE_OVERRIDES = {}
            '''))
        logger = textwrap.dedent('''\
            import json, os, pathlib, sys
            root = pathlib.Path(os.environ['RELEASE_FIXTURE_ROOT'])
            with (root / 'events.jsonl').open('a') as stream:
                stream.write(json.dumps({'tool': pathlib.Path(__file__).name, 'args': sys.argv[1:]}) + '\\n')
            ''')
        for name in ('prepare-token-monitor-desktop.py', 'prepare-token-monitor-resources.py'):
            (self.root / 'scripts' / name).write_text(logger)
        for name in ('test_health_boundaries.py', 'test_token_monitor_packaging.py'):
            (self.root / 'tests' / name).write_text(logger)
        for name in ('test-parsers.sh', 'check-memory-risks.sh'):
            self.write_executable(self.root / 'scripts' / name, '#!/usr/bin/env bash\nexit 0\n')
        for name in ('make', 'uname', 'ditto', 'hdiutil', 'lipo', 'codesign', 'git', 'gh'):
            self.write_executable(self.root / 'mockbin' / name, MOCK_TOOL)
        self.build = self.root / 'candidate build'
        self.dist = self.root / 'release output'
        for folder in (self.build, self.dist):
            folder.mkdir()
            (folder / 'keep-user-file.txt').write_text('must survive\n')
        self.env = dict(os.environ)
        for key in tuple(self.env):
            if key.startswith(('TOKEN_MONITOR_', 'RELEASE_', 'FAIL_', 'BAD_', 'MAKE')) or key in ('MFLAGS', 'DIST_DIR', 'BUILD_DIR', 'ALLOW_EXISTING_RELEASE', 'EXISTING_TAG', *EVIDENCE_KEYS):
                self.env.pop(key)
        self.env.update({'PATH': str(self.root / 'mockbin') + os.pathsep + os.environ['PATH'],
                         'RELEASE_FIXTURE_ROOT': str(self.root), 'BUILD_DIR': str(self.build),
                         'DIST_DIR': str(self.dist), 'TOKEN_MONITOR_CACHE': str(self.root / 'token cache'),
                         'TOKEN_MONITOR_RECEIPT_DIR': str(self.root / 'trusted receipts'),
                         'TOKEN_MONITOR_OFFLINE': '1', 'TOKEN_MONITOR_NODE_ARCHIVE': str(self.root / 'node archive.tar.gz')})
        self.add_runtime('arm64')
        self.write_docs()

    @staticmethod
    def write_executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def add_runtime(self, arch):
        app, dmg = self.root / f'official {arch}.app', self.root / f'official {arch}.dmg'
        app.mkdir(exist_ok=True)
        dmg.write_text('pinned input fixture')
        self.env[f'TOKEN_MONITOR_DESKTOP_RUNTIME_{arch.upper()}'] = str(app)
        self.env[f'TOKEN_MONITOR_DESKTOP_DMG_{arch.upper()}'] = str(dmg)

    def write_docs(self):
        (self.root / 'CHANGELOG.md').write_text(f'## AiGoodBro 2.2 · {RELEASE} - 2026-10-06（{VERSION} / {BUILD} 发布）\n')
        for filename in ('README.md', 'README.en.md'):
            (self.root / filename).write_text(f'# AiGoodBro 2.2\nCurrent release 2.2 · {RELEASE}, internal version {VERSION} ({BUILD}).\n')
        hashes = [hashlib.sha256(path.read_bytes()).hexdigest() for path in self.dist.glob('*.dmg')]
        self.notes.write_text(f'# AiGoodBro 2.2 ({VERSION})\nRelease name: {RELEASE}\n## Highlights\n- Fixture change.\n## Checksums\n' + '\n'.join(hashes) + '\n')

    @property
    def notes(self):
        return self.root / f'docs/release-notes-v{VERSION}.md'

    def events(self, tool=None):
        path = self.root / 'events.jsonl'
        items = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [item for item in items if tool is None or item['tool'] == tool]

    def run_wrapper(self, name, architectures='arm64', extra=None, version=VERSION, success=True):
        env = dict(self.env)
        if architectures is not None:
            env['RELEASE_ARCHITECTURES'] = architectures
        env.update(extra or {})
        result = subprocess.run(['bash', str(self.root / 'scripts' / name), version],
                                cwd=self.root, env=env, text=True, capture_output=True, timeout=20)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def package(self, architectures='arm64', **kwargs):
        return self.run_wrapper('build-release-artifacts.sh', architectures, **kwargs)

    def check(self, architectures='arm64', **kwargs):
        return self.run_wrapper('check-release-ready.sh', architectures, **kwargs)

    def assert_evidence_blocked(self, extra, diagnostic):
        before = {tool: self.events(tool) for tool in ('make', 'hdiutil')}
        result = self.package(extra=extra, success=False)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn(diagnostic, result.stderr)
        for tool, events in before.items():
            self.assertEqual(self.events(tool), events)

    def test_repeated_packages_keep_old_evidence_and_identical_payload_trees(self):
        evidence = self.root / '.local-artifacts/theme-upstream-1004v1'
        evidence.mkdir(parents=True)
        names = ('host-broken-pipe-ci.json', 'app-updates-ci.log', 'app-updates-ci.json',
                 'reset-auto-host.log', 'reset-auto-host.json',
                 'reset-auto-124-host.log', 'reset-auto-124-host.json')
        legacy = {name: ('retained ' + name).encode() for name in names}
        for name, content in legacy.items():
            (evidence / name).write_bytes(content)

        def inventory(folder):
            return {str(path.relative_to(folder)):
                    ('link', os.readlink(path)) if path.is_symlink() else
                    ('file', path.read_bytes(), path.stat().st_mode & 0o777) if path.is_file() else ('directory',)
                    for path in folder.rglob('*')}

        self.package()
        first = next(event['env'] for event in self.events('make') if event['args'][0] == 'test')
        app = self.build / 'AiGoodBro.app'
        first_app = inventory(app)
        dmg = self.dist / f'AiGoodBro-{VERSION}-mac-arm64.dmg'
        first_payload = inventory(Path(json.loads(dmg.read_text())['snapshot']))
        self.package()
        runs = [event['env'] for event in self.events('make') if event['args'][0] == 'test']
        self.assertEqual(len(runs), 2)
        self.assertEqual(len({run[key] for run in runs for key in EVIDENCE_KEYS}), 6)
        self.assertEqual(inventory(app), first_app)
        self.assertEqual(inventory(Path(json.loads(dmg.read_text())['snapshot'])), first_payload)
        for run in (first, runs[-1]):
            for key in EVIDENCE_KEYS:
                self.assertRegex(run[key], r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')
                suffixes = ('json',) if key == EVIDENCE_KEYS[0] else ('log', 'json')
                for suffix in suffixes:
                    self.assertTrue((evidence / (run[key] + '.' + suffix)).is_file())
        self.assertEqual({name: (evidence / name).read_bytes() for name in names}, legacy)

    def test_explicit_evidence_prefixes_are_forwarded_verbatim(self):
        explicit = dict(zip(EVIDENCE_KEYS, ('caller-host_1', 'caller-update_2', 'caller-reset_3')))
        self.package(extra=explicit)
        event = next(event for event in self.events('make') if event['args'][0] == 'test')
        self.assertEqual({key: event['env'][key] for key in EVIDENCE_KEYS}, explicit)

    def test_late_reset_evidence_is_never_overwritten_and_blocks_packaging(self):
        evidence = self.root / '.local-artifacts/theme-upstream-1004v1'
        for suffix in ('log', 'json'):
            for kind in ('file', 'directory', 'symlink'):
                prefix = f'late-{suffix}-{kind}'
                target = evidence / (prefix + '.' + suffix)
                with self.subTest(suffix=suffix, kind=kind):
                    result = self.package(extra={'RESET_AUTO_EVIDENCE_PREFIX': prefix,
                                                 'LATE_RESET_EVIDENCE_SUFFIX': suffix,
                                                 'LATE_RESET_EVIDENCE_KIND': kind}, success=False)
                    self.assertIn('FileExistsError', result.stderr)
                    self.assertEqual(self.events('make')[-1]['args'][0], 'test')
                    self.assertEqual(self.events('hdiutil'), [])
                    if kind == 'file':
                        self.assertEqual(target.read_bytes(), b'late synthetic evidence must survive')
                    elif kind == 'directory':
                        self.assertTrue(target.is_dir())
                    else:
                        self.assertTrue(target.is_symlink())
                        self.assertEqual(os.readlink(target), str(evidence / 'absent-late-target'))
                        self.assertFalse((evidence / 'absent-late-target').exists())
                    # A JSON collision must retain the current attempt's log for diagnosis.
                    if suffix == 'json':
                        self.assertEqual((evidence / (prefix + '.log')).read_text(),
                                         'synthetic reset evidence\n')

    def use_system_make_for_evidence(self):
        delegate = self.root / 'make-delegate/make'
        delegate.parent.mkdir()
        self.write_executable(delegate, MOCK_TOOL)
        fixture = self.root / 'evidence-fixture.mk'
        fixture.write_text('export ' + ' '.join(EVIDENCE_KEYS) + '\n'
                           '.PHONY: memory-risk-check test-macos-compatibility test build\n'
                           'memory-risk-check test-macos-compatibility test build:\n'
                           '\t@' + shlex.quote(str(delegate)) + ' "$@"\n')
        self.write_executable(self.root / 'mockbin/make', '#!/usr/bin/env python3\n'
                              'import os, sys\n'
                              f'os.execv({REAL_MAKE!r}, [{REAL_MAKE!r}, "--no-print-directory", '
                              f'"-f", {str(fixture)!r}, *sys.argv[1:]])\n')

    def test_system_make_cannot_override_preflight_prefixes_from_makeflags(self):
        self.use_system_make_for_evidence()
        evidence = self.root / '.local-artifacts/theme-upstream-1004v1'
        evidence.mkdir(parents=True)
        explicit = dict(zip(EVIDENCE_KEYS, ('checked-host', 'checked-update', 'checked-reset')))
        inherited = dict(zip(EVIDENCE_KEYS, ('unchecked-host', 'unchecked-update', 'unchecked-reset')))
        old = {}
        for key, prefix in inherited.items():
            for suffix in (('json',) if key == EVIDENCE_KEYS[0] else ('log', 'json')):
                path = evidence / (prefix + '.' + suffix)
                path.write_bytes(b'old unchecked synthetic evidence')
                old[path.name] = path.read_bytes()
        self.package(extra={**explicit, 'MAKEFLAGS': '-- ' + ' '.join(
            f'{key}={value}' for key, value in inherited.items())})
        actual = next(event['env'] for event in self.events('make') if event['args'][0] == 'test')
        self.assertEqual({key: actual[key] for key in EVIDENCE_KEYS}, explicit)
        self.assertEqual({name: (evidence / name).read_bytes() for name in old}, old)
        for key, prefix in explicit.items():
            for suffix in (('json',) if key == EVIDENCE_KEYS[0] else ('log', 'json')):
                self.assertTrue((evidence / (prefix + '.' + suffix)).is_file())

    def test_invalid_or_reserved_evidence_prefixes_fail_before_build(self):
        for key in EVIDENCE_KEYS:
            for invalid in ('', '../escape', 'nested/name', 'name.log', 'x' * 129, 'bad\nname'):
                with self.subTest(key=key, invalid=invalid):
                    self.assert_evidence_blocked({key: invalid}, 'must be a safe basename')
        self.assert_evidence_blocked({'RESET_AUTO_EVIDENCE_PREFIX': 'reset-auto-124-host'},
                                     'must not replace accepted 124 evidence')

    def test_existing_evidence_files_directories_and_dangling_links_are_preserved(self):
        evidence = self.root / '.local-artifacts/theme-upstream-1004v1'
        evidence.mkdir(parents=True)
        for key in EVIDENCE_KEYS:
            for suffix in (('json',) if key == EVIDENCE_KEYS[0] else ('log', 'json')):
                for kind in ('file', 'directory', 'symlink'):
                    prefix = key.lower() + '-' + suffix + '-' + kind
                    target = evidence / (prefix + '.' + suffix)
                    if kind == 'file':
                        target.write_bytes(b'accepted evidence must survive')
                    elif kind == 'directory':
                        target.mkdir()
                    else:
                        target.symlink_to(evidence / 'absent-target')
                    with self.subTest(key=key, suffix=suffix, kind=kind):
                        self.assert_evidence_blocked({key: prefix}, 'Evidence target already exists')
                        if kind == 'file':
                            self.assertEqual(target.read_bytes(), b'accepted evidence must survive')
                        elif kind == 'directory':
                            self.assertTrue(target.is_dir())
                        else:
                            self.assertTrue(target.is_symlink())
                            self.assertEqual(os.readlink(target), str(evidence / 'absent-target'))

    def test_test_interfaces_cannot_share_evidence_targets(self):
        for left, right in ((0, 1), (0, 2), (1, 2)):
            prefix = f'same-target-{left}-{right}'
            for right_prefix in (prefix, prefix.upper()):
                with self.subTest(left=left, right=right, right_prefix=right_prefix):
                    self.assert_evidence_blocked({EVIDENCE_KEYS[left]: prefix,
                                                 EVIDENCE_KEYS[right]: right_prefix},
                                                'Test interfaces share an evidence target')

    def test_evidence_parent_symlinks_fail_before_build(self):
        outside = self.root / 'outside evidence'
        outside.mkdir()
        sentinel = outside / 'retained.txt'
        sentinel.write_bytes(b'unchanged outside record')
        parent = self.root / '.local-artifacts'
        for target in (parent, parent / 'theme-upstream-1004v1'):
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(outside, target_is_directory=True)
            with self.subTest(target=target.name):
                self.assert_evidence_blocked({}, 'Evidence directory is not a real directory')
                self.assertEqual(sentinel.read_bytes(), b'unchanged outside record')
                self.assertEqual(list(outside.iterdir()), [sentinel])
            target.unlink()

    def test_test_gate_exit_code_is_preserved_and_stops_packaging(self):
        result = self.package(extra={'FAIL_TEST_GATE': '1'}, success=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn('mock test gate blocked', result.stderr)
        self.assertEqual(self.events('make')[-1]['args'][0], 'test')
        self.assertEqual(self.events('hdiutil'), [])
        self.assertEqual(list(self.dist.glob('*.dmg')), [])

    def test_arm64_reuses_current_optimized_test_build_and_preserves_other_files(self):
        self.package()
        make = self.events('make')
        self.assertEqual([entry['args'][0] for entry in make], ['memory-risk-check', 'test-macos-compatibility', 'test'])
        self.assertIn(f'BUILD_DIR={self.build}', make[-1]['args'])
        self.assertIn('SWIFT_OPTIMIZATION=-O', make[-1]['args'])
        self.assertEqual(make[-1]['env']['TOKEN_MONITOR_CACHE'], self.env['TOKEN_MONITOR_CACHE'])
        self.assertEqual(make[-1]['env']['TOKEN_MONITOR_RECEIPT_DIR'], self.env['TOKEN_MONITOR_RECEIPT_DIR'])
        self.assertEqual(len(list(self.dist.glob('*.dmg'))), 1)
        checksum = next(self.dist.glob('*.sha256')).read_text().split()
        self.assertEqual(checksum[1], f'AiGoodBro-{VERSION}-mac-arm64.dmg')
        self.assertTrue((self.build / 'keep-user-file.txt').is_file())
        self.assertTrue((self.dist / 'keep-user-file.txt').is_file())
        self.assertEqual(len(self.events('prepare-token-monitor-desktop.py')), 1)
        self.assertEqual(len(self.events('prepare-token-monitor-resources.py')), 1)
        desktop_args = self.events('prepare-token-monitor-desktop.py')[0]['args']
        engine_args = self.events('prepare-token-monitor-resources.py')[0]['args']
        desktop_receipt = str(Path(self.env['TOKEN_MONITOR_RECEIPT_DIR']) / 'token-monitor-desktop-arm64.json')
        self.assertEqual(desktop_args[desktop_args.index('--trusted-receipt') + 1], desktop_receipt)
        self.assertEqual(engine_args[engine_args.index('--desktop-trusted-receipt') + 1], desktop_receipt)
        self.write_docs()
        self.check()
        self.assertTrue(any(event['args'][:3] == ['--verify', '--deep', '--strict'] for event in self.events('codesign')))

    def test_default_still_builds_and_checks_both_architectures(self):
        self.add_runtime('x86_64')
        self.package(None)
        self.assertEqual([event['args'][0] for event in self.events('make')],
                         ['memory-risk-check', 'test-macos-compatibility', 'test', 'build'])
        self.assertIn('TARGET_TRIPLE=x86_64-apple-macos13.0', self.events('make')[-1]['args'])
        self.assertEqual(len(list(self.dist.glob('*.dmg'))), 2)
        for tool, flag in (('prepare-token-monitor-desktop.py', '--trusted-receipt'),
                           ('prepare-token-monitor-resources.py', '--desktop-trusted-receipt')):
            for event in self.events(tool):
                args = event['args']
                arch = args[args.index('--arch') + 1]
                expected = Path(self.env['TOKEN_MONITOR_RECEIPT_DIR']) / f'token-monitor-desktop-{arch}.json'
                self.assertEqual(args[args.index(flag) + 1], str(expected))
        self.write_docs()
        self.check(None)

    def test_default_requires_intel_input_but_arm64_does_not(self):
        result = self.package(None, success=False)
        self.assertIn('x86_64 desktop runtime DMG is missing', result.stderr)
        self.assertEqual(self.events('make'), [])

    def test_architecture_ranges_fail_before_any_gate_or_build(self):
        for name in ('build-release-artifacts.sh', 'check-release-ready.sh'):
            for invalid in ('', '   ', 'arm64 arm64', 'arm64 x86_64 arm64', 'amd64', 'arm64,x86_64', 'arm64\nx86_64'):
                with self.subTest(name=name, invalid=invalid):
                    self.run_wrapper(name, invalid, success=False)
        self.assertEqual(self.events('make'), [])

    def test_unsafe_output_paths_fail_before_build_or_cleanup(self):
        for key in ('BUILD_DIR', 'DIST_DIR'):
            for invalid in ('', '.', '/', str(self.root / 'Resources'), str(self.root / 'existing.app')):
                with self.subTest(key=key, invalid=invalid):
                    self.package(extra={key: invalid}, success=False)
        self.assertEqual(self.events('make'), [])

    def test_requested_and_built_metadata_mismatch_fail(self):
        for name in ('build-release-artifacts.sh', 'check-release-ready.sh'):
            self.run_wrapper(name, version='9.6.81', success=False)
        self.assertEqual(self.events('make'), [])
        result = self.package(extra={'BAD_BUILD_METADATA': '1'}, success=False)
        self.assertIn('version/build/name mismatch', result.stderr)
        self.assertEqual(list(self.dist.glob('*.dmg')), [])

    def test_memory_gate_is_blocking(self):
        for name in ('build-release-artifacts.sh', 'check-release-ready.sh'):
            self.run_wrapper(name, extra={'FAIL_MEMORY_GATE': '1'}, success=False)
        self.assertEqual([event['args'][0] for event in self.events('make')], ['memory-risk-check'] * 2)
        self.assertEqual(list(self.dist.glob('*.dmg')), [])

    def test_missing_checksum_and_note_hash_fail(self):
        self.package()
        checksum = next(self.dist.glob('*.sha256'))
        checksum.unlink()
        self.write_docs()
        result = self.check(success=False)
        self.assertIn('Missing arm64 release assets', result.stderr)
        self.package()
        self.notes.write_text('## Highlights\n- Fixture change without checksum.\n')
        result = self.check(success=False)
        self.assertIn('checksum is missing', result.stderr)

    def test_checksum_cannot_reference_another_asset_or_path(self):
        self.package()
        self.write_docs()
        checksum = next(self.dist.glob('*.sha256'))
        original = checksum.read_text()
        asset = next(self.dist.glob('*.dmg'))
        for invalid in (original.replace(asset.name, str(asset)),
                        original.replace(asset.name, 'another.dmg'), original + original,
                        '0' * 64 + '  ' + asset.name + '\n'):
            with self.subTest(invalid=invalid):
                checksum.write_text(invalid)
                self.check(success=False)

    def test_stale_public_docs_and_placeholders_fail(self):
        self.package()
        self.write_docs()
        for filename in ('README.md', 'README.en.md', 'CHANGELOG.md'):
            path = self.root / filename
            original = path.read_text()
            path.write_text(original.replace(BUILD, '129').replace(VERSION, '9.6.79'))
            self.check(success=False)
            path.write_text(original)
        self.notes.write_text(self.notes.read_text() + 'SHA256_PLACEHOLDER\n')
        self.check(success=False)

    def test_mounted_version_and_signature_failures_cleanup_mount(self):
        self.package()
        self.write_docs()
        for key in ('BAD_MOUNT_METADATA', 'FAIL_CODESIGN'):
            start = len(self.events('hdiutil'))
            self.check(extra={key: '1'}, success=False)
            events = self.events('hdiutil')[start:]
            self.assertEqual(events[-1]['args'][0], 'detach')
            self.assertFalse(Path(events[-1]['args'][-1]).exists())

    def test_existing_local_remote_and_github_release_fail(self):
        self.package()
        self.write_docs()
        for provider in ('rev-parse', 'ls-remote', 'gh'):
            with self.subTest(provider=provider):
                result = self.check(extra={'EXISTING_TAG': provider}, success=False)
                self.assertIn('already exists', result.stderr)

    def test_make_wrappers_forward_explicit_paths_and_token_configuration(self):
        recorder = '#!/usr/bin/env python3\nimport json, os, pathlib\npathlib.Path("wrapper-env.json").write_text(json.dumps(dict(os.environ)))\n'
        for name in ('build-release-artifacts.sh', 'check-release-ready.sh'):
            self.write_executable(self.root / 'scripts' / name, recorder)
        assignments = {**{key: value for key, value in self.env.items() if key.startswith('TOKEN_MONITOR_')},
                       'RELEASE_ARCHITECTURES': 'arm64', 'BUILD_DIR': str(self.build), 'DIST_DIR': str(self.dist)}
        for target in ('release-package', 'release-check'):
            result = subprocess.run([REAL_MAKE, '--no-print-directory', target, f'VERSION={VERSION}',
                                     *[f'{key}={value}' for key, value in assignments.items()]],
                                    cwd=self.root, env=self.env, text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            recorded = json.loads((self.root / 'wrapper-env.json').read_text())
            for key in ('BUILD_DIR', 'DIST_DIR', 'RELEASE_ARCHITECTURES'):
                self.assertEqual(recorded[key], assignments[key])
            if target == 'release-package':
                for key in assignments:
                    self.assertEqual(recorded[key], assignments[key])


if __name__ == '__main__':
    unittest.main()
