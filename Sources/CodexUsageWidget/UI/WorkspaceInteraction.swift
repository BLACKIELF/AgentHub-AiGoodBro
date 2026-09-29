import AppKit
import SwiftUI

/// Feedback is local to the control. Never animate the window or chart layout.
enum WorkspaceMotion {
    static var isPointerEvent: Bool {
        guard let type = NSApp?.currentEvent?.type else { return false }
        return [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved, .mouseEntered, .mouseExited].contains(type)
    }

    static func feedback(reduceMotion: Bool, duration: Double = 0.14) -> Animation? {
        reduceMotion || !isPointerEvent ? nil : .easeOut(duration: duration)
    }
}

struct WorkspaceQuietButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var restingFill: Double = 0
    var scalesOnPress = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(
                Color.primary.opacity(isEnabled && configuration.isPressed ? 0.13 : isEnabled && hovering ? 0.07 : restingFill),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .scaleEffect(scalesOnPress && !reduceMotion && WorkspaceMotion.isPointerEvent && configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(WorkspaceMotion.feedback(reduceMotion: reduceMotion), value: hovering)
            .animation(WorkspaceMotion.feedback(reduceMotion: reduceMotion, duration: 0.10), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// Toolbars retain readable controls when the workspace is narrowed.
struct AccountToolbar<Title: View, Actions: View>: View {
    @ViewBuilder var title: () -> Title
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                title().fixedSize()
                Spacer(minLength: 12)
                actions().fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                title()
                HStack(spacing: 8) {
                    actions()
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
    }
}
