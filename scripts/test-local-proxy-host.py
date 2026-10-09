#!/usr/bin/env python3
"""Offline native proxy host fixtures. Never reads live profiles or starts the app/helper."""
from pathlib import Path
import subprocess, tempfile, os, sys, hashlib, json, shutil
root=Path(__file__).resolve().parent.parent
service=root/'Sources/CodexUsageWidget/Services'
dynamic_http='--dynamic-http-only' in sys.argv

def declaration(source, needle):
    start=source.index(needle); opening=source.index('{',start); depth=0
    for index in range(opening,len(source)):
        if source[index]=='{': depth+=1
        elif source[index]=='}':
            depth-=1
            if depth==0: return source[start:index+1]
    raise ValueError(needle)
stubs=r'''
import Foundation
import Combine
import Darwin
struct CreditBalancePresentation: Equatable {}
// Peripheral payloads are unused by the real quota presentation helper.
struct LocalUsage: Equatable {}
struct TaskBoard: Equatable {}
struct CodexQuotaWindowSnapshot: Equatable { var usedPercent: Double; var resetsAt: Date? }
struct CodexAccountSnapshot: Equatable { var quotaReadSucceeded: Bool? = true; var planType:String? = nil; var creditBalance:String? = nil; var creditBalanceUnlimited:Bool? = nil; var accountID: String? = "account-fixture"; var email: String? = "fixture@example.invalid"; var fetchedAt: Date; var fiveHour: CodexQuotaWindowSnapshot?; var sevenDay: CodexQuotaWindowSnapshot?; var monthly: CodexQuotaWindowSnapshot? = nil }
struct CodexCredentialIdentity: Equatable { let email: String; let accountID: String }
struct CodexOfficialProfileSnapshot: Equatable { var planType: String? }
struct CodexProfile: Equatable { let id: String; var isSystemProfile=false; var lastSnapshot: CodexAccountSnapshot?; var lastQuotaReadFailureAt: Date?=nil; var isDispatchPriorityEnabled=false; var officialProfile:CodexOfficialProfileSnapshot?=nil; var proTierMultiplier:Int?=nil; var codexHomeURL: URL { DispatchParticipationPaths.supportDirectory().appendingPathComponent("credentials/"+id).resolvingSymlinksInPath() }; var recordedAccountKey:String { lastSnapshot?.email ?? id }; func matchesRecordedCredential(_ identity:CodexCredentialIdentity?) -> Bool { identity?.email == lastSnapshot?.email && identity?.accountID == lastSnapshot?.accountID } }
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
enum LocalProxyFixtureRuntime { static var allowStopSignals = true; static var failPreferenceRename=false; static var failFirstTerminalCleanup=false; static var failActivityCommit=false; static var afterReserve:(()->Void)?; static var afterRunning:(()->Void)?; static var helper:URL { DispatchParticipationPaths.supportDirectory().appendingPathComponent("fixture-helper") } }
struct DispatchParticipationPaths { static func supportDirectory()->URL { URL(fileURLWithPath:ProcessInfo.processInfo.environment["PROXY_FIXTURE_ROOT"]!) }; static let snapshotFileName="fixture.json"; var hubConfig:URL; static func live(snapshot:URL)throws->Self { throw LocalProxyFailure.unavailable } }
'''
if dynamic_http:
    # Peripheral fixture bindings only; the native queue, IPC and registry stay production code.
    stubs=stubs.replace('static func alias(for:String)->String? { "fixture-alias" }',
                        'static func alias(for id:String)->String? { "fixture-" + id }')
    stubs=stubs.replace('DispatchParticipationPaths.supportDirectory().appendingPathComponent("fixture-helper")',
                        'URL(fileURLWithPath:ProcessInfo.processInfo.environment["PROXY_FIXTURE_HELPER"]!)')
