import AppKit
import SwiftUI

/// Filled, outlined controls stay legible over both dark and light glass.
struct WorkspaceActionButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = prominent && isEnabled
        let background =
            highlighted
            ? Color(red: 0.02, green: 0.36, blue: 0.78)
            : Color(nsColor: colorScheme == .dark ? .darkGray : .controlBackgroundColor)
        configuration.label
            .font(.system(size: compact ? 10 : 12, weight: .semibold))
            .foregroundStyle(highlighted ? Color.white : Color.primary.opacity(isEnabled ? 1 : 0.62))
            .padding(.horizontal, compact ? 5 : 12)
            .padding(.vertical, compact ? 3 : 6)
            .background(background.opacity(configuration.isPressed && isEnabled ? 0.72 : isEnabled ? 0.96 : 0.5), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.primary.opacity(isEnabled ? 0.28 : 0.12), lineWidth: 1)
            }
            .contentShape(Rectangle())
    }
}

struct WorkspaceCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            configuration.isOn
                                ? (isEnabled ? Color(red: 0.02, green: 0.36, blue: 0.78) : Color.secondary)
                                : Color.primary.opacity(0.07))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(configuration.isOn ? 0.15 : 0.5), lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                configuration.label.foregroundStyle(Color.primary.opacity(isEnabled ? 1 : 0.68))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

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
