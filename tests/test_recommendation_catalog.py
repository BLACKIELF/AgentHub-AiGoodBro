#!/usr/bin/env python3
"""Exercise catalogue sync and native shelf against temporary resources only."""
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

WORKTREE = Path(__file__).resolve().parents[1]
PROJECT = next(path for path in WORKTREE.parents if (path / "shared/recommendations/catalog.json").is_file())
SYNC = PROJECT / "scripts/sync-recommendations.py"
spec = importlib.util.spec_from_file_location("recommendation_sync", SYNC)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
catalog = sync.validate(json.loads(sync.SOURCE.read_text()))

with tempfile.TemporaryDirectory(prefix="recommendation-catalog-") as directory:
    temporary = Path(directory)
    desktop = temporary / "desktop"
    mini = temporary / "mini"
    command = ["python3", str(SYNC), "--desktop-root", str(desktop), "--mini-root", str(mini)]
    subprocess.run(command, check=True, timeout=20)
    assert not mini.exists(), "default must never write mini"
    subprocess.run(command + ["--check"], check=True, timeout=20)
    # The Mini owner is the only projector. Exercise its production entry in a
    # temporary project with the same relative source and HTML layout.
    shared = temporary / "shared/recommendations"
    shared.mkdir(parents=True)
    shutil.copyfile(sync.SOURCE, shared / "catalog.json")
    (mini / "scripts").mkdir(parents=True)
    shutil.copyfile(PROJECT / "miniprogram/scripts/sync-catalog.cjs", mini / "scripts/sync-catalog.cjs")
    (mini / "client/data").mkdir(parents=True)
    (mini / "qa").mkdir(parents=True)
    html = mini / "qa/account-overview-design-1013v4.html"
    html.write_text("<!doctype html>\n<script>\nconst picks=[];\n</script>\n")
    subprocess.run(command + ["--target", "all"], check=True, timeout=20)
    subprocess.run(command + ["--target", "all", "--check"], check=True, timeout=20)
    projected = json.loads(subprocess.check_output([
        "node", "-e", "process.stdout.write(JSON.stringify(require(process.argv[1])))",
        str(mini / "client/data/resources.js")], text=True))
    assert [item["id"] for item in projected] == sync.IDS
    assert projected[2]["title"] == catalog["items"][2]["title"]["zh"]
    assert projected[2]["summary"] == catalog["items"][2]["summary"]["zh"]
    assert projected[5]["title"] == "AIHOT · 热点日报"
    assert projected[5]["sourceURL"] == "https://github.com/KKKKhazix/AIHOT"
    assert all(isinstance(item["copyText"], str) and item["steps"] for item in projected)
    metadata = json.loads(subprocess.check_output([
        "node", "-e", "process.stdout.write(JSON.stringify(require(process.argv[1])))",
        str(mini / "client/data/recommendations.js")], text=True))
    assert [item["id"] for item in metadata] == sync.IDS
    assert all(item["icon"] and item["kind"] for item in metadata)
    assert metadata[5] == {"id": "aihot", "kind": "app", "icon": "📰"}
    assert '"id":"jev-use"' in html.read_text(), "Mini owner must also refresh HTML picks"
    assert '"id":"aihot"' in html.read_text(), "AIHOT must use the shared Mini projection"
    target = mini / "client/data/resources.js"
    target.write_text("module.exports = [];\n")
    assert subprocess.run(command + ["--target", "mini", "--check"], capture_output=True, timeout=20).returncode == 1
    assert target.read_text() == "module.exports = [];\n", "check must not repair drift"

    app = temporary / "CatalogFixture.app/Contents"
    resources = app / "Resources"
    (app / "MacOS").mkdir(parents=True)
    shutil.copytree(WORKTREE / "Resources/SkillLibrary", resources / "SkillLibrary")
    sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk")
    if not sdk.is_dir():
        sdk = Path(subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
    binary = app / "MacOS/fixture"
    sources = [
        "Sources/CodexUsageWidget/Domain/RecommendationCatalog.swift",
        "Sources/CodexUsageWidget/Services/RecommendationVisibilityStore.swift",
        "Sources/CodexUsageWidget/UI/HomeSkillShelf.swift",
        "tests/RecommendationCatalogFixture.swift",
    ]
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-target", f"{platform.machine()}-apple-macos13.0", "-sdk", str(sdk),
        "-module-cache-path", str(temporary / "modules"),
        *[str(WORKTREE / source) for source in sources], "-o", str(binary),
    ], cwd=WORKTREE, check=True, timeout=120)
    subprocess.run([str(binary)], cwd=WORKTREE, check=True, timeout=20)

print("PASS catalogue sync: desktop default, delegated Mini outputs, read-only drift checks; no live app, Skill or account access")
