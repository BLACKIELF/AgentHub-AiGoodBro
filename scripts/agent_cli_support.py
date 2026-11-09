#!/usr/bin/env python3
"""Shared support for the agent-cli thin entry.

Reuses the managed dispatch modules in this directory (next_dispatch_activity /
next_dispatch_invocation). This file adds limits, state mapping and the local
WorkBuddy runner wrapper; it contains no process launching of its own — the
child is launched only by the managed activity.supervise() supervisor (list
argv, shell=False), from a minimized environment. No credentials are ever read.

Review hardening (TASK-WB-ADAPTER-REVIEW-0911v1): process-group-leader and
birth rechecks before every signal, honest cancel evidence (esrch is not
"term"), exclusive output with identity recheck, replace-based receipts,
cancel-before-launch convergence, and fd-safe capture.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import select
import stat
import tempfile
import threading
import time

import next_dispatch_activity as activity
import next_dispatch_invocation as invocation

MAX_RECEIPT_BYTES = invocation.MAX_RECEIPT_BYTES
MAX_OUTPUT_BYTES = invocation.MAX_OUTPUT_BYTES
MAX_CHILD_CAPTURE_BYTES = 1024 * 1024
MAX_ARGV_BRIEF_BYTES = 100_000
DEFAULT_RUN_TIMEOUT_SECONDS = 900.0
CANCEL_TERM_WAIT_SECONDS = 10.0
CANCEL_KILL_WAIT_SECONDS = 5.0
CANCEL_RUNNER_GRACE_SECONDS = 15.0
CANCEL_POLL_SECONDS = 0.2
TRUNCATION_MARKER = b"\n[agent-cli: stdout truncated at capture limit]\n"

# Depth-defence only — the real boundary is the managed supervisor's list-argv
# Popen with shell=False. These tokens are rejected for hygiene, not safety.
SHELL_CONTROL_TOKENS = {"&", "&&", "|", "||", ";", ";;", "(", ")", "{", "}",
                        "<", ">", ">>", "|&", "$(", "`"}
RUNNING_STATES = {"preparing", "starting", "running", "cancel_requested", "uncertain"}
STRIPPED_ENV_PREFIXES = ("CODEX_", "OPENAI_", "CODEBUDDY_", "CBC_", "WORKBUDDY_",
                        "ANTHROPIC_", "OPENCODE_", "DASHSCOPE_", "XAI_", "GROK_", "ZAI_")
STRIPPED_ENV_KEYS = {"AGENT_CLI_ALLOW_RUN", "AGENT_CLI_ALLOW_TEST_EXECUTABLE",
                     "AGENT_CLI_GROK_EXECUTABLE", "AGENT_CLI_GROK_MIN_RETURN_DIR"}


class AgentCliError(RuntimeError):
    """Fixed reason codes only; never file contents, paths or tool output."""


class Refusal(AgentCliError):
    """Safety refusal (wrong owner, stale PID, unauthorized target)."""


class Unsupported(AgentCliError):
    """Capability absent or not proven; never a fake run."""


def validate_plain_argv(argv: object) -> list[str]:
    """Reject anything that is not a plain argument array for shell=False."""
    if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
        raise Refusal("command_must_be_plain_argv")
    if any("\0" in x for x in argv):
        raise Refusal("command_contains_nul")
    if not argv[0].startswith("/") or not Path(argv[0]).is_absolute():
        raise Refusal("command_executable_must_be_absolute_path")
    if any(x in SHELL_CONTROL_TOKENS for x in argv):
        raise Refusal("command_contains_shell_control_token")
    return argv


def validate_plain_argv_prefix(argv: object) -> list[str]:
    """Validate an argument array that starts with flags, not an executable."""
    if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
        raise Refusal("command_must_be_plain_argv")
    if any("\0" in x for x in argv):
        raise Refusal("command_contains_nul")
    if any(x in SHELL_CONTROL_TOKENS for x in argv):
        raise Refusal("command_contains_shell_control_token")
    return argv


def child_environment() -> dict:
    """Minimized environment for the launched child: no armed switches, no
    provider credential variables — mirrors the managed codex path's cleaning."""
    env = {k: v for k, v in os.environ.items()
           if k not in STRIPPED_ENV_KEYS and not k.startswith(STRIPPED_ENV_PREFIXES)}
    return env


