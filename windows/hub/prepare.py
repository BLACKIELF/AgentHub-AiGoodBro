#!/usr/bin/env python3
"""Build or verify the existing companion Hub and bind its Windows resources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "Companion/Hub"
RESOURCE = REPO / "windows/apps/codexu-tauri/src-tauri/resources/companion-hub"
NATIVE_TESTS = {
    "TestNativeWindowsUncertainResolutionRequiresEmptyOwnedJob",
    "TestNativeWindowsDesktopBindingHoldsInputs",
    "TestNativeWindowsDesktopSourceAllowsReadOnlyACL",
    "TestNativeWindowsOwnedJobTreeCancellation",
    "TestNativeWindowsJobCloseKillsDescendants",
    "TestNativeWindowsHubApprovalAndCancel",
    "TestNativeWindowsPrivateStoreAndLocks",
    "TestNativeWindowsRejectsBroadACLAndHardlink",
    "TestNativeWindowsReadyAndEnvironment",
    "TestNativeWindowsRejectsReparseAncestors",
    "TestOwnedReadyEndpointRequiresAuthenticatedReceipt",
}


def require(condition, code):
    if not condition:
        raise ValueError(code)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(path):
    path = path.absolute()
    for part in (path, *path.parents):
        require(not part.is_symlink(), "hub_path_symlink")
        if part.exists():
            require(not getattr(part.stat(), "st_file_attributes", 0) & 0x400, "hub_path_reparse")
    return path


def regular(path):
    safe_path(path)
    require(path.is_file(), "hub_file_missing")
    return path.read_bytes()


def source_files(root=SOURCE):
    manifest = regular(root / "SOURCE.json")
    source = json.loads(manifest)
    files = {}
    for item in source["sourceFiles"]:
        relative = item["path"]
        require(isinstance(relative, str) and relative and "\\" not in relative
                and not Path(relative).is_absolute() and ".." not in Path(relative).parts,
                "hub_source_path_invalid")
        require(relative not in files, "hub_source_duplicate")
        data = regular(root / relative)
        require(sha(data) == item["sha256"], "hub_source_changed")
        files[relative] = data
    required = {p.relative_to(root).as_posix() for p in root.rglob("*.go")}
    required.update({"go.mod", "go.sum", "LICENSE", "LICENSE.x-sys", "web/index.html"})
    require(required <= files.keys(), "hub_source_inventory_incomplete")
    files["SOURCE.json"] = manifest
    return files


def atomic_write(path, data):
    safe_path(path)
    if path.exists() and regular(path) == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".hub-", dir=path.parent, delete=False) as f:
        temporary = Path(f.name)
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def validate_pe(data):
    require(len(data) > 256 and data[:2] == b"MZ", "hub_pe_invalid")
    offset = struct.unpack_from("<I", data, 0x3c)[0]
    require(offset + 6 <= len(data) and data[offset:offset+4] == b"PE\0\0", "hub_pe_invalid")
    require(struct.unpack_from("<H", data, offset+4)[0] == 0x8664, "hub_pe_architecture")


def native_result(output):
    passed, started, package_pass = set(), set(), False
    for line in output.decode("utf-8").splitlines():
        event = json.loads(line)
        require(event.get("Action") != "fail", "hub_native_test_failed")
        if event.get("Package") != "agent-remote-control":
            continue
        name, action = event.get("Test"), event.get("Action")
        if name in NATIVE_TESTS:
            require(action != "skip", "hub_native_tests_not_executed")
            if action == "run":
                require(name not in started, "hub_native_test_duplicate")
                started.add(name)
            elif action == "pass":
                require(name in started, "hub_native_tests_not_executed")
                passed.add(name)
        elif not name and action == "pass":
            package_pass = True
    require(NATIVE_TESTS <= passed and package_pass, "hub_native_tests_not_executed")
    return sorted(NATIVE_TESTS)


def verify_stage(stage, inputs):
    paths = list(stage.rglob("*"))
    for path in paths:
        safe_path(path)
        require(path.is_file() or path.is_dir(), "hub_stage_object_invalid")
    actual = {path.relative_to(stage).as_posix(): regular(path) for path in paths if path.is_file()}
    require(actual == inputs, "hub_stage_changed")


def prepare(args):
    require(not (args.run_native_tests and args.verify_only), "hub_conflicting_verification_modes")
    build = safe_path(args.build_root)
    resources = safe_path(args.resource_dir)
    try:
        relative = resources.relative_to(REPO)
    except ValueError:
        pass
    else:
        require(subprocess.run(["git", "check-ignore", "-q", "--", str(relative / "aigoodbro-hub.exe")], cwd=REPO).returncode == 0,
                "hub_output_not_ignored")
    inputs = source_files()
    inventory = {name: sha(data) for name, data in sorted(inputs.items())}
    receipt_path = build / "WINDOWS-RESOURCES.json"
    if args.verify_only:
        receipt = json.loads(regular(receipt_path))
        require(receipt.get("sourceFiles") == inventory, "hub_receipt_source_changed")
        require(receipt.get("target") == "windows-amd64", "hub_receipt_target")
        if args.require_native:
            require(receipt.get("nativeTests") == sorted(NATIVE_TESTS), "hub_native_receipt_missing")
            native_log = regular(build / "native-tests.jsonl")
            require(sha(native_log) == receipt.get("nativeLogSHA256"), "hub_native_log_changed")
            native_result(native_log)
        binary = regular(build / "aigoodbro-hub.exe")
    else:
        require(not args.require_native, "hub_require_native_needs_verification")
        build.mkdir(parents=True, exist_ok=True)
        stage = build / "source"
        stage.mkdir(exist_ok=True)
        # Never compile stale unmanifested Go files from a preceding retry.
        existing = {p.relative_to(stage).as_posix() for p in stage.rglob("*") if p.is_file()}
        require(existing <= inputs.keys(), "hub_stage_stale_files")
        for name, data in inputs.items():
            atomic_write(stage / name, data)
        verify_stage(stage, inputs)
        env = dict(os.environ, GOOS="windows", GOARCH="amd64", GOAMD64="v1", CGO_ENABLED="0", GOWORK="off",
                   GOFLAGS="", GOENV="off", GOEXPERIMENT="", GO111MODULE="on", GOTOOLCHAIN="local")
        native_tests, native_sha = [], None
        if args.run_native_tests:
            require(sys.platform == "win32", "hub_native_windows_required")
            proc = subprocess.run(["go", "test", "-mod=readonly", "-json", "-count=1", "-run", "^(TestNativeWindows|TestOwnedReadyEndpoint|TestDesktopWorkflow)", "./..."], cwd=stage, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
            atomic_write(build / "native-tests.jsonl", proc.stdout)
            atomic_write(build / "native-tests.stderr.log", proc.stderr)
            require(proc.returncode == 0, "hub_native_test_failed")
            native_tests = native_result(proc.stdout)
            native_sha = sha(proc.stdout)
        verify_stage(stage, inputs)
        binary_path = build / "aigoodbro-hub.exe"
        candidate = build / "aigoodbro-hub.building.exe"
        subprocess.run(["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-ldflags=-s -w", "-o", str(candidate), "."],
                       cwd=stage, env=env, check=True, timeout=180)
        binary = regular(candidate)
        validate_pe(binary)
        verify_stage(stage, inputs)
        require(source_files() == inputs, "hub_source_changed_during_build")
        atomic_write(binary_path, binary)
        candidate.unlink()
        if sys.platform == "win32":
            version = subprocess.check_output([str(binary_path), "--version"], timeout=10, text=True).strip()
            require(version == "0910v2-next", "hub_version_mismatch")
        receipt = {"schemaVersion": 1, "target": "windows-amd64", "sourceFiles": inventory,
                   "nativeTests": native_tests, "nativeLogSHA256": native_sha,
                   "syntheticOnly": True, "realAccountsRead": False}
    validate_pe(binary)
    files = {"aigoodbro-hub.exe": binary, "SOURCE.json": inputs["SOURCE.json"],
             "LICENSE": inputs["LICENSE"], "LICENSE.x-sys": inputs["LICENSE.x-sys"]}
    file_receipt = {name: {"sha256": sha(data), "size": len(data)} for name, data in sorted(files.items())}
    if args.verify_only:
        require(receipt.get("files") == file_receipt, "hub_resource_changed")
    else:
        receipt["files"] = file_receipt
        atomic_write(receipt_path, (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode())
    require(source_files() == inputs, "hub_source_changed_before_publish")
    if resources.exists():
        present = {p.relative_to(resources).as_posix() for p in resources.rglob("*") if p.is_file()}
        require(present <= (files.keys() | {"WINDOWS-RESOURCES.json"}), "hub_resource_unexpected_file")
    for name, data in files.items():
        atomic_write(resources / name, data)
    atomic_write(resources / "WINDOWS-RESOURCES.json", regular(receipt_path))
    verify_stage(resources, {**files, "WINDOWS-RESOURCES.json": regular(receipt_path)})
    print(json.dumps({"helperSHA256": sha(binary), "nativeTestsPassed": len(receipt["nativeTests"]), "sourceFiles": len(inventory)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--resource-dir", type=Path, default=RESOURCE)
    parser.add_argument("--run-native-tests", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--require-native", action="store_true")
    prepare(parser.parse_args())
