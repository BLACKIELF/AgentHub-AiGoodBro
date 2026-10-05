#!/usr/bin/env python3
"""Atomically record a controlled Next install after the bundle is promoted."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import stat
import sys
import uuid
from pathlib import Path
from xml.parsers.expat import ExpatError

DEFAULT_RECEIPT = Path.home() / "Library/Application Support/CodexAccountManagerNext/install-receipt-v1.json"
MAX_RECEIPT_BYTES = 16 * 1024
MAX_PLIST_BYTES = 64 * 1024
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _close(fd: int) -> None:
    # There must be no fallible work after replace commits the new receipt.
    try:
        os.close(fd)
    except OSError:
        pass


def _directory(path: Path, create: bool = False) -> int:
    """Walk real directories only; restrict newly created directories to 0700."""
    path = Path(os.path.abspath(path))
    fd = os.open(path.anchor, DIR_FLAGS)
    try:
        for part in path.parts[1:]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, DIR_FLAGS, dir_fd=fd)
            _close(fd)
            fd = child
        return fd
    except BaseException:
        _close(fd)
        raise


def _identity(value: os.stat_result) -> dict[str, int]:
    if not all(0 <= n < 2**64 for n in (value.st_dev, value.st_ino)):
        raise ValueError("file identity is outside the supported range")
    return {"device": value.st_dev, "inode": value.st_ino}


def bundle_receipt(bundle: Path) -> dict:
    bundle_fd = _directory(bundle)
    contents_fd = macos_fd = plist_fd = exe_fd = None
    try:
        contents_fd = os.open("Contents", DIR_FLAGS, dir_fd=bundle_fd)
        plist_fd = os.open("Info.plist", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=contents_fd)
        plist_stat = os.fstat(plist_fd)
        if not stat.S_ISREG(plist_stat.st_mode) or plist_stat.st_size > MAX_PLIST_BYTES:
            raise ValueError("bundle Info.plist is not a bounded regular file")
        with os.fdopen(plist_fd, "rb") as source:
            plist_fd = None
            data = source.read(MAX_PLIST_BYTES + 1)
        if len(data) > MAX_PLIST_BYTES:
            raise ValueError("bundle Info.plist is too large")
        info = plistlib.loads(data)
        executable = info.get("CFBundleExecutable") if isinstance(info, dict) else None
        identifier = info.get("CFBundleIdentifier") if isinstance(info, dict) else None
        if (
            not isinstance(executable, str) or not executable or executable in (".", "..")
            or any(c in executable for c in ("/", "\\", "\x00"))
            or any(ord(c) < 32 or ord(c) == 127 for c in executable)
        ):
            raise ValueError("CFBundleExecutable must be a safe basename")
        if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", identifier):
            raise ValueError("CFBundleIdentifier is invalid")
        macos_fd = os.open("MacOS", DIR_FLAGS, dir_fd=contents_fd)
        exe_fd = os.open(executable, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=macos_fd)
        executable_stat = os.fstat(exe_fd)
        if not stat.S_ISREG(executable_stat.st_mode):
            raise ValueError("bundle executable must be a real regular file")
        return {
            "schemaVersion": 1,
            "installationID": str(uuid.uuid4()),
            "bundleIdentifier": identifier,
            "bundleIdentity": _identity(os.fstat(bundle_fd)),
            "executableIdentity": _identity(executable_stat),
        }
    finally:
        for fd in (exe_fd, plist_fd, macos_fd, contents_fd, bundle_fd):
            if fd is not None:
                _close(fd)


def _existing_receipt(parent_fd: int, name: str) -> None:
    try:
        value = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if not stat.S_ISREG(value.st_mode) or value.st_size > MAX_RECEIPT_BYTES:
        raise ValueError("existing receipt must be a bounded real regular file")


def write_receipt(bundle: Path, receipt: Path = DEFAULT_RECEIPT) -> None:
    value = bundle_receipt(bundle)
    payload = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    parent_fd = _directory(receipt.parent, create=True)
    temp_name = f".{receipt.name}.{uuid.uuid4().hex}.tmp"
    temp_fd = None
    committed = False
    try:
        _existing_receipt(parent_fd, receipt.name)
        temp_fd = os.open(temp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent_fd)
        os.fchmod(temp_fd, 0o600)
        remaining = memoryview(payload)
        while remaining:
            count = os.write(temp_fd, remaining)
            if count <= 0:
                raise OSError("receipt write made no progress")
            remaining = remaining[count:]
        os.fsync(temp_fd)
        os.close(temp_fd)
        temp_fd = None
        # A replaced app between validation and commit must fail closed.
        current = bundle_receipt(bundle)
        for field in ("bundleIdentifier", "bundleIdentity", "executableIdentity"):
            if current[field] != value[field]:
                raise ValueError("bundle changed before receipt commit")
        _existing_receipt(parent_fd, receipt.name)
        # Commit is the final potentially failing operation. No chmod or fsync
        # follows it: failure must always leave the previous receipt untouched.
        os.replace(temp_name, receipt.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        committed = True
    finally:
        if temp_fd is not None:
            _close(temp_fd)
        if not committed:
            try:
                os.unlink(temp_name, dir_fd=parent_fd)
            except OSError:
                pass
        _close(parent_fd)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, default=DEFAULT_RECEIPT)
    args = parser.parse_args(argv)
    try:
        write_receipt(args.bundle, args.receipt)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
        print("install: receipt could not be committed; installation must be rolled back.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
