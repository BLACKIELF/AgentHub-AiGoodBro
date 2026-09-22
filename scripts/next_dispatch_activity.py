#!/usr/bin/env python3
"""Cooperative Next dispatch reservations and one append-only incident journal.

No daemon or account switch. Explicit profile launches verify local identity;
optional deadlines only stop their owned process group. A reservation is
occupied before launch, not evidence of model execution.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))
from next_dispatch_invocation import (Invocation, InvocationError, file_hash, inspect_result,
                                      read_file, timestamp as invocation_timestamp, MAX_RECEIPT_BYTES,
                                      SUBAGENT_MODES)


SUPPORT = Path.home() / "Library/Application Support/CodexAccountManagerNext"
STATE_NAME = "dispatch-activity-v1.json"
LOCK_NAME = ".dispatch-activity.lock"
ISSUE_NAME = "operations-issues-v1.jsonl"
ACTIVE = {"preparing", "starting", "running", "cancel_requested", "uncertain"}
TERMINAL = {"awaiting_acceptance", "accepted", "rejected", "failed", "cancelled"}
HEARTBEAT_RETRY_DELAYS = (1.0, 2.0)
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\Z")
HASH = re.compile(r"[a-f0-9]{64}\Z")
MAX_STATE_BYTES = 2 * 1024 * 1024


class ActivityError(RuntimeError):
    """Errors contain fixed reason codes only, never local paths or tool output."""


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def identity_key(profile: dict) -> str:
    email = (profile.get("lastSnapshot") or {}).get("email")
    if not isinstance(email, str) or not email.strip():
        raise ActivityError("account_identity_missing")
    return digest(email.strip().lower())


def project_key(cwd: Path) -> str:
    if not cwd.is_dir():
        raise ActivityError("project_directory_missing")
    return digest(str(cwd.resolve()))


def checked_identifier(value: str) -> str:
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise ActivityError("invalid_identifier")
    return value


def process_birth(pid: int) -> str | None:
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
        return None
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "lstart="],
            capture_output=True, text=True, timeout=2, check=False,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        )
        text = result.stdout.strip()
        if result.returncode not in {0, 1} or (result.returncode == 0 and not text):
            raise ActivityError("process_evidence_unavailable")
        return digest(text) if result.returncode == 0 and text else None
    except (OSError, subprocess.TimeoutExpired):
        raise ActivityError("process_evidence_unavailable") from None


def group_has_live_process(group: int) -> bool:
    try:
        result = subprocess.run(["/bin/ps", "-axo", "pgid=,stat="], capture_output=True,
                                text=True, timeout=2, check=True)
    except (OSError, subprocess.SubprocessError):
        raise ActivityError("process_group_evidence_unavailable") from None
    return any(len(parts := line.split()) == 2 and parts[0] == str(group) and not parts[1].startswith("Z")
               for line in result.stdout.splitlines())


def effective_state(lease: dict, now: float | None = None) -> str:
    now = time.time() if now is None else now
    if lease["state"] in ACTIVE and lease["state"] != "uncertain":
        if lease["heartbeatDueAt"] < now or lease["updatedAt"] > now + 5:
            return "uncertain"
    return lease["state"]


def validate_state(value: object) -> dict:
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise ActivityError("activity_state_invalid")
    leases = value.get("leases")
    if not isinstance(leases, list) or len(leases) > 2000:
        raise ActivityError("activity_state_invalid")
    ids = set()
    for lease in leases:
        if not isinstance(lease, dict):
            raise ActivityError("activity_state_invalid")
        for key in ("leaseId", "ownerThreadId", "taskId"):
            checked_identifier(lease.get(key))
        for key in ("accountKey", "aliasKey", "projectKey"):
            if not isinstance(lease.get(key), str) or not HASH.fullmatch(lease[key]):
                raise ActivityError("activity_state_invalid")
        if lease.get("state") not in ACTIVE | TERMINAL or lease["leaseId"] in ids:
            raise ActivityError("activity_state_invalid")
        if lease.get("code") is not None and not re.fullmatch(r"[A-Z]", lease["code"]):
            raise ActivityError("activity_state_invalid")
        for key in ("createdAt", "updatedAt", "heartbeatDueAt"):
            n = lease.get(key)
            if isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n):
                raise ActivityError("activity_state_invalid")
        for key in ("runnerPID", "childPID"):
            if lease.get(key) is not None:
                if isinstance(lease[key], bool) or not isinstance(lease[key], int) or lease[key] <= 1:
                    raise ActivityError("activity_state_invalid")
                if not isinstance(lease.get(key + "Birth"), str) or not HASH.fullmatch(lease[key + "Birth"]):
                    raise ActivityError("activity_state_invalid")
        if lease.get("processGroupID") is not None:
            group = lease["processGroupID"]
            if isinstance(group, bool) or not isinstance(group, int) or group <= 1:
                raise ActivityError("activity_state_invalid")
        ids.add(lease["leaseId"])
    return value


class Registry:
    def __init__(self, root: Path = SUPPORT):
        self.root = root
        self.path = root / STATE_NAME

    def _prepare(self):
        if self.root.is_symlink():
            raise ActivityError("unsafe_activity_directory")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = self.root.stat()
        if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077:
            raise ActivityError("unsafe_activity_directory")

    @contextlib.contextmanager
    def lock(self):
        self._prepare()
        fd = os.open(self.root / LOCK_NAME, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
                raise ActivityError("unsafe_activity_lock")
            deadline = time.monotonic() + 2
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise ActivityError("activity_lock_busy") from None
                    time.sleep(0.02)
            yield
        finally:
            os.close(fd)

    def read(self) -> dict:
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return {"schemaVersion": 1, "leases": []}
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > MAX_STATE_BYTES
                    or info.st_nlink != 1 or info.st_mode & 0o077):
                raise ActivityError("activity_state_invalid")
            with os.fdopen(fd, "r", encoding="utf-8", closefd=False) as handle:
                return validate_state(json.load(handle))
        except (ValueError, UnicodeError):
            raise ActivityError("activity_state_invalid") from None
        finally:
            os.close(fd)

    def _write(self, value: dict):
        validate_state(value)
        if self.path.is_symlink():
            raise ActivityError("unsafe_activity_file")
        payload = (json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n").encode()
        if len(payload) > MAX_STATE_BYTES:
            raise ActivityError("activity_state_full")
        fd, name = tempfile.mkstemp(prefix=".dispatch-activity-", dir=self.root)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    @staticmethod
    def retained_history(leases: list[dict]) -> list[dict]:
        """Keep every active lease plus the 100 most recently updated terminals."""
        active = [lease for lease in leases if lease["state"] in ACTIVE]
        terminal = sorted(
            (lease for lease in leases if lease["state"] not in ACTIVE),
            key=lambda lease: (lease["updatedAt"], lease["leaseId"]),
        )[-100:]
        return active + terminal

    def reserve(self, *, account_key: str, alias_key: str, code: str | None,
                project: str, owner: str, task: str, route: str, gate=None) -> dict:
        checked_identifier(owner)
        checked_identifier(task)
        if route not in {"direct", "hub", "warmup", "maintenance", "terminal"}:
            raise ActivityError("invalid_route")
        with self.lock():
            state = self.read()
            for existing in state["leases"]:
                if existing["state"] not in ACTIVE:
                    continue
                if (existing["accountKey"] == account_key or existing["aliasKey"] == alias_key
                        or existing["projectKey"] == project):
                    raise ActivityError("account_or_project_reserved")
            if gate is not None:
                gate()  # Recheck Hub inside the same local reservation transaction.
            now = time.time()
            lease = dict(leaseId=str(uuid.uuid4()), ownerThreadId=owner, taskId=task,
                         accountKey=account_key, aliasKey=alias_key, code=code,
                         projectKey=project, route=route, state="preparing",
                         createdAt=now, updatedAt=now, heartbeatDueAt=now + 600)
            state["leases"] = self.retained_history(state["leases"]) + [lease]
            self._write(state)
            return lease

    def update(self, lease_id: str, owner: str, phase: str | None = None,
               *, claim: bool = False, verified_hub: bool = False, **fields) -> dict:
        with self.lock():
            state = self.read()
            lease = next((x for x in state["leases"] if x["leaseId"] == lease_id), None)
            if lease is None or lease["ownerThreadId"] != owner:
                raise ActivityError("reservation_owner_mismatch")
            if verified_hub and lease.get("hubTaskId") not in {None, fields.get("hubTaskId")}:
                raise ActivityError("hub_task_identity_changed")
            if verified_hub and lease["state"] in TERMINAL:
                if phase not in TERMINAL:
                    raise ActivityError("hub_terminal_state_regressed")
                return lease.copy()
            if verified_hub and lease["state"] == "cancel_requested":
                # Mirror fresh, identity-checked Hub evidence atomically with
                # local cancel intent. An active Hub cannot erase intent; a
                # confirmed terminal Hub allows release with intent retained.
                # The Hub's actual outcome remains in its own task record.
                phase = "cancelled" if phase in TERMINAL else None
            # A recorded cancel intent is authoritative: no active phase may
            # resurrect it. Only an idempotent re-cancel or an evidence-checked
            # cancelled release (guards below) may follow it.
            if lease["state"] == "cancel_requested" and phase is not None \
                    and phase not in {"cancel_requested", "cancelled"}:
                raise ActivityError("cancel_intent_is_authoritative")
            if claim and (lease["state"] != "preparing" or lease.get("runnerPID") is not None):
                raise ActivityError("reservation_already_claimed")
            if phase not in TERMINAL | {"uncertain"} and effective_state(lease) == "uncertain" and not verified_hub:
                raise ActivityError("stale_reservation_requires_resolution")
            if lease["state"] in TERMINAL and phase not in {"accepted", "rejected"}:
                raise ActivityError("reservation_already_finished")
            if lease["state"] == "cancelled" and phase in {"accepted", "rejected"}:
                raise ActivityError("reservation_already_finished")
            if phase in TERMINAL:
                if lease.get("processGroupID") and group_has_live_process(lease["processGroupID"]):
                    raise ActivityError("process_group_still_running")
                for key in ("childPID", "runnerPID"):
                    if lease.get(key) and lease[key] != os.getpid():
                        if process_birth(lease[key]) == lease[key + "Birth"]:
                            raise ActivityError("process_still_running")
            allowed = {"runnerPID", "runnerPIDBirth", "childPID", "childPIDBirth", "processGroupID", "exitCode", "hubTaskId"}
            if set(fields) - allowed or (phase is not None and phase not in ACTIVE | TERMINAL):
                raise ActivityError("invalid_transition")
            lease.update(fields)
            if phase:
                lease["state"] = phase
            lease["updatedAt"] = time.time()
            lease["heartbeatDueAt"] = lease["updatedAt"] + (600 if lease["state"] == "preparing" else 120)
            self._write(state)
            return lease.copy()

    def issue(self, *, issue_id: str, component: str, phase: str, summary: str,
              code: str | None = None, owner: str | None = None, evidence: str | None = None):
        for value in (issue_id, component, phase):
            checked_identifier(value)
        if code is not None and not re.fullmatch(r"[A-Z]", code):
            raise ActivityError("invalid_issue_code")
        if owner is not None:
            checked_identifier(owner)
        if evidence is not None:
            checked_identifier(evidence)
        if not isinstance(summary, str) or len(summary) > 1200 or not summary.strip():
            raise ActivityError("invalid_issue_summary")
        # Refuse common private data rather than storing a partially redacted copy.
        forbidden = r"(?:[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|(?:/Users/|/home/|/var/|~/|https?://)|(?:sk-|Bearer\s|access_token|refresh_token|webhook))"
        if re.search(forbidden, summary, re.I):
            raise ActivityError("issue_contains_private_data")
        now = datetime.now(timezone.utc)
        event = {"schemaVersion": 1, "issueId": issue_id, "component": component,
                 "phase": phase, "recordedAt": now.isoformat(),
                 "dateShanghai": now.astimezone(ZoneInfo("Asia/Shanghai")).isoformat(),
                 "summary": summary, "code": code, "ownerThreadId": owner, "evidenceRef": evidence}
        payload = (json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        with self.lock():
            fd = os.open(self.root / ISSUE_NAME, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
                    raise ActivityError("unsafe_issue_file")
                try:
                    if os.write(fd, payload) != len(payload):
                        raise ActivityError("issue_write_incomplete")
                    os.fsync(fd)
                except BaseException:
                    # The shared lock excludes cooperating appenders. Remove
                    # only this failed append so the next JSONL row stays valid.
                    os.ftruncate(fd, info.st_size)
                    os.fsync(fd)
                    raise
            finally:
                os.close(fd)
        return event


def merge_preflight(report: dict, snapshot: dict, registry: dict, cwd: Path,
                    *, own_lease: str | None = None, owner: str | None = None) -> dict:
    """A passing read is still not a reservation. Self exclusion requires both IDs."""
    validate_state(registry)
    profiles = {x["id"]: x for x in snapshot["profiles"]}
    project = project_key(cwd)
    leases = registry["leases"]
    own = next((x for x in leases if x["leaseId"] == own_lease and x["ownerThreadId"] == owner), None)
    if own_lease and (own is None or effective_state(own) not in {"preparing", "starting", "running"}):
        raise ActivityError("reservation_owner_or_liveness_invalid")
    if own is not None and (own["projectKey"] != project or report.get("requestedCode") != own.get("code")):
        raise ActivityError("reservation_target_mismatch")
    busy = [x for x in leases if x["state"] in ACTIVE and x is not own]
    rows = report["eligible"] + report["excluded"]
    for row in rows:
        p = profiles.get(row["profileId"])
        key = identity_key(p) if p and (p.get("lastSnapshot") or {}).get("email") else None
        alias = row.get("alias")
        alias_key = digest(alias.strip().lower()) if isinstance(alias, str) else None
        conflicts = [x for x in busy if x["accountKey"] == key or x["aliasKey"] == alias_key
                     or x["projectKey"] == project]
        row["localActivity"] = [{"leaseId": x["leaseId"], "ownerThreadId": x["ownerThreadId"],
                                 "taskId": x["taskId"], "state": effective_state(x)} for x in conflicts]
        if conflicts and "local_reserved" not in row["reasons"]:
            row["reasons"].append("local_reserved")
    report["eligible"] = [x for x in report["eligible"] if not x["reasons"]]
    for index, row in enumerate(report["eligible"], 1):
        row["rank"] = index
    report["excluded"] = [x for x in rows if x["reasons"]]
    report["recommended"] = next(iter(report["eligible"]), None)
    code = report.get("requestedCode")
    report["selected"] = next((x for x in report["eligible"] if x["code"] == code), None) if code else report["recommended"]
    report["preflightPassed"] = bool(report["selected"]) and bool(report["route"].get("ready"))
    report["activityCoverage"] = "cooperating_skill_and_next_clients; legacy_unregistered_runs_require_separate_verification"
    return report


def preflight_module():
    path = Path(__file__).with_name("next_dispatch_preflight.py")
    spec = importlib.util.spec_from_file_location("next_preflight", path)
    if spec is None or spec.loader is None:
        raise ActivityError("preflight_module_missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def account_context(pre, code: str):
    mapping, _, _ = pre.mapping_source(None)
    mapping = pre.apply_local_policy(mapping, pre.load_json(pre.DEFAULT_POLICY))
    snapshot = pre.load_json(pre.DEFAULT_SNAPSHOT)
    account = next((x for x in mapping["accounts"] if x["code"] == code), None)
    profile = next((x for x in snapshot["profiles"] if account and x["id"] == account["profileId"]), None)
    if account is None or profile is None:
        raise ActivityError("account_mapping_missing")
    if pre.participation_reasons(profile, account, mapping, datetime.now(timezone.utc)):
        raise ActivityError("account_not_in_dispatch_pool")
    expected = account.get("email")
    if expected and (profile.get("name") != expected or profile.get("lastSnapshot", {}).get("email") != expected):
        raise ActivityError("account_identity_mismatch")
    return mapping, snapshot, account, profile


def profile_context(pre, profile_id: str):
    checked_identifier(profile_id)
    mapping, _, _ = pre.mapping_source(None)
    snapshot = pre.load_json(pre.DEFAULT_SNAPSHOT)
    profile = pre.profile_index(snapshot).get(profile_id)
    if profile is None:
        raise ActivityError("selected_profile_missing")
    matched = [a for a in mapping["accounts"] if a["profileId"] == profile_id]
    if len(matched) > 1:
        raise ActivityError("selected_profile_ambiguous")
    policy = pre.load_json(pre.DEFAULT_POLICY)
    rules = [r for r in policy.get("accountRules", []) if r.get("profileId") == profile_id]
    account = matched[0] if matched else {
        "code": None, "alias": rules[0]["alias"] if len(rules) == 1 else "profile-" + profile_id,
        "profileId": profile_id, "priority": 0, "active": True,
    }
    selected = {**mapping, "accounts": [account], "profileSelectionUnmapped": not matched}
    selected = pre.apply_local_policy(selected, policy)
    account = selected["accounts"][0]
    if pre.participation_reasons(profile, account, selected, datetime.now(timezone.utc)):
        raise ActivityError("account_not_in_dispatch_pool")
    home = Path(profile.get("codexHomePath", "")).expanduser().resolve()
    if not profile.get("codexHomePath") or home == (Path.home() / ".codex").resolve() or not home.is_dir():
        raise ActivityError("isolated_profile_required")
    expected = account.get("email")
    if expected and (profile.get("name") != expected or (profile.get("lastSnapshot") or {}).get("email") != expected):
        raise ActivityError("account_identity_mismatch")
    identity_key(profile)
    return selected, snapshot, account, profile


def verify_profile_credentials(profile: dict):
    """Compare bounded local credentials in memory; never expose their values."""
    try:
        home = Path(profile["codexHomePath"]).expanduser().resolve()
        if profile.get("isSystemProfile") or home == (Path.home() / ".codex").resolve():
            raise ValueError()
        auth = json.loads(read_file(home / "auth.json", 256 * 1024))
        if auth.get("auth_mode") != "chatgpt" or auth.get("OPENAI_API_KEY"):
            raise ValueError()
        tokens = auth["tokens"]
        token = tokens["id_token"]
        if not isinstance(token, str) or len(token.split(".")) != 3:
            raise ValueError()
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        snapshot = profile["lastSnapshot"]
        email = snapshot["email"].strip().lower()
        if (not email or claims.get("email", "").strip().lower() != email
                or not snapshot.get("accountID") or tokens.get("account_id") != snapshot["accountID"]):
            raise ValueError()
    except (KeyError, TypeError, ValueError, AttributeError, OSError, InvocationError):
        raise ActivityError("selected_profile_credentials_mismatch") from None


def selected_context(pre, args):
    return profile_context(pre, args.profile_id) if args.profile_id else account_context(pre, args.code)


def hub_gate(pre, mapping: dict, alias: str, cwd: Path):
    overview, _ = pre.fetch_hub(pre.DEFAULT_HUB_URL, 2)
    if overview is None or pre.hub_overview_error(overview):
        raise ActivityError("hub_evidence_unavailable")
    accounts, projects = pre.active_hub_work(overview, datetime.now(timezone.utc))
    if mapping.get("profileSelectionUnmapped") and accounts:
        raise ActivityError("unmapped_profile_hub_identity_unverified")
    if accounts.get(alias) or not pre.route_for(cwd, mapping, overview, projects).get("ready"):
        raise ActivityError("hub_account_or_project_busy")
    return overview


def sync_hub(registry: Registry, lease_id: str, owner: str, hub_id: str, cwd: Path,
             mapping: dict, overview: dict, pre) -> dict:
    """Mirror a freshly read Hub task. Never creates, approves or stops a task."""
    checked_identifier(hub_id)
    if pre.hub_overview_error(overview):
        raise ActivityError("hub_evidence_unavailable")
    lease = next((x for x in registry.read()["leases"] if x["leaseId"] == lease_id and x["ownerThreadId"] == owner), None)
    if lease is None or lease["route"] != "hub" or lease["projectKey"] != project_key(cwd):
        raise ActivityError("reservation_target_mismatch")
    if lease.get("hubTaskId") not in {None, hub_id}:
        raise ActivityError("hub_task_identity_changed")
    task = next((x for x in overview["tasks"] if x.get("id") == hub_id), None)
    route = pre.route_for(cwd, mapping, overview, {})
    if (task is None or not route.get("ready") or route.get("mode") != "hub"
            or task.get("project") != route.get("project")
            or digest(str(task.get("accountAlias", "")).strip().lower()) != lease["aliasKey"]):
        raise ActivityError("hub_task_identity_unverified")
    states = {"awaiting_approval": "preparing", "approved": "starting", "queued": "starting",
              "starting": "starting", "running": "running", "cancel_requested": "cancel_requested",
              "uncertain": "uncertain", "succeeded": "awaiting_acceptance", "failed": "failed",
              "cancelled": "cancelled", "blocked_configuration": "failed"}
    phase = states.get(task.get("state"))
    if phase is None:
        raise ActivityError("hub_task_state_unverified")
    return registry.update(lease_id, owner, phase, verified_hub=True, hubTaskId=hub_id)


def renew_heartbeat(registry: Registry, lease_id: str, owner: str, stop: threading.Event,
                    retry_delays=HEARTBEAT_RETRY_DELAYS) -> bool:
    """Retry only bounded local-lock contention; every attempt rechecks lease ownership."""
    for attempt in range(len(retry_delays) + 1):
        try:
            registry.update(lease_id, owner)
            return True
        except ActivityError as error:
            if str(error) != "activity_lock_busy" or attempt == len(retry_delays):
                raise
            if stop.wait(retry_delays[attempt]):
                return False
    return False


def read_capability_report(path: Path) -> dict:
    """Read the capability report with a reason code that names the failing input.

    The generic invocation-file codes cannot tell an operator whether the brief
    or the capability report is missing. Callers that already know which input
    they are checking use this so the failure is actionable, and so the check
    can run before a reservation is claimed.
    """
    try:
        data = read_file(path, MAX_RECEIPT_BYTES)
    except InvocationError as error:
        if str(error) == "invocation_file_unavailable":
            raise ActivityError("capability_report_unavailable") from None
        raise ActivityError("capability_report_invalid") from None
    try:
        capability = json.loads(data)
    except (ValueError, UnicodeError):
        raise ActivityError("capability_report_invalid") from None
    if not isinstance(capability, dict):
        raise ActivityError("capability_report_invalid")
    return capability


def supervise(registry: Registry, lease: dict, command: list[str], cwd: Path,
              *, env: dict | None = None, stdin=None, stdout=None, stderr=None, before_start=None, on_started=None,
              on_exited=None, verify_result=None, max_runtime_seconds: float | None = None) -> int:
    """Keep reservation visible while preflight runs and until the child exits."""
    if max_runtime_seconds is not None and (isinstance(max_runtime_seconds, bool)
            or not isinstance(max_runtime_seconds, (int, float))
            or not math.isfinite(max_runtime_seconds) or not 0 < max_runtime_seconds <= 86400):
        raise ActivityError("invalid_runtime_deadline")
    stop = threading.Event()
    heartbeat_errors = []
    owner, lease_id = lease["ownerThreadId"], lease["leaseId"]
    child = None
    thread = None
    claimed = False
    try:
        # The claim is inside the guarded section: a refused claim (already
        # claimed, cancel recorded, birth unavailable) is journalled below and
        # never rewrites a lease this supervisor does not own.
        registry.update(lease_id, owner, "starting", claim=True,
                        runnerPID=os.getpid(), runnerPIDBirth=process_birth(os.getpid()))
        claimed = True

        def heartbeat():
            while not stop.wait(20):
                try:
                    if not renew_heartbeat(registry, lease_id, owner, stop):
                        return
                except Exception:
                    heartbeat_errors.append(True)
                    return  # Leave the reservation occupied/uncertain, never relaunch.

        thread = threading.Thread(target=heartbeat, daemon=True)
        thread.start()
        if before_start:
            before_start()
        if heartbeat_errors:
            raise ActivityError("activity_heartbeat_failed")
        registry.update(lease_id, owner, "starting")
        child = subprocess.Popen(command, cwd=cwd, env=env, stdin=stdin, stdout=stdout, stderr=stderr, start_new_session=True)
        registry.update(lease_id, owner, processGroupID=child.pid)
        birth = process_birth(child.pid)
        if birth is not None:
            try:
                registry.update(lease_id, owner, "running", childPID=child.pid, childPIDBirth=birth)
            except ActivityError as error:
                if str(error) != "cancel_intent_is_authoritative":
                    raise
                # Cancel intent stays authoritative; keep the pid evidence via
                # a phase-less write so liveness checks stay honest.
                registry.update(lease_id, owner, None, childPID=child.pid, childPIDBirth=birth)
            if on_started:
                on_started()
        try:
            result = child.wait(timeout=max_runtime_seconds)
        except subprocess.TimeoutExpired:
            current = next(x for x in registry.read()["leases"] if x["leaseId"] == lease_id)
            if (current.get("ownerThreadId") != owner or current.get("childPID") != child.pid
                    or not current.get("childPIDBirth")
                    or process_birth(child.pid) != current["childPIDBirth"]
                    or current.get("processGroupID") != child.pid):
                raise ActivityError("deadline_process_identity_unverified")
            registry.update(lease_id, owner, "cancel_requested")
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            registry.issue(issue_id="cli-runtime-deadline", component="cli", phase="observed",
                           summary="Owned invocation reached its runtime deadline. Graceful stop requested; existing artifacts require inspection.",
                           code=lease.get("code"), owner=owner)
            try:
                result = child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Do not escalate to a broad kill or free unverified work.
                return 4
        if on_exited:
            on_exited(result)
        stop.set()
        thread.join(timeout=1)
        if group_has_live_process(child.pid):
            try:
                registry.update(lease_id, owner, "uncertain", exitCode=result)
            except ActivityError as error:
                if str(error) != "cancel_intent_is_authoritative":
                    raise
                # cancel_requested is ACTIVE: the lease stays occupied and
                # stale heartbeats surface it as uncertain until resolved.
            registry.issue(issue_id="cli-descendants-unverified", component="cli", phase="observed",
                           summary="CLI exited but its process group still has live work. Reservation remains occupied.",
                           code=lease.get("code"), owner=owner)
            return 4
        registry.update(lease_id, owner, exitCode=result)
        current = next(x for x in registry.read()["leases"] if x["leaseId"] == lease_id)
        if result == 0 and verify_result and current["state"] != "cancel_requested":
            verify_result()
        try:
            registry.update(lease_id, owner, "awaiting_acceptance" if result == 0 else "failed", exitCode=result)
        except ActivityError as error:
            if str(error) != "cancel_intent_is_authoritative":
                raise
            # The group is dead (checked above), so a cancelled release is
            # evidence-backed; the recorded exit code stays as evidence.
            registry.update(lease_id, owner, "cancelled", exitCode=result)
        if result != 0:
            registry.issue(issue_id="cli-exit-failed", component="cli", phase="observed",
                           summary="CLI exited unsuccessfully; inspect the owning task's artifacts before retrying.",
                           code=lease.get("code"), owner=owner)
        return result
    except BaseException:
        stop.set()
        if thread is not None:
            thread.join(timeout=1)
        still_running = child is not None
        if child is not None:
            try:
                still_running = child.poll() is None or group_has_live_process(child.pid)
            except ActivityError:
                still_running = True
        if claimed:
            try:
                registry.update(lease_id, owner, "uncertain" if still_running else "failed")
            except ActivityError as error:
                # A cancel recorded meanwhile — or an already-terminal
                # convergence such as cancelled-before-launch — is
                # authoritative and keeps the lease occupied; never clobber it.
                if str(error) not in {"cancel_intent_is_authoritative", "reservation_already_finished"}:
                    raise
        registry.issue(issue_id="cli-launch-or-supervisor-failed", component="cli", phase="observed",
                       summary="Launch or supervision did not complete. A live or unverified child retains its reservation.",
                       code=lease.get("code"), owner=owner)
        raise
    finally:
        stop.set()


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--state-dir", type=Path, default=SUPPORT, help="Isolated state directory for offline tests")
    commands = p.add_subparsers(dest="command", required=True)
    status = commands.add_parser("status")
    status.add_argument("--lease-id")
    status.add_argument("--owner")
    status.add_argument("--task-id")
    result = commands.add_parser("result")
    result.add_argument("--output", type=Path, required=True)
    reserve = commands.add_parser("reserve")
    select = reserve.add_mutually_exclusive_group(required=True)
    select.add_argument("--code")
    select.add_argument("--profile-id")
    reserve.add_argument("--cwd", type=Path, required=True)
    reserve.add_argument("--owner", required=True)
    reserve.add_argument("--task-id", required=True)
    reserve.add_argument("--route", choices=["direct", "hub"], required=True)
    for name in ("sync-hub", "watch-hub"):
        hub = commands.add_parser(name)
        for key in ("lease-id", "owner", "hub-task-id"):
            hub.add_argument("--" + key, required=True)
        hub.add_argument("--cwd", type=Path, required=True)
        if name == "watch-hub":
            hub.add_argument("--wait-seconds", type=bounded_wait, default=60)
    for name in ("heartbeat", "finish"):
        sub = commands.add_parser(name)
        sub.add_argument("--lease-id", required=True)
        sub.add_argument("--owner", required=True)
        if name == "finish":
            sub.add_argument("--outcome", choices=sorted(TERMINAL), required=True)
    for name in ("plan", "run"):
        run = commands.add_parser(name)
        select = run.add_mutually_exclusive_group(required=True)
        select.add_argument("--code")
        select.add_argument("--profile-id")
        for key in ("brief-file", "output"):
            run.add_argument("--" + key, required=True)
        run.add_argument("--codex-bin", help="Defaults to the executable verified in Next setup, then the installed CLI")
        run.add_argument("--cwd", type=Path, required=True)
        run.add_argument("--model")
        run.add_argument("--effort")
        run.add_argument("--service-tier", choices=["default", "fast"])
        run.add_argument("--subagent-mode", choices=sorted(SUBAGENT_MODES))
        run.add_argument("--sandbox", choices=["read-only", "workspace-write"], default="workspace-write")
        run.add_argument("--allow-unreported-five-hour", action="store_true",
                         help="Explicit selected Pro 5x only; successful weekly quota and zero reported credits remain required")
        run.add_argument("--max-runtime-seconds", type=positive_runtime,
                         help="Optional owned-process deadline, 1 to 86400 seconds; partial work still needs review")
        if name == "run":
            for key in ("lease-id", "owner", "capability-report"):
                run.add_argument("--" + key, required=True)
            run.add_argument("--refresh", action="store_true")
        else:
            run.add_argument("--capability-report",
                             help="Dry-run only: validate this report without reserving or launching")
    issue = commands.add_parser("issue")
    for key in ("issue-id", "component", "phase", "summary"):
        issue.add_argument("--" + key, required=True)
    issue.add_argument("--code")
    issue.add_argument("--owner")
    issue.add_argument("--evidence")
    return p


def bounded_wait(value: str) -> float:
    try:
        seconds = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("wait seconds must be a number from 0 to 60") from None
    if not math.isfinite(seconds) or not 0 <= seconds <= 60:
        raise argparse.ArgumentTypeError("wait seconds must be a number from 0 to 60")
    return seconds


def positive_runtime(value: str) -> float:
    try:
        seconds = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("runtime must be from 1 to 86400 seconds") from None
    if not math.isfinite(seconds) or not 1 <= seconds <= 86400:
        raise argparse.ArgumentTypeError("runtime must be from 1 to 86400 seconds")
    return seconds


def execute(args, registry):
    if args.command == "status":
        state = registry.read()
        state["leases"] = [lease for lease in state["leases"]
                           if (args.lease_id is None or lease["leaseId"] == args.lease_id)
                           and (args.owner is None or lease["ownerThreadId"] == args.owner)
                           and (args.task_id is None or lease["taskId"] == args.task_id)]
        for lease in state["leases"]:
            lease["effectiveState"] = effective_state(lease)
            lease["occupied"] = lease["state"] in ACTIVE
        result = state
    elif args.command == "result":
        result = inspect_result(args.output)
    elif args.command == "issue":
        result = registry.issue(issue_id=args.issue_id, component=args.component, phase=args.phase,
                                summary=args.summary, code=args.code, owner=args.owner, evidence=args.evidence)
    elif args.command == "heartbeat":
        result = registry.update(args.lease_id, args.owner)
    elif args.command == "finish":
        lease = next((x for x in registry.read()["leases"] if x["leaseId"] == args.lease_id), None)
        if lease and lease["route"] == "hub" and lease.get("hubTaskId") and lease["state"] in ACTIVE:
            raise ActivityError("sync_hub_terminal_state_before_finish")
        result = registry.update(args.lease_id, args.owner, args.outcome)
    elif args.command in {"sync-hub", "watch-hub"}:
        pre = preflight_module()
        mapping, _, _ = pre.mapping_source(None)
        deadline = time.monotonic() + getattr(args, "wait_seconds", 0)
        while True:
            overview, _ = pre.fetch_hub(pre.DEFAULT_HUB_URL, 2)
            if overview is None:
                raise ActivityError("hub_evidence_unavailable")
            result = sync_hub(registry, args.lease_id, args.owner, args.hub_task_id, args.cwd, mapping, overview, pre)
            if args.command == "sync-hub" or result["state"] in TERMINAL | {"uncertain"}:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                result["waitTimedOut"] = True
                break
            time.sleep(min(20, remaining))
    elif args.command == "reserve":
        pre = preflight_module()
        mapping, _, account, profile = selected_context(pre, args)
        if args.profile_id and args.route != "direct":
            raise ActivityError("profile_selection_requires_direct_route")
        result = registry.reserve(account_key=identity_key(profile), alias_key=digest(account["alias"].strip().lower()),
                                  code=account["code"], project=project_key(args.cwd), owner=args.owner,
                                  task=args.task_id, route=args.route,
                                  gate=lambda: hub_gate(pre, mapping, account["alias"], args.cwd))
    else:
        pre = preflight_module()
        mapping, snapshot, account, profile = selected_context(pre, args)
        if args.allow_unreported_five_hour and not args.profile_id:
            raise ActivityError("quota_exception_requires_explicit_profile")
        selected_code = account["code"]
        lease = None
        if args.command == "run":
            lease = next((x for x in registry.read()["leases"] if x["leaseId"] == args.lease_id
                          and x["ownerThreadId"] == args.owner), None)
            if lease is None or lease["state"] != "preparing" or effective_state(lease) != "preparing":
                raise ActivityError("preparing_reservation_required")
            if (lease["route"] != "direct" or lease.get("code") != selected_code
                    or lease["accountKey"] != identity_key(profile) or lease["projectKey"] != project_key(args.cwd)):
                raise ActivityError("reservation_target_mismatch")
            # Validate the launch input before the reservation is claimed. A
            # missing or unreadable report previously failed inside before_start,
            # after the lease was claimed, which burned the reservation and made
            # the retry fail again with preparing_reservation_required.
            read_capability_report(Path(args.capability_report))
        project_key(args.cwd)
        preference = pre.execution_preference(profile)
        if preference is None:
            raise ActivityError("execution_preference_invalid")
        preference = {**preference, "subagentMode": args.subagent_mode or preference.get("subagentMode", "standard")}
        preference["serviceTier"] = args.service_tier or preference["serviceTier"]
        effective = pre.effective_strategy(preference)
        if effective["useSavedModel"]:
            effective["model"] = args.model or effective["model"]
            effective["reasoningEffort"] = args.effort or effective["reasoningEffort"]
        else:
            if ((args.model is not None and args.model != effective["model"])
                    or (args.effort is not None and args.effort != effective["reasoningEffort"])):
                raise ActivityError("explicit_execution_override_conflicts_with_subagent_mode")
        if pre.execution_preference({"executionPreference": preference}) is None:
            raise ActivityError("execution_preference_invalid")
        if not pre.valid_effective_strategy(effective):
            raise ActivityError("effective_execution_preference_invalid")
        executable_value = args.codex_bin or os.environ.get("CAMNEXT_CODEX_BIN")
        if not executable_value:
            binding = Path(__file__).resolve().parent.parent / "config/runtime-paths.json"
            if binding.exists():
                saved = json.loads(read_file(binding, 8192))
                if saved.get("schemaVersion") != 1 or not isinstance(saved.get("codex"), str):
                    raise ActivityError("runtime_binding_invalid_open_next_setup")
                executable_value = saved["codex"]
            else:
                executable_value = shutil.which("codex")
        if not executable_value:
            raise ActivityError("codex_executable_missing_open_next_setup")
        executable = Path(executable_value).expanduser().resolve()
        if not os.access(executable, os.X_OK):
            raise ActivityError("codex_executable_invalid")
        home = Path(profile["codexHomePath"]).expanduser().resolve()
        if home == (Path.home() / ".codex").resolve() or not home.is_dir():
            raise ActivityError("isolated_profile_required")
        invocation = Invocation(brief=Path(args.brief_file), output=Path(args.output), executable=executable,
                                preference=preference, sandbox=args.sandbox, code=selected_code, lease=lease,
                                effective_preference=effective)
        invocation.record.update(profileId=args.profile_id,
                                 allowUnreportedFiveHour=args.allow_unreported_five_hour,
                                 maxRuntimeSeconds=args.max_runtime_seconds)
        if args.command == "plan":
            preview = invocation.preview()
            if args.capability_report is not None:
                read_capability_report(Path(args.capability_report))
                preview["capabilityReportReadable"] = True
            print(json.dumps(preview, ensure_ascii=False, indent=2))
            return 0
        environment = dict(os.environ)
        environment["CODEX_HOME"] = str(home)
        for key in ("CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL"):
            environment.pop(key, None)
        command = [str(executable), "exec", "--skip-git-repo-check", "-C", str(args.cwd.resolve()), "--sandbox", args.sandbox,
                   "--model", effective["model"], "-c", 'model_reasoning_effort="' + effective["reasoningEffort"] + '"',
                   "-c", 'service_tier="' + effective["serviceTier"] + '"',
                   "--enable" if effective["serviceTier"] == "fast" else "--disable", "fast_mode",
                   "--output-last-message", str(invocation.output), "-"]
        if args.profile_id:
            command[2:2] = ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--json", "--color", "never",
                            "-c", 'model_provider="openai"']
        if effective["subagentsEnabled"]:
            insertion = command.index("--output-last-message")
            command[insertion:insertion] = [
                "-c", "agents.enabled=true",
                "-c", "features.multi_agent_v2=true",
                "-c", "agents.max_concurrent_threads_per_session=1",
                "-c", "agents.default_subagent_model=" + json.dumps(effective["subagentModel"]),
                "-c", "agents.default_subagent_reasoning_effort=" + json.dumps(effective["subagentReasoningEffort"]),
                "-c", 'agents.next_preset_worker.description="Next managed preset implementation worker"',
                "-c", "agents.next_preset_worker.config_file=" + json.dumps(str(invocation.frozen_role_path())),
            ]
        else:
            insertion = command.index("--output-last-message")
            command[insertion:insertion] = ["-c", "agents.enabled=false", "-c", "features.multi_agent_v2=false"]

        def before_start():
            capability = read_capability_report(Path(args.capability_report))
            if capability.get("status") != "passed":
                raise ActivityError("capability_check_not_passed")
            if capability.get("cliSHA256") != file_hash(executable):
                raise ActivityError("capability_executable_changed")
            if effective["subagentsEnabled"]:
                supported = capability.get("supportedSubagentModes")
                if not isinstance(supported, list) or preference["subagentMode"] not in supported:
                    raise ActivityError("subagent_mode_capability_missing")
                if capability.get("workerRoleSHA256") != invocation.role_hash:
                    raise ActivityError("subagent_role_capability_changed")
            at = pre.parse_request_start(capability.get("checkedAt", ""))
            if not 0 <= (datetime.now(timezone.utc) - at).total_seconds() <= 3600:
                raise ActivityError("capability_check_stale")
            current_mapping, current_snapshot, current_account, current_profile = selected_context(pre, args)
            if identity_key(current_profile) != lease["accountKey"] or current_profile["codexHomePath"] != profile["codexHomePath"]:
                raise ActivityError("reservation_identity_changed")
            refresh = None
            if args.refresh:
                start = pre.request_next_refresh()
                current_snapshot, refresh = pre.wait_for_refresh(pre.DEFAULT_SNAPSHOT, current_mapping, start, 240, 0.5, selected_code)
            if args.profile_id:
                current_profile = pre.profile_index(current_snapshot).get(args.profile_id)
                if (current_profile is None or identity_key(current_profile) != lease["accountKey"]
                        or current_profile["codexHomePath"] != profile["codexHomePath"]):
                    raise ActivityError("reservation_identity_changed")
                verify_profile_credentials(current_profile)
            overview = hub_gate(pre, current_mapping, current_account["alias"], args.cwd)
            report = pre.build_report(current_snapshot, current_mapping, overview, datetime.now(timezone.utc), args.cwd, 45,
                                      {"hubAvailable": True}, refresh, selected_code,
                                      allow_unreported_five_hour=args.allow_unreported_five_hour)
            report = merge_preflight(report, current_snapshot, registry.read(), args.cwd, own_lease=args.lease_id, owner=args.owner)
            if not report["preflightPassed"]:
                raise ActivityError("fresh_preflight_failed")
            invocation.record["quotaException"] = report["selected"].get("quotaException")
            invocation.begin()

        try:
            with tempfile.TemporaryFile() as brief:
                brief.write(invocation.effective_input)
                brief.seek(0)
                return supervise(registry, lease, command, args.cwd, env=environment, stdin=brief, before_start=before_start,
                                 on_started=lambda: invocation.update(phase="running"),
                                 on_exited=lambda code: invocation.update(processEndedAt=invocation_timestamp(), exitCode=code),
                                 verify_result=invocation.verify_success, max_runtime_seconds=args.max_runtime_seconds)
        finally:
            current = next((x for x in registry.read()["leases"] if x["leaseId"] == args.lease_id), None)
            if current:
                invocation.update(phase=current["state"], exitCode=current.get("exitCode"))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def main(argv=None):
    args = parser().parse_args(argv)
    registry = Registry(args.state_dir)
    try:
        return execute(args, registry)
    except BaseException:
        if args.command == "run":
            try:
                lease = next((x for x in registry.read()["leases"] if x["leaseId"] == args.lease_id
                              and x["ownerThreadId"] == args.owner), None)
                # Only a run that actually claimed the reservation may consume
                # it. A failure before the claim (an unreadable capability
                # report, a bad path) is an input problem, not an execution
                # outcome: the lease stays preparing so the operator can fix the
                # input and retry with the same lease instead of re-reserving.
                if lease and lease.get("runnerPID") is not None \
                        and lease["state"] in {"preparing", "starting", "running"} \
                        and lease.get("runnerPID") in {None, os.getpid()}:
                    try:
                        registry.update(args.lease_id, args.owner, "failed")
                    except ActivityError:
                        registry.update(args.lease_id, args.owner, "uncertain")
            except (ActivityError, OSError, ValueError):
                print("ACTIVITY_ERROR: occupied_state_preserved; state could not be resolved", file=sys.stderr)
        if args.command not in {"issue", "status", "plan", "result"}:
            try:
                registry.issue(issue_id="dispatch-" + args.command + "-failed", component="skill", phase="observed",
                               summary="Dispatch operation failed: " + args.command + ". Check the owning task and current occupied state before retrying.",
                               code=getattr(args, "code", None), owner=getattr(args, "owner", None),
                               evidence=getattr(args, "lease_id", None))
            except (ActivityError, OSError, ValueError):
                print("ACTIVITY_ERROR: issue_journal_write_failed; preserve the failure in the owning task", file=sys.stderr)
        raise


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ActivityError, InvocationError) as exc:
        print("ACTIVITY_ERROR: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
    except Exception:
        print("ACTIVITY_ERROR: operation_failed; inspect the owning task, no private error text was logged", file=sys.stderr)
        raise SystemExit(1)
