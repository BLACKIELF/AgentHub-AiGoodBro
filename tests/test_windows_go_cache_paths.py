"""Keep every Windows Go helper on the task volume before setup-go runs."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def job(text, name):
    match = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [\w-]+:\n|\Z)', text, re.M | re.S)
    if not match:
        raise AssertionError('missing Windows job')
    return match.group(1)


def verify(block):
    env, steps = block.split('    steps:\n', 1)
    for key, leaf in [('GOMODCACHE', 'mod'), ('GOCACHE', 'build'), ('GOTMPDIR', 'tmp')]:
        expected = '      ' + key + ': ${{ github.workspace }}/.local-artifacts/go/' + leaf
        if env.splitlines().count(expected) != 1 or re.search(r'\b' + key + r'\s*:', steps):
            raise AssertionError('Go path must be the job-wide task path')
    init = steps.index('- name: Initialize task-owned Go directories')
    setup = steps.index('- uses: actions/setup-go@')
    if not init < setup or 'foreach ($path in @($env:GOMODCACHE, $env:GOCACHE, $env:GOTMPDIR))' not in steps[init:setup]:
        raise AssertionError('Go directories must exist before the first Go action')
    if 'New-Item -ItemType Directory -Force -Path $path | Out-Null' not in steps[init:setup]:
        raise AssertionError('Go directory initialization missing')
    if 'SPACE-RECEIPT.json' not in steps:
        raise AssertionError('failed space checks must preserve their evidence')


class WindowsGoCachePaths(unittest.TestCase):
    def test_all_three_windows_go_jobs_share_their_task_volume(self):
        for filename, names in [('.github/workflows/ci.yml', ['windows-rust-format', 'windows-native-visual']),
                                ('.github/workflows/release-windows.yml', ['windows'])]:
            text = (ROOT / filename).read_text(encoding='utf-8')
            for name in names:
                with self.subTest(job=name):
                    verify(job(text, name))
        self.assertNotIn('GOMODCACHE:', job((ROOT / '.github/workflows/ci.yml').read_text(encoding='utf-8'), 'macos'))

    def test_missing_cache_wrong_volume_late_init_and_step_override_are_rejected(self):
        original = job((ROOT / '.github/workflows/ci.yml').read_text(encoding='utf-8'), 'windows-rust-format')
        for changed in [original.replace('      GOCACHE:', '      OMITTED:'),
                        original.replace('${{ github.workspace }}/.local-artifacts/go/mod', 'C:/Users/runneradmin/go/pkg/mod'),
                        original.replace('- name: Initialize task-owned Go directories', '- name: Removed initializer'),
                        original + '\n        GOCACHE: C:/other\n',
                        original.replace('SPACE-RECEIPT.json', 'missing.json')]:
            with self.assertRaises((AssertionError, ValueError)):
                verify(changed)


if __name__ == '__main__':
    unittest.main()
