#!/usr/bin/env python3
"""Source-bound staging only; never installs a Skill or invokes an App/IPC."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / 'windows/companion'
RESOURCE = REPO / 'windows/apps/codexu-tauri/src-tauri/resources/companion-setup'
MAX_FILE = 256 * 1024
MAX_TOTAL = 1024 * 1024
SLOTS = (
    ('skill', 'SKILL.md'), ('guide', '使用说明.md'),
    ('launcher', 'bin/next-dispatch.py'),
    ('coordination', 'references/coordination.md'), ('brief', 'references/dispatch-brief.md'),
    ('validation', 'references/cli-validation.md'), ('grok', 'references/grok-cli.md'),
    ('jev', 'references/jev-coordination.md'), ('update', 'references/update-0927v1.md'),
    ('local-runtime', 'references/local-runtime.md'), ('runtime-setup', 'references/runtime-setup.md'),
    ('luna', 'references/luna-presets.md'), ('onboarding', 'references/onboarding-login.md'),
    ('activity', 'scripts/next_dispatch_activity.py'), ('preflight', 'scripts/next_dispatch_preflight.py'),
    ('invocation', 'scripts/next_dispatch_invocation.py'),
)
NOTE = '''<!-- next-runtime-setup:start -->
## Windows 配套运行环境
使用已验证的 Python 以 `-I -B` 执行 `bin/next-dispatch.py`。先预检并预约，再按原 lease 提交；未知结果只查询原 operation ID，不重复派单。实际 App catalog/workflow 是唯一账号与策略来源；旧 dispatch-codes/policy 文件保留但不授予本入口权限。安装、状态和能力边界见 [运行环境](references/runtime-setup.md)，本次参数与未迁移部分见 [执行档位](references/luna-presets.md)。
<!-- next-runtime-setup:end -->'''

spec = importlib.util.spec_from_file_location('companion_shared_stage_paths', REPO / 'windows/hub/prepare.py')
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)
require, safe_path, atomic_write, sha = hub.require, hub.safe_path, hub.atomic_write, hub.sha


def regular(path):
    safe_path(path)
    before = path.stat()
    require(path.is_file() and before.st_nlink == 1 and before.st_size <= MAX_FILE, 'companion_source_invalid')
    data = path.read_bytes()
    after = path.stat()
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns), 'companion_source_changed')
    require(b'\0' not in data, 'companion_source_invalid')
    data.decode('utf-8')
    return data


def encode(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode('utf-8')


def bundle(source=SOURCE):
    source = safe_path(source)
    provenance_raw = regular(source / 'SOURCE.json')
    provenance = json.loads(provenance_raw)
    require(set(provenance) == {'schemaVersion', 'macCommit', 'macSourceFiles', 'sourceFiles', 'layout'}, 'companion_provenance_invalid')
    require(provenance['schemaVersion'] == 1 and provenance['layout'] == 'windows-native-16-v1', 'companion_provenance_invalid')
    require(provenance['macCommit'] == 'ad74ecd040d498f590c889081ce7c2c8fc13f00b' and len(provenance['macSourceFiles']) == 18, 'companion_origin_invalid')
    expected_sources = {'next-dispatch.py'} | {'payload/' + path for slot, path in SLOTS if slot != 'launcher'}
    require(set(provenance['sourceFiles']) == expected_sources, 'companion_source_inventory_invalid')
    actual_payload = set()
    for p in (source / 'payload').rglob('*'):
        safe_path(p)
        require(p.is_file() or p.is_dir(), 'companion_payload_object_invalid')
        if p.is_file(): actual_payload.add(p.relative_to(source).as_posix())
    require(actual_payload == expected_sources - {'next-dispatch.py'}, 'companion_payload_inventory_changed')
    inputs, output, entries = {}, {}, []
    for slot, path in SLOTS:
        src = 'next-dispatch.py' if slot == 'launcher' else 'payload/' + path
        data = regular(source / src)
        require(sha(data) == provenance['sourceFiles'][src], 'companion_source_hash_changed')
        inputs[src] = sha(data)
        output[path] = data
        entries.append({'slot': slot, 'path': path, 'sha256': sha(data)})
    require(sum(map(len, output.values())) <= MAX_TOTAL, 'companion_bundle_too_large')
    # Real callable source, not a placeholder/existence check.
    for path, data in output.items():
        if path.endswith('.py'): compile(data, path, 'exec')
    for path, data in output.items():
        if path.endswith('.md'):
            import re, posixpath
            for target in re.findall(r'\]\(([^)]+)\)', data.decode('utf-8')):
                if target.startswith(('https://', '#')): continue
                relative = posixpath.normpath(posixpath.join(posixpath.dirname(path), target.split('#', 1)[0]))
                require(relative in output, 'companion_document_link_missing')
    output['manifest.json'] = encode({'schemaVersion': 1, 'platform': 'windows', 'adapterABI': 1,
                                     'managedNote': NOTE, 'files': entries})
    receipt = {'schemaVersion': 1, 'target': 'windows-companion-abi1', 'layout': 'windows-native-16-v1',
               'sourceSHA256': sha(provenance_raw), 'sourceFiles': inputs,
               'manifestSHA256': sha(output['manifest.json']),
               'resourceFiles': {path: sha(data) for path, data in sorted(output.items())},
               'nativeExecuted': False}
    output['COMPANION-SETUP-RESOURCES.json'] = encode(receipt)
    return output, receipt


def stage(resources, source=SOURCE, verify_only=False):
    resources = Path(resources)
    require(resources.is_absolute() and '..' not in resources.parts, 'companion_output_invalid')
    resources = safe_path(resources)
    source = safe_path(source)
    require(resources != source and resources not in source.parents and source not in resources.parents, 'companion_output_overlap')
    output, receipt = bundle(source)
    if resources.exists():
        actual = {}
        for p in resources.rglob('*'):
            safe_path(p)
            require(p.is_file() or p.is_dir(), 'companion_output_invalid')
            if p.is_file(): actual[p.relative_to(resources).as_posix()] = regular(p)
        require(set(actual) <= set(output), 'companion_output_unexpected_file')
        if verify_only:
            require(actual == output, 'companion_output_changed')
            return receipt
    else:
        require(not verify_only, 'companion_output_missing')
    resources.mkdir(parents=True, exist_ok=True)
    safe_path(resources)
    # Manifest/receipt written last; a partial stage never passes verify-only.
    for path, data in output.items():
        safe_path(resources / path)
        atomic_write(resources / path, data)
    return stage(resources, source, True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    relative = RESOURCE.relative_to(REPO) / 'manifest.json'
    require(subprocess.run(['git', 'check-ignore', '-q', '--', str(relative)], cwd=REPO).returncode == 0,
            'companion_output_not_ignored')
    receipt = stage(RESOURCE, verify_only=args.verify_only)
    print(json.dumps({'layout': receipt['layout'], 'manifestSHA256': receipt['manifestSHA256'],
                      'resourceCount': len(receipt['resourceFiles']), 'nativeExecuted': False}))

if __name__ == '__main__':
    main()
