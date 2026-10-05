#!/usr/bin/env python3
"""Production installation/onboarding state against isolated synthetic macOS files.

No AppSettings initializer, GUI, standard defaults, credentials, or network.
Swift compilation and execution both have deadlines; diagnostics redact paths.
"""
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
INPUTS = [
    'Sources/CodexUsageWidget/Services/AppInstallationState.swift',
    'Sources/CodexUsageWidget/Domain/NextSetup.swift',
    'Sources/CodexUsageWidget/Domain/WorkspaceOnboardingState.swift',
]

SWIFT = r'''
import Foundation
import Darwin

enum WidgetLanguage { case fixture; func text(_ a: String, _ b: String) -> String { b } }
enum WorkspaceDisplayMode: String, Equatable {
    case simple, professional
    static let storageKey = "CodexManagerNext.workspaceDisplayMode"
}

var assertions = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    assertions += 1
    if condition() { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func isolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "fixture.installation.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { fatalError("synthetic defaults unavailable") }
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}
func existingUser(defaults: UserDefaults, onboarding: WorkspaceOnboardingState) -> Bool {
    let loadedOnboarding = onboarding
    let storedPinnedAccountKey = defaults.string(forKey: "CodexManagerNext.pinnedAccountKey")
    EXISTING_USER_PRODUCTION
    return existingUser
}

let manager = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let app = root.appendingPathComponent("Synthetic.app", isDirectory: true)
let receiptURL = root.appendingPathComponent("synthetic-receipt.json")
let bytes = Data("synthetic executable bytes\n".utf8)
let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
func createApp(at url: URL) throws {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    let executable = contents.appendingPathComponent("MacOS/Synthetic")
    try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "fixture.installation.synthetic", "CFBundleExecutable": "Synthetic", "CFBundlePackageType": "APPL", "CFBundleVersion": "126", "CFBundleShortVersionString": "1.26"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    try bytes.write(to: executable)
    try manager.setAttributes([.posixPermissions: 0o700, .modificationDate: fixedDate], ofItemAtPath: executable.path)
    try manager.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
}
func observe() -> AppInstallationContext {
    guard let bundle = Bundle(url: app) else { fatalError("synthetic bundle unavailable") }
    return .observe(bundle: bundle, receiptURL: receiptURL)
}
func receipt(_ identity: AppInstallationIdentity, id: String = "11111111-2222-3333-4444-555555555555") -> AppInstallationReceipt {
    .init(schemaVersion: 1, installationID: id, bundleIdentifier: identity.bundleIdentifier, bundleIdentity: identity.bundle, executableIdentity: identity.executable)
}
func writeReceipt(_ value: AppInstallationReceipt) throws {
    try JSONEncoder().encode(value).write(to: receiptURL)
}
func removeReceipt() throws {
    if manager.fileExists(atPath: receiptURL.path) { try manager.removeItem(at: receiptURL) }
}

do {
    try createApp(at: app)
    let first = observe()
    guard let originalIdentity = first.identity else { fatalError("synthetic identity unavailable") }
    check(first.receipt == nil, "real observation without receipt returns file identity")
    check(observe().identity == originalIdentity, "same files have stable observed identity")
    var fresh = InstallationOnboardingState()
    fresh.observe(first, existingUser: false)
    check(fresh.scope == .full && fresh.status == .pending && fresh.shouldPresent, "fresh user receives full guide")
    check(fresh.installationID == originalIdentity.eventID, "baseline event derives from observed file identity")
    fresh.observe(first, existingUser: false)
    check(fresh.scope == .full, "same baseline does not downgrade full scope")

    for outcome in [NextSetupGuideOutcome.completed, .deferred] {
        var state = fresh
        state.finish(outcome, scope: .full)
        let terminal = state
        state.observe(first, existingUser: false)
        check(state == terminal && !state.shouldPresent, "same file event retains terminal outcome \(state.status.rawValue)")
        try isolatedDefaults { defaults in
            state.save(to: defaults)
            var restored = InstallationOnboardingState.load(from: defaults)
            restored.observe(first, existingUser: true)
            check(restored == terminal, "persisted terminal event survives restart \(state.status.rawValue)")
        }
    }
    try isolatedDefaults { defaults in
        for key in ["CodexManagerNext.setup.completed", "CodexManagerNext.setup.dismissed"] {
            defaults.set(true, forKey: key)
            var state = InstallationOnboardingState()
            state.observe(first, existingUser: existingUser(defaults: defaults, onboarding: .init()))
            check(state.scope == .connections && state.shouldPresent, "legacy terminal setup starts baseline connection guide \(key.hasSuffix("completed") ? "completed" : "dismissed")")
            defaults.removeObject(forKey: key)
        }
        var migrated = WorkspaceOnboardingState()
        migrated.bootstrapIfNeeded(existingUser: true)
        check(migrated.status == .completed && migrated.existingUserMigrated && migrated.selectedMode == .professional, "existing workspace migration remains terminal")
        var state = InstallationOnboardingState()
        state.observe(first, existingUser: existingUser(defaults: defaults, onboarding: migrated))
        check(state.scope == .connections, "migrated workspace qualifies as existing user")
    }

    try Data("{temporarily unreadable synthetic receipt".utf8).write(to: receiptURL)
    let unavailableReceipt = observe()
    check(unavailableReceipt.identity == originalIdentity && unavailableReceipt.receipt == nil, "temporarily unreadable receipt still observes matching file identity")
    try writeReceipt(receipt(originalIdentity))
    let withReceipt = observe()
    check(withReceipt.receipt?.matchingID(for: originalIdentity) == "11111111-2222-3333-4444-555555555555", "real matching receipt yields installation UUID")
    for wasExistingUser in [false, true] {
        for status in [InstallationOnboardingState.Status.pending, .completed, .deferred] {
            var state = InstallationOnboardingState()
            state.observe(unavailableReceipt, existingUser: wasExistingUser)
            state.connectionStep = .ready
            if status == .completed { state.finish(.completed, scope: state.scope) }
            if status == .deferred { state.finish(.deferred, scope: state.scope) }
            let previous = state
            let label = "\(previous.scope.rawValue) \(status.rawValue)"
            try isolatedDefaults { defaults in
                state.save(to: defaults)
                state = InstallationOnboardingState.load(from: defaults)
                state.observe(withReceipt, existingUser: true)
                check(state.installationID == "11111111-2222-3333-4444-555555555555", "readable receipt absorbs UUID after file baseline \(label)")
                check(state.status == previous.status && state.scope == previous.scope && state.connectionStep == previous.connectionStep && state.observedIdentity == previous.observedIdentity, "readable receipt preserves status scope step identity \(label)")
                check(state.shouldPresent == previous.shouldPresent, "readable receipt preserves presentation decision \(label)")
                state.save(to: defaults)
                check(InstallationOnboardingState.load(from: defaults) == state, "absorbed receipt UUID persists without outcome reset \(label)")
            }
        }
    }
    var receiptState = InstallationOnboardingState()
    receiptState.observe(withReceipt, existingUser: false)
    for outcome in [NextSetupGuideOutcome.completed, .deferred] {
        var state = receiptState
        state.finish(outcome, scope: .full)
        let terminal = state
        state.observe(observe(), existingUser: false)
        check(state == terminal, "same receipt retains terminal outcome \(state.status.rawValue)")
    }
    receiptState.finish(.completed, scope: .full)
    try writeReceipt(receipt(originalIdentity, id: "66666666-7777-8888-9999-aaaaaaaaaaaa"))
    receiptState.observe(observe(), existingUser: false)
    check(receiptState.scope == .connections && receiptState.status == .pending && receiptState.shouldPresent, "new receipt UUID retriggers same-version same-files connection guide")
    check(receiptState.installationID == "66666666-7777-8888-9999-aaaaaaaaaaaa", "new receipt ID persisted independently of version")
    receiptState.finish(.deferred, scope: .connections)
    let beforeMissing = receiptState
    try removeReceipt()
    receiptState.observe(observe(), existingUser: false)
    check(receiptState == beforeMissing, "missing receipt with same identity does not reopen terminal guide")
    try isolatedDefaults { defaults in
        receiptState.save(to: defaults)
        var restored = InstallationOnboardingState.load(from: defaults)
        restored.observe(.init(identity: nil, receipt: nil), existingUser: false)
        restored.save(to: defaults)
        check(InstallationOnboardingState.load(from: defaults) == beforeMissing, "nil identity leaves saved installation state unchanged")
    }

    let replacement = root.appendingPathComponent("Replacement.app", isDirectory: true)
    try createApp(at: replacement)
    // Keep original files alive so the filesystem cannot recycle their inodes.
    try manager.moveItem(at: app, to: root.appendingPathComponent("Previous.app", isDirectory: true))
    try manager.moveItem(at: replacement, to: app)
    let replaced = observe()
    guard let replacementIdentity = replaced.identity else { fatalError("replacement identity unavailable") }
    check(replacementIdentity.bundle != originalIdentity.bundle && replacementIdentity.executable != originalIdentity.executable, "Finder-style copied bundle changes observed directory and executable inode")
    let exec = app.appendingPathComponent("Contents/MacOS/Synthetic")
    let replacementBytes = try Data(contentsOf: exec)
    check(replacementBytes == bytes, "replacement executable preserves content")
    let attrs = try manager.attributesOfItem(atPath: exec.path)
    check(attrs[.modificationDate] as? Date == fixedDate, "replacement executable preserves modification time")
    check(Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "126", "replacement keeps same version")
    var copiedState = beforeMissing
    copiedState.observe(replaced, existingUser: false)
    check(copiedState.shouldPresent && copiedState.scope == .connections && copiedState.installationID == replacementIdentity.eventID, "new inode retriggers connection guide despite identical version mtime content")
    try writeReceipt(receipt(originalIdentity))
    let stale = observe()
    check(stale.receipt?.matchingID(for: replacementIdentity) == nil, "old receipt identity mismatch ignored")
    let unchangedCopied = copiedState
    copiedState.observe(stale, existingUser: false)
    check(copiedState == unchangedCopied, "mismatched receipt does not replace matching current file event")
    var baseline = InstallationOnboardingState()
    baseline.observe(stale, existingUser: true)
    check(baseline.installationID == replacementIdentity.eventID, "mismatched old receipt falls back to current observed file event")
    var wrongReceipt = receipt(replacementIdentity)
    wrongReceipt.schemaVersion = 2
    check(wrongReceipt.matchingID(for: replacementIdentity) == nil, "unsupported receipt schema ignored")
    wrongReceipt = receipt(replacementIdentity, id: "invalid-fixture-uuid")
    check(wrongReceipt.matchingID(for: replacementIdentity) == nil, "invalid receipt UUID ignored")
    wrongReceipt = receipt(replacementIdentity)
    wrongReceipt.bundleIdentifier = "fixture.other"
    check(wrongReceipt.matchingID(for: replacementIdentity) == nil, "receipt bundle identifier mismatch ignored")

    try removeReceipt()
    var limitReceipt = try JSONEncoder().encode(receipt(replacementIdentity))
    limitReceipt.append(Data(repeating: 32, count: 16_384 - limitReceipt.count))
    try limitReceipt.write(to: receiptURL)
    check(observe().receipt?.matchingID(for: replacementIdentity) != nil, "valid receipt at exact size limit accepted")
    try Data(repeating: 65, count: 16_385).write(to: receiptURL)
    check(observe().receipt == nil, "oversized receipt rejected")
    try Data("{malformed synthetic JSON".utf8).write(to: receiptURL)
    check(observe().receipt == nil, "malformed receipt rejected")
    try removeReceipt()
    try manager.createDirectory(at: receiptURL, withIntermediateDirectories: false)
    check(observe().receipt == nil, "directory receipt rejected")
    try removeReceipt()
    let symlinkTarget = root.appendingPathComponent("synthetic-valid-receipt.json")
    try JSONEncoder().encode(receipt(replacementIdentity)).write(to: symlinkTarget)
    try manager.createSymbolicLink(at: receiptURL, withDestinationURL: symlinkTarget)
    check(observe().receipt == nil, "symlink receipt rejected even when target is valid")
    try removeReceipt()
    check(mkfifo(receiptURL.path, 0o600) == 0, "synthetic FIFO created")
    let started = Date()
    check(observe().receipt == nil && Date().timeIntervalSince(started) < 2, "FIFO receipt rejected without waiting for writer")
    try removeReceipt()

    var noEvent = InstallationOnboardingState()
    noEvent.observe(.init(identity: nil, receipt: nil), existingUser: false)
    noEvent.finish(.completed, scope: .full)
    check(noEvent.installationID == nil && noEvent.status == .pending && !noEvent.shouldPresent, "nil initial identity and finish create no installation event")
    var pending = copiedState
    pending.finish(.completed, scope: .full)
    check(pending == copiedState, "full finish cannot finish connection scope")
    pending.finish(.deferred, scope: .full)
    check(pending == copiedState, "full defer cannot defer connection scope")
    var full = fresh
    full.finish(.completed, scope: .connections)
    check(full == fresh, "connection finish cannot finish full scope")
    full.finish(.deferred, scope: .connections)
    check(full == fresh, "connection defer cannot defer full scope")
    try isolatedDefaults { defaults in
        // Closing a presentation without an explicit outcome persists pending state.
        pending.save(to: defaults)
        let reopened = InstallationOnboardingState.load(from: defaults)
        check(reopened.status == .pending && reopened.shouldPresent, "presentation close without finish preserves pending event")
        pending.connectionStep = .ready
        pending.save(to: defaults)
        check(InstallationOnboardingState.load(from: defaults) == pending, "connection ready step persists and restores")
        pending.connectionStep = .accounts
        pending.save(to: defaults)
        check(InstallationOnboardingState.load(from: defaults).connectionStep == .notifications, "invalid saved connection step normalizes to notifications")
        let legacyJSON = Data(#"{"schemaVersion":1,"status":"inProgress","step":"connect","selectedMode":"simple","selectedProviderID":"fixture-provider","existingUserMigrated":false}"#.utf8)
        defaults.set(legacyJSON, forKey: WorkspaceOnboardingState.storageKey)
        var backup: Data?
        let legacy = WorkspaceOnboardingState.load(defaults.data(forKey: WorkspaceOnboardingState.storageKey), backupRaw: &backup)
        check(legacy.status == .inProgress && legacy.step == .connect && legacy.selectedMode == .simple && legacy.selectedProviderID == "fixture-provider" && backup == nil, "legacy full onboarding JSON still decodes")
        pending.connectionStep = .ready
        pending.save(to: defaults)
        check(defaults.data(forKey: WorkspaceOnboardingState.storageKey) == legacyJSON, "installation save does not modify legacy full JSON")
        check(InstallationOnboardingState.storageKey != WorkspaceOnboardingState.storageKey, "installation and legacy JSON use separate storage keys")
        for step in NextSetupStep.allCases {
            NextSetupProgress(step: step).save(to: defaults)
            check(NextSetupProgress.load(from: defaults).step == step, "legacy setup step roundtrip raw value \(step.rawValue)")
        }
    }
    check(NextSetupStep.accounts.rawValue == 0 && NextSetupStep.features.rawValue == 1 && NextSetupStep.notifications.rawValue == 2 && NextSetupStep.ready.rawValue == 3 && NextSetupStep.runtime.rawValue == 4, "persisted legacy step raw values unchanged")
    check(NextSetupGuideScope.full.steps == [.accounts, .runtime, .features, .notifications, .ready], "full scope keeps intended page order")
    check(NextSetupGuideScope.connections.steps == [.notifications, .ready], "connection scope contains only notification and ready pages")
    check(NextSetupGuideScope.connections.previous(.notifications) == .notifications && NextSetupGuideScope.connections.next(.notifications) == .ready && NextSetupGuideScope.connections.previous(.ready) == .notifications && NextSetupGuideScope.connections.next(.ready) == .ready, "connection navigation remains within scope")
    check(NextSetupGuideScope.full.next(.accounts) == .runtime && NextSetupGuideScope.full.previous(.runtime) == .accounts, "full navigation honors runtime insertion")
    for hasEvent in [false, true] {
        for hasIdentity in [false, true] {
            for scope in [NextSetupGuideScope.full, .connections] {
                for status in [InstallationOnboardingState.Status.pending, .completed, .deferred] {
                    for legacyPending in [false, true] {
                        let state = InstallationOnboardingState(
                            installationID: hasEvent ? originalIdentity.eventID : nil,
                            observedIdentity: hasIdentity ? originalIdentity : nil,
                            scope: scope, status: status)
                        let expected: NextSetupGuideScope?
                        if hasEvent {
                            expected = status == .pending ? scope : nil
                        } else {
                            expected = legacyPending ? .full : nil
                        }
                        check(state.automaticScope(legacyShouldPresent: legacyPending) == expected,
                              "automatic scope event=\(hasEvent) identity=\(hasIdentity) scope=\(scope.rawValue) status=\(status.rawValue) legacy=\(legacyPending)")
                    }
                }
            }
        }
    }
    var oldFull = WorkspaceOnboardingState()
    oldFull.begin()
    for outcome in [NextSetupGuideOutcome.completed, .deferred] {
        var connection = copiedState
        connection.finish(outcome, scope: .connections)
        check(oldFull.shouldPresent && connection.automaticScope(legacyShouldPresent: oldFull.shouldPresent) == nil,
              "terminal connection event suppresses unfinished legacy full fallback \(connection.status.rawValue)")
    }
} catch {
    failures += 1
    print("FAIL synthetic fixture threw \(String(describing: type(of: error)))")
}
print("ASSERTIONS \(assertions); FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
'''


