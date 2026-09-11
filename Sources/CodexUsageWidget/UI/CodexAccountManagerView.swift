import AppKit
import Combine
import SwiftUI

struct CodexAccountManagerView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    let paletteCatalog: PaletteCatalog
    private var language: WidgetLanguage { settings.language }
    var screenshotRequests: AnyPublisher<NSWindow, Never> = Empty().eraseToAnyPublisher()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditingProfiles = false
    @State private var profileReorder: ProfileReorderSession?
    @State private var profileFrames: [String: CGRect] = [:]
    @State private var isAddingCustomTokenSource = false
    @State private var customSourceNameDraft = ""
    @State private var customSourceTokensDraft = ""
    @State private var isAgentBreakdownExpanded = true
    @State private var isAutomationCenterPresented = false
    @State private var isSetupGuidePresented = false
    @State private var openAutomationAfterGuide = false
    @State private var isAccountDetailsExpanded = true
    @State private var isUsageDetailsExpanded = true
    @State private var isSavingScreenshot = false
    @State private var screenshotFeedback: String?
    @StateObject private var hubTaskStatusModel = HubAccountTaskStatusModel()
    @StateObject private var localCLIAccounts: LocalCLIAccountStore
    @State private var selectedLocalCLI: LocalCLIKind?
    @State private var showingHome = true
    @State private var professionalSection: ProfessionalWorkspaceSection = .overview

    private enum ProfessionalWorkspaceSection: String, CaseIterable, Identifiable {
        case overview
        case accounts
        case tasks
        case usage
        case settings

        var id: String { rawValue }

        func title(_ language: WidgetLanguage) -> String {
            switch self {
            case .overview: return language.text("总览", "Overview")
            case .accounts: return language.text("账号", "Accounts")
            case .tasks: return language.text("任务", "Tasks")
            case .usage: return language.text("用量", "Usage")
            case .settings: return language.text("设置", "Settings")
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .accounts: return "person.2"
            case .tasks: return "checklist"
            case .usage: return "chart.bar"
            case .settings: return "gearshape"
            }
        }
    }

    static let defaultWidth: CGFloat = 980
    static let minWidth: CGFloat = 820
    static let maxWidth: CGFloat = 1280
    static let defaultHeight: CGFloat = 700
    static let minHeight: CGFloat = 600
    static let windowCornerRadius: CGFloat = 28

    init(
        store: UsageStore, settings: AppSettings, paletteCatalog: PaletteCatalog,
        screenshotRequests: AnyPublisher<NSWindow, Never> = Empty().eraseToAnyPublisher(),
        localCLIAccounts: LocalCLIAccountStore? = nil,
        previewOpenCodexWorkspace: Bool = false
    ) {
        self.store = store
        self.settings = settings
        self.paletteCatalog = paletteCatalog
        self.screenshotRequests = screenshotRequests
        _localCLIAccounts = StateObject(wrappedValue: localCLIAccounts ?? LocalCLIAccountStore())
        _showingHome = State(initialValue: !previewOpenCodexWorkspace)
    }

    private var effectiveColorScheme: ColorScheme {
        settings.themeMode.preferredColorScheme ?? colorScheme
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            workspaceContent
        }
        .background(
            FixedVisualPalette.windowScrim(
                effectiveColorScheme,
                reduceTransparency: reduceTransparency
            )
            .ignoresSafeArea()
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            operationStatusBar
        }
        .environment(
            \.visualTokens,
            paletteCatalog.resolve(
                id: settings.paletteID,
                appearance: effectiveColorScheme == .dark ? .dark : .light
            )
        )
        .preferredColorScheme(settings.themeMode.preferredColorScheme)
        .onReceive(screenshotRequests) { saveLongScreenshot(for: $0) }
        .onAppear {
            if !store.isPreview {
                localCLIAccounts.discover()
                refreshMissingLocalCLIQuotas()
                hubTaskStatusModel.startPolling()
                if settings.setupProgress.shouldPresentAutomatically { isSetupGuidePresented = true }
            }
        }
        .onDisappear {
            hubTaskStatusModel.stopPolling()
            profileReorder = nil
        }
        .onChange(of: presentedProfiles.map(\.id)) { _ in profileReorder = nil }
        .onChange(of: displayedAccountLayout) { _ in profileReorder = nil }
        .onChange(of: usesHomeAccountCards) { compact in
            if compact { profileReorder = nil }
        }
        .sheet(isPresented: $isAutomationCenterPresented) {
            AccountAutomationCenterView(store: store)
                .environment(\.widgetLanguage, language)
                .environment(\.locale, language.locale)
        }
        .sheet(
            isPresented: $isSetupGuidePresented,
            onDismiss: {
                settings.setupProgress.dismissed = true
                if openAutomationAfterGuide {
                    openAutomationAfterGuide = false
                    isAutomationCenterPresented = true
                }
            }
        ) {
            NextSetupGuideView(store: store, settings: settings) {
                openAutomationAfterGuide = true
                isSetupGuidePresented = false
            }
        }
        .alert(
            store.forcedAccountSwitchProfileID == nil ? language.text("未切换账号", "Account not switched") : language.text("强制切换账号？", "Force account switch?"),
            isPresented: Binding(
                get: { store.accountSwitchAlertMessage != nil },
                set: { if !$0 { store.dismissAccountSwitchAlert() } }
            )
        ) {
            if store.forcedAccountSwitchProfileID != nil {
                Button(language.text("强制切换", "Force switch"), role: .destructive) {
                    store.confirmForcedAccountSwitch()
                }
            }
            Button(store.forcedAccountSwitchProfileID == nil ? language.text("知道了", "OK") : language.text("取消", "Cancel"), role: .cancel) {
                store.dismissAccountSwitchAlert()
            }
        } message: {
            Text(store.accountSwitchAlertMessage ?? "")
        }
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
    }

    private var workspaceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            cliSelector
            if showingHome {
                homeOverview
            } else if let selectedLocalCLI {
                LocalCLIWorkspaceView(model: localCLIAccounts, settings: settings, kind: selectedLocalCLI, language: language)
            } else {
                codexWorkspaceContent
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var homeOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            homeHeader
            AutomationMaintenanceNotice(features: store.pausedAutomationFeatures, language: language)
            if settings.workspaceDisplayMode == .professional {
                professionalHomeSections
            } else {
                simpleHomeContent
            }
        }
    }

    private var homeHeader: some View {
        ViewThatFits(in: .horizontal) {
            homeHeaderRow
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    homeWorkspaceTitle
                    Spacer(minLength: 8)
                    homeBrandMark
                }
                HStack(spacing: 8) {
                    homeDisplayModePicker
                    homeGettingStartedButton
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var homeHeaderRow: some View {
        HStack(alignment: .center, spacing: 10) {
            homeWorkspaceTitle
            homeDisplayModePicker
            homeGettingStartedButton
            Spacer(minLength: 8)
            homeBrandMark
        }
    }

    private var homeWorkspaceTitle: some View {
        Text("AgentHub")
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private var homeBrandMark: some View {
        HStack(spacing: 6) {
            AHBrandSymbol(size: 20)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("AiGoodBro")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AiGoodBro")
        .help("AiGoodBro")
    }

    private var homeDisplayModePicker: some View {
        Picker(language.text("工作台显示", "Workspace display"), selection: $settings.workspaceDisplayMode) {
            ForEach(WorkspaceDisplayMode.allCases, id: \.self) { mode in
                Text(mode.title(language)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: 220)
        .accessibilityLabel(language.text("工作台显示", "Workspace display"))
        .help(
            language.text(
                "专业版使用总览、账号、任务、用量、设置五项工作台；极简版三种预设都保留紧凑总览和全部平台账号。",
                "Professional uses five stable workspace sections. Every Simple preset keeps the compact overview and all provider accounts."
            )
        )
    }

    private var homeGettingStartedButton: some View {
        Button(language.text("使用引导", "Getting started")) {
            isSetupGuidePresented = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(language.text("使用引导", "Getting started"))
    }

    private var professionalHomeSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            professionalNavigation
            Group {
                switch professionalSection {
                case .overview:
                    professionalOverviewContent
                case .accounts:
                    homeUnifiedAccounts
                case .tasks:
                    professionalTaskContent
                case .usage:
                    professionalUsageContent
                case .settings:
                    professionalSettingsContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var professionalNavigation: some View {
        HStack(spacing: 4) {
            ForEach(ProfessionalWorkspaceSection.allCases) { section in
                Button {
                    professionalSection = section
                } label: {
                    Label(section.title(language), systemImage: section.symbol)
                        .font(.system(size: 11.5, weight: professionalSection == section ? .semibold : .medium))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(professionalSection == section ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(professionalSection == section ? Color.accentColor.opacity(0.11) : Color.clear)
                )
                .accessibilityAddTraits(professionalSection == section ? .isSelected : [])
                .accessibilityIdentifier("next.workspace.tab.\(section.rawValue)")
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("专业工作台导航", "Professional workspace navigation"))
    }

    private var professionalOverviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            homeTokenTotalsCard
            resetUpdatesBanner
            compactHomeMonitorCard
            professionalTaskSummary
            homeOverviewRows
        }
    }

    private var resetUpdatesBanner: some View {
        ResetUpdatesBanner(
            language: language,
            fiveHourResetsAt: overviewQuota.fiveHour?.resetsAt,
            sevenDayResetsAt: overviewQuota.sevenDay?.resetsAt,
            announcement: store.publicResetAnnouncements.latest,
            checkedAt: store.publicResetAnnouncements.checkedAt,
            accountsWithResetCards: accountsWithAvailableResetCards,
            onOpenAnnouncements: { isAutomationCenterPresented = true },
            onOpenAccounts: { openAccountsFromResetBanner() }
        )
    }

    private var accountsWithAvailableResetCards: Int {
        store.profiles.filter { ($0.lastSnapshot?.availableResetCredits ?? 0) > 0 }.count
    }

    private func openAccountsFromResetBanner() {
        showingHome = true
        professionalSection = .accounts
        selectedLocalCLI = nil
    }

    private var professionalTaskOverview: TaskOverviewPresentation {
        TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: store.runtimeSnapshots,
            codexLiveTasks: store.codexLiveTasks,
            now: Date()
        )
    }

    private var professionalTaskSummary: some View {
        let tasks = professionalTaskOverview
        return HStack(spacing: 10) {
            professionalMetric(
                value: tasks.runningCount,
                title: language.text("运行中", "Running"),
                symbol: "play.circle.fill",
                tint: .blue
            )
            professionalMetric(
                value: tasks.needsAttentionCount,
                title: language.text("待处理", "Needs action"),
                symbol: "exclamationmark.circle.fill",
                tint: .orange
            )
            professionalMetric(
                value: tasks.recentlyEndedCount,
                title: language.text("最近结束", "Recently ended"),
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        }
    }

    private func professionalMetric(value: Int, title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 11)
        .accessibilityElement(children: .combine)
    }

    private var professionalTaskContent: some View {
        let tasks = professionalTaskOverview
        return VStack(alignment: .leading, spacing: 10) {
            professionalTaskSummary
            HStack(spacing: 8) {
                Circle()
                    .fill(taskDataStateColor(tasks.dataState))
                    .frame(width: 7, height: 7)
                Text(taskDataStateText(tasks.dataState))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(language.text("只显示已有真实任务证据", "Existing task evidence only"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            if tasks.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(language.text("暂无可显示的任务记录", "No task records to show"))
                        .font(.callout.weight(.medium))
                    Text(language.text("Token 增长不会被当作运行中。", "Token growth is not treated as a running task."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .sectionBackground()
            } else {
                VStack(spacing: 6) {
                    ForEach(tasks.items) { item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(taskStateColor(item.state))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                HStack(spacing: 5) {
                                    Text(taskStateText(item.state))
                                    Text("·")
                                    Text(item.runtimeScope.displayName)
                                    if let updatedAt = item.updatedAt {
                                        Text("·")
                                        Text(updatedAt, style: .relative)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(10)
                .sectionBackground()
            }

            Text(language.text("账号的模型、Free 信息、调度与终端操作仍在“账号”页和各平台详情中。", "Models, Free details, dispatch and CLI actions remain available from Accounts and provider details."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var professionalUsageContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            quotaOverview
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    tokenTotalPanel.frame(width: 300)
                    agentBreakdownPanel
                }
                VStack(alignment: .leading, spacing: 10) {
                    tokenTotalPanel
                    agentBreakdownPanel
                }
            }
        }
    }

    private var professionalSettingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("工作台设置", "Workspace settings"))
                        .font(.headline)
                    Text(
                        language.text(
                            "这里保留常用布局入口；完整外观、菜单栏、自动化与高级设置沿用原设置界面。",
                            "Common layout controls live here. Appearance, menu bar, automation and advanced options remain in the existing Settings panel."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    _ = NSApp.sendAction(NSSelectorFromString("openSettingsFromMenu"), to: NSApp.delegate, from: nil)
                } label: {
                    Label(language.text("打开完整设置", "Open full settings"), systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .sectionBackground()

            VStack(alignment: .leading, spacing: 10) {
                Text(language.text("极简自定义模块", "Simple custom modules"))
                    .font(.subheadline.weight(.semibold))
                simpleCustomModuleToggles
                Button(language.text("恢复默认模块", "Restore default modules")) {
                    settings.restoreSimpleCustomModules()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
            .sectionBackground()
            automationPanel
            safetyFooter
        }
    }

    private func taskDataStateText(_ state: TaskOverviewDataState) -> String {
        switch state {
        case .available: return language.text("任务状态已连接", "Task status connected")
        case .stale: return language.text("任务状态可能过期", "Task status may be stale")
        case .disconnected: return language.text("任务状态未连接", "Task status disconnected")
        case .noData: return language.text("暂无任务状态数据", "No task status data")
        }
    }

    private func taskDataStateColor(_ state: TaskOverviewDataState) -> Color {
        switch state {
        case .available: return FixedVisualPalette.statusSuccess
        case .stale: return FixedVisualPalette.statusWarning
        case .disconnected, .noData: return .secondary
        }
    }

    private func taskStateText(_ state: TaskOverviewItemState) -> String {
        TaskStatusCopy.label(state, language)
    }

    private func taskStateColor(_ state: TaskOverviewItemState) -> Color {
        TaskStatusCopy.color(state)
    }

    private var simpleHomeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(language.text("极简版内容", "Simple view"), selection: $settings.simpleWorkspacePreset) {
                ForEach(SimpleWorkspacePreset.allCases, id: \.self) { preset in
                    Text(preset.title(language)).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 420)
            .accessibilityLabel(language.text("极简版内容", "Simple view"))
            Text(
                language.text(
                    "三种预设都显示顶部总览和全部平台账号。总览、卡片、自定义只改变密度和额外模块；各平台页仍保留完整操作。",
                    "Every preset shows the compact overview and all provider accounts. Overview, cards and custom only change density and extra modules. Provider tabs keep full controls."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            homeTokenTotalsCard
            resetUpdatesBanner
            compactHomeMonitorCard
            if settings.simpleWorkspacePreset == .overview {
                compactHomeMetricTiles
            }
            if settings.simpleWorkspacePreset == .custom {
                homeCustomModules
            }
            homeUnifiedAccounts
        }
    }

    private var homeTokenTotalsCard: some View {
        TokenTotalsHeader(
            layout: .compact,
            language: language,
            combinedTokensTotal: combinedTokensTotal,
            combinedEquivalentCostUSD: combinedEquivalentCostUSD,
            officialAccountsLifetimeTokens: officialAccountsTotal,
            localAllAgentsLifetimeTokens: localAllAgentsTokens
        )
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("总 Token 消耗量", "Total Token Consumption"))
    }

    private var compactHomeMonitorCard: some View {
        let summary = crossProviderSummary
        let monitored = summary.monitored
        let tasks = professionalTaskOverview
        return VStack(alignment: .leading, spacing: 8) {
            if let monitored {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(language.text("当前监控", "Monitored"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(selectedAccountName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Circle()
                        .fill(monitored.connected ? FixedVisualPalette.statusSuccess : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(
                        monitored.connected
                            ? language.text("官方额度已连接", "Usage limits connected")
                            : language.text("等待官方额度", "Waiting for usage limits")
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    ForEach(Array(monitored.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                        compactQuotaStrip(label: window.label, remaining: window.remainingPercent)
                    }
                }
            }
            HStack(spacing: 12) {
                compactCountChip(
                    title: language.text("账号总数", "Accounts"),
                    value: "\(summary.accountCount)"
                )
                compactCountChip(
                    title: language.text("运行中", "Running"),
                    value: "\(tasks.runningCount)"
                )
                compactCountChip(
                    title: language.text("待处理", "Needs action"),
                    value: "\(tasks.needsAttentionCount)"
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("当前监控与任务计数", "Monitored account and task counts"))
    }

    private var compactHomeMetricTiles: some View {
        HStack(spacing: 10) {
            compactMetricTile(
                title: language.text("今日消耗", "Today"),
                value: language.tokens(
                    store.snapshot.local?.allAgentsTodayTokens
                        ?? store.snapshot.local?.todayTokens
                )
            )
            compactMetricTile(
                title: language.text("会员有效期", "Membership"),
                value: homeMembershipSummary
            )
        }
    }

    private func compactCountChip(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04), in: Capsule())
    }

    private func compactMetricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(FixedVisualPalette.statusSuccessForeground(effectiveColorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .sectionBackground()
    }

    private func compactQuotaStrip(label: String, remaining: Double?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            QuotaProgressTrack(percent: remaining)
                .frame(maxWidth: .infinity)
            Text(QuotaAvailabilityPresentation.percentText(remaining))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(minWidth: 36, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var homeMembershipSummary: String {
        guard let profile = presentation.quotaProfile,
            let activeUntil = profile.officialProfile?.subscriptionActiveUntil
        else { return "—" }
        let days =
            Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: Date()),
                to: Calendar.current.startOfDay(for: activeUntil)
            ).day ?? 0
        if days >= 0 {
            return language.text("还有 \(days) 天", "\(days) days left")
        }
        return language.text("日期待刷新", "Date pending refresh")
    }

    private var crossProviderSummary: CrossProviderQuotaSummary {
        var accounts: [CrossProviderQuotaAccount] = []
        for profile in presentedProfiles {
            let linked = linkedManagedProfile(for: profile)
            let health = AccountSnapshotHealth.classify(
                snapshotAt: profile.lastSnapshot?.fetchedAt,
                lastFailureAt: profile.lastQuotaReadFailureAt
            )
            let connected = linked == nil && profile.lastSnapshot != nil && profile.lastQuotaReadFailureAt == nil
            let available = linked == nil && profile.lastQuotaReadFailureAt == nil && profile.lastSnapshot != nil
            let status: String?
            if linked != nil {
                status = language.text("待独立登录", "Sign-in needed")
            } else if health == .failed {
                status = language.text("读取失败", "Read failed")
            } else if !connected {
                status = language.text("等待官方额度", "Waiting for usage limits")
            } else {
                status = nil
            }
            accounts.append(
                CrossProviderQuotaAccount(
                    providerID: "codex",
                    providerName: "Codex",
                    accountID: profile.id,
                    isMonitored: profile.id == store.selectedMonitorProfileID,
                    quotaConnected: connected,
                    isAvailable: available,
                    isStale: health == .stale || health == .failed,
                    windows: [
                        CrossProviderQuotaWindow(
                            label: language.text("5 小时", "5h"),
                            remainingPercent: fiveHourRemaining(for: profile)
                        ),
                        CrossProviderQuotaWindow(
                            label: language.text("7 天", "7d"),
                            remainingPercent: sevenDayRemaining(for: profile)
                        ),
                    ],
                    statusLabel: status
                )
            )
        }
        for kind in homeOrderedKinds {
            for profile in localCLIAccounts.profiles(for: kind) {
                let result = localCLIAccounts.quotas[profile.id]
                let stale = localCLIAccounts.stale.contains(profile.id)
                let windows = (result?.windows ?? []).prefix(2).map { window in
                    CrossProviderQuotaWindow(label: window.label, remainingPercent: 100 - window.usedPercent)
                }
                let connected = result != nil && (!windows.isEmpty || result?.balance != nil) && result?.state == .available
                let available = result?.state != .needsLogin
                accounts.append(
                    CrossProviderQuotaAccount(
                        providerID: kind.rawValue,
                        providerName: kind.displayName,
                        accountID: profile.id,
                        isMonitored: false,
                        quotaConnected: connected,
                        isAvailable: available,
                        isStale: stale,
                        windows: windows,
                        statusLabel: localAccountStatus(kind: kind, profile: profile)
                    )
                )
            }
        }
        let quota = overviewQuota
        return CrossProviderQuotaSummary.build(
            accounts: accounts,
            monitored: CrossProviderMonitoredQuota(
                providerName: "Codex",
                connected: quota.readSucceeded,
                windows: [
                    CrossProviderQuotaWindow(
                        label: language.text("5 小时", "5h"),
                        remainingPercent: quota.fiveHour?.remainingPercent
                    ),
                    CrossProviderQuotaWindow(
                        label: language.text("7 天", "7d"),
                        remainingPercent: quota.sevenDay?.remainingPercent
                    ),
                ]
            )
        )
    }

    private func localAccountStatus(kind: LocalCLIKind, profile: LocalCLIProfile) -> String {
        localProviderOverview(kind).status.isEmpty
            ? localProviderOverview(kind).quota
            : (localCLIAccounts.profiles(for: kind).count == 1
                ? (localProviderOverview(kind).quota == "—"
                    ? localProviderOverview(kind).status
                    : localProviderOverview(kind).quota)
                : language.text("额度按账号显示", "Limits shown per account"))
    }

    private var homeOverviewRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeOverviewProviderRow(
                name: "Codex",
                accountCountText: language.text("\(presentation.accountCount) 个账号", "\(presentation.accountCount) accounts"),
                quotaText: codexOverviewQuotaText,
                statusText: codexOverviewStatusText,
                language: language
            ) {
                openCodexTab()
            } icon: {
                Image(systemName: "terminal")
            }
            ForEach(homeOrderedKinds) { kind in
                homeLocalOverviewRow(kind)
            }
        }
    }

    private enum HomeAccountEntry: Identifiable {
        case codex(CodexProfile)
        case local(LocalCLIProfile)
        var id: String {
            switch self {
            case .codex(let profile): return ResetCardPresentation.codexKey(profile.id)
            case .local(let profile): return ResetCardPresentation.localKey(kind: profile.kind.rawValue, profileID: profile.id)
            }
        }
    }

    private func codexCardExpiring(_ profile: CodexProfile, now: Date) -> Bool {
        let selected = profile.id == store.selectedMonitorProfileID
        let fetchedAt = selected ? store.snapshot.refreshedAt : profile.lastSnapshot?.fetchedAt
        let readSucceeded = selected ? store.snapshot.quotaReadSucceeded : profile.lastSnapshot?.quotaReadSucceeded == true
        return ResetCardPresentation.codexIsExpiring(
            available: store.availableResetCredits(for: profile),
            expiries: store.resetCreditExpiries(for: profile), fetchedAt: fetchedAt,
            readSucceeded: readSucceeded && profile.lastQuotaReadFailureAt == nil, now: now)
    }

    private func homeAccounts(now: Date) -> [HomeAccountEntry] {
        let entries =
            presentedProfiles.map(HomeAccountEntry.codex)
            + installedLocalCLIKinds.flatMap { kind in
                localCLIAccounts.profiles(for: kind).map(HomeAccountEntry.local)
            }
        let expiring = Set(
            entries.filter { entry in
                switch entry {
                case .codex(let profile): return codexCardExpiring(profile, now: now)
                case .local(let profile):
                    let result = localCLIAccounts.quotas[profile.id]
                    return ResetCardPresentation.isExpiringSoon(
                        result?.resetCards, now: now,
                        evidenceFresh: !localCLIAccounts.stale.contains(profile.id) && ResetCardPresentation.isFresh(result?.fetchedAt, now: now))
                }
            }.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return ResetCardPresentation.prioritizedOrder(entries.map(\.id), expiring: expiring, pinnedAccountID: settings.pinnedAccountKey).compactMap { byID[$0] }
    }

    private var homeUnifiedAccounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(language.text("所有账号", "All accounts"), systemImage: "person.2").font(.headline)
                Spacer()
                Menu(language.text("固定第一位", "Pin first")) {
                    Button(language.text("取消置顶", "Unpin")) { settings.pinnedAccountKey = nil }
                    ForEach(homeAccounts(now: Date())) { entry in
                        switch entry {
                        case .codex(let profile):
                            Button("Codex · " + AccountDisplay.profileName(profile, allProfiles: store.profiles)) { settings.pinnedAccountKey = entry.id }
                        case .local(let profile):
                            Button(profile.kind.displayName + " · " + profile.displayName) { settings.pinnedAccountKey = entry.id }
                        }
                    }
                }
                if !usesHomeAccountCards {
                    Picker(language.text("账号显示方式", "Account layout"), selection: $settings.accountWorkspaceLayout) {
                        Text(language.text("列表", "List")).tag(AccountWorkspaceLayout.rows)
                        Text(language.text("卡片", "Cards")).tag(AccountWorkspaceLayout.cards)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 136)
                }
            }
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                profilesLayout {
                    ForEach(homeAccounts(now: timeline.date)) { entry in
                        switch entry {
                        case .codex(let profile):
                            codexAccountRow(profile, index: presentedProfiles.firstIndex(where: { $0.id == profile.id }) ?? 0, now: timeline.date)
                        case .local(let profile):
                            LocalCLIWorkspaceView(
                                model: localCLIAccounts, settings: settings, kind: profile.kind, language: language,
                                onlyProfileID: profile.id, embeddedLayout: displayedAccountLayout, onOpenDetails: { openLocalCLITab(profile.kind) })
                        }
                    }
                }
            }
        }
    }

    private var homeCustomModules: some View {
        VStack(alignment: .leading, spacing: 8) {
            simpleCustomModuleToggles
            if settings.hasSimpleCustomModules {
                if settings.simpleCustomShowPlatformOverview {
                    homeOverviewRows
                }
                if settings.simpleCustomShowMonitoredQuota {
                    quotaOverview
                }
                if settings.simpleCustomShowCodexAccounts {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(language.text("Codex 账号详情", "Codex account details"))
                                .font(.subheadline.weight(.semibold))
                            Text(
                                language.text(
                                    "模型、Free 信息、调度设置与完整账号操作仍从原平台页进入。",
                                    "Models, Free details, dispatch settings and complete account actions remain in the provider workspace."
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button {
                            openCodexTab()
                        } label: {
                            Label(language.text("打开详情", "Open details"), systemImage: "arrow.right")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .sectionBackground()
                }
                if settings.simpleCustomShowUsageAutomation {
                    tokenTotalPanel
                    agentBreakdownPanel
                    automationPanel
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        language.text(
                            "未选择额外模块；紧凑总览和全部账号仍会显示。",
                            "No extra modules selected. The compact overview and every account remain visible."
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Button(language.text("恢复默认模块", "Restore default modules")) {
                        settings.restoreSimpleCustomModules()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(
                        language.text(
                            "重新显示平台总览、当前监控额度、Codex 高级入口以及用量与自动化。",
                            "Shows platform overview, monitored account limits, the advanced Codex entry, and usage and automation again."
                        ))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionBackground()
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var simpleCustomModuleToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $settings.simpleCustomShowPlatformOverview) {
                Text(language.text("平台总览", "Platform overview"))
            }
            Toggle(isOn: $settings.simpleCustomShowMonitoredQuota) {
                Text(language.text("当前监控额度", "Monitored account limits"))
            }
            Toggle(isOn: $settings.simpleCustomShowCodexAccounts) {
                Text(language.text("Codex 账号高级入口", "Advanced Codex account entry"))
            }
            Toggle(isOn: $settings.simpleCustomShowUsageAutomation) {
                Text(language.text("用量与自动化", "Usage and automation"))
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(.subheadline)
    }

    private var installedLocalCLIKinds: [LocalCLIKind] {
        // Keep linked accounts visible even when their executable is currently
        // missing. Installation affects actions, never whether an account exists.
        LocalCLIKind.allCases.filter {
            localCLIAccounts.installed[$0] != nil || !localCLIAccounts.profiles(for: $0).isEmpty
        }
    }

    /// Home ordering contract: the Codex group stays first, Grok takes the second
    /// group position when installed, and remaining providers keep their relative
    /// order. Group-level only — no account row is pulled across provider groups,
    /// so this is never presented as an account being "globally second".
    private var homeOrderedKinds: [LocalCLIKind] {
        let kinds = installedLocalCLIKinds
        guard kinds.contains(.grok) else { return kinds }
        return [.grok] + kinds.filter { $0 != .grok }
    }

    private var usesHomeAccountCards: Bool {
        showingHome
            && settings.workspaceDisplayMode == .simple
            && settings.simpleWorkspacePreset == .accountCards
    }

    private var displayedAccountLayout: AccountWorkspaceLayout {
        usesHomeAccountCards ? .cards : settings.accountWorkspaceLayout
    }

    private var isEditingDisplayedProfiles: Bool {
        isEditingProfiles && !showingHome
    }

    private var codexOverviewQuotaText: String {
        let quota = overviewQuota
        let fiveHour = QuotaAvailabilityPresentation.percentText(quota.fiveHour?.remainingPercent)
        let sevenDay = QuotaAvailabilityPresentation.percentText(quota.sevenDay?.remainingPercent)
        return language.text("5 小时 \(fiveHour) · 7 天 \(sevenDay)", "5h \(fiveHour) · 7d \(sevenDay)")
    }

    private var codexOverviewStatusText: String {
        var parts: [String] = []
        if presentation.accountCount > 1 {
            parts.append(language.text("当前监控", "Monitored account"))
        }
        parts.append(
            overviewQuota.readSucceeded
                ? language.text("官方额度已连接", "Usage limits connected")
                : language.text("等待官方额度", "Waiting for usage limits")
        )
        let unverified = codexOverviewUnverifiedCount
        let failed = codexOverviewFailedCount
        if unverified > 0 {
            parts.append(language.text("\(unverified) 个待核验", "\(unverified) need verification"))
        }
        if failed > 0 {
            parts.append(language.text("\(failed) 个读取失败", "\(failed) quota read failed"))
        }
        return parts.joined(separator: " · ")
    }

    private var codexOverviewUnverifiedCount: Int {
        presentedProfiles.filter { profile in
            linkedManagedProfile(for: profile) == nil
                && profile.lastSnapshot == nil
                && profile.lastQuotaReadFailureAt == nil
        }.count
    }

    private var codexOverviewFailedCount: Int {
        presentedProfiles.filter { profile in
            linkedManagedProfile(for: profile) == nil && profile.lastQuotaReadFailureAt != nil
        }.count
    }

    private func homeLocalOverviewRow(_ kind: LocalCLIKind) -> some View {
        let summary = localProviderOverview(kind)
        return HomeOverviewProviderRow(
            name: kind.displayName,
            accountCountText: language.text(
                "\(localCLIAccounts.profiles(for: kind).count) 个账号",
                "\(localCLIAccounts.profiles(for: kind).count) accounts"),
            quotaText: summary.quota,
            statusText: summary.status,
            language: language
        ) {
            openLocalCLITab(kind)
        } icon: {
            LocalCLIIcon(kind: kind)
        }
    }

    private func localProviderOverview(_ kind: LocalCLIKind) -> (quota: String, status: String) {
        let profiles = localCLIAccounts.profiles(for: kind)
        if profiles.isEmpty {
            return ("—", language.text("未关联账号", "No linked accounts"))
        }
        if profiles.count > 1 {
            var stale = 0
            var needsLogin = 0
            var unavailable = 0
            for profile in profiles {
                if localCLIAccounts.stale.contains(profile.id) { stale += 1 }
                switch localCLIAccounts.quotas[profile.id]?.state {
                case .needsLogin: needsLogin += 1
                case .unavailable: unavailable += 1
                default: break
                }
            }
            var parts: [String] = []
            if stale > 0 {
                parts.append(language.text("\(stale) 个刷新失败", "\(stale) refresh failed"))
            }
            if needsLogin > 0 {
                parts.append(language.text("\(needsLogin) 个待登录", "\(needsLogin) need sign-in"))
            }
            if unavailable > 0 {
                parts.append(language.text("\(unavailable) 个暂未读到", "\(unavailable) limits not read"))
            }
            parts.append(language.text("额度按账号显示", "Limits shown per account"))
            return ("—", parts.joined(separator: " · "))
        }
        let profile = profiles[0]
        if localCLIAccounts.refreshing.contains(profile.id), localCLIAccounts.quotas[profile.id] == nil {
            return ("—", language.text("读取中…", "Reading…"))
        }
        guard let result = localCLIAccounts.quotas[profile.id] else {
            return ("—", language.text("额度未读到", "Limits not read"))
        }
        let staleNote =
            localCLIAccounts.stale.contains(profile.id)
            ? language.text("刷新失败 · 上次快照", "Refresh failed · Previous snapshot")
            : nil
        if !result.windows.isEmpty {
            let quota = result.windows.prefix(2).map { window in
                "\(window.label) \(QuotaAvailabilityPresentation.percentText(100 - window.usedPercent))"
            }.joined(separator: " · ")
            return (quota, staleNote ?? "")
        }
        let status: String
        switch result.state {
        case .available:
            status = staleNote ?? language.text("暂无用量百分比", "No usage percentage")
        case .needsLogin:
            status = language.text("待登录", "Sign-in needed")
        case .unsupported:
            status = language.text("额度接口未接通", "Quota interface unavailable")
        case .rateLimited:
            status = language.text("暂时限流", "Rate limited")
        case .unavailable:
            status = language.text("暂未读到额度", "Limits not read")
        }
        return ("—", status)
    }

    private func openCodexTab() {
        showingHome = false
        selectedLocalCLI = nil
    }

    private func openLocalCLITab(_ kind: LocalCLIKind) {
        showingHome = false
        selectedLocalCLI = kind
        if !store.isPreview {
            for profile in localCLIAccounts.profiles(for: kind) where localCLIAccounts.quotas[profile.id] == nil {
                localCLIAccounts.refresh(profile)
            }
        }
    }

    @ViewBuilder
    private var codexWorkspaceContent: some View {
        if presentation.isSingleAccount { workspaceBranding }
        if !showingHome {
            AutomationMaintenanceNotice(features: store.pausedAutomationFeatures, language: language)
        }
        workspace
    }

    private var cliSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    showingHome = true
                    selectedLocalCLI = nil
                    refreshMissingLocalCLIQuotas()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "house")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16, height: 16)
                        Text(language.text("主页", "Home")).font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(showingHome ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("主页", "Home"))
                Button {
                    openCodexTab()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "terminal")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16, height: 16)
                        Text("Codex").font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(!showingHome && selectedLocalCLI == nil ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
                }.buttonStyle(.plain)
                ForEach(installedLocalCLIKinds) { kind in
                    Button {
                        openLocalCLITab(kind)
                    } label: {
                        HStack(spacing: 7) {
                            LocalCLIIcon(kind: kind).frame(width: 16, height: 16)
                            Text(kind.displayName).font(.callout.weight(.medium))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(!showingHome && selectedLocalCLI == kind ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Button {
                    guard !store.isPreview else { return }
                    localCLIAccounts.discover()
                    if showingHome { refreshMissingLocalCLIQuotas() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless).padding(.horizontal, 6).padding(.vertical, 8)
                .help(language.text("重新检测本机 CLI", "Scan installed CLIs"))
                .accessibilityLabel(language.text("重新检测本机 CLI", "Scan installed CLIs"))
                if !showingHome {
                    Button(language.text("使用引导", "Getting started")) {
                        isSetupGuidePresented = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(language.text("使用引导", "Getting started"))
                }
            }
        }
        .frame(minHeight: 40)
    }

    private func refreshMissingLocalCLIQuotas() {
        guard !store.isPreview else { return }
        for kind in LocalCLIKind.allCases where localCLIAccounts.installed[kind] != nil {
            for profile in localCLIAccounts.profiles(for: kind) where localCLIAccounts.quotas[profile.id] == nil {
                localCLIAccounts.refresh(profile)
            }
        }
    }

    /// Share the exact content tree with the screen, without its viewport or polling hooks.
    var screenshotContent: some View {
        VStack(spacing: 0) {
            workspaceContent
            operationStatusBar
        }
        .background(FixedVisualPalette.windowScrim(effectiveColorScheme, reduceTransparency: reduceTransparency))
        .environment(
            \.visualTokens,
            paletteCatalog.resolve(
                id: settings.paletteID, appearance: effectiveColorScheme == .dark ? .dark : .light
            )
        )
        .transaction { $0.disablesAnimations = true }
        .preferredColorScheme(settings.themeMode.preferredColorScheme)
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
    }

    private func saveLongScreenshot(for window: NSWindow) {
        guard !isSavingScreenshot else { return }
        guard window.attachedSheet == nil else {
            screenshotFeedback = language.text("请先关闭当前对话框，再保存长截图。", "Close the current dialog before saving a screenshot.")
            return
        }
        isSavingScreenshot = true
        screenshotFeedback = nil
        do {
            let capture = try WorkspaceScreenshotExporter.render(
                screenshotContent, width: window.contentLayoutRect.width, scheme: effectiveColorScheme
            )
            WorkspaceScreenshotExporter.save(capture, for: window, language: language) { result in
                isSavingScreenshot = false
                switch result {
                case .success(.some): screenshotFeedback = language.text("长截图已保存到所选位置。", "Screenshot saved.")
                case .success(.none): break
                case .failure: screenshotFeedback = language.text("截图未保存，请检查目标文件夹的写入权限后重试。", "Could not save the screenshot. Check folder permissions and try again.")
                }
            }
        } catch {
            isSavingScreenshot = false
            screenshotFeedback =
                (error as? WorkspaceScreenshotExporter.ExportError)?.message(language) ?? language.text("未能生成截图，请重试。", "Could not capture the workspace. Please try again.")
        }
    }

    private var workspaceBranding: some View {
        HStack {
            if !showingHome {
                Text("AgentHub")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
            }
            Spacer()

            Label(
                presentation.isSingleAccount
                    ? language.text("单账号 · 专注模式", "Single account · Focus mode") : language.text("\(presentation.accountCount) 个账号", "\(presentation.accountCount) accounts"),
                systemImage: presentation.isSingleAccount ? "person.crop.circle" : "person.2"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            workspaceHeader
            tokenTotalPanel
            resetUpdatesBanner
            if presentation.isSingleAccount {
                currentExecutableSection
                DisclosureGroup(language.text("用量统计", "Usage"), isExpanded: $isUsageDetailsExpanded) {
                    agentBreakdownPanel.padding(.top, 12)
                }
                .font(.subheadline.weight(.medium))
                .padding(16)
                .sectionBackground()
                DisclosureGroup(language.text("账号管理与自动化", "Account settings and automation"), isExpanded: $isAccountDetailsExpanded) {
                    VStack(spacing: 16) {
                        if !showingHome { profilesPanel }
                        automationPanel
                        safetyFooter
                    }
                    .padding(.top, 14)
                }
                .font(.subheadline.weight(.medium))
                .padding(16)
                .sectionBackground()
            } else {
                DisclosureGroup(isExpanded: $isUsageDetailsExpanded) {
                    quotaOverview.padding(.top, 8)
                } label: {
                    HStack(spacing: 16) {
                        Label(language.text("当前监控 · \(selectedAccountName)", "Monitoring · \(selectedAccountName)"), systemImage: "eye")
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .sectionBackground()
                agentBreakdownPanel
                if !showingHome { profilesPanel }
                automationPanel
                safetyFooter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presentation: WorkspacePresentation {
        WorkspacePresentation(profiles: store.profiles, selectedProfileID: store.selectedMonitorProfileID)
    }

    private var overviewQuota: (fiveHour: RateWindow?, sevenDay: RateWindow?, readSucceeded: Bool) {
        presentation.quotaSummary(monitored: store.snapshot)
    }

    private var currentExecutableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.text("当前可执行", "Ready to run"))
                .font(.headline)
            quotaOverview
            focusedExecutionPanel
        }
    }

    @ViewBuilder
    private var focusedExecutionPanel: some View {
        if let profile = presentation.focusedProfile, !profile.isSystemProfile {
            let status = hubTaskStatusModel.status(
                forAccountAlias: store.accountTaskAlias(for: profile),
                accountKey: profile.lastSnapshot?.email.map { DispatchActivityStore.hash($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            )
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(language.text("下一次任务", "Next CLI session"), systemImage: "terminal")
                        .font(.headline)
                    Spacer()
                    HubCLITaskStatusBadge(status: status)
                }
                HStack(spacing: 16) {
                    ExecutionPreferenceControl(
                        preference: profile.effectiveExecutionPreference,
                        allowsApplyToAll: presentation.managedAccountCount > 1,
                        expanded: true
                    ) { preference, applyToAll in
                        store.setExecutionPreference(preference, for: profile.id, applyToAll: applyToAll)
                    }
                    Button {
                        store.openTerminal(for: profile.id, workingDirectory: nil)
                    } label: {
                        Label(language.text("在终端中使用", "Open CLI"), systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(status.blocksLocalCLI || store.isLaunchingCodex || store.isLoggingIn)
                }
                Text(
                    status.blocksLocalCLI
                        ? (status.blockingReason(language)
                            ?? language.text(
                                "账号正在使用，或调度状态尚未确认。确认空闲后才能开始，避免重复占用。",
                                "This account is busy or its status is unverified. CLI launch is available after Hub confirms it is idle."))
                        : language.text("模型偏好已就绪。新任务使用上面的模型与速度，现有任务保持不变。", "These settings apply to new CLI sessions and dispatched tasks. Running tasks stay unchanged.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .sectionBackground()
        } else {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(language.text("安心查看当前账号", "Monitor your current account")).font(.headline)
                    Text(
                        language.text(
                            "直接查看额度，无需添加其他账号。如需指定任务模型，可把同一账号添加为独立 CLI 环境；不会切换当前 Codex。",
                            "No second account needed. Add this account as an isolated CLI profile to choose task models without switching Codex.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(language.text("设置独立 CLI", "Set up isolated CLI")) { store.addProfile() }
                    .buttonStyle(.bordered)
                    .disabled(store.isLoggingIn)
            }
            .padding(20)
            .sectionBackground()
        }
    }

    @ViewBuilder
    private var operationStatusBar: some View {
        if store.accountManagerMessage != nil || store.isAwaitingCodexHistoryConfirmation || screenshotFeedback != nil {
            HStack(spacing: 12) {
                if let screenshotFeedback {
                    Label(screenshotFeedback, systemImage: "photo")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        self.screenshotFeedback = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("关闭截图提示", "Dismiss screenshot status"))
                }
                if let message = store.accountManagerMessage {
                    HStack(spacing: 8) {
                        if store.isLaunchingCodex { ProgressView().controlSize(.small) }
                        Text(message)
                            .font(.caption.weight(.medium))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(message)
                        if store.canCancelDesktopSwitch {
                            Button(language.text("取消切换", "Cancel switch")) { store.cancelDesktopSwitchPreparation() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if store.isAwaitingCodexHistoryConfirmation {
                    Button(language.text("历史完整，完成切换", "History verified — finish switch")) {
                        store.confirmRestoredCodexHistory()
                    }
                    .buttonStyle(.borderedProminent)
                    Button(language.text("历史不完整，回滚", "History missing — roll back")) {
                        store.rejectRestoredCodexHistory()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }

    private var workspaceHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AgentHub")
                    .font(.system(size: presentation.isSingleAccount ? 24 : 20, weight: .semibold))
                if presentation.isSingleAccount {
                    Text(language.text("看清额度，专注下一次任务。", "Know your limits. Focus on the next task."))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            Button {
                store.refreshQuotas()
            } label: {
                Label(store.isRefreshing ? language.text("读取中…", "Refreshing…") : language.text("刷新额度", "Refresh limits"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(store.isRefreshing)
        }
    }

    private var quotaOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedAccountName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(overviewQuota.readSucceeded ? FixedVisualPalette.statusSuccess : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(overviewQuota.readSucceeded ? language.text("官方额度已连接", "Usage limits connected") : language.text("等待官方额度", "Waiting for usage limits"))
                        if let profile = presentation.quotaProfile {
                            ProfileSnapshotNotice(profile: profile)
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                Spacer()

                Label(accountPlan, systemImage: accountPlanIcon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }

            HStack(spacing: 16) {
                QuotaDetailTile(
                    title: language.text("5 小时剩余", "5h available"),
                    icon: "timer",
                    window: overviewQuota.fiveHour,
                    prominent: true
                )
                QuotaDetailTile(
                    title: language.text("7 天剩余", "7d remaining"),
                    icon: "calendar.badge.clock",
                    window: overviewQuota.sevenDay,
                    prominent: true
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
        .sectionBackground()
    }

    private var localAllAgentsTokens: Int64? {
        store.localAllAgentsLifetimeTokens
    }

    private var combinedTokensTotal: Int64? {
        let official = officialAccountsTotal ?? 0
        let local = localAllAgentsTokens ?? 0
        guard official > 0 || local > 0 else { return nil }
        return official + local
    }

    private var combinedEquivalentCostUSD: Double? {
        guard let combinedTokensTotal,
            let localTokens = store.snapshot.local?.detailedUsage?.lifetime.tokens
        else { return nil }
        return estimatedSolProEquivalentCostUSD(
            officialTotalTokens: combinedTokensTotal,
            localTokens: localTokens
        )
    }

    private var tokenTotalPanel: some View {
        TokenTotalsHeader(
            layout: .hero,
            language: language,
            combinedTokensTotal: combinedTokensTotal,
            combinedEquivalentCostUSD: combinedEquivalentCostUSD,
            officialAccountsLifetimeTokens: officialAccountsTotal,
            localAllAgentsLifetimeTokens: localAllAgentsTokens,
            officialAccountsStatsAsOf: officialAccountsStatsAsOf
        )
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sectionBackground()
    }

    private var agentBreakdownPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isAgentBreakdownExpanded.toggle()
                }
            } label: {
                HStack {
                    Label(language.text("本机各 Agent 占比", "Local usage by agent"), systemImage: "chart.pie")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(language.tokens(localAllAgentsTokens))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isAgentBreakdownExpanded ? 0 : -90))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isAgentBreakdownExpanded ? language.text("收起各 Agent 占比", "Collapse agent breakdown") : language.text("展开各 Agent 占比", "Expand agent breakdown"))

            if isAgentBreakdownExpanded {
                let shares = store.snapshot.local?.allAgentsShares ?? []
                let percentBase = max(Double(localAllAgentsTokens ?? 0), 1)
                if shares.isEmpty {
                    Text(language.text("暂无本机 Agent 记录", "No local usage records"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shares.prefix(10)) { share in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(share.name)
                                .font(.caption.weight(.medium))
                                .frame(minWidth: 110, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.25))
                                    .frame(width: max(proxy.size.width * CGFloat(share.tokens) / CGFloat(percentBase), 2))
                            }
                            .frame(height: 6)
                            Text("\(Int((Double(share.tokens) / percentBase * 100).rounded()))%")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.tint)
                                .frame(width: 40, alignment: .trailing)
                            Text(language.tokens(share.tokens))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            if share.manual {
                                Button {
                                    removeCustomTokenSource(named: share.name)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(language.text("删除自定义来源", "Remove custom source"))
                                .accessibilityLabel(language.text("删除自定义来源 \(share.name)", "Remove custom source \(share.name)"))
                            } else {
                                Spacer().frame(width: 18)
                            }
                        }
                    }
                }
                Button {
                    customSourceNameDraft = ""
                    customSourceTokensDraft = ""
                    isAddingCustomTokenSource = true
                } label: {
                    Label(language.text("添加自定义来源", "Add custom source"), systemImage: "plus.circle")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help(language.text("手动录入其他 API 的累计用量，并入本机全 Agent 统计", "Add a manually recorded API total to local agent usage."))
                .alert(language.text("添加自定义来源", "Add custom source"), isPresented: $isAddingCustomTokenSource) {
                    TextField(language.text("名称（如 美团）", "Source name"), text: $customSourceNameDraft)
                    TextField(language.text("累计 token（单位：万，如 5000）", "Lifetime tokens in 10,000s (e.g. 5000)"), text: $customSourceTokensDraft)
                    Button(language.text("添加", "Add")) { addCustomTokenSource() }
                    Button(language.text("取消", "Cancel"), role: .cancel) {}
                } message: {
                    Text(language.text("录入的用量会并入本机全 Agent 合计与占比", "Each unit is 10,000 tokens. This value is included in local totals and the agent breakdown."))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .sectionBackground()
    }

    private func addCustomTokenSource() {
        let name = customSourceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let tokens = customTokenCount(fromWanText: customSourceTokensDraft) else { return }
        var entries = CustomTokenSourceStore.load()
        entries.removeAll { $0.name == name }
        entries.append(CustomTokenSourceStore.Entry(name: name, tokens: tokens))
        CustomTokenSourceStore.save(entries)
        store.refresh(queueIfBusy: true)
    }

    private func removeCustomTokenSource(named name: String) {
        var entries = CustomTokenSourceStore.load()
        entries.removeAll { $0.name == name }
        CustomTokenSourceStore.save(entries)
        store.refresh(queueIfBusy: true)
    }

    private var officialAccountsTotal: Int64? {
        store.officialAccountsLifetimeTokens
    }

    private var officialAccountsStatsAsOf: Date? {
        accountGroups.compactMap { group in
            group.compactMap { $0.officialProfile?.statsAsOf }.max()
        }.min()
    }

    private var accountGroups: [[CodexProfile]] {
        CodexProfile.groupsByRecordedAccount(store.profiles)
    }

    private var presentedProfiles: [CodexProfile] {
        store.profiles.filter { profile in
            linkedManagedProfile(for: profile) == nil || profile.remark?.isEmpty == false
        }
    }

    private var orderedProfiles: [CodexProfile] {
        let current = presentedProfiles
        guard let profileReorder, profileReorder.originalOrder == current.map(\.id) else {
            if isEditingDisplayedProfiles { return current }
            let expiring = Set(current.filter { codexCardExpiring($0, now: Date()) }.map { ResetCardPresentation.codexKey($0.id) })
            let byID = Dictionary(uniqueKeysWithValues: current.map { (ResetCardPresentation.codexKey($0.id), $0) })
            return ResetCardPresentation.prioritizedOrder(
                current.map { ResetCardPresentation.codexKey($0.id) }, expiring: expiring,
                pinnedAccountID: settings.pinnedAccountKey
            ).compactMap { byID[$0] }
        }
        let profilesByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return profileReorder.order.compactMap { profilesByID[$0] }
    }

    private var profilesLayout: AnyLayout {
        displayedAccountLayout == .cards
            ? AnyLayout(AccountCardGridLayout())
            : AnyLayout(VStackLayout(spacing: 8))
    }

    private var canReorderProfiles: Bool {
        isEditingDisplayedProfiles && !store.isLaunchingCodex && !store.isRefreshing && !store.isLoggingIn && !isSavingScreenshot
    }

    private func beginProfileReorder(_ id: String) -> Bool {
        guard canReorderProfiles else { return false }
        profileReorder = ProfileReorderSession(sourceID: id, order: presentedProfiles.map(\.id))
        return profileReorder != nil
    }

    private func previewProfileReorder(at point: CGPoint) {
        guard canReorderProfiles, var draft = profileReorder,
            draft.originalOrder == presentedProfiles.map(\.id),
            let id = profileFrames.first(where: { $0.key != draft.sourceID && $0.value.contains(point) })?.key
        else { return }
        draft.move(over: id)
        withAnimation(ProfileReorderMotion.animation(reduceMotion: reduceMotion)) { profileReorder = draft }
    }

    private func finishProfileReorder(at point: CGPoint) {
        defer { profileReorder = nil }
        guard canReorderProfiles, let draft = profileReorder,
            profileFrames.values.contains(where: { $0.contains(point) }),
            let destination = draft.destination(currentOrder: presentedProfiles.map(\.id))
        else { return }
        store.moveProfile(draft.sourceID, relativeTo: destination.targetID, before: destination.before)
    }

    private func movePresentedProfile(_ id: String, offset: Int) {
        guard canReorderProfiles else { return }
        let current = presentedProfiles
        guard let index = current.firstIndex(where: { $0.id == id }),
            current.indices.contains(index + offset)
        else { return }
        store.moveProfile(id, relativeTo: current[index + offset].id, before: offset < 0)
    }

    private func isDuplicateAccount(_ profile: CodexProfile) -> Bool {
        (accountGroups.first { $0.contains(where: { $0.id == profile.id }) }?.count ?? 0) > 1
    }

    private func linkedManagedProfile(for profile: CodexProfile) -> CodexProfile? {
        guard profile.isSystemProfile else { return nil }
        return accountGroups.first { $0.contains(where: { $0.id == profile.id }) }?
            .first { !$0.isSystemProfile }
    }

    private func isCurrentCodexAccount(_ profile: CodexProfile) -> Bool {
        guard let group = accountGroups.first(where: { $0.contains(where: { $0.id == profile.id }) }) else {
            return false
        }
        return profile.isSystemProfile
            ? !group.contains(where: { !$0.isSystemProfile })
            : group.contains(where: { $0.isSystemProfile })
    }

    private var selectedMonitorHubTaskStatus: HubAccountTaskStatus {
        hubTaskStatusModel.status(
            forAccountAlias: store.selectedMonitorProfile.flatMap {
                store.accountTaskAlias(for: $0)
            },
            accountKey: store.selectedMonitorProfile?.lastSnapshot?.email.map { DispatchActivityStore.hash($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        )
    }

    private var profilesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label(presentation.isSingleAccount ? language.text("账号设置", "Account settings") : language.text("账号与任务", "Accounts and tasks"), systemImage: "person.2")
                        .font(.headline)
                    if presentation.isSingleAccount {
                        Text(language.text("登录、暖号与高级设置", "Sign-in, warm-up and advanced settings"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(language.text("查看工作状态，空闲后再派单；刷新不触发暖号", "Check task status before starting work. Refresh only reads usage; it does not warm up an account."))
                Spacer()
                Text(language.text("\(presentation.accountCount) 个账号", "\(presentation.accountCount) accounts"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(language.text("账号显示方式", "Account layout"), selection: $settings.accountWorkspaceLayout) {
                    Text(language.text("列表", "List")).tag(AccountWorkspaceLayout.rows)
                    Text(language.text("卡片", "Cards")).tag(AccountWorkspaceLayout.cards)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 136)
                .help(language.text("列表适合连续查看；卡片适合横向比较。两种视图共用账号顺序与全部功能。", "List and card layouts share the same account order and controls."))
                Button(isEditingProfiles ? language.text("完成", "Done") : language.text("编辑", "Edit")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        isEditingProfiles.toggle()
                        profileReorder = nil
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityValue(isEditingProfiles ? language.text("编辑模式已开启", "Editing enabled") : language.text("编辑模式已关闭", "Editing disabled"))
                Menu {
                    Button(language.text("账号专属 Chrome（推荐）", "Dedicated Chrome profile (recommended)")) { store.addProfile() }
                    if !store.availableChromeProfiles.isEmpty { Divider() }
                    ForEach(store.availableChromeProfiles) { chromeProfile in
                        Button(chromeProfile.displayName) {
                            store.addProfile(using: chromeProfile)
                        }
                    }
                } label: {
                    Label(store.isLoggingIn ? language.text("登录中…", "Signing in…") : language.text("添加账号", "Add account"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isLoggingIn)
            }

            HStack(spacing: 12) {
                Text(language.text("智能暖号", "Auto warm-up"))
                    .font(.caption.weight(.semibold))
                Text(language.text("按各账号自己的 5 小时与 7 天窗口轮流执行", "Follows each account's reset times"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Toggle(
                    language.text("5 小时", "5h"),
                    isOn: Binding(
                        get: { store.warmUpSelection.fiveHour },
                        set: { store.setWarmUpFiveHourEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(store.pausedAutomationFeatures.contains(.fiveHour))
                .help(
                    language.text(
                        "所有账号按自己的 5 小时窗口维护，不受参与调度开关影响；忙碌或失败会自动复核，周额度用尽后等待恢复。",
                        "Maintains every account on its own 5h schedule regardless of dispatch participation. Busy or failed accounts are rechecked; exhausted weekly limits wait for recovery."
                    ))
                Toggle(
                    language.text("7 天", "7d"),
                    isOn: Binding(
                        get: { store.warmUpSelection.sevenDay },
                        set: { store.setWarmUpSevenDayEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(store.pausedAutomationFeatures.contains(.sevenDay))
                .help(
                    language.text(
                        "所有账号按自己的 7 天窗口维护，不受参与调度开关影响；失败 5 分钟后自动复核重试。",
                        "Maintains every account on its weekly schedule regardless of dispatch participation. Failed requests are rechecked for retry after 5 minutes.")
                )
            }

            codexProfileRows

            HStack {
                Text(language.text("账号凭据独立保存；切换 Codex 时沿用当前电脑的项目与对话。", "Account sign-ins stay isolated. Desktop switching retains this Mac's projects and conversations."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(store.isLoggingIn ? language.text("取消登录", "Cancel sign-in") : language.text("重新登录所选账号", "Sign in again")) {
                    if store.isLoggingIn {
                        store.cancelLogin()
                    } else {
                        store.loginSelectedMonitorProfile()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!store.isLoggingIn && selectedMonitorHubTaskStatus.blocksLocalCLI)
                .help(
                    store.isLoggingIn
                        ? language.text("取消正在进行的登录", "Cancel the current sign-in")
                        : selectedMonitorHubTaskStatus.blocksLocalCLI
                            ? (selectedMonitorHubTaskStatus.blockingReason(language)
                                ?? language.text(
                                    "Hub 状态未确认或同账号有活跃任务，暂不能重新登录所选账号",
                                    "Sign-in is blocked while Hub status is unverified or this account has an active task."))
                            : language.text("重新登录当前监控账号", "Sign in to the monitored account again"))
            }
        }
        .padding(.vertical, 4)
    }

    private var codexProfileRows: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            profilesLayout {
                ForEach(Array(orderedProfiles.enumerated()), id: \.element.id) { index, profile in
                    codexAccountRow(profile, index: index, now: timeline.date)
                }
            }
            .onPreferenceChange(ProfileFramePreferenceKey.self) { frames in
                if profileFrames != frames { profileFrames = frames }
            }
        }
    }

    private func codexAccountRow(_ profile: CodexProfile, index: Int, now: Date) -> some View {
        let linkedProfile = linkedManagedProfile(for: profile)
        return ProfileRow(
            profile: profile,
            allProfiles: store.profiles,
            executionPreference: profile.effectiveExecutionPreference,
            dispatchCode: DispatchCodeCatalog.code(for: profile.id, allowsLocalRead: !store.isPreview),
            cliTaskStatus: hubTaskStatusModel.status(
                forAccountAlias: store.accountTaskAlias(for: profile),
                accountKey: profile.lastSnapshot?.email.map { DispatchActivityStore.hash($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            ),
            isMonitoring: profile.id == store.selectedMonitorProfileID,
            isLaunchProfile: profile.id == store.selectedLaunchProfileID,
            isDuplicateAccount: isDuplicateAccount(profile),
            isCurrentCodexAccount: isCurrentCodexAccount(profile),
            linkedAccountName: linkedProfile.map { AccountDisplay.profileName($0) },
            participatesInAutomaticSwitch: store.automaticSwitchParticipation(for: profile),
            prioritizesDispatch: store.dispatchPriority(for: profile),
            isEditing: isEditingDisplayedProfiles,
            layout: displayedAccountLayout,
            isLoggingIn: store.isLoggingIn,
            isLaunching: store.isLaunchingCodex,
            isSwitchTarget: store.desktopSwitchTargetID == profile.id,
            isRefreshingStatistics: store.isRefreshing,
            isRefreshingProfile: store.refreshingProfileIDs.contains(profile.id),
            isWarmingProfile: store.warmingProfileID == profile.id,
            canMoveUp: index > 0,
            canMoveDown: index < presentedProfiles.count - 1,
            quotaReadSucceeded: linkedProfile == nil
                && profile.lastSnapshot != nil
                && profile.lastQuotaReadFailureAt == nil,
            fiveHourRemainingPercent: fiveHourRemaining(for: profile),
            fiveHourResetsAt: fiveHourReset(for: profile),
            remainingPercent: sevenDayRemaining(for: profile),
            resetsAt: sevenDayReset(for: profile),
            currentDate: now,
            warmUpStatus: linkedProfile == nil ? store.warmUpStatus(for: profile, language: language) : nil,
            creditBalance: store.creditBalancePresentation(for: profile),
            allowsResetCreditAction: !store.isPreview && linkedProfile == nil,
            hubAccountAlias: store.accountTaskAlias(for: profile),
            availableResetCredits: store.availableResetCredits(for: profile),
            resetCreditExpiries: store.resetCreditExpiries(for: profile),
            resetCardsExpiring: codexCardExpiring(profile, now: now),
            localResetHistoryCount: store.localResetHistoryCount(for: profile),
            chromeProfiles: store.availableChromeProfiles,
            onMonitor: { store.selectMonitorProfile(profile.id) },
            onRefresh: { store.refreshProfile(profile.id) },
            onWarmUp: { store.warmUpProfile(profile.id) },
            onRelogin: {
                if linkedProfile != nil {
                    store.loginProfileIndependently(profile.id)
                } else {
                    store.loginProfile(profile.id)
                }
            },
            onLaunch: { store.launchCodex(with: profile.id) },
            onOpenTerminal: { store.openTerminal(for: profile.id, workingDirectory: $0) },
            onCopyTerminalCommand: { store.copyTerminalCommand(for: profile.id) },
            onSetAutomaticSwitchParticipation: {
                store.setAutomaticSwitchParticipation($0, for: profile.id)
            },
            onSetDispatchPriority: {
                store.setDispatchPriority($0, for: profile.id)
            },
            onSetDispatchParticipationWindow: {
                store.setDispatchParticipationWindow($0, for: profile.id)
            },
            onSetProTierMultiplier: { store.setProTierMultiplier($0, for: profile.id) },
            onSetExecutionPreference: { preference, applyToAll in
                store.setExecutionPreference(preference, for: profile.id, applyToAll: applyToAll)
            },
            onRename: { store.setProfileRemark($0, for: profile.id) },
            onSetChromeProfile: { store.setChromeProfile($0, for: profile.id) },
            onMoveUp: {
                movePresentedProfile(profile.id, offset: -1)
            },
            onMoveDown: {
                movePresentedProfile(profile.id, offset: 1)
            },
            onBeginReorder: { beginProfileReorder(profile.id) },
            onMoveReorder: previewProfileReorder,
            onDropReorder: finishProfileReorder,
            onEndReorder: {
                withAnimation(ProfileReorderMotion.animation(reduceMotion: reduceMotion)) { profileReorder = nil }
            },
            onDelete: { store.deleteProfile(profile.id) },
            onAdjustResetCount: { store.adjustResetCount(for: profile, delta: $0) }
        )
        .opacity(profileReorder?.sourceID == profile.id ? 0.55 : 1)
        .contextMenu {
            let key = ResetCardPresentation.codexKey(profile.id)
            Button(settings.pinnedAccountKey == key ? language.text("取消置顶", "Unpin") : language.text("固定第一位", "Pin first")) {
                settings.pinnedAccountKey = settings.pinnedAccountKey == key ? nil : key
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ProfileFramePreferenceKey.self,
                    value: isEditingDisplayedProfiles ? [profile.id: geometry.frame(in: .global)] : [:]
                )
            }
        }
    }

    private var automationPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(language.text("低额度调度提醒", "Low-limit alerts"))
                        .font(.subheadline.weight(.semibold))
                    Text("5h ≤\(store.lowQuotaAlertThresholds.fiveHour)%")
                        .profileBadge()
                    if store.feishuNotificationsEnabled && store.feishuWebhookConfigured {
                        Label(language.text("飞书已启用", "Feishu enabled"), systemImage: "paperplane.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FixedVisualPalette.statusSuccessForeground(effectiveColorScheme))
                    }
                }
                Text(language.text("低额度时提醒并推荐可用账号，不改写当前 Codex 身份", "Alerts and account suggestions only. Your current Codex sign-in stays unchanged."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Label(
                store.automaticAccountSwitchEnabled ? language.text("已开启", "On") : language.text("未开启", "Off"),
                systemImage: store.automaticAccountSwitchEnabled ? "checkmark.shield.fill" : "shield"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(store.automaticAccountSwitchEnabled ? FixedVisualPalette.statusSuccessForeground(effectiveColorScheme) : Color.secondary)

            Button(language.text("运行问题日志", "Issue journal")) {
                store.openOperationsIssueJournal()
            }
            .buttonStyle(.bordered)

            if let message = store.operationsIssueJournalMessage {
                Label(language.text("日志写入失败", "Journal write failed"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help(message)
            }

            Button(language.text("自动化中心", "Automation")) {
                isAutomationCenterPresented = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .sectionBackground()
        .accessibilityElement(children: .contain)
    }

    private var safetyFooter: some View {
        HStack(spacing: 10) {
            Label(language.text("保存切换前快照", "Back up before switching"), systemImage: "checkmark.circle.fill")
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Label(language.text("验证目标账号", "Verify target account"), systemImage: "checkmark.shield.fill")
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Label(language.text("切换本机登录", "Switch Desktop sign-in"), systemImage: "arrow.triangle.2.circlepath")
            Spacer()
            Text(language.text("原对话未恢复则回滚原账号", "Roll back if conversation history is missing"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .combine)
    }

    private var accountPlan: String {
        AccountDisplay.planLabel(
            presentation.isSingleAccount ? presentation.focusedProfile : store.selectedMonitorProfile, fallbackPlan: store.snapshot.account?.planType,
            empty: language.text("官方服务", "Codex"))
    }

    private var accountPlanIcon: String {
        accountPlan.hasPrefix("PRO") ? "crown.fill" : "plus.circle.fill"
    }

    private var selectedAccountName: String {
        guard let profile = presentation.isSingleAccount ? presentation.focusedProfile : store.selectedMonitorProfile else { return language.text("未选择账号", "No account selected") }
        return AccountDisplay.profileName(
            profile,
            fallbackRaw: store.snapshot.account?.email,
            allProfiles: store.profiles
        )
    }

    private func sevenDayRemaining(for profile: CodexProfile) -> Double? {
        guard linkedManagedProfile(for: profile) == nil else { return nil }
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.sevenDayQuota?.remainingPercent
        }
        return profile.lastSnapshot?.sevenDay.map { max(0, min(100, 100 - $0.usedPercent)) }
    }

    private func fiveHourRemaining(for profile: CodexProfile) -> Double? {
        guard linkedManagedProfile(for: profile) == nil else { return nil }
        if QuotaAvailabilityPresentation.isWeeklyExhausted(sevenDayRemaining(for: profile)) { return 0 }
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.fiveHourQuota?.remainingPercent
        }
        return profile.lastSnapshot?.fiveHour.map { max(0, min(100, 100 - $0.usedPercent)) }
    }

    private func fiveHourReset(for profile: CodexProfile) -> Date? {
        guard linkedManagedProfile(for: profile) == nil else { return nil }
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.fiveHourQuota?.resetsAt
        }
        return profile.lastSnapshot?.fiveHour?.resetsAt
    }

    private func sevenDayReset(for profile: CodexProfile) -> Date? {
        guard linkedManagedProfile(for: profile) == nil else { return nil }
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.sevenDayQuota?.resetsAt
        }
        return profile.lastSnapshot?.sevenDay?.resetsAt
    }
}

private struct HomeOverviewProviderRow<Icon: View>: View {
    let name: String
    let accountCountText: String
    let quotaText: String
    let statusText: String
    let language: WidgetLanguage
    let icon: Icon
    let action: () -> Void

    init(
        name: String,
        accountCountText: String,
        quotaText: String,
        statusText: String,
        language: WidgetLanguage,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.name = name
        self.accountCountText = accountCountText
        self.quotaText = quotaText
        self.statusText = statusText
        self.language = language
        self.icon = icon()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                    Text(accountCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(quotaText)
                        .font(.caption.monospacedDigit())
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sectionBackground()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(language.text("打开\(name)页", "Opens the \(name) tab"))
    }
}

private struct AutomationMaintenanceNotice: View {
    let features: [PausedAutomationFeature]
    let language: WidgetLanguage

    var body: some View {
        if !features.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("维护期间暂停", "Paused for maintenance"))
                        .font(.subheadline.weight(.semibold))
                    Text(features.map { $0.name(language) }.joined(separator: " · "))
                        .font(.caption)
                    Text(language.text("原设置已保留；普通启动后恢复。", "Your saved settings are preserved and resume on a normal launch."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(FixedVisualPalette.statusWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
    }
}

private struct DispatchParticipationWindowEditor: View {
    @Binding var window: DispatchParticipationWindow
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.widgetLanguage) private var language

    private func timeBinding(_ index: Int, start: Bool) -> Binding<Date> {
        Binding(
            get: {
                let value = start ? window.intervals[index].startMinute : window.intervals[index].endMinute
                return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: value / 60, minute: value % 60))!
            },
            set: { date in
                let value = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
                if start { window.intervals[index].startMinute = value } else { window.intervals[index].endMinute = value }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("参与调度时间段", "Dispatch hours")).font(.headline)
            Picker(language.text("模式", "Mode"), selection: $window.mode) {
                Text(language.text("不限制时间", "Any time")).tag(DispatchParticipationWindow.Mode.unrestricted)
                Text(language.text("仅在时间段内参与", "Only within these hours")).tag(DispatchParticipationWindow.Mode.onlyWithin)
                Text(language.text("排除以下时间段", "Except during these hours")).tag(DispatchParticipationWindow.Mode.exceptWithin)
            }
            TextField(language.text("时区，例如 Asia/Shanghai", "Time zone, e.g. Asia/Shanghai"), text: $window.timeZoneIdentifier)
                .textFieldStyle(.roundedBorder)
            if window.mode != .unrestricted {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(window.intervals.indices, id: \.self) { index in
                                VStack(alignment: .leading) {
                                    HStack {
                                        DatePicker(language.text("开始", "Start"), selection: timeBinding(index, start: true), displayedComponents: .hourAndMinute)
                                            .disabled(window.intervals[index].allDay)
                                        DatePicker(language.text("结束", "End"), selection: timeBinding(index, start: false), displayedComponents: .hourAndMinute)
                                            .disabled(window.intervals[index].allDay)
                                        Button {
                                            window.intervals.remove(at: index)
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .accessibilityLabel(language.text("删除时间段", "Remove interval"))
                                    }
                                    HStack {
                                        Toggle(language.text("全天", "All day"), isOn: $window.intervals[index].allDay)
                                        Toggle(language.text("每天", "Every day"), isOn: $window.intervals[index].allDays)
                                    }
                                    if !window.intervals[index].allDays {
                                        HStack {
                                            ForEach(1...7, id: \.self) { day in
                                                Toggle(
                                                    String(day),
                                                    isOn: Binding(
                                                        get: { window.intervals[index].weekdays.contains(day) },
                                                        set: { enabled in
                                                            if enabled { window.intervals[index].weekdays.insert(day) } else { window.intervals[index].weekdays.remove(day) }
                                                        })
                                                ).toggleStyle(.button)
                                            }
                                        }
                                        Text(language.text("1 为周一，7 为周日", "1 = Monday, 7 = Sunday")).font(.caption)
                                    }
                                }
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: window.intervals.count) { count in
                        guard count > 0 else { return }
                        withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
                .frame(height: window.intervals.isEmpty ? 0 : 220)
                Button(language.text("添加时间段", "Add interval")) {
                    window.intervals.append(.init(startMinute: 9 * 60, endMinute: 18 * 60))
                }.disabled(window.intervals.count >= 32)
                Text(
                    language.text(
                        "结束时间不包含在内；跨午夜按开始日计算。空的参与时间段会暂停新派单。",
                        "End time is exclusive; overnight hours belong to the starting day. An empty inclusion schedule blocks new assignments.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Text(language.text("仅限制新派单；已运行任务、额度刷新和暖号继续。", "Applies to new assignments. Running tasks, quota refresh and warm-up continue."))
                .font(.caption).foregroundStyle(.secondary)
            if !window.isValid {
                Text(language.text("请检查时区、星期和起止时间；全天请勾选“全天”。", "Check the time zone, weekdays and times; use All day for a full day."))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(language.text("取消", "Cancel")) { dismiss() }
                Button(language.text("保存", "Save"), action: onSave).buttonStyle(.borderedProminent).disabled(!window.isValid)
            }
        }.padding(16).frame(width: 440)
    }
}

struct AccountAutomationCenterView: View {
    @Environment(\.widgetLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var webhookDraft = ""
    @State private var isConfirmingWebhookRemoval = false
    @State private var isShowingMessageChannels = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("自动化中心", "Automation"))
                        .font(.title2.weight(.semibold))
                    Text(language.text("提醒、通知与审计", "Alerts, notifications and event history"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(language.text("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AutomationMaintenanceNotice(features: store.pausedAutomationFeatures, language: language)
                    GroupBox {
                        PublicResetAnnouncementView(monitor: store.publicResetAnnouncements, paused: false)
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label(language.text("重置消息", "Reset updates"), systemImage: "arrow.counterclockwise.circle")
                            .font(.headline)
                    }
                    localNotificationsGroup
                    DisclosureGroup(language.text("低额度提醒设置", "Low-limit alert settings")) { automaticSwitchGroup }
                    DisclosureGroup(language.text("同时发送到飞书（可选）", "Also send to Feishu (optional)")) { feishuGroup }
                    Button {
                        isShowingMessageChannels = true
                    } label: {
                        Label(language.text("Telegram 与企业微信通知", "Telegram and WeCom messages"), systemImage: "bubble.left.and.bubble.right")
                    }
                    DisclosureGroup(language.text("活动记录", "Activity history")) { auditGroup }
                }
                .padding(20)
            }
        }
        .frame(width: 600, height: 680)
        .onAppear { store.refreshLocalNotificationAuthorization() }
        .sheet(isPresented: $isShowingMessageChannels) {
            MessageChannelsSettingsView(controller: store.messageChannels)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshLocalNotificationAuthorization()
        }
        .alert(language.text("移除飞书 Webhook？", "Remove Feishu webhook?"), isPresented: $isConfirmingWebhookRemoval) {
            Button(language.text("移除", "Remove"), role: .destructive) {
                store.removeFeishuWebhook()
                webhookDraft = ""
            }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text("钥匙串中的 Webhook 会被删除，飞书通知也会关闭。", "Removes the webhook from Keychain and disables Feishu notifications."))
        }
    }

    private var automaticSwitchGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("低额度提醒", "Low-limit alerts"))
                            .font(.headline)
                        Text(language.text("默认开启；额度低于阈值时提醒并推荐可用账号", "On by default. Alerts you and suggests accounts when limits are low."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        language.text("低额度提醒", "Low-limit alerts"),
                        isOn: Binding(
                            get: { store.automaticAccountSwitchEnabled },
                            set: { store.setAutomaticAccountSwitchEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(store.pausedAutomationFeatures.contains(.lowQuota))
                }

                Divider()

                HStack(spacing: 10) {
                    automationMetric(title: language.text("触发", "Trigger"), value: "5h ≤\(store.lowQuotaAlertThresholds.fiveHour)%", icon: "exclamationmark.triangle.fill")
                    automationMetric(title: language.text("备用", "Candidate"), value: "≥ 30%", icon: "battery.75percent")
                    automationMetric(title: language.text("评估间隔", "Check interval"), value: language.text("1 小时", "1 hour"), icon: "clock.arrow.circlepath")
                }

                HStack(spacing: 16) {
                    Picker(
                        language.text("5 小时提醒线", "5h alert threshold"),
                        selection: Binding(
                            get: { store.lowQuotaAlertThresholds.fiveHour },
                            set: { store.setLowQuotaAlertThresholds(fiveHour: $0, sevenDay: store.lowQuotaAlertThresholds.sevenDay) }
                        )
                    ) {
                        ForEach(LowQuotaAlertThresholds.choices, id: \.self) { Text("≤\($0)%").tag($0) }
                    }
                    Picker(
                        language.text("7 天提醒线", "Weekly alert threshold"),
                        selection: Binding(
                            get: { store.lowQuotaAlertThresholds.sevenDay },
                            set: { store.setLowQuotaAlertThresholds(fiveHour: store.lowQuotaAlertThresholds.fiveHour, sevenDay: $0) }
                        )
                    ) {
                        ForEach(LowQuotaAlertThresholds.choices, id: \.self) { Text("<\($0)%").tag($0) }
                    }
                }
                .pickerStyle(.menu)
                Text(language.text("只调整提醒时间；候选额度、状态核验及提醒间隔保持不变。", "Changes when alerts trigger. Candidate limits, status checks and alert intervals stay unchanged."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    safetyRule(
                        language.text(
                            "官方 5 小时剩余 ≤\(store.lowQuotaAlertThresholds.fiveHour)%，或 7 天剩余严格低于 \(store.lowQuotaAlertThresholds.sevenDay)%",
                            "5h remaining at \(store.lowQuotaAlertThresholds.fiveHour)% or less, or weekly remaining below \(store.lowQuotaAlertThresholds.sevenDay)%."))
                    safetyRule(language.text("实时任务状态已连接、数据新鲜，且没有运行或等待输入的任务", "Requires fresh task status with no running tasks or pending input."))
                    safetyRule(language.text("按已保存快照推荐参与提醒且对应窗口至少剩余 30% 的账号", "Suggests opted-in accounts with at least 30% in the affected window, based on saved snapshots."))
                    safetyRule(language.text("推荐只显示候选；请回到账号卡手动启动 CLI 并执行 Hub 门禁", "Suggestions do not start work. Open CLI from the account card; Hub checks still apply."))
                }

                Label(
                    language.text("只发送低额度提醒与账号推荐；不再自动改写 ~/.codex 身份。", "Sends alerts and suggestions only. Never switches your Codex sign-in automatically."),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            Label(language.text("提醒策略", "Alert policy"), systemImage: "bell.badge")
                .font(.headline)
        }
    }

    private var localNotificationsGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("额度与重置提醒", "Limit and reset notifications"))
                            .font(.subheadline.weight(.semibold))
                        Text(language.text("默认开启；完成 macOS 授权后接收提醒", "On by default. Allow macOS permission to receive alerts."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isRequestingLocalNotificationPermission {
                        ProgressView().controlSize(.small)
                    }
                    Toggle(
                        language.text("系统通知", "System notifications"),
                        isOn: Binding(
                            get: { store.localNotificationsEnabled },
                            set: { store.setLocalNotificationsEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(store.isRequestingLocalNotificationPermission || store.pausedAutomationFeatures.contains(.localNotification))
                }
                Text(
                    language.text(
                        "显示额度与公开重置消息，不包含账号资料；显示方式由 macOS 通知与专注模式决定。",
                        "Shows quota and public reset updates without account details. macOS notification and Focus settings control presentation.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if store.localNotificationsEnabled && !store.localNotificationAuthorizationReady {
                    Button(
                        store.localNotificationUsesSystemSettings
                            ? language.text("打开通知设置", "Open notification settings") : language.text("允许系统通知", "Allow notifications")
                    ) { store.configureLocalNotifications() }
                    .disabled(store.isRequestingLocalNotificationPermission || store.pausedAutomationFeatures.contains(.localNotification))
                }
                if let message = store.localNotificationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label(language.text("macOS 通知", "macOS notifications"), systemImage: "bell")
                .font(.headline)
        }
    }

    private var feishuGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            store.feishuWebhookConfigured
                                ? language.text("飞书已连接", "Feishu connected")
                                : (store.feishuNeedsAuthorization ? language.text("需要钥匙串授权", "Keychain permission needed") : language.text("待配置飞书机器人", "Feishu bot setup needed"))
                        )
                        .font(.subheadline.weight(.semibold))
                        Text(language.text("地址只保存在 macOS 钥匙串；不会写入设置、日志或仓库", "Stored only in macOS Keychain, never in settings, logs or the repository."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        language.text("飞书通知", "Feishu notifications"),
                        isOn: Binding(
                            get: { store.feishuNotificationsEnabled },
                            set: { store.setFeishuNotificationsEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(store.pausedAutomationFeatures.contains(.feishu))
                }

                Toggle(
                    language.text("额度重置提醒", "Limit reset alerts"),
                    isOn: Binding(
                        get: { store.feishuQuotaResetEnabled }, set: { store.setFeishuQuotaResetEnabled($0) }
                    )
                )
                .disabled(store.pausedAutomationFeatures.contains(.feishu))

                Toggle(
                    language.text("获得 Reset 卡提醒", "New reset credit alerts"),
                    isOn: Binding(
                        get: { store.feishuResetCreditEnabled }, set: { store.setFeishuResetCreditEnabled($0) }
                    )
                )
                .disabled(store.pausedAutomationFeatures.contains(.feishu))

                Toggle(
                    language.text("任务完成提醒", "Task completion alerts"),
                    isOn: Binding(
                        get: { store.feishuTaskCompletionNotificationsEnabled },
                        set: { store.setFeishuTaskCompletionNotificationsEnabled($0) }
                    )
                )
                .disabled(store.pausedAutomationFeatures.contains(.feishu))

                Text(
                    language.text(
                        "三个选项默认开启。额度重置与 Reset 卡提醒约每分钟读取官方状态，确认额度恢复或可用 Reset 次数增加时提醒。Codex 对话完成后发送任务提醒。首次同步不补发历史消息，Reset 卡由你手动使用。",
                        "All three are on by default. Limit reset and reset credit alerts check the official state about once a minute and notify on restored limits or new reset credits. Task alerts notify you when a Codex conversation completes. Initial sync sends no past events. Reset credits are used manually."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                FeishuMessageOptionsView(
                    options: Binding(
                        get: { store.feishuMessageOptions },
                        set: { store.setFeishuMessageOptions($0) }
                    ),
                    disabled: store.pausedAutomationFeatures.contains(.feishu)
                )

                DisclosureGroup(language.text("飞书发送记录", "Feishu delivery details")) {
                    PublicResetAnnouncementView(monitor: store.publicResetAnnouncements, paused: store.pausedAutomationFeatures.contains(.feishu), deliveryDetailsOnly: true)
                }

                SecureField("https://open.feishu.cn/open-apis/bot/v2/hook/…", text: $webhookDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(language.text("飞书机器人 Webhook", "Feishu bot webhook"))

                Text(
                    language.text(
                        "首次连接时由 macOS 请求电脑登录密码。如系统提供“始终允许”，选择后可记住授权；升级后可能需要重新授权。后台不会弹窗。",
                        "macOS may ask for your login password when connecting. Choose Always Allow, if offered, to remember access. An update may require authorization again. Background checks stay silent."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button(language.text("保存并连接", "Save and connect")) {
                        let submitted = webhookDraft
                        store.saveFeishuWebhook(submitted) { saved in
                            if saved, webhookDraft == submitted { webhookDraft = "" }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isUpdatingFeishuConnection)

                    if store.feishuNeedsAuthorization {
                        Button(language.text("授权连接", "Authorize connection"), action: store.authorizeFeishuConnection)
                            .disabled(store.isUpdatingFeishuConnection)
                    }

                    if store.isUpdatingFeishuConnection { ProgressView().controlSize(.small) }

                    Button(language.text("发送测试", "Send test notification")) {
                        store.sendFeishuTestNotification()
                    }
                    .disabled(!store.feishuWebhookConfigured || store.isUpdatingFeishuConnection)

                    Spacer()

                    if store.feishuWebhookConfigured || store.feishuNeedsAuthorization {
                        Button(language.text("移除 Webhook", "Remove webhook"), role: .destructive) {
                            isConfirmingWebhookRemoval = true
                        }
                        .disabled(store.isUpdatingFeishuConnection)
                    }
                }

                if let message = store.feishuNotificationMessage {
                    Label(message, systemImage: "paperplane")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                }
            }
            .padding(4)
        } label: {
            Label(language.text("飞书通知", "Feishu notifications"), systemImage: "paperplane.fill")
                .font(.headline)
        }
    }

    private var auditGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if store.automationEvents.isEmpty {
                    Label(language.text("尚无自动化事件", "No automation events yet"), systemImage: "clock.badge.checkmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
                } else {
                    ForEach(Array(store.automationEvents.prefix(12).enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider().padding(.leading, 30) }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: auditIcon(for: event.level))
                                .foregroundStyle(auditColor(for: event.level))
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(event.title)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(language.dateTime(event.occurredAt))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(event.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(4)
        } label: {
            Label(language.text("最近事件", "Recent events"), systemImage: "list.bullet.clipboard")
                .font(.headline)
        }
    }

    private func automationMetric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func safetyRule(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func auditIcon(for level: AccountAutomationEvent.Level) -> String {
        switch level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func auditColor(for level: AccountAutomationEvent.Level) -> Color {
        switch level {
        case .info: return .accentColor
        case .success: return FixedVisualPalette.statusSuccessForeground(colorScheme)
        case .warning: return FixedVisualPalette.statusWarningForeground(colorScheme)
        case .failure: return FixedVisualPalette.statusDangerForeground(colorScheme)
        }
    }
}

struct CodexAccountMenuView: View {
    enum Screen: Equatable {
        case home
        case accounts
        case runningTasks
        case usageDetails
        case settings

        var floatingScreen: AccountFloatingPanelScreen {
            switch self {
            case .home: return .overview
            case .accounts: return .accounts
            case .runningTasks: return .runningTasks
            case .usageDetails: return .usageDetails
            case .settings: return .settings
            }
        }

        init(_ screen: AccountFloatingPanelScreen) {
            switch screen {
            case .overview: self = .home
            case .accounts: self = .accounts
            case .runningTasks: self = .runningTasks
            case .usageDetails: self = .usageDetails
            case .settings: self = .settings
            }
        }
    }

    static let preferredSize = CGSize(width: 380, height: 550)
    static let compactSize = CGSize(width: 380, height: 64)

    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var updateStore: AppUpdateStore
    let paletteCatalog: PaletteCatalog
    let openFullWindow: () -> Void
    let openPaletteLibrary: () -> Void
    let quit: () -> Void
    let initialSettingsPage: SettingsPage
    let isFloatingPanel: Bool
    let onOpenFloatingPanel: (Screen) -> Void
    let onClose: () -> Void
    let onTogglePinned: () -> Void
    @ObservedObject var panelModel: AccountFloatingPanelModel
    private var language: WidgetLanguage { settings.language }

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditingAccounts = false
    @State private var profilePendingDeletion: CodexProfile?
    @StateObject private var hubTaskStatusModel = HubAccountTaskStatusModel()
    @StateObject private var localCLIAccounts: LocalCLIAccountStore

    init(
        store: UsageStore,
        settings: AppSettings,
        updateStore: AppUpdateStore,
        paletteCatalog: PaletteCatalog,
        initialScreen: Screen = .home,
        initialSettingsPage: SettingsPage = .appearance,
        panelModel: AccountFloatingPanelModel? = nil,
        isFloatingPanel: Bool = false,
        localCLIAccounts: LocalCLIAccountStore? = nil,
        openFullWindow: @escaping () -> Void,
        openPaletteLibrary: @escaping () -> Void,
        quit: @escaping () -> Void,
        onOpenFloatingPanel: @escaping (Screen) -> Void = { _ in },
        onClose: @escaping () -> Void = {},
        onTogglePinned: @escaping () -> Void = {}
    ) {
        self.store = store
        self.settings = settings
        self.updateStore = updateStore
        self.paletteCatalog = paletteCatalog
        self.openFullWindow = openFullWindow
        self.openPaletteLibrary = openPaletteLibrary
        self.quit = quit
        self.initialSettingsPage = initialSettingsPage
        self.isFloatingPanel = isFloatingPanel
        self.onOpenFloatingPanel = onOpenFloatingPanel
        self.onClose = onClose
        self.onTogglePinned = onTogglePinned
        self.panelModel = panelModel ?? AccountFloatingPanelModel(screen: initialScreen.floatingScreen)
        _localCLIAccounts = StateObject(wrappedValue: localCLIAccounts ?? LocalCLIAccountStore())
    }

    private var screen: Screen { Screen(panelModel.screen) }

    private var colorScheme: ColorScheme {
        if let preferred = settings.themeMode.preferredColorScheme { return preferred }
        if settings.paletteID == PaletteCatalog.defaultPaletteID { return .dark }
        if settings.paletteID == "codexu.liquid-keycap" { return .light }
        return systemColorScheme
    }

    private var selectedProfile: CodexProfile? {
        menuPresentation.isSingleAccount ? menuPresentation.focusedProfile : store.selectedMonitorProfile
    }

    private var visibleProfiles: [CodexProfile] {
        // A linked system profile is the same recorded account as its managed
        // profile. Keep the existing de-duplication while retaining every
        // independently added and unverified profile.
        store.profiles.filter { linkedManagedProfile(for: $0) == nil }
    }

    private func hubTaskStatus(for profile: CodexProfile) -> HubAccountTaskStatus {
        hubTaskStatusModel.status(
            forAccountAlias: store.accountTaskAlias(for: profile),
            accountKey: profile.lastSnapshot?.email.map { DispatchActivityStore.hash($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        )
    }

    var body: some View {
        Group {
            if isFloatingPanel && panelModel.isCollapsed {
                compactStatusStrip
            } else {
                ZStack {
                    menuBackdrop
                    VStack(spacing: 0) {
                        if screen == .settings {
                            NextSettingsHeader(language: settings.language) { changeScreen(.home) }
                        } else {
                            header
                        }
                        compactUsageOverview
                        Group {
                            switch screen {
                            case .home:
                                ScrollView(showsIndicators: false) { home }
                            case .accounts:
                                accounts
                            case .runningTasks:
                                runningTasks
                            case .usageDetails:
                                usageDetails
                            case .settings:
                                settingsView
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        footerMenu
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isFloatingPanel && screen == .settings {
                        floatingWindowControls
                            .padding(.top, 10)
                            .padding(.trailing, 14)
                    }
                }
            }
        }
        .frame(
            width: Self.preferredSize.width,
            height: isFloatingPanel && panelModel.isCollapsed ? Self.compactSize.height : Self.preferredSize.height
        )
        .overlay(alignment: .bottom) {
            if !panelModel.isCollapsed && store.isAwaitingCodexHistoryConfirmation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text("请在 Codex 检查旧消息", "Check older messages in Codex"))
                        .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 8) {
                        Button(text("历史完整", "History Complete")) {
                            store.confirmRestoredCodexHistory()
                        }
                        .buttonStyle(AccountGlassButtonStyle(tint: .accentColor, foreground: .white, compact: true))
                        Button(text("回滚原账号", "Roll Back")) {
                            store.rejectRestoredCodexHistory()
                        }
                        .buttonStyle(AccountGlassButtonStyle(tint: .red, foreground: .white, compact: true))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(12)
            }
        }
        .environment(\.colorScheme, colorScheme)
        .appVisualEnvironment(
            catalog: paletteCatalog,
            paletteID: settings.paletteID,
            appearance: PaletteAppearance(colorScheme)
        )
        .preferredColorScheme(colorScheme)
        .onAppear {
            if !store.isPreview {
                hubTaskStatusModel.startPolling()
                localCLIAccounts.discover()
            }
        }
        .onDisappear { hubTaskStatusModel.stopPolling() }
        .alert(
            store.forcedAccountSwitchProfileID == nil ? language.text("未切换账号", "Account not switched") : language.text("强制切换账号？", "Force account switch?"),
            isPresented: Binding(
                get: { store.accountSwitchAlertMessage != nil },
                set: { if !$0 { store.dismissAccountSwitchAlert() } }
            )
        ) {
            if store.forcedAccountSwitchProfileID != nil {
                Button(language.text("强制切换", "Force switch"), role: .destructive) {
                    store.confirmForcedAccountSwitch()
                }
            }
            Button(store.forcedAccountSwitchProfileID == nil ? language.text("知道了", "OK") : language.text("取消", "Cancel"), role: .cancel) {
                store.dismissAccountSwitchAlert()
            }
        } message: {
            Text(store.accountSwitchAlertMessage ?? "")
        }
        .alert(item: $profilePendingDeletion) { profile in
            Alert(
                title: Text(
                    text("删除“\(AccountDisplay.profileName(profile, allProfiles: store.profiles))”？", "Delete \(AccountDisplay.profileName(profile, allProfiles: store.profiles))?")),
                message: Text(text("账号及本机登录资料会移到废纸篓，不会删除你的 OpenAI 账号。", "Local login data will move to Trash. Your OpenAI account will not be deleted.")),
                primaryButton: .destructive(Text(text("删除账号", "Delete Account"))) {
                    guard !hubTaskStatus(for: profile).blocksLocalCLI else { return }
                    store.deleteProfile(profile.id)
                },
                secondaryButton: .cancel(Text(text("取消", "Cancel")))
            )
        }
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
    }

    private var compactStatusStrip: some View {
        Button {
            panelModel.isCollapsed = false
        } label: {
            HStack(spacing: 10) {
                avatar(for: selectedProfile, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedProfile.map { AccountDisplay.profileName($0, allProfiles: store.profiles) } ?? text("账号浮窗", "Account panel"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(menuQuota.readSucceeded ? FixedVisualPalette.statusSuccess : Color.secondary)
                            .frame(width: 5, height: 5)
                        Text(menuQuota.sevenDay.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 14)
            .frame(width: Self.compactSize.width, height: Self.compactSize.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
        .accessibilityLabel(text("展开账号浮窗", "Expand account panel"))
    }

    private var floatingWindowControls: some View {
        HStack(spacing: 5) {
            Button(action: onTogglePinned) {
                Image(systemName: panelModel.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(AccountMenuIconButtonStyle())
            .help(text(panelModel.isPinned ? "取消置顶" : "置顶浮窗", panelModel.isPinned ? "Unpin panel" : "Pin panel"))
            Button {
                panelModel.isCollapsed = true
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(AccountMenuIconButtonStyle())
            .help(text("收起浮窗", "Collapse panel"))
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(AccountMenuIconButtonStyle())
            .help(text("关闭浮窗（Esc）", "Close panel (Esc)"))
        }
    }

    private var footerMenu: some View {
        HStack(spacing: 2) {
            footerTab(.home, title: text("总览", "Overview"), icon: "rectangle.grid.2x2")
            footerTab(.accounts, title: text("账号", "Accounts"), icon: "person.2")
            footerTab(.runningTasks, title: text("任务", "Tasks"), icon: "checklist", badge: pendingTaskCount)
            footerTab(.usageDetails, title: text("用量", "Usage"), icon: "chart.xyaxis.line")
            footerTab(.settings, title: text("设置", "Settings"), icon: "gearshape")
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text("菜单栏导航", "Menu bar navigation"))
    }

    private func footerTab(_ target: Screen, title: String, icon: String, badge: Int = 0) -> some View {
        Button {
            changeScreen(target)
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: screen == target ? .semibold : .medium))
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .offset(x: 8, y: -6)
                    }
                }
                Text(title)
                    .font(.system(size: 9, weight: screen == target ? .semibold : .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(screen == target ? Color.accentColor : Color.secondary)
        .accessibilityLabel(title)
        .accessibilityAddTraits(screen == target ? .isSelected : [])
    }

    private var currentScreenTitle: String {
        switch screen {
        case .home: return text("总览", "Overview")
        case .accounts: return text("账号与额度", "Accounts & Quota")
        case .runningTasks: return text("运行任务", "Running Tasks")
        case .usageDetails: return text("用量明细", "Usage Details")
        case .settings: return text("设置", "Settings")
        }
    }

    private var pendingTaskCount: Int {
        TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: store.runtimeSnapshots,
            codexLiveTasks: store.codexLiveTasks
        ).needsAttentionCount
    }

    private var selectedUsageTotal: Int64? {
        let local = store.multiRuntimeSnapshot.aggregate.local
        let detailed = local?.detailedUsage
        return AccountFloatingPanelStateStore.usageRangeValue(
            today: detailed?.today.tokens.visibleTotalTokens
                ?? local?.allAgentsTodayTokens
                ?? local?.todayTokens,
            sevenDays: detailed?.sevenDay.tokens.visibleTotalTokens
                ?? local?.sevenDayTokens,
            allTime: detailed?.lifetime.tokens.visibleTotalTokens
                ?? local?.allAgentsLifetimeTokens
                ?? local?.lifetimeTokens,
            range: panelModel.usageRange
        )
    }

    private var compactUsageOverview: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            menuLabeledMetric(
                title: panelModel.usageRange.title(language: language),
                value: language.tokens(selectedUsageTotal),
                alignment: .leading
            )
            Spacer(minLength: 4)
            menuLabeledMetric(
                title: text("待处理", "Needs action"),
                value: "\(pendingTaskCount)",
                alignment: .center
            )
            menuLabeledMetric(
                title: text("7 天剩余", "7-day left"),
                value: menuQuota.sevenDay.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--",
                alignment: .trailing
            )
        }
        .padding(.horizontal, 15)
        .frame(height: 38)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func menuLabeledMetric(title: String, value: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var menuBackdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black.opacity(backdropOpacity + 0.18), Color.black.opacity(backdropOpacity)]
                    : [Color.white.opacity(backdropOpacity + 0.24), Color.white.opacity(backdropOpacity + 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            if screen == .settings {
                colorScheme == .dark
                    ? Color(red: 0.085, green: 0.095, blue: 0.12)
                    : Color(red: 0.97, green: 0.98, blue: 0.99)
            }
        }
        .ignoresSafeArea()
    }

    private var backdropOpacity: Double {
        if reduceTransparency { return colorScheme == .dark ? 0.82 : 0.90 }
        switch settings.accountMenuTransparency {
        case .clear: return 0.03
        case .standard: return 0.14
        case .frosted: return 0.30
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            if screen == .home {
                avatar(for: selectedProfile, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedProfile.map { AccountDisplay.profileName($0, allProfiles: store.profiles) } ?? text("未选择账号", "No Account"))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(menuQuota.readSucceeded ? FixedVisualPalette.statusSuccess : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(
                            menuQuota.readSucceeded
                                ? text("官方额度已连接 · \(planName)", "Official quota connected · \(planName)")
                                : text("等待官方额度", "Waiting for official quota"))
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    changeScreen(.home)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                Text(currentScreenTitle)
                    .font(.system(size: 17, weight: .semibold))
            }

            Spacer(minLength: 8)

            if screen == .home {
                Button {
                    store.refreshQuotas()
                } label: {
                    Image(systemName: store.isRefreshing ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .disabled(store.isRefreshing)
                .help(text("刷新额度", "Refresh quota"))

                Button {
                    changeScreen(.accounts)
                } label: {
                    Image(systemName: "person.2")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .help(text("管理账号", "Manage accounts"))

                Button {
                    changeScreen(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .help(text("设置", "Settings"))
            } else if screen == .accounts {
                Button(isEditingAccounts ? text("完成", "Done") : text("编辑", "Edit")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        if !isEditingAccounts {
                            panelModel.accountFilter = .all
                        }
                        isEditingAccounts.toggle()
                    }
                }
                .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))

                Button {
                    store.addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .disabled(store.isLoggingIn)
                .help(text("添加账号", "Add account"))
            }

            if isFloatingPanel {
                Button(action: onTogglePinned) {
                    Image(systemName: panelModel.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .help(text(panelModel.isPinned ? "取消置顶" : "置顶浮窗", panelModel.isPinned ? "Unpin panel" : "Pin panel"))
                Button {
                    panelModel.isCollapsed = true
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .help(text("收起浮窗", "Collapse panel"))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .help(text("关闭浮窗（Esc）", "Close panel (Esc)"))
            } else {
                Button {
                    onOpenFloatingPanel(screen)
                } label: {
                    Image(systemName: "pin")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .help(text("固定到桌面", "Pin to desktop"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
        }
    }

    private var home: some View {
        VStack(spacing: 10) {
            if menuPresentation.isSingleAccount {
                TokenTotalsHeader(
                    layout: .compact,
                    language: language,
                    combinedTokensTotal: combinedTokensTotal,
                    combinedEquivalentCostUSD: combinedEquivalentCostUSD,
                    officialAccountsLifetimeTokens: officialAccountsTotal,
                    localAllAgentsLifetimeTokens: localAllAgentsTokens
                )
                HStack(spacing: 18) {
                    QuotaDetailTile(title: text("5 小时剩余", "5-hour remaining"), icon: "timer", window: menuQuota.fiveHour, prominent: true)
                    QuotaDetailTile(title: text("7 天剩余", "7-day remaining"), icon: "calendar", window: menuQuota.sevenDay, prominent: true)
                }
                .padding(16)
                .cardBackground(cornerRadius: 18)
            } else {
                tokenHero
            }
            HStack(spacing: 10) {
                statTile(
                    title: text("今日消耗", "Today"),
                    value: language.tokens(
                        store.snapshot.local?.allAgentsTodayTokens
                            ?? store.snapshot.local?.todayTokens
                    ),
                    tint: FixedVisualPalette.statusSuccessForeground(colorScheme)
                )
                statTile(
                    title: text("会员有效期", "Membership"),
                    value: membershipSummary,
                    tint: membershipIsLow
                        ? FixedVisualPalette.statusDangerForeground(colorScheme)
                        : FixedVisualPalette.statusSuccessForeground(colorScheme)
                )
            }

            if menuPresentation.isSingleAccount {
                singleAccountActions
                HStack {
                    Text(text("官方累计", "Official total"))
                    Spacer()
                    Text(language.tokens(officialAccountsTotal))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                Spacer(minLength: 0)
            } else {
                homeAccountList
            }

            if let message = store.accountManagerMessage {
                Label(message, systemImage: "info.circle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(text("打开完整窗口", "Open Full Window")) { openFullWindow() }
                .buttonStyle(AccountGlassButtonStyle(tint: .accentColor, foreground: .white))
        }
        .padding(12)
    }

    private var menuPresentation: WorkspacePresentation {
        WorkspacePresentation(profiles: store.profiles, selectedProfileID: store.selectedMonitorProfileID)
    }

    private var menuQuota: (fiveHour: RateWindow?, sevenDay: RateWindow?, readSucceeded: Bool) {
        menuPresentation.quotaSummary(monitored: store.snapshot)
    }

    @ViewBuilder
    private var singleAccountActions: some View {
        if let profile = menuPresentation.focusedProfile, !profile.isSystemProfile {
            let status = hubTaskStatus(for: profile)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(text("下一次任务", "Next task")).font(.caption.weight(.semibold))
                    Spacer()
                    HubCLITaskStatusBadge(status: status)
                }
                ExecutionPreferenceControl(preference: profile.effectiveExecutionPreference, allowsApplyToAll: false) { preference, applyToAll in
                    store.setExecutionPreference(preference, for: profile.id, applyToAll: applyToAll)
                }
                Button {
                    store.openTerminal(for: profile.id, workingDirectory: nil)
                } label: {
                    Label(text("在终端中使用", "Open in Terminal"), systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(status.blocksLocalCLI || store.isLoggingIn || store.isLaunchingCodex)
                if status.blocksLocalCLI {
                    Text(
                        status.blockingReason(language)
                            ?? text("确认账号空闲后才能开始；不会重复占用。", "Waiting for confirmed availability; no overlapping tasks.")
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .cardBackground(cornerRadius: 18)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label(text("当前账号 · 只读监控", "Current account · read-only"), systemImage: "checkmark.shield")
                    .font(.caption.weight(.semibold))
                Text(
                    text("无需添加其他账号。设置独立 CLI 后，可选择 Astra 等任务模型，当前 Codex 身份不变。", "No second account required. Set up an isolated CLI to choose task models without switching Codex.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(text("设置独立 CLI", "Set Up Isolated CLI")) { store.addProfile() }
                    .buttonStyle(.bordered)
                    .disabled(store.isLoggingIn)
            }
            .padding(14)
            .cardBackground(cornerRadius: 18)
        }
    }

    private var homeAccountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(text("账号", "Accounts"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(text("\(visibleProfiles.count) 个常用", "\(visibleProfiles.count) saved"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ScrollView(showsIndicators: visibleProfiles.count > 4) {
                LazyVStack(spacing: 8) {
                    ForEach(visibleProfiles) { profile in
                        homeProfileRow(profile)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 2)
        .frame(maxHeight: .infinity)
    }

    private var runningTasks: some View {
        let presentation = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: store.runtimeSnapshots,
            codexLiveTasks: store.codexLiveTasks
        )
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(text("待处理", "Needs action"), systemImage: "exclamationmark.circle")
                Text("\(presentation.needsAttentionCount)")
                    .monospacedDigit()
                    .foregroundStyle(presentation.needsAttentionCount > 0 ? .orange : .secondary)
                Spacer()
                Text(text("运行 \(presentation.runningCount)", "\(presentation.runningCount) running"))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if presentation.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: presentation.dataState == .available ? "checkmark.circle" : "questionmark.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(
                        presentation.dataState == .available
                            ? text("暂无待处理任务", "No tasks need attention")
                            : text("任务状态暂不可确认", "Task status cannot be confirmed yet")
                    )
                    .font(.callout.weight(.medium))
                    Text(text("这里不会创建或调度新任务。", "This view never creates or schedules tasks."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(presentation.items) { item in
                            Button {
                                store.requestTaskFocus(scope: item.runtimeScope, threadID: item.threadID)
                                openFullWindow()
                            } label: {
                                HStack(spacing: 9) {
                                    Circle()
                                        .fill(taskStateColor(item.state))
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text(taskStateTitle(item.state))
                                            .font(.system(size: 9.5, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                                .accountMenuCard()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            Button(action: openFullWindow) {
                Label(text("打开工作台", "Open Workspace"), systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AccountGlassButtonStyle(tint: .accentColor, foreground: .white))
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private var usageDetails: some View {
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(AccountFloatingUsageRange.allCases) { range in
                    Button {
                        panelModel.usageRange = range
                    } label: {
                        Text(range.title(language: language))
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                panelModel.usageRange == range
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(panelModel.usageRange == range ? .isSelected : [])
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 11)

            VStack(alignment: .leading, spacing: 5) {
                Text(text("本机用量", "Local usage"))
                    .font(.system(size: 11, weight: .semibold))
                Text(language.tokens(selectedUsageTotal))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                Text(
                    text(
                        "所选周期只影响本机用量；不改变官方额度窗口",
                        "The selected period affects local usage only; official quota windows are unchanged"
                    )
                )
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .accountMenuCard(highlighted: true)
            .padding(.horizontal, 13)
            .padding(.top, 11)

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(store.multiRuntimeSnapshot.runtimes) { runtime in
                        usageRuntimeRow(runtime, range: panelModel.usageRange)
                    }
                    if store.multiRuntimeSnapshot.runtimes.isEmpty {
                        Text(text("暂无可用平台用量快照", "No platform usage snapshot is available"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
            }
        }
    }

    private func usageRuntimeRow(_ runtime: RuntimeUsageSnapshot, range: AccountFloatingUsageRange) -> some View {
        let local = runtime.snapshot.local
        let detailed = local?.detailedUsage
        let value = AccountFloatingPanelStateStore.usageRangeValue(
            today: detailed?.today.tokens.visibleTotalTokens ?? local?.todayTokens,
            sevenDays: detailed?.sevenDay.tokens.visibleTotalTokens ?? local?.sevenDayTokens,
            allTime: detailed?.lifetime.tokens.visibleTotalTokens ?? local?.lifetimeTokens,
            range: range
        )
        return HStack(spacing: 9) {
            Image(systemName: runtime.scope == .codex ? "sparkles" : "terminal")
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.displayName)
                    .font(.system(size: 11, weight: .semibold))
                Text(runtime.status.localized(language))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 5)
            Text(language.tokens(value))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .accountMenuCard()
    }

    private func taskStateTitle(_ state: TaskOverviewItemState) -> String {
        TaskStatusCopy.label(state, language)
    }

    private func taskStateColor(_ state: TaskOverviewItemState) -> Color {
        TaskStatusCopy.color(state)
    }

    private var localAllAgentsTokens: Int64? {
        store.localAllAgentsLifetimeTokens
    }

    private var combinedTokensTotal: Int64? {
        let official = officialAccountsTotal ?? 0
        let local = localAllAgentsTokens ?? 0
        guard official > 0 || local > 0 else { return nil }
        return official + local
    }

    private var combinedEquivalentCostUSD: Double? {
        guard let combinedTokensTotal,
            let localTokens = store.snapshot.local?.detailedUsage?.lifetime.tokens
        else { return nil }
        return estimatedSolProEquivalentCostUSD(
            officialTotalTokens: combinedTokensTotal,
            localTokens: localTokens
        )
    }

    private var tokenHero: some View {
        let sevenDayRemaining = store.snapshot.sevenDayQuota?.remainingPercent
        return VStack(alignment: .leading, spacing: 9) {
            TokenTotalsHeader(
                layout: .hero,
                language: language,
                combinedTokensTotal: combinedTokensTotal,
                combinedEquivalentCostUSD: combinedEquivalentCostUSD,
                officialAccountsLifetimeTokens: officialAccountsTotal,
                localAllAgentsLifetimeTokens: localAllAgentsTokens
            )
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(text("7 天剩余", "7-day left"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(resetSummary(store.snapshot.sevenDayQuota?.resetsAt))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(sevenDayRemaining.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            AccountSemanticQuotaTrack(percent: sevenDayRemaining, height: 6)
        }
        .padding(15)
        .accountMenuCard(highlighted: true)
    }

    private func statTile(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .accountMenuCard()
    }

    private func homeProfileRow(_ profile: CodexProfile) -> some View {
        let remaining = sevenDayRemaining(for: profile)
        let cliTaskStatus = hubTaskStatusModel.status(
            forAccountAlias: store.accountTaskAlias(for: profile),
            accountKey: profile.lastSnapshot?.email.map { DispatchActivityStore.hash($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        )
        return HStack(spacing: 6) {
            Button {
                if profile.id != store.selectedMonitorProfileID {
                    store.selectMonitorProfile(profile.id)
                }
            } label: {
                HStack(spacing: 10) {
                    avatar(for: profile, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if let dispatchCode = DispatchCodeCatalog.code(for: profile.id, allowsLocalRead: !store.isPreview) {
                                DispatchCodeBadge(code: dispatchCode)
                            }
                            Text(AccountDisplay.profileName(profile, allProfiles: store.profiles))
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            if let availableResetCredits = store.availableResetCredits(for: profile) {
                                Label(language.text("可用 \(availableResetCredits)", "\(availableResetCredits) resets"), systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(FixedVisualPalette.statusSuccessForeground(colorScheme))
                                    .help(text("官方返回的当前可用重置卡数量", "Available reset credits returned by Codex"))
                            }
                            if profile.id == store.selectedMonitorProfileID {
                                Circle().fill(FixedVisualPalette.statusSuccess).frame(width: 6, height: 6)
                            }
                            HubCLITaskStatusBadge(status: cliTaskStatus, compact: true)
                        }
                        AccountSemanticQuotaTrack(percent: remaining, height: 6)
                    }
                    Text(remaining.map { "\(Int($0.rounded()))%" } ?? "--")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                text("切换监控账号到 \(AccountDisplay.profileName(profile, allProfiles: store.profiles))", "Monitor \(AccountDisplay.profileName(profile, allProfiles: store.profiles))"))

            Button {
                store.openTerminal(for: profile.id, workingDirectory: nil)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(AccountGlassButtonStyle(tint: .accentColor, foreground: .white, compact: true))
            .disabled(profile.isSystemProfile || profile.lastSnapshot == nil || cliTaskStatus.blocksLocalCLI)
            .help(
                cliTaskStatus.blocksLocalCLI
                    ? (cliTaskStatus.blockingReason(language)
                        ?? language.text(
                            "缺少可信映射、Hub 概览不新鲜或同账号有活跃任务",
                            "Blocked: missing account mapping, stale Hub status or an active task."))
                    : text("在终端中使用", "Use in Terminal")
            )
            .accessibilityLabel(text("在终端中使用", "Use in Terminal"))
            .padding(.trailing, 7)
        }
        .accountMenuCard(highlighted: profile.id == store.selectedMonitorProfileID)
    }

    private var accounts: some View {
        VStack(spacing: 10) {
            Picker(text("账号筛选", "Account filter"), selection: $panelModel.accountFilter) {
                Text(text("全部账号", "All accounts")).tag(AccountFloatingAccountFilter.all)
                Text(text("当前监控账号", "Monitored account")).tag(AccountFloatingAccountFilter.selected)
            }
            .pickerStyle(.segmented)
            .font(.system(size: 10))

            Text(text("切换监控只改变本面板数据；启动前会再次验证账号身份。", "Monitoring changes this panel only; identity is verified again before launch."))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .accountMenuCard()

            ScrollView(showsIndicators: true) {
                LazyVStack(spacing: 9) {
                    ForEach(filteredVisibleProfiles) { profile in
                        accountCard(profile)
                    }
                    if !isFilteringMonitoredAccount {
                        ForEach(LocalCLIKind.allCases) { kind in
                            ForEach(localCLIAccounts.profiles(for: kind)) { profile in
                                localAccountCard(profile)
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
            }

            if let message = store.accountManagerMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 9) {
                if store.isLoggingIn {
                    Button(text("取消登录", "Cancel Login")) {
                        store.cancelLogin()
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary))
                }
                Button(text("打开完整窗口", "Open Full Window")) { openFullWindow() }
                    .buttonStyle(AccountGlassButtonStyle(tint: .accentColor, foreground: .white))
            }
        }
        .padding(14)
    }

    private var isFilteringMonitoredAccount: Bool {
        panelModel.accountFilter == .selected
            && visibleProfiles.contains(where: { $0.id == store.selectedMonitorProfileID })
    }

    private var filteredVisibleProfiles: [CodexProfile] {
        let ids = Set(
            AccountFloatingPanelStateStore.filteredIDs(
                allIDs: visibleProfiles.map(\.id),
                selectedID: store.selectedMonitorProfileID,
                filter: panelModel.accountFilter
            )
        )
        return visibleProfiles.filter { ids.contains($0.id) }
    }

    private func localAccountCard(_ profile: LocalCLIProfile) -> some View {
        let result = localCLIAccounts.quotas[profile.id]
        let status = localAccountStatus(profile, result: result)
        let windows = result?.windows.prefix(3) ?? []
        let needsLogin: Bool
        switch result?.state {
        case .needsLogin, .none: needsLogin = true
        case .available, .unsupported, .rateLimited, .unavailable: needsLogin = false
        }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.13))
                    Image(systemName: "terminal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(profile.kind.displayName)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(profile.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(result?.maskedIdentity ?? text("等待账号核验", "Waiting for account verification"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 5)
            }

            HStack(spacing: 8) {
                if windows.isEmpty {
                    Text(text("额度未知", "Quota unknown"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(windows), id: \.id) { window in
                        HStack(spacing: 3) {
                            Text(window.label)
                                .foregroundStyle(.secondary)
                            Text("\(Int(max(0, min(100, 100 - window.usedPercent)).rounded()))%")
                                .monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9.5, weight: .semibold))

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(result?.planLabel ?? text("模型待核验", "Model not verified"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(status)
                    .foregroundStyle(localAccountStatusColor(result?.state))
                    .lineLimit(1)
            }
            .font(.system(size: 9.5, weight: .semibold))

            HStack(spacing: 7) {
                if needsLogin {
                    Button(text("登录", "Sign in")) {
                        guard !store.isPreview else { return }
                        localCLIAccounts.signIn(profile)
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .accentColor, foreground: .white, compact: true))
                    .disabled(!localCLIAccounts.canSignIn(profile) || !localCLIAccounts.signingIn.isEmpty)
                }
                Button(text("详情", "Details")) { openFullWindow() }
                    .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))
                Button {
                    guard !store.isPreview else { return }
                    localCLIAccounts.refresh(profile)
                } label: {
                    Image(systemName: localCLIAccounts.refreshing.contains(profile.id) ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))
                .disabled(localCLIAccounts.refreshing.contains(profile.id))
                .accessibilityLabel(text("刷新额度", "Refresh quota"))
            }
        }
        .padding(11)
        .accountMenuCard()
    }

    private func localAccountStatus(_ profile: LocalCLIProfile, result: LocalCLIQuotaResult?) -> String {
        if localCLIAccounts.signingIn.contains(profile.id) {
            return text("登录中…", "Signing in…")
        }
        if localCLIAccounts.refreshing.contains(profile.id), result == nil {
            return text("读取中…", "Reading…")
        }
        guard let result else { return text("待核验", "Needs verification") }
        if localCLIAccounts.stale.contains(profile.id) {
            return text("快照过期", "Stale snapshot")
        }
        switch result.state {
        case .available: return text("已连接", "Connected")
        case .needsLogin: return text("待登录", "Needs sign-in")
        case .unsupported: return text("未支持", "Unsupported")
        case .rateLimited: return text("暂时限流", "Rate limited")
        case .unavailable: return text("不可用", "Unavailable")
        }
    }

    private func localAccountStatusColor(_ state: LocalCLIQuotaState?) -> Color {
        switch state {
        case .available: return FixedVisualPalette.statusSuccessForeground(colorScheme)
        case .needsLogin, .rateLimited: return FixedVisualPalette.statusWarningForeground(colorScheme)
        case .unsupported, .unavailable, .none: return .secondary
        }
    }

    private func accountCard(_ profile: CodexProfile) -> some View {
        let remaining = sevenDayRemaining(for: profile)
        let isCurrent = isCurrentCodexAccount(profile)
        let cliTaskStatus = hubTaskStatusModel.status(
            forAccountAlias: store.accountTaskAlias(for: profile),
            accountKey: profile.lastSnapshot?.email.map { DispatchActivityStore.hash($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        )
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                avatar(for: profile, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if let dispatchCode = DispatchCodeCatalog.code(for: profile.id, allowsLocalRead: !store.isPreview) {
                            DispatchCodeBadge(code: dispatchCode)
                        }
                        Text(AccountDisplay.profileName(profile, allProfiles: store.profiles))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if let availableResetCredits = store.availableResetCredits(for: profile) {
                            Label(language.text("可用 \(availableResetCredits)", "\(availableResetCredits) resets"), systemImage: "arrow.counterclockwise")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(FixedVisualPalette.statusSuccessForeground(colorScheme))
                                .help(text("官方返回的当前可用重置卡数量", "Available reset credits returned by Codex"))
                        }
                        if profile.id == store.selectedMonitorProfileID {
                            Text(text("监控中", "Monitoring"))
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(
                        profile.lastSnapshot.map {
                            text("更新于 ", "Updated ") + language.dateTime($0.fetchedAt)
                        } ?? text("等待账号验证", "Waiting for verification")
                    )
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            AccountSemanticQuotaTrack(percent: remaining, height: 7)

            HStack(spacing: 8) {
                profileQuotaWindowLabel(
                    title: text("5 小时", "5h"),
                    window: profileFiveHourWindow(profile)
                )
                profileQuotaWindowLabel(
                    title: text("7 天", "7d"),
                    window: profileSevenDayWindow(profile)
                )
                profileQuotaWindowLabel(
                    title: text("月", "Month"),
                    window: profileMonthlyWindow(profile)
                )
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(profile.effectiveExecutionPreference.model.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                HubCLITaskStatusBadge(status: cliTaskStatus, compact: true)
            }
            .font(.system(size: 9.5, weight: .semibold))

            HStack(spacing: 7) {
                if isEditingAccounts {
                    Button(text("重新登录", "Log In Again")) {
                        guard !cliTaskStatus.blocksLocalCLI else { return }
                        store.loginProfile(profile.id)
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .accentColor, foreground: .white, compact: true))
                    .disabled(store.isLoggingIn || store.isLaunchingCodex || cliTaskStatus.blocksLocalCLI)
                    .help(
                        cliTaskStatus.blocksLocalCLI
                            ? (cliTaskStatus.blockingReason(language)
                                ?? text(
                                    "Hub 状态未确认或同账号有活跃任务，暂不能重新登录",
                                    "Hub status is unverified or this account has an active task; login is disabled"))
                            : text("重新登录此账号", "Log in to this account again"))
                    Button {
                        moveProfile(profile, offset: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))
                    .disabled(adjacentProfile(to: profile, offset: -1) == nil)
                    .help(text("上移账号", "Move account up"))
                    .accessibilityLabel(text("上移账号", "Move account up"))

                    Button {
                        moveProfile(profile, offset: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))
                    .disabled(adjacentProfile(to: profile, offset: 1) == nil)
                    .help(text("下移账号", "Move account down"))
                    .accessibilityLabel(text("下移账号", "Move account down"))
                    if !profile.isSystemProfile {
                        Button(role: .destructive) {
                            profilePendingDeletion = profile
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(AccountGlassButtonStyle(tint: .red, foreground: .white, compact: true))
                        .disabled(store.isLaunchingCodex || cliTaskStatus.blocksLocalCLI)
                        .help(
                            cliTaskStatus.blocksLocalCLI
                                ? (cliTaskStatus.blockingReason(language)
                                    ?? text(
                                        "Hub 状态未确认或同账号有活跃任务，暂不能删除",
                                        "Hub status is unverified or this account has an active task; deletion is disabled"))
                                : text("删除账号", "Delete account")
                        )
                        .accessibilityLabel(text("删除账号", "Delete account"))
                    }
                } else {
                    Button(profile.id == store.selectedMonitorProfileID ? text("已监控", "Monitoring") : text("监控", "Monitor")) {
                        store.selectMonitorProfile(profile.id)
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))
                    .disabled(profile.id == store.selectedMonitorProfileID)

                    Button(isCurrent ? text("当前账号", "Current Account") : text("切换 Desktop 到此账号…", "Switch Desktop to Account…")) {
                        guard !cliTaskStatus.blocksLocalCLI else { return }
                        store.launchCodex(with: profile.id)
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .accentColor, foreground: .white, compact: true))
                    .disabled(store.isLaunchingCodex || isCurrent || cliTaskStatus.blocksLocalCLI)
                    .help(
                        cliTaskStatus.blocksLocalCLI
                            ? (cliTaskStatus.blockingReason(language)
                                ?? text(
                                    "Hub 状态未确认或同账号有活跃任务，暂不能切换 Desktop",
                                    "Hub status is unverified or this account has an active task; Desktop switching is disabled"))
                            : text("切换 Desktop 到此账号", "Switch Desktop to this account"))
                }
            }
        }
        .padding(11)
        .accountMenuCard(highlighted: profile.id == store.selectedMonitorProfileID)
    }

    private func profileQuotaWindowLabel(title: String, window: RateWindow?) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(window.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--")
                .monospacedDigit()
        }
        .font(.system(size: 9.5, weight: .semibold))
        .lineLimit(1)
    }

    private func profileFiveHourWindow(_ profile: CodexProfile) -> RateWindow? {
        if profile.id == store.selectedMonitorProfileID, store.snapshot.quotaReadSucceeded {
            return QuotaAvailabilityPresentation.fiveHourWindow(
                store.snapshot.fiveHourQuota,
                sevenDay: store.snapshot.sevenDayQuota
            )
        }
        let five = profile.lastSnapshot?.fiveHour.map {
            RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt)
        }
        let seven = profileSevenDayWindow(profile)
        return QuotaAvailabilityPresentation.fiveHourWindow(five, sevenDay: seven)
    }

    private func profileSevenDayWindow(_ profile: CodexProfile) -> RateWindow? {
        if profile.id == store.selectedMonitorProfileID, store.snapshot.quotaReadSucceeded {
            return store.snapshot.sevenDayQuota
        }
        return profile.lastSnapshot?.sevenDay.map {
            RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt)
        }
    }

    private func profileMonthlyWindow(_ profile: CodexProfile) -> RateWindow? {
        if profile.id == store.selectedMonitorProfileID, store.snapshot.quotaReadSucceeded {
            return store.snapshot.monthlyQuota
        }
        return profile.lastSnapshot?.monthly.map {
            RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt)
        }
    }

    private var settingsView: some View {
        VStack(spacing: 0) {
            SettingsPanelView(
                settings: settings,
                store: store,
                updateStore: updateStore,
                onOpenPaletteLibrary: openPaletteLibrary,
                compact: true,
                showsHeader: false,
                initialPage: initialSettingsPage
            )
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                Button {
                    openFullWindow()
                } label: {
                    Label(text("打开工作台", "Open workspace"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    quit()
                } label: {
                    Label(text("退出 AiGoodBro", "Quit AiGoodBro"), systemImage: "power")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                    .padding(.horizontal, 20)
            }
        }
    }

    private func avatar(for profile: CodexProfile?, size: CGFloat) -> some View {
        let title = profile.map { AccountDisplay.profileName($0) } ?? ""
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.accentColor.opacity(0.13))
            if let first = title.first, !first.isASCII {
                Text(String(first)).font(.system(size: size * 0.52))
            } else {
                Image(systemName: profile?.isSystemProfile == true ? "house.fill" : "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var planName: String {
        AccountDisplay.planLabel(selectedProfile, fallbackPlan: store.snapshot.account?.planType ?? "PLUS")
    }

    private var officialAccountsTotal: Int64? {
        store.officialAccountsLifetimeTokens
    }

    private var membershipDate: Date? {
        selectedProfile?.officialProfile?.subscriptionActiveUntil
    }

    private var membershipDays: Int? {
        guard let membershipDate else { return nil }
        return Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: membershipDate)
        ).day
    }

    private var membershipSummary: String {
        guard let membershipDays else { return "--" }
        return membershipDays >= 0
            ? text("还有 \(membershipDays) 天", "\(membershipDays) days left")
            : text("日期待刷新", "Date pending refresh")
    }

    private var membershipIsLow: Bool {
        membershipDays.map { $0 >= 0 && $0 <= 7 } ?? false
    }

    private func resetSummary(_ date: Date?) -> String {
        guard let date else { return text("官方未返回窗口重置时间", "Window reset time unavailable") }
        return text("\(language.dateTime(date)) 窗口重置", "Window resets \(language.dateTime(date))")
    }

    private func sevenDayRemaining(for profile: CodexProfile) -> Double? {
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.sevenDayQuota?.remainingPercent
        }
        return profile.lastSnapshot?.sevenDay.map { max(0, min(100, 100 - $0.usedPercent)) }
    }

    private func linkedManagedProfile(for profile: CodexProfile) -> CodexProfile? {
        guard profile.isSystemProfile else { return nil }
        return CodexProfile.groupsByRecordedAccount(store.profiles)
            .first { $0.contains(where: { $0.id == profile.id }) }?
            .first { !$0.isSystemProfile }
    }

    private func isCurrentCodexAccount(_ profile: CodexProfile) -> Bool {
        guard
            let group = CodexProfile.groupsByRecordedAccount(store.profiles)
                .first(where: { $0.contains(where: { $0.id == profile.id }) })
        else { return false }
        return profile.isSystemProfile
            ? !group.contains(where: { !$0.isSystemProfile })
            : group.contains(where: { $0.isSystemProfile })
    }

    private func adjacentProfile(to profile: CodexProfile, offset: Int) -> CodexProfile? {
        guard let index = visibleProfiles.firstIndex(where: { $0.id == profile.id }) else { return nil }
        let targetIndex = index + offset
        guard visibleProfiles.indices.contains(targetIndex) else { return nil }
        return visibleProfiles[targetIndex]
    }

    private func moveProfile(_ profile: CodexProfile, offset: Int) {
        guard let target = adjacentProfile(to: profile, offset: offset) else { return }
        store.moveProfile(profile.id, relativeTo: target.id, before: offset < 0)
    }

    private func changeScreen(_ target: Screen) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            panelModel.screen = target.floatingScreen
        }
    }

    private func text(_ zh: String, _ en: String) -> String {
        settings.language.text(zh, en)
    }
}

private struct AccountSemanticQuotaTrack: View {
    @Environment(\.widgetLanguage) private var language
    let percent: Double?
    var height: CGFloat = 8

    private var colors: [Color] {
        let colors = RemainingQuotaHealth.classify(percent).colors
        return [Color(nsColor: colors.start), Color(nsColor: colors.end)]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(max(0, min(100, percent ?? 0)) / 100))
            }
        }
        .frame(height: height)
        .accessibilityLabel(language.text("剩余额度", "Remaining limit"))
        .accessibilityValue(percent.map { "\(Int($0.rounded()))%" } ?? language.text("未知", "Unknown"))
    }
}

private struct AccountMenuIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 29, height: 29)
            .background(.thinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct AccountGlassButtonStyle: ButtonStyle {
    let tint: Color
    let foreground: Color
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(minWidth: compact ? 52 : 0, minHeight: compact ? 26 : 34)
            .padding(.horizontal, compact ? 8 : 10)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(tint == .clear ? Color.primary.opacity(0.06) : tint.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .strokeBorder(
                        tint == .clear ? Color.primary.opacity(0.12) : Color.white.opacity(0.16),
                        lineWidth: 0.7
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct AccountMenuCardModifier: ViewModifier {
    let highlighted: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(reduceTransparency ? 0.12 : (highlighted ? 0.09 : 0.045))
                        : Color.white.opacity(reduceTransparency ? 0.92 : (highlighted ? 0.68 : 0.42))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            highlighted ? Color.accentColor.opacity(0.38) : Color.primary.opacity(contrast == .increased ? 0.24 : 0.10),
                            lineWidth: highlighted ? 1 : 0.6
                        )
                )
        )
    }
}

private extension View {
    func accountMenuCard(highlighted: Bool = false) -> some View {
        modifier(AccountMenuCardModifier(highlighted: highlighted))
    }
}

private struct QuotaDetailTile: View {
    @Environment(\.widgetLanguage) private var language
    let title: String
    let icon: String
    let window: RateWindow?
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 9 : 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if !prominent {
                    Text(QuotaAvailabilityPresentation.percentText(window?.remainingPercent))
                        .font(.caption.weight(.bold).monospacedDigit())
                }
            }
            if prominent {
                Text(QuotaAvailabilityPresentation.percentText(window?.remainingPercent))
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(window == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            QuotaProgressTrack(percent: window?.remainingPercent)
            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(prominent ? 2 : 1)
                .minimumScaleFactor(prominent ? 0.85 : 1)
                .fixedSize(horizontal: false, vertical: true)
                .help(resetHelp)
        }
        .padding(.horizontal, prominent ? 0 : 10)
        .padding(.vertical, prominent ? 0 : 7)
        .background(RoundedRectangle(cornerRadius: 11).fill(FixedVisualPalette.surfaceTrack.opacity(prominent ? 0 : 0.72)))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(resetHelp)
    }

    private var resetText: String {
        guard let reset = window?.resetsAt else { return language.text("官方未返回窗口重置时间", "Window reset time not reported") }
        let absolute = language.dateTime(reset)
        if prominent {
            return language.text("窗口重置 \(absolute)", "Window resets \(absolute)")
        }
        return language.text("窗口重置：\(absolute)（\(resetRelative(reset))）", "Window resets \(absolute) (\(resetRelative(reset)))")
    }

    private var resetHelp: String {
        guard let reset = window?.resetsAt else { return language.text("官方未返回窗口重置时间", "Window reset time not reported") }
        let absolute = language.dateTime(reset)
        return language.text("窗口重置 \(absolute)（\(resetRelative(reset))）", "Window resets \(absolute) (\(resetRelative(reset)))")
    }

    private func resetRelative(_ reset: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        return formatter.localizedString(for: reset, relativeTo: Date())
    }
}

struct QuotaProgressTrack: View {
    @Environment(\.widgetLanguage) private var language
    let percent: Double?

    private var colors: [Color] {
        let colors = RemainingQuotaHealth.classify(percent).colors
        return [Color(nsColor: colors.start), Color(nsColor: colors.end)]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(FixedVisualPalette.surfaceTrack)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(max(0, min(100, percent ?? 0)) / 100))
            }
        }
        .frame(height: 8)
        .accessibilityLabel(language.text("剩余额度", "Remaining limit"))
        .accessibilityValue(percent.map { "\(Int($0.rounded()))%" } ?? language.text("未知", "Unknown"))
    }
}

/// Keep the latest warm-up result visible; omit only duplicate future schedules.
enum WarmUpStatusText {
    static let criticalPhrases = [
        "7 天额度不足", "额度读取失败", "登录已失效", "暖号失败", "请求超时", "网络失败",
        "登录失效", "无权访问", "频率受限", "官方服务异常", "官方返回失败", "响应未完成",
        "weekly limit low", "Limit refresh failed", "Sign-in expired", "warm-up failed", "Request timed out",
        "Network error", "Access denied", "Rate limited", "Service error", "Request failed", "Incomplete response",
    ]

    static func attributed(_ status: String) -> AttributedString {
        var text = AttributedString(status)
        for phrase in criticalPhrases {
            var start = text.startIndex
            while let range = text[start...].range(of: phrase) {
                text[range].foregroundColor = FixedVisualPalette.statusDanger
                text[range].font = .caption2.weight(.semibold)
                start = range.upperBound
            }
        }
        return text
    }

    static func summary(_ status: String, fiveHourReset: Date?, sevenDayReset: Date?, language: WidgetLanguage = .zh) -> String? {
        let duplicateSchedules = [(language.text("5 小时", "5h"), fiveHourReset), (language.text("7 天", "7d"), sevenDayReset)].compactMap { label, date in
            date.map { language.text("下次暖号 \(label) ", "Next \(label) warm-up ") + language.dateTime($0) }
        }
        let parts = status.components(separatedBy: " · ").filter {
            !duplicateSchedules.contains($0)
        }
        let summary = parts.joined(separator: " · ")
        return summary.isEmpty ? nil : summary
    }
}

/// Vertical slots shared by native account cards. These are deliberately small
/// layout contracts rather than a generic card framework: both Codex and local
/// provider cards can keep the same footer baselines while optional content is
/// absent, and real content can still grow beyond the minimum.
enum AccountCardFooterSlots {
    static let preferenceRow: CGFloat = 24
    static let firstActionRow: CGFloat = 24
    static let secondaryRow: CGFloat = 24
    static let timestamp: CGFloat = 16
    static let resetSummary: CGFloat = 18
}

private struct ProfileRow: View {
    @Environment(\.widgetLanguage) private var language
    let profile: CodexProfile
    let allProfiles: [CodexProfile]
    let executionPreference: CodexExecutionPreference
    let dispatchCode: String?
    let cliTaskStatus: HubAccountTaskStatus
    let isMonitoring: Bool
    let isLaunchProfile: Bool
    let isDuplicateAccount: Bool
    let isCurrentCodexAccount: Bool
    let linkedAccountName: String?
    let participatesInAutomaticSwitch: Bool
    let prioritizesDispatch: Bool
    let isEditing: Bool
    let layout: AccountWorkspaceLayout
    let isLoggingIn: Bool
    let isLaunching: Bool
    var isSwitchTarget: Bool = false
    let isRefreshingStatistics: Bool
    let isRefreshingProfile: Bool
    let isWarmingProfile: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let quotaReadSucceeded: Bool
    let fiveHourRemainingPercent: Double?
    let fiveHourResetsAt: Date?
    let remainingPercent: Double?
    let resetsAt: Date?
    let currentDate: Date
    let warmUpStatus: String?
    let creditBalance: CreditBalancePresentation
    let allowsResetCreditAction: Bool
    let hubAccountAlias: String?
    let availableResetCredits: Int?
    let resetCreditExpiries: [Date]
    let resetCardsExpiring: Bool
    let localResetHistoryCount: Int
    let chromeProfiles: [ChromeProfileBinding]
    let onMonitor: () -> Void
    let onRefresh: () -> Void
    let onWarmUp: () -> Void
    let onRelogin: () -> Void
    let onLaunch: () -> Void
    let onOpenTerminal: (URL?) -> Void
    let onCopyTerminalCommand: () -> Void
    let onSetAutomaticSwitchParticipation: (Bool) -> Void
    let onSetDispatchPriority: (Bool) -> Void
    let onSetDispatchParticipationWindow: (DispatchParticipationWindow) -> Bool
    let onSetProTierMultiplier: (Int?) -> Void
    let onSetExecutionPreference: (CodexExecutionPreference, Bool) -> Void
    let onRename: (String) -> Void
    let onSetChromeProfile: (ChromeProfileBinding?) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onBeginReorder: () -> Bool
    let onMoveReorder: (CGPoint) -> Void
    let onDropReorder: (CGPoint) -> Void
    let onEndReorder: () -> Void
    let onDelete: () -> Void
    let onAdjustResetCount: (Int) -> Void
    @State private var isEditingRemark = false
    @State private var isConfirmingDelete = false
    @State private var remarkDraft = ""
    @State private var isShowingDetails = false
    @State private var isEditingDispatchWindow = false
    @State private var dispatchWindowDraft = DispatchParticipationWindow()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let resetReminder = SevenDayResetReminder.message(resetsAt: resetsAt, now: currentDate, language: language)
        let cardExpiring = resetCardsExpiring
        VStack(alignment: .leading, spacing: layout == .cards ? 6 : 8) {
            if layout == .cards {
                identitySummary
                quotaSummary.padding(.vertical, 2)
                Spacer(minLength: 0)
                cardFooter
            } else {
                HStack(alignment: .top, spacing: 16) {
                    identitySummary
                        .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                    quotaSummary.frame(width: 168, alignment: .leading)
                    primaryControls.frame(width: 290, alignment: .trailing)
                }
            }
            if isEditing {
                Divider().opacity(0.55)
                ScrollView(.horizontal, showsIndicators: true) { editControls }
            }
        }
        .padding(.horizontal, layout == .cards ? 10 : 12)
        .padding(.vertical, 10)
        .cardBackground(cornerRadius: layout == .cards ? 14 : 12, elevated: isMonitoring)
        .overlay(
            RoundedRectangle(cornerRadius: layout == .cards ? 14 : 12, style: .continuous)
                .strokeBorder(resetReminder == nil && !cardExpiring ? Color.clear : FixedVisualPalette.statusDanger, lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .accessibilityElement(children: .contain)
        .alert(language.text("修改账号备注", "Edit account label"), isPresented: $isEditingRemark) {
            TextField(language.text("例如：工作账号", "For example: Work"), text: $remarkDraft)
            Button(language.text("取消", "Cancel"), role: .cancel) {}
            Button(language.text("保存", "Save")) { onRename(remarkDraft) }
        } message: {
            Text(language.text("最多 40 个字符；留空会恢复脱敏账号名。", "Up to 40 characters. Leave blank to use the masked account name."))
        }
    }

    /// The card footer has the same rows as LocalCLIWorkspaceView's embedded
    /// cards. Empty timestamp space is intentional: local CLI results expose a
    /// fetched-at time while Codex exposes the official reset summary instead.
    /// Both remain aligned when either optional value is absent.
    private var cardFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().opacity(0.4)
            cardPreferenceRow
                .frame(minHeight: AccountCardFooterSlots.preferenceRow, alignment: .leading)
            cardActionRow
                .frame(minHeight: AccountCardFooterSlots.firstActionRow, alignment: .leading)
            dispatchControls
                .frame(minHeight: AccountCardFooterSlots.secondaryRow, alignment: .leading)
            Color.clear
                .frame(maxWidth: .infinity, minHeight: AccountCardFooterSlots.timestamp)
                .accessibilityHidden(true)
            officialResetSummary
                .frame(minHeight: AccountCardFooterSlots.resetSummary, alignment: .topLeading)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var officialResetSummary: some View {
        let evidence = profile.officialResetHistory?.confirmed(
            profileID: profile.id, accountID: profile.lastSnapshot?.accountID, now: currentDate)
        let value = evidence.map { language.dateTime($0.occurredAt) + " · " + $0.kind.rawValue } ?? "-"
        return Text(language.text("上次官方重置：", "Last official reset: ") + value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileAvatar: some View {
        Image(systemName: profile.isSystemProfile ? "house.fill" : "person.crop.circle")
            .font(.system(size: 16, weight: .medium))
            .frame(width: 20, height: 20)
            .foregroundStyle(isMonitoring ? Color.accentColor : Color.secondary)
            .accessibilityHidden(true)
    }

    private var identitySummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                profileAvatar
                if let dispatchCode {
                    DispatchCodeBadge(code: dispatchCode)
                }
                Text(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .help(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                Label(planBadge.name, systemImage: planBadge.icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .accessibilityLabel(language.text("\(planBadge.name) 套餐", "\(planBadge.name) plan"))
                Spacer(minLength: 0)
                if isEditing { identityEditButtons }
                if isEditing && layout == .cards { reorderHandle }
            }
            HStack(spacing: 5) {
                if isMonitoring && (layout != .cards || !isCurrentCodexAccount) {
                    Text(language.text("监控", "Monitor")).profileBadge().help(language.text("正在监控此账号", "This account is being monitored"))
                }
                if isLaunchProfile && (layout != .cards || !isCurrentCodexAccount) {
                    Text(language.text("启动", layout == .cards ? "Launch" : "Launch target")).profileBadge().help(
                        language.text("当前选定的 Desktop 启动账号", "Selected account for Desktop launch"))
                }
                HubCLITaskStatusBadge(status: cliTaskStatus)
                    .fixedSize()
                if linkedAccountName != nil {
                    Text(language.text("待独立登录", "Sign-in needed"))
                        .profileBadge()
                        .help(language.text("这张账号卡尚未保存独立登录；当前 Codex 登录不会被修改", "This profile needs its own sign-in. Your current Codex sign-in stays unchanged."))
                } else if isCurrentCodexAccount {
                    Text(language.text("当前 Codex", "Current Codex")).profileBadge()
                } else if isDuplicateAccount {
                    Text(language.text("同一账号", "Same account"))
                        .profileBadge()
                        .help(language.text("这个 CODEX_HOME 与列表中的另一个入口登录了同一账号", "This profile uses the same account as another entry in the list."))
                }
                Button(language.text("详情", "Details")) { isShowingDetails = true }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel(language.text("账号资料与暖号详情", "Account and warm-up details"))
                    .popover(isPresented: $isShowingDetails) { accountDetails }
            }
            ProfileSnapshotNotice(profile: profile)
            if linkedAccountName == nil, let activeUntil = profile.officialProfile?.subscriptionActiveUntil,
                membershipRemainingDays(activeUntil) <= 7
            {
                Text(membershipDetail(activeUntil))
                    .font(.caption2)
                    .foregroundStyle(membershipTint(activeUntil))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warmUpStatus,
                let summary = WarmUpStatusText.summary(warmUpStatus, fiveHourReset: fiveHourResetsAt, sevenDayReset: resetsAt, language: language)
            {
                let compactSummary =
                    layout == .cards
                    ? WarmUpStatusText.criticalPhrases.first(where: { summary.contains($0) }) ?? summary : summary
                Text(WarmUpStatusText.attributed(compactSummary))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(layout == .cards ? 1 : nil)
                    .help(summary)
            }
            resetCreditSummary
            if allowsResetCreditAction, isMonitoring {
                ResetCreditButton(
                    profile: profile,
                    selectedProfileID: profile.id,
                    hubAccountAlias: hubAccountAlias,
                    onConfirmedResult: onRefresh
                )
                .controlSize(.small)
            }
            if linkedAccountName == nil, creditBalance.value != .unavailable {
                CreditBalanceView(presentation: creditBalance)
            }
            if layout != .cards { officialResetSummary }
            if let resetReminder = SevenDayResetReminder.message(resetsAt: resetsAt, now: currentDate, language: language) {
                Label(resetReminder, systemImage: "exclamationmark.circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(resetReminder)
            }
        }
    }

    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                .font(.headline)
            Text(
                linkedAccountName.map { language.text("本机 Codex 当前登录 \($0)；此卡尚未独立登录", "Codex is signed in as \($0). This profile still needs an isolated sign-in.") } ?? profile
                    .lastSnapshot.map {
                        language.text("更新于 ", "Updated ") + language.dateTime($0.fetchedAt)
                    } ?? language.text("等待账号验证", "Waiting for verification")
            )
            ProfileSnapshotNotice(profile: profile)
            resetCreditSummary
            CreditBalanceView(presentation: creditBalance)
            officialResetSummary
            if linkedAccountName == nil, let official = profile.officialProfile {
                Text(officialAccountDetail(official))
                if let activeUntil = official.subscriptionActiveUntil {
                    Text(membershipDetail(activeUntil))
                        .foregroundStyle(membershipTint(activeUntil))
                }
            }
            if let warmUpStatus {
                Divider()
                Text(WarmUpStatusText.attributed(warmUpStatus))
                Text(language.text("暖号成功表示最小请求已完成；额度窗口以官方刷新结果为准。", "Warm-up success means the minimal request completed; quota windows use the official refresh result."))
                    .foregroundStyle(.secondary)
                if let history = profile.warmUpHistory, history.count > 1 {
                    ForEach(Array(history.dropLast().suffix(4).reversed().enumerated()), id: \.offset) { _, attempt in
                        Text((attempt.succeeded ? language.text("暖号成功 ", "Warm-up succeeded ") : language.text("暖号失败 ", "Warm-up failed ")) + language.dateTime(attempt.at))
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private var identityEditButtons: some View {
        HStack(spacing: 7) {
            Button {
                remarkDraft = profile.remark ?? ""
                isEditingRemark = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(language.text("修改备注", "Edit label"))
            .accessibilityLabel(language.text("修改账号备注", "Edit account label"))
            if !profile.isSystemProfile {
                Button {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(
                    cliTaskStatus.blocksLocalCLI
                        ? (cliTaskStatus.blockingReason(language)
                            ?? language.text(
                                "Hub 状态未确认或同账号有活跃任务，暂不能删除账号",
                                "Removal is blocked while Hub status is unverified or this account has an active task."))
                        : language.text("删除账号", "Remove account")
                )
                .accessibilityLabel(language.text("删除账号", "Remove account"))
                .disabled(isLaunching || cliTaskStatus.blocksLocalCLI)
                .alert(
                    language.text(
                        "删除“\(AccountDisplay.profileName(profile, allProfiles: allProfiles))”？", "Remove \(AccountDisplay.profileName(profile, allProfiles: allProfiles))?"),
                    isPresented: $isConfirmingDelete
                ) {
                    Button(language.text("取消", "Cancel"), role: .cancel) {}
                    Button(language.text("删除账号", "Remove account"), role: .destructive) {
                        guard !cliTaskStatus.blocksLocalCLI else { return }
                        onDelete()
                    }
                } message: {
                    Text(language.text("账号及其本机登录资料会移到废纸篓，不会删除你的 OpenAI 账号。", "Moves this profile and its local sign-in data to Trash. Your OpenAI account is not deleted."))
                }
            }
        }
    }

    private var quotaSummary: some View {
        let quotaLayout =
            layout == .cards
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return quotaLayout {
            quotaWindow(
                title: layout == .cards ? language.text("5 小时", "5h") : language.text("5 小时剩余", "5h available"),
                remainingPercent: fiveHourRemainingPercent,
                resetsAt: fiveHourResetsAt,
                officialReadSucceeded: quotaReadSucceeded,
                prominent: layout == .cards,
                weeklyLimitExhausted: QuotaAvailabilityPresentation.isWeeklyExhausted(remainingPercent)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            quotaWindow(
                title: layout == .cards ? language.text("7 天", "7d") : language.text("7 天剩余", "7d remaining"),
                remainingPercent: remainingPercent,
                resetsAt: resetsAt,
                officialReadSucceeded: quotaReadSucceeded,
                prominent: layout == .cards
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resetCreditSummary: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .foregroundStyle(.secondary)
                Text(language.text("可用重置卡", "Reset cards"))
                    .foregroundStyle(.secondary)
                if let availableResetCredits {
                    Text(language.text("\(availableResetCredits) 次", "\(availableResetCredits)"))
                        .foregroundStyle(FixedVisualPalette.statusSuccessForeground(colorScheme))
                        .monospacedDigit()
                } else {
                    Text(quotaReadSucceeded ? language.text("官方未返回", "Not reported") : language.text("暂无", "Unknown"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .help(language.text("仅显示 Codex 官方返回的当前可用重置卡数量", "Available banked reset credits reported by Codex. This label does not redeem a credit."))
            .accessibilityElement(children: availableResetCredits == nil ? .contain : .ignore)
            .accessibilityLabel(
                availableResetCredits.map { language.text("可用重置卡 \($0) 次", "\($0) reset cards") }
                    ?? (quotaReadSucceeded ? language.text("官方未返回可用重置卡次数", "Reset-card count not reported") : language.text("可用重置卡次数未知", "Reset-card count unknown")))
            if (availableResetCredits ?? 0) > 0,
                let expiry = resetCreditExpiries.first
            {
                Text(language.text("到期 ", "Expires ") + language.dateTime(expiry))
                    .font(.caption2)
                    .foregroundStyle(expiry <= currentDate ? FixedVisualPalette.statusDanger : Color.secondary)
                    .lineLimit(1)
                    .help(language.text("重置卡最近到期 ", "Next reset credit expiry: ") + language.dateTime(expiry))
            }
        }
    }

    private func quotaWindow(
        title: String,
        remainingPercent: Double?,
        resetsAt: Date?,
        officialReadSucceeded: Bool,
        prominent: Bool = false,
        weeklyLimitExhausted: Bool = false
    ) -> some View {
        let windowUnavailable = remainingPercent == nil && resetsAt == nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(QuotaAvailabilityPresentation.percentText(remainingPercent))
                    .font(prominent ? .system(size: 23, weight: .semibold, design: .rounded).monospacedDigit() : .subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(remainingPercent == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: prominent ? 28 : nil, alignment: .bottom)
            }
            QuotaProgressTrack(percent: remainingPercent)
            Text(
                weeklyLimitExhausted
                    ? language.text("周额度已用尽", layout == .cards ? "Weekly limit reached" : "Weekly limit exhausted")
                    : resetsAt.map {
                        (layout == .cards ? "" : language.text("窗口重置 ", "Window resets ")) + language.dateTime($0)
                    } ?? (officialReadSucceeded && windowUnavailable ? language.text("此窗口未由官方返回", "Limit not reported") : language.text("官方窗口重置时间未知", "Window reset time unknown"))
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(resetsAt.map { language.text("官方窗口重置 ", "Reported window reset: ") + language.dateTime($0) } ?? language.text("官方窗口重置时间未知", "Window reset time unknown"))
        }
    }

    private var primaryControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            cardPreferenceRow
            cardActionRow
            dispatchControls
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardPreferenceRow: some View {
        HStack(spacing: 6) {
            if !profile.isSystemProfile {
                ExecutionPreferenceControl(
                    preference: executionPreference,
                    allowsApplyToAll: WorkspacePresentation(profiles: allProfiles, selectedProfileID: profile.id).managedAccountCount > 1,
                    compact: true,
                    onSave: onSetExecutionPreference
                )
            }
            Spacer(minLength: 0)
            if isEditing && layout == .rows { reorderHandle }
        }
    }

    private var cardActionRow: some View {
        HStack(spacing: 8) {
            refreshAndWarmUpControls
            terminalControls
                .fixedSize()
            monitorAndDesktopControls
        }
    }

    private var reorderHandle: some View {
        ProfileReorderHandle(
            isEnabled: !isLaunching && !isLoggingIn && (canMoveUp || canMoveDown),
            onBegin: onBeginReorder,
            onMove: onMoveReorder,
            onDrop: onDropReorder,
            onCancel: onEndReorder
        )
        .frame(width: 28, height: 24)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button(language.text("上移账号", "Move account up"), action: onMoveUp).disabled(!canMoveUp || isLaunching || isLoggingIn)
            Button(language.text("下移账号", "Move account down"), action: onMoveDown).disabled(!canMoveDown || isLaunching || isLoggingIn)
        }
        .accessibilityAction(named: Text(language.text("上移账号", "Move account up"))) {
            if canMoveUp && !isLaunching && !isLoggingIn { onMoveUp() }
        }
        .accessibilityAction(named: Text(language.text("下移账号", "Move account down"))) {
            if canMoveDown && !isLaunching && !isLoggingIn { onMoveDown() }
        }
    }

    private var refreshAndWarmUpControls: some View {
        HStack(spacing: 6) {
            Button(action: onRefresh) {
                HStack(spacing: 4) {
                    if isRefreshingProfile {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshingProfile || isWarmingProfile || isLoggingIn || isLaunching)
            .help(language.text("只刷新这个账号的额度、重置时间和快照", "Refresh this account's limits, reset times and snapshot. Does not send a warm-up request."))
            .accessibilityLabel(isRefreshingProfile ? language.text("正在刷新此账号", "Refreshing this account") : language.text("刷新此账号", "Refresh account"))

            Button(action: onWarmUp) {
                HStack(spacing: 4) {
                    if isWarmingProfile {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "bolt")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshingProfile || isWarmingProfile || isLoggingIn || isLaunching)
            .help(language.text("只为这个账号发送一次最小请求，完成后刷新额度", "Send one minimal request for this account, then refresh its limits. Uses quota; does not resume a task."))
            .accessibilityLabel(isWarmingProfile ? language.text("正在暖号此账号", "Warming up this account") : language.text("暖号此账号", "Warm up account"))
        }
    }

    private var dispatchControls: some View {
        HStack(spacing: layout == .cards ? 8 : 14) {
            Button {
                dispatchWindowDraft = profile.dispatchParticipationWindow ?? .init()
                isEditingDispatchWindow = true
            } label: {
                Image(systemName: "clock")
            }
            .buttonStyle(.plain)
            .help(language.text("设置参与调度时间段", "Set dispatch participation hours"))
            .popover(isPresented: $isEditingDispatchWindow) {
                DispatchParticipationWindowEditor(window: $dispatchWindowDraft) {
                    if onSetDispatchParticipationWindow(dispatchWindowDraft) { isEditingDispatchWindow = false }
                }
            }
            Toggle(
                isOn: Binding(
                    get: { participatesInAutomaticSwitch },
                    set: onSetAutomaticSwitchParticipation
                )
            ) {
                Text(language.text("参与调度", "In pool"))
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityValue(participatesInAutomaticSwitch ? language.text("已加入", "Included") : language.text("已排除", "Excluded"))
            .help(
                language.text(
                    "只控制派单与低额度推荐，同步 Hub 配置和账号编号；关闭后保留原编号，仍刷新额度、会员日期，并按全局开关执行 5 小时与 7 天暖号",
                    "Controls task assignment and low-limit suggestions; syncs Hub config and retains the pool code when excluded. Limit and subscription refresh, plus both warm-up windows, remain independent."
                )
            )
            .frame(maxWidth: .infinity)
            Toggle(
                isOn: Binding(
                    get: { prioritizesDispatch },
                    set: onSetDispatchPriority
                )
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.text("优先标记", "Priority"))
                        .font(.caption.weight(.semibold))
                    if layout != .cards {
                        Text(language.text("供 Skill 选号", "For Skill selection"))
                            .font(.system(size: 8))
                    }
                }
                .foregroundStyle(prioritizesDispatch ? Color.red : Color.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(prioritizesDispatch ? .red : .accentColor)
            .accessibilityLabel(language.text("优先标记，供 Skill 在门禁通过后选号使用", "Priority preference for Skill selection after eligibility checks."))
            .accessibilityValue(prioritizesDispatch ? language.text("已开启", "On") : language.text("已关闭", "Off"))
            .help(
                language.text(
                    "开启时同步加入调度并保存优先偏好；新版调度 Skill 在额度和占用门禁通过后优先选择。Hub 自主选号仍取决于其版本，指定账号不受排序覆盖。",
                    "Adds the account to the pool and saves its priority. The updated dispatch Skill honors it after quota and occupancy checks. Hub selection depends on its version; an explicit account choice is preserved."
                )
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var terminalControls: some View {
        let accountUnavailable = linkedAccountName != nil || profile.isSystemProfile || isLoggingIn
        let launchUnavailable = accountUnavailable || cliTaskStatus.blocksLocalCLI || isLaunching
        return HStack(spacing: 0) {
            Button {
                onOpenTerminal(nil)
            } label: {
                Label(language.text("终端", "CLI"), systemImage: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(minHeight: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("直接在终端中使用此账号", "Open CLI with this account directly"))
            .disabled(launchUnavailable)
            .help(
                cliTaskStatus.blocksLocalCLI
                    ? (cliTaskStatus.blockingReason(language)
                        ?? language.text(
                            "缺少可信映射、Hub 概览不新鲜或同账号有活跃任务",
                            "Blocked: missing account mapping, stale Hub status or an active task."))
                    : language.text("在终端中使用此账号", "Open CLI with this account"))

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)

            Menu {
                Button(language.text("以该账号打开 CLI（选择目录…）", "Open CLI in folder…")) { chooseDirectoryAndOpenTerminal() }
                    .disabled(cliTaskStatus.blocksLocalCLI || isLaunching || isLoggingIn)
                Button(language.text("复制一句话 CLI 调用命令", "Copy CLI launch command")) { onCopyTerminalCommand() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 25, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(accountUnavailable)
            .help(
                cliTaskStatus.blocksLocalCLI
                    ? language.text("更多终端选项；当前不能启动，但仍可复制命令", "More CLI options. Launch is blocked, but the command can still be copied.")
                    : language.text("选择目录或复制 CLI 命令", "Choose a folder or copy the CLI command")
            )
            .accessibilityLabel(language.text("终端更多选项", "More CLI options"))
        }
        .foregroundStyle(.white)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 0.8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var monitorAndDesktopControls: some View {
        HStack(spacing: 4) {
            if linkedAccountName != nil {
                Button {
                    guard !cliTaskStatus.blocksLocalCLI else { return }
                    onRelogin()
                } label: {
                    Label(isLoggingIn ? language.text("登录中…", "Signing in…") : language.text("登录", "Sign in"), systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isLoggingIn || isLaunching || isRefreshingStatistics || cliTaskStatus.blocksLocalCLI)
                .help(
                    cliTaskStatus.blocksLocalCLI
                        ? (cliTaskStatus.blockingReason(language)
                            ?? language.text(
                                "Hub 状态未确认或同账号有活跃任务，暂不能登录",
                                "Sign-in is blocked while Hub status is unverified or this account has an active task."))
                        : language.text("登录为独立账号，不修改当前 Codex 登录", "Sign in to this isolated profile without changing the current Codex sign-in."))
            } else {
                Button {
                    onMonitor()
                } label: {
                    Label(isMonitoring ? language.text("已监控", "Monitoring") : language.text("监控", "Monitor"), systemImage: isMonitoring ? "checkmark.circle.fill" : "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isMonitoring)
                .help(isMonitoring ? language.text("正在监控此账号", "This account is being monitored") : language.text("监控此账号", "Monitor this account without switching Desktop"))
            }

            Button {
                guard !cliTaskStatus.blocksLocalCLI else { return }
                onLaunch()
            } label: {
                if isSwitchTarget && isLaunching {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        .accessibilityLabel(language.text("正在切换到此账号", "Switching to this account"))
                } else {
                    Label(isCurrentCodexAccount ? language.text("当前账号", "Current account") : language.text("切换桌面", "Switch Desktop"), systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isLaunching || linkedAccountName != nil || isCurrentCodexAccount || cliTaskStatus.blocksLocalCLI)
            .help(
                cliTaskStatus.blocksLocalCLI
                    ? (cliTaskStatus.blockingReason(language)
                        ?? language.text(
                            "Hub 状态未确认或同账号有活跃任务，暂不能切换 Desktop",
                            "Desktop switching is blocked while Hub status is unverified or this account has an active task."))
                    : language.text("切换 Desktop 到此账号", "Switch Codex Desktop to this account"))
        }
        .labelStyle(.iconOnly)
    }

    private func chooseDirectoryAndOpenTerminal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = language.text("选择", "Choose")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        onOpenTerminal(directory)
    }

    private var editControls: some View {
        HStack(spacing: 10) {
            if linkedAccountName == nil {
                Button(isLoggingIn ? language.text("登录中…", "Signing in…") : language.text("重新登录", "Sign in again")) {
                    guard !cliTaskStatus.blocksLocalCLI else { return }
                    onRelogin()
                }
                .buttonStyle(.bordered)
                .disabled(isLoggingIn || isLaunching || cliTaskStatus.blocksLocalCLI)
                .help(
                    cliTaskStatus.blocksLocalCLI
                        ? (cliTaskStatus.blockingReason(language)
                            ?? language.text(
                                "Hub 状态未确认或同账号有活跃任务，暂不能重新登录",
                                "Sign-in is blocked while Hub status is unverified or this account has an active task."))
                        : language.text("重新登录此账号", "Sign in to this account again"))
            }
            if isProPlan {
                Picker(
                    language.text("Pro 档位", "Pro tier label"),
                    selection: Binding(
                        get: { profile.displayedProTierMultiplier },
                        set: onSetProTierMultiplier
                    )
                ) {
                    Text(language.text("未指定", "Not set")).tag(Int?.none)
                    Text("5x").tag(Int?.some(5))
                    Text("20x").tag(Int?.some(20))
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 132)
                .help(language.text("手动标记官方 Pro 档位；只影响显示，不参与额度或切换判断", "Manual Pro tier label for display only. Does not change limits or account selection."))
            }
            Menu {
                Button(language.text("自动匹配 / 账号专属", "Automatic / dedicated profile")) { onSetChromeProfile(nil) }
                if !chromeProfiles.isEmpty { Divider() }
                ForEach(chromeProfiles) { chromeProfile in
                    Button(chromeProfile.displayName) { onSetChromeProfile(chromeProfile) }
                }
            } label: {
                Label(profile.chromeProfile?.displayName ?? language.text("Chrome 专属", "Dedicated Chrome"), systemImage: "person.crop.circle")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(language.text("首次登录或重新认证时使用；平时切号不会打开浏览器", "Used for sign-in and reauthentication. Normal account switching does not open a browser."))

            Divider().frame(height: 24)
            Text(language.text("本地重置记录 \(localResetHistoryCount)", "Local reset records: \(localResetHistoryCount)"))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .help(language.text("本机检测与手工校正的本地重置记录，不代表当前可用重置卡", "Detected and manually adjusted local reset records. Not your available reset credit balance."))
            Button {
                onAdjustResetCount(-1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)
            .help(language.text("本地重置记录减一；不影响官方可用重置卡", "Subtract one from local reset records. Does not affect available reset cards."))
            .accessibilityLabel(language.text("本地重置记录减一", "Decrease local reset records"))
            .disabled(localResetHistoryCount <= 0)
            Button {
                onAdjustResetCount(1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .help(language.text("本地重置记录加一；不影响官方可用重置卡", "Add one to local reset records. Does not affect available reset cards."))
            .accessibilityLabel(language.text("本地重置记录加一", "Increase local reset records"))

        }
        .controlSize(.small)
    }

    private var planBadge: (name: String, icon: String) {
        if linkedAccountName != nil {
            return (language.text("未登录", "Signed out"), "person.crop.circle.badge.xmark")
        }
        return isProPlan
            ? (AccountDisplay.planLabel(profile, fallbackPlan: "PRO"), "crown.fill")
            : ("PLUS", "plus.circle.fill")
    }

    private var isProPlan: Bool {
        (profile.officialProfile?.planType ?? profile.lastSnapshot?.planType)?.lowercased() == "pro"
    }

    private func officialAccountDetail(_ official: CodexOfficialProfileSnapshot) -> String {
        var parts: [String] = []
        if let total = official.lifetimeTokens {
            parts.append(language.text("官方累计 \(language.tokens(total)) Token", "Reported total: \(language.tokens(total)) tokens"))
        }
        if let statsAsOf = official.statsAsOf {
            parts.append(language.text("统计至 ", "As of ") + statsAsOf.formatted(.dateTime.month().day().locale(language.locale)))
        }
        return parts.isEmpty ? language.text("官方账号资料已连接", "Account details connected") : parts.joined(separator: " · ")
    }

    private func membershipDetail(_ activeUntil: Date) -> String {
        let remainingDays = membershipRemainingDays(activeUntil)
        let date = activeUntil.formatted(.dateTime.month().day().locale(language.locale))
        if remainingDays >= 0 {
            return language.text("会员有效期还有 \(remainingDays) 天 · 至 \(date)", "Subscription: \(remainingDays) days left · until \(date)")
        }
        if let checkedAt = profile.lastMembershipRefreshAt, checkedAt >= activeUntil {
            return profile.lastMembershipRefreshSucceeded == true
                ? language.text("已核查，官方日期未更新 · 原记录至 \(date)", "Rechecked; no new subscription date · last reported until \(date)")
                : language.text("会员日期刷新失败，稍后重试 · 原记录至 \(date)", "Subscription date refresh failed; retrying later · last reported until \(date)")
        }
        return language.text("会员日期待刷新 · 原记录至 \(date)", "Subscription date needs refresh · last reported until \(date)")
    }

    private func membershipTint(_ activeUntil: Date) -> Color {
        let remainingDays = membershipRemainingDays(activeUntil)
        return remainingDays < 0 ? .orange : (remainingDays <= 7 ? .red : .secondary)
    }

    private func membershipRemainingDays(_ activeUntil: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: activeUntil)
        ).day ?? 0
    }
}

private struct ProfileSnapshotNotice: View {
    @Environment(\.widgetLanguage) private var language
    let profile: CodexProfile

    var body: some View {
        let health = AccountSnapshotHealth.classify(snapshotAt: profile.lastSnapshot?.fetchedAt, lastFailureAt: profile.lastQuotaReadFailureAt)
        if let notice = health.notice(language) {
            Label(notice, systemImage: "exclamationmark.circle")
                .font(.caption2.weight(.medium))
                .foregroundStyle(health == .failed ? FixedVisualPalette.statusDanger : FixedVisualPalette.statusWarning)
                .help(
                    language.text(
                        "刷新只读取官方额度，不会触发暖号；超过 30 分钟的快照仅供参考。", "Refresh reads usage limits without warming up the account. Snapshots older than 30 minutes are for reference only."))
        }
    }
}

enum DispatchCodeCatalog {
    private static let maximumCatalogBytes = 256 * 1_024
    private static var entries = load()

    static func reload() {
        entries = load()
    }

    private struct Entry {
        let code: String
        let alias: String
        let active: Bool
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let accounts: [Account]
    }

    private struct Account: Decodable {
        let code: String
        let alias: String
        let profileId: String
        let active: Bool?
    }

    static func code(for profileID: String, allowsLocalRead: Bool = true) -> String? {
        allowsLocalRead && entries[profileID]?.active == true ? entries[profileID]?.code : nil
    }

    static func alias(for profileID: String, allowsLocalRead: Bool = true) -> String? {
        allowsLocalRead ? entries[profileID]?.alias : nil
    }

    private static func load() -> [String: Entry] {
        guard
            let data = try? DispatchParticipationSync.readBoundedRegularFile(
                DispatchParticipationPaths.codesURL,
                maximumBytes: maximumCatalogBytes
            ),
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.schemaVersion == 1,
            payload.accounts.count <= DispatchParticipationSync.maximumCatalogEntries
        else { return [:] }

        var entries: [String: Entry] = [:]
        var claimedCodes = Set<String>()
        for account in payload.accounts {
            let profileID = account.profileId.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = account.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let alias = account.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profileID.isEmpty,
                !alias.isEmpty,
                profileID.utf8.count <= DispatchParticipationSync.maximumCatalogFieldBytes,
                alias.utf8.count <= DispatchParticipationSync.maximumCatalogFieldBytes,
                entries[profileID] == nil,
                code.unicodeScalars.count == 1,
                code.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) }),
                claimedCodes.insert(code).inserted
            else { continue }
            entries[profileID] = Entry(code: code, alias: alias, active: account.active != false)
        }
        return entries
    }
}

private struct DispatchCodeBadge: View {
    @Environment(\.widgetLanguage) private var language
    let code: String

    var body: some View {
        Text(code)
            .font(.caption2.weight(.black))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .accessibilityLabel(language.text("调度编号 \(code)", "Pool code \(code)"))
    }
}

private struct HubCLITaskStatusBadge: View {
    @Environment(\.widgetLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    let status: HubAccountTaskStatus
    var compact = false

    private var tint: Color {
        switch status.phase {
        case .succeeded: return FixedVisualPalette.statusSuccessForeground(colorScheme)
        case .failed, .cancelled: return FixedVisualPalette.statusDangerForeground(colorScheme)
        case .uncertain, .unavailable, .cancelRequested: return FixedVisualPalette.statusWarningForeground(colorScheme)
        case .awaitingApproval, .starting, .running, .maintenance: return .accentColor
        case .awaitingAcceptance: return FixedVisualPalette.statusWarningForeground(colorScheme)
        case .idle: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            Circle()
                .fill(tint)
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            Text(status.label(language))
                .lineLimit(1)
        }
        .font(.system(size: compact ? 8.5 : 9.5, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(FixedVisualPalette.statusFill(tint, colorScheme: colorScheme)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.09), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.text("CLI 任务状态：\(status.localizedLabel)", "CLI task status: \(status.label(language))"))
    }
}

enum AccountDisplay {
    static func planLabel(
        _ profile: CodexProfile?,
        fallbackPlan: String? = nil,
        empty: String = "PLUS"
    ) -> String {
        let plan = profile?.officialProfile?.planType ?? profile?.lastSnapshot?.planType ?? fallbackPlan
        guard let plan, !plan.isEmpty else { return empty }
        let normalized = plan.uppercased()
        guard normalized == "PRO", let multiplier = profile?.displayedProTierMultiplier else {
            return normalized
        }
        return "PRO \(multiplier)x"
    }

    static func profileName(
        _ profile: CodexProfile,
        fallbackRaw: String? = nil,
        allProfiles: [CodexProfile] = []
    ) -> String {
        let remark = profile.remark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !remark.isEmpty { return masked(remark) }
        if profile.isSystemProfile, !allProfiles.isEmpty,
            let linkedRemark = linkedManagedRemark(for: profile, in: allProfiles)
        {
            return masked(linkedRemark)
        }
        if let displayName = profile.officialProfile?.displayName,
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return masked(displayName)
        }
        return masked(fallbackRaw ?? profile.name)
    }

    static func masked(_ raw: String) -> String {
        guard let at = raw.firstIndex(of: "@") else { return raw }
        let local = String(raw[..<at])
        let domain = String(raw[raw.index(after: at)...])
        guard !local.isEmpty, !domain.isEmpty else { return raw }
        guard local.count > 6 else { return local }
        return "\(local.prefix(3))•••\(local.suffix(3))"
    }

    static func selfTest() -> Bool {
        let profile = CodexProfile(
            id: "display-test",
            name: "fallback@example.com",
            remark: "visible@example.com",
            codexHomePath: "/tmp/display-test",
            isSystemProfile: false,
            createdAt: Date(),
            lastSnapshot: nil
        )
        guard profileName(profile) == "vis•••ble",
            masked("short@example.com") == "short",
            masked("Display Name") == "Display Name",
            masked("@handle") == "@handle",
            masked("name@") == "name@"
        else {
            print("Account display self-test failed: raw email masking")
            return false
        }
        print("Account display self-test passed")
        return true
    }

    private static func linkedManagedRemark(
        for profile: CodexProfile,
        in profiles: [CodexProfile]
    ) -> String? {
        guard profile.isSystemProfile else { return nil }
        return CodexProfile.groupsByRecordedAccount(profiles)
            .first { $0.contains(where: { $0.id == profile.id }) }?
            .first { !$0.isSystemProfile }?
            .remark?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension View {
    func profileBadge() -> some View {
        self
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(FixedVisualPalette.surfaceTrack))
    }
}
