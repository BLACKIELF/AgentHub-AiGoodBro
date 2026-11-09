#!/usr/bin/env python3
"""Unified thin CLI entry for cooperating agents.

Subcommands: capabilities / inspect / plan / status / result / cancel, plus an optional
double-switched WorkBuddy run. Codex plan is delegated in-process to the
managed entry (next_dispatch_activity.main) verbatim; status/result/cancel
reuse the same shared Registry. This file is a thin layer, not a second
scheduler: it contains no process launching, no shell, no network, and never
reads credentials. It owns the WorkBuddy run path and a Grok adapter whose
production launch remains fail-closed until the native quota bridge exists.
Both retain the --allow-run AND AGENT_CLI_ALLOW_RUN=1 gate, and any eventual
child launch is delegated to the managed activity.supervise() supervisor.

Exit codes: 0 ok (including an idempotent re-cancel), 1 managed error reason,
2 usage, 3 safety refusal, 4 unsupported capability.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import next_dispatch_activity as activity          # noqa: E402 (managed module, reused)
import next_dispatch_invocation as invocation      # noqa: E402 (managed module, reused)
import agent_cli_capabilities as capabilities      # noqa: E402
import agent_cli_grok as grok                      # noqa: E402 (thin grok candidate)
import agent_cli_support as support                # noqa: E402
import agent_cli_snapshot as snapshot              # noqa: E402
from agent_cli_support import AgentCliError, Refusal, Unsupported  # noqa: E402

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_REFUSED = 3
EXIT_UNSUPPORTED = 4
MANAGED_SCRIPT = str(SCRIPT_DIR / "next_dispatch_activity.py")
WORKBUDDY_MODEL = capabilities.WORKBUDDY_MODEL


def emit(payload) -> None:
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2))


def cmd_capabilities(args, registry) -> int:
    emit(capabilities.catalog_for(args.product))
    return EXIT_OK


def cmd_status(args, registry) -> int:
    state = registry.read()
    leases = state["leases"]
    if args.lease_id:
        leases = [x for x in leases if x["leaseId"] == args.lease_id]
    if args.owner:
        leases = [x for x in leases if x["ownerThreadId"] == args.owner]
    if args.task_id:
        leases = [x for x in leases if x["taskId"] == args.task_id]
    if args.code:
        leases = [x for x in leases if x.get("code") == args.code]
    emit({"schemaVersion": 1, "leases": [support.lease_view(x) for x in leases],
          "note": "occupied/observable states are registry facts; accepted is never implied by exit 0"})
    return EXIT_OK


def cmd_result(args, registry) -> int:
    output = support.secure_output_path(args.output, registry.root)
    result = invocation.inspect_result(output)
    result["observableState"] = support.observable_state(result["phase"]) if result.get("executionSucceeded") else result.get("phase")
    result["acceptanceNote"] = "result-ready is not accepted; acceptance stays with the reviewer"
    emit(result)
    return EXIT_OK


def build_codex_plan_args(state_dir: Path, *, code: str, brief_file: Path,
                          output: Path, cwd: Path, model: str | None, effort: str | None,
                          sandbox: str) -> list[str]:
    """Managed-entry argv for codex plan; plain array, passed to argparse only."""
    managed = ["--state-dir", str(state_dir), "plan",
               "--code", code, "--brief-file", str(brief_file), "--output", str(output),
               "--cwd", str(cwd), "--sandbox", sandbox]
    if model:
        managed += ["--model", model]
    if effort:
        managed += ["--effort", effort]
    return support.validate_plain_argv_prefix(managed)


def cmd_plan(args, registry) -> int:
    if args.product == "codex":
        if args.print_argv_only:
            managed = build_codex_plan_args(
                registry.root,
                code=args.code or "CODE", brief_file=Path(args.brief_file or "brief.md"),
                output=Path(args.output or "out.md"), cwd=Path(args.cwd or Path.cwd()),
                model=args.model, effort=args.effort, sandbox=args.sandbox)
            emit({"schemaVersion": 1, "delegatesTo": MANAGED_SCRIPT,
                  "invocation": "in-process next_dispatch_activity.main", "argv": managed})
            return EXIT_OK
        if not (args.code and args.brief_file and args.output and args.cwd):
            raise Refusal("codex_plan_requires_code_brief_output_cwd")
        managed = build_codex_plan_args(
            registry.root, code=args.code, brief_file=Path(args.brief_file),
            output=Path(args.output), cwd=Path(args.cwd),
            model=args.model, effort=args.effort, sandbox=args.sandbox)
        result = activity.main(managed)
        return EXIT_OK if result in (None, 0) else int(result)
    if args.product == "grok":
        return grok.plan(args, registry)
    if args.product == "workbuddy":
        return plan_workbuddy(args, registry)
    print(f"USAGE_ERROR: unknown product '{args.product}'", file=sys.stderr)
    return EXIT_USAGE


def plan_workbuddy(args, registry) -> int:
    model = args.model or WORKBUDDY_MODEL
    if model not in capabilities.WORKBUDDY_FREE_MODELS:
        raise Refusal("model_not_authorized_for_workbuddy")
    brief_bytes = invocation.read_file(Path(args.brief_file).expanduser(), invocation.MAX_BRIEF_BYTES)
    text = brief_bytes.decode("utf-8")
    if not text.strip() or "\0" in text:
        raise invocation.InvocationError("brief_is_empty_or_invalid")
    output = support.secure_output_path(args.output, registry.root)
    for probe in (output, invocation.receipt_path(output),
                  output.with_name(output.name + ".next-resources")):
        if os.path.lexists(probe):
            raise invocation.InvocationError("output_already_exists_inspect_existing_run")
    executable = Path(args.executable or capabilities.WORKBUDDY_EXECUTABLE)
    if len(text.encode()) > support.MAX_ARGV_BRIEF_BYTES:
        raise Unsupported("brief_too_large_for_managed_argv")
    support.validate_plain_argv([str(executable), "--model", model, "--input-format", "text", "-p"])
    support.validate_executable(executable)
    emit({
        "schemaVersion": 1, "product": "workbuddy", "planOnly": True, "willNotLaunch": True,
        "model": model,
        "executable": str(executable),
        "briefBytes": len(brief_bytes),
        "briefSHA256": hashlib.sha256(brief_bytes).hexdigest(),
        "briefDelivery": "stdin",
        "output": str(output),
        "outputExclusive": True,
        "stateDir": str(registry.root),
        "runGates": ["--allow-run flag", "AGENT_CLI_ALLOW_RUN=1 environment",
                     "explicit model from the native free-model allowlist; no automatic fallback"],
    })
    return EXIT_OK


def cmd_run(args, registry) -> int:
    if not (args.allow_run and os.environ.get("AGENT_CLI_ALLOW_RUN") == "1"):
        raise Unsupported("run_requires_explicit_double_switch")
    if args.product == "codex":
        if not (args.code and args.lease_id and args.capability_report and args.cwd):
            raise Refusal("codex_run_requires_code_lease_capability_report_cwd")
        managed = build_codex_plan_args(registry.root, code=args.code, brief_file=args.brief_file,
            output=args.output, cwd=args.cwd, model=args.model, effort=args.effort, sandbox=args.sandbox)
        managed[2] = "run"
        managed += ["--lease-id", args.lease_id, "--owner", args.owner, "--capability-report", str(args.capability_report)]
        if args.refresh:
            managed.append("--refresh")
        result = activity.main(managed)
        return EXIT_OK if result in (None, 0) else int(result)
    if args.product == "grok":
        return grok.run(args, registry)
    if args.product != "workbuddy":
        raise Unsupported("run_not_authorized_for_product")
    model = args.model or WORKBUDDY_MODEL
    if model not in capabilities.WORKBUDDY_FREE_MODELS:
        raise Refusal("model_not_authorized_for_workbuddy")
    brief_path = Path(args.brief_file).expanduser()
    brief_bytes = invocation.read_file(brief_path, invocation.MAX_BRIEF_BYTES)
    text = brief_bytes.decode("utf-8")
    if not text.strip() or "\0" in text:
        raise invocation.InvocationError("brief_is_empty_or_invalid")
    if len(text.encode()) > support.MAX_ARGV_BRIEF_BYTES:
        raise Unsupported("brief_too_large_for_managed_argv")
    output = support.secure_output_path(args.output, registry.root)
    # F-08: probe all three artifacts before reserving, with plan's fixed code.
    for probe in (output, invocation.receipt_path(output),
                  output.with_name(output.name + ".next-resources")):
        if os.path.lexists(probe):
            raise invocation.InvocationError("output_already_exists_inspect_existing_run")
    executable = Path(args.executable or capabilities.WORKBUDDY_EXECUTABLE)
    if args.executable and os.environ.get("AGENT_CLI_ALLOW_TEST_EXECUTABLE") != "1":
        # F-13: the pinned catalog binary is the only production entry;
        # overrides exist solely for offline pseudo-process tests.
        raise Refusal("executable_override_requires_test_switch")
    support.validate_executable(executable)
    argv = support.validate_plain_argv([str(executable), "--model", model, "--input-format", "text", "-p"])
    cwd = Path(args.cwd or Path.cwd()).resolve()
    if not cwd.is_dir():
        raise activity.ActivityError("project_directory_missing")
    lease = registry.reserve(
        account_key=hashlib.sha256(b"local:workbuddy").hexdigest(),
        alias_key=hashlib.sha256(b"workbuddy").hexdigest(),
        code=None, project=activity.project_key(cwd), owner=args.owner,
        task=args.task_id, route="direct")
    try:
        output_identity = support.create_exclusive_output(output)
        result = support.run_workbuddy_task(
            registry, lease, argv=argv, cwd=cwd, brief_path=brief_path, output=output,
            timeout=float(args.timeout_seconds) if args.timeout_seconds is not None
            else support.DEFAULT_RUN_TIMEOUT_SECONDS,
            capture_limit=support.MAX_CHILD_CAPTURE_BYTES,
            output_identity=output_identity, stdin_bytes=brief_bytes)
    except BaseException:
        # Preserve the reservation truthfully; never relaunch over an occupied
        # lease. A cancel that landed before launch must converge to cancelled
        # here instead of sticking in cancel_requested (F-01B).
        support.converge_reservation_after_failure(registry, lease, args.owner)
        raise
    lease_after = next((x for x in registry.read()["leases"] if x["leaseId"] == lease["leaseId"]), None)
    emit({"schemaVersion": 1, "run": result,
          "lease": support.lease_view(lease_after) if lease_after else None,
          "requestedModel": model, "observedModel": None, "observedCost": None,
          "quotaGate": "native free-model allowlist; quota is unknown; no automatic retry or fallback",
          "note": "exit 0 means the run was recorded truthfully; it is not acceptance and not "
                  "a claim that the child succeeded"})
    return EXIT_OK


def cmd_cancel(args, registry) -> int:
    owner, lease_id = args.owner, args.lease_id
    lease = next((x for x in registry.read()["leases"] if x["leaseId"] == lease_id), None)
    if lease is None:
        raise activity.ActivityError("reservation_owner_mismatch")
    if lease["ownerThreadId"] != owner:
        raise Refusal("cancel_refused_owner_mismatch")
    effective = activity.effective_state(lease)
    if lease["state"] in activity.TERMINAL:
        emit({"schemaVersion": 1, "leaseId": lease_id, "cancel": "idempotent_noop",
              "state": lease["state"], "observableState": support.observable_state(effective),
              "note": "already terminal; exit 0 is not artifact acceptance"})
        return EXIT_OK
    # Verify the recorded child before any state mutation: a stale PID must be
    # refused while the lease and the live process stay untouched.
    group = None
    if lease.get("childPID"):
        group = support.verified_group_for_cancel(lease)
    registry.update(lease_id, owner, "cancel_requested")
    stop = None
    if group is not None:
        stop = support.stop_process_group(group, support.CANCEL_TERM_WAIT_SECONDS,
                                          support.CANCEL_KILL_WAIT_SECONDS,
                                          child=lease["childPID"], birth=lease.get("childPIDBirth"))
        if not stop["exited"]:
            raise AgentCliError("process_group_survived_sigkill")
    # The owning runner keeps the exclusive right to record a terminal state;
    # wait bounded for it instead of writing over a live supervisor.
    final = None
    deadline = time.monotonic() + support.CANCEL_RUNNER_GRACE_SECONDS
    while time.monotonic() < deadline:
        current = next((x for x in registry.read()["leases"] if x["leaseId"] == lease_id), None)
        if current and current["state"] in activity.TERMINAL:
            final = current
            break
        time.sleep(0.2)
    if final is not None:
        emit({"schemaVersion": 1, "leaseId": lease_id,
              "cancel": "completed" if stop is not None else "no_live_group_runner_reached_terminal",
              "stop": stop if stop is not None else {"signalled": "none",
                                                     "reason": "no live recorded process group"},
              "state": final["state"],
              "observableState": support.observable_state(final["state"]),
              "partialResults": "output artifacts were never deleted; inspect them for partial work",
              "note": "cancel success is not acceptance and not a claim about partial outputs"})
    elif stop is not None:
        emit({"schemaVersion": 1, "leaseId": lease_id,
              "cancel": "requested_stop_verified_pending_runner",
              "stop": stop, "state": "cancel_requested",
              "observableState": support.observable_state(
                  activity.effective_state({**lease, "state": "cancel_requested"})),
              "note": "the recorded process group was signalled; the owning runner is still "
                      "recording its terminal state and keeps the lease truthful"})
    else:
        # No live group was recorded. If a runner never claimed the lease
        # (no runnerPID/childPID ever), converge it here — nobody else will.
        # Otherwise the owning runner keeps the exclusive terminal write.
        current = next((x for x in registry.read()["leases"] if x["leaseId"] == lease_id), None)
        converged = False
        if current and current["state"] == "cancel_requested" \
                and current.get("runnerPID") is None and current.get("childPID") is None:
            try:
                updated = registry.update(lease_id, owner, "cancelled")
                converged = True
            except activity.ActivityError:
                converged = False
        if converged:
            emit({"schemaVersion": 1, "leaseId": lease_id,
                  "cancel": "completed_no_runner_converged",
                  "stop": {"signalled": "none", "reason": "lease never launched a process"},
                  "state": "cancelled", "observableState": "cancelled",
                  "partialResults": "output artifacts were never deleted; inspect them for partial work",
                  "note": "no signal was sent: the lease never launched; terminal written by cancel"})
        else:
            # Nothing was running and the runner has not converged yet; report
            # the honest fact instead of claiming a stop that never happened (F-02).
            emit({"schemaVersion": 1, "leaseId": lease_id,
                  "cancel": "requested_no_live_group_nothing_signalled",
                  "stop": {"signalled": "none", "reason": "no live recorded process group"},
                  "state": "cancel_requested",
                  "observableState": support.observable_state(
                      activity.effective_state({**lease, "state": "cancel_requested"})),
                  "partialResults": "output artifacts were never deleted; inspect them for partial work",
                  "note": "no signal was sent: the lease had no live process group; the owning "
                          "runner (or a later run attempt) converges the terminal state"})
    return EXIT_OK


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--state-dir", type=Path, default=None,
                   help="activity state directory (defaults to the shared managed location)")
    sub = p.add_subparsers(dest="command", required=True)

    cap = sub.add_parser("capabilities", help="static capability statement (not live account success)")
    cap.add_argument("--product", choices=sorted(capabilities.CATALOG))

    inspect = sub.add_parser("inspect", help="read recorded quota/models without refreshing, launching or changing accounts",
                             description="Read cached facts only. Models use saved local CLI environment metadata; "
                             "--model-dir selects one environment. Missing caches stay unknown. No credentials are read.")
    inspect.add_argument("--section", choices=["all", "quota", "models"], default="all")
    inspect.add_argument("--snapshot-dir", type=Path, default=None,
                         help="Mac app support directory; defaults to ~/Library/Application Support/CodexAccountManagerNext")
    inspect.add_argument("--model-dir", type=Path,
                         help="read model-availability-v1.json in this one environment instead of saved environment metadata")

    plan = sub.add_parser("plan", help="prepare a task without launching anything")
    plan.add_argument("--product", choices=["codex", "grok", "workbuddy"], required=True)
    plan.add_argument("--code", help="codex account code (managed entry)")
    plan.add_argument("--brief-file", type=Path)
    plan.add_argument("--output", type=Path)
    plan.add_argument("--cwd", type=Path)
    plan.add_argument("--model")
    plan.add_argument("--effort")
    plan.add_argument("--sandbox", choices=["read-only", "workspace-write"], default="workspace-write")
    plan.add_argument("--executable", help="workbuddy/grok executable override (Grok overrides require the offline test switch)")
    plan.add_argument("--print-argv-only", action="store_true",
                      help="print the managed-entry argv without executing it")
    plan.set_defaults(needs_args=True)

    status = sub.add_parser("status", help="registry status with observable state mapping")
    status.add_argument("--lease-id")
    status.add_argument("--owner")
    status.add_argument("--task-id")
    status.add_argument("--code")

    result = sub.add_parser("result", help="inspect and verify a task receipt")
    result.add_argument("--output", type=Path, required=True)

    cancel = sub.add_parser("cancel", help="cancel own lease after owner+lease+PID-birth verification")
    cancel.add_argument("--lease-id", required=True)
    cancel.add_argument("--owner", required=True)
    cancel.add_argument("--product", choices=sorted(capabilities.CATALOG))

    run = sub.add_parser("run", help="managed Codex delegation, native WorkBuddy run, or fail-closed Grok adapter")
    run.add_argument("--product", choices=["codex", "grok", "workbuddy"], required=True)
    run.add_argument("--owner", required=True)
    run.add_argument("--task-id", required=True)
    run.add_argument("--brief-file", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--cwd", type=Path)
    run.add_argument("--model")
    run.add_argument("--code")
    run.add_argument("--lease-id")
    run.add_argument("--capability-report", type=Path)
    run.add_argument("--effort")
    run.add_argument("--sandbox", choices=["read-only", "workspace-write"], default="workspace-write")
    run.add_argument("--refresh", action="store_true")
    run.add_argument("--executable")
    run.add_argument("--quota-evidence", type=Path,
                     help="grok bridge input; caller JSON is rejected until the native producer is wired")
    run.add_argument("--timeout-seconds", default=None,
                     help="run deadline in seconds; grok requires it explicitly")
    run.add_argument("--allow-run", action="store_true",
                     help="requires AGENT_CLI_ALLOW_RUN=1 in the environment as well")
    return p


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    if args.command == "inspect":
        try:
            emit(snapshot.inspect(args.snapshot_dir or snapshot.default_directory(),
                                  section=args.section, model_directory=args.model_dir))
            return EXIT_OK
        except snapshot.SnapshotError as error:
            print("SNAPSHOT_ERROR: " + str(error), file=sys.stderr)
            return EXIT_ERROR
    state_dir = args.state_dir or activity.SUPPORT
    registry = activity.Registry(Path(state_dir))
    commands = {
        "capabilities": cmd_capabilities, "status": cmd_status, "result": cmd_result,
        "plan": cmd_plan, "cancel": cmd_cancel, "run": cmd_run,
    }
    try:
        return commands[args.command](args, registry)
    except Refusal as error:
        print("REFUSED: " + str(error), file=sys.stderr)
        return EXIT_REFUSED
    except Unsupported as error:
        print("UNSUPPORTED: " + str(error), file=sys.stderr)
        return EXIT_UNSUPPORTED
    except (activity.ActivityError, invocation.InvocationError, support.AgentCliError) as error:
        print("ACTIVITY_ERROR: " + str(error), file=sys.stderr)
        return EXIT_ERROR
    except (OSError, ValueError, UnicodeError, TypeError) as error:
        print("ACTIVITY_ERROR: operation_failed_no_private_details", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