def run(args, temp, env, timeout):
    try:
        result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print('FAIL synthetic fixture deadline exceeded')
        sys.exit(1)
    output = (result.stdout + result.stderr).replace(str(ROOT), '<repo>').replace(str(temp), '<temp>').replace(str(Path.home()), '<home>')
    print(output, end='')
    if result.returncode:
        sys.exit(result.returncode)


# Run the actual existing-user predicate without constructing AppSettings.
settings = (ROOT / 'Sources/CodexUsageWidget/Services/AppSettings.swift').read_text()
start = settings.index('        let existingUser =\n')
end = settings.index('        workspaceDisplayMode =', start)
predicate = settings[start:end]
assert 'loadedOnboarding.status != .notStarted' in predicate
# Verify the real view calls the tested production decision, instead of duplicating it.
view = (ROOT / 'Sources/CodexUsageWidget/UI/CodexAccountManagerView.swift').read_text()
wire = 'if let scope = settings.installationOnboarding.automaticScope(legacyShouldPresent: settings.onboarding.shouldPresent) {'
assert wire in view, 'Production onAppear must use the tested automaticScope decision'
wire_start = view.index(wire)
assert 'if !store.isPreview && !hasCheckedAutomaticGuide {' in view[max(0, wire_start - 200):wire_start]
assert 'setupGuideScope = scope' in view[wire_start:wire_start + 320]
print('PASS production onAppear calls automaticScope and projects returned scope')
swift = SWIFT.replace('EXISTING_USER_PRODUCTION', predicate)
snapshots = {relative: (ROOT / relative).read_bytes() for relative in INPUTS}
for relative, data in snapshots.items():
    print('SOURCE ' + Path(relative).name + ' SHA256 ' + hashlib.sha256(data).hexdigest())
print('SOURCE AppSettings.existingUser SHA256 ' + hashlib.sha256(predicate.encode()).hexdigest())
print('SOURCE CodexAccountManagerView.automaticScope-call SHA256 ' + hashlib.sha256(view[wire_start:wire_start + 320].encode()).hexdigest())
with tempfile.TemporaryDirectory(prefix='install-onboarding-fixture-') as folder:
    temp = Path(folder).resolve()
    fixture = temp / 'main.swift'
    fixture.write_text(swift)
    sources = []
    for relative, data in snapshots.items():
        source = temp / Path(relative).name
        source.write_bytes(data)
        sources.append(str(source))
    env = dict(os.environ, TMPDIR=str(temp) + '/', CLANG_MODULE_CACHE_PATH=str(temp / 'modules'))
    binary = temp / 'fixture'
    run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(temp / 'modules'), *sources, str(fixture), '-o', str(binary)], temp, env, 120)
    run([str(binary), str(temp / 'files')], temp, env, 30)
print('BOUNDARY: complete production state files and existing-user predicate; synthetic Bundle/files/random defaults; presentation-close check covers state persistence, not native window callback; no app, credentials, network, or installation')
