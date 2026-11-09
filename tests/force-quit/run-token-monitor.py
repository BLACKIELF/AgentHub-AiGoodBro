#!/usr/bin/env python3
"""Compile the real TokenMonitor controller against isolated synthetic helpers."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import uuid

root = Path(__file__).resolve().parents[2]
evidence = Path(os.environ['FORCE_QUIT_EVIDENCE']).resolve()
evidence.mkdir(parents=True, exist_ok=True)
tmp = evidence / 'tmp'
tmp.mkdir(exist_ok=True)
cache = evidence / 'module-cache'
cache.mkdir(exist_ok=True)
runroot = evidence / f'token-fixture-run-{uuid.uuid4().hex}'
runroot.mkdir(exist_ok=False)
sources = [root/'Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift',
           root/'Sources/CodexUsageWidget/Services/TokenMonitorDesktopController.swift',
           root/'tests/force-quit/TokenMonitorFixture.swift']
exe = evidence/'token-fixture'
env = {**os.environ, 'TMPDIR': str(tmp), 'CLANG_MODULE_CACHE_PATH': str(cache), 'FORCE_QUIT_FIXTURE_ROOT': str(runroot)}
subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(cache),
                *map(str,sources),'-o',str(exe)],cwd=root,env=env,check=True,timeout=120)
run = subprocess.run([str(exe)],cwd=root,env=env,capture_output=True,text=True,timeout=25)
output = run.stdout + run.stderr
print(output,end='')
checks = ['PASS no child:', 'PASS starting child exits', 'PASS ready child is killed']
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
receipt = {'sources': {str(p.relative_to(root)): sha(p) for p in sources}, 'runner_sha256': sha(Path(__file__)),
           'binary_sha256': sha(exe), 'returncode': run.returncode, 'output': output,
           'scope': 'real TokenMonitorDesktopController with private synthetic helper and unrelated sleep child'}
(evidence/'token-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
if run.returncode != 0 or any(marker not in output for marker in checks):
    raise SystemExit(1)
