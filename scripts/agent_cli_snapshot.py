"""Read-only, bounded projections of the Mac app's existing cache schemas.

No credentials, registry, locks, network, refreshes or configuration writes.
Codex dates use Swift's 2001 epoch; model receipts use ISO-8601. A recorded
model test never proves the current account/environment binding or grants run.
"""
from __future__ import annotations

from datetime import datetime, timezone, timedelta
import json
import math
import os
from pathlib import Path
import re
from urllib.parse import urlsplit

from next_dispatch_invocation import InvocationError, read_open_file

PROVIDERS = ("claudeCode", "grok", "openCode", "trae", "workBuddy", "kimi", "mimo", "zcode", "gemini", "antigravity")
SWIFT_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
MAX_PROFILE_BYTES = 2 * 1024 * 1024
MAX_MODEL_BYTES = 64 * 1024
MODEL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:+-]*(?:/[A-Za-z0-9][A-Za-z0-9._:+-]*)?\Z")
SUPPORT_HOSTS = {"zcode.z.ai", "opencode.ai", "docs.opencode.ai"}
FORBIDDEN_KEYS = ("token", "apikey", "api_key", "cookie", "password", "secret", "authorization", "email")


class SnapshotError(ValueError):
    """Only fixed public reason codes; never source values or local paths."""


def default_directory() -> Path:
    return Path.home() / "Library/Application Support/CodexAccountManagerNext"


def _require(condition: bool, code: str = "invalid_snapshot") -> None:
    if not condition:
        raise SnapshotError(code)


def _directory_fd(root: Path) -> int | None:
    # Walk directories via held descriptors: an ancestor/leaf symlink cannot
    # redirect a cache read to another file. Missing roots are never created.
    path = os.path.abspath(root)
    _require("\0" not in path and len(os.fsencode(path)) <= 4096, "invalid_directory")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in Path(path).parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        _require(os.fstat(fd).st_uid == os.getuid(), "unsafe_directory")
        return fd
    except FileNotFoundError:
        os.close(fd)
        return None
    except (OSError, SnapshotError):
        os.close(fd)
        raise SnapshotError("unsafe_directory") from None


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        _require(key not in result)
        result[key] = value
    return result


