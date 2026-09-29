import AppKit
import SwiftUI

/// Screen-coordinate placement shared by the native controller and its pure
/// regression checks. AppKit rects use bottom-origin coordinates; offset is
/// top-origin like the vendored Edge Dock's persisted 0...1 placement.
enum TokenMonitorEdgeDockNativeGeometry {
    static func railFrame(
        workArea: NSRect, side: TokenMonitorEdgeDockPreferences.Side,
        offset: Double, height: CGFloat
    ) -> NSRect {
        let boundedHeight = min(height, max(1, workArea.height - 16))
        let travel = max(0, workArea.height - boundedHeight - 16)
        let safeOffset = offset.isFinite ? max(0, min(1, offset)) : 0.3
        return NSRect(
            x: side == .right ? workArea.maxX - 64 : workArea.minX,
            y: workArea.maxY - 8 - boundedHeight - travel * CGFloat(safeOffset),
            width: 64, height: boundedHeight
        )
    }

    static func placementAfterDrag(
        rail: NSRect, translation: CGSize, destinationWorkArea: NSRect
    ) -> (side: TokenMonitorEdgeDockPreferences.Side, offset: Double) {
        let centerX = rail.midX + translation.width
        let side: TokenMonitorEdgeDockPreferences.Side = centerX < destinationWorkArea.midX ? .left : .right
        let maxBottom = destinationWorkArea.maxY - rail.height - 8
        let minBottom = destinationWorkArea.minY + 8
        let travel = max(0, maxBottom - minBottom)
        let bottom = max(minBottom, min(maxBottom, rail.minY - translation.height))
        let offset = travel > 0 ? Double((maxBottom - bottom) / travel) : 0.3
        return (side, offset)
    }

    static func cardFrame(
        rail: NSRect, centerY: CGFloat, height: CGFloat,
        workArea: NSRect, side: TokenMonitorEdgeDockPreferences.Side
    ) -> NSRect {
        let boundedHeight = min(height, max(120, workArea.height - 16))
        let y = max(
            workArea.minY + 8,
            min(workArea.maxY - boundedHeight - 8, centerY - boundedHeight / 2))
        let x = side == .right ? rail.minX - 4 - 292 : rail.maxX + 4
        return NSRect(x: x, y: y, width: 292, height: boundedHeight)
    }
}

/// Three nonactivating native surfaces: a seven-point screen-edge affordance,
/// a shaped quota/stat rail and one detail card. Only already projected,
/// display-safe data reaches the windows. Cursor reads are used for the narrow
/// rail-to-card corridor; no Accessibility or input-monitoring permission is
/// required and no other application's window is inspected.
@MainActor
final class TokenMonitorEdgeDockController: NSObject {
    private struct Layout {
        let screen: NSScreen
        let workArea: NSRect
        let peek: NSRect
        let rail: NSRect
        let cellTops: [CGFloat]
        let cellHeights: [CGFloat]
        let compact: Bool
    }

    private var preferences = TokenMonitorEdgeDockPreferences()
    private var cells: [TokenMonitorEdgeDockCell] = []
    private var language: WidgetLanguage = .zh
    private var glass = WorkspaceGlassPreferences()
    private var onPreferencesChange: ((TokenMonitorEdgeDockPreferences) -> Void)?
    private var onOpenDashboard: (() -> Void)?

    private var peekPanel: NSPanel?
    private var railPanel: NSPanel?
    private var cardPanel: NSPanel?
    private var peekHost: NSHostingView<TokenMonitorEdgeDockPeekView>?
    private var railHost: NSHostingView<TokenMonitorEdgeDockRailView>?
    private var cardHost: NSHostingView<TokenMonitorEdgeDockCardView>?
    private var timer: Timer?
    private var layout: Layout?
    private var railVisible = false
    private var railPinned = false
    private var cardIndex: Int?
    private var hoveredIndex: Int?
    private var hoverStartedAt: Date?
    private var edgeStartedAt: Date?
    private var outsideStartedAt: Date?
    private var dragStart: NSRect?
    private var isDragging = false

