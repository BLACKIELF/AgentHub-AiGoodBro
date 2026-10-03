import Cocoa
import Combine
import SwiftUI

@MainActor
final class TaskOverviewPanelViewModel: ObservableObject {
    @Published var presentation: TaskOverviewPresentation?
    @Published var workbench: TaskWorkbenchPresentation?
    @Published var isExpanded = false
    @Published var language: WidgetLanguage

    init(language: WidgetLanguage) {
        self.language = language
    }
}

@MainActor
final class TaskOverviewPanelController: NSObject, NSWindowDelegate {
    static let compactSize = NSSize(width: 360, height: 370)
    static let expandedSize = NSSize(width: 400, height: 492)

    private let store: UsageStore
    private let settings: AppSettings
    private let openTask: (RuntimeScope, String?) -> Void
    private let openWorkspace: () -> Void
    private let visibilityDidChange: (Bool) -> Void
    private var panel: TaskOverviewPanel?
    private var viewModel: TaskOverviewPanelViewModel?
    private var cancellables = Set<AnyCancellable>()
    private var lifecycle = TaskOverviewPanelLifecycle()

    var isVisible: Bool { panel?.isVisible == true }

    init(
        store: UsageStore,
        settings: AppSettings,
        openTask: @escaping (RuntimeScope, String?) -> Void,
        openWorkspace: @escaping () -> Void,
        visibilityDidChange: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.settings = settings
        self.openTask = openTask
        self.openWorkspace = openWorkspace
        self.visibilityDidChange = visibilityDidChange
        super.init()
    }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        switch lifecycle.beginShowing() {
        case .reuse:
            if let panel {
                panel.makeKeyAndOrderFront(nil)
                return
            }
            lifecycle.finishClosing()
            show()
            return
        case .create:
            break
        }

        let model = TaskOverviewPanelViewModel(language: settings.language)
        viewModel = model
        startObserving(model)

        let panel = TaskOverviewPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.title = settings.language.text("任务概览", "Task Overview")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.escapeHandler = { [weak self] in self?.close() }
        panel.contentViewController = NSHostingController(
            rootView: TaskOverviewPanelView(
                model: model,
                onClose: { [weak self] in self?.close() },
                onOpenTask: { [weak self] item in
                    guard let self else { return }
                    self.close()
                    self.openTask(item.runtimeScope, item.threadID)
                },
                onOpenWorkspace: { [weak self] in
                    guard let self else { return }
                    self.close()
                    self.openWorkspace()
                }
            )
        )
        _ = panel.setFrameAutosaveName("CodexAccountManagerNext.taskOverviewPanel")
        if panel.frame.origin == .zero {
            positionNearTopCenter(panel, size: Self.compactSize)
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        visibilityDidChange(true)
    }

    func close() {
        guard let panel else { return }
        panel.delegate = nil
        finishClosing(panel)
        panel.close()
    }

    func shutdown() {
        close()
        cancellables.removeAll()
        viewModel = nil
        lifecycle.finishClosing()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? TaskOverviewPanel,
            closingPanel === panel
        else { return }
        finishClosing(closingPanel)
    }

    private func startObserving(_ model: TaskOverviewPanelViewModel) {
        cancellables.removeAll()

        store.taskWorkbench.$presentation
            .receive(on: RunLoop.main)
            .sink { [weak model] workbench in
                model?.presentation = workbench?.overview
                model?.workbench = workbench
            }
            .store(in: &cancellables)

        settings.$language
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak model, weak self] language in
                model?.language = language
                self?.panel?.title = language.text("任务概览", "Task Overview")
            }
            .store(in: &cancellables)

        model.$isExpanded
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                self?.resizePanel(expanded: expanded)
            }
            .store(in: &cancellables)
    }

    private func finishClosing(_ closingPanel: NSPanel) {
        guard closingPanel === panel else { return }
        closingPanel.contentViewController = nil
        panel = nil
        viewModel = nil
        cancellables.removeAll()
        lifecycle.finishClosing()
        visibilityDidChange(false)
    }

    private func resizePanel(expanded: Bool) {
        guard let panel else { return }
        let size = expanded ? Self.expandedSize : Self.compactSize
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        panel.setFrame(
            frame,
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func positionNearTopCenter(_ panel: NSPanel, size: NSSize) {
        let visibleFrame =
            NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 18
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

@MainActor
private final class TaskOverviewPanel: NSPanel {
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
