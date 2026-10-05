#!/usr/bin/env python3
"""Offline controller/Keychain-policy regression; all credentials and I/O are synthetic."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
base = root / "Sources/CodexUsageWidget"
def read(path):
    return (base / path).read_text()

service = read("Services/FeishuWebhookService.swift")
error = service[service.index("enum FeishuWebhookError:"):service.index("/// A display-only")]
keychain = service[service.index("final class FeishuKeychainRead<"):service.index("final class FeishuWebhookService")]
announcement = read("Services/PublicResetAnnouncements.swift")
announcement = announcement[announcement.index("struct PublicResetAnnouncement:"):announcement.index("struct PublicResetPage:")]
options = read("Domain/FeishuMessageOptions.swift").split("\nenum FeishuQuotaValue", 1)[0]
quota = read("Domain/CodexQuotaEventTracker.swift").split("/// Compares", 1)[0]
stubs = '''import Foundation
import Combine
import Security
enum WidgetLanguage { case zh, en
static func storedOrAutomatic() -> Self { .en }
var locale: Locale { Locale(identifier: "en_US") }
func dateTime(_ date: Date) -> String { "fixture-date" }
func text(_ zh: String, _ en: String) -> String { self == .zh ? zh : en }
}
struct CodexTaskLiveSnapshot {
 enum Mode { case disconnected, connected }
 struct Record { let threadID: String; let updatedAt: Date?; let name: String? }
 var connectionMode: Mode = .disconnected
 var records: [String: Record] = [:]
}
struct FeishuTaskCompletionObserver {
 struct Completion { let occurredAt: Date }
 mutating func observe(_ snapshot: CodexTaskLiveSnapshot, now: Date) -> [Completion] { [] }
}
'''
parts = [stubs, error, keychain, quota, options, read("Services/PublicResetTranslation.swift"), announcement]
parts += [read(path) for path in ["Domain/MessageChannel.swift", "Services/TelegramMessageChannel.swift", "Services/WeChatMessageChannel.swift", "Services/PersonalWeChatMessageChannel.swift", "Services/CodexDesktopIPC.swift", "Services/WeChatCodexConversation.swift", "Services/WeChatBotEventLedger.swift", "Services/MessageChannelsController.swift"]]
if "--controller" in __import__("sys").argv:
    runtime = read("Domain/TaskRuntime.swift")
    runtime = runtime[runtime.index("enum TaskRuntimeState:"):runtime.index("struct TaskRuntimeReducer")]
    parts[0] = (stubs.split("struct CodexTaskLiveSnapshot")[0]
        + "\nenum TaskColumnKind { case active, done, pending }\nenum FeishuTaskCompletionNotification { static let futureToleranceSeconds: TimeInterval = 60 }\n"
        + runtime + "\n" + read("Domain/FeishuTaskCompletionObserver.swift"))
    parts += [read("Services/MessageChannelsControllerSelfTest.swift"),
        "@main struct Runner { static func main() { exit(MessageChannelsControllerSelfTest.run() ? 0 : 1) } }"]
else:
    parts += [(root / "tests" / path).read_text() for path in ["MessageTestAdmissionFixture.swift", "MessageCredentialRecoveryFixture.swift"]]
with tempfile.TemporaryDirectory(prefix="wechat-recovery-fixture-") as temporary:
    directory = pathlib.Path(temporary)
    source = directory / "tests.swift"
    source.write_text("\n".join(parts))
    binary = directory / "tests"
    result = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "module-cache"), str(source), "-o", str(binary)], capture_output=True, text=True)
    output = result.stdout + result.stderr
    print(output.replace(str(root), "<workspace>").replace(temporary, "<fixture>"), end="")
    if result.returncode:
        raise SystemExit(result.returncode)
    subprocess.run([str(binary)], check=True)
