#!/usr/bin/env python3
"""Compile the real proxy quota refresh flow with synthetic homes and readers."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/CodexUsageWidget/Services/UsageStore.swift').read_text()
start = source.index('    func refreshLocalProxyQuotas(')
end = source.index('    private func updateCodexForegroundState(', start)
flow = source[start:end]
stubs = r'''
import Foundation
struct CodexProfile {
    let id: String
    var isSystemProfile = false
    let codexHomeURL: URL
    var recordedAccountKey: String { id }
    var lastSnapshot: Account? = Account(accountID: "fixture")
}
struct Account { let accountID: String }
struct Snapshot { let home: URL; let managedID: String?; var engineLimits: Int? = nil }
final class TokenMonitorCancellation { var isCancelled = false }
enum WidgetLanguage { static func storedOrAutomatic() -> Self { .fixture }; case fixture; func text(_ a: String, _ b: String) -> String { b } }
struct RuntimeLoadContext {
    let home: URL
    static func live(statisticsPreference: Int, codexHomeDirectory: URL) -> Self { Self(home: codexHomeDirectory) }
}
enum ReaderFixture {
    static let entered = DispatchSemaphore(value: 0)
    static let release = DispatchSemaphore(value: 0)
    static var held = false
}
struct CodexUsageReader {
    func readQuotaSnapshot(context: RuntimeLoadContext, quotaOnly: Bool, messages: inout [String], managedProfile: CodexProfile?, cancellation: TokenMonitorCancellation, selectLimitsProvider: Int) -> Snapshot {
        if ReaderFixture.held { ReaderFixture.entered.signal(); _ = ReaderFixture.release.wait(timeout: .now()+5) }
        return Snapshot(home: context.home, managedID: managedProfile?.id)
    }
    func finishingLoad(appServer: Snapshot, messages: [String], context: RuntimeLoadContext, quotaOnly: Bool) -> Snapshot { appServer }
}
@MainActor final class ProfileStore {
    var homes: [String: URL] = [:]
    var recorded: [(String, Snapshot)] = []
    func effectiveCredentialHome(for id: String) -> URL? { homes[id] }
    func record(_ snapshot: Snapshot, for id: String) throws { recorded.append((id,snapshot)) }
}
@MainActor final class UsageStore {
    var profiles: [CodexProfile] = []
    var isPreview = false, hasStarted = true, isLoggingIn = false, isLaunchingCodex = false, isAccountSwitchTransactionActive = false
    var localProxyQuotaPendingIDs: Set<String> = []
    var localProxyQuotaRefreshes: [String:TokenMonitorCancellation] = [:]
    var localProxyQuotaRetry: DispatchWorkItem?
    var statisticsPreference = 0, engineLimitsSelector = 0
    var engineLimitsByProfileID: [String:Int] = [:]
    var accountManagerMessage = ""
    let profileStore = ProfileStore()
    func observeOfficialQuotaChanges(_ snapshot: Snapshot, profileID: String) {}
    func syncProfiles() {}
'''
tests = r'''
}
@main struct Fixture {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        preconditionFailure("quota refresh fixture timed out")
    }
    @MainActor static func main() async {
        let usage = UsageStore()
        let desktop = URL(fileURLWithPath: "/fixture/.codex")
        let enrolled = URL(fileURLWithPath: "/fixture/managed/enrolled")
        let peer = URL(fileURLWithPath: "/fixture/managed/peer")
        usage.profiles = [CodexProfile(id:"enrolled",codexHomeURL:enrolled),CodexProfile(id:"peer",codexHomeURL:peer),CodexProfile(id:"system",isSystemProfile:true,codexHomeURL:desktop)]
        usage.profileStore.homes = ["enrolled":desktop,"peer":peer,"system":desktop]
        usage.refreshLocalProxyQuotas(profileIDs:["enrolled","peer","system"])
        await wait { usage.localProxyQuotaRefreshes.isEmpty }
        let records = usage.profileStore.recorded
        precondition(records.count == 2)
        let own = records.first { $0.0 == "enrolled" }!.1
        let other = records.first { $0.0 == "peer" }!.1
        precondition(own.home == desktop && own.managedID == nil, "Desktop quota must use current effective session")
        precondition(other.home == peer && other.managedID == "peer", "other enrolled identity must keep its own home")
        precondition(!records.contains { $0.0 == "system" }, "proxy must not record the system profile")
        usage.profileStore.recorded = []
        ReaderFixture.held = true
        usage.refreshLocalProxyQuotas(profileIDs:["enrolled"])
        let entered = await Task.detached { ReaderFixture.entered.wait(timeout:.now()+2) == .success }.value
        precondition(entered)
        usage.profileStore.homes["enrolled"] = enrolled
        ReaderFixture.release.signal()
        await wait { usage.localProxyQuotaRefreshes.isEmpty }
        precondition(usage.profileStore.recorded.isEmpty, "changed effective identity must discard in-flight result")
        print("PASS: actual proxy refresh reads enrolled Desktop's effective home, preserves peer isolation, excludes system-profile writes and discards changed identity")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='agb-proxy-quota-') as directory:
    folder = Path(directory)
    swift = folder / 'Fixture.swift'
    swift.write_text(stubs + flow + tests)
    binary = folder / 'fixture'
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
