#!/usr/bin/env python3
"""Build/test the provider helper with an isolated, checksum-pinned SDK backport."""
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
MANIFEST_SHA256 = "145e5e913a3ccd3400c529d169d110666916299746e2587ca2123f77cea27876"
APPROVED = {
    "internal/runtime/executor/claude_executor_execute.go": "c2dfec28d57221be9e042d33e2e1e0da58b16542",
    "internal/translator/claude/openai/chat-completions/claude_openai_response.go": "c2dfec28d57221be9e042d33e2e1e0da58b16542",
    "internal/translator/claude/openai/responses/claude_openai-responses_response.go": "d495e24cbc3965a28afd1ebdd4160eb2b7febb0e",
}


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
    manifest_path = source / MANIFEST
    if manifest_path.parent.is_symlink():
        raise ValueError("Upstream patch directory must not be a symlink")
    data = regular_bytes(manifest_path)
    # Pin the manifest itself, so changing both a patch and its listed digest
    # cannot silently introduce an unreviewed SDK change.
    if sha256(data) != MANIFEST_SHA256:
        raise ValueError("Upstream patch manifest digest mismatch")
    manifest = json.loads(data)
    if (manifest.get("schemaVersion") != 1 or manifest.get("upstreamModule") != MODULE
            or manifest.get("upstreamVersion") != VERSION or manifest.get("upstreamCommit") != COMMIT
            or manifest.get("moduleSum") != "h1:m+a2kr/wB1Jp/XZttcNBhCm50edVwGoaphdf7q4u88U="
            or manifest.get("moduleGoModSum") != "h1:j1Mtcj0TrC66O1JwbSBB03lY3uYPx4J7yHNvU6nDBCo="
            or manifest.get("license") != "MIT"):
        raise ValueError("Upstream patch provenance does not match the reviewed source")
    patches = manifest.get("patches")
    if not isinstance(patches, list) or len(patches) != len(APPROVED):
        raise ValueError("Unexpected upstream patch set")
    seen = set()
    for patch in patches:
        target = str(relative_path(patch.get("target", "")))
        if target in seen or APPROVED.get(target) != patch.get("upstreamCommit"):
            raise ValueError("Unreviewed upstream patch target or commit")
        seen.add(target)
        path = source / relative_path(patch.get("file", ""))
        if path.parent != source / "upstream-patches" or path.parent.is_symlink():
            raise ValueError("Unexpected upstream patch location")
        for field in ("originalSHA256", "patchedSHA256", "patchSHA256"):
            if not re.fullmatch(r"[0-9a-f]{64}", patch.get(field, "")):
                raise ValueError("Invalid upstream patch digest")
        if sha256(regular_bytes(path)) != patch["patchSHA256"]:
            raise ValueError("Upstream patch digest mismatch")
    if seen != set(APPROVED):
        raise ValueError("Incomplete upstream patch set")
    return manifest


def apply_patch(original, patch_bytes, target):
    """Apply every pinned hunk with exact lines, counts and offsets."""
    source_lines = original.decode("utf-8").splitlines(keepends=True)
    lines = patch_bytes.decode("utf-8").splitlines(keepends=True)
    if lines[:2] != ["--- a/" + target + "\n", "+++ b/" + target + "\n"]:
        raise ValueError("Unexpected upstream patch headers")
    out, position, index, hunks = [], 0, 2, 0
    while index < len(lines):
        match = re.fullmatch(r"@@ -(\d+),(\d+) \+(\d+),(\d+) @@[^\n]*\n", lines[index])
        if not match:
            raise ValueError("Unexpected upstream patch hunk")
        old_start, old_count, new_start, new_count = map(int, match.groups())
        index += 1
        if old_start - 1 < position or new_start - 1 != len(out) + old_start - 1 - position:
            raise ValueError("Unexpected upstream patch offset")
        out.extend(source_lines[position:old_start - 1])
        old, new = [], []
        while index < len(lines) and not lines[index].startswith("@@ "):
            line = lines[index]
            index += 1
            if not line or line[0] not in " +-":
                raise ValueError("Unsupported upstream patch syntax")
            if line[0] in " -":
                old.append(line[1:])
            if line[0] in " +":
                new.append(line[1:])
        if (len(old) != old_count or len(new) != new_count
                or source_lines[old_start - 1:old_start - 1 + old_count] != old):
            raise ValueError("Upstream patch does not match the pinned source exactly")
        position = old_start - 1 + old_count
        out.extend(new)
        hunks += 1
    if not hunks:
        raise ValueError("Upstream patch has no hunks")
    return "".join(out + source_lines[position:]).encode()


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


