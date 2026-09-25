#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MANIFEST="scripts/self-tests.txt"
SWIFT_SOURCE="Sources/CodexUsageWidget/main.swift"
EXPECTED_COUNT=32
BUILD_DIR="build"
SKIP_BUILD=0
SELECTED_TEST=""

usage() {
  echo "Usage: $0 [--skip-build] [--build-dir DIR] [--only SELF_TEST]" >&2
}

fail() {
  echo "self-test runner: $1" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --build-dir)
      (( $# >= 2 )) || { usage; exit 2; }
      BUILD_DIR="$2"
      shift 2
      ;;
    --only)
      (( $# >= 2 )) || { usage; exit 2; }
      SELECTED_TEST="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -f "$MANIFEST" ]] || fail "missing manifest: $MANIFEST"
[[ -f "$SWIFT_SOURCE" ]] || fail "missing Swift entry point: $SWIFT_SOURCE"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MANIFEST_NORMALIZED="$TMP_DIR/manifest"
MANIFEST_SORTED="$TMP_DIR/manifest-sorted"
SWIFT_EXPOSED="$TMP_DIR/swift-exposed"
SWIFT_SORTED="$TMP_DIR/swift-sorted"

manifest_count=0
while IFS= read -r self_test || [[ -n "$self_test" ]]; do
  manifest_count=$((manifest_count + 1))
  [[ "$self_test" =~ ^--self-test-[a-z0-9-]+$ ]] \
    || fail "invalid entry on manifest line $manifest_count"
  printf '%s\n' "$self_test" >> "$MANIFEST_NORMALIZED"
done < "$MANIFEST"

[[ "$manifest_count" -eq "$EXPECTED_COUNT" ]] \
  || fail "manifest must contain exactly $EXPECTED_COUNT entries; found $manifest_count"

sort "$MANIFEST_NORMALIZED" > "$MANIFEST_SORTED"
duplicate="$(uniq -d "$MANIFEST_SORTED" | sed -n '1p')"
[[ -z "$duplicate" ]] || fail "duplicate manifest entry: $duplicate"

sed -n 's/.*CommandLine\.arguments\.contains("\(--self-test-[a-z0-9-]*\)").*/\1/p' \
  "$SWIFT_SOURCE" > "$SWIFT_EXPOSED"
swift_count="$(wc -l < "$SWIFT_EXPOSED" | tr -d ' ')"
[[ "$swift_count" -eq "$EXPECTED_COUNT" ]] \
  || fail "Swift must expose exactly $EXPECTED_COUNT self-tests; found $swift_count"

sort "$SWIFT_EXPOSED" > "$SWIFT_SORTED"
duplicate="$(uniq -d "$SWIFT_SORTED" | sed -n '1p')"
[[ -z "$duplicate" ]] || fail "duplicate Swift self-test exposure: $duplicate"

if ! cmp -s "$MANIFEST_SORTED" "$SWIFT_SORTED"; then
  while IFS= read -r missing; do
    [[ -z "$missing" ]] || echo "self-test runner: manifest entry not exposed by Swift: $missing" >&2
  done < <(comm -23 "$MANIFEST_SORTED" "$SWIFT_SORTED")
  while IFS= read -r unlisted; do
    [[ -z "$unlisted" ]] || echo "self-test runner: Swift exposure missing from manifest: $unlisted" >&2
  done < <(comm -13 "$MANIFEST_SORTED" "$SWIFT_SORTED")
  exit 1
fi

if [[ -n "$SELECTED_TEST" && "$SELECTED_TEST" != --self-test-* ]]; then
  SELECTED_TEST="--self-test-$SELECTED_TEST"
fi
if [[ -n "$SELECTED_TEST" ]] && ! awk -v selected="$SELECTED_TEST" '$0 == selected { found = 1 } END { exit !found }' "$MANIFEST_NORMALIZED"; then
  fail "unknown self-test: $SELECTED_TEST"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  make build BUILD_DIR="$BUILD_DIR"
  make --no-print-directory verify-runtime-resources BUILD_DIR="$BUILD_DIR"
fi

BIN="$BUILD_DIR/AiGoodBro.app/Contents/MacOS/AiGoodBro"
[[ -x "$BIN" ]] || fail "built executable is missing; run without --skip-build or check --build-dir"

run_count="$EXPECTED_COUNT"
[[ -z "$SELECTED_TEST" ]] || run_count=1
current=0
while IFS= read -r self_test; do
  [[ -z "$SELECTED_TEST" || "$self_test" == "$SELECTED_TEST" ]] || continue
  current=$((current + 1))
  echo "[$current/$run_count] $self_test"
  "$BIN" "$self_test"
done < "$MANIFEST_NORMALIZED"

echo "All $run_count selected self-test(s) passed"
