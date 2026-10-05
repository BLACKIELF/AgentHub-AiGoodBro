#!/usr/bin/env python3
"""Frozen production drag/configure/observer regression with synthetic UI/screens.

The B callback is delivered before the coalesced observer consumes B, matching
settings' debounce window. Both callbacks are exercised; reset-removal mutants
must fail the same A restoration assertion. No window/application is launched.
"""
from pathlib import Path
import subprocess
import tempfile
import hashlib

ROOT = Path(__file__).resolve().parent.parent


def extract(source, needle, start_at=0):
    start = source.index(needle, start_at)
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


# Read each production file once: all normal and negative runs share this snapshot.
app = (ROOT / 'Sources/CodexUsageWidget/App/AppLifecycle.swift').read_text()
controller = (ROOT / 'Sources/CodexUsageWidget/Services/TokenMonitorEdgeDockController.swift').read_text()
model = (ROOT / 'Sources/CodexUsageWidget/Domain/TokenMonitorEdgeDockModels.swift').read_text()
models = '\n'.join(extract(model, name) for name in [
    'enum TokenMonitorEdgeDockScreenTarget {',
    'struct TokenMonitorEdgeDockPreferences:',
    'struct TokenMonitorEdgeDockItem:',
    'struct TokenMonitorEdgeDockChangeGate<',
])
safe_id = extract((ROOT / 'Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift').read_text(), 'static func safeID(')
geometry = extract(controller, 'enum TokenMonitorEdgeDockNativeGeometry {')
configuration = extract(controller, 'private struct Configuration:')
configure = extract(controller, '    func configure(')
drop = extract(controller, 'private func dropRail(')
sync = extract(app, 'private func syncEdgeDockIfChanged()')
sync_body = extract(app, 'private func syncEdgeDock()')
callbacks = []
position = 0
while True:
    try:
        position = sync_body.index('onPreferencesChange:', position)
    except ValueError:
        break
    callback = extract(sync_body, 'onPreferencesChange:', position)
    callbacks.append(callback[len('onPreferencesChange:'):].strip())
    position += len(callback)
assert len(callbacks) == 2, 'Expected both disabled and enabled production configure callbacks'

