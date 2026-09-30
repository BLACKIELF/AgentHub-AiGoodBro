import SwiftUI

/// A native navigation entry only. The complete dashboard/settings are rendered
/// by the bundled upstream code, so no second layout can drift from its assets.
struct TokenMonitorDesktopEntryView: View {
    let language: WidgetLanguage
    let route: TokenMonitorDesktopController.Route
    @ObservedObject private var desktop = TokenMonitorDesktopController.shared

    private var title: String {
        switch route {
        case .menuBarSettings: return language.text("菜单栏显示", "Menu bar display")
        case .floatingBubbleSettings: return language.text("悬浮窗行为", "Floating window behaviour")
        case .dashboard: return language.text("AiGoodBro 用量与限额", "AiGoodBro Usage & Limits")
        default: return language.text("用量统计设置", "Usage settings")
        }
    }

    private var detail: String {
        switch route {
        case .menuBarSettings:
            return language.text("调整菜单栏图标、额度条、Token 和成本显示。", "Choose the menu bar icon, limit bars, tokens and cost.")
        case .floatingBubbleSettings:
            return language.text("调整悬浮窗的开启方式、收起行为和显示内容。", "Choose how the floating window opens, collapses and displays its content.")
        case .dashboard:
            return language.text("查看用量趋势、模型、工具、项目和会话统计。", "Explore usage trends, models, tools, projects and sessions.")
        default:
            return language.text("调整统计数据源、限额与价格。", "Adjust usage sources, limits and pricing.")
        }
    }

    private var actionTitle: String {
        switch route {
        case .menuBarSettings: return language.text("调整菜单栏显示", "Configure menu bar")
        case .floatingBubbleSettings: return language.text("调整悬浮窗", "Configure floating window")
        case .dashboard: return language.text("打开用量看板", "Open usage dashboard")
        default: return language.text("打开统计设置", "Open usage settings")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
            .font(.headline)
            Text(detail)
            .foregroundStyle(.secondary)
            HStack {
                Button(actionTitle) { desktop.open(route) }
                .buttonStyle(.borderedProminent)
            }
            if let error = desktop.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }
}
