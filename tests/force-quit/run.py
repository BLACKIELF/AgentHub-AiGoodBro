#!/usr/bin/env python3
"""Exercise the actual AppLifecycle quit method with isolated surrounding stubs.
All build outputs go into FORCE_QUIT_EVIDENCE; no real app is launched.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import time

root = Path(__file__).resolve().parents[2]
evidence = Path(os.environ['FORCE_QUIT_EVIDENCE']).resolve()
evidence.mkdir(parents=True, exist_ok=True)
tmp = evidence / 'tmp'
tmp.mkdir(exist_ok=True)
cache = evidence / 'module-cache'
cache.mkdir(exist_ok=True)
source = root / 'Sources/CodexUsageWidget/App/AppLifecycle.swift'
fixture = root / 'tests/force-quit/LifecycleFixture.swift'
text = source.read_text()
watchdog = text[text.index('private enum ConfirmedTerminationWatchdog {'):text.index('\nprivate func fourCharCode')]
method = text[text.index('    func applicationShouldTerminate('):text.index('    func applicationWillTerminate(')]
assert watchdog.count('Darwin._exit(0)') == 1
assert method.count('ConfirmedTerminationWatchdog.arm()') == 1
code = fixture.read_text()
assert code.count('// __PRODUCTION_WATCHDOG__') == 1
assert code.count('// __PRODUCTION_TERMINATION__') == 1
code = code.replace('// __PRODUCTION_WATCHDOG__', watchdog).replace('// __PRODUCTION_TERMINATION__', method)
generated = evidence / 'Lifecycle-extracted.swift'
generated.write_text(code)
exe = evidence / 'lifecycle-fixture'
env = {**os.environ, 'TMPDIR': str(tmp), 'CLANG_MODULE_CACHE_PATH': str(cache)}
compiler = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(cache), str(generated), '-o', str(exe)]
subprocess.run(compiler, cwd=root, env=env, check=True, timeout=120)
results = []
for mode in ['guard', 'normal', 'confirm', 'modal', 'cancel', 'blocked', 'blocked-login', 'repeat-deadline']:
    began = time.monotonic()
    run = subprocess.run([str(exe), mode], cwd=evidence, env=env, capture_output=True, text=True, timeout=10)
    seconds = time.monotonic() - began
    output = run.stdout + run.stderr
    marker = {'guard': 'PASS existing active Codex launch guard is preserved',
              'normal': 'PASS unconfirmed normal termination keeps original cleanup',
              'confirm': 'PASS confirmation bypasses failed cleanup and does not wait for login',
              'modal': 'PASS windowless confirmation takes the same forced exit path',
              'cancel': 'PASS cancellation keeps helpers running and arms no watchdog',
              'blocked': 'REPLY_BLOCKED_MAIN', 'blocked-login': 'LOGIN_BLOCKED_AFTER_OWNED_HELPERS',
              'repeat-deadline': 'REPEAT_2S_BLOCKED_MAIN'}[mode]
    ok = run.returncode == 0 and marker in output
    if mode in ('blocked', 'blocked-login', 'repeat-deadline'):
        ok = ok and 4.5 <= seconds < 7
    if mode == 'cancel':
        ok = ok and seconds >= 5
    results.append({'mode': mode, 'returncode': run.returncode, 'elapsed_seconds': round(seconds, 3), 'ok': ok, 'output': output})
    print(('PASS' if ok else 'FAIL'), mode, 'elapsed=', round(seconds, 3), flush=True)
    if not ok:
        print(output, flush=True)
        break
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
receipt = {'source_sha256': sha(source), 'fixture_sha256': sha(fixture), 'runner_sha256': sha(Path(__file__)),
           'extracted_sha256': sha(generated), 'binary_sha256': sha(exe), 'results': results,
           'scope': 'actual extracted production termination method and watchdog, fake AppKit and stores'}
(evidence / 'lifecycle-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
if len(results) != 8 or not all(r['ok'] for r in results):
    raise SystemExit(1)
