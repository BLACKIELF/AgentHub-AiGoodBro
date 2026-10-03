"""Run production preference and timer wiring with isolated in-memory defaults."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, needle):
    start = source.index(needle)
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == '{') - (source[index] == '}')
        if depth == 0:
            return source[start:index + 1].replace('private ', '')
    raise AssertionError(needle)


class AccountRefreshFrequencyTests(unittest.TestCase):
    def test_real_timers_and_persistence(self):
        usage = (ROOT / 'Sources/CodexUsageWidget/Services/UsageStore.swift').read_text()
        policy = (ROOT / 'Sources/CodexUsageWidget/Domain/AccountRefreshFrequency.swift').read_text()
        methods = '\n'.join(declaration(usage, needle) for needle in [
            'var accountSnapshotRefreshInterval:',
            'private var foregroundFullRefreshInterval:', 'private var backgroundFullRefreshInterval:',
            'private func scheduleFullRefreshTimer()', 'private func scheduleWarmUpMaintenanceTimer()',
            'func setAccountRefreshFrequency(',
        ])
        fixture = r'''
import Foundation
struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ zh: String, _ en: String) -> String { en }
}
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
enum CodexWarmUpPolicy {
    static func maintenanceRefreshInterval(warmUpEnabled: Bool, quotaNotificationsEnabled: Bool) -> TimeInterval { 1800 }
    static func maintenanceTimerNeedsReplacement(currentInterval: TimeInterval, requestedInterval: TimeInterval) -> Bool { currentInterval != requestedInterval }
}
struct Selection { var isEnabled = false }
final class UsageStore {
    var accountRefreshFrequency = AccountRefreshFrequency.load()
    var hasStarted = true, isPreview = false, isMainWindowActive = true, isTaskOverviewVisible = false
    var automaticAccountSwitchEnabled = false
    var isRefreshingWarmUpProfiles = false, observesOfficialQuotaEvents = false
    var fullTimer: Timer?, warmUpMaintenanceTimer: Timer?
    var warmUpSelection = Selection()
    var lastFullRefreshCompletedAt: Date?, warmUpRefreshStartedAt: Date?
    var accountManagerMessage: String?
    var reads = 0
    var monitorConnectionRefreshes = 0
    func refresh() { reads += 1 }
    func refreshTokenMonitorConnections() { monitorConnectionRefreshes += 1 }
    func refreshWarmUpProfilesThenSchedule(performWarmUpAfterRefresh: Bool, quotaOnly: Bool, retryQuotaReadOnce: Bool) { reads += 1 }
    // METHODS
}
let defaults = UserDefaults.standard
precondition(AccountRefreshFrequency.load() == .automatic)
defaults.set("invalid", forKey: AccountRefreshFrequency.defaultsKey)
precondition(AccountRefreshFrequency.load() == .automatic)
let store = UsageStore()
precondition(store.foregroundFullRefreshInterval == 180 && store.backgroundFullRefreshInterval == 300)
store.scheduleFullRefreshTimer(); store.scheduleWarmUpMaintenanceTimer()
let originalFull = store.fullTimer!, originalPool = store.warmUpMaintenanceTimer!
store.setAccountRefreshFrequency(.oneMinute)
precondition(!originalFull.isValid && !originalPool.isValid)
precondition(store.fullTimer?.timeInterval == 60 && store.warmUpMaintenanceTimer?.timeInterval == 60)
precondition(AccountRefreshFrequency.load() == .oneMinute && store.reads == 0 && store.monitorConnectionRefreshes == 0)
let unchanged = store.fullTimer
store.setAccountRefreshFrequency(.oneMinute)
precondition(unchanged === store.fullTimer)
for frequency in AccountRefreshFrequency.allCases {
    store.setAccountRefreshFrequency(frequency)
    precondition(store.fullTimer?.timeInterval == frequency.interval(default: 180))
    precondition(store.warmUpMaintenanceTimer?.timeInterval == frequency.interval(default: 1800))
}
store.setAccountRefreshFrequency(.automatic)
store.automaticAccountSwitchEnabled = true; store.scheduleWarmUpMaintenanceTimer()
precondition(store.warmUpMaintenanceTimer?.timeInterval == 180)
store.isMainWindowActive = false; store.scheduleFullRefreshTimer()
precondition(store.fullTimer?.timeInterval == 300)
store.fullTimer?.invalidate(); store.warmUpMaintenanceTimer?.invalidate()
let preview = UsageStore(); preview.isPreview = true; preview.hasStarted = false
preview.setAccountRefreshFrequency(.fiveMinutes)
precondition(AccountRefreshFrequency.load() == .automatic && preview.fullTimer == nil && preview.warmUpMaintenanceTimer == nil)
print("account-refresh-frequency: ok")
'''.replace('// METHODS', methods)
        with tempfile.TemporaryDirectory(prefix='refresh-frequency-fixture-') as folder:
            folder = Path(folder)
            source = folder / 'main.swift'
            source.write_text(policy + '\n' + fixture)
            binary = folder / 'fixture'
            result = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'), str(source), '-o', str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn('account-refresh-frequency: ok', result.stdout)


if __name__ == '__main__':
    unittest.main()
