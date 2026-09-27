import SwiftUI

/// One approved brand shared by the workspace, Dock, menu bar and companion.
struct AppIconStylePicker: View {
    @Binding var selection: AppIconStyle
    var language: WidgetLanguage

    var body: some View {
        HStack(spacing: 12) {
            AHBrandSymbol(size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("AiGoodBro")
                    .font(.system(size: WorkspaceVisualMetrics.metaSize, weight: .semibold))
                Text(language.text("统一应用图标", "App icon used throughout AiGoodBro"))
                    .font(.system(size: WorkspaceVisualMetrics.metaSize))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
