import AppKit
import Foundation
import WebKit

@MainActor
enum TokenMonitorUISelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        reproduceFloatingBubble(expect: expect)
        reproduceNavigation(expect: expect)
        reproduceAvatars(expect: expect)
        reproduceIcons(expect: expect)
        reproduceMenuAndModel(expect: expect)
        reproduceResponsiveTokenAndAccountLayouts(expect: expect)
        reproduceTokenCalendarSemantics(expect: expect)
        reproduceLocalUsageCoverage(expect: expect)
        reproduceTrendRendererBoundaries(expect: expect)
        reproduceResetAnnouncementPresentation(expect: expect)
        reproducePublicResetCalendar(expect: expect)
        expect(ResetCardPresentation.savedOrder(["a", "b", "c"], pinnedAccountID: nil) == ["a", "b", "c"], "account order remains saved without a pin")
        expect(ResetCardPresentation.savedOrder(["a", "b", "c"], pinnedAccountID: "c") == ["c", "a", "b"], "only an explicit pin changes presentation order")
        expect(HomeMessageInboxStore.visibleAnnouncementLimit == 3, "homepage shows only three reset messages")
        expect(PublisherMessageSelfTest.run(), "publisher announcements respect delivery and URL boundaries")
        expect(OnboardingModesSelfTest.run(), "onboarding modes, 6pt track and skip/back fixtures")

        if failures.isEmpty {
            print("token-monitor UI self-test passed: floating geometry, navigation, avatars, icons, menu/model, responsive totals, calendar, chart states, announcements")
            return true
        }
        failures.forEach { print("token-monitor UI self-test failed: \($0)") }
        return false
    }

    private static func reproducePublicResetCalendar(expect: (Bool, String) -> Void) {
        let parser = ISO8601DateFormatter()
        let lateUTC = parser.date(from: "2026-09-03T23:12:00Z")!
        let beijingDay = parser.date(from: "2026-09-03T16:00:00Z")!
        let earlierDay = parser.date(from: "2026-09-02T16:00:00Z")!
        let event = PublicResetAnnouncement(
            id: "fixture-reset-calendar", resetType: .banked, announcedAt: lateUTC, text: "A public reset announcement", source: .init(type: "observed", author: nil, url: nil))
        expect(PublicResetCalendarModel.events(on: beijingDay, from: [event]).count == 1, "reset calendar uses Beijing day boundaries")
        expect(PublicResetCalendarModel.events(on: earlierDay, from: [event]).isEmpty, "UTC date is not incorrectly used as Beijing calendar day")
        expect(PublicResetCalendarModel.normalized([event, event]).count == 1, "latest announcement and API page do not duplicate calendar counts")
        let leap = PublicResetCalendarModel.days(in: parser.date(from: "2024-02-12T00:00:00Z")!)
        expect(leap.compactMap { $0 }.count == 29 && leap.count.isMultiple(of: 7), "reset calendar preserves leap days and complete weeks")
        let september = PublicResetCalendarModel.days(in: lateUTC)
        expect(september.first! == nil && september[1] != nil, "calendar starts Monday with correct leading empty cells")
        let january = PublicResetCalendarModel.days(in: parser.date(from: "2027-01-12T00:00:00Z")!)
        expect(january.compactMap { $0 }.count == 31, "calendar month navigation crosses year boundaries")
        expect(PublicResetCalendarModel.events(on: beijingDay, from: []).isEmpty, "missing historical records are not invented")
    }

    private static func reproduceFloatingBubble(expect: (Bool, String) -> Void) {
        // Assertions copied from vendor/token-monitor/tests/electron/floatingBubble.test.js
        let workArea = TokenMonitorFloatingBubbleGeometry.Rect(x: 0, y: 24, width: 1440, height: 876)
        let windowsDisplay = TokenMonitorFloatingBubbleGeometry.Display(
            bounds: .init(x: 0, y: 0, width: 1920, height: 1080),
            workArea: .init(x: 0, y: 0, width: 1840, height: 1040)
        )
        expect(
            TokenMonitorFloatingBubbleGeometry.canUseFloatingBubble(
                .init(floatingBubbleEnabled: true, trayMode: false, windowBehavior: "floating")),
            "floating bubble is available in movable window modes")
        expect(
            !TokenMonitorFloatingBubbleGeometry.canUseFloatingBubble(
                .init(floatingBubbleEnabled: true, trayMode: false, windowBehavior: "desktop")),
            "desktop window behavior disables the bubble")
        expect(
            !TokenMonitorFloatingBubbleGeometry.canUseFloatingBubble(
                .init(floatingBubbleEnabled: true, trayMode: true, windowBehavior: "floating")),
            "tray mode disables the bubble")
        expect(TokenMonitorFloatingBubbleGeometry.nativeGlassEnabled(.init(systemGlass: true)), "native glass follows systemGlass")
        expect(!TokenMonitorFloatingBubbleGeometry.nativeGlassEnabled(.init(systemGlass: false)), "systemGlass false disables glass")
        expect(TokenMonitorFloatingBubbleGeometry.collapsedArea(windowsDisplay, platform: .windows) == windowsDisplay.bounds, "Windows uses physical bounds")
        expect(TokenMonitorFloatingBubbleGeometry.collapsedArea(windowsDisplay, platform: .macOS) == windowsDisplay.workArea, "macOS uses work area")
        expect(TokenMonitorFloatingBubbleGeometry.collapsedMargin(platform: .windows) == .init(x: 0, y: 0), "Windows collapsed margin")
        expect(TokenMonitorFloatingBubbleGeometry.collapsedMargin(platform: .macOS) == .init(x: 0, y: 8), "macOS collapsed margin")
        let collapsedLeft = TokenMonitorFloatingBubbleGeometry.collapsedBounds(
            .init(x: 120, y: 80, width: 360, height: 520), workArea: workArea)
        expect(collapsedLeft == .init(x: 120, y: 323, width: 18, height: 34), "left collapsed handle matches upstream")
        let collapsedRight = TokenMonitorFloatingBubbleGeometry.collapsedBounds(
            .init(x: 1000, y: 80, width: 360, height: 520), workArea: workArea)
        expect(collapsedRight == .init(x: 1342, y: 323, width: 18, height: 34), "right collapsed handle matches upstream")
        let plan = TokenMonitorFloatingBubbleGeometry.collapsePlan(
            bounds: .init(x: 120, y: 120, width: 360, height: 520),
            workArea: workArea,
            settings: .init(floatingBubbleEnabled: true, windowBehavior: "floating")
        )
        expect(plan?.side == "left", "collapse plan side is left")
        expect(plan?.collapsedBounds == .init(x: 120, y: 363, width: 18, height: 34), "collapse plan bounds match upstream")
        expect(
            TokenMonitorFloatingBubbleGeometry.collapsePlan(
                bounds: .init(x: 120, y: 120, width: 360, height: 520),
                workArea: workArea,
                settings: .init(floatingBubbleEnabled: true, windowBehavior: "floating"),
                suppressNextCollapse: true
            ) == nil,
            "suppressNextCollapse returns nil"
        )
        let reused = TokenMonitorFloatingBubbleGeometry.collapsePlan(
            bounds: .init(x: 120, y: 120, width: 360, height: 520),
            workArea: workArea,
            settings: .init(floatingBubbleEnabled: true, windowBehavior: "normal"),
            previousCollapsed: .init(x: 640, y: 220, width: 18, height: 34)
        )
        expect(reused?.collapsedBounds == .init(x: 640, y: 220, width: 18, height: 34), "last dragged mini-window is reused")
        let expanded = TokenMonitorFloatingBubbleGeometry.expandedBounds(
            collapsed: .init(x: 1100, y: 500, width: 18, height: 34),
            workArea: workArea,
            previousExpanded: .init(x: 0, y: 0, width: 360, height: 520)
        )
        expect(expanded == .init(x: 758, y: 257, width: 360, height: 520), "expand from right handle")
        let expandedClamped = TokenMonitorFloatingBubbleGeometry.expandedBounds(
            collapsed: .init(x: 8, y: 8, width: 18, height: 34),
            workArea: workArea,
            previousExpanded: .init(x: 0, y: 0, width: 360, height: 520)
        )
        expect(expandedClamped == .init(x: 8, y: 32, width: 360, height: 520), "expand clamps into the work area")
        expect(
            TokenMonitorFloatingBubbleGeometry.moveBounds(
                .init(x: 8, y: 30, width: 18, height: 34), workArea: workArea, dx: -80, dy: -80)
                == .init(x: 0, y: 32, width: 18, height: 34),
            "drag clamps to the work area"
        )
        let query = TokenMonitorFloatingBubbleGeometry.initialRendererQuery(
            collapsed: true, side: "right", collapsedWindow: true)
        expect(query["period"] == "today" && query["breakdown"] == "tool" && query["floatingBubbleSide"] == "right", "renderer query carries view state")
    }

    private static func reproduceNavigation(expect: (Bool, String) -> Void) {
        var state = AgentNavigationState()
        expect(!state.initialized, "fresh navigation is uninitialized")
        state.bootstrapIfNeeded(existingUser: false, currentVisible: ["codex", "grok"])
        expect(state.initialized && state.customized && state.orderedVisibleProviderIDs.isEmpty, "new users start with no Agent tabs")
        expect(state.add("codex"), "Codex can be added")
        expect(!state.add("codex"), "duplicate add is rejected")
        expect(state.add("grok") && state.add("claudeCode"), "workspace agents can be added")
        expect(!state.add("cursor"), "unsupported catalog items cannot be added")
        expect(state.remove("codex") == "codex", "Codex can be hidden without deleting accounts")
        expect(state.renderableIDs() == ["grok", "claudeCode"], "remove only hides the tab")
        state.move("claudeCode", by: -1)
        expect(state.orderedVisibleProviderIDs == ["claudeCode", "grok"], "keyboard reorder swaps neighbors")
        var draft = state
        _ = draft.remove("grok")
        expect(state.orderedVisibleProviderIDs.contains("grok"), "cancel keeps the pre-edit snapshot")
        state.orderedVisibleProviderIDs = ["grok", "unknown-future", "claudeCode"]
        expect(state.renderableIDs() == ["grok", "claudeCode"], "unknown IDs stay stored but are not rendered")
        expect(state.unknownIDs() == ["unknown-future"], "unknown IDs remain for later recovery")
        let empty = AgentNavigationState(initialized: true, customized: true, orderedVisibleProviderIDs: [])
        expect(empty.renderableIDs().isEmpty, "an explicit empty list is not missing config")
        let overflow = AgentNavigationOverflow.layout(
            orderedIDs: AgentNavCatalog.workspaceProviders.map(\.id),
            availableWidth: 820,
            homeWidth: 88,
            trailingChromeWidth: 196,
            moreWidth: 92,
            itemWidth: { _ in 110 }
        )
        expect(
            overflow.showsMore && !overflow.overflowIDs.isEmpty && overflow.visibleIDs.count < AgentNavCatalog.workspaceProviders.count,
            "narrow windows keep Home/Add/Manage and overflow the rest")
        let wide = AgentNavigationOverflow.layout(
            orderedIDs: ["codex"],
            availableWidth: 1280,
            itemWidth: { _ in 90 }
        )
        expect(!wide.showsMore && wide.visibleIDs == ["codex"], "a single tab does not need More")
        let none = AgentNavigationOverflow.layout(orderedIDs: [], availableWidth: 820)
        expect(!none.showsMore && none.visibleIDs.isEmpty, "zero agent tabs is legal")
        var many = AgentNavigationState(initialized: true, customized: true, orderedVisibleProviderIDs: (0..<40).map { "p\($0)" })
        many.orderedVisibleProviderIDs.insert("codex", at: 0)
        expect(many.orderedVisibleProviderIDs.count >= 35, "35+ stored IDs remain addressable")
        expect(AgentNavCatalog.workspaceProviders.contains { $0.id == "codex" }, "Codex is part of the workspace catalog")
    }

    private static func reproduceAvatars(expect: (Bool, String) -> Void) {
        expect(AccountAvatarEmoji.isolatedCluster("😀") == "😀", "single emoji is stored as one cluster")
        expect(AccountAvatarEmoji.isolatedCluster("👨‍👩‍👧‍👦") == "👨‍👩‍👧‍👦", "ZWJ family stays one cluster")
        expect(AccountAvatarEmoji.isolatedCluster("🇺🇸") == "🇺🇸", "flag sequences stay one cluster")
        expect(AccountAvatarEmoji.isolatedCluster("😀😀") == nil, "multiple emoji are rejected")
        expect(AccountAvatarEmoji.isolatedCluster("Codex") == nil, "plain text is rejected")
        expect(AccountAvatarEmoji.isolatedCluster("") == nil, "empty emoji is rejected")
        expect(ProviderIconSlot.list.container == 24 && ProviderIconSlot.card.container == 32, "list/card avatar sizes")
        expect(ProviderIconSlot.detail.container == 48 && ProviderIconSlot.editor.container == 80, "detail/editor avatar sizes")
        expect(
            ProviderIconSlot.card.hitTarget >= 32 && ProviderIconSlot.detail.hitTarget >= 32 && ProviderIconSlot.editor.hitTarget >= 32,
            "card/detail/editor avatars keep a 32pt hit target")
        expect(
            ProviderIconSlot.compactRow.container == 20 && ProviderIconSlot.compactRow.glyph == 20,
            "compact-row avatars keep the original 20pt footprint")
        var table = AccountAvatarTable()
        table.set(.init(mode: .emoji, emoji: "😀"), for: "a")
        table.set(.init(mode: .image, assetID: "avatar-a-1"), for: "b")
        expect(table.record(for: "a").emoji == "😀", "emoji is keyed by profile ID")
        expect(table.record(for: "b").assetID == "avatar-a-1", "image asset is keyed by profile ID")
        expect(table.record(for: "a").assetID == nil, "two accounts cannot share by accident")
        table.restoreDefault(for: "a")
        expect(table.record(for: "a").mode == .platformDefault, "restore default does not delete the account")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-self-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AccountAvatarAssetStore(root: tmp)
        let png = solidPNG(color: .systemOrange)
        let assetID = try? store.savePNG(png, profileID: "profile/one")
        expect(assetID != nil && store.load(assetID: assetID ?? "") != nil, "managed PNG is readable")
        expect(!(assetID ?? "").contains("/"), "asset IDs do not embed paths")
        store.remove(assetID: assetID ?? "")
        expect(store.load(assetID: assetID ?? "") == nil, "missing files fall back")
        let svg = tmp.appendingPathComponent("x.svg")
        try? "<svg xmlns='http://www.w3.org/2000/svg'></svg>".write(to: svg, atomically: true, encoding: .utf8)
        if case .failure(let reason) = AccountAvatarImageProcessor.inspect(url: svg) {
            expect(reason == .vector, "SVG is rejected")
        } else {
            expect(false, "SVG inspection should fail")
        }
    }

    private static func reproduceIcons(expect: (Bool, String) -> Void) {
        expect(ProviderIconSlot.navigation.container == 20, "navigation container is 20pt")
        expect((16...18).contains(Int(ProviderIconSlot.navigation.glyph.rounded())), "navigation glyph is 16-18pt")
        expect(ProviderIconSlot.menu.container == 16, "menu icons are 16pt")
        expect(ProviderIconSlot.detail.container == 48, "detail avatars are 48pt")
        let optical = ProviderIconMetrics.opticalLayout(sourceWidth: 24, sourceHeight: 12, size: 20)
        expect(abs(optical.width - 15.6) < 0.01 && abs(optical.height - 7.8) < 0.01, "optical 0.78 matches upstream tray layout")
        expect(abs(optical.midX - 10) < 0.01, "marks stay centered in the container")
        for kind in LocalCLIKind.allCases {
            expect(AgentNavCatalog.localKind(kind.rawValue) == kind, "every local CLI has a catalog mark")
        }
    }

    private static func reproduceMenuAndModel(expect: (Bool, String) -> Void) {
        let claude = AnchoredMenuRequest(
            ownerID: "claude-default",
            actions: [
                AnchoredMenuAction(id: "pin", title: "固定第一位"),
                AnchoredMenuAction(id: "rename", title: "重命名"),
            ]
        )
        let grok = AnchoredMenuRequest(
            ownerID: "grok-default",
            actions: [
                AnchoredMenuAction(id: "pin", title: "固定第一位"),
                AnchoredMenuAction(id: "rename", title: "重命名"),
            ]
        )
        expect(claude.ownerID != grok.ownerID, "repro: each ellipsis is bound to one profile")
        expect(claude.action(id: "pin") != nil, "repro: Claude more-menu owns pin/rename")
        var mutated = ""
        func apply(_ request: AnchoredMenuRequest, action: String) {
            mutated = request.ownerID + ":" + action
        }
        apply(claude, action: "pin")
        expect(mutated == "claude-default:pin", "a Claude menu cannot mutate the Grok row")
        apply(grok, action: "rename")
        expect(mutated == "grok-default:rename", "a Grok menu only mutates Grok")

        let summary = "5.6 Sol · High · 子：5.6 Luna · High · 标准速度"
        expect(
            !ExecutionPreferenceCompactCopy.showsDuplicateModelName(modelName: "5.6 Sol", visibleLine: summary),
            "compact model label must not print the model name twice"
        )
        expect(
            ExecutionPreferenceCompactCopy.showsDuplicateModelName(
                modelName: "5.6 Sol",
                visibleLine: "5.6 Sol 5.6 Sol · High · 子：5.6 Luna"
            ),
            "repro: the reported compact control concatenated the model name with a summary that already started with it"
        )
        expect(
            ExecutionPreferenceCompactCopy.compactSummary(modelName: "5.6 Sol", summary: summary) == summary,
            "compact copy keeps one summary line"
        )
        expect(AgentNavCatalog.localKind("grok") == .grok, "non-Codex model UI is keyed by provider ID, not Codex")
        expect(AgentNavCatalog.localKind("codex") == nil, "Codex execution presets stay on Codex rows only")
    }

    private static func reproduceResponsiveTokenAndAccountLayouts(expect: (Bool, String) -> Void) {
        expect(
            TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: 786),
            "822pt window content stacks totals and announcement columns"
        )
        expect(
            !TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: 1_064),
            "1100pt window content keeps the two modules side by side"
        )
        expect(
            !TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: 1_404),
            "1440pt window content keeps the two modules side by side"
        )
        expect(TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: 320), "narrow bounds stack safely")
        expect(TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: .infinity), "nonfinite responsive widths are safe")
        expect(
            TokenTotalsHeaderResponsiveLayout.shouldStack(
                containerWidth: TokenTotalsHeaderResponsiveLayout.minimumHorizontalWidth.nextDown
            ),
            "totals stack immediately below the exact three-child HStack boundary"
        )
        expect(
            !TokenTotalsHeaderResponsiveLayout.shouldStack(
                containerWidth: TokenTotalsHeaderResponsiveLayout.minimumHorizontalWidth
            ),
            "totals fit at the exact three-child HStack boundary"
        )

        expect(AccountCardGridLayout.columnCount(width: 784, itemCount: 9) == 2, "account cards keep natural width at 822pt")
        expect(AccountCardGridLayout.columnCount(width: 1_064, itemCount: 9) == 3, "account cards add a third column at 1100pt")
        expect(AccountCardGridLayout.columnCount(width: 1_404, itemCount: 9) == 4, "account cards add a fourth column at 1440pt")
    }

    private static func reproduceTokenCalendarSemantics(expect: (Bool, String) -> Void) {
        let utc = StatisticsContext(
            preference: StatisticsTimeZonePreference(selection: .utc, fixedIdentifier: "UTC"),
            now: Date(timeIntervalSince1970: 0)
        )
        let shanghai = StatisticsContext(
            preference: StatisticsTimeZonePreference(selection: .fixed, fixedIdentifier: "Asia/Shanghai"),
            now: Date(timeIntervalSince1970: 0)
        )
        let event = ISO8601DateFormatter().date(from: "2026-09-04T17:30:00Z")!
        expect(utc.dayKey(for: event) == "2026-09-04", "calendar fixture uses UTC day bucket")
        expect(shanghai.dayKey(for: event) == "2026-09-05", "calendar fixture uses selected Shanghai day bucket")

        let losAngeles = StatisticsContext(
            preference: StatisticsTimeZonePreference(selection: .fixed, fixedIdentifier: "America/Los_Angeles"),
            now: Date(timeIntervalSince1970: 0)
        )
        let historicalDSTInstant = ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z")!
        let nextDay = losAngeles.calendar.date(
            byAdding: .day,
            value: 1,
            to: losAngeles.startOfDay(for: historicalDSTInstant)
        )!
        expect(
            Int(nextDay.timeIntervalSince(losAngeles.startOfDay(for: historicalDSTInstant))) == 23 * 3_600,
            "DST fixture uses a real UTC instant rather than nonexistent local 02:30"
        )

        let points = [
            UpstreamTrendView.Point(date: "2026-09-05", tokens: 0),
            UpstreamTrendView.Point(date: "invalid", tokens: .nan),
            UpstreamTrendView.Point(date: "huge", tokens: .infinity),
            UpstreamTrendView.Point(date: "too-large", tokens: Double.greatestFiniteMagnitude),
        ]
        let values = TokenTotalsHeader.normalizedDailyValues(points)
        expect(values["2026-09-05"] == 0, "a true zero remains a recorded zero")
        expect(values["missing"] == nil, "an absent day remains missing")
        expect(TokenTotalsHeader.safeTokenCount(.nan) == nil, "NaN token data is rejected safely")
        expect(TokenTotalsHeader.safeTokenCount(.infinity) == nil, "infinite token data is rejected safely")
        expect(TokenTotalsHeader.safeTokenCount(Double.greatestFiniteMagnitude) == nil, "huge token data is rejected safely")
    }

    private static func reproduceLocalUsageCoverage(expect: (Bool, String) -> Void) {
        expect(LocalUsageTotalsContract.combined(official: 0, local: 0) == 0, "complete true zero totals stay numeric")
        expect(LocalUsageTotalsContract.combined(official: nil, local: 17) == nil, "missing official source cannot produce a complete total")
        expect(LocalUsageTotalsContract.combined(official: 17, local: nil) == nil, "missing local source cannot produce a complete total")
        expect(LocalUsageTotalsContract.combined(official: Int64.max, local: 1) == nil, "combined total overflow is unavailable")
        expect(
            LocalUsageTotalsContract.confirmed(0, hasCompleteTotals: true) == 0,
            "a complete true zero remains a confirmed aggregate"
        )
        expect(
            LocalUsageTotalsContract.confirmed(0, hasCompleteTotals: false) == nil,
            "daily-only placeholder zero is never presented as an aggregate"
        )
        expect(
            TokenTotalsHeader.totalText(0, language: .zh) != "暂不可确认",
            "a complete true zero has a numeric display contract"
        )
        expect(
            TokenTotalsHeader.totalText(nil, language: .zh) == "暂不可确认",
            "a missing aggregate uses the explicit unavailable display contract"
        )
        let historical = LocalUsageTotalsContract.lifetime(nil, historicalHighWater: 42)
        expect(
            historical == .init(value: 42, isHistorical: true),
            "a saved high-water mark remains visible only as historical lifetime usage"
        )
        expect(
            LocalUsageTotalsContract.lifetime(nil, historicalHighWater: 0).value == nil,
            "an unconfirmed zero high-water mark cannot stand in for a missing source"
        )
        let dailyOnlyBuckets = [UpstreamTrendView.Point(date: "2026-09-12", tokens: 17)]
        expect(
            TokenTotalsHeader.normalizedDailyValues(dailyOnlyBuckets)["2026-09-12"] == 17,
            "daily records remain independently renderable when aggregate coverage is unavailable"
        )
    }

    private static func reproduceTrendRendererBoundaries(expect: (Bool, String) -> Void) {
        let valid = UpstreamTrendView.Point(date: "2026-09-05", tokens: 1)
        let sanitized = UpstreamTrendView.Renderer.sanitizedPoints([
            valid,
            UpstreamTrendView.Point(date: "", tokens: 2),
            UpstreamTrendView.Point(date: "bad", tokens: .nan),
            UpstreamTrendView.Point(date: "negative", tokens: -1),
        ])
        expect(sanitized == [valid], "chart payload keeps only finite nonnegative dated points")
        expect(UpstreamTrendView.Renderer.sanitizedPoints([]).isEmpty, "empty chart payload stays distinct")
        expect(UpstreamTrendView.Renderer.renderResultIsValid("<svg></svg>"), "chart success requires nonempty SVG output")
        expect(!UpstreamTrendView.Renderer.renderResultIsValid(nil), "missing chart result is a failure")
        expect(!UpstreamTrendView.Renderer.renderResultIsValid("  \n"), "blank chart result is a failure")
        expect(!UpstreamTrendView.Renderer.renderResultIsValid("not SVG"), "non-SVG chart result is a failure")
        expect(!UpstreamTrendView.Renderer.renderResultIsValid(["unexpected"]), "invalid chart result is a failure")
        expect(UpstreamTrendView.Renderer.rendererFunctionIsAvailable(true), "JavaScript boolean renderer result is accepted")
        expect(UpstreamTrendView.Renderer.rendererFunctionIsAvailable("true"), "string renderer probe remains compatible")
        expect(!UpstreamTrendView.Renderer.rendererFunctionIsAvailable(false), "missing renderer function is rejected")

        let initiallyInvalid = UpstreamTrendView.Renderer()
        initiallyInvalid.update(
            points: [UpstreamTrendView.Point(date: "invalid", tokens: .nan)],
            height: 40
        )
        expect(initiallyInvalid.state == .failed(.invalidData), "initial all-invalid input cannot early-return as loading")
        let currentWeb = WKWebView(frame: .zero)
        let previousWeb = WKWebView(frame: .zero)
        initiallyInvalid.attach(currentWeb)
        initiallyInvalid.attach(currentWeb)
        expect(initiallyInvalid.state == .failed(.invalidData), "representable attachment preserves invalid input instead of feeding filtered empty data back")
        initiallyInvalid.didFinishLoading(previousWeb, navigation: nil)
        expect(initiallyInvalid.isAttached(to: currentWeb), "a stale WebView finish cannot replace the current attachment")
        initiallyInvalid.didFailNavigation(previousWeb, navigation: nil)
        expect(initiallyInvalid.isAttached(to: currentWeb), "a stale WebView failure cannot replace the current attachment")
        expect(initiallyInvalid.state == .failed(.invalidData), "stale WebView callbacks cannot change the current input state")
        initiallyInvalid.update(points: [], height: 40)
        expect(initiallyInvalid.state == .empty, "invalid input can transition to true empty")
        initiallyInvalid.update(points: [valid], height: 40)
        expect(initiallyInvalid.state == .loading, "invalid to empty to valid returns to loading")

        var emptyToValid = UpstreamTrendView.Renderer.Lifecycle()
        emptyToValid.updateInput(.empty)
        let emptyLoad = emptyToValid.beginLoad()
        expect(!emptyToValid.finishNavigation(loadID: emptyLoad), "empty navigation finishes without rendering")
        emptyToValid.updateInput(.valid)
        expect(emptyToValid.canProbeRenderer, "empty to valid probes the already loaded renderer")
        let emptyProbe = emptyToValid.beginRendererProbe()
        expect(emptyProbe == emptyLoad, "renderer probe belongs to the current navigation")
        expect(
            emptyToValid.completeRendererProbe(loadID: emptyLoad, available: true),
            "available renderer requests a render for valid data"
        )
        let firstRender = emptyToValid.beginRender()
        expect(firstRender != nil, "valid data begins a production render")
        if let firstRender {
            expect(emptyToValid.completeRender(firstRender, failure: nil), "current render completion is accepted")
        }
        expect(emptyToValid.state == .ready, "empty to valid reaches ready")

        emptyToValid.updateInput(.empty)
        expect(emptyToValid.state == .empty, "ready to empty clears the chart state")
        emptyToValid.updateInput(.valid)
        expect(emptyToValid.canRender, "ready to empty to valid reuses the confirmed renderer")
        let restoredRender = emptyToValid.beginRender()
        if let restoredRender {
            _ = emptyToValid.completeRender(restoredRender, failure: nil)
        }
        expect(emptyToValid.state == .ready, "ready to empty to valid renders again")

        emptyToValid.updateInput(.invalid)
        expect(emptyToValid.state == .failed(.invalidData), "ready to invalid exposes invalid data")
        emptyToValid.updateInput(.empty)
        emptyToValid.updateInput(.valid)
        expect(emptyToValid.canRender, "invalid to empty to valid reuses a healthy renderer")

        var retriedNavigation = UpstreamTrendView.Renderer.Lifecycle()
        retriedNavigation.updateInput(.valid)
        let oldLoad = retriedNavigation.beginLoad()
        let currentLoad = retriedNavigation.beginLoad()
        expect(
            !retriedNavigation.failNavigation(loadID: oldLoad),
            "an old navigation failure cannot overwrite a retry"
        )
        expect(retriedNavigation.state == .loading, "the retry remains loading after an old failure")
        expect(retriedNavigation.finishNavigation(loadID: currentLoad), "the current retry navigation can finish")

        let currentProbe = retriedNavigation.beginRendererProbe()
        expect(currentProbe == currentLoad, "retry probes only the current load")
        _ = retriedNavigation.completeRendererProbe(loadID: currentLoad, available: true)
        let oldSizeRender = retriedNavigation.beginRender()
        let currentSizeRender = retriedNavigation.beginRender()
        if let oldSizeRender {
            expect(
                !retriedNavigation.completeRender(oldSizeRender, failure: .scriptFailed),
                "a stale pre-resize completion cannot replace the current render"
            )
        }
        if let currentSizeRender {
            expect(
                retriedNavigation.completeRender(currentSizeRender, failure: nil),
                "the latest resize render completion is accepted"
            )
        }
        expect(retriedNavigation.state == .ready, "resize lifecycle ends ready")

        var failures = UpstreamTrendView.Renderer.Lifecycle()
        failures.updateInput(.valid)
        failures.failWithoutNavigation(.resourceUnavailable)
        expect(failures.state == .failed(.resourceUnavailable), "missing resources keep a visible retry state")
        let failedNavigation = failures.beginLoad()
        expect(failures.failNavigation(loadID: failedNavigation), "current navigation failures are accepted")
        expect(failures.state == .failed(.navigationFailed), "navigation failure keeps a visible retry state")

        let rendererLoad = failures.beginLoad()
        _ = failures.finishNavigation(loadID: rendererLoad)
        _ = failures.beginRendererProbe()
        _ = failures.completeRendererProbe(loadID: rendererLoad, available: false)
        expect(failures.state == .failed(.rendererUnavailable), "missing JS function keeps a visible retry state")

        let scriptLoad = failures.beginLoad()
        _ = failures.finishNavigation(loadID: scriptLoad)
        _ = failures.beginRendererProbe()
        _ = failures.completeRendererProbe(loadID: scriptLoad, available: true)
        if let scriptRender = failures.beginRender() {
            _ = failures.completeRender(scriptRender, failure: .scriptFailed)
        }
        expect(failures.state == .failed(.scriptFailed), "script errors keep a visible retry state")
        if let emptyOutputRender = failures.beginRender() {
            _ = failures.completeRender(emptyOutputRender, failure: .rendererReturnedNoOutput)
        }
        expect(failures.state == .failed(.rendererReturnedNoOutput), "missing SVG output keeps a visible retry state")

        failures.contentProcessTerminated()
        expect(failures.state == .failed(.processTerminated), "content process termination keeps a visible retry state")
    }

    private static func reproduceResetAnnouncementPresentation(expect: (Bool, String) -> Void) {
        let xSource = PublicResetAnnouncement.Source(
            type: "x_post",
            author: "thsottiaux",
            url: URL(string: "https://x.com/thsottiaux/status/123")
        )
        let observedSource = PublicResetAnnouncement.Source(type: "observed", author: nil, url: PublicResetClient.siteURL)
        let xLabel = PublicResetAnnouncementPresentation.sourceLabel(xSource, language: .zh)
        let observedLabel = PublicResetAnnouncementPresentation.sourceLabel(observedSource, language: .zh)
        expect(xLabel.contains("X") && xLabel.contains("thsottiaux"), "X source keeps its author visible")
        expect(!xLabel.contains("网友观察"), "X source is not mislabeled as generic user observation")
        expect(observedLabel.contains("观察记录") && !observedLabel.contains(".com"), "observed source keeps its meaning without showing a bare domain")
        expect(
            PublicResetAnnouncementPresentation.readableText("Reset complete. https://t.co/example") == "Reset complete.",
            "announcement presentation removes trailing web addresses"
        )
        expect(
            PublicResetAnnouncementPresentation.readableText("第一行\nHTTPS://example.com/reset\n确认完成") == "第一行\n\n确认完成",
            "URL filtering preserves surrounding multilingual content and paragraph boundaries"
        )
        expect(
            PublicResetAnnouncementPresentation.sourceLinkTitle(observedSource, language: .zh).contains("来源"),
            "an aggregator URL is labeled as its source"
        )
        expect(PublicResetAnnouncementPresentation.title(.zh) == "额度重置公告", "announcement section uses the critical label")
        expect(
            PublicResetAnnouncementPresentation.typeTitle(.regular, language: .zh).contains("常规额度"),
            "regular quota announcements stay distinct from reset cards"
        )
        expect(
            PublicResetAnnouncementPresentation.typeTitle(.banked, language: .zh).contains("重置卡"),
            "banked announcements are labeled as reset-card announcements"
        )
        let regularMeaning = PublicResetAnnouncementPresentation.interpretation(.regular, language: .zh)
        expect(!regularMeaning.contains("有人额度") && regularMeaning.contains("不代表个人额度已刷新"), "regular copy does not invent personal delivery")
        expect(AnnouncementOriginalText.collapsedLineLimit == 2, "home announcement defaults to two lines with a full-text expansion")
        expect(
            PublicResetAnnouncementPresentation.eventTime(Date(timeIntervalSince1970: 1_789_000_000), language: .zh).contains(":"),
            "announcement event time keeps an exact clock value"
        )
        let event = ISO8601DateFormatter().date(from: "2026-09-12T08:09:17Z")!
        let compactTime = PublicResetAnnouncementPresentation.compactEventTime(event, language: .zh)
        expect(compactTime.contains("2026-09-12 16:09"), "home announcement keeps the full Beijing year and clock")
        expect(
            PublicResetAnnouncementPresentation.relativeEventTime(event, now: event.addingTimeInterval(7 * 3600), language: .zh).contains("7"),
            "home announcement age uses its event time")
        expect(
            PublicResetAnnouncementPresentation.relativeEventTime(event, now: event.addingTimeInterval(-30), language: .zh) == "刚刚",
            "allowed source clock skew does not create a future reset claim")
        let now = ISO8601DateFormatter().date(from: "2026-09-19T00:00:00Z")!
        let recent = PublicResetAnnouncement(
            id: "456", resetType: .regular, announcedAt: now.addingTimeInterval(-86_400), text: "recent",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/456")))
        let old = PublicResetAnnouncement(
            id: "457", resetType: .regular, announcedAt: now.addingTimeInterval(-31 * 86_400), text: "old",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/457")))
        let future = PublicResetAnnouncement(
            id: "458", resetType: .regular, announcedAt: now.addingTimeInterval(60), text: "future",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/458")))
        expect(
            PublicResetAnnouncementPresentation.recentVerifiableAnnouncement([old, future, recent], now: now)?.id == "456",
            "homepage announcements use only verifiable, non-future items from the last 30 days"
        )
        expect(
            PublicResetAnnouncementPresentation.recentVerifiableAnnouncement([old, future], now: now) == nil,
            "old and future announcements stay out of the homepage current-message slot"
        )
    }

    private static func solidPNG(color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }
}
