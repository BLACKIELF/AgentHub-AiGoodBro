#!/usr/bin/env python3
"""Build/test LocalProxy against verified upstream modules without modifying their cache."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import shlex
import subprocess
import sys
import tempfile

SOURCE = Path(__file__).resolve().parent
MANIFEST = "upstream-patches/manifest.json"
MODULE = "github.com/router-for-me/CLIProxyAPI/v8"
VERSION = "v8.0.58"
COMMIT = "e5e6ad1e1b91fc20ab9964e6fb22c0c269b9d882"
MANIFEST_SHA256 = "a596dbbe1a21793d2cea602024481c49e2a0eabf7aa832f6a3515c3133743821"


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
    path = source / MANIFEST
    if path.parent.is_symlink():
        raise ValueError("Upstream manifest directory must not be a symlink")
    data = regular_bytes(path)
    if sha256(data) != MANIFEST_SHA256:
        raise ValueError("Upstream manifest digest mismatch")
    manifest = json.loads(data)
    if (manifest.get("schemaVersion") != 1 or manifest.get("upstreamModule") != MODULE
            or manifest.get("upstreamVersion") != VERSION or manifest.get("upstreamCommit") != COMMIT
            or manifest.get("patches") != []):
        raise ValueError("Upstream provenance does not match the reviewed source")
    return manifest


def has_source_override(flags):
    return any(flag.split("=", 1)[0].lstrip("-") in {"overlay", "modfile", "C"} for flag in flags)


def check_dependency_replacement(module, pin):
    replacement = module.get("Replace", {})
    if (module.get("Path") != pin["module"] or module.get("Version") != pin["version"]
            or replacement.get("Path") != pin["replacementModule"]
            or replacement.get("Version") != pin["replacementVersion"]
            or replacement.get("Sum") != pin["moduleSum"]
            or replacement.get("GoModSum") != pin["moduleGoModSum"]
            or not isinstance(replacement.get("Dir"), str) or not replacement["Dir"]
            or replacement.get("Replace")):
        raise ValueError("Dependency replacement does not match upstream's reviewed pin")
    return Path(replacement["Dir"])


def write_generated(path, data):
    if path.exists() or path.is_symlink():
        if regular_bytes(path) != data:
            raise ValueError("Generated upstream source already differs")
        return
    with path.open("xb") as handle:
        handle.write(data)


def verify_module_tree(module, expected, module_name=MODULE, version=VERSION):
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
        name = module_name + "@" + version + "/" + path.relative_to(module).as_posix()
        aggregate.update((sha256(path.read_bytes()) + "  " + name + "\n").encode())
    if "h1:" + base64.b64encode(aggregate.digest()).decode() != expected:
        raise ValueError("Pinned upstream module tree checksum mismatch")


def prepare_source(directory, environment, source=SOURCE):
    manifest = load_manifest(source)
    if has_source_override(shlex.split(environment.get("GOFLAGS", ""))):
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
    verify_module_tree(module, manifest["moduleSum"])
    for fix in manifest["includedUpstreamFixes"]:
        if sha256(regular_bytes(module / relative_path(fix["target"]))) != fix["targetSHA256"]:
            raise ValueError("Included upstream fix source digest mismatch")
    module_config = json.loads(subprocess.check_output(
        ["go", "mod", "edit", "-json"], cwd=source, env=environment, text=True))
    expected_replacements = [
        {"Old": {"Path": pin["module"], "Version": pin["version"]},
         "New": {"Path": pin["replacementModule"], "Version": pin["replacementVersion"]}}
        for pin in manifest["dependencyReplacements"]]
    if module_config.get("Replace", []) != expected_replacements:
        raise ValueError("LocalProxy module contains an unreviewed replacement")
    for pin in manifest["dependencyReplacements"]:
        for attempt in range(2):
            replacement = json.loads(subprocess.check_output(
                ["go", "list", "-mod=readonly", "-m", "-json", pin["module"]],
                cwd=source, env=environment, text=True))
            if replacement.get("Replace", {}).get("Dir"):
                break
            if attempt:
                raise ValueError("Pinned dependency source is unavailable after download")
            subprocess.run(["go", "mod", "download", pin["replacementModule"] + "@" + pin["replacementVersion"]],
                           cwd=source, env=environment, check=True)
        replacement_dir = check_dependency_replacement(replacement, pin)
        verify_module_tree(replacement_dir, pin["moduleSum"], pin["replacementModule"], pin["replacementVersion"])
    if directory.is_symlink():
        raise ValueError("Build source directory must not be a symlink")
    directory.mkdir(parents=True, exist_ok=True)
    build_source = directory.resolve() / "adapter"
    build_source.mkdir()
    for path in sorted(source.glob("*.go")):
        shutil.copyfile(path, build_source / path.name)
    for name in ("go.mod", "go.sum"):
        shutil.copyfile(source / name, build_source / name)
    write_generated(directory / "receipt.json", (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode())
    return build_source, manifest, None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("command", choices=["build", "test", "vet", "list"])
    args, flags = parser.parse_known_args()
    if has_source_override(flags):
        parser.error("The reviewed upstream source cannot be overridden")
    flags = [str((Path.cwd() / flag).resolve()) if index > 0 and flags[index - 1] == "-o" else flag
             for index, flag in enumerate(flags)]
    environment = dict(os.environ, GOWORK="off")
    root = args.build_root or Path(environment.get("AIGOODBRO_PROXY_BUILD_ROOT", SOURCE.parents[1] / "build/proxy-upstream"))
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".verified-1107v1-", dir=root) as temporary:
        build_source, _, _ = prepare_source(Path(temporary), environment)
        return subprocess.call(["go", args.command, *flags], cwd=build_source, env=environment)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("LocalProxy upstream verification rejected: " + str(error), file=sys.stderr)
        sys.exit(1)

