#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Offline synthetic fixture for the Grok reset-card presentation/sorting rules.
# All card samples are synthetic (the official billing response carries no
# reset-card fields; see review-inputs/grok-reset-schema-0911v1.json).

SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) TARGET="arm64-apple-macosx13.0" ;;
  *) TARGET="x86_64-apple-macosx13.0" ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
OUTPUT="$TMP_DIR/grok-reset-cards-fixture"
CACHE_DIR="$TMP_DIR/module-cache"
mkdir -p "$CACHE_DIR"

python3 scripts/check-build-target-idle.py "$OUTPUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -module-cache-path "$CACHE_DIR" \
  Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift \
  Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift \
  Sources/CodexUsageWidget/Services/TokenMonitorEngine.swift \
  Sources/CodexUsageWidget/Services/TokenMonitorLocalCLIQuotaReader.swift \
  Sources/CodexUsageWidget/Domain/ResetCardPresentation.swift \
  Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift \
  Sources/CodexUsageWidget/Services/GrokResetStatusObservationReader.swift \
  Sources/CodexUsageWidget/Services/LocalCLIQuotaReader.swift \
  Sources/CodexUsageWidget/Services/ClaudeSubscriptionService.swift \
  Sources/CodexUsageWidget/Services/LocalCLIQuotaRefresh.swift \
  Sources/CodexUsageWidget/Services/CCSwitchClaudeRelay.swift \
  Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  tests/GrokResetCardsFixture.swift \
  -o "$OUTPUT"

"$OUTPUT"
