import Cocoa
import Combine
import SwiftUI

@MainActor
final class AccountFloatingPanelController: NSObject, NSWindowDelegate {
    static let expandedSize = NSSize(width: 380, height: 550)
    static let compactSize = NSSize(width: 380, height: 64)

    private let store: UsageStore
    private let settings: AppSettings
    private let updateStore: AppUpdateStore
    private let paletteCatalog: PaletteCatalog
    private let localCLIAccounts: LocalCLIAccountStore
    private let openFullWindow: () -> Void
    private let openPaletteLibrary: () -> Void
    private let quit: () -> Void
    private let defaults: UserDefaults
    private let visibilityDidChange: (Bool) -> Void
    private var panel: AccountFloatingPanel?
    private var model: AccountFloatingPanelModel?
    private var cancellables = Set<AnyCancellable>()
    private var lifecycle = AccountFloatingPanelLifecycle()
    private var persistedState: AccountFloatingPanelPersistedState

    var isVisible: Bool { panel?.isVisible == true }

    init(
        store: UsageStore,
        settings: AppSettings,
        updateStore: AppUpdateStore,
        paletteCatalog: PaletteCatalog,
        defaults: UserDefaults = .standard,
        localCLIAccounts: LocalCLIAccountStore? = nil,
        openFullWindow: @escaping () -> Void,
        openPaletteLibrary: @escaping () -> Void,
        quit: @escaping () -> Void,
        visibilityDidChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.store = store
        self.settings = settings
        self.updateStore = updateStore
        self.paletteCatalog = paletteCatalog
        self.defaults = defaults
        self.localCLIAccounts = localCLIAccounts ?? LocalCLIAccountStore()
        self.openFullWindow = openFullWindow
        self.openPaletteLibrary = openPaletteLibrary
        self.quit = quit
        self.visibilityDidChange = visibilityDidChange
        self.persistedState = AccountFloatingPanelStateStore.load(from: defaults)
        super.init()
    }

    func show(initialScreen: CodexAccountMenuView.Screen? = nil) {
        switch lifecycle.beginShowing() {
        case .reuse:
            guard let panel else {
                lifecycle.finishClosing()
                show(initialScreen: initialScreen)
                return
            }
            model?.isCollapsed = false
            if let initialScreen {
                model?.screen = initialScreen.floatingScreen
            }
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        case .create:
            break
        }

        persistedState = AccountFloatingPanelStateStore.load(from: defaults)
        let model = AccountFloatingPanelModel(
            screen: initialScreen?.floatingScreen ?? persistedState.screen,
            isPinned: persistedState.isPinned
        )
        self.model = model
        observe(model)

        let panel = AccountFloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.title = settings.language.text("账号浮窗", "Account Panel")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.escapeHandler = { [weak self] in self?.close() }
        panel.contentView = GlassHostingContainer(
            rootView: CodexAccountMenuView(
                store: store,
                settings: settings,
                updateStore: updateStore,
                paletteCatalog: paletteCatalog,
                panelModel: model,
                isFloatingPanel: true,
                localCLIAccounts: localCLIAccounts,
                openFullWindow: { [weak self] in
                    guard let self else { return }
                    self.close()
                    self.openFullWindow()
                },
                openPaletteLibrary: { [weak self] in
                    guard let self else { return }
                    self.openPaletteLibrary()
                },
                quit: { [weak self] in
                    self?.quit()
                },
                onClose: { [weak self] in self?.close() },
                onTogglePinned: { [weak self] in self?.togglePinned() },
                preferredContentSize: Self.expandedSize
            ),
            cornerRadius: 20,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            allowsWindowDragging: false
        )
        self.panel = panel
        position(panel, persisted: persistedState)
        applyPinnedState()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        visibilityDidChange(true)
    }

    func close() {
        guard let panel else {
            lifecycle.finishClosing()
            return
        }
        saveState()
        panel.delegate = nil
        panel.escapeHandler = nil
        panel.contentView = nil
        self.panel = nil
        self.model = nil
        cancellables.removeAll()
        lifecycle.finishClosing()
        panel.close()
        visibilityDidChange(false)
    }

    func shutdown() {
        close()
        cancellables.removeAll()
        model = nil
        lifecycle.finishClosing()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? AccountFloatingPanel,
            closingPanel === panel
        else { return }
        saveState()
        closingPanel.delegate = nil
        closingPanel.contentView = nil
        panel = nil
        model = nil
        cancellables.removeAll()
        lifecycle.finishClosing()
        visibilityDidChange(false)
    }

