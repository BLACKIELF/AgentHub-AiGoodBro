import SwiftUI

/// The full label row is one native button, including its arrow and whitespace.
struct FullRowDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.widgetLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .animation(WorkspaceMotion.feedback(reduceMotion: reduceMotion), value: configuration.isExpanded)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(WorkspaceQuietButtonStyle(scalesOnPress: false))
            .accessibilityValue(configuration.isExpanded ? language.text("已展开", "Expanded") : language.text("已收起", "Collapsed"))
            if configuration.isExpanded {
                configuration.content.padding(.leading, 18)
            }
        }
    }
}
