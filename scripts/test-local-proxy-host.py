#!/usr/bin/env python3
"""Offline native proxy host fixtures. Never reads live profiles or starts the app/helper."""
from pathlib import Path
import subprocess, tempfile, os, sys
root=Path(__file__).resolve().parent.parent
service=root/'Sources/CodexUsageWidget/Services'
stubs=r'''
import Foundation
import Combine
import Darwin
struct CreditBalancePresentation: Equatable {}
struct CodexQuotaWindowSnapshot: Equatable { var usedPercent: Double; var resetsAt: Date? }
struct CodexAccountSnapshot: Equatable { var quotaReadSucceeded: Bool? = true; var planType:String? = nil; var creditBalance:String? = nil; var creditBalanceUnlimited:Bool? = nil; var accountID: String? = "account-fixture"; var email: String? = "fixture@example.invalid"; var fetchedAt: Date; var fiveHour: CodexQuotaWindowSnapshot?; var sevenDay: CodexQuotaWindowSnapshot?; var monthly: CodexQuotaWindowSnapshot? = nil }
struct CodexCredentialIdentity: Equatable { let email: String; let accountID: String }
struct CodexProfile: Equatable { let id: String; var isSystemProfile=false; var lastSnapshot: CodexAccountSnapshot?; var lastQuotaReadFailureAt: Date?=nil; var isDispatchPriorityEnabled=false; var codexHomeURL: URL { DispatchParticipationPaths.supportDirectory().appendingPathComponent("credentials/"+id).resolvingSymlinksInPath() }; var recordedAccountKey:String { lastSnapshot?.email ?? id }; func matchesRecordedCredential(_ identity:CodexCredentialIdentity?) -> Bool { identity?.email == lastSnapshot?.email && identity?.accountID == lastSnapshot?.accountID } }
enum CodexCredentialAccessGate { static let lock=NSRecursiveLock(); static func homeLock(forHomePath:String)->NSRecursiveLock { lock } }
enum WidgetLanguage { case fixture; static func storedOrAutomatic()->Self { .fixture }; func text(_ zh:String,_ en:String)->String { en } }
enum HubAccountTaskPhase { case maintenance,starting,running,cancelRequested,uncertain,awaitingAcceptance,succeeded,failed,cancelled,unavailable }
struct HubAccountTaskStatus { let phase:HubAccountTaskPhase; let updatedAt:Date? }
enum HubWarmUpAvailability { case idle,busy,unavailable }
enum HubConsoleModel { static var fixtureAvailability: HubWarmUpAvailability = .unavailable; static var fixtureOnWarmUp:(()->Void)?; static func warmUpAvailability(for:String,excludingLocalLease:String?,deadline:TimeInterval? = nil) async ->HubWarmUpAvailability { fixtureOnWarmUp?(); return fixtureAvailability } }
enum HubAccountTaskStatusResolver { static func canonicalAlias(_ value:String)->String { value.lowercased() } }
enum DispatchCodeCatalog { static func alias(for:String)->String? { "fixture-alias" } }
enum AccountDisplay { static func profileName(_ p:CodexProfile,allProfiles:[CodexProfile])->String { p.id }; static func number(for p:CodexProfile,in profiles:[CodexProfile])->Int? { profiles.firstIndex(where:{$0.id == p.id}).map{$0+1} } }
struct CodexExecutionPreference { enum Model:String,CaseIterable { case fixture="fixture-model" } }
@MainActor final class UsageStore:ObservableObject { @Published var profiles:[CodexProfile]; var isPreview=true; var refreshCount=0; init(_ profiles:[CodexProfile]) { self.profiles=profiles }; func refreshLocalProxyQuotas(profileIDs:Set<String>){refreshCount += 1}; func creditBalancePresentation(for:CodexProfile)->CreditBalancePresentation { .init() }; func availableResetCredits(for:CodexProfile)->Int? { nil } }
enum CodexExecutable { static func path()->String? { "/usr/bin/true" } }
enum LocalProxyFixtureRuntime { static var allowStopSignals = true; static var afterReserve:(()->Void)?; static var afterRunning:(()->Void)?; static var helper:URL { DispatchParticipationPaths.supportDirectory().appendingPathComponent("fixture-helper") } }
struct DispatchParticipationPaths { static func supportDirectory()->URL { URL(fileURLWithPath:ProcessInfo.processInfo.environment["PROXY_FIXTURE_ROOT"]!) }; static let snapshotFileName="fixture.json"; var hubConfig:URL; static func live(snapshot:URL)throws->Self { throw LocalProxyFailure.unavailable } }
'''
with tempfile.TemporaryDirectory(prefix='aigoodbro-proxy-host-fixture-') as temporary:
    folder=Path(temporary)
    text=(service/'DispatchParticipationSync.swift').read_text()
    a=text.index('    static func readBoundedRegularFile('); b=text.index('\n    private static func read(',a)
    bounded='enum DispatchParticipationError:Error { case fileAccess }\nstruct DispatchParticipationSync {\n'+next(x for x in text.splitlines() if 'static let maximumConfigurationBytes =' in x)+'\n'+text[a:b]+'\n}\n'
    profiles=(service/'CodexProfileStore.swift').read_text()
    a=profiles.index('    static func credentialIdentity(fromAuthData');b=profiles.index('    private static func parseDate(',a)
    identity='enum CodexOfficialProfileReader {\n'+profiles[a:b]+'\n}\n'
    presentation=(root/'Sources/CodexUsageWidget/Domain/WorkspacePresentation.swift').read_text()
    presentation=presentation[:presentation.index('/// Presentation only:')]
    rate_window='struct RateWindow { let usedPercent:Double; let windowDurationMins:Int; let resetsAt:Date?; var remainingPercent:Double { 100-usedPercent } }\n'
    (folder/'Stubs.swift').write_text(stubs+bounded+identity+rate_window+presentation)
    files=[folder/'Stubs.swift',root/'Sources/CodexUsageWidget/Domain/LocalProxyQueue.swift',service/'CodexCredentialTransaction.swift',service/'DispatchActivityStore.swift',service/'LocalProxyBridge.swift',service/'LocalProxyNetworkSettings.swift',service/'LocalProxyQueueStore.swift',root/'scripts/test-local-proxy-host.swift']
    # Credential transaction fixture only uses its actual read and gate routines.
    raw=(service/'CodexCredentialTransaction.swift').read_text();raw=raw[:raw.index('    private static func tokens(')]+'}\n'
    (folder/'Credential.swift').write_text(raw);files[2]=folder/'Credential.swift'
    # Freeze inputs before compile; other authorized agents may edit integration code.
    frozen=[]
    for source in files:
        target=folder/source.name
        if target != source:
            content=source.read_text()
            if source.name == 'LocalProxyQueueStore.swift':
                # Test-only visibility, without changing production APIs or behavior.
                content=content.replace('private(set)', '').replace('private ', '')
                content=content.replace('LocalProxyNetworkSettings.load()', 'LocalProxyNetworkSettings.resolve([:])')
                begin=content.index('    func verifiedHelper() throws -> URL {')
                end=content.index('    func randomKey()',begin)
                content=content[:begin]+'    func verifiedHelper() throws -> URL { LocalProxyFixtureRuntime.helper }\n'+content[end:]
                content=content.replace('if child.isRunning { child.terminate() }','if child.isRunning && LocalProxyFixtureRuntime.allowStopSignals { child.terminate() }')
                content=content.replace('if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }','if child.isRunning && LocalProxyFixtureRuntime.allowStopSignals { _ = kill(child.processIdentifier, SIGKILL) }')
                content=content.replace('0..<40 {','0..<(LocalProxyFixtureRuntime.allowStopSignals ? 40 : 0) {').replace('0..<20 {','0..<(LocalProxyFixtureRuntime.allowStopSignals ? 20 : 0) {')
                # Pause only the copied fixture source after the real registry write
                # and before the detached task returns to the main actor.
                content=content.replace('let id = try await Task.detached {\n                try DispatchActivityStore.live.reserveProxy(',
                    'let id = try await Task.detached {\n                let reserved = try DispatchActivityStore.live.reserveProxy(')
                content=content.replace('admissionDeadline: admissionDeadline, enforceFreshness: request.receivedAt != nil)\n            }.value',
                    'admissionDeadline: admissionDeadline, enforceFreshness: request.receivedAt != nil)\n                LocalProxyFixtureRuntime.afterReserve?()\n                return reserved\n            }.value')
                content=content.replace('profileID: lease.profileID, state: "running")\n            }.value',
                    'profileID: lease.profileID, state: "running")\n                LocalProxyFixtureRuntime.afterRunning?()\n            }.value')
            target.write_text(content)
        frozen.append(target)
    files=frozen
    subprocess.run(['python3',str(root/'scripts/check-build-target-idle.py'),str(folder/'fixture')],check=True)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(folder/'modules'),*[str(f) for f in files],'-o',str(folder/'fixture')],check=True)
    subprocess.run([str(folder/'fixture')],env={**os.environ,'PROXY_FIXTURE_ROOT':str(folder/'support'),'PROXY_FIXTURE_PYTHON':sys.executable,'PROXY_FIXTURE_INTEROP':str(root/'scripts/test-local-proxy-host-interop.py')},check=True)
