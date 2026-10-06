#!/usr/bin/env python3
"""A real closed pipe reproduces the old host's SIGPIPE without touching the app."""
from pathlib import Path
import hashlib, json, os, re, signal, subprocess, tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Sources/CodexUsageWidget/main.swift'
source = SOURCE.read_text()
startup = source.split('@MainActor static func main() async {', 1)[1].split('if let index', 1)[0]
policy = re.search(r'^\s*signal\(SIGPIPE, SIG_IGN\)\s*$', startup, re.M)
assert policy, 'Host must configure SIGPIPE before any helper or application path'
fixture = '''import Foundation
import Darwin
signal(SIGPIPE, SIG_DFL)
POLICY
let pipe = Pipe()
try pipe.fileHandleForReading.close()
do {
    try pipe.fileHandleForWriting.write(contentsOf: Data("synthetic".utf8))
    exit(2)
} catch {
    print("BROKEN_PIPE_REPORTED; HOST_SURVIVED")
}
'''
with tempfile.TemporaryDirectory(prefix='aigoodbro-broken-pipe-') as temp:
    directory = Path(temp)
    results = {}
    for name, replacement in [('before', ''), ('after', policy.group().strip())]:
        swift = directory / (name + '.swift')
        binary = directory / name
        swift.write_text(fixture.replace('POLICY', replacement))
        subprocess.run(['xcrun', 'swiftc', str(swift), '-o', str(binary)], check=True, capture_output=True)
        reply = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        results[name] = {'exitCode': reply.returncode, 'stdout': reply.stdout.strip()}
    assert results['before']['exitCode'] == -signal.SIGPIPE, results
    assert results['after'] == {'exitCode': 0, 'stdout': 'BROKEN_PIPE_REPORTED; HOST_SURVIVED'}, results
receipt = {'mainSHA256': hashlib.sha256(source.encode()).hexdigest(), 'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'results': results,
           'scope': 'Standalone real FileHandle pipe write; no installed app launch, helpers, credentials or network', 'ok': True}
prefix = os.environ.get('HOST_PIPE_EVIDENCE_PREFIX', 'host-broken-pipe-ci')
assert re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}', prefix)
out = ROOT / ('.local-artifacts/theme-upstream-1004v1/' + prefix + '.json')
out.parent.mkdir(parents=True, exist_ok=True)
with out.open('x') as stream: stream.write(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))
