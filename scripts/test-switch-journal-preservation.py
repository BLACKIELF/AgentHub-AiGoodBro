#!/usr/bin/env python3
"""Run the real startup external-cleanup branch with synthetic files only."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ROOT / "Sources/CodexUsageWidget/Services"
spec = importlib.util.spec_from_file_location("credential_generation", ROOT / "scripts/test-credential-generation.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
files = [SERVICES / "CodexAccountActions.swift", SERVICES / "CodexProfileStore.swift", SERVICES / "CodexCredentialTransaction.swift",
         ROOT / "tests/SwitchJournalPreservationFixture.swift", Path(__file__).resolve(), ROOT / "scripts/test-credential-generation.py", ROOT / "scripts/test-auth-stability.py"]
inputs = {p: p.read_bytes() for p in files}
actions, profiles, transaction, fixture = [inputs[p].decode() for p in files[:4]]
reader = "enum CodexOfficialProfileReader {\n" + "\n".join(g.extract(profiles, n) for n in [
    "static func credentialIdentity(fromAuthData", "private static func claims(fromToken", "private static func accountID(in",
    "private static func normalizedEmail(_", "private static func nonEmpty(_",
]) + "\n}"
start = actions.index("    func recoverPendingSwitchIfNeeded(")
start = actions.index("                case .preserveExternal:", start) + len("                case .preserveExternal:")
body = actions[start:actions.index("                case .originalAlreadyPresent:", start)]
methods = ["fileprivate enum AuthState:", "fileprivate struct PendingSwitchJournal:", "fileprivate enum PendingSwitchRecoveryDecision:",
           "fileprivate static func authFingerprint(", "fileprivate static func identityDigest(for identity:", "fileprivate static func identityDigest(for state:",
           "fileprivate static func pendingSwitchRecoveryDecision(", "fileprivate static func authState("]
code = g.STUBS + reader + "\nstruct WidgetLanguage {static func storedOrAutomatic()->Self {Self()};func text(_ c:String,_ e:String)->String {e}}\n"
code += "enum CodexCredentialTransaction {\n" + g.extract(transaction, "static func read(_ url:") + "\n}\n"
code += r'''
enum CodexAccountActions {
    static var cleanupCount = 0
    enum RecoveryOutcome { case preservedExternalAuth }
    static func switchError(_ message: String) -> Error { CocoaError(.fileReadCorruptFile) }
    static func clearPendingSwitchJournal(fileManager: FileManager) throws { cleanupCount += 1 }
    fileprivate static func cleanupExternal(currentAuth: AuthState, journal: PendingSwitchJournal, systemAuthURL: URL, fileManager: FileManager) throws {
        var result: Result<RecoveryOutcome, Error>?
'''
code += body + "\n_ = result\n}\n" + "\n".join(g.extract(actions, n) for n in methods) + "\n}\n"
code += g.extract(g.TESTS, "func jwt(") + "\n" + g.extract(g.TESTS, "func bundle(") + "\n" + fixture
with tempfile.TemporaryDirectory(prefix="aigoodbro-journal-preservation-") as temporary:
    folder = Path(temporary)
    (folder / "checks.swift").write_text(code)
    result = subprocess.run(["xcrun", "swift", "-module-cache-path", str(folder / "modules"), str(folder / "checks.swift")], capture_output=True, text=True, timeout=90)
    output = (result.stdout + result.stderr).replace(temporary, "<isolated-temporary>")
unchanged = all(p.read_bytes() == data for p, data in inputs.items())
print(output, end="")
print(json.dumps({"exitCode": result.returncode, "inputsUnchanged": unchanged,
                  "inputHashes": {str(p.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for p, data in inputs.items()}}))
raise SystemExit(result.returncode or (0 if unchanged else 2))
