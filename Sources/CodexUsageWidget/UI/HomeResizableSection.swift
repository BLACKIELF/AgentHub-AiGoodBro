import AppKit
import SwiftUI

private struct HomeSectionGeometryKey: PreferenceKey {
    static var defaultValue: [String: CGSize] { [:] }
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// Resizing changes presentation only. The natural layout remains the default.
struct HomeResizableSection<Content: View>: View {
    let section: HomeResizableSectionID
    let title: String
    let language: WidgetLanguage
    let expanded: Bool
    let minimumWidth: CGFloat
    let minimumHeight: CGFloat
    let allowsWidth: Bool
    let allowsHeight: Bool
    let fillsProposedHeight: Bool
    let content: Content
    @AppStorage private var savedWidth: Double
    @AppStorage private var savedHeight: Double
    @State private var availableWidth: CGFloat = 0
    @State private var naturalHeight: CGFloat = 0
    @State private var liveSize: HomeSectionSize?
    @State private var dragOrigin: CGPoint?
    @State private var originalSize: HomeSectionSize?
    @State private var startingSize = CGSize.zero

    init(
        section: HomeResizableSectionID, title: String, language: WidgetLanguage,
        expanded: Bool = true, minimumWidth: CGFloat = 300, minimumHeight: CGFloat = 72,
        allowsWidth: Bool = true, allowsHeight: Bool = true, fillsProposedHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.section = section
        self.title = title
        self.language = language
        self.expanded = expanded
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
        self.allowsWidth = allowsWidth
        self.allowsHeight = allowsHeight
        self.fillsProposedHeight = fillsProposedHeight
        self.content = content()
        _savedWidth = AppStorage(wrappedValue: 1, section.widthKey)
        _savedHeight = AppStorage(wrappedValue: 0, section.heightKey)
    }

    private var persistedSize: HomeSectionSize { .init(widthFraction: savedWidth, height: savedHeight) }
    private var size: HomeSectionSize { liveSize ?? persistedSize }
    private var width: CGFloat {
        allowsWidth ? HomeSectionSizing.width(size, available: availableWidth, minimum: minimumWidth) : availableWidth
    }
    private var constrainedHeight: CGFloat? {
        guard expanded, allowsHeight, size.height > 0 else { return nil }
        let requested = HomeSectionSizing.height(size, natural: naturalHeight, minimum: minimumHeight)
        return naturalHeight > 0 ? min(requested, naturalHeight) : requested
    }

    var body: some View {
        Group {
            if fillsProposedHeight && expanded && allowsHeight {
                ScrollView(.vertical, showsIndicators: true) { measuredContent }
                    .frame(
                        minHeight: 0, idealHeight: constrainedHeight ?? max(minimumHeight, naturalHeight),
                        maxHeight: .infinity, alignment: .topLeading)
            } else if let constrainedHeight {
                ScrollView(.vertical, showsIndicators: true) { measuredContent }
                    .frame(height: constrainedHeight)
            } else {
                measuredContent
            }
        }
        .frame(width: width > 0 ? width : nil, alignment: .topLeading)
        .sectionBackground()
        .overlay(alignment: .bottom) {
            if expanded && allowsHeight { handle(.height).frame(width: 38, height: 16) }
        }
        .overlay(alignment: .bottomTrailing) {
            if allowsWidth { handle(expanded && allowsHeight ? .both : .width).frame(width: 18, height: 16) }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: HomeSectionGeometryKey.self, value: [section.rawValue + ".available": geometry.size])
            }
        }
        .onPreferenceChange(HomeSectionGeometryKey.self) { measurements in
            if let value = measurements[section.rawValue + ".available"], value.width.isFinite, value.width > 0 {
                availableWidth = value.width
            }
            if let value = measurements[section.rawValue + ".natural"], value.height.isFinite, value.height >= 0 {
                naturalHeight = value.height
            }
        }
        .transaction { if liveSize != nil { $0.animation = nil } }
        .onDisappear { cancel() }
    }

    private var measuredContent: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: HomeSectionGeometryKey.self, value: [section.rawValue + ".natural": geometry.size])
                }
            }
    }

    private func handle(_ axis: HomeSectionResizeAxis) -> some View {
        let label = language.text("调整\(title)大小", "Resize \(title)")
        return HomeSectionResizeHandle(
            axis: axis, label: label,
            help: language.text("拖动调整大小 · 双击恢复默认", "Drag to resize · Double-click to reset"),
            onBegin: { point in
                guard availableWidth > 0 else { return false }
                dragOrigin = point
                originalSize = persistedSize
                startingSize = CGSize(width: width, height: constrainedHeight ?? naturalHeight)
                return true
            },
            onMove: { point in resize(point, axis: axis) },
            onEnd: { point in
                resize(point, axis: axis)
                if let liveSize {
                    savedWidth = liveSize.widthFraction
                    savedHeight = liveSize.height
                }
                cancel()
            },
            onCancel: cancel,
            onReset: reset
        )
        .accessibilityLabel(label)
        .accessibilityIdentifier("home.resize.\(section.rawValue).\(axis)")
        .accessibilityValue(language.text("宽 \(Int(width))，高 \(Int(constrainedHeight ?? naturalHeight))", "Width \(Int(width)), height \(Int(constrainedHeight ?? naturalHeight))"))
        .accessibilityAction(named: language.text("恢复默认大小", "Reset size"), reset)
        .contextMenu {
            Button(language.text("恢复默认大小", "Reset size"), action: reset)
            if expanded && allowsHeight {
                Button(language.text("增高", "Increase height")) { adjust(.height, translation: CGSize(width: 0, height: 40)) }
                Button(language.text("降低", "Decrease height")) { adjust(.height, translation: CGSize(width: 0, height: -40)) }
            }
            if allowsWidth {
                Button(language.text("加宽", "Increase width")) { adjust(.width, translation: CGSize(width: 80, height: 0)) }
                Button(language.text("收窄", "Decrease width")) { adjust(.width, translation: CGSize(width: -80, height: 0)) }
            }
        }
    }

    private func resize(_ point: CGPoint, axis: HomeSectionResizeAxis) {
        guard let dragOrigin, let originalSize else { return }
        liveSize = HomeSectionSizing.resized(
            originalSize, startingSize: startingSize,
            translation: CGSize(width: point.x - dragOrigin.x, height: point.y - dragOrigin.y),
            availableWidth: availableWidth, minimumWidth: minimumWidth, minimumHeight: minimumHeight, axis: axis)
    }

    private func adjust(_ axis: HomeSectionResizeAxis, translation: CGSize) {
        guard
            let next = HomeSectionSizing.resized(
                persistedSize, startingSize: CGSize(width: width, height: constrainedHeight ?? naturalHeight),
                translation: translation, availableWidth: availableWidth,
                minimumWidth: minimumWidth, minimumHeight: minimumHeight, axis: axis)
        else { return }
        savedWidth = next.widthFraction
        savedHeight = next.height
    }

    private func cancel() {
        liveSize = nil
        dragOrigin = nil
        originalSize = nil
    }

    private func reset() {
        cancel()
        savedWidth = 1
        savedHeight = 0
    }
}