stubs = r'''
import Foundation
import CoreGraphics
// Geometry Foundation types only; no AppKit/SwiftUI imports or actual screen/window access.
typealias NSRect = CGRect
typealias NSPoint = CGPoint
enum WidgetLanguage: Equatable {
    case zh
    func text(_ zh: String, _ en: String) -> String { en }
}
struct WorkspaceGlassPreferences: Equatable {}
struct PaletteCatalog { static let defaultPaletteID = "fixture" }
enum ColorScheme: Equatable { case light, dark }
struct TokenMonitorEdgeDockCell: Equatable { var id: String }
final class NSScreen {
    let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    var visibleFrame: CGRect { frame }
}
enum TokenMonitorEdgeDockScreenCatalog {
    struct Entry { var screen: NSScreen; var identity: TokenMonitorEdgeDockScreenTarget.Identity }
    static let fixture = Entry(screen: NSScreen(), identity: .init(numericID: 1, uuid: nil, isBuiltIn: true))
    static func connected() -> [Entry] { [fixture] }
}
'''
controller_stubs = r'''
final class TokenMonitorEdgeDockController {
    struct Layout { let screen: NSScreen; let workArea: CGRect; let rail: CGRect }
    private var preferences = TokenMonitorEdgeDockPreferences()
    private var cells: [TokenMonitorEdgeDockCell] = []
    private var language: WidgetLanguage = .zh
    private var glass = WorkspaceGlassPreferences()
    private var paletteCatalog = PaletteCatalog()
    private var paletteID = PaletteCatalog.defaultPaletteID
    private var preferredColorScheme: ColorScheme?
    private var onPreferencesChange: ((TokenMonitorEdgeDockPreferences) -> Void)?
    private var onOpenDashboard: (() -> Void)?
    private var onOpenUsageOverview: (() -> Void)?
    private var onOpenProxy: (() -> Void)?
    private var onRefresh: ((TokenMonitorEdgeDockCell) async -> Void)?
    private var configurationGate = TokenMonitorEdgeDockChangeGate<Configuration>()
    private var cardIndex: Int?
    private var cardPinned = false
    private var railPinned = false
    private var railVisible = false
    private var layout: Layout?
    private var dragStart: CGRect?
    private var isDragging = false
    var surfaceUpdates = 0
    var timerRequests = 0
    var snapshot: TokenMonitorEdgeDockPreferences { preferences }
    func hideAll() {}
    func observeScreenChanges() {}
    func ensurePanels() {}
    func updateSurfaces() { surfaceUpdates += 1 }
    func suspendForMissingScreen() {}
    func scheduleTick() { timerRequests += 1 }
    func refreshScreenLayout() {}
    // UI layout is peripheral here; use production geometry with one synthetic screen.
    private func makeLayout(using screens: [TokenMonitorEdgeDockScreenCatalog.Entry]) -> Layout? {
        let screen = screens[0].screen
        let rail = TokenMonitorEdgeDockNativeGeometry.railFrame(
            workArea: screen.visibleFrame, side: preferences.side, offset: preferences.offset, height: 250)
        return Layout(screen: screen, workArea: screen.visibleFrame, rail: rail)
    }
    func drag(_ translation: CGSize) {
        dragStart = layout?.rail
        isDragging = true
        dropRail(translation)
    }
    var hasActiveDrag: Bool { dragStart != nil || isDragging }
'''
app_stubs = r'''
}
final class Settings {
    var writes = 0
    var edgeDock = TokenMonitorEdgeDockPreferences(enabled: true) { didSet { writes += 1 } }
}
final class AppDelegate {
    let settings = Settings()
    let edgeDockController = TokenMonitorEdgeDockController()
    private var edgeDockInputGate = TokenMonitorEdgeDockChangeGate<TokenMonitorEdgeDockPreferences>()
    var syncCount = 0
    var callbackVariant = 0
    func edgeDockInput() -> TokenMonitorEdgeDockPreferences { settings.edgeDock }
    func observe() { syncEdgeDockIfChanged() }
    private func syncEdgeDock() {
        syncCount += 1
        let callback: (TokenMonitorEdgeDockPreferences) -> Void
        if callbackVariant == 0 {
            callback = CALLBACK_DISABLED
        } else {
            callback = CALLBACK_ENABLED
        }
        edgeDockController.configure(
            preferences: settings.edgeDock, cells: [.init(id: "synthetic")], language: .zh,
            onPreferencesChange: callback, onOpenDashboard: {}, onOpenUsageOverview: {}, onOpenProxy: {})
    }
'''
tests = r'''
}
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ name: String) {
    if ok() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
for variant in 0...1 {
    let app = AppDelegate()
    app.callbackVariant = variant
    let label = variant == 0 ? "disabled-callsite closure" : "enabled-callsite closure"
    let a = app.settings.edgeDock
    app.observe()
    let initialUpdates = app.edgeDockController.surfaceUpdates
    let initialTimerRequests = app.edgeDockController.timerRequests
    app.observe()
    check(app.syncCount == 1 && app.edgeDockController.surfaceUpdates == initialUpdates
          && app.edgeDockController.timerRequests == initialTimerRequests,
          "\(label): A-to-A input deduplicates projection/UI/timer")
    app.edgeDockController.drag(CGSize(width: -1000, height: 100))
    let b = app.edgeDockController.snapshot
    check(b != a && app.settings.edgeDock == b, "\(label): actual dropRail mutates A to B and production callback persists B")
    check(!app.edgeDockController.hasActiveDrag, "\(label): actual dropRail clears drag state")
    // Do NOT observe B: the 220ms debounced settings event has not fired yet.
    app.settings.edgeDock = a
    app.observe()
    check(app.edgeDockController.snapshot == a, "\(label): restoring A before B observer consumption restores controller A")
    let restoredSyncs = app.syncCount
    let restoredUpdates = app.edgeDockController.surfaceUpdates
    app.observe()
    check(app.syncCount == restoredSyncs && app.edgeDockController.surfaceUpdates == restoredUpdates,
          "\(label): restored A-to-A remains deduplicated")
    // A zero drag must not invalidate gates or issue a callback for identical prefs.
    app.edgeDockController.drag(.zero)
    let zeroDragSyncs = app.syncCount
    app.observe()
    check(app.syncCount == zeroDragSyncs, "\(label): unchanged drop keeps observer deduplication")

    // Independently seed settings B before the same real drop: no observer B
    // consumption, and the callback receives B equal to settings' current B.
    let equalApp = AppDelegate()
    equalApp.callbackVariant = variant
    equalApp.observe()
    equalApp.settings.edgeDock = b
    let beforeCallbackWrites = equalApp.settings.writes
    equalApp.edgeDockController.drag(CGSize(width: -1000, height: 100))
    check(equalApp.edgeDockController.snapshot == b && equalApp.settings.edgeDock == b,
          "\(label): callback B equals already-pending settings B")
    check(equalApp.settings.writes == beforeCallbackWrites,
          "\(label): equal callback avoids duplicate settings publication")
    equalApp.settings.edgeDock = a
    equalApp.observe()
    check(equalApp.edgeDockController.snapshot == a,
          "\(label): restoring A before B observer consumption restores controller A (equal-settings callback)")
    let equalRestoredSyncs = equalApp.syncCount
    equalApp.observe()
    check(equalApp.syncCount == equalRestoredSyncs, "\(label): equal-callback restored A-to-A deduplicates")
}
exit(failures == 0 ? 0 : 1)
'''


