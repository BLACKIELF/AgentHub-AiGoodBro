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
@MainActor final class UsageStore:ObservableObject { @Published var profiles:[CodexProfile]; var isPreview=true; var refreshCount=0; var onRefresh:((Set<String>)->Void)?; init(_ profiles:[CodexProfile]) { self.profiles=profiles }; func refreshLocalProxyQuotas(profileIDs:Set<String>){refreshCount += 1; onRefresh?(profileIDs)}; func creditBalancePresentation(for:CodexProfile)->CreditBalancePresentation { .init() }; func availableResetCredits(for:CodexProfile)->Int? { nil } }
enum CodexExecutable { static func path()->String? { "/usr/bin/true" }; static func bundledPath()->String? { nil } }
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
                old_reserve='''            let id = try await Task.detached {
                try DispatchActivityStore.live.reserveProxy(
                    account: account, alias: alias, runID: request.runID, requestID: request.requestID, profileID: profileID, childPID: pid,
                    admissionDeadline: admissionDeadline, enforceFreshness: request.receivedAt != nil)
            }.value'''
                assert content.count(old_reserve) == 1
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
    sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
    target=f'{os.uname().machine}-apple-macos13.0'
    compiler=['xcrun','swiftc','-O','-g','-target',target,'-sdk',sdk,'-swift-version','5','-parse-as-library','-module-cache-path',str(folder/'modules')]
    subprocess.run([*compiler,*[str(f) for f in files],'-o',str(folder/'fixture')],check=True)
    fixture_env={**os.environ,'PROXY_FIXTURE_TRACE':'1','PROXY_FIXTURE_ROOT':str(folder/'support'),'PROXY_FIXTURE_PYTHON':sys.executable,'PROXY_FIXTURE_INTEROP':str(root/'scripts/test-local-proxy-host-interop.py')}
    try:
        subprocess.run([str(folder/'fixture')],env=fixture_env,check=True)
    except subprocess.CalledProcessError as failure:
        if failure.returncode < 0:
            probe=folder/'TaskWaitProbe.swift'
            probe.write_text(r'''
import Foundation
import Darwin
enum ProbeError: Error { case synthetic }
func work(_ fail: Bool) throws -> String {
    Thread.sleep(forTimeInterval: 0.02)
    if fail { throw ProbeError.synthetic }
    return "ok"
}
@main struct TaskWaitProbe {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        let useResult = CommandLine.arguments.contains("result")
        let fail = CommandLine.arguments.contains("--fail")
        print("PROXY_TASK_PROBE: before await")
        do {
            let value: String
            if useResult {
                let task: Task<Result<String, Error>, Never> = Task.detached { Result { try work(fail) } }
                value = try await task.value.get()
            } else {
                let task: Task<String, Error> = Task.detached { try work(fail) }
                value = try await task.value
            }
            precondition(!fail && value == "ok")
            print("PROXY_TASK_PROBE: success")
        } catch {
            precondition(fail && error is ProbeError)
            print("PROXY_TASK_PROBE: expected synthetic failure")
        }
    }
}
''')
            try:
                subprocess.run([*compiler,str(probe),'-o',str(folder/'task-wait-probe')],timeout=60,check=True)
                for mode in [[],['--fail'],['result'],['result','--fail']]:
                    print(f'PROXY_TASK_PROBE: mode={mode}',flush=True)
                    outcome=subprocess.run([str(folder/'task-wait-probe'),*mode],env=fixture_env,timeout=10,check=False)
                    print(f'PROXY_TASK_PROBE: exit={outcome.returncode}',flush=True)
            except (OSError,subprocess.CalledProcessError,subprocess.TimeoutExpired) as probe_failure:
                print(f'PROXY_TASK_PROBE: unavailable: {type(probe_failure).__name__}',flush=True)
            # Rerun only this disposable fixture under LLDB to locate a native
            # crash. Keep a fresh synthetic registry and preserve the failure.
            print('PROXY_HOST_CRASH: collecting isolated fixture backtrace',flush=True)
            diagnostic_env={**fixture_env,'PROXY_FIXTURE_ROOT':str(folder/'diagnostic-support')}
            try:
                subprocess.run(['xcrun','lldb','--no-lldbinit','--batch','-o','run','-k','thread backtrace all','-k','register read x0 x1 x2 x3 x4','--',str(folder/'fixture')],env=diagnostic_env,timeout=180,check=False)
            except (OSError,subprocess.TimeoutExpired) as diagnostic_failure:
                print(f'PROXY_HOST_CRASH: backtrace unavailable: {type(diagnostic_failure).__name__}',flush=True)
        raise
