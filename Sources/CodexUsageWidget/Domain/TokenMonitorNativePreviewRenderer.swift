import AppKit
import SwiftUI

/// Renders the production Token Monitor SwiftUI views with synthetic DTOs only.
@MainActor
enum TokenMonitorNativePreviewRenderer {
    private static let referenceDate = Date()

    static func fixtureSelfTest() -> Bool {
        let regular = TokenMonitorDashboardSnapshot(response: response())
        let large = TokenMonitorDashboardSnapshot(response: response(largeNumbers: true))
        let empty = TokenMonitorDashboardSnapshot(response: nil)
        let leapNow = fixtureDate(year: 2024, month: 3, day: 1)
        let leapSnapshot = TokenMonitorDashboardSnapshot(response: response(dayCount: 366, endingAt: leapNow))
        let leapYear = leapSnapshot.trendDays(range: .year, now: leapNow)
        let leapHeatmap = leapSnapshot.heatmapDays(count: 365, now: leapNow)
        let leapDates = leapHeatmap.compactMap { $0?.date }
        let sparseTrendMiddle = TokenMonitorTrendPlot.datePosition(
            for: "2026-09-10",
            between: "2026-09-01",
            and: "2026-09-20"
        )
        let statusEntryError = TokenMonitorServiceStatusEntry(
            id: "fixture-error",
            label: "Claude",
            pageURL: "https://status.claude.com",
            state: .unknown,
            indicator: .unknown,
            description: "",
            checkedAt: referenceDate,
            updatedAt: nil,
            componentIssues: [],
            incidentTitle: nil,
            incidentCount: 0,
            maintenanceCount: 0,
            error: "synthetic network failure",
            isStale: false
        )
        let statusErrorZh = statusEntryError.localizedError(.zh)
        let statusErrorEn = statusEntryError.localizedError(.en)
        let statusComponent = TokenMonitorServiceStatusPresentation(store: serviceStatusStore())
            .providers.first(where: { $0.id == "openai" })
        let hubErrorZh = TokenMonitorIntegrationFailure.transport.localizedMessage(.zh)
        let hubErrorEn = TokenMonitorIntegrationFailure.transport.localizedMessage(.en)
        let maxCount = TokenMonitorFormatting.count(Int64.max, compact: true, language: .en)
        return regular.summary.totalTokens == 482_137_009
            && regular.days.count == 365
            && regular.value(for: .total, metric: .tokens, now: referenceDate) == 482_137_009
            && regular.heatmapDays(count: 365, now: referenceDate).count == 365
            && large.summary.totalTokens == Int64.max
            && large.tokenCount(for: .total, now: referenceDate) == Int64.max
            && TokenMonitorFormatting.count(large.tokenCount(for: .total, now: referenceDate), language: .en) == "9,223,372,036,854,775,807"
            && large.summary.peakDayTokens == Int64.max
            && large.days.count == 365
            && maxCount.hasPrefix("9,223,372,036.")
            && maxCount.hasSuffix("B")
            && empty.summary.totalTokens == nil
            && empty.days.isEmpty
            && leapYear.count == 365
            && leapYear.first?.date == "2023-03-03"
            && leapYear.last?.date == "2024-03-01"
            && leapDates.count == 365
            && leapDates.first == "2023-03-03"
            && leapDates.last == "2024-03-01"
            && leapDates.contains("2024-02-29")
            && sparseTrendMiddle.map { abs($0 - (9.0 / 19.0)) < 0.0001 } == true
            && TokenMonitorTrendPlot.datePosition(
                for: "2026-09-21",
                between: "2026-09-01",
                and: "2026-09-20"
            ) == nil
            && statusErrorZh == "暂时无法读取官方服务状态。"
            && statusErrorEn == "Official service status is temporarily unavailable."
            && statusComponent?.localizedComponentIssues(.zh) == ["API · 性能下降"]
            && statusComponent?.localizedComponentIssues(.en) == ["API · Degraded performance"]
            && hubErrorZh == "无法连接 Hub，请检查地址和网络。"
            && hubErrorEn == "The Hub could not be reached. Check its address and network."
    }

