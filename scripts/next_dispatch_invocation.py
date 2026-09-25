#!/usr/bin/env python3
"""Local invocation previews and receipts. No account, network or model calls."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
from datetime import datetime, timezone

MAX_BRIEF_BYTES = 1024 * 1024
MAX_RECEIPT_BYTES = 64 * 1024
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
RECEIPT_PHASES = {"starting", "running", "cancel_requested", "awaiting_acceptance", "accepted", "rejected", "failed", "cancelled", "uncertain"}
SUBAGENT_MODES = {"standard", "sol_luna", "luna_direct"}
PRESET_ROLE_NAME = "next_preset_worker"


def collaboration_policy(mode: str, effective: dict | None = None) -> bytes:
    if not effective or not effective.get("subagentsEnabled"):
        return b""
    return (
        "Next collaboration preset: " + mode + ". You are the primary planner and final reviewer; "
        "your model, reasoning effort, service tier, sandbox, and approval policy remain unchanged. "
        "Delegate implementation only when useful, use only the next_preset_worker role, do not request "
        "fork_context=true, and do not specify model or reasoning-effort overrides in spawn requests. "
        "Keep the collaboration one level deep as a working convention. "
        "Open only one next_preset_worker child thread at a time and review its result before continuing. "
        "The configured child-thread ceiling is 1"
        "; do not describe this convention as an unbypassable whole-tree security boundary.\n\n"
    ).encode("utf-8")


def generated_role(model: str, effort: str) -> bytes:
    return f'model = "{model}"\nmodel_reasoning_effort = "{effort}"\n'.encode()


class InvocationError(RuntimeError):
    """Fixed reason codes, never file contents or paths."""


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_file(path: Path, maximum: int) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        raise InvocationError("invocation_file_unavailable") from None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise InvocationError("invocation_file_invalid_or_too_large")
        with os.fdopen(fd, "rb", closefd=False) as handle:
            data = handle.read(maximum + 1)
        if len(data) > maximum:
            raise InvocationError("invocation_file_invalid_or_too_large")
        return data
    finally:
        os.close(fd)


def file_identity(info: os.stat_result) -> tuple[int, int]:
    return info.st_dev, info.st_ino


def read_open_file(fd: int, maximum: int) -> bytes:
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1 or info.st_size > maximum):
        raise InvocationError("invocation_file_invalid_or_too_large")
    os.lseek(fd, 0, os.SEEK_SET)
    chunks = []
    total = 0
    while True:
        chunk = os.read(fd, min(1024 * 1024, maximum + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > maximum:
            raise InvocationError("invocation_file_invalid_or_too_large")
    return b"".join(chunks)


def path_has_identity(path: Path, identity: tuple[int, int]) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and file_identity(info) == identity


def write_all(fd: int, data: bytes):
    written = 0
    while written < len(data):
        count = os.write(fd, data[written:])
        if count <= 0:
            raise InvocationError("invocation_receipt_unwritable")
        written += count


def file_hash(path: Path) -> str:
    result = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        maximum = 1024 * 1024 * 1024
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise InvocationError("executable_file_invalid")
        total = 0
        with os.fdopen(fd, "rb", closefd=False) as handle:
            while chunk := handle.read(1024 * 1024):
                total += len(chunk)
                if total > maximum:
                    raise InvocationError("executable_file_invalid")
                result.update(chunk)
    finally:
        os.close(fd)
    return result.hexdigest()


def output_key(output: Path) -> str:
    return hashlib.sha256(str(output).encode()).hexdigest()


def receipt_path(output: Path) -> Path:
    return output.with_name(output.name + ".next-run.json")


def normalized_output(path: Path) -> Path:
    # Resolve the parent, not the leaf: an existing symlink must remain visible.
    path = path.expanduser().absolute()
    parent = path.parent.resolve()
    if not parent.is_dir() or path.name in {"", ".", ".."}:
        raise InvocationError("output_directory_missing")
    return parent / path.name


def inspect_result(path: Path) -> dict:
    output = normalized_output(path)
    try:
        receipt = json.loads(read_file(receipt_path(output), MAX_RECEIPT_BYTES))
    except (ValueError, UnicodeError):
        raise InvocationError("invocation_receipt_invalid") from None
    if not isinstance(receipt, dict):
        raise InvocationError("invocation_receipt_invalid")
    exit_code = receipt.get("exitCode")
    if (receipt.get("schemaVersion") != 1
            or receipt.get("outputKey") != output_key(output)
            or receipt.get("phase") not in RECEIPT_PHASES
            or (exit_code is not None and (isinstance(exit_code, bool) or not isinstance(exit_code, int)))):
        raise InvocationError("invocation_receipt_invalid")
    data = read_file(output, MAX_OUTPUT_BYTES)
    expected = receipt.get("finalMessage")
    if expected is None:
        expected = {}
    elif (not isinstance(expected, dict) or isinstance(expected.get("bytes"), bool)
          or not isinstance(expected.get("bytes"), int) or not 0 < expected["bytes"] <= MAX_OUTPUT_BYTES
          or not isinstance(expected.get("sha256"), str) or len(expected["sha256"]) != 64
          or any(character not in "0123456789abcdef" for character in expected["sha256"])):
        raise InvocationError("invocation_receipt_invalid")
    verified = bool(data.strip()) and expected.get("sha256") == hashlib.sha256(data).hexdigest() and expected.get("bytes") == len(data)
    succeeded = verified and receipt.get("exitCode") == 0 and receipt.get("phase") in {"awaiting_acceptance", "accepted"}
    preference = receipt.get("executionPreference")
    if isinstance(preference, dict) and "subagentMode" not in preference:
        preference = {**preference, "subagentMode": "standard"}
    return {
        "schemaVersion": 1, "leaseId": receipt.get("leaseId"), "taskId": receipt.get("taskId"),
        "phase": receipt.get("phase"), "exitCode": receipt.get("exitCode"),
        "profileId": receipt.get("profileId"), "quotaException": receipt.get("quotaException"),
        "maxRuntimeSeconds": receipt.get("maxRuntimeSeconds"),
        "executionPreference": preference, "updatedAt": receipt.get("updatedAt"),
        "effectiveExecutionPreference": receipt.get("effectiveExecutionPreference", preference),
        "inputHashes": receipt.get("inputHashes"), "workerRole": receipt.get("workerRole"),
        "subagentExecution": receipt.get("subagentExecution"),
        "processEndedAt": receipt.get("processEndedAt"), "resultCollectedAt": receipt.get("resultCollectedAt"),
        "resultVerified": verified, "acceptanceRequired": True, "dispatchExecuted": False,
        "executionSucceeded": succeeded,
        "nextAction": "read_result_and_validate_artifacts" if verified else "inspect_existing_run_before_retry",
    }


class Invocation:
    def __init__(self, *, brief: Path, output: Path, executable: Path, preference: dict, sandbox: str,
                 code: str, lease: dict | None = None,
                 effective_preference: dict | None = None):
        self.brief = read_file(brief.expanduser(), MAX_BRIEF_BYTES)
        try:
            text = self.brief.decode("utf-8")
        except UnicodeError:
            raise InvocationError("brief_must_be_utf8") from None
        if not text.strip() or "\0" in text:
            raise InvocationError("brief_is_empty_or_invalid")
        self.output = normalized_output(output)
        self.receipt = receipt_path(self.output)
        self.resources = self.output.with_name(self.output.name + ".next-resources")
        mode = preference.get("subagentMode", "standard")
        if mode not in SUBAGENT_MODES:
            raise InvocationError("subagent_mode_invalid")
        frozen_preference = {**preference, "subagentMode": mode}
        effective = effective_preference or frozen_preference
        self.policy = collaboration_policy(mode, effective)
        self.effective_input = self.policy + self.brief
        self.role_data = None
        self.role_hash = None
        if effective.get("subagentsEnabled"):
            self.role_data = generated_role(effective["subagentModel"], effective["subagentReasoningEffort"])
            self.role_hash = hashlib.sha256(self.role_data).hexdigest()
        if os.path.lexists(self.output) or os.path.lexists(self.receipt) or os.path.lexists(self.resources):
            raise InvocationError("output_already_exists_inspect_existing_run")
        self.record = {
            "schemaVersion": 1, "code": code, "executionPreference": frozen_preference, "sandbox": sandbox,
            "effectiveExecutionPreference": effective,
            "briefBytes": len(self.brief), "briefSHA256": hashlib.sha256(self.brief).hexdigest(),
            "inputHashes": {
                "originalBriefSHA256": hashlib.sha256(self.brief).hexdigest(),
                "collaborationPolicySHA256": hashlib.sha256(self.policy).hexdigest(),
                "effectiveInputSHA256": hashlib.sha256(self.effective_input).hexdigest(),
            },
            "cliSHA256": file_hash(executable), "outputKey": output_key(self.output),
            "leaseId": (lease or {}).get("leaseId"), "taskId": (lease or {}).get("taskId"),
            "ownerThreadId": (lease or {}).get("ownerThreadId"),
            "subagentExecution": {
                "requested": {"mode": mode},
                "observed": None,
            },
        }
        if self.role_hash is not None:
            self.record["workerRole"] = {
                "name": PRESET_ROLE_NAME, "model": effective["subagentModel"],
                "reasoningEffort": effective["subagentReasoningEffort"], "sha256": self.role_hash,
            }
            self.record["subagentExecution"]["requested"].update({
                "role": PRESET_ROLE_NAME, "model": effective["subagentModel"],
                "reasoningEffort": effective["subagentReasoningEffort"],
                "concurrentThreads": 1,
            })
        self._saved: bytes | None = None
        self._output_identity: tuple[int, int] | None = None
        self._receipt_identity: tuple[int, int] | None = None

    def preview(self) -> dict:
        return {**self.record, "localInputsValid": True, "dispatchExecuted": False,
                "preflightRequired": True, "capabilityRequired": True,
                "outputWillBeCreatedExclusively": True, "nextAction": "reserve_then_refresh_and_run"}

    def begin(self):
        if self.role_data is not None:
            try:
                os.mkdir(self.resources, 0o700)
                role_fd = os.open(self.frozen_role_path(), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                try:
                    write_all(role_fd, self.role_data)
                    os.fsync(role_fd)
                finally:
                    os.close(role_fd)
            except OSError:
                raise InvocationError("preset_role_freeze_failed") from None
        try:
            fd = os.open(self.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except OSError:
            raise InvocationError("output_already_exists_or_unwritable") from None
        info = os.fstat(fd)
        os.close(fd)
        self._output_identity = file_identity(info)
        try:
            self.record.update(phase="starting", createdAt=timestamp(), updatedAt=timestamp())
            data = self._encoded()
            fd = os.open(self.receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as handle:
                receipt_info = os.fstat(handle.fileno())
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            self._receipt_identity = file_identity(receipt_info)
            self._saved = data
        except OSError:
            # Remove only our untouched placeholder; preserve an external writer.
            try:
                current = self.output.lstat()
                if file_identity(current) == self._output_identity and current.st_size == 0:
                    self.output.unlink()
            except OSError:
                pass
            raise InvocationError("invocation_receipt_unwritable") from None

    def frozen_role_path(self) -> Path:
        return self.resources / (PRESET_ROLE_NAME + ".toml")

    def update(self, **fields):
        if self._saved is None:
            return
        try:
            current_fd = os.open(self.receipt, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError:
            raise InvocationError("invocation_receipt_changed") from None
        try:
            info = os.fstat(current_fd)
            if file_identity(info) != self._receipt_identity or read_open_file(current_fd, MAX_RECEIPT_BYTES) != self._saved:
                raise InvocationError("invocation_receipt_changed")
        finally:
            os.close(current_fd)
        next_record = {**self.record, **fields, "updatedAt": timestamp()}
        data = (json.dumps(next_record, ensure_ascii=False, sort_keys=True) + "\n").encode()
        if len(data) > MAX_RECEIPT_BYTES:
            raise InvocationError("invocation_receipt_invalid")
        temporary_fd, temporary_name = tempfile.mkstemp(prefix=".next-run-", dir=self.receipt.parent)
        temporary_identity = file_identity(os.fstat(temporary_fd))
        try:
            try:
                write_all(temporary_fd, data)
                os.fsync(temporary_fd)
            except OSError:
                raise InvocationError("invocation_receipt_unwritable") from None
            finally:
                os.close(temporary_fd)
            if not path_has_identity(self.receipt, self._receipt_identity):
                raise InvocationError("invocation_receipt_changed")
            os.replace(temporary_name, self.receipt)
            if not path_has_identity(self.receipt, temporary_identity):
                raise InvocationError("invocation_receipt_changed")
            directory_fd = os.open(self.receipt.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            self.record = next_record
            self._receipt_identity = temporary_identity
            self._saved = data
        except OSError:
            raise InvocationError("invocation_receipt_unwritable") from None
        finally:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass

    def verify_success(self):
        try:
            fd = os.open(self.output, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError:
            raise InvocationError("final_message_invalid") from None
        try:
            info = os.fstat(fd)
            if file_identity(info) != self._output_identity:
                raise InvocationError("final_message_invalid")
            data = read_open_file(fd, MAX_OUTPUT_BYTES)
            if not data.strip():
                raise InvocationError("final_message_missing")
            try:
                data.decode("utf-8")
            except UnicodeError:
                raise InvocationError("final_message_invalid") from None
            os.fchmod(fd, 0o600)
            if not path_has_identity(self.output, self._output_identity):
                raise InvocationError("final_message_invalid")
        finally:
            os.close(fd)
        self.update(finalMessage={"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()},
                    resultCollectedAt=timestamp())

    def _encoded(self) -> bytes:
        return (json.dumps(self.record, ensure_ascii=False, sort_keys=True) + "\n").encode()
