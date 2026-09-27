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
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    outline.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    EdgeDockHUDMaterial(outline: outline)
                    outline.fill(
                        colorScheme == .dark
                            ? Color(red: 48 / 255, green: 52 / 255, blue: 56 / 255).opacity(0.68)
                            : Color(red: 246 / 255, green: 247 / 255, blue: 250 / 255).opacity(0.54))
                }
                outline.stroke(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.13), lineWidth: 0.6)
            }
            .clipShape(outline)
            .contentShape(outline)
    }
}

struct TokenMonitorEdgeDockPeekView: View {
    let side: TokenMonitorEdgeDockPreferences.Side
    let language: WidgetLanguage
    let onReveal: () -> Void

    var body: some View {
        Button(action: onReveal) {
            EdgeDockGlass(
                outline: EdgeDockPeekShape(side: side),
                content:
                    Capsule()
                    .fill(Color(red: 0.40, green: 0.75, blue: 0.90))
                    .frame(width: 2, height: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        .buttonStyle(.plain)
        .help(language.text("展开右侧边栏", "Reveal Edge Dock"))
        .accessibilityLabel(language.text("展开侧边栏", "Reveal Edge Dock"))
        .accessibilityIdentifier("edge-dock-peek")
    }
}

struct TokenMonitorEdgeDockRailView: View {
    let cells: [TokenMonitorEdgeDockCell]
    let side: TokenMonitorEdgeDockPreferences.Side
    let language: WidgetLanguage
    let compact: Bool
    let warnColors: Bool
    let focusedIndex: Int?
    let onSelect: (Int) -> Void
    let onDrag: (CGSize) -> Void
    let onDrop: (CGSize) -> Void

    private var cellHeight: CGFloat { compact ? 54 : 70 }

    var body: some View {
        EdgeDockGlass(
            outline: EdgeDockRailShape(side: side),
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
                        .help(cell.title)
                        .accessibilityLabel(cell.title)
                        .accessibilityValue(
                            cell.isAvailable
                                ? (cell.kind == .stat
                                    ? statisticValue(cell, compact: false)
                                    : percentText(cell.percentRemaining)) : language.text("暂不可用", "Unavailable"))
                    }
                }
                .padding(.top, 32)
                .padding(.bottom, 32)
                .frame(width: 64)
                .frame(maxHeight: .infinity, alignment: .top)
        )
        .overlay(alignment: .top) {
            Color.clear.frame(width: 64, height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { onDrag($0.translation) }
                        .onEnded { onDrop($0.translation) }
                )
                .accessibilityLabel(language.text("拖动侧边栏", "Drag Edge Dock"))
        }
        .accessibilityIdentifier("edge-dock-rail")
    }

    @ViewBuilder
    private func cellView(_ cell: TokenMonitorEdgeDockCell, focused: Bool) -> some View {
        if cell.kind == .provider {
            VStack(spacing: 2) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.13), lineWidth: 3.5)
                    Circle().trim(from: 0, to: CGFloat(max(0, min(100, cell.percentRemaining ?? 0)) / 100))
                        .stroke(
                            warnColors && (cell.severityRemainingPercent ?? 100) < 20
                                ? Color(red: 0.88, green: 0.48, blue: 0.31) : providerColor(cell.providerID),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .opacity(cell.isAvailable ? 1 : 0.3)
                    if let providerID = cell.providerID {
                        ProviderMark(providerID: providerID, slot: .navigation)
                            .scaleEffect(0.63)
                    }
                }
                .frame(width: 42, height: 42)
                Text(cell.headlineValueLabel ?? percentText(cell.percentRemaining))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(focused ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(spacing: 2) {
                Text(cell.metric == .liveRate ? "tok/s" : cell.title.uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(focused ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func liveRateStateLabel(_ cell: TokenMonitorEdgeDockCell) -> String {
        guard let sample = cell.liveRate else { return language.text("等待", "WAIT") }
        return sample.isIdle ? language.text("上次", "LAST") : language.text("即时", "LIVE")
    }

    private func statisticValue(_ cell: TokenMonitorEdgeDockCell, compact: Bool) -> String {
        if cell.metric == .liveRate {
            guard let rate = cell.liveRate, rate.speed.isFinite else { return "—" }
            return TokenMonitorFormatting.count(rate.speed, compact: compact, language: language)
        }
        if cell.metric == .sessions {
            return cell.sessionCount.map(String.init) ?? "—"
        }
        return TokenMonitorFormatting.count(cell.tokenCount, compact: compact, language: language)
    }
}

struct TokenMonitorEdgeDockCardView: View {
    let cell: TokenMonitorEdgeDockCell
    let side: TokenMonitorEdgeDockPreferences.Side
    let language: WidgetLanguage
    let tailY: CGFloat
    let isPinned: Bool
    let canPin: Bool
    let onPin: () -> Void
    let onOpenDashboard: () -> Void
    @State private var byModel = false

    var body: some View {
        EdgeDockGlass(
            outline: EdgeDockCardShape(side: side, tailY: tailY),
            content:
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 9) {
                        header
                        if cell.metric == .liveRate {
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
                }
        )
        .accessibilityIdentifier("edge-dock-card")
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text(cell.title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if cell.kind == .stat && cell.metric != .liveRate && cell.metric != .sessions {
                HStack(spacing: 0) {
                    dimensionButton(language.text("工具", "Tools"), selected: !byModel) { byModel = false }
                    dimensionButton(language.text("模型", "Models"), selected: byModel) { byModel = true }
                }
                .padding(3)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            if canPin {
                Button(action: onPin) { Image(systemName: isPinned ? "pin.fill" : "pin").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .help(isPinned ? language.text("取消固定侧边栏", "Unpin rail") : language.text("固定侧边栏", "Pin rail"))
                    .accessibilityLabel(isPinned ? language.text("取消固定侧边栏", "Unpin rail") : language.text("固定侧边栏", "Pin rail"))
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
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
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
            Text(cell.liveRate.map { TokenMonitorFormatting.count($0.speed, language: language) } ?? "—")
                .font(.system(size: 30, weight: .medium)).monospacedDigit()
            Text(language.text("输出 Token / 秒", "Output tokens / second"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let rate = cell.liveRate {
                Text(language.text("采样时间：", "Sampled: ") + language.dateTime(rate.sampledAt))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
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
                .font(.system(size: 9, design: .monospaced))
            }
        }
    }

    private func rankRow(_ rank: TokenMonitorEdgeDockRank) -> some View {
        let color = providerColor(rank.id)
        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                ProviderMark(providerID: rank.id, slot: .navigation)
                    .scaleEffect(0.58).frame(width: 16, height: 16)
                Text(rank.id).font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Text(TokenMonitorFormatting.count(rank.tokens, language: language))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(rank.share.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14))
                    Capsule().fill(color).frame(width: geometry.size.width * CGFloat(max(0, min(1, rank.share ?? 0))))
                }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 2)
    }

    private var limitsContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(cell.headlineValueLabel ?? cell.percentRemaining.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 28, weight: .medium)).monospacedDigit()
                Text(language.text("剩余额度", "remaining"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !cell.isAvailable {
                Text(language.text("当前暂无可核对的额度", "No verified limit right now"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(cell.accounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.name).font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    ForEach(account.quotaRows) { metric in
                        HStack {
                            Text(metric.title).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(metric.valueLabel ?? metric.percentRemaining.map { "\(Int($0.rounded()))%" } ?? "—")
                                .monospacedDigit()
                        }
                        .font(.system(size: 9, design: .monospaced))
                        if metric.resetLabel != "—" {
                            Text(language.text("重置：", "Reset: ") + metric.resetLabel)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if metric.isStale || account.isStale {
                            Text(language.text("上次记录 · 数据已过期", "Last recorded · Stale"))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let collectedAt = cell.lastCollectedAt {
                Text(language.text("采集：", "Collected: ") + language.dateTime(collectedAt))
                    .font(.system(size: 8, design: .monospaced))
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
