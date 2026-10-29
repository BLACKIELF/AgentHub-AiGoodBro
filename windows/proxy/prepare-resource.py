#!/usr/bin/env python3
"""Prepare verified Windows helper resources and the current Mac model seed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SHARED = REPO / "Companion/LocalProxy"
MODEL_SOURCE = REPO / "Sources/CodexUsageWidget/Services/CodexProfileStore.swift"
DEFAULT_RESOURCE = REPO / "windows/apps/codexu-tauri/src-tauri/resources/proxy"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular_bytes(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("A required resource is not a regular file")
    return path.read_bytes()


def model_seed(data):
    text = data.decode("utf-8")
    outer = re.search(r"(?m)^struct CodexExecutionPreference: Codable, Equatable \{\s*", text)
    if not outer:
        raise ValueError("The Mac execution preference declaration changed")
    header = re.match(r"enum Model: String, Codable, CaseIterable \{\s*\n", text[outer.end():])
    if not header:
        raise ValueError("The Mac model seed is no longer an automatic CaseIterable enum")
    start = outer.end() + header.end()
    depth, names, values, lines = 1, [], [], []
    for line in text[start:].splitlines(keepends=True):
        if '/*' in line or '"""' in line:
            raise ValueError("Unsupported Swift syntax in the model declaration; review required")
        clean = re.sub(r'"(?:\\.|[^"\\])*"', '""', line).split('//', 1)[0]
        if depth == 1 and clean.strip().startswith("case "):
            match = re.fullmatch(r'\s*case ([A-Za-z][A-Za-z0-9_]*) = "([A-Za-z0-9][A-Za-z0-9_.-]{0,127})"\s*(?://[^\n]*)?\n?', line)
            if not match:
                raise ValueError("A Mac model case is ambiguous; review required")
            names.append(match[1]); values.append(match[2])
        if re.search(r"\bstatic\s+(?:let|var)\s+allCases\b", clean):
            raise ValueError("A custom Mac allCases requires explicit migration review")
        lines.append(line)
        depth += clean.count('{') - clean.count('}')
        if depth == 0:
            break
    if depth != 0 or not values or len(values) > 100 or len(set(values)) != len(values) or len(set(names)) != len(names):
        raise ValueError("The complete Mac model declaration could not be verified")
    return values, digest(''.join(lines).encode("utf-8"))


def safe_output(directory):
    absolute = directory.absolute()
    for parent in [absolute, *absolute.parents]:
        if parent.is_symlink():
            raise ValueError("Resource output may not traverse a symlink")
        if parent.exists():
            stat = parent.stat()
            if getattr(stat, "st_file_attributes", 0) & 0x400:
                raise ValueError("Resource output may not traverse a reparse point")
    try:
        relative = absolute.relative_to(REPO)
    except ValueError:
        return absolute
    # Source output is generated only after the root owner ignores this folder.
    result = subprocess.run(["git", "check-ignore", "-q", "--", str(relative / "aigoodbro-local-proxy.exe")], cwd=REPO)
    if result.returncode != 0:
        raise ValueError("Ignore the generated resources/proxy folder before preparing source-tree binaries")
    return absolute


def pe_machine(data, target):
    if len(data) < 256 or data[:2] != b'MZ':
        raise ValueError("The helper is not a PE executable")
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    if offset + 6 > len(data) or data[offset:offset + 4] != b'PE\0\0':
        raise ValueError("The helper has an invalid PE header")
    expected = {"windows-amd64": 0x8664, "windows-arm64": 0xaa64}[target]
    if struct.unpack_from('<H', data, offset + 4)[0] != expected:
        raise ValueError("The helper architecture does not match the bundle target")


