#!/usr/bin/env python3
"""Compile and run synthetic auth-stability tests from production Swift snippets."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIR.parent
DEFAULT_BUILD_DIR = REPOSITORY_ROOT / "task-test-outputs" / "auth-b2-build"
TARGET_NAME = "AuthStabilityFixture"


def extract_declaration(source: str, needle: str, *, optional: bool = False) -> str:
    start = source.find(needle)
    if start < 0:
        if optional:
            return ""
        raise RuntimeError(f"production declaration not found: {needle}")
    opening = source.find("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise RuntimeError(f"unclosed production declaration: {needle}")


def read_source(source_root: Path, relative_path: str) -> str:
    path = source_root / relative_path
    if not path.is_file():
        raise RuntimeError(f"source file not found: {path}")
    return path.read_text(encoding="utf-8")


def fixture_source(source_root: Path) -> str:
    services = "Sources/CodexUsageWidget/Services"
    reader = read_source(source_root, f"{services}/CodexUsageReader.swift")
    actions = read_source(source_root, f"{services}/CodexAccountActions.swift")
    profile_store = read_source(source_root, f"{services}/CodexProfileStore.swift")
    pipe_reader = read_source(source_root, f"{services}/CodexAppServerTaskClient.swift")
    models = read_source(source_root, "Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift")
    engine = read_source(source_root, f"{services}/TokenMonitorEngine.swift")
    usage_models = read_source(source_root, "Sources/CodexUsageWidget/Domain/UsageModels.swift")

    gate = extract_declaration(actions, "enum CodexCredentialAccessGate")
    pending = extract_declaration(reader, "final class AppServerPendingResponses")
    classifier = extract_declaration(reader, "enum AppServerFailureClassifier")
    snapshot = extract_declaration(reader, "struct AppServerSnapshot")
    read_app_server = extract_declaration(reader, "private func readAppServer(").replace(
        "private func readAppServer(", "func readAppServer(", 1
    )
    # Compare the exact production gate selection directly; child startup time is not lock evidence.
    selection_start = read_app_server.index("        let homePath =")
    selection_end = read_app_server.index("        while !gate.try()", selection_start)
    gate_selection = (
        "\nfunc selectedReaderGate(context: RuntimeLoadContext, profile: CodexProfile? = nil) -> NSRecursiveLock {\n        var messages: [String] = []\n        func stopReason() -> TokenMonitorFailure? { nil }\n"
        + read_app_server[selection_start:selection_end].replace("return AppServerSnapshot()", "return CodexCredentialAccessGate.lock")
        + "        return gate\n}\n"
    )
    failure_message = extract_declaration(reader, "static func appServerFailureMessage(")
    terminate = extract_declaration(reader, "private func terminate(")
    quota_failure = extract_declaration(profile_store, "static func quotaFailureReason(")
    posix_error = extract_declaration(pipe_reader, "enum POSIXPipeReaderError")
    posix_reader = extract_declaration(pipe_reader, "enum POSIXPipeReader {")

    stubs = r'''
import Foundation
import Darwin

struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ zh: String, _ en: String) -> String { en }
}

struct RuntimeLoadContext {
    var codexHomeDirectory: URL
    var homeDirectory: URL
    var quotaCancellation: TokenMonitorCancellation? = nil
}

struct Identity { var accountID: String }

struct CodexProfile {
    var isSystemProfile: Bool
    var codexHomeURL: URL
    var recordedAccountID: String
    var recordedEmail: String

    func matchesRecordedCredential(_ identity: Identity) -> Bool {
        identity.accountID == recordedAccountID
    }

    func matchesRecordedAccount(email: String?) -> Bool {
        email == recordedEmail
    }
}

enum SyntheticCredentialBoundary {
    static var root: URL?

    static func requireSynthetic(_ url: URL) {
        guard let root else { fatalError("synthetic credential root was not configured") }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            fatalError("fixture refused a non-synthetic credential path")
        }
    }
}

enum CodexOfficialProfileReader {
    static func credentialIdentity(codexHomeURL: URL) -> Identity? {
        SyntheticCredentialBoundary.requireSynthetic(codexHomeURL)
        return Identity(accountID: codexHomeURL.lastPathComponent == ".codex" ? "system-id" : "managed-id")
    }
}

struct AccountInfo { var email: String? }

class PerformanceMonitor {
    enum Kind { case appServerQuota }
    static let shared = PerformanceMonitor()
    func begin(_ kind: Kind) -> Int { 0 }
    func end(_ span: Int) {}
}
'''

    reader_wrapper = (
        "\nfinal class CodexUsageReader {\n"
        "    var fakeExecutable: String\n"
        "    init(_ path: String) { fakeExecutable = path }\n"
        + snapshot
        + "\n"
        + read_app_server
        + "\n"
        + failure_message
        + "\n"
        + terminate
        + r'''

    private func resolveCodexExecutablePath() -> String? { fakeExecutable }

    private func parseAccount(_ result: [String: Any]) -> AccountInfo? {
        AccountInfo(email: "managed@example.invalid")
    }

    private func parseRateLimits(_ result: [String: Any], into snapshot: inout AppServerSnapshot) {
        snapshot.quotaReadSucceeded = result["fixtureOK"] as? Bool == true
        let names = [
            "fileStore", "blockedKeysPresent", "allSentinelsPresent",
            "unrelatedPresent", "homeMatches", "disableConfig", "appServerFirst", "stdio",
        ]
        snapshot.limitName = names.map { name in
            "\(name)=\((result[name] as? Bool) == true ? 1 : 0)"
        }.joined(separator: ";")
    }

    private func parseCloudLifetimeTokens(_ result: [String: Any]) -> Int64? { nil }
}
'''
    )

    main = r'''
var failures = 0

func expect(_ value: Bool, _ name: String) {
    print("\(value ? "PASS" : "FAIL"): \(name)")
    if !value { failures += 1 }
}

func observed(_ snapshot: CodexUsageReader.AppServerSnapshot, _ name: String) -> Bool {
    snapshot.limitName?.contains("\(name)=1") == true
}

let synthetic = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: synthetic, withIntermediateDirectories: true)
SyntheticCredentialBoundary.root = synthetic

let realLockHome = synthetic.appendingPathComponent("lock-real", isDirectory: true)
let otherLockHome = synthetic.appendingPathComponent("lock-other", isDirectory: true)
let nested = realLockHome.appendingPathComponent("nested", isDirectory: true)
let symlinkLockHome = synthetic.appendingPathComponent("lock-symlink", isDirectory: true)
try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
try fileManager.createDirectory(at: otherLockHome, withIntermediateDirectories: true)
try fileManager.createSymbolicLink(at: symlinkLockHome, withDestinationURL: realLockHome)

let realLock = CodexCredentialAccessGate.homeLock(forHomePath: realLockHome.path)
let symlinkLock = CodexCredentialAccessGate.homeLock(forHomePath: symlinkLockHome.path)
let dotDotLock = CodexCredentialAccessGate.homeLock(forHomePath: nested.path + "/..")
let otherLock = CodexCredentialAccessGate.homeLock(forHomePath: otherLockHome.path)
expect(realLock === symlinkLock, "real and symlink homes share one lock identity")
expect(realLock === dotDotLock, "normalized dot-dot alias shares one lock identity")
expect(realLock !== otherLock, "different physical homes keep independent locks")
realLock.lock()
realLock.lock()
realLock.unlock()
realLock.unlock()
expect(true, "home lock remains recursively nestable")

for phrase in ["refresh token has expired", "refresh token was already used", "refresh token was revoked"] {
    expect(
        CodexProfileStore.quotaFailureReason(from: ["The synthetic \(phrase)."]) == "oauth-invalidated",
        phrase
    )
}
expect(CodexProfileStore.quotaFailureReason(from: ["401 Unauthorized: access token expired"]) == nil, "generic401 is not permanent")
for code in ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated", "invalid_grant"] {
    expect(
        CodexUsageReader.appServerFailureMessage(
            requestID: 3,
            error: ["message": "safe generic failure", "data": ["code": code]]
        ) == "app-server 3: oauth-invalidated",
        "structured \(code)"
    )
}
expect(
    !CodexUsageReader.appServerFailureMessage(
        requestID: 3,
        error: ["message": "secret-fixture-marker generic failure"]
    ).contains("secret-fixture-marker"),
    "raw app-server messages remain sanitized"
)

let fakeScript = synthetic.appendingPathComponent("fake-app-server.py")
let fakeSource = #"""
#!/usr/bin/env python3
import json
import os
import sys

