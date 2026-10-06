#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
PLIST_RELEASE="$(/usr/libexec/PlistBuddy -c 'Print CodexAccountManagerNextReleaseName' Resources/Info.plist)"
BUILD_DIR="${BUILD_DIR-build}"
DIST_DIR="${DIST_DIR-dist}"
RELEASE_ARCHITECTURES="${RELEASE_ARCHITECTURES-arm64 x86_64}"
TOKEN_MONITOR_CACHE="${TOKEN_MONITOR_CACHE:-$HOME/Library/Caches/AiGoodBro/Next/token-monitor-downloads}"
TOKEN_MONITOR_RECEIPT_DIR="${TOKEN_MONITOR_RECEIPT_DIR:-.build-receipts/AiGoodBro/Next}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
export TOKEN_MONITOR_CACHE TOKEN_MONITOR_RECEIPT_DIR SIGN_IDENTITY
ARM_RUNTIME="${TOKEN_MONITOR_DESKTOP_RUNTIME_ARM64:-${TOKEN_MONITOR_DESKTOP_RUNTIME:-}}"
ARM_DMG="${TOKEN_MONITOR_DESKTOP_DMG_ARM64:-${TOKEN_MONITOR_DESKTOP_DMG:-}}"
INTEL_RUNTIME="${TOKEN_MONITOR_DESKTOP_RUNTIME_X86_64:-}"
INTEL_DMG="${TOKEN_MONITOR_DESKTOP_DMG_X86_64:-}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || { echo "Invalid release version: $VERSION" >&2; exit 1; }
if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
  echo "Requested version $VERSION does not match Info.plist version $PLIST_VERSION" >&2
  exit 1