def atomic_write(path, data):
    if path.exists() and regular_bytes(path) == data:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".proxy-resource-", dir=path.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        try:
            temporary.write(data); temporary.flush(); os.fsync(temporary.fileno())
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", required=True, type=Path)
    parser.add_argument("--resource-dir", type=Path, default=DEFAULT_RESOURCE)
    parser.add_argument("--target", choices=("windows-amd64", "windows-arm64"), default="windows-amd64")
    args = parser.parse_args()
    resource = safe_output(args.resource_dir)
    build_root = args.build_root.resolve(); build_root.mkdir(parents=True, exist_ok=True)
    source_data = regular_bytes(MODEL_SOURCE)
    models, declaration_digest = model_seed(source_data)
    with tempfile.TemporaryDirectory(prefix="resource-candidate-", dir=build_root) as working:
        working = Path(working)
        helper = working / "aigoodbro-local-proxy.exe"
        command = [sys.executable, str(HERE / "build.py"), "--build-root", str(build_root), "--target", args.target,
                   "build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-ldflags=-s -w", "-o", str(helper), "."]
        subprocess.run(command, cwd=REPO, check=True)
        helper_data = regular_bytes(helper); pe_machine(helper_data, args.target)
        build_receipt = json.loads(regular_bytes(build_root / ("build-" + args.target + ".json")))
        if build_receipt.get("artifact", {}).get("sha256") != digest(helper_data):
            raise ValueError("The helper does not match the checksum-verifying build receipt")
        runtime_check = "not run: build host is not Windows"
        if sys.platform == "win32":
            environment = dict(os.environ)
            environment.pop("AIGOODBRO_PROXY_CONNECTION_FILE", None)
            environment.pop("AIGOODBRO_PROXY_KEY", None)
            version = subprocess.check_output([str(helper), "--version"], env=environment, timeout=10, text=True, encoding="utf-8", errors="strict")
            if version.strip() != "AiGoodBro Local Proxy 1026v1; CLIProxyAPI v8.0.38 + metadata patch 9e79552":
                raise ValueError("The native Windows helper version is not the reviewed component")
            runtime_check = "native --version passed"
        files = {"aigoodbro-local-proxy.exe": helper_data, "models.json": (json.dumps(models, indent=2) + "\n").encode("utf-8")}
        for name in ("SOURCE.json", "LICENSE.CLIProxyAPI", "LICENSE.Hazmat", "THIRD-PARTY-NOTICES.txt"):
            files[name] = regular_bytes(SHARED / name)
        for path in sorted((SHARED / "upstream-patches").rglob("*")):
            if path.is_file():
                files[path.relative_to(SHARED).as_posix()] = regular_bytes(path)
        if regular_bytes(MODEL_SOURCE) != source_data:
            raise ValueError("The Mac model declaration changed during the build")
        receipt = {"schemaVersion": 1, "target": args.target, "runtimeCheck": runtime_check,
                   "modelSource": MODEL_SOURCE.relative_to(REPO).as_posix(), "modelSourceSHA256": digest(source_data),
                   "modelDeclarationSHA256": declaration_digest, "models": models, "build": build_receipt,
                   "files": {name: {"size": len(data), "sha256": digest(data)} for name, data in sorted(files.items())}}
        for name in files:
            destination = resource / name
            for parent in [destination.parent, resource]:
                if parent.is_symlink() or (parent.exists() and (not parent.is_dir() or getattr(parent.stat(), "st_file_attributes", 0) & 0x400)):
                    raise ValueError("A generated resource directory is unsafe")
            if destination.is_symlink() or (destination.exists() and not destination.is_file()):
                raise ValueError("A generated resource target is unsafe")
        # All inputs and the built artifact have been checked before target writes.
        changed = []
        for name, data in sorted(files.items()):
            destination = resource / name
            if destination.is_symlink():
                raise ValueError("A generated target is a symlink")
            if atomic_write(destination, data):
                changed.append(name)
        for name, data in files.items():
            if regular_bytes(resource / name) != data:
                raise ValueError("Generated resource readback mismatch")
        atomic_write(resource / "resource-receipt.json", (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode("utf-8"))
        print(json.dumps({"models": models, "changedFiles": changed, "helperSHA256": digest(helper_data), "runtimeCheck": runtime_check}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Windows LocalProxy resource preparation rejected: " + str(error), file=sys.stderr)
        sys.exit(1)
