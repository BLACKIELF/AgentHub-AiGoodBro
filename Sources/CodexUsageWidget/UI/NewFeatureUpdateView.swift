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
                    Text(language.text("了解用量、反代、侧栏与精选更新，已有设置继续保留。", "Explore usage, proxy, sidebar and recommendation updates. Your existing settings are preserved."))
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

    @Environment(\.colorScheme) private var colorScheme
    private var language: WidgetLanguage { settings.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                featureHeading(language.text("本次更新", "What's new"), symbol: "arrow.triangle.2.circlepath")
                Text(
                    language.text(
                        "首次安装采用统一的外观与布局：跟随系统主题、卡片列表、自动隐藏侧栏、菜单栏倒计时和全部用量趋势。覆盖安装保留你的已有配置；账号、通知连接和自动使用授权仍由你设置。",
                        "New installations share a consistent appearance and layout: system theme, account cards, an auto-hiding sidebar, menu-bar countdowns and all-time usage trends. Replacement installations retain your settings; accounts, notification connections and automatic-use permissions remain yours to configure."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "关于页新增订阅优惠入口；版本标题跟随实际安装版本显示。已有账号、主题与设置继续保留。",
                        "About adds a subscription-offer link and displays the installed app version. Your accounts, themes and settings are preserved.")
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "2.5 反代与微信修复：修复并行请求下的误报忙碌，等待超时提供重试提示。排队遵守等待期限和取消信号；已预留账号的短暂文件锁竞争会在原期限内重试，已发送请求继续安全收尾。临时错误过期后按最新额度证据显示，忙碌标签明确为上次请求报告。避免控制通道阻塞，核实额度恢复后同步解除对应冷却。来源不明的旧版冷却，可停止反代后按账号备份清理；关闭面板会取消待核验清理，避免下次开启被阻止。微信会话更新不再中断发送中的通知；启动时调整通知内容，也能完成已保存连接的读取。自定义 5 小时上限保存后不再回退。普通账号暂时忙碌时先等待，不立即使用“最后使用”账号；已有规则保留。Codex 列表开关紧凑排列，窄窗口下分组换行。",
                        "2.5 proxy and WeChat fixes: Fix false busy refusals during parallel requests and provide retry guidance when waits expire. Queued admissions honor deadlines and cancellation; brief file-lock contention after reservation retries within the original budget, while issued requests complete safely. Expired temporary errors return to the latest quota evidence, and busy labels describe the last request. Prevent blocked control communication and reconcile verified quota recovery with engine cooldowns. After stopping the proxy, you can back up and clear one account’s legacy cooldowns with unknown causes; closing the panel cancels pending checks so they cannot block the next start. WeChat context updates no longer interrupt notifications in flight; changing notification content during startup also preserves the saved connection load. Custom 5-hour limits retain their saved values. Temporarily busy ordinary accounts are awaited before Use last accounts. Existing rules are preserved. Codex list switches use a compact layout, wrapping as groups in narrow windows."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "用量统计保留 Token Monitor 0.70 的日志读取与计价修复，并采纳 0.71 的两项修复：历史统计交接给后台后释放重复占用，读取失败时保留上一份完整统计；修复可选菜单栏浮窗点击关闭后立即又弹出的问题。侧栏、浮窗与统一 TPM 沿用已有设置。",
                        "Usage tracking keeps the log-reading and pricing fixes from Token Monitor 0.70 and adopts two fixes from 0.71: release duplicate archive memory after background handoff and retain the last complete totals when reads fail; fix the optional tray popover immediately reopening when you click to close it. Your sidebar, popover and unified TPM settings stay in place."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "反代引擎更新至 8.0.28：改进流式响应解析，修正部分连接断开被误记为账号冷却。取消参与后，等待与重试也会跳过该账号；已接入的响应继续完成。保留优先、最后使用及点数底线。",
                        "Proxy engine 8.0.28 improves streamed-response parsing and prevents certain closed connections from incorrectly cooling an account. Disabling participation also skips waiting admissions and retries; admitted responses finish. Priority, Use last and credit floors are preserved."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "Claude 登录配置跟随官方规则：空的旧配置文件不再遮住当前配置，保存和切换时核对同一文件，保留账号与共享设置。",
                        "Claude configuration follows the official rules: an empty legacy file no longer shadows the current configuration. Saving and switching validate the same file while preserving account and shared settings."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            Text(
                language.text(
                    "反代新增统一 5 小时已用上限：填写百分比，一键应用到 Plus 账号，仍可单独调整。Pro 保持原规则。低于 100% 时达到上限即停止新请求，已有响应继续完成；设为 100% 时保留原有点数接续规则。",
                    "Set a uniform 5-hour used-percentage limit for Plus accounts, with individual overrides. Pro rules remain unchanged. A limit below 100% stops new admissions when reached; admitted responses finish. At 100%, existing credit-fallback rules remain."
                )
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18).padding(.bottom, 18)
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