    func configure(
        preferences: TokenMonitorEdgeDockPreferences,
        cells: [TokenMonitorEdgeDockCell],
        language: WidgetLanguage,
        glass: WorkspaceGlassPreferences = .init(),
        onPreferencesChange: @escaping (TokenMonitorEdgeDockPreferences) -> Void,
        onOpenDashboard: @escaping () -> Void
    ) {
        let previous = self.preferences
        self.preferences = preferences.normalized()
        self.cells = cells
        self.language = language
        self.glass = glass
        self.onPreferencesChange = onPreferencesChange
        self.onOpenDashboard = onOpenDashboard
        guard self.preferences.enabled, !cells.isEmpty else {
            hideAll()
            return
        }
        if previous.side != self.preferences.side || previous.displayID != self.preferences.displayID || previous.offset != self.preferences.offset
            || previous.mode != self.preferences.mode
        {
            cardIndex = nil
            railPinned = false
        }
        if let cardIndex, !cells.indices.contains(cardIndex) { self.cardIndex = nil }
        layout = makeLayout()
        ensurePanels()
        if self.preferences.mode == .always { railVisible = true }
        updateSurfaces()
        if timer == nil {
            let next = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            next.tolerance = 0.02
            timer = next
        }
    }

    func shutdown() {
        hideAll()
        for panel in [peekPanel, railPanel, cardPanel] { panel?.close() }
        peekPanel = nil
        railPanel = nil
        cardPanel = nil
        peekHost = nil
        railHost = nil
        cardHost = nil
        onPreferencesChange = nil
        onOpenDashboard = nil
    }

    private func hideAll() {
        timer?.invalidate()
        timer = nil
        peekPanel?.orderOut(nil)
        railPanel?.orderOut(nil)
        cardPanel?.orderOut(nil)
        railVisible = false
        cardIndex = nil
        hoveredIndex = nil
        edgeStartedAt = nil
        hoverStartedAt = nil
        outsideStartedAt = nil
        railPinned = false
        isDragging = false
        dragStart = nil
        layout = nil
    }

    private func ensurePanels() {
        guard let layout else { return }
        if peekPanel == nil {
            peekPanel = makePanel(layout.peek, shadow: false)
        }
        if railPanel == nil {
            railPanel = makePanel(layout.rail, shadow: true)
        }
        if cardPanel == nil {
            cardPanel = makePanel(NSRect(x: 0, y: 0, width: 292, height: 300), shadow: true)
        }
    }