def fixture(mutant):
    mutated_callbacks = callbacks
    mutated_drop = drop
    if mutant == 'without-outer-reset':
        assert all('self.edgeDockInputGate.reset()' in c for c in callbacks)
        mutated_callbacks = [c.replace('self.edgeDockInputGate.reset()', '', 1) for c in callbacks]
    if mutant == 'equal-guard-before-outer-reset':
        assert all('guard let self else { return }' in c for c in callbacks)
        mutated_callbacks = [c.replace('guard let self else { return }',
            'guard let self, self.settings.edgeDock != next else { return }', 1) for c in callbacks]
    if mutant == 'without-inner-reset':
        reset = 'if changed { configurationGate.reset() }'
        assert reset in drop
        mutated_drop = drop.replace(reset, '', 1)
    adapter = app_stubs.replace('CALLBACK_DISABLED', mutated_callbacks[0]).replace('CALLBACK_ENABLED', mutated_callbacks[1])
    return '\n'.join([stubs, 'enum TokenMonitorSource {\n' + safe_id + '\n}', models, geometry, controller_stubs, configuration, configure, mutated_drop, adapter, sync, tests])


print('SOURCE SHA256 app=' + hashlib.sha256(app.encode()).hexdigest() + ' controller=' + hashlib.sha256(controller.encode()).hexdigest())
with tempfile.TemporaryDirectory(prefix='edge-dock-state-') as temp:
    temp = Path(temp)
    for variant in ['production', 'without-outer-reset', 'without-inner-reset', 'equal-guard-before-outer-reset']:
        source = temp / f'{variant}.swift'
        binary = temp / variant
        source.write_text(fixture(variant))
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(temp / 'modules'),
                        str(source), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if variant == 'production':
            print(result.stdout, end='')
            if result.returncode != 0:
                raise RuntimeError('Production state regression failed')
        else:
            assert result.returncode != 0, f'Negative control unexpectedly passed: {variant}'
            expected_failures = 2 if variant == 'equal-guard-before-outer-reset' else 4
            assert result.stdout.count('FAIL ') == expected_failures, result.stdout
            failed = [line for line in result.stdout.splitlines() if line.startswith('FAIL ')]
            assert all('restoring A before B observer consumption restores controller A' in line for line in failed), failed
            if variant == 'equal-guard-before-outer-reset':
                assert all('(equal-settings callback)' in line for line in failed), failed
            print(f'PASS negative control {variant}: {expected_failures} intended A restoration failures')
print('BOUNDARY: frozen verbatim dropRail/configure/syncEdgeDockIfChanged/callbacks/ChangeGate/preference models; synthetic screen/UI/timer scheduling; no native window or real event debounce')

