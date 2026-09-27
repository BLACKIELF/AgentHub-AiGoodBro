#!/usr/bin/env python3
"""Exercise UsageStore's real scoped refresh methods with an offline quota reader."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parent.parent
source = (root/'Sources/CodexUsageWidget/Services/UsageStore.swift').read_text()
a = source.index('    func refreshLocalProxyQuotas(')
b = source.index('    private func updateCodexForegroundState(', a)
methods = source[a:b].replace('private func ', 'func ')
fixture = r'''
import Foundation
struct Snapshot { var accountID: String?; let fetchedAt: Date }
struct Profile { let id: String; var isSystemProfile = false; var lastSnapshot: Snapshot?; var codexHomeURL: URL { URL(fileURLWithPath: "/fixture/" + id) }; var recordedAccountKey: String { id } }
final class TokenMonitorCancellation { private let lock = NSLock(); private var stopped = false; var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }; func cancel() { lock.lock(); stopped = true; lock.unlock() } }
struct RuntimeLoadContext { let id: String; let now: Date; static func live(statisticsPreference: Int, codexHomeDirectory: URL) -> Self { .init(id: codexHomeDirectory.lastPathComponent, now: Date()) } }
struct Quota { let accountID: String; let engineLimits: Int? = nil }
final class ReaderState { static let live = ReaderState(); let lock = NSLock(); var delays: [String: Double] = [:]; var counts: [String: Int] = [:]; var active = 0; var peak = 0; func read(_ id: String) { lock.lock(); counts[id, default: 0] += 1; active += 1; peak = max(peak, active); let delay = delays[id] ?? 0.02; lock.unlock(); Thread.sleep(forTimeInterval: delay); lock.lock(); active -= 1; lock.unlock() }; func count(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[id, default: 0] } }
struct CodexUsageReader { func readQuotaSnapshot(context: RuntimeLoadContext, quotaOnly: Bool, messages: inout [String], managedProfile: Profile, cancellation: TokenMonitorCancellation, selectLimitsProvider: Int) -> Quota { precondition(quotaOnly); ReaderState.live.read(context.id); return Quota(accountID: context.id) }; func finishingLoad(appServer: Quota, messages: [String], context: RuntimeLoadContext, quotaOnly: Bool) -> Snapshot { Snapshot(accountID: appServer.accountID, fetchedAt: context.now) } }
final class ProfileStore { var saved: [String: Snapshot] = [:]; func record(_ snapshot: Snapshot, for id: String) throws { if saved[id].map({ $0.fetchedAt > snapshot.fetchedAt }) == true { return }; saved[id] = snapshot } }
enum WidgetLanguage { case fixture; static func storedOrAutomatic() -> Self { .fixture }; func text(_ zh: String, _ en: String) -> String { en } }
final class FixtureStore {
 var isPreview = false; var hasStarted = true; var isLoggingIn = false; var isLaunchingCodex = false; var isAccountSwitchTransactionActive = false
 var localProxyQuotaPendingIDs = Set<String>(); var localProxyQuotaRefreshes: [String: TokenMonitorCancellation] = [:]; var localProxyQuotaRetry: DispatchWorkItem?
 var profiles: [Profile]; let statisticsPreference = 0; let engineLimitsSelector = 0; let profileStore = ProfileStore(); var engineLimitsByProfileID: [String: Int] = [:]; var accountManagerMessage = ""
 init(_ ids: [String]) { profiles = ids.map { Profile(id: $0, lastSnapshot: Snapshot(accountID: $0, fetchedAt: .distantPast)) } }
 func observeOfficialQuotaChanges(_ snapshot: Snapshot, profileID: String) {}
 func syncProfiles() { for i in profiles.indices { if let saved = profileStore.saved[profiles[i].id] { profiles[i].lastSnapshot = saved } } }
'''+methods+r'''
}
@main struct Tests {
 @MainActor static func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
 @MainActor static func main() async {
  let reads = ReaderState.live
  reads.delays = ["fast": 0.01, "slow": 0.5, "repeat": 0.15, "stopped": 0.15]
  let store = FixtureStore(["fast", "slow"])
  let started = Date(); store.refreshLocalProxyQuotas(profileIDs: ["fast", "slow"])
  await pause(0.12)
  precondition(store.profileStore.saved["fast"] != nil && store.profileStore.saved["slow"] == nil, "fast account must publish before unrelated slow account")
  precondition(store.profileStore.saved["fast"]!.fetchedAt >= started && store.profileStore.saved["fast"]!.fetchedAt < Date(), "preserve actual read timestamp")
  let repeatStore = FixtureStore(["repeat"])
  repeatStore.refreshLocalProxyQuotas(profileIDs: ["repeat"]); await pause(0.04)
  repeatStore.refreshLocalProxyQuotas(profileIDs: ["repeat"]); repeatStore.refreshLocalProxyQuotas(profileIDs: ["repeat"])
  await pause(0.5); precondition(reads.count("repeat") == 2, "refresh during read coalesces into one pending observation")
  let blocked = FixtureStore(["blocked"]); blocked.isAccountSwitchTransactionActive = true
  blocked.refreshLocalProxyQuotas(profileIDs: ["blocked"]); await pause(0.05)
  precondition(reads.count("blocked") == 0, "account operation blocks read")
  blocked.isAccountSwitchTransactionActive = false; await pause(1.1)
  precondition(blocked.profileStore.saved["blocked"] != nil, "blocked request is retained")
  let stopped = FixtureStore(["stopped"]); stopped.refreshLocalProxyQuotas(profileIDs: ["stopped"]); await pause(0.03)
  stopped.hasStarted = false; stopped.localProxyQuotaRefreshes.values.forEach { $0.cancel() }; stopped.localProxyQuotaRefreshes.removeAll(); await pause(0.2)
  precondition(stopped.profileStore.saved.isEmpty, "late completion cannot publish after stop")
  let many = FixtureStore((0..<9).map { "many-\($0)" }); reads.peak = 0
  many.refreshLocalProxyQuotas(profileIDs: Set(many.profiles.map(\.id))); await pause(0.3)
  precondition(reads.peak <= 4 && many.profileStore.saved.count == 9, "bounded concurrency completes all accounts")
  let identities = FixtureStore(["system", "other"]); identities.profiles[0].isSystemProfile = true
  identities.refreshLocalProxyQuotas(profileIDs: ["system", "other", "missing"]); await pause(0.1)
  precondition(reads.count("system") == 0 && identities.profileStore.saved.count == 1, "central and unknown profiles excluded")
  print("PASS: 8 scoped quota refresh checks; no accounts, credentials or network")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aigoodbro-proxy-quota-') as temporary:
    p = Path(temporary); (p/'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
    subprocess.run([str(p/'fixture')],check=True,timeout=15)
