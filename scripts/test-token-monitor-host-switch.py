#!/usr/bin/env python3
"""Run the real host switch handler and store methods against offline identities.

Only the credential reader and launch operation are synthetic. No socket, auth
file, application, or account switch is opened by the fixture.
"""
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT = ROOT / "Sources/CodexUsageWidget"
paths = [
    SWIFT / "App/AppLifecycle.swift",
    SWIFT / "Services/UsageStore.swift",
    SWIFT / "Domain/TokenMonitorHostIdentity.swift",
    SWIFT / "Services/TokenMonitorHostServer.swift",
    ROOT / "tests/TokenMonitorHostSwitchFixture.swift",
]
snapshots = {path: path.read_bytes() for path in paths}
lifecycle, usage = (snapshots[path].decode() for path in paths[:2])
start = lifecycle.index("            case .switchCodexAccount:\n") + len("            case .switchCodexAccount:\n")
end = lifecycle.index("\n            }\n            return TokenMonitorHostReply", start)
handler = lifecycle[start:end]
start = usage.index("    func requestTokenMonitorDesktopSwitch(")
end = usage.index("    private func reserveDesktopSwitchMaintenance(", start)
methods = usage[start:end]
template = snapshots[paths[-1]].decode()
assert template.count("// PRODUCTION_STORE_METHODS") == template.count("// PRODUCTION_HOST_SWITCH") == 1
with tempfile.TemporaryDirectory(prefix="aigoodbro-host-switch-fixture-") as temporary:
    folder = Path(temporary)
    fixture = folder / "HostSwitch.swift"
    fixture.write_text(template.replace("// PRODUCTION_STORE_METHODS", methods).replace("// PRODUCTION_HOST_SWITCH", handler))
    sources = [fixture]
    for path in paths[2:4]:
        frozen = folder / path.name
        frozen.write_bytes(snapshots[path])
        sources.append(frozen)
    binary = folder / "host-switch"
    subprocess.run(
        ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(folder / "modules"), *map(str, sources), "-o", str(binary)],
        check=True,
    )
    result = subprocess.run([str(binary)], check=False)
unchanged = all(path.read_bytes() == value for path, value in snapshots.items())
print(json.dumps({"testExitCode": result.returncode, "inputsUnchanged": unchanged,
                  "inputsSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(value).hexdigest() for path, value in snapshots.items()}}))
raise SystemExit(result.returncode or (0 if unchanged else 2))
