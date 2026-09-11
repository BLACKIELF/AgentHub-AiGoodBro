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

    private var language: WidgetLanguage { settings.language }
    private var themeMode: WidgetThemeMode { settings.themeMode }
    private var effectiveColorScheme: ColorScheme {
        themeMode.preferredColorScheme ?? colorScheme
    }

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            AHBrandSymbol(size: 24)
                .frame(width: 34, height: titlebarControlHeight)
                .help("AiGoodBro")

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
    case automation
    case workspace
    case about

    var id: String { rawValue }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .appearance: return language.text("外观", "Appearance")
        case .menuBar: return language.text("菜单栏", "Menu Bar")
        case .automation: return language.text("自动化", "Automation")
        case .workspace: return language.text("工作区", "Workspace")
        case .about: return language.text("关于", "About")
        }
    }

    func detail(_ language: WidgetLanguage) -> String {
        switch self {
        case .appearance: return language.text("主题、语言、透明度与额度环动效。", "Theme, language, opacity and ring motion.")
        case .menuBar: return language.text("选择展示模式、额度口径与可见指标。", "Choose display mode, usage display and visible metrics.")
        case .automation: return language.text("按窗口预约暖号，默认关闭。", "Schedule warm-up per window. Off by default.")
        case .workspace: return language.text("数据口径、窗口行为与快捷入口。", "Data, window behavior and shortcuts.")
        case .about: return language.text("版本、更新与开源来源。", "Version, updates and open-source attribution.")
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .menuBar: return "menubar.rectangle"
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

struct SettingsPanelView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var updateStore: AppUpdateStore
    let onOpenPaletteLibrary: () -> Void
    var compact = false
    var showsHeader = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualTokens) private var visualTokens
    @State private var selectedPage: SettingsPage

    init(
        settings: AppSettings,
        store: UsageStore,
        updateStore: AppUpdateStore,
        onOpenPaletteLibrary: @escaping () -> Void,
        compact: Bool = false,
        showsHeader: Bool = true,
        initialPage: SettingsPage = .appearance
    ) {
        self.settings = settings
        self.store = store
        self.updateStore = updateStore
        self.onOpenPaletteLibrary = onOpenPaletteLibrary
        self.compact = compact
        self.showsHeader = showsHeader
        _selectedPage = State(initialValue: initialPage)
    }

    private var language: WidgetLanguage { settings.language }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                NextSettingsHeader(language: language, currentPage: selectedPage)
            }
            pageNavigation
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedPage.title(language))
                            .font(.system(size: 15, weight: .semibold))
                        Text(selectedPage.detail(language))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityAddTraits(.isHeader)
                    pageContent
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, compact ? 36 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("next.settings.page.\(selectedPage.rawValue)")
            }
            .id(selectedPage)
            .frame(maxHeight: .infinity)
        }
        .frame(width: compact ? CodexAccountMenuView.preferredSize.width : 480, alignment: .topLeading)
        .frame(maxHeight: compact ? .infinity : nil)
        .appVisualEnvironment(
            catalog: settings.paletteCatalog,
            paletteID: settings.paletteID,
            appearance: PaletteAppearance(colorScheme)
        )
        .readableForegroundHierarchy(colorScheme)
        .onAppear { AHSettingsHeaderContext.shared.currentPage = selectedPage }
        .onChange(of: selectedPage) { page in
            AHSettingsHeaderContext.shared.currentPage = page
        }
        .onDisappear { AHSettingsHeaderContext.shared.currentPage = nil }
    }

    private var pageNavigation: some View {
        HStack(spacing: 2) {
            ForEach(SettingsPage.allCases) { page in
                Button {
                    selectedPage = page
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: page.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(height: 16)
                        Text(page.title(language))
                            .font(.system(size: 9.5, weight: selectedPage == page ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedPage == page ? visualTokens.accent.primary.color : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous)
                            .fill(selectedPage == page ? visualTokens.accent.primary.color.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.title(language))
                .accessibilityAddTraits(selectedPage == page ? .isSelected : [])
                .accessibilityIdentifier("next.settings.tab.\(page.rawValue)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch selectedPage {
        case .appearance: appearancePage
        case .menuBar:
            VStack(spacing: 6) {
                StatusItemSettingsView(settings: settings, store: store)
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
                title: language.text("数据来源", "Data sources"),
                detail: language.text("至少保留一个 Runtime；不重复导入历史记录", "Keep at least one source. Existing history is not counted twice.")
            ) {
                SettingsRuntimeMultiSelectControl(
                    selectedScopes: settings.visibleRuntimeScopes, language: language
                ) { scope in
                    settings.setRuntime(scope, visible: !settings.isRuntimeVisible(scope))
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
                            .fill(Color.primary.opacity(selection == mode ? 0.06 : 0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: settingsControlCornerRadius, style: .continuous)
                            .strokeBorder(
                                selection == mode ? visualTokens.accent.primary.color : Color.primary.opacity(0.08),
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
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
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
