"""Offline thin-entry tests: fake executables, temp state dirs, no network.

Covers: argument arrays with spaces and quotes, run double-switch, timeout,
external cancel (happy/wrong-owner/stale-PID/idempotent), late output after
cancel, failure preserving results, concurrent duplicate reservation refusal,
and the rule that status/result never impersonate success.
"""
import base64
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
from unittest.mock import patch
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
import next_dispatch_activity as activity  # noqa: E402
import agent_cli_support as support        # noqa: E402

AGENT_CLI = SCRIPTS / "agent-cli.py"


def run_cli(argv, env_extra=None, cwd=None):
    env = dict(os.environ)
    env.pop("AGENT_CLI_ALLOW_RUN", None)
    env.pop("AGENT_CLI_ALLOW_TEST_EXECUTABLE", None)
    env.pop("AGENT_CLI_GROK_EXECUTABLE", None)
    env.pop("AGENT_CLI_GROK_MIN_RETURN_DIR", None)
    if env_extra:
        env.update(env_extra)
    return subprocess.run([sys.executable, str(AGENT_CLI)] + argv, capture_output=True,
                          text=True, env=env, cwd=cwd, timeout=120)


def reserve_worker(root, project, barrier, output):
    barrier.wait()
    try:
        activity.Registry(Path(root)).reserve(
            account_key=activity.digest("fixture-account"), alias_key=activity.digest("fixture"),
            code="A", project=activity.digest(project), owner="owner-" + str(os.getpid()),
            task="fixture-task", route="direct")
        output.put((True, "reserved"))
    except activity.ActivityError as error:
        output.put((False, str(error)))


def make_fake(directory: Path, name: str, body: str) -> Path:
    path = directory / name
    path.write_text(textwrap.dedent(body), encoding="utf-8")
    path.chmod(0o755)
    return path


