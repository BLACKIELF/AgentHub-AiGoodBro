#!/usr/bin/env python3
"""Offline manual reset/referral tests. No App, real account, network, or keychain.

Compiles the full production reset controller/journal/activity store with a synthetic
reader, plus exact production referral resolver/credential snapshot and reader gates.
"""
from pathlib import Path
import hashlib, importlib.util, json, os, subprocess, tempfile
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('reset_auto_fixture', ROOT / 'scripts/test-reset-credit-auto.py')
auto = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auto)
extract = auto.declaration
BASE = ROOT / 'Sources/CodexUsageWidget'
paths = [*auto.SOURCES, BASE/'Services/UsageStore.swift', BASE/'Services/CodexUsageReader.swift',
         BASE/'Services/CodexReferralClient.swift', BASE/'Services/CodexProfileStore.swift',
         BASE/'Services/CodexCredentialTransaction.swift', BASE/'UI/ResetCreditButton.swift',
         ROOT/'tests/ManualAccountActionsTests.swift', ROOT/'scripts/test-reset-credit-auto.py']
snapshots = {p: p.read_bytes() for p in paths}
inputs = {str(p.relative_to(ROOT)): hashlib.sha256(v).hexdigest() for p,v in snapshots.items()}
reader = snapshots[BASE/'Services/CodexUsageReader.swift'].decode()
usage = snapshots[BASE/'Services/UsageStore.swift'].decode()
referral = snapshots[BASE/'Services/CodexReferralClient.swift'].decode()
profile = snapshots[BASE/'Services/CodexProfileStore.swift'].decode().split('enum CodexOfficialProfileReader {',1)[1]
transaction = snapshots[BASE/'Services/CodexCredentialTransaction.swift'].decode()
controller = snapshots[BASE/'Services/CodexResetCreditController.swift'].decode()
# These extracts execute their actual production bodies; fixtures only supply dependencies.
referral_parts = '\n'.join(extract(referral, name) for name in [
    'struct CodexReferralAccount:', 'enum CodexReferralFailure:', 'enum CodexReferralCredentialReader {'])
identity = extract(snapshots[BASE/'Services/CodexProfileStore.swift'].decode(), 'struct CodexCredentialIdentity:')
official = 'enum CodexOfficialProfileReader {\n' + '\n'.join(extract(profile,n) for n in [
    'static func credentialIdentity(fromAuthData', 'private static func claims(',
    'private static func accountID(', 'private static func normalizedEmail(', 'private static func nonEmpty(']) + '\n}'
