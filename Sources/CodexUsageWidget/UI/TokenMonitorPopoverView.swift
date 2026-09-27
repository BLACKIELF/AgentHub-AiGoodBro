import AppKit
import SwiftUI

/// Compact native menu-bar surface. All numbers come from the shared snapshot;
/// official provider status and Hub health remain separate evidence.
struct TokenMonitorPopoverView: View {
    let snapshot: TokenMonitorDashboardSnapshot
    let serviceStatus: TokenMonitorServiceStatusPresentation
    let hub: TokenMonitorHubPresentation
    let language: WidgetLanguage
    let onRefresh: () -> Void
    let onRefreshStatus: () -> Void
    let onRefreshHub: () -> Void
    let onOpenAccounts: () -> Void
    let onOpenRunningTasks: () -> Void
    let onOpenSettings: () -> Void
    let onOpenWorkbench: () -> Void
    let onTogglePinned: (() -> Void)?
    let onCollapse: (() -> Void)?
    let onClose: (() -> Void)?
    let isRefreshing: Bool

    @State private var route: TokenMonitorViewRoute
    @State private var period: TokenMonitorPeriod = .total
    @State private var metric: TokenMonitorMetric = .tokens

    init(
        snapshot: TokenMonitorDashboardSnapshot,
        serviceStatus: TokenMonitorServiceStatusPresentation = .unavailable,
        hub: TokenMonitorHubPresentation = .unavailable,
        language: WidgetLanguage,
        initialRoute: TokenMonitorViewRoute = .home,
        onRefresh: @escaping () -> Void = {},
        onRefreshStatus: @escaping () -> Void = {},
        onRefreshHub: @escaping () -> Void = {},
        onOpenAccounts: @escaping () -> Void = {},
        onOpenRunningTasks: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onOpenWorkbench: @escaping () -> Void = {},
        onTogglePinned: (() -> Void)? = nil,
        onCollapse: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        isRefreshing: Bool = false
    ) {
        self.snapshot = snapshot
        self.serviceStatus = serviceStatus
        self.hub = hub
        self.language = language
        self._route = State(initialValue: initialRoute)
        self.onRefresh = onRefresh
        self.onRefreshStatus = onRefreshStatus
        self.onRefreshHub = onRefreshHub
        self.onOpenAccounts = onOpenAccounts
        self.onOpenRunningTasks = onOpenRunningTasks
        self.onOpenSettings = onOpenSettings
        self.onOpenWorkbench = onOpenWorkbench
        self.onTogglePinned = onTogglePinned
        self.onCollapse = onCollapse
        self.onClose = onClose
        self.isRefreshing = isRefreshing
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch route {
                case .home: home
                case .status: status
                case .totalsByTool: totals(byModel: false)
                case .totalsByModel: totals(byModel: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceGlassSurface(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("token-monitor-popover")
        .onChange(of: route) { newRoute in
            if newRoute == .status { onRefreshStatus() }
        }
        .onAppear {
            if route == .status { onRefreshStatus() }
            if hub.isEnabled { onRefreshHub() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AHBrandSymbol(size: 34)
                Circle().fill(snapshot.isHubSource ? FixedVisualPalette.statusSuccess : Color.accentColor)
                    .frame(width: 7, height: 7).overlay(Circle().strokeBorder(.background, lineWidth: 1))
                    .offset(x: 1, y: 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(AHBrandIdentity.displayName).font(.system(size: 13, weight: .semibold))
                Text(snapshot.isHubSource ? language.text("所有设备", "All devices") : language.text("本机统计", "This device"))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            shortcutButton("person.2", help: language.text("账号", "Accounts"), action: onOpenAccounts)
            shortcutButton("checklist", help: language.text("运行任务", "Running tasks"), action: onOpenRunningTasks)
            shortcutButton("rectangle.stack", help: language.text("打开工作台", "Open workspace"), action: onOpenWorkbench)
            Button(action: {
                if hub.isEnabled { onRefreshHub() } else { onRefresh() }
            }) {
                Group {
                    if isRefreshing || hub.isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).disabled(isRefreshing || hub.isLoading)
            .help(language.text("刷新用量", "Refresh usage"))
            .accessibilityLabel(language.text("刷新用量", "Refresh usage"))
            if let onTogglePinned {
                Button(action: onTogglePinned) { Image(systemName: "pin").frame(width: 24, height: 28) }
                    .buttonStyle(.plain).help(language.text("置顶", "Pin"))
                    .accessibilityLabel(language.text("置顶", "Pin"))
            }
            if let onCollapse {
                Button(action: onCollapse) { Image(systemName: "chevron.down").frame(width: 24, height: 28) }
                    .buttonStyle(.plain).help(language.text("收起", "Collapse"))
                    .accessibilityLabel(language.text("收起", "Collapse"))
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 24, height: 28) }
                    .buttonStyle(.plain).help(language.text("关闭", "Close"))
                    .accessibilityLabel(language.text("关闭", "Close"))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(FixedVisualPalette.surfaceHairline).frame(height: 0.5) }
    }

    private func shortcutButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 25, height: 28) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }

    private var home: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(language.text("总 Token", "Total tokens").uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Picker(language.text("时间范围", "Period"), selection: $period) {
                        ForEach(TokenMonitorPeriod.allCases) { item in Text(item.title(language)).tag(item) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(TokenMonitorFormatting.count(snapshot.tokenCount(for: period), language: language))
                        .font(.system(size: 34, weight: .medium))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    Text(TokenMonitorFormatting.cost(snapshot.value(for: period, metric: .cost), language: language))
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Text(
                    language.text(
                        "成本按当前价格配置估算，不代表实际账单。",
                        "Costs use the current pricing configuration and are not an actual bill."
                    )
                )
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

                if hub.isEnabled {
                    deviceRows
                } else {
                    toolRows
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(language.text("活跃度", "Activity")).font(.system(size: 11, weight: .bold, design: .monospaced))
                    Spacer()
                    Text(
                        snapshot.summary.activeDays.map { count in
                            let value = TokenMonitorFormatting.count(count, language: language)
                            return language.text("\(value) 天活跃", "\(value) active days")
                        } ?? "—"
                    )
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                TokenMonitorHeatmap(days: snapshot.heatmapDays(count: 180), metric: metric, timezone: snapshot.timezone, language: language)
                    .frame(height: 116)
                HStack {
                    Text(language.text("趋势", "Trend")).font(.system(size: 11, weight: .bold, design: .monospaced))
                    Spacer()
                    Picker(language.text("指标", "Metric"), selection: $metric) {
                        ForEach(TokenMonitorMetric.allCases) { item in
                            Text(item.compactTitle(language)).accessibilityLabel(item.title(language)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 118)
                }
                TokenMonitorTrendPlot(days: snapshot.trendDays(range: .month), metric: metric, language: language)
                    .frame(height: 70)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        }
    }

    private var deviceRows: some View {
        VStack(spacing: 5) {
            if hub.devices.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.secondary)
                    Text(hub.localizedError(language) ?? language.text("等待设备快照", "Waiting for device snapshot"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hub.isLoading { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 10)).padding(.vertical, 5)
            } else {
                ForEach(hub.devices.prefix(3)) { device in
                    HStack(spacing: 7) {
                        Image(systemName: device.isCurrent ? "laptopcomputer" : "desktopcomputer")
                            .foregroundStyle(device.isCurrent ? Color.accentColor : .secondary).frame(width: 15)
                        Text(device.name + (device.isCurrent ? language.text(" · 本机", " · This Mac") : ""))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(TokenMonitorFormatting.count(device.tokenCount(for: period), language: language))
                            .monospacedDigit().fontWeight(.semibold)
                        if device.isStale {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(FixedVisualPalette.statusWarning)
                                .help(language.text("设备数据可能已过期", "Device data may be stale"))
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.012), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var toolRows: some View {
        let rows = snapshot.breakdown(byModel: false, metric: .tokens, period: period).prefix(3)
        return VStack(spacing: 5) {
            if rows.isEmpty {
                HStack {
                    Text(language.text("工具用量", "Tool usage"))
                    Spacer()
                    Text(language.text("未采集", "Not collected")).foregroundStyle(.secondary)
                }
                .font(.system(size: 10)).padding(.vertical, 5)
            } else {
                ForEach(Array(rows)) { row in
                    HStack(spacing: 8) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        Text(row.id).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(TokenMonitorFormatting.count(row.value, compact: true, language: language))
                            .monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.012), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var status: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("官方服务状态", "Official service status")).font(.headline)
                        Text(statusTimestamp).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onRefreshStatus) {
                        if serviceStatus.isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(serviceStatus.isLoading)
                    .help(language.text("刷新官方状态", "Refresh official status"))
                    .accessibilityLabel(language.text("刷新官方状态", "Refresh official status"))
                }
                if let error = serviceStatus.localizedError(language) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(FixedVisualPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(displayedProviders) { provider in serviceRow(provider) }
            }
            .padding(15)
        }
    }

    private var displayedProviders: [TokenMonitorServiceProviderPresentation] {
        if !serviceStatus.providers.isEmpty { return serviceStatus.providers }
        return [
            .init(
                id: "claude", name: "Claude", condition: .unknown, description: nil, pageURL: URL(string: "https://status.claude.com"), checkedAt: nil, updatedAt: nil,
                componentIssues: [], incidentTitle: nil, incidentCount: 0, maintenanceCount: 0, error: nil, isStale: false),
            .init(
                id: "openai", name: "OpenAI", condition: .unknown, description: nil, pageURL: URL(string: "https://status.openai.com"), checkedAt: nil, updatedAt: nil,
                componentIssues: [], incidentTitle: nil, incidentCount: 0, maintenanceCount: 0, error: nil, isStale: false),
        ]
    }

    private var statusTimestamp: String {
        if serviceStatus.isLoading { return language.text("正在查询官方状态…", "Checking official status…") }
        guard let checkedAt = serviceStatus.checkedAt else { return language.text("尚未查询", "Not checked yet") }
        return language.text("检查于 \(TokenMonitorFormatting.time(checkedAt, language: language))", "Checked \(TokenMonitorFormatting.time(checkedAt, language: language))")
    }

    private func serviceRow(_ provider: TokenMonitorServiceProviderPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: provider.id.lowercased() == "claude" ? "sparkle" : "circle.hexagongrid.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(statusColor(provider.condition))
                Text(provider.name).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(conditionTitle(provider.condition))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(statusColor(provider.condition).opacity(0.13), in: Capsule())
                    .foregroundStyle(statusColor(provider.condition))
            }
            Text(
                provider.description.flatMap { $0.isEmpty ? nil : $0 }
                    ?? provider.localizedError(language)
                    ?? language.text("状态未知", "Status unknown")
            )
            .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if !provider.componentIssues.isEmpty {
                Text(language.text("受影响：", "Affected: ") + provider.localizedComponentIssues(language).prefix(3).joined(separator: " · "))
                    .font(.caption).foregroundStyle(FixedVisualPalette.statusWarning).lineLimit(2)
            } else if let incident = provider.incidentTitle {
                Text(incident).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(provider.isStale ? language.text("显示上次检查结果", "Showing last checked result") : language.text("没有已确认的活动故障", "No confirmed active incidents"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(provider.checkedAt.map { TokenMonitorFormatting.time($0, language: language) } ?? language.text("未检查", "Not checked"))
                Spacer()
                if provider.incidentCount > 0 { Text(language.text("事件 \(provider.incidentCount)", "\(provider.incidentCount) incidents")) }
                if provider.maintenanceCount > 0 { Text(language.text("维护 \(provider.maintenanceCount)", "\(provider.maintenanceCount) maintenance")) }
                if let url = provider.pageURL { Link(language.text("官方", "Official"), destination: url) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(13).sectionBackground()
    }

    private func totals(byModel: Bool) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(language.text("总计", "Totals")).font(.headline)
                    Spacer()
                    Picker(language.text("维度", "Dimension"), selection: $route) {
                        Text(language.text("工具", "Tool")).tag(TokenMonitorViewRoute.totalsByTool)
                        Text(language.text("模型", "Model")).tag(TokenMonitorViewRoute.totalsByModel)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 128)
                }
                Picker(language.text("时间范围", "Period"), selection: $period) {
                    ForEach(TokenMonitorPeriod.allCases) { item in Text(item.title(language)).tag(item) }
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(formattedValue(snapshot.value(for: period, metric: metric)))
                        .font(.system(size: 30, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    Spacer(minLength: 2)
                    Picker(language.text("指标", "Metric"), selection: $metric) {
                        ForEach(TokenMonitorMetric.allCases) { item in
                            Text(item.compactTitle(language)).accessibilityLabel(item.title(language)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                }
                if metric == .cost {
                    Text(
                        language.text(
                            "成本按当前价格配置估算，不代表实际账单。",
                            "Costs use the current pricing configuration and are not an actual bill."
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                TokenMonitorBreakdownCard(
                    title: byModel ? language.text("按模型", "By model") : language.text("按工具", "By tool"),
                    rows: snapshot.breakdown(byModel: byModel, metric: metric, period: period),
                    metric: metric, denominator: snapshot.value(for: period, metric: metric), language: language
                )
                if hub.isEnabled && hub.devices.count > 0 {
                    deviceRows
                }
            }
            .padding(15)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TokenMonitorViewRoute.allCases) { destination in
                    Button {
                        route = destination
                    } label: {
                        Label(destination.title(language), systemImage: routeSymbol(destination))
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: routeSymbol(route))
                    Text(route.shortTitle(language))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11).frame(height: 34)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(language.text("切换用量视图", "Choose usage view"))
            Spacer()
            if let status = snapshot.localizedStatusText(language) {
                Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").frame(width: 36, height: 34)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain).help(language.text("设置", "Settings"))
            .accessibilityLabel(language.text("设置", "Settings"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(FixedVisualPalette.surfaceHairline).frame(height: 0.5) }
    }

    private var totalsTitle: String { route == .totalsByModel ? language.text("按模型", "By model") : language.text("按工具", "By tool") }

    private func formattedValue(_ value: Double?) -> String {
        if metric == .tokens {
            return TokenMonitorFormatting.count(snapshot.tokenCount(for: period), language: language)
        }
        return formatted(value, metric: metric)
    }

    private func formatted(_ value: Double?, metric: TokenMonitorMetric) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if metric == .cost { return TokenMonitorFormatting.cost(value, language: language) }
        return TokenMonitorFormatting.count(value, language: language)
    }

    private func routeSymbol(_ route: TokenMonitorViewRoute) -> String {
        switch route {
        case .home: return "house"
        case .status: return "heart.text.square"
        case .totalsByTool: return "hammer"
        case .totalsByModel: return "cpu"
        }
    }

    private func conditionTitle(_ condition: TokenMonitorServiceProviderPresentation.Condition) -> String {
        switch condition {
        case .operational: return language.text("正常", "Operational")
        case .degraded: return language.text("降级", "Degraded")
        case .outage: return language.text("故障", "Outage")
        case .unknown: return language.text("未知", "Unknown")
        }
    }

    private func statusColor(_ condition: TokenMonitorServiceProviderPresentation.Condition) -> Color {
        switch condition {
        case .operational: return FixedVisualPalette.statusSuccess
        case .degraded: return FixedVisualPalette.statusWarning
        case .outage: return FixedVisualPalette.statusDanger
        case .unknown: return .secondary
        }
    }
}

private extension TokenMonitorViewRoute {
    func shortTitle(_ language: WidgetLanguage) -> String {
        switch self {
        case .home: return language.text("首页", "Home")
        case .status: return language.text("状态", "Status")
        case .totalsByTool: return language.text("工具汇总", "Totals by Tool")
        case .totalsByModel: return language.text("模型汇总", "Totals by Model")
        }
    }
}