# Real layout calculation and the state prefix of updateSurfaces, before native rendering.
layout_method = extract(controller, 'private func makeLayout(')
layout_type = extract(controller, 'private struct Layout {').replace('private struct', 'struct', 1)
page_model = extract(model, 'struct TokenMonitorEdgeDockPage {')
idle_model = extract(model, 'enum TokenMonitorEdgeDockIdlePolicy {')
surface_prefix = controller[controller.index('        guard let layout else { return }', controller.index('private func updateSurfaces()')):controller.index('        let peek = peekPanel', controller.index('private func updateSurfaces()'))]
pagination = r'''
import Foundation
import CoreGraphics
typealias NSRect = CGRect
typealias NSPoint = CGPoint
struct NSDeviceDescriptionKey: Hashable { init(_ value:String) {} }
final class NSScreen {
    static var main: NSScreen? { nil }
    var deviceDescription: [NSDeviceDescriptionKey: NSNumber] { [:] }
    var visibleFrame = CGRect(x:0,y:0,width:1440,height:1200)
}
struct TokenMonitorEdgeDockCell { enum Kind { case stat, provider }; var kind=Kind.provider }
enum TokenMonitorEdgeDockScreenCatalog {
 struct Entry { var screen:NSScreen;var identity:TokenMonitorEdgeDockScreenTarget.Identity }
 static var fixture=Entry(screen:NSScreen(),identity:.init(numericID:1,uuid:nil,isBuiltIn:true))
 static func connected()->[Entry] {[fixture]}
}
enum WidgetLanguage { case zh;func text(_ a:String,_ b:String)->String {b} }
''' + models + '\n' + 'enum TokenMonitorSource {\n' + safe_id + '\n}\n' + page_model + '\n' + idle_model + '\n' + geometry + r'''
class Pagination {
 var preferences=TokenMonitorEdgeDockPreferences(enabled:true,mode:.autoHide)
 var cells=Array(repeating:TokenMonitorEdgeDockCell(),count:14)
 var pageIndex=0
 var layout:Layout?
 var cardIndex:Int?=13;var cardPinned=true;var railPinned=true
 var hoveredIndex:Int?=13;var hoverStartedAt:Date?=Date();var outsideStartedAt:Date?=Date()
''' + layout_type + '\n' + layout_method + '\nfunc updateSurfaces(){\n' + surface_prefix + r'''
}
func run()->Bool {
layout=makeLayout();updateSurfaces()
guard cardIndex==13 && cardPinned else {print("FAIL pagination initial in-page pinned detail");return false}
print("PASS pagination initial in-page pinned detail")
TokenMonitorEdgeDockScreenCatalog.fixture.screen.visibleFrame.size.height=800
layout=makeLayout();updateSurfaces()
guard layout?.page.indices == 0..<12, cardIndex == nil, !cardPinned, hoveredIndex == nil, hoverStartedAt == nil, outsideStartedAt == nil, railPinned else {print("FAIL pagination off-page pinned detail after shrink");return false}
print("PASS pagination off-page clear after shrink preserves rail pin")
cardIndex=3;cardPinned=true;updateSurfaces()
guard cardIndex==3 && cardPinned else {print("FAIL pagination in-page pin preservation");return false}
print("PASS pagination in-page pin preservation")
cardIndex=13;updateSurfaces() // Same selected ID after configuration moves it off the current page.
guard cardIndex==nil && !cardPinned else{print("FAIL pagination moved selected detail");return false}
print("PASS pagination moved selected detail clears")
railPinned=false;cardIndex=13;cardPinned=true;updateSurfaces()
guard cardIndex==nil && !cardPinned && !railPinned else{print("FAIL pagination unpinned rail preservation");return false}
print("PASS pagination unpinned rail preservation")
let canHide=TokenMonitorEdgeDockIdlePolicy.shouldClearOutside(hasCard:false,railVisible:true,mode:.autoHide,pinned:railPinned,cardPinned:cardPinned)
updateSurfaces()
guard canHide && !cardPinned && cardIndex == nil else {print("FAIL pagination no-card refresh and auto-hide");return false}
print("PASS pagination no-card refresh and auto-hide");return true
}
}
let result=Pagination().run();exit(result ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='edge-dock-pagination-') as temp:
    temp=Path(temp)
    for variant in ['production', 'without-page-validation']:
        content=pagination
        if variant != 'production':
            assert 'if let cardIndex,' in surface_prefix
            content=content.replace(surface_prefix, '        guard let layout else { return }\n', 1)
        source=temp/(variant+'.swift'); binary=temp/variant
        source.write_text(content)
        subprocess.run(['xcrun','swiftc','-swift-version','5',str(source),'-o',str(binary)],check=True)
        result=subprocess.run([str(binary)],capture_output=True,text=True)
        if variant == 'production':
            print(result.stdout,end='')
            if result.returncode: raise RuntimeError('Pagination regression failed')
        else:
            assert result.returncode == 1, 'Page negative control must fail assertion, not crash'
            assert [line for line in result.stdout.splitlines() if line.startswith('FAIL ')] == ['FAIL pagination off-page pinned detail after shrink'], result.stdout
            assert not result.stderr, result.stderr
            print('PASS negative control pagination without-page-validation: off-page detail stays pinned')
print('BOUNDARY pagination: verbatim makeLayout and updateSurfaces pre-render state, production page/idle/geometry; synthetic screen objects, native rendering omitted; selected index moving across pages simulated after configuration')
