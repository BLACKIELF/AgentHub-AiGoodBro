from pathlib import Path
import subprocess, tempfile, sys
root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
source = (root/'Sources/CodexUsageWidget/Services/UsageStore.swift').read_text()
def method(signature):
 start = source.index(signature)
 opening = source.index('{', start); depth = 1; end = opening + 1
 while depth:
  depth += (source[end] == '{') - (source[end] == '}'); end += 1
 return source[start:end]
configure = method('    func configureStatisticsSources(')
scan_key = method('    private func currentStatisticsEngineScanKey()')
fixture='''import Foundation
struct StatisticsTimeZonePreference: Equatable {
    func resolvedTimeZone() -> TimeZone { TimeZone(identifier: "UTC")! }
}
final class StoreFixture {
    private struct StatisticsEngineScanKey: Equatable {
        let choice: StatisticsEngineChoice
        let preference: StatisticsTimeZonePreference
        let timeZone: String
        let sources: [TokenMonitorSource]
    }
    var statisticsPreference = StatisticsTimeZonePreference()
    var engineLocalSources: [TokenMonitorSource] = []
    var statisticsIncludesManagedCodex = true
    var hasStarted = false
    var cancelled = 0
    var refreshed = 0
    var scanned = 0
    func cancelStatisticsEngine() { cancelled += 1 }
    func refreshStatisticsEngine() { scanned += 1 }
    func refresh(queueIfBusy: Bool) { refreshed += 1 }
''' + configure + '\n' + scan_key + '''
    struct Profile { let id: String; let isSystemProfile: Bool; let codexHomeURL: URL }
    var profiles = [
        Profile(id: "system", isSystemProfile: true, codexHomeURL: URL(fileURLWithPath: "/tmp/synthetic-system")),
        Profile(id: "managed", isSystemProfile: false, codexHomeURL: URL(fileURLWithPath: "/tmp/synthetic-managed"))]
    func candidates() -> [TokenMonitorSource] {
        currentStatisticsEngineScanKey().sources.filter { $0.kind == .managedAccount }
    }
}
@main struct Main {
 static func main() throws {
  let s = StoreFixture()
  precondition(s.candidates().map(\\.id) == ["managed"])
  print("PASS default managed Codex inclusion")
  try s.configureStatisticsSources([], includeManagedCodex: false)
  precondition(s.candidates().isEmpty && s.cancelled == 1)
  print("PASS disabled Codex yields no managed usage sources")
  s.hasStarted = true
  try s.configureStatisticsSources([])
  precondition(s.candidates().map(\\.id) == ["managed"] && s.cancelled == 1 && s.scanned == 1 && s.refreshed == 1)
  print("PASS enabled default starts new managed usage scan before queued refresh")
  let bad = TokenMonitorSource(id: "custom", providerId: "codex", kind: .custom, canonicalPath: "/tmp/synthetic-custom.json", pathRole: .customFile, toolId: "codex", authority: .custom)
  do { try s.configureStatisticsSources([bad], includeManagedCodex: false); fatalError("invalid authority accepted") }
  catch TokenMonitorFailure.invalidSource { }
  precondition(s.candidates().map(\\.id) == ["managed"] && s.cancelled == 1 && s.scanned == 1)
  print("PASS rejected configuration preserves previous inclusion state")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='token-monitor-selection-') as tmp:
 p=Path(tmp); (p/'Fixture.swift').write_text(fixture)
 sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
 arch=subprocess.check_output(['uname','-m'],text=True).strip()
 subprocess.run(['swiftc','-sdk',sdk,'-target',arch+'-apple-macosx13.0','-module-cache-path',str(p/'cache'),str(root/'Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift'),str(root/'Sources/CodexUsageWidget/Services/TokenMonitorEngine.swift'),str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True)