def observable_state(effective_state: str) -> str:
    """Map a registry lease state onto the mandated observable vocabulary."""
    if effective_state == "accepted":
        return "accepted"
    if effective_state == "awaiting_acceptance":
        return "result-ready"
    if effective_state in RUNNING_STATES:
        return "running"
    return effective_state


def lease_view(lease: dict) -> dict:
    effective = activity.effective_state(lease)
    return {
        "leaseId": lease["leaseId"], "ownerThreadId": lease["ownerThreadId"],
        "taskId": lease["taskId"], "code": lease.get("code"), "route": lease.get("route"),
        "state": lease["state"], "effectiveState": effective, "occupied": lease["state"] in activity.ACTIVE,
        "observableState": observable_state(effective),
        "createdAt": lease.get("createdAt"), "updatedAt": lease.get("updatedAt"),
        "heartbeatDueAt": lease.get("heartbeatDueAt"),
        "hasProcessGroup": lease.get("processGroupID") is not None,
    }


def secure_output_path(value: str | Path, state_dir: Path | None = None) -> Path:
    """Normalize an output path and refuse state-dir mixing.

    Reuses invocation.normalized_output() (parent resolved, leaf symlink kept
    visible), then refuses outputs that resolve inside the activity state
    directory so shared state and task artifacts never mix.
    """
    path = invocation.normalized_output(Path(value))
    if state_dir is not None:
        state_resolved = Path(state_dir).resolve()
        parent = path.parent
        if parent == state_resolved or state_resolved in parent.parents:
            raise Refusal("output_inside_activity_state_refused")
    return path


def group_alive(group: int) -> bool:
    return activity.group_has_live_process(group)


def wait_group_exit(group: int, timeout: float, poll: float = CANCEL_POLL_SECONDS) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not group_alive(group):
            return True
        time.sleep(poll)
    return not group_alive(group)


def verified_group_for_cancel(lease: dict) -> int | None:
    """Return the process group to signal, or None when nothing is running.

    A recorded child whose PID is gone is already stopped. A live child must
    (a) carry the recorded birth, (b) be its own process-group leader, and
    (c) equal the recorded group — otherwise the target is refused so a
    cancel can never signal an unrelated group (F-03).
    """
    child = lease.get("childPID")
    if child is None:
        return None
    birth = lease.get("childPIDBirth")
    group = lease.get("processGroupID") or child
    current_birth = activity.process_birth(child)
    if current_birth is None:
        return None
    if not birth or current_birth != birth:
        raise Refusal("stale_child_pid_refuses_signal")
    if group != child:
        raise Refusal("target_not_process_group_leader")
    try:
        if os.getpgid(child) != child:
            raise Refusal("target_not_process_group_leader")
    except ProcessLookupError:
        return None
    return group


def stop_process_group(group: int, term_wait: float, kill_wait: float,
                       child: int | None = None, birth: str | None = None) -> dict:
    """SIGTERM then bounded SIGKILL for one verified process group.

    Right before each signal the recorded birth is recomputed so the
    check-to-kill window cannot land on a reused PID (F-03B). Evidence only
    claims signals that were actually delivered; ESRCH is reported as such.
    """
    if child is not None and birth is not None and activity.process_birth(child) != birth:
        raise Refusal("pid_reused_before_signal")
    try:
        os.killpg(group, 15)  # SIGTERM
    except ProcessLookupError:
        return {"signalled": "esrch_group_gone", "exited": True}
    if wait_group_exit(group, term_wait):
        return {"signalled": "term", "exited": True}
    if child is not None and birth is not None and activity.process_birth(child) != birth:
        raise Refusal("pid_reused_before_signal")
    try:
        os.killpg(group, 9)  # SIGKILL
    except ProcessLookupError:
        return {"signalled": "esrch_group_gone", "exited": True}
    return {"signalled": "kill", "exited": wait_group_exit(group, kill_wait)}


def create_exclusive_output(output: Path) -> tuple[int, int]:
    """Create the output placeholder and return its (st_dev, st_ino) identity."""
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
    finally:
        os.close(fd)
    return info.st_dev, info.st_ino


def output_identity_matches(output: Path, identity: tuple[int, int]) -> bool:
    try:
        info = output.lstat()
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and (info.st_dev, info.st_ino) == identity


def write_captured_output(output: Path, data: bytes, identity: tuple[int, int]) -> None:
    """Fill the placeholder only if it is still the file we created (F-06)."""
    if not output_identity_matches(output, identity):
        raise AgentCliError("output_placeholder_replaced")
    fd = os.open(output, os.O_WRONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if (info.st_dev, info.st_ino) != identity or info.st_nlink != 1:
            raise AgentCliError("output_placeholder_replaced")
        os.ftruncate(fd, 0)
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)