def has_source_override(flags):
    return any(flag.startswith("-") and flag.lstrip("-").split("=", 1)[0] in {"overlay", "modfile", "C"}
               for flag in flags)


def resolve_output_flags(command, flags, cwd):
    """Keep Go's output outside the disposable adapter, or fail clearly."""
    resolved = list(flags)
    before_args = resolved.index("-args") if "-args" in resolved else len(resolved)
    output = False
    index = 0
    while index < before_args:
        flag = resolved[index]
        if flag == "-o":
            if index + 1 >= before_args or not resolved[index + 1]:
                raise ValueError("The output flag requires a path")
            resolved[index + 1] = str((cwd / resolved[index + 1]).resolve())
            output = True
            index += 1
        elif flag.startswith("-o="):
            if not flag[3:]:
                raise ValueError("The output flag requires a path")
            resolved[index] = "-o=" + str((cwd / flag[3:]).resolve())
            output = True
        index += 1
    compiled_test = any(flag in {"-c", "--c", "-c=true", "--c=true", "-c=1", "--c=1"}
                        for flag in resolved[:before_args])
    if not output and (command == "build" or (command == "test" and compiled_test)):
        raise ValueError("Build and test -c require an explicit -o path")
    return resolved


def prepare_source(directory, environment, source=SOURCE):
    manifest = load_manifest(source)
    if has_source_override(shlex.split(environment.get("GOFLAGS", ""))):
        raise ValueError("GOFLAGS contains an unreviewed source override")
    module_data = regular_bytes(source / "go.mod")
    if re.search(rb"(?m)^[ \t]*replace\b", module_data):
        raise ValueError("Provider module contains an unreviewed replacement")
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
    if directory.is_symlink():
        raise ValueError("Upstream source directory must not be a symlink")
    directory.mkdir(parents=True, exist_ok=True)
    # Go refuses overlays beneath GOMODCACHE. Verify the original module, then
    # copy it into this disposable build directory; shared cache bytes stay intact.
    verify_module_tree(module, manifest["moduleSum"])
    replacement = directory.resolve() / "cliproxyapi-v8.0.38"
    shutil.copytree(module, replacement)
    verify_module_tree(replacement, manifest["moduleSum"])
    # Validate every patch and target before writing any changed copied source.
    patched_sources = []
    for patch in manifest["patches"]:
        patched_path = replacement / relative_path(patch["target"])
        original = regular_bytes(patched_path)
        if sha256(original) != patch["originalSHA256"]:
            raise ValueError("Original upstream source digest mismatch")
        patched = apply_patch(original, regular_bytes(source / patch["file"]), patch["target"])
        if sha256(patched) != patch["patchedSHA256"]:
            raise ValueError("Patched upstream source digest mismatch")
        patched_sources.append((patched_path, patched))
    for patched_path, patched in patched_sources:
        patched_path.chmod(0o644)
        patched_path.write_bytes(patched)
    build_source = directory.resolve() / "adapter"
    build_source.mkdir()
    for path in sorted(source.glob("*.go")):
        shutil.copyfile(path, build_source / path.name)
    for name in ("go.mod", "go.sum"):
        shutil.copyfile(source / name, build_source / name)
    modfile = build_source / "go.mod"
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
    if has_source_override(flags):
        parser.error("The reviewed upstream source cannot be overridden")
    flags = resolve_output_flags(args.command, flags, Path.cwd())
    environment = dict(os.environ, GOWORK="off")
    root = args.build_root or Path(environment.get("AIGOODBRO_PROVIDER_BUILD_ROOT", SOURCE.parents[1] / "build/provider-upstream"))
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".claude-truncation-1027v1-", dir=root) as temporary:
        build_source, _, _ = prepare_source(Path(temporary), environment)
        return subprocess.call(["go", args.command, *flags], cwd=build_source, env=environment)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Provider upstream patch rejected: " + str(error), file=sys.stderr)
        sys.exit(1)

