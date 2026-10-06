import SwiftUI

/// Presents a choice only. Selecting or deferring is handled by the installation host.
struct InstallationAudienceChoiceView: View {
    static let preferredSize = CGSize(width: 620, height: 500)
    let language: WidgetLanguage
    var onSelect: (NextSetupAudience) -> Void
    var onDefer: () -> Void
    var onShowUpdates: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedAudience: NextSetupAudience?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                AHBrandSymbol(size: 44)
                    .padding(7)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                Text(language.text("欢迎使用 AiGoodBro", "Welcome to AiGoodBro"))
                    .font(.system(size: 22, weight: .semibold))
                Text(language.text("选择适合你的设置方式", "Make yourself at home"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                audienceCard(
                    .newUser, symbol: "person.crop.circle.badge.plus",
                    title: language.text("我是新用户", "I'm a new user"),
                    detail: language.text("从连接账号开始，逐步设置全部功能。", "Connect your accounts and explore each feature."),
                    action: language.text("开始完整设置", "Start full setup"))
                audienceCard(
                    .returningUser, symbol: "arrow.clockwise.circle",
                    title: language.text("我是老用户", "I'm a returning user"),
                    detail: language.text("保留已有配置，检查微信、飞书与新功能。", "Keep your setup. Review connections and new features."),
                    action: language.text("检查升级设置", "Review update settings"))
            }
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(FixedVisualPalette.statusInfoForeground(colorScheme))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("本次更新 · 2 项可选设置", "What's new · 2 optional settings"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(language.text("重置卡临期自动使用 · 侧栏额度样式", "Reset-card expiry protection · Sidebar quota style"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(language.text("查看与设置", "Review settings"), action: onShowUpdates)
                    .buttonStyle(.bordered).controlSize(.small)
                    .fixedSize()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Label(language.text("保留账号与数据，功能由你选择开启", "Your data stays saved. Features remain opt-in."), systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(language.text("以后再说", "Not now"), action: onDefer)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
    }

    private func audienceCard(_ audience: NextSetupAudience, symbol: String, title: String, detail: String, action: String) -> some View {
        let accent = audience == .newUser ? FixedVisualPalette.statusInfo : FixedVisualPalette.statusScheduled
        let foreground =
            audience == .newUser
            ? FixedVisualPalette.statusInfoForeground(colorScheme) : FixedVisualPalette.statusScheduledForeground(colorScheme)
        return Button {
            onSelect(audience)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(foreground)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(colorScheme == .dark ? 0.14 : 0.085), in: RoundedRectangle(cornerRadius: 11))
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(action).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(foreground)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 184, maxHeight: 184, alignment: .topLeading)
        }
        .buttonStyle(AudienceChoiceButtonStyle(accent: accent, isFocused: focusedAudience == audience))
        .focused($focusedAudience, equals: audience)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

private struct AudienceChoiceButtonStyle: ButtonStyle {
    let accent: Color
    let isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return configuration.label
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                if !reduceTransparency {
                    shape.fill(accent.opacity(configuration.isPressed ? 0.10 : isHovered ? 0.065 : colorScheme == .dark ? 0.035 : 0.018))
                }
            }
            .overlay {
                shape.strokeBorder(
                    isFocused ? Color.accentColor : isHovered || configuration.isPressed ? accent.opacity(0.6) : Color.primary.opacity(contrast == .increased ? 0.25 : 0.09),
                    lineWidth: isFocused ? 2 : 1)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.035), radius: 5, y: 2)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
