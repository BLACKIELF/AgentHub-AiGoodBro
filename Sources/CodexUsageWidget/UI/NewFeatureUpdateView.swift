import AppKit
import SwiftUI

/// A standalone reminder. Closing it never completes an installation guide.
@MainActor
struct NewFeatureUpdateView: View {
    static let preferredSize = CGSize(width: 620, height: 570)
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    var doneTitle: String? = nil
    var onDone: () -> Void
    var onOpenClaude: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    private var language: WidgetLanguage { settings.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(FixedVisualPalette.statusInfoForeground(colorScheme))
                    .frame(width: 48, height: 48)
                    .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(language.text("新功能与设置", "New features & settings"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(
                        language.text(
                            "反代控制与额度暂停改进，飞书、微信通知统一。",
                            "Proxy control and quota-pause improvements, with consistent Feishu and WeChat notifications.")
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 22)
            ScrollView {
                NewFeatureSetupControls(store: store, settings: settings, onOpenClaude: onOpenClaude)
                    .padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
            Divider().padding(.top, 16).padding(.bottom, 16)
            HStack(spacing: 16) {
                Text(language.text("查看介绍不会改变账号或设置；可选设置由你手动开启。", "Viewing this introduction does not change accounts or settings. Enable optional settings yourself."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(doneTitle ?? language.text("完成", "Done"), action: onDone)
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
        .onExitCommand(perform: onDone)
        .accessibilityIdentifier("next.new-feature-updates")
    }

}

/// Shared with the guide. Only explicit native control actions edit preferences.
@MainActor
struct NewFeatureSetupControls: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    var onOpenClaude: () -> Void = {}
    @State private var showingResetAutoSettings = false
    @State private var showingNotificationSettings = false

    @Environment(\.colorScheme) private var colorScheme
    private var language: WidgetLanguage { settings.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                featureHeading(language.text("本次更新 · 2.5.2（149）", "What's new · 2.5.2 (149)"), symbol: "arrow.triangle.2.circlepath")
                Text(
                    language.text(
                        "可恢复的短暂本地心跳断连会在原等待期限内重试；若无法确认请求状态，停止反代并保留故障记录。已发送的模型请求不会自动重发。",
                        "Recoverable brief local-heartbeat disconnects retry within the original deadline. If request state cannot be confirmed, the proxy stops and keeps a failure record. Sent model requests are not automatically resubmitted."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "单账号反代最多支持 10 个并发请求，继续核对身份、额度、点数和参与规则。反代面板布局更紧凑，已核实的 Plus 账号可统一设置 5 小时已用上限。",
                        "Each proxy account supports up to 10 concurrent requests, subject to identity, quota, credit and participation rules. The compact proxy panel also lets verified Plus accounts share a 5-hour used-quota limit."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "在反代面板按账号开启“额度恢复后暂停”：新的官方快照确认 5 小时或 7 天额度恢复后，停止接新任务，当前回复继续完成。预告与倒计时不触发；重新勾选参与即可继续。",
                        "Enable Pause after quota reset per account in the proxy panel. A new official snapshot confirming a 5-hour or 7-day quota reset stops new tasks while admitted replies finish. Forecasts and countdowns do not trigger it; re-enable Use to resume."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "飞书和微信的生成通知共用内容，统一北京时间，日期不含年份，并附“消息来源：aigoodbro.com”尾标，不再附原帖链接。重置卡按同一账号、同一额度池的官方前后快照核对增减；减少原因未知时如实说明。",
                        "Generated Feishu and WeChat notifications share content, Beijing time with the year omitted and the source footer aigoodbro.com, without original-post links. Reset-card changes compare official snapshots for the same account and quota pool; unknown reasons for decreases stay explicit."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "微信会话不再因本地推定的 24 小时期限失效；服务端拒绝时，仍需在通知设置中恢复连接。账号套餐类型保留官方读取结果，缺失值不覆盖已核实信息。设置中的配色库新增可选 GitHub Primer。",
                        "WeChat conversations no longer expire under a locally assumed 24-hour limit; server rejection still requires restoring the connection in notification settings. Account plan types retain official readings when a later read omits them. GitHub Primer is available in the palette library under Settings."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(language.text("通知与连接设置…", "Notification & connection settings…")) { showingNotificationSettings = true }
                        .controlSize(.regular)
                        .disabled(store.isPreview)
                        .accessibilityIdentifier("next.new-feature.notification-settings")
                    Button(language.text("打开设置…", "Open Settings…")) {
                        _ = NSApp.sendAction(NSSelectorFromString("openSettingsFromMenu"), to: NSApp.delegate, from: nil)
                    }
                    .controlSize(.regular)
                    .disabled(store.isPreview)
                    .accessibilityIdentifier("next.new-feature.settings")
                }
            }
            .padding(18)
            Divider().padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 10) {
                featureHeading(language.text("精选工具与安装自检", "Recommendations & installation checks"), symbol: "square.stack.3d.up")
                Text(
                    language.text(
                        "精选新增 REA，用于分析软件包、程序行为与版本差异；JEV 根据界面文字协助选择下一步，由 Codex 执行并核验。点击卡片查看用途和安装指令，按需安装。",
                        "REA joins the recommendations for analyzing software packages, runtime behavior and version changes. JEV helps choose the next step from interface text; Codex executes and verifies it. Open a card for its purpose and installation instructions."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "首次安装或覆盖安装后，只读检查一次本机安装情况；已检测到安装的项目不再推荐。每项可选择“不再显示”，也可在精选区手动“重新检查”。安装检测不代表服务已连接，也不会替你安装或调用工具。",
                        "After a new or replacement installation, one read-only check hides recommendations already installed locally. Choose Don't show again for any item, or Recheck in the recommendations area. Detection does not establish a service connection or install or invoke a tool."
                    )
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            Divider().padding(.horizontal, 18)
            ClaudeFeatureIntroductionPanel(
                language: language, isPreview: store.isPreview, onOpenClaude: onOpenClaude)
            Divider().padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 10) {
                featureHeading(language.text("重置卡增减与到期提醒", "Reset-card changes & expiry alerts"), symbol: "bell.badge")
                Text(
                    language.text(
                        "核实可用次数的增加或减少，显示前后数量与观察时段。已知到期时间的卡进入 24 小时内时提醒，减少忘记使用造成的浪费；提醒本身不会使用卡片。",
                        "Verified increases and decreases show both counts and the observation interval. Cards with a known expiry are flagged within 24 hours to help avoid forgotten credits. Alerts do not use cards."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "沿用已开启的系统、飞书和微信等消息通道及内容选项。同一张卡按通道去重；首次同步不补发历史增减，发送结果不确定时暂停重发。打开自动化中心检查连接与重置卡提醒设置。",
                        "Uses your enabled desktop, Feishu, WeChat and other channels and content choices. Each card is deduplicated per channel. Initial sync does not replay old changes; uncertain sends pause. Review connections and reset-card alerts in Automation."
                    )
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            Divider().padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 12) {
                featureHeading(
                    language.text("重置卡临期自动使用", "Use expiring reset cards"),
                    symbol: "clock.arrow.circlepath")
                Text(
                    language.text(
                        "避免忘记操作，让即将过期的重置卡及时使用。默认关闭、提前 30 分钟；每个账号由你单独授权。",
                        "Help avoid forgotten reset cards expiring unused. Off by default, with a 30-minute lead; authorize each account individually.")
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            ResetCreditAutoSettingsView.summary(
                                profiles: store.profiles, preferences: settings.resetCreditAutoPreferences, language: language)
                        )
                        .font(.system(size: 12, weight: .medium))
                        Text(
                            language.text(
                                "当前提前 \(settings.resetCreditAutoPreferences.leadMinutes) 分钟",
                                "Current lead: \(settings.resetCreditAutoPreferences.leadMinutes) min")
                        )
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(language.text("选择账号…", "Choose accounts…")) { showingResetAutoSettings = true }
                        .controlSize(.regular)
                        .help(language.text("仅打开设置，不会立即使用重置卡。", "Opens settings without using a reset card."))
                }
                Text(
                    language.text(
                        "应用须保持运行；仅空闲且身份核验通过时尝试，结果不确定时暂停核对。",
                        "Keep the app running. Only idle, verified accounts are eligible; uncertain outcomes pause for review.")
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            Divider().padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    featureHeading(language.text("侧栏额度样式", "Sidebar quota style"), symbol: "chart.pie")
                    Spacer(minLength: 8)
                    Picker(language.text("额度样式", "Quota style"), selection: $settings.edgeDock.quotaStyle) {
                        Text(language.text("圆环", "Rings")).tag(TokenMonitorEdgeDockPreferences.QuotaStyle.ring)
                        Text(language.text("小鱼", "Fish")).tag(TokenMonitorEdgeDockPreferences.QuotaStyle.fish)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 148)
                    .disabled(store.isPreview)
                }
                Toggle(language.text("显示侧栏", "Show sidebar"), isOn: $settings.edgeDock.enabled)
                    .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                    .disabled(store.isPreview)
                Text(
                    language.text(
                        "⌘I 显示／隐藏侧栏。Pro 显示 7 天，Plus 显示 5 小时额度；悬停查看详情，可固定保持展开。",
                        "⌘I shows or hides the sidebar. Pro shows 7-day limits and Plus shows 5-hour limits. Hover for details; Pin keeps them open.")
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "新增侧栏大小与 75–150% 自定义缩放、可选刷新按钮及运行指示设置。",
                        "New sidebar sizes, custom scaling from 75–150%, and optional refresh and running indicators.")
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button(language.text("更多侧栏设置…", "More sidebar settings…")) {
                    _ = NSApp.sendAction(NSSelectorFromString("openEdgeDockSettingsFromMenu"), to: NSApp.delegate, from: nil)
                }
                .controlSize(.regular)
                .disabled(store.isPreview)
                .accessibilityIdentifier("next.new-feature.sidebar-settings")
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        .sheet(isPresented: $showingResetAutoSettings) {
            ResetCreditAutoSettingsView(
                profiles: store.profiles, preferences: $settings.resetCreditAutoPreferences,
                status: store.resetCreditAutoStatus, language: language, isPreview: store.isPreview,
                onDone: { showingResetAutoSettings = false })
        }
        .sheet(isPresented: $showingNotificationSettings) {
            AccountAutomationCenterView(store: store)
                .environment(\.widgetLanguage, language)
        }
        .accessibilityIdentifier("next.new-feature-setup-controls")
    }

    private func featureHeading(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(FixedVisualPalette.statusInfoForeground(colorScheme)).frame(width: 18)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
    }
}

/// Informational content shared by the account guide and feature updates.
@MainActor
struct ClaudeFeatureIntroductionPanel: View {
    let language: WidgetLanguage
    var isPreview = false
    var onOpenClaude: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FixedVisualPalette.statusInfoForeground(colorScheme))
                    .frame(width: 18)
                Text(language.text("Claude 订阅账号与额度", "Claude subscriptions & limits"))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(
                language.text(
                    "先在 Claude Code 登录，再用“添加当前登录账号”保存；已有 Claude-swap 订阅可直接关联。在账号卡片上手动切换、刷新额度。当前账号不可解除关联；切换时可安全续期已过期的保存凭据，无法续期时提示重新登录。",
                    "Sign in to Claude Code, then choose Add signed-in account to save it. Link existing Claude-swap subscriptions; switch manually and refresh limits from account cards. The current account cannot be unlinked. Expired saved credentials are renewed during an explicit switch, or you are asked to sign in again."
                )
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                language.text(
                    "用圆环分别查看 5 小时和 7 天额度；API 实际返回 Fable 等独立模型额度时，按返回名称显示。",
                    "View 5-hour and 7-day limits in separate rings. When the API returns independent model limits such as Fable, they appear under the returned names.")
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button(language.text("查看 Claude 账号", "View Claude accounts"), action: onOpenClaude)
                .controlSize(.regular)
                .disabled(isPreview)
                .accessibilityIdentifier("next.open-claude-accounts")
        }
        .padding(18)
        .accessibilityIdentifier("next.claude-feature-introduction")
    }
}
