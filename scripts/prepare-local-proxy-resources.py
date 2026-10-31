#!/usr/bin/env python3
"""Build the opt-in local proxy companion; never starts it or reads accounts."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from contextlib import ExitStack

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Companion/LocalProxy"
EXECUTABLE = "aigoodbro-local-proxy"
RESOURCE_DIRECTORY = "LocalProxy"
UPSTREAM_MODULE = "github.com/router-for-me/CLIProxyAPI/v8"
UPSTREAM_VERSION = "v8.0.38"
UPSTREAM_COMMIT = "0db19025571684b198a2ef508f99b41c717337e8"


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


def upstream_patch_support():
    provenance = json.loads((SOURCE / "SOURCE.json").read_text())
    patch_manifest = provenance.get("upstreamPatchManifest")
    if patch_manifest is None:
        if RESOURCE_DIRECTORY == "LocalProxy":
            raise ValueError("Local proxy is missing the reviewed upstream patch manifest")
        return None, None
    if patch_manifest != "upstream-patches/manifest.json" or RESOURCE_DIRECTORY != "LocalProxy":
        raise ValueError("Unreviewed proxy upstream patch configuration")
    spec = importlib.util.spec_from_file_location("local_proxy_upstream_patch", SOURCE / "go.py")
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)
    manifest = support.load_manifest(SOURCE)
    return support, manifest


def verify(resources, arch):
    directory = resources / RESOURCE_DIRECTORY
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
    patch_support, patches = upstream_patch_support()
    if patches is not None:
        patch_files = {"upstream-patches/manifest.json", *[row["file"] for row in patches["patches"]]}
        required.update(patch_files)
        if (manifest.get("upstreamPatchManifestSHA256") != digest(SOURCE / "upstream-patches/manifest.json")
                or manifest.get("upstreamPatches") != patches):
            raise ValueError("Local proxy manifest is missing the reviewed upstream patch provenance")
        for name in patch_files:
            if (directory / name).parent.is_symlink() or digest(directory / name) != digest(SOURCE / name):
                raise ValueError("Packaged upstream patch does not match the reviewed source")
        patch_support.load_manifest(directory)
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


def dependency_notices(environment, build_source=SOURCE, reviewed_replacement=None):
    listing = subprocess.check_output(
        ["go", "list", "-mod=readonly", "-deps", "-json", "."],
        cwd=build_source, env=environment, text=True)
    modules = {}
    for package in json_stream(listing):
        module = package.get("Module")
        if not module or module.get("Main"):
            continue
        if module.get("Replace"):
            replacement = module["Replace"]
            if (module["Path"] != UPSTREAM_MODULE or module.get("Version") != UPSTREAM_VERSION
                    or reviewed_replacement is None
                    or Path(replacement.get("Dir", "")).resolve() != reviewed_replacement.resolve()
                    or replacement.get("Version")):
                raise ValueError("Proxy build contains an unreviewed Go module replacement")
        modules[module["Path"]] = module
    upstream = modules.get(UPSTREAM_MODULE)
    if not upstream or upstream.get("Version") != UPSTREAM_VERSION:
        raise ValueError("Local proxy must compile against the pinned upstream version")
    notices = ["AiGoodBro local proxy — compiled third-party module notices\n"]
    for name, module in sorted(modules.items()):
        directory = Path(module.get("Replace", module)["Dir"])
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
    destination = resources / RESOURCE_DIRECTORY
    if destination.exists() or destination.is_symlink():
        raise ValueError("Build resources already contain LocalProxy; use a clean candidate build")
    environment = dict(os.environ, GOOS="darwin", GOARCH="arm64" if arch == "arm64" else "amd64", CGO_ENABLED="0", GOWORK="off")
    patch_support, patches = upstream_patch_support()
    with ExitStack() as cleanup:
        staging = cleanup.enter_context(tempfile.TemporaryDirectory(prefix=".local-proxy-", dir=resources))
        directory = Path(staging)
        build_source, replacement = SOURCE, None
        if patches is not None:
            generated = cleanup.enter_context(tempfile.TemporaryDirectory(prefix=".local-proxy-upstream-", dir=resources))
            build_source, generated_patches, replacement = patch_support.prepare_source(Path(generated), environment, SOURCE)
            if generated_patches != patches:
                raise ValueError("Proxy patch inputs changed during preparation")
        notices, dependency_count = dependency_notices(environment, build_source, replacement)
        executable = directory / EXECUTABLE
        subprocess.run(["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false",
                        "-ldflags=-s -w", "-o", str(executable), "."],
                       cwd=build_source, env=environment, check=True)
        architecture(executable, arch)
        signing = ["/usr/bin/codesign", "--force", "--sign", identity]
        if identity != "-":
            signing += ["--options", "runtime", "--timestamp"]
        subprocess.run(signing + [str(executable)], check=True)
        for name in ("LICENSE.CLIProxyAPI", "LICENSE.Hazmat", "SOURCE.json"):
            shutil.copyfile(SOURCE / name, directory / name)
        if patches is not None:
            for name in ["upstream-patches/manifest.json", *[row["file"] for row in patches["patches"]]]:
                target = directory / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(SOURCE / name, target)
        (directory / "THIRD_PARTY_NOTICES.txt").write_text(notices)
        manifest = {
            "schemaVersion": 1, "architecture": arch, "executable": EXECUTABLE,
            "upstreamModule": UPSTREAM_MODULE, "upstreamVersion": UPSTREAM_VERSION,
            "upstreamCommit": UPSTREAM_COMMIT, "dependencyNoticeCount": dependency_count,
            "files": {name: digest(directory / name) for name in
                      (EXECUTABLE, "LICENSE.CLIProxyAPI", "LICENSE.Hazmat", "SOURCE.json", "THIRD_PARTY_NOTICES.txt")},
        }
        if patches is not None:
            manifest["upstreamPatches"] = patches
            manifest["upstreamPatchManifestSHA256"] = digest(SOURCE / "upstream-patches/manifest.json")
            for name in ["upstream-patches/manifest.json", *[row["file"] for row in patches["patches"]]]:
                manifest["files"][name] = digest(directory / name)
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
