#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
TAG="v${VERSION}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
PLIST_RELEASE="$(/usr/libexec/PlistBuddy -c 'Print CodexAccountManagerNextReleaseName' Resources/Info.plist)"
NOTES="docs/release-notes-v${VERSION}.md"
BUILD_DIR="${BUILD_DIR-build}"
DIST_DIR="${DIST_DIR-dist}"
RELEASE_ARCHITECTURES="${RELEASE_ARCHITECTURES-arm64 x86_64}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || { echo "Invalid release version: $VERSION" >&2; exit 1; }
[[ "$VERSION" == "$PLIST_VERSION" ]] || { echo "Info.plist version mismatch" >&2; exit 1; }
[[ "$PLIST_BUILD" =~ ^[1-9][0-9]*$ && "$PLIST_RELEASE" =~ ^[0-9]{4}v[1-9][0-9]*$ ]] || { echo "Invalid release build/name in Info.plist" >&2; exit 1; }
[[ -n "$BUILD_DIR" && -n "$DIST_DIR" ]] || { echo "BUILD_DIR and DIST_DIR must not be empty" >&2; exit 1; }
[[ "$RELEASE_ARCHITECTURES" != *$'\n'* && "$RELEASE_ARCHITECTURES" != *$'\r'* ]] || { echo "Invalid RELEASE_ARCHITECTURES" >&2; exit 1; }
read -r -a RELEASE_ARCHS <<< "$RELEASE_ARCHITECTURES"
[[ "${#RELEASE_ARCHS[@]}" -gt 0 ]] || { echo "RELEASE_ARCHITECTURES must not be empty" >&2; exit 1; }
seen_archs=" "
for arch in "${RELEASE_ARCHS[@]}"; do
  [[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "Unknown release architecture: $arch" >&2; exit 1; }
  [[ "$seen_archs" != *" $arch "* ]] || { echo "Duplicate release architecture: $arch" >&2; exit 1; }
  seen_archs+="$arch "
done

make memory-risk-check BUILD_DIR="$BUILD_DIR"
[[ -f "$NOTES" ]] || { echo "Missing release notes: $NOTES" >&2; exit 1; }
python3 - "$VERSION" "$PLIST_BUILD" "$PLIST_RELEASE" "${RELEASE_ARCHS[@]}" <<'PY'
import pathlib, re, sys
version, build, release, *architectures = sys.argv[1:]
escaped = re.escape(version)
legacy = re.compile(rf'^## {escaped}(?: / {re.escape(release)})? - ', re.M)
public = re.compile(rf'^## AiGoodBro [0-9]+\.[0-9]+ · {re.escape(release)} - [^\n]*[（(]{escaped} / {re.escape(build)}(?:[ /）)]|$)', re.M)
if not (legacy.search(pathlib.Path('CHANGELOG.md').read_text()) or public.search(pathlib.Path('CHANGELOG.md').read_text())):
    raise SystemExit(f'CHANGELOG is missing the release version/build/name: {version} / {build} / {release}')
for filename in ('README.md', 'README.en.md'):
    text = pathlib.Path(filename).read_text()
    artifacts = all(f'AiGoodBro-{version}-mac-{arch}.dmg' in text for arch in architectures)
    # Public brand/version prose is accepted if it identifies the exact internal
    # update version, build and formal release, rather than a stale candidate.
    metadata = (re.search(rf'(?<![0-9.]){escaped}\s*\({re.escape(build)}\)', text)
                and re.search(rf'(?<![0-9A-Za-z]){re.escape(release)}(?![0-9A-Za-z])', text)
                and re.search(r'AiGoodBro', text))
    if not (artifacts or metadata):
        raise SystemExit(f'{filename} release metadata/artifact examples are stale')
PY

if grep -q 'SHA256_PLACEHOLDER' "$NOTES"; then
  echo "Release notes still contain checksum placeholders" >&2
  exit 1
fi

MOUNT_DIR=""
cleanup_mount() {
  if [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null && rmdir "$MOUNT_DIR" || true
  fi
}
trap cleanup_mount EXIT

for arch in "${RELEASE_ARCHS[@]}"; do
  dmg="$DIST_DIR/AiGoodBro-${VERSION}-mac-${arch}.dmg"
  checksum="${dmg}.sha256"
  [[ -f "$dmg" && -f "$checksum" ]] || { echo "Missing $arch release assets" >&2; exit 1; }
  python3 - "$dmg" "$checksum" <<'PY'
import pathlib, re, sys
asset, checksum = map(pathlib.Path, sys.argv[1:])
lines = checksum.read_text().splitlines()
match = re.fullmatch(r'([0-9a-fA-F]{64}) [ *](.+)', lines[0]) if len(lines) == 1 else None
if not match or match[2] != asset.name:
    raise SystemExit(f'Checksum must contain one hash and the asset basename: {checksum}')
PY
  (cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$checksum")")
  hash="$(awk '{print $1}' "$checksum")"
  grep -Fq "$hash" "$NOTES" || { echo "$arch checksum is missing from $NOTES" >&2; exit 1; }
  hdiutil verify "$dmg" >/dev/null
  MOUNT_DIR="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$dmg" >/dev/null
  bundle="$MOUNT_DIR/AiGoodBro.app"
  python3 - "$bundle/Contents/Info.plist" "$VERSION" "$PLIST_BUILD" "$PLIST_RELEASE" <<'PY'
import pathlib, plistlib, sys
expected = tuple(sys.argv[2:])
keys = ('CFBundleShortVersionString', 'CFBundleVersion', 'CodexAccountManagerNextReleaseName')
for filename in ('Resources/Info.plist', sys.argv[1]):
    with pathlib.Path(filename).open('rb') as stream:
        metadata = plistlib.load(stream)
    if tuple(str(metadata.get(key, '')) for key in keys) != expected:
        raise SystemExit(f'Release version/build/name mismatch: {filename}')
PY
  [[ "$(lipo -archs "$bundle/Contents/MacOS/AiGoodBro")" == "$arch" ]] || { echo "Native app architecture mismatch: $arch" >&2; exit 1; }
  codesign --verify --deep --strict "$bundle"
  hdiutil detach "$MOUNT_DIR" >/dev/null
  rmdir "$MOUNT_DIR"
  MOUNT_DIR=""
done

plutil -lint Resources/Info.plist
git diff --check

if [[ "${ALLOW_EXISTING_RELEASE:-0}" != "1" ]]; then
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Local tag already exists: $TAG" >&2
    exit 1
  fi

  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "Remote tag already exists: $TAG" >&2
    exit 1
  fi

  if command -v gh >/dev/null && gh release view "$TAG" >/dev/null 2>&1; then
    echo "GitHub Release already exists: $TAG" >&2
    exit 1
  fi
fi

echo "Release metadata and assets are ready for $TAG ($RELEASE_ARCHITECTURES)"
