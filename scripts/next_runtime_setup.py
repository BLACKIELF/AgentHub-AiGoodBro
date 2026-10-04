#!/usr/bin/env python3
"""Private Next runtime setup. Outputs fixed status codes, never paths or account data."""
from __future__ import annotations
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shlex
import shutil
import signal
import socket
import stat
import sys
import subprocess
import tempfile
import time
import urllib.request
import uuid

SUPPORT_NAME = 'CodexAccountManagerNext'
HUB_LABEL = 'com.blackielf.codex-account-manager-next.hub'
LEGACY_LABEL = 'com.agenthub.arc-hub'
MANAGED_BEGIN = '<!-- next-runtime-setup:start -->'
MANAGED_END = '<!-- next-runtime-setup:end -->'
MANAGED_NOTE = (MANAGED_BEGIN + '\n## 运行环境引导\n'
    '配套应用检测已有 Codex 与 Python，缺少时引导官方安装。优先使用 `bin/next-dispatch`；先 `plan`，中断后用 `status` / `result` 收取原任务。'
    '安装、诊断、参数与验收边界见 [运行环境说明](references/runtime-setup.md)。'
    '首次连接多个工具见 [连接清单](references/onboarding-login.md)：ZCode 走桌面登录，OpenCode 走 CLI；本人确认与账号、额度证据分别显示。'
    '三个可自定义执行档位及配置与实测证据的区别见 [执行档位](references/luna-presets.md)。'
    '需要 Jev 协作时，读取 [Jev 协作流程](references/jev-coordination.md)；文档与实际执行能力分别验证。\n' + MANAGED_END + '\n')
MANAGED_SKILL_FILES = ('bin/next-dispatch', 'scripts/next_dispatch_activity.py',
    'scripts/next_dispatch_preflight.py', 'scripts/next_dispatch_invocation.py',
    'references/runtime-setup.md', 'references/luna-presets.md', 'references/onboarding-login.md',
    'references/jev-coordination.md', 'references/update-0927v1.md')


class SetupError(RuntimeError):
    pass


def read_regular(path, maximum=1024 * 1024):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise SetupError('file_invalid')
        with os.fdopen(fd, 'rb', closefd=False) as f:
            data = f.read(maximum + 1)
        if len(data) > maximum:
            raise SetupError('file_too_large')
        return data
    finally:
        os.close(fd)


