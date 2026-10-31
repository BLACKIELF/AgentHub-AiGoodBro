#!/usr/bin/env python3
"""Stage the existing reviewed OAuth helper for Windows, without account access.

Use the unchanged upstream-patch verifier once, then reuse only an exact staged
source inventory. No Darwin builder, SDK cache modification or silent download.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / 'Companion/AntigravityProxy'
RESOURCE = REPO / 'windows/apps/codexu-tauri/src-tauri/resources/provider-pool'
NAME = 'aigoodbro-antigravity-proxy.exe'
PACKAGE = 'github.com/router-for-me/CLIProxyAPI/v8/aigoodbro-antigravity-proxy'


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Shared build-path, exact-tree, PE and atomic-output checks are already used by
# the Windows Hub pipeline. The provider's pinned patch implementation is reused.
hub = load(REPO / 'windows/hub/prepare.py', 'provider_pool_build_paths')
require, sha, safe_path, atomic_write = hub.require, hub.sha, hub.safe_path, hub.atomic_write


def regular(path):
    data = hub.regular(path)
    require(path.stat().st_nlink == 1, 'provider_pool_hardlink')
    return data


def validate_pe(data):
    hub.validate_pe(data)
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    require(offset + 26 <= len(data) and data[offset + 24:offset + 26] == b'\x0b\x02',
            'provider_pool_pe_abi')


def locations(build, resources):
    for path in (build, resources):
        require(path.is_absolute() and '..' not in path.parts, 'provider_pool_path_invalid')
    build, resources = safe_path(build), safe_path(resources)
    require(build != resources and build not in resources.parents and resources not in build.parents,
            'provider_pool_build_resource_overlap')
    for path in (build, resources):
        require(path != SOURCE and SOURCE not in path.parents and path not in SOURCE.parents,
                'provider_pool_source_overlap')
    return build, resources


def inventory(root):
    safe_path(root)
    files = {}
    for path in sorted(root.rglob('*')):
        safe_path(path)
        if path.is_dir():
            continue
        files[path.relative_to(root).as_posix()] = sha(regular(path))
    return files


def source_inputs(source=SOURCE):
    required = {'go.mod', 'go.sum', 'go.py', 'SOURCE.json', 'LICENSE.CLIProxyAPI',
                'LICENSE.Hazmat', 'upstream-patches/manifest.json'}
    files = inventory(source)
    require(required <= files.keys(), 'provider_pool_source_incomplete')
    support = load(source / 'go.py', 'provider_pool_reviewed_patch')
    manifest = support.load_manifest(source)
    provenance = json.loads(regular(source / 'SOURCE.json'))
    for key in ('upstreamModule', 'upstreamVersion', 'upstreamCommit', 'moduleSum', 'moduleGoModSum', 'license'):
        require(provenance.get(key) == manifest.get(key), 'provider_pool_provenance_changed')
    tests = set()
    for path in source.glob('*_test.go'):
        names = re.findall(rb'(?m)^func (Test[A-Za-z0-9_]+)\(t \*testing\.T\)', regular(path))
        for name in names:
            text = name.decode('ascii')
            require(text not in tests, 'provider_pool_duplicate_test')
            tests.add(text)
    require(len(tests) >= 30, 'provider_pool_tests_incomplete')
    return files, support, manifest, tests


def native_result(output, required):
    started, passed = set(), set()
    package_pass = False
    for line in output.decode('utf-8').splitlines():
        event = json.loads(line)
        require(event.get('Action') != 'fail', 'provider_pool_native_test_failed')
        if event.get('Package') != PACKAGE:
            continue
        action, name = event.get('Action'), event.get('Test')
        if name in required:
            require(action != 'skip', 'provider_pool_native_tests_not_executed')
            if action == 'run':
                require(name not in started, 'provider_pool_native_duplicate')
                started.add(name)
            if action == 'pass':
                require(name in started and name not in passed, 'provider_pool_native_duplicate')
                passed.add(name)
        elif not name and action == 'pass':
            package_pass = True
    require(started == required and passed == required and package_pass,
            'provider_pool_native_tests_not_executed')
    return sorted(passed)


def environment(build, allow_download):
    allowed = ('PATH', 'SystemRoot', 'WINDIR', 'PATHEXT', 'COMSPEC', 'ProgramFiles',
               'ProgramFiles(x86)', 'ProgramW6432', 'SystemDrive', 'GOMODCACHE', 'GOCACHE', 'GOPATH')
    env = {key: os.environ[key] for key in allowed if key in os.environ}
    # Locate existing public caches before isolating HOME. No new parallel cache.
    for name in ('GOMODCACHE', 'GOCACHE', 'GOPATH'):
        if not env.get(name):
            env[name] = subprocess.check_output(['go', 'env', name], env={**os.environ, 'GOTOOLCHAIN':'local', 'GOENV':'off'},
                                                text=True, timeout=20).strip()
        require(bool(env[name]), 'provider_pool_go_cache_missing')
    home, temp = build / 'isolated-home', build / 'tmp'
    for path in (home, temp):
        safe_path(path).mkdir(exist_ok=True)
    env.update(HOME=str(home), USERPROFILE=str(home), APPDATA=str(home / 'AppData/Roaming'),
               LOCALAPPDATA=str(home / 'AppData/Local'), TEMP=str(temp), TMP=str(temp), TMPDIR=str(temp),
               GOOS='windows', GOARCH='amd64', GOAMD64='v1', CGO_ENABLED='0',
               GOWORK='off', GOFLAGS='', GOENV='off', GOEXPERIMENT='', GO111MODULE='on', GOTOOLCHAIN='local')
    if not allow_download:
        env.update(GOPROXY='off', GOSUMDB='off')
    return env


def source_stage(build, inputs, support, env):
    stage, marker = build / 'source', build / 'STAGED-SOURCE.json'
    if stage.exists():
        receipt = json.loads(regular(marker))
        require(receipt.get('sourceFiles') == inputs, 'provider_pool_stage_source_changed')
        require(inventory(stage) == receipt.get('files'), 'provider_pool_stage_changed')
        return stage / 'adapter', receipt['files']
    # This creates exactly one task-owned source tree. Interrupted partial trees
    # are retained and rejected, never erased or copied into a second retry tree.
    stage.mkdir()
    adapter, _, _ = support.prepare_source(stage, env, SOURCE)
    files = inventory(stage)
    atomic_write(marker, (json.dumps({'schemaVersion': 1, 'sourceFiles': inputs, 'files': files}, sort_keys=True, indent=2)+'\n').encode())
    return adapter, files


def verify_receipt(receipt, inputs, staged, required, native_log=None):
    require(receipt.get('schemaVersion') == 1 and receipt.get('target') == 'windows-amd64', 'provider_pool_receipt_target')
    require(receipt.get('sourceFiles') == inputs and receipt.get('stagedSourceFiles') == staged,
            'provider_pool_receipt_source_changed')
    require(receipt.get('upstreamPatchManifestSHA256') == inputs['upstream-patches/manifest.json'],
            'provider_pool_receipt_patch_changed')
    require(receipt.get('syntheticOnly') is True and receipt.get('realAccountsRead') is False,
            'provider_pool_receipt_boundary')
    if native_log is not None:
        require(receipt.get('nativeTests') == sorted(required), 'provider_pool_native_receipt_missing')
        require(receipt.get('nativeLogSHA256') == sha(native_log), 'provider_pool_native_log_changed')
        native_result(native_log, required)


def prepare(args):
    require(args.build_root.is_absolute(), 'provider_pool_build_root_relative')
    require(not (args.run_native_tests and args.verify_only), 'provider_pool_conflicting_modes')
    require(not args.require_native or args.verify_only, 'provider_pool_native_requires_verify')
    build, resources = locations(args.build_root, args.resource_dir)
    if resources.is_relative_to(REPO):
        require(subprocess.run(['git', 'check-ignore', '-q', '--', str((resources / NAME).relative_to(REPO))], cwd=REPO).returncode == 0,
                'provider_pool_output_not_ignored')
    inputs, support, manifest, required_tests = source_inputs()
    receipt_path = build / 'WINDOWS-RESOURCES.json'
    if args.verify_only:
        receipt = json.loads(regular(receipt_path))
        stage_receipt = json.loads(regular(build / 'STAGED-SOURCE.json'))
        require(stage_receipt.get('sourceFiles') == inputs, 'provider_pool_stage_source_changed')
        staged = inventory(build / 'source')
        require(stage_receipt.get('files') == staged, 'provider_pool_stage_changed')
        native_log = regular(build / 'native-tests.jsonl') if args.require_native else None
        verify_receipt(receipt, inputs, staged, required_tests, native_log)
        binary = regular(build / NAME)
    else:
        build.mkdir(parents=True, exist_ok=True)
        # Go caches may grow by more than one GiB on a fresh host. Respect the
        # task's local storage policy before staging or invoking a build tool.
        require(shutil.disk_usage(build).free >= 50 * 1024**3, 'provider_pool_insufficient_build_space')
        env = environment(build, args.allow_dependency_download)
        for key in ('GOMODCACHE', 'GOCACHE'):
            path = safe_path(Path(env[key]))
            require(path.is_absolute(), 'provider_pool_cache_relative')
            existing = next(p for p in (path, *path.parents) if p.exists())
            require(shutil.disk_usage(existing).free >= 50 * 1024**3, 'provider_pool_insufficient_cache_space')
        adapter, staged = source_stage(build, inputs, support, env)
        native_tests, native_sha = [], None
        if args.run_native_tests:
            require(sys.platform == 'win32', 'provider_pool_native_windows_required')
            proc = subprocess.run(['go', 'test', '-mod=readonly', '-json', '-count=1', '.'], cwd=adapter, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
            atomic_write(build / 'native-tests.jsonl', proc.stdout)
            atomic_write(build / 'native-tests.stderr.log', proc.stderr)
            require(proc.returncode == 0, 'provider_pool_native_test_failed')
            native_tests, native_sha = native_result(proc.stdout, required_tests), sha(proc.stdout)
        require(inventory(build / 'source') == staged, 'provider_pool_stage_changed')
        candidate = build / 'aigoodbro-antigravity-proxy.building.exe'
        subprocess.run(['go', 'build', '-mod=readonly', '-trimpath', '-buildvcs=false', '-ldflags=-s -w', '-o', str(candidate), '.'],
                       cwd=adapter, env=env, check=True, timeout=600)
        binary = regular(candidate)
        validate_pe(binary)
        require(inventory(build / 'source') == staged and source_inputs()[0] == inputs, 'provider_pool_source_changed_during_build')
        atomic_write(build / NAME, binary)
        candidate.unlink()
        receipt = {'schemaVersion': 1, 'target': 'windows-amd64', 'sourceFiles': inputs, 'stagedSourceFiles': staged,
                   'upstreamPatchManifestSHA256': inputs['upstream-patches/manifest.json'],
                   'upstreamVersion': manifest['upstreamVersion'], 'upstreamCommit': manifest['upstreamCommit'],
                   'nativeTests': native_tests, 'nativeLogSHA256': native_sha,
                   'syntheticOnly': True, 'realAccountsRead': False}
    validate_pe(binary)
    files = {NAME: binary, **{name: regular(SOURCE / name) for name in ('SOURCE.json', 'LICENSE.CLIProxyAPI', 'LICENSE.Hazmat')}}
    file_receipt = {name: {'sha256': sha(data), 'size': len(data)} for name, data in sorted(files.items())}
    if args.verify_only:
        require(receipt.get('files') == file_receipt, 'provider_pool_resource_changed')
    else:
        receipt['files'] = file_receipt
        atomic_write(receipt_path, (json.dumps(receipt, indent=2, sort_keys=True)+'\n').encode())
    require(source_inputs()[0] == inputs, 'provider_pool_source_changed_before_publish')
    if resources.exists():
        require(inventory(resources).keys() <= files.keys() | {'WINDOWS-RESOURCES.json'}, 'provider_pool_resource_unexpected_file')
    for name, data in files.items():
        atomic_write(resources / name, data)
    atomic_write(resources / 'WINDOWS-RESOURCES.json', regular(receipt_path))
    hub.verify_stage(resources, {**files, 'WINDOWS-RESOURCES.json': regular(receipt_path)})
    print(json.dumps({'helperSHA256': sha(binary), 'sourceFiles': len(inputs), 'nativeTestsPassed': len(receipt['nativeTests'])}))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build-root', type=Path, required=True)
    p.add_argument('--resource-dir', type=Path, default=RESOURCE)
    p.add_argument('--run-native-tests', action='store_true')
    p.add_argument('--verify-only', action='store_true')
    p.add_argument('--require-native', action='store_true')
    p.add_argument('--allow-dependency-download', action='store_true')
    prepare(p.parse_args())
