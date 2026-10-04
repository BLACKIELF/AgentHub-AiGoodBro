import AppKit
import SwiftUI

/// Resolve screen identities only from connected macOS displays. The UUID is
/// stable across changes in CGDirectDisplayID; a built-in screen is selected
/// by meaning rather than by the numeric ID assigned at this boot.
@MainActor
enum TokenMonitorEdgeDockScreenCatalog {
    struct Entry {
        let screen: NSScreen
        let identity: TokenMonitorEdgeDockScreenTarget.Identity
    }

    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
        let identity: TokenMonitorEdgeDockScreenTarget.Identity
    }

    private static var identitiesByNumber: [UInt32: TokenMonitorEdgeDockScreenTarget.Identity] = [:]

    static func screensChanged() { identitiesByNumber.removeAll() }

    static func connected() -> [Entry] {
        NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let number else {
                return Entry(screen: screen, identity: .init(numericID: nil, uuid: nil, isBuiltIn: false))
            }
            if let cached = identitiesByNumber[number] { return Entry(screen: screen, identity: cached) }
            let directID = CGDirectDisplayID(number)
            let uuid: UUID? = CGDisplayCreateUUIDFromDisplayID(directID).flatMap { value in
                let string = CFUUIDCreateString(nil, value.takeRetainedValue()) as String
                return UUID(uuidString: string)
            }
            let identity = TokenMonitorEdgeDockScreenTarget.Identity(
                numericID: number, uuid: uuid, isBuiltIn: CGDisplayIsBuiltin(directID) != 0
            )
            identitiesByNumber[number] = identity
            return Entry(screen: screen, identity: identity)
        }
    }

    static func options() -> [Option] {
        connected().compactMap { entry in
            guard let id = TokenMonitorEdgeDockScreenTarget.stableID(for: entry.identity) else { return nil }
            let title: String
            if entry.identity.isBuiltIn {
                title = entry.screen.localizedName
            } else {
                let width = Int(entry.screen.frame.width)
                let height = Int(entry.screen.frame.height)
                title = "\(entry.screen.localizedName) · \(width)×\(height) · \(id.suffix(6).uppercased())"
            }
            return Option(id: id, title: title, identity: entry.identity)
        }
    }
}

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
    private struct Configuration: Equatable {
        let preferences: TokenMonitorEdgeDockPreferences
        let cells: [TokenMonitorEdgeDockCell]
        let language: WidgetLanguage
        let glass: WorkspaceGlassPreferences
        let paletteID: String
        let preferredColorScheme: ColorScheme?
    }

    private struct PeekContent: Equatable {
        let side: TokenMonitorEdgeDockPreferences.Side
        let language: WidgetLanguage
        let glass: WorkspaceGlassPreferences
        let paletteID: String
        let preferredColorScheme: ColorScheme?
    }

    private struct RailContent: Equatable {
        let cells: [TokenMonitorEdgeDockCell]
        let side: TokenMonitorEdgeDockPreferences.Side
        let language: WidgetLanguage
        let glass: WorkspaceGlassPreferences
        let paletteID: String
        let preferredColorScheme: ColorScheme?
        let compact: Bool
        let warnColors: Bool
        let focusedIndex: Int?
        let startIndex: Int
        let pageIndex: Int
        let pageCount: Int
        let isPinned: Bool
    }

    private struct CardContent: Equatable {
        let cell: TokenMonitorEdgeDockCell
        let side: TokenMonitorEdgeDockPreferences.Side
        let language: WidgetLanguage
        let glass: WorkspaceGlassPreferences
        let paletteID: String
        let preferredColorScheme: ColorScheme?
        let tailY: CGFloat
        let isPinned: Bool
        let canPin: Bool
        let isRefreshing: Bool
        let snapshotDescription: String
    }

    private struct Layout {
        let screen: NSScreen
        let workArea: NSRect
        let peek: NSRect
        let rail: NSRect
        let cellTops: [CGFloat]
        let cellHeights: [CGFloat]
        let compact: Bool
        let page: TokenMonitorEdgeDockPage
    }

    private var preferences = TokenMonitorEdgeDockPreferences()
    private var cells: [TokenMonitorEdgeDockCell] = []
    private var language: WidgetLanguage = .zh
    private var glass = WorkspaceGlassPreferences()
    private var paletteCatalog = PaletteCatalog.loadFromMainBundle()
    private var paletteID = PaletteCatalog.defaultPaletteID
    private var preferredColorScheme: ColorScheme?
    private var onPreferencesChange: ((TokenMonitorEdgeDockPreferences) -> Void)?
    private var onOpenDashboard: (() -> Void)?
    private var onOpenUsageOverview: (() -> Void)?
    private var onOpenProxy: (() -> Void)?
    private var onRefresh: ((TokenMonitorEdgeDockCell) async -> Void)?
    private var refreshingCells: Set<String> = []

    private var peekPanel: NSPanel?
    private var railPanel: NSPanel?
    private var cardPanel: NSPanel?
    private var peekHost: NSHostingView<NativePaletteRoot<TokenMonitorEdgeDockPeekView>>?
    private var railHost: NSHostingView<NativePaletteRoot<TokenMonitorEdgeDockRailView>>?
    private var cardHost: NSHostingView<NativePaletteRoot<TokenMonitorEdgeDockCardView>>?
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var layout: Layout?
    private var railVisible = false
    private var railPinned = false
    private var cardPinned = false
    private var cardIndex: Int?
    private var hoveredIndex: Int?
    private var hoverStartedAt: Date?
    private var edgeStartedAt: Date?
    private var outsideStartedAt: Date?
    private var dragStart: NSRect?
    private var isDragging = false
    private var pageIndex = 0
    private var configurationGate = TokenMonitorEdgeDockChangeGate<Configuration>()
    private var lastPeekContent: PeekContent?
    private var lastRailContent: RailContent?
    private var lastCardContent: CardContent?
    private var measuredCardHeights: [String: CGFloat] = [:]

    var isRailVisible: Bool { railVisible && preferences.enabled && railPanel?.isVisible == true }

    func revealFromShortcut() {
        guard preferences.enabled else { return }
        railVisible = true
        railPinned = true
        cardIndex = nil
        cardPinned = false
        updateSurfaces()
    }

    private func toggleRailPinOrHide() {
        guard preferences.enabled else { return }
        if railPinned {
            preferences.enabled = false
            configurationGate.reset()
            hideAll()
            onPreferencesChange?(preferences)
        } else {
            revealFromShortcut()
        }
    }

    func configure(
        preferences: TokenMonitorEdgeDockPreferences,
        cells: [TokenMonitorEdgeDockCell],
        language: WidgetLanguage,
        glass: WorkspaceGlassPreferences = .init(),
        paletteCatalog: PaletteCatalog? = nil,
        paletteID: String = PaletteCatalog.defaultPaletteID,
        preferredColorScheme: ColorScheme? = nil,
        onPreferencesChange: @escaping (TokenMonitorEdgeDockPreferences) -> Void,
        onOpenDashboard: @escaping () -> Void,
        onOpenUsageOverview: @escaping () -> Void,
        onOpenProxy: @escaping () -> Void,
        onRefresh: ((TokenMonitorEdgeDockCell) async -> Void)? = nil
    ) {
        var normalized = preferences.normalized()
        let screens = TokenMonitorEdgeDockScreenCatalog.connected()
        let migrated = TokenMonitorEdgeDockScreenTarget.migratedID(
            normalized.displayID, screens: screens.map(\.identity)
        )
        let needsMigration = migrated != normalized.displayID
        normalized.displayID = migrated
        let configuration = Configuration(
            preferences: normalized, cells: cells, language: language, glass: glass,
            paletteID: paletteID, preferredColorScheme: preferredColorScheme
        )
        self.onPreferencesChange = onPreferencesChange
        self.onOpenDashboard = onOpenDashboard
        self.onOpenUsageOverview = onOpenUsageOverview
        self.onOpenProxy = onOpenProxy
        self.onRefresh = onRefresh
        guard configurationGate.accept(configuration) else { return }
        let previous = self.preferences
        let selectedID = cardIndex.flatMap { self.cells.indices.contains($0) ? self.cells[$0].id : nil }
        self.preferences = normalized
        self.cells = cells
        cardIndex = selectedID.flatMap { id in cells.firstIndex { $0.id == id } }
        if cardIndex == nil { cardPinned = false }
        self.language = language
        self.glass = glass
        if let paletteCatalog { self.paletteCatalog = paletteCatalog }
        self.paletteID = paletteID
        self.preferredColorScheme = preferredColorScheme
        guard self.preferences.enabled, !cells.isEmpty else {
            hideAll()
            return
        }
        observeScreenChanges()
        if previous.side != self.preferences.side || previous.displayID != self.preferences.displayID || previous.offset != self.preferences.offset
            || previous.mode != self.preferences.mode
        {
            cardIndex = nil
            railPinned = false
            cardPinned = false
        }
        if let cardIndex, !cells.indices.contains(cardIndex) { self.cardIndex = nil }
        if let newLayout = makeLayout(using: screens) {
            layout = newLayout
            ensurePanels()
            if self.preferences.mode == .always { railVisible = true }
            updateSurfaces()
        } else {
            suspendForMissingScreen()
        }
        scheduleTick()
        if needsMigration { onPreferencesChange(self.preferences) }
    }

    func shutdown() {
        hideAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for panel in [peekPanel, railPanel, cardPanel] { panel?.close() }
        peekPanel = nil
        railPanel = nil
        cardPanel = nil
        peekHost = nil
        railHost = nil
        cardHost = nil
        onPreferencesChange = nil
        onOpenDashboard = nil
        onOpenUsageOverview = nil
        onOpenProxy = nil
        onRefresh = nil
        refreshingCells.removeAll()
        configurationGate.reset()
        lastPeekContent = nil
        lastRailContent = nil
        lastCardContent = nil
        measuredCardHeights.removeAll()
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
        cardPinned = false
        isDragging = false
        dragStart = nil
        layout = nil
    }

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                TokenMonitorEdgeDockScreenCatalog.screensChanged()
                self?.refreshScreenLayout()
            }
        }
    }

    private func suspendForMissingScreen() {
        guard
            layout != nil || peekPanel?.isVisible == true || railPanel?.isVisible == true
                || cardPanel?.isVisible == true
        else { return }
        layout = nil
        if peekPanel?.isVisible == true { peekPanel?.orderOut(nil) }
        if railPanel?.isVisible == true { railPanel?.orderOut(nil) }
        if cardPanel?.isVisible == true { cardPanel?.orderOut(nil) }
        railVisible = false
        cardIndex = nil
        hoveredIndex = nil
        edgeStartedAt = nil
        hoverStartedAt = nil
        outsideStartedAt = nil
        railPinned = false
        cardPinned = false
        dragStart = nil
        isDragging = false
    }

    private func refreshScreenLayout() {
        guard preferences.enabled, !cells.isEmpty else { return }
        let screens = TokenMonitorEdgeDockScreenCatalog.connected()
        let migrated = TokenMonitorEdgeDockScreenTarget.migratedID(
            preferences.displayID, screens: screens.map(\.identity)
        )
        if migrated != preferences.displayID {
            preferences.displayID = migrated
            onPreferencesChange?(preferences)
        }
        guard let newLayout = makeLayout(using: screens) else {
            suspendForMissingScreen()
            return
        }
        if layoutChanged(layout, newLayout) {
            let hadLayout = layout != nil
            layout = newLayout
            ensurePanels()
            if !hadLayout && preferences.mode == .always { railVisible = true }
            updateSurfaces()
        }
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

    private func themed<Content: View>(_ content: Content) -> NativePaletteRoot<Content> {
        NativePaletteRoot(
            content: content, catalog: paletteCatalog, paletteID: paletteID,
            preferredColorScheme: preferredColorScheme, glass: glass
        )
    }

    private func updateSurfaces() {
        guard let layout else { return }
        if let cardIndex, !cells.indices.contains(cardIndex) || !layout.page.indices.contains(cardIndex) {
            self.cardIndex = nil
            cardPinned = false
            hoveredIndex = nil
            hoverStartedAt = nil
            outsideStartedAt = nil
        }
        let peek = peekPanel
        let rail = railPanel
        let card = cardPanel
        let isAutoHidden = preferences.mode == .autoHide && !railVisible

        if let peek, peek.frame != layout.peek { peek.setFrame(layout.peek, display: false) }
        if isAutoHidden {
            if let peek {
                let content = PeekContent(
                    side: preferences.side, language: language, glass: glass,
                    paletteID: paletteID, preferredColorScheme: preferredColorScheme
                )
                if peekHost == nil || lastPeekContent != content {
                    let view = themed(
                        TokenMonitorEdgeDockPeekView(side: preferences.side, language: language, glass: glass) { [weak self] in self?.revealRail() }
                    )
                    if let peekHost {
                        peekHost.rootView = view
                    } else {
                        let host = NSHostingView(rootView: view)
                        peek.contentView = host
                        peekHost = host
                    }
                    lastPeekContent = content
                }
                if !peek.isVisible { peek.orderFrontRegardless() }
            }
        } else {
            if peek?.isVisible == true { peek?.orderOut(nil) }
        }

        if let rail, rail.frame != layout.rail { rail.setFrame(layout.rail, display: false) }
        if railVisible, let rail {
            let content = RailContent(
                cells: Array(cells[layout.page.indices]), side: preferences.side, language: language, glass: glass,
                paletteID: paletteID, preferredColorScheme: preferredColorScheme,
                compact: layout.compact, warnColors: preferences.warnColors,
                focusedIndex: cardIndex.map { $0 - layout.page.indices.lowerBound },
                startIndex: layout.page.indices.lowerBound,
                pageIndex: layout.page.index, pageCount: layout.page.count, isPinned: railPinned
            )
            if railHost == nil || lastRailContent != content {
                let view = themed(
                    TokenMonitorEdgeDockRailView(
                        cells: content.cells, side: content.side, language: content.language, glass: content.glass,
                        compact: content.compact, warnColors: content.warnColors,
                        focusedIndex: content.focusedIndex, pageIndex: content.pageIndex, pageCount: content.pageCount,
                        isPinned: content.isPinned, onPin: { [weak self] in self?.toggleRailPinOrHide() },
                        onPage: { [weak self] direction in self?.changePage(direction) },
                        onSelect: { [weak self] index in self?.activateCell(at: index + content.startIndex) },
                        onDrag: { [weak self] translation in self?.dragRail(translation) },
                        onDrop: { [weak self] translation in self?.dropRail(translation) }
                    ))
                if let railHost {
                    railHost.rootView = view
                } else {
                    let host = NSHostingView(rootView: view)
                    rail.contentView = host
                    railHost = host
                }
                lastRailContent = content
            }
            if !rail.isVisible { rail.orderFrontRegardless() }
        } else {
            if rail?.isVisible == true { rail?.orderOut(nil) }
        }

        if let index = cardIndex, cells.indices.contains(index), railVisible,
            let card, let placement = cardPlacement(index: index, layout: layout)
        {
            if card.frame != placement.frame { card.setFrame(placement.frame, display: false) }
            let content = CardContent(
                cell: cells[index], side: preferences.side, language: language, glass: glass,
                paletteID: paletteID, preferredColorScheme: preferredColorScheme,
                tailY: placement.tailY, isPinned: cardPinned,
                canPin: true, isRefreshing: refreshingCells.contains(cells[index].id),
                snapshotDescription: cells[index].snapshotDescription(language)
            )
            if cardHost == nil || lastCardContent != content {
                let view = themed(
                    TokenMonitorEdgeDockCardView(
                        cell: content.cell, side: content.side, language: content.language, glass: content.glass,
                        tailY: content.tailY, isPinned: content.isPinned, canPin: content.canPin,
                        onPin: { [weak self] in self?.togglePin() },
                        onOpenDashboard: { [weak self] in self?.openDashboard() },
                        onOpenProxy: { [weak self] in self?.openProxySettings() },
                        snapshotDescription: content.snapshotDescription,
                        isRefreshing: content.isRefreshing,
                        onRefresh: onRefresh == nil ? nil : { [weak self] in self?.refresh(content.cell) },
                        onContentHeightChange: { [weak self] height in
                            self?.resizeCardForContent(height, cellID: content.cell.id)
                        }
                    ))
                if let cardHost {
                    cardHost.rootView = view
                } else {
                    let host = NSHostingView(rootView: view)
                    card.contentView = host
                    cardHost = host
                }
                lastCardContent = content
            }
            if !card.isVisible { card.orderFrontRegardless() }
        } else {
            if card?.isVisible == true { card?.orderOut(nil) }
        }
    }

    private func refresh(_ cell: TokenMonitorEdgeDockCell) {
        guard let onRefresh, !refreshingCells.contains(cell.id) else { return }
        refreshingCells.insert(cell.id)
        updateSurfaces()
        Task { @MainActor [weak self] in
            await onRefresh(cell)
            guard let self else { return }
            self.refreshingCells.remove(cell.id)
            self.updateSurfaces()
        }
    }

    private func resizeCardForContent(_ height: CGFloat, cellID: String) {
        guard height.isFinite, height > 0,
            let index = cardIndex, cells.indices.contains(index), cells[index].id == cellID,
            cardUsesContentHeight(cells[index])
        else { return }
        let measured = ceil(height) + 1
        if let previous = measuredCardHeights[cellID], abs(previous - measured) < 1 { return }
        measuredCardHeights[cellID] = measured
        updateSurfaces()
    }

    private func cardUsesContentHeight(_ cell: TokenMonitorEdgeDockCell) -> Bool {
        cell.kind != .provider || (cell.providerID != "codex" && cell.accounts.count <= 1)
    }

    private func scheduleTick() {
        guard timer == nil, preferences.enabled, !cells.isEmpty else { return }
        let point = NSEvent.mouseLocation
        let nearEdge =
            layout.map {
                $0.rail.insetBy(dx: -64, dy: -32).contains(point)
                    || $0.peek.insetBy(dx: -64, dy: -32).contains(point)
                    || (cardPanel?.isVisible == true
                        && cardPanel?.frame.insetBy(dx: -24, dy: -24).contains(point) == true)
            } ?? false
        let interval = TokenMonitorEdgeDockIdlePolicy.tickInterval(
            nearEdge: nearEdge, hasCard: cardIndex != nil && !cardPinned, dragging: isDragging,
            waitingOutside: outsideStartedAt != nil
        )
        let next = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.tick()
                self.scheduleTick()
            }
        }
        next.tolerance = interval == 0.05 ? 0.01 : 0.03
        timer = next
    }

    private func tick() {
        guard preferences.enabled, !cells.isEmpty else { return }
        // Live monitor changes, a detached display or a moving Dock can change
        // visibleFrame while the app stays open. Clamp the native panels before
        // reading hit targets so they never remain stranded off-screen.
        refreshScreenLayout()
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
        if !cardPinned, let index, let hoverStartedAt, now.timeIntervalSince(hoverStartedAt) >= 0.07 {
            let nextCard = index
            if cardIndex != nextCard {
                cardIndex = nextCard
                updateSurfaces()
            }
        }

        // Reuse the existing hover tick. The content gate changes only when
        // the age label changes; no second timer or quota request is created.
        if let cardIndex, cells.indices.contains(cardIndex), cells[cardIndex].kind != .proxy,
            lastCardContent?.snapshotDescription != cells[cardIndex].snapshotDescription(language, now: now)
        {
            updateSurfaces()
        }
        let overRail = layout.rail.contains(point)
        let overCard = cardPanel?.isVisible == true && cardPanel?.frame.contains(point) == true
        let crossing = cardPanel?.isVisible == true && corridorContains(point, rail: layout.rail, card: cardPanel?.frame)
        if overRail || overCard || crossing || edgeTrigger(layout).contains(point) {
            outsideStartedAt = nil
            return
        }
        guard
            TokenMonitorEdgeDockIdlePolicy.shouldClearOutside(
                hasCard: cardIndex != nil, railVisible: railVisible,
                mode: preferences.mode, pinned: railPinned, cardPinned: cardPinned
            )
        else {
            outsideStartedAt = nil
            return
        }
        if outsideStartedAt == nil { outsideStartedAt = now }
        if let outsideStartedAt, now.timeIntervalSince(outsideStartedAt) >= 0.32 {
            let hadCard = cardIndex != nil
            let hideRail = preferences.mode == .autoHide && !railPinned
            cardIndex = nil
            hoveredIndex = nil
            hoverStartedAt = nil
            if hideRail { railVisible = false }
            self.outsideStartedAt = nil
            if hadCard || hideRail { updateSurfaces() }
        }
    }

    private func revealRail() {
        edgeStartedAt = nil
        railVisible = true
        updateSurfaces()
    }

    func activateCell(at index: Int) {
        guard cells.indices.contains(index) else { return }
        if cells[index].kind == .provider && cells[index].providerID == "codex" {
            cardIndex = nil
            cardPinned = false
            hoveredIndex = index
            // Leave and re-enter before showing the quota hover card again;
            // otherwise the next pointer tick covers the newly opened overview.
            hoverStartedAt = nil
            updateSurfaces()
            onOpenUsageOverview?()
            return
        }
        if cells[index].kind == .proxy {
            hoveredIndex = index
            openProxySettings()
            return
        }
        railPinned = true
        railVisible = true
        if cardIndex != index { cardPinned = false }
        cardIndex = index
        hoveredIndex = index
        hoverStartedAt = Date()
        outsideStartedAt = nil
        updateSurfaces()
    }

    private func openProxySettings() {
        cardIndex = nil
        cardPinned = false
        hoverStartedAt = nil
        outsideStartedAt = nil
        updateSurfaces()
        onOpenProxy?()
    }

    private func openDashboard() {
        cardIndex = nil
        cardPinned = false
        hoverStartedAt = nil
        outsideStartedAt = nil
        updateSurfaces()
        onOpenDashboard?()
    }

    static func navigationSelfTest() -> Bool {
        let dock = TokenMonitorEdgeDockController()
        let cells = TokenMonitorEdgeDockProjection.make(
            preferences: .init(items: [.limit("codex"), .proxy()]), quotaSources: [],
            usage: TokenMonitorDashboardSnapshot(response: nil), language: .en)
        var usageOpens = 0
        var proxyOpens = 0
        dock.configure(
            preferences: .init(), cells: cells, language: .en,
            onPreferencesChange: { _ in }, onOpenDashboard: {},
            onOpenUsageOverview: { usageOpens += 1 }, onOpenProxy: { proxyOpens += 1 })
        defer { dock.shutdown() }
        dock.preferences.enabled = true
        dock.preferences.mode = .autoHide
        dock.railVisible = false
        dock.revealFromShortcut()
        guard dock.railVisible, dock.railPinned, dock.preferences.mode == .autoHide else { return false }
        dock.toggleRailPinOrHide()
        guard !dock.preferences.enabled else { return false }
        dock.configure(
            preferences: .init(), cells: cells, language: .zh,
            onPreferencesChange: { _ in }, onOpenDashboard: {},
            onOpenUsageOverview: { usageOpens += 1 }, onOpenProxy: { proxyOpens += 1 })
        dock.tick()
        dock.revealFromShortcut()
        guard !dock.railVisible, !dock.railPinned, dock.peekPanel?.isVisible != true,
            dock.railPanel?.isVisible != true, dock.timer == nil
        else { return false }
        let shortcutPreferences = TokenMonitorEdgeDockPreferences(
            enabled: true, mode: .autoHide, displayID: "uuid:" + UUID().uuidString,
            items: [.limit("codex"), .proxy()])
        func configureShortcutPreferences() {
            dock.configure(
                preferences: shortcutPreferences, cells: cells, language: .en,
                onPreferencesChange: { _ in }, onOpenDashboard: {},
                onOpenUsageOverview: { usageOpens += 1 }, onOpenProxy: { proxyOpens += 1 })
        }
        configureShortcutPreferences()
        dock.revealFromShortcut()
        dock.toggleRailPinOrHide()
        guard !dock.preferences.enabled, !dock.railVisible, dock.timer == nil else { return false }
        // No intermediate disabled configuration: the same enabled snapshot must be accepted again.
        configureShortcutPreferences()
        dock.revealFromShortcut()
        guard dock.preferences == shortcutPreferences.normalized(), dock.railVisible, dock.railPinned,
            dock.timer != nil, dock.peekPanel == nil, dock.railPanel == nil, dock.cardPanel == nil
        else { return false }

        for index in [0, 1] {
            dock.cardIndex = index
            dock.cardPinned = true
            dock.hoveredIndex = index
            dock.hoverStartedAt = .distantPast
            dock.activateCell(at: index)
            guard dock.cardIndex == nil, !dock.cardPinned, dock.hoverStartedAt == nil, dock.hoveredIndex == index else { return false }
        }
        for mode in [TokenMonitorEdgeDockPreferences.Mode.always, .autoHide] {
            dock.preferences.mode = mode
            dock.cardIndex = 1
            dock.togglePin()
            guard dock.cardPinned,
                !TokenMonitorEdgeDockIdlePolicy.shouldClearOutside(
                    hasCard: true, railVisible: true, mode: mode, pinned: false, cardPinned: dock.cardPinned)
            else { return false }
            dock.togglePin()
            guard !dock.cardPinned,
                TokenMonitorEdgeDockIdlePolicy.shouldClearOutside(
                    hasCard: true, railVisible: true, mode: mode, pinned: false, cardPinned: dock.cardPinned)
            else { return false }
        }
        dock.cardIndex = 1
        dock.hoverStartedAt = .distantPast
        dock.openProxySettings()
        return usageOpens == 1 && proxyOpens == 2 && dock.cardIndex == nil && dock.hoverStartedAt == nil
    }

    private func changePage(_ direction: Int) {
        guard let layout else { return }
        pageIndex = max(0, min(layout.page.count - 1, layout.page.index + direction))
        cardIndex = nil
        cardPinned = false
        hoveredIndex = nil
        hoverStartedAt = nil
        self.layout = makeLayout()
        updateSurfaces()
    }

    private func togglePin() {
        guard let cardIndex, cells.indices.contains(cardIndex) else { return }
        cardPinned.toggle()
        outsideStartedAt = nil
        if cardPinned { railVisible = true }
        updateSurfaces()
    }

    private func dragRail(_ translation: CGSize) {
        guard let panel = railPanel, let layout else { return }
        if dragStart == nil { dragStart = layout.rail }
        isDragging = true
        cardIndex = nil
        cardPinned = false
        cardPanel?.orderOut(nil)
        guard let start = dragStart else { return }
        let translatedX = start.minX + translation.width
        let newX =
            preferences.displayID == nil
            ? translatedX
            : max(
                layout.workArea.minX,
                min(layout.workArea.maxX - start.width, translatedX)
            )
        let newY = max(
            layout.workArea.minY + 8,
            min(layout.workArea.maxY - start.height - 8, start.minY - translation.height))
        panel.setFrameOrigin(NSPoint(x: newX, y: newY))
    }

    private func dropRail(_ translation: CGSize) {
        guard let start = dragStart, let layout else { return }
        defer {
            dragStart = nil
            isDragging = false
        }
        let screens = TokenMonitorEdgeDockScreenCatalog.connected()
        guard let originIndex = screens.firstIndex(where: { $0.screen === layout.screen }) else {
            refreshScreenLayout()
            return
        }
        let dropped = NSPoint(x: start.midX + translation.width, y: start.midY - translation.height)
        let destinationIndex =
            preferences.displayID == nil
            ? screens.firstIndex(where: { $0.screen.frame.contains(dropped) }) ?? originIndex
            : originIndex
        let target = TokenMonitorEdgeDockScreenTarget.targetAfterDrag(
            preferences.displayID, originIndex: originIndex, destinationIndex: destinationIndex,
            screens: screens.map(\.identity)
        )
        let destination =
            preferences.displayID == nil && target != nil
            ? screens[destinationIndex].screen : layout.screen
        let placement = TokenMonitorEdgeDockNativeGeometry.placementAfterDrag(
            rail: start, translation: translation, destinationWorkArea: destination.visibleFrame
        )
        var next = preferences
        next.side = placement.side
        next.offset = placement.offset
        next.displayID = target
        let changed = next.normalized() != preferences
        preferences = next.normalized()
        if changed { configurationGate.reset() }
        self.layout = makeLayout(using: screens)
        updateSurfaces()
        if changed { onPreferencesChange?(preferences) }
    }

    private func makeLayout(using screens: [TokenMonitorEdgeDockScreenCatalog.Entry]? = nil) -> Layout? {
        let screens = screens ?? TokenMonitorEdgeDockScreenCatalog.connected()
        let main = NSScreen.main
        let mainNumber = (main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let preferredIndex = screens.firstIndex {
            $0.screen === main || (mainNumber != nil && $0.identity.numericID == mainNumber)
        }
        guard
            let index = TokenMonitorEdgeDockScreenTarget.index(
                for: preferences.displayID, in: screens.map(\.identity), preferredIndex: preferredIndex
            )
        else { return nil }
        let screen = screens[index].screen
        let work = screen.visibleFrame
        let normal = cells.map { $0.kind == .stat ? CGFloat(56) : CGFloat(70) }
        let compressed = cells.map { $0.kind == .stat ? CGFloat(48) : CGFloat(54) }
        let chrome: CGFloat = 28 * 2 + 4 * 2
        let gaps = CGFloat(max(0, cells.count - 1)) * 2
        let compact = chrome + normal.reduce(0, +) + gaps > work.height - 16
        let page =
            compact
            ? TokenMonitorEdgeDockPage.make(cellCount: cells.count, availableHeight: Double(work.height - 16), index: pageIndex)
            : TokenMonitorEdgeDockPage(indices: cells.indices, index: 0, count: 1)
        let heights = Array((compact ? compressed : normal)[page.indices])
        let fullHeight = chrome + heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 2
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
            cellTops: tops, cellHeights: heights, compact: compact, page: page)
    }

    private func cardPlacement(index: Int, layout: Layout) -> (frame: NSRect, tailY: CGFloat)? {
        guard layout.page.indices.contains(index) else { return nil }
        let localIndex = index - layout.page.indices.lowerBound
        let cellCenter = layout.rail.maxY - layout.cellTops[localIndex] - layout.cellHeights[localIndex] / 2
        let cell = cells[index]
        let rows = cell.kind == .stat ? min(12, max(cell.byTool.count, cell.byModel.count)) : cell.accounts.reduce(0) { $0 + max(1, $1.quotaRows.count) }
        let preferredHeight: CGFloat
        if cardUsesContentHeight(cell), let measured = measuredCardHeights[cell.id] {
            preferredHeight = measured
        } else if cell.kind == .proxy {
            preferredHeight = max(164, min(520, 132 + CGFloat(cell.proxyAccounts.count) * 100))
        } else if cell.kind == .provider && cell.providerID != "codex" {
            if cell.accounts.count > 1 {
                preferredHeight = 480
            } else {
                preferredHeight = measuredCardHeights[cell.id] ?? max(190, 190 + CGFloat(rows) * 48)
            }
        } else {
            preferredHeight = cell.kind == .stat ? max(190, min(520, 132 + CGFloat(rows) * 44)) : max(150, min(480, 102 + CGFloat(rows) * 37))
        }
        let frame = TokenMonitorEdgeDockNativeGeometry.cardFrame(
            rail: layout.rail, centerY: cellCenter, height: preferredHeight,
            workArea: layout.workArea, side: preferences.side
        )
        return (frame, frame.maxY - cellCenter)
    }

    private func cellAt(_ point: NSPoint, layout: Layout) -> Int? {
        guard layout.rail.contains(point), abs(point.x - layout.rail.midX) <= 28 else { return nil }
        let localTop = layout.rail.maxY - point.y
        for index in layout.cellTops.indices {
            if localTop >= layout.cellTops[index] && localTop < layout.cellTops[index] + layout.cellHeights[index] + 2 {
                return index + layout.page.indices.lowerBound
            }
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
        return old.screen !== new.screen || old.workArea != new.workArea || old.rail != new.rail || old.peek != new.peek
            || old.cellHeights != new.cellHeights || old.page.indices != new.page.indices
    }

}