def _read(root: Path, filename: str, maximum: int) -> object | None:
    directory = _directory_fd(root)
    if directory is None:
        return None
    fd = None
    try:
        try:
            fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
        except FileNotFoundError:
            return None
        before = os.fstat(fd)
        data = read_open_file(fd, maximum)
        after = os.fstat(fd)
        _require((before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                 == (after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                 and len(data) == after.st_size, "snapshot_changed")
        value = json.loads(data, object_pairs_hook=_unique_object,
                           parse_constant=lambda _: (_ for _ in ()).throw(SnapshotError("invalid_snapshot")))
        _require(value is not None)
        return value
    except SnapshotError:
        raise
    except (OSError, InvocationError, ValueError, UnicodeError, RecursionError):
        raise SnapshotError("unreadable_or_invalid_snapshot") from None
    finally:
        if fd is not None:
            os.close(fd)
        os.close(directory)


def _number(value: object) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def _swift_date(value: object) -> datetime | None:
    if value is None:
        return None
    _require(_number(value))
    try:
        return SWIFT_EPOCH + timedelta(seconds=value)
    except (OverflowError, ValueError):
        raise SnapshotError("invalid_timestamp") from None


def _iso(value: datetime | None) -> str | None:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z") if value else None


def _quota(root: Path, now: datetime) -> dict:
    raw = _read(root, "account-manager-next-v1.json", MAX_PROFILE_BYTES)
    rows = []
    if raw is not None:
        _require(isinstance(raw, dict) and type(raw.get("schemaVersion")) is int and raw["schemaVersion"] == 1)
        profiles = raw.get("profiles")
        _require(isinstance(profiles, list) and len(profiles) <= 512)
        ids = set()
        for index, profile in enumerate(profiles, 1):
            _require(isinstance(profile, dict) and isinstance(profile.get("id"), str))
            _require(0 < len(profile["id"]) <= 128 and profile["id"] not in ids)
            ids.add(profile["id"])
            value = profile.get("lastSnapshot")
            row = {"account": f"Codex {index:02d}", "state": "unknown", "fetchedAt": None, "windows": []}
            if value is not None:
                _require(isinstance(value, dict))
                fetched = _swift_date(value.get("fetchedAt"))
                _require(fetched is not None)
                failed = _swift_date(profile.get("lastQuotaReadFailureAt"))
                succeeded = value.get("quotaReadSucceeded") is True
                fresh = succeeded and (failed is None or failed < fetched) and -5 <= (now - fetched).total_seconds() <= 900
                row.update(fetchedAt=_iso(fetched), state="fresh_cache" if fresh else "stale_cache")
                for name in ("fiveHour", "sevenDay", "monthly"):
                    window = value.get(name)
                    if window is None:
                        continue
                    _require(isinstance(window, dict) and _number(window.get("usedPercent")) and 0 <= window["usedPercent"] <= 100)
                    reset = _swift_date(window.get("resetsAt"))
                    row["windows"].append({"window": name, "recordedUsedPercent": window["usedPercent"],
                                           "resetsAt": _iso(reset), "current": fresh and (reset is None or reset > now)})
            rows.append(row)
    return {"sourceState": "missing" if raw is None else "loaded", "codex": rows,
            "otherProviders": [{"provider": kind, "state": "unknown", "reason": "quota_not_persisted"} for kind in PROVIDERS]}


def _token(value: object, maximum: int = 128) -> str:
    _require(isinstance(value, str) and 0 < len(value.encode("utf-8")) <= maximum)
    _require(not any(ord(c) < 32 or ord(c) == 127 for c in value))
    return value


def _model(value: object) -> str:
    token = _token(value)
    _require(MODEL_ID.fullmatch(token) is not None and not token.lower().startswith(("sk-", "bearer", "users/", "home/")))
    return token


def _absolute_date(value: object) -> datetime:
    token = _token(value, 64)
    try:
        result = datetime.fromisoformat(token.replace("Z", "+00:00"))
        _require(result.tzinfo is not None)
        return result.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise SnapshotError("invalid_timestamp") from None


def _instant(value: object, *, end: bool = False) -> tuple[str | None, datetime | None, bool]:
    if value is None or value == "":
        return None, None, False
    text = _token(value, 64)
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        civil = parsed.tzinfo is None
        if civil:
            _require(2020 <= parsed.year <= 2100)
            if len(text) == 10 and end:
                parsed = parsed.replace(hour=23, minute=59, second=59)
            parsed = parsed.astimezone()
        return text, parsed.astimezone(timezone.utc), civil
    except (ValueError, OverflowError):
        raise SnapshotError("invalid_timestamp") from None


def _forbidden(value: object) -> bool:
    if isinstance(value, dict):
        return any(any(word in key.lower() for word in FORBIDDEN_KEYS) or _forbidden(item) for key, item in value.items())
    return isinstance(value, list) and any(_forbidden(item) for item in value)


def _models(root: Path, now: datetime, provider: str | None = None) -> dict:
    raw = _read(root, "model-availability-v1.json", MAX_MODEL_BYTES)
    result = {"sourceState": "missing", "bindingVerified": False, "dispatchEligible": False,
              "civilDatesEvaluatedIn": "system_timezone", "evidence": [], "freeFacts": []}
    if raw is None:
        return result
    _require(isinstance(raw, dict) and type(raw.get("version")) is int and raw["version"] == 1 and not _forbidden(raw))
    evidence, facts = raw.get("evidence", []), raw.get("freeFacts", [])
    _require(isinstance(evidence, list) and len(evidence) <= 256 and isinstance(facts, list) and len(facts) <= 64)
    seen = set()
    for item in evidence:
        _require(isinstance(item, dict) and item.get("provider") in PROVIDERS and item.get("status") in ("passed", "invalid", "untested"))
        model, requested, observed = (_model(item.get(key)) for key in ("modelID", "requestedModel", "observedActualModel"))
        for key in ("environmentFingerprint", "accountFingerprint"):
            _require(re.fullmatch(r"[A-Za-z0-9_-]{1,128}", _token(item.get(key))) is not None)
        _require(re.fullmatch(r"(?:sha256:)?[a-f0-9]{64}", _token(item.get("executableHash"), 80)) is not None)
        _token(item.get("cliVersion"), 64)
        _require(type(item.get("matched")) is bool and type(item.get("toolCalls")) is int and 0 <= item["toolCalls"] <= 1024)
        _require(type(item.get("exitCode")) is int and -32768 <= item["exitCode"] <= 32767)
        tested, until = _absolute_date(item.get("testedAt")), _absolute_date(item.get("validUntil"))
        identity = (item["provider"], model, item["accountFingerprint"], tested)
        _require(identity not in seen)
        seen.add(identity)
        status = item["status"]
        reason = "current_binding_unverified"
        if status == "passed":
            if not item["matched"] or item["toolCalls"] != 0 or item["exitCode"] != 0 or requested != model or observed != model:
                status, reason = "invalid", "minimum_return_failed"
            elif tested > now + timedelta(seconds=300) or until < tested:
                status, reason = "invalid", "invalid_test_time"
            elif until < now:
                status, reason = "invalid", "expired"
        if provider is None or item["provider"] == provider:
            result["evidence"].append({"provider": item["provider"], "modelID": model, "recordedStatus": item["status"],
                                       "resolvedStatus": status, "reason": reason, "testedAt": _iso(tested), "validUntil": _iso(until)})
    seen.clear()
    for item in facts:
        _require(isinstance(item, dict) and item.get("provider") in PROVIDERS and item.get("source") in ("official", "userConfirmed"))
        _token(item.get("label"))  # Free-form labels are validated but never copied to output.
        models = item.get("modelIDs", [item.get("modelID")])
        _require(isinstance(models, list) and 0 < len(models) <= 16)
        models = [_model(value) for value in models]
        _require(len(set(models)) == len(models))
        confirmed = _token(item.get("confirmedOn"), 10)
        _require(re.fullmatch(r"\d{4}-\d{2}-\d{2}", confirmed) is not None)
        _instant(confirmed)
        source_host = None
        if item.get("sourceURL") is not None:
            source = urlsplit(_token(item["sourceURL"], 256))
            _require(source.scheme == "https" and source.netloc in SUPPORT_HOSTS and not source.query and not source.fragment)
            source_host = source.hostname
        start_text, start, start_civil = _instant(item.get("startsOn"))
        end_text, end, end_civil = _instant(item.get("endsOn"), end=True)
        order = item.get("sortIndex", 0)
        _require(type(order) is int and 0 <= order <= 1024)
        identity = (item["provider"], tuple(models), order)
        _require(identity not in seen)
        seen.add(identity)
        state = "upcoming" if start and start > now else "expired" if end and end < now else "active" if start or end else "unknown"
        if provider is None or item["provider"] == provider:
            result["freeFacts"].append({"provider": item["provider"], "modelIDs": models, "source": item["source"],
                                        "sourceHost": source_host, "confirmedOn": confirmed, "startsOn": start_text,
                                        "endsOn": end_text, "timezoneUnstated": start_civil or end_civil, "windowState": state})
    result["sourceState"] = "loaded"
    return result


def _environments(root: Path, now: datetime, model_directory: Path | None) -> dict:
    if model_directory is not None:
        return {"sourceState": "explicit_environment", "environments": [{"environment": "Environment 01", **_models(model_directory, now)}]}
    profiles = _read(root, "local-cli-accounts-v1.json", 256 * 1024)
    if profiles is None:
        return {"sourceState": "missing", "environments": []}
    _require(isinstance(profiles, list) and len(profiles) <= 64)
    rows, ids = [], set()
    for index, profile in enumerate(profiles, 1):
        _require(isinstance(profile, dict) and profile.get("kind") in PROVIDERS)
        identity = _token(profile.get("id"))
        _require(identity not in ids)
        ids.add(identity)
        path = _token(profile.get("configDirectory"), 4096)
        _require(path.startswith("/") and not path.startswith("//") and ".." not in Path(path).parts, "invalid_directory")
        row = {"environment": f"Environment {index:02d}", "provider": profile["kind"]}
        try:
            row.update(_models(Path(path), now, profile["kind"]))
        except SnapshotError as error:
            row.update(sourceState="rejected", reason=str(error), bindingVerified=False, dispatchEligible=False, evidence=[], freeFacts=[])
        except (ValueError, TypeError, OverflowError, RecursionError):
            row.update(sourceState="rejected", reason="invalid_snapshot", bindingVerified=False, dispatchEligible=False, evidence=[], freeFacts=[])
        rows.append(row)
    return {"sourceState": "loaded", "environments": rows}


def inspect(root: Path, *, section: str = "all", model_directory: Path | None = None, now: datetime | None = None) -> dict:
    _require(section in ("all", "quota", "models"), "invalid_section")
    now = now or datetime.now(timezone.utc)
    result = {"schemaVersion": 1, "mode": "cached", "isLive": False, "readAt": _iso(now)}
    try:
        if section in ("all", "quota"):
            result["quota"] = _quota(root, now)
        if section in ("all", "models"):
            result["models"] = _environments(root, now, model_directory)
    except SnapshotError:
        raise
    except (OSError, ValueError, TypeError, OverflowError, RecursionError):
        raise SnapshotError("unreadable_or_invalid_snapshot") from None
    return result