    private static func renderProxyActivity(to directory: URL) throws {
        let rows = [4, 8].map { number in
            LocalProxyQueueRow(
                id: "fixture-proxy-\(number)", label: "示例 Plus 账号", accountNumber: number,
                windows: [
                    .init(id: "5h", remaining: number == 4 ? 89 : 100, resetsAt: referenceDate.addingTimeInterval(17_520)),
                    .init(id: "7d", remaining: number == 4 ? 21 : 73, resetsAt: referenceDate.addingTimeInterval(360_000)),
                ], creditBalance: .init(balance: "2240.36", unlimited: false),
                isEnabled: true, isPriority: false, isCurrent: true, quotaText: nil,
                state: "current", cooldownUntil: nil, activeRequestCount: 1)
        }
        let preferences = TokenMonitorEdgeDockPreferences(enabled: true, mode: .always, items: [.proxy()])
        let cells = TokenMonitorEdgeDockProjection.make(
            preferences: preferences, quotaSources: [], usage: .init(response: nil), language: .zh,
            proxyPhase: .running, proxyRows: rows)
        for scheme in [ColorScheme.dark, .light] {
            let controlSamples = VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("开启反代") {}.buttonStyle(WorkspaceActionButtonStyle(prominent: true))
                    Button("复制连接配置") {}.buttonStyle(WorkspaceActionButtonStyle())
                    Button("保存底线") {}.buttonStyle(WorkspaceActionButtonStyle()).disabled(true)
                }
                HStack(spacing: 18) {
                    Toggle("参与", isOn: .constant(true))
                    Toggle("优先", isOn: .constant(false))
                    Toggle("参与（运行时锁定）", isOn: .constant(true)).disabled(true)
                }
                .toggleStyle(WorkspaceCheckboxStyle())
                TokenMonitorDesktopEntryView(language: .zh, route: .menuBarSettings)
                Divider()
                TokenMonitorDesktopEntryView(language: .zh, route: .floatingBubbleSettings)
            }
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
            try WorkspacePreviewRenderer.renderView(
                controlSamples, size: CGSize(width: 610, height: 390), scheme: scheme,
                to: directory.appendingPathComponent("settings-controls-\(scheme == .dark ? "dark" : "light").png"))
            let view = HStack(alignment: .center, spacing: 4) {
                TokenMonitorEdgeDockCardView(
                    cell: cells[0], side: .right, language: .zh, tailY: 166,
                    isPinned: true, canPin: false, onPin: {}, onOpenDashboard: {})
                    .frame(width: 292, height: 332)
                TokenMonitorEdgeDockRailView(
                    cells: cells, side: .right, language: .zh, compact: false, warnColors: false,
                    focusedIndex: 0, onSelect: { _ in }, onDrag: { _ in }, onDrop: { _ in })
                    .frame(width: 64, height: 134)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.workspacePreviewDate, referenceDate)
            try WorkspacePreviewRenderer.renderView(
                view, size: CGSize(width: 392, height: 364), scheme: scheme,
                to: directory.appendingPathComponent("proxy-activity-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private static func renderQuotaDock(to directory: URL) throws {
        var grok = TokenMonitorFloatingBubbleAccount(
            providerID: "grok", providerName: "Grok", accountID: "fixture-grok",
            accountName: "01 · Grok", metrics: [
                .init(id: "balance", name: "余额", sourceID: "grok:fixture-grok:balance",
                      fetchedAt: referenceDate, value: .text("7.50 USD")),
                .init(id: "credits", name: "每月额度", sourceID: "grok:fixture-grok:credits",
                      fetchedAt: referenceDate, value: .percentRemaining(63),
                      resetLabel: "2026-10-01"),
            ])
        let claude = TokenMonitorFloatingBubbleAccount(
            providerID: "claude", providerName: "Claude", accountID: "fixture-claude",
            accountName: "02 · Claude", metrics: [
                .init(id: "balance", name: "余额", sourceID: "claude:fixture-claude:balance",
                      fetchedAt: referenceDate, value: .text("12.34 USD")),
            ])
        grok.metrics[1].isStale = true
        let preferences = TokenMonitorEdgeDockPreferences(
            enabled: true, mode: .always,
            items: [.account("grok", grok.accountID), .account("claude", claude.accountID)])
        let cells = TokenMonitorEdgeDockProjection.make(
            preferences: preferences, quotaSources: [grok, claude],
            usage: .init(response: nil), language: .zh, now: referenceDate)
        for scheme in [ColorScheme.dark, .light] {
            for index in cells.indices {
                let view = HStack(alignment: .center, spacing: 4) {
                    TokenMonitorEdgeDockCardView(
                        cell: cells[index], side: .right, language: .zh, tailY: 166,
                        isPinned: true, canPin: false, onPin: {}, onOpenDashboard: {})
                        .frame(width: 292, height: 332)
                    TokenMonitorEdgeDockRailView(
                        cells: cells, side: .right, language: .zh, compact: false, warnColors: false,
                        focusedIndex: index, onSelect: { _ in }, onDrag: { _ in }, onDrop: { _ in })
                        .frame(width: 64, height: 204)
                }
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
                try WorkspacePreviewRenderer.renderView(
                    view, size: CGSize(width: 392, height: 364), scheme: scheme,
                    to: directory.appendingPathComponent(
                        "edge-quota-\(index == 0 ? "grok" : "claude")-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    static func render(to directory: URL) -> Bool {
        guard fixtureSelfTest() else {
            print("Token Monitor native preview fixture check failed")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try renderProxyActivity(to: directory)
            try renderQuotaDock(to: directory)
            let catalog = PaletteCatalog.loadFromMainBundle()
            let dashboard = TokenMonitorDashboardSnapshot(response: response())
            let largeDashboard = TokenMonitorDashboardSnapshot(response: response(largeNumbers: true))
            let leapNow = fixtureDate(year: 2024, month: 3, day: 1)
            let leapSnapshot = TokenMonitorDashboardSnapshot(response: response(dayCount: 366, endingAt: leapNow))
            let leapHeatmap = leapSnapshot.heatmapDays(count: 365, now: leapNow)
            let status = TokenMonitorServiceStatusPresentation(store: serviceStatusStore())
            let hub = TokenMonitorHubPresentation(store: hubStore())

            try renderDashboard(
                dashboard,
                paletteID: "codexu.liquid-keycap",
                scheme: .dark,
                language: .zh,
                catalog: catalog,
                directory: directory,
                filename: "dashboard-dark-zh-liquid-keycap.png",
                size: CGSize(width: 1_280, height: 900)
            )
            try renderDashboard(
                dashboard,
                paletteID: "codexu.liquid-keycap",
                scheme: .dark,
                language: .zh,
                catalog: catalog,
                directory: directory,
                filename: "dashboard-dark-zh-four-column-920.png",
                size: CGSize(width: 920, height: 1_000)
            )
            try renderDashboard(
                dashboard,
                paletteID: "codexu.liquid-keycap",
                scheme: .dark,
                language: .zh,
                catalog: catalog,
                directory: directory,
                filename: "dashboard-dark-zh-two-column-520.png",
                size: CGSize(width: 520, height: 1_150)
            )
            try renderLeapHeatmap(
                days: leapHeatmap,
                timezone: leapSnapshot.timezone,
                now: leapNow,
                paletteID: "codexu.liquid-keycap",
                catalog: catalog,
                directory: directory
            )
            try renderSparseTrend(
                days: sparseTrendFixtureDays,
                paletteID: "codexu.liquid-keycap",
                catalog: catalog,
                directory: directory
            )
            try renderDashboard(
                dashboard,
                paletteID: "codexu.liquid-keycap",
                scheme: .dark,
                language: .en,
                catalog: catalog,
                directory: directory,
                filename: "dashboard-dark-en-liquid-keycap.png",
                size: CGSize(width: 1_280, height: 900)
            )
            try renderDashboard(
                dashboard,
                paletteID: "codexu.liquid-keycap",
                scheme: .light,
                language: .en,
                catalog: catalog,
                directory: directory,
                filename: "dashboard-light-en-liquid-keycap.png",
                size: CGSize(width: 1_280, height: 900)
            )
            try renderPopover(
                dashboard,
                status: status,
                hub: hub,
                paletteID: "codexu.blue-white-porcelain",
                scheme: .dark,
                language: .zh,
                catalog: catalog,
                directory: directory,
                filename: "popover-home-dark-zh-blue-white-porcelain.png",
                size: CGSize(width: 430, height: 780)
            )
            try renderPopover(
                largeDashboard,
                status: status,
                hub: hub,
                paletteID: "codexu.liquid-keycap",
                scheme: .light,
                language: .en,
                catalog: catalog,
                directory: directory,
                filename: "popover-home-large-counts-light-en-narrow.png",
                size: CGSize(width: 420, height: 760)
            )
            try renderPopover(
                dashboard,
                status: status,
                hub: hub,
                paletteID: "codexu.liquid-keycap",
                scheme: .dark,
                language: .en,
                catalog: catalog,
                directory: directory,
                filename: "popover-home-dark-en-short-height-412.png",
                size: CGSize(width: 420, height: 412)
            )
            try renderPopover(
                TokenMonitorDashboardSnapshot(response: nil),
                status: .unavailable,
                hub: .unavailable,
                paletteID: "codexu.liquid-keycap",
                scheme: .dark,
                language: .zh,
                catalog: catalog,
                directory: directory,
                filename: "popover-empty-dark-zh.png",
                size: CGSize(width: 420, height: 680)
            )
            try renderPopover(
                dashboard,
                status: status,
                hub: hub,
                route: .status,
                paletteID: "codexu.liquid-keycap",
                scheme: .dark,
                language: .zh,
                catalog: catalog,
                directory: directory,
                filename: "popover-status-dark-zh.png",
                size: CGSize(width: 430, height: 720)
            )
            try renderPopover(
                dashboard,
                status: status,
                hub: hub,
                route: .status,
                paletteID: "codexu.blue-white-porcelain",
                scheme: .light,
                language: .en,
                catalog: catalog,
                directory: directory,
                filename: "popover-status-light-en.png",
                size: CGSize(width: 430, height: 720)
            )
            try renderPopover(
                dashboard,
                status: status,
                hub: hub,
                route: .totalsByTool,
                paletteID: "codexu.liquid-keycap",
                scheme: .dark,
                language: .zh,
                catalog: catalog,
                directory: directory,
                filename: "popover-totals-tool-dark-zh.png",
                size: CGSize(width: 430, height: 720)
            )
            try renderPopover(
                dashboard,
                status: status,
                hub: hub,
                route: .totalsByModel,
                paletteID: "codexu.blue-white-porcelain",
                scheme: .light,
                language: .en,
                catalog: catalog,
                directory: directory,
                filename: "popover-totals-model-light-en.png",
                size: CGSize(width: 430, height: 720)
            )

            try renderSettings(
                paletteID: "codexu.liquid-keycap",
                scheme: .dark,
                language: .zh,
                includeStatusError: false,
                catalog: catalog,
                directory: directory,
                filename: "settings-token-monitor-dark-zh.png"
            )
            try renderSettings(
                paletteID: "codexu.liquid-keycap",
                scheme: .light,
                language: .en,
                includeStatusError: true,
                catalog: catalog,
                directory: directory,
                filename: "settings-token-monitor-light-en.png"
            )

            let note = """
                AiGoodBro Token Monitor native SwiftUI preview; synthetic data only.
                The screenshots render production Dashboard, Home Popover, Status, Totals, and Settings views over a fixed fixture wallpaper.
                Chinese and English are included; dashboard captures cover eight, four, and two KPI columns at 1280, 920, and 520 pt widths.
                Separate fixtures cover a 2024 cross-year grid through leap day and sparse September trend dates, with exact date-position assertions. A 412 pt popover capture covers limited available screen height.
                The offscreen captures composite the production SwiftUI views over a fixed synthetic wallpaper. The native AppKit glass host and system popover are verified separately in the running app with a real window screenshot.
                No user account data, credentials, Hub writes, UsageStore startup, or network calls are used by this renderer.
                """
            try note.write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            print(
                "Token Monitor native previews rendered: synthetic SwiftUI fixtures, zh/en, dark/light, dashboard/popover/status/totals/settings, sparse trend, narrow/empty/large-value states"
            )
            return true
        } catch {
            print("Token Monitor native preview render failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func renderDashboard(
        _ snapshot: TokenMonitorDashboardSnapshot,
        paletteID: String,
        scheme: ColorScheme,
        language: WidgetLanguage,
        catalog: PaletteCatalog,
        directory: URL,
        filename: String,
        size: CGSize
    ) throws {
        let tokens = catalog.resolve(id: paletteID, appearance: PaletteAppearance(scheme))
        let content = TokenMonitorDashboardView(snapshot: snapshot, language: language, onRefresh: {})
            .padding(22)
            .background(WorkspaceGlassSurface(cornerRadius: 22))
        let view = TokenMonitorPreviewCanvas(tokens: tokens, scheme: scheme, language: language, size: size) {
            content
        }
        try WorkspacePreviewRenderer.renderView(
            view,
            size: size,
            scheme: scheme,
            to: directory.appendingPathComponent(filename)
        )
    }

    private static func renderLeapHeatmap(
        days: [TokenMonitorDashboardSnapshot.Day?],
        timezone: TimeZone,
        now: Date,
        paletteID: String,
        catalog: PaletteCatalog,
        directory: URL
    ) throws {
        let size = CGSize(width: 1_280, height: 210)
        let tokens = catalog.resolve(id: paletteID, appearance: PaletteAppearance(.dark))
        let heatmap = TokenMonitorHeatmap(
            days: days,
            metric: .tokens,
            timezone: timezone,
            language: .en,
            now: now
        )
        .frame(height: 170)
        .padding(16)
        .background(WorkspaceGlassSurface(cornerRadius: 18))
        let view = TokenMonitorPreviewCanvas(tokens: tokens, scheme: .dark, language: .en, size: size) {
            heatmap
        }
        try WorkspacePreviewRenderer.renderView(
            view,
            size: size,
            scheme: .dark,
            to: directory.appendingPathComponent("heatmap-cross-year-leap-day-2024-en.png")
        )
    }

    private static var sparseTrendFixtureDays: [TokenMonitorDashboardSnapshot.Day] {
        [
            ("2026-09-01", Int64(140_000)),
            ("2026-09-10", Int64(420_000)),
            ("2026-09-20", Int64(260_000)),
        ].map { date, tokens in
            TokenMonitorDashboardSnapshot.Day(
                date: date,
                tokens: tokens,
                cost: nil,
                messages: nil,
                activeTimeMs: nil,
                perClient: ["Codex": tokens],
                perModel: ["GPT-6 Luna": tokens],
                coverage: .known,
                costCoverage: .unknown
            )
        }
    }

    private static func renderSparseTrend(
        days: [TokenMonitorDashboardSnapshot.Day],
        paletteID: String,
        catalog: PaletteCatalog,
        directory: URL
    ) throws {
        let size = CGSize(width: 760, height: 330)
        let tokens = catalog.resolve(id: paletteID, appearance: PaletteAppearance(.dark))
        let content = VStack(alignment: .leading, spacing: 10) {
            Text("Sparse daily captures")
                .font(.system(size: 16, weight: .semibold))
            Text("Sep 1 · Sep 10 · Sep 20, 2026")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            TokenMonitorTrendPlot(days: days, metric: .tokens, language: .en)
                .frame(height: 190)
        }
        .padding(18)
        .background(WorkspaceGlassSurface(cornerRadius: 18))
        let view = TokenMonitorPreviewCanvas(tokens: tokens, scheme: .dark, language: .en, size: size) {
            content
        }
        try WorkspacePreviewRenderer.renderView(
            view,
            size: size,
            scheme: .dark,
            to: directory.appendingPathComponent("trend-sparse-dates-dark-en.png")
        )
    }

    private static func renderPopover(
        _ snapshot: TokenMonitorDashboardSnapshot,
        status: TokenMonitorServiceStatusPresentation,
        hub: TokenMonitorHubPresentation,
        route: TokenMonitorViewRoute = .home,
        paletteID: String,
        scheme: ColorScheme,
        language: WidgetLanguage,
        catalog: PaletteCatalog,
        directory: URL,
        filename: String,
        size: CGSize
    ) throws {
        let tokens = catalog.resolve(id: paletteID, appearance: PaletteAppearance(scheme))
        let content = TokenMonitorPopoverView(
            snapshot: snapshot,
            serviceStatus: status,
            hub: hub,
            language: language,
            initialRoute: route,
            onRefresh: {},
            onRefreshStatus: {},
            onRefreshHub: {},
            onOpenAccounts: {},
            onOpenRunningTasks: {},
            onOpenSettings: {},
            onOpenWorkbench: {}
        )
        .padding(16)
        let view = TokenMonitorPreviewCanvas(tokens: tokens, scheme: scheme, language: language, size: size) {
            content
        }
        try WorkspacePreviewRenderer.renderView(
            view,
            size: size,
            scheme: scheme,
            to: directory.appendingPathComponent(filename)
        )
    }

    private static func renderSettings(
        paletteID: String,
        scheme: ColorScheme,
        language: WidgetLanguage,
        includeStatusError: Bool,
        catalog: PaletteCatalog,
        directory: URL,
        filename: String
    ) throws {
        let size = CGSize(width: 820, height: 704)
        let tokens = catalog.resolve(id: paletteID, appearance: PaletteAppearance(scheme))
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("aigoodbro-token-monitor-settings-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let suiteName = "AiGoodBro.TokenMonitorNativePreview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileReadUnknown) }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let settings = AppSettings(defaults: defaults, paletteCatalog: catalog, previewAvatarRoot: sandbox.appendingPathComponent("avatars"))
        settings.language = language
        settings.themeMode = scheme == .dark ? .dark : .light

        let services = serviceStatusStore(includeError: includeStatusError)
        let hub = hubStore()
        let usage = UsageStore(
            previewProfiles: [],
            snapshot: .empty,
            isolatedRoot: sandbox.appendingPathComponent("usage"),
            serviceStatus: services,
            tokenMonitorHubSync: hub
        )
        let updateStore = AppUpdateStore(settings: settings)
        let panel = SettingsPanelView(
            settings: settings,
            store: usage,
            updateStore: updateStore,
            onOpenPaletteLibrary: {},
            initialPage: .tokenMonitor
        )
        .frame(width: 780, height: 640)
        .background(WorkspaceGlassSurface(cornerRadius: 18))
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
        .preferredColorScheme(scheme)

        let view = TokenMonitorPreviewCanvas(tokens: tokens, scheme: scheme, language: language, size: size) {
            panel.padding(8)
        }
        try WorkspacePreviewRenderer.renderView(
            view,
            size: size,
            scheme: scheme,
            to: directory.appendingPathComponent(filename)
        )
    }

    private static func response(
        largeNumbers: Bool = false,
        dayCount: Int = 365,
        endingAt requestedEndDate: Date? = nil
    ) -> TokenMonitorResponse {
        let endDate = requestedEndDate ?? referenceDate
        let timezone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"

        let dates = (0..<dayCount).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: offset - (dayCount - 1), to: endDate) else { return nil }
            return formatter.string(from: date)
        }
        let sourceID = "synthetic-codex"
        let providerID = "codex"
        let totalTokens: Int64 = largeNumbers ? Int64.max : 482_137_009
        let totalCost = largeNumbers ? 1_234_567_890.12 : 184.72
        let activeIndices = fixtureActiveIndices(dayCount: dayCount)
        let daily: [TokenMonitorJSON] = dates.enumerated().map { index, date -> TokenMonitorJSON in
            let active = activeIndices.contains(index)
            let tokens: Int64
            if largeNumbers {
                tokens = Int64.max / Int64(dayCount)
            } else if active {
                tokens = index == dayCount - 9 ? 11_824_400 : Int64(2_700_000 + ((index * 37) % 91) * 65_000)
            } else {
                tokens = 0
            }
            let cost: Double = largeNumbers ? 12_345.67 : Double(tokens) * 0.000000383
            let messages: Int = tokens > 0 ? 60 + (index % 45) : 0
            let activeTimeMs: Int = tokens > 0 ? (3 + index % 7) * 60 * 60 * 1_000 : 0
            let perClient: [String: TokenMonitorJSON] = [
                "Codex": .number(Decimal(scaled(tokens, percent: 58))),
                "Claude Code": .number(Decimal(scaled(tokens, percent: 29))),
                "OpenCode": .number(Decimal(scaled(tokens, percent: 13))),
            ]
            let perModel: [String: TokenMonitorJSON] = [
                "GPT-6 Luna": .number(Decimal(scaled(tokens, percent: 49))),
                "Claude Sonnet": .number(Decimal(scaled(tokens, percent: 32))),
                "GPT-6 Sol": .number(Decimal(scaled(tokens, percent: 19))),
            ]
            return .object([
                "date": .string(date),
                "tokens": .number(Decimal(tokens)),
                "cost": decimal(cost),
                "messages": .number(Decimal(messages)),
                "activeTimeMs": .number(Decimal(activeTimeMs)),
                "perClient": .object(perClient),
                "perModel": .object(perModel),
            ])
        }
        let peakTokens = largeNumbers ? Int64.max : 11_824_400
        let summary: TokenMonitorJSON = .object([
            "totalTokens": .number(Decimal(totalTokens)),
            "totalCost": decimal(totalCost),
            "activeDays": .number(Decimal(82)),
            "currentStreak": .number(Decimal(17)),
            "peakDayTokens": .number(Decimal(peakTokens)),
            "favoriteModel": .string("GPT-6 Luna"),
            "messages": .number(Decimal(9_218)),
            "activeTimeMs": .number(Decimal(8_640_000_000)),
        ])
        let allTime: TokenMonitorJSON = .object([
            "models": .object([
                "GPT-6 Luna": .number(Decimal(scaled(totalTokens, percent: 49))),
                "Claude Sonnet": .number(Decimal(scaled(totalTokens, percent: 32))),
                "GPT-6 Sol": .number(Decimal(scaled(totalTokens, percent: 19))),
            ]),
            "clients": .object([
                "Codex": .number(Decimal(scaled(totalTokens, percent: 58))),
                "Claude Code": .number(Decimal(scaled(totalTokens, percent: 29))),
                "OpenCode": .number(Decimal(scaled(totalTokens, percent: 13))),
            ]),
            "modelCosts": .object([
                "GPT-6 Luna": decimal(totalCost * 0.49),
                "Claude Sonnet": decimal(totalCost * 0.32),
                "GPT-6 Sol": decimal(totalCost * 0.19),
            ]),
            "clientCosts": .object([
                "Codex": decimal(totalCost * 0.58),
                "Claude Code": decimal(totalCost * 0.29),
                "OpenCode": decimal(totalCost * 0.13),
            ]),
        ])
        let history: TokenMonitorJSON = .object([
            "summary": summary,
            "daily": .array(daily),
        ])
        let entries = dates.flatMap { date in
            ["tokens", "cost"].map { metric in
                TokenMonitorResponse.Coverage.Entry(
                    sourceId: sourceID,
                    providerId: providerID,
                    toolId: "codex",
                    accountId: nil,
                    date: date,
                    metric: metric,
                    status: .known
                )
            }
        }
        return TokenMonitorResponse(
            schemaVersion: 1,
            requestId: "native-preview-fixture",
            operation: .collectUsage,
            engine: .init(repository: "Javis603/token-monitor", commit: TokenMonitorResponse.commit, version: "fixture"),
            collectedAt: ISO8601DateFormatter().string(from: endDate),
            timezone: "Asia/Shanghai",
            status: .ok,
            sources: [.init(id: sourceID, providerId: providerID, status: .ok, coverage: .known, reasonCode: nil)],
            payload: .object(["aggregate": .object(["history": history, "allTime": allTime])]),
            coverage: .init(
                entries: entries,
                days: dates.map { .init(date: $0, status: .known) },
                cost: .known
            ),
            errors: []
        )
    }

    private static func serviceStatusStore(includeError: Bool = false) -> TokenMonitorServiceStatusStore {
        let checkedAt = referenceDate.addingTimeInterval(-85)
        let status = TokenMonitorServiceStatusStore(
            previewOnly: true,
            previewEntries: [
                .claude: TokenMonitorServiceStatusEntry(
                    id: "claude",
                    label: "Claude",
                    pageURL: "https://status.claude.com",
                    state: includeError ? .unknown : .operational,
                    indicator: includeError ? .unknown : .none,
                    description: includeError ? "Synthetic fixture · Status lookup unavailable" : "Synthetic fixture · All systems operational",
                    checkedAt: checkedAt,
                    updatedAt: checkedAt,
                    componentIssues: [],
                    incidentTitle: nil,
                    incidentCount: 0,
                    maintenanceCount: 0,
                    error: includeError ? "synthetic network failure" : nil,
                    isStale: false
                ),
                .openAI: TokenMonitorServiceStatusEntry(
                    id: "openai",
                    label: "OpenAI",
                    pageURL: "https://status.openai.com",
                    state: .degraded,
                    indicator: .minor,
                    description: "Synthetic fixture · Elevated API latency",
                    checkedAt: checkedAt,
                    updatedAt: checkedAt,
                    componentIssues: [.init(name: "API", status: "degraded_performance")],
                    incidentTitle: "Synthetic latency notice",
                    incidentCount: 1,
                    maintenanceCount: 0,
                    error: nil,
                    isStale: false
                ),
            ]
        )
        return status
    }

    private static func hubStore() -> TokenMonitorHubSyncStore {
        let timestamp = ISO8601DateFormatter().string(from: referenceDate)
        let currentDeviceID = "fixture-local-device"
        func period(_ tokens: Int64, _ cost: Double) -> TokenMonitorHubPeriod {
            TokenMonitorHubPeriod(totalTokens: tokens, costUSD: cost)
        }
        let devices = [
            TokenMonitorHubDevice(
                deviceId: currentDeviceID,
                hostname: "This Mac",
                platform: "macOS",
                agentVersion: "fixture",
                agentRuntime: "native-preview",
                updatedAt: timestamp,
                receivedAt: timestamp,
                ageMs: 300_000,
                stale: false,
                trackedClients: ["codex", "claude-code"],
                periods: TokenMonitorHubPeriods(
                    today: period(12_841_100, 4.27),
                    month: period(106_428_000, 34.12),
                    allTime: period(182_400_000, 63.42)
                ),
                isCurrent: true
            ),
            TokenMonitorHubDevice(
                deviceId: "fixture-studio-device",
                hostname: "Studio Mac",
                platform: "macOS",
                agentVersion: "fixture",
                agentRuntime: "native-preview",
                updatedAt: timestamp,
                receivedAt: timestamp,
                ageMs: 420_000,
                stale: false,
                trackedClients: ["codex"],
                periods: TokenMonitorHubPeriods(
                    today: period(6_782_000, 2.04),
                    month: period(47_600_000, 15.23),
                    allTime: period(92_810_000, 38.15)
                ),
                isCurrent: false
            ),
        ]
        let history = TokenMonitorHubHistory(
            daily: [],
            monthly: [],
            summary: TokenMonitorHubHistorySummary(
                totalTokens: 275_210_000,
                totalCost: 101.57,
                activeDays: 96,
                currentStreak: 7,
                longestStreak: 21,
                peakDayTokens: 18_240_000,
                favoriteModel: "GPT-6 Luna",
                messages: 5_481,
                activeTimeMs: 5_420_000_000
            )
        )
        let store = TokenMonitorHubSyncStore(
            previewOnly: true,
            previewEnabled: true,
            previewServerURL: "https://hub.example.invalid",
            previewCredentialStatus: .stored,
            previewConnectionState: .connected,
            previewDevices: devices,
            previewHistory: history,
            previewLocalDeviceID: currentDeviceID
        )
        return store
    }

    private static func decimal(_ value: Double) -> TokenMonitorJSON {
        .number(Decimal(string: String(format: "%.4f", value), locale: Locale(identifier: "en_US_POSIX")) ?? 0)
    }

    private static func fixtureDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private static func scaled(_ value: Int64, percent: Int64) -> Int64 {
        (value / 100) * percent + (value % 100) * percent / 100
    }

    private static func fixtureActiveIndices(dayCount: Int) -> Set<Int> {
        // Synthetic history grows denser toward today and ends with the 17-day
        // streak shown in the summary. Exactly 82 of 365 days are active.
        let streakStart = max(0, dayCount - 17)
        let firstEnd = min(streakStart, dayCount * 180 / 365)
        let secondEnd = min(streakStart, dayCount * 280 / 365)
        func sample(_ range: Range<Int>, count: Int) -> [Int] {
            range.sorted { left, right in
                func score(_ value: Int) -> UInt64 {
                    let mixed = UInt64(value + 1) &* 1_103_515_245 &+ 12_345
                    return (mixed ^ (mixed >> 15)) % 65_537
                }
                return score(left) == score(right) ? left < right : score(left) > score(right)
            }.prefix(count).map { $0 }
        }
        return Set(
            sample(0..<firstEnd, count: 10)
                + sample(firstEnd..<secondEnd, count: 15)
                + sample(secondEnd..<streakStart, count: 40)
                + Array(streakStart..<dayCount))
    }
}

private struct TokenMonitorPreviewCanvas<Content: View>: View {
    let tokens: ResolvedVisualTokens
    let scheme: ColorScheme
    let language: WidgetLanguage
    let size: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.035, green: 0.055, blue: 0.10), Color(red: 0.065, green: 0.14, blue: 0.20), Color(red: 0.11, green: 0.09, blue: 0.16)]
                    : [Color(red: 0.80, green: 0.88, blue: 0.96), Color(red: 0.88, green: 0.91, blue: 0.93), Color(red: 0.93, green: 0.86, blue: 0.80)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [tokens.accent.primary.color.opacity(scheme == .dark ? 0.28 : 0.22), .clear],
                center: .topTrailing,
                startRadius: 5,
                endRadius: 480
            )
            RadialGradient(
                colors: [tokens.accent.secondary.color.opacity(scheme == .dark ? 0.18 : 0.16), .clear],
                center: .bottomLeading,
                startRadius: 5,
                endRadius: 440
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text("原生 SwiftUI · 合成数据", "NATIVE SWIFTUI · SYNTHETIC DATA"))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.34), in: Capsule())
                    .padding(.leading, 6)
                content
            }
            .padding(12)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.visualTokens, tokens)
        .environment(\.colorScheme, scheme)
        .environment(\.workspacePreviewOpaqueSurface, false)
        .environment(\.locale, language.locale)
        .environment(\.widgetLanguage, language)
        .tint(tokens.accent.primary.color)
    }
}
