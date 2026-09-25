#!/usr/bin/env python3
"""Next quota preflight and deterministic account selector."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from next_dispatch_activity import ActivityError, Registry, SUPPORT, merge_preflight


APPLE_EPOCH_OFFSET = 978_307_200
SHANGHAI = ZoneInfo("Asia/Shanghai")
SKILL_ROOT = Path(__file__).resolve().parent.parent
BUNDLED_MAPPING = SKILL_ROOT / "config" / "dispatch-codes-v1.json"
DEFAULT_POLICY = SKILL_ROOT / "config" / "dispatch-policy-v1.json"
RUNTIME_MAPPING = (
    Path.home()
    / "Library/Application Support/CodexAccountManagerNext/dispatch-codes-v1.json"
)
DEFAULT_SNAPSHOT = (
    Path.home()
    / "Library/Application Support/CodexAccountManagerNext/account-manager-next-v1.json"
)
DEFAULT_HUB_URL = "http://127.0.0.1:8787/api/overview"
REFRESH_NOTIFICATION = "local.codex.account-manager-next.refresh-dispatch-quotas"
DEFAULT_REFRESH_WAIT_SECONDS = 240
MAX_REFRESH_WAIT_SECONDS = 300
ACCOUNT_BUSY_STATES = {
    "awaiting_approval",
    "approved",
    "queued",
    "starting",
    "running",
    "cancel_requested",
    "uncertain",
}
PROJECT_BUSY_STATES = {
    "approved",
    "queued",
    "starting",
    "running",
    "cancel_requested",
    "uncertain",
}
KNOWN_TASK_STATES = ACCOUNT_BUSY_STATES | {
    "succeeded", "failed", "cancelled", "blocked_configuration",
}
REASON_LABELS = {
    "missing_profile": "Next 中没有该账号",
    "system_or_central": "系统/中枢账号",
    "participation_false": "未允许参与调度",
    "catalog_inactive": "编号当前未参与调度",
    "plan_excluded": "当前套餐被调度策略排除",
    "dispatch_window_closed": "已到账号退出调度时间",
    "dispatch_schedule_closed": "当前不在允许派单的时段",
    "invalid_execution_preference": "保存的模型、推理强度、速度或协作模式无效",
    "identity_mismatch": "账号身份与固定映射不一致",
    "missing_quota": "缺少额度快照",
    "invalid_quota_timestamp": "额度时间无效",
    "future_quota_timestamp": "额度时间在未来",
    "stale_quota": "额度快照已过期",
    "quota_read_not_confirmed": "最新快照未确认额度读取成功",
    "latest_quota_read_failed": "额度快照之后又发生读取失败",
    "invalid_quota_failure_timestamp": "额度失败时间无效",
    "missing_five_hour_quota": "缺少 5 小时额度",
    "invalid_five_hour_quota": "5 小时额度无效",
    "five_hour_reset_not_future": "5 小时重置时间已过",
    "missing_seven_day_quota": "缺少 7 天额度",
    "invalid_seven_day_quota": "7 天额度无效",
    "seven_day_reset_not_future": "7 天重置时间已过",
    "five_hour_below_reserve": "5 小时剩余额度低于派单保留阈值",
    "seven_day_below_reserve": "7 天剩余额度低于派单保留阈值",
    "hub_busy": "Hub 中已有未结束任务",
    "local_reserved": "其他任务已登记准备/运行占用，或状态待核实",
    "refresh_incomplete": "本次额度刷新未完成",
    "outside_refresh_scope": "不在本次指定账号刷新范围",
}


class PreflightError(RuntimeError):
    pass


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise PreflightError(f"文件不存在: {path}") from exc
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PreflightError(f"无法读取 JSON: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PreflightError(f"JSON 顶层必须是对象: {path}")
    return value


def apple_datetime(value: Any, field: str) -> datetime:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PreflightError(f"{field} 必须是 Apple 纪元秒")
    numeric = float(value)
    if not math.isfinite(numeric):
        raise PreflightError(f"{field} 不是有限数值")
    try:
        return datetime.fromtimestamp(numeric + APPLE_EPOCH_OFFSET, timezone.utc)
    except (OverflowError, OSError, ValueError) as exc:
        raise PreflightError(f"{field} 超出时间范围") from exc


def parse_request_start(value: str) -> datetime:
    text = value.strip()
    if not text:
        raise PreflightError("--request-start 不能为空")
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise PreflightError(
            "--request-start 必须是带时区 ISO 8601，例如 2026-08-30T22:05:00+08:00"
        ) from exc
    if parsed.tzinfo is None:
        raise PreflightError("--request-start 必须包含时区")
    return parsed.astimezone(timezone.utc)


def refresh_notification_script(name: str = REFRESH_NOTIFICATION) -> str:
    return (
        'ObjC.import("Foundation"); '
        "$.NSDistributedNotificationCenter.defaultCenter."
        "postNotificationNameObjectUserInfoDeliverImmediately("
        f'$("{name}"), undefined, undefined, true);'
    )


def request_next_refresh() -> datetime:
    request_start = datetime.now(timezone.utc)
    try:
        result = subprocess.run(
            [
                "/usr/bin/osascript",
                "-l",
                "JavaScript",
                "-e",
                refresh_notification_script(),
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PreflightError(f"无法请求 Next 刷新额度: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "未知错误"
        raise PreflightError(f"无法请求 Next 刷新额度: {detail}")
    return request_start


def parse_hub_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def validate_mapping(mapping: dict[str, Any]) -> None:
    if mapping.get("schemaVersion") != 1:
        raise PreflightError("dispatch-codes 映射 schemaVersion 必须为 1")
    accounts = mapping.get("accounts")
    if not isinstance(accounts, list) or not accounts:
        raise PreflightError("dispatch-codes 映射缺少 accounts")
    seen_codes: set[str] = set()
    seen_aliases: set[str] = set()
    seen_profiles: set[str] = set()
    max_age = mapping.get("snapshotMaxAgeSeconds")
    if (
        isinstance(max_age, bool)
        or not isinstance(max_age, (int, float))
        or not math.isfinite(float(max_age))
        or float(max_age) <= 0
    ):
        raise PreflightError("snapshotMaxAgeSeconds 必须是正数")
    minimums = mapping.get("minimumRemainingPercent")
    if not isinstance(minimums, dict):
        raise PreflightError("minimumRemainingPercent 必须是对象")
    for key in ("fiveHour", "sevenDay"):
        value = minimums.get(key)
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            or not 0 <= float(value) <= 100
        ):
            raise PreflightError(f"minimumRemainingPercent.{key} 必须在 0 到 100 之间")
    central = mapping.get("centralAliases", [])
    if not isinstance(central, list) or any(not isinstance(alias, str) for alias in central):
        raise PreflightError("centralAliases 必须是字符串数组")
    for index, account in enumerate(accounts):
        if not isinstance(account, dict):
            raise PreflightError(f"accounts[{index}] 必须是对象")
        code = account.get("code")
        alias = account.get("alias")
        profile_id = account.get("profileId")
        priority = account.get("priority")
        if not isinstance(code, str) or not re.fullmatch(r"[A-Z]", code):
            raise PreflightError(f"accounts[{index}].code 必须是单个大写字母")
        if not isinstance(alias, str) or not alias:
            raise PreflightError(f"accounts[{index}].alias 无效")
        if not isinstance(profile_id, str) or not profile_id:
            raise PreflightError(f"accounts[{index}].profileId 无效")
        if isinstance(priority, bool) or not isinstance(priority, int):
            raise PreflightError(f"accounts[{index}].priority 必须是整数")
        email = account.get("email")
        if email is not None and (not isinstance(email, str) or not email):
            raise PreflightError(f"accounts[{index}].email 无效")
        if code in seen_codes or alias in seen_aliases or profile_id in seen_profiles:
            raise PreflightError("dispatch-codes 存在重复 code、alias 或 profileId")
        seen_codes.add(code)
        seen_aliases.add(alias)
        seen_profiles.add(profile_id)
    projects = mapping.get("hubProjects", {})
    if not isinstance(projects, dict) or any(
        not isinstance(alias, str)
        or not alias
        or not isinstance(path, str)
        or not path
        or not Path(path).expanduser().is_absolute()
        for alias, path in projects.items()
    ):
        raise PreflightError("hubProjects 必须是 project -> 绝对路径映射")


def mapping_source(explicit: Path | None) -> tuple[dict[str, Any], Path, bool]:
    if explicit is not None:
        source = explicit.expanduser()
        fallback = False
    elif RUNTIME_MAPPING.is_file():
        source = RUNTIME_MAPPING
        fallback = False
    else:
        source = BUNDLED_MAPPING
        fallback = True
    mapping = load_json(source)
    validate_mapping(mapping)
    return mapping, source.resolve(), fallback


def fetch_hub(url: str, timeout: float) -> tuple[dict[str, Any] | None, str | None]:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.load(response)
    except (OSError, UnicodeError, urllib.error.URLError, json.JSONDecodeError) as exc:
        return None, f"{type(exc).__name__}: {exc}"
    error = hub_overview_error(value)
    if error is not None:
        return None, error
    return value, None


def hub_overview_error(value: Any) -> str | None:
    if not isinstance(value, dict):
        return "overview 顶层不是对象"
    for key in ("accounts", "projects"):
        entries = value.get(key)
        if not isinstance(entries, list) or any(
            not isinstance(entry, str) or not entry for entry in entries
        ):
            return f"overview.{key} 无法解析"
    tasks = value.get("tasks")
    if not isinstance(tasks, list):
        return "overview.tasks 无法解析"
    for task in tasks:
        if (
            not isinstance(task, dict)
            or not isinstance(task.get("state"), str)
            or task["state"] not in KNOWN_TASK_STATES
        ):
            return "overview.tasks 含未知任务状态"
        if task["state"] in ACCOUNT_BUSY_STATES and any(
            not isinstance(task.get(key), str) or not task[key]
            for key in ("id", "accountAlias", "project")
        ):
            return "overview.tasks 含缺失身份或项目的活动任务"
    return None


def active_hub_work(
    overview: dict[str, Any] | None, now: datetime
) -> tuple[dict[str, list[dict[str, str]]], dict[str, list[dict[str, str]]]]:
    account_work: dict[str, list[dict[str, str]]] = {}
    project_work: dict[str, list[dict[str, str]]] = {}
    tasks = overview.get("tasks", []) if overview else []
    if not isinstance(tasks, list):
        return account_work, project_work
    for task in tasks:
        if not isinstance(task, dict):
            continue
        state = str(task.get("state", ""))
        if state not in ACCOUNT_BUSY_STATES:
            continue
        if state == "awaiting_approval":
            expires = parse_hub_time(task.get("approvalExpiresAt"))
            if expires is not None and expires <= now:
                continue
        item = {
            "taskId": str(task.get("id", "")),
            "project": str(task.get("project", "")),
            "state": state,
        }
        alias = task.get("accountAlias")
        if isinstance(alias, str) and alias:
            account_work.setdefault(alias, []).append(item)
        project = task.get("project")
        if state in PROJECT_BUSY_STATES and isinstance(project, str) and project:
            project_work.setdefault(project, []).append(item)
    return account_work, project_work


def profile_index(snapshot: dict[str, Any]) -> dict[str, dict[str, Any]]:
    profiles = snapshot.get("profiles")
    if not isinstance(profiles, list):
        raise PreflightError("Next 快照缺少 profiles")
    indexed: dict[str, dict[str, Any]] = {}
    for profile in profiles:
        if not isinstance(profile, dict) or not isinstance(profile.get("id"), str):
            continue
        profile_id = profile["id"]
        if profile_id in indexed:
            raise PreflightError(f"Next 快照存在重复 profile id: {profile_id}")
        indexed[profile_id] = profile
    return indexed


def quota_window(
    snapshot: dict[str, Any], key: str, now: datetime
) -> tuple[dict[str, Any] | None, list[str], datetime | None]:
    label = "five_hour" if key == "fiveHour" else "seven_day"
    window = snapshot.get(key)
    if not isinstance(window, dict):
        return None, [f"missing_{label}_quota"], None
    used = window.get("usedPercent")
    if isinstance(used, bool) or not isinstance(used, (int, float)):
        return None, [f"invalid_{label}_quota"], None
    used_value = float(used)
    if not math.isfinite(used_value) or not 0 <= used_value <= 100:
        return None, [f"invalid_{label}_quota"], None
    try:
        reset = apple_datetime(window.get("resetsAt"), f"{key}.resetsAt")
    except PreflightError:
        return None, [f"invalid_{label}_quota"], None
    reasons: list[str] = []
    if reset <= now:
        reasons.append(f"{label}_reset_not_future")
    remaining = 100.0 - used_value
    return {
        "remainingPercent": round(remaining, 4),
        "resetAt": reset.isoformat().replace("+00:00", "Z"),
        "resetAtShanghai": reset.astimezone(SHANGHAI).strftime("%Y-%m-%d %H:%M:%S"),
    }, reasons, reset


def rank_key(row: dict[str, Any]) -> tuple[Any, ...]:
    return (
        not row.get("prioritizeDispatch", False),
        row["_sevenReset"],
        row.get("_fiveReset", row["_sevenReset"]),
        -row["sevenDay"]["remainingPercent"],
        -(row.get("fiveHour") or {}).get("remainingPercent", -1),
        row["priority"],
        row["alias"],
    )


def route_for(
    cwd: Path,
    mapping: dict[str, Any],
    overview: dict[str, Any] | None,
    project_work: dict[str, list[dict[str, str]]],
) -> dict[str, Any]:
    current = cwd.expanduser().resolve()
    matches: list[tuple[int, str, Path]] = []
    for alias, raw_path in mapping.get("hubProjects", {}).items():
        root = Path(raw_path).expanduser().resolve()
        try:
            current.relative_to(root)
        except ValueError:
            continue
        matches.append((len(str(root)), alias, root))
    if not matches:
        if overview is None:
            return {
                "mode": "direct",
                "ready": False,
                "reason": "hub_unavailable_for_busy_check",
                "project": None,
            }
        return {
            "mode": "direct",
            "ready": True,
            "reason": "cwd_not_registered_in_hub",
            "project": None,
        }
    matches.sort(key=lambda item: (-item[0], item[1]))
    longest = matches[0][0]
    best = [item for item in matches if item[0] == longest]
    if len(best) > 1:
        return {
            "mode": "hub",
            "ready": False,
            "reason": "ambiguous_hub_project",
            "project": None,
            "matches": [item[1] for item in best],
        }
    project = best[0][1]
    if overview is None:
        return {
            "mode": "hub",
            "ready": False,
            "reason": "hub_unavailable",
            "project": project,
        }
    advertised = overview.get("projects", [])
    if not isinstance(advertised, list) or project not in advertised:
        return {
            "mode": "hub",
            "ready": False,
            "reason": "hub_project_not_advertised",
            "project": project,
        }
    if project in project_work:
        return {
            "mode": "hub",
            "ready": False,
            "reason": "project_busy",
            "project": project,
            "activeTasks": project_work[project],
        }
    return {"mode": "hub", "ready": True, "reason": "registered_hub_project", "project": project}


def quota_read_failure_reason(
    profile: dict[str, Any], quota_snapshot: dict[str, Any], fetched_at: datetime,
) -> str | None:
    if quota_snapshot.get("quotaReadSucceeded") is not True:
        return "quota_read_not_confirmed"
    failure_value = profile.get("lastQuotaReadFailureAt")
    if failure_value is None:
        return None
    try:
        failure_at = apple_datetime(failure_value, "lastQuotaReadFailureAt")
    except PreflightError:
        return "invalid_quota_failure_timestamp"
    return "latest_quota_read_failed" if failure_at >= fetched_at else None



def apply_local_policy(mapping: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    if policy.get("schemaVersion") != 1:
        raise PreflightError("调度策略 schemaVersion 无效")
    plans = policy.get("excludedPlanTypes")
    rules = policy.get("accountRules")
    if not isinstance(plans, list) or any(not isinstance(plan, str) or not plan for plan in plans):
        raise PreflightError("调度策略 excludedPlanTypes 无效")
    if not isinstance(rules, list):
        raise PreflightError("调度策略 accountRules 无效")
    result = {**mapping, "excludedPlanTypes": [plan.lower() for plan in plans], "accounts": [dict(a) for a in mapping["accounts"]]}
    seen: set[str] = set()
    for rule in rules:
        if not isinstance(rule, dict) or any(not isinstance(rule.get(k), str) or not rule[k] for k in ("alias", "profileId", "notAfter")):
            raise PreflightError("调度策略账号规则无效")
        if rule["profileId"] in seen:
            raise PreflightError("调度策略账号规则重复")
        seen.add(rule["profileId"])
        parse_request_start(rule["notAfter"])
        matches = [a for a in result["accounts"] if a["alias"] == rule["alias"] or a["profileId"] == rule["profileId"]]
        if any(a["alias"] != rule["alias"] or a["profileId"] != rule["profileId"] for a in matches):
            raise PreflightError("调度截止规则与当前账号身份不一致")
        for account in matches:
            account["dispatchNotAfter"] = rule["notAfter"]
    return result


def dispatch_window_allows(policy: Any, now: datetime) -> bool:
    """Recurring local wall-clock intervals; endpoints match the Swift UI policy."""
    if policy is None:
        return True  # Backward-compatible profiles have no time restriction.
    if not isinstance(policy, dict):
        return False
    mode, zone, intervals = (policy.get(k) for k in ("mode", "timeZoneIdentifier", "intervals"))
    if mode not in ("unrestricted", "onlyWithin", "exceptWithin") or not isinstance(zone, str):
        return False
    try:
        local = now.astimezone(ZoneInfo(zone))
    except (KeyError, ValueError):
        return False
    if not isinstance(intervals, list) or len(intervals) > 32:
        return False
    matched = False
    weekday = local.isoweekday()
    previous = 7 if weekday == 1 else weekday - 1
    minute = local.hour * 60 + local.minute
    for interval in intervals:
        if not isinstance(interval, dict):
            return False
        start, end = interval.get("startMinute"), interval.get("endMinute")
        all_days, all_day = interval.get("allDays"), interval.get("allDay")
        days = interval.get("weekdays")
        if (type(start) is not int or type(end) is not int or not 0 <= start < 1440 or not 0 <= end < 1440
                or type(all_days) is not bool or type(all_day) is not bool
                or not isinstance(days, list) or any(type(d) is not int or not 1 <= d <= 7 for d in days)
                or (not all_days and not days) or (not all_day and start == end)):
            return False
        today, yesterday = all_days or weekday in days, all_days or previous in days
        matched |= (today if all_day else today and start <= minute < end if start < end
                    else (today and minute >= start) or (yesterday and minute < end))
    return True if mode == "unrestricted" else matched if mode == "onlyWithin" else not matched


def participation_reasons(profile: dict[str, Any], account: dict[str, Any], mapping: dict[str, Any], now: datetime) -> list[str]:
    reasons = []
    if not dispatch_window_allows(profile.get("dispatchParticipationWindow"), now):
        reasons.append("dispatch_schedule_closed")
    if profile.get("isSystemProfile") is True or account["alias"] in mapping.get("centralAliases", []):
        reasons.append("system_or_central")
    if profile.get("automaticSwitchParticipation") is False:
        reasons.append("participation_false")
    if account.get("active") is False:
        reasons.append("catalog_inactive")
    snapshot = profile.get("lastSnapshot") or {}
    plan = snapshot.get("planType") if isinstance(snapshot, dict) else None
    if isinstance(plan, str) and plan.lower() in mapping.get("excludedPlanTypes", ["pro"]):
        reasons.append("plan_excluded")
    if account.get("dispatchNotAfter") and now >= parse_request_start(account["dispatchNotAfter"]):
        reasons.append("dispatch_window_closed")
    return reasons


def valid_preset_name(value: Any) -> bool:
    if value is None:
        return True
    if not isinstance(value, str) or value != value.strip() or not value:
        return False
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return len(encoded) <= 64 and not any(unicodedata.category(character) == "Cc" for character in value)


def execution_preference(profile: dict[str, Any]) -> dict[str, Any] | None:
    preference = profile.get("executionPreference")
    if preference is None:
        return {"model": "gpt-6-astra", "reasoningEffort": "low", "serviceTier": "default", "subagentMode": "standard"}
    if not isinstance(preference, dict):
        return None
    model, effort, tier = (preference.get(k) for k in ("model", "reasoningEffort", "serviceTier"))
    subagent_mode = preference.get("subagentMode", "standard")
    maxima = {"gpt-6-astra": 6, "gpt-5.6-sol": 6, "gpt-5.6-terra": 6, "gpt-5.6-luna": 5, "gpt-5.5": 4, "gpt-5.2": 4}
    ranks = {"low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5, "ultra": 6}
    if not all(isinstance(value, str) for value in (model, effort, tier, subagent_mode)):
        return None
    if (model not in maxima or effort not in ranks or ranks[effort] > maxima[model]
            or tier not in ("default", "fast")
            or subagent_mode not in ("standard", "sol_luna", "luna_direct")):
        return None
    result = {"model": model, "reasoningEffort": effort, "serviceTier": tier, "subagentMode": subagent_mode}
    custom = preference.get("customPresets")
    if custom is not None:
        if not isinstance(custom, dict) or len(custom) > 3 or any(key not in ("standard", "sol_luna", "luna_direct") for key in custom):
            return None
        normalized = {}
        for key, value in custom.items():
            if not isinstance(value, dict) or set(value) - {"name", "useSavedModel", "model", "reasoningEffort", "subagentsEnabled", "subagentModel", "subagentReasoningEffort"}:
                return None
            required = ("useSavedModel", "model", "reasoningEffort", "subagentsEnabled", "subagentModel", "subagentReasoningEffort")
            if any(field not in value for field in required) or type(value["useSavedModel"]) is not bool or type(value["subagentsEnabled"]) is not bool:
                return None
            name = value.get("name")
            if not valid_preset_name(name):
                return None
            for model_key, effort_key in (("model", "reasoningEffort"), ("subagentModel", "subagentReasoningEffort")):
                chosen_model, chosen_effort = value[model_key], value[effort_key]
                if (not isinstance(chosen_model, str) or not isinstance(chosen_effort, str)
                        or chosen_model not in maxima or chosen_effort not in ranks
                        or ranks[chosen_effort] > maxima[chosen_model]):
                    return None
            normalized[key] = value
        result["customPresets"] = normalized
    strategy = effective_strategy(result)
    if tier == "fast" and (strategy["model"] == "gpt-5.2"
                           or strategy["subagentsEnabled"] and strategy["subagentModel"] == "gpt-5.2"):
        return None
    return result


def effective_strategy(preference: dict[str, Any]) -> dict[str, Any]:
    defaults = {
        "standard": {"useSavedModel": True, "model": "gpt-6-astra", "reasoningEffort": "low", "subagentsEnabled": False, "subagentModel": "gpt-5.6-luna", "subagentReasoningEffort": "max"},
        "sol_luna": {"useSavedModel": False, "model": "gpt-5.6-sol", "reasoningEffort": "high", "subagentsEnabled": True, "subagentModel": "gpt-5.6-luna", "subagentReasoningEffort": "max"},
        "luna_direct": {"useSavedModel": False, "model": "gpt-5.6-luna", "reasoningEffort": "max", "subagentsEnabled": False, "subagentModel": "gpt-5.6-luna", "subagentReasoningEffort": "max"},
    }
    mode = preference["subagentMode"]
    preset = (preference.get("customPresets") or {}).get(mode, defaults[mode])
    return {
        "model": preference["model"] if preset["useSavedModel"] else preset["model"],
        "reasoningEffort": preference["reasoningEffort"] if preset["useSavedModel"] else preset["reasoningEffort"],
        "serviceTier": preference["serviceTier"], "subagentMode": mode,
        "useSavedModel": preset["useSavedModel"], "subagentsEnabled": preset["subagentsEnabled"],
        "subagentModel": preset["subagentModel"], "subagentReasoningEffort": preset["subagentReasoningEffort"],
        "maximumConcurrentSubagents": 1 if preset["subagentsEnabled"] else 0,
    }


def valid_effective_strategy(strategy: dict[str, Any]) -> bool:
    """Validate the values that will actually reach Codex, after CLI overrides."""
    maxima = {"gpt-6-astra": 6, "gpt-5.6-sol": 6, "gpt-5.6-terra": 6,
              "gpt-5.6-luna": 5, "gpt-5.5": 4, "gpt-5.2": 4}
    ranks = {"low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5, "ultra": 6}

    def valid_pair(model: Any, effort: Any) -> bool:
        return (isinstance(model, str) and isinstance(effort, str)
                and model in maxima and effort in ranks and ranks[effort] <= maxima[model])

    if (not valid_pair(strategy.get("model"), strategy.get("reasoningEffort"))
            or strategy.get("serviceTier") not in ("default", "fast")
            or type(strategy.get("subagentsEnabled")) is not bool):
        return False
    if strategy["subagentsEnabled"] and not valid_pair(
            strategy.get("subagentModel"), strategy.get("subagentReasoningEffort")):
        return False
    return not (strategy["serviceTier"] == "fast"
                and (strategy["model"] == "gpt-5.2"
                     or strategy["subagentsEnabled"] and strategy.get("subagentModel") == "gpt-5.2"))


def refresh_status(
    snapshot: dict[str, Any], mapping: dict[str, Any], request_start: datetime,
    requested_code: str | None = None,
) -> dict[str, Any]:
    profiles = profile_index(snapshot)
    central = set(mapping.get("centralAliases", []))
    pending: list[str] = []
    failed: list[str] = []
    completed: list[str] = []
    if requested_code is not None and not any(
        account["code"] == requested_code for account in mapping["accounts"]
    ):
        raise PreflightError(f"未知账号编号: {requested_code}")
    for account in mapping["accounts"]:
        if requested_code is not None and account["code"] != requested_code:
            continue
        alias = account["alias"]
        profile = profiles.get(account["profileId"])
        if profile is None:
            pending.append(alias)
            continue
        if participation_reasons(profile, account, mapping, request_start):
            continue
        failure_value = profile.get("lastQuotaReadFailureAt")
        failure_at = None
        if failure_value is not None:
            try:
                failure_at = apple_datetime(failure_value, "lastQuotaReadFailureAt")
            except PreflightError:
                failed.append(alias)
                continue
        failed_during_request = failure_at is not None and failure_at >= request_start
        profile_snapshot = profile.get("lastSnapshot")
        if not isinstance(profile_snapshot, dict):
            (failed if failed_during_request else pending).append(alias)
            continue
        try:
            fetched_at = apple_datetime(profile_snapshot.get("fetchedAt"), "fetchedAt")
        except PreflightError:
            pending.append(alias)
            continue
        if fetched_at < request_start:
            (failed if failed_during_request else pending).append(alias)
        elif quota_read_failure_reason(profile, profile_snapshot, fetched_at) is not None:
            failed.append(alias)
        else:
            completed.append(alias)
    return {
        "complete": not pending and not failed,
        "requestedCode": requested_code,
        "completedAliases": completed,
        "pendingAliases": pending,
        "failedAliases": failed,
    }


def wait_for_refresh(
    snapshot_path: Path,
    mapping: dict[str, Any],
    request_start: datetime,
    timeout: float,
    poll_interval: float,
    requested_code: str | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    started = time.monotonic()
    while True:
        snapshot = load_json(snapshot_path)
        status = refresh_status(snapshot, mapping, request_start, requested_code)
        elapsed = time.monotonic() - started
        status.update(
            {
                "requestStart": request_start.isoformat().replace("+00:00", "Z"),
                "waitedSeconds": round(elapsed, 3),
            }
        )
        if status["complete"] or status["failedAliases"] or elapsed >= timeout:
            status["timedOut"] = bool(
                not status["complete"] and not status["failedAliases"] and elapsed >= timeout
            )
            return snapshot, status
        time.sleep(min(poll_interval, max(0.0, timeout - elapsed)))


def build_report(
    snapshot: dict[str, Any],
    mapping: dict[str, Any],
    overview: dict[str, Any] | None,
    now: datetime,
    cwd: Path,
    max_age: float,
    sources: dict[str, Any],
    refresh: dict[str, Any] | None = None,
    requested_code: str | None = None,
    allow_unreported_five_hour: bool = False,
) -> dict[str, Any]:
    if overview is not None:
        hub_error = hub_overview_error(overview)
        if hub_error is not None:
            overview = None
            sources = {**sources, "hubAvailable": False, "hubError": hub_error}
    profiles = profile_index(snapshot)
    account_work, project_work = active_hub_work(overview, now)
    route = route_for(cwd, mapping, overview, project_work)
    central = set(mapping.get("centralAliases", []))
    minimums = mapping.get("minimumRemainingPercent", {})
    min_five = float(minimums.get("fiveHour", 30))
    min_seven = float(minimums.get("sevenDay", 15))
    refreshed_since = (
        parse_request_start(refresh["requestStart"])
        if refresh and refresh.get("complete") and refresh.get("requestStart")
        else None
    )
    rows: list[dict[str, Any]] = []
    refresh_code = refresh.get("requestedCode") if refresh else None
    if refresh_code is not None and refresh_code != requested_code:
        raise PreflightError("刷新范围与指定账号不一致")

    for account in mapping["accounts"]:
        alias = account["alias"]
        row: dict[str, Any] = {
            "code": account["code"],
            "alias": alias,
            "profileId": account["profileId"],
            "priority": account["priority"],
            "fiveHour": None,
            "sevenDay": None,
            "snapshotAgeSeconds": None,
            "hubWork": account_work.get(alias, []),
            "reasons": [],
        }
        if refresh_code is not None and account["code"] != refresh_code:
            row["reasons"].append("outside_refresh_scope")
        profile = profiles.get(account["profileId"])
        if profile is None:
            row["reasons"].append("missing_profile")
            rows.append(row)
            continue
        row["reasons"].extend(participation_reasons(profile, account, mapping, now))
        row["prioritizeDispatch"] = profile.get("prioritizeDispatch") is True
        row["executionPreference"] = execution_preference(profile)
        if row["executionPreference"] is None:
            row["reasons"].append("invalid_execution_preference")
        if account.get("dispatchNotAfter"):
            row["dispatchNotAfter"] = account["dispatchNotAfter"]
        expected_email = account.get("email")
        snapshot_email = (
            profile["lastSnapshot"].get("email")
            if isinstance(profile.get("lastSnapshot"), dict)
            else None
        )
        if isinstance(expected_email, str) and (
            profile.get("name") != expected_email or snapshot_email != expected_email
        ):
            row["reasons"].append("identity_mismatch")
        profile_snapshot = profile.get("lastSnapshot")
        if not isinstance(profile_snapshot, dict):
            row["reasons"].append("missing_quota")
            rows.append(row)
            continue
        try:
            fetched_at = apple_datetime(profile_snapshot.get("fetchedAt"), "fetchedAt")
            age = (now - fetched_at).total_seconds()
            row["snapshotAgeSeconds"] = round(age, 3)
            row["snapshotFetchedAt"] = fetched_at.isoformat().replace("+00:00", "Z")
            read_failure = quota_read_failure_reason(profile, profile_snapshot, fetched_at)
            if read_failure is not None:
                row["reasons"].append(read_failure)
            if age < -5:
                row["reasons"].append("future_quota_timestamp")
            elif age > max_age and (
                refreshed_since is None or fetched_at < refreshed_since
            ):
                row["reasons"].append("stale_quota")
        except PreflightError:
            row["reasons"].append("invalid_quota_timestamp")

        five, five_reasons, five_reset = quota_window(profile_snapshot, "fiveHour", now)
        seven, seven_reasons, seven_reset = quota_window(profile_snapshot, "sevenDay", now)
        row["fiveHour"] = five
        row["sevenDay"] = seven
        # Explicit per-invocation allowance for a selected weekly-only Pro 5x.
        # It never invents a missing window, changes pool defaults, or admits
        # a present-but-invalid/exhausted five-hour window.
        balance = profile_snapshot.get("creditBalance")
        weekly_only = (
            allow_unreported_five_hour and len(mapping["accounts"]) == 1
            and isinstance(profile_snapshot.get("planType"), str)
            and profile_snapshot["planType"].lower() == "prolite"
            and profile_snapshot.get("fiveHour") is None
            and profile_snapshot.get("quotaReadSucceeded") is True
            and not profile_snapshot.get("failure")
            and profile_snapshot.get("creditBalanceUnlimited") is not True
            and not isinstance(balance, bool) and balance in (0, 0.0, "0", "0.0")
            and seven is not None and not seven_reasons and seven["remainingPercent"] > min_seven
        )
        row["quotaException"] = "explicit_prolite_unreported_five_hour" if weekly_only else None
        if not weekly_only:
            row["reasons"].extend(five_reasons)
        row["reasons"].extend(seven_reasons)
        if five is not None and five["remainingPercent"] <= min_five:
            row["reasons"].append("five_hour_below_reserve")
        if seven is not None and seven["remainingPercent"] <= min_seven:
            row["reasons"].append("seven_day_below_reserve")
        if row["hubWork"]:
            row["reasons"].append("hub_busy")
        if refresh and not refresh.get("complete"):
            row["reasons"].append("refresh_incomplete")
        if five_reset is not None:
            row["_fiveReset"] = five_reset
        if seven_reset is not None:
            row["_sevenReset"] = seven_reset
        row["reasons"] = list(dict.fromkeys(row["reasons"]))
        rows.append(row)

    eligible = [
        row
        for row in rows
        if not row["reasons"] and ("_fiveReset" in row or row.get("quotaException")) and "_sevenReset" in row
    ]
    eligible.sort(key=rank_key)
    for rank, row in enumerate(eligible, 1):
        row["rank"] = rank
    excluded = [row for row in rows if row not in eligible]
    for row in rows:
        row.pop("_fiveReset", None)
        row.pop("_sevenReset", None)

    recommended = eligible[0] if eligible else None
    selected = (
        next((row for row in eligible if row["code"] == requested_code), None)
        if requested_code
        else recommended
    )
    warnings: list[str] = []
    if sources.get("mappingFallback"):
        warnings.append("运行时映射不存在，使用 Skill 内置固定映射")
    if not sources.get("hubAvailable"):
        warnings.append("Hub 不可用，未合并实时忙碌状态")
    if refresh and not refresh.get("complete"):
        warnings.append("额度刷新未完成，本次预检不通过")
    if not eligible:
        warnings.append("没有满足额度、时效与空闲条件的账号")
    elif requested_code and selected is None:
        warnings.append(f"指定编号 {requested_code} 当前不可调度；不会自动改派其他账号")

    return {
        "schemaVersion": 2,
        "generatedAt": now.isoformat().replace("+00:00", "Z"),
        "timezone": "Asia/Shanghai",
        "cwd": str(cwd.expanduser().resolve()),
        "sources": sources,
        "thresholds": {
            "snapshotMaxAgeSeconds": max_age,
            "fiveHourMinimumRemainingPercent": min_five,
            "sevenDayMinimumRemainingPercent": min_seven,
        },
        "refresh": refresh,
        "route": route,
        "eligible": eligible,
        "excluded": excluded,
        "requestedCode": requested_code,
        "recommended": recommended,
        "selected": selected,
        "preflightPassed": bool(selected) and bool(route.get("ready")),
        "dispatchExecuted": False,
        "warnings": warnings,
    }


def percent(value: Any) -> str:
    if value is None:
        return "暂无"
    number = float(value)
    return f"{number:.0f}%" if number.is_integer() else f"{number:.1f}%"


def human_report(report: dict[str, Any]) -> str:
    route = report["route"]
    lines = [
        "Next 调度预检（只读）",
        f"工作目录：{report['cwd']}",
        f"映射：{report['sources']['mapping']}",
        f"快照：{report['sources']['snapshot']}",
        (
            f"Hub：{'可用' if report['sources']['hubAvailable'] else '不可用'}；"
            f"路由={route['mode']}；project={route.get('project') or '-'}；"
            f"ready={'是' if route.get('ready') else '否'}；原因={route['reason']}"
        ),
    ]
    refresh = report.get("refresh")
    if refresh:
        lines.append(
            "刷新等待："
            f"complete={'是' if refresh['complete'] else '否'}；"
            f"pending={','.join(refresh['pendingAliases']) or '-'}；"
            f"failed={','.join(refresh['failedAliases']) or '-'}；"
            f"waited={refresh['waitedSeconds']:.1f}s"
        )
    lines.extend(
        [
            "",
            "候选（门禁通过后按优先标记、7天重置、5小时重置、剩余额度、固定优先级排序）：",
            "排名\t编号\t账号\t5小时剩余\t5小时重置（上海）\t7天剩余\t7天重置（上海）",
        ]
    )
    for row in report["eligible"]:
        lines.append(
            "\t".join(
                [
                    str(row["rank"]),
                    row["code"] or "—",
                    row["alias"],
                    percent((row["fiveHour"] or {}).get("remainingPercent")),
                    (row["fiveHour"] or {}).get("resetAtShanghai", "暂无"),
                    percent(row["sevenDay"]["remainingPercent"]),
                    row["sevenDay"]["resetAtShanghai"],
                ]
            )
        )
    if not report["eligible"]:
        lines.append("-\t-\t没有可用账号\t-\t-\t-\t-")
    if report["excluded"]:
        lines.extend(["", "排除：", "编号\t账号\t原因"])
        for row in report["excluded"]:
            labels = [REASON_LABELS.get(reason, reason) for reason in row["reasons"]]
            lines.append(f"{row['code']}\t{row['alias']}\t{'；'.join(labels)}")
    selected = report.get("selected")
    if report.get("requestedCode"):
        lines.append(f"指定编号：{report['requestedCode']}（不可用时不自动改派）")
    lines.extend(
        [
            "",
            (
                f"预选：{selected['code']} / {selected['alias']}"
                if selected
                else "预选：无"
            ),
            f"预检：{'通过' if report['preflightPassed'] else '未通过'}；仅表示账号与路由检查结果。",
            "启动：未执行；本脚本不启动任务，是否已有执行授权由编排者依据当前对话判定。",
        ]
    )
    if selected and selected.get("executionPreference"):
        preference = selected["executionPreference"]
        lines.append(f"Next 保存参数：{preference['model']} / {preference['reasoningEffort']} / {preference['serviceTier']}（Hub 创建时冻结，批准前核对）")
    for warning in report["warnings"]:
        lines.append(f"警告：{warning}")
    return "\n".join(lines)


def self_test() -> None:
    # Keep recurring schedules aligned with the Swift editor and Hub gate.
    recurring = {"mode": "onlyWithin", "timeZoneIdentifier": "Asia/Shanghai", "intervals": [
        {"startMinute": 1380, "endMinute": 60, "allDays": False, "weekdays": [1], "allDay": False}
    ]}
    for at, expected in (("2026-09-07T15:00:00+00:00", True), ("2026-09-07T16:59:59+00:00", True),
                         ("2026-09-07T17:00:00+00:00", False), ("2026-09-06T16:30:00+00:00", False)):
        assert dispatch_window_allows(recurring, datetime.fromisoformat(at)) == expected
    at = datetime(2026, 9, 7, 15, tzinfo=timezone.utc)
    assert not dispatch_window_allows({**recurring, "mode": "exceptWithin"}, at)
    assert not dispatch_window_allows({**recurring, "intervals": []}, at)
    assert not dispatch_window_allows({**recurring, "timeZoneIdentifier": "invalid/zone"}, at)
    assert not dispatch_window_allows({**recurring, "intervals": [{"startMinute": True, "endMinute": 60}]}, at)
    dst = {"mode": "onlyWithin", "timeZoneIdentifier": "America/New_York", "intervals": [
        {"startMinute": 90, "endMinute": 120, "allDays": True, "weekdays": [], "allDay": False}
    ]}
    for at in ("2026-11-01T05:45:00+00:00", "2026-11-01T06:45:00+00:00"):
        assert dispatch_window_allows(dst, datetime.fromisoformat(at))
    now = datetime(2026, 8, 30, 12, 0, tzinfo=timezone.utc)

    def apple(instant: datetime) -> float:
        return instant.timestamp() - APPLE_EPOCH_OFFSET

    def profile(
        profile_id: str,
        email: str,
        seven_reset_hours: int,
        five_reset_hours: int,
        *,
        used_five: int = 10,
        used_seven: int = 10,
        age: int = 1,
        participation: bool | None = None,
    ) -> dict[str, Any]:
        value: dict[str, Any] = {
            "id": profile_id,
            "name": email,
            "isSystemProfile": False,
            "lastSnapshot": {
                "email": email,
                "quotaReadSucceeded": True,
                "fetchedAt": apple(now) - age,
                "fiveHour": {
                    "usedPercent": used_five,
                    "resetsAt": apple(now) + five_reset_hours * 3600,
                },
                "sevenDay": {
                    "usedPercent": used_seven,
                    "resetsAt": apple(now) + seven_reset_hours * 3600,
                },
            },
        }
        if participation is not None:
            value["automaticSwitchParticipation"] = participation
        return value

    mapping = {
        "schemaVersion": 1,
        "snapshotMaxAgeSeconds": 45,
        "minimumRemainingPercent": {"fiveHour": 30, "sevenDay": 15},
        "centralAliases": ["central"],
        "accounts": [
            {"code": code, "alias": alias, "profileId": code.lower(), "email": f"{alias}@x", "priority": priority}
            for code, alias, priority in (
                ("A", "alpha", 1),
                ("B", "busy", 1),
                ("C", "disabled", 1),
                ("D", "stale", 2),
                ("E", "low", 3),
                ("F", "fast", 4),
            )
        ],
        "hubProjects": {"demo": "/tmp/next-selector-self-test"},
    }
    validate_mapping(mapping)
    snapshot = {
        "profiles": [
            profile("a", "alpha@x", 5, 3),
            profile("b", "busy@x", 4, 1),
            profile("c", "disabled@x", 2, 1, participation=False),
            profile("d", "stale@x", 3, 1, age=60),
            profile("e", "low@x", 1, 1, used_seven=85),
            profile("f", "fast@x", 5, 2),
        ]
    }
    overview = {
        "accounts": ["alpha", "busy", "disabled", "stale", "low", "fast"],
        "projects": ["demo"],
        "tasks": [
            {
                "id": "task-1",
                "accountAlias": "busy",
                "project": "other",
                "state": "running",
            }
        ],
    }
    report = build_report(
        snapshot,
        mapping,
        overview,
        now,
        Path("/tmp/next-selector-self-test/work"),
        45,
        {
            "snapshot": "fixture",
            "mapping": "fixture",
            "mappingFallback": False,
            "hub": "fixture",
            "hubAvailable": True,
            "hubError": None,
        },
    )
    assert report["selected"]["alias"] == "fast"
    assert report["schemaVersion"] == 2
    assert report["preflightPassed"] is True
    assert report["dispatchExecuted"] is False
    excluded = {row["alias"]: row["reasons"] for row in report["excluded"]}
    assert "hub_busy" in excluded["busy"]
    assert "participation_false" in excluded["disabled"]
    assert "stale_quota" in excluded["stale"]
    assert "seven_day_below_reserve" in excluded["low"]
    assert report["route"] == {
        "mode": "hub",
        "ready": True,
        "reason": "registered_hub_project",
        "project": "demo",
    }
    requested_busy = build_report(
        snapshot,
        mapping,
        overview,
        now,
        Path("/tmp/next-selector-self-test/work"),
        45,
        {"hubAvailable": True, "mappingFallback": False},
        requested_code="B",
    )
    assert requested_busy["selected"] is None
    assert requested_busy["recommended"]["alias"] == "fast"
    assert requested_busy["preflightPassed"] is False
    assert requested_busy["dispatchExecuted"] is False
    project_busy_overview = {
        **overview,
        "tasks": [
            *overview["tasks"],
            {"id": "task-2", "accountAlias": "busy", "project": "demo", "state": "uncertain"},
        ],
    }
    for case_overview, case_cwd, expected_mode, expected_pass in (
        (overview, Path("/tmp/unregistered"), "direct", True),
        (None, Path("/tmp/next-selector-self-test/work"), "hub", False),
        (None, Path("/tmp/unregistered"), "direct", False),
        (project_busy_overview, Path("/tmp/next-selector-self-test/work"), "hub", False),
    ):
        case_report = build_report(
            snapshot, mapping, case_overview, now, case_cwd, 45,
            {**report["sources"], "hubAvailable": case_overview is not None},
        )
        assert case_report["selected"] is not None
        assert case_report["route"]["mode"] == expected_mode
        assert case_report["preflightPassed"] is expected_pass
        assert case_report["dispatchExecuted"] is False
        human_report(case_report)
    assert route_for(Path("/tmp/unregistered"), mapping, None, {})["ready"] is False
    notification_script = refresh_notification_script("local.camnext.ipc-self-test")
    assert "undefined, undefined" in notification_script
    assert "null" not in notification_script
    same_reset = [
        {
            "_sevenReset": now,
            "_fiveReset": now,
            "sevenDay": {"remainingPercent": 80},
            "fiveHour": {"remainingPercent": 90},
            "priority": 2,
            "alias": "z",
        },
        {
            "_sevenReset": now,
            "_fiveReset": now,
            "sevenDay": {"remainingPercent": 90},
            "fiveHour": {"remainingPercent": 80},
            "priority": 3,
            "alias": "a",
        },
    ]
    assert min(same_reset, key=rank_key)["alias"] == "a"
    request_start = now
    for item in snapshot["profiles"]:
        item["lastSnapshot"]["fetchedAt"] = apple(now) + 1
    status = refresh_status(snapshot, mapping, request_start)
    assert status["complete"] and "disabled" not in status["completedAliases"]
    refreshed_report = build_report(
        snapshot,
        mapping,
        overview,
        now.replace(minute=2),
        Path("/tmp/next-selector-self-test/work"),
        45,
        {"hubAvailable": True, "mappingFallback": False},
        {
            "complete": True,
            "requestStart": request_start.isoformat().replace("+00:00", "Z"),
        },
    )
    assert "stale_quota" not in next(
        row["reasons"] for row in refreshed_report["eligible"] if row["alias"] == "fast"
    )
    snapshot["profiles"][0]["lastQuotaReadFailureAt"] = apple(now) + 2
    status = refresh_status(snapshot, mapping, request_start)
    assert status["failedAliases"] == ["alpha"]
    blocked_report = build_report(
        snapshot,
        mapping,
        overview,
        now,
        Path("/tmp/next-selector-self-test/work"),
        45,
        {"hubAvailable": True, "mappingFallback": False},
        {"complete": False, "requestStart": request_start.isoformat()},
    )
    assert blocked_report["selected"] is None
    assert blocked_report["preflightPassed"] is False
    assert blocked_report["dispatchExecuted"] is False
    assert all("refresh_incomplete" in row["reasons"] for row in blocked_report["excluded"])
    # A failed refresh elsewhere must not block an explicitly selected healthy F.
    selected_refresh = refresh_status(snapshot, mapping, request_start, "F")
    assert selected_refresh["complete"] is True
    assert selected_refresh["completedAliases"] == ["fast"]
    assert selected_refresh["requestedCode"] == "F"
    selected_refresh["requestStart"] = request_start.isoformat()

    def selected_report(case_snapshot=snapshot, case_overview=overview, case_refresh=selected_refresh):
        return build_report(
            case_snapshot, mapping, case_overview, now.replace(minute=2),
            Path("/tmp/next-selector-self-test/work"), 45,
            {"hubAvailable": case_overview is not None, "mappingFallback": False},
            case_refresh, "F",
        )

    scoped_report = selected_report()
    assert scoped_report["preflightPassed"] is True
    assert [row["code"] for row in scoped_report["eligible"]] == ["F"]
    assert scoped_report["recommended"]["code"] == "F"
    assert all("outside_refresh_scope" in row["reasons"] for row in scoped_report["excluded"])
    assert selected_report(case_overview=None)["preflightPassed"] is False
    assert selected_report(case_overview=project_busy_overview)["preflightPassed"] is False
    busy_f = {**overview, "tasks": [{"id": "f-active", "accountAlias": "fast", "project": "other", "state": "uncertain"}]}
    assert selected_report(case_overview=busy_f)["preflightPassed"] is False

    for mutation in ("stale", "failure", "missing_quota", "low_five", "low_seven", "identity", "disabled", "missing_profile"):
        case_snapshot = json.loads(json.dumps(snapshot))
        chosen = case_snapshot["profiles"][-1]
        if mutation == "stale":
            chosen["lastSnapshot"]["fetchedAt"] = apple(now) - 1
        elif mutation == "failure":
            chosen["lastQuotaReadFailureAt"] = apple(now) + 2
        elif mutation == "missing_quota":
            chosen["lastSnapshot"]["fiveHour"] = None
        elif mutation == "low_five":
            chosen["lastSnapshot"]["fiveHour"]["usedPercent"] = 71
        elif mutation == "low_seven":
            chosen["lastSnapshot"]["sevenDay"]["usedPercent"] = 86
        elif mutation == "identity":
            chosen["lastSnapshot"]["email"] = "other@x"
        elif mutation == "disabled":
            chosen["automaticSwitchParticipation"] = False
        elif mutation == "missing_profile":
            case_snapshot["profiles"].pop()
        case_refresh = refresh_status(case_snapshot, mapping, request_start, "F")
        case_refresh["requestStart"] = request_start.isoformat()
        assert selected_report(case_snapshot=case_snapshot, case_refresh=case_refresh)["preflightPassed"] is False, mutation

    for bad_code in ("A", None):
        try:
            build_report(snapshot, mapping, overview, now, Path("/tmp/unregistered"), 45,
                         {"hubAvailable": True}, selected_refresh, bad_code)
        except PreflightError:
            pass
        else:
            raise AssertionError("mismatched refresh scope accepted")
    try:
        refresh_status(snapshot, mapping, request_start, "Z")
    except PreflightError:
        pass
    else:
        raise AssertionError("unknown scope accepted")
    for invalid_hub in (
        {"accounts": [], "projects": ["demo"]},
        {"accounts": [], "projects": ["demo"], "tasks": None},
        {"accounts": [], "projects": ["demo"], "tasks": {}},
        {"accounts": [], "projects": ["demo"], "tasks": [{}]},
        {"accounts": [], "projects": ["demo"], "tasks": [{"state": []}]},
        {"accounts": [], "projects": ["demo"], "tasks": [{"state": "new_unknown_state"}]},
        {"accounts": [], "projects": ["demo"], "tasks": [{"state": "running", "id": "x"}]},
    ):
        assert selected_report(case_overview=invalid_hub)["preflightPassed"] is False
        direct_bad_hub = build_report(snapshot, mapping, invalid_hub, now, Path("/tmp/unregistered"),
                                      45, {"hubAvailable": True}, selected_refresh, "F")
        assert direct_bad_hub["preflightPassed"] is False
    # A fresh cached snapshot must obey the same success/failure gate as Hub approval.
    for mutation in ("quota_false", "quota_missing", "quota_invalid", "failure_newer", "failure_equal", "failure_invalid"):
        case_snapshot = json.loads(json.dumps(snapshot))
        chosen = case_snapshot["profiles"][-1]
        if mutation == "quota_false":
            chosen["lastSnapshot"]["quotaReadSucceeded"] = False
        elif mutation == "quota_missing":
            chosen["lastSnapshot"].pop("quotaReadSucceeded")
        elif mutation == "quota_invalid":
            chosen["lastSnapshot"]["quotaReadSucceeded"] = "true"
        elif mutation == "failure_newer":
            chosen["lastQuotaReadFailureAt"] = apple(now) + 2
        elif mutation == "failure_equal":
            chosen["lastQuotaReadFailureAt"] = chosen["lastSnapshot"]["fetchedAt"]
        else:
            chosen["lastQuotaReadFailureAt"] = "invalid"
        cached = build_report(case_snapshot, mapping, overview, now, Path("/tmp/next-selector-self-test/work"),
                              45, {"hubAvailable": True}, requested_code="F")
        assert cached["preflightPassed"] is False and cached["selected"] is None, mutation
        scoped = refresh_status(case_snapshot, mapping, request_start, "F")
        assert scoped["complete"] is False and scoped["failedAliases"] == ["fast"], mutation

    # A later confirmed success supersedes failure, including failure in this request.
    for failure_offset in (-1, 0.5):
        recovered = json.loads(json.dumps(snapshot))
        recovered["profiles"][-1]["lastQuotaReadFailureAt"] = apple(now) + failure_offset
        cached = build_report(recovered, mapping, overview, now, Path("/tmp/next-selector-self-test/work"),
                              45, {"hubAvailable": True}, requested_code="F")
        assert cached["preflightPassed"] is True
        assert refresh_status(recovered, mapping, request_start, "F")["complete"] is True

    # An old failure must allow a new refresh to finish; a new failure ends that wait.
    waiting = json.loads(json.dumps(snapshot))
    waiting["profiles"][-1]["lastSnapshot"]["fetchedAt"] = apple(now) - 10
    waiting["profiles"][-1]["lastQuotaReadFailureAt"] = apple(now) - 9
    scoped = refresh_status(waiting, mapping, request_start, "F")
    assert scoped["pendingAliases"] == ["fast"] and not scoped["failedAliases"]
    waiting["profiles"][-1]["lastQuotaReadFailureAt"] = apple(now) + 0.5
    scoped = refresh_status(waiting, mapping, request_start, "F")
    assert scoped["failedAliases"] == ["fast"] and not scoped["pendingAliases"]
    json.dumps(report, ensure_ascii=False)


    # Policy enforcement must hold at the exact Shanghai cutoff, even before
    # a delayed UI automation has changed the account's participation flag.
    policy = {"schemaVersion": 1, "excludedPlanTypes": ["pro"], "accountRules": [
        {"alias": "alpha", "profileId": "a", "notAfter": "2026-08-30T20:00:00+08:00"}
    ]}
    policy_mapping = apply_local_policy({**mapping, "accounts": [mapping["accounts"][0]]}, policy)
    policy_snapshot = {"profiles": [profile("a", "alpha@x", 5, 3)]}
    policy_snapshot["profiles"][0]["lastSnapshot"]["planType"] = "plus"
    def policy_report(at: datetime, current=policy_snapshot, configured=policy_mapping):
        return build_report(current, configured, overview, at, Path("/tmp/next-selector-self-test/work"),
                            45, {"hubAvailable": True}, requested_code="A")
    before_cutoff = datetime.fromtimestamp(now.timestamp() - 1, timezone.utc)
    assert policy_report(before_cutoff)["preflightPassed"] is True
    cutoff_result = policy_report(now)
    assert cutoff_result["preflightPassed"] is False and cutoff_result["selected"] is None
    assert "dispatch_window_closed" in cutoff_result["excluded"][0]["reasons"]
    assert refresh_status(policy_snapshot, policy_mapping, now)["pendingAliases"] == []
    assert participation_reasons(policy_snapshot["profiles"][0], policy_mapping["accounts"][0], policy_mapping,
                                 datetime(2026, 8, 31, tzinfo=timezone.utc)) == ["dispatch_window_closed"]
    pro_snapshot = json.loads(json.dumps(policy_snapshot))
    pro_snapshot["profiles"][0]["lastSnapshot"]["planType"] = "pro"
    assert "plan_excluded" in policy_report(before_cutoff, pro_snapshot)["excluded"][0]["reasons"]
    inactive_mapping = json.loads(json.dumps(policy_mapping))
    inactive_mapping["accounts"][0]["active"] = False
    assert "catalog_inactive" in policy_report(before_cutoff, configured=inactive_mapping)["excluded"][0]["reasons"]
    mismatched = {**policy, "accountRules": [{**policy["accountRules"][0], "alias": "different"}]}
    try:
        apply_local_policy(mapping, mismatched)
    except PreflightError:
        pass
    else:
        raise AssertionError("cutoff policy followed a mismatched identity")
    for invalid_cutoff in ("2026-08-30T20:00:00", "not-a-date"):
        try:
            apply_local_policy(mapping, {**policy, "accountRules": [{**policy["accountRules"][0], "notAfter": invalid_cutoff}]})
        except PreflightError:
            pass
        else:
            raise AssertionError("invalid cutoff accepted")
    astra_snapshot = json.loads(json.dumps(policy_snapshot))
    astra_snapshot["profiles"][0]["executionPreference"] = {"model": "gpt-6-astra", "reasoningEffort": "low", "serviceTier": "fast"}
    assert policy_report(before_cutoff, astra_snapshot)["selected"]["executionPreference"] == {
        **astra_snapshot["profiles"][0]["executionPreference"], "subagentMode": "standard"
    }
    astra_snapshot["profiles"][0]["executionPreference"]["reasoningEffort"] = "unsupported"
    assert "invalid_execution_preference" in policy_report(before_cutoff, astra_snapshot)["excluded"][0]["reasons"]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="请求/读取 Next 额度并按固定规则选择调度账号；绝不启动 Codex。"
    )
    result.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    result.add_argument("--self-test", action="store_true", help="运行内置离线自检")
    result.add_argument("--cwd", type=Path, default=Path.cwd(), help="任务工作目录")
    result.add_argument("--code", help="指定固定大写编号；不可用时不自动改派")
    result.add_argument("--activity-dir", type=Path, default=SUPPORT, help="共享占用状态目录；测试使用隔离目录")
    result.add_argument("--lease-id", help="本任务已取得的占用标识；与 owner-thread 和 code 一起使用")
    result.add_argument("--owner-thread", help="占用所属任务 ID；不能忽略其他任务的占用")
    result.add_argument("--snapshot", type=Path, default=DEFAULT_SNAPSHOT, help="Next 快照路径")
    result.add_argument("--mapping", type=Path, help="显式固定编号映射路径")
    result.add_argument("--policy", type=Path, default=DEFAULT_POLICY, help="本机账号排除与截止时间策略")
    result.add_argument("--hub-url", default=DEFAULT_HUB_URL, help="Hub overview URL")
    result.add_argument("--hub-timeout", type=float, default=1.5, help="Hub GET 超时秒数")
    result.add_argument("--no-hub", action="store_true", help="跳过 Hub 查询；因无法排除忙碌账号而不放行")
    result.add_argument("--max-age", type=float, help="覆盖快照最大年龄秒数")
    result.add_argument(
        "--request-start",
        help="调用方发出刷新请求的带时区 ISO 8601 时间；提供后只轮询文件，不发刷新请求",
    )
    result.add_argument(
        "--refresh",
        action="store_true",
        help="通知已运行的 Next 只刷新参与账号额度，再轮询快照；不启动应用、不切号",
    )
    result.add_argument(
        "--wait-seconds",
        type=float,
        default=DEFAULT_REFRESH_WAIT_SECONDS,
        help=f"刷新轮询最长等待秒数（默认 {DEFAULT_REFRESH_WAIT_SECONDS}）",
    )
    result.add_argument("--poll-interval", type=float, default=0.5, help="刷新轮询间隔秒数")
    return result


def run(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return run_preflight(args)
    except (PreflightError, ActivityError, OSError, ValueError):
        if not args.self_test:
            try:
                Registry(args.activity_dir).issue(
                    issue_id="dispatch-preflight-failed", component="skill", phase="observed",
                    summary="Dispatch preflight could not be completed. Inspect the task's failure reason before reserving or starting work.",
                    code=args.code.upper() if args.code else None, owner=args.owner_thread, evidence=args.lease_id)
            except (ActivityError, OSError, ValueError):
                print("PRECHECK_ERROR: issue_journal_write_failed; preserve the failure in the owning task", file=sys.stderr)
        raise


def run_preflight(args) -> int:
    if args.self_test:
        self_test()
        print("SELF_TEST_OK")
        return 0
    if not math.isfinite(args.hub_timeout) or args.hub_timeout <= 0:
        raise PreflightError("--hub-timeout 必须大于 0")
    if not math.isfinite(args.wait_seconds) or not 0 <= args.wait_seconds <= MAX_REFRESH_WAIT_SECONDS:
        raise PreflightError(f"--wait-seconds 必须在 0 到 {MAX_REFRESH_WAIT_SECONDS} 秒之间")
    if not math.isfinite(args.poll_interval) or not 0.1 <= args.poll_interval <= 5:
        raise PreflightError("--poll-interval 必须在 0.1 到 5 秒之间")
    if args.refresh and args.request_start:
        raise PreflightError("--refresh 与 --request-start 不能同时使用")
    if bool(args.lease_id) != bool(args.owner_thread) or (args.lease_id and not args.code):
        raise PreflightError("--lease-id、--owner-thread、--code 必须一起使用")

    mapping, mapping_path, fallback = mapping_source(args.mapping)
    mapping = apply_local_policy(mapping, load_json(args.policy))
    requested_code = args.code.upper() if args.code else None
    configured_codes = {account["code"] for account in mapping["accounts"]}
    if requested_code is not None and requested_code not in configured_codes:
        raise PreflightError(f"未知账号编号: {requested_code}")
    snapshot_path = args.snapshot.expanduser().resolve()
    refresh = None
    if args.refresh or args.request_start:
        request_start = (
            request_next_refresh()
            if args.refresh
            else parse_request_start(args.request_start)
        )
        snapshot, refresh = wait_for_refresh(
            snapshot_path,
            mapping,
            request_start,
            args.wait_seconds,
            args.poll_interval,
            requested_code,
        )
    else:
        snapshot = load_json(snapshot_path)

    if args.no_hub:
        overview, hub_error = None, "disabled_by_flag"
    else:
        overview, hub_error = fetch_hub(args.hub_url, args.hub_timeout)
    max_age = (
        args.max_age
        if args.max_age is not None
        else float(mapping.get("snapshotMaxAgeSeconds", 45))
    )
    if not math.isfinite(max_age) or max_age <= 0:
        raise PreflightError("快照最大年龄必须大于 0")
    now = datetime.now(timezone.utc)
    report = build_report(
        snapshot,
        mapping,
        overview,
        now,
        args.cwd,
        max_age,
        {
            "snapshot": str(snapshot_path),
            "mapping": str(mapping_path),
            "policy": str(args.policy),
            "mappingFallback": fallback,
            "runtimeMappingExpected": str(RUNTIME_MAPPING),
            "hub": args.hub_url,
            "hubAvailable": overview is not None,
            "hubError": hub_error,
        },
        refresh,
        requested_code,
    )
    report = merge_preflight(report, snapshot, Registry(args.activity_dir).read(), args.cwd,
                             own_lease=args.lease_id, owner=args.owner_thread)
    if args.lease_id and not report["preflightPassed"]:
        Registry(args.activity_dir).issue(
            issue_id="reserved-dispatch-preflight-blocked", component="skill", phase="observed",
            summary="A reserved dispatch failed a quota, identity, participation or route gate. No task was started by this preflight.",
            code=requested_code, owner=args.owner_thread, evidence=args.lease_id)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(human_report(report))
    return 0


def main() -> int:
    try:
        return run()
    except (PreflightError, ActivityError, OSError) as exc:
        print(f"PRECHECK_ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
