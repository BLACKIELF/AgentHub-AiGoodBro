#!/usr/bin/env python3
"""Exercise the real Codex app-server through the adapter, using localhost fixtures."""
import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import queue
import secrets
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--codex", type=Path, required=True)
    args = parser.parse_args()
    calls = []
    accounts = []
    key = secrets.token_urlsafe(32)
    marker = "AIGOODBRO_ISOLATED_DESKTOP_OK"
    desktop_token = "fixture-desktop-access-token"
    expected_auth = [key]

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            if self.headers.get("Upgrade"):
                self.send_response(426)
                self.end_headers()
                return
            # The official auth control plane remains separate from inference.
            if self.path.startswith("/backend-api/wham/accounts/check"):
                assert self.headers.get("Authorization") == "Bearer " + desktop_token
                value = {"accounts": [{"id": "fixture-account",
                    "workspace_backend_origin": "https://127.0.0.1",
                    "account_routing_override": "NO_CONSTRAINT"}]}
            elif self.path.startswith("/backend-api/wham/config/bundle"):
                value = {}
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(value).encode())
        def do_POST(self):
            if self.path != "/v1/responses":
                self.send_error(404)
                return
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert self.headers.get("Authorization") == "Bearer " + expected_auth[0]
            assert self.path == "/v1/responses"
            calls.append(body)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            item = {"id": "msg_fixture", "type": "message", "role": "assistant",
                    "status": "completed", "content": [{"type": "output_text", "text": marker, "annotations": []}]}
            events = [
                {"type": "response.created", "response": {"id": "resp_fixture"}},
                {"type": "response.output_item.added", "output_index": 0,
                 "item": {**item, "content": [], "status": "in_progress"}},
                {"type": "response.output_text.delta", "item_id": item["id"],
                 "output_index": 0, "content_index": 0, "delta": marker},
                {"type": "response.output_item.done", "output_index": 0, "item": item},
                {"type": "response.completed", "response": {
                    "id": "resp_fixture", "object": "response", "status": "completed",
                    "model": body["model"], "output": [item],
                    "usage": {"input_tokens": 10, "output_tokens": 1, "total_tokens": 11}}},
            ]
            for event in events:
                self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                self.wfile.flush()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="aigoodbro-desktop-fixture-") as temp:
        root = Path(temp)
        home = root / "codex"
        home.mkdir(mode=0o700)
        claims = {"email": "fixture@example.invalid", "https://api.openai.com/auth": {
            "chatgpt_account_id": "fixture-account", "chatgpt_user_id": "fixture-user",
            "chatgpt_plan_type": "plus"}}
        encode = lambda value: base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
        # Synthetic login in an isolated home; never copy a real account token.
        auth_path = home / "auth.json"
        auth_path.write_text(json.dumps({"auth_mode": "chatgpt", "tokens": {
            "id_token": encode({"alg": "none"}) + "." + encode(claims) + ".fixture",
            "access_token": desktop_token, "refresh_token": "fixture-refresh-token",
            "account_id": "fixture-account"}, "last_refresh": "2099-01-01T00:00:00Z"}))
        auth_path.chmod(0o600)
        auth_before = auth_path.read_bytes()
        (home / "config.toml").write_text(
            f'chatgpt_base_url="http://127.0.0.1:{server.server_port}/backend-api/"\n'
            'cli_auth_credentials_store="file"\n')
        connection = root / "connection.json"
        connection.write_text(json.dumps({
            "schemaVersion": 1, "endpoint": f"http://127.0.0.1:{server.server_port}/v1",
            "clientKey": key, "runID": "desktop-isolated-fixture",
            "codexExecutable": str(args.codex.resolve())}))
        connection.chmod(0o600)
        env = {"PATH": "/usr/bin:/bin", "HOME": temp, "CODEX_HOME": str(home),
               "TMPDIR": temp, "LANG": "en_US.UTF-8",
               "AIGOODBRO_PROXY_CONNECTION_FILE": str(connection)}
        thread_id = None
        for run in range(5):
            # Match Desktop's real argv, including config on both sides of
            # app-server. A bare app-server missed a provider-loss regression.
            command = [str(args.helper.resolve()), "-c", "features.code_mode_host=true",
                       "app-server", "--analytics-default-enabled", "-c",
                       "plugins.codex-app-tools@openai-bundled.mcp_servers.codex_app.enabled=true"]
            endpoint = f"http://127.0.0.1:{server.server_port}/v1"
            run_env = dict(env)
            expected_auth[0] = key
            if run == 0:
                # Seed the exact legacy provider metadata left by build 73.
                command[0] = str(args.codex.resolve())
                command += ["-c", 'model_provider="aigoodbro_local"', "-c",
                            'model_providers.aigoodbro_local={name="AiGoodBro Local",base_url="' + endpoint + '",env_key="AIGOODBRO_PROXY_KEY",wire_api="responses",requires_openai_auth=false,supports_websockets=false}']
                run_env["AIGOODBRO_PROXY_KEY"] = key
            elif run in (2, 4):
                # Ordinary Codex after disabling the proxy: no adapter/provider
                # definition, and no explicit provider on thread/resume.
                command[0] = str(args.codex.resolve())
                command += ["-c", 'openai_base_url="' + endpoint + '"',
                            "-c", "features.responses_websockets=false",
                            "-c", "features.responses_websockets_v2=false",
                            "-c", "features.enable_request_compression=false"]
                run_env.pop("AIGOODBRO_PROXY_CONNECTION_FILE")
                expected_auth[0] = desktop_token
            child = subprocess.Popen(command,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env=run_env, text=True)
            incoming = queue.Queue()
            def read():
                for line in child.stdout:
                    try: incoming.put(json.loads(line))
                    except ValueError: pass
            reader = threading.Thread(target=read, daemon=True)
            reader.start()
            def send(method, params, ident=None):
                value = {"method": method, "params": params}
                if ident is not None: value["id"] = ident
                child.stdin.write(json.dumps(value) + "\n")
                child.stdin.flush()
            def until(predicate):
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    item = incoming.get(timeout=max(.1, deadline-time.monotonic()))
                    if predicate(item): return item
                raise TimeoutError("app-server fixture timed out")
            def rpc(method, params, ident):
                send(method, params, ident)
                reply = until(lambda x: x.get("id") == ident)
                assert "error" not in reply, (run, method, reply.get("error"))
                return reply["result"]
            try:
                rpc("initialize", {"clientInfo": {"name": "aigoodbro_fixture", "version": "1"},
                                   "capabilities": {"experimentalApi": True}}, 1)
                send("initialized", {})
                params = {"cwd": temp, "approvalPolicy": "never", "sandbox": "read-only",
                          "model": "gpt-6-sol", "modelProvider": "aigoodbro_local",
                          "config": {"model_reasoning_effort": "max"}}
                if run in (0, 3):
                    result = rpc("thread/start", params, 2)
                    thread_id = result["thread"]["id"]
                else:
                    if run in (1, 2, 4):
                        params.pop("model")
                        params.pop("config")
                    if run in (2, 4):
                        params.pop("modelProvider")
                    result = rpc("thread/resume", {**params, "threadId": thread_id}, 2)
                assert result["modelProvider"] == ("aigoodbro_local" if run == 0 else "openai")
                assert result["model"] == "gpt-6-sol"
                if run > 0:
                    account = rpc("account/read", {"refreshToken": False}, 5)
                    assert account["requiresOpenaiAuth"] is True
                    assert account["account"]["type"] == "chatgpt"
                    assert account["account"]["email"] == "fixture@example.invalid"
                    assert account["account"]["planType"] == "plus"
                    accounts.append(account)
                turn = {"threadId": thread_id,
                        "input": [{"type": "text", "text": "Return the fixture marker."}]}
                if run in (0, 3):
                    turn.update(model="gpt-6-sol", effort="max")
                rpc("turn/start", turn, 3)
                finished = until(lambda x: x.get("method") == "turn/completed")
                assert finished["params"]["turn"]["status"] == "completed", finished
                # Old rollouts retain their creation provider in all-provider
                # history. New adapter threads must appear in normal OpenAI
                # history without needing the adapter after it is disabled.
                providers = [] if run == 2 else ["aigoodbro_local" if run == 0 else "openai"]
                history = rpc("thread/list", {"modelProviders": providers, "limit": 20}, 4)
                assert thread_id in [x["id"] for x in history["data"]]
            finally:
                child.stdin.close()
                try: child.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    child.wait(timeout=5)
                reader.join(timeout=2)
        assert len(calls) == 5, len(calls)
        # Standalone 0.154 no longer exposes workspaceRouting in account/read.
        # Compare the entire adapter/direct responses, including that field on
        # versions that expose it, instead of depending on a removed API field.
        assert len(accounts) == 4 and all(account == accounts[0] for account in accounts)
        assert all(x["model"] == "gpt-6-sol" and x.get("reasoning", {}).get("effort") == "max" for x in calls)
        assert any(marker in json.dumps(x.get("input")) for x in calls[1:])
        assert auth_path.read_bytes() == auth_before
        print("PASS: legacy provider recovery, proxy turn, ordinary Codex resume after disable, ChatGPT workspace identity, history and model/effort retained; synthetic account only")
    server.shutdown()


if __name__ == "__main__":
    main()
