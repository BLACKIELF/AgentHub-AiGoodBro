#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
BUILD_DIR="${BUILD_DIR:-build}"
DIST_DIR="${DIST_DIR:-dist}"
TOKEN_MONITOR_CACHE="${TOKEN_MONITOR_CACHE:-$HOME/Library/Caches/AiGoodBro/Next/token-monitor-downloads}"
TOKEN_MONITOR_RECEIPT_DIR="${TOKEN_MONITOR_RECEIPT_DIR:-.build-receipts/AiGoodBro/Next}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
export TOKEN_MONITOR_CACHE TOKEN_MONITOR_RECEIPT_DIR SIGN_IDENTITY
ARM_RUNTIME="${TOKEN_MONITOR_DESKTOP_RUNTIME_ARM64:-${TOKEN_MONITOR_DESKTOP_RUNTIME:-}}"
ARM_DMG="${TOKEN_MONITOR_DESKTOP_DMG_ARM64:-${TOKEN_MONITOR_DESKTOP_DMG:-}}"
INTEL_RUNTIME="${TOKEN_MONITOR_DESKTOP_RUNTIME_X86_64:-}"
INTEL_DMG="${TOKEN_MONITOR_DESKTOP_DMG_X86_64:-}"

if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
  echo "Requested version $VERSION does not match Info.plist version $PLIST_VERSION" >&2
  exit 1
fi
[[ "$(uname -m)" == arm64 ]] || { echo "Dual-architecture release tests require an arm64 Mac" >&2; exit 1; }
for input in "$ARM_DMG" "$INTEL_DMG"; do
  [[ -f "$input" ]] || { echo "Pinned official desktop runtime DMG is missing: $input" >&2; exit 1; }
done
for input in "$ARM_RUNTIME" "$INTEL_RUNTIME"; do
  [[ -d "$input" ]] || { echo "Read-only mounted desktop runtime is missing: $input" >&2; exit 1; }
done

make memory-risk-check BUILD_DIR="$BUILD_DIR"
python3 tests/test_health_boundaries.py
python3 -B tests/test_token_monitor_packaging.py
plutil -lint Resources/Info.plist
git diff --check

make test-macos-compatibility
make test TOKEN_MONITOR_DESKTOP_RUNTIME="$ARM_RUNTIME" TOKEN_MONITOR_DESKTOP_DMG="$ARM_DMG"
CAMNEXT_SKIP_BUILD=1 ./scripts/test-parsers.sh

make clean-dist DIST_DIR="$DIST_DIR"
make release-arm64 BUILD_DIR="$BUILD_DIR" DIST_DIR="$DIST_DIR" BUNDLE_COMPANION=1 \
  TOKEN_MONITOR_DESKTOP_RUNTIME="$ARM_RUNTIME" TOKEN_MONITOR_DESKTOP_DMG="$ARM_DMG"
make release-intel BUILD_DIR="$BUILD_DIR" DIST_DIR="$DIST_DIR" BUNDLE_COMPANION=1 \
  TOKEN_MONITOR_DESKTOP_RUNTIME="$INTEL_RUNTIME" TOKEN_MONITOR_DESKTOP_DMG="$INTEL_DMG"

