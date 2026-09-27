#!/usr/bin/env python3
"""Package Next's own helper and Skill. Python and Codex are installed separately."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SKILL_FILES = (
    'SKILL.md', '使用说明.md', 'bin/next-dispatch',
    'config/dispatch-codes-v1.json', 'config/dispatch-policy-v1.json',
    'references/coordination.md', 'references/dispatch-brief.md',
    'references/cli-validation.md', 'references/grok-cli.md',
    'references/jev-coordination.md', 'references/update-0927v1.md',
    'references/local-runtime.md', 'references/runtime-setup.md', 'references/luna-presets.md', 'references/onboarding-login.md',
    'scripts/next_dispatch_activity.py', 'scripts/next_dispatch_invocation.py',
    'scripts/next_dispatch_preflight.py',
)
SKILL_SOURCE_OVERRIDES = {
    'references/luna-presets.md': ROOT / 'scripts/companion-skill/references/luna-presets.md',
    'scripts/next_dispatch_activity.py': ROOT / 'scripts/next_dispatch_activity.py',
    'scripts/next_dispatch_invocation.py': ROOT / 'scripts/next_dispatch_invocation.py',
    'scripts/next_dispatch_preflight.py': ROOT / 'scripts/next_dispatch_preflight.py',
}


def copy_public_skill(destination):
    source = ROOT / '.agents/skills/multi-agent-management'
    destination.mkdir()
    for relative in SKILL_FILES:
        src = SKILL_SOURCE_OVERRIDES.get(relative, source / relative)
        if not src.is_file():
            raise SystemExit(f'Missing reviewed companion Skill file: {relative}')
        dest = destination / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)


def verify_resources(resources, require_hub=False):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('bundled_runtime_setup', resources / 'SupportTools/next_runtime_setup.py')
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)
    for relative in set(SKILL_FILES) | set(setup.MANAGED_SKILL_FILES):
        bundled = resources / 'CompanionSkill' / relative
        source = SKILL_SOURCE_OVERRIDES.get(relative, ROOT / '.agents/skills/multi-agent-management' / relative)
        if not bundled.is_file() or bundled.read_bytes() != source.read_bytes():
            raise SystemExit(f'Companion Skill missing or different: {relative}')
    if require_hub:
        hub = resources / 'CompanionHub'
        manifest = json.loads((hub / 'manifest.json').read_text())
        if hashlib.sha256((hub / 'agent-remote-control').read_bytes()).hexdigest() != manifest['sha256']:
            raise SystemExit('Companion Hub integrity mismatch')
    print('Verified packaged Skill files, installer requirements and companion resources.')


def verify_hub_source_manifest():
    source = ROOT / 'Companion/Hub'
    manifest = json.loads((source / 'SOURCE.json').read_text())
    for entry in manifest.get('sourceFiles', []):
        path = source / entry['path']
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            raise SystemExit(f'Companion Hub SOURCE.json mismatch: {entry["path"]}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--resources', type=Path, required=True)
    p.add_argument('--arch', choices=['arm64', 'x86_64'], required=True)
    p.add_argument('--sign-identity', default='-')
    p.add_argument('--include-hub', action='store_true')
    p.add_argument('--verify', action='store_true')
    args = p.parse_args()
    resources = args.resources.resolve()
    if args.verify:
        verify_resources(resources, args.include_hub)
        return
    copy_public_skill(resources / 'CompanionSkill')
    support = resources / 'SupportTools'
    support.mkdir()
    shutil.copyfile(ROOT / 'scripts/next_runtime_setup.py', support / 'next_runtime_setup.py')
    if args.include_hub:
        verify_hub_source_manifest()
        dest = resources / 'CompanionHub'
        dest.mkdir()
        executable = dest / 'agent-remote-control'
        env = dict(os.environ, GOOS='darwin', GOARCH='arm64' if args.arch == 'arm64' else 'amd64', CGO_ENABLED='0')
        subprocess.run(['go', 'build', '-trimpath', '-buildvcs=false', '-ldflags=-s -w', '-o', str(executable), '.'],
                       cwd=ROOT / 'Companion/Hub', env=env, check=True)
        command = ['/usr/bin/codesign', '--force', '--sign', args.sign_identity]
        if args.sign_identity != '-':
            command += ['--options', 'runtime', '--timestamp']
        subprocess.run(command + [str(executable)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(executable)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for name in ['LICENSE', 'SOURCE.json']:
            shutil.copyfile(ROOT / 'Companion/Hub' / name, dest / name)
        manifest = {'schemaVersion': 1, 'architecture': args.arch, 'version': '0910v2-next',
                    'executable': executable.name,
                    'sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
                    'sourceManifestSHA256': hashlib.sha256((ROOT / 'Companion/Hub/SOURCE.json').read_bytes()).hexdigest()}
        (dest / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    verify_resources(resources, args.include_hub)
    print('Packaged Next companion resources; external Python and Codex are not bundled.')


if __name__ == '__main__':
    main()
