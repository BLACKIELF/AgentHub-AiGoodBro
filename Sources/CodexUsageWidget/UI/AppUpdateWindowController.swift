import AppKit
import SwiftUI

@MainActor
final class AppUpdateWindowController: NSObject, NSWindowDelegate {
    static let shared = AppUpdateWindowController()
    private var window: NSWindow?

    func show(store: AppUpdateStore, settings: AppSettings) {
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 550, height: 500)
            window.delegate = self
            window.center()
            self.window = window
        }
        window.title = settings.language.text("AiGoodBro 更新", "AiGoodBro Update")
        window.contentView = NSHostingView(
            rootView: AppUpdateDetailView(
                store: store, settings: settings, downloader: .shared,
                onClose: { [weak self] in self?.window?.orderOut(nil) }
            ))
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
