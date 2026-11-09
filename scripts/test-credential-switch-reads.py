#!/usr/bin/env python3
"""Exercise actual switch readers and the bounded FD reader in synthetic homes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ROOT / "Sources/CodexUsageWidget/Services"
spec = importlib.util.spec_from_file_location("credential_generation", ROOT / "scripts/test-credential-generation.py")
generation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generation)
extract = generation.extract
files = [SERVICES / name for name in ["CodexAccountActions.swift", "CodexProfileStore.swift", "CodexCredentialTransaction.swift", "DispatchParticipationSync.swift"]]
files += [ROOT / "tests/CredentialSwitchReadsFixture.swift", Path(__file__).resolve(), ROOT / "scripts/test-credential-generation.py", ROOT / "scripts/test-auth-stability.py"]
inputs = {p: p.read_bytes() for p in files}
actions, profiles, transaction, sync, fixture = [inputs[p].decode() for p in files[:5]]
reader = "enum CodexOfficialProfileReader {\n" + "\n".join(extract(profiles, n) for n in [
    "static func credentialIdentity(fromAuthData", "private static func claims(fromToken",
    "private static func accountID(in", "private static func normalizedEmail(_", "private static func nonEmpty(_",
]) + "\n}"
bounded = "enum DispatchParticipationError: Error { case fileAccess }\nenum DispatchParticipationSync {\nstatic let maximumConfigurationBytes = 1_048_576\n" + extract(sync, "static func readBoundedRegularFile(") + "\n}"
stubs = generation.STUBS.replace(extract(generation.STUBS, "enum DispatchParticipationSync {"), bounded)
helpers = r'''
struct WidgetLanguage { static func storedOrAutomatic() -> Self { Self() }; func text(_ c: String, _ e: String) -> String { e } }
extension CodexProfile {
    func matchesRecordedCredential(_ identity: CodexCredentialIdentity?) -> Bool {
        identity == CodexCredentialIdentity(email: recordedAccountKey, accountID: lastSnapshot!.accountID!)
    }
}
'''
methods = ["fileprivate enum AuthState:", "fileprivate static func authState(", "fileprivate static func validatedManagedAuth("]
code = "import Darwin\n" + stubs + reader + helpers
code += "enum CodexCredentialTransaction {\n" + extract(transaction, "static func read(_ url:") + "\n}\n"
code += "enum CodexAccountActions {\nstatic func switchError(_ value: String) -> Error { CocoaError(.fileReadCorruptFile) }\n"
code += "\n".join(extract(actions, n) for n in methods) + "\n}\n"
code += extract(generation.TESTS, "func jwt(") + "\n" + extract(generation.TESTS, "func bundle(") + "\n" + fixture
with tempfile.TemporaryDirectory(prefix="aigoodbro-switch-reads-") as temporary:
    folder = Path(temporary)
    (folder / "checks.swift").write_text(code)
    result = subprocess.run(["xcrun", "swift", "-module-cache-path", str(folder / "modules"), str(folder / "checks.swift")], capture_output=True, text=True, timeout=90)
    output = (result.stdout + result.stderr).replace(temporary, "<isolated-temporary>")
unchanged = all(p.read_bytes() == data for p, data in inputs.items())
print(output, end="")
print(json.dumps({"exitCode": result.returncode, "inputsUnchanged": unchanged,
                  "inputHashes": {str(p.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for p, data in inputs.items()}}))
raise SystemExit(result.returncode or (0 if unchanged else 2))
