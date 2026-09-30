import Cocoa
import SwiftUI

@MainActor
final class LocalProxyQueueWindowController: NSObject, NSWindowDelegate {
    static let shared = LocalProxyQueueWindowController()
    static let initialContentSize = NSSize(width: 830, height: 660)
    static let minimumContentSize = NSSize(width: 680, height: 500)

    private var window: NSWindow?

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = settings.language.text("反代模式", "Local proxy")
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumContentSize
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: LocalProxyQueueWindowContent(
                model: model,
                settings: settings,
                paletteCatalog: paletteCatalog,
                onClose: { [weak self] in self?.hide() }
            )
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
        LocalProxyQueueView(model: model, language: settings.language, onClose: onClose)
            .environment(\.visualTokens, visualTokens)
            .environment(\.workspaceGlass, settings.workspaceGlass)
            .environment(\.widgetLanguage, settings.language)
            .environment(\.locale, settings.language.locale)
            .tint(visualTokens.accent.primary.color)
            .preferredColorScheme(settings.themeMode.preferredColorScheme)
    }
}
