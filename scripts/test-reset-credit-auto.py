#!/usr/bin/env python3
"""Offline auto-reset host tests: frozen real controller, journal, lease and file writers.

Only supportDirectory resolves to a disposable fixture root. Reader and Hub fallbacks
trap; every runAutomatic call supplies injected readers and availability.
"""
from pathlib import Path
import hashlib,json,os,re,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parent.parent
SOURCES=[ROOT/'Sources/CodexUsageWidget'/p for p in [
 'Domain/CodexResetCredit.swift','Domain/CodexResetCreditAuto.swift',
 'Services/CodexResetCreditController.swift','Services/DispatchParticipationSync.swift',
 'Services/DispatchActivityStore.swift']]
TEST=ROOT/'tests/ResetCreditAutoTests.swift'
WIRING_TEST=ROOT/'tests/ResetCreditAutoWiringTests.swift'
FALLBACK_TEST=ROOT/'tests/ResetCreditAutoFallbackTests.swift'
USAGE=ROOT/'Sources/CodexUsageWidget/Services/UsageStore.swift'
READER=ROOT/'Sources/CodexUsageWidget/Services/CodexUsageReader.swift'
STUBS=r'''import Foundation
import Combine
struct CodexAccountSnapshot { var accountID:String?; var quotaReadSucceeded:Bool? = true; var resetCreditExpiries:[Date]? = nil }
struct CodexProfile { let id:String; var lastSnapshot:CodexAccountSnapshot?; var lastQuotaReadFailureAt:Date? = nil; var isSystemProfile = false
 var recordedAccountKey:String { "synthetic-"+(lastSnapshot?.accountID ?? id) }; var codexHomeURL:URL { URL(fileURLWithPath:ProcessInfo.processInfo.environment["RESET_AUTO_TEST_ROOT"]!).appendingPathComponent("home-"+id) } }
enum AccountDisplay { static func profileName(_ profile:CodexProfile)->String { "Synthetic account" }; static func numberedName(_ profile:CodexProfile,allProfiles:[CodexProfile])->String { profile.id } }
enum WidgetLanguage { case fixture; static func storedOrAutomatic()->Self { .fixture }; func text(_ zh:String,_ en:String)->String { en } }
enum HubAccountTaskPhase { case maintenance,starting,running,cancelRequested,uncertain,awaitingAcceptance,succeeded,failed,cancelled,unavailable }
struct HubAccountTaskStatus { let phase:HubAccountTaskPhase; let updatedAt:Date? }
enum HubWarmUpAvailability { case idle }
enum HubConsoleModel { static func warmUpAvailability(for:String,excludingLocalLease:String?) async ->HubWarmUpAvailability { fatalError("Uninjected Hub call forbidden") } }
struct RuntimeLoadContext { static func live(codexHomeDirectory:URL)->Self { Self() } }
struct CodexUsageReader {
 func readResetCreditReview(context:RuntimeLoadContext,profile:CodexProfile,expectedAccountID:String,accountRemark:String)->Result<CodexResetCreditReview,CodexResetCreditFailure> { fatalError("Uninjected reader forbidden") }
 func consumeResetCredit(context:RuntimeLoadContext,profile:CodexProfile,review:CodexResetCreditReview,idempotencyKey:String,admission:CodexResetCreditAutoAdmission? = nil)->Result<CodexResetCreditConsumeOutcome,CodexResetCreditFailure> { fatalError("Real consume forbidden") }
}
'''
def declaration(source,needle):
 start=source.index(needle);opening=source.index('{',start);depth=0
 for i in range(opening,len(source)):
  if source[i]=='{':depth+=1
  if source[i]=='}':
   depth-=1
   if depth==0:return source[start:i+1]
 raise ValueError(needle)