transactions = 'enum CodexCredentialTransaction {\n' + '\n'.join(extract(transaction,n) for n in ['static func canonical(', 'static func read(']) + '\n}'
resolver = extract(usage, 'func referralAccount(for profileID:')
process_gate = extract(reader, 'if selectedCard != nil, admission != nil, profile.isSystemProfile {')
referral_host = '''
final class ReferralProfileStore { var homes: [String:URL] = [:]; func effectiveCredentialHome(for id:String)->URL? { homes[id] } }
final class ReferralResolver {
 var isPreview=false; var isLoggingIn=false; var isLaunchingCodex=false; var isAccountSwitchTransactionActive=false
 var profiles:[CodexProfile]=[]; let profileStore=ReferralProfileStore()
''' + resolver + '\n}\n'
# pgrep is a deterministic double. The complete real conditional is exercised both ways.
process_host = '''
enum BoundedLocalProcess { static var calls=0; static var bytes=Data("12345".utf8)
 static func run(executable:URL,arguments:[String],maximumOutputBytes:Int,timeout:Int,allowedExitCodes:[Int]) throws -> Data { calls += 1; return bytes }
}
func processGate(profile:CodexProfile, selectedCard:CodexResetCreditCard?, admission:CodexResetCreditAutoAdmission?)->Result<Void,CodexResetCreditFailure> {
''' + process_gate + '\n return .success(())\n}\n'
reader_double = r'''
final class ManualReaderFixture {
 static let lock = NSLock()
 static var outcome:Result<CodexResetCreditConsumeOutcome,CodexResetCreditFailure> = .success(.reset)
 static var keys:[String]=[]; static var reviewedAt:Date?; static var cardID="synthetic-card"
 static var pause:DispatchSemaphore?; static var started=DispatchSemaphore(value:0)
 static func reset() { lock.lock(); defer { lock.unlock() }; outcome = .success(.reset); keys=[]; reviewedAt=nil; cardID="synthetic-card"; pause=nil; started=DispatchSemaphore(value:0) }
 static func review(_ profile:CodexProfile)->CodexResetCreditReview {
 lock.lock(); defer { lock.unlock() }
 return CodexResetCreditReview(profileID:profile.id,accountID:profile.lastSnapshot!.accountID!,accountRemark:"Synthetic account",card:.init(creditID:cardID,expiresAt:nil),observedAt:reviewedAt ?? Date()) }
}
struct CodexUsageReader {
 func readResetCreditReview(context:RuntimeLoadContext,profile:CodexProfile,expectedAccountID:String,accountRemark:String)->Result<CodexResetCreditReview,CodexResetCreditFailure> { .success(ManualReaderFixture.review(profile)) }
 func consumeResetCredit(context:RuntimeLoadContext,profile:CodexProfile,review:CodexResetCreditReview,idempotencyKey:String,admission:CodexResetCreditAutoAdmission?=nil)->Result<CodexResetCreditConsumeOutcome,CodexResetCreditFailure> {
 ManualReaderFixture.lock.lock(); ManualReaderFixture.keys.append(idempotencyKey); let pause=ManualReaderFixture.pause; let result=ManualReaderFixture.outcome; ManualReaderFixture.lock.unlock()
 ManualReaderFixture.started.signal(); if let pause { precondition(pause.wait(timeout:.now()+3) == .success) }; return result
 }
}
'''
stubs = auto.STUBS.replace(extract(auto.STUBS,'struct CodexUsageReader {'),reader_double)
stubs = stubs.replace('var accountID:String?;', 'var accountID:String?; var email:String? = "sender@example.invalid";')
stubs += '\nimport Darwin\n'+ '\n'.join([identity,official,transactions,referral_parts,referral_host,process_host])
# Static checks bind the UI and unchanged lower-level exact-card/identity/uncertain safeguards.
button=snapshots[BASE/'UI/ResetCreditButton.swift'].decode()
assert 'onManualResetConfirmed: onManualResetConfirmed' in button
assert button.count('controller.confirmReviewed(')==1 and button.count('controller.confirmConsumption(')==1
assert 'profile.lastSnapshot?.accountID == expectedAccountID' in reader
assert 'guard idempotencyKey.utf8.count == 36' in reader or 'UUID(uuidString: idempotencyKey)' in reader
assert 'consumeMayHaveBeenSent ? .outcomeUnknown : .requestNotSent' in reader
assert 'guard admission.map({ $0.admit(sendConsume) }) ?? sendConsume()' in reader
with tempfile.TemporaryDirectory(prefix='aigoodbro-manual-actions-') as temp:
 folder=Path(temp); frozen=[]
 for path in auto.SOURCES:
  text=snapshots[path].decode()
  if path.name=='DispatchParticipationSync.swift':
   text=text.replace(extract(text,'static func supportDirectory('),'static func supportDirectory(fileManager:FileManager = .default)->URL { URL(fileURLWithPath:ProcessInfo.processInfo.environment["RESET_AUTO_TEST_ROOT"]!) }',1)
  target=folder/path.name;target.write_text(text);frozen.append(target)
 test=folder/'ManualAccountActionsTests.swift';test.write_bytes(snapshots[ROOT/'tests/ManualAccountActionsTests.swift'])
 stub=folder/'Stubs.swift';stub.write_text(stubs);binary=folder/'checks'
 command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(folder/'modules'),str(stub),*map(str,frozen),str(test),'-o',str(binary)]
 compiled=subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
 output=compiled.stdout+compiled.stderr;run=None
 if compiled.returncode==0:
  run=subprocess.run([str(binary)],env={**os.environ,'RESET_AUTO_TEST_ROOT':str(folder/'support')},capture_output=True,text=True,timeout=45);output+=run.stdout+run.stderr
 print(output,end='')
 receipt={'inputsSHA256':inputs,'scriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'compileCommand':command,'compileExitCode':compiled.returncode,'testExitCode':run.returncode if run else None,'frozenSHA256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [stub,*frozen,test]},'inputsUnchanged':all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in inputs.items()),'scope':'Full production reset controller, pending journal, activity store, atomic file writer; exact referral resolver/account binding/credential snapshot identity validation; exact process gate with deterministic pgrep double. Synthetic account/card/JWT in owned temporary directories; no App, real credential, invitation, reset RPC, network, or live mutation.'}
 out=ROOT.parent/'evidence/manual-account-actions-1030v1';out.mkdir(parents=True,exist_ok=True)
 (out/'checks.log').write_text(output);(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if compiled.returncode or not run or run.returncode:raise SystemExit(1)
