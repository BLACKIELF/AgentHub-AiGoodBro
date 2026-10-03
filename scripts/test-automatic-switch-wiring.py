#!/usr/bin/env python3
"""Extract real entry/preparation/cleanup methods into an offline Swift harness.
--prepare-only generates source and static assertions; it never compiles/runs Swift.
Default mode must pass the existing idle guard before any compilation.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import time

OUT = Path('task-test-outputs/revision-0912v2')
OUT.mkdir(parents=True, exist_ok=True)
usage = Path('Sources/CodexUsageWidget/Services/UsageStore.swift').read_text()
actions = Path('Sources/CodexUsageWidget/Services/CodexAccountActions.swift').read_text()
policy = Path('Sources/CodexUsageWidget/Domain/AutomaticAccountSwitch.swift').read_text()
policy = policy[:policy.index('enum CodexAutomaticSwitchPolicySelfTest {')]

def section(start, end):
    return usage[usage.index(start):usage.index(end, usage.index(start))]

parts = [
    section('    private struct AutomaticSwitchContext {', '    private static let feishuNotificationsEnabledKey'),
    section('    func launchCodex(with profileID:', '    private func reserveDesktopSwitchMaintenance('),
    section('    private func beginCodexHistoryConfirmation(', '    private func rollbackManualSwitch('),
    section('    private func evaluateAutomaticAccountSwitch()', '    private func sendFeishuNotification('),
]
# Only access-control adaptation; all branches, shared-entry calls and defaults
# references remain unchanged. Stub UserDefaults is entirely in memory.
methods = '\n'.join(parts).replace('private ', '')
template = Path('tests/AutomaticSwitchWiringFixture.swift').read_text()
assert template.count('// PRODUCTION_METHODS') == 1
generated = OUT / 'AutomaticSwitchWiring.generated.swift'
generated_policy = OUT / 'AutomaticSwitchPolicy.generated.swift'
generated_resume_gates = OUT / 'AutomaticSwitchResumeGates.generated.swift'
final = section('                if isAutomaticSwitch {\n                    self.taskClient.refreshThreads()', '                var sourceBackupProfile:')
quota_gate = final[final.index('                    let quotaEligible ='):final.index('                    let legacyManagerRunning =')]
predicate = final[final.index('                    let preflightNow'):final.index('                    else {')]
predicate += ' else { return false }\n        return true\n'
probe = actions[actions.index('                        // Recheck immediately before writing;'):actions.index('                        try targetAuth.write(to: systemAuthURL, options: .atomic)')]
generated_policy.write_text(policy)
resume_gates = section('    @MainActor\n    static func runReadyQuotaResume(', '    @MainActor\n    private func canContinueQuotaResume(')
generated_resume_gates.write_text('import Foundation\nfinal class UsageStore {\n' + resume_gates + '}\n')
generated.write_text(template.replace('// PRODUCTION_METHODS', methods)
                     .replace('// PRODUCTION_FINAL_GATE', predicate)
                     .replace('// PRODUCTION_ATOMIC_PROBE', probe))
checks = {
    'one_shared_entry_call': parts[3].count('launchCodex(with: target.id)') == 1,
    'context_before_shared_entry': parts[3].index('automaticSwitchContext = AutomaticSwitchContext(') < parts[3].index('launchCodex(with: target.id)'),
    'always_read_complete_tasks': 'client.awaitSnapshot(timeout: 5)' in parts[1] and 'previousTasks' not in parts[1],
    'nil_invalidates_display': 'codexLiveTasks = .disconnected' in parts[1],
    'preparation_cleanup': 'defer {' in parts[1] and 'if !handedOff' in parts[1],
    'final_user_thresholds': 'currentQuota.triggeredWindows(thresholds: self.lowQuotaAlertThresholds)' in final,
    'final_complete_source': all(x in quota_gate for x in [
        'oneShotIntent.map { intent in',
        'CodexOneShotSwitchIntent.targetPlanMatches(',
        'intent.quotaPolicy.accepts(currentSystemSnapshot, target: false, now: preflightNow)',
        'intent.quotaPolicy.accepts(verifiedSnapshot, target: true, now: preflightNow)',
        '?? (currentQuota.hasCompleteApplicableWindows',
        '&& !triggeredWindows.isEmpty && targetIsEligible)',
    ]),
    'final_independent_task_evidence': 'let completeTasks = context.completeTasks' in final and 'hasSafeTaskState(\n                            completeTasks,' in final,
    'final_fingerprint': '== context.sourceAuthFingerprint' in final,
    'final_desktop_probe': 'runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty' in final,
    'throwing_desktop_probe_before_atomic_write': 'guard try Self.codexProcessIDs(appURL: appURL).isEmpty,' in actions[actions.index('// Recheck immediately before writing;'):actions.index('try targetAuth.write(to: systemAuthURL, options: .atomic)')],
    'resume_requires_confirmed_switch_and_history': 'guard switchSucceeded, pausedTasksConfirmed, historyConfirmed else { return }' in resume_gates,
    'resume_requires_ready_journal': 'guard store.isReady else { return }' in resume_gates,
}
(OUT / 'fixture-source-check.json').write_text(json.dumps({
    'kind': 'static only; not Swift execution', 'checks': checks,
    'generated_sha256': hashlib.sha256(generated.read_bytes()).hexdigest(),
    'policy_sha256': hashlib.sha256(generated_policy.read_bytes()).hexdigest(),
    'resume_gates_sha256': hashlib.sha256(generated_resume_gates.read_bytes()).hexdigest(),
}, indent=2)+'\n')
assert all(checks.values()), checks
if '--prepare-only' in sys.argv:
    print('PASS source extraction and static assertions; Swift NOT compiled or executed')
    sys.exit(0)

records = []
def run(command):
    started = time.monotonic()
    proc = subprocess.run(command, capture_output=True, text=True)
    # Replace only the workspace prefix in compiler diagnostics; keep relative evidence.
    records.append({'command': command, 'exit_code': proc.returncode, 'seconds': time.monotonic()-started,
                    'stdout': proc.stdout.replace(str(Path.cwd())+'/', ''),
                    'stderr': proc.stderr.replace(str(Path.cwd())+'/', '')})
    (OUT / 'fixture-execution.json').write_text(json.dumps(records, indent=2)+'\n')
    print('exit', proc.returncode, command[0])
    if proc.returncode:
        sys.exit(proc.returncode)

binary = str(OUT / 'AutomaticSwitchWiringFixture')
run(['python3', 'scripts/check-build-target-idle.py', binary])
run(['swiftc', '-swift-version', '5', '-module-cache-path', str(OUT / 'ModuleCache'),
     str(generated_policy), str(generated), '-o', binary])
run([binary])

flow_binary = str(OUT / 'AutomaticSwitchContinuationFlowFixture')
run(['python3', 'scripts/check-build-target-idle.py', flow_binary])
run(['swiftc', '-swift-version', '5', '-module-cache-path', str(OUT / 'ModuleCache'),
     str(generated_policy), str(generated_resume_gates),
     'Sources/CodexUsageWidget/Domain/CodexPausedDesktopTurn.swift',
     'Sources/CodexUsageWidget/Services/CodexDesktopQuotaPause.swift',
     'Sources/CodexUsageWidget/Services/CodexQuotaResumeStore.swift',
     'tests/AutomaticSwitchContinuationFlowFixture.swift', '-o', flow_binary])
run([flow_binary])
