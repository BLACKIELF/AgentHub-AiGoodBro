#!/usr/bin/env python3
"""Actual Swift bridge and Go processes; generated synthetic credentials only."""
import argparse, http.client, json, os, pathlib, queue, socket as unix_socket, subprocess, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODULE = pathlib.Path(__file__).resolve().parents[1]
ROOT = MODULE.parents[1]

def collect_events(process):
    # The production busy wait emits repeated state events. Drain continuously
    # so a full diagnostic pipe cannot block the real Swift handler under test.
    process.fixture_events = queue.Queue()
    def read():
        for value in process.stdout:
            process.fixture_events.put(value)
    process.fixture_reader = threading.Thread(target=read, daemon=True)
    process.fixture_reader.start()
    return process

def line(process):
    return json.loads(process.fixture_events.get(timeout=15))

def stop(process):
    process.stdin.close()
    process.wait(timeout=15)
    assert process.returncode == 0, 'fixture failed'
    process.fixture_reader.join(timeout=2)
    assert not process.fixture_reader.is_alive(), 'fixture output did not close'
    data = []
    while not process.fixture_events.empty():
        data.append(json.loads(process.fixture_events.get_nowait()))
    assert not process.stderr.read(), 'unexpected stderr'
    return data

def request(port, key, body=None, timeout=10):
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=timeout)
    client.request('GET' if body is None else 'POST', '/v1/models' if body is None else '/v1/responses',
        body=None if body is None else json.dumps(body), headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'})
    response = client.getresponse(); result = (response.status, response.read()); client.close(); return result

class Upstream(BaseHTTPRequestHandler):
    calls = []
    def log_message(self, *_): pass
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        account = self.headers['Authorization'].removeprefix('Bearer fixture-')
        self.calls.append(account)
        assert self.headers['Chatgpt-Account-Id'] == 'fixture-account-'+account
        if account == 'A':
            import time
            body=json.dumps({'error':{'type':'usage_limit_reached','message':'fixture limit','resets_at':int(time.time())+120}}).encode()
            self.send_response(429);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
        event={'type':'response.completed','response':{'id':'resp_fixture','object':'response','status':'completed','model':'fixture-model','output':[{'type':'message','role':'assistant','content':[{'type':'output_text','text':'done-B'}]}]}}
        body=('event: response.completed\ndata: '+json.dumps(event)+'\n\n').encode()
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)


