import AppKit
import SwiftUI

/// The native outline uses the same 64/28/20 rail and 280/12/18 card
/// dimensions as the vendored Edge Dock. A single system material is clipped
/// to each silhouette, including the rail shoulders and detail-card tail.
private struct EdgeDockRailShape: Shape {
    let side: TokenMonitorEdgeDockPreferences.Side

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let shoulder = min(28, h / 2)
        let spread = min(w * 0.53, w - 20)
        let radius = max(0, min(20, (h - 2 * shoulder) / 2, w - spread))
        let arc: CGFloat = 0.448
        var path = Path()
        path.move(to: CGPoint(x: w, y: 0))
        path.addCurve(
            to: CGPoint(x: w - spread, y: shoulder),
            control1: CGPoint(x: w, y: shoulder * 0.76),
            control2: CGPoint(x: w - w * 0.25, y: shoulder))
        path.addLine(to: CGPoint(x: radius, y: shoulder))
        path.addCurve(
            to: CGPoint(x: 0, y: shoulder + radius),
            control1: CGPoint(x: radius * arc, y: shoulder),
            control2: CGPoint(x: 0, y: shoulder + radius * arc))
        path.addLine(to: CGPoint(x: 0, y: h - shoulder - radius))
        path.addCurve(
            to: CGPoint(x: radius, y: h - shoulder),
            control1: CGPoint(x: 0, y: h - shoulder - radius * arc),
            control2: CGPoint(x: radius * arc, y: h - shoulder))
        path.addLine(to: CGPoint(x: w - spread, y: h - shoulder))
        path.addCurve(
            to: CGPoint(x: w, y: h),
            control1: CGPoint(x: w - w * 0.25, y: h - shoulder),
            control2: CGPoint(x: w, y: h - shoulder * 0.76))
        path.closeSubpath()
        if side == .left {
            return path.applying(CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1))
        }
        return path
    }
}

private struct EdgeDockCardShape: Shape {
    let side: TokenMonitorEdgeDockPreferences.Side
    let tailY: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let tail: CGFloat = 12
        let body = w - tail
        let radius = min(18, h / 2, body / 2)
        let neck = min(18, (h - 2 * radius) / 2)
        let tipY = max(radius + neck, min(h - radius - neck, tailY))
        let tipX = max(body, w - 1)
        let arc: CGFloat = 0.448
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: body - radius, y: 0))
        path.addCurve(
            to: CGPoint(x: body, y: radius),
            control1: CGPoint(x: body - radius * arc, y: 0),
            control2: CGPoint(x: body, y: radius * arc))
        path.addLine(to: CGPoint(x: body, y: tipY - neck))
        path.addCurve(
            to: CGPoint(x: tipX, y: tipY),
            control1: CGPoint(x: body, y: tipY - neck * 0.4),
            control2: CGPoint(x: body + tail * 0.5, y: tipY - 1.5))
        path.addCurve(
            to: CGPoint(x: body, y: tipY + neck),
            control1: CGPoint(x: body + tail * 0.5, y: tipY + 1.5),
            control2: CGPoint(x: body, y: tipY + neck * 0.4))
        path.addLine(to: CGPoint(x: body, y: h - radius))
        path.addCurve(
            to: CGPoint(x: body - radius, y: h),
            control1: CGPoint(x: body, y: h - radius * arc),
            control2: CGPoint(x: body - radius * arc, y: h))
        path.addLine(to: CGPoint(x: radius, y: h))
        path.addCurve(
            to: CGPoint(x: 0, y: h - radius),
            control1: CGPoint(x: radius * arc, y: h),
            control2: CGPoint(x: 0, y: h - radius * arc))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addCurve(
            to: CGPoint(x: radius, y: 0),
            control1: CGPoint(x: 0, y: radius * arc),
            control2: CGPoint(x: radius * arc, y: 0))
        path.closeSubpath()
        if side == .left {
            return path.applying(CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1))
        }
        return path
    }
}

