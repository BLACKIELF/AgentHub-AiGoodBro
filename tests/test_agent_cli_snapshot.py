"""Synthetic cache inspection: no live accounts, registry, credentials or API."""
from contextlib import redirect_stdout, redirect_stderr
from datetime import datetime, timezone, timedelta
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import agent_cli_snapshot as snapshot

SPEC = importlib.util.spec_from_file_location("agent_cli_inspection_fixture", ROOT / "scripts/agent-cli.py")
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)
NOW = datetime(2026, 11, 9, 8, tzinfo=timezone.utc)


def swift_date(value):
    return (value - snapshot.SWIFT_EPOCH).total_seconds()


def receipt():
    return {"provider": "kimi", "modelID": "fixture-model", "requestedModel": "fixture-model",
            "observedActualModel": "fixture-model", "cliVersion": "fixture-1", "executableHash": "a" * 64,
            "environmentFingerprint": "synthetic-environment", "accountFingerprint": "synthetic-account",
            "matched": True, "toolCalls": 0, "exitCode": 0,
            "testedAt": snapshot._iso(NOW - timedelta(minutes=1)),
            "validUntil": snapshot._iso(NOW + timedelta(minutes=1)), "status": "passed"}


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agent-cli-snapshot-")
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def write(self, filename, value, root=None):
        path = (root or self.root) / filename
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def codex(self, **changes):
        value = {"fetchedAt": swift_date(NOW - timedelta(minutes=1)), "quotaReadSucceeded": True,
                 "email": "synthetic@example.invalid", "accountID": "private-fixture-id", "creditBalance": "not-exported",
                 "fiveHour": {"usedPercent": 20.5, "resetsAt": swift_date(NOW + timedelta(hours=1))}}
        value.update(changes)
        self.write("account-manager-next-v1.json", {"schemaVersion": 1, "profiles": [
            {"id": "private-fixture-profile", "name": "private-fixture-name", "codexHomePath": "/private-fixture-home",
             "lastSnapshot": value}]})

    def models(self, evidence=None, facts=None, root=None):
        return self.write("model-availability-v1.json", {"version": 1, "evidence": evidence or [], "freeFacts": facts or []}, root)

    def test_missing_directory_does_not_create_files(self):
        missing = self.root / "missing"
        value = snapshot.inspect(missing, now=NOW)
        self.assertFalse(missing.exists())
        self.assertEqual(value["mode"], "cached")
        self.assertFalse(value["isLive"])
        self.assertEqual(value["quota"]["sourceState"], "missing")
        self.assertEqual(value["models"]["sourceState"], "missing")
        self.assertTrue(all(row["state"] == "unknown" for row in value["quota"]["otherProviders"]))

    def test_codex_swift_dates_and_allowlist(self):
        self.codex()
        value = snapshot.inspect(self.root, section="quota", now=NOW)
        row = value["quota"]["codex"][0]
        self.assertEqual(row["state"], "fresh_cache")
        self.assertEqual(row["fetchedAt"], "2026-11-09T07:59:00Z")
        self.assertEqual(row["windows"][0]["recordedUsedPercent"], 20.5)
        self.assertTrue(row["windows"][0]["current"])
        text = json.dumps(value)
        for private in ("synthetic@example.invalid", "private-fixture", "not-exported", str(self.root)):
            self.assertNotIn(private, text)

    def test_stale_failed_future_and_ended_windows(self):
        for changes in ({"fetchedAt": swift_date(NOW - timedelta(hours=1))},
                        {"quotaReadSucceeded": False}, {"fetchedAt": swift_date(NOW + timedelta(minutes=1))}):
            self.codex(**changes)
            row = snapshot.inspect(self.root, section="quota", now=NOW)["quota"]["codex"][0]
            self.assertEqual(row["state"], "stale_cache")
            self.assertFalse(row["windows"][0]["current"])
        self.codex(fiveHour={"usedPercent": 100, "resetsAt": swift_date(NOW)})
        self.assertFalse(snapshot.inspect(self.root, section="quota", now=NOW)["quota"]["codex"][0]["windows"][0]["current"])
        source = self.root / "account-manager-next-v1.json"
        data = json.loads(source.read_text())
        data["profiles"][0]["lastQuotaReadFailureAt"] = swift_date(NOW)
        source.write_text(json.dumps(data))
        self.assertEqual(snapshot.inspect(self.root, section="quota", now=NOW)["quota"]["codex"][0]["state"], "stale_cache")

    def test_model_test_requires_current_binding_and_valid_evidence(self):
        item = receipt()
        self.models([item])
        result = snapshot.inspect(self.root, section="models", model_directory=self.root, now=NOW)["models"]["environments"][0]
        self.assertEqual(result["evidence"][0]["resolvedStatus"], "passed")
        self.assertFalse(result["bindingVerified"])
        self.assertFalse(result["dispatchEligible"])
        self.assertNotIn("synthetic-account", json.dumps(result))
        for changes, reason in (({"validUntil": snapshot._iso(NOW - timedelta(seconds=1))}, "expired"),
                                ({"toolCalls": 1}, "minimum_return_failed"),
                                ({"observedActualModel": "different-model"}, "minimum_return_failed"),
                                ({"testedAt": snapshot._iso(NOW + timedelta(hours=1))}, "invalid_test_time")):
            self.models([{**item, **changes}])
            row = snapshot.inspect(self.root, section="models", model_directory=self.root, now=NOW)["models"]["environments"][0]["evidence"][0]
            self.assertEqual(row["resolvedStatus"], "invalid")
            self.assertEqual(row["reason"], reason)

    def test_free_facts_keep_source_and_unknown_dates_separate(self):
        fact = {"provider": "openCode", "modelID": "fixture-model", "label": "Private local label", "source": "official",
                "confirmedOn": "2026-11-08", "sourceURL": "https://opencode.ai/docs/models"}
        self.models(facts=[fact])
        def read():
            return snapshot.inspect(self.root, section="models", model_directory=self.root, now=NOW)["models"]["environments"][0]["freeFacts"][0]
        row = read()
        self.assertEqual(row["source"], "official")
        self.assertEqual(row["sourceHost"], "opencode.ai")
        self.assertEqual(row["windowState"], "unknown")
        self.assertIsNone(row["endsOn"])
        self.assertNotIn("Private local label", json.dumps(row))
        self.models(facts=[{**fact, "endsOn": "2026-11-01"}])
        self.assertEqual(read()["windowState"], "expired")
        self.assertTrue(read()["timezoneUnstated"])
        self.models(facts=[{**fact, "startsOn": "2026-12-01T00:00:00Z"}])
        self.assertEqual(read()["windowState"], "upcoming")
        self.assertFalse(read()["timezoneUnstated"])

    def test_models_follow_only_saved_metadata_and_fixed_filename(self):
        environment = self.root / "environment"
        environment.mkdir()
        self.models([receipt()], root=environment)
        # A credential-shaped file is deliberately unreadable/malformed. The
        # inspector must never open it; only the fixed evidence file matters.
        (environment / "auth.json").mkdir()
        self.write("local-cli-accounts-v1.json", [{"id": "private-id", "kind": "kimi", "displayName": "private-name",
                                                 "configDirectory": str(environment)}])
        before = {p: p.stat().st_mtime_ns for p in self.root.rglob("*")}
        result = snapshot.inspect(self.root, section="models", now=NOW)
        rows = result["models"]["environments"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["evidence"][0]["provider"], "kimi")
        self.assertNotIn(str(environment), json.dumps(result))
        self.assertNotIn("private-", json.dumps(result))
        self.assertEqual(before, {p: p.stat().st_mtime_ns for p in self.root.rglob("*")})

    def test_wrong_provider_is_not_projected_into_saved_environment(self):
        self.models([receipt()])
        self.write("local-cli-accounts-v1.json", [{"id": "id", "kind": "grok", "configDirectory": str(self.root)}])
        row = snapshot.inspect(self.root, section="models", now=NOW)["models"]["environments"][0]
        self.assertEqual(row["evidence"], [])

    def test_symlink_root_file_ancestor_hardlink_fifo_rejected(self):
        self.codex()
        linked_root = self.root / "linked"
        linked_root.symlink_to(self.root, target_is_directory=True)
        for path in (linked_root, linked_root / "nested"):
            with self.assertRaises(snapshot.SnapshotError):
                snapshot.inspect(path, section="quota", now=NOW)
        source = self.root / "account-manager-next-v1.json"
        retained = self.root / "retained"
        source.rename(retained)
        source.symlink_to(retained)
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.inspect(self.root, section="quota", now=NOW)
        source.unlink()
        os.link(retained, source)
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.inspect(self.root, section="quota", now=NOW)
        source.unlink()
        os.mkfifo(source)
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.inspect(self.root, section="quota", now=NOW)

    def test_invalid_oversized_duplicate_and_nonfinite_data_rejected(self):
        source = self.root / "account-manager-next-v1.json"
        for raw in (b"private error details", b"null", b"{}" * (snapshot.MAX_PROFILE_BYTES // 2 + 1),
                    b'{"schemaVersion":1,"schemaVersion":1,"profiles":[]}',
                    b'{"schemaVersion":1,"profiles":[],"value":NaN}',
                    b'{"schemaVersion":true,"profiles":[]}'):
            source.write_bytes(raw)
            with self.assertRaises(snapshot.SnapshotError) as error:
                snapshot.inspect(self.root, section="quota", now=NOW)
            self.assertNotIn("private error", str(error.exception))
        self.codex(fiveHour={"usedPercent": True})
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.inspect(self.root, section="quota", now=NOW)

    def test_models_reject_secret_keys_urls_paths_and_oversized_file(self):
        for item in ({**receipt(), "apiToken": "synthetic-private-value"},
                     {**receipt(), "modelID": "/private/fixture/path"},
                     {**receipt(), "accountFingerprint": "synthetic@example.invalid"}):
            self.models([item])
            with self.assertRaises(snapshot.SnapshotError):
                snapshot.inspect(self.root, section="models", model_directory=self.root, now=NOW)
        self.models(facts=[{"provider": "kimi", "modelID": "fixture", "label": "fixture", "source": "official",
                            "confirmedOn": "2026-11-01", "sourceURL": "https://opencode.ai/?secret=fixture"}])
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.inspect(self.root, section="models", model_directory=self.root, now=NOW)
        (self.root / "model-availability-v1.json").write_bytes(b" " * (snapshot.MAX_MODEL_BYTES + 1))
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.inspect(self.root, section="models", model_directory=self.root, now=NOW)

    def test_invalid_model_cache_does_not_hide_independent_environment(self):
        good, bad = self.root / "good", self.root / "bad"
        good.mkdir()
        bad.mkdir()
        self.models([receipt()], root=good)
        (bad / "model-availability-v1.json").write_text("synthetic-private-error")
        self.write("local-cli-accounts-v1.json", [{"id": str(i), "kind": "kimi", "configDirectory": str(path)}
                                                 for i, path in enumerate((good, bad))])
        result = snapshot.inspect(self.root, section="models", now=NOW)
        rows = result["models"]["environments"]
        self.assertEqual([row["sourceState"] for row in rows], ["loaded", "rejected"])
        self.assertNotIn("synthetic-private-error", json.dumps(result))

    def test_concurrent_file_change_is_rejected(self):
        self.codex()
        source = self.root / "account-manager-next-v1.json"
        original_reader = snapshot.read_open_file
        def changed_reader(fd, maximum):
            data = original_reader(fd, maximum)
            source.write_bytes(data + b" ")
            return data
        with patch.object(snapshot, "read_open_file", side_effect=changed_reader):
            with self.assertRaisesRegex(snapshot.SnapshotError, "snapshot_changed"):
                snapshot.inspect(self.root, section="quota", now=NOW)

    def test_cli_does_not_construct_registry_or_write_bytecode(self):
        output, errors = io.StringIO(), io.StringIO()
        missing = self.root / "missing"
        with patch.object(CLI.activity, "Registry", side_effect=AssertionError("registry must not initialize")), \
             patch("socket.socket", side_effect=AssertionError("network must not open")), \
             patch("subprocess.Popen", side_effect=AssertionError("process must not launch")), \
             redirect_stdout(output), redirect_stderr(errors):
            code = CLI.main(["--state-dir", str(self.root / "never-created"), "inspect", "--snapshot-dir", str(missing)])
        self.assertEqual(code, 0, errors.getvalue())
        self.assertFalse(missing.exists())
        self.assertFalse((self.root / "never-created").exists())
        scripts = self.root / "isolated-scripts"
        scripts.mkdir()
        for name in ("agent-cli.py", "agent_cli_snapshot.py", "agent_cli_support.py", "agent_cli_grok.py", "agent_cli_grok_bridge.py",
                     "agent_cli_capabilities.py", "next_dispatch_activity.py", "next_dispatch_invocation.py"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        run = subprocess.run([sys.executable, str(scripts / "agent-cli.py"), "inspect", "--snapshot-dir", str(missing)],
                             text=True, capture_output=True, timeout=20)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse((scripts / "__pycache__").exists())
        self.assertFalse(missing.exists())

    def test_cli_errors_do_not_print_source_paths_or_content(self):
        (self.root / "account-manager-next-v1.json").write_text("synthetic-private-content")
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            code = CLI.main(["inspect", "--section", "quota", "--snapshot-dir", str(self.root)])
        self.assertEqual(code, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn(str(self.root), errors.getvalue())
        self.assertNotIn("synthetic-private-content", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