case = os.environ.get("FIXTURE_CASE", "success")
launch_marker = os.environ.get("AUTH_STABILITY_LAUNCH_MARKER")
if launch_marker:
    open(launch_marker, "w").write("launched")
blocked = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"]
args = sys.argv[1:]

def flag(name):
    return os.environ.get(name) is not None

def report():
    disabled = ["apps", "plugins", "remote_plugin", "recommended_plugins", "skill_search"]
    pairs = list(zip(args, args[1:]))
    return {
        "fixtureOK": True,
        "fileStore": ("-c", 'cli_auth_credentials_store="file"') in pairs,
        "blockedKeysPresent": any(flag(key) for key in blocked),
        "allSentinelsPresent": all(flag(key) for key in blocked),
        "unrelatedPresent": os.environ.get("AUTH_STABILITY_UNRELATED") == "retained",
        "homeMatches": os.environ.get("CODEX_HOME") == os.environ.get("AUTH_STABILITY_EXPECTED_HOME"),
        "disableConfig": all(("--disable", name) in pairs for name in disabled),
        "appServerFirst": len(args) > 0 and args[0] == "app-server",
        "stdio": "--stdio" in args,
    }

for line in sys.stdin:
    request = json.loads(line)
    request_id = request.get("id")
    if request_id == 1:
        if case == "wait-cancel":
            import time
            time.sleep(30)
        if case == "early-exit":
            sys.exit(0)
        if case == "init-error":
            print(json.dumps({"id": 1, "error": {"message": "failed", "data": {"code": "refresh_token_expired"}}}), flush=True)
            sys.exit(0)
        print(json.dumps({"id": 1, "result": {}}), flush=True)
        if case == "partial-eof":
            sys.exit(0)
        if case == "unknown-duplicate":
            print(json.dumps({"id": 999, "error": {"message": "ignored"}}), flush=True)
    elif request_id == 2:
        if case != "partial-cancel":
            print(json.dumps({"id": 2, "result": {"account": {"type": "chatgpt", "email": "managed@example.invalid"}}}), flush=True)
        if case == "unknown-duplicate":
            print(json.dumps({"id": 2, "result": {}}), flush=True)
    elif request_id == 3:
        if case == "missing-result":
            print(json.dumps({"id": 3}), flush=True)
        else:
            print(json.dumps({"id": 3, "result": report()}), flush=True)
        if case == "partial-cancel":
            open(os.environ["AUTH_STABILITY_PARTIAL_READY"], "w").write("ready")
            import time
            time.sleep(30)
        sys.exit(0)