private struct EdgeDockPeekShape: Shape {
    let side: TokenMonitorEdgeDockPreferences.Side

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: 12), control: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: rect.height - 12))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height), control: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        if side == .left {
            return path.applying(CGAffineTransform(translationX: rect.width, y: 0).scaledBy(x: -1, y: 1))
        }
        return path
    }
}

private final class EdgeDockHUDView: NSVisualEffectView {
    var outlinePath: ((CGSize) -> CGPath)?
    private var maskedSize: CGSize = .zero

    override func layout() {
        super.layout()
        guard bounds.size.width > 0, bounds.size.height > 0,
            bounds.size != maskedSize, let outlinePath
        else { return }
        maskedSize = bounds.size
        let size = bounds.size
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.addPath(outlinePath(size))
            context.setFillColor(NSColor.white.cgColor)
            context.fillPath()
            return true
        }
        maskImage = image
    }

    func updateMask() {
        maskedSize = .zero
        needsLayout = true
    }
}

private struct EdgeDockHUDMaterial<Outline: Shape>: NSViewRepresentable {
    let outline: Outline

    func makeNSView(context: Context) -> EdgeDockHUDView {
        let view = EdgeDockHUDView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: EdgeDockHUDView, context: Context) {
        view.outlinePath = { size in outline.path(in: CGRect(origin: .zero, size: size)).cgPath }
        view.updateMask()
    }
}

private struct EdgeDockGlass<Content: View, Outline: Shape>: View {
    let outline: Outline
    let glass: WorkspaceGlassPreferences
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.visualTokens) private var tokens

    var body: some View {
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    outline.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    if glass.systemGlass { EdgeDockHUDMaterial(outline: outline) }
                    outline.fill(
                        colorScheme == .dark
                            ? Color(red: 48 / 255, green: 52 / 255, blue: 56 / 255).opacity(glass.tintOpacity)
                            : Color(red: 246 / 255, green: 247 / 255, blue: 250 / 255).opacity(glass.tintOpacity))
                    if tokens.identity.paletteID != PaletteCatalog.defaultPaletteID {
                        WorkspaceGlassBackdrop().environment(\.workspaceGlass, glass)
                    }
                }
                outline.stroke(Color.primary.opacity(glass.lineOpacity), lineWidth: 0.6)
            }
            .clipShape(outline)
            .contentShape(outline)
    }
}

/// The collapsed handle owns the mouse-down that reveals the rail. Consuming
/// it here prevents the same press from activating a newly revealed cell.
private struct EdgeDockRevealMouseView: NSViewRepresentable {
    let onReveal: () -> Void

    final class MouseView: NSView {
        var onReveal: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onReveal() }
    }

    func makeNSView(context: Context) -> MouseView {
        let view = MouseView()
        view.onReveal = onReveal
        return view
    }

    func updateNSView(_ view: MouseView, context: Context) { view.onReveal = onReveal }
}

private struct EdgeDockRunningArc: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            Circle().trim(from: 0, to: 0.25)
                .stroke(Color.primary.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 28, height: 28)
                .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TokenMonitorEdgeDockPeekView: View {
    let side: TokenMonitorEdgeDockPreferences.Side
    let language: WidgetLanguage
    var glass = WorkspaceGlassPreferences()
    var scale: CGFloat = 1
    var isNearby = false
    let onReveal: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onReveal) {
            Capsule()
                .fill(Color.primary.opacity(isNearby ? 0.48 : 0.26))
                .frame(width: max(5, ((isNearby ? 8 : 6) * scale).rounded()),
                       height: ((isNearby ? 80 : 72) * scale).rounded())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .right ? .trailing : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { EdgeDockRevealMouseView(onReveal: onReveal).accessibilityHidden(true) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isNearby)
        .help(language.text("展开侧边栏", "Reveal Edge Dock"))
        .accessibilityLabel(language.text("展开侧边栏", "Reveal Edge Dock"))
        .accessibilityIdentifier("edge-dock-peek")
    }
}

