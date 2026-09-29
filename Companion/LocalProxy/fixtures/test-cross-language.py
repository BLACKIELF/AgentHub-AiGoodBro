#!/usr/bin/env python3
"""Actual Swift bridge and Go processes; generated synthetic credentials only."""
import argparse, http.client, json, os, pathlib, select, subprocess, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODULE = pathlib.Path(__file__).resolve().parents[1]
ROOT = MODULE.parents[1]

def line(process):
    assert select.select([process.stdout], [], [], 15)[0], 'fixture output timeout'
    return json.loads(process.stdout.readline())

def stop(process):
    process.stdin.close()
    process.wait(timeout=15)
    assert process.returncode == 0, 'fixture failed'
    data = [json.loads(item) for item in process.stdout.read().splitlines()]
    assert not process.stderr.read(), 'unexpected stderr'
    return data

def request(port, key, body=None):
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
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
            for mode in ('deny','allow'):
                socket=folder/(mode+'.sock')
                bridge=subprocess.Popen([str(folder/'bridge')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env={**os.environ,'FIXTURE_SOCKET':str(socket),'FIXTURE_MODE':mode})
                assert line(bridge)['event']=='ready'
                env={**os.environ}
                executable=helper
                if mode=='allow':
                    executable=test_helper
                    env.update(AIGOODBRO_PROTOCOL_FIXTURE_CHILD='1',AIGOODBRO_FIXTURE_UPSTREAM=f'http://127.0.0.1:{upstream.server_port}')
                child=subprocess.Popen([str(executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
                try:
                    startup={'schemaVersion':1,'runID':'cross-language','controlSocket':str(socket),'controlKey':'k'*32,'clientKey':'c'*32,'port':0,'stateDirectory':str(folder/(mode+'-state')),'accounts':[{'id':'A'},{'id':'B'}],'models':['fixture-model']}
                    child.stdin.write(json.dumps(startup)+'\n');child.stdin.flush()
                    ready=line(child);assert ready['event']=='ready',ready
                    port=ready['port'];status,body=request(port,'c'*32);assert status==200 and b'fixture-model' in body
                    status,body=request(port,'c'*32,{'model':'fixture-model','input':'synthetic','stream':False})
                    if mode=='deny':assert status==503 and not Upstream.calls,(status,Upstream.calls)
                    else:assert status==200 and b'done-B' in body and Upstream.calls==['A','B'],(status,Upstream.calls)
                    events=stop(child);assert events[-1]['event']=='stopped',events
                    bridge_events=stop(bridge);assert bridge_events[-1]['event']=='stopped' and bridge_events[-1]['held']==0,bridge_events
                    commands=[(e['command'],e['profileID']) for e in bridge_events if e['event']=='bridge']
                    assert commands[:3]==[('order','A'),('acquire','A'),('acquire','B')],commands
                    if mode=='allow':assert sorted(commands[3:])==[('release','A'),('release','B')],commands
                    print('PASS:',mode,'production Swift bridge +', 'production Go helper' if mode=='deny' else 'Go runtime test child + fake HTTP upstream')
                finally:
                    for process in (child,bridge):
                        if process.poll() is None:process.kill();process.wait()
        finally:upstream.shutdown();upstream.server_close()

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--helper',type=pathlib.Path);args=parser.parse_args();run(args.helper)
