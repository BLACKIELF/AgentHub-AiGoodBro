import SwiftUI

/// A standalone reminder. Closing it never completes an installation guide.
@MainActor
struct NewFeatureUpdateView: View {
    static let preferredSize = CGSize(width: 620, height: 570)
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    var doneTitle: String? = nil
    var onDone: () -> Void

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
                    Text(language.text("两项可选设置，按需开启。", "Two optional settings. Choose what suits you."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 22)
            ScrollView {
                NewFeatureSetupControls(store: store, settings: settings)
                    .padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
            Divider().padding(.top, 16).padding(.bottom, 16)
            HStack(spacing: 16) {
                Text(language.text("已有设置保留，不会自动开启。", "Your settings stay saved. Nothing turns on automatically."))
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
    @State private var showingResetAutoSettings = false

    @Environment(\.colorScheme) private var colorScheme
    private var language: WidgetLanguage { settings.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
