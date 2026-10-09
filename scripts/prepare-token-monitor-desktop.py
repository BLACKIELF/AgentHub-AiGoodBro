#!/usr/bin/env python3
"""Build an AiGoodBro Electron helper from pinned source and official runtime.

The official app and vendored source are read-only inputs. This script uses only
the Python standard library, Node for the strict staging transform, and macOS
codesign. It archives the original Widget extension outside active PlugIns,
because AiGoodBro cannot claim the original Team/App Group entitlement.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DESKTOP = ROOT / "Companion/TokenMonitorDesktop"
VENDOR = ROOT / "Companion/TokenMonitorEngine"
MANIFEST = DESKTOP / "SOURCE.json"
DEFAULT_OUTPUT = ROOT / ".local-artifacts/token-monitor-native-0926v1/desktop-companion/AiGoodBro Token Core.app"
DEFAULT_RECEIPT = DEFAULT_OUTPUT.parent / "package-receipt.json"
BLOCK_SIZE = 4 * 1024 * 1024


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(BLOCK_SIZE), b""):
            digest.update(block)
    return digest.hexdigest()


def widget_tree_digest(widget: Path) -> str:
    records = [
        [file.relative_to(widget).as_posix(), file.stat().st_size, digest_file(file)]
        for file in sorted(widget.rglob("*")) if file.is_file()
    ]
    require(len(records) >= 50, "Original Widget extension is incomplete")
    return sha256(json.dumps(records, separators=(",", ":")).encode())


def archived_widget_digest(archive: Path) -> str:
    records = []
    with zipfile.ZipFile(archive) as zipped:
        require(zipped.testzip() is None, "Archived Widget is corrupt")
        names = [name for name in zipped.namelist() if not name.endswith("/")]
        require(len(names) == len(set(names)), "Archived Widget has duplicate paths")
        for name in sorted(names):
            prefix = "TokenMonitorWidget.appex/"
            require(name.startswith(prefix), "Archived Widget has an unexpected path")
            content = zipped.read(name)
            records.append([name[len(prefix):], len(content), sha256(content)])
    require(len(records) >= 50, "Archived Widget is incomplete")
    return sha256(json.dumps(records, separators=(",", ":")).encode())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def run(*command: str) -> str:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"{command[0]} failed ({result.returncode}): {(result.stderr or result.stdout)[-3000:]}")
    return result.stdout


def select_manifest(manifest: dict, architecture: str) -> dict:
    require(architecture in ("arm64", "x86_64"), f"Unsupported desktop runtime architecture: {architecture}")
    if architecture == "arm64":
        require(manifest["runtime"]["architecture"] == architecture, "Arm64 runtime pin changed")
        return manifest
    override = manifest["architectures"][architecture]
    require(set(override["runtime"]) == {
        "architecture", "officialDMGURL", "officialDMGSHA256",
        "officialAsarHeaderSHA256", "officialUnpackedTreeSHA256", "officialNodeModulesMembers",
    }, "Intel runtime pin is incomplete")
    require(set(override["widget"]) == {
        "originalTreeSHA256", "originalConfigSHA256",
    }, "Intel Widget pin is incomplete")
    require(override["runtime"]["architecture"] == architecture, "Intel runtime architecture pin changed")
    return {
        **manifest,
        "runtime": {**manifest["runtime"], **override["runtime"]},
        "widget": {**manifest["widget"], **override["widget"]},
    }


MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}


def verify_architecture(app: Path, architecture: str) -> int:
    count = 0
    seen: set[str] = set()
    for path in app.rglob("*"):
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic not in MACHO_MAGICS:
            continue
        actual = run("lipo", "-archs", str(path)).split()
        require(actual == [architecture], f"Embedded Mach-O architecture mismatch: {path.relative_to(app)}")
        seen.add(path.relative_to(app).as_posix())
        count += 1
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    name = info["CFBundleName"]
    required = {
        f"Contents/MacOS/{info['CFBundleExecutable']}",
        "Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework",
        *(f"Contents/Frameworks/{name} Helper{suffix}.app/Contents/MacOS/{name} Helper{suffix}"
          for suffix in ("", " (GPU)", " (Plugin)", " (Renderer)")),
    }
    require(required.issubset(seen), "Desktop runtime executable closure is incomplete")
    require(any(path.endswith(".node") for path in seen), "Desktop runtime native module is missing")
    require(count >= 15, "Desktop runtime native closure is incomplete")
    return count


def entries(tree: dict, prefix: str = ""):
    for name, entry in tree["files"].items():
        relative = f"{prefix}/{name}" if prefix else name
        if "files" in entry:
            yield from entries(entry, relative)
        else:
            yield relative, entry


def header_entry(tree: dict, relative: str) -> dict:
    current = tree
    for part in relative.split("/"):
        current = current["files"][part]
    return current


def asar_header(path: Path) -> tuple[dict, int, str]:
    with path.open("rb") as stream:
        numbers = struct.unpack("<IIII", stream.read(16))
        require(numbers[0] == 4, "ASAR UInt32 header is invalid")
        length = numbers[3]
        padded = (length + 3) & ~3
        require(numbers[1] == 8 + padded and numbers[2] == 4 + padded, "ASAR header lengths are invalid")
        raw = stream.read(length)
        require(len(raw) == length, "ASAR JSON header is truncated")
        require(stream.read(padded - length) == b"\0" * (padded - length), "ASAR header padding is invalid")
    tree = json.loads(raw)
    require(isinstance(tree, dict) and isinstance(tree.get("files"), dict), "ASAR file tree is invalid")
    return tree, 16 + padded, sha256(raw)


def asar_content(path: Path, tree: dict, payload_start: int, relative: str) -> bytes:
    entry = header_entry(tree, relative)
    require("link" not in entry, f"ASAR symlink is unsupported: {relative}")
    if entry.get("unpacked"):
        content = path.with_name(path.name + ".unpacked").joinpath(*relative.split("/")).read_bytes()
    else:
        with path.open("rb") as stream:
            stream.seek(payload_start + int(entry["offset"]))
            content = stream.read(entry["size"])
    require(len(content) == entry["size"], f"ASAR member is truncated: {relative}")
    integrity = entry.get("integrity")
    if integrity:
        require(integrity.get("algorithm") == "SHA256", f"Unsupported ASAR integrity: {relative}")
        require(sha256(content) == integrity.get("hash"), f"ASAR member hash mismatch: {relative}")
        size = integrity.get("blockSize", BLOCK_SIZE)
        expected = [sha256(content[index:index + size]) for index in range(0, len(content), size)] or [sha256(b"")]
        require(expected == integrity.get("blocks"), f"ASAR block hash mismatch: {relative}")
    return content


def packed_entry(content: bytes, offset: int, *, unpacked: bool = False, executable: bool = False) -> dict:
    entry: dict = {"size": len(content)}
    if unpacked:
        entry["unpacked"] = True
    else:
        entry["offset"] = str(offset)
    if executable:
        entry["executable"] = True
    entry["integrity"] = {
        "algorithm": "SHA256",
        "hash": sha256(content),
        "blockSize": BLOCK_SIZE,
        "blocks": [sha256(content[index:index + BLOCK_SIZE]) for index in range(0, len(content), BLOCK_SIZE)] or [sha256(b"")],
    }
    return entry


def build_asar(destination: Path, members: dict[str, tuple[bytes, bool, bool]]) -> tuple[str, int]:
    tree: dict = {"files": {}}
    payload = bytearray()
    for relative in sorted(members):
        content, unpacked, executable = members[relative]
        components = relative.split("/")
        require(all(part not in ("", ".", "..") for part in components), f"Unsafe ASAR path: {relative}")
        current = tree
        for part in components[:-1]:
            current = current["files"].setdefault(part, {"files": {}})
            require("files" in current, f"ASAR path conflicts with file: {relative}")
        require(components[-1] not in current["files"], f"Duplicate ASAR path: {relative}")
        current["files"][components[-1]] = packed_entry(content, len(payload), unpacked=unpacked, executable=executable)
        if not unpacked:
            payload.extend(content)
    raw = json.dumps(tree, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    padded = (len(raw) + 3) & ~3
    with destination.open("wb") as stream:
        stream.write(struct.pack("<IIII", 4, 8 + padded, 4 + padded, len(raw)))
        stream.write(raw)
        stream.write(b"\0" * (padded - len(raw)))
        stream.write(payload)
    return sha256(raw), len(members)


def verify_asar(path: Path, expected_header: str | None = None) -> dict:
    tree, start, header_hash = asar_header(path)
    if expected_header:
        require(header_hash == expected_header, "ElectronAsarIntegrity header hash mismatch")
    counts = {"members": 0, "unpacked": 0, "packed": 0}
    seen: set[str] = set()
    for relative, entry in entries(tree):
        require(relative not in seen, f"Duplicate ASAR member: {relative}")
        seen.add(relative)
        asar_content(path, tree, start, relative)
        counts["members"] += 1
        key = "unpacked" if entry.get("unpacked") else "packed"
        counts[key] += 1
    counts["headerSHA256"] = header_hash
    return counts


def official_unpacked_tree_digest(path: Path, tree: dict) -> str:
    records = []
    for relative, entry in entries(tree):
        if entry.get("unpacked"):
            file = path.with_name(path.name + ".unpacked").joinpath(*relative.split("/"))
            content = file.read_bytes()
            records.append([relative, len(content), sha256(content)])
    require(len(records) >= 50, "Official native unpacked closure is incomplete")
    return sha256(json.dumps(records, separators=(",", ":")).encode())


def ensure_source_inventory(source: Path, inventory: dict) -> None:
    pinned = inventory["finalSource"]["files"]
    for top in ("src", "assets"):
        for file in source.joinpath(top).rglob("*"):
            if not file.is_file():
                continue
            relative = file.relative_to(source).as_posix()
            key = f"upstream/{relative}"
            require(key in pinned, f"Vendored desktop source is not inventoried: {key}")
            require(digest_file(file) == pinned[key], f"Vendored desktop source changed: {key}")
    for name in ("package.json", "LICENSE"):
        key = f"upstream/{name}"
        require(digest_file(source / name) == pinned[key], f"Vendored desktop source changed: {key}")


def prepare_stage(stage: Path, manifest: dict) -> dict:
    source = VENDOR / "upstream"
    inventory = json.loads((VENDOR / "SOURCE.json").read_text())
    require(inventory["upstream"]["commit"] == manifest["upstream"]["commit"], "Vendored commit changed")
    ensure_source_inventory(source, inventory)
    avatar = ROOT / manifest["helper"]["approvedAvatarSource"]
    require(digest_file(avatar) == manifest["helper"]["approvedAvatarSHA256"], "Approved avatar source changed")
    run(sys.executable, str(ROOT / "scripts/prepare-aigoodbro-brand-icons.py"), "--verify-only")
    stage.mkdir(parents=True)
    for folder in ("src", "assets"):
        shutil.copytree(source / folder, stage / folder)
    for name in ("package.json", "LICENSE"):
        shutil.copy2(source / name, stage / name)
    # The collector and Advanced settings read this declarative fork build pin
    # at runtime. Keep the exact inventoried manifest, without build scripts.
    vendor_manifest = "scripts/vendor/tokscale.json"
    require(digest_file(source / vendor_manifest) == inventory["finalSource"]["files"][f"upstream/{vendor_manifest}"], "Vendored scanner manifest changed")
    (stage / "scripts/vendor").mkdir(parents=True)
    shutil.copy2(source / vendor_manifest, stage / vendor_manifest)
    shutil.copy2(ROOT / manifest["helper"]["brandIcon"], stage / "assets/icon.png")
    shutil.copy2(ROOT / manifest["helper"]["trayIcon"], stage / "assets/tray-curve.png")
    stage.joinpath("aigoodbro").mkdir()
    for name in ("bootstrap.cjs", "hostBridge.cjs"):
        shutil.copy2(DESKTOP / name, stage / "aigoodbro" / name)
    transformed = json.loads(run("node", str(ROOT / manifest["helper"]["transformer"]), str(stage.resolve())))
    require(transformed.get("ok") is True and transformed.get("changed"), "Staging transform did not apply")
    package = json.loads((stage / "package.json").read_text())
    package["main"] = manifest["helper"]["asarMain"]
    package["productName"] = manifest["helper"]["displayName"]
    package["build"]["productName"] = manifest["helper"]["displayName"]
    package["build"]["appId"] = manifest["helper"]["bundleID"]
    (stage / "package.json").write_text(json.dumps(package, ensure_ascii=False, indent=2) + "\n")
    require(package["main"] == "aigoodbro/bootstrap.cjs", "Electron main path changed")
    require("../../../assets/icon.png" in (stage / "src/electron/renderer/index.html").read_text(), "Renderer brand icon path is wrong")
    require(digest_file(stage / "assets/icon.png") == digest_file(ROOT / manifest["helper"]["brandIcon"]), "Brand icon was not staged")
    require(digest_file(stage / "assets/tray-curve.png") == digest_file(ROOT / manifest["helper"]["trayIcon"]), "Tray icon was not staged")
    for icon in (source / "assets/icons").rglob("*"):
        if icon.is_file():
            require(digest_file(icon) == digest_file(stage / "assets/icons" / icon.relative_to(source / "assets/icons")), f"Provider icon changed: {icon.name}")
    return {"stageFiles": sum(1 for file in stage.rglob("*") if file.is_file()), "transformChanged": transformed["changed"]}


def collect_members(original_asar: Path, stage: Path, expected_node_modules: int) -> dict[str, tuple[bytes, bool, bool]]:
    original_tree, start, _ = asar_header(original_asar)
    members: dict[str, tuple[bytes, bool, bool]] = {}
    for relative, entry in entries(original_tree):
        if not relative.startswith("node_modules/"):
            continue
        if entry.get("unpacked"):
            # The signed official DMG has three native binaries whose actual
            # bytes differ from the pre-signing header metadata. The entire
            # unpacked tree is separately pinned to that DMG below; regenerate
            # correct metadata for those real bytes in our output ASAR.
            content = original_asar.with_name(original_asar.name + ".unpacked").joinpath(*relative.split("/")).read_bytes()
        else:
            content = asar_content(original_asar, original_tree, start, relative)
        members[relative] = (content, bool(entry.get("unpacked")), bool(entry.get("executable")))
    require(len(members) == expected_node_modules, "Official packaged node_modules closure changed")
    for file in stage.rglob("*"):
        if file.is_file():
            relative = file.relative_to(stage).as_posix()
            require(relative not in members, f"Stage overwrote official node_modules: {relative}")
            members[relative] = (file.read_bytes(), False, os.access(file, os.X_OK))
    return members


def copied_info(app: Path, manifest: dict, header_hash: str) -> None:
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    require(info["CFBundleIdentifier"] == manifest["runtime"]["sourceBundleID"], "Unexpected official runtime bundle")
    display_name = manifest["helper"]["displayName"]
    info["CFBundleIdentifier"] = manifest["helper"]["bundleID"]
    info["CFBundleDisplayName"] = display_name
    info["CFBundleName"] = display_name
    # The native host owns the Dock icon, including before Electron is ready.
    info["LSUIElement"] = True
    old_executable = info["CFBundleExecutable"]
    require(old_executable == "Token Monitor", "Official Electron executable name changed")
    (app / "Contents/MacOS" / old_executable).rename(app / "Contents/MacOS" / display_name)
    info["CFBundleExecutable"] = display_name
    info["ElectronAsarIntegrity"] = {"Resources/app.asar": {"algorithm": "SHA256", "hash": header_hash}}
    info["CFBundleIconFile"] = "icon.icns"
    with info_path.open("wb") as stream:
        plistlib.dump(info, stream)
    # ElectronMainDelegate::OverrideChildProcessPath derives the helper app and
    # executable names from the main bundle's CFBundleName before any JS runs.
    # Keep all four child variants aligned with the new AiGoodBro bundle name.
    frameworks = app / "Contents/Frameworks"
    for suffix in ("", " (GPU)", " (Plugin)", " (Renderer)"):
        old_name = f"Token Monitor Helper{suffix}"
        new_name = f"{display_name} Helper{suffix}"
        old_helper = frameworks / f"{old_name}.app"
        helper = frameworks / f"{new_name}.app"
        require(old_helper.is_dir() and not helper.exists(), f"Official Electron helper path changed: {old_name}")
        old_helper.rename(helper)
        old_binary = helper / "Contents/MacOS" / old_name
        require(old_binary.is_file(), f"Official Electron helper executable changed: {old_name}")
        old_binary.rename(helper / "Contents/MacOS" / new_name)
        child_plist = helper / "Contents/Info.plist"
        with child_plist.open("rb") as stream:
            child_info = plistlib.load(stream)
        child_info["CFBundleName"] = new_name
        child_info["CFBundleDisplayName"] = new_name
        child_info["CFBundleExecutable"] = new_name
        child_info["CFBundleIdentifier"] = manifest["helper"]["bundleID"] + ".helper" + ("." + suffix[2:-1] if suffix else "")
        with child_plist.open("wb") as stream:
            plistlib.dump(child_info, stream)
    shutil.copy2(ROOT / "Resources/AiGoodBro.icns", app / "Contents/Resources/icon.icns")
    shutil.copy2(VENDOR / "upstream/LICENSE", app / "Contents/Resources/TokenMonitor-MIT-LICENSE.txt")
    # A Widget in Contents/PlugIns may register under its author's bundle ID,
    # even though AiGoodBro cannot inherit that Team/App Group. Preserve its
    # exact files in a non-registerable archive for a later provisioned build.
    widget = app / "Contents/PlugIns/TokenMonitorWidget.appex"
    require(widget.is_dir(), "Official runtime Widget extension is missing")
    require(widget_tree_digest(widget) == manifest["widget"]["originalTreeSHA256"], "Original Widget extension changed")
    archive = app / manifest["widget"]["archive"]
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zipped:
        for file in sorted(widget.rglob("*")):
            if file.is_file():
                zipped.write(file, f"TokenMonitorWidget.appex/{file.relative_to(widget).as_posix()}")
    require(archived_widget_digest(archive) == manifest["widget"]["originalTreeSHA256"], "Archived Widget bytes changed")
    shutil.rmtree(widget)
    active_config = app / "Contents/Resources/token-monitor-widget.json"
    require(digest_file(active_config) == manifest["widget"]["originalConfigSHA256"], "Original Widget configuration changed")
    active_config.rename(app / manifest["widget"]["configArchive"])


def sign_app(app: Path) -> None:
    # Re-sign the copied runtime; the original Widget is an inert resource,
    # outside PlugIns, and cannot reuse the author's App Group entitlement.
    entitlements = app.parent / "token-core-entitlements.plist"
    with entitlements.open("wb") as stream:
        plistlib.dump({
            "com.apple.security.cs.allow-jit": True,
            "com.apple.security.cs.allow-unsigned-executable-memory": True,
            "com.apple.security.cs.disable-library-validation": True,
        }, stream)
    run("codesign", "--force", "--deep", "--sign", "-", "--options", "runtime", "--entitlements", str(entitlements), str(app))
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
    entitlements.unlink()


def verify_bundle(app: Path, manifest: dict, *, check_signature: bool) -> dict:
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    require(info["CFBundleIdentifier"] == manifest["helper"]["bundleID"], "Helper bundle ID mismatch")
    require(info["CFBundleDisplayName"] == manifest["helper"]["displayName"], "Helper brand mismatch")
    require(info["CFBundleName"] == manifest["helper"]["displayName"], "Electron main bundle name mismatch")
    require(info.get("LSUIElement") is True, "Embedded helper must not register a second Dock icon")
    require(info["CFBundleExecutable"] == manifest["helper"]["displayName"], "Electron main executable name mismatch")
    require((app / "Contents/MacOS" / info["CFBundleExecutable"]).is_file(), "Electron main executable is missing")
    mach_o_files = verify_architecture(app, manifest["runtime"]["architecture"])
    for suffix in ("", " (GPU)", " (Plugin)", " (Renderer)"):
        name = f"{manifest['helper']['displayName']} Helper{suffix}"
        helper = app / "Contents/Frameworks" / f"{name}.app"
        require(helper.is_dir(), f"Electron child app is missing: {name}")
        child_info = plistlib.loads((helper / "Contents/Info.plist").read_bytes())
        require(all(child_info.get(key) == name for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable")), f"Electron child bundle naming mismatch: {name}")
        require((helper / "Contents/MacOS" / name).is_file(), f"Electron child executable is missing: {name}")
        require(child_info["CFBundleIdentifier"] == manifest["helper"]["bundleID"] + ".helper" + ("." + suffix[2:-1] if suffix else ""), f"Electron child bundle ID mismatch: {name}")
        require(not (app / "Contents/Frameworks" / f"Token Monitor Helper{suffix}.app").exists(), "Original helper app name still active")
    integrity = info["ElectronAsarIntegrity"]["Resources/app.asar"]
    require(integrity["algorithm"] == "SHA256", "ASAR integrity algorithm changed")
    asar = app / "Contents/Resources/app.asar"
    result = verify_asar(asar, integrity["hash"])
    tree, start, _ = asar_header(asar)
    package = json.loads(asar_content(asar, tree, start, "package.json"))
    require(package["main"] == manifest["helper"]["asarMain"], "Helper main path mismatch")
    require(package["productName"] == manifest["helper"]["displayName"], "Electron product brand mismatch")
    require(sum(relative.startswith("node_modules/") for relative, _ in entries(tree)) == manifest["runtime"]["officialNodeModulesMembers"], "Packaged dependency closure count mismatch")
    for name in ("bootstrap.cjs", "hostBridge.cjs"):
        require(asar_content(asar, tree, start, f"aigoodbro/{name}") == (DESKTOP / name).read_bytes(), f"Packaged host adapter is stale: {name}")
    require(asar_content(asar, tree, start, "assets/icon.png") == (ROOT / manifest["helper"]["brandIcon"]).read_bytes(), "ASAR brand icon mismatch")
    require(asar_content(asar, tree, start, "assets/tray-curve.png") == (ROOT / manifest["helper"]["trayIcon"]).read_bytes(), "ASAR tray icon mismatch")
    require(digest_file(app / "Contents/Resources/icon.icns") == digest_file(ROOT / "Resources/AiGoodBro.icns"), "Helper Dock icon mismatch")
    require(asar_content(asar, tree, start, "LICENSE") == (VENDOR / "upstream/LICENSE").read_bytes(), "Upstream MIT license missing")
    require(not (app / "Contents/PlugIns/TokenMonitorWidget.appex").exists(), "Original Widget is still in the active PlugIns directory")
    require(not (app / "Contents/Resources/token-monitor-widget.json").exists(), "Original author's Widget configuration is still active")
    require(archived_widget_digest(app / manifest["widget"]["archive"]) == manifest["widget"]["originalTreeSHA256"], "Original Widget archive is missing or changed")
    require(digest_file(app / manifest["widget"]["configArchive"]) == manifest["widget"]["originalConfigSHA256"], "Original Widget configuration archive is missing or changed")
    if check_signature:
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
    result["bundleID"] = info["CFBundleIdentifier"]
    result["architecture"] = manifest["runtime"]["architecture"]
    result["machOFiles"] = mach_o_files
    result["signatureVerified"] = check_signature
    result["widgetFunctionality"] = "archived-inert-unavailable-without-AiGoodBro-Team-and-App-Group"
    result["asarSHA256"] = digest_file(asar)
    return result


def build(runtime: Path, output: Path, *, architecture: str, replace: bool, skip_sign: bool, source_dmg: Path | None, receipt: Path) -> dict:
    manifest = select_manifest(json.loads(MANIFEST.read_text()), architecture)
    if source_dmg:
        require(digest_file(source_dmg) == manifest["runtime"]["officialDMGSHA256"], "Official source DMG SHA256 mismatch")
    require(runtime.resolve() != output.resolve(), "Output cannot overwrite official runtime")
    require(not output.resolve().is_relative_to(runtime.resolve()), "Output cannot be inside official runtime")
    require(runtime.is_dir(), "Official runtime app is missing")
    require(not output.exists() or replace, "Output already exists; pass --replace for this candidate")
    original_info = plistlib.loads((runtime / "Contents/Info.plist").read_bytes())
    require(original_info["CFBundleIdentifier"] == manifest["runtime"]["sourceBundleID"], "Official runtime bundle ID changed")
    require(original_info["CFBundleShortVersionString"] == manifest["runtime"]["version"], "Official runtime version changed")
    run("codesign", "--verify", "--deep", "--strict", str(runtime))
    signature = subprocess.run(("codesign", "-dv", str(runtime)), capture_output=True, text=True, check=True)
    require(f"TeamIdentifier={manifest['runtime']['sourceTeamID']}" in signature.stderr, "Official runtime signing Team changed")
    verify_architecture(runtime, architecture)
    original_asar = runtime / "Contents/Resources/app.asar"
    _, _, official_header = asar_header(original_asar)
    require(official_header == manifest["runtime"]["officialAsarHeaderSHA256"], "Official runtime ASAR pin mismatch")
    require(original_info["ElectronAsarIntegrity"]["Resources/app.asar"]["hash"] == official_header, "Official ElectronAsarIntegrity mismatch")
    original_tree, _, _ = asar_header(original_asar)
    require(official_unpacked_tree_digest(original_asar, original_tree) == manifest["runtime"]["officialUnpackedTreeSHA256"], "Official unpacked native modules differ from the SHA-pinned DMG")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="token-core-package-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        stage = temporary / "stage"
        transformer_hash = digest_file(DESKTOP / "transform-stage.cjs")
        stage_result = prepare_stage(stage, manifest)
        require(digest_file(DESKTOP / "transform-stage.cjs") == transformer_hash, "Staging transformer changed during packaging")
        candidate = temporary / output.name
        shutil.copytree(runtime, candidate, symlinks=True)
        new_asar = candidate / "Contents/Resources/app.asar"
        header_hash, member_count = build_asar(new_asar, collect_members(original_asar, stage, manifest["runtime"]["officialNodeModulesMembers"]))
        copied_info(candidate, manifest, header_hash)
        if not skip_sign:
            sign_app(candidate)
        result = verify_bundle(candidate, manifest, check_signature=not skip_sign)
        require(result["members"] == member_count, "ASAR member count changed")
        result.update(stage_result)
        result["transformerSHA256"] = transformer_hash
        result["bootstrapSHA256"] = digest_file(DESKTOP / "bootstrap.cjs")
        result["hostBridgeSHA256"] = digest_file(DESKTOP / "hostBridge.cjs")
        if output.exists():
            shutil.rmtree(output)
        candidate.rename(output)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({"output": str(output), **result}, indent=2) + "\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
    parser.add_argument("--runtime-app", type=Path, default=Path("/Applications/Token Monitor.app"))
    parser.add_argument("--source-dmg", type=Path, help="Optional SHA256 check of the downloaded official release image")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--receipt", type=Path, default=DEFAULT_RECEIPT)
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--skip-sign", action="store_true", help="For ASAR tests only; never install this output")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    manifest = select_manifest(json.loads(MANIFEST.read_text()), args.arch)
    result = verify_bundle(args.output, manifest, check_signature=not args.skip_sign) if args.verify_only else build(args.runtime_app, args.output, architecture=args.arch, replace=args.replace, skip_sign=args.skip_sign, source_dmg=args.source_dmg, receipt=args.receipt)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"AiGoodBro desktop packaging failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
