import Carbon.HIToolbox
import Cocoa
import Combine
import SwiftUI

private func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { result, byte in
        (result << 8) + OSType(byte)
    }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class GlassHostingContainer<Content: View>: NSView {
    private let cornerRadius: CGFloat

    init(rootView: Content, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        let host = DraggableHostingView(rootView: rootView)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]

        #if compiler(>=6.2) && CAMNEXT_HAS_LIQUID_GLASS
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: bounds)
                glass.autoresizingMask = [.width, .height]
                glass.cornerRadius = cornerRadius
                glass.style = .regular
                glass.tintColor = nil
                glass.contentView = host
                addSubview(glass)
            } else {
                installMaterialFallback(host: host)
            }
        #else
            installMaterialFallback(host: host)
        #endif
    }

    private func installMaterialFallback(host: NSView) {
        let material = NSVisualEffectView(frame: bounds)
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        material.addSubview(host)
        addSubview(material)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    /// Native fullscreen fills the screen, so the rounded floating-panel frame
    /// must flatten on entry and restore on exit. Keep every subview layer in
    /// sync so no glass/material layer keeps clipping to the old radius.
    func updateCornerRadius(_ radius: CGFloat) {
        layer?.cornerRadius = radius
        for subview in subviews {
            #if compiler(>=6.2) && CAMNEXT_HAS_LIQUID_GLASS
                if #available(macOS 26.0, *), let glass = subview as? NSGlassEffectView {
                    glass.cornerRadius = radius
                    continue
                }
            #endif
            if let material = subview as? NSVisualEffectView {
                material.layer?.cornerRadius = radius
                material.layer?.masksToBounds = radius > 0
            }
        }
    }
}

/// Non-generic handle so the window delegate can toggle the container's
/// rounded frame without naming the hosted SwiftUI root type.
private protocol FullscreenRoundedContent: AnyObject {
    func updateCornerRadius(_ radius: CGFloat)
}

extension GlassHostingContainer: FullscreenRoundedContent {}

final class MainAppWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "AiGoodBro"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.fullScreenPrimary]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, TokenMonitorFloatingBubbleSessionOwner {
    private let startupPerformanceSpan = PerformanceMonitor.shared.begin(.appStartup)
    private let store = UsageStore()
    private let localCLIAccounts = LocalCLIAccountStore()
    private let paletteCatalog = PaletteCatalog.loadFromMainBundle()
    private lazy var settings = AppSettings(paletteCatalog: paletteCatalog)
    private lazy var updateStore = AppUpdateStore(settings: settings)
    private var window: MainAppWindow?
    private var paletteLibraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var taskOverviewController: TaskOverviewPanelController?
    private var accountFloatingPanelController: AccountFloatingPanelController?
    /// token-monitor 风格悬浮窗。此前视图已编译进 App 但无人创建，这里负责真正挂到桌面浮层。
    private let floatingBubbleController = TokenMonitorFloatingBubbleController()
    private var floatingBubbleEditorWindow: NSWindow?
    private var floatingBubbleEnabled = false
    private var floatingBubbleShuttingDown = false
    private weak var taskOverviewMenuItem: NSMenuItem?
    private var titlebarToolbarController: NSTitlebarAccessoryViewController?
    private let screenshotRequests = PassthroughSubject<NSWindow, Never>()
    private let guideRequests = PassthroughSubject<Void, Never>()
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var statusPopoverEventMonitors: [Any] = []
    private var statusItemAppearanceObservation: NSKeyValueObservation?
    private var activeSpaceObserver: NSObjectProtocol?
    private var globalHotKeyRef: EventHotKeyRef?
    private var globalHotKeyHandler: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()
    private var statisticsSourceManifest: [TokenMonitorSource]?
    private var statisticsIncludesCodex: Bool?
    private let statusItemPresentationBuilder = StatusItemPresentationBuilder()
    private let statusItemRenderer = StatusItemRenderer()
    private var lastRenderedStatusItemPresentation: StatusItemPresentation?
    private var lastRenderedStatusItemAppearanceName: NSAppearance.Name?
    private var lastRenderedStatusItemPaletteIdentity: PaletteRenderIdentity?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings.themeMode.applyAppearance()
        setupMainMenu()
        debugLog("app launched")