with tempfile.TemporaryDirectory(prefix='aigoodbro-proxy-host-fixture-', dir=os.environ['PROXY_DYNAMIC_HTTP_EVIDENCE'] if dynamic_http else None) as temporary:
    folder=Path(temporary)
    if dynamic_http:
        # Foundation presents /private paths through /var and /tmp aliases. The
        # workspace evidence root lets the real Go checks use a link-free path.
        folder=folder.resolve()
    text=(service/'DispatchParticipationSync.swift').read_text()
    a=text.index('    static func readBoundedRegularFile('); b=text.index('\n    private static func read(',a)
    bounded='enum DispatchParticipationError:Error { case fileAccess }\nstruct DispatchParticipationSync {\n'+next(x for x in text.splitlines() if 'static let maximumConfigurationBytes =' in x)+'\n'+text[a:b]+'\n}\n'
    profiles=(service/'CodexProfileStore.swift').read_text()
    a=profiles.index('    static func credentialIdentity(fromAuthData');b=profiles.index('    private static func parseDate(',a)
    writer_start=text.index('    /// Proxy preferences commit')
    writer_end=text.index('    private static func removeAtomicallyIfMatching(',writer_start)
    writer=text[writer_start:writer_end]
    expectation=text[text.index('    private enum ReplacementExpectation'):text.index('    let paths:',text.index('    private enum ReplacementExpectation'))]
    writer=writer.replace('Darwin.rename(source, destination)', '(LocalProxyFixtureRuntime.failPreferenceRename ? String(cString: destination) + \".blocked\" : String(cString: destination)).withCString { Darwin.rename(source, $0) }')
    bounded=bounded.replace('case fileAccess', 'case fileAccess, writeFailed, concurrentChange, rollbackFailed')
    bounded=bounded[:-2]+expectation+'    enum Checkpoint { case beforeAtomicSwap(Int), beforeMismatchRestore(Int), afterMismatchRestore(Int) }\n'+writer+'}\n'
    identity='enum CodexOfficialProfileReader {\n'+profiles[a:b]+'\n}\n'
    # Use the actual production plan and multiplier projection in routing checks.
    identity+='extension CodexProfile {\n'+declaration(profiles,'    var displayedProTierMultiplier: Int?')+'\n'+declaration(profiles,'    var resolvedPlanType: String?')+'\n}\n'
    presentation=(root/'Sources/CodexUsageWidget/Domain/WorkspacePresentation.swift').read_text()
    presentation=presentation[:presentation.index('/// Presentation only:')]
    usage_models=(root/'Sources/CodexUsageWidget/Domain/UsageModels.swift').read_text()
    quota_models='\n'.join(declaration(usage_models,'struct '+name+':') for name in [
        'RateWindow','AccountInfo','ResetCreditDetail','CreditsInfo','UsageSnapshot'])+'\n'
    (folder/'Stubs.swift').write_text(stubs+bounded+identity+quota_models+presentation)
    files=[folder/'Stubs.swift',root/'Sources/CodexUsageWidget/Domain/LocalProxyQueue.swift',service/'CodexCredentialTransaction.swift',service/'DispatchActivityStore.swift',service/'LocalProxyBridge.swift',service/'LocalProxyNetworkSettings.swift',service/'LocalProxyQueueStore.swift',root/'scripts/test-local-proxy-host.swift']
    if dynamic_http:
        files[-1]=root/'scripts/LocalProxyDynamicHTTPFixture.swift'
    # Credential transaction fixture only uses its actual read and gate routines.
    raw=(service/'CodexCredentialTransaction.swift').read_text();raw=raw[:raw.index('    private static func tokens(')]+'}\n'
    (folder/'Credential.swift').write_text(raw);files[2]=folder/'Credential.swift'
    # Freeze inputs before compile; other authorized agents may edit integration code.
    frozen=[]
    for source in files:
        target=folder/source.name
        if target != source:
            content=source.read_text()
            if source.name == 'test-local-proxy-host.swift' and '--release-fence-only' in sys.argv:
                original_main=declaration(content, '    @MainActor static func main() async throws')
                content=content.replace(original_main, '    @MainActor static func main() async throws { setbuf(stdout, nil); try await releaseFenceFixtures() }')
            if source.name == 'DispatchActivityStore.swift':
                commit='guard written == data.count, fsync(fd) == 0,'
                assert content.count(commit) == 1
                content=content.replace(commit, 'guard written == data.count, !LocalProxyFixtureRuntime.failActivityCommit, fsync(fd) == 0,')
            if source.name == 'LocalProxyQueueStore.swift':
                # Test-only visibility, without changing production APIs or behavior.
                content=content.replace('private(set)', '').replace('private ', '')
                content=content.replace('LocalProxyNetworkSettings.load()', 'LocalProxyNetworkSettings.resolve([:])')
                begin=content.index('    func verifiedHelper() throws -> URL {')
                end=content.index('    func randomKey()',begin)
                content=content[:begin]+'    func verifiedHelper() throws -> URL { LocalProxyFixtureRuntime.helper }\n'+content[end:]
                if dynamic_http:
                    environment='child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]'
                    assert content.count(environment) == 1
                    content=content.replace(environment, environment + '\n            child.environment?["AIGOODBRO_PROTOCOL_FIXTURE_CHILD"] = "1"\n            child.environment?["AIGOODBRO_FIXTURE_UPSTREAM"] = ProcessInfo.processInfo.environment["PROXY_DYNAMIC_UPSTREAM"]!')
                    configuration='var bytes = try JSONSerialization.data(withJSONObject: configuration)'
                    assert content.count(configuration) == 1
                    content=content.replace(configuration, '''var sanitizedConfiguration = configuration
            sanitizedConfiguration["controlKey"] = "<redacted>"
            sanitizedConfiguration["clientKey"] = "<redacted>"
            let diagnostic = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROXY_DYNAMIC_HTTP_EVIDENCE"]!).appendingPathComponent("startup-sanitized.json")
            try JSONSerialization.data(withJSONObject: sanitizedConfiguration, options: [.prettyPrinted, .sortedKeys]).write(to: diagnostic)
            ''' + configuration)
                    consume='func consume(_ data: Data, run: String) {'
                    assert content.count(consume) == 1
                    content=content.replace(consume, consume + '''
        if let diagnostic = try? JSONSerialization.jsonObject(with: data) as? [String: Any], diagnostic["event"] as? String == "error" {
            print("DYNAMIC_HTTP_CHILD_DIAGNOSTIC: " + (diagnostic["errorCode"] as? String ?? "missing_error_code"))
        }
''')
                    mutation=os.environ.get('PROXY_DYNAMIC_HTTP_MUTATION', '')
                    if mutation == 'stale-active-membership':
                        assignment='activeIDs = preferences.enabledIDs.intersection(Set(registeredPool.keys))'
                        assert content.count(assignment) == 1
                        content=content.replace(assignment, '// Negative control: omit live membership synchronization.')
                    elif mutation == 'removed-admission-revocation':
                        for guard in ['guard activeIDs.contains(request.profileID), preferences.enabledIDs.contains(request.profileID)\n        else { return .failure(.notParticipating) }',
                                      'guard activeIDs.contains(request.profileID), preferences.enabledIDs.contains(request.profileID)\n            else { return .notParticipating }']:
                            assert content.count(guard) == 1, 'exact native revocation guard required'
                            content=content.replace(guard, '// Negative control: omit disabled-account admission guard.')
                    else:
                        assert mutation == '', 'unknown dynamic HTTP mutation'
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
                cleanup='''    func retireLeaseAfterExit(_ lease: Lease) throws {
        try update(lease, state: "cancelled", allowTerminalCleanup: true)'''
                assert content.count(cleanup) == 1
                content=content.replace(cleanup, '''    func retireLeaseAfterExit(_ lease: Lease) throws {
        if LocalProxyFixtureRuntime.failFirstTerminalCleanup {
            LocalProxyFixtureRuntime.failFirstTerminalCleanup = false
            throw DispatchActivityStore.Failure.busy
        }
        try update(lease, state: "cancelled", allowTerminalCleanup: true)''')
            target.write_text(content)
        frozen.append(target)
    files=frozen
    if dynamic_http:
        evidence=Path(os.environ['PROXY_DYNAMIC_HTTP_EVIDENCE'])
        evidence.mkdir(parents=True, exist_ok=True)
        copied=evidence/'compiled-source'
        copied.mkdir(exist_ok=True)
        for source in files:
            shutil.copy2(source, copied/source.name)
        (evidence/'compiled-source-manifest.json').write_text(json.dumps({
            'schemaVersion':1, 'mutation':os.environ.get('PROXY_DYNAMIC_HTTP_MUTATION', ''),
            'files':[{'name':source.name, 'sha256':hashlib.sha256(source.read_bytes()).hexdigest()} for source in files],
            'seams':['peripheral stubs', 'private test visibility', 'isolated support root', 'test-binary helper',
                     'no system network proxy', 'loopback upstream injected into copied host child environment'],
        }, indent=2)+'\n')
    subprocess.run(['python3',str(root/'scripts/check-build-target-idle.py'),str(folder/'fixture')],check=True)
    sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
    target=f'{os.uname().machine}-apple-macos13.0'
    compiler=['xcrun','swiftc','-O','-g','-target',target,'-sdk',sdk,'-swift-version','5','-parse-as-library','-module-cache-path',str(folder/'modules')]
    subprocess.run([*compiler,*[str(f) for f in files],'-o',str(folder/'fixture')],check=True)
    if dynamic_http:
        shutil.copy2(folder/'fixture', evidence/'native-fixture')
        (evidence/'native-fixture-sha256.txt').write_text(hashlib.sha256((folder/'fixture').read_bytes()).hexdigest()+'\n')
    fixture_env={**os.environ,'PROXY_FIXTURE_TRACE':'1','PROXY_FIXTURE_ROOT':str(folder/'support'),'PROXY_FIXTURE_PYTHON':sys.executable,'PROXY_FIXTURE_INTEROP':str(root/'scripts/test-local-proxy-host-interop.py')}
    if '--release-fence-only' in sys.argv:
        fixture_env['PROXY_RELEASE_FENCE_ONLY']='1'
    try:
        subprocess.run([str(folder/'fixture')],env=fixture_env,check=True)
    except subprocess.CalledProcessError as failure:
        if dynamic_http:
            raise
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
