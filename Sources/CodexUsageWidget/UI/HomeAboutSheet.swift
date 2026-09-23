import SwiftUI

/// Reuse the complete About page, including contact details and every attribution.
struct HomeAboutSheet: View {
    @ObservedObject var settings: AppSettings
    let store: UsageStore
    @StateObject private var updateStore: AppUpdateStore
    @State private var showsPalettes = false
    @Environment(\.dismiss) private var dismiss

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _updateStore = StateObject(wrappedValue: AppUpdateStore(settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(settings.language.text("关于 AiGoodBro · 致谢", "About AiGoodBro · Credits"))
                    .font(.headline)
                Spacer()
                Button(settings.language.text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            SettingsPanelView(
                settings: settings, store: store, updateStore: updateStore,
                onOpenPaletteLibrary: { showsPalettes = true }, initialPage: .about)
        }
        .frame(width: 820, height: 640)
        .preferredColorScheme(settings.themeMode.preferredColorScheme)
        .sheet(isPresented: $showsPalettes) {
            PaletteLibraryView(settings: settings).frame(width: 760, height: 560)
        }
    }
}
