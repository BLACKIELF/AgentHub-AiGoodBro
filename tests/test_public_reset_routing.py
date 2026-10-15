"""Offline focused compile: real routing/adapter code, inert unrelated dependencies."""
import os, pathlib, subprocess, tempfile, sys
root = pathlib.Path(__file__).resolve().parents[1]
def read(p): return (root / p).read_text()
base = 'Sources/CodexUsageWidget/'
controller = read(base+'Services/MessageChannelsController.swift')
a=controller.index('final class MessageChannelKeychainStore:')
b=controller.index('private final class FrozenMessageChannelCredential:')
controller=controller[:a]+'''final class MessageChannelKeychainStore: MessageChannelCredentialStoring {
func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) { fatalError("Keychain forbidden") }
func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) { fatalError("Keychain forbidden") }
}
'''+controller[b:]
stubs='''import Foundation
import Combine
import Darwin
enum WidgetLanguage { case zh, en
static func storedOrAutomatic() -> Self { .en }
var locale: Locale { Locale(identifier: self == .zh ? "zh_CN" : "en_US") }
func dateTime(_ date: Date) -> String { "fixture-date" }
func text(_ zh: String, _ en: String) -> String { self == .zh ? zh : en }
}
enum FeishuWebhookError: Error {
case cancelled, transportFailed, invalidResponse, httpStatus(Int), invalidNotification
case keychainAuthorizationRequired, keychainTimedOut, keychainBusy, keychain(Int32)
}
struct CodexTaskLiveSnapshot {
enum Mode { case connected, disconnected }
struct Record { let threadID: String; let updatedAt: Date?; let name: String? }
var connectionMode: Mode = .disconnected
var records: [String: Record] = [:]
}
struct FeishuTaskCompletionObserver {
struct Completion { let occurredAt: Date }
mutating func observe(_ snapshot: CodexTaskLiveSnapshot, now: Date) -> [Completion] { [] }
}
enum NextFeatureDefaults { static func isEnabled(_ key: String) -> Bool { false } }
enum DispatchParticipationPaths { static func supportDirectory() -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["PUBLIC_RESET_FIXTURE_DIRECTORY"]!) } }
enum DispatchParticipationSync {
static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool) throws -> Data? {
 guard FileManager.default.fileExists(atPath: url.path) else { return nil }
 let d = try Data(contentsOf: url); guard d.count <= maximumBytes else { throw PublicResetFailure.localState }; return d
}
}
final class FeishuWebhookService {
func sendPublicResetAnnouncement(_ event: PublicResetAnnouncement, shouldSend: () -> Bool, completion: (Result<Void, FeishuWebhookError>) -> Void) { fatalError("real send forbidden") }
func sendPublicResetForecast(_ event: PublicResetForecastNotification, shouldSend: () -> Bool, completion: (Result<Void, FeishuWebhookError>) -> Void) { fatalError("real send forbidden") }
static func publicResetPayload(_ event: PublicResetAnnouncement, language: WidgetLanguage) throws -> Data { Data() }
}
'''
batch=read(base+'Domain/CodexResetNotice.swift').split('\nenum CodexResetNoticeChannel',1)[0]
quota=read(base+'Domain/CodexQuotaEventTracker.swift').split('/// Compares',1)[0]
options=read(base+'Domain/FeishuMessageOptions.swift').split('\nenum FeishuQuotaValue',1)[0]
forecast=read(base+'Services/PublicResetForecast.swift').split('\nenum PublicResetForecastSelfTest',1)[0]
announcements=read(base+'Services/PublicResetAnnouncements.swift').split('\nenum PublicResetAnnouncementSelfTest',1)[0]
context_fixture=read('tests/PublicResetContextFixture.swift')
parts=[stubs,batch,quota,options,read(base+'Domain/MessageNoticeFormat.swift'),read(base+'Domain/MessageChannel.swift'),read(base+'Services/TelegramMessageChannel.swift'),read(base+'Services/WeChatMessageChannel.swift'),read(base+'Services/PersonalWeChatMessageChannel.swift'),read(base+'Services/CodexDesktopIPC.swift'),read(base+'Services/WeChatCodexConversation.swift'),read(base+'Services/WeChatBotEventLedger.swift'),controller,read(base+'Services/PublicResetTranslation.swift'),read(base+'Services/PrivateLocalFileStore.swift'),forecast,read(base+'Services/PublicResetForecastDeliveryLedger.swift'),read(base+'Domain/PublicResetForecastNotification.swift'),announcements,read('tests/MessageTestAdmissionFixture.swift'),read('tests/PublicResetLifecycleFixture.swift'),context_fixture,read('tests/PublicResetRoutingFixture.swift')]
probe = '--caller-probe' in sys.argv
if probe:
 parts = parts[:-2] + ['\nfinal class UnownedCallerProbe {\n    let monitor = PublicResetAnnouncementMonitor(preview: true)\n    func refreshResetAnnouncements() { monitor.check() }\n    func stop() { monitor.stop() }\n    private func startAfterPendingSwitchRecovery() {\n        monitor.configure(notifyLocally: { _ in .inAppOnly }, canSend: { false }, send: { _ in .failure(.cancelled) })\n    }\n}\n']
with tempfile.TemporaryDirectory(prefix='next-routing-fixture-') as tmp:
 p=pathlib.Path(tmp); src=p/'fixture.swift'; src.write_text('\n'.join(parts))
 command=['xcrun','swiftc','-parse-as-library','-module-cache-path',str(p/'cache'),str(src),'-o',str(p/'fixture')]
 if probe: command = command[:2] + ['-typecheck'] + command[2:-2]
 result=subprocess.run(command,capture_output=True,text=True)
 output=result.stdout+result.stderr
 output=output.replace(str(root),'<workspace>').replace(tmp,'<fixture>').replace(str(pathlib.Path.home()),'<home>')
 print(output,end='')
 if probe:
  assert result.returncode != 0
  for method in ['check', 'stop', 'configure']:
   assert "call to main actor-isolated instance method '" + method in output
  print('PASS caller probe: all three synchronous unowned callers require actor integration (expected typecheck failure)')
  raise SystemExit(0)
 if result.returncode: raise SystemExit(result.returncode)
 result=subprocess.run([str(p/'fixture')],capture_output=True,text=True,env={**os.environ,'PUBLIC_RESET_FIXTURE_DIRECTORY':str(p/'support')})
 print(result.stdout,end=''); print(result.stderr.replace(tmp,'<fixture>').replace(str(root),'<workspace>').replace(str(pathlib.Path.home()),'<home>'),end='')
 raise SystemExit(result.returncode)
