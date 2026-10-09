#!/usr/bin/env python3
"""Offline dead-owner warm-up recovery. No live profiles, provider or application."""
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / 'Sources/CodexUsageWidget/Services'

def declaration(source, needle):
    start = source.index(needle)
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{': depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0: return source[start:index + 1]
    raise ValueError(needle)

interop = ast.parse((ROOT / 'tests/test-dispatch-activity-interop.py').read_text())
boundaries = next(ast.literal_eval(node.value) for node in interop.body if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'BOUNDARIES' for t in node.targets)).split('@main struct Fixture')[0]
profiles = (SERVICE / 'CodexProfileStore.swift').read_text()
profile_method = declaration(profiles, '    func recordInterruptedWarmUp(')
model = declaration(profiles, 'struct CodexWarmUpRequest:') + '\n' + declaration(profiles, 'struct CodexWarmUpAttempt:')
store = (SERVICE / 'DispatchActivityStore.swift').read_text()
assert store.count('kill(ownerPID, 0)') == 2
# Only process evidence is injectable, in the frozen fixture copy. All tuple,
# time, shared-file locking/write and profile CAS logic is production source.
store = store.replace('kill(ownerPID, 0)', 'FixtureProbe.kill(ownerPID, 0)')
save_guard = 'guard written == data.count, fsync(fd) == 0,'
assert store.count(save_guard) == 1
store = store.replace(save_guard, 'guard written == data.count, (FixtureProbe.failRegistrySave ? false : fsync(fd) == 0),')
with tempfile.TemporaryDirectory(prefix='aigoodbro-warmup-orphan-') as temporary:
    folder = Path(temporary)
    (folder / 'DispatchActivityStore.swift').write_text(store)
    (folder / 'Boundaries.swift').write_text(boundaries + model + '''
struct FixtureSnapshot { let accountID: String? }
struct CodexProfile {
    var id: String; var recordedAccountKey: String; var warmUpRequest: CodexWarmUpRequest?
    var lastSnapshot: FixtureSnapshot?; var lastWarmUpSucceeded: Bool? = false
    var lastWarmUpFailureReason: String? = "pending"; var lastWarmUpAt: Date?
    var warmUpHistory: [CodexWarmUpAttempt]?; var identityMatches = true
    var codexHomeURL: URL { URL(fileURLWithPath: "/synthetic-unused") }
    func matchesRecordedCredential(_ identity: Bool) -> Bool { identityMatches && identity }
}
enum CodexOfficialProfileReader { static func credentialIdentity(codexHomeURL: URL) -> Bool { true } }
final class CodexProfileStore {
    struct State { var profiles: [CodexProfile] }
    enum WarmUpStateError: Error { case unverifiedIdentityOrState }
    var state: State; var failSave = false; var saveCount = 0; var onSave: (() throws -> Void)?
    init(_ profiles: [CodexProfile]) { state = State(profiles: profiles) }
    func mutateState(_ mutation: () throws -> Bool) throws {
        let old = state
        do {
            if try mutation() {
                if failSave { throw WarmUpStateError.unverifiedIdentityOrState }
                try onSave?(); saveCount += 1
            }
        } catch { state = old; throw error }
    }
''' + profile_method + '\n}\n')
    fixture = ROOT / 'tests/WarmUpOrphanFixture.swift'
    subprocess.run(['swiftc', '-module-cache-path', str(folder / 'module-cache'), '-parse-as-library', str(folder / 'Boundaries.swift'), str(folder / 'DispatchActivityStore.swift'), str(fixture), '-o', str(folder / 'fixture')], check=True)
    subprocess.run([str(folder / 'fixture'), str(folder / 'registry')], check=True)
