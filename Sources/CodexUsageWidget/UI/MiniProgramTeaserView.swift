import SwiftUI

/// A local preview entry; it does not launch or connect to an unpublished mini program.
struct MiniProgramTeaserView: View {
    let language: WidgetLanguage
    var compact = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MiniProgramFeaturePreview(language: language)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(width: 34, height: 34)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("微信小程序", "WeChat Mini Program"))
                        .font(.callout.weight(.semibold))
                    Text(language.text("即将上线，敬请期待 · 点击查看预告", "Coming soon · View the preview"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .accessibilityIdentifier("about.miniprogram.preview")
        .padding(compact ? 12 : 14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct MiniProgramFeaturePreview: View {
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            feature(
                symbol: "books.vertical",
                title: language.text("AI 实用资源库", "Practical AI library"),
                detail: language.text("汇集 Skill、提示词与 AI 实用方法。", "Explore Skills, prompts and practical AI guides.")
            )
            feature(
                symbol: "magnifyingglass",
                title: language.text("随手查，随手用", "Find it. Save it. Use it."),
                detail: language.text("搜索资源、收藏常用内容，一键复制。", "Search resources, bookmark favorites and copy content.")
            )
            feature(
                symbol: "bell.badge",
                title: language.text("独立订阅重置消息", "Subscribe to public reset updates"),
                detail: language.text(
                    "计划支持不绑定桌面，通过微信授权订阅公共重置消息。",
                    "Planned: subscribe to public reset updates with WeChat permission, without linking the desktop."
                )
            )
            feature(
                symbol: "desktopcomputer",
                title: language.text("桌面消息，手机查看", "Desktop updates on your phone"),
                detail: language.text(
                    "计划支持连接桌面后，查看重置卡增减与 24 小时临期提醒。",
                    "Planned: connect to the desktop to view reset-card changes and 24-hour expiry reminders."
                )
            )
            Text(
                language.text(
                    "以上为功能预告，暂未上线。登录、桌面同步与离线推送仍在准备中。",
                    "Feature preview only; not yet available. Login, desktop sync and offline notifications are still in development."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