    func windowDidMove(_ notification: Notification) {
        clampPanelToVisibleWorkspace()
        saveState()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        clampPanelToVisibleWorkspace()
        saveState()
    }

    private func observe(_ model: AccountFloatingPanelModel) {
        cancellables.removeAll()
        model.$isCollapsed
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isCollapsed in
                self?.resizePanel(isCollapsed: isCollapsed)
            }
            .store(in: &cancellables)

        model.$screen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.saveState() }
            .store(in: &cancellables)

        model.$isPinned
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyPinnedState()
                self?.saveState()
            }
            .store(in: &cancellables)

        settings.$language
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] language in
                self?.panel?.title = language.text("账号浮窗", "Account Panel")
            }
            .store(in: &cancellables)
    }

    private func resizePanel(isCollapsed: Bool) {
        guard let panel else { return }
        let targetSize = isCollapsed ? Self.compactSize : Self.expandedSize
        var frame = panel.frame
        let top = frame.maxY
        frame.size = targetSize
        frame.origin.y = top - targetSize.height
        let visibleFrame = visibleFrame(for: frame.origin)
        frame = AccountFloatingPanelStateStore.clampedFrame(
            origin: frame.origin,
            size: targetSize,
            visibleFrame: visibleFrame
        )
        panel.setFrame(
            frame,
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        saveState()
    }

    private func position(
        _ panel: AccountFloatingPanel,
        persisted: AccountFloatingPanelPersistedState
    ) {
        let proposedOrigin = persisted.frame?.point ?? CGPoint(x: 0, y: 0)
        let visibleFrame: CGRect
        if persisted.frame == nil {
            let screen =
                NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
            visibleFrame = screen
            let origin = CGPoint(
                x: screen.midX - Self.expandedSize.width / 2,
                y: screen.maxY - Self.expandedSize.height - 18
            )
            let frame = AccountFloatingPanelStateStore.clampedFrame(
                origin: origin,
                size: Self.expandedSize,
                visibleFrame: visibleFrame
            )
            panel.setFrame(frame, display: false)
        } else {
            visibleFrame = self.visibleFrame(for: proposedOrigin)
            let frame = AccountFloatingPanelStateStore.clampedFrame(
                origin: proposedOrigin,
                size: Self.expandedSize,
                visibleFrame: visibleFrame
            )
            panel.setFrame(frame, display: false)
        }
    }

    private func visibleFrame(for origin: CGPoint) -> CGRect {
        let frames = NSScreen.screens.map { $0.visibleFrame }
        return AccountFloatingPanelStateStore.screenVisibleFrame(
            containing: origin,
            screens: frames
        ) ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
    }

    private func clampPanelToVisibleWorkspace() {
        guard let panel else { return }
        let visibleFrame = visibleFrame(for: panel.frame.origin)
        let clamped = AccountFloatingPanelStateStore.clampedFrame(
            origin: panel.frame.origin,
            size: panel.frame.size,
            visibleFrame: visibleFrame
        )
        guard clamped != panel.frame else { return }
        panel.setFrame(clamped, display: true)
    }

    private func togglePinned() {
        guard let model else { return }
        model.isPinned.toggle()
    }

    private func applyPinnedState() {
        guard let panel else { return }
        if model?.isPinned == true {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            panel.level = .normal
            panel.collectionBehavior = [.fullScreenAuxiliary]
        }
    }

    private func saveState() {
        guard let panel else { return }
        // Persist the expanded frame's bottom anchor while collapsed so a
        // later reopen restores the same desktop position instead of shifting
        // down by the collapsed height delta.
        let savedOrigin = AccountFloatingPanelStateStore.persistedOrigin(
            panelFrame: panel.frame,
            expandedSize: Self.expandedSize,
            isCollapsed: model?.isCollapsed == true
        )
        let state = AccountFloatingPanelPersistedState(
            frame: AccountFloatingPanelFrame(origin: savedOrigin),
            screen: model?.screen ?? persistedState.screen,
            isPinned: model?.isPinned ?? persistedState.isPinned
        )
        persistedState = state
        AccountFloatingPanelStateStore.save(state, to: defaults)
    }
}

@MainActor
private final class AccountFloatingPanel: NSPanel {
    var escapeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            escapeHandler?()
            return
        }
        super.keyDown(with: event)
    }
}
