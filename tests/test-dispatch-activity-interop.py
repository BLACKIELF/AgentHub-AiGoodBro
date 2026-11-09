#!/usr/bin/env python3
"""macOS-only Python/Swift shared-file contract and real flock interoperability."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import next_dispatch_activity as activity

# Standalone boundaries replace only application dependencies. The production
# DispatchActivityStore itself is compiled unchanged and reads/writes real files.
BOUNDARIES = '''
import Foundation
import Darwin
enum HubAccountTaskPhase { case maintenance, starting, running, cancelRequested, uncertain, awaitingAcceptance, succeeded, failed, cancelled, unavailable }
struct HubAccountTaskStatus { let phase: HubAccountTaskPhase; let updatedAt: Date? }
enum DispatchParticipationError: Error { case fileAccess }
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL { fatalError("Live directory must not be used by this fixture") }
}
enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw NSError(domain: "fixture", code: 1) }
        return data
    }
}
@main struct Fixture {
    static func main() {
        let store = DispatchActivityStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        do {
            if CommandLine.arguments[2] == "--audit" {
                var failures: [String] = []
                do {
                    let ids = try store.reserveMaintenance(accounts: [("different-account", "  FIXTURE-ALIAS-FIXTURE-A  ")])
                    failures.append("batch-alias-conflict")
                    for id in ids { try store.finishMaintenance(id, succeeded: false) }
                } catch DispatchActivityStore.Failure.busy {}
                let lease = DispatchActivityStore.Lease(
                    leaseId: "fixture", ownerThreadId: "fixture-owner", taskId: "fixture-task",
                    accountKey: DispatchActivityStore.hash("a"), aliasKey: DispatchActivityStore.hash("a"),
                    projectKey: DispatchActivityStore.hash("p"), code: nil, route: "maintenance",
                    state: "cancel_requested", createdAt: 100, updatedAt: 100, heartbeatDueAt: 220)
                if lease.taskStatus(now: Date(timeIntervalSince1970: 101)).phase != .cancelRequested {
                    failures.append("maintenance-cancel-mapping")
                }
                let phases: [(String, HubAccountTaskPhase)] = [
                    ("preparing", .starting), ("starting", .starting), ("running", .running),
                    ("cancel_requested", .cancelRequested), ("uncertain", .uncertain),
                    ("awaiting_acceptance", .awaitingAcceptance), ("accepted", .succeeded),
                    ("rejected", .failed), ("failed", .failed), ("cancelled", .cancelled)
                ]
                for route in ["direct", "hub", "terminal", "warmup", "maintenance"] {
                    for (state, phase) in phases {
                        for (updated, now) in [(100.0, 100.0), (100, 220), (100, 221), (105, 100), (106, 100)] {
                            let value = DispatchActivityStore.Lease(
                                leaseId: "fixture", ownerThreadId: "fixture-owner", taskId: "fixture-task",
                                accountKey: lease.accountKey, aliasKey: lease.aliasKey, projectKey: lease.projectKey,
                                code: nil, route: route, state: state, createdAt: 90, updatedAt: updated, heartbeatDueAt: 220)
                            let stale = value.occupied && (now > 220 || updated > now + 5)
                            let maintenance = ["warmup", "maintenance"].contains(route) && ["preparing", "starting", "running"].contains(state)
                            let expected: HubAccountTaskPhase = stale ? .uncertain : maintenance ? .maintenance : phase
                            if value.taskStatus(now: Date(timeIntervalSince1970: now)).phase != expected {
                                failures.append("state-time-mapping")
                            }
                        }
                    }
                }
                let journalURL = store.directory.appendingPathComponent(DispatchActivityStore.issueName)
                let journalBefore = try Data(contentsOf: journalURL)
                for (id, phase, summary, code) in [
                    ("bad id", "observed", "Safe observation", Optional<String>.none),
                    ("fixture", "bad phase", "Safe observation", nil),
                    ("fixture", "observed", "", nil),
                    ("fixture", "observed", "Safe observation", "AB"),
                    ("fixture", "observed", "https:" + "//fixture.invalid/hook", nil)
                ] {
                    do {
                        try store.appendIssue(id: id, phase: phase, summary: summary, code: code)
                        failures.append("journal-invalid-field")
                    } catch DispatchActivityStore.Failure.invalidState {}
                }
                if try Data(contentsOf: journalURL) != journalBefore { failures.append("invalid-journal-mutated") }
                if !DispatchActivityStoreSelfTest.run() { failures.append("store-self-test") }
                print(failures.isEmpty ? "AUDIT-PASSED" : failures.joined(separator: ","))
                return
            }
            let alias = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "fixture-alias-" + CommandLine.arguments[2]
            let id = try store.reserveWarmUp(account: CommandLine.arguments[2], alias: alias)
            try store.finishWarmUp(id, succeeded: true)
            try store.appendIssue(id: "interop", phase: "verified", summary: "Swift fixture appended", code: "B")
            print("WROTE")
        } catch DispatchActivityStore.Failure.busy {
            print("BUSY")
        } catch {
            print("FAILED")
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='next-activity-interop-') as temporary:
    root = Path(temporary)
    source = root / 'Fixture.swift'
    source.write_text(BOUNDARIES)
    binary = root / 'fixture'
    compile_result = subprocess.run(
        ['xcrun', 'swiftc', '-parse-as-library', str(ROOT / 'Sources/CodexUsageWidget/Services/DispatchActivityStore.swift'),
         str(source), '-o', str(binary)], capture_output=True, text=True,
        env={**os.environ, 'CLANG_MODULE_CACHE_PATH': str(root / 'module-cache')})
    if compile_result.returncode:
        print('Interop fixture compilation failed; no live state was used')
        detail = compile_result.stderr.replace(str(ROOT), '<repo>').replace(str(root), '<temp>').strip()
        if detail:
            print(detail)
        raise SystemExit(1)
    registry = activity.Registry(root / 'state')
    lease = registry.reserve(account_key=activity.digest('fixture-a'), alias_key=activity.digest('fixture-alias-fixture-a'),
                             code='A', project=activity.digest('fixture-project'), owner='fixture-owner',
                             task='fixture-task', route='direct')
    # Unknown process fields are preserved by Swift's schema-preserving mutation.
    registry.update(lease['leaseId'], 'fixture-owner', childPID=99999, childPIDBirth=activity.digest('birth'))
    def invoke(account):
        return subprocess.run([str(binary), str(registry.root), account], capture_output=True, text=True, check=True).stdout.strip()
    assert invoke('fixture-a') == 'BUSY', 'Swift failed to honor Python account reservation'
    same_alias = subprocess.run([str(binary), str(registry.root), 'different-account', 'fixture-alias-fixture-a'], capture_output=True, text=True, check=True)
    assert same_alias.stdout.strip() == 'BUSY', 'Swift failed to honor Python alias reservation'
    with registry.lock():
        assert invoke('fixture-b') == 'BUSY', 'Swift failed to honor Python system file lock'
    assert invoke('fixture-b') == 'WROTE'
    leases = registry.read()['leases']
    assert len(leases) == 2
    assert leases[0]['leaseId'] == lease['leaseId'] and leases[0]['childPIDBirth'] == activity.digest('birth')
    assert leases[1]['state'] == 'accepted' and leases[1]['accountKey'] == activity.digest('fixture-b')
    registry.issue(issue_id='interop', component='skill', phase='verified', summary='Python fixture appended')
    lines = [json.loads(line) for line in (registry.root / activity.ISSUE_NAME).read_text().splitlines()]
    assert len(lines) == 2 and all('dateShanghai' in line for line in lines)
    assert lines[0]['code'] == 'B'
    audit = subprocess.run([str(binary), str(registry.root), '--audit'], capture_output=True, text=True, check=True)
    assert audit.stdout.strip().splitlines()[-1] == 'AUDIT-PASSED', audit.stdout.strip()
    print('Interop passed: shared account reservation, system lock, schema preservation, two-language journal append, alias normalization, state/time matrix, journal validation, store self-test')
