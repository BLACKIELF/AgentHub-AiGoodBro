#!/usr/bin/env python3
"""Run verbatim production registration methods against offline Carbon/Settings doubles.

No Carbon/AppKit imports, application launch, live hotkeys, accounts or network.
"""
from pathlib import Path
import subprocess
import tempfile
import hashlib
import os

ROOT = Path(__file__).resolve().parent.parent


def extract(source, needle):
    start = source.index(needle)
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise RuntimeError(f'Unclosed declaration: {needle}')


app = (ROOT / 'Sources/CodexUsageWidget/App/AppLifecycle.swift').read_text()
shortcut = (ROOT / 'Sources/CodexUsageWidget/Domain/GlobalShortcut.swift').read_text()
methods = '\n'.join(extract(app, name) for name in [
    'private func registerGlobalHotKey(',
    'private func registerHotKeyReference(',
    'private func registerEdgeDockHotKey()',
    'private func unregisterGlobalHotKey()',
    'private func unregisterGlobalHotKeyReference()',
])
helper = '\n'.join([
    'enum Action { case mainWindow, edgeDock }',
    extract(shortcut, 'static func action('),
    extract(shortcut, 'static func shouldHideEdgeDock('),
    extract(shortcut, 'static func ensureEdgeDockRegistration('),
])

def extract_shortcut_constant(needle):
    start = shortcut.index(needle)
    opening = shortcut.index('(', start)
    depth = 0
    for index in range(opening, len(shortcut)):
        if shortcut[index] == '(':
            depth += 1
        elif shortcut[index] == ')':
            depth -= 1
            if depth == 0:
                return shortcut[start:index + 1]
    raise RuntimeError(f'Unclosed shortcut constant: {needle}')

constants = '\n'.join(extract_shortcut_constant(name) for name in [
    'static let `default` = GlobalShortcut(', 'static let edgeDock = GlobalShortcut('
])
# Enforce that the integration bypass cannot enter normal application behavior.
skip_name = 'CAMNEXT_SELF_TEST_SKIP_CARBON_INTEGRATION'
skip_uses = [p for p in (ROOT / 'Sources').rglob('*.swift') if skip_name in p.read_text()]
assert skip_uses == [ROOT / 'Sources/CodexUsageWidget/Domain/GlobalShortcutSelfTest.swift'], skip_uses
selftest = (ROOT / 'Sources/CodexUsageWidget/Domain/GlobalShortcutSelfTest.swift').read_text()
selftest_run = extract(selftest, 'static func run() -> Bool')
entry = (ROOT / 'Sources/CodexUsageWidget/main.swift').read_text()
assert 'exit(GlobalShortcutSelfTest.run() ? 0 : 1)' in extract(entry, 'if CommandLine.arguments.contains("--self-test-global-shortcut")')