struct TokenMonitorEdgeDockRailView: View {
    let cells: [TokenMonitorEdgeDockCell]
    let side: TokenMonitorEdgeDockPreferences.Side
    let language: WidgetLanguage
    var glass = WorkspaceGlassPreferences()
    let compact: Bool
    let warnColors: Bool
    let focusedIndex: Int?
    var pageIndex = 0
    var pageCount = 1
    var quotaStyle: TokenMonitorEdgeDockPreferences.QuotaStyle = .ring
    var isPinned = false
    var scale: CGFloat = 1
    var viewportHeight: CGFloat? = nil
    var refreshEnabled = false
    var isRefreshing = false
    var runningIndicatorEnabled = true
    var onRefreshAll: (() -> Void)? = nil
    var onPin: () -> Void = {}
    var onPage: (Int) -> Void = { _ in }
    let onSelect: (Int) -> Void
    let onDrag: (CGSize) -> Void
    let onDrop: (CGSize) -> Void

    private var cellHeight: CGFloat { compact ? 54 : 70 }

    var body: some View {
        railContent
            .frame(width: 64, height: viewportHeight, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: 64 * scale, height: viewportHeight.map { $0 * scale }, alignment: .topLeading)
    }

    private var railContent: some View {
        EdgeDockGlass(
            outline: EdgeDockRailShape(side: side),
            glass: glass,
            content:
                VStack(spacing: 2) {
                    ForEach(cells.indices, id: \.self) { index in
                        let cell = cells[index]
                        Button {
                            onSelect(index)
                        } label: {
                            cellView(cell, focused: focusedIndex == index)
                                .frame(width: 56, height: cell.kind == .stat ? (compact ? 48 : 56) : cellHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(cell.kind == .proxy ? "\(cell.title) · \(cell.proxyStatusTitle(language))" : cell.title)
                        .accessibilityLabel(cell.title)
                        .accessibilityValue(accessibilityValue(cell))
                        .accessibilityIdentifier(cell.kind == .proxy ? "edge-dock-proxy" : "edge-dock-item-\(index)")
                    }
                }
                .padding(.top, 32)
                .padding(.bottom, refreshEnabled ? 64 : 32)
                .frame(width: 64)
                .frame(maxHeight: .infinity, alignment: .top)
        )
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 30, height: 28)
                .padding(.leading, 3)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { onDrag(CGSize(width: $0.translation.width * scale, height: $0.translation.height * scale)) }
                        .onEnded { onDrop(CGSize(width: $0.translation.width * scale, height: $0.translation.height * scale)) }
                )
                .accessibilityLabel(language.text("拖动侧边栏", "Drag Edge Dock"))
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onPin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(language.text(isPinned ? "隐藏侧边栏 · ⌘I" : "固定侧边栏 · ⌘I", isPinned ? "Hide Edge Dock · ⌘I" : "Pin Edge Dock · ⌘I"))
            .accessibilityLabel(language.text(isPinned ? "隐藏侧边栏" : "固定侧边栏", isPinned ? "Hide Edge Dock" : "Pin Edge Dock"))
            .accessibilityIdentifier("edge-dock-rail-pin")
            .padding(.trailing, 3)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 4) {
                if pageCount > 1 {
                HStack(spacing: 3) {
                    Button {
                        onPage(-1)
                    } label: {
                        Image(systemName: "chevron.up").frame(width: 18, height: 24)
                    }
                    .disabled(pageIndex == 0)
                    .accessibilityLabel(language.text("上一页账号", "Previous accounts"))
                    Text("\(pageIndex + 1)/\(pageCount)").font(.system(size: 8)).monospacedDigit()
                    Button {
                        onPage(1)
                    } label: {
                        Image(systemName: "chevron.down").frame(width: 18, height: 24)
                    }
                    .disabled(pageIndex + 1 == pageCount)
                    .accessibilityLabel(language.text("下一页账号", "Next accounts"))
                }
                .font(.system(size: 10)).buttonStyle(.plain)
                }
                if refreshEnabled {
                    Button { onRefreshAll?() } label: {
                        Group {
                            if isRefreshing {
                                ProgressView().controlSize(.small).scaleEffect(0.65)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                            }
                        }
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing || onRefreshAll == nil)
                    .help(language.text("刷新用量和额度", "Refresh usage and quotas"))
                    .accessibilityLabel(language.text("刷新用量和额度", "Refresh usage and quotas"))
                    .accessibilityIdentifier("edge-dock-refresh-all")
                }
            }
            .padding(.bottom, 4)
        }
        .accessibilityIdentifier("edge-dock-rail")
    }

    @ViewBuilder
    private func cellView(_ cell: TokenMonitorEdgeDockCell, focused: Bool) -> some View {
        if cell.kind == .proxy {
            Image(systemName: "network")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(proxyColor(cell))
                .frame(width: 42, height: 42)
                .background(proxyColor(cell).opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(proxyColor(cell)).frame(width: 7, height: 7)
                        .overlay { Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5) }
                        .offset(x: -1, y: -1)
                }
                .overlay {
                    if runningIndicatorEnabled && cell.activeWorkCount > 0 { EdgeDockRunningArc() }
                }
        } else if cell.kind == .provider {
            VStack(spacing: 2) {
                ZStack {
                    if cell.providerID == "codex", cell.headlineMetricID == "five-hour", cell.headlineValueLabel == "∞" {
                        QuotaPercentageRing(percent: nil, diameter: 42, lineWidth: focused ? 4.5 : 3.5, isWeeklyOnlyPro: true)
                            .help(QuotaAvailabilityPresentation.weeklyOnlyProHelp(language))
                    } else if cell.headlineValueLabel == nil, quotaStyle == .fish {
                        QuotaFishView(
                            percentRemaining: cell.percentRemaining,
                            tint: warnColors && (cell.severityRemainingPercent ?? 100) < 20
                                ? Color(red: 0.88, green: 0.48, blue: 0.31) : providerColor(cell.providerID),
                            language: language, compact: true)
                    } else if cell.headlineValueLabel == nil {
                        QuotaPercentageRing(
                            percent: cell.percentRemaining, diameter: 42, lineWidth: focused ? 4.5 : 3.5,
                            tint: warnColors && (cell.severityRemainingPercent ?? 100) < 20
                                ? Color(red: 0.88, green: 0.48, blue: 0.31) : providerColor(cell.providerID))
                    } else if let providerID = cell.providerID {
                        ProviderMark(providerID: providerID, slot: .card)
                    }
                }
                .frame(width: 42, height: 42)
                .overlay {
                    if runningIndicatorEnabled && cell.activeWorkCount > 0 { EdgeDockRunningArc() }
                }
                .overlay(alignment: .topTrailing) {
                    if let label = cell.accountBadge {
                        Text(label)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.black.opacity(0.75), in: Capsule())
                            .offset(x: 3, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                Text(
                    cell.providerID == "codex" && cell.headlineMetricID == "seven-day"
                        ? language.text("7 天", "7d")
                        : cell.providerID == "codex" && cell.headlineMetricID == "five-hour"
                            ? language.text("5 小时", "5h") : (cell.headlineValueLabel ?? cell.title)
                )
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: 56)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(focused ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(spacing: 2) {
                Text(cell.metric == .liveRate ? (cell.liveRate?.unit ?? "TPM") : cell.title.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(statisticValue(cell, compact: true))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(
                    cell.metric == .liveRate
                        ? liveRateStateLabel(cell)
                        : TokenMonitorFormatting.cost(cell.costUSD, compact: true, language: language)
                )
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(focused ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func proxyColor(_ cell: TokenMonitorEdgeDockCell) -> Color {
        switch cell.proxyPhase {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .stopped, nil: return .secondary
        }
    }

    private func accessibilityValue(_ cell: TokenMonitorEdgeDockCell) -> String {
        if cell.kind == .proxy { return cell.proxyStatusTitle(language) }
        guard cell.isAvailable else {
            return cell.providerID == "grok" || cell.providerID == "claude"
                ? providerHeadline(cell) : language.text("暂不可用", "Unavailable")
        }
        return cell.kind == .stat
            ? statisticValue(cell, compact: false)
            : providerHeadline(cell)
    }

    private func providerHeadline(_ cell: TokenMonitorEdgeDockCell) -> String {
        if let label = cell.headlineValueLabel { return label }
        if let percent = cell.percentRemaining { return percentText(percent) }
        guard cell.providerID == "grok" || cell.providerID == "claude" else { return "—" }
        return cell.isStale ? language.text("待刷新", "Refresh needed") : language.text("未知", "Unknown")
    }

    private func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func liveRateStateLabel(_ cell: TokenMonitorEdgeDockCell) -> String {
        guard let rate = cell.liveRate else { return language.text("等待", "WAIT") }
        return rate.isIdle ? language.text("上次", "LAST") : language.text("采样", "SAMPLE")
    }

    private func statisticValue(_ cell: TokenMonitorEdgeDockCell, compact: Bool) -> String {
        if cell.metric == .liveRate {
            guard let rate = cell.liveRate, rate.value.isFinite else { return "—" }
            return rate.formattedValue(language: language)
        }
        if cell.metric == .sessions {
            return cell.sessionCount.map(String.init) ?? "—"
        }
        return TokenMonitorFormatting.count(cell.tokenCount, compact: compact, language: language)
    }
}

private struct EdgeDockCardContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TokenMonitorEdgeDockCardView: View {
    let cell: TokenMonitorEdgeDockCell
    let side: TokenMonitorEdgeDockPreferences.Side
    let language: WidgetLanguage
    var glass = WorkspaceGlassPreferences()
    let tailY: CGFloat
    let isPinned: Bool
    let canPin: Bool
    let onPin: () -> Void
    let onOpenDashboard: () -> Void
    var onOpenProxy: () -> Void = {}
    var snapshotDescription: String? = nil
    var isRefreshing = false
    var quotaStyle: TokenMonitorEdgeDockPreferences.QuotaStyle = .ring
    var scale: CGFloat = 1
    var viewportHeight: CGFloat? = nil
    var onRefresh: (() -> Void)? = nil
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    @State private var byModel = false
    @State private var accountPage = 0

    private var paginatesAccounts: Bool {
        cell.kind == .provider && cell.providerID != "codex" && cell.accounts.count > 1
    }

    private var visibleAccounts: [TokenMonitorEdgeDockAccountRow] {
        guard paginatesAccounts else { return cell.accounts }
        return [cell.accounts[min(accountPage, cell.accounts.count - 1)]]
    }

    var body: some View {
        cardContent
            .frame(width: 292, height: viewportHeight, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: 292 * scale, height: viewportHeight.map { $0 * scale }, alignment: .topLeading)
    }

    private var cardContent: some View {
        EdgeDockGlass(
            outline: EdgeDockCardShape(side: side, tailY: tailY),
            glass: glass,
            content:
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 9) {
                        header
                        if cell.kind != .proxy {
                            Text(snapshotDescription ?? cell.snapshotDescription(language))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("edge-dock-snapshot-age")
                        }
                        if cell.kind == .proxy {
                            proxyContent
                        } else if cell.metric == .liveRate {
                            liveRateContent
                        } else if cell.metric == .sessions {
                            sessionsContent
                        } else if cell.kind == .stat {
                            statisticsContent
                        } else {
                            limitsContent
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                    .padding(.leading, side == .left ? 24 : 14)
                    .padding(.trailing, side == .right ? 24 : 14)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: EdgeDockCardContentHeightKey.self, value: geometry.size.height)
                        }
                    }
                }
        )
        .onPreferenceChange(EdgeDockCardContentHeightKey.self, perform: onContentHeightChange)
        .onChange(of: cell.id) { _ in accountPage = 0 }
        .onChange(of: cell.accounts.map(\.id)) { _ in accountPage = 0 }
        .environment(\.widgetLanguage, language)
        .accessibilityIdentifier("edge-dock-card")
    }

    private var header: some View {
        HStack(spacing: 5) {
            if cell.kind == .proxy {
                Image(systemName: "network").font(.system(size: 12))
            }
            Text(cell.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if paginatesAccounts {
                HStack(spacing: 3) {
                    Button {
                        accountPage = max(0, accountPage - 1)
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 18, height: 24)
                    }
                    .disabled(accountPage == 0)
                    .accessibilityLabel(language.text("上一个账号", "Previous account"))
                    Text("\(min(accountPage, cell.accounts.count - 1) + 1)/\(cell.accounts.count)")
                        .font(.system(size: 10)).monospacedDigit()
                    Button {
                        accountPage = min(cell.accounts.count - 1, accountPage + 1)
                    } label: {
                        Image(systemName: "chevron.right").frame(width: 18, height: 24)
                    }
                    .disabled(accountPage >= cell.accounts.count - 1)
                    .accessibilityLabel(language.text("下一个账号", "Next account"))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("edge-dock-account-pages")
            }
            Spacer(minLength: 4)
            if cell.kind == .proxy && !cell.proxyAccounts.isEmpty {
                Text(language.text("\(cell.proxyAccounts.count) 个账号", "\(cell.proxyAccounts.count) accounts"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if cell.kind == .stat && cell.metric != .liveRate && cell.metric != .sessions {
                HStack(spacing: 0) {
                    dimensionButton(language.text("工具", "Tools"), selected: !byModel) { byModel = false }
                    dimensionButton(language.text("模型", "Models"), selected: byModel) { byModel = true }
                }
                .padding(3)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            if cell.kind == .provider, let onRefresh {
                Button(action: onRefresh) {
                    ZStack {
                        if isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                        }
                    }
                    .frame(width: 24, height: 24)
                    .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).foregroundStyle(.blue).disabled(isRefreshing)
                .help(language.text("刷新额度", "Refresh quota"))
                .accessibilityLabel(language.text(isRefreshing ? "正在刷新额度" : "刷新额度", isRefreshing ? "Refreshing quota" : "Refresh quota"))
                .accessibilityIdentifier("edge-dock-card-refresh")
            }
            if canPin {
                Button(action: onPin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.blue)
                        .frame(width: 24, height: 24)
                        .background(Color.blue.opacity(isPinned ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(isPinned ? language.text("取消固定，移开鼠标后关闭", "Unpin to dismiss when the pointer leaves") : language.text("固定此详情并置顶", "Keep this detail on top"))
                .accessibilityLabel(isPinned ? language.text("取消固定详情", "Unpin detail") : language.text("固定详情", "Pin detail"))
                .accessibilityIdentifier("edge-dock-card-pin")
                .accessibilityValue(isPinned ? language.text("已固定", "Pinned") : language.text("未固定", "Not pinned"))
            }
        }
    }

    private func dimensionButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(selected ? Color.primary.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var proxyContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Circle().fill(cell.proxyRequestCount > 0 ? Color.green : Color.secondary)
                    .frame(width: 5, height: 5)
                Text(cell.proxyStatusTitle(language))
                Spacer(minLength: 4)
                if cell.proxyRequestCount > 0 {
                    Text(language.text("\(cell.proxyRequestCount) 个请求", "\(cell.proxyRequestCount) requests"))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10, weight: .medium))
            if cell.proxyAccounts.isEmpty {
                Text(
                    cell.proxyPhase == .running
                        ? language.text("上次快照没有活动请求", "No active requests in the last snapshot")
                        : language.text("没有活动账号记录", "No active accounts in this snapshot")
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
                ForEach(cell.proxyAccounts) { account in
                    Divider().opacity(0.5)
                    proxyAccount(account)
                }
                Text(language.text("请求快照每分钟更新 · 额度为最近一次读取", "Request snapshot updates every minute · Last reported quota"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Button(action: onOpenProxy) {
                Label(language.text("反代设置", "Proxy settings"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .accessibilityIdentifier("edge-dock-proxy-settings")
        }
        .accessibilityIdentifier("edge-dock-proxy-activity")
    }

    private func proxyAccount(_ account: LocalProxyQueueRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(account.accountNumber.map { String(format: "%02d", $0) } ?? "—")
                    .foregroundStyle(.secondary).monospacedDigit()
                Text(account.label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 3)
                Text(language.text("运行中", "Running"))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.green)
            }
            .font(.system(size: 11, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                ForEach(account.windows) { window in proxyWindow(window) }
            }
            HStack(spacing: 5) {
                if let balance = account.creditBalance {
                    CreditBalanceView(presentation: balance, compact: true)
                }
                Spacer(minLength: 3)
                if account.activeRequestCount > 1 {
                    Text(language.text("\(account.activeRequestCount) 个请求", "\(account.activeRequestCount) requests"))
                }
                if account.snapshotStale {
                    Text(language.text("额度待刷新", "Quota needs refresh"))
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func proxyWindow(_ window: LocalProxyQuotaWindow) -> some View {
        let remaining = window.remaining.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        let color = window.id == "5h" ? Color(red: 0.30, green: 0.66, blue: 0.73) : Color.purple
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                QuotaPercentageRing(percent: remaining, diameter: 36, tint: color)
                Text(window.id).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            if let reset = window.resetsAt {
                ResetCountdownText(deadline: reset, kind: .accountWindow, language: language, compact: true)
                    .font(.system(size: 8)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statisticsContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(TokenMonitorFormatting.count(cell.tokenCount, language: language))
                    .font(.system(size: 29, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .accessibilityLabel(language.text("精确 Token 总数", "Exact token total"))
                if cell.tokenCount != nil {
                    Text("≈ " + TokenMonitorFormatting.count(cell.tokenCount, compact: true, language: language))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(TokenMonitorFormatting.cost(cell.costUSD, language: language))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if cell.isStale {
                Text(language.text("上次记录 · 数据已过期", "Last recorded · Stale"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            let ranks = Array((byModel ? cell.byModel : cell.byTool).prefix(12))
            if ranks.isEmpty {
                Text(language.text("此期间暂无可核对的明细", "No verified breakdown for this period"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.vertical, 18)
            } else {
                ForEach(ranks, id: \.id) { rank in rankRow(rank) }
            }
            Button(action: onOpenDashboard) {
                HStack(spacing: 3) {
                    Text(language.text("打开完整统计", "Open full dashboard"))
                    Image(systemName: "arrow.up.right")
                }.font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    private var liveRateContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(cell.liveRate.map { $0.formattedValue(language: language) } ?? "—")
                .font(.system(size: 30, weight: .medium)).monospacedDigit()
            Text(cell.liveRate?.mode == .speed
                ? language.text("输出 Token / 秒", "Output tokens / second")
                : language.text("Token 消耗量 / 分钟 · TPM", "Token consumption / minute · TPM"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let rate = cell.liveRate {
                Text(language.text("采样时间：", "Sampled: ") + language.dateTime(rate.sampledAt))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if rate.isIdle {
                    Text(language.text("上次采样 · 等待新采样", "Last sample · Waiting for a new sample"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            } else {
                Text(language.text("等待可信的用量采样", "Waiting for a verified usage sample"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var sessionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cell.sessionCount.map(String.init) ?? "—")
                .font(.system(size: 30, weight: .medium)).monospacedDigit()
            Text(language.text("上次采集的会话", "Sessions at last collection"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(cell.sessions.prefix(6)) { session in
                HStack {
                    Text(session.clientID).lineLimit(1)
                    Spacer()
                    Text(TokenMonitorFormatting.count(session.tokenCount, compact: true, language: language))
                        .monospacedDigit()
                }
                .font(.system(size: 9))
            }
        }
    }

    private func rankRow(_ rank: TokenMonitorEdgeDockRank) -> some View {
        let color = providerColor(rank.id)
        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                ProviderMark(providerID: rank.id, slot: .navigation)
                    .scaleEffect(0.58).frame(width: 16, height: 16)
                Text(rank.id).font(.system(size: 10, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Text(TokenMonitorFormatting.count(rank.tokens, language: language))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                QuotaPercentageRing(
                    percent: rank.share.map { $0 * 100 }, diameter: 32, lineWidth: 2.5,
                    tint: color, accessibilityTitle: language.text("占比", "Share"))
            }
        }
        .padding(.vertical, 2)
    }

    private var limitsContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                if cell.providerID == "codex", cell.headlineMetricID == "five-hour", cell.headlineValueLabel == "∞" {
                    QuotaPercentageRing(percent: nil, diameter: 64, lineWidth: 4, isWeeklyOnlyPro: true)
                        .help(QuotaAvailabilityPresentation.weeklyOnlyProHelp(language))
                } else if let label = cell.headlineValueLabel {
                    Text(label).font(.system(size: 28, weight: .medium)).monospacedDigit()
                } else if quotaStyle == .fish {
                    QuotaFishView(percentRemaining: cell.percentRemaining, tint: providerColor(cell.providerID), language: language)
                        .frame(width: 126)
                } else {
                    QuotaPercentageRing(
                        percent: cell.percentRemaining, diameter: 64, lineWidth: 4,
                        isWeeklyOnlyPro: cell.providerID == "codex" && cell.headlineMetricID == "five-hour" && cell.headlineValueLabel == "∞")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(cell.providerID == "claude" ? language.text("余额", "Balance") : (cell.headlineMetricName ?? language.text("剩余额度", "Remaining quota")))
                        .font(.system(size: 11, weight: .medium))
                    if let reset = cell.headlineResetLabel, reset != "—" {
                        Text(language.text("重置：", "Reset: ") + reset)
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if cell.isStale {
                        Text(language.text("上次记录 · 待刷新", "Last recorded · Refresh needed")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if !cell.isAvailable {
                Text(
                    cell.accountBindingMissing
                        ? language.text(
                            "没有匹配到所选账号。请到侧边栏设置重新选择；不会自动改用其他账号。",
                            "The selected account could not be matched. Choose it again in Edge Dock settings; another account is never substituted automatically.")
                        : cell.providerID == "claude"
                            ? language.text("当前暂无可核对的余额", "No verified balance right now")
                            : cell.providerID == "grok"
                                ? language.text("订阅额度待核对，请在账号页刷新。", "Refresh the account page to verify subscription quota.")
                                : language.text("当前暂无可核对的额度", "No verified limit right now")
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(visibleAccounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.name).font(.system(size: 10, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    ForEach(account.quotaRows) { metric in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(metric.title).font(.system(size: 10)).foregroundStyle(.secondary)
                                if metric.isAvailable, let fetchedAt = metric.fetchedAt {
                                    Text(language.text("快照：", "Snapshot: ") + language.dateTime(fetchedAt))
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                if metric.resetLabel != "—" {
                                    Text(language.text("重置：", "Reset: ") + metric.resetLabel)
                                        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                if metric.isStale || account.isStale {
                                    Text(language.text("上次记录 · 待刷新", "Last recorded · Refresh needed"))
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            if let label = metric.valueLabel {
                                if cell.providerID == "codex", metric.id == "five-hour", label == "∞" {
                                    QuotaPercentageRing(percent: nil, diameter: 38, isWeeklyOnlyPro: true)
                                        .help(QuotaAvailabilityPresentation.weeklyOnlyProHelp(language))
                                } else {
                                    Text(label).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                }
                            } else if quotaStyle == .fish {
                                QuotaFishView(percentRemaining: metric.percentRemaining, tint: providerColor(cell.providerID), language: language)
                                    .frame(width: 100)
                            } else {
                                QuotaPercentageRing(percent: metric.percentRemaining, diameter: 38)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let collectedAt = cell.lastCollectedAt {
                Text(language.text("用量采集：", "Usage collected: ") + language.dateTime(collectedAt))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private func providerColor(_ id: String?) -> Color {
    let name = (id ?? "").lowercased()
    if name.contains("claude") || name.contains("anthropic") { return Color(red: 0.80, green: 0.49, blue: 0.37) }
    if name.contains("codex") || name.contains("openai") || name.hasPrefix("gpt") {
        return Color(red: 0.29, green: 0.64, blue: 0.69)
    }
    return Color(red: 0.44, green: 0.70, blue: 0.92)
}
