#!/usr/bin/env python3
"""Compile the production AppSettings initializer and display models in isolation.

No app launch, standard-defaults access, account reads, Keychain or network.
Unrelated palette/navigation validation dependencies are explicit fixture doubles.
"""
from pathlib import Path
import hashlib
import os
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = 'Sources/CodexUsageWidget/'
FULL = [
    'Services/AppSettings.swift',
    'Services/AppInstallationState.swift',
    'Domain/PortableFirstRunPreferences.swift',
    'Domain/PortableFirstRunPreferencesSelfTest.swift',
    'Domain/StatusItemPreferences.swift',
    'Domain/WorkspaceGlassPreferences.swift',
    'Domain/HomeDashboardPreferences.swift',
    'Domain/GlobalShortcut.swift',
    'Domain/WorkspaceOnboardingState.swift',
    'Domain/NextSetup.swift',
    'Domain/TokenFormatter.swift',
    'Domain/AppIconStyle.swift',
]
SLICES = [
    ('Domain/TokenMonitorEngineModels.swift', 'enum StatisticsEngineChoice:', 'enum TokenMonitorOperation:'),
    ('Domain/ModelUsageTrend.swift', 'enum UsageTrendWindow:', 'struct ModelUsageMetricSummary:'),
    ('UI/WorkspaceModuleLayout.swift', 'struct WorkspaceModuleArrangement:', 'private struct ModuleSpan:'),
    ('Domain/TokenMonitorEdgeDockModels.swift', 'enum TokenMonitorEdgeDockScreenTarget', 'struct TokenMonitorEdgeDockQuotaRow:'),
    ('Domain/TokenMonitorFloatingBubbleGeometry.swift', 'struct TokenMonitorFloatingBubblePreferences:', 'struct TokenMonitorFloatingBubbleSnapshot:'),
    ('Domain/AgentRuntime.swift', 'enum RuntimeScope:', 'enum RuntimeMenuStatus:'),
    ('Domain/AgentNavigationPreferences.swift', 'struct AgentNavigationState:', 'enum AgentNavCatalog'),
    ('Domain/AccountAvatarPreference.swift', 'enum AccountAvatarMode:', 'enum ProviderIconSlot:'),
    ('Domain/CodexResetCreditAuto.swift', 'struct CodexResetCreditAutoPreferences:', '/// Cancellation'),
]
DOUBLES = r'''
import Foundation
struct PaletteCatalog {
    static let initialPaletteID = "codexu.default"
    static let defaultPaletteID = "codexu.default"
    static func loadFromMainBundle() -> Self { .init() }
    func contains(_ id: String) -> Bool { id == Self.defaultPaletteID }
}
enum AgentNavCatalog {
    static let homeID = "home"
    static func isRenderable(_ id: String) -> Bool { false }
    static func isAddable(_ id: String) -> Bool { false }
}
enum TokenMonitorResponse { static func validDate(_ value: String) -> Bool { false } }
enum TokenMonitorSource { static func safeID(_ value: String) -> Bool { false } }
enum DispatchActivityStore { static func hash(_ value: String) -> String { "" } }
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL { fatalError("fixture attempted real support-directory discovery") }
}
'''
MAIN = r'''
import Cocoa
import Foundation
if NSApp != nil { fatalError("fixture must not create NSApplication") }
exit(PortableFirstRunPreferencesSelfTest.run() ? 0 : 1)
'''


def run(args, temp, env, timeout):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    output = (result.stdout + result.stderr).replace(str(ROOT), '<repo>').replace(str(temp), '<temp>').replace(str(Path.home()), '<home>')
    print(output, end='')
    if result.returncode:
        sys.exit(result.returncode)


snapshots = {relative: (ROOT / (BASE + relative)).read_text() for relative in FULL}
for relative, start, end in SLICES:
    text = (ROOT / (BASE + relative)).read_text()
    snapshots[relative] = 'import Cocoa\nimport Foundation\n' + text[text.index(start):text.index(end, text.index(start))]
settings = snapshots['Services/AppSettings.swift']
assert re.search(r'let existingUser =\s+hasExistingUser\s+\?\? PortableFirstRunPreferences.hasExistingUser\(', settings)
assert settings.index('let existingUser =') < settings.index('PortableFirstRunPreferences.seedIfNeeded') < settings.index('self.defaults = defaults')
lifecycle = (ROOT / (BASE + 'App/AppLifecycle.swift')).read_text()
assert lifecycle.index('hadExistingUserAtStartup = PortableFirstRunPreferences.prepareForStartup(') < lifecycle.index('private let store = UsageStore()')
assert 'hasExistingUser: hadExistingUserAtStartup' in lifecycle
print('PASS AppSettings checks user state before seeding; normal startup persists recovery before generated service state')
with tempfile.TemporaryDirectory(prefix='portable-first-run-fixture-') as folder:
    temp = Path(folder).resolve()
    sources = []
    for index, (relative, text) in enumerate(snapshots.items()):
        source = temp / f'{index}-{Path(relative).name}'
        source.write_text(text)
        sources.append(str(source))
        print('SOURCE ' + Path(relative).name + ' SHA256 ' + hashlib.sha256(text.encode()).hexdigest())
    dependencies = temp / 'FixtureDependencies.swift'
    dependencies.write_text(DOUBLES)
    main = temp / 'main.swift'
    main.write_text(MAIN)
    env = dict(os.environ, TMPDIR=str(temp) + '/', CLANG_MODULE_CACHE_PATH=str(temp / 'modules'))
    binary = temp / 'fixture'
    run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(temp / 'modules'), *sources, str(dependencies), str(main), '-o', str(binary)], temp, env, 120)
    run([str(binary)], temp, env, 30)
print('BOUNDARY: production AppSettings, display codecs, shortcuts and state machines; isolated suites and files; unrelated dependencies doubled; no complete app build, GUI, real preferences, account contents, credentials or network')
