#!/usr/bin/env python3
"""Exercise the real Codex app-server through the adapter, using localhost fixtures."""
import argparse
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
    key = secrets.token_urlsafe(32)
    marker = "AIGOODBRO_ISOLATED_DESKTOP_OK"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert self.headers.get("Authorization") == "Bearer " + key
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
        for run in range(2):
            child = subprocess.Popen([str(args.helper.resolve()), "app-server", "--listen", "stdio://"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env=env, text=True)
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
                assert "error" not in reply, reply.get("error")
                return reply["result"]
            try:
                rpc("initialize", {"clientInfo": {"name": "aigoodbro_fixture", "version": "1"},
                                   "capabilities": {"experimentalApi": True}}, 1)
                send("initialized", {})
                params = {"cwd": temp, "approvalPolicy": "never", "sandbox": "read-only",
                          "model": "gpt-6-sol", "modelProvider": "openai",
                          "config": {"model_reasoning_effort": "max"}}
                if run == 0:
                    result = rpc("thread/start", params, 2)
                    thread_id = result["thread"]["id"]
                else:
                    result = rpc("thread/resume", {**params, "threadId": thread_id}, 2)
                assert result["modelProvider"] == "aigoodbro_local"
                assert result["model"] == "gpt-6-sol"
                rpc("turn/start", {"threadId": thread_id, "model": "gpt-6-sol", "effort": "max",
                                  "input": [{"type": "text", "text": "Return the fixture marker."}]}, 3)
                finished = until(lambda x: x.get("method") == "turn/completed")
                assert finished["params"]["turn"]["status"] == "completed", finished
                history = rpc("thread/list", {"modelProviders": ["openai"], "limit": 20}, 4)
                assert thread_id in [x["id"] for x in history["data"]]
            finally:
                child.stdin.close()
                try: child.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    child.wait(timeout=5)
                reader.join(timeout=2)
        assert len(calls) == 2, len(calls)
        assert all(x["model"] == "gpt-6-sol" and x.get("reasoning", {}).get("effort") == "max" for x in calls)
        assert any(marker in json.dumps(x.get("input")) for x in calls[1:])
        print("PASS: real app-server start, cold resume, history listing and two localhost turns; model/effort retained; no live account")
    server.shutdown()


if __name__ == "__main__":
    main()