stubs = r'''
import Foundation
// Deliberately no Carbon import: every external call is a recording double.
typealias OSType = UInt32
typealias OSStatus = Int32
typealias EventHotKeyRef = Int
typealias EventHandlerRef = Int
let noErr: OSStatus = 0
let eventHotKeyExistsErr: OSStatus = -9878
let kEventHotKeyExclusive = 1
let kVK_ANSI_U = 32
let kVK_ANSI_I = 34
let cmdKey = 256
struct EventHotKeyID { var signature: OSType; var id: UInt32 }
struct Call: Equatable {
    var key: UInt32; var modifiers: UInt32; var signature: OSType
    var id: UInt32; var target: Int; var options: UInt32
}
final class CarbonDouble {
    static let shared = CarbonDouble()
    var statuses: [OSStatus] = []
    var calls: [Call] = []
    var refs: [Int: UInt32] = [:]
    var unregistered: [Int] = []
    var removed: [Int] = []
    var nextRef = 100
    func reset() {
        statuses = []; calls = []; refs = [:]; unregistered = []; removed = []; nextRef = 100
    }
}
func RegisterEventHotKey(_ key: UInt32, _ modifiers: UInt32, _ hotKey: EventHotKeyID,
                         _ target: Int, _ options: UInt32, _ ref: inout EventHotKeyRef?) -> OSStatus {
    let c = CarbonDouble.shared
    c.calls.append(Call(key: key, modifiers: modifiers, signature: hotKey.signature,
                        id: hotKey.id, target: target, options: options))
    let status = c.statuses.isEmpty ? noErr : c.statuses.removeFirst()
    if status == noErr { c.nextRef += 1; ref = c.nextRef; c.refs[c.nextRef] = hotKey.id }
    return status
}
func GetApplicationEventTarget() -> Int { 17 }
@discardableResult func UnregisterEventHotKey(_ ref: EventHotKeyRef) -> OSStatus {
    let c = CarbonDouble.shared; c.unregistered.append(ref); c.refs.removeValue(forKey: ref); return noErr
}
func RemoveEventHandler(_ ref: EventHandlerRef) { CarbonDouble.shared.removed.append(ref) }
func fourCharCode(_ value: String) -> OSType { value.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
func debugLog(_ value: String) {}
enum GlobalShortcutRegistrationFailure: Error, Equatable { case occupied, failed }
struct GlobalShortcut {
    var keyCode: UInt32; var carbonModifiers: UInt32; var keyLabel: String
    var displayName: String { "synthetic" }
'''
fixture = r'''
}
final class Settings {
    var edgeDockShortcutError: String?
    var edgeDockShortcutRetry: (() -> Void)?
}
final class AppDelegate {
    var globalHotKeyRef: EventHotKeyRef?
    var edgeDockHotKeyRef: EventHotKeyRef?
    var globalHotKeyHandler: EventHandlerRef?
    let settings = Settings()
    var handlerStatus = true
    var handlerAttempts = 0
    func installGlobalHotKeyHandler() -> Bool {
        handlerAttempts += 1
        guard handlerStatus else { return false }
        if globalHotKeyHandler == nil { globalHotKeyHandler = 900 }
        return true
    }
    func registerMain() -> Bool { registerGlobalHotKey(.default) }
    func registerDock() { registerEdgeDockHotKey() }
    func stop() { unregisterGlobalHotKey() }
'''
tests = r'''
}
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ name: String) {
    if ok() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
let carbon = CarbonDouble.shared
carbon.reset()
let handlerFailure = AppDelegate()
handlerFailure.handlerStatus = false
handlerFailure.registerDock()
check(handlerFailure.settings.edgeDockShortcutError == "failed" && handlerFailure.edgeDockHotKeyRef == nil,
      "handler failure reports failed and keeps dock reference empty")
check(carbon.calls.isEmpty, "handler failure never reaches Carbon registration")
handlerFailure.handlerStatus = true
handlerFailure.registerDock()
check(handlerFailure.edgeDockHotKeyRef != nil && handlerFailure.settings.edgeDockShortcutError == nil,
      "handler failure can recover on retry")
handlerFailure.stop()
carbon.reset()
let app = AppDelegate()
check(app.registerMain(), "actual main registration succeeds")
let mainRef = app.globalHotKeyRef!
let mainCall = carbon.calls[0]
check(mainCall.id == 1 && carbon.refs[mainRef] == 1, "actual main Carbon ID is 1")
carbon.statuses = [eventHotKeyExistsErr, noErr]
app.registerDock()
check(app.settings.edgeDockShortcutError == "occupied" && app.edgeDockHotKeyRef == nil,
      "occupied dock registration leaves no dock reference")
check(app.globalHotKeyRef == mainRef && carbon.refs[mainRef] == 1 && carbon.unregistered.isEmpty,
      "occupied dock leaves actual main registration/reference untouched")
app.registerDock()
let dockRef = app.edgeDockHotKeyRef!
check(app.settings.edgeDockShortcutError == nil && carbon.refs[dockRef] == 3,
      "occupied-to-success retry stores actual dock Carbon reference with ID 3")
check(carbon.calls.dropFirst().allSatisfy { $0 == Call(key: 34, modifiers: 256, signature: 0x43414D4E,
                                                     id: 3, target: 17, options: 1) },
      "actual dock registration passes Command-I, CAMN, ID 3, application target, exclusive option")
let attempts = carbon.calls.count
let handlerAttempts = app.handlerAttempts
app.settings.edgeDockShortcutError = "occupied"
app.registerDock()
check(carbon.calls.count == attempts && app.handlerAttempts == handlerAttempts && app.edgeDockHotKeyRef == dockRef,
      "second successful registration is idempotent before handler and Carbon calls")
check(app.settings.edgeDockShortcutError == nil, "idempotent registration clears stale error")
check(app.globalHotKeyRef == mainRef && carbon.refs[mainRef] == 1 && carbon.calls[0] == mainCall,
      "actual main ID/reference/key remain unchanged after dock retry and repeat")
app.settings.edgeDockShortcutRetry = { app.registerDock() }
app.stop()
check(app.settings.edgeDockShortcutRetry == nil, "shutdown clears retry closure")
check(app.globalHotKeyRef == nil && app.edgeDockHotKeyRef == nil && app.globalHotKeyHandler == nil,
      "shutdown clears main/dock/handler references")
check(carbon.refs.isEmpty && carbon.unregistered == [mainRef, dockRef] && carbon.removed == [900],
      "shutdown unregisters exact recorded references and removes handler")
app.stop()
check(carbon.unregistered == [mainRef, dockRef] && carbon.removed == [900], "repeated shutdown is idempotent")
carbon.reset()
let failed = AppDelegate()
carbon.statuses = [-50, noErr]
failed.registerDock()
check(failed.settings.edgeDockShortcutError == "failed" && failed.edgeDockHotKeyRef == nil,
      "non-conflict Carbon failure reports failed")
failed.registerDock()
check(failed.settings.edgeDockShortcutError == nil && failed.edgeDockHotKeyRef != nil,
      "non-conflict failure can recover on retry")
failed.stop()
print("BOUNDARY: verbatim production registration/helper/cleanup methods; synthetic handler, Carbon and Settings; no live system integration")
exit(failures == 0 ? 0 : 1)
'''
print('SOURCE SHA256 app=' + hashlib.sha256(app.encode()).hexdigest() + ' shortcut=' + hashlib.sha256(shortcut.encode()).hexdigest(), flush=True)
skip_stubs = r'''
}
final class NSApplication { static let shared = NSApplication() }
enum GlobalShortcutSelfTest {
    static var integrationAttempts = 0
    private static func checkValidationRules(failures: inout [String]) {}
    private static func checkPersistence(failures: inout [String]) {}
    private static func checkSettingsMutations(failures: inout [String]) {}
    private static func checkInvalidStoredValues(failures: inout [String]) {}
    private static func checkReplacementTransaction(failures: inout [String]) {}
    private static func checkExclusiveConflictPreservesOldRegistration(failures: inout [String]) {
        integrationAttempts += 1  // Recording double: never registers a hotkey.
    }
'''
skip_tests = r'''
}
guard GlobalShortcutSelfTest.run() else { exit(1) }
let expected = Int(CommandLine.arguments[1])!
guard GlobalShortcutSelfTest.integrationAttempts == expected else { exit(2) }
print("PASS actual self-test run integration branch attempts=\(expected)")
'''
with tempfile.TemporaryDirectory(prefix='edge-dock-registration-') as temp:
    temp = Path(temp)
    source = temp / 'main.swift'
    source.write_text('\n'.join([stubs, constants, helper, fixture, methods, tests]))
    binary = temp / 'registration-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(temp / 'modules'),
                    str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    skip_source = temp / 'skip.swift'
    skip_binary = temp / 'skip-tests'
    skip_source.write_text('\n'.join([stubs, constants, helper, skip_stubs, selftest_run, skip_tests]))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(temp / 'modules'),
                    str(skip_source), '-o', str(skip_binary)], check=True)
    for skip_value, expected in [(None, 1), ('1', 0), ('true', 1)]:
        environment = dict(os.environ)
        environment.pop(skip_name, None)
        if skip_value is not None:
            environment[skip_name] = skip_value
        result = subprocess.run([str(skip_binary), str(expected)], env=environment, capture_output=True, text=True, check=True)
        assert ('SKIP Carbon exclusive-conflict integration:' in result.stdout) == (skip_value == '1'), result.stdout
        print(f'PASS actual self-test run skip={skip_value!r}: integration double attempts={expected}; explicit SKIP=' + str(skip_value == '1'))
print('PASS self-test integration skip is scoped to GlobalShortcutSelfTest and --self-test-global-shortcut exits before normal app startup')