        createMainWindow()
        // 自动重置：启动时立刻拉取最新重置公告，latest 是 @Published，变化会触发主页重渲染
        // （CoA 传 store.publicResetAnnouncements.latest 到 ResetUpdatesBanner 即可）
        store.refreshResetAnnouncements()
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTaskBoardPollingActivity()
            }
        }
        setupStatusItemIfNeeded()
        observeStatusItemUsage()
        observeSettings()
        settings.globalShortcutRegistration = { [weak self] shortcut in
            self?.replaceGlobalHotKey(with: shortcut) ?? .failure(.failed)
        }
        settings.globalShortcutUnregistration = { [weak self] in
            self?.unregisterGlobalHotKeyReference() ?? .failure(.failed)
        }
        if let shortcut = settings.globalShortcut,
            !registerGlobalHotKey(shortcut)
        {
            let defaultRegistered =
                shortcut == .default
                ? false
                : registerGlobalHotKey(.default)
            settings.handleInitialGlobalShortcutFailure(defaultRegistered: defaultRegistered)
        } else if settings.globalShortcut == nil {
            _ = installGlobalHotKeyHandler()
        }
        if let argumentIndex = CommandLine.arguments.firstIndex(of: "--switch-profile-id"),
            CommandLine.arguments.indices.contains(argumentIndex + 1)
        {
            store.stageLaunchProfileID(CommandLine.arguments[argumentIndex + 1])
        }
        store.updateVisibleRuntimeScopes(settings.visibleRuntimeScopes)
        setupStatisticsSources()
        store.start()
        setupFloatingBubbleSync()
        showMainWindow()
        PerformanceMonitor.shared.end(startupPerformanceSpan)
    }

    private func createMainWindow() {
        let width = CodexAccountManagerView.defaultWidth
        let height = CodexAccountManagerView.defaultHeight
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(
            x: max(screenFrame.minX + 16, screenFrame.maxX - width - 28),
            y: max(screenFrame.minY + 16, screenFrame.maxY - height - 36)
        )

        let mainWindow = MainAppWindow(contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)))
        mainWindow.delegate = self
        mainWindow.minSize = CGSize(width: CodexAccountManagerView.minWidth, height: CodexAccountManagerView.minHeight)
        mainWindow.maxSize = CGSize(width: CodexAccountManagerView.maxWidth, height: .greatestFiniteMagnitude)
        mainWindow.contentMinSize = mainWindow.minSize
        mainWindow.contentMaxSize = mainWindow.maxSize
        mainWindow.contentView = GlassHostingContainer(
            rootView: CodexAccountManagerView(
                store: store,
                settings: settings,
                paletteCatalog: paletteCatalog,
                screenshotRequests: screenshotRequests.eraseToAnyPublisher(),
                guideRequests: guideRequests.eraseToAnyPublisher(),
                localCLIAccounts: localCLIAccounts
            ),
            cornerRadius: CodexAccountManagerView.windowCornerRadius
        )
        installTitlebarToolbar(on: mainWindow)
        _ = mainWindow.setFrameAutosaveName("CodexAccountManagerNext.mainWindow")
        window = mainWindow
        applyMainWindowLevel()
    }

    private func setupStatisticsSources() {
        syncStatisticsSources()
        // Account snapshots change frequently; only metadata/selection changes restart statistics.
        localCLIAccounts.$profiles
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncStatisticsSources() }
            .store(in: &cancellables)
        store.$profiles
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncStatisticsSources() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: StatisticsSources.selectionChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncStatisticsSources() }
            .store(in: &cancellables)
    }

    private func syncStatisticsSources() {
        do {
            let catalog = try StatisticsClientCatalog.load()
            let enabled = catalog.enabledIDs()
            let sources = try StatisticsSources.make(
                catalog: catalog, enabledIDs: enabled,
                userHome: FileManager.default.homeDirectoryForCurrentUser,
                systemCodexHome: store.profiles.first(where: \.isSystemProfile)?.codexHomeURL,
                localProfiles: localCLIAccounts.profiles
            )
            let includeCodex = enabled.contains("codex")
            guard sources != statisticsSourceManifest || includeCodex != statisticsIncludesCodex else { return }
            try store.configureStatisticsSources(sources, includeManagedCodex: includeCodex)
            statisticsSourceManifest = sources
            statisticsIncludesCodex = includeCodex
        } catch {
            // The engine reports missing/invalid packaged resources in its existing error state.
            debugLog("statistics source catalog unavailable")
        }
    }

    private func setupFloatingBubbleSync() {
        TokenMonitorFloatingBubbleSession.owner = self
        floatingBubbleController.onOpenEditor = { [weak self] in
            self?.openFloatingBubbleEditor()
        }
        syncFloatingBubble()
        // These publishers emit before mutation. Deliver on the next main-loop
        // turn and read current state, including when several changes coalesce.
        settings.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncFloatingBubble() }
            .store(in: &cancellables)
        settings.$floatingBubble
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncFloatingBubble() }
            .store(in: &cancellables)
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncFloatingBubble() }
            .store(in: &cancellables)
        localCLIAccounts.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncFloatingBubble() }
            .store(in: &cancellables)
    }

    private func syncFloatingBubble(reveal: Bool = false) {
        guard !floatingBubbleShuttingDown else { return }
        let prefs = settings.floatingBubble
        let bubble = floatingBubbleController
        bubble.language = settings.language
        bubble.preferences = prefs
        bubble.snapshot = TokenMonitorFloatingBubbleProjection.resolve(
            preferences: prefs,
            sources: FloatingBubbleEvidence.make(store: store, localAccounts: localCLIAccounts, language: settings.language)
        )
        if prefs.enabled {
            if reveal || !floatingBubbleEnabled { bubble.show() } else { bubble.refreshContent() }
        } else {
            bubble.close()
            closeFloatingBubbleEditor()
        }
        floatingBubbleEnabled = prefs.enabled
    }

    func showFloatingBubble(settings callerSettings: AppSettings, language: WidgetLanguage) {
        guard !floatingBubbleShuttingDown, callerSettings === settings else { return }
        if !settings.floatingBubble.enabled { settings.floatingBubble.enabled = true }
        syncFloatingBubble(reveal: true)
    }

    private func openFloatingBubbleEditor() {
        guard !floatingBubbleShuttingDown, settings.floatingBubble.enabled else { return }
        if let floatingBubbleEditorWindow {
            if floatingBubbleEditorWindow.isMiniaturized {
                floatingBubbleEditorWindow.deminiaturize(nil)
            }
            floatingBubbleEditorWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let editor = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        editor.isReleasedWhenClosed = false
        editor.delegate = self
        editor.title = settings.language.text("自定义悬浮窗", "Customize floating bubble")
        editor.contentView = NSHostingView(
            rootView: LiveFloatingBubbleEditor(
                settings: settings,
                store: store,
                localAccounts: localCLIAccounts,
                onShowDesktop: { [weak self] in
                    guard let self else { return }
                    self.showFloatingBubble(settings: self.settings, language: self.settings.language)
                    self.closeFloatingBubbleEditor()
                },
                onCancel: { [weak self] in self?.closeFloatingBubbleEditor() },
                onDone: { [weak self] in self?.closeFloatingBubbleEditor() }
            ))
        floatingBubbleEditorWindow = editor
        editor.center()
        editor.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeFloatingBubbleEditor() {
        let editor = floatingBubbleEditorWindow
        floatingBubbleEditorWindow = nil
        editor?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let editor = notification.object as? NSWindow, editor === floatingBubbleEditorWindow {
            floatingBubbleEditorWindow = nil
        }
    }

    private func installTitlebarToolbar(on window: NSWindow) {
        let toolbarView = NSHostingView(
            rootView: TitlebarToolbarView(
                settings: settings,
                onOpenSettings: { [weak self] in
                    self?.openSettingsWindow()
                },
                onSaveScreenshot: { [weak self] in
                    guard let self, let window = self.window else { return }
                    self.screenshotRequests.send(window)
                },
                onOpenGuide: { [weak self] in
                    self?.guideRequests.send(())
                }
            )
        )
        toolbarView.frame = NSRect(x: 0, y: 0, width: 136, height: 44)

        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = .right
        controller.view = toolbarView
        window.addTitlebarAccessoryViewController(controller)
        titlebarToolbarController = controller
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store.isLaunchingCodex { return .terminateCancel }
        if store.isLoggingIn {
            Task { @MainActor in
                await store.finishLoginForTermination()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        floatingBubbleShuttingDown = true
        if TokenMonitorFloatingBubbleSession.owner === self {
            TokenMonitorFloatingBubbleSession.owner = nil
        }
        closeFloatingBubbleEditor()
        floatingBubbleController.shutdown()
        taskOverviewController?.shutdown()
        taskOverviewController = nil
        accountFloatingPanelController?.shutdown()
        accountFloatingPanelController = nil
        closeStatusPopover()
        statusItemAppearanceObservation = nil
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
        unregisterGlobalHotKey()
        store.stop()
    }

    func toggleMainWindow() {
        guard let window else { return }

        if window.isVisible, !window.isMiniaturized, window.isKeyWindow {
            window.orderOut(nil)
            updateTaskBoardPollingActivity()
            return
        }

        showMainWindow()
    }

    func applicationDidResignActive(_ notification: Notification) {
        updateTaskBoardPollingActivity()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateTaskBoardPollingActivity()
    }

    func applicationDidHide(_ notification: Notification) {
        updateTaskBoardPollingActivity()
    }

    func applicationDidUnhide(_ notification: Notification) {
        updateTaskBoardPollingActivity()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            if settings.keepRunningWhenMainWindowClosed {
                hideMainWindowAfterClose()
            } else {
                NSApp.terminate(nil)
            }
            return false
        }
        return true
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateTaskBoardPollingActivity()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateTaskBoardPollingActivity()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateTaskBoardPollingActivity()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateTaskBoardPollingActivity()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateTaskBoardPollingActivity()
    }

    // P0 fullscreen black edges: the main window is normally a transparent,
    // 28pt-rounded panel capped at maxWidth = 1280. Native fullscreen fills the
    // screen, so those traits must be suspended on entry — otherwise the
    // rounded corners and the region beyond maxSize reveal the fullscreen
    // space's black backdrop (user-visible as large black edges).
    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        let fallbackScheme: ColorScheme =
            window.effectiveAppearance.name.rawValue.contains("Dark") ? .dark : .light
        let effectiveScheme = settings.themeMode.preferredColorScheme ?? fallbackScheme
        window.isOpaque = true
        window.backgroundColor = Self.fullscreenBackground(for: effectiveScheme)
        window.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.contentMaxSize = window.maxSize
        (window.contentView as? FullscreenRoundedContent)?.updateCornerRadius(0)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.maxSize = CGSize(width: CodexAccountManagerView.maxWidth, height: .greatestFiniteMagnitude)
        window.contentMaxSize = window.maxSize
        (window.contentView as? FullscreenRoundedContent)?.updateCornerRadius(CodexAccountManagerView.windowCornerRadius)
    }

    /// Opaque counterparts of FixedVisualPalette.windowScrim, so the
    /// behind-window material never reveals the black fullscreen space.
    private static func fullscreenBackground(for scheme: ColorScheme) -> NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.075, green: 0.080, blue: 0.100, alpha: 1)
            : NSColor(calibratedRed: 0.955, green: 0.960, blue: 0.975, alpha: 1)
    }

    private func showMainWindow() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        setupStatusItemIfNeeded()
        closeStatusPopover()
        paletteLibraryWindow?.orderOut(nil)
        applyMainWindowLevel()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateTaskBoardPollingActivity()
    }

    private func hideMainWindowAfterClose() {
        closeStatusPopover()
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        updateTaskBoardPollingActivity()
    }

    private func applyMainWindowLevel() {
        window?.level = settings.keepMainWindowOnTop ? .floating : .normal
    }

    @objc private func openSettingsFromMenu() {
        openSettingsWindow()
    }

    @objc private func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func toggleTaskOverviewFromMenu() {
        if taskOverviewController == nil {
            taskOverviewController = TaskOverviewPanelController(
                store: store,
                settings: settings,
                openTask: { [weak self] scope, threadID in
                    guard let self else { return }
                    self.store.requestTaskFocus(scope: scope, threadID: threadID)
                    self.showMainWindow()
                },
                openWorkspace: { [weak self] in
                    guard let self else { return }
                    self.store.setTaskBoardSelected(true)
                    self.showMainWindow()
                },
                visibilityDidChange: { [weak self] isVisible in
                    guard let self else { return }
                    self.taskOverviewMenuItem?.state = isVisible ? .on : .off
                    self.updateTaskBoardPollingActivity()
                }
            )
        }
        taskOverviewController?.toggle()
    }

    private func setupMainMenu() {
        let language = settings.language
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "AiGoodBro")
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            NSMenuItem(
                title: language.text("关于 AiGoodBro", "About AiGoodBro"),
                action: #selector(showAboutPanel),
                keyEquivalent: ""
            ))
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: language.text("设置…", "Settings..."),
                action: #selector(openSettingsFromMenu),
                keyEquivalent: ","
            ))
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: language.text("隐藏 AiGoodBro", "Hide AiGoodBro"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: language.text("隐藏其他", "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: language.text("全部显示", "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: language.text("退出 AiGoodBro", "Quit AiGoodBro"),
                action: #selector(quitFromMenu),
                keyEquivalent: "q"
            ))

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: language.text("编辑", "Edit"))
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: language.text("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: language.text("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: language.text("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: language.text("复制", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: language.text("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: language.text("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: language.text("显示", "View"))
        viewMenuItem.submenu = viewMenu
        let fullScreenItem = NSMenuItem(
            title: language.text("进入全屏", "Enter Full Screen"),
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: language.text("窗口", "Window"))
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(
            NSMenuItem(
                title: language.text("关闭窗口", "Close Window"),
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            ))
        windowMenu.addItem(.separator())
        let minimizeItem = NSMenuItem(
            title: language.text("最小化", "Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(minimizeItem)
        let bringAllItem = NSMenuItem(
            title: language.text("全部前置", "Bring All to Front"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        bringAllItem.target = NSApp
        windowMenu.addItem(bringAllItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func openSettingsWindow() {
        closeStatusPopover()
        if settingsWindow == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 740, height: 520)
            panel.contentViewController = NSHostingController(
                rootView: SettingsWindowContent(
                    settings: settings, store: store, updateStore: updateStore, localAccounts: localCLIAccounts,
                    onOpenPaletteLibrary: { [weak self] in self?.openPaletteLibraryWindow() }
                ))
            panel.center()
            settingsWindow = panel
        }
        guard let panel = settingsWindow else { return }
        panel.title = settings.language.text("AiGoodBro 设置", "AiGoodBro Settings")
        NSApp.setActivationPolicy(.regular)
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openPaletteLibraryWindow() {
        closeStatusPopover()
        window?.orderOut(nil)
        if paletteLibraryWindow == nil {
            let paletteLibraryWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 320),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            paletteLibraryWindow.title = settings.language.text("配色库", "Palette Library")
            paletteLibraryWindow.titleVisibility = .hidden
            paletteLibraryWindow.titlebarAppearsTransparent = true
            paletteLibraryWindow.isReleasedWhenClosed = false
            paletteLibraryWindow.isOpaque = false
            paletteLibraryWindow.backgroundColor = .clear
            paletteLibraryWindow.hasShadow = true
            paletteLibraryWindow.isMovableByWindowBackground = true
            paletteLibraryWindow.acceptsMouseMovedEvents = true
            paletteLibraryWindow.delegate = self
            paletteLibraryWindow.contentMinSize = NSSize(width: 660, height: 320)
            paletteLibraryWindow.contentView = GlassHostingContainer(
                rootView: PaletteLibraryView(settings: settings),
                cornerRadius: 20
            )
            paletteLibraryWindow.center()
            self.paletteLibraryWindow = paletteLibraryWindow
        }

        guard let paletteLibraryWindow else { return }
        NSApp.setActivationPolicy(.regular)
        paletteLibraryWindow.title = settings.language.text("配色库", "Palette Library")
        if paletteLibraryWindow.isMiniaturized {
            paletteLibraryWindow.deminiaturize(nil)
        }
        paletteLibraryWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observeSettings() {
        settings.$keepMainWindowOnTop
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyMainWindowLevel()
            }
            .store(in: &cancellables)

        settings.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] language in
                self?.paletteLibraryWindow?.title = language.text("配色库", "Palette Library")
                self?.settingsWindow?.title = language.text("AiGoodBro 设置", "AiGoodBro Settings")
                self?.setupMainMenu()
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        settings.$themeMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        settings.$paletteID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lastRenderedStatusItemPaletteIdentity = nil
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        settings.$visibleRuntimeScopes
            .receive(on: RunLoop.main)
            .sink { [weak self] scopes in
                guard let self else { return }
                self.store.updateVisibleRuntimeScopes(scopes)
                self.updateStatusItem()
            }
            .store(in: &cancellables)

        settings.$statusItemPreferences
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        settings.$globalShortcut
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

    }

    @objc private func statusItemClicked() {
        toggleStatusPopover()
    }

    private func toggleStatusPopover() {
        if statusPopover?.isShown == true {
            closeStatusPopover()
            return
        }

        showStatusPopover(initialScreen: .home)
    }

    private func showStatusPopover(initialScreen: CodexAccountMenuView.Screen) {
        guard let button = statusItem?.button else { return }
        window?.orderOut(nil)
        paletteLibraryWindow?.orderOut(nil)
        let requiresActivationPolicyTransition = NSApp.activationPolicy() != .accessory
        NSApp.setActivationPolicy(.accessory)
        if requiresActivationPolicyTransition {
            DispatchQueue.main.async { [weak self] in
                self?.showStatusPopover(initialScreen: initialScreen)
            }
            return
        }
        store.refreshIfStale(maximumAge: 5 * 60)
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = CodexAccountMenuView.preferredSize
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: CodexAccountMenuView(
                store: store,
                settings: settings,
                updateStore: updateStore,
                paletteCatalog: paletteCatalog,
                initialScreen: initialScreen,
                localCLIAccounts: localCLIAccounts,
                openFullWindow: { [weak self] in
                    self?.openMainWindow(selecting: nil)
                },
                openPaletteLibrary: { [weak self] in
                    self?.openPaletteLibraryWindow()
                },
                quit: {
                    NSApp.terminate(nil)
                },
                onOpenFloatingPanel: { [weak self] initialScreen in
                    self?.openFloatingAccountPanel(initialScreen: initialScreen)
                }
            )
        )
        statusPopover = popover
        store.setStatusPopoverVisible(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        updateTaskBoardPollingActivity()
        configureStatusPopoverWindow()
        DispatchQueue.main.async { [weak self] in
            self?.configureStatusPopoverWindow()
        }
        installStatusPopoverEventMonitors()
    }

    private func configureStatusPopoverWindow() {
        guard let window = statusPopover?.contentViewController?.view.window else { return }
        window.level = .statusBar
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
    }

    private func openMainWindow(selecting scope: RuntimeScope?) {
        accountFloatingPanelController?.close()
        if let scope {
            store.selectRuntime(scope)
        }
        showMainWindow()
    }

    private func openFloatingAccountPanel(initialScreen: CodexAccountMenuView.Screen? = nil) {
        closeStatusPopover()
        window?.orderOut(nil)
        if accountFloatingPanelController == nil {
            accountFloatingPanelController = AccountFloatingPanelController(
                store: store,
                settings: settings,
                updateStore: updateStore,
                paletteCatalog: paletteCatalog,
                localCLIAccounts: localCLIAccounts,
                openFullWindow: { [weak self] in
                    self?.openMainWindow(selecting: nil)
                },
                openPaletteLibrary: { [weak self] in
                    guard let self else { return }
                    self.accountFloatingPanelController?.close()
                    self.openPaletteLibraryWindow()
                },
                quit: {
                    NSApp.terminate(nil)
                },
                visibilityDidChange: { [weak self] _ in
                    self?.updateTaskBoardPollingActivity()
                }
            )
        }
        accountFloatingPanelController?.show(initialScreen: initialScreen)
    }

    private var currentPopoverAttention: TaskAttentionItem? {
        store.highestPriorityAttention(
            for: settings.visibleRuntimeScopes,
            updateResult: updateStore.result
        )
    }

    private func openAttentionItem(_ item: TaskAttentionItem) {
        if item.kind == .update {
            updateStore.openPreferredUpdateURL()
            return
        }
        let scope = item.runtimeScope ?? store.selectedRuntimeScope
        if item.threadID != nil {
            store.requestTaskFocus(scope: scope, threadID: item.threadID)
        } else {
            store.selectRuntime(scope)
        }
        showMainWindow()
    }

    private func updateStatusPopoverSize() {
        guard statusPopover?.isShown == true else { return }
        statusPopover?.contentSize = CodexAccountMenuView.preferredSize
    }

    func popoverDidClose(_ notification: Notification) {
        statusPopover = nil
        removeStatusPopoverEventMonitors()
        updateTaskBoardPollingActivity()
        store.setStatusPopoverVisible(false)
    }

    private func closeStatusPopover() {
        statusPopover?.performClose(nil)
        statusPopover = nil
        removeStatusPopoverEventMonitors()
        updateTaskBoardPollingActivity()
        store.setStatusPopoverVisible(false)
    }

    private func updateTaskBoardPollingActivity() {
        store.setTaskOverviewVisible(
            taskOverviewController?.isVisible == true
                || accountFloatingPanelController?.isVisible == true
                || statusPopover?.isShown == true
        )
        guard let window else {
            store.setMainWindowActive(false)
            return
        }
        let mainWindowActive =
            window.isVisible
            && !window.isMiniaturized
            && window.isKeyWindow
            && window.isOnActiveSpace
            && window.occlusionState.contains(.visible)
            && NSApp.isActive
            && !NSApp.isHidden
        store.setMainWindowActive(mainWindowActive)
    }

    private func installStatusPopoverEventMonitors() {
        removeStatusPopoverEventMonitors()
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseEvents.union(.keyDown),
            handler: { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.closeStatusPopover()
                    return nil
                }
                if self.shouldCloseStatusPopover(for: event) {
                    self.closeStatusPopover()
                }
                return event
            })
        {
            statusPopoverEventMonitors.append(localMonitor)
        }

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouseEvents,
            handler: { [weak self] _ in
                DispatchQueue.main.async {
                    self?.closeStatusPopover()
                }
            })
        {
            statusPopoverEventMonitors.append(globalMonitor)
        }
    }

    private func shouldCloseStatusPopover(for event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown else {
            return false
        }
        if let popoverWindow = statusPopover?.contentViewController?.view.window, event.window === popoverWindow {
            return false
        }
        if let statusButtonWindow = statusItem?.button?.window, event.window === statusButtonWindow {
            return false
        }
        return true
    }

    private func removeStatusPopoverEventMonitors() {
        for monitor in statusPopoverEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        statusPopoverEventMonitors.removeAll()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        statusItemAppearanceObservation = button.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }
        updateStatusItem()
        button.target = self
        button.action = #selector(statusItemClicked)
    }

    private func setupStatusItemIfNeeded() {
        guard statusItem == nil else {
            updateStatusItem()
            return
        }
        setupStatusItem()
    }

    private func observeStatusItemUsage() {
        store.$multiRuntimeSnapshot
            .combineLatest(store.$selectedRuntimeScope, store.$isRefreshing)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updateStatusItem()
                self?.updateStatusPopoverSize()
            }
            .store(in: &cancellables)

        store.$runtimeSnapshots
            .combineLatest(updateStore.$result)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusPopoverSize()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let presentation = currentStatusItemPresentation()
        let appearance = button.effectiveAppearance
        let paletteAppearance: PaletteAppearance = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let visualTokens = paletteCatalog.resolve(id: settings.paletteID, appearance: paletteAppearance)

        // Skip redundant redraws. Mutating `button.image`/`length` triggers a
        // status-bar relayout, which re-fires the `effectiveAppearance` KVO
        // observer and calls back into this method. Without this guard the icon
        // repaints in a tight feedback loop, pinning a CPU core.
        if presentation == lastRenderedStatusItemPresentation,
            appearance.name == lastRenderedStatusItemAppearanceName,
            visualTokens.identity == lastRenderedStatusItemPaletteIdentity
        {
            return
        }
        lastRenderedStatusItemPresentation = presentation
        lastRenderedStatusItemAppearanceName = appearance.name
        lastRenderedStatusItemPaletteIdentity = visualTokens.identity

        let performanceSpan = PerformanceMonitor.shared.begin(.statusRender)
        statusItem?.length = presentation.itemLength
        button.image = statusItemRenderer.render(
            presentation,
            tokens: visualTokens,
            appearance: appearance
        )
        button.toolTip = presentation.tooltip
        button.setAccessibilityLabel("AiGoodBro")
        button.setAccessibilityValue(presentation.accessibilityValue)
        PerformanceMonitor.shared.end(performanceSpan)
    }

    private func selectedRuntimeSummary() -> RuntimeMenuSummary? {
        store.runtimeSnapshot(for: store.selectedRuntimeScope)?.summary
    }

    private func currentStatusItemPresentation() -> StatusItemPresentation {
        let source =
            selectedRuntimeSummary().map(StatusItemSourceSnapshot.init(summary:))
            ?? StatusItemSourceSnapshot.unavailable(runtime: store.selectedRuntimeScope)
        return statusItemPresentationBuilder.build(
            source: source,
            preferences: settings.statusItemPreferences,
            language: settings.language,
            shortcutName: settings.globalShortcut?.displayName
        )
    }

    @discardableResult
    private func registerGlobalHotKey(_ shortcut: GlobalShortcut) -> Bool {
        debugLog("register global hotkey \(shortcut.displayName)")
        guard installGlobalHotKeyHandler() else { return false }
        let status = registerHotKeyReference(shortcut, id: 1, reference: &globalHotKeyRef)
        if status == noErr {
            debugLog("global hotkey registered")
        } else {
            debugLog("RegisterEventHotKey failed status=\(status)")
        }
        return status == noErr
    }

    @discardableResult
    private func installGlobalHotKeyHandler() -> Bool {
        guard globalHotKeyHandler == nil else { return true }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.toggleMainWindow()
                }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &globalHotKeyHandler
        )
        guard handlerStatus == noErr else {
            debugLog("InstallEventHandler failed status=\(handlerStatus)")
            return false
        }

        return true
    }

    private func replaceGlobalHotKey(
        with shortcut: GlobalShortcut
    ) -> Result<Void, GlobalShortcutRegistrationFailure> {
        guard installGlobalHotKeyHandler() else { return .failure(.failed) }
        let replacement: Result<EventHotKeyRef, GlobalShortcutRegistrationFailure> =
            GlobalShortcutRegistrationTransaction.replace(
                current: globalHotKeyRef,
                registerCandidate: {
                    var candidateRef: EventHotKeyRef?
                    let status = registerHotKeyReference(
                        shortcut,
                        id: 2,
                        reference: &candidateRef
                    )
                    guard status == noErr, let candidateRef else {
                        debugLog("replacement hotkey registration failed status=\(status)")
                        return .failure(status == eventHotKeyExistsErr ? .occupied : .failed)
                    }
                    return .success(candidateRef)
                },
                unregister: { reference in
                    let status = UnregisterEventHotKey(reference)
                    guard status == noErr else {
                        debugLog("old hotkey unregistration failed status=\(status)")
                        return .failure(.failed)
                    }
                    return .success(())
                },
                rollbackCandidate: { reference in
                    let status = UnregisterEventHotKey(reference)
                    if status != noErr {
                        debugLog("candidate hotkey rollback failed status=\(status)")
                    }
                }
            )
        switch replacement {
        case .failure(let error):
            return .failure(error)
        case .success(let candidateRef):
            globalHotKeyRef = candidateRef
            debugLog("global hotkey replaced with \(shortcut.displayName)")
            return .success(())
        }
    }

    private func registerHotKeyReference(
        _ shortcut: GlobalShortcut,
        id: UInt32,
        reference: inout EventHotKeyRef?
    ) -> OSStatus {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("CAMN"), id: id)
        // Carbon can report conflicts only when the existing registration is
        // also exclusive. macOS does not expose other apps' nonexclusive
        // registrations for preflight inspection.
        return RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &reference
        )
    }

    private func unregisterGlobalHotKey() {
        _ = unregisterGlobalHotKeyReference()
        if let globalHotKeyHandler {
            RemoveEventHandler(globalHotKeyHandler)
        }
        globalHotKeyHandler = nil
    }

    private func unregisterGlobalHotKeyReference() -> Result<Void, GlobalShortcutRegistrationFailure> {
        guard let reference = globalHotKeyRef else { return .success(()) }
        let status = UnregisterEventHotKey(reference)
        guard status == noErr else {
            debugLog("global hotkey unregistration failed status=\(status)")
            return .failure(.failed)
        }
        globalHotKeyRef = nil
        return .success(())
    }
}