def wait_for_state(registry, lease_id, states, timeout=15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        lease = next((x for x in registry.read()["leases"] if x["leaseId"] == lease_id), None)
        if lease and lease["state"] in states:
            return lease
        time.sleep(0.1)
    raise AssertionError("lease never reached " + str(states))


class AgentCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agent-cli-test-")
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.work = self.root / "work"
        self.work.mkdir(parents=True)
        self.registry = activity.Registry(self.state)

    def tearDown(self):
        self.temp.cleanup()

    # -- capabilities --------------------------------------------------------
    def fixture_receipts(self):
        import agent_cli_capabilities as caps
        root = self.work / "receipts"
        root.mkdir(exist_ok=True)
        for name in caps.RECEIPT_FILENAMES["workbuddy"]:
            (root / name).write_text("fixture receipt bytes", encoding="utf-8")
        return root

    def test_capabilities_lists_state_vocabulary_and_pins_workbuddy(self):
        root = self.fixture_receipts()
        import agent_cli_capabilities as caps
        done = run_cli(["capabilities"], env_extra={caps.RECEIPT_DIR_ENV: str(root)})
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        self.assertEqual(payload["stateVocabulary"],
                         ["installed", "authenticated", "quota-known", "minimal-verified",
                          "running", "result-ready", "accepted"])
        wb = payload["capabilities"]["workbuddy"]
        self.assertEqual(wb["run"]["model"], "deepseek-v4.1-flash")
        self.assertTrue(any("codebuddy/cbc" in c for c in wb["constraints"]))
        self.assertTrue(payload["receiptStatus"]["workbuddy"]["receipts"][0]["exists"])
        self.assertNotIn(str(root), json.dumps(payload), "published rows must not carry local paths")

    def test_capabilities_publish_no_private_absolute_paths(self):
        # Work-order boundary: the static catalog and receipt rows never carry
        # a private absolute path, with or without a receipt root configured.
        import agent_cli_capabilities as caps
        root = self.fixture_receipts()
        for env in ({}, {caps.RECEIPT_DIR_ENV: str(root)}):
            done = run_cli(["capabilities"], env_extra=env)
            self.assertEqual(done.returncode, 0, done.stderr)
            payload = json.dumps(json.loads(done.stdout), ensure_ascii=False)
            self.assertNotIn("/Users/", payload, "no user home paths may be published")
            self.assertNotIn(str(root), payload)
            self.assertNotIn("receiptDir", payload)

    def test_capabilities_without_receipt_root_fail_closed(self):
        # An unresolvable receipt root degrades minimal-verified to not proven
        # while declaredStatic stays visible for audit.
        import agent_cli_capabilities as caps
        done = run_cli(["capabilities", "--product", "workbuddy"],
                       env_extra={caps.RECEIPT_DIR_ENV: ""})
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        verified = payload["capabilities"]["workbuddy"]["minimalVerified"]
        self.assertFalse(verified["value"])
        self.assertNotIn("declaredStatic", verified)
        self.assertEqual(payload["receiptStatus"]["workbuddy"]["receipts"], [])

    def test_capabilities_single_product(self):
        done = run_cli(["capabilities", "--product", "grok"])
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        # 0911v8: Grok plan is reviewable, while the missing authenticated
        # native quota bridge keeps production run explicitly unavailable.
        self.assertTrue(payload["capabilities"]["grok"]["plan"]["supported"])
        self.assertFalse(payload["capabilities"]["grok"]["run"]["supported"])
        self.assertEqual(payload["capabilities"]["grok"]["run"]["reason"],
                         "grok_quota_bridge_missing")
        self.assertFalse(payload["capabilities"]["grok"]["quotaKnown"]["value"])
        self.assertEqual(set(payload["capabilities"]), {"grok"})

    def test_capabilities_unknown_product_is_usage_error(self):
        done = run_cli(["--state-dir", str(self.state), "capabilities", "--product", "nonsense"])
        self.assertEqual(done.returncode, 2)

    # -- plan ----------------------------------------------------------------
    def test_plan_workbuddy_accepts_spaces_and_quotes_and_pins_model(self):
        brief = self.work / "brief.md"
        brief.write_text("审查 'TaskRuntime' 的取消路径;  \"引用\" 与 空格 都要原样保留 — 中文 also", encoding="utf-8")
        output = self.work / "out one.md"
        done = run_cli(["--state-dir", str(self.state), "plan", "--product", "workbuddy",
                        "--brief-file", str(brief), "--output", str(output), "--executable", "/bin/echo"])
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        self.assertTrue(payload["planOnly"] and payload["willNotLaunch"])
        self.assertEqual(payload["model"], "deepseek-v4.1-flash")
        self.assertFalse(os.path.lexists(output), "plan must not create output files")

    def test_plan_workbuddy_refuses_other_models(self):
        brief = self.work / "brief.md"
        brief.write_text("x", encoding="utf-8")
        for model in ("hy4", "hy4-preview", "glm-5.3-flash"):
            done = run_cli(["--state-dir", str(self.state), "plan", "--product", "workbuddy",
                            "--brief-file", str(brief), "--output", str(self.work / "o.md"),
                            "--model", model])
            self.assertEqual(done.returncode, 3, model)
            self.assertIn("model_not_authorized_for_workbuddy", done.stderr)

    def test_plan_workbuddy_refuses_existing_output(self):
        brief = self.work / "brief.md"
        brief.write_text("x", encoding="utf-8")
        output = self.work / "taken.md"
        output.write_text("existing", encoding="utf-8")
        done = run_cli(["--state-dir", str(self.state), "plan", "--product", "workbuddy",
                        "--brief-file", str(brief), "--output", str(output), "--executable", "/bin/echo"])
        self.assertEqual(done.returncode, 1)
        self.assertIn("output_already_exists_inspect_existing_run", done.stderr)

    def test_plan_workbuddy_refuses_output_inside_state_dir(self):
        brief = self.work / "brief.md"
        brief.write_text("x", encoding="utf-8")
        self.state.mkdir(parents=True, exist_ok=True)
        done = run_cli(["--state-dir", str(self.state), "plan", "--product", "workbuddy",
                        "--brief-file", str(brief), "--output", str(self.state / "out.md")])
        self.assertEqual(done.returncode, 3)
        self.assertIn("output_inside_activity_state_refused", done.stderr)

    def test_plan_grok_executable_override_requires_test_switch(self):
        brief = self.work / "brief.md"
        brief.write_text("x", encoding="utf-8")
        fake = make_fake(self.work, "fake-grok", "#!/bin/sh\nexit 0\n")
        done = run_cli(["--state-dir", str(self.state), "plan", "--product", "grok",
                        "--brief-file", str(brief), "--output", str(self.work / "o.md"),
                        "--cwd", str(self.work), "--model", "grok-4.6-build",
                        "--executable", str(fake)])
        self.assertEqual(done.returncode, 3)
        self.assertIn("executable_override_requires_test_switch", done.stderr)

    def test_plan_codex_print_argv_only_is_a_plain_array(self):
        brief = self.work / "brief with space.md"
        brief.write_text("x", encoding="utf-8")
        done = run_cli(["--state-dir", str(self.state), "plan", "--product", "codex",
                        "--brief-file", str(brief), "--output", str(self.work / "o.md"),
                        "--cwd", str(self.work), "--print-argv-only"])
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        argv = payload["argv"]
        self.assertIsInstance(argv, list)
        self.assertTrue(all(isinstance(x, str) for x in argv))
        self.assertEqual(argv[0], "--state-dir")
        self.assertIn("plan", argv)
        self.assertNotIn("shell", " ".join(argv).lower().split("--sandbox")[0])

    # -- run double switch ---------------------------------------------------
    def test_run_requires_double_switch(self):
        brief = self.work / "brief.md"
        brief.write_text("x", encoding="utf-8")
        base = ["--state-dir", str(self.state), "run", "--product", "workbuddy",
                "--owner", "owner-a", "--task-id", "t-1",
                "--brief-file", str(brief), "--output", str(self.work / "o.md"),
                "--cwd", str(self.work), "--executable", "/bin/echo"]
        done = run_cli(base)
        self.assertEqual(done.returncode, 4)
        done = run_cli(base + ["--allow-run"])
        self.assertEqual(done.returncode, 4)
        self.assertIn("run_requires_explicit_double_switch", done.stderr)

    def test_run_happy_path_with_fake_executable(self):
        brief = self.work / "brief.md"
        brief.write_text("echo marker 任务", encoding="utf-8")
        output = self.work / "ok out.md"
        fake = make_fake(self.work, "fake-ok.sh", """\
            #!/bin/bash
            echo 'FAKE-OK marker'
            """)
        done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
                        "--owner", "owner-ok", "--task-id", "task-ok",
                        "--brief-file", str(brief), "--output", str(output),
                        "--cwd", str(self.work), "--executable", str(fake),
                        "--timeout-seconds", "30", "--allow-run"],
                       env_extra={"AGENT_CLI_ALLOW_RUN": "1", "AGENT_CLI_ALLOW_TEST_EXECUTABLE": "1"})
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        self.assertEqual(payload["lease"]["state"], "awaiting_acceptance")
        self.assertEqual(payload["lease"]["observableState"], "result-ready")
        self.assertIn("FAKE-OK marker", output.read_text(encoding="utf-8"))
        # result verifies the receipt but must not claim acceptance
        res = run_cli(["--state-dir", str(self.state), "result", "--output", str(output)])
        self.assertEqual(res.returncode, 0, res.stderr)
        result = json.loads(res.stdout)
        self.assertTrue(result["resultVerified"])
        self.assertEqual(result["observableState"], "result-ready")
        self.assertIn("not accepted", result["acceptanceNote"])

    def test_workbuddy_brief_uses_anonymous_stdin_not_process_arguments(self):
        brief = self.work / "brief.md"
        expected = "fixture-private-brief 引号 ' \"\n第二行\n".encode("utf-8")
        brief.write_bytes(expected)
        output = self.work / "stdin-output.json"
        fake = make_fake(self.work, "fake-stdin.py", f"""\
            #!{sys.executable}
            import base64, json, os, subprocess, sys
            data = sys.stdin.buffer.read()
            process_args = subprocess.check_output(
                ["/bin/ps", "-ww", "-p", str(os.getpid()), "-o", "args="], text=True)
            print(json.dumps({{"input": base64.b64encode(data).decode(),
                              "argv": sys.argv[1:], "processArgs": process_args,
                              "stdinLinks": os.fstat(0).st_nlink}}))
            """)
        done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
                        "--owner", "owner-stdin", "--task-id", "task-stdin",
                        "--brief-file", str(brief), "--output", str(output),
                        "--cwd", str(self.work), "--executable", str(fake),
                        "--timeout-seconds", "30", "--allow-run"],
                       env_extra=self.BOTH_SWITCHES)
        self.assertEqual(done.returncode, 0, done.stderr)
        observed = json.loads(output.read_text())
        self.assertEqual(base64.b64decode(observed["input"]), expected)
        self.assertEqual(observed["argv"], ["--model", "deepseek-v4.1-flash", "--input-format", "text", "-p"])
        self.assertNotIn("fixture-private-brief", observed["processArgs"])
        self.assertEqual(observed["stdinLinks"], 0, "stdin has no named filesystem entry")
        self.assertNotIn("fixture-private-brief", self.registry.path.read_text())
        self.assertNotIn("fixture-private-brief", support.invocation.receipt_path(output).read_text())

    def test_run_timeout_kills_and_marks_not_success(self):
        brief = self.work / "brief.md"
        brief.write_text("x", encoding="utf-8")
        output = self.work / "slow out.md"
        fake = make_fake(self.work, "fake-slow.sh", """\
            #!/bin/bash
            echo 'partial before hang'
            sleep 30
            """)
        done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
                        "--owner", "owner-slow", "--task-id", "task-slow",
                        "--brief-file", str(brief), "--output", str(output),
                        "--cwd", str(self.work), "--executable", str(fake),
                        "--timeout-seconds", "1", "--allow-run"],
                       env_extra={"AGENT_CLI_ALLOW_RUN": "1", "AGENT_CLI_ALLOW_TEST_EXECUTABLE": "1"})
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        self.assertTrue(payload["run"]["runTimedOut"])
        self.assertEqual(payload["lease"]["state"], "failed")
        self.assertIn("partial before hang", output.read_text(encoding="utf-8"))
        res = run_cli(["--state-dir", str(self.state), "result", "--output", str(output)])
        result = json.loads(res.stdout)
        self.assertFalse(result["executionSucceeded"])
        self.assertEqual(result["observableState"], "failed")

    def test_run_failure_preserves_partial_result(self):
        brief = self.work / "brief.md"
        brief.write_text("x", encoding="utf-8")
        output = self.work / "fail out.md"
        fake = make_fake(self.work, "fake-fail.sh", """\
            #!/bin/bash
            echo 'partial work before crash'
            exit 3
            """)
        done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
                        "--owner", "owner-fail", "--task-id", "task-fail",
                        "--brief-file", str(brief), "--output", str(output),
                        "--cwd", str(self.work), "--executable", str(fake),
                        "--timeout-seconds", "30", "--allow-run"],
                       env_extra={"AGENT_CLI_ALLOW_RUN": "1", "AGENT_CLI_ALLOW_TEST_EXECUTABLE": "1"})
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        self.assertEqual(payload["lease"]["state"], "failed")
        self.assertIn("partial work before crash", output.read_text(encoding="utf-8"))

    def test_timeout_refuses_reused_pid_and_preserves_failed_output(self):
        lease = self.registry.reserve(
            account_key=activity.digest("timeout-reuse"), alias_key=activity.digest("timeout-reuse"),
            code="A", project=activity.digest(str(self.work)), owner="owner-timeout",
            task="task-timeout", route="direct")
        self.registry.update(lease["leaseId"], lease["ownerThreadId"], childPID=424242,
                             childPIDBirth=activity.digest("original-birth"), processGroupID=424242)
        output = self.work / "reused-pid.md"
        identity = support.create_exclusive_output(output)

        class ImmediateTimer:
            def __init__(self, interval, callback, args=()):
                self.callback, self.args = callback, args

            def start(self):
                self.callback(*self.args)

            def cancel(self):
                pass

        def supervisor(registry, record, argv, cwd, **callbacks):
            os.write(callbacks["stdout"], b"partial timeout output")
            callbacks["on_started"]()
            callbacks["on_exited"](0)
            with self.assertRaisesRegex(support.AgentCliError, "run_incomplete"):
                callbacks["verify_result"]()
            registry.update(record["leaseId"], record["ownerThreadId"], "failed", exitCode=0)
            return 1

        with patch.object(support.threading, "Timer", ImmediateTimer), \
                patch.object(activity, "supervise", supervisor), \
                patch.object(activity, "process_birth", return_value=activity.digest("different-birth")), \
                patch.object(support.os, "killpg") as signal_group:
            result = support.run_workbuddy_task(
                self.registry, lease, argv=["unused-fixture"], cwd=self.work,
                brief_path=self.work / "unused-brief.md", output=output,
                timeout=1, capture_limit=1024, output_identity=identity)
        signal_group.assert_not_called()
        self.assertTrue(result["runTimedOut"])
        self.assertTrue(result["runTimeoutStopRefused"])
        self.assertEqual(result["exitCode"], 0, "a timeout must not fabricate an exit code")
        self.assertEqual(result["phase"], "failed")
        self.assertEqual(output.read_text(), "partial timeout output")

    # -- cancel --------------------------------------------------------------
    def test_cancel_happy_path_and_idempotence(self):
        project_dir = self.work / "cancel-ok"
        project_dir.mkdir()
        brief = project_dir / "brief.md"
        brief.write_text("x", encoding="utf-8")
        output = project_dir / "out.md"
        fake = make_fake(self.work, "fake-cancel.sh", """\
            #!/bin/bash
            # /bin/echo (external) writes immediately; a bash builtin would keep
            # 'tick' in an unflushed buffer that SIGTERM would destroy.
            /bin/echo tick
            sleep 30
            """)
        env = dict(os.environ)
        env["AGENT_CLI_ALLOW_RUN"] = "1"
        env["AGENT_CLI_ALLOW_TEST_EXECUTABLE"] = "1"
        proc = subprocess.Popen(
            [sys.executable, str(AGENT_CLI), "--state-dir", str(self.state), "run",
             "--product", "workbuddy", "--owner", "owner-cancel", "--task-id", "task-cancel",
             "--brief-file", str(brief), "--output", str(output), "--cwd", str(project_dir),
             "--executable", str(fake), "--timeout-seconds", "60", "--allow-run"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        try:
            lease = None
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                candidates = [x for x in self.registry.read()["leases"]
                              if x["taskId"] == "task-cancel"]
                if candidates and candidates[0]["state"] == "running" and candidates[0].get("childPID"):
                    lease = candidates[0]
                    break
                time.sleep(0.1)
            self.assertIsNotNone(lease, "run never reached running state")
            # Give the child time to actually emit its line: a cancel racing
            # the child's own startup legitimately captures zero bytes.
            time.sleep(1.0)

            done = run_cli(["--state-dir", str(self.state), "cancel", "--product", "workbuddy",
                            "--lease-id", lease["leaseId"], "--owner", "owner-cancel"])
            self.assertEqual(done.returncode, 0, done.stderr)
            payload = json.loads(done.stdout)
            self.assertEqual(payload["cancel"], "completed")
            after = next(x for x in self.registry.read()["leases"]
                         if x["leaseId"] == lease["leaseId"])
            self.assertIn(after["state"], {"cancelled", "failed"},
                          "external cancel races the supervisor; both are truthful terminals")
            self.assertFalse(after["state"] in {"awaiting_acceptance", "accepted"})
            self.assertIn("tick", output.read_text(encoding="utf-8"),
                          "partial stdout captured before the cancel must survive")

            again = run_cli(["--state-dir", str(self.state), "cancel", "--product", "workbuddy",
                             "--lease-id", lease["leaseId"], "--owner", "owner-cancel"])
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertEqual(json.loads(again.stdout)["cancel"], "idempotent_noop")
        finally:
            proc.communicate(timeout=90)

    def test_cancel_refuses_wrong_owner(self):
        project_dir = self.work / "cancel-owner"
        project_dir.mkdir()
        brief = project_dir / "brief.md"
        brief.write_text("x", encoding="utf-8")
        output = project_dir / "out.md"
        fake = make_fake(self.work, "fake-owner.sh", """\
            #!/bin/bash
            sleep 30
            """)
        env = dict(os.environ)
        env["AGENT_CLI_ALLOW_RUN"] = "1"
        env["AGENT_CLI_ALLOW_TEST_EXECUTABLE"] = "1"
        proc = subprocess.Popen(
            [sys.executable, str(AGENT_CLI), "--state-dir", str(self.state), "run",
             "--product", "workbuddy", "--owner", "owner-right", "--task-id", "task-owner",
             "--brief-file", str(brief), "--output", str(output), "--cwd", str(project_dir),
             "--executable", str(fake), "--timeout-seconds", "60", "--allow-run"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        try:
            lease = None
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                candidates = [x for x in self.registry.read()["leases"]
                              if x["taskId"] == "task-owner"]
                if candidates and candidates[0]["state"] == "running" and candidates[0].get("childPID"):
                    lease = candidates[0]
                    break
                time.sleep(0.1)
            self.assertIsNotNone(lease)
            done = run_cli(["--state-dir", str(self.state), "cancel",
                            "--lease-id", lease["leaseId"], "--owner", "owner-wrong"])
            self.assertEqual(done.returncode, 3, done.stderr)
            self.assertIn("cancel_refused_owner_mismatch", done.stderr)
            after = next(x for x in self.registry.read()["leases"]
                         if x["leaseId"] == lease["leaseId"])
            self.assertEqual(after["state"], "running", "refused cancel must not mutate the lease")
        finally:
            run_cli(["--state-dir", str(self.state), "cancel",
                     "--lease-id", lease["leaseId"], "--owner", "owner-right"])
            proc.communicate(timeout=90)

    def test_cancel_refuses_stale_pid_and_spares_live_group(self):
        sleeper = subprocess.Popen(["/bin/sleep", "20"], start_new_session=True)
        try:
            lease = self.registry.reserve(
                account_key=activity.digest("stale-account"), alias_key=activity.digest("stale"),
                code="B", project=activity.digest(str(self.work / "stale")),
                owner="owner-stale", task="task-stale", route="direct")
            # Record the live sleeper's PID with a deliberately wrong birth.
            self.registry.update(lease["leaseId"], "owner-stale",
                                 childPID=sleeper.pid, childPIDBirth=activity.digest("wrong-birth"),
                                 processGroupID=sleeper.pid)
            done = run_cli(["--state-dir", str(self.state), "cancel",
                            "--lease-id", lease["leaseId"], "--owner", "owner-stale"])
            self.assertEqual(done.returncode, 3, done.stderr)
            self.assertIn("stale_child_pid_refuses_signal", done.stderr)
            self.assertIsNone(sleeper.poll(), "the live group must survive a stale-PID cancel")
            after = next(x for x in self.registry.read()["leases"]
                         if x["leaseId"] == lease["leaseId"])
            self.assertEqual(after["state"], "preparing",
                             "refused cancel must not mutate the lease")
        finally:
            sleeper.kill()
            sleeper.wait(timeout=10)

    # -- registry semantics --------------------------------------------------
    def test_concurrent_duplicate_reservation_is_refused(self):
        if hasattr(multiprocessing, "set_start_method"):
            try:
                multiprocessing.set_start_method("fork")
            except RuntimeError:
                pass
        barrier = multiprocessing.Barrier(2)
        output = multiprocessing.Queue()
        project = str(self.work / "same-project")
        workers = [multiprocessing.Process(target=reserve_worker,
                                           args=(str(self.state), project, barrier, output))
                   for _ in range(2)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(timeout=30)
        results = [output.get() for _ in range(2)]
        states = sorted(ok for ok, _ in results)
        self.assertEqual(states, [False, True])
        self.assertIn("account_or_project_reserved", "".join(msg for ok, msg in results if not ok))

    def test_status_never_impersonates_success(self):
        lease = self.registry.reserve(
            account_key=activity.digest("status-account"), alias_key=activity.digest("status"),
            code="C", project=activity.digest(str(self.work / "status")),
            owner="owner-status", task="task-status", route="direct")
        self.registry.update(lease["leaseId"], "owner-status", "failed", exitCode=3)
        done = run_cli(["--state-dir", str(self.state), "status",
                        "--task-id", "task-status"])
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        row = payload["leases"][0]
        self.assertEqual(row["observableState"], "failed")
        self.assertFalse(row["occupied"])

    def test_status_corrupt_registry_has_only_redacted_errors(self):
        lease = self.registry.reserve(
            account_key=activity.digest("shape-account"), alias_key=activity.digest("shape"),
            code="C", project=activity.digest(str(self.work / "shape")),
            owner="owner-shape", task="task-shape", route="direct")
        original = self.registry.read()
        for field in ("leaseId", "ownerThreadId", "taskId", "state", "state_list", "code_list"):
            with self.subTest(field=field):
                row = dict(lease)
                if field.endswith("_list"):
                    row[field.removesuffix("_list")] = []
                else:
                    row.pop(field)
                self.registry.path.write_text(json.dumps({"schemaVersion": 1, "leases": [row]}))
                self.registry.path.chmod(0o600)
                before = self.registry.path.read_bytes()
                done = run_cli(["--state-dir", str(self.state), "status", "--lease-id", lease["leaseId"]])
                self.assertEqual(done.returncode, 1)
                self.assertEqual(done.stdout, "")
                self.assertNotIn("Traceback", done.stderr)
                self.assertNotIn(str(self.root), done.stderr)
                self.assertTrue(done.stderr.startswith("ACTIVITY_ERROR: "))
                if field.endswith("_list"):
                    self.assertEqual(done.stderr, "ACTIVITY_ERROR: operation_failed_no_private_details\n")
                self.assertEqual(self.registry.path.read_bytes(), before, "status never repairs registry state")
        self.registry.path.write_text(json.dumps(original))
        done = run_cli(["--state-dir", str(self.state), "status", "--lease-id", lease["leaseId"]])
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout)["leases"][0]["leaseId"], lease["leaseId"])

    # -- review hardening regressions (TASK-WB-ADAPTER-REVIEW-0911v1) --------
    BOTH_SWITCHES = {"AGENT_CLI_ALLOW_RUN": "1", "AGENT_CLI_ALLOW_TEST_EXECUTABLE": "1"}

    def test_cancel_before_claim_converges_to_cancelled(self):
        # T-01 / F-01B: cancelling a never-claimed lease converges the terminal
        # state honestly and frees the project instead of sticking forever.
        lease = self.registry.reserve(
            account_key=activity.digest("c1"), alias_key=activity.digest("c1"),
            code="A", project=activity.digest(str(self.work / "c1")),
            owner="owner-c1", task="task-c1", route="direct")
        done = run_cli(["--state-dir", str(self.state), "cancel",
                        "--lease-id", lease["leaseId"], "--owner", "owner-c1"])
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        self.assertEqual(payload["cancel"], "completed_no_runner_converged")
        self.assertEqual(payload["stop"]["signalled"], "none")
        after = next(x for x in self.registry.read()["leases"] if x["leaseId"] == lease["leaseId"])
        self.assertEqual(after["state"], "cancelled")
        # The project is usable again; a fresh run reaches a normal result.
        project = self.work / "c1"
        project.mkdir(exist_ok=True)
        brief = project / "brief.md"
        brief.write_text("x", encoding="utf-8")
        fake = make_fake(self.work, "fake-c1.sh", "#!/bin/bash\n/bin/echo recovered\n")
        done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
                        "--owner", "owner-c1b", "--task-id", "task-c1b",
                        "--brief-file", str(brief), "--output", str(project / "out.md"),
                        "--cwd", str(project), "--executable", str(fake),
                        "--timeout-seconds", "30", "--allow-run"], env_extra=self.BOTH_SWITCHES)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout)["lease"]["state"], "awaiting_acceptance")

    def test_cancel_refuses_non_group_leader_target(self):
        # T-07 / F-03A: a live child that is not its own process-group leader
        # must be refused; the unrelated process survives untouched.
        sleeper = subprocess.Popen(["/bin/sleep", "15"])  # inherits this test's pgid
        try:
            lease = self.registry.reserve(
                account_key=activity.digest("c2"), alias_key=activity.digest("c2"),
                code="A", project=activity.digest(str(self.work / "c2")),
                owner="owner-c2", task="task-c2", route="direct")
            birth = activity.process_birth(sleeper.pid)
            self.assertIsNotNone(birth)
            self.registry.update(lease["leaseId"], "owner-c2",
                                 childPID=sleeper.pid, childPIDBirth=birth,
                                 processGroupID=sleeper.pid)
            done = run_cli(["--state-dir", str(self.state), "cancel",
                            "--lease-id", lease["leaseId"], "--owner", "owner-c2"])
            self.assertEqual(done.returncode, 3, done.stderr)
            self.assertIn("target_not_process_group_leader", done.stderr)
            self.assertIsNone(sleeper.poll(), "the unrelated process must survive")
            after = next(x for x in self.registry.read()["leases"]
                         if x["leaseId"] == lease["leaseId"])
            self.assertEqual(after["state"], "preparing")
        finally:
            sleeper.kill()
            sleeper.wait(timeout=10)

    def test_run_child_env_is_minimized(self):
        # T-11 / F-09: the launched child never sees the armed switches or
        # provider credential variables. The decoy value is composed at
        # runtime precisely so no credential-looking literal lands in source.
        project = self.work / "envrun"
        project.mkdir(exist_ok=True)
        brief = project / "brief.md"
        brief.write_text("x", encoding="utf-8")
        output = project / "out.md"
        envdump = self.work / "env-dump.txt"
        fake = make_fake(self.work, "fake-env.sh", '#!/bin/bash\nenv > "$AGENTCLI_ENVFILE"\n')
        decoy = "not-a-credential-" + str(os.getpid())
        done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
                        "--owner", "owner-env", "--task-id", "task-env",
                        "--brief-file", str(brief), "--output", str(output),
                        "--cwd", str(project), "--executable", str(fake),
                        "--timeout-seconds", "30", "--allow-run"],
                       env_extra={**self.BOTH_SWITCHES, "OPENAI_API_KEY": decoy,
                                  "CODEX_HOME": "/decoy-home", "CODEBUDDY_AUTH_TOKEN": decoy,
                                  "CODEBUDDY_API_BASE_URL": decoy, "ANTHROPIC_API_KEY": decoy,
                                  "OPENCODE_AUTH_JSON": decoy, "AGENTCLI_ENVFILE": str(envdump)})
        self.assertEqual(done.returncode, 0, done.stderr)
        child_env = envdump.read_text()
        self.assertNotIn("AGENT_CLI_ALLOW_RUN=1", child_env)
        self.assertNotIn("AGENT_CLI_ALLOW_TEST_EXECUTABLE", child_env)
        self.assertNotIn(decoy, child_env)
        self.assertNotIn("CODEX_HOME=/decoy-home", child_env)

    def test_run_refuses_existing_receipt_with_fixed_code(self):
        # F-08: artifacts are probed before reserve; an external receipt is
        # never truncated and the error code matches plan's.
        project = self.work / "rec-exists"
        project.mkdir(exist_ok=True)
        brief = project / "brief.md"
        brief.write_text("x", encoding="utf-8")
        output = project / "out.md"
        output.write_text("prior artifacts", encoding="utf-8")
        receipt = output.with_name(output.name + ".next-run.json")
        receipt.write_text('{"external": true}\n', encoding="utf-8")
        fake = make_fake(self.work, "fake-r.sh", "#!/bin/bash\n/bin/echo boom\n")
        done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
                        "--owner", "owner-re", "--task-id", "task-re",
                        "--brief-file", str(brief), "--output", str(output),
                        "--cwd", str(project), "--executable", str(fake),
                        "--timeout-seconds", "30", "--allow-run"], env_extra=self.BOTH_SWITCHES)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertIn("output_already_exists_inspect_existing_run", done.stderr)
        self.assertEqual(receipt.read_text(), '{"external": true}\n')
        self.assertEqual(output.read_text(), "prior artifacts")
        status = run_cli(["--state-dir", str(self.state), "status", "--task-id", "task-re"])
        self.assertEqual(json.loads(status.stdout)["leases"], [],
                         "a refused run must not leave a reservation behind")

    def test_executable_override_requires_test_switch(self):
        # F-13: production path only ever uses the pinned catalog binary.
        brief = self.work / "e-brief.md"
        brief.write_text("x", encoding="utf-8")
        done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
                        "--owner", "owner-e", "--task-id", "task-e",
                        "--brief-file", str(brief), "--output", str(self.work / "e-out.md"),
                        "--cwd", str(self.work), "--executable", "/bin/echo", "--allow-run"],
                       env_extra={"AGENT_CLI_ALLOW_RUN": "1"})
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("executable_override_requires_test_switch", done.stderr)

    def test_receipt_existence_never_implies_minimal_verified(self):
        # F-11: minimal-verified is derived from referenced receipts; the
        # declared static value stays visible for audit and calls stay stable.
        import agent_cli_capabilities as caps
        real = self.work / "receipt.md"
        real.write_text("receipt", encoding="utf-8")
        missing = self.work / "missing.md"
        original = caps.RECEIPT_REFS
        try:
            caps.RECEIPT_REFS = {"workbuddy": [real]}
            first = caps.catalog_for("workbuddy")
            self.assertFalse(first["capabilities"]["workbuddy"]["minimalVerified"]["value"])
            caps.RECEIPT_REFS = {"workbuddy": [missing]}
            second = caps.catalog_for("workbuddy")
            self.assertFalse(second["capabilities"]["workbuddy"]["minimalVerified"]["value"])
            self.assertIsNone(second["capabilities"]["workbuddy"]["authenticated"]["value"])
            caps.RECEIPT_REFS = {"workbuddy": [real]}
            third = caps.catalog_for("workbuddy")
            self.assertFalse(third["capabilities"]["workbuddy"]["minimalVerified"]["value"],
                            "repeated calls must not drift after a missing-receipt probe")
        finally:
            caps.RECEIPT_REFS = original


    def test_capabilities_detect_installation_without_inventing_login(self):
        import agent_cli_capabilities as caps
        with patch.object(caps.shutil, "which", return_value=None):
            data = caps.catalog_for("codex")["capabilities"]["codex"]
            self.assertFalse(data["installed"]["value"])
            self.assertIsNone(data["authenticated"]["value"])
            self.assertFalse(data["minimalVerified"]["value"])
        with patch.object(caps.shutil, "which", return_value="/fixture/bin/codex"):
            data = caps.catalog_for("codex")["capabilities"]["codex"]
            self.assertTrue(data["installed"]["value"])
            self.assertIsNone(data["authenticated"]["value"])

    def test_workbuddy_free_model_is_passed_to_actual_child_argv(self):
        import agent_cli_capabilities as caps
        brief = self.work / "model-brief.md"
        brief.write_text("preserve quoted task", encoding="utf-8")
        fake = make_fake(self.work, "arguments.sh", "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
        for index, model in enumerate(caps.WORKBUDDY_FREE_MODELS):
            output = self.work / ("model-" + str(index) + ".md")
            done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
                "--owner", "model-owner", "--task-id", "model-task-" + str(index),
                "--brief-file", str(brief), "--output", str(output), "--cwd", str(self.work),
                "--executable", str(fake), "--model", model, "--allow-run"], env_extra=self.BOTH_SWITCHES)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(output.read_text().splitlines(), ["--model", model, "--input-format", "text", "-p"])
            payload = json.loads(done.stdout)
            self.assertEqual(payload["requestedModel"], model)
            self.assertIsNone(payload["observedModel"])
            self.assertIsNone(payload["observedCost"])

    def test_codex_run_delegates_to_existing_managed_entry(self):
        spec = importlib.util.spec_from_file_location("agent_cli_entry_fixture", AGENT_CLI)
        entry = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(entry)
        with patch.dict(os.environ, {"AGENT_CLI_ALLOW_RUN": "1"}), patch.object(entry.activity, "main", return_value=0) as managed:
            result = entry.main(["--state-dir", str(self.state), "run", "--product", "codex",
                "--owner", "fixture-owner", "--task-id", "fixture-task", "--code", "A",
                "--lease-id", "fixture-lease", "--capability-report", str(self.work / "cap.json"),
                "--brief-file", str(self.work / "brief.md"), "--output", str(self.work / "out.md"),
                "--cwd", str(self.work), "--allow-run"])
            self.assertEqual(result, 0)
            argv = managed.call_args.args[0]
            self.assertEqual(argv[2], "run")
            self.assertEqual(argv[argv.index("--lease-id") + 1], "fixture-lease")
            self.assertEqual(argv[argv.index("--code") + 1], "A")
            self.assertEqual(self.registry.read()["leases"], [])

    def test_large_capture_is_bounded_and_not_successful(self):
        brief = self.work / "large-brief.md"
        brief.write_text("x")
        output = self.work / "large-out.md"
        fake = make_fake(self.work, "large.sh", "#!/bin/sh\n/usr/bin/yes x | /usr/bin/head -c 2097152\n")
        done = run_cli(["--state-dir", str(self.state), "run", "--product", "workbuddy",
            "--owner", "large-owner", "--task-id", "large-task", "--brief-file", str(brief),
            "--output", str(output), "--cwd", str(self.work), "--executable", str(fake), "--allow-run"],
            env_extra=self.BOTH_SWITCHES)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertLessEqual(output.stat().st_size, support.MAX_CHILD_CAPTURE_BYTES + len(support.TRUNCATION_MARKER))
        receipt = json.loads(output.with_name(output.name + ".next-run.json").read_text())
        self.assertTrue(receipt["capturedStdoutTruncated"])
        self.assertEqual(receipt["exitCode"], 0)
        self.assertEqual(receipt["phase"], "failed")

    def test_output_symlink_parent_boundaries(self):
        # T-17 / F-07: symlinked parents can neither sneak into the state dir
        # nor break a legitimate outside target.
        brief = self.work / "s-brief.md"
        brief.write_text("x", encoding="utf-8")
        outside = self.work / "outside"
        outside.mkdir()
        self.state.mkdir(parents=True, exist_ok=True)
        link_into_state = self.work / "link-into-state"
        link_outside = self.work / "link-outside"
        try:
            link_into_state.symlink_to(self.state, target_is_directory=True)
            link_outside.symlink_to(outside, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("symlink unsupported")
        done = run_cli(["--state-dir", str(self.state), "plan", "--product", "workbuddy",
                        "--brief-file", str(brief),
                        "--output", str(link_into_state / "out.md"), "--executable", "/bin/echo"])
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("output_inside_activity_state_refused", done.stderr)
        done = run_cli(["--state-dir", str(self.state), "plan", "--product", "workbuddy",
                        "--brief-file", str(brief),
                        "--output", str(link_outside / "out.md"), "--executable", "/bin/echo"])
        self.assertEqual(done.returncode, 0, done.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
