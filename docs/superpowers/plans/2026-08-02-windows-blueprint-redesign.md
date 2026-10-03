# codexU Windows Blueprint Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stale Windows Blueprint with a schema-backed five-block runtime graph whose test, native-capture, probe, build, and evidence satellites connect to the exact Windows objects they validate or consume.

**Architecture:** `schema.yaml` remains the only semantic source of truth. The deterministic renderer reads the schema and produces SVG/HTML/PNG maintenance artifacts; a separately generated presentation candidate uses the same node, edge, and composition contract. The selected `diagram.png` is chosen only after semantic and visual review, while `BLUEPRINT.md` records responsibilities, contracts, evidence, and limits.

**Tech Stack:** YAML, Python 3, PyYAML, SVG/HTML, Mermaid, Edge/Chrome headless PNG capture, Blueprint validation scripts, image generation.

## Global Constraints

- Use only current Windows implementation, Windows documentation, Windows tests, and Windows build scripts from `windows-port/ui-dev` as architecture evidence.
- Keep exactly five primary runtime blocks inside `codexU Windows Desktop Runtime`; tests and delivery tools remain outside that boundary.
- Draw the local telemetry primary path separately from the read-only official quota bypass.
- Draw `Screenshot Workflow Preflight --verifies--> Native Screenshot Demo --captures exact HWND--> Windows Desktop UI` and make the Demo produce local-only visual evidence.
- Do not use macOS `Sources/` to fill Windows gaps and do not restore stale Claude-primary, runtime-registry, WinUI, updater, or old Leadership-model nodes.
- Do not publish, embed, or commit real `.local-artifacts` screenshots, logs, paths, or local values.
- Keep deterministic and generated PNG candidates as separate files before selecting `diagram.png`.
- Do not claim native, build, or test results that were not executed during this implementation.

---

### Task 1: Replace the Blueprint semantic source and narrative

**Files:**
- Modify: `docs/windows-port/blueprint/schema.yaml`
- Modify: `docs/windows-port/blueprint/diagram.mmd`
- Modify: `docs/windows-port/blueprint/BLUEPRINT.md`

**Interfaces:**
- Consumes: approved design in `docs/superpowers/specs/2026-08-02-windows-blueprint-redesign.md` and current Windows evidence paths.
- Produces: stable node IDs and edge contracts consumed by the renderer, generated-image prompt, Mermaid fallback, and narrative.

- [ ] **Step 1: Prove the stale schema does not meet the approved semantic contract**

Run:

```powershell
@'
import pathlib, yaml
p = pathlib.Path("docs/windows-port/blueprint/schema.yaml")
s = yaml.safe_load(p.read_text(encoding="utf-8"))
ids = {n["id"] for n in s["nodes"]}
required = {
    "local_evidence", "safe_readers", "dashboard_aggregation",
    "snapshot_app_state", "windows_desktop_ui", "quota_tests",
    "core_tests", "app_state_tests", "web_contract_tests",
    "native_capture_demo", "capture_preflight", "local_visual_evidence",
    "codexu_probe", "build_package"
}
assert ids == required, (ids - required, required - ids)
'@ | uv run --with pyyaml python -
```

Expected: FAIL because the old schema contains stale nodes and lacks the approved runtime/test nodes.

- [ ] **Step 2: Rewrite `schema.yaml` with the exact approved topology**

Define these 14 stable node IDs:

```yaml
runtime: [local_evidence, safe_readers, dashboard_aggregation, snapshot_app_state, windows_desktop_ui]
verification: [quota_tests, core_tests, app_state_tests, web_contract_tests, native_capture_demo, capture_preflight]
operations: [local_visual_evidence, codexu_probe, build_package]
```

Define the primary/runtime edges:

```yaml
local_evidence -> safe_readers: reads local evidence
safe_readers -> dashboard_aggregation: safe observations
local_evidence -> dashboard_aggregation: official quota bypass
dashboard_aggregation -> snapshot_app_state: CodexDashboardSnapshot
snapshot_app_state -> windows_desktop_ui: Tauri commands and events
```

Define satellite edges with explicit verbs:

```yaml
quota_tests -> local_evidence: verifies quota protocol
quota_tests -> dashboard_aggregation: verifies apply and retain
core_tests -> safe_readers: verifies reduction
core_tests -> dashboard_aggregation: verifies aggregation
app_state_tests -> snapshot_app_state: verifies state behavior
web_contract_tests -> windows_desktop_ui: verifies component contracts
native_capture_demo -> windows_desktop_ui: captures exact HWND
capture_preflight -> native_capture_demo: verifies workflow
native_capture_demo -> local_visual_evidence: produces manifest and 12 PNGs
codexu_probe -> safe_readers: consumes safe readers
codexu_probe -> dashboard_aggregation: emits diagnostic snapshot
build_package -> snapshot_app_state: bundles Tauri backend
build_package -> windows_desktop_ui: bundles WebView UI
build_package -> native_capture_demo: provides release executable
```

- [ ] **Step 3: Rewrite the Mermaid fallback as a semantic subset**

Use one `Windows Desktop Runtime` subgraph containing the five runtime nodes. Keep each satellite outside the subgraph and use dashed arrows only for `verifies`; use labeled solid arrows for runtime, capture, build, consume, and produce relationships.

- [ ] **Step 4: Rewrite `BLUEPRINT.md` from the same contract**

Include: selected architecture image and source links; one-paragraph Windows positioning; a five-row responsibility/input/output/non-goal table; runtime edge ledger; test-to-object ledger; native screenshot chain; privacy/read-only boundary; rendering/validation status; known evidence limits.

- [ ] **Step 5: Validate semantic source and fallback**

Run:

```powershell
uv run --with pyyaml python "$env:USERPROFILE\.cc-switch\skills\blueprint\scripts\validate_blueprint.py" --schema docs/windows-port/blueprint/schema.yaml --artifacts-dir docs/windows-port/blueprint
@'
import pathlib, yaml
s = yaml.safe_load(pathlib.Path("docs/windows-port/blueprint/schema.yaml").read_text(encoding="utf-8"))
ids = {n["id"] for n in s["nodes"]}
required = {"local_evidence", "safe_readers", "dashboard_aggregation", "snapshot_app_state", "windows_desktop_ui", "quota_tests", "core_tests", "app_state_tests", "web_contract_tests", "native_capture_demo", "capture_preflight", "local_visual_evidence", "codexu_probe", "build_package"}
assert ids == required
edges = {(e["from"], e["to"], e.get("label")) for e in s["edges"]}
assert ("capture_preflight", "native_capture_demo", "verifies workflow") in edges
assert ("native_capture_demo", "windows_desktop_ui", "captures exact HWND") in edges
assert ("native_capture_demo", "local_visual_evidence", "produces manifest + 12 PNGs") in edges
'@ | uv run --with pyyaml python -
git diff --check
```

Expected: validator reports zero errors; semantic assertions and `git diff --check` exit 0.

- [ ] **Step 6: Commit the semantic Blueprint**

```powershell
git add -- docs/windows-port/blueprint/schema.yaml docs/windows-port/blueprint/diagram.mmd docs/windows-port/blueprint/BLUEPRINT.md
git commit -m "docs(windows): rebuild blueprint semantics"
```

### Task 2: Build the deterministic renderer and maintenance artifacts

**Files:**
- Create: `docs/windows-port/blueprint/render.py`
- Modify: `docs/windows-port/blueprint/diagram.svg`
- Modify: `docs/windows-port/blueprint/diagram.html`
- Create: `docs/windows-port/blueprint/diagram.render.png`

**Interfaces:**
- Consumes: `schema.yaml` nodes, categories, edges, groups, callouts, and explicit layout.
- Produces: `render(schema_path: Path, out_dir: Path) -> tuple[Path, Path]`, plus deterministic SVG/HTML and browser-rasterized PNG.

- [ ] **Step 1: Add explicit layout metadata to the schema**

Use an 1800×1400 composition: five runtime cards centered left-to-right inside one strong rounded boundary; quota/core/AppState tests above their targets; Web contracts, native capture, and capture preflight near the UI; Probe, build/package, and local evidence below their targets. Reserve orthogonal corridors so verification lines do not read as runtime data flow.

- [ ] **Step 2: Implement the project-local renderer**

