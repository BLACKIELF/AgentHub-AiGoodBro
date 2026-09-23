import Cocoa
import SwiftUI

let titlebarControlHeight: CGFloat = 18
let settingsAccessoryColumnWidth: CGFloat = 184
let settingsControlCornerRadius: CGFloat = 8
let settingsSegmentHeight: CGFloat = 30
let settingsControlVisualHeight: CGFloat = settingsSegmentHeight + 6
let settingsRowTitleFontSize: CGFloat = 12.5
let settingsRowDetailFontSize: CGFloat = 10.5
let settingsControlFontSize: CGFloat = 11
private let settingsSwitchWidth: CGFloat = 56
private let settingsShortcutControlSpacing: CGFloat = 8
private let settingsShortcutRecorderWidth: CGFloat = 108
private let settingsShortcutActionWidth: CGFloat =
    settingsAccessoryColumnWidth
    - settingsShortcutRecorderWidth
    - settingsShortcutControlSpacing

struct HeaderActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualTokens) private var visualTokens
    @State private var isHovering = false

    let systemName: String
    var isActive = false
    var hoverTint: Color?
    let help: String
    let accessibilityLabel: String
    var accessibilityValue: String?
    let action: () -> Void

    private var foregroundColor: Color {
        if isActive {
            return visualTokens.selection.foreground.color
        }
        if isHovering, let hoverTint {
            return hoverTint
        }
        return Color.secondary
    }

    private var fillColor: Color {
        if isActive {
            return visualTokens.selection.fill.color
        }
        if isHovering {
            return FixedVisualPalette.controlSelectedFill(colorScheme)
        }
        return Color.clear
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: titlebarControlHeight, height: titlebarControlHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isActive ? visualTokens.selection.stroke.color : Color.clear,
                            lineWidth: 0.8
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct TitlebarToolbarView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    let onOpenSettings: () -> Void
    let onSaveScreenshot: () -> Void
    let onOpenGuide: () -> Void

    private var language: WidgetLanguage { settings.language }
    private var themeMode: WidgetThemeMode { settings.themeMode }
    private var effectiveColorScheme: ColorScheme {
        themeMode.preferredColorScheme ?? colorScheme
    }

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            HeaderActionButton(
                systemName: "questionmark.circle",
                help: language.text("使用引导", "Getting started"),
                accessibilityLabel: language.text("使用引导", "Getting started")
            ) {
                onOpenGuide()
            }

            HStack(spacing: 2) {
                HeaderActionButton(
                    systemName: "camera.viewfinder",
                    help: language.text("保存主界面长截图（PNG）", "Save full workspace screenshot (PNG)"),
                    accessibilityLabel: language.text("保存主界面长截图", "Save full workspace screenshot")
                ) {
                    onSaveScreenshot()
                }
                HeaderActionButton(
                    systemName: "gearshape",
                    help: language.text("设置", "Settings"),
                    accessibilityLabel: language.text("设置", "Settings")
                ) {
                    onOpenSettings()
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FixedVisualPalette.controlFill(effectiveColorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(FixedVisualPalette.controlStroke(effectiveColorScheme), lineWidth: 0.8)
                    )
            )
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .topTrailing)
        .appVisualEnvironment(
            catalog: settings.paletteCatalog,
            paletteID: settings.paletteID,
            appearance: PaletteAppearance(effectiveColorScheme)
        )
        .environment(\.colorScheme, effectiveColorScheme)
        .preferredColorScheme(themeMode.preferredColorScheme)
        .readableForegroundHierarchy(effectiveColorScheme)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance
    case menuBar
    case floatingBubble
    case automation
    case workspace
    case about

    var id: String { rawValue }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .appearance: return language.text("显示与图标", "Display & Icons")
        case .menuBar: return language.text("菜单栏", "Menu Bar")
        case .floatingBubble: return language.text("悬浮窗", "Floating window")
        case .automation: return language.text("自动化", "Automation")
        case .workspace: return language.text("工作区", "Workspace")
        case .about: return language.text("关于", "About")
        }
    }

    func detail(_ language: WidgetLanguage) -> String {
        switch self {
        case .appearance: return language.text("主题、语言、透明度与额度环动效；账号头像在账号详情中修改。", "Theme, language, opacity and ring motion. Change account avatars in account details.")
        case .menuBar: return language.text("选择菜单栏显示的账号与指标。", "Choose the account and metrics shown in the menu bar.")
        case .floatingBubble: return language.text("选择桌面上持续显示的账号、用量与外观。", "Choose the account, usage and appearance shown on the desktop.")
        case .automation: return language.text("按各账号的额度窗口安排自动维护。", "Schedule automatic maintenance around each account’s quota windows.")
        case .workspace: return language.text("数据口径、窗口行为与快捷入口。", "Data, window behavior and shortcuts.")
        case .about: return language.text("版本、联系小助理与开源来源。", "Version, contact and open-source attribution.")
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .menuBar: return "menubar.rectangle"
        case .floatingBubble: return "macwindow.on.rectangle"
        case .automation: return "bolt.badge.clock"
        case .workspace: return "rectangle.3.group"
        case .about: return "info.circle"
        }
    }
}