def write_conforming_receipt(output: Path, *, phase: str, exit_code: int | None,
                             extra: dict | None = None) -> None:
    """Write a receipt compatible with next_dispatch_invocation.inspect_result.

    Uses temp-file + os.replace (the managed invocation.update pattern) so an
    externally pre-existing receipt is never silently truncated (F-06).
    """
    fd = os.open(output, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        data = invocation.read_open_file(fd, invocation.MAX_OUTPUT_BYTES)
    finally:
        os.close(fd)
    receipt = {
        "schemaVersion": 1,
        "outputKey": invocation.output_key(output),
        "phase": phase,
        "exitCode": exit_code,
        "finalMessage": {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()} if data.strip() else None,
        "updatedAt": invocation.timestamp(),
    }
    if extra:
        receipt.update(extra)
    payload = (json.dumps(receipt, ensure_ascii=False, sort_keys=True) + "\n").encode()
    fd, name = tempfile.mkstemp(prefix=".agent-cli-receipt-", dir=output.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, invocation.receipt_path(output))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def validate_executable(path: Path, maximum_bytes: int = 64 * 1024 * 1024) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum_bytes:
            raise Refusal("executable_invalid")
    finally:
        os.close(fd)
    if not os.access(path, os.X_OK):
        raise Refusal("executable_not_executable")


def converge_reservation_after_failure(registry: activity.Registry, lease: dict, owner: str) -> None:
    """Truthfully settle a reservation whose runner failed before supervision
    completed. A cancel that landed before launch converges to cancelled
    (F-01B) instead of sticking in cancel_requested; any other still-ours,
    still-unsettled lease becomes failed, degrading to uncertain only when a
    concurrent write wins. Never relaunches and never frees an occupied lease."""
    current = next((x for x in registry.read()["leases"] if x["leaseId"] == lease["leaseId"]), None)
    if current and current["state"] in {"preparing", "starting", "running", "cancel_requested"} \
            and current.get("runnerPID") in {None, os.getpid()}:
        try:
            registry.update(lease["leaseId"], owner, "cancelled"
                            if current["state"] == "cancel_requested" else "failed")
        except activity.ActivityError:
            try:
                registry.update(lease["leaseId"], owner, "uncertain")
            except activity.ActivityError:
                pass


def run_workbuddy_task(registry: activity.Registry, lease: dict, *, argv: list[str],
                       cwd: Path, brief_path: Path, output: Path, timeout: float,
                       capture_limit: int, output_identity: tuple[int, int],
                       stdin_bytes: bytes | None = None) -> dict:
    """Optional WorkBuddy entry wrapped around the managed activity.supervise().

    The child is launched only by activity.supervise() with a minimized
    environment. This wrapper adds: an exclusive output placeholder with
    identity recheck, a conforming receipt, bounded stdout+stderr capture via
    redirected descriptors, a hard timeout that stops the recorded process
    group, and a cancel-before-launch convergence check. Never reads
    credentials.
    """
    if stdin_bytes is not None and (not isinstance(stdin_bytes, bytes)
                                    or len(stdin_bytes) > MAX_ARGV_BRIEF_BYTES):
        raise AgentCliError("invalid_managed_stdin")
    owner, lease_id = lease["ownerThreadId"], lease["leaseId"]
    write_conforming_receipt(output, phase="starting", exit_code=None, extra={
        "leaseId": lease_id, "taskId": lease["taskId"], "ownerThreadId": owner,
    })
    read_fd, write_fd = os.pipe()
    capture = bytearray()
    capture_stop = threading.Event()
    def drain():
        while not capture_stop.is_set():
            if not select.select([read_fd], [], [], 0.1)[0]:
                continue
            chunk = os.read(read_fd, 64 * 1024)
            if not chunk:
                return
            room = max(0, capture_limit + 1 - len(capture))
            capture.extend(chunk[:room])
    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    def close_writer():
        nonlocal write_fd
        if write_fd is not None:
            os.close(write_fd)
            write_fd = None
    state = {"timed_out": False, "timeout_stop_refused": False,
             "truncated": False, "exit_code": None, "timer": None}
    stopped_early = {"flag": False}

    def expire(started_lease: dict):
        state["timed_out"] = True
        try:
            group = verified_group_for_cancel(started_lease)
            if group is not None:
                stop_process_group(group, CANCEL_TERM_WAIT_SECONDS, CANCEL_KILL_WAIT_SECONDS,
                                   child=started_lease["childPID"], birth=started_lease["childPIDBirth"])
        except (Refusal, OSError):
            # Preserve the timeout outcome while refusing an unverifiable or
            # reused process. Never signal using a numeric group alone.
            state["timeout_stop_refused"] = True

    def before_start():
        # F-01A: a cancel that landed between claim and launch must win —
        # never start a child over a cancel_requested lease.
        current = next(x for x in registry.read()["leases"] if x["leaseId"] == lease_id)
        if current["state"] == "cancel_requested":
            stopped_early["flag"] = True
            registry.update(lease_id, owner, "cancelled")
            raise AgentCliError("cancelled_before_launch")

    def on_started():
        close_writer()
        # The supervisor stored the group in the registry after launch; the
        # captured lease dict predates that update, so re-read the record.
        current = next(x for x in registry.read()["leases"] if x["leaseId"] == lease_id)
        timer = threading.Timer(timeout, expire, args=(dict(current),))
        timer.daemon = True
        timer.start()
        state["timer"] = timer

    def on_exited(result: int):
        state["exit_code"] = result
        timer = state.get("timer")
        if timer is not None:
            timer.cancel()
        close_writer()
        reader.join(timeout=1)
        capture_stop.set()
        reader.join(timeout=1)
        data = bytes(capture)
        state["truncated"] = len(data) > capture_limit
        if state["truncated"]:
            data = data[:capture_limit] + TRUNCATION_MARKER
        write_captured_output(output, data, output_identity)
        current = next(x for x in registry.read()["leases"] if x["leaseId"] == lease_id)
        phase = "cancelled" if current["state"] == "cancel_requested" else (
            "failed" if result != 0 or state["timed_out"] or state["truncated"] else "awaiting_acceptance")
        write_conforming_receipt(output, phase=phase, exit_code=result, extra={
            "leaseId": lease_id, "taskId": lease["taskId"], "ownerThreadId": owner,
            "capturedStdoutBytes": len(data), "capturedStdoutTruncated": state["truncated"],
            "runTimeoutSeconds": timeout, "runTimedOut": state["timed_out"],
            "runTimeoutStopRefused": state["timeout_stop_refused"],
        })

    def verify_result():
        if state["timed_out"] or state["truncated"]:
            raise AgentCliError("run_incomplete_timeout_or_capture_limit")

    stdin_file = None
    try:
        child_env = child_environment()
        child_env["PWD"] = str(cwd)
        if stdin_bytes is not None:
            # The validated brief never enters argv or a persistent path.
            # An anonymous seekable descriptor avoids a pipe writer that can
            # block before cancellation or survive the supervised child.
            stdin_file = tempfile.TemporaryFile(mode="w+b")
            stdin_file.write(stdin_bytes)
            stdin_file.seek(0)
        # Only the child receives the capture descriptors. The reader drains
        # excess bytes without retaining them; memory and disk stay bounded.
        result = activity.supervise(registry, lease, argv, cwd, env=child_env,
                                    stdin=stdin_file, stdout=write_fd, stderr=write_fd,
                                    on_started=on_started, on_exited=on_exited, verify_result=verify_result,
                                    before_start=before_start)
    finally:
        if stdin_file is not None:
            stdin_file.close()
        close_writer()
        capture_stop.set()
        reader.join(timeout=1)
        os.close(read_fd)
        timer = state.get("timer")
        if timer is not None:
            timer.cancel()
    if stopped_early["flag"]:
        return {"exitCode": None, "superviseExitCode": result, "cancelledBeforeLaunch": True,
                "phase": "cancelled", "output": str(output)}
    current = next(x for x in registry.read()["leases"] if x["leaseId"] == lease_id)
    # A surviving descendant or cancelled zero exit is still represented by
    # its registry state. The result command must not call it successful.
    receipt = json.loads(invocation.read_file(invocation.receipt_path(output), MAX_RECEIPT_BYTES))
    receipt["phase"] = current["state"]
    write_conforming_receipt(output, phase=current["state"], exit_code=state["exit_code"], extra=receipt)
    return {"exitCode": state["exit_code"], "superviseExitCode": result,
            "phase": current["state"],
            "runTimedOut": state["timed_out"], "capturedStdoutTruncated": state["truncated"],
            "runTimeoutStopRefused": state["timeout_stop_refused"],
            "output": str(output)}
