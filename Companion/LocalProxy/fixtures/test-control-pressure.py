#!/usr/bin/env python3
"""Bounded real Swift Unix IPC pressure; only synthetic IDs and private temp files."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--bridge-source', type=Path)
parser.add_argument('--expect-legacy-disconnect', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='lp-pressure-', dir='/private/tmp') as temporary:
    folder = Path(temporary)
    os.chmod(folder, 0o700)
    source = (args.bridge_source or ROOT/'Sources/CodexUsageWidget/Services/LocalProxyBridge.swift').read_text()
    (folder/'Bridge.swift').write_text(source[:source.index('\nenum LocalProxyCredentialReader')])
    domain = (ROOT/'Sources/CodexUsageWidget/Domain/LocalProxyQueue.swift').read_text()
    (folder/'Domain.swift').write_text('import Foundation\n'+domain[domain.index('enum LocalProxyFailure:'):domain.index('enum LocalProxyRouting {')])
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(folder/'Bridge.swift'),str(folder/'Domain.swift'),str(Path(__file__).with_name('BridgeFixture.swift')),'-o',str(folder/'fixture')],check=True)
    if not args.expect_legacy_disconnect:
        # Build before any client starts its bounded wait. Cold compilation
        # must not consume the held admission clients' eight-second budget.
        control_test = folder/'control-tests'
        subprocess.run(['go','test','-mod=readonly','-c','-o',str(control_test),'.'],
                       cwd=ROOT/'Companion/LocalProxy',check=True,timeout=90)
    path = folder/'b.sock'
    child = subprocess.Popen([str(folder/'fixture')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             env={**os.environ,'FIXTURE_SOCKET':str(path),'FIXTURE_MODE':'pressure'})
    events = queue.Queue()
    def collect():
        for line in child.stdout: events.put(json.loads(line))
    threading.Thread(target=collect, daemon=True).start()
    request_id = str(uuid.uuid4())
    def call(command, profile):
        payload = dict(schemaVersion=1,runID='cross-language',key='k'*32,command=command,requestID=request_id,profileID=profile)
        if command in ('heartbeat','release'): payload['leaseID']='lease-'+profile
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
            client.settimeout(8)
            client.connect(str(path))
            try:
                client.sendall(json.dumps(payload).encode()+b'\n')
                line = client.makefile('rb').readline()
            except (BrokenPipeError,ConnectionResetError): return {'transport':'closed'}
            return json.loads(line) if line else {'transport':'closed'}
    try:
        assert events.get(timeout=10)['event']=='ready'
        assert call('acquire','maintenance')['ok']
        events.get(timeout=2)
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
            held = [executor.submit(call,'acquire',str(i)) for i in range(8)]
            for _ in range(8): assert events.get(timeout=5)['command']=='acquire'
            try:
                refused = list(executor.map(lambda _: call('acquire','overflow'), range(32)))
                if args.expect_legacy_disconnect:
                    assert all(r.get('transport')=='closed' for r in refused), refused
                    print('REPRODUCED: 32 overflow requests closed without a no-mutation reply',flush=True)
                else:
                    assert all(r.get('error')=='control_busy' and not r.get('ok') for r in refused), refused
                    start=time.monotonic()
                    assert call('heartbeat','maintenance')['ok']
                    assert call('release','maintenance')['ok']
                    assert time.monotonic()-start < 2
                    print('PASS: 32 overflow replies explicitly busy; heartbeat/release complete while all 8 admission handlers wait',flush=True)
                    subprocess.run([str(control_test),'-test.run=^TestRealSwiftControlPressure$','-test.count=1','-test.timeout=20s'],
                                   cwd=ROOT/'Companion/LocalProxy',check=True,timeout=45,
                                   env={**os.environ,'AIGOODBRO_CONTROL_PRESSURE_SOCKET':str(path),'AIGOODBRO_CONTROL_PRESSURE_GATE':str(folder/'release-gate')})
                    print('PASS: 32 real Go callers retry the Swift busy reply, acquire and release exactly once',flush=True)
            finally: (folder/'release-gate').touch()
            assert all(f.result(timeout=8)['ok'] for f in held)
        if args.expect_legacy_disconnect: assert call('release','maintenance')['ok']
        for i in range(8): assert call('release',str(i))['ok']
        child.stdin.close(); child.wait(timeout=10)
        captured=[]
        while not events.empty(): captured.append(events.get())
        assert child.returncode==0 and not child.stderr.read()
        assert captured[-1]['event']=='stopped' and captured[-1]['held']==0, captured
        assert not any(e.get('profileID')=='overflow' for e in captured), captured
        print('PASS: no overflow handler executed, no lease leaked; fixture exited cleanly',flush=True)
    finally:
        if child.poll() is None: child.kill();child.wait()