    private func makePanel(_ frame: NSRect, shadow: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func updateSurfaces() {
        guard let layout else { return }
        let peek = peekPanel
        let rail = railPanel
        let card = cardPanel
        let isAutoHidden = preferences.mode == .autoHide && !railVisible

        peek?.setFrame(layout.peek, display: true)
        if isAutoHidden {
            if let peek {
                let view = TokenMonitorEdgeDockPeekView(side: preferences.side, language: language, glass: glass) { [weak self] in self?.revealRail() }
                if let peekHost {
                    peekHost.rootView = view
                } else {
                    let host = NSHostingView(rootView: view)
                    peek.contentView = host
                    peekHost = host
                }
                peek.orderFrontRegardless()
            }
        } else {
            peek?.orderOut(nil)
        }

        rail?.setFrame(layout.rail, display: true)
        if railVisible, let rail {
            let view = TokenMonitorEdgeDockRailView(
                cells: cells, side: preferences.side, language: language, glass: glass,
                compact: layout.compact, warnColors: preferences.warnColors,
                focusedIndex: cardIndex,
                onSelect: { [weak self] index in self?.selectCell(index) },
                onDrag: { [weak self] translation in self?.dragRail(translation) },
                onDrop: { [weak self] translation in self?.dropRail(translation) }
            )
            if let railHost {
                railHost.rootView = view
            } else {
                let host = NSHostingView(rootView: view)
                rail.contentView = host
                railHost = host
            }
            rail.orderFrontRegardless()
        } else {
            rail?.orderOut(nil)
        }

        if let index = cardIndex, cells.indices.contains(index), railVisible,
            let card, let placement = cardPlacement(index: index, layout: layout)
        {
            card.setFrame(placement.frame, display: true)
            let view = TokenMonitorEdgeDockCardView(
                cell: cells[index], side: preferences.side, language: language, glass: glass,
                tailY: placement.tailY,
                isPinned: railPinned || preferences.mode == .always,
                canPin: preferences.mode != .always,
                onPin: { [weak self] in self?.togglePin() },
                onOpenDashboard: { [weak self] in self?.onOpenDashboard?() }
            )
            if let cardHost {
                cardHost.rootView = view
            } else {
                let host = NSHostingView(rootView: view)
                card.contentView = host
                cardHost = host
            }
            card.orderFrontRegardless()
        } else {
            card?.orderOut(nil)
        }
    }

    private func tick() {
        guard preferences.enabled, !cells.isEmpty else { return }
        // Live monitor changes, a detached display or a moving Dock can change
        // visibleFrame while the app stays open. Clamp the native panels before
        // reading hit targets so they never remain stranded off-screen.
        if let newLayout = makeLayout(), layoutChanged(layout, newLayout) {
            layout = newLayout
            updateSurfaces()
        }
        guard let layout else { return }
        let point = NSEvent.mouseLocation
        let now = Date()

        if !railVisible {
            let edge = layout.peek.insetBy(dx: -2, dy: 0).contains(point) || edgeTrigger(layout).contains(point)
            if edge {
                if edgeStartedAt == nil { edgeStartedAt = now }
                if now.timeIntervalSince(edgeStartedAt!) >= 0.14 { revealRail() }
            } else {
                edgeStartedAt = nil
            }
            return
        }

        if isDragging { return }
        let index = cellAt(point, layout: layout)
        if index != hoveredIndex {
            hoveredIndex = index
            hoverStartedAt = index == nil ? nil : now
            if index != nil, preferences.hapticEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
        }
        if let index, let hoverStartedAt, now.timeIntervalSince(hoverStartedAt) >= 0.07,
            cardIndex != index
        {
            cardIndex = index
            updateSurfaces()
        }

        let overRail = layout.rail.contains(point)
        let overCard = cardPanel?.isVisible == true && cardPanel?.frame.contains(point) == true
        let crossing = cardPanel?.isVisible == true && corridorContains(point, rail: layout.rail, card: cardPanel?.frame)
        if overRail || overCard || crossing || edgeTrigger(layout).contains(point) {
            outsideStartedAt = nil
            return
        }
        if outsideStartedAt == nil { outsideStartedAt = now }
        if let outsideStartedAt, now.timeIntervalSince(outsideStartedAt) >= 0.32 {
            cardIndex = nil
            hoveredIndex = nil
            hoverStartedAt = nil
            if preferences.mode == .autoHide && !railPinned { railVisible = false }
            self.outsideStartedAt = nil
            updateSurfaces()
        }
    }

    private func revealRail() {
        edgeStartedAt = nil
        railVisible = true
        updateSurfaces()
    }

    private func selectCell(_ index: Int) {
        guard cells.indices.contains(index) else { return }
        railPinned = true
        railVisible = true
        cardIndex = index
        hoveredIndex = index
        hoverStartedAt = Date()
        outsideStartedAt = nil
        updateSurfaces()
    }

    private func togglePin() {
        railPinned.toggle()
        if preferences.mode == .always { railPinned = true }
        updateSurfaces()
    }

    private func dragRail(_ translation: CGSize) {
        guard let panel = railPanel, let layout else { return }
        if dragStart == nil { dragStart = layout.rail }
        isDragging = true
        cardIndex = nil
        cardPanel?.orderOut(nil)
        guard let start = dragStart else { return }
        let newX = start.minX + translation.width
        let newY = max(
            layout.workArea.minY + 8,
            min(layout.workArea.maxY - start.height - 8, start.minY - translation.height))
        panel.setFrameOrigin(NSPoint(x: newX, y: newY))
    }

    private func dropRail(_ translation: CGSize) {
        guard let start = dragStart else { return }
        defer {
            dragStart = nil
            isDragging = false
        }
        let dropped = NSPoint(x: start.midX + translation.width, y: start.midY - translation.height)
        let screen = NSScreen.screens.first { $0.frame.contains(dropped) } ?? layout?.screen ?? NSScreen.main
        guard let screen else { return }
        let work = screen.visibleFrame
        let placement = TokenMonitorEdgeDockNativeGeometry.placementAfterDrag(
            rail: start, translation: translation, destinationWorkArea: work
        )
        var next = preferences
        next.side = placement.side
        next.offset = placement.offset
        next.displayID = Self.displayID(screen)
        preferences = next.normalized()
        layout = makeLayout()
        updateSurfaces()
        onPreferencesChange?(preferences)
    }

    private func makeLayout() -> Layout? {
        let screen =
            NSScreen.screens.first { Self.displayID($0) == preferences.displayID }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        let work = screen.visibleFrame
        let normal = cells.map { $0.kind == .stat ? CGFloat(56) : CGFloat(70) }
        let compressed = cells.map { $0.kind == .stat ? CGFloat(48) : CGFloat(54) }
        let chrome: CGFloat = 28 * 2 + 4 * 2
        let gaps = CGFloat(max(0, cells.count - 1)) * 2
        let compact = chrome + normal.reduce(0, +) + gaps > work.height - 16
        let heights = compact ? compressed : normal
        let fullHeight = chrome + heights.reduce(0, +) + gaps
        let length = min(fullHeight, max(1, work.height - 16))
        let rail = TokenMonitorEdgeDockNativeGeometry.railFrame(
            workArea: work, side: preferences.side, offset: preferences.offset, height: length
        )
        let peek = NSRect(
            x: preferences.side == .right ? work.maxX - 7 : work.minX,
            y: rail.midY - 29, width: 7, height: 58)
        var tops: [CGFloat] = []
        var top: CGFloat = 28 + 4
        for height in heights {
            tops.append(top)
            top += height + 2
        }
        return Layout(
            screen: screen, workArea: work, peek: peek, rail: rail,
            cellTops: tops, cellHeights: heights, compact: compact)
    }

    private func cardPlacement(index: Int, layout: Layout) -> (frame: NSRect, tailY: CGFloat)? {
        guard layout.cellTops.indices.contains(index) else { return nil }
        let cellCenter = layout.rail.maxY - layout.cellTops[index] - layout.cellHeights[index] / 2
        let cell = cells[index]
        let rows = cell.kind == .stat ? min(12, max(cell.byTool.count, cell.byModel.count)) : cell.accounts.reduce(0) { $0 + max(1, $1.quotaRows.count) }
        let preferredHeight = cell.kind == .stat ? max(190, min(520, 132 + CGFloat(rows) * 44)) : max(150, min(480, 102 + CGFloat(rows) * 37))
        let frame = TokenMonitorEdgeDockNativeGeometry.cardFrame(
            rail: layout.rail, centerY: cellCenter, height: preferredHeight,
            workArea: layout.workArea, side: preferences.side
        )
        return (frame, frame.maxY - cellCenter)
    }

    private func cellAt(_ point: NSPoint, layout: Layout) -> Int? {
        guard layout.rail.contains(point), abs(point.x - layout.rail.midX) <= 28 else { return nil }
        let localTop = layout.rail.maxY - point.y
        for index in cells.indices where layout.cellTops.indices.contains(index) {
            if localTop >= layout.cellTops[index] && localTop < layout.cellTops[index] + layout.cellHeights[index] + 2 { return index }
        }
        return nil
    }

    private func edgeTrigger(_ layout: Layout) -> NSRect {
        let work = layout.workArea
        let x = preferences.side == .right ? work.maxX - 2 : work.minX
        return NSRect(x: x, y: layout.rail.minY, width: 2, height: layout.rail.height)
    }

    private func corridorContains(_ point: NSPoint, rail: NSRect, card: NSRect?) -> Bool {
        guard let card else { return false }
        let start = preferences.side == .right ? card.maxX : rail.maxX
        let end = preferences.side == .right ? rail.minX : card.minX
        return point.x >= min(start, end) - 6 && point.x <= max(start, end) + 6 && point.y >= card.minY && point.y <= card.maxY
    }

    private func layoutChanged(_ old: Layout?, _ new: Layout) -> Bool {
        guard let old else { return true }
        return old.screen !== new.screen || old.workArea != new.workArea || old.rail != new.rail || old.peek != new.peek || old.cellHeights != new.cellHeights
    }

    private static func displayID(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }
}
