#!/usr/bin/env python3
"""Real native-control -> IPC -> Go -> loopback HTTP fixture; never uses live profiles."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_EVIDENCE = ROOT / ".local-artifacts/theme-upstream-1004v1/proxy-controls-live-1008v1/dynamic-http-1008v1"
NATIVE_INPUTS = [
    "Sources/CodexUsageWidget/Domain/LocalProxyQueue.swift",
    "Sources/CodexUsageWidget/Domain/UsageModels.swift",
    "Sources/CodexUsageWidget/Domain/WorkspacePresentation.swift",
    *["Sources/CodexUsageWidget/Services/" + name for name in [
        "DispatchParticipationSync.swift", "CodexProfileStore.swift", "CodexCredentialTransaction.swift",
        "DispatchActivityStore.swift", "LocalProxyBridge.swift", "LocalProxyNetworkSettings.swift", "LocalProxyQueueStore.swift",
    ]],
    "scripts/test-local-proxy-host.py", "scripts/LocalProxyDynamicHTTPFixture.swift",
    "scripts/check-build-target-idle.py", "scripts/test-local-proxy-dynamic-http.py",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def next_run(base):
    base.mkdir(parents=True, exist_ok=True)
    for index in range(1, 1000):
        target = base / ("run-" + str(index))
        try:
            target.mkdir()
        except FileExistsError:
            continue
        return target
    raise RuntimeError("bounded fixture evidence directory is full")


def freeze(run):
    target = run / "frozen-source"
    files = list(NATIVE_INPUTS)
    files += [str(path.relative_to(ROOT)) for path in sorted((ROOT / "Companion/LocalProxy").glob("*.go"))]
    files += ["Companion/LocalProxy/go.mod", "Companion/LocalProxy/go.sum"]
    manifest = []
    for relative in files:
        data = (ROOT / relative).read_bytes()
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        manifest.append({"path": relative, "sha256": digest(data), "bytes": len(data)})
    module = (target / "Companion/LocalProxy/go.mod").read_text()
    if "github.com/router-for-me/CLIProxyAPI/v8 v8.0.20" not in module:
        raise RuntimeError("actual current Go runtime v8.0.20 is required")
    save_json(run / "frozen-source-manifest.json", {"schemaVersion": 1, "files": manifest})
    return target, manifest


def run_command(args, cwd, env, log, timeout):
    print("DYNAMIC_HTTP_BUILD: " + log.stem, flush=True)
    result = subprocess.run(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=timeout)
    # Evidence is local, but routine output need not reveal workspace/temp paths.
    output = result.stdout.replace(str(ROOT), "<workspace>")
    output = re.sub(r"/private/var/folders/[^\s:]+", "<fixture-temp>", output)
    log.write_text(output)
    if result.returncode:
        print("DYNAMIC_HTTP_BUILD: exit " + str(result.returncode), flush=True)
    return result


class MockState:
    def __init__(self):
        self.lock = threading.Lock()
        self.calls = []
        self.failures = []
        self.root = None
        self.released = set()
        self.barriers = {name: threading.Event() for name in ["overlap", "revoked-retry"]}

    def snapshot(self):
        with self.lock:
            return {"calls": list(self.calls), "failures": list(self.failures), "released": sorted(self.released)}

    def close(self):
        for barrier in self.barriers.values():
            barrier.set()


class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, status, payload, content_type="application/json"):
        raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection = True

    def body(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size < 0 or size > 65536:
            raise ValueError("bounded synthetic body required")
        return self.rfile.read(size)

    def do_GET(self):
        if self.path == "/fixture/status":
            self.reply(200, self.server.state.snapshot())
        else:
            self.reply(404, {})

    def do_POST(self):
        state = self.server.state
        try:
            raw = self.body()
            if self.path == "/fixture/control":
                command = json.loads(raw)
                if command["command"] == "register":
                    root = Path(command["root"]).resolve()
                    if "aigoodbro-proxy-host-fixture-" not in str(root) or not root.is_dir():
                        raise ValueError("isolated synthetic support root required")
                    with state.lock:
                        state.root = root
                elif command["command"] == "release":
                    name = command["case"]
                    if name not in state.barriers:
                        raise ValueError("unknown barrier")
                    with state.lock:
                        state.released.add(name)
                    state.barriers[name].set()
                else:
                    raise ValueError("unknown control command")
                self.reply(200, {"ok": True})
                return
            # Consume credential data only to verify the synthetic tuple; never retain it.
            bearer = self.headers.get("Authorization", "").removeprefix("Bearer ")
            parts = bearer.split(".")
            if len(parts) != 3 or parts[0] != "fixture" or parts[2] != "fixture":
                raise ValueError("synthetic JWT required")
            claims = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
            account = claims.get("account_id", "").removeprefix("account-")
            if account not in {"A", "B", "C"} or claims["exp"] <= time.time():
                raise ValueError("synthetic account claim invalid")
            if self.headers.get("Chatgpt-Account-Id") != "account-" + account:
                raise ValueError("synthetic account header mismatch")
            marker = re.search(rb"dynamic:([A-Za-z0-9_-]+)", raw)
            if marker is None:
                raise ValueError("synthetic request marker missing")
            scenario = marker.group(1).decode()
            if state.root is None:
                raise ValueError("native registry not registered")
            registry = json.loads((state.root / "dispatch-activity-v1.json").read_bytes())
            leases = [row for row in registry["leases"] if row.get("route") == "proxy"
                      and row.get("state") == "running" and row.get("proxyProfileKey") == digest(account.encode())]
            if len(leases) != 1 or not leases[0].get("proxyRequestID"):
                raise ValueError("upstream account lacks exact running native lease")
            with state.lock:
                state.calls.append({"case": scenario, "account": account,
                                    "requestID": leases[0]["proxyRequestID"], "nativeLeaseVerified": True})
            if scenario in state.barriers and account == "A":
                if not state.barriers[scenario].wait(15):
                    raise ValueError("bounded hold barrier expired")
                if scenario == "revoked-retry":
                    self.reply(429, {"error": {"type": "usage_limit_reached", "message": "synthetic exhausted account",
                                               "resets_at": int(time.time()) + 60}})
                    return
            response = {"type": "response.completed", "response": {
                "id": "resp_dynamic_" + scenario, "object": "response", "status": "completed", "model": "fixture-model",
                "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "done-" + account}]}],
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
            }}
            event = ("event: response.completed\ndata: " + json.dumps(response) + "\n\n").encode()
            self.reply(200, event, "text/event-stream")
        except (ValueError, KeyError, OSError, json.JSONDecodeError) as error:
            # Only fixed validation reasons escape; no request/token values.
            reason = str(error) if isinstance(error, ValueError) and type(error) is ValueError else type(error).__name__
            with state.lock:
                state.failures.append(reason)
            self.reply(500, {"error": "synthetic fixture validation failed"})


def run_case(name, frozen, go_binary, run, env):
    evidence = run / name
    evidence.mkdir()
    state = MockState()
    server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
    server.daemon_threads = True
    server.state = state
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    fixture_env = dict(env, PROXY_FIXTURE_HELPER=str(go_binary),
                       PROXY_DYNAMIC_UPSTREAM="http://127.0.0.1:" + str(server.server_port),
                       PROXY_DYNAMIC_HTTP_EVIDENCE=str(evidence),
                       PROXY_DYNAMIC_HTTP_MUTATION="" if name == "positive" else name)
    try:
        native = run_command([sys.executable, str(frozen / "scripts/test-local-proxy-host.py"), "--dynamic-http-only"],
                             frozen, fixture_env, evidence / "native-build-and-run.log", 420)
    finally:
        state.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    upstream = state.snapshot()
    save_json(evidence / "upstream-receipt.json", upstream)
    result_path = evidence / "result.json"
    result = json.loads(result_path.read_text()) if result_path.exists() else {}
    if name == "positive":
        expected = native.returncode == 0 and result.get("ok") is True and not upstream["failures"]
    elif name == "stale-active-membership":
        expected = native.returncode != 0 and result.get("failure", {}).get("label") == "runtime-membership-disable-A"
    else:
        routes = [row for row in result.get("requests", []) if row["case"] == "revoked-retry"]
        expected = (native.returncode != 0 and result.get("failure", {}).get("label") == "http-route-revoked-retry"
                    and routes and routes[-1].get("actual") == "B"
                    and [row["account"] for row in upstream["calls"] if row["case"] == "revoked-retry"] == ["A", "B"])
    summary = {"case": name, "expectedOutcomeObserved": bool(expected), "exit": native.returncode,
               "checks": len(result.get("checks", [])), "requests": result.get("requests", []),
               "failure": result.get("failure", {}), "runtimeStopped": result.get("runtimeStopped", False)}
    save_json(evidence / "case-receipt.json", summary)
    print("DYNAMIC_HTTP_CASE: " + name + ": " + ("PASS" if expected else "FAIL"), flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    parser.add_argument("--positive-only", action="store_true", help="Omit both deliberate negative controls.")
    args = parser.parse_args()
    run = next_run(args.evidence.resolve())
    frozen, manifest = freeze(run)
    env = dict(os.environ, GOPROXY="off", GOSUMDB="off", GOTOOLCHAIN="local",
               GOCACHE=str(args.evidence.resolve() / "go-cache"),
               PYTHONPYCACHEPREFIX=str(args.evidence.resolve() / "python-cache"),
               PYTHONDONTWRITEBYTECODE="1")
    go_binary = run / "go-protocol-fixture"
    built = run_command(["go", "test", "-c", "-o", str(go_binary), "."],
                        frozen / "Companion/LocalProxy", env, run / "go-build.log", 420)
    if built.returncode:
        raise RuntimeError("frozen Go fixture compilation failed; see go-build.log")
    go_metadata = subprocess.check_output(["go", "version", "-m", str(go_binary)], env=env, text=True)
    (run / "go-binary-metadata.txt").write_text(go_metadata.replace(str(ROOT), "<workspace>"))
    cases = ["positive"] if args.positive_only else ["positive", "stale-active-membership", "removed-admission-revocation"]
    summaries = [run_case(name, frozen, go_binary, run, env) for name in cases]
    matching = all(digest((ROOT / row["path"]).read_bytes()) == row["sha256"] for row in manifest)
    receipt = {"schemaVersion": 1, "ok": all(row["expectedOutcomeObserved"] for row in summaries),
               "cases": summaries, "sourceManifest": "frozen-source-manifest.json",
               "sourceStillMatchesFrozenInputs": matching, "runtimeSDK": "CLIProxyAPI v8.0.20",
               "goBinarySHA256": digest(go_binary.read_bytes()), "realAccountsOrProviders": False,
               "networkBoundary": "127.0.0.1 only; Go dependencies offline",
               "productionFilesModifiedByFixture": False}
    save_json(run / "qualification.json", receipt)
    print("DYNAMIC_HTTP_RECEIPT: " + str(run / "qualification.json"), flush=True)
    if not receipt["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
