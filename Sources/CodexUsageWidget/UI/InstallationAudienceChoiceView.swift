import SwiftUI

/// Presents a choice only. Selecting or deferring is handled by the installation host.
struct InstallationAudienceChoiceView: View {
    let language: WidgetLanguage
    var onSelect: (NextSetupAudience) -> Void
    var onDefer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                AHBrandSymbol(size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(language.text("欢迎使用 AiGoodBro", "Welcome to AiGoodBro"))
                        .font(.system(size: 23, weight: .semibold))
                    Text(language.text("选择设置方式", "Choose how to set up"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                audienceCard(
                    .newUser, symbol: "person.crop.circle.badge.plus",
                    title: language.text("我是新用户", "I'm a new user"),
                    detail: language.text("连接账号与工具，了解所有功能。", "Connect accounts and tools, then explore all features."))
                audienceCard(
                    .returningUser, symbol: "arrow.clockwise.circle",
                    title: language.text("我是老用户", "I'm a returning user"),
                    detail: language.text("保留已有配置，只检查微信、飞书和新增功能。", "Keep your setup. Review WeChat, Feishu and new features."))
            }
            HStack {
                Text(language.text("选择或跳过不会自动开启功能，也不会删除数据。", "Choosing or skipping does not enable features or remove data."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(language.text("以后再说", "Not now"), action: onDefer)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(26)
        .frame(width: 640, height: 360, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
    }

    private func audienceCard(_ audience: NextSetupAudience, symbol: String, title: String, detail: String) -> some View {
        Button {
            onSelect(audience)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(Color.accentColor)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
