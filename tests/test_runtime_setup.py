"""First-use dependency setup, fully isolated from the user's tools and services."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime_setup', ROOT / 'scripts/next_runtime_setup.py')
setup = importlib.util.module_from_spec(spec); spec.loader.exec_module(setup)
package_spec = importlib.util.spec_from_file_location('companion_package', ROOT / 'scripts/prepare-companion-resources.py')
package = importlib.util.module_from_spec(package_spec); package_spec.loader.exec_module(package)


class RuntimeSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='next-runtime-test-')
        self.root = Path(self.temp.name).resolve()
        self.resources = self.root / 'resources'
        self.resources.mkdir()
        package.copy_public_skill(self.resources / 'CompanionSkill')
        self.codex = self.root / 'codex'
        self.codex.write_text(
            '#!/bin/sh\n'
            'if [ "$1" = "exec" ] && [ "$2" = "--help" ]; then\n'
            '  printf "%s\\n" "--output-last-message --sandbox --model"\n'
            'else\n'
            '  printf "codex-cli 0.154.0\\n"\n'
            'fi\n')
        self.codex.chmod(0o700)
        self.manager = setup.Setup(self.resources, home=self.root / 'user', python=sys.executable, codex=self.codex)
        companion = self.resources / 'CompanionHub'; companion.mkdir()
        hub = companion / 'agent-remote-control'; hub.write_text('#!/bin/sh\nprintf "0910v2-next\\n"\n'); hub.chmod(0o700)
        (companion / 'manifest.json').write_text(json.dumps({'schemaVersion': 1, 'sha256': setup.digest(hub)}))
        self.project = self.root / 'project'; self.project.mkdir()

    def tearDown(self): self.temp.cleanup()

    def test_packaged_files_cover_every_installer_requirement(self):
        support = self.resources / 'SupportTools'; support.mkdir()
        shutil.copyfile(ROOT / 'scripts/next_runtime_setup.py', support / 'next_runtime_setup.py')
        package.verify_resources(self.resources, require_hub=True)
        self.manager.install_tools()
        self.assertTrue(self.manager.skill_ready())
        (self.resources / 'CompanionSkill/references/onboarding-login.md').unlink()
        with self.assertRaises(SystemExit):
            package.verify_resources(self.resources, require_hub=True)

    def profiles(self):
        profile_home = self.manager.home / '.codex-account-manager-next/profiles/profileA'
        profile_home.mkdir(parents=True)
        self.manager.support.mkdir(parents=True, exist_ok=True)
        data = {'schemaVersion': 1, 'profiles': [
            {'id': 'system', 'isSystemProfile': True, 'codexHomePath': str(self.manager.home / '.codex')},
            {'id': 'profileA', 'isSystemProfile': False, 'codexHomePath': str(profile_home), 'automaticSwitchParticipation': False}]}
        (self.manager.support / 'account-manager-next-v1.json').write_text(json.dumps(data))
        return data

    def test_fresh_install_is_idempotent_and_does_not_install_external_runtimes(self):
        self.manager.install_tools()
        self.assertTrue(self.manager.skill_ready())
        self.assertFalse((self.resources / 'Runtime').exists())
        self.assertFalse((self.manager.home / '.local/bin/codex').exists())
        self.manager.install_tools()
        self.assertFalse((self.manager.support / 'ToolingBackups').exists())
        self.assertEqual(self.manager.current.resolve(), self.resources / 'CompanionHub')

    def test_existing_private_skill_policy_is_kept_and_changed_helpers_backed_up(self):
        self.manager.skill.mkdir(parents=True)
        (self.manager.skill / 'SKILL.md').write_text('# Personal policy\nKeep this exact policy.\n')
        (self.manager.skill / 'config').mkdir()
        policy = self.manager.skill / 'config/dispatch-policy-v1.json'; policy.write_text('{"personal": "unchanged"}')
        (self.manager.skill / 'scripts').mkdir()
        (self.manager.skill / 'scripts/next_dispatch_activity.py').write_text('# previous script\n')
        self.manager.install_tools()
        self.assertEqual(policy.read_text(), '{"personal": "unchanged"}')
        self.assertIn('Keep this exact policy.', (self.manager.skill / 'SKILL.md').read_text())
        backups = list((self.manager.support / 'ToolingBackups').glob('*/scripts/next_dispatch_activity.py'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), '# previous script\n')

    def test_sparse_existing_skill_gets_source_policy_without_overwriting_other_files(self):
        self.manager.skill.mkdir(parents=True)
        personal = self.manager.skill / 'personal.txt'; personal.write_text('keep')
        self.manager.install_tools()
        self.assertEqual(personal.read_text(), 'keep')
        self.assertEqual((self.manager.skill / 'SKILL.md').read_bytes(),
            (self.resources / 'CompanionSkill/SKILL.md').read_bytes())
        self.assertTrue(self.manager.skill_ready())

    def test_symlinked_skill_is_rejected_without_touching_destination(self):
        outside = self.root / 'outside'; outside.mkdir()
        self.manager.skill.parent.mkdir(parents=True)
        self.manager.skill.symlink_to(outside)
        with self.assertRaises(setup.SetupError): self.manager.install_tools()
        self.assertEqual(list(outside.iterdir()), [])

    def test_hub_configuration_uses_only_managed_accounts_and_selected_external_cli(self):
        self.profiles()
        files = self.manager.hub_files(self.project)
        config = json.loads(files[self.manager.hub / 'config.json'])
        self.assertEqual(config['commands'], {'codex': str(self.codex)})
        self.assertEqual(config['listen'], '127.0.0.1:8787')
        self.assertEqual(len(config['accounts']), 1)
        self.assertTrue(config['accounts'][0]['dispatchDisabled'])
        mapping = json.loads(files[self.manager.support / 'dispatch-codes-v1.json'])
        self.assertFalse(mapping['accounts'][0]['active'])
        self.assertFalse((self.manager.hub / 'config.json').exists())

    def test_system_home_masquerading_as_managed_account_is_rejected(self):
        data = self.profiles()
        data['profiles'][1]['codexHomePath'] = str(self.manager.home / '.codex')
        (self.manager.home / '.codex').mkdir()
        (self.manager.support / 'account-manager-next-v1.json').write_text(json.dumps(data))
        with self.assertRaisesRegex(setup.SetupError, 'account_identity_invalid'):
            self.manager.hub_files(self.project)

    def test_symlinked_managed_profile_is_rejected(self):
        data = self.profiles()
        profile = self.manager.home / '.codex-account-manager-next/profiles/profileA'
        profile.rmdir()
        outside = self.root / 'outside-profile'; outside.mkdir()
        profile.symlink_to(outside)
        (self.manager.support / 'account-manager-next-v1.json').write_text(json.dumps(data))
        with self.assertRaisesRegex(setup.SetupError, 'account_identity_invalid'):
            self.manager.hub_files(self.project)

    def test_case_colliding_profile_aliases_are_rejected(self):
        data = self.profiles()
        second_home = self.manager.home / '.codex-account-manager-next/profiles/profilea'
        data['profiles'].append({'id': 'profilea', 'isSystemProfile': False,
            'codexHomePath': str(second_home), 'automaticSwitchParticipation': True})
        (self.manager.support / 'account-manager-next-v1.json').write_text(json.dumps(data))
        with self.assertRaisesRegex(setup.SetupError, 'account_identity_invalid'):
            self.manager.hub_files(self.project)

    def test_malformed_participation_setting_is_rejected(self):
        data = self.profiles()
        data['profiles'][1]['automaticSwitchParticipation'] = 'false'
        (self.manager.support / 'account-manager-next-v1.json').write_text(json.dumps(data))
        with self.assertRaisesRegex(setup.SetupError, 'account_identity_invalid'):
            self.manager.hub_files(self.project)

    def test_install_rechecks_codex_exec_capabilities(self):
        self.codex.write_text('#!/bin/sh\nprintf "codex-cli 0.154.0\\n"\n')
        with self.assertRaisesRegex(setup.SetupError, 'codex_capability_missing'):
            self.manager.install_tools()

    def test_install_rolls_back_files_after_partial_write_failure(self):
        self.manager.skill.mkdir(parents=True)
        (self.manager.skill / 'SKILL.md').write_text('# Personal policy\n')
        original = setup.atomic_write
        writes = 0
        def fail_second_target(path, data, **kwargs):
            nonlocal writes
            if str(path).startswith(str(self.manager.skill)):
                writes += 1
                if writes == 2:
                    raise setup.SetupError('injected_write_failure')
            return original(path, data, **kwargs)
        with patch.object(setup, 'atomic_write', side_effect=fail_second_target):
            with self.assertRaisesRegex(setup.SetupError, 'injected_write_failure'):
                self.manager.install_tools()
        self.assertEqual((self.manager.skill / 'SKILL.md').read_text(), '# Personal policy\n')
        self.assertFalse((self.manager.skill / 'bin/next-dispatch').exists())

    def test_setup_lock_rejects_concurrent_mutation(self):
        with self.manager.setup_lock():
            with self.assertRaisesRegex(setup.SetupError, 'setup_in_progress'):
                with self.manager.setup_lock():
                    self.fail('second setup lock unexpectedly acquired')

    def test_existing_hub_is_never_installed_or_restarted(self):
        with patch.object(self.manager, 'hub_status', return_value='ready'), patch.object(setup, 'bounded_command') as command:
            with self.assertRaisesRegex(setup.SetupError, 'existing_hub_preserved'):
                self.manager.setup_hub(self.project)
            command.assert_not_called()
        self.assertFalse(self.manager.agent.exists())

    def test_new_hub_bootstrap_is_explicit_and_readback_verified(self):
        self.profiles()
        real_command = setup.bounded_command
        calls = []
        def command(args, **kwargs):
            if args[0] == '/bin/launchctl': calls.append(args); return ''
            return real_command(args, **kwargs)
        with patch.object(self.manager, 'hub_status', side_effect=['setup_needed', 'setup_needed', 'ready']), patch.object(setup, 'bounded_command', side_effect=command):
            self.manager.setup_hub(self.project)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], 'bootstrap')
        self.assertTrue(self.manager.agent.exists())
        self.assertEqual((self.manager.hub / 'config.json').stat().st_mode & 0o777, 0o600)

    def test_hub_file_creation_failure_rolls_back_for_safe_retry(self):
        self.profiles()
        original = setup.atomic_write
        hub_writes = 0
        def fail_second_hub_file(path, data, **kwargs):
            nonlocal hub_writes
            if path in {self.manager.hub / 'config.json', self.manager.support / 'dispatch-codes-v1.json', self.manager.agent}:
                hub_writes += 1
                if hub_writes == 2:
                    raise setup.SetupError('injected_hub_write_failure')
            return original(path, data, **kwargs)
        with patch.object(self.manager, 'hub_status', return_value='setup_needed'), \
                patch.object(setup, 'atomic_write', side_effect=fail_second_hub_file):
            with self.assertRaisesRegex(setup.SetupError, 'injected_hub_write_failure'):
                self.manager.setup_hub(self.project)
        self.assertFalse((self.manager.hub / 'config.json').exists())
        self.assertFalse((self.manager.support / 'dispatch-codes-v1.json').exists())
        self.assertFalse(self.manager.agent.exists())

    def test_ambiguous_bootstrap_failure_keeps_receipt_and_never_retries(self):
        self.profiles()
        real_command = setup.bounded_command
        def command(args, **kwargs):
            if args[0] == '/bin/launchctl':
                raise setup.SetupError('command_failed')
            return real_command(args, **kwargs)
        with patch.object(self.manager, 'hub_status', return_value='setup_needed'), \
                patch.object(setup, 'bounded_command', side_effect=command):
            with self.assertRaisesRegex(setup.SetupError, 'command_failed'):
                self.manager.setup_hub(self.project)
        self.assertTrue(self.manager.hub_receipt.exists())
        self.assertTrue((self.manager.hub / 'config.json').exists())
        with self.assertRaisesRegex(setup.SetupError, 'existing_hub_preserved'):
            self.manager.setup_hub(self.project)

    def test_health_version_must_match_bundled_hub(self):
        self.manager.hub.mkdir(parents=True)
        (self.manager.hub / 'config.json').write_text('{"listen":"127.0.0.1:8787"}')
        response = unittest.mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(
            {'status': 'ok', 'version': 'unrelated-service'}).encode()
        with patch.object(setup.socket, 'create_connection'), patch.object(setup.urllib.request.OpenerDirector, 'open', return_value=response):
            self.assertEqual(self.manager.hub_status(), 'port_conflict')

    def test_unrecognized_artifact_cannot_bless_matching_health_service(self):
        self.manager.hub.mkdir(parents=True)
        (self.manager.hub / 'config.json').write_text('{"listen":"0.0.0.0:8787"}')
        response = unittest.mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(
            {'status': 'ok', 'version': '0910v2-next'}).encode()
        with patch.object(setup.socket, 'create_connection'), patch.object(setup.urllib.request.OpenerDirector, 'open', return_value=response):
            self.assertEqual(self.manager.hub_status(), 'port_conflict')

    def test_literal_legacy_hub_wrapper_is_recognized_without_execution(self):
        config = self.root / 'legacy config.json'
        config.write_text('{"listen":"127.0.0.1:8787"}')
        self.manager.legacy_agent.parent.mkdir(parents=True, exist_ok=True)
        command = f'exec "/private/legacy tools/agent-remote-control" --config "{config}"'
        for suffix, expected in [('', True), ('; echo unexpected', False), ('$(echo unexpected)', False)]:
            value = {'Label': setup.LEGACY_LABEL, 'ProgramArguments': ['/bin/bash', '-c', command + suffix]}
            self.manager.legacy_agent.write_bytes(setup.plistlib.dumps(value))
            with patch.object(setup, 'bounded_command') as execute:
                self.assertEqual(self.manager.recognized_hub_artifact(), expected)
                execute.assert_not_called()

    def test_command_output_and_elapsed_time_are_bounded(self):
        with self.assertRaisesRegex(setup.SetupError, 'output_too_large'):
            setup.bounded_command([sys.executable, '-c', 'print("x"*100000)'])
        with self.assertRaisesRegex(setup.SetupError, 'timeout'):
            setup.bounded_command([sys.executable, '-c', 'import time; time.sleep(2)'], timeout=0.05)

    def test_cleanup_reaps_before_signaling_but_keeps_live_descendants(self):
        child = Mock(pid=987654321)
        child.poll.return_value = 0
        with patch.object(setup, 'process_group_exists', return_value=False), patch.object(setup.os, 'killpg') as kill:
            setup.cleanup_process_group(child, timeout=0)
            child.poll.assert_called()
            kill.assert_not_called()
        with patch.object(setup, 'process_group_exists', side_effect=[True, True, True, True, False, False, False]), \
                patch.object(setup.os, 'killpg') as kill:
            setup.cleanup_process_group(child, timeout=0)
            self.assertEqual(kill.call_args_list, [unittest.mock.call(child.pid, setup.signal.SIGTERM),
                                                  unittest.mock.call(child.pid, setup.signal.SIGKILL)])

    def test_cleanup_permission_error_requires_verified_group_absence(self):
        child = Mock(pid=987654321)
        child.poll.return_value = 0
        with patch.object(setup, 'process_group_exists', side_effect=[True, False, False]), \
                patch.object(setup.os, 'killpg', side_effect=PermissionError(1, 'synthetic denial')):
            with self.assertRaisesRegex(setup.SetupError, 'command_output_too_large'):
                try:
                    raise setup.SetupError('command_output_too_large')
                finally:
                    setup.cleanup_process_group(child, timeout=0)

    def test_cleanup_permission_error_with_remaining_group_fails_closed(self):
        child = Mock(pid=987654321)
        child.poll.return_value = 0
        with patch.object(setup, 'process_group_exists', return_value=True), \
                patch.object(setup.os, 'killpg', side_effect=PermissionError(1, 'synthetic denial')):
            with self.assertRaisesRegex(setup.SetupError, 'command_cleanup_failed') as result:
                setup.cleanup_process_group(child, timeout=0)
            self.assertIsInstance(result.exception.__cause__, PermissionError)

    def test_bounded_command_cleans_its_process_group(self):
        for parent_exits in (False, True):
            with self.subTest(parent_exits=parent_exits):
                marker = self.root / ('group-exit' if parent_exits else 'group-live')
                tail = '' if parent_exits else '; time.sleep(30)'
                source = (
                    'import os,pathlib,subprocess,sys,time; '
                    'pathlib.Path(sys.argv[1]).write_text(str(os.getpgrp())); '
                    'subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"])' + tail)
                with self.assertRaisesRegex(setup.SetupError, 'command_timeout'):
                    setup.bounded_command([sys.executable, '-c', source, str(marker)], timeout=0.3)
                group_id = int(marker.read_text())
                with self.assertRaises(ProcessLookupError):
                    os.killpg(group_id, 0)

    def test_rollback_restores_existing_executable_mode(self):
        self.manager.skill.mkdir(parents=True)
        (self.manager.skill / 'SKILL.md').write_text('# Personal policy\n')
        entry = self.manager.skill / 'bin/next-dispatch'
        entry.parent.mkdir(); entry.write_text('old entry\n'); entry.chmod(0o700)
        original = setup.atomic_write
        target_writes = 0
        def fail_second_target(path, data, **kwargs):
            nonlocal target_writes
            if str(path).startswith(str(self.manager.skill)):
                target_writes += 1
                if target_writes == 2:
                    raise setup.SetupError('injected_write_failure')
            return original(path, data, **kwargs)
        with patch.object(setup, 'atomic_write', side_effect=fail_second_target):
            with self.assertRaisesRegex(setup.SetupError, 'injected_write_failure'):
                self.manager.install_tools()
        self.assertEqual(entry.read_text(), 'old entry\n')
        self.assertEqual(entry.stat().st_mode & 0o777, 0o700)

    def test_rollback_preserves_concurrent_file_change(self):
        self.manager.skill.mkdir(parents=True)
        (self.manager.skill / 'SKILL.md').write_text('# Personal policy\n')
        entry = self.manager.skill / 'bin/next-dispatch'
        entry.parent.mkdir(); entry.write_text('old entry\n'); entry.chmod(0o700)
        original = setup.atomic_write
        target_writes = 0
        def change_then_fail(path, data, **kwargs):
            nonlocal target_writes
            if str(path).startswith(str(self.manager.skill)):
                target_writes += 1
                if target_writes == 2:
                    entry.write_text('concurrent change\n')
                    raise setup.SetupError('injected_write_failure')
            return original(path, data, **kwargs)
        with patch.object(setup, 'atomic_write', side_effect=change_then_fail):
            with self.assertRaisesRegex(setup.SetupError, 'rollback_conflict'):
                self.manager.install_tools()
        self.assertEqual(entry.read_text(), 'concurrent change\n')


if __name__ == '__main__': unittest.main()
