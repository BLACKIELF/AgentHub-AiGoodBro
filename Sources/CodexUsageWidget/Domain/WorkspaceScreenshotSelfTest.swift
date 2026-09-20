import AppKit
import SwiftUI

/// Offline tests: isolated defaults, synthetic accounts, no dialogs or runtime connections.
@MainActor
enum WorkspaceScreenshotSelfTest {
    static func run() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-screenshot-test-\(UUID().uuidString)")
        let suite = "CodexAccountManagerNext.screenshot-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        var modules = WorkspaceModuleArrangement()
        modules.move("usage", to: "accounts")
        modules.compact = ["monitor"]
        modules.resizeHeight("monitor", by: 70)
        expect(modules.extraHeight["monitor"] == 3, "height snaps to the nearest 24 point grid")
        modules.resizeHeight("monitor", by: 900)
        expect(modules.extraHeight["monitor"] == 10, "resize cannot grow unbounded")
        modules.resizeHeight("monitor", by: -900)
        expect(modules.extraHeight["monitor"] == 0, "resize cannot clip intrinsic content")
        modules.extraHeight["monitor"] = 3
        let moduleSettings = AppSettings(defaults: defaults)
        moduleSettings.homeModuleArrangement = modules
        expect(AppSettings(defaults: defaults).homeModuleArrangement == modules, "module order and snapped sizes survive reload")
        expect(modules.order == ["monitor", "accounts", "usage"], "module moves preserve all three identities")
        expect(WorkspaceModuleArrangement.load(Data("{broken".utf8)) == .init(), "corrupt module layout falls back safely")
        var invalid = modules
        invalid.order = ["usage", "usage", "monitor"]
        expect(WorkspaceModuleArrangement.load(try? JSONEncoder().encode(invalid)) == .init(), "duplicate modules cannot hide accounts")
        moduleSettings.homeModuleArrangement = .init()
        expect(AppSettings(defaults: defaults).homeModuleArrangement == .init(), "layout reset survives reload")
        func result(_ state: LocalCLIQuotaState, code: String? = nil) -> LocalCLIQuotaResult {
            LocalCLIQuotaResult(
                state: state, fetchedAt: Date(), maskedIdentity: nil, identityFingerprint: nil,
                planLabel: nil, windows: [], balance: nil, balanceCurrency: nil, sourceLabel: "Synthetic", messageCode: code)
        }
        expect(LocalCLIReadiness.resolve(installed: false, result: nil) == .notInstalled, "missing tools require installation")
        expect(LocalCLIReadiness.resolve(installed: true, result: nil) == .unknown, "unknown sign-in is never called signed-in")
        expect(LocalCLIReadiness.resolve(installed: true, result: result(.needsLogin)) == .needsLogin, "login state remains actionable")
        expect(
            LocalCLIReadiness.resolve(installed: true, result: result(.unavailable, code: "capability_report_unavailable")) == .inputFailure("capability_report_unavailable"),
            "input failure is separate from ended reservations")
        expect(
            LocalCLIReadiness.resolve(installed: true, result: result(.unavailable, code: "preparing_reservation_required")) == .endedReservation,
            "ended reservations must not suggest retrying the same lease")
        expect(LocalCLIReadiness.resolve(installed: true, result: result(.available), stale: true) == .stale, "old quota evidence cannot be presented as current")
        expect(LocalCLIReadiness.resolve(installed: true, result: result(.unavailable)) == .readFailed, "read failures are distinct from missing quota integration")
        expect(!LocalCLIReadiness.inputFailure("invocation_file_unavailable").detail(.zh).contains("能力报告"), "brief and capability report failures must not be conflated")
        let status = "5 小时已暂停 · 7 天额度不足 · 下次暖号 7 天 9月10日 09:30 · 7 天额度不足"
        let highlighted = WarmUpStatusText.attributed(status)
        expect(String(highlighted.characters) == status, "highlighting must preserve the exact status text")
        expect(
            highlighted.runs.filter { $0.foregroundColor == FixedVisualPalette.statusDanger }.count == 2,
            "every critical phrase occurrence must be red")
        if let dateRange = highlighted.range(of: "9月10日 09:30") {
            expect(highlighted[dateRange].foregroundColor == nil, "ordinary schedule dates must keep their neutral color")
        }
        for neutral in ["", "最近暖号成功 9月7日 09:00", "智能暖号已关闭"] {
            expect(WarmUpStatusText.attributed(neutral).runs.allSatisfy { $0.foregroundColor == nil }, "neutral status must not become an alert")
        }
        for phrase in WarmUpStatusText.criticalPhrases {
            let text = WarmUpStatusText.attributed(phrase)
            expect(text.foregroundColor == FixedVisualPalette.statusDanger, "each supported blocking status must be red")
            expect(text.font == .caption2.weight(.semibold), "blocking status must also use stronger weight")
        }
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let resetText = WidgetLanguage.zh.dateTime(reset)
        let englishReset = WidgetLanguage.en.dateTime(reset)
        let englishStatus = "Last warm-up succeeded Sep 7, 09:00 · Next 5h warm-up \(englishReset) · Next 7d warm-up \(englishReset)"
        expect(
            WarmUpStatusText.summary(englishStatus, fiveHourReset: reset, sevenDayReset: reset, language: .en) == "Last warm-up succeeded Sep 7, 09:00",
            "English warm-up result and timestamp remain visible while duplicate schedules are omitted")
        expect(
            WorkspaceScreenshotExporter.ExportError.invalidSize.message(.en).range(of: "\\p{Han}", options: .regularExpression) == nil,
            "English screenshot errors must stay English")
        let duplicate = "最近暖号成功 9月7日 09:00 · 下次暖号 5 小时 \(resetText) · 下次暖号 7 天 \(resetText)"
        expect(
            WarmUpStatusText.summary(duplicate, fiveHourReset: reset, sevenDayReset: reset) == "最近暖号成功 9月7日 09:00",
            "warm-up result and timestamp remain visible next to the account")
        let unique = "5 小时已暂停 · 7 天额度不足 · 下次暖号 7 天 \(resetText)"
        expect(WarmUpStatusText.summary(unique, fiveHourReset: nil, sevenDayReset: reset) == "5 小时已暂停 · 7 天额度不足", "deduplication must keep the reason for a pause")
        let differentSchedule = "下次暖号 7 天 \(resetText)"
        expect(
            WarmUpStatusText.summary(differentSchedule, fiveHourReset: nil, sevenDayReset: reset.addingTimeInterval(3_600)) == differentSchedule,
            "a warm-up time different from official reset must remain visible")
        let unknown = "下次暖号 7 天 未知；请点刷新检查"
        expect(WarmUpStatusText.summary(unknown, fiveHourReset: nil, sevenDayReset: nil) == unknown, "unknown and actionable schedules must remain visible")
        expect(AccountWorkspaceLayout.storedOrDefault(defaults: defaults) == .rows, "the original vertical layout must remain the default")
        let layoutSettings = AppSettings(defaults: defaults)
        layoutSettings.accountWorkspaceLayout = .cards
        expect(AppSettings(defaults: defaults).accountWorkspaceLayout == .cards, "a card choice must survive settings reload")
        layoutSettings.accountWorkspaceLayout = .rows
        expect(AppSettings(defaults: defaults).accountWorkspaceLayout == .rows, "users must be able to return to the original layout")
        defaults.set("future-layout", forKey: AccountWorkspaceLayout.storageKey)
        expect(AccountWorkspaceLayout.storedOrDefault(defaults: defaults) == .rows, "unknown stored layouts must fall back to the original")
        defaults.removeObject(forKey: AccountWorkspaceLayout.storageKey)
        expect(AccountCardGridLayout.columnCount(width: 784, itemCount: 9) == 2, "the compact minimum window keeps two natural-width cards")
        expect(AccountCardGridLayout.columnCount(width: 944, itemCount: 9) == 2, "the 1100pt window content keeps two cards until a third is comfortable")
        expect(AccountCardGridLayout.columnCount(width: 1_064, itemCount: 9) == 3, "the 1100pt window content fits three cards")
        expect(AccountCardGridLayout.columnCount(width: 1_404, itemCount: 9) == 4, "the 1440pt window content fits four cards")
        expect(AccountCardGridLayout.columnCount(width: .infinity, itemCount: 9) == 1, "nonfinite probes must be safe")
        expect(AccountCardGridLayout.selfTest(), "all card rows must share one global measured size at 720 and 980 points")
        expect(CrossProviderQuotaSummary.selfTest(), "provider summaries must preserve unknown values and never add unrelated percentages")
        expect(ProfileReorderMotion.animation(reduceMotion: true) == nil, "reordering must respect reduced motion")
        let originalOrder = ["one", "two", "three", "four"]
        expect(ProfileReorderSession(sourceID: "missing", order: originalOrder) == nil, "unknown drag sources must be rejected")
        expect(ProfileReorderSession(sourceID: "one", order: ["one", "one"]) == nil, "duplicate identifiers must be rejected")
        if var drag = ProfileReorderSession(sourceID: "one", order: originalOrder) {
            drag.move(over: "three")
            expect(drag.order == ["two", "three", "one", "four"], "downward and grid-crossing drag previews must use stable identifiers")
            expect(drag.originalOrder == originalOrder, "hovering must not mutate the original order")
            let destination = drag.destination(currentOrder: originalOrder)
            expect(destination?.targetID == "four" && destination?.before == true, "a successful drop must resolve one final insertion")
            expect(drag.destination(currentOrder: ["two", "one", "three", "four"]) == nil, "a concurrent reorder must invalidate a stale drag")
            drag.move(over: "four")
            expect(drag.destination(currentOrder: originalOrder)?.before == false, "dropping at the end must insert after the final peer")
            drag.move(over: "two")
            expect(drag.order == originalOrder && drag.destination(currentOrder: originalOrder) == nil, "returning to the start must not write storage")
            drag.move(over: "missing")
            expect(drag.order == originalOrder, "external or removed targets must not reorder accounts")
        } else {
            failures.append("a valid drag must be accepted")
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let reorderRoot = root.appendingPathComponent("reorder-save")
            let reorderStore = WorkspacePreviewRenderer.fixtureStore(accountCount: 4, root: reorderRoot)
            let recoveryProfile = reorderStore.profiles[0]
            expect(AccountRecoveryGuide.isIsolated(recoveryProfile), "recovery accepts explicit isolated profiles")
            expect(AccountRecoveryGuide.quotaVerified(recoveryProfile), "fresh successful quota supports recovery evidence")
            var failedRecovery = recoveryProfile
            failedRecovery.lastQuotaReadFailureAt = Date()
            expect(!AccountRecoveryGuide.quotaVerified(failedRecovery), "old success cannot hide a current quota failure")
            let systemRecovery = CodexProfile(
                id: "system-fixture", name: "Synthetic", codexHomePath: root.appendingPathComponent("system").path, isSystemProfile: true, createdAt: Date())
            expect(!AccountRecoveryGuide.isIsolated(systemRecovery), "recovery must never offer the system account")
            let firstID = reorderStore.profiles[0].id
            let lastID = reorderStore.profiles[3].id
            let originalIDs = reorderStore.profiles.map(\.id)
            reorderStore.moveProfile(firstID, relativeTo: lastID, before: false)
            let reloadedOrder = CodexProfileStore(
                homeDirectory: reorderRoot.appendingPathComponent("home"),
                applicationSupportDirectory: reorderRoot.appendingPathComponent("support")
            )
            expect(reorderStore.profiles.map(\.id) == Array(originalIDs.dropFirst()) + [firstID], "drop commits must preserve all account identities")
            expect(reloadedOrder.profiles.map(\.id) == reorderStore.profiles.map(\.id), "the committed order must survive disk reload")
            expect(reorderStore.selectedMonitorProfileID == firstID && reorderStore.selectedLaunchProfileID == firstID, "sorting must not switch the monitored or launch account")
            let retina = try WorkspaceScreenshotExporter.RasterPlan(size: CGSize(width: 980, height: 1_400))
            expect(retina.scale == 2 && retina.pixelsWide == 1_960 && retina.pixelsHigh == 2_800, "normal export must be 2x")
            let long = try WorkspaceScreenshotExporter.RasterPlan(size: CGSize(width: 980, height: 12_000))
            expect(long.scale == 1 && long.pixelsHigh == 12_000, "large export must lower scale without cropping")
            let pixelLimit = try WorkspaceScreenshotExporter.RasterPlan(size: CGSize(width: 32_000, height: 1_000))
            expect(
                pixelLimit.scale == 1 && pixelLimit.pixelsWide * pixelLimit.pixelsHigh == 32_000_000,
                "the exact pixel limit must remain exportable at 1x"
            )
            let dimensionLimit = try WorkspaceScreenshotExporter.RasterPlan(size: CGSize(width: 1, height: 32_768))
            expect(
                dimensionLimit.scale == 1 && dimensionLimit.pixelsHigh == 32_768,
                "the exact dimension limit must not be truncated"
            )
            for size in [
                CGSize(width: 0, height: 100), CGSize(width: 100, height: -1),
                CGSize(width: CGFloat.nan, height: 100), CGSize(width: 100, height: CGFloat.infinity),
                CGSize(width: 100, height: 32_769), CGSize(width: 10_000, height: 10_000),
                CGSize(width: 32_000, height: 1_000.01),
            ] {
                do {
                    _ = try WorkspaceScreenshotExporter.RasterPlan(size: size)
                    failures.append("invalid or oversized layout was accepted")
                } catch {}
            }

            // Explicit top/bottom markers catch viewport-only or upside-down exports.
            let stripes = VStack(spacing: 0) {
                Color.red.frame(height: 80)
                Color.blue.frame(height: 1_800)
                Color.green.frame(height: 80)
            }
            let stripeCapture = try WorkspaceScreenshotExporter.render(stripes, width: 320, scheme: .light)
            expect(stripeCapture.plan.size.height == 1_960, "content height must exceed and not depend on any viewport")
            if let bitmap = NSBitmapImageRep(data: stripeCapture.png),
                let top = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20)?.usingColorSpace(.deviceRGB),
                let bottom = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 20)?.usingColorSpace(.deviceRGB)
            {
                expect(top.redComponent > top.greenComponent, "top marker must be present and correctly oriented")
                expect(bottom.greenComponent > bottom.redComponent, "offscreen bottom marker must be present")
                expect(top.alphaComponent > 0.99 && bottom.alphaComponent > 0.99, "image must have an opaque background")
            } else {
                failures.append("export must decode as a complete PNG")
            }

            // A selected chart is represented by distinct pixels, not a newly
            // loaded WebKit instance. The complete export must keep those pixels.
            let chartPixels = try WorkspaceScreenshotExporter.render(
                VStack(spacing: 0) {
                    Color.red.frame(height: 40)
                    Color.blue.frame(height: 180)
                    Color.green.frame(height: 40)
                }, width: 320, scheme: .dark)
            guard let chartImage = NSImage(data: chartPixels.png) else { throw WorkspaceScreenshotExporter.ExportError.renderingFailed }
            chartImage.size = chartPixels.plan.size
            let chartInput = "{\"schemaVersion\":1,\"payload\":{}}"
            let selectedChart = UpstreamTrendView.Screenshot(image: chartImage, dashboardJSON: chartInput, points: [])
            let chartExport = try WorkspaceScreenshotExporter.render(
                UpstreamTrendView(dashboardJSON: chartInput), width: 320, scheme: .dark,
                liveCharts: .init(captures: [selectedChart]))
            expect(chartExport.plan.size.height == 260, "export keeps the live chart height")
            if let bitmap = NSBitmapImageRep(data: chartExport.png),
                let top = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20)?.usingColorSpace(.deviceRGB),
                let bottom = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 20)?.usingColorSpace(.deviceRGB)
            {
                expect(top.redComponent > 0.8 && bottom.greenComponent > 0.4, "selected chart pixels survive the offscreen export instead of a loading placeholder")
            } else {
                failures.append("selected chart export must decode")
            }
            for captures in [[], [selectedChart, selectedChart]] {
                do {
                    _ = try WorkspaceScreenshotExporter.render(
                        UpstreamTrendView(dashboardJSON: chartInput), width: 320, scheme: .dark,
                        liveCharts: .init(captures: captures))
                    failures.append("missing or ambiguous live chart must not be exported")
                } catch WorkspaceScreenshotExporter.ExportError.liveContentUnavailable {}
            }
            do {
                _ = try WorkspaceScreenshotExporter.render(
                    UpstreamTrendView(dashboardJSON: chartInput + " "), width: 320, scheme: .dark,
                    liveCharts: .init(captures: [selectedChart]))
                failures.append("a changed dashboard must not be paired with stale chart pixels")
            } catch WorkspaceScreenshotExporter.ExportError.liveContentUnavailable {}
            let output = root.appendingPathComponent("roundtrip.png")
            expect(try WorkspaceScreenshotExporter.finishSave(stripeCapture, to: nil) == nil, "cancel must return without saving")
            expect(!FileManager.default.fileExists(atPath: output.path), "cancel must not create a file")
            expect(try WorkspaceScreenshotExporter.finishSave(stripeCapture, to: output) == output, "save must return the selected destination")
            expect(try Data(contentsOf: output) == stripeCapture.png, "PNG must survive an atomic write")
            do {
                _ = try WorkspaceScreenshotExporter.finishSave(stripeCapture, to: root)
                failures.append("writing over a directory should fail")
            } catch {}
            expect(try Data(contentsOf: output) == stripeCapture.png, "failed save must preserve the prior file")

            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(defaults: defaults, paletteCatalog: catalog)
            settings.workspaceDisplayMode = .simple
            settings.simpleWorkspacePreset = .overview
            var previousHeight: CGFloat = 0
            for count in 1...9 {
                let store = WorkspacePreviewRenderer.fixtureStore(
                    accountCount: count,
                    root: root.appendingPathComponent("row-growth-\(count)")
                )
                let view = CodexAccountManagerView(store: store, settings: settings, paletteCatalog: catalog, previewOpenCodexWorkspace: true)
                let captured = try WorkspaceScreenshotExporter.render(view.screenshotContent, width: 980, scheme: .light)
                // The Codex page retains the explicit list layout, independent of the home grid.
                if count > 2 {
                    expect(captured.plan.size.height > previousHeight, "each added account in the multi-account layout must increase export height")
                }
                previousHeight = captured.plan.size.height
            }
            for scheme in [ColorScheme.light, .dark] {
                settings.themeMode = scheme == .dark ? .dark : .light
                for width: CGFloat in [820, 980, 1280] {
                    let eightAccountStore = WorkspacePreviewRenderer.fixtureStore(
                        accountCount: 8,
                        root: root.appendingPathComponent(UUID().uuidString)
                    )
                    let eightAccountView = CodexAccountManagerView(
                        store: eightAccountStore,
                        settings: settings,
                        paletteCatalog: catalog,
                        previewOpenCodexWorkspace: true
                    )
                    let eightAccountCapture = try WorkspaceScreenshotExporter.render(
                        eightAccountView.screenshotContent,
                        width: width,
                        scheme: scheme
                    )
                    let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 9, root: root.appendingPathComponent(UUID().uuidString))
                    let view = CodexAccountManagerView(store: store, settings: settings, paletteCatalog: catalog, previewOpenCodexWorkspace: true)
                    let captured = try WorkspaceScreenshotExporter.render(view.screenshotContent, width: width, scheme: scheme)
                    expect(captured.plan.size.width == width, "export must keep the current workspace width")
                    expect(
                        captured.plan.size.height > eightAccountCapture.plan.size.height,
                        "the ninth account row must increase the complete export height at every layout"
                    )
                    let rowHeight = captured.plan.size.height - eightAccountCapture.plan.size.height
                    // 0921v2 intentionally exposes model and dispatch controls
                    // by default; the old 118pt folded-row budget hid them.
                    expect(rowHeight >= 150 && rowHeight <= 208, "expanded model/scheduling rows must remain visible and bounded to 208 points including the gap")
                    print("Compact layout: width=\(Int(width)), scheme=\(scheme), row=\(Int(rowHeight))pt")
                    expect(NSBitmapImageRep(data: captured.png)?.pixelsHigh == captured.plan.pixelsHigh, "long PNG must retain its full planned height")
                    expect(store.isPreview && store.profiles.count == 9, "export must retain all nine fixture accounts")
                    settings.accountWorkspaceLayout = .cards
                    let sixAccountStore = WorkspacePreviewRenderer.fixtureStore(accountCount: 6, root: root.appendingPathComponent(UUID().uuidString))
                    let sixAccountView = CodexAccountManagerView(store: sixAccountStore, settings: settings, paletteCatalog: catalog, previewOpenCodexWorkspace: true)
                    let sixCardCapture = try WorkspaceScreenshotExporter.render(sixAccountView.screenshotContent, width: width, scheme: scheme)
                    let cardCapture = try WorkspaceScreenshotExporter.render(view.screenshotContent, width: width, scheme: scheme)
                    expect(cardCapture.plan.size.height > sixCardCapture.plan.size.height, "card screenshots must include rows beyond the viewport")
                    expect(NSBitmapImageRep(data: cardCapture.png)?.pixelsHigh == cardCapture.plan.pixelsHigh, "all card rows must survive PNG encoding")
                    print("Card layout: width=\(Int(width)), scheme=\(scheme), height=\(Int(cardCapture.plan.size.height))pt")
                    let homeSix = CodexAccountManagerView(store: sixAccountStore, settings: settings, paletteCatalog: catalog)
                    let homeNine = CodexAccountManagerView(store: store, settings: settings, paletteCatalog: catalog)
                    let homeSixCapture = try WorkspaceScreenshotExporter.render(homeSix.screenshotContent, width: width, scheme: scheme)
                    let homeNineCapture = try WorkspaceScreenshotExporter.render(homeNine.screenshotContent, width: width, scheme: scheme)
                    expect(homeNineCapture.plan.size.height > homeSixCapture.plan.size.height, "the home grid exports every additional account row")
                    expect(NSBitmapImageRep(data: homeNineCapture.png)?.pixelsHigh == homeNineCapture.plan.pixelsHigh, "the full home grid survives PNG encoding")
                    settings.accountWorkspaceLayout = .rows
                }
            }
        } catch {
            failures.append("render or persistence test threw an error")
        }
        if failures.isEmpty {
            print(
                "Workspace screenshot self-test passed: live chart pixels and stale/missing source rejection, bounds, 2x/1x, offscreen bottom, cancel/save/failure, row growth through nine, 6 nine-account layouts"
            )
            return true
        }
        failures.forEach { print("Workspace screenshot self-test failed: \($0)") }
        return false
    }
}
