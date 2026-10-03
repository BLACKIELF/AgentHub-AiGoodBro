import SwiftUI

struct StatisticsSourceSettings: View {
    let language: WidgetLanguage
    @State private var catalog = try? StatisticsClientCatalog.load()
    @State private var enabledIDs: Set<String> = []

    var body: some View {
        Group {
            if let catalog {
                DisclosureGroup {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(catalog.clients) { client in
                            Toggle(
                                client.label,
                                isOn: Binding(
                                    get: { enabledIDs.contains(client.id) },
                                    set: { enabled in
                                        if enabled { enabledIDs.insert(client.id) } else { enabledIDs.remove(client.id) }
                                        StatisticsSources.saveSelection(enabledIDs, catalog: catalog)
                                    }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .font(.system(size: settingsRowDetailFontSize))
                            .accessibilityIdentifier("next.statistics.source.\(client.id)")
                        }
                    }
                    .padding(.vertical, 8)
                    Text(
                        language.text(
                            "MiMo Code 可能包含从 Claude 导入的记录，同时启用可能重复。Qoder CN 使用实验性读取方式。其余来源默认开启。",
                            "MiMo Code may include imported Claude sessions and duplicate their usage. Qoder CN uses an experimental reader. Other sources are enabled by default."
                        )
                    )
                    .font(.system(size: settingsRowDetailFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text(language.text("统计来源 · 已启用 \(enabledIDs.count)/\(catalog.clients.count)", "Usage sources · \(enabledIDs.count)/\(catalog.clients.count) enabled"))
                        .font(.system(size: settingsRowTitleFontSize, weight: .semibold))
                }
            } else {
                Text(language.text("统计组件未就绪，请重新安装应用。", "The statistics component is missing. Reinstall the app."))
                    .font(.system(size: settingsRowDetailFontSize))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { enabledIDs = catalog?.enabledIDs() ?? [] }
        .onReceive(NotificationCenter.default.publisher(for: StatisticsSources.selectionChanged)) { _ in
            enabledIDs = catalog?.enabledIDs() ?? []
        }
    }
}