def main():
 prefix=os.environ.get('RESET_AUTO_EVIDENCE_PREFIX','reset-auto-host')
 if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,127}',prefix) or prefix=='reset-auto-124-host':
  raise ValueError('RESET_AUTO_EVIDENCE_PREFIX must be a safe basename and must not overwrite accepted 124 evidence')
 snapshots={p:p.read_bytes() for p in SOURCES+[TEST,WIRING_TEST,FALLBACK_TEST,USAGE,READER]}
 inputs={str(p.relative_to(ROOT)):hashlib.sha256(data).hexdigest() for p,data in snapshots.items()}
 with tempfile.TemporaryDirectory(prefix='aigoodbro-reset-auto-fixture-') as tmp:
  folder=Path(tmp);frozen=[]
  for path in SOURCES:
   text=snapshots[path].decode()
   if path.name=='DispatchParticipationSync.swift':
    old=declaration(text,'static func supportDirectory(')
    replacement='static func supportDirectory(fileManager: FileManager = .default) -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["RESET_AUTO_TEST_ROOT"]!) }'
    text=text.replace(old,replacement,1)
   target=folder/path.name;target.write_text(text);frozen.append(target)
  usage=snapshots[USAGE].decode();reader=snapshots[READER].decode()
  runner=declaration(usage,'private func checkResetCreditAuto()').replace('private func','func',1)
  start=reader.index('                    guard admission?.isCancelled != true else {')
  end=reader.index('                }\n            } else if id == 3',start)
  send=reader[start:end]
  # A test scheduling seam after the real precheck, before the real admission lock.
  marker='                    stage = .awaitingConsume'
  assert send.count(marker)==1
  send=send.replace(marker,'                    beforeWrite?()\n'+marker,1)
  wiring=r'''
@MainActor final class FixtureAutoController {
 var attempted:[String]=[]; var consumed:[String]=[]; var busyIDs:Set<String>=[]; var onAttempt:(()->Void)?
 func runAutomatic(profile:CodexProfile,accountID:String,hubAccountAlias:String,lead:TimeInterval,quotaFingerprint:String,admission:CodexResetCreditAutoAdmission,onStatus:((String)->Void)?=nil,onConfirmedResult:@escaping()->Void) async -> CodexResetCreditController.AutomaticAttemptDisposition {
 attempted.append(profile.id); if !busyIDs.contains(profile.id) { consumed.append(profile.id) }; onAttempt?(); return .accountHandledOrBlocked
 }
}
@MainActor final class AutomaticRunnerFixture {
 var hasStarted=true; var resetCreditAutoDesktopVerified=true; var resetCreditAutoIdentityRetryAt:Date?=nil; var identityRefreshCancellation:UUID?=nil; var isPreview=false
 func synchronizeMonitorWithCurrentCodex(announce:Bool) {}
 var resetCreditAutoTask:Task<Void,Never>?; var isLaunchingCodex=false; var isLoggingIn=false; var isAccountSwitchTransactionActive=false
 var profiles:[CodexProfile]=[]; var resetCreditAutoPreferences=CodexResetCreditAutoPreferences(); var aliases:[String:String]=[:]
 var resetCreditAutoAdmission:CodexResetCreditAutoAdmission?; var resetCreditAutoIdentity:(String,String,URL)?; var resetCreditAutoController=FixtureAutoController(); var resetCreditAutoStatus:String?
 func accountTaskAlias(for profile:CodexProfile)->String? { aliases[profile.id] }; func refreshProfile(_ id:String) {}
''' + runner + r'''
}
final class ReaderSendFixture {
 enum Stage { case awaitingInitialize,awaitingConsume };var stage=Stage.awaitingInitialize
 var consumeMayHaveBeenSent=false;var writes=0;var writeSucceeds=true;var failure:CodexResetCreditFailure?
 let card=CodexResetCreditCard(creditID:"synthetic-card",expiresAt:nil);let idempotencyKey=UUID().uuidString
 func writeMessageLocked(_ object:[String:Any])->Bool { writes += 1; return writeSucceeds }
 func finishLocked(_ result:Result<Void,CodexResetCreditFailure>) { if case .failure(let value)=result { failure=value } }
 func send(admission:CodexResetCreditAutoAdmission?,beforeWrite:(()->Void)?=nil) {
 var consumeMayHaveBeenSent=self.consumeMayHaveBeenSent
 defer { self.consumeMayHaveBeenSent=consumeMayHaveBeenSent }
 let card=self.card;let idempotencyKey=self.idempotencyKey
 func writeMessageLocked(_ request:[String:Any])->Bool { self.writeMessageLocked(request) }
''' + send + '\n}\n}\n'
  realRunner=runner
  seam='lead: self.resetCreditAutoPreferences.leadSeconds, quotaFingerprint: "", admission: admission,'
  assert realRunner.count(seam)==1
  realRunner=realRunner.replace(seam,seam+'\n                    autoStore: self.autoStore, reviewReader: self.reviewReader, consumeReader: self.consumeReader, hubAvailability: self.hubAvailability,',1)
  verified=declaration(reader,'func verifiedCard(')
  helpers='\n'.join(declaration(reader,n) for n in ['private func resetExactInt64(', 'private func resetValidField(', 'private func resetExpiry('])
  verifier='import CoreFoundation\n'+helpers+'\nstruct FallbackVerifier { let expectedAccountID:String; let selectedCard:CodexResetCreditCard?=nil;\n'+verified+'\n}\n'
  fallback=snapshots[FALLBACK_TEST].decode().replace('// EXTRACTED_RUNNER',realRunner,1)
  stubs=folder/'Stubs.swift';stubs.write_text(STUBS+wiring+verifier)
  fallbackTest=folder/FALLBACK_TEST.name;fallbackTest.write_text(fallback)
  wiringTest=folder/WIRING_TEST.name;wiringTest.write_bytes(snapshots[WIRING_TEST])
  test=folder/TEST.name;test.write_bytes(snapshots[TEST])
  binary=folder/'checks';env={**os.environ,'RESET_AUTO_TEST_ROOT':str(folder/'support')}
  command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(folder/'modules'),str(stubs),*map(str,frozen),str(test),str(wiringTest),str(fallbackTest),'-o',str(binary)]
  compiled=subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
  output=compiled.stdout+compiled.stderr
  run=None
  if compiled.returncode==0:
   run=subprocess.run([str(binary)],env=env,capture_output=True,text=True,timeout=60);output+=run.stdout+run.stderr
  race_results=[]
  if run and run.returncode==0:
   race=folder/'race';race.mkdir(mode=0o700)
   competitors=[subprocess.Popen([str(binary),'--race-claim',str(race),str(i)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for i in range(2)]
   deadline=time.monotonic()+5
   while not all((race/('ready-'+str(i))).exists() for i in range(2)) and time.monotonic()<deadline:time.sleep(0.01)
   assert all((race/('ready-'+str(i))).exists() for i in range(2)), 'race children did not reach barrier'
   (race/'start').touch()
   for child in competitors:
    out,err=child.communicate(timeout=10);race_results.append({'exitCode':child.returncode,'stdout':out,'stderr':err})
   wins=sum(r['stdout'].strip()=='CLAIM=1' for r in race_results)
   losses=sum(r['stdout'].strip()=='CLAIM=0' for r in race_results)
   busy=sum(r['exitCode']==0 and r['stdout'].strip()=='CLAIM=BUSY' for r in race_results)
   assert all(r['exitCode']==0 for r in race_results) and wins==1 and losses+busy==1,race_results
   output+='PASS cross-process exclusive claim: exactly one winner\n'
  negative={}
  if run and run.returncode==0:
   real_gate='guard admission.map({ $0.admit(sendConsume) }) ?? sendConsume()'
   original=stubs.read_text();assert original.count(real_gate)==1
   mutated=original.replace(real_gate,'guard sendConsume()',1)
   negativeSource=folder/'NegativeStubs.swift';negativeSource.write_text(mutated)
   negativeBinary=folder/'negative-checks'
   negativeCommand=[str(negativeSource) if item==str(stubs) else str(negativeBinary) if item==str(binary) else item for item in command]
   nc=subprocess.run(negativeCommand,cwd=ROOT,capture_output=True,text=True)
   assert nc.returncode==0,nc.stderr
   negativeEnv={**env,'RESET_AUTO_TEST_ROOT':str(folder/'negative-support')}
   nr=subprocess.run([str(negativeBinary)],env=negativeEnv,capture_output=True,text=True,timeout=60)
   expected='FAIL actual reader atomic admission blocks cancellation after precheck'
   markers=[line for line in nr.stdout.splitlines() if line.startswith('FAIL ')]
   assert nr.returncode==1 and markers==[expected],(nr.returncode,markers,nr.stdout,nr.stderr)
   negative={'compileExitCode':nc.returncode,'expectedExitCode':1,'actualExitCode':nr.returncode,'requiredFailureMarker':expected,'failureMarkers':markers,'mutatedFixtureSHA256':hashlib.sha256(mutated.encode()).hexdigest(),'stdout':nr.stdout,'stderr':nr.stderr,'passed':True}
   output+='PASS expected-failure reader admission removal: exit1, sole intended marker matched\n'
   early=fallback.replace('!seen.contains(account)','seen.insert(account).inserted',1)
   assert early != fallback
   earlySource=folder/'EarlySeenFallback.swift';earlySource.write_text(early)
   earlyBinary=folder/'early-seen-checks'
   earlyCommand=[str(earlySource) if item==str(fallbackTest) else str(earlyBinary) if item==str(binary) else item for item in command]
   ec=subprocess.run(earlyCommand,cwd=ROOT,capture_output=True,text=True);assert ec.returncode==0,ec.stderr
   er=subprocess.run([str(earlyBinary)],env={**env,'RESET_AUTO_TEST_ROOT':str(folder/'early-support')},capture_output=True,text=True,timeout=60)
   em=[line for line in er.stdout.splitlines() if line.startswith('FAIL ')]
   expectedFallback='FAIL same-account identityChanged review falls back to healthy profile exactly once'
   assert er.returncode==1 and em==[expectedFallback],(er.returncode,em,er.stdout,er.stderr)
   negative['earlySeen']={'compileExitCode':ec.returncode,'actualExitCode':er.returncode,'failureMarkers':em,'passed':True}
   output+='PASS expected-failure early dedup restore: exit1, sole fallback marker matched\n'

  for private,label in [(str(ROOT),'<repo>'),(tmp,'<fixture>'),(str(Path.home()),'<home>')]:output=output.replace(private,label)
  print(output,end='')
  q=ROOT/'.local-artifacts/theme-upstream-1004v1';q.mkdir(parents=True,exist_ok=True)
  (q/(prefix+'.log')).write_text(output)
  receipt={'inputsSHA256':inputs,'scriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'frozenSHA256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [stubs,*frozen,test,wiringTest,fallbackTest]},'fullSourceAdjustment':'Only DispatchParticipationSync.supportDirectory resolves to fixture root','extractedRunnerSHA256':hashlib.sha256(runner.encode()).hexdigest(),'extractedReaderSendSHA256':hashlib.sha256(reader[start:end].encode()).hexdigest(),'readerSendTestSeam':'beforeWrite callback immediately after real pre-cancel check; no gate/body changes','readerAdmissionNegative':negative,'swiftAssertions':57,'crossProcessClaimChecks':1,'raceResults':race_results,'logSHA256':hashlib.sha256(output.encode()).hexdigest(),'compileExitCode':compiled.returncode,'testExitCode':run.returncode if run else None,'inputsUnchanged':all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in inputs.items()),'scope':'Real complete auto controller/journal/pending/activity/atomic writers plus actual extracted UsageStore runner and Reader consume write admission block; profile/reader/Hub doubles; original wiring-controller double plus real controller fallback runner and real Reader verifiedCard; no real app/network/auth/hotkeys'}
  (q/(prefix+'.json')).write_text(json.dumps(receipt,indent=2)+'\n')
  assert compiled.returncode==0 and run and run.returncode==0 and 'reset-credit auto host: 57 assertions, 0 failures' in run.stdout and receipt['inputsUnchanged'],receipt
if __name__=='__main__':main()
