#!/usr/bin/env python3
"""Called only by the native fixture with an explicitly supplied synthetic registry."""
import json
import os
from pathlib import Path
import sys

from next_dispatch_activity import ActivityError, Registry, digest, effective_state


def check_error(code, operation):
    try:
        operation()
    except ActivityError as error:
        assert str(error) == code, "unexpected registry error code"
    else:
        raise AssertionError("registry operation unexpectedly succeeded")


def reserve(registry, account, alias, task):
    return registry.reserve(account_key=digest(account), alias_key=digest(alias), code=None,
                            project=digest("fixture-project-" + task), owner="fixture-python",
                            task=task, route="direct")


def main():
    # No default path is ever allowed: the parent fixture owns and removes this root.
    root = Path(os.environ["PROXY_FIXTURE_ROOT"])
    assert "aigoodbro-proxy-host-fixture-" in str(root), "synthetic root required"
    registry = Registry(root)
    mode, lease_id = sys.argv[1:]
    state = registry.read()
    native = next(row for row in state["leases"] if row["leaseId"] == lease_id)
    checks = 0
    if mode in {"native-active", "native-uncertain"}:
        assert native["route"] == "proxy" and native["ownerThreadId"].startswith("next-")
        assert native["proxyRunID"] and native["proxyRequestID"] and native["proxyProfileKey"]
        assert native["pid"] > 1
        assert effective_state(native, native["heartbeatDueAt"] + 1) == "uncertain"
        checks += 2
        check_error("account_or_project_reserved", lambda: reserve(registry, "fixture-account", "different-alias", "account-overlap"))
        check_error("account_or_project_reserved", lambda: reserve(registry, "different-account", "fixture-alias", "alias-overlap"))
        checks += 2
        before = registry.path.read_bytes()
        check_error("reservation_owner_mismatch", lambda: registry.update(lease_id, "fixture-python"))
        check_error("reservation_owner_mismatch", lambda: registry.update(lease_id, "fixture-python", "accepted"))
        assert registry.path.read_bytes() == before
        checks += 3
        if mode == "native-active":
            held = reserve(registry, "python-held", "python-held-alias", "python-owned")
            registry.update(held["leaseId"], "fixture-python", "running")
            check_error("reservation_owner_mismatch", lambda: registry.update(held["leaseId"], native["ownerThreadId"], "accepted"))
            # A Python atomic rewrite preserves all native ownership fields unchanged.
            rewritten = next(row for row in registry.read()["leases"] if row["leaseId"] == lease_id)
            assert rewritten == native
            checks += 3
            print(json.dumps({"ok": True, "checks": checks, "leaseID": held["leaseId"]}))
            return
    elif mode == "release-python":
        assert native["ownerThreadId"] == "fixture-python" and native["route"] == "direct"
        registry.update(lease_id, "fixture-python")
        completed = registry.update(lease_id, "fixture-python", "accepted")
        assert completed["state"] == "accepted"
        checks += 2
    elif mode == "native-released":
        assert native["route"] == "proxy" and native["state"] == "accepted"
        next_dispatch = reserve(registry, "fixture-account", "fixture-alias", "after-native-release")
        registry.update(next_dispatch["leaseId"], "fixture-python", "accepted")
        checks += 2
        # Python deliberately does not mint native proxy leases itself.
        check_error("invalid_route", lambda: registry.reserve(
            account_key=digest("fixture-account"), alias_key=digest("fixture-alias"),
            code=None, project=digest("fixture-project"), owner="fixture-python", task="invalid-route", route="proxy"))
        checks += 1
    else:
        raise AssertionError("unknown fixture mode")
    print(json.dumps({"ok": True, "checks": checks}))


if __name__ == "__main__":
    main()
