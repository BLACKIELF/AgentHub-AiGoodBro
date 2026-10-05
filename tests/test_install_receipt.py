#!/usr/bin/env python3
"""Receipt transaction tests using temporary bundles and fault injection only."""

import importlib.util
import json
import os
import plistlib
import stat
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("install_receipt_writer", ROOT / "scripts/write-install-receipt.py")
assert SPEC is not None and SPEC.loader is not None
writer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(writer)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="next-receipt-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.bundle = self.root / "AiGoodBro.app"
        self.executable = self.bundle / "Contents/MacOS/AiGoodBro"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"fixture executable")
        self.plist = self.bundle / "Contents/Info.plist"
        self.info = {"CFBundleIdentifier": "com.example.next", "CFBundleExecutable": "AiGoodBro", "CFBundleVersion": "126"}
        self.plist.write_bytes(plistlib.dumps(self.info))
        self.receipt = self.root / "Support/Next/install-receipt-v1.json"

    def test_new_receipt_exact_schema_identity_and_permissions(self):
        writer.write_receipt(self.bundle, self.receipt)
        result = json.loads(self.receipt.read_bytes())
        self.assertEqual(set(result), {"schemaVersion", "installationID", "bundleIdentifier", "bundleIdentity", "executableIdentity"})
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["bundleIdentifier"], self.info["CFBundleIdentifier"])
        self.assertEqual(str(uuid.UUID(result["installationID"])), result["installationID"])
        for key, path in (("bundleIdentity", self.bundle), ("executableIdentity", self.executable)):
            self.assertEqual(result[key], {"device": path.stat().st_dev, "inode": path.stat().st_ino})
        self.assertEqual(stat.S_IMODE(self.receipt.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.receipt.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.receipt.parent.parent.stat().st_mode), 0o700)
        self.assertEqual(list(self.receipt.parent.glob(".*.tmp")), [])

    def test_same_version_reinstall_gets_new_uuid_and_preserves_existing_directory_mode(self):
        self.receipt.parent.mkdir(parents=True)
        self.receipt.parent.chmod(0o755)
        writer.write_receipt(self.bundle, self.receipt)
        first = json.loads(self.receipt.read_bytes())
        writer.write_receipt(self.bundle, self.receipt)
        second = json.loads(self.receipt.read_bytes())
        self.assertNotEqual(first["installationID"], second["installationID"])
        self.assertEqual(first["bundleIdentity"], second["bundleIdentity"])
        self.assertEqual(stat.S_IMODE(self.receipt.parent.stat().st_mode), 0o755)

    def test_all_precommit_io_failures_leave_previous_bytes_unchanged(self):
        self.receipt.parent.mkdir(parents=True)
        self.receipt.write_bytes(b"old receipt bytes")
        original_open = os.open

        def fail_temp_open(path, flags, *args, **kwargs):
            if flags & os.O_CREAT:
                raise OSError("create failure")
            return original_open(path, flags, *args, **kwargs)

        for operation in ("create", "write", "chmod", "fsync", "replace"):
            with self.subTest(operation=operation):
                target = {"create": "open", "write": "write", "chmod": "fchmod", "fsync": "fsync", "replace": "replace"}[operation]
                with patch.object(writer.os, target, side_effect=fail_temp_open if operation == "create" else OSError(operation)):
                    with self.assertRaises(OSError):
                        writer.write_receipt(self.bundle, self.receipt)
                self.assertEqual(self.receipt.read_bytes(), b"old receipt bytes")
                self.assertEqual(list(self.receipt.parent.glob(".*.tmp")), [])

    def test_mkdir_failure_does_not_create_receipt(self):
        with patch.object(writer.os, "mkdir", side_effect=OSError("mkdir failure")):
            with self.assertRaises(OSError):
                writer.write_receipt(self.bundle, self.receipt)
        self.assertFalse(self.receipt.exists())

    def test_no_fallible_chmod_or_fsync_after_replace(self):
        calls = []
        originals = {name: getattr(os, name) for name in ("fchmod", "fsync", "replace")}
        patches = []
        for name in originals:
            def record(*args, _name=name, **kwargs):
                calls.append(_name)
                return originals[_name](*args, **kwargs)
            patches.append(patch.object(writer.os, name, side_effect=record))
        with patches[0], patches[1], patches[2]:
            writer.write_receipt(self.bundle, self.receipt)
        self.assertEqual(calls, ["fchmod", "fsync", "replace"])

    def test_rejects_symlink_bundle_executable_plist_and_receipt(self):
        self.receipt.parent.mkdir(parents=True)
        target = self.root / "untouched"
        target.write_bytes(b"untouched bytes")
        for path in (self.bundle, self.executable, self.plist, self.receipt):
            with self.subTest(path=path.name):
                backup = path.with_name(path.name + ".real")
                if path.exists():
                    path.rename(backup)
                path.symlink_to(backup if backup.exists() else target)
                with self.assertRaises((OSError, ValueError)):
                    writer.write_receipt(self.bundle, self.receipt)
                path.unlink()
                if backup.exists():
                    backup.rename(path)
        self.assertEqual(target.read_bytes(), b"untouched bytes")

    def test_rejects_symlink_receipt_parent(self):
        other = self.root / "other"
        other.mkdir()
        (self.root / "Support").symlink_to(other)
        with self.assertRaises(OSError):
            writer.write_receipt(self.bundle, self.receipt)
        self.assertEqual(list(other.iterdir()), [])

    def test_rejects_oversized_existing_receipt(self):
        self.receipt.parent.mkdir(parents=True)
        old = b"x" * (writer.MAX_RECEIPT_BYTES + 1)
        self.receipt.write_bytes(old)
        with self.assertRaises(ValueError):
            writer.write_receipt(self.bundle, self.receipt)
        self.assertEqual(self.receipt.read_bytes(), old)

    def test_rejects_invalid_plist_executable_and_identifier(self):
        for field, values in (("CFBundleExecutable", ("../AiGoodBro", "dir/AiGoodBro", "dir\\AiGoodBro", "..", "", "name\n", 1)), ("CFBundleIdentifier", ("", "bad identifier", "../next", 1))):
            for value in values:
                with self.subTest(field=field, value=value):
                    info = dict(self.info, **{field: value})
                    self.plist.write_bytes(plistlib.dumps(info))
                    with self.assertRaises(ValueError):
                        writer.write_receipt(self.bundle, self.receipt)
        self.assertFalse(self.receipt.exists())

    def test_executable_directory_and_fifo_are_rejected_without_blocking(self):
        self.executable.unlink()
        self.executable.mkdir()
        with self.assertRaises(ValueError):
            writer.write_receipt(self.bundle, self.receipt)
        self.executable.rmdir()
        os.mkfifo(self.executable)
        with self.assertRaises(ValueError):
            writer.write_receipt(self.bundle, self.receipt)

    def test_fifo_plist_is_rejected_without_blocking_and_preserves_old_receipt(self):
        self.receipt.parent.mkdir(parents=True)
        self.receipt.write_bytes(b"old receipt bytes")
        self.plist.unlink()
        os.mkfifo(self.plist)
        with self.assertRaises(ValueError):
            writer.write_receipt(self.bundle, self.receipt)
        self.assertEqual(self.receipt.read_bytes(), b"old receipt bytes")

    def test_main_failure_is_nonzero(self):
        with patch.object(writer, "write_receipt", side_effect=OSError("fixture")):
            self.assertEqual(writer.main(["--bundle", str(self.bundle), "--receipt", str(self.receipt)]), 1)

    def test_malformed_plist_main_is_nonzero_without_traceback(self):
        self.plist.write_bytes(b"<?xml version='1.0'?><plist><dict>")
        self.assertEqual(writer.main(["--bundle", str(self.bundle), "--receipt", str(self.receipt)]), 1)
        self.assertFalse(self.receipt.exists())

    def test_partial_write_failure_and_changed_bundle_leave_old_receipt(self):
        self.receipt.parent.mkdir(parents=True)
        self.receipt.write_bytes(b"old receipt bytes")
        original_write = os.write
        calls = 0

        def partial_then_fail(fd, data):
            nonlocal calls
            calls += 1
            if calls == 1:
                return original_write(fd, data[:7])
            raise OSError("partial write failure")

        with patch.object(writer.os, "write", side_effect=partial_then_fail):
            with self.assertRaises(OSError):
                writer.write_receipt(self.bundle, self.receipt)
        self.assertEqual(self.receipt.read_bytes(), b"old receipt bytes")
        original_bundle_receipt = writer.bundle_receipt
        calls = 0

        def changed_bundle(bundle):
            nonlocal calls
            calls += 1
            result = original_bundle_receipt(bundle)
            if calls == 2:
                result["bundleIdentity"]["inode"] += 1
            return result

        with patch.object(writer, "bundle_receipt", side_effect=changed_bundle):
            with self.assertRaises(ValueError):
                writer.write_receipt(self.bundle, self.receipt)
        self.assertEqual(self.receipt.read_bytes(), b"old receipt bytes")
        self.assertEqual(list(self.receipt.parent.glob(".*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
