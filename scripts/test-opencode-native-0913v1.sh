#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-next-opencode-fixture.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
# Never bypass this guard, including for standalone fixture compilation.
python3 scripts/check-build-target-idle.py "$fixture_dir/fixture"
# Match the local CLI quota fixture's language shell while compiling the real helpers.
cat > "$fixture_dir/WidgetLanguage.swift" <<'SWIFT'
struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ chinese: String, _ english: String) -> String { english }
}
SWIFT
xcrun swiftc -swift-version 5 -module-cache-path "$fixture_dir/modules" \
  Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift \
  Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift \
  Sources/CodexUsageWidget/Services/TokenMonitorEngine.swift \
  Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift \
  Sources/CodexUsageWidget/Services/LocalCLIQuotaReader.swift \
  Sources/CodexUsageWidget/Services/ClaudeSubscriptionService.swift \
  Sources/CodexUsageWidget/Services/LocalCLIQuotaRefresh.swift \
  Sources/CodexUsageWidget/Services/CCSwitchClaudeRelay.swift \
  Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  Sources/CodexUsageWidget/Services/TokenMonitorLocalCLIQuotaReader.swift \
  "$fixture_dir/WidgetLanguage.swift" scripts/test-opencode-native-0913v1.swift -o "$fixture_dir/fixture"
"$fixture_dir/fixture" "$@"