extension View {
    func homeResizable(
        _ section: HomeResizableSectionID, title: String, language: WidgetLanguage,
        expanded: Bool = true, minimumWidth: CGFloat = 300, minimumHeight: CGFloat = 72,
        allowsWidth: Bool = true, allowsHeight: Bool = true, fillsProposedHeight: Bool = false
    ) -> some View {
        HomeResizableSection(
            section: section, title: title, language: language, expanded: expanded,
            minimumWidth: minimumWidth, minimumHeight: minimumHeight,
            allowsWidth: allowsWidth, allowsHeight: allowsHeight, fillsProposedHeight: fillsProposedHeight
        ) { self }
    }
}

/// Window-local AppKit tracking keeps the pointer stable as the handle moves.
struct HomeSectionResizeHandle: NSViewRepresentable {
    let axis: HomeSectionResizeAxis
    let label: String
    let help: String
    var alwaysVisible: Bool = false
    let onBegin: (CGPoint) -> Bool
    let onMove: (CGPoint) -> Void
    let onEnd: (CGPoint) -> Void
    let onCancel: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.axis = axis
        view.alwaysVisible = alwaysVisible
        view.setAccessibilityLabel(label)
        view.toolTip = help
        view.onBegin = onBegin
        view.onMove = onMove
        view.onEnd = onEnd
        view.onCancel = onCancel
        view.onReset = onReset
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: HandleView, coordinator: ()) { view.cancel() }

    final class HandleView: NSView {
        var axis: HomeSectionResizeAxis = .both
        var alwaysVisible = false
        private var isHovered = false
        private var hoverTrackingArea: NSTrackingArea?
        var onBegin: (CGPoint) -> Bool = { _ in false }
        var onMove: (CGPoint) -> Void = { _ in }
        var onEnd: (CGPoint) -> Void = { _ in }
        var onCancel: () -> Void = {}
        var onReset: () -> Void = {}
        private var downPoint: CGPoint?
        private var dragging = false
        private weak var previousResponder: NSResponder?
        override var acceptsFirstResponder: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }

        required init?(coder: NSCoder) { nil }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: axis == .height ? .resizeUpDown : axis == .width ? .resizeLeftRight : .crosshair)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovered = false
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard alwaysVisible || isHovered || dragging else { return }
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            if axis == .height {
                path.move(to: CGPoint(x: bounds.midX - 12, y: bounds.midY))
                path.line(to: CGPoint(x: bounds.midX + 12, y: bounds.midY))
            } else if axis == .width {
                path.move(to: CGPoint(x: bounds.midX, y: bounds.midY - 5))
                path.line(to: CGPoint(x: bounds.midX, y: bounds.midY + 5))
            } else {
                for offset: CGFloat in [0, 4, 8] {
                    path.move(to: CGPoint(x: bounds.maxX - 3 - offset, y: bounds.minY + 3))
                    path.line(to: CGPoint(x: bounds.maxX - 3, y: bounds.minY + 3 + offset))
                }
            }
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                cancel()
                onReset()
                return
            }
            downPoint = workspacePoint(event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let downPoint else { return }
            if !dragging {
                guard onBegin(downPoint) else { return }
                dragging = true
                needsDisplay = true
                previousResponder = window?.firstResponder
                window?.makeFirstResponder(self)
            }
            if let point = workspacePoint(event) { onMove(point) }
        }

        override func mouseUp(with event: NSEvent) {
            downPoint = nil
            guard dragging else { return }
            dragging = false
            needsDisplay = true
            restoreResponder()
            if let point = workspacePoint(event) { onEnd(point) } else { onCancel() }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 && dragging { cancel() } else { super.keyDown(with: event) }
        }

        private func workspacePoint(_ event: NSEvent) -> CGPoint? {
            guard let content = window?.contentView else { return nil }
            var point = content.convert(event.locationInWindow, from: nil)
            if !content.isFlipped { point.y = content.bounds.height - point.y }
            return point
        }

        func cancel() {
            downPoint = nil
            guard dragging else { return }
            dragging = false
            needsDisplay = true
            restoreResponder()
            onCancel()
        }

        private func restoreResponder() {
            if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
            previousResponder = nil
            NSCursor.arrow.set()
        }
    }
}
