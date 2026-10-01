"""Offline coordination tests: no real accounts, providers, Hub mutations or UI."""
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import next_dispatch_activity as activity
import next_dispatch_preflight as preflight


def reserve_worker(root, account, project, barrier, output):
    barrier.wait()
    try:
        value = activity.Registry(Path(root)).reserve(
            account_key=activity.digest(account), alias_key=activity.digest(account), code="A",
            project=activity.digest(project), owner="owner-" + str(os.getpid()),
            task="fixture-task", route="direct")
        output.put((True, value["state"]))
    except activity.ActivityError as error:
        output.put((False, str(error)))


def issue_worker(root, number):
    activity.Registry(Path(root)).issue(issue_id="shared-issue", component="cli", phase="observed",
                                       summary="Concurrent observation " + str(number))


def fixture_process_birth(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    return activity.digest(str(pid))


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="next-dispatch-test-")
        self.root = Path(self.temp.name)
        self.registry = activity.Registry(self.root / "state")
        self.work = self.root / "work"
        self.work.mkdir()
        self.birth_patch = patch.object(activity, "process_birth", side_effect=fixture_process_birth)
        self.group_patch = patch.object(activity, "group_has_live_process", return_value=False)
        self.birth_patch.start()
        self.group_patch.start()
        self.addCleanup(self.birth_patch.stop)
        self.addCleanup(self.group_patch.stop)

    def tearDown(self):
        self.temp.cleanup()

    def reserve(self, account="account-a", project=None, owner="owner-one", task="task-one"):
        return self.registry.reserve(account_key=activity.digest(account), alias_key=activity.digest(account),
                                     code="A", project=project or activity.project_key(self.work),
                                     owner=owner, task=task, route="direct")

    def race(self, accounts, projects):
        ctx = multiprocessing.get_context("fork")
        barrier, output = ctx.Barrier(2), ctx.Queue()
        processes = [ctx.Process(target=reserve_worker, args=(str(self.registry.root), accounts[i], projects[i], barrier, output)) for i in range(2)]
        for process in processes:
            process.start()
        results = [output.get(timeout=5) for _ in processes]
        for process in processes:
            process.join(5)
            self.assertEqual(process.exitcode, 0)
        return results

    def test_alias_conflict_blocks_distinct_identity_and_project(self):
        self.reserve()
        before = self.registry.path.read_bytes()
        with self.assertRaisesRegex(activity.ActivityError, "account_or_project_reserved"):
            self.registry.reserve(account_key=activity.digest("other-account"),
                                  alias_key=activity.digest("account-a"), code="B",
                                  project=activity.digest("other-project"), owner="other-owner",
                                  task="other-task", route="direct")
        self.assertEqual(self.registry.path.read_bytes(), before)

    def test_preflight_alias_conflict_blocks_changed_identity(self):
        snapshot, report = self.report_fixture()
        self.registry.reserve(account_key=activity.digest("previous-identity"),
                              alias_key=activity.digest("fixture-a"), code="A",
                              project=activity.digest("other-project"), owner="other-owner",
                              task="other-task", route="direct")
        result = activity.merge_preflight(report("A"), snapshot, self.registry.read(), self.work)
        self.assertFalse(result["preflightPassed"])
        self.assertIn("local_reserved", next(x for x in result["excluded"] if x["code"] == "A")["reasons"])

    def test_short_issue_write_does_not_poison_next_append(self):
        args = dict(issue_id="fixture", component="cli", phase="observed", summary="Safe observation")
        self.registry.issue(**args)
        journal = self.registry.root / activity.ISSUE_NAME
        before = journal.read_bytes()
        real_write = os.write
        with patch.object(activity.os, "write", side_effect=lambda fd, data: real_write(fd, data[:7])):
            with self.assertRaisesRegex(activity.ActivityError, "issue_write_incomplete"):
                self.registry.issue(**args)
        self.assertEqual(journal.read_bytes(), before)
        self.registry.issue(**args)
        self.assertEqual(len([json.loads(line) for line in journal.read_text().splitlines()]), 2)

    def test_effective_state_time_boundaries(self):
        for state in sorted(activity.ACTIVE | activity.TERMINAL):
            lease = dict(state=state, createdAt=90, updatedAt=100, heartbeatDueAt=220)
            for now in (100, 220, 221):
                expected = "uncertain" if state in activity.ACTIVE and now > 220 else state
                self.assertEqual(activity.effective_state(lease, now), expected)
            self.assertEqual(activity.effective_state({**lease, "updatedAt": 105}, 100), state)
            expected = "uncertain" if state in activity.ACTIVE else state
            self.assertEqual(activity.effective_state({**lease, "updatedAt": 106}, 100), expected)

    def test_issue_fsync_failure_preserves_history(self):
        args = dict(issue_id="fixture", component="cli", phase="observed", summary="Safe observation")
        self.registry.issue(**args)
        journal = self.registry.root / activity.ISSUE_NAME
        before = journal.read_bytes()
        real_fsync = os.fsync
        calls = []
        def failing_once(fd):
            calls.append(fd)
            if len(calls) == 1:
                raise OSError("synthetic-storage-failure")
            return real_fsync(fd)
        with patch.object(activity.os, "fsync", side_effect=failing_once):
            with self.assertRaises(OSError):
                self.registry.issue(**args)
        self.assertEqual(journal.read_bytes(), before)

    def test_command_journal_failure_keeps_original_error_and_fixed_diagnostic(self):
        import contextlib
        import io
        diagnostic = io.StringIO()
        with patch.object(activity.Registry, "issue", side_effect=OSError("synthetic-storage-failure")), contextlib.redirect_stderr(diagnostic):
            with self.assertRaisesRegex(activity.ActivityError, "reservation_owner_mismatch"):
                activity.main(["--state-dir", str(self.registry.root), "heartbeat", "--lease-id", "missing", "--owner", "owner"])
        self.assertIn("issue_journal_write_failed", diagnostic.getvalue())
        self.assertNotIn("synthetic-storage-failure", diagnostic.getvalue())

    def test_unavailable_group_evidence_blocks_terminal_mutation(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "running", processGroupID=99999)
        before = self.registry.path.read_bytes()
        with patch.object(activity, "group_has_live_process", side_effect=activity.ActivityError("process_group_evidence_unavailable")):
            with self.assertRaisesRegex(activity.ActivityError, "process_group_evidence_unavailable"):
                self.registry.update(lease["leaseId"], "owner-one", "awaiting_acceptance")
        self.assertEqual(self.registry.path.read_bytes(), before)

    def test_same_account_only_one_writer_wins(self):
        results = self.race(["a", "a"], ["project-a", "project-b"])
        self.assertEqual(sum(ok for ok, _ in results), 1)
        self.assertEqual(len(self.registry.read()["leases"]), 1)

    def test_same_real_project_only_one_writer_wins(self):
        results = self.race(["a", "b"], ["same-project", "same-project"])
        self.assertEqual(sum(ok for ok, _ in results), 1)

    def test_independent_accounts_and_projects_do_not_block(self):
        self.assertEqual(sum(ok for ok, _ in self.race(["a", "b"], ["one", "two"])), 2)

    def test_maintenance_occupies_without_a_process_and_preserves_task_defaults(self):
        lease = self.registry.reserve(account_key=activity.digest("account-a"), alias_key=activity.digest("account-a"),
                                      code="A", project=activity.project_key(self.work), owner="maintenance-owner",
                                      task="maintenance", route="maintenance")
        self.assertEqual(lease["state"], "preparing")
        self.assertNotIn("childPID", lease)
        with self.assertRaises(activity.ActivityError):
            self.reserve()
        self.assertEqual(preflight.execution_preference({}),
                         {"model": "gpt-6-astra", "reasoningEffort": "low", "serviceTier": "default",
                          "subagentMode": "standard"})
        saved = {"model": "gpt-5.5", "reasoningEffort": "high", "serviceTier": "fast"}
        self.assertEqual(preflight.execution_preference({"executionPreference": saved}),
                         {**saved, "subagentMode": "standard"})
        self.assertIsNone(preflight.execution_preference({"executionPreference": {
            **saved, "subagentMode": "unknown"
        }}))
        custom = {"sol_luna": {"name": "自定义中蹬", "useSavedModel": False,
            "model": "gpt-5.6-terra", "reasoningEffort": "xhigh", "subagentsEnabled": True,
            "subagentModel": "gpt-5.5", "subagentReasoningEffort": "high"}}
        customized = preflight.execution_preference({"executionPreference": {
            **saved, "subagentMode": "sol_luna", "customPresets": custom}})
        strategy = preflight.effective_strategy(customized)
        self.assertEqual((strategy["model"], strategy["reasoningEffort"], strategy["subagentModel"],
                          strategy["subagentReasoningEffort"], strategy["maximumConcurrentSubagents"]),
                         ("gpt-5.6-terra", "xhigh", "gpt-5.5", "high", 1))
        for bad in ({"extra": custom["sol_luna"]},
                    {"sol_luna": {**custom["sol_luna"], "name": " bad"}},
                    {"sol_luna": {**custom["sol_luna"], "name": "bad\u0085name"}},
                    {"sol_luna": {**custom["sol_luna"], "name": "bad\ud800name"}},
                    {"sol_luna": {**custom["sol_luna"], "model": []}},
                    {"sol_luna": {**custom["sol_luna"], "subagentsEnabled": "yes"}}):
            self.assertIsNone(preflight.execution_preference({"executionPreference": {
                **saved, "subagentMode": "sol_luna", "customPresets": bad}}))
        fast_saved_unsupported = preflight.execution_preference({"executionPreference": {
            "model": "gpt-5.2", "reasoningEffort": "xhigh", "serviceTier": "fast",
            "subagentMode": "sol_luna"}})
        self.assertIsNotNone(fast_saved_unsupported)
        self.assertEqual(preflight.effective_strategy(fast_saved_unsupported)["model"], "gpt-6.1-sol")

    def test_directory_aliases_have_same_key(self):
        link = self.root / "linked"
        link.symlink_to(self.work, target_is_directory=True)
        self.assertEqual(activity.project_key(link), activity.project_key(self.work))

    def test_preparing_is_visible_before_any_process_exists(self):
        lease = self.reserve()
        saved = self.registry.read()["leases"][0]
        self.assertEqual(saved["state"], "preparing")
        self.assertNotIn("childPID", saved)
        self.assertIn(saved["state"], activity.ACTIVE)
        self.assertEqual(saved["leaseId"], lease["leaseId"])

    def test_retention_keeps_just_finished_first_record_and_all_active(self):
        just_finished = self.reserve(task="just-finished")
        self.registry.update(just_finished["leaseId"], "owner-one", "accepted")
        with self.registry.lock():
            state = self.registry.read()
            recent = state["leases"][0]
            recent["updatedAt"] = 10_000
            older = []
            for index in range(101):
                item = {**recent, "leaseId": f"00000000-0000-4000-8000-{index:012d}",
                        "ownerThreadId": f"old-owner-{index}", "taskId": f"old-task-{index}",
                        "updatedAt": float(1 if index in (1, 2) else index), "createdAt": float(index)}
                older.append(item)
            state["leases"] = [recent] + older
            self.registry._write(state)

        active = self.reserve(account="account-b", project=activity.digest("other-project"),
                              owner="owner-two", task="new-active")
        saved = self.registry.read()["leases"]
        terminals = [item for item in saved if item["state"] not in activity.ACTIVE]
        terminal_ids = {item["leaseId"] for item in terminals}
        self.assertEqual(len(terminals), 100)
        self.assertIn(just_finished["leaseId"], terminal_ids)
        self.assertNotIn("00000000-0000-4000-8000-000000000000", terminal_ids)
        self.assertNotIn("00000000-0000-4000-8000-000000000001", terminal_ids)
        self.assertIn("00000000-0000-4000-8000-000000000002", terminal_ids)
        self.assertIn(active["leaseId"], {item["leaseId"] for item in saved})
        self.assertEqual(terminals, sorted(terminals, key=lambda item: (item["updatedAt"], item["leaseId"])))

    def test_stale_reservation_never_becomes_free(self):
        lease = self.reserve()
        with self.registry.lock():
            value = self.registry.read()
            value["leases"][0]["heartbeatDueAt"] = time.time() - 1
            self.registry._write(value)
        self.assertEqual(activity.effective_state(self.registry.read()["leases"][0]), "uncertain")
        with self.assertRaises(activity.ActivityError):
            self.reserve()
        with self.assertRaises(activity.ActivityError):
            self.registry.update(lease["leaseId"], "owner-one")

    def test_owner_and_live_process_protect_release(self):
        lease = self.reserve()
        with self.assertRaises(activity.ActivityError):
            self.registry.update(lease["leaseId"], "owner-two", "failed")
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(1)"])
        try:
            self.registry.update(lease["leaseId"], "owner-one", "running", childPID=process.pid, childPIDBirth=activity.process_birth(process.pid))
            with self.assertRaisesRegex(activity.ActivityError, "process_still_running"):
                self.registry.update(lease["leaseId"], "owner-one", "awaiting_acceptance")
        finally:
            process.wait(timeout=4)
        self.registry.update(lease["leaseId"], "owner-one", "awaiting_acceptance")
        self.assertNotIn(self.registry.read()["leases"][0]["state"], activity.ACTIVE)

    def test_failed_launch_releases_and_appends_issue(self):
        lease = self.reserve()
        with self.assertRaises(OSError):
            activity.supervise(self.registry, lease, [str(self.root / "missing-program")], self.work)
        self.assertEqual(self.registry.read()["leases"][0]["state"], "failed")
        issue = json.loads((self.registry.root / activity.ISSUE_NAME).read_text())
        self.assertIn("dateShanghai", issue)
        self.assertNotIn(str(self.root), json.dumps(issue))
        self.reserve(owner="new-owner", task="new-task")

    def test_success_waits_for_acceptance_and_has_actual_pid(self):
        lease = self.reserve()
        self.assertEqual(activity.supervise(self.registry, lease, [sys.executable, "-c", "import time; time.sleep(0.1)"], self.work), 0)
        saved = self.registry.read()["leases"][0]
        self.assertEqual(saved["state"], "awaiting_acceptance")
        self.assertIn("childPID", saved)
        self.assertEqual(saved["exitCode"], 0)
        self.registry.update(lease["leaseId"], "owner-one", "accepted")

    def test_failed_capability_starts_no_child(self):
        lease = self.reserve()
        marker = self.root / "should-not-exist"
        def blocked():
            raise activity.ActivityError("capability_check_not_passed")
        with self.assertRaises(activity.ActivityError):
            activity.supervise(self.registry, lease, [sys.executable, "-c", "raise SystemExit(88)"], self.work, before_start=blocked)
        self.assertNotIn("childPID", self.registry.read()["leases"][0])
        self.assertEqual(self.registry.read()["leases"][0]["state"], "failed")

    def test_one_reservation_cannot_start_twice(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "starting", claim=True,
                             runnerPID=os.getpid(), runnerPIDBirth=activity.process_birth(os.getpid()))
        with self.assertRaisesRegex(activity.ActivityError, "reservation_already_claimed"):
            activity.supervise(self.registry, lease, [sys.executable, "-c", "raise SystemExit(88)"], self.work)
        self.assertEqual(self.registry.read()["leases"][0]["state"], "starting")

    def test_heartbeat_retries_bounded_transient_lock_contention(self):
        registry = Mock()
        registry.update.side_effect = [activity.ActivityError("activity_lock_busy"),
                                       activity.ActivityError("activity_lock_busy"), {"state": "running"}]
        stop = Mock()
        stop.wait.return_value = False
        self.assertTrue(activity.renew_heartbeat(registry, "lease-one", "owner-one", stop, (0, 0)))
        self.assertEqual(registry.update.call_count, 3)
        registry.update.assert_called_with("lease-one", "owner-one")

    def test_heartbeat_does_not_retry_identity_or_storage_failure(self):
        for reason in ("reservation_owner_mismatch", "activity_state_invalid"):
            with self.subTest(reason=reason):
                registry = Mock()
                registry.update.side_effect = activity.ActivityError(reason)
                with self.assertRaisesRegex(activity.ActivityError, reason):
                    activity.renew_heartbeat(registry, "lease-one", "owner-one", Mock(), (0, 0))
                self.assertEqual(registry.update.call_count, 1)

    def test_heartbeat_lock_retries_have_a_hard_limit(self):
        registry = Mock()
        registry.update.side_effect = activity.ActivityError("activity_lock_busy")
        stop = Mock()
        stop.wait.return_value = False
        with self.assertRaisesRegex(activity.ActivityError, "activity_lock_busy"):
            activity.renew_heartbeat(registry, "lease-one", "owner-one", stop, (0, 0))
        self.assertEqual(registry.update.call_count, 3)

    def test_cli_descendants_keep_account_occupied(self):
        lease = self.reserve()
        command = [sys.executable, "-c", "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(0.7)'])"]
        with patch.object(activity, "group_has_live_process", side_effect=[True, True, False]):
            self.assertEqual(activity.supervise(self.registry, lease, command, self.work), 4)
            self.assertEqual(self.registry.read()["leases"][0]["state"], "uncertain")
            with self.assertRaisesRegex(activity.ActivityError, "process_group_still_running"):
                self.registry.update(lease["leaseId"], "owner-one", "failed")
            self.registry.update(lease["leaseId"], "owner-one", "failed")

    def test_reused_pid_does_not_identify_old_runner(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "running", childPID=99999, childPIDBirth=activity.digest("old"))
        with patch.object(activity, "process_birth", return_value=activity.digest("new")):
            self.registry.update(lease["leaseId"], "owner-one", "failed")

    def test_hub_sync_checks_identity_and_preserves_review_phase(self):
        lease = self.registry.reserve(account_key=activity.digest("a"), alias_key=activity.digest("fixture-a"), code="A",
                                      project=activity.project_key(self.work), owner="owner", task="task", route="hub")
        mapping = {"hubProjects": {"fixture": str(self.work)}}
        task = {"id": "hub-one", "accountAlias": "fixture-a", "project": "fixture", "state": "running"}
        overview = {"accounts": ["fixture-a"], "projects": ["fixture"], "tasks": [task]}
        with self.assertRaises(activity.ActivityError):
            activity.sync_hub(self.registry, lease["leaseId"], "owner", "missing", self.work, mapping, overview, preflight)
        result = activity.sync_hub(self.registry, lease["leaseId"], "owner", "hub-one", self.work, mapping, overview, preflight)
        self.assertEqual(result["state"], "running")
        task["state"] = "succeeded"
        result = activity.sync_hub(self.registry, lease["leaseId"], "owner", "hub-one", self.work, mapping, overview, preflight)
        self.assertEqual(result["state"], "awaiting_acceptance")
        self.registry.update(lease["leaseId"], "owner", "accepted")
        result = activity.sync_hub(self.registry, lease["leaseId"], "owner", "hub-one", self.work, mapping, overview, preflight)
        self.assertEqual(result["state"], "accepted")

    def test_hub_sync_preserves_cancel_intent_until_verified_terminal(self):
        for terminal in ("succeeded", "failed", "cancelled", "blocked_configuration"):
            lease = self.registry.reserve(account_key=activity.digest("a"), alias_key=activity.digest("fixture-a"), code="A",
                                          project=activity.project_key(self.work), owner="owner", task="task", route="hub")
            mapping = {"hubProjects": {"fixture": str(self.work)}}
            task = {"id": "hub-one", "accountAlias": "fixture-a", "project": "fixture", "state": "running"}
            overview = {"accounts": ["fixture-a"], "projects": ["fixture"], "tasks": [task]}
            self.registry.update(lease["leaseId"], "owner", "cancel_requested")
            for active in ("awaiting_approval", "approved", "queued", "starting", "running", "uncertain"):
                task["state"] = active
                result = activity.sync_hub(self.registry, lease["leaseId"], "owner", "hub-one", self.work, mapping, overview, preflight)
                self.assertEqual(result["state"], "cancel_requested")
            task["state"] = terminal
            result = activity.sync_hub(self.registry, lease["leaseId"], "owner", "hub-one", self.work, mapping, overview, preflight)
            self.assertEqual(result["state"], "cancelled")
            self.assertEqual(task["state"], terminal, "actual Hub outcome is not rewritten")

    def test_failed_command_appends_same_journal(self):
        with self.assertRaises(activity.ActivityError):
            activity.main(["--state-dir", str(self.registry.root), "heartbeat", "--lease-id", "missing", "--owner", "owner"])
        record = json.loads((self.registry.root / activity.ISSUE_NAME).read_text())
        self.assertEqual(record["issueId"], "dispatch-heartbeat-failed")
        self.assertIn("dateShanghai", record)

    def test_concurrent_issue_appends_never_replace_history(self):
        ctx = multiprocessing.get_context("fork")
        processes = [ctx.Process(target=issue_worker, args=(str(self.registry.root), i)) for i in range(8)]
        for process in processes:
            process.start()
        for process in processes:
            process.join(5)
            self.assertEqual(process.exitcode, 0)
        lines = (self.registry.root / activity.ISSUE_NAME).read_text().splitlines()
        self.assertEqual(len(lines), 8)
        self.assertEqual(len({json.loads(x)["summary"] for x in lines}), 8)

    def test_journal_rejects_private_content_and_symlinks(self):
        for text in ["fixture@example.invalid", "/Users/private/file", "Bearer secret", "https://private.invalid/hook"]:
            with self.assertRaises(activity.ActivityError):
                self.registry.issue(issue_id="i", component="cli", phase="observed", summary=text)
        self.registry.root.mkdir(exist_ok=True, mode=0o700)
        target = self.root / "protected"
        target.write_text("preserve")
        (self.registry.root / activity.ISSUE_NAME).symlink_to(target)
        with self.assertRaises(OSError):
            self.registry.issue(issue_id="i", component="cli", phase="observed", summary="safe summary")
        self.assertEqual(target.read_text(), "preserve")

    def test_invalid_registry_fails_closed_without_overwriting(self):
        self.registry.root.mkdir(mode=0o700)
        self.registry.path.write_text("{broken")
        self.registry.path.chmod(0o600)
        with self.assertRaises(activity.ActivityError):
            self.reserve()
        self.assertEqual(self.registry.path.read_text(), "{broken")

    def test_hub_gate_failure_creates_no_reservation(self):
        def blocked():
            raise activity.ActivityError("hub_evidence_unavailable")
        with self.assertRaises(activity.ActivityError):
            self.registry.reserve(account_key=activity.digest("a"), alias_key=activity.digest("a"), code="A",
                                  project=activity.digest("p"), owner="o", task="t", route="hub", gate=blocked)
        self.assertEqual(self.registry.read()["leases"], [])

    def report_fixture(self):
        now = datetime.now(timezone.utc)
        at = now.timestamp() - preflight.APPLE_EPOCH_OFFSET
        def profile(identifier, email):
            return {"id": identifier, "name": email, "automaticSwitchParticipation": True,
                    "lastSnapshot": {"email": email, "planType": "plus", "quotaReadSucceeded": True, "fetchedAt": at,
                                     "fiveHour": {"usedPercent": 5, "resetsAt": at + 3600},
                                     "sevenDay": {"usedPercent": 10, "resetsAt": at + 86400}}}
        snapshot = {"profiles": [profile("a", "fixture-a@example.invalid"), profile("b", "fixture-b@example.invalid")]}
        mapping = {"accounts": [{"code": "A", "profileId": "a", "alias": "fixture-a", "priority": 1},
                                {"code": "B", "profileId": "b", "alias": "fixture-b", "priority": 2}],
                   "minimumRemainingPercent": {"fiveHour": 30, "sevenDay": 15}, "hubProjects": {}}
        overview = {"accounts": ["fixture-a", "fixture-b"], "projects": [], "tasks": []}
        def report(code=None):
            return preflight.build_report(snapshot, mapping, overview, now, self.work, 45, {"hubAvailable": True}, requested_code=code)
        return snapshot, report

    def test_preflight_excludes_preparing_account_and_owner_can_continue(self):
        snapshot, report = self.report_fixture()
        lease = self.registry.reserve(account_key=activity.identity_key(snapshot["profiles"][0]), alias_key=activity.digest("fixture-a"),
                                      code="A", project=activity.project_key(self.work), owner="owner", task="task", route="direct")
        blocked = activity.merge_preflight(report("A"), snapshot, self.registry.read(), self.work)
        self.assertFalse(blocked["preflightPassed"])
        self.assertTrue(any("local_reserved" in row["reasons"] for row in blocked["excluded"]))
        own = activity.merge_preflight(report("A"), snapshot, self.registry.read(), self.work, own_lease=lease["leaseId"], owner="owner")
        self.assertTrue(own["preflightPassed"])
        with self.assertRaises(activity.ActivityError):
            activity.merge_preflight(report("A"), snapshot, self.registry.read(), self.work, own_lease=lease["leaseId"], owner="wrong-owner")
        with self.assertRaises(activity.ActivityError):
            activity.merge_preflight(report("B"), snapshot, self.registry.read(), self.work, own_lease=lease["leaseId"], owner="owner")

    def test_priority_only_applies_to_eligible_candidates(self):
        snapshot, report = self.report_fixture()
        snapshot["profiles"][1]["prioritizeDispatch"] = True
        self.assertEqual(report()["selected"]["code"], "B")
        self.assertEqual(report("A")["selected"]["code"], "A")
        snapshot["profiles"][1]["lastSnapshot"]["fiveHour"]["usedPercent"] = 95
        self.assertEqual(report()["selected"]["code"], "A")

    def run_fixture(self, name):
        """Synthetic run/plan fixtures; no real account, provider or Home is used."""
        case = self.root / name
        case.mkdir()
        work = case / "work"; work.mkdir()
        home = case / "profile-home"; home.mkdir()
        brief = case / "brief.txt"; brief.write_text("Synthetic brief.\n")
        cli = case / "codex"
        cli.write_text('#!/bin/sh\ntouch "$EXECUTION_MARKER"\n')
        cli.chmod(0o700)
        marker = case / "executed"
        profile = {"id": "fixture-profile", "name": "fixture-identity", "codexHomePath": str(home),
                   "executionPreference": {"model": "gpt-6-astra", "reasoningEffort": "low", "serviceTier": "default"},
                   "lastSnapshot": {"email": "fixture-identity", "planType": "plus", "quotaReadSucceeded": True}}
        mapping = {"accounts": [{"code": "A", "alias": "fixture-a"}]}

        def account_context(_pre, _code):
            return mapping, {"profiles": [profile]}, mapping["accounts"][0], profile

        common = ["--code", "A", "--cwd", str(work), "--codex-bin", str(cli),
                  "--brief-file", str(brief), "--output", str(case / "result.txt"),
                  "--subagent-mode", "standard"]
        return case, work, marker, profile, mapping, account_context, common

    def test_bad_capability_report_fails_before_claim_and_keeps_the_lease(self):
        case, work, marker, profile, mapping, account_context, common = self.run_fixture("bad-capability")
        registry = activity.Registry(case / "state")
        lease = registry.reserve(account_key=activity.identity_key(profile), alias_key=activity.digest("fixture-a"),
                                 code="A", project=activity.project_key(work), owner="fixture-owner",
                                 task="fixture-task-bad-capability", route="direct")
        absent = case / "absent.json"

        with patch.object(activity, "account_context", side_effect=account_context), \
             patch.dict(os.environ, {"EXECUTION_MARKER": str(marker)}, clear=False):
            with self.assertRaisesRegex(activity.ActivityError, "capability_report_unavailable"):
                activity.main(["--state-dir", str(registry.root), "run"] + common +
                              ["--lease-id", lease["leaseId"], "--owner", "fixture-owner",
                               "--capability-report", str(absent)])
            # The reservation stays usable: the operator can fix the file and retry
            # with the same lease instead of re-reserving.
            saved = next(x for x in registry.read()["leases"] if x["leaseId"] == lease["leaseId"])
            self.assertEqual(saved["state"], "preparing")
            self.assertNotIn("runnerPID", saved)
            self.assertNotIn("childPID", saved)
            self.assertFalse(marker.exists())
            self.assertFalse((case / "result.txt").exists())

            # plan dry-run reports the same input problem without any reservation.
            with self.assertRaisesRegex(activity.ActivityError, "capability_report_unavailable"):
                activity.main(["--state-dir", str(case / "plan-state"), "plan"] + common +
                              ["--capability-report", str(absent)])
        self.assertFalse((case / "plan-state").exists())

    def test_unparseable_capability_report_is_named_and_does_not_launch(self):
        case, work, marker, profile, mapping, account_context, common = self.run_fixture("broken-capability")
        registry = activity.Registry(case / "state")
        lease = registry.reserve(account_key=activity.identity_key(profile), alias_key=activity.digest("fixture-a"),
                                 code="A", project=activity.project_key(work), owner="fixture-owner",
                                 task="fixture-task-broken-capability", route="direct")
        broken = case / "capability.json"
        broken.write_text("{not json")

        with patch.object(activity, "account_context", side_effect=account_context), \
             patch.dict(os.environ, {"EXECUTION_MARKER": str(marker)}, clear=False):
            with self.assertRaisesRegex(activity.ActivityError, "capability_report_invalid"):
                activity.main(["--state-dir", str(registry.root), "run"] + common +
                              ["--lease-id", lease["leaseId"], "--owner", "fixture-owner",
                               "--capability-report", str(broken)])
        saved = next(x for x in registry.read()["leases"] if x["leaseId"] == lease["leaseId"])
        self.assertEqual(saved["state"], "preparing")
        self.assertFalse(marker.exists())

    def test_terminal_lease_reports_preparing_reservation_required(self):
        case, work, marker, profile, mapping, account_context, common = self.run_fixture("terminal-lease")
        registry = activity.Registry(case / "state")
        lease = registry.reserve(account_key=activity.identity_key(profile), alias_key=activity.digest("fixture-a"),
                                 code="A", project=activity.project_key(work), owner="fixture-owner",
                                 task="fixture-task-terminal", route="direct")
        valid = case / "capability.json"
        valid.write_text('{"status": "passed"}')
        registry.update(lease["leaseId"], "fixture-owner", "failed")

        with patch.object(activity, "account_context", side_effect=account_context), \
             patch.dict(os.environ, {"EXECUTION_MARKER": str(marker)}, clear=False):
            with self.assertRaisesRegex(activity.ActivityError, "preparing_reservation_required"):
                activity.main(["--state-dir", str(registry.root), "run"] + common +
                              ["--lease-id", lease["leaseId"], "--owner", "fixture-owner",
                               "--capability-report", str(valid)])
        self.assertEqual(next(x for x in registry.read()["leases"]
                              if x["leaseId"] == lease["leaseId"])["state"], "failed")
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
