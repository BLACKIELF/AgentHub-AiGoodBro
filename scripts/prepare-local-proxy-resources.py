#!/usr/bin/env python3
"""Build the opt-in local proxy companion; never starts it or reads accounts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Companion/LocalProxy"
EXECUTABLE = "aigoodbro-local-proxy"
UPSTREAM_MODULE = "github.com/router-for-me/CLIProxyAPI/v8"
UPSTREAM_VERSION = "v8.0.20"
UPSTREAM_COMMIT = "0f96f568e4dbf6f84ad7399a74b78344c5eac7e6"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def json_stream(value):
    decoder = json.JSONDecoder()
    value = value.lstrip()
    while value:
        item, end = decoder.raw_decode(value)
        yield item
        value = value[end:].lstrip()


def check_regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected regular packaged file: {path.name}")


def architecture(path, expected):
    actual = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split()
    if actual != [expected]:
        raise ValueError("Local proxy architecture does not match app target")


def verify(resources, arch):
    directory = resources / "LocalProxy"
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Local proxy resources missing or symlinked")
    manifest_path = directory / "manifest.json"
    check_regular(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("schemaVersion") != 1 or manifest.get("architecture") != arch
            or manifest.get("upstreamModule") != UPSTREAM_MODULE
            or manifest.get("upstreamVersion") != UPSTREAM_VERSION
            or manifest.get("upstreamCommit") != UPSTREAM_COMMIT):
        raise ValueError("Local proxy manifest does not match reviewed source")
    required = {EXECUTABLE, "LICENSE.CLIProxyAPI", "LICENSE.Hazmat", "THIRD_PARTY_NOTICES.txt", "SOURCE.json"}
    if set(manifest.get("files", {})) != required:
        raise ValueError("Local proxy manifest file set is incomplete")
    for name in required:
        path = directory / name
        check_regular(path)
        if digest(path) != manifest["files"][name]:
            raise ValueError(f"Local proxy resource integrity mismatch: {name}")
    executable = directory / EXECUTABLE
    if not os.access(executable, os.X_OK):
        raise ValueError("Local proxy helper is not executable")
    architecture(executable, arch)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(executable)], check=True)
    # A resource-only verification never launches an application or helper.
    print("Verified local proxy architecture, signature, pinned source and resources.")


def dependency_notices(environment):
    listing = subprocess.check_output(
        ["go", "list", "-mod=readonly", "-deps", "-json", "."],
        cwd=SOURCE, env=environment, text=True)
    modules = {}
    for package in json_stream(listing):
        module = package.get("Module")
        if not module or module.get("Main"):
            continue
        if module.get("Replace"):
            raise ValueError("Local proxy release build cannot use replaced Go modules")
        modules[module["Path"]] = module
    upstream = modules.get(UPSTREAM_MODULE)
    if not upstream or upstream.get("Version") != UPSTREAM_VERSION:
        raise ValueError("Local proxy must compile against the pinned upstream version")
    notices = ["AiGoodBro local proxy — compiled third-party module notices\n"]
    for name, module in sorted(modules.items()):
        directory = Path(module["Dir"])
        files = sorted(p for p in directory.iterdir()
                       if p.is_file() and not p.is_symlink()
                       and p.name.upper().split(".")[0] in {"LICENSE", "LICENCE", "COPYING", "NOTICE"})
        if not files:
            raise ValueError(f"Missing dependency license for {name}")
        notices.append(f"\n{name} {module.get('Version', '')}\n")
        for path in files:
            notices.append(f"\n--- {path.name} ---\n{path.read_text(errors='replace')}\n")
    return "".join(notices), len(modules)


def build(resources, arch, identity):
    for name in ("go.mod", "go.sum", "LICENSE.CLIProxyAPI", "LICENSE.Hazmat", "SOURCE.json"):
        check_regular(SOURCE / name)
    provenance = json.loads((SOURCE / "SOURCE.json").read_text())
    if (provenance.get("upstreamCommit") != UPSTREAM_COMMIT
            or provenance.get("upstreamVersion") != UPSTREAM_VERSION):
        raise ValueError("Local proxy source provenance does not match reviewed version")
    resources.mkdir(parents=True, exist_ok=True)
    destination = resources / "LocalProxy"
    if destination.exists() or destination.is_symlink():
        raise ValueError("Build resources already contain LocalProxy; use a clean candidate build")
    environment = dict(os.environ, GOOS="darwin", GOARCH="arm64" if arch == "arm64" else "amd64", CGO_ENABLED="0")
    notices, dependency_count = dependency_notices(environment)
    with tempfile.TemporaryDirectory(prefix=".local-proxy-", dir=resources) as staging:
        directory = Path(staging)
        executable = directory / EXECUTABLE
        subprocess.run(["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false",
                        "-ldflags=-s -w", "-o", str(executable), "."],
                       cwd=SOURCE, env=environment, check=True)
        architecture(executable, arch)
        signing = ["/usr/bin/codesign", "--force", "--sign", identity]
        if identity != "-":
            signing += ["--options", "runtime", "--timestamp"]
        subprocess.run(signing + [str(executable)], check=True)
        for name in ("LICENSE.CLIProxyAPI", "LICENSE.Hazmat", "SOURCE.json"):
            shutil.copyfile(SOURCE / name, directory / name)
        (directory / "THIRD_PARTY_NOTICES.txt").write_text(notices)
        manifest = {
            "schemaVersion": 1, "architecture": arch, "executable": EXECUTABLE,
            "upstreamModule": UPSTREAM_MODULE, "upstreamVersion": UPSTREAM_VERSION,
            "upstreamCommit": UPSTREAM_COMMIT, "dependencyNoticeCount": dependency_count,
            "files": {name: digest(directory / name) for name in
                      (EXECUTABLE, "LICENSE.CLIProxyAPI", "LICENSE.Hazmat", "SOURCE.json", "THIRD_PARTY_NOTICES.txt")},
        }
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.copytree(directory, destination)
    verify(resources, arch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--arch", choices=["arm64", "x86_64"], required=True)
    parser.add_argument("--sign-identity", default="-")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    resources = args.resources.resolve()
    if args.verify:
        verify(resources, args.arch)
    else:
        build(resources, args.arch, args.sign_identity)


if __name__ == "__main__":
    main()