def run(helper=None):
    with tempfile.TemporaryDirectory(prefix='lp-cross-',dir='/private/tmp') as temporary:
        folder=pathlib.Path(temporary);os.chmod(folder,0o700)
        bridge_source=(ROOT/'Sources/CodexUsageWidget/Services/LocalProxyBridge.swift').read_text()
        bridge_source=bridge_source[:bridge_source.index('/// Reads under the same')]
        domain=(ROOT/'Sources/CodexUsageWidget/Domain/LocalProxyQueue.swift').read_text()
        # Compile only the shared IPC DTOs. UI rows and quota admission have
        # native application dependencies and are covered by host fixtures.
        domain='import Foundation\n'+domain[domain.index('enum LocalProxyFailure:'):domain.index('enum LocalProxyAdmission {')]
        (folder/'Bridge.swift').write_text(bridge_source)
        (folder/'Domain.swift').write_text(domain)
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(folder/'Bridge.swift'),str(folder/'Domain.swift'),str(MODULE/'fixtures/BridgeFixture.swift'),'-o',str(folder/'bridge')],check=True)
        if helper is None:
            helper=folder/'production-helper'
            subprocess.run(['go','build','-mod=readonly','-o',str(helper),'.'],cwd=MODULE,env={**os.environ,'CGO_ENABLED':'0'},check=True)
        test_helper=folder/'test-helper'
        subprocess.run(['go','test','-mod=readonly','-c','-o',str(test_helper),'.'],cwd=MODULE,check=True)
        upstream=ThreadingHTTPServer(('127.0.0.1',0),Upstream);threading.Thread(target=upstream.serve_forever,daemon=True).start()
        try:
            for mode in ('deny','allow','late'):
                Upstream.calls = []
                socket=folder/(mode+'.sock')
                bridge=collect_events(subprocess.Popen([str(folder/'bridge')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env={**os.environ,'FIXTURE_SOCKET':str(socket),'FIXTURE_MODE':mode}))
                assert line(bridge)['event']=='ready'
                env={**os.environ}
                executable=helper
                if mode=='allow':
                    executable=test_helper
                    env.update(AIGOODBRO_PROTOCOL_FIXTURE_CHILD='1',AIGOODBRO_FIXTURE_UPSTREAM=f'http://127.0.0.1:{upstream.server_port}')
                child=collect_events(subprocess.Popen([str(executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env))
                try:
                    startup={'schemaVersion':1,'runID':'cross-language','controlSocket':str(socket),'controlKey':'k'*32,'clientKey':'c'*32,'port':0,'stateDirectory':str(folder/(mode+'-state')),'accounts':[{'id':'A'},{'id':'B'}],'models':['fixture-model']}
                    child.stdin.write(json.dumps(startup)+'\n');child.stdin.flush()
                    ready=line(child);assert ready['event']=='ready',ready
                    port=ready['port'];status,body=request(port,'c'*32);assert status==200 and b'fixture-model' in body
                    started=time.monotonic()
                    status,body=request(port,'c'*32,{'model':'fixture-model','input':'synthetic','stream':False},timeout=75 if mode!='allow' else 10)
                    elapsed=time.monotonic()-started
                    if mode=='deny':
                        assert status==503 and not Upstream.calls,(status,Upstream.calls)
                        assert 59 <= elapsed < 75, ('busy admission budget',elapsed)
                    elif mode=='late':
                        assert status==503 and not Upstream.calls,(status,Upstream.calls)
                        assert 24 <= elapsed < 35, ('late acquire budget',elapsed)
                        time.sleep(2)  # Let the delayed Swift handler attempt its stale reply.
                    else:assert status==200 and b'done-B' in body and Upstream.calls==['A','B'],(status,Upstream.calls)
                    events=stop(child);assert events[-1]['event']=='stopped',events
                    bridge_events=stop(bridge);assert bridge_events[-1]['event']=='stopped' and bridge_events[-1]['held']==0,bridge_events
                    commands=[(e['command'],e['profileID']) for e in bridge_events if e['event']=='bridge']
                    if mode=='late':
                        assert commands[:-1] == [('order','A'),('acquire','A'),('acquire_resolve','A')],commands
                        assert commands[-1] == ('order_end',''),commands
                        assert any(e.get('errorCode')=='lease_acquire_reconciled' for e in events),events
                        assert not any(e.get('errorCode')=='lease_acquire_unknown' for e in events),events
                    else: assert commands[:3]==[('order','A'),('acquire','A'),('acquire','B')],commands
                    if mode=='allow':
                        releases = sorted(commands[3:-1])
                        assert releases == [('release','A'),('release','B')],commands
                        assert commands[-1] == ('order_end',''),commands
                    print('PASS:',mode,'production Swift bridge +', 'Go runtime test child + fake HTTP upstream' if mode=='allow' else 'production Go helper', 'in',round(elapsed,2),'seconds',flush=True)
                finally:
                    for process in (child,bridge):
                        if process.poll() is None:process.kill();process.wait()
            write_socket = folder/'writefail.sock'
            bridge = collect_events(subprocess.Popen([str(folder/'bridge')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
                env={**os.environ,'FIXTURE_SOCKET':str(write_socket),'FIXTURE_MODE':'writefail'}))
            try:
                assert line(bridge)['event']=='ready'
                client=unix_socket.socket(unix_socket.AF_UNIX,unix_socket.SOCK_STREAM)
                client.connect(str(write_socket))
                client.sendall((json.dumps({'schemaVersion':1,'runID':'cross-language','key':'k'*32,'command':'acquire',
                    'requestID':str(uuid.uuid4()),'profileID':'A'})+'\n').encode())
                assert line(bridge)['command']=='acquire'
                client.close()
                rollback=line(bridge)
                assert rollback=={'event':'rollback','resolution':'abandoned'},rollback
                stopped=stop(bridge)
                assert stopped[-1]['event']=='stopped' and stopped[-1]['held']==0,stopped
                print('PASS: failed acquire reply rolled back without an orphan',flush=True)
            finally:
                if bridge.poll() is None:bridge.kill();bridge.wait()
        finally:upstream.shutdown();upstream.server_close()

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--helper',type=pathlib.Path);args=parser.parse_args();run(args.helper)