`render.py` must:

```python
def load_schema(path: Path) -> dict: ...
def render_svg(schema: dict) -> str: ...
def write_html(svg: str, path: Path) -> None: ...
def render(schema_path: Path, out_dir: Path) -> tuple[Path, Path]: ...
```

It must escape all schema text, draw groups before edges and nodes, route edges orthogonally, assign arrow/dash styles by `kind`, wrap Chinese/English labels inside cards, calculate the final viewBox from declared canvas size, and embed the SVG in a UTF-8 standalone HTML page.

- [ ] **Step 3: Generate deterministic SVG and HTML**

Run:

```powershell
uv run --with pyyaml python docs/windows-port/blueprint/render.py --schema docs/windows-port/blueprint/schema.yaml --out-dir docs/windows-port/blueprint
```

Expected: `diagram.svg` and `diagram.html` are rewritten and non-empty.

- [ ] **Step 4: Rasterize the deterministic HTML with the Windows browser fallback**

Run:

```powershell
python "$env:USERPROFILE\.cc-switch\skills\blueprint\scripts\html_to_png.py" docs/windows-port/blueprint/diagram.html docs/windows-port/blueprint/diagram.render.png --width 1800 --height 1400
```

Expected: `diagram.render.png` exists and is non-empty. Record browser fallback in `BLUEPRINT.md`; do not claim CairoSVG was used.

- [ ] **Step 5: Run geometry acceptance and inspect the render**

Run:

```powershell
python "$env:USERPROFILE\.cc-switch\skills\blueprint\scripts\check_svg_geometry.py" docs/windows-port/blueprint/diagram.svg --json-out docs/windows-port/blueprint/geometry.json --overlay-out docs/windows-port/blueprint/geometry-overlay.svg --screenshot-out docs/windows-port/blueprint/geometry-screenshot.png --fail-on-error
```

Expected: zero geometry errors. Inspect `diagram.render.png` and `geometry-overlay.svg`; fix clipped text, card/group overlap, unintended crossings, or weak spacing in schema/layout/renderer, then rerun until clean. Remove diagnostic `geometry.json`, `geometry-overlay.svg`, and `geometry-screenshot.png` before committing because they are review intermediates, not canonical Blueprint assets.

- [ ] **Step 6: Commit the deterministic track**

```powershell
git add -- docs/windows-port/blueprint/render.py docs/windows-port/blueprint/schema.yaml docs/windows-port/blueprint/diagram.svg docs/windows-port/blueprint/diagram.html docs/windows-port/blueprint/diagram.render.png docs/windows-port/blueprint/BLUEPRINT.md
git commit -m "docs(windows): render blueprint maintenance view"
```

### Task 3: Generate and review the presentation candidate

**Files:**
- Create: `docs/windows-port/blueprint/diagram.generated.png`
- Modify: `docs/windows-port/blueprint/BLUEPRINT.md`

**Interfaces:**
- Consumes: exact schema labels, five-block runtime boundary, satellite relationships, and composition coordinates.
- Produces: a non-authoritative presentation candidate that may be selected only if its labels and relationships remain faithful.

- [ ] **Step 1: Build the image-generation prompt from schema facts**

The prompt must demand: 16:9 dark technical editorial style; one central framed Windows runtime with exactly five named blocks; surrounding test/operations satellites attached to exact targets; dashed `verifies` links; the nested `Preflight -> Screenshot Demo -> UI -> Local Evidence` relationship; no icons or nodes not present in schema; no macOS or Claude-primary content.

- [ ] **Step 2: Generate one presentation candidate**

Use the image-generation tool with no reference image. Save the returned image as `docs/windows-port/blueprint/diagram.generated.png` without changing its pixels through a separate drawing pipeline.

- [ ] **Step 3: Perform semantic fidelity review**

Compare the generated candidate against the schema edge ledger. Reject it as the final selection if it omits a runtime block, merges a test with its target, moves a test into Runtime, invents a node, reverses a key arrow, or renders labels unreadably. Record the honest verdict in `BLUEPRINT.md`.

- [ ] **Step 4: Commit the generated candidate**

```powershell
git add -- docs/windows-port/blueprint/diagram.generated.png docs/windows-port/blueprint/BLUEPRINT.md
git commit -m "docs(windows): add blueprint presentation candidate"
```