"""#
try fakeSource.write(to: fakeScript, atomically: true, encoding: .utf8)
try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeScript.path)

for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] {
    setenv(key, "synthetic-present", 1)
}
setenv("AUTH_STABILITY_UNRELATED", "retained", 1)

let b1Home = synthetic.appendingPathComponent("b1-home", isDirectory: true)
for name in ["early-exit", "partial-eof", "init-error", "missing-result", "success", "unknown-duplicate"] {
    setenv("FIXTURE_CASE", name, 1)
    setenv("AUTH_STABILITY_EXPECTED_HOME", b1Home.path, 1)
    let context = RuntimeLoadContext(codexHomeDirectory: b1Home, homeDirectory: synthetic)
    let reader = CodexUsageReader(fakeScript.path)
    var messages: [String] = []
    let started = Date()
    let result = reader.readAppServer(context: context, messages: &messages, quotaOnly: true, requestTimeout: 2)
    let elapsed = Date().timeIntervalSince(started)
    expect(elapsed < 1.5, "\(name) returns promptly before response timeout")
    if name == "success" || name == "unknown-duplicate" {
        expect(result.quotaReadSucceeded, "\(name) preserves a valid quota response")
        expect(messages.isEmpty, "\(name) adds no spurious failure")
    } else {
        expect(!result.quotaReadSucceeded, "\(name) cannot infer quota success")
        expect(!messages.isEmpty, "\(name) explains the incomplete response")
    }
}

setenv("FIXTURE_CASE", "wait-cancel", 1)
let cancellation = TokenMonitorCancellation()
let cancelContext = RuntimeLoadContext(codexHomeDirectory: b1Home, homeDirectory: synthetic, quotaCancellation: cancellation)
DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
let cancelStart = Date()
var cancelledMessages: [String] = []
let cancelledResult = CodexUsageReader(fakeScript.path).readAppServer(context: cancelContext, messages: &cancelledMessages, quotaOnly: true, requestTimeout: 20)
expect(Date().timeIntervalSince(cancelStart) < 2, "manual cancellation stops an in-flight quota reader promptly")
expect(!cancelledResult.quotaReadSucceeded, "cancelled quota read cannot report success")

let userHome = synthetic.appendingPathComponent("user-home", isDirectory: true)
let systemHome = userHome.appendingPathComponent(".codex", isDirectory: true)
let systemAlias = synthetic.appendingPathComponent("system-home-alias", isDirectory: true)
try fileManager.createDirectory(at: systemHome, withIntermediateDirectories: true)
try fileManager.createSymbolicLink(at: systemAlias, withDestinationURL: systemHome)
setenv("FIXTURE_CASE", "success", 1)
setenv("AUTH_STABILITY_EXPECTED_HOME", systemAlias.path, 1)

expect(
    selectedReaderGate(context: RuntimeLoadContext(codexHomeDirectory: systemAlias, homeDirectory: userHome)) === CodexCredentialAccessGate.lock,
    "system-home symlink selects the existing global gate"
)
expect(
    selectedReaderGate(context: RuntimeLoadContext(codexHomeDirectory: systemHome, homeDirectory: userHome)) === CodexCredentialAccessGate.lock,
    "direct system-home retains the existing global gate"
)
var normalMessages: [String] = []
let normal = CodexUsageReader(fakeScript.path).readAppServer(
    context: RuntimeLoadContext(codexHomeDirectory: systemAlias, homeDirectory: userHome),
    messages: &normalMessages,
    quotaOnly: true,
    requestTimeout: 2
)
expect(normal.quotaReadSucceeded, "profile-nil API-key branch still reads quota")
expect(!observed(normal, "fileStore"), "profile-nil branch preserves existing app-server config")
expect(observed(normal, "allSentinelsPresent"), "profile-nil branch retains auth environment")
expect(observed(normal, "unrelatedPresent"), "profile-nil branch retains unrelated environment")
expect(observed(normal, "homeMatches"), "profile-nil branch retains intended CODEX_HOME")
expect(observed(normal, "disableConfig"), "profile-nil branch retains quota-only disables")
expect(observed(normal, "appServerFirst") && !observed(normal, "stdio"), "profile-nil branch retains launch shape")

let managedRoot = userHome.appendingPathComponent(".codex-account-manager-next/profiles", isDirectory: true)
let managedHome = managedRoot.appendingPathComponent("managed", isDirectory: true)
try fileManager.createDirectory(at: managedHome, withIntermediateDirectories: true)
setenv("AUTH_STABILITY_EXPECTED_HOME", managedHome.path, 1)
let profile = CodexProfile(
    isSystemProfile: false,
    codexHomeURL: managedHome,
    recordedAccountID: "managed-id",
    recordedEmail: "managed@example.invalid"
)
var managedMessages: [String] = []
let managed = CodexUsageReader(fakeScript.path).readAppServer(
    context: RuntimeLoadContext(codexHomeDirectory: managedHome, homeDirectory: userHome),
    messages: &managedMessages,
    quotaOnly: true,
    refreshingMembershipFor: profile,
    requestTimeout: 2
)
expect(managed.quotaReadSucceeded, "identity-verified membership branch reads quota")
expect(managed.membershipRefreshSucceeded, "identity-verified membership branch confirms account")
expect(observed(managed, "fileStore"), "identity-verified membership branch forces file credential store")
expect(!observed(managed, "blockedKeysPresent"), "identity-verified membership branch removes scoped auth keys")
expect(observed(managed, "unrelatedPresent"), "identity-verified membership branch retains unrelated environment")
expect(observed(managed, "homeMatches"), "identity-verified membership branch retains intended CODEX_HOME")
expect(observed(managed, "disableConfig"), "identity-verified membership branch retains quota-only disables")
expect(observed(managed, "appServerFirst") && !observed(managed, "stdio"), "identity-verified membership branch retains launch shape")

let launchMarker = synthetic.appendingPathComponent("blocked-gate-launch")
setenv("FIXTURE_CASE", "success", 1)
setenv("AUTH_STABILITY_LAUNCH_MARKER", launchMarker.path, 1)
for (name, heldGate) in [
    ("membership global gate", CodexCredentialAccessGate.lock),
    ("membership home gate", CodexCredentialAccessGate.homeLock(forHomePath: managedHome.path)),
] {
    try? fileManager.removeItem(at: launchMarker)
    let entered = DispatchSemaphore(value: 0)
    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        heldGate.lock()
        entered.signal()
        Thread.sleep(forTimeInterval: 0.45)
        heldGate.unlock()
        exited.signal()
    }
    entered.wait()
    let started = ProcessInfo.processInfo.systemUptime
    var gateMessages: [String] = []
    let gateResult = CodexUsageReader(fakeScript.path).readAppServer(
        context: RuntimeLoadContext(codexHomeDirectory: managedHome, homeDirectory: userHome),
        messages: &gateMessages, quotaOnly: true,
        refreshingMembershipFor: profile, requestTimeout: 0.1)
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    exited.wait()
    expect(elapsed < 0.3 && !gateResult.quotaReadSucceeded && !fileManager.fileExists(atPath: launchMarker.path),
        "\(name) consumes the absolute request budget without launching")
}
unsetenv("AUTH_STABILITY_LAUNCH_MARKER")

setenv("FIXTURE_CASE", "partial-cancel", 1)
let partialReady = synthetic.appendingPathComponent("partial-ready")
setenv("AUTH_STABILITY_PARTIAL_READY", partialReady.path, 1)
let partialCancellation = TokenMonitorCancellation()
DispatchQueue.global().async {
    for _ in 0..<200 {
        if fileManager.fileExists(atPath: partialReady.path) {
            Thread.sleep(forTimeInterval: 0.1)
            partialCancellation.cancel()
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    partialCancellation.cancel()
}
var partialMessages: [String] = []
let partialResult = CodexUsageReader(fakeScript.path).readAppServer(
    context: RuntimeLoadContext(codexHomeDirectory: b1Home, homeDirectory: synthetic,
        quotaCancellation: partialCancellation),
    messages: &partialMessages, quotaOnly: true, requestTimeout: 5)
expect(fileManager.fileExists(atPath: partialReady.path), "fake transport sent a partial quota before cancellation")
expect(!partialResult.quotaReadSucceeded && partialMessages.contains(TokenMonitorFailure.cancelled.rawValue),
    "cancelled app-server read cannot publish a parsed partial quota")

print("RESULT: \(failures) failures")
exit(Int32(failures == 0 ? 0 : 1))
'''

    return (
        stubs
        + "\n"
        + models + "\n" + engine + "\n"
        + "\n".join(extract_declaration(usage_models, name) for name in [
            "struct RateWindow:", "struct CreditsInfo:", "struct ResetCreditDetail:"])
        + "\n"
        + gate
        + "\nenum CodexProfileStore {\n"
        + quota_failure
        + "\n}\n"
        + pending
        + "\n"
        + classifier
        + "\n"
        + posix_error
        + "\n"
        + posix_reader
        + "\n"
        + reader_wrapper
        + "\n"
        + gate_selection
        + main
    )


def run(args: list[str], *, cwd: Path, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=timeout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=REPOSITORY_ROOT)
    parser.add_argument("--build-dir", type=Path, default=DEFAULT_BUILD_DIR)
    arguments = parser.parse_args()

    source_root = arguments.source_root.resolve()
    build_dir = arguments.build_dir.resolve()
    target = build_dir / TARGET_NAME
    guard_command = ["python3", str(SCRIPT_DIR / "check-build-target-idle.py"), str(target)]
    guard = run(guard_command, cwd=REPOSITORY_ROOT)
    print(f"idle guard: exit {guard.returncode}")
    if guard.stdout:
        print(guard.stdout, end="")
    if guard.stderr:
        print(guard.stderr, end="", file=sys.stderr)
    if guard.returncode != 0:
        print("compile skipped: target process state was not proved idle", file=sys.stderr)
        return guard.returncode

    try:
        source = fixture_source(source_root)
    except (OSError, RuntimeError) as error:
        print(f"fixture generation failed: {error}", file=sys.stderr)
        return 2

    build_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="auth-stability-") as temporary:
        temporary_root = Path(temporary)
        swift_file = temporary_root / "AuthStabilityFixture.swift"
        swift_file.write_text(source, encoding="utf-8")
        compile_command = [
            "/usr/bin/swiftc",
            "-module-cache-path",
            str(temporary_root / "ModuleCache"),
            str(swift_file),
            "-o",
            str(target),
        ]
        compiled = run(compile_command, cwd=REPOSITORY_ROOT, timeout=90)
        print(f"compile: exit {compiled.returncode}")
        if compiled.stdout:
            print(compiled.stdout, end="")
        if compiled.stderr:
            print(compiled.stderr, end="", file=sys.stderr)
        if compiled.returncode != 0:
            return compiled.returncode

        synthetic_root = temporary_root / "synthetic"
        tested = run([str(target), str(synthetic_root)], cwd=REPOSITORY_ROOT, timeout=45)
        print(tested.stdout, end="")
        if tested.stderr:
            print(tested.stderr, end="", file=sys.stderr)
        return tested.returncode


if __name__ == "__main__":
    sys.exit(main())