struct NextSettingsHeader: View {
    let language: WidgetLanguage
    var currentPage: SettingsPage? = nil
    var onBack: (() -> Void)? = nil
    @ObservedObject private var pageContext = AHSettingsHeaderContext.shared
    @Environment(\.visualTokens) private var visualTokens

    private var resolvedPage: SettingsPage? { currentPage ?? pageContext.currentPage }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AHBrandSymbol(size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(AHBrandIdentity.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(AHBrandIdentity.headerDetail(page: resolvedPage, language: language))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let onBack {
                Button(action: onBack) {
                    Label(language.text("返回", "Back"), systemImage: "arrow.left")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(visualTokens.accent.primary.color)
                .help(language.text("返回账号概览", "Back to account overview"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AHBrandIdentity.displayName) \(AHBrandIdentity.headerDetail(page: resolvedPage, language: language))")
    }
}

final class SettingsWindowNavigation: ObservableObject {
    @Published var page: SettingsPage = .appearance
}

struct SettingsWindowContent: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var updateStore: AppUpdateStore
    @ObservedObject var localAccounts: LocalCLIAccountStore
    @ObservedObject var navigation: SettingsWindowNavigation
    let onOpenPaletteLibrary: () -> Void

    var body: some View {
        SettingsPanelView(
            settings: settings, store: store, updateStore: updateStore,
            onOpenPaletteLibrary: onOpenPaletteLibrary,
            pageSelection: $navigation.page,
            floatingBubbleSources: FloatingBubbleEvidence.make(store: store, localAccounts: localAccounts, language: settings.language)
        )
        .environment(\.widgetLanguage, settings.language)
        .environment(\.locale, settings.language.locale)
        .preferredColorScheme(settings.themeMode.preferredColorScheme)
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
    }
}

struct SettingsPanelView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var updateStore: AppUpdateStore
    let onOpenPaletteLibrary: () -> Void
    var compact = false
    var showsHeader = true
    var floatingBubbleSources: [TokenMonitorFloatingBubbleAccount]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualTokens) private var visualTokens
    @State private var localSelectedPage: SettingsPage
    private let pageSelection: Binding<SettingsPage>?
    @State private var showsAutomationCenter = false

    private var selectedPage: SettingsPage {
        get { pageSelection?.wrappedValue ?? localSelectedPage }
        nonmutating set {
            if let pageSelection { pageSelection.wrappedValue = newValue } else { localSelectedPage = newValue }
        }
    }

    init(
        settings: AppSettings,
        store: UsageStore,
        updateStore: AppUpdateStore,
        onOpenPaletteLibrary: @escaping () -> Void,
        compact: Bool = false,
        showsHeader: Bool = true,
        initialPage: SettingsPage = .appearance,
        pageSelection: Binding<SettingsPage>? = nil,
        floatingBubbleSources: [TokenMonitorFloatingBubbleAccount] = []
    ) {
        self.settings = settings
        self.store = store
        self.updateStore = updateStore
        self.onOpenPaletteLibrary = onOpenPaletteLibrary
        self.compact = compact
        self.showsHeader = showsHeader
        self.floatingBubbleSources = floatingBubbleSources
        _localSelectedPage = State(initialValue: initialPage)
        self.pageSelection = pageSelection
    }

    private var language: WidgetLanguage { settings.language }

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    if showsHeader { NextSettingsHeader(language: language, currentPage: selectedPage) }
                    pageNavigation
                    pageScroll
                }
                .frame(width: CodexAccountMenuView.preferredSize.width)
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    pageScroll
                }
                .frame(minWidth: 740, idealWidth: 780, minHeight: 520, idealHeight: 640)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .appVisualEnvironment(catalog: settings.paletteCatalog, paletteID: settings.paletteID, appearance: PaletteAppearance(colorScheme))
        .readableForegroundHierarchy(colorScheme)
        .sheet(isPresented: $showsAutomationCenter) { AccountAutomationCenterView(store: store) }
        .onAppear { AHSettingsHeaderContext.shared.currentPage = selectedPage }
        .onChange(of: selectedPage) { AHSettingsHeaderContext.shared.currentPage = $0 }
        .onDisappear { AHSettingsHeaderContext.shared.currentPage = nil }
    }

    private var pageScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedPage.title(language))
                        .font(.system(size: compact ? 18 : 24, weight: .semibold))
                    Text(selectedPage.detail(language))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityAddTraits(.isHeader)
                pageContent
            }
            .padding(compact ? 18 : 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("next.settings.page.\(selectedPage.rawValue)")
        }
        .id(selectedPage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                AHBrandSymbol(size: 24)
                Text("AiGoodBro").font(.headline)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 20)
            ForEach(SettingsPage.allCases) { page in
                Button {
                    selectedPage = page
                } label: {
                    Label(page.title(language), systemImage: page.symbol)
                        .font(.system(size: 13, weight: selectedPage == page ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .background(selectedPage == page ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedPage == page ? .isSelected : [])
                .accessibilityIdentifier("next.settings.tab.\(page.rawValue)")
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 172)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    private var pageNavigation: some View {
        Picker(language.text("设置分类", "Settings category"), selection: Binding(get: { selectedPage }, set: { selectedPage = $0 })) {
            ForEach(SettingsPage.allCases) { page in
                Label(page.title(language), systemImage: page.symbol).tag(page)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    @ViewBuilder private var pageContent: some View {
        switch selectedPage {
        case .appearance: appearancePage
        case .menuBar:
            StatusItemSettingsView(settings: settings, store: store)
        case .floatingBubble:
            VStack(spacing: 6) {
                TokenMonitorFloatingBubbleEditor(
                    preferences: $settings.floatingBubble,
                    snapshot: TokenMonitorFloatingBubbleProjection.resolve(
                        preferences: settings.floatingBubble, sources: floatingBubbleSources
                    ),
                    language: language,
                    providers: AgentNavCatalog.workspaceProviders,
                    previewUsesSyntheticData: false,
                    sources: floatingBubbleSources,
                    embeddedInSettings: true,
                    onShowDesktop: { TokenMonitorFloatingBubbleSession.show(settings: settings, language: language) },
                    onCancel: {},
                    onDone: {}
                )
            }
        case .automation: automationPage
        case .workspace: workspacePage
        case .about: aboutPage
        }
    }

    private var appearancePage: some View {
        VStack(spacing: 6) {
            SettingsAppearanceChooser(selection: $settings.themeMode, language: language)
                .padding(.bottom, 4)
            PaletteSettingsView(settings: settings, onOpenLibrary: onOpenPaletteLibrary)
            AppIconStylePicker(selection: $settings.appIconStyle, language: language)
                .padding(.bottom, 6)
            SettingsPickerRow(
                title: language.text("语言", "Language"),
                detail: ""
            ) {
                SettingsSegmentedControl(
                    selection: $settings.language,
                    options: [
                        SettingsSegmentOption(value: .zh, title: "中文"),
                        SettingsSegmentOption(value: .en, title: "English"),
                    ],
                    width: settingsAccessoryColumnWidth
                )
            }
            SettingsPickerRow(
                title: language.text("面板透明度", "Panel opacity"),
                detail: language.text("调整菜单栏面板的背景浓度", "Adjust the menu bar panel's background opacity")
            ) {
                SettingsSegmentedControl(
                    selection: $settings.accountMenuTransparency,
                    options: [
                        SettingsSegmentOption(value: .clear, title: language.text("清晰", "Clear")),
                        SettingsSegmentOption(value: .standard, title: language.text("标准", "Standard")),
                        SettingsSegmentOption(value: .frosted, title: language.text("磨砂", "Frosted")),
                    ],
                    width: settingsAccessoryColumnWidth
                )
            }
            SettingsPickerRow(
                title: language.text("额度环动效", "Ring motion"),
                detail: language.text("默认仅前台聚焦时播放；省电仅悬停时播放", "Default: active window only. Power Saving: pointer hover only.")
            ) {
                SettingsSegmentedControl(
                    selection: $settings.particleAnimationMode,
                    options: [
                        SettingsSegmentOption(value: .standard, title: language.text("默认", "Default")),
                        SettingsSegmentOption(value: .powerSaving, title: language.text("省电", "Power Saving")),
                    ],
                    width: settingsAccessoryColumnWidth
                )
            }
        }
    }

    private var automationPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("自动切换与通知", "Auto-switch and notifications")).font(.headline)
                    Text(language.text("额度提醒、消息渠道与活动记录", "Quota alerts, message channels and activity history"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(language.text("管理…", "Manage…")) { showsAutomationCenter = true }
                    .buttonStyle(.bordered)
            }
            .padding(.bottom, 14)
            SettingsWarmUpCard(
                interval: "5h",
                title: language.text("5 小时暖号", "5-hour warm-up"),
                detail: language.text(
                    "按官方重置时间预约，短暂缓冲后优先刷新额度并暖号；周额度不足时暂停。",
                    "Schedule at the official reset time, briefly allow for propagation, then refresh quota and warm up. Pause on low weekly quota."
                ),
                isOn: Binding(get: { store.warmUpSelection.fiveHour }, set: { store.setWarmUpFiveHourEnabled($0) })
            )
            SettingsWarmUpCard(
                interval: "7d",
                title: language.text("7 天暖号", "7-day warm-up"),
                detail: language.text("分别跟随各账号自己的 7 天窗口。", "Follow each account's own 7-day window."),
                isOn: Binding(get: { store.warmUpSelection.sevenDay }, set: { store.setWarmUpSevenDayEnabled($0) })
            )
            Label(language.text("先确认空闲，再自动运行", "Runs only after idle-state checks"), systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(visualTokens.accent.primary.color)
            Text(
                language.text(
                    "暖号会发送最小请求并消耗额度。以官方返回的窗口时间为准；账号忙碌、映射缺失或状态不明确时，不会启动。打开这个分区不会触发暖号。",
                    "Warm-up sends a minimal request and uses quota. Official window times are authoritative. Busy accounts, missing mappings or unverified state block execution. Opening this page does not start warm-up."
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workspacePage: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsPickerRow(
                title: language.text("账号自动刷新", "Automatic account refresh"),
                detail: language.text(
                    "调整额度与用量的定时读取；手动刷新随时可用，切号不等待刷新", "Controls scheduled quota and usage reads. Manual refresh stays available; switching does not wait for refresh.")
            ) {
                Picker(
                    language.text("刷新间隔", "Refresh interval"),
                    selection: Binding(
                        get: { store.accountRefreshFrequency }, set: { store.setAccountRefreshFrequency($0) })
                ) {
                    ForEach(AccountRefreshFrequency.allCases) { frequency in
                        Text(frequency.label(language)).tag(frequency)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                .frame(width: settingsAccessoryColumnWidth)
                .accessibilityIdentifier("next.accounts.refreshFrequency")
            }
            SettingsToggleRow(
                title: language.text("额度不足自动换号", "Switch when quota is low"),
                detail: language.text("低于阈值时核对备用账号；任务空闲且身份、额度通过检查才切换", "Checks an eligible backup below the threshold, then switches after idle, identity and quota checks pass.")
            ) {
                SettingsSwitchToggle(
                    isOn: Binding(
                        get: { store.automaticAccountSwitchEnabled }, set: { store.setAutomaticAccountSwitchEnabled($0) })
                )
                .disabled(store.pausedAutomationFeatures.contains(.lowQuota))
            }
            SettingsPickerRow(
                title: language.text("统计方式", "Statistics mode"),
                detail: language.text("主页按所选方式汇总；切换后分别计算，不混加", "The home page uses the selected engine. Each mode keeps its own totals.")
            ) {
                Picker(
                    language.text("统计方式", "Statistics mode"),
                    selection: Binding(
                        get: { store.statisticsEngineChoice },
                        set: { choice in
                            settings.statisticsEngine = choice
                            store.selectStatisticsEngine(choice)
                        }
                    )
                ) {
                    Text(language.text("Token Monitor（默认）", "Token Monitor (default)")).tag(StatisticsEngineChoice.upstream)
                    Text(language.text("自定义（原有模式）", "Custom (previous mode)")).tag(StatisticsEngineChoice.custom)
                    if store.statisticsEngineChoice == .nativeLegacy {
                        Text(language.text("旧版统计", "Legacy statistics")).tag(StatisticsEngineChoice.nativeLegacy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: settingsAccessoryColumnWidth)
                .accessibilityIdentifier("next.statistics.engine")
            }
            if store.statisticsEngineChoice == .upstream {
                StatisticsSourceSettings(language: language)
            } else {
                SettingsPickerRow(
                    title: language.text("数据来源", "Data sources"),
                    detail: language.text("保留原有自定义来源与统计方式", "Use the existing custom sources and statistics")
                ) {
                    SettingsRuntimeMultiSelectControl(
                        selectedScopes: settings.visibleRuntimeScopes, language: language
                    ) { scope in
                        settings.setRuntime(scope, visible: !settings.isRuntimeVisible(scope))
                    }
                }
            }
            SettingsPickerRow(title: language.text("统计时区", "Usage time zone"), detail: statisticsTimeZoneDetail) {
                SettingsSegmentedControl(
                    selection: statisticsTimeZoneSelectionBinding,
                    options: [
                        SettingsSegmentOption(value: .system, title: language.text("系统", "System")),
                        SettingsSegmentOption(value: .utc, title: "UTC"),
                        SettingsSegmentOption(value: .fixed, title: language.text("固定", "Fixed")),
                    ],
                    width: settingsAccessoryColumnWidth
                )
            }
            if store.statisticsPreference.selection == .fixed {
                SettingsPickerRow(
                    title: language.text("固定时区", "Fixed time zone"),
                    detail: language.text("IANA 时区，自动处理夏令时", "IANA time zone with daylight-saving support")
                ) {
                    Picker(language.text("固定时区", "Fixed time zone"), selection: statisticsFixedIdentifierBinding) {
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                            Text(identifier).tag(identifier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: settingsAccessoryColumnWidth)
                }
            }
            SettingsToggleRow(
                title: language.text("主窗口置顶", "Always on top"),
                detail: language.text("持续观察额度时，保持窗口可见", "Keep quota in view while you work")
            ) {
                SettingsSwitchToggle(isOn: $settings.keepMainWindowOnTop)
            }
            SettingsToggleRow(
                title: language.text("关闭后留在菜单栏", "Stay in menu bar"),
                detail: language.text("关闭窗口后继续运行，可从菜单栏或快捷键重新打开", "Keep running after closing. Reopen from the menu bar or shortcut.")
            ) {
                SettingsSwitchToggle(isOn: $settings.keepRunningWhenMainWindowClosed)
            }
            SettingsPickerRow(
                title: language.text("全局快捷键", "Global shortcut"),
                detail: language.text(
                    "默认 ⌘U；自定义需两个修饰键（含 ⌘ 或 ⌃），仅检测独占冲突。",
                    "Default ⌘U. Custom shortcuts need two modifiers including ⌘ or ⌃. Only exclusive conflicts can be detected."
                )
            ) {
                HStack(spacing: settingsShortcutControlSpacing) {
                    ShortcutRecorderView(
                        shortcut: settings.globalShortcut, language: language,
                        onRecord: settings.requestGlobalShortcut, onClear: settings.clearGlobalShortcut
                    )
                    .frame(width: settingsShortcutRecorderWidth, height: settingsControlVisualHeight)
                    Button(language.text("重置", "Reset")) {
                        settings.resetGlobalShortcut()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: settingsControlFontSize))
                    .frame(width: settingsShortcutActionWidth)
                    .disabled(settings.globalShortcut == .default && settings.globalShortcutError == nil)
                }
            }
            if let error = settings.globalShortcutError {
                SettingsErrorRow(
                    title: language.text("快捷键不可用", "Shortcut unavailable"),
                    message: error.message(language: language),
                    currentValue: settings.globalShortcut.map {
                        language.text("当前仍使用 \($0.displayName)", "Still using \($0.displayName)")
                    } ?? language.text("当前未设置全局快捷键", "No global shortcut is currently set")
                )
            }
        }
    }

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(alignment: .center, spacing: 10) {
                AHBrandSymbol(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AHBrandIdentity.displayName)
                        .font(.system(size: 16, weight: .semibold))
                    Text(AHBrandIdentity.workspaceName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(updateStore.result.currentVersion)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(AHBrandIdentity.aboutAttribution(language))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link(destination: AHBrandIdentity.siteURL) {
                    Label("aigoodbro.com", systemImage: "globe")
                }
                Link(destination: AHBrandIdentity.repositoryURL) {
                    Label("GitHub · AiGoodBro", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .font(.callout.weight(.medium))
            .padding(.vertical, 8)
            AssistantContactCard(language: language, compact: compact)
                .padding(.bottom, 14)
            SettingsValueRow(
                title: language.text("当前 Runtime", "Current runtime"),
                detail: language.text("当前工作台的数据范围", "Data scope of the current workspace"),
                value: store.selectedRuntimeScope.displayName
            )
            SettingsValueRow(
                title: language.text("订阅计划", "Plan"),
                detail: language.text("来自本机账号读取结果", "Reported by the connected account"),
                value: store.snapshot.account?.planType?.uppercased() ?? "LOCAL"
            )
            AppUpdateSettingsRows(settings: settings, updateStore: updateStore, language: language)
            Divider().padding(.vertical, 12)
            acknowledgements
        }
    }

    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("鸣谢与开源项目", "Acknowledgements & open source"))
                .font(.headline)
            Text(
                language.text(
                    "感谢愿意分享代码、经验和时间的开发者。AiGoodBro 的许多能力建立在这些项目的成果之上。",
                    "Thank you to the developers who share their code, experience and time. Their work makes many of AiGoodBro’s capabilities possible."
                )
            )
            .font(.callout).foregroundStyle(.secondary)
            acknowledgement(
                "Token Monitor · Javis603 / Javis", url: "https://github.com/Javis603/token-monitor",
                detail: language.text(
                    "特别感谢 Token Monitor 开放多工具 Token 采集、年度热图、趋势图和用量看板。本 App 的统计引擎与图表由这些成果直接支持。",
                    "Special thanks for the multi-tool token collectors, annual heatmap, trend charts and usage dashboard that directly support this app’s statistics engine and charts."
                ))
            acknowledgement(
                "Tokscale · junhoyeo & Javis603", url: "https://github.com/Javis603/tokscale",
                detail: language.text(
                    "感谢原项目作者 junhoyeo 与分支维护者 Javis603 提供本地用量扫描能力，为统计采集打下基础。",
                    "Thanks to original author junhoyeo and fork maintainer Javis603 for the local usage scanner at the foundation of token collection."
                ))
            acknowledgement(
                "codexU · Guomeiqing / shanggqm", url: "https://github.com/shanggqm/codexU",
                detail: language.text(
                    "感谢分享早期 SwiftUI 工作台、额度展示和配色基础，让后续界面迭代有了可靠的起点。",
                    "Thank you for the early SwiftUI workspace, quota presentation and palette foundations that gave this interface a starting point."
                ))
            acknowledgement(
                "Codex-Manager · hongshun.gao / qxcnm", url: "https://github.com/qxcnm/Codex-Manager",
                detail: language.text(
                    "感谢公开账号暖号协议的实现，为自动维护能力提供参考与基础。",
                    "Thank you for sharing the account warm-up protocol implementation that informs automatic maintenance."
                ))
            acknowledgement(
                "Codex Resets", url: "https://codex-resets.com/",
                detail: language.text(
                    "感谢持续追踪和整理公开重置公告，为重置消息提供可核对的来源。",
                    "Thank you for tracking and preserving public reset announcements, providing verifiable sources for reset updates."
                ))
            acknowledgement(
                "AIHOT · Tibo 重置监控", url: "https://aihot.news/codex-reset",
                detail: language.text(
                    "感谢公开重置动态的中文整理、状态解释与时间说明，为信息呈现提供参考。",
                    "Thank you for the Chinese summaries, status explanations and time guidance that inform the presentation of public reset updates."
                ))
            acknowledgement(
                "Node.js contributors", url: "https://nodejs.org/",
                detail: language.text(
                    "感谢维护随 App 打包的 JavaScript 运行时，让统计引擎无需依赖用户另行安装 Node.js。",
                    "Thank you for the bundled JavaScript runtime that lets the statistics engine run without a separate Node.js installation."
                ))
            Text(
                language.text(
                    "也感谢持续反馈问题、测试新版本和提出改进建议的每一位使用者。各项目的版权和许可证随 App 保留。",
                    "Thanks as well to everyone who reports issues, tests new versions and suggests improvements. Project copyrights and licenses are retained in the app."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func acknowledgement(_ title: String, url: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Link(destination: URL(string: url)!) {
                Label(title, systemImage: "arrow.up.right.square")
                    .font(.callout.weight(.semibold))
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statisticsTimeZoneSelectionBinding: Binding<StatisticsTimeZoneSelection> {
        Binding(
            get: { store.statisticsPreference.selection },
            set: { selection in
                var preference = store.statisticsPreference
                preference.selection = selection
                store.updateStatisticsTimeZone(preference)
            }
        )
    }

    private var statisticsFixedIdentifierBinding: Binding<String> {
        Binding(
            get: { store.statisticsPreference.fixedIdentifier },
            set: { identifier in
                store.updateStatisticsTimeZone(StatisticsTimeZonePreference(selection: .fixed, fixedIdentifier: identifier))
            }
        )
    }

    private var statisticsTimeZoneDetail: String {
        if let message = store.statisticsTransitionMessage { return message }
        let identity = store.multiRuntimeSnapshot.statisticsIdentity
        switch identity.preference.selection {
        case .system:
            return language.text("跟随系统自然日 · \(identity.resolvedIdentifier)", "System calendar day · \(identity.resolvedIdentifier)")
        case .utc:
            return language.text("UTC 日界线，便于对照官方", "UTC day boundary for official comparison")
        case .fixed:
            return identity.resolvedIdentifier
        }
    }
}

private struct SettingsAppearanceChooser: View {
    @Binding var selection: WidgetThemeMode
    @Environment(\.visualTokens) private var visualTokens
    let language: WidgetLanguage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WidgetThemeMode.allCases, id: \.rawValue) { mode in
                Button {
                    selection = mode
                } label: {
                    VStack(spacing: 6) {
                        preview(mode)
                            .frame(height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        HStack(spacing: 4) {
                            Text(title(mode))
                            Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selection == mode ? visualTokens.accent.primary.color : Color.secondary)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous)
                            .fill(selection == mode ? FixedVisualPalette.surfaceSoftFill : FixedVisualPalette.surfaceSubtleFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous)
                            .strokeBorder(
                                selection == mode ? visualTokens.accent.primary.color : FixedVisualPalette.surfaceHairline,
                                lineWidth: 1
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("外观：\(title(mode))", "Appearance: \(title(mode))"))
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
    }

    private func title(_ mode: WidgetThemeMode) -> String {
        switch mode {
        case .system: return language.text("自动", "System")
        case .light: return language.text("浅色", "Light")
        case .dark: return language.text("深色", "Dark")
        }
    }

    private func preview(_ mode: WidgetThemeMode) -> some View {
        let dark = Color(red: 0.12, green: 0.14, blue: 0.19)
        let light = Color(red: 0.92, green: 0.94, blue: 0.98)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Rectangle().fill(mode == .dark ? dark : light)
                Rectangle().fill(mode == .light ? light : dark)
            }
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(visualTokens.accent.primary.color.opacity(0.65))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(visualTokens.accent.primary.color).frame(width: 30, height: 3)
                    Capsule().fill(Color.gray.opacity(0.45)).frame(height: 3)
                    Capsule().fill(Color.gray.opacity(0.3)).frame(width: 26, height: 3)
                }
                .padding(.top, 4)
            }
            .padding(8)
        }
        .accessibilityHidden(true)
    }
}

private struct SettingsWarmUpCard: View {
    let interval: String
    let title: String
    let detail: String
    let isOn: Binding<Bool>

    var body: some View {
        SettingsBaseRow(title: "\(interval) · \(title)", detail: detail) {
            SettingsSwitchToggle(isOn: isOn)
                .accessibilityLabel(title)
        }
    }
}

struct SettingsPickerRow<Control: View>: View {
    let title: String
    let detail: String
    let control: Control

    init(title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        SettingsBaseRow(title: title, detail: detail) {
            control
                .accessibilityLabel(title)
        }
    }
}

struct SettingsSegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

struct SettingsSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SettingsSegmentOption<Value>]
    let width: CGFloat

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.title).tag(option.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .frame(width: width, height: settingsControlVisualHeight)
    }
}

struct SettingsRuntimeMultiSelectControl: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualTokens) private var visualTokens
    let selectedScopes: [RuntimeScope]
    let language: WidgetLanguage
    let onToggle: (RuntimeScope) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(RuntimeScope.allCases.enumerated()), id: \.element.id) { index, scope in
                Button {
                    onToggle(scope)
                } label: {
                    HStack(spacing: 6) {
                        RuntimeLogoView(scope: scope, size: 16)
                        Text(label(for: scope))
                            .font(.system(size: settingsControlFontSize, weight: isSelected(scope) ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(isSelected(scope) ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: settingsSegmentHeight)
                    .background(
                        RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous)
                            .fill(isSelected(scope) ? visualTokens.accent.primary.color : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(for: scope))
                .accessibilityValue(isSelected(scope) ? language.text("已选择", "Selected") : language.text("未选择", "Not selected"))

                if index < RuntimeScope.allCases.count - 1 {
                    Rectangle()
                        .fill(FixedVisualPalette.controlStroke(colorScheme))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 1)
                }
            }
        }
        .padding(3)
        .frame(width: settingsAccessoryColumnWidth, height: settingsControlVisualHeight)
        .background(
            RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous)
                .fill(FixedVisualPalette.controlFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous)
                        .strokeBorder(FixedVisualPalette.controlStroke(colorScheme), lineWidth: 0.8)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous))
    }

    private func isSelected(_ scope: RuntimeScope) -> Bool {
        selectedScopes.contains(scope)
    }

    private func label(for scope: RuntimeScope) -> String {
        switch scope {
        case .codex:
            return "Codex"
        case .claudeCode:
            return language.text("Claude Code", "Claude Code")
        }
    }
}

struct SettingsSwitchToggle: View {
    @Environment(\.visualTokens) private var visualTokens
    let isOn: Binding<Bool>
    var isDisabled = false
    var help: String?

    var body: some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
            .tint(visualTokens.accent.primary.color)
            .frame(width: settingsSwitchWidth, alignment: .trailing)
            .disabled(isDisabled)
            .help(help ?? "")
    }
}

struct SettingsToggleRow<Control: View>: View {
    let title: String
    let detail: String
    let control: Control

    init(title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        SettingsBaseRow(title: title, detail: detail) {
            control
                .accessibilityLabel(title)
        }
    }
}

struct SettingsValueRow: View {
    let title: String
    let detail: String
    let value: String

    var body: some View {
        SettingsBaseRow(title: title, detail: detail) {
            Text(value)
                .font(.system(size: settingsControlFontSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct SettingsErrorRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let message: String
    let currentValue: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FixedVisualPalette.statusDanger)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: settingsRowTitleFontSize, weight: .semibold))
                    .foregroundStyle(FixedVisualPalette.statusDanger)
                Text(message)
                    .font(.system(size: settingsRowDetailFontSize, weight: .regular))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(currentValue)
                    .font(.system(size: settingsRowDetailFontSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous)
                .fill(FixedVisualPalette.statusDangerFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous)
                        .strokeBorder(FixedVisualPalette.statusDangerStroke(colorScheme), lineWidth: 0.8)
                )
        )
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsBaseRow<Accessory: View>: View {
    let title: String
    let detail: String
    let accessory: Accessory

    init(title: String, detail: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.system(size: settingsRowTitleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory
                    .frame(width: settingsAccessoryColumnWidth, alignment: .trailing)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: settingsRowDetailFontSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FixedVisualPalette.surfaceSoftFill)
                .frame(height: 1)
        }
    }
}

struct SectionBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        FixedVisualPalette.sectionFill(
                            colorScheme,
                            reduceTransparency: reduceTransparency
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                FixedVisualPalette.sectionStroke(
                                    colorScheme,
                                    increasedContrast: colorSchemeContrast == .increased
                                ),
                                lineWidth: colorSchemeContrast == .increased ? 1.0 : 0.8
                            )
                    )
            )
    }
}

struct CardBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        FixedVisualPalette.cardFill(
                            colorScheme,
                            elevated: elevated,
                            reduceTransparency: reduceTransparency
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                FixedVisualPalette.cardStroke(
                                    colorScheme,
                                    elevated: elevated,
                                    increasedContrast: colorSchemeContrast == .increased
                                ),
                                lineWidth: colorSchemeContrast == .increased ? 1.0 : 0.8
                            )
                    )
            )
    }
}

extension View {
    func readableForegroundHierarchy(_ colorScheme: ColorScheme) -> some View {
        foregroundStyle(
            Color.primary,
            FixedVisualPalette.secondaryText(colorScheme),
            FixedVisualPalette.tertiaryText(colorScheme)
        )
    }

    func sectionBackground() -> some View {
        modifier(SectionBackgroundModifier())
    }

    func cardBackground(cornerRadius: CGFloat = 10, elevated: Bool = false) -> some View {
        modifier(CardBackgroundModifier(cornerRadius: cornerRadius, elevated: elevated))
    }
}
