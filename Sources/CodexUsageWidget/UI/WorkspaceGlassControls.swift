import SwiftUI

struct WorkspaceGlassControls: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var language: WidgetLanguage { settings.language }

    var body: some View {
        VStack(spacing: 6) {
            SettingsPickerRow(title: language.text("玻璃背景", "Glass backdrop"), detail: "") {
                SettingsSegmentedControl(
                    selection: $settings.workspaceGlass.systemGlass,
                    options: [
                        SettingsSegmentOption(value: true, title: language.text("系统", "System")),
                        SettingsSegmentOption(value: false, title: language.text("透明", "Transparent")),
                    ], width: 224
                )
                .accessibilityIdentifier("appearance.glass.backdrop")
            }
            sliderRow(title: language.text("玻璃浓度", "Glass"), value: $settings.workspaceGlass.opacity, defaultValue: 68, id: "opacity")
            sliderRow(title: language.text("层次", "Depth"), value: $settings.workspaceGlass.depth, defaultValue: 32, id: "depth")
            if reduceTransparency || contrast == .increased {
                Text(language.text("系统辅助功能正在使用不透明背景，设置仍会保留。", "System accessibility uses an opaque background. Your settings are retained."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sliderRow(title: String, value: Binding<Int>, defaultValue: Int, id: String) -> some View {
        SettingsPickerRow(
            title: title,
            detail: id == "depth"
                ? language.text("边框与控件的层次感", "Border and control contrast") : ""
        ) {
            HStack(spacing: 8) {
                Button {
                    value.wrappedValue = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 26)
                }
                .buttonStyle(WorkspaceQuietButtonStyle())
                .help(language.text("恢复默认 \(defaultValue)", "Reset to \(defaultValue)"))
                .accessibilityLabel(language.text("重置\(title)", "Reset \(title)"))
                .accessibilityIdentifier("appearance.glass." + id + ".reset")
                Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }), in: 0...100)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("appearance.glass." + id)
                Text("\(value.wrappedValue)").font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 25, alignment: .trailing)
            }
            .frame(width: 224)
        }
    }
}
