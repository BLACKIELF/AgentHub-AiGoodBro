#!/usr/bin/env python3
"""Exercise the real new-account registration gates with isolated Swift stubs."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / "Sources/CodexUsageWidget/Services"


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


usage = (SERVICE / "UsageStore.swift").read_text()
store = (SERVICE / "CodexProfileStore.swift").read_text()
added = method(usage, "private func verifyAddedProfile(")
# The duplicate-account branch returns before registration intent is saved.
assert added.index("case .duplicateIndependent") < added.index("case .continueIndependent") < added.index("requestDispatchRegistration: true")
# No registration runs until the other throwing profile-save operations finish.
assert added.index("try self.profileStore.selectMonitor") < added.index("self.registerPendingDispatchProfile(after:") < added.index("self.syncProfiles()", added.index("try self.profileStore.selectMonitor"))
record = method(usage, "private func recordOfficialSnapshot(")
assert "if !requestDispatchRegistration" in record
assert record.index("profileStore.record(") < record.index("registerPendingDispatchProfile(after:")
persist = method(store, "func record(\n")
assert "if requestDispatchRegistration, !profile.isSystemProfile, hasBoundCredential" in persist

registration = method(store, "func registerPendingDispatchProfile(for")
attempt = method(usage, "private func registerPendingDispatchProfile(after").replace("private func", "func", 1)
fixture = r'''
import Foundation
enum DispatchParticipationSync {
    enum Change { case registration }
    static func registrationIdentityHash(_ accountID: String) -> String { "fixture-hash-" + accountID }
}
enum DispatchParticipationError: Error { case identityMismatch }
enum FixtureError: Error { case unavailable }
struct Snapshot { let fetchedAt: Date; var accountID: String? = "account" }
struct Profile { let id: String; var isSystemProfile = false; var lastSnapshot: Snapshot?; var dispatchRegistrationPending: Bool?; var dispatchRegistrationIdentity: String? = "fixture-hash-account"; var participates = true }
struct State { var profiles: [Profile] }
struct UsageSnapshot { let refreshedAt: Date; var quotaReadSucceeded = true }
struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ chinese: String, _ english: String) -> String { english }
}
enum DispatchCodeCatalog { static var reloads = 0; static func reload() { reloads += 1 } }
final class ProfileStore {
    var state: State
    var attempts = 0
    var fail = false
    var profiles: [Profile] { state.profiles }
    init(_ profiles: [Profile]) { state = State(profiles: profiles) }
    func applyDispatchSettings(_ change: DispatchParticipationSync.Change, for id: String) throws {
        attempts += 1
        if fail { throw FixtureError.unavailable }
        state.profiles[state.profiles.firstIndex(where: { $0.id == id })!].dispatchRegistrationPending = nil
    }
''' + registration + r'''
}
final class Usage {
    let profileStore: ProfileStore
    var isPreview = false
    var accountManagerMessage: String?
    init(_ store: ProfileStore) { profileStore = store }
''' + attempt + r'''
}
let now = Date()
let current = UsageSnapshot(refreshedAt: now)
func subject(pending: Bool? = true, system: Bool = false, participates: Bool = true) -> Usage {
    Usage(ProfileStore([Profile(id: "new", isSystemProfile: system, lastSnapshot: Snapshot(fetchedAt: now), dispatchRegistrationPending: pending, participates: participates)]))
}
let success = subject()
success.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(success.profileStore.attempts == 1 && success.profileStore.profiles[0].dispatchRegistrationPending == nil)
let reloads = DispatchCodeCatalog.reloads
success.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(success.profileStore.attempts == 1 && DispatchCodeCatalog.reloads == reloads)
let optedOut = subject(participates: false)
optedOut.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(!optedOut.profileStore.profiles[0].participates)
let existing = subject(pending: nil)
existing.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(existing.profileStore.attempts == 0)
let system = subject(system: true)
system.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(system.profileStore.attempts == 0)
let stale = subject()
stale.registerPendingDispatchProfile(after: UsageSnapshot(refreshedAt: now.addingTimeInterval(-1)), profileID: "new")
precondition(stale.profileStore.attempts == 0 && stale.profileStore.profiles[0].dispatchRegistrationPending == true)
let pendingQuota = subject()
pendingQuota.registerPendingDispatchProfile(after: UsageSnapshot(refreshedAt: now, quotaReadSucceeded: false), profileID: "new")
precondition(pendingQuota.profileStore.attempts == 0 && pendingQuota.profileStore.profiles[0].dispatchRegistrationPending == true)
pendingQuota.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(pendingQuota.profileStore.attempts == 1)
let preview = subject()
preview.isPreview = true
preview.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(preview.profileStore.attempts == 0)
let missing = subject()
missing.registerPendingDispatchProfile(after: current, profileID: "absent")
precondition(missing.profileStore.attempts == 0)
let failed = subject()
failed.profileStore.fail = true
failed.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(failed.profileStore.profiles.count == 1 && failed.profileStore.profiles[0].lastSnapshot?.fetchedAt == now)
precondition(failed.profileStore.profiles[0].dispatchRegistrationPending == true && failed.accountManagerMessage != nil)
failed.profileStore.fail = false
failed.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(failed.profileStore.attempts == 2 && failed.profileStore.profiles[0].dispatchRegistrationPending == nil)
let replaced = subject()
replaced.profileStore.state.profiles[0].lastSnapshot = Snapshot(fetchedAt: now, accountID: "replacement")
replaced.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(replaced.profileStore.attempts == 0 && replaced.profileStore.profiles[0].dispatchRegistrationPending == true)
let missingBinding = subject()
missingBinding.profileStore.state.profiles[0].dispatchRegistrationIdentity = nil
missingBinding.registerPendingDispatchProfile(after: current, profileID: "new")
precondition(missingBinding.profileStore.attempts == 0 && missingBinding.profileStore.profiles[0].dispatchRegistrationPending == true)
print("PASS: new-account registration gates, delayed quota, retry, no duplicate enrollment, opt-out and failure retention (isolated stubs).")
'''

sdk = os.environ.get("CAMNEXT_CHECK_SDK_PATH") or subprocess.check_output(
    ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
with tempfile.TemporaryDirectory(prefix="new-account-registration-") as temporary:
    work = Path(temporary)
    script = work / "fixture.swift"
    script.write_text(fixture)
    subprocess.run(["xcrun", "swift", "-target", platform.machine() + "-apple-macos13.0",
                    "-sdk", sdk, "-module-cache-path", str(work / "ModuleCache"), str(script)], check=True)
print("PASS: add-flow and subsequent-refresh wiring contracts.")
