"""Use Git's actual text filters to test package/upgrade source-byte parity."""
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def checkout_options(job):
    text = (ROOT / '.github/workflows/release-windows.yml').read_text()
    block = re.search(r'^  ' + re.escape(job) + r':\n(.*?)(?=^  [a-z][a-z-]*:|\Z)', text, re.M | re.S).group(1)
    before_checkout = block.split('- uses: actions/checkout@v4', 1)[0]
    values = dict(re.findall(r'^      (GIT_CONFIG_[A-Z_0-9]+):\s*"?([^"\n]+)"?$', before_checkout, re.M))
    count = int(values['GIT_CONFIG_COUNT'])
    return [piece for i in range(count) for piece in ('-c', values['GIT_CONFIG_KEY_'+str(i)]+'='+values['GIT_CONFIG_VALUE_'+str(i)])]


class CheckoutParityTests(unittest.TestCase):
    def test_real_git_filters_preserve_all_seven_resource_bytes(self):
        producer = checkout_options('windows')
        upgrade = checkout_options('installer-upgrade')
        self.assertEqual(producer, upgrade)
        script = (ROOT/'windows/scripts/MsiEncoding.ps1').read_text()
        paths = re.findall(r"'skill-library/([^']+)'", script.split('function Read-MsiCodepageExport')[0])
        self.assertEqual(len(paths), 7)
        env = os.environ.copy()
        # Test exactly the extracted command-scoped policy, not inherited runner policy.
        for key in list(env):
            if key.startswith('GIT_CONFIG_'): del env[key]
        for path in paths:
            with self.subTest(resource=path):
                obj = 'HEAD:Resources/SkillLibrary/'+path
                def git(*args):
                    return subprocess.check_output(['git', *args], cwd=ROOT, env=env)
                blob = git('show', obj)
                old_windows = git('-c', 'core.autocrlf=true', '-c', 'core.eol=crlf', 'cat-file', '--filters', obj)
                self.assertNotEqual(len(old_windows), len(blob))
                self.assertEqual(old_windows, blob.replace(b'\n', b'\r\n'))
                self.assertEqual(git(*producer, 'cat-file', '--filters', obj), blob)
                self.assertEqual(git(*upgrade, 'cat-file', '--filters', obj), blob)


if __name__ == '__main__': unittest.main()
