#!/usr/bin/env python3
"""Build/test LocalProxy with an isolated, checksum-pinned single upstream patch."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import shlex
import subprocess
import sys
import tempfile

SOURCE = Path(__file__).resolve().parent
MANIFEST = "upstream-patches/manifest.json"
MODULE = "github.com/router-for-me/CLIProxyAPI/v8"
VERSION = "v8.0.38"
COMMIT = "0db19025571684b198a2ef508f99b41c717337e8"
TARGET = "internal/runtime/executor/codex_executor_terminal.go"
PATCH_COMMIT = "9e79552fb79461b3ee475c0b30ef33408392db5a"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def regular_bytes(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected a regular upstream patch input")
    return path.read_bytes()


def relative_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or str(path) != value:
        raise ValueError("Invalid upstream patch path")
    return path


def load_manifest(source=SOURCE):
    manifest = json.loads(regular_bytes(source / MANIFEST))
    if (manifest.get("schemaVersion") != 1 or manifest.get("upstreamModule") != MODULE
            or manifest.get("upstreamVersion") != VERSION or manifest.get("upstreamCommit") != COMMIT
            or len(manifest.get("patches", [])) != 1):
        raise ValueError("Upstream patch provenance does not match the reviewed source")
    patch = manifest["patches"][0]
    if patch.get("target") != TARGET or patch.get("upstreamCommit") != PATCH_COMMIT:
        raise ValueError("Unreviewed upstream patch target or commit")
    path = source / relative_path(patch["file"])
    if path.parent.is_symlink() or sha256(regular_bytes(path)) != patch["patchSHA256"]:
        raise ValueError("Upstream patch digest mismatch")
    for field in ("originalSHA256", "patchedSHA256", "patchSHA256"):
        if not re.fullmatch(r"[0-9a-f]{64}", patch.get(field, "")):
            raise ValueError("Invalid upstream patch digest")
    return manifest


def apply_patch(original, patch_bytes, target):
    """Apply the pinned single hunk with exact lines and counts; never fuzzy-match."""
    source_lines = original.decode("utf-8").splitlines(keepends=True)
    lines = patch_bytes.decode("utf-8").splitlines(keepends=True)
    while lines and lines[-1] == "\n":
        lines.pop()
    if len(lines) < 4 or lines[:2] != ["--- a/" + target + "\n", "+++ b/" + target + "\n"]:
        raise ValueError("Unexpected upstream patch headers")
    match = re.fullmatch(r"@@ -(\d+),(\d+) \+(\d+),(\d+) @@[^\n]*\n", lines[2])
    if not match:
        raise ValueError("Expected exactly one bounded upstream patch hunk")
    old_start, old_count, new_start, new_count = map(int, match.groups())
    if old_start != new_start:
        raise ValueError("Unexpected upstream patch offset")
    old, new = [], []
    for line in lines[3:]:
        if not line or line[0] not in " +-":
            raise ValueError("Unsupported upstream patch syntax")
        if line[0] in " -":
            old.append(line[1:])
        if line[0] in " +":
            new.append(line[1:])
    if len(old) != old_count or len(new) != new_count or source_lines[old_start - 1:old_start - 1 + old_count] != old:
        raise ValueError("Upstream patch does not match the pinned source exactly")
    return "".join(source_lines[:old_start - 1] + new + source_lines[old_start - 1 + old_count:]).encode()


def write_generated(path, data):
    if path.exists() or path.is_symlink():
        if regular_bytes(path) != data:
            raise ValueError("Generated upstream source already differs")
        return
    with path.open("xb") as handle:
        handle.write(data)


def verify_module_tree(module, expected):
    # Go dirhash.Hash1: SHA256 of each content digest and its module zip name.
    # This verifies only this fixed module and works with a fully offline cache.
    aggregate = hashlib.sha256()
    files = []
    for path in module.rglob("*"):
        if path.is_symlink():
            raise ValueError("Pinned upstream source contains a symlink")
        if path.is_file():
            files.append(path)
    for path in sorted(files, key=lambda item: item.as_posix()):
        name = MODULE + "@" + VERSION + "/" + path.relative_to(module).as_posix()
        aggregate.update((sha256(path.read_bytes()) + "  " + name + "\n").encode())
    if "h1:" + base64.b64encode(aggregate.digest()).decode() != expected:
        raise ValueError("Pinned upstream module tree checksum mismatch")


def prepare_source(directory, environment, source=SOURCE):
    manifest = load_manifest(source)
    if any(flag == "-overlay" or flag.startswith("-overlay=") or flag == "-modfile" or flag.startswith("-modfile=")
           for flag in shlex.split(environment.get("GOFLAGS", ""))):
        raise ValueError("GOFLAGS contains an unreviewed source override")
    # Query the effective module, not a different manually downloaded copy.
    for attempt in range(2):
        upstream = json.loads(subprocess.check_output(
            ["go", "list", "-mod=readonly", "-m", "-json", MODULE],
            cwd=source, env=environment, text=True))
        if (upstream.get("Path") != MODULE or upstream.get("Version") != VERSION or upstream.get("Replace")
                or upstream.get("Sum") != manifest["moduleSum"]
                or upstream.get("GoModSum") != manifest["moduleGoModSum"]):
            raise ValueError("Effective upstream module does not match the pinned checksums")
        if isinstance(upstream.get("Dir"), str) and upstream["Dir"]:
            break
        if attempt:
            raise ValueError("Pinned upstream module source is unavailable after download")
        # A fresh Go cache can resolve metadata without extracting source files.
        # Download only the reviewed version, then recheck the effective module.
        subprocess.run(["go", "mod", "download", MODULE + "@" + VERSION],
                       cwd=source, env=environment, check=True)
    module = Path(upstream["Dir"])
    patch = manifest["patches"][0]
    original_path = module / relative_path(patch["target"])
    original = regular_bytes(original_path)
    if sha256(original) != patch["originalSHA256"]:
        raise ValueError("Original upstream source digest mismatch; cache was not changed")
    patched = apply_patch(original, regular_bytes(source / patch["file"]), patch["target"])
    if sha256(patched) != patch["patchedSHA256"]:
        raise ValueError("Patched upstream source digest mismatch")
    if directory.is_symlink():
        raise ValueError("Upstream source directory must not be a symlink")
    directory.mkdir(parents=True, exist_ok=True)
    # Go refuses overlays beneath GOMODCACHE. Verify the original module, then
    # copy it into this disposable build directory; shared cache bytes stay intact.
    verify_module_tree(module, manifest["moduleSum"])
    replacement = directory.resolve() / "cliproxyapi-v8.0.38"
    shutil.copytree(module, replacement)
    verify_module_tree(replacement, manifest["moduleSum"])
    patched_path = replacement / patch["target"]
    patched_path.chmod(0o644)
    patched_path.write_bytes(patched)
    build_source = directory.resolve() / "adapter"
    build_source.mkdir()
    for path in sorted(source.glob("*.go")):
        shutil.copyfile(path, build_source / path.name)
    for name in ("go.mod", "go.sum"):
        shutil.copyfile(source / name, build_source / name)
    modfile = build_source / "go.mod"
    module_data = regular_bytes(source / "go.mod")
    if re.search(rb"(?m)^replace\b", module_data):
        raise ValueError("LocalProxy module contains an unreviewed replacement")
    # The relative path is stable across machines/build directories and is
    # recorded verbatim in Go build metadata. No random/private path is embedded.
    modfile.write_bytes(module_data + ("\nreplace " + MODULE + " => ../cliproxyapi-v8.0.38\n").encode())
    write_generated(directory / "receipt.json", (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode())
    return build_source, manifest, replacement


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("command", choices=["build", "test", "vet", "list"])
    args, flags = parser.parse_known_args()
    if any(flag == "-overlay" or flag.startswith("-overlay=") or flag == "-modfile" or flag.startswith("-modfile=") for flag in flags):
        parser.error("The reviewed upstream source cannot be overridden")
    flags = [str((Path.cwd() / flag).resolve()) if index > 0 and flags[index - 1] == "-o" else flag
             for index, flag in enumerate(flags)]
    environment = dict(os.environ, GOWORK="off")
    root = args.build_root or Path(environment.get("AIGOODBRO_PROXY_BUILD_ROOT", SOURCE.parents[1] / "build/proxy-upstream"))
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".metadata-1026v1-", dir=root) as temporary:
        build_source, _, _ = prepare_source(Path(temporary), environment)
        return subprocess.call(["go", args.command, *flags], cwd=build_source, env=environment)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("LocalProxy upstream patch rejected: " + str(error), file=sys.stderr)
        sys.exit(1)

