import AppKit
import SwiftUI

/// Compact quota bubble. Geometry comes from the vendored token-monitor
/// floatingBubble.js port; the chrome stays in the host so the WebView is not
/// given file or process access.
struct TokenMonitorFloatingBubbleView: View {
    var snapshot: TokenMonitorFloatingBubbleSnapshot
    var preferences: TokenMonitorFloatingBubblePreferences
    var collapsed: Bool
    var side: String
    var language: WidgetLanguage
    var onToggle: () -> Void
    var onOpenEditor: () -> Void
    @Environment(\.visualTokens) private var tokens

    var body: some View {
        Group {
            if collapsed {
                collapsedHandle
            } else {
                expandedCard
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("用量悬浮窗", "Usage floating bubble"))
    }

    private var collapsedHandle: some View {
        Button(action: onToggle) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    if tokens.identity.paletteID != PaletteCatalog.defaultPaletteID {
                        WorkspaceGlassBackdrop()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .overlay { Capsule().fill(Color.accentColor).frame(width: 4, height: 18) }
                .frame(width: TokenMonitorFloatingBubbleGeometry.handleWidth, height: TokenMonitorFloatingBubbleGeometry.handleHeight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("展开悬浮窗", "Expand floating bubble"))
        .help(language.text("展开悬浮窗", "Expand floating bubble"))
    }

    private var expandedCard: some View {
        VStack(alignment: side == "right" ? .trailing : .leading, spacing: 8) {
            HStack(spacing: 8) {
                if preferences.showIcon {
                    ProviderMark(providerID: snapshot.providerID, slot: .navigation)
                }
                Text(snapshot.providerName).font(font.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onOpenEditor) {
                    Image(systemName: "slider.horizontal.3").font(.caption)
                }.buttonStyle(.plain).help(language.text("自定义悬浮窗", "Customize bubble"))
                Button(action: onToggle) {
                    Image(systemName: side == "right" ? "chevron.right" : "chevron.left").font(.caption)
                }.buttonStyle(.plain).help(language.text("收起", "Collapse"))
            }
            if !snapshot.accountName.isEmpty {
                Text(snapshot.accountName).font(font).lineLimit(1)
            }
            if !snapshot.metricName.isEmpty {
                Text(snapshot.metricName).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if preferences.showPercent || preferences.showQuotaBar {
                    if let value = snapshot.valueLabel {
                        if preferences.showPercent { Text(value).font(valueFont) }
                    } else {
                        QuotaPercentageRing(percent: displayedPercent, diameter: 48, showsValue: preferences.showPercent)
                    }
                }
                Spacer()
                if preferences.showResetTime {
                    Text(snapshot.resetLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if preferences.showCost && snapshot.hasCost {
                Text(snapshot.costLabel).font(.caption2).foregroundStyle(.secondary)
            }
            if !preferences.customText.isEmpty {
                Text(preferences.customText).font(font).foregroundStyle(.secondary).lineLimit(2)
            }
            if let fetchedAt = snapshot.fetchedAt {
                Text(language.dateTime(fetchedAt)).font(.caption2).foregroundStyle(.secondary)
            }
            if snapshot.isStale {
                Text(language.text("数据已过期", "Stale data")).font(.caption2).foregroundStyle(.secondary)
            }
            if snapshot.isUnavailable {
                Text(language.text("暂不可用", "Unavailable")).font(.caption2).foregroundStyle(.secondary)
            } else if snapshot.isUnknown {
                Text(language.text("暂无数据", "No data yet")).font(.caption2).foregroundStyle(.secondary)
            } else if displayedPercent == 0 {
                Text(language.text("当前为 0", "Currently 0")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: side == "right" ? .trailing : .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial)
                if tokens.identity.paletteID != PaletteCatalog.defaultPaletteID {
                    WorkspaceGlassBackdrop()
                    WorkspaceGlassSurface(cornerRadius: 12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }

    private var percentText: String {
        if snapshot.isUnknown || snapshot.isUnavailable { return "—" }
        if let label = snapshot.valueLabel { return label }
        guard let percent = displayedPercent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    private var displayedPercent: Double? {
        snapshot.displayedPercent(valueMode: preferences.valueMode)
    }

    private var valueFont: Font {
        switch preferences.fontStyle {
        case "normal": return .system(size: 20, weight: .regular)
        case "condensed": return .system(size: 18, weight: .semibold).width(.condensed)
        case "compactMono": return .system(size: 16, weight: .medium, design: .monospaced)
        default: return .system(size: 14, weight: .semibold).monospacedDigit()
        }
    }

    private var font: Font {
        switch preferences.fontStyle {
        case "normal": return .body
        case "condensed": return .system(size: 13, weight: .medium).width(.condensed)
        case "compactMono": return .system(size: 12, design: .monospaced)
        default: return .caption
        }
    }
}

struct TokenMonitorFloatingBubbleEditor: View {
    @Binding var preferences: TokenMonitorFloatingBubblePreferences
    var snapshot: TokenMonitorFloatingBubbleSnapshot
    var language: WidgetLanguage
    var providers: [AgentNavProvider]
    var sources: [TokenMonitorFloatingBubbleAccount]
    var embeddedInSettings: Bool
    var previewUsesSyntheticData: Bool
    var onShowDesktop: () -> Void
    var onCancel: () -> Void
    var onDone: () -> Void

    @State private var session: TokenMonitorFloatingBubbleDraft

    init(
        preferences: Binding<TokenMonitorFloatingBubblePreferences>,
        snapshot: TokenMonitorFloatingBubbleSnapshot,
        language: WidgetLanguage,
        providers: [AgentNavProvider],
        previewUsesSyntheticData: Bool = true,
        sources: [TokenMonitorFloatingBubbleAccount] = [],
        embeddedInSettings: Bool = false,
        onShowDesktop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self._preferences = preferences
        self.snapshot = snapshot
        self.language = language
        self.providers = providers
        self.sources = sources
        self.embeddedInSettings = embeddedInSettings
        self.previewUsesSyntheticData = previewUsesSyntheticData
        self.onShowDesktop = onShowDesktop
        self.onCancel = onCancel
        self.onDone = onDone
        _session = State(initialValue: TokenMonitorFloatingBubbleDraft(preferences: preferences.wrappedValue))
    }

    private var draftSnapshot: TokenMonitorFloatingBubbleSnapshot {
        TokenMonitorFloatingBubbleProjection.resolve(preferences: session.preferences, sources: sources)
    }

    var body: some View {
        Group {
            if embeddedInSettings {
                VStack(alignment: .leading, spacing: 20) {
                    preview.frame(maxWidth: .infinity)
                    controls
                    Divider()
                    editorActions
                }
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 12) {
                        ScrollView(.vertical) {
                            editorContent(width: geometry.size.width - 40)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                        editorActions
                    }
                    .padding(20)
                }
            }
        }
    }

    @ViewBuilder
    private func editorContent(width: CGFloat) -> some View {
        if width >= 680 {
            HStack(alignment: .top, spacing: 20) {
                preview
                controls.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                controls
                preview.frame(maxWidth: .infinity)
            }
        }
    }

    private var preview: some View {
        TokenMonitorFloatingBubbleView(
            snapshot: draftSnapshot,
            preferences: session.preferences,
            collapsed: false,
            side: "left",
            language: language,
            onToggle: {},
            onOpenEditor: {}
        )
        .allowsHitTesting(false)
        .disabled(true)
        .accessibilityLabel(language.text("只读悬浮窗预览", "Read-only floating bubble preview"))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("自定义悬浮窗", "Customize floating bubble")).font(.headline)
            Toggle(language.text("显示图标", "Show icon"), isOn: $session.preferences.showIcon)
            Toggle(language.text("显示额度环", "Show quota ring"), isOn: $session.preferences.showQuotaBar)
            Toggle(language.text("显示百分比", "Show percent"), isOn: $session.preferences.showPercent)
            Toggle(language.text("显示恢复时间", "Show reset time"), isOn: $session.preferences.showResetTime)
            if draftSnapshot.hasCost {
                Toggle(language.text("显示费用", "Show cost"), isOn: $session.preferences.showCost)
            }
            FloatingBubbleSelectionFields(preferences: $session.preferences, sources: sources, language: language)
            Picker(language.text("数值", "Value"), selection: $session.preferences.valueMode) {
                Text(language.text("剩余", "Remaining")).tag("remaining")
                Text(language.text("已用", "Used")).tag("used")
            }
            TextField(language.text("自定义文字", "Custom text"), text: $session.preferences.customText)
                .textFieldStyle(.roundedBorder)
            Picker(language.text("字体", "Font"), selection: $session.preferences.fontStyle) {
                Text(language.text("菜单栏", "Menu bar")).tag("menubar")
                Text(language.text("常规", "Regular")).tag("normal")
                Text(language.text("压缩", "Condensed")).tag("condensed")
                Text(language.text("等宽", "Monospace")).tag("compactMono")
            }
            Text(
                previewUsesSyntheticData
                    ? language.text("预览使用合成数据；不会登录、通知或改真实账号。", "Preview uses synthetic data. It does not sign in, notify or change real accounts.")
                    : language.text("预览使用当前已获取的数据；缺失数据会显示为待获取。", "Preview uses currently available data; missing data is shown as pending.")
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorActions: some View {
        HStack {
            Button(
                preferences.enabled
                    ? language.text("隐藏悬浮窗", "Hide floating bubble")
                    : language.text("在桌面显示", "Show on desktop")
            ) {
                if preferences.enabled {
                    preferences.enabled = false
                } else {
                    preferences = session.saved(enabled: true)
                    onShowDesktop()
                }
            }
            Spacer()
            Button(language.text("取消", "Cancel")) {
                session.cancel(saved: preferences)
                onCancel()
            }
            Button(embeddedInSettings ? language.text("保存", "Save") : language.text("完成", "Done")) {
                preferences = session.saved(enabled: preferences.enabled)
                onDone()
            }.keyboardShortcut(.defaultAction)
        }
    }
}

private struct FloatingBubbleSelectionFields: View {
    @Binding var preferences: TokenMonitorFloatingBubblePreferences
    var sources: [TokenMonitorFloatingBubbleAccount]
    var language: WidgetLanguage

    private var providers: [TokenMonitorFloatingBubbleAccount] {
        var seen = Set<String>()
        return sources.filter { $0.isLoggedIn && seen.insert($0.providerID).inserted }
    }

    private var accounts: [TokenMonitorFloatingBubbleAccount] {
        TokenMonitorFloatingBubbleProjection.accounts(in: sources, providerID: preferences.selectedProviderID)
    }

    private var metrics: [TokenMonitorFloatingBubbleMetric] {
        accounts.first { $0.accountID == preferences.selectedProfileID }?.metrics ?? []
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker(
                language.text("显示平台", "Display provider"),
                selection: Binding(
                    get: { preferences.selectedProviderID ?? "" },
                    set: {
                        preferences.selectedProviderID = $0
                        preferences.selectedProfileID = nil
                        preferences.selectedMetricID = nil
                    }
                )
            ) {
                Text(language.text("请选择 / 暂不可用", "Select / unavailable"))
                    .tag(providers.contains { $0.providerID == preferences.selectedProviderID } ? "" : preferences.selectedProviderID ?? "")
                ForEach(providers, id: \.providerID) { Text($0.providerName).tag($0.providerID) }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 0, maxWidth: .infinity)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityValue(providers.first { $0.providerID == preferences.selectedProviderID }?.providerName ?? language.text("请选择 / 暂不可用", "Select / unavailable"))
            .help(providers.first { $0.providerID == preferences.selectedProviderID }?.providerName ?? language.text("请选择 / 暂不可用", "Select / unavailable"))
            Picker(
                language.text("显示账号", "Display account"),
                selection: Binding(
                    get: { preferences.selectedProfileID ?? "" },
                    set: {
                        preferences.selectedProfileID = $0
                        preferences.selectedMetricID = nil
                    }
                )
            ) {
                Text(language.text("请选择 / 暂不可用", "Select / unavailable"))
                    .tag(accounts.contains { $0.accountID == preferences.selectedProfileID } ? "" : preferences.selectedProfileID ?? "")
                ForEach(accounts, id: \.accountID) { Text($0.accountName).tag($0.accountID) }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 0, maxWidth: .infinity)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityValue(accounts.first { $0.accountID == preferences.selectedProfileID }?.accountName ?? language.text("请选择 / 暂不可用", "Select / unavailable"))
            .help(accounts.first { $0.accountID == preferences.selectedProfileID }?.accountName ?? language.text("请选择 / 暂不可用", "Select / unavailable"))
            Picker(
                language.text("显示指标", "Display metric"),
                selection: Binding(
                    get: { preferences.selectedMetricID ?? "" },
                    set: { preferences.selectedMetricID = $0 }
                )
            ) {
                Text(language.text("请选择 / 暂不可用", "Select / unavailable"))
                    .tag(metrics.contains { $0.id == preferences.selectedMetricID } ? "" : preferences.selectedMetricID ?? "")
                ForEach(metrics) { metric in
                    Text(metric.name + (metric.isAvailable ? "" : language.text(" · 暂不可用", " · Unavailable")))
                        .tag(metric.id)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 0, maxWidth: .infinity)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityValue(metrics.first { $0.id == preferences.selectedMetricID }?.name ?? language.text("请选择 / 暂不可用", "Select / unavailable"))
            .help(metrics.first { $0.id == preferences.selectedMetricID }?.name ?? language.text("请选择 / 暂不可用", "Select / unavailable"))
        }
    }
}

@MainActor
protocol TokenMonitorFloatingBubbleSessionOwner: AnyObject {
    func showFloatingBubble(settings: AppSettings, language: WidgetLanguage)
}

@MainActor
enum TokenMonitorFloatingBubbleSession {
    static weak var owner: (any TokenMonitorFloatingBubbleSessionOwner)?

    static func show(settings: AppSettings, language: WidgetLanguage) {
        owner?.showFloatingBubble(settings: settings, language: language)
    }
}

@MainActor
final class TokenMonitorFloatingBubbleController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hosting: NSHostingView<NativePaletteRoot<TokenMonitorFloatingBubbleView>>?
    private var expanded = TokenMonitorFloatingBubbleGeometry.Rect(x: 80, y: 120, width: 304, height: 168)
    private var collapsed: TokenMonitorFloatingBubbleGeometry.Rect?
    private var isCollapsed = false
    private var side = "left"
    var language: WidgetLanguage = .zh
    var paletteCatalog = PaletteCatalog.loadFromMainBundle()
    var paletteID = PaletteCatalog.defaultPaletteID
    var preferredColorScheme: ColorScheme?
    var glass = WorkspaceGlassPreferences()
    var snapshot = TokenMonitorFloatingBubbleSnapshot(
        providerID: "codex", providerName: "Codex", percentRemaining: nil,
        resetLabel: "—", costLabel: "—", customText: "",
        isUnknown: true, isZero: false
    )
    var preferences = TokenMonitorFloatingBubblePreferences()

    var onOpenEditor: (() -> Void)?

    func show() {
        let workArea = currentWorkArea()
        let bounds =
            isCollapsed
            ? (collapsed ?? TokenMonitorFloatingBubbleGeometry.collapsedBounds(expanded, workArea: workArea) ?? expanded)
            : expanded
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { apply(bounds, on: panel) }
        refreshContent()
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    func shutdown() {
        onOpenEditor = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        hosting = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        if isCollapsed { collapsed = rect(from: panel) } else { expanded = rect(from: panel) }
    }

    func toggle() {
        let workArea = currentWorkArea()
        if isCollapsed {
            if let restored = TokenMonitorFloatingBubbleGeometry.expandedBounds(
                collapsed: collapsed, workArea: workArea, previousExpanded: expanded
            ) {
                expanded = restored
            }
            isCollapsed = false
        } else if let plan = TokenMonitorFloatingBubbleGeometry.collapsePlan(
            bounds: panel.map { rect(from: $0) } ?? expanded,
            workArea: workArea,
            settings: .init(floatingBubbleEnabled: true, windowBehavior: "floating"),
            previousCollapsed: collapsed
        ) {
            expanded = plan.expandedBounds
            collapsed = plan.collapsedBounds
            side = plan.side
            isCollapsed = true
        }
        if let panel {
            apply(isCollapsed ? (collapsed ?? expanded) : expanded, on: panel)
        }
        show()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 80, y: 120, width: 304, height: 168),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        return panel
    }

    func refreshContent() {
        guard let panel else { return }
        let content = TokenMonitorFloatingBubbleView(
            snapshot: snapshot,
            preferences: preferences,
            collapsed: isCollapsed,
            side: side,
            language: language,
            onToggle: { [weak self] in self?.toggle() },
            onOpenEditor: { [weak self] in self?.onOpenEditor?() }
        )
        let view = NativePaletteRoot(
            content: content, catalog: paletteCatalog, paletteID: paletteID,
            preferredColorScheme: preferredColorScheme, glass: glass
        )
        if let hosting {
            hosting.rootView = view
            fitExpandedContent(hosting, panel: panel)
            return
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = host
        hosting = host
        fitExpandedContent(host, panel: panel)
    }

    private func fitExpandedContent(_ host: NSHostingView<NativePaletteRoot<TokenMonitorFloatingBubbleView>>, panel: NSPanel) {
        guard !isCollapsed else { return }
        let height = max(168, ceil(host.fittingSize.height))
        guard height.isFinite, abs(expanded.height - height) > 1 else { return }
        expanded.height = height
        if let bounded = TokenMonitorFloatingBubbleGeometry.clampBounds(expanded, workArea: currentWorkArea()) {
            expanded = bounded
        }
        apply(expanded, on: panel)
    }

    private func apply(_ bounds: TokenMonitorFloatingBubbleGeometry.Rect, on panel: NSPanel) {
        let screen = NSScreen.main?.frame ?? .zero
        // JS y is top-origin; AppKit y is bottom-origin.
        let y = screen.height - bounds.y - bounds.height
        panel.setFrame(NSRect(x: bounds.x, y: y, width: bounds.width, height: bounds.height), display: true)
    }

    private func rect(from panel: NSPanel) -> TokenMonitorFloatingBubbleGeometry.Rect {
        let screen = NSScreen.main?.frame ?? .zero
        let frame = panel.frame
        return .init(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
    }

    private func currentWorkArea() -> TokenMonitorFloatingBubbleGeometry.Rect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screen = NSScreen.main?.frame ?? visible
        return .init(
            x: visible.minX,
            y: screen.height - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }
}
