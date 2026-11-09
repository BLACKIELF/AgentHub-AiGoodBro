#!/usr/bin/env python3
"""Exercise production engine refresh/cancel with an offline synthetic collector."""
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/CodexUsageWidget"
paths = [SOURCE / "Services/UsageStore.swift", SOURCE / "Domain/TokenMonitorEngineModels.swift",
         SOURCE / "Domain/StatisticsTimeZone.swift", SOURCE / "Services/TokenMonitorEngine.swift",
         ROOT / "tests/StatisticsEngineCacheFixture.swift"]
snapshots = {path: path.read_bytes() for path in paths}
usage, models, timezone, engine, fixture = [snapshots[path].decode() for path in paths]
fields = usage[usage.index("    private var engineGeneration ="):usage.index("    @Published private(set) var engineLimitsByProfileID:")]
methods = usage[usage.index("    func selectStatisticsEngine("):usage.index("    private func updateTokenMonitorHubAfterLocalCollection(")]
code = fixture.replace("// PRODUCTION_ENGINE_FIELDS", fields.replace("private ", ""))
code = code.replace("// PRODUCTION_ENGINE_METHODS", methods.replace("private ", ""))
stop_start = usage.index("    func stop() {")
stop_start = usage.index("        fullRefreshCancellation?.cancel()", stop_start)
stop = usage[stop_start:usage.index("        feishuTaskCompletionObserver =", stop_start)]
code = code.replace("// PRODUCTION_STOP_REFRESH", stop)
warmup_guard = "guard self.refreshGeneration == generation, !self.isLaunchingCodex, !self.isAccountSwitchTransactionActive else { return }"
full_guard = "guard self.fullRefreshCancellation === cancellation, !cancellation.isCancelled else { return }"
assert usage.count(warmup_guard) == usage.count(full_guard) == 1
code = code.replace("// PRODUCTION_WARMUP_GUARD", usage[usage.index(warmup_guard):usage.index(warmup_guard) + len(warmup_guard)])
code = code.replace("// PRODUCTION_FULL_REFRESH_GUARD", usage[usage.index(full_guard):usage.index(full_guard) + len(full_guard)])
timezone = timezone[:timezone.index("enum StatisticsTimeZonePreferenceStore")]
cancellation = engine[engine.index("final class TokenMonitorCancellation:"):engine.index("/// Blocking supervision:")]
with tempfile.TemporaryDirectory(prefix="statistics-engine-cache-") as temporary:
    directory = Path(temporary)
    inputs = []
    for name, source in [("Fixture.swift", code), ("Models.swift", models), ("Timezone.swift", timezone), ("Cancellation.swift", "import Foundation\n" + cancellation)]:
        path = directory / name
        path.write_text(source)
        inputs.append(str(path))
    binary = directory / "cache-fixture"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(directory / "modules"), *inputs, "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], timeout=20)
unchanged = all(path.read_bytes() == data for path, data in snapshots.items())
print(json.dumps({"testExitCode": result.returncode, "inputsUnchanged": unchanged,
                  "inputsSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for path, data in snapshots.items()}}))
raise SystemExit(result.returncode or (0 if unchanged else 2))
