"""Invocation regression tests; fake CLI only, no live state or provider calls."""
import contextlib
import hashlib
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import next_dispatch_invocation as invocation
import next_dispatch_activity as activity
import next_dispatch_preflight as preflight


class InvocationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='next-invocation-test-')
        self.root = Path(self.temp.name).resolve()
        self.brief = self.root / 'brief.txt'
        self.brief.write_text('Prepare a local test result.\n')
        self.output = self.root / 'result.txt'
        self.cli = self.root / 'codex'
        self.cli.write_text('#!/bin/sh\nexit 0\n')
        self.cli.chmod(0o700)
        self.preference = {'model': 'gpt-6-astra', 'reasoningEffort': 'low', 'serviceTier': 'default'}

    def tearDown(self):
        self.temp.cleanup()

    def make(self):
        return invocation.Invocation(brief=self.brief, output=self.output, executable=self.cli,
            preference=self.preference, sandbox='workspace-write', code='A')

    def test_preview_is_read_only_and_does_not_expose_body_or_paths(self):
        before = set(self.root.iterdir())
        report = self.make().preview()
        self.assertEqual(set(self.root.iterdir()), before)
        self.assertFalse(report['dispatchExecuted'])
        self.assertTrue(report['preflightRequired'] and report['capabilityRequired'])
        encoded = json.dumps(report)
        self.assertNotIn(str(self.root), encoded)
        self.assertNotIn(self.brief.read_text().strip(), encoded)

    def test_brief_is_frozen_and_duplicate_output_cannot_be_reused(self):
        run = self.make()
        original = run.brief
        self.brief.write_text('Changed after the preview')
        run.begin()
        self.assertEqual(run.brief, original)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(run.receipt.stat().st_mode & 0o777, 0o600)
        with self.assertRaisesRegex(invocation.InvocationError, 'output_already_exists'):
            self.make()

    def test_valid_result_and_tampering_are_distinguished(self):
        run = self.make(); run.begin()
        self.output.write_text('Done. The artifact still needs acceptance.\n')
        self.output.chmod(0o644)
        run.verify_success(); run.update(phase='awaiting_acceptance', exitCode=0)
        result = invocation.inspect_result(self.output)
        self.assertTrue(result['resultVerified'] and result['executionSucceeded'])
        self.assertTrue(result['acceptanceRequired'])
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.output.write_text('changed')
        changed = invocation.inspect_result(self.output)
        self.assertFalse(changed['resultVerified'])
        self.assertFalse(changed['executionSucceeded'])

    def test_pending_cancellation_receipt_remains_readable_and_never_succeeds(self):
        run = self.make(); run.begin()
        run.update(phase='cancel_requested', exitCode=None, maxRuntimeSeconds=10)
        result = invocation.inspect_result(self.output)
        self.assertEqual(result['phase'], 'cancel_requested')
        self.assertEqual(result['maxRuntimeSeconds'], 10)
        self.assertFalse(result['executionSucceeded'])
        self.assertFalse(result['resultVerified'])
        self.assertEqual(result['nextAction'], 'inspect_existing_run_before_retry')

    def test_output_and_receipt_replacement_are_detected_without_overwrite(self):
        run = self.make(); run.begin()
        old_output = self.root / 'old-output'
        self.output.rename(old_output)
        self.output.write_text('replacement')
        with self.assertRaisesRegex(invocation.InvocationError, 'final_message_invalid'):
            run.verify_success()
        self.assertEqual(self.output.read_text(), 'replacement')

        old_receipt = self.root / 'old-receipt'
        run.receipt.rename(old_receipt)
        run.receipt.write_text('{"external": true}')
        with self.assertRaisesRegex(invocation.InvocationError, 'receipt_changed'):
            run.update(phase='running')
        self.assertEqual(json.loads(run.receipt.read_text()), {'external': True})

    def test_empty_large_invalid_and_symlink_files_are_rejected(self):
        for data in [b' ', b'\xff', b'x' * (invocation.MAX_BRIEF_BYTES + 1)]:
            self.brief.write_bytes(data)
            with self.assertRaises(invocation.InvocationError): self.make()
        self.brief.unlink(); self.brief.symlink_to(self.cli)
        with self.assertRaises(invocation.InvocationError): self.make()
        fifo = self.root / 'fifo'; os.mkfifo(fifo)
        with self.assertRaises(invocation.InvocationError): invocation.file_hash(fifo)

    def test_invalid_large_fifo_and_symlink_outputs_are_rejected(self):
        run = self.make(); run.begin()
        self.output.write_bytes(b'\xff')
        with self.assertRaisesRegex(invocation.InvocationError, 'final_message_invalid'):
            run.verify_success()

        self.output.write_bytes(b'x' * (invocation.MAX_OUTPUT_BYTES + 1))
        with self.assertRaisesRegex(invocation.InvocationError, 'invalid_or_too_large'):
            run.verify_success()

        self.output.unlink()
        os.mkfifo(self.output)
        with self.assertRaisesRegex(invocation.InvocationError, 'final_message_invalid'):
            run.verify_success()
        self.output.unlink()
        self.output.symlink_to(self.cli)
        with self.assertRaisesRegex(invocation.InvocationError, 'final_message_invalid'):
            run.verify_success()

    def test_successful_process_without_a_final_message_fails_acceptance(self):
        registry = activity.Registry(self.root / 'state')
        lease = registry.reserve(account_key=activity.digest('fixture'), alias_key=activity.digest('fixture'),
            code='A', project=activity.project_key(self.root), owner='fixture-owner', task='fixture-task', route='direct')
        run = self.make()
        def fake_birth(pid):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return None
            return activity.digest(str(pid))
        with patch.object(activity, 'process_birth', side_effect=fake_birth), \
             patch.object(activity, 'group_has_live_process', return_value=False), \
             self.assertRaisesRegex(invocation.InvocationError, 'final_message_missing'):
            activity.supervise(registry, lease, [str(self.cli)], self.root, before_start=run.begin,
                               verify_result=run.verify_success)
        state = registry.read()['leases'][0]
        self.assertEqual(state['state'], 'failed')
        self.assertEqual(state['exitCode'], 0)

    def test_receipt_changed_by_another_writer_is_preserved(self):
        run = self.make(); run.begin()
        run.receipt.write_text('{"external": true}')
        with self.assertRaisesRegex(invocation.InvocationError, 'receipt_changed'):
            run.update(phase='running')
        self.assertEqual(json.loads(run.receipt.read_text()), {'external': True})

    def test_partial_write_and_interrupted_replace_preserve_last_complete_receipt(self):
        run = self.make(); run.begin()
        original = run.receipt.read_bytes()
        real_write = os.write
        writes = 0
        def fail_after_partial(fd, data):
            nonlocal writes
            if writes == 0:
                writes += 1
                return real_write(fd, data[:20])
            raise OSError('injected')
        with patch.object(invocation.os, 'write', side_effect=fail_after_partial), \
             self.assertRaisesRegex(invocation.InvocationError, 'receipt_unwritable'):
            run.update(phase='running')
        self.assertEqual(run.receipt.read_bytes(), original)
        self.assertEqual(invocation.inspect_result(self.output)['phase'], 'starting')

        with patch.object(invocation.os, 'replace', side_effect=KeyboardInterrupt), \
             self.assertRaises(KeyboardInterrupt):
            run.update(phase='running')
        self.assertEqual(run.receipt.read_bytes(), original)
        self.assertEqual(invocation.inspect_result(self.output)['phase'], 'starting')
        run.update(phase='running')
        self.assertEqual(invocation.inspect_result(self.output)['phase'], 'running')

    def test_readonly_command_failure_does_not_create_state_or_issue_journal(self):
        state = self.root / 'state'
        with self.assertRaises(invocation.InvocationError):
            activity.main(['--state-dir', str(state), 'result', '--output', str(self.output)])
        self.assertFalse(state.exists())

        status = io.StringIO()
        with contextlib.redirect_stdout(status):
            self.assertEqual(activity.main(['--state-dir', str(state), 'status']), 0)
        self.assertEqual(json.loads(status.getvalue())['leases'], [])
        self.assertFalse(state.exists())

    def test_result_reads_existing_run_without_mutating_files_or_state(self):
        run = self.make(); run.begin()
        self.output.write_text('Review this result.\n')
        run.verify_success(); run.update(phase='awaiting_acceptance', exitCode=0)
        before = {path: (path.stat().st_mtime_ns, path.read_bytes()) for path in (self.output, run.receipt)}
        state = self.root / 'read-only-state'
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(activity.main(['--state-dir', str(state), 'result', '--output', str(self.output)]), 0)
        self.assertTrue(json.loads(stdout.getvalue())['resultVerified'])
        self.assertFalse(state.exists())
        self.assertEqual(before, {path: (path.stat().st_mtime_ns, path.read_bytes()) for path in before})

    def test_status_filters_and_wait_bounds(self):
        registry = activity.Registry(self.root / 'state')
        registry.reserve(account_key=activity.digest('fixture'), alias_key=activity.digest('fixture'), code='A',
            project=activity.project_key(self.root), owner='fixture-owner', task='fixture-task', route='direct')
        result = io.StringIO()
        with contextlib.redirect_stdout(result):
            activity.main(['--state-dir', str(registry.root), 'status', '--owner', 'another-owner'])
        self.assertEqual(json.loads(result.getvalue())['leases'], [])
        for value in ['-1', '61', 'nan', 'inf']:
            with self.assertRaises(Exception): activity.bounded_wait(value)

    def test_execute_plan_and_run_use_frozen_stdin_and_exact_parameters(self):
        for mode, subagent_mode, expected_model, expected_effort, expected_code, expected_state, expected_verified in [
                ('success', 'standard', 'gpt-5.6-sol', 'medium', 0, 'awaiting_acceptance', True),
                ('empty', 'sol_luna', 'gpt-5.6-terra', 'xhigh', None, 'failed', False),
                ('nonzero', 'luna_direct', 'gpt-5.6-luna', 'max', 17, 'failed', False)]:
            with self.subTest(mode=mode):
                case = self.root / mode
                case.mkdir()
                work = case / 'work'; work.mkdir()
                home = case / 'profile-home'; home.mkdir()
                brief = case / 'brief.txt'; brief.write_text('Frozen fake task.\n')
                output = case / 'result.txt'
                argv_log = case / 'argv.json'
                stdin_log = case / 'stdin.bin'
                cli = case / 'codex.js'
                cli.write_text(
                    '#!/usr/bin/env python3\n'
                    'import json, os, pathlib, sys\n'
                    'args = sys.argv[1:]\n'
                    'pathlib.Path(os.environ["FAKE_ARGV_LOG"]).write_text(json.dumps(args))\n'
                    'body = sys.stdin.buffer.read()\n'
                    'pathlib.Path(os.environ["FAKE_STDIN_LOG"]).write_bytes(body)\n'
                    'out = pathlib.Path(args[args.index("--output-last-message") + 1])\n'
                    'mode = os.environ["FAKE_MODE"]\n'
                    'if mode == "success": out.write_text("Fake final response.\\n")\n'
                    'elif mode == "empty": out.write_bytes(b"")\n'
                    'else: out.write_text("Not a successful result.\\n")\n'
                    'raise SystemExit(17 if mode == "nonzero" else 0)\n')
                cli.chmod(0o700)
                cli_entry = case / 'codex'
                cli_entry.symlink_to(cli.name)
                now = datetime.now(timezone.utc)
                apple_now = now.timestamp() - preflight.APPLE_EPOCH_OFFSET
                profile_preference = self.preference
                child_model, child_effort = 'gpt-5.6-luna', 'max'
                if subagent_mode == 'sol_luna':
                    child_model, child_effort = 'gpt-5.5', 'high'
                    profile_preference = {**self.preference, 'customPresets': {'sol_luna': {
                        'name': 'Display only custom worker', 'useSavedModel': False,
                        'model': expected_model, 'reasoningEffort': expected_effort,
                        'subagentsEnabled': True, 'subagentModel': child_model,
                        'subagentReasoningEffort': child_effort,
                    }}}
                profile = {
                    'id': 'fixture-profile', 'name': 'fixture-identity',
                    'codexHomePath': str(home), 'automaticSwitchParticipation': True,
                    'executionPreference': profile_preference,
                    'lastSnapshot': {
                        'email': 'fixture-identity', 'planType': 'plus',
                        'quotaReadSucceeded': True, 'fetchedAt': apple_now,
                        'fiveHour': {'usedPercent': 1, 'resetsAt': apple_now + 3600},
                        'sevenDay': {'usedPercent': 1, 'resetsAt': apple_now + 86400}}}
                snapshot = {'profiles': [profile]}
                mapping = {
                    'schemaVersion': 1, 'accounts': [{'code': 'A', 'profileId': 'fixture-profile',
                        'alias': 'fixture-a', 'priority': 1, 'active': True}],
                    'minimumRemainingPercent': {'fiveHour': 30, 'sevenDay': 15},
                    'hubProjects': {}}
                snapshot_path = case / 'snapshot.json'
                mapping_path = case / 'mapping.json'
                snapshot_path.write_text(json.dumps(snapshot))
                mapping_path.write_text(json.dumps(mapping))
                capability = case / 'capability.json'
                capability.write_text(json.dumps({
                    'status': 'passed', 'checkedAt': now.isoformat(),
                    'cliSHA256': invocation.file_hash(cli),
                    'supportedSubagentModes': ['sol_luna'],
                    'workerRoleSHA256': hashlib.sha256(
                        invocation.generated_role(child_model, child_effort)).hexdigest(),
                }))
                registry = activity.Registry(case / 'state')
                account = mapping['accounts'][0]

                def account_context(_pre, code):
                    self.assertEqual(code, 'A')
                    return (json.loads(mapping_path.read_text()), json.loads(snapshot_path.read_text()),
                            account, json.loads(snapshot_path.read_text())['profiles'][0])

                common = ['--code', 'A', '--cwd', str(work), '--codex-bin', str(cli_entry),
                          '--brief-file', str(brief), '--output', str(output),
                          '--subagent-mode', subagent_mode]
                if subagent_mode == 'standard':
                    common += ['--model', expected_model, '--effort', expected_effort]
                environment = {'FAKE_MODE': mode, 'FAKE_ARGV_LOG': str(argv_log),
                               'FAKE_STDIN_LOG': str(stdin_log)}
                def fake_birth(pid):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        return None
                    return activity.digest(str(pid))
                with patch.object(activity, 'account_context', side_effect=account_context), \
                     patch.object(activity, 'hub_gate', return_value={'accounts': ['fixture-a'], 'projects': [], 'tasks': []}), \
                     patch.object(activity, 'process_birth', side_effect=fake_birth), \
                     patch.object(activity, 'group_has_live_process', return_value=False), \
                     patch.dict(os.environ, environment, clear=False):
                    self.assertTrue(cli_entry.is_symlink())
                    self.assertEqual(cli_entry.resolve().name, 'codex.js')
                    if subagent_mode == 'sol_luna':
                        with self.assertRaisesRegex(activity.ActivityError, 'explicit_execution_override_conflicts'):
                            activity.main(['--state-dir', str(registry.root), 'plan'] + common +
                                          ['--model', 'gpt-5.6-luna'])
                    plan_stdout = io.StringIO()
                    with contextlib.redirect_stdout(plan_stdout):
                        self.assertEqual(activity.main(['--state-dir', str(registry.root), 'plan'] + common), 0)
                    plan = json.loads(plan_stdout.getvalue())
                    self.assertFalse(plan['dispatchExecuted'])
                    self.assertFalse(registry.root.exists())
                    self.assertFalse(output.exists())

                    if mode == 'success':
                        bad_type = case / 'not-a-file'
                        bad_type.mkdir()
                        bad_type_args = common.copy()
                        bad_type_args[bad_type_args.index('--codex-bin') + 1] = str(bad_type)
                        with self.assertRaisesRegex(invocation.InvocationError, 'executable_file_invalid'):
                            activity.main(['--state-dir', str(registry.root), 'plan'] + bad_type_args)

                        not_executable = case / 'renamed-cli'
                        not_executable.write_text('#!/bin/sh\nexit 0\n')
                        not_executable.chmod(0o600)
                        not_executable_args = common.copy()
                        not_executable_args[not_executable_args.index('--codex-bin') + 1] = str(not_executable)
                        with self.assertRaisesRegex(activity.ActivityError, 'codex_executable_invalid'):
                            activity.main(['--state-dir', str(registry.root), 'plan'] + not_executable_args)

                        mismatched = registry.reserve(account_key=activity.identity_key(profile),
                            alias_key=activity.digest('fixture-a'), code='A', project=activity.project_key(work),
                            owner='fixture-owner', task='fixture-task-sha-mismatch', route='direct')
                        bad_capability = case / 'bad-capability.json'
                        bad_capability.write_text(json.dumps({
                            'status': 'passed', 'checkedAt': now.isoformat(), 'cliSHA256': '0' * 64}))
                        mismatched_args = ['--state-dir', str(registry.root), 'run'] + common + [
                            '--lease-id', mismatched['leaseId'], '--owner', 'fixture-owner',
                            '--capability-report', str(bad_capability)]
                        with self.assertRaisesRegex(activity.ActivityError, 'capability_executable_changed'):
                            activity.main(mismatched_args)
                        self.assertFalse(output.exists())

                    if subagent_mode == 'sol_luna':
                        unsupported = registry.reserve(account_key=activity.identity_key(profile),
                            alias_key=activity.digest('fixture-a'), code='A', project=activity.project_key(work),
                            owner='fixture-owner', task='fixture-task-unsupported-mode', route='direct')
                        old_capability = case / 'old-capability.json'
                        old_capability.write_text(json.dumps({
                            'status': 'passed', 'checkedAt': now.isoformat(),
                            'cliSHA256': invocation.file_hash(cli),
                            'workerRoleSHA256': hashlib.sha256(
                                invocation.generated_role(child_model, child_effort)).hexdigest()}))
                        unsupported_args = ['--state-dir', str(registry.root), 'run'] + common + [
                            '--lease-id', unsupported['leaseId'], '--owner', 'fixture-owner',
                            '--capability-report', str(old_capability)]
                        with self.assertRaisesRegex(activity.ActivityError, 'subagent_mode_capability_missing'):
                            activity.main(unsupported_args)
                        self.assertFalse(output.exists())

                    lease = registry.reserve(account_key=activity.identity_key(profile),
                        alias_key=activity.digest('fixture-a'), code='A', project=activity.project_key(work),
                        owner='fixture-owner', task='fixture-task-' + mode, route='direct')
                    run_args = ['--state-dir', str(registry.root), 'run'] + common + [
                        '--lease-id', lease['leaseId'], '--owner', 'fixture-owner',
                        '--capability-report', str(capability)]
                    if mode == 'empty':
                        with self.assertRaisesRegex(invocation.InvocationError, 'final_message_missing'):
                            activity.main(run_args)
                    else:
                        self.assertEqual(activity.main(run_args), expected_code)

                args = json.loads(argv_log.read_text())
                self.assertEqual(args[0], 'exec')
                self.assertEqual(args[args.index('--model') + 1], expected_model)
                self.assertIn('model_reasoning_effort="' + expected_effort + '"', args)
                if subagent_mode != 'sol_luna':
                    self.assertFalse(any('next_preset_worker' in arg for arg in args))
                    expected_stdin = b'Frozen fake task.\n'
                    self.assertIn('agents.enabled=false', args)
                    self.assertIn('features.multi_agent_v2=false', args)
                else:
                    self.assertIn('agents.enabled=true', args)
                    self.assertIn('features.multi_agent_v2=true', args)
                    self.assertIn('agents.max_concurrent_threads_per_session=1', args)
                    self.assertIn('agents.default_subagent_model="' + child_model + '"', args)
                    self.assertIn('agents.default_subagent_reasoning_effort="' + child_effort + '"', args)
                    self.assertTrue(any('agents.next_preset_worker.config_file=' in arg for arg in args))
                    expected_stdin = invocation.collaboration_policy(
                        subagent_mode, {'subagentsEnabled': True}) + b'Frozen fake task.\n'
                    self.assertIn(b'do not specify model or reasoning-effort overrides in spawn requests',
                                  expected_stdin)
                self.assertEqual(args[-1], '-')
                self.assertNotIn('Frozen fake task.', json.dumps(args))
                self.assertEqual(stdin_log.read_bytes(), expected_stdin)
                state = next(item for item in registry.read()['leases'] if item['leaseId'] == lease['leaseId'])
                self.assertEqual(state['state'], expected_state)
                self.assertEqual(state.get('exitCode'), 0 if mode == 'empty' else expected_code)
                result = invocation.inspect_result(output)
                self.assertEqual(result['executionPreference']['subagentMode'], subagent_mode)
                self.assertEqual(result['effectiveExecutionPreference']['model'], expected_model)
                self.assertEqual(result['effectiveExecutionPreference']['reasoningEffort'], expected_effort)
                if subagent_mode == 'sol_luna':
                    frozen_role = output.with_name(output.name + '.next-resources') / 'next_preset_worker.toml'
                    self.assertEqual(frozen_role.read_bytes(), invocation.generated_role(child_model, child_effort))
                    self.assertEqual(result['workerRole']['sha256'],
                                     hashlib.sha256(frozen_role.read_bytes()).hexdigest())
                    self.assertEqual(result['workerRole']['model'], child_model)
                    self.assertIsNone(result['subagentExecution']['observed'])
                    self.assertNotIn('Display only custom worker', stdin_log.read_text())
                self.assertEqual(result['resultVerified'], expected_verified)
                self.assertEqual(result['executionSucceeded'], expected_verified)
                self.assertIsNotNone(result['processEndedAt'])
                self.assertEqual(result['resultCollectedAt'] is not None, expected_verified)

    def test_explicit_effective_overrides_fail_before_preview_or_execution(self):
        case = self.root / 'invalid-effective'
        case.mkdir()
        work = case / 'work'; work.mkdir()
        home = case / 'profile-home'; home.mkdir()
        brief = case / 'brief.txt'; brief.write_text('Synthetic brief.\n')
        output = case / 'result.txt'
        marker = case / 'executed'
        cli = case / 'codex'
        cli.write_text('#!/bin/sh\ntouch "$EXECUTION_MARKER"\n')
        cli.chmod(0o700)
        profile = {'id': 'fixture-profile', 'name': 'fixture-identity', 'codexHomePath': str(home),
                   'executionPreference': self.preference}
        mapping = {'accounts': [{'code': 'A', 'alias': 'fixture-a'}]}

        def account_context(_pre, _code):
            return mapping, {'profiles': [profile]}, mapping['accounts'][0], profile

        common = ['--code', 'A', '--cwd', str(work), '--codex-bin', str(cli),
                  '--brief-file', str(brief), '--output', str(output), '--subagent-mode', 'standard']
        invalid = [
            ['--model', 'not-a-model'],
            ['--effort', 'not-an-effort'],
            ['--model', 'gpt-5.5', '--effort', 'max'],
            ['--service-tier', 'fast', '--model', 'gpt-5.2', '--effort', 'high'],
        ]
        with patch.object(activity, 'account_context', side_effect=account_context), \
             patch.dict(os.environ, {'EXECUTION_MARKER': str(marker)}, clear=False):
            for overrides in invalid:
                with self.subTest(overrides=overrides), self.assertRaisesRegex(
                        activity.ActivityError, 'effective_execution_preference_invalid'):
                    activity.main(['--state-dir', str(case / 'state'), 'plan'] + common + overrides)
        self.assertFalse(marker.exists())
        self.assertFalse(output.exists())

    def test_unknown_mode_missing_role_and_legacy_receipt_boundaries(self):
        invalid = {**self.preference, 'subagentMode': 'unknown'}
        with self.assertRaisesRegex(invocation.InvocationError, 'subagent_mode_invalid'):
            invocation.Invocation(brief=self.brief, output=self.output, executable=self.cli,
                preference=invalid, sandbox='workspace-write', code='A')
        run = self.make(); run.begin()
        receipt = json.loads(run.receipt.read_text())
        receipt['executionPreference'].pop('subagentMode')
        run.receipt.write_text(json.dumps(receipt))
        self.output.write_text('legacy result\n')
        receipt['finalMessage'] = {'bytes': len(self.output.read_bytes()),
                                   'sha256': invocation.file_hash(self.output)}
        receipt.update(phase='awaiting_acceptance', exitCode=0)
        run.receipt.write_text(json.dumps(receipt))
        self.assertEqual(invocation.inspect_result(self.output)['executionPreference']['subagentMode'], 'standard')


if __name__ == '__main__': unittest.main()
