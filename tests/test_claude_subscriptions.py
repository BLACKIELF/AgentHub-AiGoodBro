#!/usr/bin/env python3
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
class ClaudeSubscriptionTests(unittest.TestCase):
    def test_real_service_with_mock_keychain_http_and_synthetic_home(self):
        sources = ['Domain/LocalCLIAccount.swift', 'Domain/TokenMonitorEngineModels.swift',
                   'Services/TokenMonitorEngine.swift','Services/TokenMonitorLocalCLIQuotaReader.swift',
                   'Services/DispatchParticipationSync.swift','Services/LocalCLIQuotaReader.swift',
                   'Services/LocalCLIQuotaRefresh.swift','Services/CCSwitchClaudeRelay.swift',
                   'Services/BoundedLocalProcess.swift','Services/ClaudeSubscriptionService.swift']
        with tempfile.TemporaryDirectory(prefix='claude-subscription-test-') as directory:
            sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
            binary = Path(directory)/'fixture'
            result = subprocess.run(['xcrun','swiftc','-target',f'{platform.machine()}-apple-macos13.0','-sdk',sdk,
                '-module-cache-path',str(Path(directory)/'cache'),*[str(ROOT/'Sources/CodexUsageWidget'/s) for s in sources],
                str(ROOT/'tests/ClaudeSubscriptionFixture.swift'),'-o',str(binary)],capture_output=True,text=True,timeout=180)
            self.assertEqual(result.returncode,0,result.stderr)
            result = subprocess.run([str(binary)],capture_output=True,text=True,timeout=45,
                env={'PATH':os.environ.get('PATH','/usr/bin:/bin')})
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('PASS claude-subscription fixture',result.stdout)
if __name__ == '__main__': unittest.main()
