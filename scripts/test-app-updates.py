#!/usr/bin/env python3
"""Compile actual update logic and use URLProtocol fixtures; no external requests or UI."""
from pathlib import Path
import hashlib, json, os, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parent.parent
FILES = [
    'Sources/CodexUsageWidget/Domain/AppUpdate.swift',
    'Sources/CodexUsageWidget/Services/AppUpdateStore.swift',
    'Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift',
    'Sources/CodexUsageWidget/Services/AppUpdateDownloader.swift',
    'tests/AppUpdateTransportTests.swift', 'tests/AppUpdateAvailabilityTests.swift',
]
STUB = '''import Foundation
import Combine
final class AppSettings: ObservableObject {
 @Published var automaticUpdateChecksEnabled = true
 var skippedUpdateVersion: String?
 init(defaults: UserDefaults) {}
 func skipUpdateVersion(_ version: String) { skippedUpdateVersion = version }
}
struct RuntimeLoadContext {
 let cacheDirectory: URL
 static func live() -> RuntimeLoadContext {
  .init(cacheDirectory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["APP_UPDATE_TEST_ROOT"]!))
 }
}
'''
prefix = os.environ.get('APP_UPDATE_EVIDENCE_PREFIX', 'app-updates-ci')
assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,127}', prefix)
snapshots = {name: (ROOT / name).read_bytes() for name in FILES}
inputs = {name: hashlib.sha256(data).hexdigest() for name, data in snapshots.items()}
with tempfile.TemporaryDirectory(prefix='aigoodbro-updates-') as temp:
    directory = Path(temp)
    frozen = []
    for index, (name, data) in enumerate(snapshots.items()):
        target = directory / (str(index) + '-' + Path(name).name)
        target.write_bytes(data)
        frozen.append(target)
    stub = directory / 'stub.swift'
    stub.write_text(STUB)
    main = directory / 'main.swift'
    main.write_text('''import Foundation
if !AppUpdateSelfTest.run() { fatalError("update self-test failed") }
if !AppUpdateDownloadPolicy.selfTest() { fatalError("update policy self-test failed") }
runAvailabilityTests()
runTransportTests()
''')
    binary = directory / 'checks'
    compiled = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(directory / 'modules'), str(stub), *map(str, frozen), str(main), '-o', str(binary)], capture_output=True, text=True, cwd=ROOT)
    output = compiled.stdout + compiled.stderr
    tested = None
    if compiled.returncode == 0:
        tested = subprocess.run([str(binary)], env={**os.environ, 'APP_UPDATE_TEST_ROOT': str(directory / 'cache')}, capture_output=True, text=True, timeout=60)
        output += tested.stdout + tested.stderr
    for name, replacement in [(temp, '<fixture>'), (str(ROOT), '<repo>'), (str(Path.home()), '<home>')]:
        output = output.replace(name, replacement)
    print(output, end='')
    receipt = {'inputsSHA256': inputs, 'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'compileExitCode': compiled.returncode, 'testExitCode': tested.returncode if tested else None,
               'inputsUnchanged': all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == value for name, value in inputs.items()),
               'scope': 'Actual release policy, checker, store and downloader; URLProtocol transport, private defaults/cache/download roots; no external network, real app, package opening, installation or release',
               'logSHA256': hashlib.sha256(output.encode()).hexdigest()}
    out = ROOT / '.local-artifacts/theme-upstream-1004v1'
    out.mkdir(parents=True, exist_ok=True)
    with (out / (prefix + '.log')).open('x') as stream: stream.write(output)
    with (out / (prefix + '.json')).open('x') as stream: stream.write(json.dumps(receipt, indent=2) + '\n')
    assert compiled.returncode == 0 and tested and tested.returncode == 0 and receipt['inputsUnchanged'], receipt
