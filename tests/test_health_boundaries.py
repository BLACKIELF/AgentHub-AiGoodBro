#!/usr/bin/env python3
"""Pure local regression checks for health and companion release boundaries."""

import hashlib
import json
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class HealthBoundaryTests(unittest.TestCase):
    @staticmethod
    def swift_toolchain(work):
        sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk')
        if not sdk.is_dir():
            sdk = Path(subprocess.run(
                ['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                check=True, capture_output=True, text=True,
            ).stdout.strip())
        architecture = subprocess.run(
            ['uname', '-m'], check=True, capture_output=True, text=True,
        ).stdout.strip()
        return [
            'swiftc', '-target', f'{architecture}-apple-macos13.0',
            '-sdk', str(sdk), '-module-cache-path', str(work / 'ModuleCache'),
        ]

    def test_bounded_process_runtime_edges(self):
        with tempfile.TemporaryDirectory(prefix='camnext-health-') as raw:
            work = Path(raw)
            shutil.copy2(
                ROOT / 'Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift',
                work / 'BoundedLocalProcess.swift',
            )
            cc_source = (ROOT / 'Sources/CodexUsageWidget/Services/CCSwitchUsageReader.swift').read_text()
            token_start = cc_source.index('func customTokenCount(')
            token_end = cc_source.index('\n\nstruct CCSwitchUsageSummary', token_start)
            (work / 'TokenBoundary.swift').write_text('import Foundation\n\n' + cc_source[token_start:token_end] + '\n')
            (work / 'main.swift').write_text(
                r'''
import Darwin
import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

let shell = URL(fileURLWithPath: "/bin/sh")
require(customTokenCount(fromWanText: "922337203685477.6") == nil, "overflowing Double converted to Int64")
require(customTokenCount(fromWanText: "922337203685477.4") != nil, "valid near-boundary Double was rejected")
require(customTokenCount(fromWanText: "inf") == nil, "non-finite Double was accepted")
let plain = try BoundedLocalProcess.run(executable: shell, arguments: ["-c", "printf ok"])
require(String(data: plain, encoding: .utf8) == "ok", "EOF output mismatch")
let allowedExit = try BoundedLocalProcess.run(
    executable: shell,
    arguments: ["-c", "printf seven; exit 7"],
    allowedExitCodes: [7]
)
require(String(data: allowedExit, encoding: .utf8) == "seven", "allowed direct-child exit was lost")
do {
    _ = try BoundedLocalProcess.run(executable: shell, arguments: ["-c", "exit 7"])
    fatalError("disallowed direct-child exit was accepted")
} catch BoundedLocalProcessError.failed {}

let descriptorFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try Data("ordinary parent descriptor fixture\n".utf8).write(to: descriptorFile)
defer { try? FileManager.default.removeItem(at: descriptorFile) }
let parentDescriptor = descriptorFile.path.withCString { Darwin.open($0, O_RDONLY) }
require(parentDescriptor >= 0, "could not open parent descriptor fixture")
defer { Darwin.close(parentDescriptor) }
let descriptorProbe = try BoundedLocalProcess.run(
    executable: shell,
    arguments: [
        "-c",
        "if eval \"IFS= read -r inherited <&$1\" 2>/dev/null; then printf leaked; else printf isolated; fi",
        "fixture",
        String(parentDescriptor),
    ]
)
require(String(data: descriptorProbe, encoding: .utf8) == "isolated", "unrelated parent descriptor leaked")
require(Darwin.lseek(parentDescriptor, 0, SEEK_SET) == 0, "parent descriptor was closed or changed")
var parentBuffer = [UInt8](repeating: 0, count: 64)
let parentCount = parentBuffer.withUnsafeMutableBytes {
    Darwin.read(parentDescriptor, $0.baseAddress, $0.count)
}
require(
    parentCount > 0 && String(decoding: parentBuffer.prefix(parentCount), as: UTF8.self) == "ordinary parent descriptor fixture\n",
    "parent descriptor stopped working"
)

func requireRejectedDescendant(_ script: String, _ label: String) throws {
    let started = Date()
    let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pidFile) }
    do {
        _ = try BoundedLocalProcess.run(
            executable: shell,
            arguments: ["-c", script, "fixture", pidFile.path],
            timeout: 1
        )
        fatalError("\(label) descendant was incorrectly accepted as complete")
    } catch BoundedLocalProcessError.failed {}
    require(Date().timeIntervalSince(started) < 1.5, "\(label) descendant cleanup was not bounded")
    let descendantPID = Int32((try String(contentsOf: pidFile)).trimmingCharacters(in: .whitespacesAndNewlines))!
    var descendantGone = false
    for _ in 0..<50 {
        if Darwin.kill(descendantPID, 0) != 0, errno == ESRCH { descendantGone = true; break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    require(descendantGone, "\(label) descendant survived process-group cleanup")
}

try requireRejectedDescendant("sleep 30 & echo $! > \"$1\"; exit 0", "inherited-stdout")
try requireRejectedDescendant("sleep 30 >/dev/null 2>&1 & echo $! > \"$1\"; exit 0", "detached-stdio")

let timeoutStarted = Date()
do {
    _ = try BoundedLocalProcess.run(executable: shell, arguments: ["-c", "sleep 2"], timeout: 0.05)
    fatalError("timeout was accepted")
} catch BoundedLocalProcessError.timedOut {}
require(Date().timeIntervalSince(timeoutStarted) < 1.5, "timeout cleanup was not bounded")

do {
    _ = try BoundedLocalProcess.run(
        executable: shell,
        arguments: ["-c", "yes x | head -c 200000"],
        maximumOutputBytes: 1024
    )
    fatalError("oversized output was accepted")
} catch BoundedLocalProcessError.outputTooLarge {}

do {
    _ = try BoundedLocalProcess.run(executable: shell, arguments: ["-c", "true"], maximumOutputBytes: -1)
    fatalError("negative output limit was accepted")
} catch BoundedLocalProcessError.failed {}

print("bounded process health checks passed")
'''
            )
            binary = work / 'health-boundaries'
            subprocess.run(
                self.swift_toolchain(work) + [
                    str(work / 'BoundedLocalProcess.swift'), str(work / 'TokenBoundary.swift'),
                    str(work / 'main.swift'),
                    '-o', str(binary),
                ],
                check=True,
                cwd=ROOT,
            )
            completed = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('bounded process health checks passed', completed.stdout)

    def test_grok_usage_overflow_and_scan_limits(self):
        with tempfile.TemporaryDirectory(prefix='camnext-grok-health-') as raw:
            work = Path(raw)
            cc_source = (ROOT / 'Sources/CodexUsageWidget/Services/CCSwitchUsageReader.swift').read_text()
            sync = (ROOT / 'Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift').read_text()
            read_start = sync.index('    static func readBoundedRegularFile(')
            read_end = sync.index('\n    private static func read(', read_start)
            (work / 'GrokReader.swift').write_text(
                cc_source[:cc_source.index('func customTokenCount(')]
                + '\nenum DispatchParticipationError: Error { case fileAccess }\n'
                + 'enum DispatchParticipationSync { static let maximumConfigurationBytes = 1048576\n'
                + sync[read_start:read_end] + '\n}\n'
                + cc_source[cc_source.index('enum GrokUsageReader {'):]
            )
            (work / 'main.swift').write_text(r'''
import Darwin
import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let manager = FileManager.default
let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? manager.removeItem(at: home) }
let session = home.appendingPathComponent(".grok/sessions/work/session")
try manager.createDirectory(at: session, withIntermediateDirectories: true)
let updates = session.appendingPathComponent("updates.jsonl")
func write(_ text: String) throws { try Data(text.utf8).write(to: updates) }
func read(_ limits: GrokUsageReader.Limits = .init()) -> Int64? {
    GrokUsageReader.lifetimeTokens(homeDirectory: home, limits: limits)
}
try write("{\"usage\":{\"inputTokens\":5,\"outputTokens\":8,\"totalTokens\":13}}\nnot json\n{\"nested\":[{\"usage\":{\"inputTokens\":20,\"totalTokens\":20}}]}")
require(read() == 33, "ordinary nested usage or final line was lost")
try write("{\"usage\":{\"inputTokens\":9223372036854775807,\"outputTokens\":0,\"totalTokens\":9223372036854775807}}")
require(read() == Int64.max, "exact Int64 maximum was rejected")
try write("{\"usage\":{\"inputTokens\":9223372036854775807,\"outputTokens\":1,\"totalTokens\":9223372036854775807}}")
require(read() == nil, "input plus output overflow was accepted")
try write("{\"usage\":{\"inputTokens\":9223372036854775807,\"totalTokens\":9223372036854775807}}\n{\"usage\":{\"inputTokens\":1,\"totalTokens\":1}}")
require(read() == nil, "aggregate overflow was accepted")
for value in ["-1", "true", "1.5", "18446744073709551615", "\"5\""] {
    try write("{\"usage\":{\"inputTokens\":\(value),\"totalTokens\":1}}")
    require(read() == nil, "invalid token count was accepted")
}
let normal = "{\"usage\":{\"inputTokens\":5,\"outputTokens\":8,\"totalTokens\":13}}\n"
try write(normal)
require(read(.init(maximumFileBytes: 16)) == nil, "oversized regular file was accepted")
require(read(.init(maximumLineBytes: 16)) == nil, "oversized line was accepted")
require(read(.init(maximumEntries: 1)) == nil, "incomplete directory scan was accepted")
require(read(.init(timeout: .leastNonzeroMagnitude)) == nil, "elapsed scan deadline was accepted")
let second = home.appendingPathComponent(".grok/sessions/work/second")
try manager.createDirectory(at: second, withIntermediateDirectories: true)
try Data(normal.utf8).write(to: second.appendingPathComponent("updates.jsonl"))
require(read() == 26, "multiple sessions were not counted")
require(read(.init(maximumTotalBytes: normal.utf8.count + 1)) == nil, "total byte budget returned a partial total")
try manager.removeItem(at: second)
let ordinary = home.appendingPathComponent("ordinary-fixture.jsonl")
try Data(normal.utf8).write(to: ordinary)
try manager.removeItem(at: updates)
try manager.createSymbolicLink(at: updates, withDestinationURL: ordinary)
require(read() == nil, "symbolic usage file was followed")
try manager.removeItem(at: updates)
require(Darwin.mkfifo(updates.path, 0o600) == 0, "could not create FIFO fixture")
let started = ProcessInfo.processInfo.systemUptime
require(read() == nil, "FIFO usage file was accepted")
require(ProcessInfo.processInfo.systemUptime - started < 1, "FIFO read blocked")
try manager.removeItem(at: updates)
try write(String(repeating: "{\"nested\":", count: 35) + normal.trimmingCharacters(in: .newlines) + String(repeating: "}", count: 35))
require(read() == nil, "unbounded nested usage search was accepted")
try manager.removeItem(at: session)
try manager.createSymbolicLink(at: session, withDestinationURL: second)
require(read() == nil, "symbolic session directory was accepted")
let fallback = [AgentTokenShare(name: "grokbuild", tokens: 90)]
require(replacingGrokSessionShare(in: fallback, with: read()) == fallback, "failed local scan replaced existing usage")
print("Grok usage health checks passed")
''')
            binary = work / 'grok-health'
            subprocess.run(
                self.swift_toolchain(work) + [str(work / 'GrokReader.swift'), str(work / 'main.swift'), '-o', str(binary)],
                check=True, cwd=ROOT,
            )
            completed = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('Grok usage health checks passed', completed.stdout)

    def test_usage_number_and_epoch_boundaries(self):
        # Exercise only the shared read-only conversion leaves, not reset code.
        source = (ROOT / 'Sources/CodexUsageWidget/Services/CodexUsageReader.swift').read_text()
        leaves = []
        for name in ('summedTokenCounts', 'intValue', 'int64Value', 'doubleValue', 'dateFromEpoch'):
            start = source.index('private func ' + name + '(')
            end = source.index('\n}\n', start) + 3
            leaves.append(source[start:end])
        with tempfile.TemporaryDirectory(prefix='camnext-number-boundary-') as raw:
            work = Path(raw)
            checks = r'''
func require(_ value: @autoclosure () -> Bool) {
    if !value() { fatalError("numeric boundary failed") }
}
for invalid: Any in [true, false, Double.nan, Double.infinity, -Double.infinity, 1.5, Double(Int64.max), NSNumber(value: UInt64.max)] {
    require(intValue(invalid) == nil)
    require(int64Value(invalid) == nil)
}
require(summedTokenCounts([Int64.max, 1]) == nil)
require(summedTokenCounts([Int64.max]) == Int64.max)
require(summedTokenCounts([3, 7]) == 10)
require(summedTokenCounts([-1]) == nil)
require(int64Value(NSNumber(value: Int64.max)) == Int64.max)
require(int64Value(String(Int64.max)) == Int64.max)
require(int64Value(NSNumber(value: Int64.min)) == Int64.min)
require(intValue(42.0) == 42)
require(doubleValue(true) == nil)
require(doubleValue("NaN") == nil)
require(doubleValue("Infinity") == nil)
require(doubleValue("1.25") == 1.25)
require(dateFromEpoch(Double.infinity) == nil)
require(dateFromEpoch(1e30) == nil)
require(dateFromEpoch(1_700_000_000_000)?.timeIntervalSince1970 == 1_700_000_000)
print("usage numeric leaves passed")
'''
            main = work / 'main.swift'
            main.write_text('import Foundation\nimport CoreFoundation\n' + '\n'.join(leaves) + checks)
            binary = work / 'number-boundary'
            subprocess.run(self.swift_toolchain(work) + [str(main), '-o', str(binary)], check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=5)

    def test_cache_reads_delegate_to_bounded_regular_file(self):
        usage = (ROOT / 'Sources/CodexUsageWidget/Services/CodexUsageReader.swift').read_text()
        inference = (ROOT / 'Sources/CodexUsageWidget/Services/ModelInferenceHistoryStore.swift').read_text()

        skill = usage[usage.index('private func skillStaticInfo(for path: String)'):usage.index(
            '\n    private func cachedSessionUsage(', usage.index('private func skillStaticInfo(for path: String)')
        )]
        local = usage[usage.index('private func readPersistentLocalAnalyticsCache()'):usage.index(
            '\n    private func persistentSessionUsageCache()', usage.index('private func readPersistentLocalAnalyticsCache()')
        )]
        session = usage[usage.index('private func persistentSessionUsageCache()'):usage.index(
            '\n    private func writePersistentLocalAnalyticsCache(', usage.index('private func persistentSessionUsageCache()')
        )]
        load = inference[inference.index('static func load('):inference.index('\n    @discardableResult', inference.index('static func load('))]

        self.assertIn('.resolvingSymlinksInPath()', skill)
        self.assertIn('maximumBytes: 4 * 1_024 * 1_024', skill)
        self.assertIn('DispatchParticipationSync.readBoundedRegularFile(', skill)
        self.assertIn('DispatchParticipationSync.readBoundedRegularFile(', local)
        self.assertIn('DispatchParticipationSync.readBoundedRegularFile(', session)
        self.assertIn('DispatchParticipationSync.readBoundedRegularFile(', load)
        self.assertNotIn('Data(contentsOf:', skill + local + session + load)
        self.assertGreaterEqual(
            usage.count('guard Int64(data.count) <= Self.maximumPersistentCacheBytes else { return }'),
            2,
        )

    def test_update_store_rejects_late_callbacks(self):
        with tempfile.TemporaryDirectory(prefix='camnext-update-') as raw:
            work = Path(raw)
            shutil.copy2(
                ROOT / 'Sources/CodexUsageWidget/Services/AppUpdateStore.swift',
                work / 'AppUpdateStore.swift',
            )
            (work / 'Boundaries.swift').write_text(
                r'''
import Combine
import Foundation

enum AppUpdateStatus: Equatable { case idle, disabled, checking, upToDate, updateAvailable, failed }
struct AppRelease: Equatable {}
struct AppAsset: Equatable {}
struct AppUpdateResult: Equatable {
    let status: AppUpdateStatus
    let checkedAt: Date
    let currentVersion: String
    let latestRelease: AppRelease?
    let preferredAsset: AppAsset?
    let errorMessage: String?
    static func idle() -> Self { .init(status: .idle, checkedAt: Date(), currentVersion: "0", latestRelease: nil, preferredAsset: nil, errorMessage: nil) }
    var preferredOpenURL: URL? { nil }
    var latestVersionLabel: String? { latestRelease == nil ? nil : "1.0.1" }
}
enum AppVersion { static func current() -> String { "1.0.0" } }
protocol AppUpdateChecking {
    func check(currentVersion: String, includePrereleases: Bool, force: Bool, completion: @escaping (AppUpdateResult) -> Void)
}
final class GitHubReleaseUpdateChecker: AppUpdateChecking {
    func check(currentVersion: String, includePrereleases: Bool, force: Bool, completion: @escaping (AppUpdateResult) -> Void) {}
}
final class AppSettings: ObservableObject {
    @Published var automaticUpdateChecksEnabled = true
    var skippedUpdateVersion: String?
    init(defaults: UserDefaults) {}
    func skipUpdateVersion(_ version: String) { skippedUpdateVersion = version }
}
'''
            )
            (work / 'main.swift').write_text(
                'import Foundation\nif !AppUpdateStore.selfTest() { fatalError("update callback lifecycle failed") }\nprint("update callback checks passed")\n'
            )
            binary = work / 'update-boundaries'
            subprocess.run(
                self.swift_toolchain(work) + [
                    str(work / 'Boundaries.swift'), str(work / 'AppUpdateStore.swift'),
                    str(work / 'main.swift'), '-framework', 'AppKit', '-framework', 'Combine',
                    '-o', str(binary),
                ],
                check=True, cwd=ROOT,
            )
            completed = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('update callback checks passed', completed.stdout)

    def test_audit_archive_runtime_boundaries(self):
        with tempfile.TemporaryDirectory(prefix='camnext-audit-') as raw:
            work = Path(raw)
            for relative in (
                'Sources/CodexUsageWidget/Services/AccountAutomationAuditStore.swift',
                'Sources/CodexUsageWidget/Services/PrivateLocalFileStore.swift',
            ):
                shutil.copy2(ROOT / relative, work / Path(relative).name)
            (work / 'Boundaries.swift').write_text(
                r'''
import Darwin
import Foundation

enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if allowMissing && errno == ENOENT { return nil }
            throw NSError(domain: "fixture", code: 1)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumBytes else {
            throw NSError(domain: "fixture", code: 2)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while result.count <= maximumBytes {
            let remaining = maximumBytes - result.count + 1
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { return result }
            result.append(chunk)
        }
        throw NSError(domain: "fixture", code: 3)
    }
}
'''
            )
            (work / 'main.swift').write_text(
                'import Foundation\nif !AccountAutomationAuditStoreSelfTest.run() { fatalError("audit archive test failed") }\n'
            )
            binary = work / 'audit-boundaries'
            subprocess.run(
                self.swift_toolchain(work) + [
                    str(work / 'Boundaries.swift'), str(work / 'PrivateLocalFileStore.swift'),
                    str(work / 'AccountAutomationAuditStore.swift'), str(work / 'main.swift'),
                    '-o', str(binary),
                ],
                check=True, cwd=ROOT,
            )
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)

    def test_companion_skill_is_an_explicit_public_allowlist(self):
        with tempfile.TemporaryDirectory(prefix='camnext-companion-') as raw:
            resources = Path(raw) / 'Resources'
            resources.mkdir()
            subprocess.run(
                [
                    'python3', 'scripts/prepare-companion-resources.py',
                    '--resources', str(resources), '--arch', 'arm64',
                ],
                check=True,
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            packaged = {
                path.relative_to(resources).as_posix()
                for path in resources.rglob('*') if path.is_file()
            }
            namespace = runpy.run_path(str(ROOT / 'scripts/prepare-companion-resources.py'))
            expected = {f'CompanionSkill/{path}' for path in namespace['SKILL_FILES']}
            expected.add('SupportTools/next_runtime_setup.py')
            self.assertEqual(packaged, expected)
            self.assertFalse(any('runtime-paths.json' in path or 'runtime-python.txt' in path for path in packaged))
            entrypoint = resources / 'CompanionSkill/SKILL.md'
            for relative in re.findall(r'\]\((references/[^)#]+)', entrypoint.read_text()):
                self.assertTrue((entrypoint.parent / relative).is_file(), relative)

    def test_hub_source_manifest_matches_owned_sources(self):
        hub = ROOT / 'Companion/Hub'
        manifest = json.loads((hub / 'SOURCE.json').read_text())
        declared = set()
        for entry in manifest['sourceFiles']:
            path = hub / entry['path']
            declared.add(entry['path'])
            self.assertTrue(path.is_file(), entry['path'])
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), entry['sha256'], entry['path'])
        actual = {
            path.relative_to(hub).as_posix()
            for path in hub.rglob('*')
            if path.is_file() and path.name not in {'LICENSE', 'SOURCE.json'}
        }
        self.assertEqual(declared, actual)

    def test_release_wrapper_forces_and_verifies_companion(self):
        wrapper = (ROOT / 'scripts/build-release-artifacts.sh').read_text()
        makefile = (ROOT / 'Makefile').read_text()
        self.assertIn('BUNDLE_COMPANION=1', wrapper)
        self.assertIn('CompanionHub/manifest.json', wrapper)
        self.assertIn("'runtime-paths.json', 'runtime-python.txt'", wrapper)
        self.assertIn('BUNDLE_COMPANION ?= 1', makefile)
        self.assertIn('--include-hub', makefile)


if __name__ == '__main__':
    unittest.main(verbosity=2)
