import SwiftUI

/// Only presentation is persisted; no account, lease or runtime state lives here.
struct WorkspaceModuleArrangement: Codable, Equatable {
    static let storageKey = "AiGoodBro.homeModules.v1"
    static let modules = ["usage", "monitor", "accounts"]
    var order = modules
    var compact: [String] = []
    var extraHeight: [String: Int] = [:]

    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data),
            value.order.count == 3, Set(value.order) == Set(modules),
            value.compact.allSatisfy({ ["usage", "monitor"].contains($0) }),
            value.extraHeight.allSatisfy({ modules.contains($0.key) && (0...10).contains($0.value) })
        else { return Self() }
        return value
    }

    mutating func move(_ source: String, to target: String) {
        guard source != target, let from = order.firstIndex(of: source), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(source, at: to)
    }

    mutating func resizeHeight(_ id: String, by translation: CGFloat) {
        guard Self.modules.contains(id), translation.isFinite else { return }
        let steps = Int((min(240, max(-240, translation)) / 24).rounded())
        extraHeight[id] = min(10, max(0, extraHeight[id, default: 0] + steps))
    }
}

private struct ModuleSpan: LayoutValueKey { static let defaultValue = 2 }
private struct ModuleFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Two-column grid collapses to one below 1,000 points. Intrinsic content always wins over resizing.
private struct ModuleGrid: Layout {
    func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let gap: CGFloat = 12
        let width = width.isFinite ? max(1, width) : 944
        var result: [CGRect] = []
        var y: CGFloat = 0
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let half = width >= 1000 && view[ModuleSpan.self] == 1
            let w = half ? (width - gap) / 2 : width
            if x > 0 && !half {
                y += rowHeight + gap
                x = 0
                rowHeight = 0
            }
            let h = view.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            result.append(CGRect(x: x, y: y, width: w, height: h))
            rowHeight = max(rowHeight, h)
            if x > 0 || !half {
                y += rowHeight + gap
                x = 0
                rowHeight = 0
            } else {
                x = w + gap
            }
        }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 944
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

struct WorkspaceModules<Content: View>: View {
    @Binding var arrangement: WorkspaceModuleArrangement
    let editing: Bool
    let language: WidgetLanguage
    @ViewBuilder let content: (String) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [String: CGRect] = [:]
    @State private var dragged: String?
    @State private var translation = CGSize.zero
    @State private var resizeTranslation = CGSize.zero
    @State private var resizing: String?

    private func title(_ id: String) -> String {
        switch id {
        case "usage": language.text("Token 与重置", "Tokens & resets")
        case "monitor": language.text("监控", "Monitor")
        default: language.text("账号", "Accounts")
        }
    }

    var body: some View {
        ModuleGrid {
            ForEach(arrangement.order, id: \.self) { id in
                VStack(alignment: .leading, spacing: 8) {
                    handle(id)
                    content(id)
                    if extraSpace(id) > 0 {
                        Color.clear.frame(height: extraSpace(id))
                    }
                    if editing { resizeHandle(id) }
                }
                .padding(editing ? 8 : 0)
                .background {
                    if editing {
                        RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ModuleFrames.self, value: [id: proxy.frame(in: .named("home-modules"))])
                    }
                )
                .offset(dragged == id ? translation : .zero)
                .zIndex(dragged == id ? 1 : 0)
                .layoutValue(key: ModuleSpan.self, value: arrangement.compact.contains(id) ? 1 : 2)
            }
        }
        .coordinateSpace(name: "home-modules")
        .onPreferenceChange(ModuleFrames.self) { frames = $0 }
        .onChange(of: editing) { _ in
            dragged = nil
            translation = .zero
            resizing = nil
        }
    }

    private func handle(_ id: String) -> some View {
        HStack(spacing: 8) {
            Text(title(id))
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            if dragged == id {
                Text(language.text("松手吸附到最近位置", "Release to snap"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if editing {
                Menu {
                    Button(language.text("增高一格", "Grow one step")) { arrangement.resizeHeight(id, by: 24) }
                    Button(language.text("缩短一格", "Shrink one step")) { arrangement.resizeHeight(id, by: -24) }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .menuStyle(.borderlessButton).frame(width: 24)
                .help(language.text("调整模块尺寸", "Resize module"))
            }
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            dragged = id
                            translation = value.translation
                        }
                        .onEnded { value in
                            if let frame = frames[id] {
                                let point = CGPoint(x: frame.midX + value.predictedEndTranslation.width, y: frame.midY + value.predictedEndTranslation.height)
                                let target =
                                    frames.min { a, b in
                                        hypot(a.value.midX - point.x, a.value.midY - point.y) < hypot(b.value.midX - point.x, b.value.midY - point.y)
                                    }?.key ?? id
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                    arrangement.move(id, to: target)
                                    dragged = nil
                                    translation = .zero
                                }
                            }
                            dragged = nil
                            translation = .zero
                        }
                )
                .help(language.text("拖动模块排序", "Drag to reorder module"))
                .accessibilityLabel(language.text("拖动\(title(id))模块排序", "Drag \(title(id)) module to reorder"))
                .accessibilityIdentifier("next.workspace.module.grip.\(id)")
        }
        .foregroundStyle(PaletteControlForeground())
    }

    private func resizeHandle(_ id: String) -> some View {
        HStack(spacing: 8) {
            Text(resizing == id ? language.text("松手吸附 · 24 pt 网格", "Release to snap · 24 pt grid") : language.text("拖边调整 · 自动保存", "Resize edge · Saved automatically"))
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if id != "accounts" {
                Button(arrangement.compact.contains(id) ? language.text("整行", "Full width") : language.text("半宽", "Half width")) {
                    setCompact(id, !arrangement.compact.contains(id))
                }.buttonStyle(.borderless).font(.caption2)
            }
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .padding(5).contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            resizing = id
                            resizeTranslation = value.translation
                        }
                        .onEnded { value in
                            arrangement.resizeHeight(id, by: value.translation.height)
                            if id != "accounts", abs(value.translation.width) > 60 { setCompact(id, value.translation.width < 0) }
                            resizing = nil
                            resizeTranslation = .zero
                        }
                )
                .accessibilityLabel(language.text("调整模块尺寸", "Resize module"))
        }
    }

    private func setCompact(_ id: String, _ compact: Bool) {
        arrangement.compact.removeAll { $0 == id }
        if compact { arrangement.compact.append(id) }
    }

    private func extraSpace(_ id: String) -> CGFloat {
        let stored = CGFloat(arrangement.extraHeight[id, default: 0]) * 24
        return min(240, max(0, stored + (resizing == id ? resizeTranslation.height : 0)))
    }
}
