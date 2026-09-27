import SwiftUI

/// A native navigation entry only. The complete dashboard/settings are rendered
/// by the bundled upstream code, so no second layout can drift from its assets.
struct TokenMonitorDesktopEntryView: View {
    let language: WidgetLanguage
    let route: TokenMonitorDesktopController.Route
    @ObservedObject private var desktop = TokenMonitorDesktopController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                route == .dashboard
                    ? language.text("AiGoodBro 用量与限额", "AiGoodBro Usage & Limits")
                    : language.text("AiGoodBro 浮窗", "AiGoodBro Popover")
            )
            .font(.headline)
            Text(
                route == .dashboard
                    ? language.text("查看用量趋势、模型、工具、项目和会话统计。", "Explore usage trends, models, tools, projects and sessions.")
                    : language.text("在菜单栏 Home 使用同一浮窗调整显示、右侧 Dock、数据源、限额与价格。", "Adjust display, Edge Dock, data sources, limits and pricing in the same popover as menu bar Home.")
            )
            .foregroundStyle(.secondary)
            HStack {
                Button(
                    route == .dashboard
                        ? language.text("打开用量看板", "Open usage dashboard")
                        : language.text("打开浮窗设置", "Open popover settings")
                ) { desktop.open(route) }
                .buttonStyle(.borderedProminent)
                if route == .settings {
                    Button(language.text("打开菜单栏 Home", "Open menu bar Home")) { desktop.open(.home) }
                }
            }
            if let error = desktop.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }
}
