#!/usr/bin/env python3
"""Production Swift client + frozen Node server; synthetic IO on loopback only."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'Sources/CodexUsageWidget'
INPUTS = [BASE / relative for relative in [
    'Domain/UsageModels.swift', 'Domain/CodexResetNotice.swift', 'Domain/FeishuMessageOptions.swift',
    'Domain/MiniProgramAccountExport.swift', 'Services/MiniProgramDesktopClient.swift',
]] + [ROOT / 'tests/MiniProgramDesktopClientFixture.swift', ROOT / 'tests/MiniProgramDesktopClientHTTPFixture.cjs',
      ROOT / 'scripts/test-miniprogram-account-export.py', Path(__file__).resolve()]
SUPPORT = '''import Foundation
struct ModelInferencePerformanceHistory: Equatable {}
struct AgentTokenShare: Equatable {}
enum TaskRuntimeState { case recorded }
enum TaskSourceKind { case fixture }
enum TaskDisplayState { case fixture }
enum TaskStateBasis { case fixture }
enum WidgetLanguage {
    case fixture
    static func storedOrAutomatic() -> Self { .fixture }
    func text(_ zh: String, _ en: String) -> String { en }
}
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server-root', type=Path, required=True, help='Explicit Mini Program checkout; never its .runtime')
    parser.add_argument('--evidence', type=Path, default=ROOT / '.local-artifacts/miniprogram-interface-1015v1/tests')
    parser.add_argument('--http-only-from', type=Path, help='Reuse a hash-matching compiled client and mock result; run only the affected HTTP chain')
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    frozen = {path: path.read_bytes() for path in INPUTS}
    # Freeze all top-level source modules because the server owner can add a require dependency.
    server_dir = args.server_root.resolve() / 'server'
    server_inputs = {path: path.read_bytes() for path in sorted(server_dir.glob('*.cjs')) if path.is_file() and not path.is_symlink()}
    if server_dir / 'server.cjs' not in server_inputs:
        raise ValueError('Explicit server root does not contain regular source modules')
    for source, data in frozen.items():
        target = evidence / 'frozen-source' / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    for source, data in server_inputs.items():
        target = evidence / 'frozen-source/miniprogram/server' / source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    spec = importlib.util.spec_from_file_location('export_test_helpers', ROOT / 'scripts/test-miniprogram-account-export.py')
    helpers = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
    receipt = {'version': '1015v1', 'checkedAt': datetime.now(timezone.utc).isoformat(),
               'inputs': {str(path.relative_to(ROOT)): sha(data) for path, data in frozen.items()},
               'serverInputs': {path.name: sha(data) for path, data in server_inputs.items()},
               'supportSHA256': sha(SUPPORT.encode()), 'realAccountIO': False, 'externalNetworkSends': 0, 'packaged': False}
    output = ''
    result = None
    bridge = None
    with tempfile.TemporaryDirectory(prefix='agb-mini-desktop-fixture-') as raw:
        folder = Path(raw)
        support = folder / 'Support.swift'
        support.write_text(SUPPORT)
        sources = [support]
        for path, data in frozen.items():
            if path.suffix != '.swift':
                continue
            if path.name == 'FeishuMessageOptions.swift':
                data = ('import Foundation\n' + helpers.declaration(data.decode(), 'struct CreditBalancePresentation:')).encode()
            target = folder / path.name
            target.write_bytes(data)
            sources.append(target)
        binary = folder / 'desktop-client-checks'
        if args.http_only_from:
            previous = args.http_only_from.resolve()
            prior = json.loads((previous / 'receipt.json').read_text())
            relevant = {name: value for name, value in receipt['inputs'].items()
                        if name.endswith('.swift') or name == 'scripts/test-miniprogram-account-export.py'}
            if (prior.get('compileExitCode') != 0 or prior.get('mockExitCode') != 0
                    or prior.get('supportSHA256') != receipt['supportSHA256']
                    or any(prior.get('inputs', {}).get(name) != value for name, value in relevant.items())
                    or sha((previous / 'desktop-client-checks').read_bytes()) != prior.get('binarySHA256')):
                raise ValueError('Prior compiled input hashes do not match current Swift and helper inputs')
            shutil.copyfile(previous / 'desktop-client-checks', binary)
            binary.chmod(0o700)
            receipt.update(compileExitCode=0, mockExitCode=0, mock=prior['mock'], compilationReused=True, mockReused=True)
            output += 'REUSED matching compiled Swift inputs and previous mock checks; HTTP only.\n'
        else:
            compiled = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                '-module-cache-path', str(folder / 'modules'), *map(str, sources), '-o', str(binary)],
                capture_output=True, text=True, timeout=120)
            output += compiled.stdout + compiled.stderr
            receipt.update(compileExitCode=compiled.returncode, compilationReused=False, mockReused=False)
        (evidence / 'compile.log').write_text(output.replace(str(ROOT), '<workspace>').replace(raw, '<fixture>'))
        if receipt['compileExitCode'] == 0:
            shutil.copyfile(binary, evidence / 'desktop-client-checks')
            (evidence / 'desktop-client-checks').chmod(0o700)
            receipt['binarySHA256'] = sha(binary.read_bytes())
            if not args.http_only_from:
                result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=45,
                    env={'PATH': os.environ.get('PATH', '/usr/bin:/bin')})
                output += result.stdout + result.stderr
                (evidence / 'mock-run.log').write_text((result.stdout + result.stderr).replace(raw, '<fixture>'))
                receipt['mockExitCode'] = result.returncode
                if result.returncode == 0:
                    receipt['mock'] = json.loads(result.stdout.strip().splitlines()[-1])
            if receipt.get('mockExitCode') == 0:
                frozen_server = folder / 'server'
                frozen_server.mkdir()
                for path, data in server_inputs.items():
                    (frozen_server / path.name).write_bytes(data)
                fixture = folder / 'MiniProgramDesktopClientHTTPFixture.cjs'
                fixture.write_bytes(frozen[ROOT / 'tests/MiniProgramDesktopClientHTTPFixture.cjs'])
                bridge = subprocess.run(['node', str(fixture), str(frozen_server), str(binary), str(folder / 'http-state'),
                                        str(evidence / 'http-receipt.json')],
                    capture_output=True, text=True, timeout=180,
                    env={'PATH': os.environ.get('PATH', '/usr/bin:/bin')})
                output += bridge.stdout + bridge.stderr
                (evidence / 'http-run.log').write_text((bridge.stdout + bridge.stderr).replace(raw, '<fixture>'))
        receipt.setdefault('mockExitCode', None)
        receipt['httpExitCode'] = bridge.returncode if bridge else None
        receipt['inputMatchCurrent'] = all(path.read_bytes() == data for path, data in frozen.items())
        receipt['serverInputMatchCurrent'] = all(path.read_bytes() == data for path, data in server_inputs.items())
        receipt['serverModuleSetMatchCurrent'] = set(server_inputs) == {path for path in server_dir.glob('*.cjs') if path.is_file() and not path.is_symlink()}
        receipt['ok'] = bool(receipt['compileExitCode'] == 0 and receipt['mockExitCode'] == 0 and bridge and bridge.returncode == 0
                             and receipt['inputMatchCurrent'] and receipt['serverInputMatchCurrent'] and receipt['serverModuleSetMatchCurrent'])
        receipt['output'] = output.replace(str(ROOT), '<workspace>').replace(str(args.server_root.resolve()), '<mini-source>').replace(raw, '<fixture>')
    (evidence / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(receipt['output'], end='')
    print(json.dumps({key: value for key, value in receipt.items() if key not in ('inputs', 'serverInputs', 'output')}, sort_keys=True))
    return 0 if receipt['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
