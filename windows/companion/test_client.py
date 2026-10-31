"""Synthetic protocol/client tests only; no Windows pipe or user config access."""
import argparse
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("companion_client", Path(__file__).with_name("next-dispatch.py"))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
ID = "a" * 64
HASH = "b" * 64


def reply(result, **extra):
    value = {"abi": 1, "requestId": ID, "result": result, "issueCode": None}
    value.update(extra)
    return json.dumps(value).encode()


class FakeTransport:
    def __init__(self, response=None, error=None, before=None):
        self.response = response
        self.error = error
        self.before = before
        self.writes = []
        self.authenticated = False
    def authenticate(self):
        if self.before == "auth":
            client.fail("companion_peer_untrusted")
        self.authenticated = True
    def recheck(self):
        if self.before == "deadline":
            client.fail("companion_ipc_timeout")
    def write_once(self, data):
        assert self.authenticated
        self.writes.append(data)
        if self.error:
            raise self.error
    def read_frame(self):
        if self.response is None:
            client.fail("companion_ipc_disconnected")
        return self.response


def args(command="run", **changes):
    values = dict(command=command, request_id=ID, profile_id=1, project="C:\\synthetic", lease_id=HASH, operation_id=HASH)
    values.update(changes)
    return argparse.Namespace(**values)


def verify_installed_layout(launcher):
    """Exercise the actual installed main; replace only its Windows transport.

    Also called by a macOS-only Rust fixture after the real SetupStore writer
    installs the real bundled client into a synthetic temporary Skill tree.
    """
    spec = importlib.util.spec_from_file_location("installed_companion_client", launcher)
    installed = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installed)
    seen = []

    class LayoutTransport(FakeTransport):
        def __init__(self, config, request_id):
            value = installed.decode(config.read_bytes(), 16384)
            installed.keys(value, ("schemaVersion", "python", "adapterABI", "bridgeRoot"))
            assert value["schemaVersion"] == value["adapterABI"] == 1
            assert Path(value["python"]).is_absolute()
            assert Path(value["bridgeRoot"]).is_absolute()
            assert config == launcher.parent.parent / "config" / "runtime-paths.json"
            seen.append(value)
            super().__init__(reply({"state": "missing"}))

        def close(self):
            pass

    with mock.patch.object(installed, "WinTransport", LayoutTransport), \
         mock.patch.object(sys, "argv", [str(launcher), "status", "--request-id", ID, "--operation-id", HASH]), \
         mock.patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO())), \
         mock.patch.object(sys, "stdout", io.StringIO()):
        assert installed.main() == 0
    assert len(seen) == 1
    return seen[0]


class ClientTests(unittest.TestCase):
    def request(self):
        return client.build_request(args(), io.BytesIO(b"fixture prompt"))

    def test_actual_installed_main_reads_only_native_generated_config_name(self):
        with tempfile.TemporaryDirectory(prefix="companion-layout-") as temporary:
            root = Path(temporary).resolve()
            (root / "bin").mkdir()
            (root / "config").mkdir()
            launcher = root / "bin" / "next-dispatch.py"
            launcher.write_bytes(Path(__file__).with_name("next-dispatch.py").read_bytes())
            config = root / "config" / "runtime-paths.json"
            config.write_text(json.dumps({"schemaVersion": 1, "python": str(root / "python.exe"),
                                         "adapterABI": 1, "bridgeRoot": str(root / "bridge")}))
            verify_installed_layout(launcher)
            config.rename(config.with_name("runtime-paths-v1.json"))
            with self.assertRaises(AssertionError):
                verify_installed_layout(launcher)

    def test_exact_typed_frame_and_prompt_stays_in_frame_only(self):
        task = {"taskId": "synthetic-1", "actionHash": HASH, "scopeSha256": HASH}
        t = FakeTransport(reply({"state": "accepted", "task": task, "taskState": "running"}))
        result = client.invoke_once(t, self.request())
        self.assertEqual(result["state"], "accepted")
        self.assertEqual(len(t.writes), 1)
        frame = t.writes[0]
        self.assertEqual(struct.unpack("<I", frame[:4])[0], len(frame)-4)
        self.assertEqual(json.loads(frame[4:])["method"]["leaseId"], HASH)
        self.assertNotIn("fixture prompt", json.dumps(result))

    def test_prewrite_peer_and_deadline_failures_have_zero_writes(self):
        for stage in ("auth", "deadline"):
            t = FakeTransport(before=stage)
            with self.assertRaises(client.ClientError):
                client.invoke_once(t, self.request())
            self.assertEqual(t.writes, [])

    def test_postwrite_disconnect_partial_and_unexpected_exception_unknown_once(self):
        for error in (OSError("synthetic"), client.ClientError("companion_ipc_short_write"), TypeError("synthetic"), KeyboardInterrupt()):
            t = FakeTransport(error=error)
            self.assertEqual(client.invoke_once(t, self.request()), {"state": "unknown"})
            self.assertEqual(len(t.writes), 1)

    def test_postwrite_error_response_is_not_claimed_not_sent(self):
        t = FakeTransport(reply(None, issueCode="companion_scope_changed"))
        self.assertEqual(client.invoke_once(t, self.request()), {"state": "unknown"})
        self.assertEqual(len(t.writes), 1)

    def test_wrong_id_version_method_and_extra_fields_are_unknown(self):
        bodies = [reply({"state": "unknown"}, requestId=HASH), reply({"state": "unknown"}, abi=2),
                  reply({"state": "ready", "scopeSha256": HASH, "validUntilMs": 100}),
                  reply({"state": "unknown", "approved": True}),
                  reply({"state": "unknown"}, arbitrary="field")]
        for body in bodies:
            t = FakeTransport(body)
            self.assertEqual(client.invoke_once(t, self.request()), {"state": "unknown"})
            self.assertEqual(len(t.writes), 1)

    def test_duplicate_json_keys_and_boolean_abi_reject(self):
        for body in (b'{"abi":1,"abi":1}', reply({"state": "unknown"}, abi=True)):
            with self.assertRaises(client.ClientError):
                client.response(body, ID)

    def test_prompt_size_utf8_nul_empty_and_scope_reject(self):
        for prompt in (b"", b" " * 8, b"x" * 65537, b"a\0b", b"\xff"):
            with self.assertRaises(client.ClientError):
                client.build_request(args(), io.BytesIO(prompt))
        with self.assertRaises(client.ClientError):
            client.build_request(args(profile_id=0), io.BytesIO(b"x"))
        with self.assertRaises(client.ClientError):
            client.build_request(args(lease_id="self-claimed"), io.BytesIO(b"x"))

    def test_status_only_query_carries_no_prompt_or_lease(self):
        request = client.build_request(args("status"), io.BytesIO(b"unused secret"))
        self.assertEqual(request["method"], {"kind": "status", "operationId": HASH})
        t = FakeTransport(reply({"state": "missing"}))
        self.assertEqual(client.invoke_once(t, request), {"state": "missing"})
        self.assertNotIn(b"unused secret", t.writes[0])

    def test_created_is_not_approval_or_model_success(self):
        task = {"taskId": "synthetic-1", "actionHash": HASH, "scopeSha256": HASH}
        t = FakeTransport(reply({"state": "created", "task": task, "taskState": "awaitingApproval"}))
        self.assertEqual(client.invoke_once(t, self.request())["state"], "created")
        t = FakeTransport(reply({"state": "accepted", "task": task, "taskState": "awaitingApproval"}))
        self.assertEqual(client.invoke_once(t, self.request()), {"state": "unknown"})


if __name__ == "__main__":
    unittest.main()
