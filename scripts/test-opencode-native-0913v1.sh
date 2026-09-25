#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-next-opencode-fixture.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
# Never bypass this guard, including for standalone fixture compilation.
python3 scripts/check-build-target-idle.py "$fixture_dir/fixture"
# Include the exact existing bounded-file helper without the unrelated service.
python3 - "$fixture_dir/BoundedFile.swift" <<'PY'
from pathlib import Path
import sys
text = Path('Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift').read_text()
start = text.index('    static func readBoundedRegularFile(')
end = text.index('\n    private static func read(', start)
Path(sys.argv[1]).write_text('import Foundation\nimport Darwin\nenum DispatchParticipationError: Error { case fileAccess }\nstruct DispatchParticipationSync {\n' + next(line for line in text.splitlines() if 'static let maximumConfigurationBytes =' in line) + '\n' + text[start:end] + '\n}\n')
PY
xcrun swiftc -swift-version 5 -module-cache-path "$fixture_dir/modules" \
  Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift \
  Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift \
  Sources/CodexUsageWidget/Services/TokenMonitorEngine.swift \
  Sources/CodexUsageWidget/Services/LocalCLIQuotaReader.swift \
  Sources/CodexUsageWidget/Services/TokenMonitorLocalCLIQuotaReader.swift \
  "$fixture_dir/BoundedFile.swift" scripts/test-opencode-native-0913v1.swift -o "$fixture_dir/fixture"
"$fixture_dir/fixture" "$@"
