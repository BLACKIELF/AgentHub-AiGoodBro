#!/usr/bin/env python3
"""Offline production client launcher checks; no real Keychain, network or GUI."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parent.parent
STUBS = r'''import AppKit
import Foundation

enum AntigravityProxyProvider: String, CaseIterable { case antigravity, claude, kimi, xai }
enum AntigravityProxyFailure: Error { case unavailable, connection, storage }
enum TerminalLauncherError: Error { case launchFailed }
struct TerminalAppLauncher { static func shellQuote(_ x: String) -> String { "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'" } }
struct TerminalLaunchSession { let scriptURL: URL; static func create(command: String) throws -> Self { fatalError("GUI must not open") } }
enum CodexExecutable { static func bundledPath() -> String? { ProcessInfo.processInfo.environment["FIXTURE_CLI"] }; static func path() -> String? { nil } }
struct AntigravityProxyKeychain { func read(_ name: String) throws -> Data? { guard name == "client-key" else { fatalError("provider credentials must not be read") }; return Data(String(repeating: "fixture_", count: 5).utf8) } }
enum DispatchParticipationPaths { static func supportDirectory() -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_ROOT"]!) } }
enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let d = try Data(contentsOf: url); guard d.count <= maximumBytes else { throw AntigravityProxyFailure.storage }; return d
    }
    static func writePrivateProxyPreferences(_ data: Data, at url: URL) throws { try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
}
struct TokenMonitorURLSessionTransport {
    struct Response { let statusCode: Int; let body: Data }
    init(configuration: URLSessionConfiguration) {}
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> Response {
        precondition(request.url?.host == "127.0.0.1")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "fixture_", count: 5))
        return Response(statusCode: 200, body: Data(#"{"object":"list","data":[{"id":"fixture-model"}]}"#.utf8))
    }
}
@main struct Fixture {
    static func main() async throws {
        let root = DispatchParticipationPaths.supportDirectory()
        let profile = root.appendingPathComponent("profiles/agy")
        try ProviderProxyClientLauncher.prepareAgyProfile(profile)
        let file = profile.appendingPathComponent("antigravity-cli/settings.json")
        let bytes = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        precondition(object["modelProvider"] as? String == "gemini")
        precondition(!String(decoding: bytes, as: UTF8.self).contains("fixture_"))
        let link = root.appendingPathComponent("profiles/linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: profile)
        do { try ProviderProxyClientLauncher.prepareAgyProfile(link); fatalError("symlink accepted") } catch {}
        let result = await ProviderProxyClientLauncher.runCodex(provider: .claude, model: "fixture-model", workingDirectory: root)
        precondition(result == 0, "isolated child environment or arguments incorrect")
        let invalid = await ProviderProxyClientLauncher.runCodex(provider: .claude, model: "missing-model", workingDirectory: root)
        precondition(invalid == 1, "unlisted model must not launch")
        do { _ = try await ProviderProxyClientLauncher.catalog(endpoint: "https://example.invalid", key: "fixture"); fatalError("remote endpoint accepted") } catch {}
        print("PASS: production client launcher isolates credentials/profile, rejects symlink/remote endpoint/unknown model; mock catalog and Keychain only")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="agb-client-", dir="/private/tmp") as folder:
    folder = Path(folder)
    (folder / "stubs.swift").write_text(STUBS)
    fake = folder / "fake-codex"
    fake.write_text("#!/bin/sh\n[ \"$CODEX_HOME\" = \"$PWD/proxy-clients/codex-claude\" ] || exit 31\n[ -n \"$AIGOODBRO_PROXY_KEY\" ] || exit 32\n[ -z \"${OPENAI_API_KEY-}\" ] || exit 33\n[ \"$1\" = -m ] && [ \"$2\" = fixture-model ] || exit 34\ncase \"$*\" in *fixture_fixture*) exit 35;; esac\nexit 0\n")
    fake.chmod(0o700)
    env = dict(os.environ, FIXTURE_ROOT=str(folder), FIXTURE_CLI=str(fake), OPENAI_API_KEY="must-not-inherit")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-sdk", sdk, "-module-cache-path", str(folder / "cache"), str(ROOT / "Sources/CodexUsageWidget/Services/ProviderProxyClientLauncher.swift"), str(folder / "stubs.swift"), "-o", str(folder / "fixture")], check=True)
    subprocess.run([str(folder / "fixture")], env=env, check=True)