fi
[[ "$PLIST_BUILD" =~ ^[1-9][0-9]*$ && "$PLIST_RELEASE" =~ ^[0-9]{4}v[1-9][0-9]*$ ]] || { echo "Invalid release build/name in Info.plist" >&2; exit 1; }
[[ "$RELEASE_ARCHITECTURES" != *$'\n'* && "$RELEASE_ARCHITECTURES" != *$'\r'* ]] || { echo "Invalid RELEASE_ARCHITECTURES" >&2; exit 1; }
read -r -a RELEASE_ARCHS <<< "$RELEASE_ARCHITECTURES"
[[ "${#RELEASE_ARCHS[@]}" -gt 0 ]] || { echo "RELEASE_ARCHITECTURES must not be empty" >&2; exit 1; }
seen_archs=" "
for arch in "${RELEASE_ARCHS[@]}"; do
  [[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "Unknown release architecture: $arch" >&2; exit 1; }
  [[ "$seen_archs" != *" $arch "* ]] || { echo "Duplicate release architecture: $arch" >&2; exit 1; }
  seen_archs+="$arch "
done
[[ "$(uname -m)" == arm64 ]] || { echo "Release self-tests require an arm64 Mac" >&2; exit 1; }

# The native self-test gate always runs on ARM64, even for an Intel-only output.
[[ -f "$ARM_DMG" ]] || { echo "Pinned official arm64 desktop runtime DMG is missing: $ARM_DMG" >&2; exit 1; }
[[ -d "$ARM_RUNTIME" ]] || { echo "Read-only mounted arm64 desktop runtime is missing: $ARM_RUNTIME" >&2; exit 1; }
if [[ "$seen_archs" == *" x86_64 "* ]]; then
  [[ -f "$INTEL_DMG" ]] || { echo "Pinned official x86_64 desktop runtime DMG is missing: $INTEL_DMG" >&2; exit 1; }
  [[ -d "$INTEL_RUNTIME" ]] || { echo "Read-only mounted x86_64 desktop runtime is missing: $INTEL_RUNTIME" >&2; exit 1; }
fi

python3 - "$ROOT_DIR" "$BUILD_DIR" "$DIST_DIR" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
protected = {pathlib.Path('/'), pathlib.Path.home(), root, pathlib.Path('/Applications'), pathlib.Path('/tmp'), pathlib.Path('/private/tmp')}
source_dirs = [root / name for name in ('Sources', 'Resources', 'Companion', 'scripts', 'tests', 'docs', 'windows', '.agents', '.git')]
for value in sys.argv[2:]:
    if not value.strip():
        raise SystemExit('BUILD_DIR and DIST_DIR must not be empty')
    path = pathlib.Path(value).resolve()
    if path in protected or path in root.parents or path.is_relative_to('/Applications') or any(part.endswith('.app') for part in path.parts):
        raise SystemExit(f'Unsafe release output directory: {value}')
    if any(path == item or path.is_relative_to(item) for item in source_dirs):
        raise SystemExit(f'Release output overlaps source directory: {value}')
PY

verify_bundle_version() {
  python3 - "$1/Contents/Info.plist" "$VERSION" "$PLIST_BUILD" "$PLIST_RELEASE" <<'PY'
import pathlib, plistlib, sys
expected = tuple(sys.argv[2:])
keys = ('CFBundleShortVersionString', 'CFBundleVersion', 'CodexAccountManagerNextReleaseName')
for filename in ('Resources/Info.plist', sys.argv[1]):
    with pathlib.Path(filename).open('rb') as stream:
        metadata = plistlib.load(stream)
    if tuple(str(metadata.get(key, '')) for key in keys) != expected:
        raise SystemExit(f'Release version/build/name mismatch: {filename}')
PY
}

make memory-risk-check BUILD_DIR="$BUILD_DIR"
python3 tests/test_health_boundaries.py
python3 -B tests/test_token_monitor_packaging.py
plutil -lint Resources/Info.plist
git diff --check

make test-macos-compatibility
make test BUILD_DIR="$BUILD_DIR" DIST_DIR="$DIST_DIR" VERSION="$VERSION" \
  TARGET_TRIPLE="arm64-apple-macos${DEPLOYMENT_TARGET:-13.0}" SWIFT_OPTIMIZATION=-O \
  BUNDLE_COMPANION=1 BUNDLE_TOKEN_MONITOR_DESKTOP=1 \
  TOKEN_MONITOR_DESKTOP_RUNTIME="$ARM_RUNTIME" TOKEN_MONITOR_DESKTOP_DMG="$ARM_DMG"
CAMNEXT_SKIP_BUILD=1 ./scripts/test-parsers.sh

package_asset() {
  local arch="$1"
  local name="AiGoodBro-${VERSION}-mac-${arch}.dmg"
  verify_bundle_version "$BUILD_DIR/AiGoodBro.app"
  APP_NAME=AiGoodBro DISPLAY_NAME=AiGoodBro VERSION="$VERSION" ARCH_NAME="$arch" \
    BUILD_DIR="$BUILD_DIR" DIST_DIR="$DIST_DIR" APP_DIR="$BUILD_DIR/AiGoodBro.app" \
    DMG_PATH="$DIST_DIR/$name" ./scripts/package-dmg.sh
  (cd "$DIST_DIR" && shasum -a 256 "$name" > "$name.sha256")
}

MOUNT_DIR=""
cleanup_mount() {
  if [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null && rmdir "$MOUNT_DIR" || true
  fi
}
trap cleanup_mount EXIT

verify_asset() {
  local arch="$1"
  local expected_arch="$2"
  local dmg="$DIST_DIR/AiGoodBro-${VERSION}-mac-${arch}.dmg"
  local checksum="${dmg}.sha256"
  local mount_dir

  [[ -f "$dmg" ]] || { echo "Missing release asset: $dmg" >&2; exit 1; }
  [[ -f "$checksum" ]] || { echo "Missing checksum: $checksum" >&2; exit 1; }
  python3 - "$dmg" "$checksum" <<'PY'
import pathlib, re, sys
asset, checksum = map(pathlib.Path, sys.argv[1:])
lines = checksum.read_text().splitlines()
match = re.fullmatch(r'([0-9a-fA-F]{64}) [ *](.+)', lines[0]) if len(lines) == 1 else None
if not match or match[2] != asset.name:
    raise SystemExit(f'Checksum must contain one hash and the asset basename: {checksum}')
PY
  (cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$checksum")")
  hdiutil verify "$dmg" >/dev/null

  mount_dir="$(mktemp -d)"
  MOUNT_DIR="$mount_dir"
  hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg" >/dev/null
  verify_bundle_version "$mount_dir/AiGoodBro.app"
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
# Only these source directories belong to the independently verified upstream
# closure. Same-named files, links or directories elsewhere remain forbidden.
provider_directories = {
    resources / 'TokenMonitorEngine/upstream/src/shared/providers/codex',
    resources / 'TokenMonitorEngine/upstream/src/electron/providers/codex',
}
for forbidden in ('python', 'python3', 'codex'):
    for path in resources.rglob(forbidden):
        assert path in provider_directories and path.is_dir() and not path.is_symlink(), forbidden
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
  MOUNT_DIR=""
}

if [[ "$seen_archs" == *" arm64 "* ]]; then
  package_asset arm64
  verify_asset arm64 arm64
fi
if [[ "$seen_archs" == *" x86_64 "* ]]; then
  make build BUILD_DIR="$BUILD_DIR" DIST_DIR="$DIST_DIR" VERSION="$VERSION" \
    TARGET_TRIPLE="x86_64-apple-macos${DEPLOYMENT_TARGET:-13.0}" SWIFT_OPTIMIZATION=-O \
    BUNDLE_COMPANION=1 BUNDLE_TOKEN_MONITOR_DESKTOP=1 \
    TOKEN_MONITOR_DESKTOP_RUNTIME="$INTEL_RUNTIME" TOKEN_MONITOR_DESKTOP_DMG="$INTEL_DMG"
  package_asset x86_64
  verify_asset x86_64 x86_64
fi

echo "Release artifacts verified for AiGoodBro $VERSION ($RELEASE_ARCHITECTURES)"
for arch in "${RELEASE_ARCHS[@]}"; do
  cat "$DIST_DIR/AiGoodBro-${VERSION}-mac-${arch}.dmg.sha256"
done
