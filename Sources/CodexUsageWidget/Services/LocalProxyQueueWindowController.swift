import Cocoa
import SwiftUI

@MainActor
final class LocalProxyQueueWindowController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = LocalProxyQueueWindowController()
    static let initialContentSize = NSSize(width: 830, height: 660)
    static let minimumContentSize = NSSize(width: 680, height: 440)

    private var window: NSWindow?
    private weak var model: LocalProxyQueueStore?
    @Published private(set) var contentID = UUID()

    func show(
        model: LocalProxyQueueStore,
        settings: AppSettings,
        paletteCatalog: PaletteCatalog
    ) {
        model.flushDisplayRows()
        if let window {
            window.title = settings.language.text("反代模式", "Local proxy")
            bringToFront(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = settings.language.text("反代模式", "Local proxy")
        // Let the glass surface own the whole frame. The default titlebar
        // separator otherwise leaves a dark horizontal seam between the
        // traffic lights and the proxy content.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.contentMinSize = Self.minimumContentSize
        window.delegate = self
        self.model = model
        window.contentView = GlassHostingContainer(
            rootView: LocalProxyQueueWindowContent(
                model: model,
                settings: settings,
                paletteCatalog: paletteCatalog,
                controller: self,
                onClose: { [weak self] in self?.hide() }
            ), cornerRadius: 14, allowsWindowDragging: false, settings: settings
        )
        window.center()
        self.window = window
        bringToFront(window)
    }

    private func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hide() {
        // orderOut keeps the hosting view alive; it does not run onDisappear.
        model?.cancelLegacyCooldownRecovery()
        contentID = UUID()
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        hide()
        return false
    }
}

struct LocalProxyQueueWindowContent: View {
    @ObservedObject var model: LocalProxyQueueStore
    @ObservedObject var settings: AppSettings
    let paletteCatalog: PaletteCatalog
    @ObservedObject var controller: LocalProxyQueueWindowController
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var effectiveColorScheme: ColorScheme {
        settings.themeMode.preferredColorScheme ?? colorScheme
    }

    private var visualTokens: ResolvedVisualTokens {
        paletteCatalog.resolve(
            id: settings.paletteID,
            appearance: effectiveColorScheme == .dark ? .dark : .light
        )
    }

    var body: some View {
        let contentID = controller.contentID
        LocalProxyQueueView(
            model: model, language: settings.language, onClose: onClose,
            isCurrentPresentation: { controller.contentID == contentID }
        )
        .id(contentID)
        .environment(\.visualTokens, visualTokens)
        .environment(\.workspaceGlass, settings.workspaceGlass)
        .environment(\.widgetLanguage, settings.language)
        .environment(\.locale, settings.language.locale)
        .tint(visualTokens.accent.primary.color)
        .preferredColorScheme(settings.themeMode.preferredColorScheme)
    }
}