verify_asset() {
  local arch="$1"
  local expected_arch="$2"
  local dmg="$DIST_DIR/AiGoodBro-${VERSION}-mac-${arch}.dmg"
  local checksum="${dmg}.sha256"
  local mount_dir

  [[ -f "$dmg" ]] || { echo "Missing release asset: $dmg" >&2; exit 1; }
  [[ -f "$checksum" ]] || { echo "Missing checksum: $checksum" >&2; exit 1; }
  shasum -a 256 -c "$checksum"
  hdiutil verify "$dmg" >/dev/null

  mount_dir="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg" >/dev/null
  [[ "$(lipo -archs "$mount_dir/AiGoodBro.app/Contents/MacOS/AiGoodBro")" == "$expected_arch" ]] || { echo "Native app architecture mismatch: $arch" >&2; exit 1; }
  codesign --verify --deep --strict "$mount_dir/AiGoodBro.app"
  python3 scripts/prepare-token-monitor-desktop.py --arch "$arch" \
    --output "$mount_dir/AiGoodBro.app/Contents/Helpers/AiGoodBro Token Core.app" --verify-only
  local resources="$mount_dir/AiGoodBro.app/Contents/Resources"
  python3 scripts/prepare-token-monitor-resources.py --verify --resources "$resources" \
    --bundle "$mount_dir/AiGoodBro.app" --arch "$arch" --cache "$TOKEN_MONITOR_CACHE" \
    --trusted-receipt "$TOKEN_MONITOR_RECEIPT_DIR/token-monitor-${arch}.json" --sign-identity "$SIGN_IDENTITY"
  local hub="$resources/CompanionHub/agent-remote-control"
  [[ -x "$hub" ]] || { echo "Missing bundled Companion Hub" >&2; exit 1; }
  [[ "$(lipo -archs "$hub")" == "$expected_arch" ]] || { echo "Companion Hub architecture mismatch: $arch" >&2; exit 1; }
  codesign --verify --strict "$hub"
  cmp scripts/next_runtime_setup.py "$resources/SupportTools/next_runtime_setup.py"
  python3 - "$resources" "$arch" <<'PY'
import hashlib, json, pathlib, sys
resources, expected_arch = pathlib.Path(sys.argv[1]), sys.argv[2]
manifest = json.loads((resources / 'CompanionHub/manifest.json').read_text())
hub = resources / 'CompanionHub/agent-remote-control'
assert manifest == {
    'schemaVersion': 1,
    'architecture': expected_arch,
    'version': '0910v2-next',
    'executable': 'agent-remote-control',
    'sha256': hashlib.sha256(hub.read_bytes()).hexdigest(),
    'sourceManifestSHA256': hashlib.sha256(pathlib.Path('Companion/Hub/SOURCE.json').read_bytes()).hexdigest(),
}
for forbidden in ('runtime-paths.json', 'runtime-python.txt'):
    assert not list(resources.rglob(forbidden)), forbidden
# TokenMonitorEngine closure was rebuilt and verified above; no other exception.
for modules in resources.rglob('node_modules'):
    assert modules.is_relative_to(resources / 'TokenMonitorEngine/vendor'), 'outside node_modules'
for forbidden in ('__pycache__', '.pytest_cache'):
    assert not list(resources.rglob(forbidden)), forbidden
for forbidden in ('python', 'python3', 'codex'):
    assert not list(resources.rglob(forbidden)), forbidden
PY
  python3 - "$resources/CompanionSkill" <<'PY'
import pathlib, runpy, subprocess, sys
source = pathlib.Path(sys.argv[1])
if not source.is_dir() or source.is_symlink():
    raise SystemExit('Missing reviewed app CompanionSkill resources')
definition = runpy.run_path('scripts/prepare-companion-resources.py')
public = definition['ROOT'] / '.agents/skills/multi-agent-management'
for relative in definition['SKILL_FILES']:
    bundled = source / relative
    reviewed = definition['SKILL_SOURCE_OVERRIDES'].get(relative, public / relative)
    if (not bundled.is_file() or bundled.is_symlink()
            or any((source / parent).is_symlink() for parent in pathlib.Path(relative).parents)
            or not reviewed.is_file() or reviewed.is_symlink()):
        raise SystemExit(f'Missing reviewed companion Skill file: {relative}')
    if subprocess.run(['/usr/bin/cmp', '-s', str(reviewed), str(bundled)]).returncode:
        raise SystemExit(f'App companion Skill differs from reviewed source: {relative}')
PY
  python3 - "$resources/CompanionSkill" "$mount_dir/Companion Skill/multi-agent-management" <<'PY'
import pathlib, runpy, subprocess, sys
source, attachment = map(pathlib.Path, sys.argv[1:])
for folder in (source, attachment):
    if not folder.is_dir() or folder.is_symlink():
        raise SystemExit('Missing reviewed companion Skill resources')
definition = runpy.run_path('scripts/prepare-companion-resources.py')
for relative in definition['SKILL_FILES']:
    for folder in (source, attachment):
        item = folder / relative
        if (not item.is_file() or item.is_symlink()
                or any((folder / parent).is_symlink() for parent in pathlib.Path(relative).parents)):
            raise SystemExit(f'Missing reviewed companion Skill file: {relative}')
    if subprocess.run(['/usr/bin/cmp', '-s', str(source / relative), str(attachment / relative)]).returncode:
        raise SystemExit(f'DMG companion Skill differs from verified app resources: {relative}')
PY
  hdiutil detach "$mount_dir" >/dev/null
  rmdir "$mount_dir"
}

verify_asset arm64 arm64
verify_asset x86_64 x86_64

echo "Release artifacts verified for AiGoodBro $VERSION"
cat "$DIST_DIR/AiGoodBro-${VERSION}-mac-arm64.dmg.sha256"
cat "$DIST_DIR/AiGoodBro-${VERSION}-mac-x86_64.dmg.sha256"