def digest(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1024**3:
            raise SetupError('runtime_file_invalid')
        h = hashlib.sha256()
        with os.fdopen(fd, 'rb', closefd=False) as f:
            while data := f.read(1024 * 1024):
                h.update(data)
        return h.hexdigest()
    finally:
        os.close(fd)


def process_group_exists(group_id):
    try:
        os.killpg(group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def cleanup_process_group(child, timeout=0.5):
    group_id = child.pid
    for process_signal in (signal.SIGTERM, signal.SIGKILL):
        child.poll()  # Reap an exited leader before signaling its remaining group.
        if not process_group_exists(group_id):
            break
        try:
            os.killpg(group_id, process_signal)
        except ProcessLookupError:
            pass
        except PermissionError as error:
            # Darwin may deny a zombie-only group. Only a verified absent group
            # is safe; a reaped leader alone says nothing about descendants.
            child.poll()
            if not process_group_exists(group_id):
                break
            raise SetupError('command_cleanup_failed') from error
        deadline = time.monotonic() + timeout
        while process_group_exists(group_id) and time.monotonic() < deadline:
            child.poll()
            time.sleep(0.02)
        if not process_group_exists(group_id):
            break
    if child.poll() is None:
        try:
            child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            pass
    if process_group_exists(group_id):
        raise SetupError('command_cleanup_failed')


def bounded_command(arguments, timeout=5):
    env = {key: os.environ[key] for key in ['HOME', 'USER', 'TMPDIR'] if key in os.environ}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', PYTHONDONTWRITEBYTECODE='1')
    child = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             env=env, start_new_session=True)
    deadline = time.monotonic() + timeout
    data = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise SetupError('command_timeout')
                for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                    chunk = os.read(key.fd, 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        data.extend(chunk)
                        if len(data) > 64 * 1024:
                            raise SetupError('command_output_too_large')
            code = child.wait(timeout=max(0.01, deadline - time.monotonic()))
            if code != 0:
                raise SetupError('command_failed')
            return bytes(data).decode('utf-8').strip()
    finally:
        try:
            cleanup_process_group(child)
        finally:
            child.stdout.close()


def atomic_write(path, data, *, exclusive=False, executable=False, mode=None):
    private_directory(path.parent)
    if os.path.lexists(path):
        info = path.lstat()
        if exclusive or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise SetupError('existing_file_conflict')
    fd, name = tempfile.mkstemp(prefix='.next-setup-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(name, mode if mode is not None else (0o700 if executable else 0o600))
        if exclusive:
            os.link(name, path)
        else:
            os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def private_directory(path):
    if any(parent.is_symlink() for parent in [path, *path.parents]):
        raise SetupError('directory_symlink_conflict')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise SetupError('directory_permission_conflict')


class Setup:
    def __init__(self, resources, home=None, python=None, codex=None):
        self.resources = Path(resources).resolve()
        self.companion = self.resources / 'CompanionHub'
        self.python = str(Path(python or sys.executable).absolute())
        self.codex = str(Path(codex).absolute()) if codex else None
        self.home = (Path(home) if home else Path.home()).resolve()
        self.support = self.home / 'Library/Application Support' / SUPPORT_NAME
        self.hub = self.home / 'Library/Application Support/CodexAccountManagerNextHub'
        self.skill = self.home / '.codex/skills/multi-agent-management'
        self.current = self.support / 'Companion/current'
        self.hub_receipt = self.support / 'Companion/hub-setup-state.json'
        self.agent = self.home / 'Library/LaunchAgents' / (HUB_LABEL + '.plist')
        self.legacy_agent = self.agent.with_name(LEGACY_LABEL + '.plist')

    def validate_inputs(self):
        if sys.version_info < (3, 9) or not self.codex or not os.access(self.codex, os.X_OK):
            raise SetupError('install_external_tools_first')
        if not os.path.samefile(self.python, sys.executable):
            raise SetupError('python_selection_changed')
        if not bounded_command([self.codex, '--version']).startswith('codex'):
            raise SetupError('codex_check_failed')
        help_text = bounded_command([self.codex, 'exec', '--help'])
        if not all(flag in help_text for flag in ('--output-last-message', '--sandbox', '--model')):
            raise SetupError('codex_capability_missing')

    @contextmanager
    def setup_lock(self):
        private_directory(self.support)
        lock_path = self.support / '.runtime-setup.lock'
        try:
            fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        except OSError as error:
            raise SetupError('setup_lock_invalid') from error
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise SetupError('setup_lock_invalid')
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise SetupError('setup_in_progress') from error
            yield
        finally:
            os.close(fd)

    def hub_status(self):
        existing = any(os.path.lexists(p) for p in [self.agent, self.legacy_agent, self.hub / 'config.json'])
        recognized = self.recognized_hub_artifact()
        occupied = False
        try:
            with socket.create_connection(('127.0.0.1', 8787), timeout=0.3):
                occupied = True
        except OSError:
            pass
        if occupied:
            try:
                class NoRedirect(urllib.request.HTTPRedirectHandler):
                    def redirect_request(self, *args, **kwargs):
                        return None
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
                with opener.open('http://127.0.0.1:8787/healthz', timeout=2) as r:
                    value = json.loads(r.read(4097))
                version = value.get('version')
                compatible = version == self.expected_hub_version() or (
                    isinstance(version, str) and re.fullmatch(r'09[0-9]{2}v[0-9]+(?:-next)?', version))
                if existing and recognized and value.get('status') == 'ok' and compatible:
                    return 'ready'
            except Exception:
                pass
            return 'port_conflict'
        if os.path.lexists(self.hub_receipt):
            return 'setup_incomplete'
        return 'existing_stopped' if existing else 'setup_needed'

    def recognized_hub_artifact(self):
        config = self.hub / 'config.json'
        if os.path.lexists(config):
            try:
                value = json.loads(read_regular(config, 1024 * 1024))
                if isinstance(value, dict) and value.get('listen') == '127.0.0.1:8787':
                    return True
            except (OSError, ValueError, SetupError):
                pass
        for path, label in ((self.agent, HUB_LABEL), (self.legacy_agent, LEGACY_LABEL)):
            if not os.path.lexists(path):
                continue
            try:
                value = plistlib.loads(read_regular(path, 1024 * 1024))
                arguments = value.get('ProgramArguments') if isinstance(value, dict) else None
                if isinstance(value, dict) and value.get('Label') == label and isinstance(arguments, list) and '--config' in arguments:
                    return True
                # Existing legacy installations can wrap one literal exec in a
                # shell. Parse that narrow form without evaluating shell text.
                if (isinstance(value, dict) and value.get('Label') == LEGACY_LABEL
                        and label == LEGACY_LABEL and isinstance(arguments, list)
                        and len(arguments) == 3 and arguments[0] in ('/bin/bash', '/bin/zsh')
                        and arguments[1] == '-c' and isinstance(arguments[2], str)
                        and not any(c in arguments[2] for c in '\n\r`$;|&<>')):
                    tokens = shlex.split(arguments[2])
                    if (len(tokens) == 4 and tokens[0] == 'exec' and tokens[2] == '--config'
                            and Path(tokens[1]).is_absolute() and Path(tokens[1]).name == 'agent-remote-control'
                            and Path(tokens[3]).is_absolute()):
                        config = json.loads(read_regular(Path(tokens[3]), 1024 * 1024))
                        if isinstance(config, dict) and config.get('listen') == '127.0.0.1:8787':
                            return True
            except (OSError, ValueError, SetupError):
                pass
        return False

    def expected_hub_version(self):
        try:
            manifest = json.loads(read_regular(self.companion / 'manifest.json', 8192))
            if manifest.get('schemaVersion') == 1 and isinstance(manifest.get('version'), str):
                return manifest['version']
        except (OSError, ValueError, SetupError):
            pass
        return '0910v2-next'

    def skill_ready(self):
        try:
            source = self.resources / 'CompanionSkill'
            files = MANAGED_SKILL_FILES
            policy = read_regular(self.skill / 'SKILL.md').decode('utf-8')
            return (all(read_regular(self.skill / f) == read_regular(source / f) for f in files)
                    and policy.count(MANAGED_BEGIN) == 1 and policy.count(MANAGED_END) == 1
                    and json.loads(read_regular(self.skill / 'config/runtime-paths.json', 8192)) == self.runtime_paths()
                    and read_regular(self.skill / 'config/runtime-python.txt', 4096).decode().strip() == self.python)
        except (OSError, ValueError, SetupError):
            return False

    def check(self):
        report = {'schemaVersion': 1, 'components': [], 'skill': 'setup_needed', 'hub': self.hub_status(), 'error': None}
        try:
            self.validate_inputs()
            report['skill'] = 'ready' if self.skill_ready() else 'setup_needed'
        except SetupError as e:
            report['error'] = str(e)
        except Exception:
            report['error'] = 'runtime_unavailable'
        return report

    def install_tools(self):
        self.validate_inputs()
        private_directory(self.support)
        with self.setup_lock():
            self._install_tools_locked()

    def _install_tools_locked(self):
        private_directory(self.support / 'Companion')
        source = self.resources / 'CompanionSkill'
        if self.skill.exists() or self.skill.is_symlink():
            private_directory(self.skill)
            targets = [Path(f) for f in MANAGED_SKILL_FILES]
        else:
            private_directory(self.skill.parent)
            private_directory(self.skill)
            targets = [p.relative_to(source) for p in source.rglob('*') if p.is_file()]
        updates = {rel: read_regular(source / rel) for rel in targets}
        old_skill = read_regular(self.skill / 'SKILL.md') if (self.skill / 'SKILL.md').exists() else read_regular(source / 'SKILL.md')
        content = old_skill.decode('utf-8')
        if content.count(MANAGED_BEGIN) != content.count(MANAGED_END) or content.count(MANAGED_BEGIN) > 1:
            raise SetupError('skill_managed_section_conflict')
        start = content.find(MANAGED_BEGIN)
        if start >= 0:
            end = content.find(MANAGED_END, start)
            if end < 0:
                raise SetupError('skill_managed_section_conflict')
            content = content[:start] + content[end + len(MANAGED_END):]
        updates[Path('SKILL.md')] = (content.rstrip() + '\n\n' + MANAGED_NOTE).encode()
        updates[Path('config/runtime-paths.json')] = (json.dumps(self.runtime_paths(), sort_keys=True) + '\n').encode()
        updates[Path('config/runtime-python.txt')] = (self.python + '\n').encode()
        backup = self.support / 'ToolingBackups' / uuid.uuid4().hex
        changed = []
        for rel, data in updates.items():
            target = self.skill / rel
            private_directory(target.parent)
            if os.path.lexists(target):
                old = read_regular(target)
                if old == data:
                    continue
                old_mode = target.lstat().st_mode & 0o777
                atomic_write(backup / rel, old, exclusive=True)
            else:
                old_mode = None
            changed.append((target, data, rel.parts[0] == 'bin', old_mode))
        applied = []
        current_existed = os.path.lexists(self.current)
        current_target = os.readlink(self.current) if self.current.is_symlink() else None
        current_replaced = False
        try:
            for target, data, executable, old_mode in changed:
                existed = os.path.lexists(target)
                atomic_write(target, data, exclusive=not existed, executable=executable)
                applied.append((target, existed, data, old_mode))
            if not self.companion.is_dir():
                return
            if current_existed and not self.current.is_symlink():
                raise SetupError('runtime_link_conflict')
            temporary = self.current.with_name('.runtime-' + uuid.uuid4().hex)
            try:
                temporary.symlink_to(self.companion)
                os.replace(temporary, self.current)
                current_replaced = True
            finally:
                temporary.unlink(missing_ok=True)
        except Exception as original_error:
            rollback_conflict = False
            for target, existed, installed_data, old_mode in reversed(applied):
                try:
                    if read_regular(target) != installed_data:
                        rollback_conflict = True
                        continue
                    if existed and old_mode is not None:
                        atomic_write(target, read_regular(backup / target.relative_to(self.skill)), mode=old_mode)
                    elif not existed:
                        target.unlink()
                except (OSError, SetupError):
                    rollback_conflict = True
            try:
                current_is_ours = self.current.is_symlink() and self.current.resolve() == self.companion.resolve()
                if current_replaced and current_existed and current_target is not None and current_is_ours:
                    temporary = self.current.with_name('.runtime-rollback-' + uuid.uuid4().hex)
                    temporary.symlink_to(current_target)
                    os.replace(temporary, self.current)
                elif current_replaced and not current_existed and current_is_ours:
                    self.current.unlink()
                elif current_replaced and not current_is_ours:
                    rollback_conflict = True
            except OSError:
                rollback_conflict = True
            if rollback_conflict:
                raise SetupError('rollback_conflict') from original_error
            raise

    def runtime_paths(self):
        return {'schemaVersion': 1, 'python': self.python, 'codex': self.codex}

    def hub_files(self, project):
        project = Path(project).resolve(strict=True)
        if not project.is_dir():
            raise SetupError('project_folder_missing')
        snapshot = json.loads(read_regular(self.support / 'account-manager-next-v1.json', 8 * 1024 * 1024))
        if not isinstance(snapshot, dict) or snapshot.get('schemaVersion') != 1 or not isinstance(snapshot.get('profiles'), list):
            raise SetupError('account_snapshot_invalid')
        if not all(isinstance(x, dict) and isinstance(x.get('isSystemProfile'), bool) for x in snapshot['profiles']):
            raise SetupError('account_snapshot_invalid')
        profiles = [x for x in snapshot['profiles'] if x.get('isSystemProfile') is False]
        if not 1 <= len(profiles) <= 26:
            raise SetupError('add_accounts_first')
        accounts, mapping, seen_ids, seen_homes, seen_aliases = [], [], set(), set(), set()
        expected_root = self.home / '.codex-account-manager-next/profiles'
        try:
            root_info = expected_root.lstat()
        except OSError as error:
            raise SetupError('account_identity_invalid') from error
        if not stat.S_ISDIR(root_info.st_mode) or expected_root.is_symlink():
            raise SetupError('account_identity_invalid')
        for profile in profiles:
            profile_id = profile.get('id', '')
            alias = 'next-' + profile_id.lower() if isinstance(profile_id, str) else ''
            if (not isinstance(profile_id, str) or not re.fullmatch(r'[A-Za-z0-9]{1,48}', profile_id)
                    or profile_id in seen_ids or alias in seen_aliases
                    or ('automaticSwitchParticipation' in profile and not isinstance(profile['automaticSwitchParticipation'], bool))):
                raise SetupError('account_identity_invalid')
            seen_ids.add(profile_id)
            seen_aliases.add(alias)
        seen_ids.clear()
        seen_aliases.clear()
        for index, profile in enumerate(profiles):
            profile_id = profile.get('id', '')
            if not re.fullmatch(r'[A-Za-z0-9]{1,48}', profile_id) or profile_id in seen_ids:
                raise SetupError('account_identity_invalid')
            raw_home = profile.get('codexHomePath', '')
            if not isinstance(raw_home, str) or not os.path.isabs(raw_home):
                raise SetupError('account_identity_invalid')
            account_home = Path(os.path.abspath(raw_home))
            expected_home = expected_root / profile_id
            try:
                home_info = account_home.lstat()
            except OSError as error:
                raise SetupError('account_identity_invalid') from error
            if (account_home != expected_home or not stat.S_ISDIR(home_info.st_mode) or account_home.is_symlink()
                    or account_home in seen_homes):
                raise SetupError('account_identity_invalid')
            seen_ids.add(profile_id); seen_homes.add(account_home)
            alias = 'next-' + profile_id.lower()
            if alias in seen_aliases:
                raise SetupError('account_identity_invalid')
            seen_aliases.add(alias)
            active = profile.get('automaticSwitchParticipation') is not False
            accounts.append({'alias': alias, 'home': str(account_home), 'dispatchDisabled': not active})
            mapping.append({'code': chr(65 + index), 'alias': alias, 'profileId': profile_id, 'priority': index + 1, 'active': active})
        config = {'listen': '127.0.0.1:8787', 'dataDir': str(self.hub / 'data'), 'requireToken': False,
                  'approvalTTLSeconds': 300, 'approvalQuotaMaxAgeSeconds': 300, 'mode': 'workspace-write',
                  'claudeMaxBudgetUSD': 1, 'accountStrategy': 'least_recently_used', 'accounts': accounts,
                  'commands': {'codex': self.codex}, 'projects': {'workspace': str(project)}}
        codes = {'schemaVersion': 1, 'snapshotMaxAgeSeconds': 45, 'minimumRemainingPercent': {'fiveHour': 0, 'sevenDay': 0},
                 'centralAliases': ['system'], 'accounts': mapping, 'hubProjects': {'workspace': str(project)}}
        log = self.home / 'Library/Logs/CodexAccountManagerNextHub'
        plist = {'Label': HUB_LABEL, 'ProgramArguments': [str(self.current / 'agent-remote-control'), '--config', str(self.hub / 'config.json')],
                 'WorkingDirectory': str(self.hub), 'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 10,
                 'EnvironmentVariables': {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'},
                 'StandardOutPath': str(log / 'service.log'), 'StandardErrorPath': str(log / 'service.log')}
        return {self.hub / 'config.json': (json.dumps(config, indent=2) + '\n').encode(),
                self.support / 'dispatch-codes-v1.json': (json.dumps(codes, indent=2) + '\n').encode(), self.agent: plistlib.dumps(plist)}

    def setup_hub(self, project):
        manifest = json.loads(read_regular(self.companion / 'manifest.json', 8192))
        if manifest.get('schemaVersion') != 1 or digest(self.companion / 'agent-remote-control') != manifest.get('sha256'):
            raise SetupError('companion_integrity_failed')
        with self.setup_lock():
            if self.hub_status() != 'setup_needed':
                raise SetupError('existing_hub_preserved')
            self.validate_inputs()
            files = self.hub_files(project)
            if any(os.path.lexists(p) for p in files):
                raise SetupError('existing_hub_configuration_preserved')
            self._install_tools_locked()
            for folder in [self.hub, self.agent.parent, self.home / 'Library/Logs/CodexAccountManagerNextHub']:
                private_directory(folder)
            created = []
            launch_attempted = False
            try:
                for path, data in files.items():
                    atomic_write(path, data, exclusive=True)
                    created.append((path, data))
                receipt = b'{"schemaVersion":1,"status":"bootstrap_attempted"}\n'
                atomic_write(self.hub_receipt, receipt, exclusive=True)
                created.append((self.hub_receipt, receipt))
                launch_attempted = True
                bounded_command(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(self.agent)])
            except Exception:
                if not launch_attempted:
                    for path, expected in reversed(created):
                        try:
                            if read_regular(path, max(len(expected), 1)) == expected:
                                path.unlink()
                        except (OSError, SetupError):
                            pass
                raise
            for _ in range(15):
                if self.hub_status() == 'ready':
                    atomic_write(self.hub_receipt, b'{"schemaVersion":1,"status":"ready"}\n')
                    return
                time.sleep(0.2)
            raise SetupError('hub_start_needs_review')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--resources', type=Path, required=True)
    p.add_argument('--python', type=Path)
    p.add_argument('--codex', type=Path, required=True)
    p.add_argument('command', choices=['check', 'install-tools', 'setup-hub'])
    p.add_argument('--project', type=Path)
    args = p.parse_args()
    setup = Setup(args.resources, python=args.python, codex=args.codex)
    try:
        if args.command == 'install-tools':
            setup.install_tools()
        elif args.command == 'setup-hub':
            if args.project is None:
                raise SetupError('project_folder_missing')
            setup.setup_hub(args.project)
        result = setup.check()
    except SetupError as e:
        result = {'schemaVersion': 1, 'components': [], 'skill': 'setup_needed', 'hub': 'unknown', 'error': str(e)}
    except Exception:
        result = {'schemaVersion': 1, 'components': [], 'skill': 'setup_needed', 'hub': 'unknown', 'error': 'setup_failed'}
    print(json.dumps(result, sort_keys=True))
    return 1 if result['error'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