### Task 4: Select the human-facing diagram and close validation

**Files:**
- Modify: `docs/windows-port/blueprint/diagram.png`
- Modify: `docs/windows-port/blueprint/BLUEPRINT.md`

**Interfaces:**
- Consumes: `diagram.render.png`, `diagram.generated.png`, schema validation, geometry results, and manual visual comparison.
- Produces: reviewed `diagram.png` plus a narrative that names the selected source and remaining limits.

- [ ] **Step 1: Compare both candidates side by side**

Inspect both images at original resolution. Score: exact five-block hierarchy, correct test-to-target mapping, readable labels, clear runtime boundary, uncluttered orthogonal routing, spacing rhythm, and report/slide suitability.

- [ ] **Step 2: Select the stronger faithful candidate**

Copy the winner byte-for-byte to `diagram.png`. Prefer the deterministic render when the generated candidate has any semantic or text-fidelity defect; do not select a prettier but incorrect image.

- [ ] **Step 3: Update final Blueprint status**

In `BLUEPRINT.md`, state which candidate was selected, how the deterministic PNG was produced, which validation commands actually passed, and these evidence limits: browser contracts do not prove native WebView2/DPI/IPC; native screenshots are local evidence rather than a committed baseline or blanket UI acceptance.

- [ ] **Step 4: Run final artifact and semantic checks**

Run:

```powershell
uv run --with pyyaml python "$env:USERPROFILE\.cc-switch\skills\blueprint\scripts\validate_blueprint.py" --schema docs/windows-port/blueprint/schema.yaml --artifacts-dir docs/windows-port/blueprint
python "$env:USERPROFILE\.cc-switch\skills\blueprint\scripts\check_svg_geometry.py" docs/windows-port/blueprint/diagram.svg --json-out docs/windows-port/blueprint/geometry.json --overlay-out docs/windows-port/blueprint/geometry-overlay.svg --fail-on-error
@'
from pathlib import Path
d = Path("docs/windows-port/blueprint")
for name in ["schema.yaml", "diagram.mmd", "diagram.svg", "diagram.html", "diagram.render.png", "diagram.generated.png", "diagram.png", "render.py", "BLUEPRINT.md"]:
    p = d / name
    assert p.exists() and p.stat().st_size > 0, name
'@ | python -
git diff --check
```

Expected: schema/Mermaid validation has zero errors, geometry has zero errors, all canonical artifacts are non-empty, and `git diff --check` exits 0. Remove `geometry.json` and `geometry-overlay.svg` after reviewing them.

- [ ] **Step 5: Commit the selected Blueprint**

```powershell
git add -- docs/windows-port/blueprint/diagram.png docs/windows-port/blueprint/BLUEPRINT.md
git commit -m "docs(windows): select reviewed blueprint view"
```

### Task 5: Verify repository state and close the goal

**Files:**
- Verify only: `docs/windows-port/blueprint/`
- Verify only: `docs/superpowers/specs/2026-08-02-windows-blueprint-redesign.md`
- Verify only: `docs/superpowers/plans/2026-08-02-windows-blueprint-redesign.md`

**Interfaces:**
- Consumes: all committed Blueprint artifacts and recorded validation results.
- Produces: evidence-backed completion statement without modifying Windows product code.

- [ ] **Step 1: Confirm no unrelated paths were changed**

Run:

```powershell
git status --short
git log --oneline --decorate -6
git diff HEAD~4..HEAD --name-only
```

Expected: implementation commits contain only the Blueprint folder, this plan, and the already approved design spec; worktree is clean.

- [ ] **Step 2: Re-open the selected image and final narrative**

Inspect `diagram.png` at original resolution and read `BLUEPRINT.md` once more. Confirm the displayed diagram matches the stated selected candidate and the native screenshot Demo connects directly to Windows Desktop UI.

- [ ] **Step 3: Mark the goal complete only after all required artifacts and checks pass**

Use the goal status tool with `status: complete`. If a required generated or deterministic artifact is missing, a geometry error remains, or the worktree contains unexplained changes, keep the goal active and continue fixing rather than reporting completion.
