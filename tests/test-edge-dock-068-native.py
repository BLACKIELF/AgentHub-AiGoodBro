#!/usr/bin/env python3
"""Offline 0.68 native preferences, geometry, refresh and first-mouse fixture.

Production declarations/methods are frozen once per run. No app/window launch,
account data, provider network or preferences outside this temporary fixture.
"""
from pathlib import Path
import hashlib
import subprocess
import tempfile

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
    raise RuntimeError(needle)


models = (ROOT / 'Sources/CodexUsageWidget/Domain/TokenMonitorEdgeDockModels.swift').read_text()
controller = (ROOT / 'Sources/CodexUsageWidget/Services/TokenMonitorEdgeDockController.swift').read_text()
view = (ROOT / 'Sources/CodexUsageWidget/UI/TokenMonitorEdgeDockView.swift').read_text()
engine = (ROOT / 'Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift').read_text()
declarations = '\n'.join(extract(models, needle) for needle in [
    'enum TokenMonitorEdgeDockScreenTarget {',
    'struct TokenMonitorEdgeDockPreferences:',
    'struct TokenMonitorEdgeDockItem:',
    'struct TokenMonitorEdgeDockPage {',
])
fixture = r'''
import Foundation
import AppKit
import SwiftUI
enum WidgetLanguage { case zh, en; func text(_ zh: String, _ en: String) -> String { self == .zh ? zh : en } }
enum TokenMonitorSource {
SAFE_ID
}
DECLARATIONS
GEOMETRY
FIRST_MOUSE
RUNNING_ARC
@MainActor final class RefreshFixture {
    var preferences = TokenMonitorEdgeDockPreferences(enabled: true, refreshEnabled: true)
    var isRefreshingAll = false
    var refreshAllTask: Task<Void, Never>?
    var refreshAllGeneration = UUID()
    var refreshingCells: Set<String> = []
    var onRefreshAll: (() async -> Void)?
    var surfaceUpdates = 0
    func updateSurfaces() { surfaceUpdates += 1 }
    func trigger() { refreshAll() }
REFRESH_ALL
}
@main struct Fixture {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            if value { print("PASS \(message)") } else { failures += 1; print("FAIL \(message)") }
        }
        let legacy = TokenMonitorEdgeDockPreferences.load(Data(#"{"enabled":true,"mode":"always","side":"left","offset":0.7,"items":[],"hapticEnabled":false,"warnColors":true,"quotaStyle":"fish"}"#.utf8))
        check(legacy.enabled && legacy.mode == .always && legacy.side == .left && legacy.offset == 0.7
              && legacy.items == [] && !legacy.hapticEnabled && legacy.warnColors && legacy.quotaStyle == .fish,
              "all previous choices survive adding 0.68 controls")
        check(!legacy.refreshEnabled && legacy.runningIndicatorEnabled && legacy.size == .medium && legacy.scale == 1,
              "older native JSON receives optional-refresh/default-running/medium defaults")
        var sizes = TokenMonitorEdgeDockPreferences(size: .custom, customScale: 1.33).normalized()
        check(sizes.scale == 1.35, "custom scale quantizes to five-percent step")
        sizes.size = .small
        check(sizes.scale == 0.85 && sizes.customScale == 1.35, "small preset retains custom value")
        sizes.size = .large
        check(sizes.scale == 1.25 && sizes.customScale == 1.35, "large preset retains custom value")
        sizes.size = .custom
        check(sizes.scale == 1.35, "return to custom retains saved value")
        check(TokenMonitorEdgeDockPreferences.normalizedCustomScale(.nan) == 1
              && TokenMonitorEdgeDockPreferences.normalizedCustomScale(0.1) == 0.75
              && TokenMonitorEdgeDockPreferences.normalizedCustomScale(2) == 1.5, "invalid scale is bounded")
        let invalidSize = TokenMonitorEdgeDockPreferences.load(Data(#"{"enabled":true,"size":"future","customScale":1.2}"#.utf8))
        check(invalidSize.enabled && invalidSize.size == .medium && invalidSize.customScale == 1.2,
              "unknown size keeps valid other preferences")
        let migrated = TokenMonitorEdgeDockPreferences.migratedEmbeddedSettings(Data(#"{"edgeDockEnabled":false,"edgeDockItems":[],"edgeDockRefreshEnabled":true,"edgeDockRunningIndicatorEnabled":false,"edgeDockSize":"custom","edgeDockCustomScale":1.2}"#.utf8))
        check(migrated?.enabled == false && migrated?.items == [] && migrated?.refreshEnabled == true
              && migrated?.runningIndicatorEnabled == false && migrated?.scale == 1.2,
              "embedded 0.68 migration keeps disabled/empty choices and new controls")
        let area = NSRect(x: 100, y: 80, width: 1200, height: 600)
        for scale: CGFloat in [0.75, 0.85, 1, 1.25, 1.5] {
            for side in TokenMonitorEdgeDockPreferences.Side.allCases {
                let rail = TokenMonitorEdgeDockNativeGeometry.railFrame(workArea: area, side: side, offset: 0.7, height: 300 * scale, scale: scale)
                let peek = TokenMonitorEdgeDockNativeGeometry.peekFrame(rail: rail, workArea: area, side: side, scale: scale)
                let wake = TokenMonitorEdgeDockNativeGeometry.handleZone(peek: peek, side: side, approaching: false)
                let approach = TokenMonitorEdgeDockNativeGeometry.handleZone(peek: peek, side: side, approaching: true)
                check(rail.width == 64 * scale && peek.width >= 10 && peek.height == (88 * scale).rounded()
                      && peek.midY == rail.midY && wake.width == 24 && approach.width == 48
                      && approach.height == peek.height + 48,
                      "\(side) \(scale): visual metrics scale and pointer depths/slack do not")
                let card = TokenMonitorEdgeDockNativeGeometry.cardFrame(rail: rail, centerY: rail.midY, height: 700 * scale, workArea: area, side: side, scale: scale)
                check(card.width == 292 * scale && card.minY >= area.minY + 8 && card.maxY <= area.maxY - 8,
                      "\(side) \(scale): card scales with fixed screen margin")
            }
            let pages = (0..<24).map { TokenMonitorEdgeDockPage.make(cellCount: 24, availableHeight: 250 / Double(scale), index: $0, chromeHeight: 96) }
            let uniquePages = pages.prefix(pages[0].count)
            check(uniquePages.flatMap { Array($0.indices) } == Array(0..<24), "\(scale): optional refresh leaves all 24 cells reachable")
        }
        check(TokenMonitorEdgeDockNativeGeometry.fittingScale(requested: 1.5, naturalHeight: 400, availableHeight: 500) == 1.25,
              "large dock shrinks only to the largest fitting cent-percent size")
        check(TokenMonitorEdgeDockNativeGeometry.fittingScale(requested: 1.25, naturalHeight: 700, availableHeight: 500) == 1,
              "a rail already too tall at medium paginates at medium")
        var reveals = 0
        let mouse = EdgeDockRevealMouseView.MouseView(frame: .zero)
        mouse.onReveal = { reveals += 1 }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        check(mouse.acceptsFirstMouse(for: event), "collapsed handle accepts the first mouse press")
        mouse.mouseDown(with: event)
        mouse.mouseUp(with: event)
        check(reveals == 1, "collapsed handle consumes mouse-down once; mouse-up does not repeat reveal")
        let refresh = RefreshFixture()
        var requests = 0
        var continuation: CheckedContinuation<Void, Never>?
        refresh.onRefreshAll = {
            requests += 1
            await withCheckedContinuation { continuation = $0 }
        }
        refresh.trigger(); refresh.trigger()
        for _ in 0..<10 { await Task.yield() }
        check(requests == 1 && refresh.refreshAllTask != nil && refresh.surfaceUpdates == 1,
              "repeated refresh clicks await one real callback and keep busy state")
        continuation?.resume()
        for _ in 0..<10 { await Task.yield() }
        check(refresh.refreshAllTask == nil && refresh.surfaceUpdates == 2,
              "callback completion clears busy and updates the visible control")
        refresh.isRefreshingAll = true; refresh.trigger()
        refresh.isRefreshingAll = false; refresh.preferences.refreshEnabled = false; refresh.trigger()
        refresh.preferences.refreshEnabled = true; refresh.refreshingCells.insert("isolated"); refresh.trigger()
        refresh.refreshingCells = []; refresh.preferences.enabled = false; refresh.trigger()
        for _ in 0..<10 { await Task.yield() }
        check(requests == 1, "external busy, hidden refresh, per-cell refresh and disabled dock cannot start another request")
        print("BOUNDARY: frozen production declarations and refresh/first-mouse methods; synthetic screens/events/callbacks; no app/window/account/provider actions")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
for marker, source in {
    'SAFE_ID': extract(engine, 'static func safeID('),
    'DECLARATIONS': declarations,
    'GEOMETRY': extract(controller, 'enum TokenMonitorEdgeDockNativeGeometry {'),
    'FIRST_MOUSE': extract(view, 'private struct EdgeDockRevealMouseView:'),
    'RUNNING_ARC': extract(view, 'private struct EdgeDockRunningArc:'),
    'REFRESH_ALL': extract(controller, 'private func refreshAll()'),
}.items():
    fixture = fixture.replace(marker, source)
print('SOURCE SHA256 models={} controller={} view={}'.format(*[
    hashlib.sha256(source.encode()).hexdigest() for source in [models, controller, view]
]), flush=True)
with tempfile.TemporaryDirectory(prefix='agb-edge-dock-068-') as temporary:
    directory = Path(temporary)
    source = directory / 'Fixture.swift'
    binary = directory / 'Fixture'
    source.write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    '-module-cache-path', str(directory / 'ModuleCache'), str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
