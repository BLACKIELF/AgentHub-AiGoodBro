#!/usr/bin/env python3
"""Exercise the production SwiftUI editor with synthetic rows and disposable persistence.
Never reads live profiles, starts the real app/proxy, or changes authentication.
"""
from pathlib import Path
import argparse
import hashlib
import os
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def declaration(source, needle):
    start = source.index(needle)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(needle)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, help="Freeze an alternate UI source for a before/after control")
parser.add_argument("--source-revision", help="Use the actual UI from a Git revision as a regression control")
parser.add_argument("--stale-row-negative", action="store_true", help="Restore only the stale snapshot read in the frozen copy")
parser.add_argument("--diagnose", action="store_true")
args = parser.parse_args()
if args.source and args.source_revision:
    parser.error("Choose either --source or --source-revision")
ui_path = args.source or ROOT / "Sources/CodexUsageWidget/UI/LocalProxyQueueView.swift"
ui = (subprocess.check_output(["git", "show", f"{args.source_revision}:Sources/CodexUsageWidget/UI/LocalProxyQueueView.swift"],
                              cwd=ROOT, text=True) if args.source_revision else ui_path.read_text())
domain = (ROOT / "Sources/CodexUsageWidget/Domain/LocalProxyQueue.swift").read_text()
interaction = (ROOT / "Sources/CodexUsageWidget/UI/WorkspaceInteraction.swift").read_text()
parts = [
    "import AppKit\nimport SwiftUI\n",
    declaration(domain, "struct LocalProxyQueueRow:"),
    declaration(domain, "struct LocalProxyQuotaWindow:"),
    declaration(domain, "struct LocalProxyPreferences:"),
    declaration(domain, "struct LocalProxyAccountPolicy:"),
    declaration(interaction, "struct WorkspaceCheckboxStyle:"),
]
# Editor-specific helpers stay in the actual source, directly next to the editor.
start = ui.index("private struct LocalProxyAccountPolicyEditor<")
parts.append(ui[start:])
parts.append((ROOT / "tests/LocalProxyPolicyEditorFixture.swift").read_text())
frozen = "\n\n".join(parts)
if args.stale_row_negative:
    needle = "if !preserveDraft { resetDrafts(to: value) }"
    assert frozen.count(needle) == 1
    frozen = frozen.replace(needle, "if !preserveDraft { resetDrafts(to: savedState) }")
# Observe actual rendered state and control geometry without replacing any event handlers.
summary_needle = "Text(summary).foregroundStyle(.secondary)"
assert frozen.count(summary_needle) == 1
frozen = frozen.replace(summary_needle,
    "Text(PolicyEditorFixtureProbe.observe(summary: summary, dirty: dirty, saveFailed: saveFailed)).foregroundStyle(.secondary)")
save_needle = "}.disabled(!enabled || !dirty || policy == nil).fixedSize()"
assert frozen.count(save_needle) == 1
frozen = frozen.replace(save_needle, save_needle + '.background(PolicyEditorFixtureBounds(name: "save"))')
disclosure_needle = '.accessibilityIdentifier("next.local-proxy.rules-\\(row.id)")'
assert frozen.count(disclosure_needle) == 1
frozen = frozen.replace(disclosure_needle, disclosure_needle + '.background(PolicyEditorFixtureBounds(name: "rules"))')
for marker, name in [("    private var defaultsToggle:", "defaults"), ("    private var allowCreditsToggle:", "credits")]:
    block = declaration(frozen, marker)
    frozen = frozen.replace(block, block[:-1] + f'    .background(PolicyEditorFixtureBounds(name: "{name}"))\n    }}')
if args.diagnose:
    frozen = frozen.replace(
        ".onChange(of: row.policy) { _ in if !dirty { resetDrafts() } }",
        '.onChange(of: row.policy) { next in print("TRACE policy onChange new=\\(next.fiveHourUsedLimit), captured=\\(row.policy.fiveHourUsedLimit), dirty=\\(dirty), draft=\\(limit)"); if !dirty { resetDrafts() } }')
    frozen = frozen.replace(
        ".onChange(of: limit) { _ in markDirty() }",
        '.onChange(of: limit) { next in print("TRACE limit onChange new=\\(next), saved=\\(row.policy.fiveHourUsedLimit)"); markDirty() }')
    frozen = frozen.replace(
        "    private func resetDrafts() {",
        '    private func resetDrafts() {\n        print("TRACE resetDrafts saved=\\(row.policy.fiveHourUsedLimit), draft=\\(limit), dirty=\\(dirty)")')
    frozen = frozen.replace(
        "    private func markDirty() {",
        '    private func markDirty() {\n        print("TRACE markDirty saved=\\(row.policy.fiveHourUsedLimit), draft=\\(limit), previous=\\(dirty)")')
    frozen = frozen.replace(
        ".onChange(of: savedState) { value in",
        '.onChange(of: savedState) { value in\n            print("TRACE savedState onChange new=\\(value.policy.fiveHourUsedLimit), captured=\\(row.policy.fiveHourUsedLimit), dirty=\\(dirty), draft=\\(limit)")')
    frozen = frozen.replace(
        "    private func resetDrafts(to value: SavedState) {",
        '    private func resetDrafts(to value: SavedState) {\n        print("TRACE resetDrafts delivered=\\(value.policy.fiveHourUsedLimit), captured=\\(row.policy.fiveHourUsedLimit), draft=\\(limit)")')
print("Production editor source SHA-256:", hashlib.sha256(ui[start:].encode()).hexdigest(), flush=True)
print("Policy editor frozen harness SHA-256:", hashlib.sha256(frozen.encode()).hexdigest(), flush=True)
with tempfile.TemporaryDirectory(prefix="aigoodbro-policy-editor-fixture-") as temporary:
    folder = Path(temporary)
    source = folder / "Fixture.swift"
    source.write_text(frozen)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    print("POLICY_EDITOR_STAGE compiling native fixture (90s limit)", flush=True)
    subprocess.run([
        "xcrun", "swiftc", "-g", "-target", f"{platform.machine()}-apple-macos13.0", "-sdk", sdk,
        "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(folder / "modules"),
        str(source), "-o", str(folder / "fixture"), "-framework", "AppKit", "-framework", "SwiftUI",
    ], check=True, timeout=90)
    env = {**os.environ, "POLICY_EDITOR_FIXTURE_ROOT": str(folder / "support")}
    print("POLICY_EDITOR_STAGE running native fixture (45s limit)", flush=True)
    try:
        result = subprocess.run([str(folder / "fixture"), *(["--diagnose"] if args.diagnose else [])],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=45)
    except subprocess.TimeoutExpired as failure:
        # communicate() retains bytes on timeout even when text=True. Expose
        # the last native stage instead of discarding it with the traceback.
        partial = failure.stdout or b""
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", errors="replace")
        print(partial, end="", flush=True)
        print("FAIL native policy editor fixture exceeded 45s; captured output shown above", flush=True)
        raise
    print(result.stdout, end="", flush=True)
    if args.stale_row_negative:
        assert result.returncode == 1 and "FAIL A live input reverted after saving 30.0" in result.stdout, result.stdout
        assert "TRACE save requested limit=30.0" in result.stdout, result.stdout
        assert any(line.startswith('TRACE saved 30: inputs=["100"], saved=30.0,')
                   for line in result.stdout.splitlines()), result.stdout
        print("PASS negative control: restoring only the stale-row read reproduces 30 saved / 100 input")
    else:
        result.check_returncode()
