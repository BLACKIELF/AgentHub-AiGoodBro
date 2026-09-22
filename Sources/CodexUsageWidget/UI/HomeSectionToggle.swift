import SwiftUI

enum HomeSection: String, CaseIterable {
    case reset, messages, recommendations, accounts, usage, maintenance

    var storageKey: String { "AiGoodBro.home.section.\(rawValue).expanded" }
}

/// Keep disclosure actions separate from refresh, settings and account controls.
struct HomeSectionToggle: View {
    let title: String
    var systemImage: String? = nil
    let language: WidgetLanguage
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
                if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text(isExpanded ? "收起\(title)" : "展开\(title)", isExpanded ? "Collapse \(title)" : "Expand \(title)"))
        .accessibilityValue(language.text(isExpanded ? "已展开" : "已收起", isExpanded ? "Expanded" : "Collapsed"))
    }
}
