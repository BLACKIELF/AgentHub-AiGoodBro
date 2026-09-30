import SwiftUI

/// Message-channel settings surface. The view holds no state of its own
/// beyond drafts and performs no I/O: credentials, enablement and sending are
/// injected closures wired by the host, so Keychain access stays in the app
/// layer and tests can drive the view with synthetic placeholders only.
struct MessageChannelsView: View {
    let telegramPhase: MessageChannelPhase
    let weChatCapabilities: [WeChatChannelCapability]

    @Binding var telegramEnabled: Bool
    @Binding var telegramTokenDraft: String
    @Binding var telegramTargetDraft: String
    @Binding var weChatEnabled: Bool
    @Binding var weChatKeyDraft: String
    @Binding var weChatMessageOptions: FeishuMessageOptions
    @Binding var personalWeChatEnabled: Bool
    @Binding var personalPairingCode: String
    var personalWeChatConnected: Bool
    var personalWeChatHasContext: Bool
    var personalLoginInProgress: Bool
    var personalLoginQRCode: String?
    var personalLoginNeedsCode: Bool

    var onSaveTelegram: () -> Void
    var onTestTelegram: () -> Void
    var onSaveWeChat: () -> Void
    var onTestWeChat: () -> Void
    var onConnectPersonalWeChat: () -> Void
    var onCancelPersonalWeChat: () -> Void
    var onSubmitPersonalWeChatCode: (String) -> Void
    var onTestPersonalWeChat: () -> Void
    var onOpenHelp: (URL) -> Void

    var actionInFlight: Bool = false
    var statusText: String? = nil

    var personalChatEnabled: Binding<Bool> = .constant(false)
    var personalChatThreadID: Binding<String> = .constant("")
    var personalChatTargets: [WeChatCodexConversationTarget] = []
    var personalBotIsReplying = false
    var onRefreshPersonalChatTargets: () -> Void = {}
    var onOpenPersonalChat: () -> Void = {}

    @Environment(\.widgetLanguage) private var language

    var body: some View {
        Form {
            if actionInFlight {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(language.text("正在处理，请稍候…", "Working, please wait…"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let statusText {
                Section(language.text("操作结果", "Action result")) {
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Section(language.text("微信机器人", "WeChat bot")) {
                PersonalWeChatSettingsView(
                    enabled: $personalWeChatEnabled, pairingCode: $personalPairingCode,
                    connected: personalWeChatConnected, hasContext: personalWeChatHasContext,
                    connecting: personalLoginInProgress, qrContent: personalLoginQRCode,
                    needsCode: personalLoginNeedsCode, disabled: actionInFlight,
                    onConnect: onConnectPersonalWeChat, onCancel: onCancelPersonalWeChat,
                    onSubmitCode: onSubmitPersonalWeChatCode, onTest: onTestPersonalWeChat)
                Toggle(language.text("允许微信继续 Codex 对话", "Continue Codex chats from WeChat"), isOn: personalChatEnabled)
                    .disabled(actionInFlight || personalLoginInProgress)
                if personalChatEnabled.wrappedValue {
                    Picker(language.text("继续哪个原聊天", "Continue which chat"), selection: personalChatThreadID) {
                        Text(language.text("请选择原聊天", "Choose a chat")).tag("")
                        if !personalChatThreadID.wrappedValue.isEmpty,
                            !personalChatTargets.contains(where: { $0.id == personalChatThreadID.wrappedValue })
                        {
                            Text(language.text("已选聊天（暂未刷新）", "Selected chat (not refreshed)")).tag(personalChatThreadID.wrappedValue)
                        }
                        ForEach(personalChatTargets) { target in
                            Text(target.title).tag(target.id)
                        }
                    }.disabled(actionInFlight)
                    HStack {
                        Button(language.text("刷新聊天列表", "Refresh chats"), action: onRefreshPersonalChatTargets)
                        Button(language.text("打开原聊天", "Open original chat"), action: onOpenPersonalChat)
                            .disabled(personalChatThreadID.wrappedValue.isEmpty)
                    }
                    if personalBotIsReplying {
                        Label(language.text("Codex 正在回复", "Codex is replying"), systemImage: "ellipsis.message")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(language.text("沿用原聊天的模型、工具和权限；审批、登录在电脑上完成。", "Uses the original chat’s model, tools and permissions. Complete approvals and sign-in on your computer."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(language.text("微信发送 /状态、/任务、/重置卡、/帮助，即可查询。", "Send /status, /tasks, /reset or /help in WeChat to query."))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(language.text("通知内容与提醒", "Notification content and alerts")) {
                    FeishuMessageOptionsView(options: $weChatMessageOptions, disabled: actionInFlight || personalLoginInProgress)
                    Text(language.text("个人微信与企业微信共用这些内容选项。", "These content options apply to personal WeChat and WeCom."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(language.text("腾讯官方说明", "Tencent documentation")) {
                    onOpenHelp(PersonalWeChatMessageChannel.documentation)
                }.font(.caption)
            }

            Section(language.text("Telegram Bot", "Telegram Bot")) {
                phaseRow(telegramPhase)
                if case .unavailable(let reason) = telegramPhase {
                    Text(reason.summary(language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle(language.text("启用 Telegram 通知", "Enable Telegram messages"), isOn: $telegramEnabled)
                        .disabled(actionInFlight)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text("Bot Token", "Bot token"))
                        SecureField(language.text("输入新令牌", "Enter a new token"), text: $telegramTokenDraft)
                            .accessibilityLabel(language.text("Bot Token", "Bot token"))
                    }
                    .disabled(actionInFlight)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text("Chat ID 或 @频道用户名", "Chat ID or @channel username"))
                        TextField(language.text("输入接收目标", "Enter a recipient"), text: $telegramTargetDraft)
                            .accessibilityLabel(language.text("Chat ID 或 @频道用户名", "Chat ID or @channel username"))
                    }
                    .disabled(actionInFlight)
                    VStack(alignment: .leading, spacing: 8) {
                        Button(language.text("保存凭据", "Save credential"), action: onSaveTelegram)
                        Button(language.text("发送测试消息", "Send test message"), action: onTestTelegram)
                            .disabled(telegramPhase != .pendingVerification && telegramPhase != .ready)
                    }
                    .disabled(actionInFlight)
                    Text(
                        language.text(
                            "令牌只保存在本机钥匙串，不会显示或写入日志。发送成功仅表示 Telegram API 已接收，不保证送达。",
                            "The token is stored in the local Keychain only, never shown or logged. A successful send only means the Telegram API accepted the message.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(language.text("企业微信与公众号", "WeCom and Official Accounts")) {
                ForEach(weChatCapabilities.filter { $0.variant != .personal }, id: \.variant) { capability in
                    VStack(alignment: .leading, spacing: 4) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capability.variant.displayName(language))
                            phaseBadge(capability.phase)
                        }
                        Text(capability.summary(language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if capability.variant == .workGroupBot, isConfigurable(capability.phase) {
                        Toggle(language.text("启用企业微信通知", "Enable WeCom messages"), isOn: $weChatEnabled)
                            .disabled(actionInFlight)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(language.text("群机器人 Webhook Key", "Group-robot webhook key"))
                            SecureField(language.text("输入新密钥", "Enter a new key"), text: $weChatKeyDraft)
                                .accessibilityLabel(language.text("群机器人 Webhook Key", "Group-robot webhook key"))
                        }
                        .disabled(actionInFlight)
                        VStack(alignment: .leading, spacing: 8) {
                            Button(language.text("保存凭据", "Save credential"), action: onSaveWeChat)
                            Button(language.text("发送测试消息", "Send test message"), action: onTestWeChat)
                                .disabled(capability.phase != .pendingVerification && capability.phase != .ready)
                        }
                        .disabled(actionInFlight)
                        FeishuMessageOptionsView(options: $weChatMessageOptions, disabled: actionInFlight)
                    }
                    if let helpURL = capability.helpURL {
                        Button(language.text("官方说明", "Official documentation")) {
                            onOpenHelp(helpURL)
                        }
                        .font(.caption)
                    }
                }
                Text(
                    language.text(
                        "企业微信与个人微信分别开关；公众号仍需单独部署服务端。",
                        "WeCom and personal WeChat have separate switches. Official Accounts still require a separate server deployment."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .tint(.blue)
    }

    private func isConfigurable(_ phase: MessageChannelPhase) -> Bool {
        switch phase {
        case .disabled, .needsSetup, .pendingVerification, .ready:
            return true
        case .unavailable:
            return false
        }
    }

    @ViewBuilder
    private func phaseRow(_ phase: MessageChannelPhase) -> some View {
        HStack {
            Text(language.text("状态", "Status"))
            Spacer()
            phaseBadge(phase)
        }
    }

    @ViewBuilder
    private func phaseBadge(_ phase: MessageChannelPhase) -> some View {
        switch phase {
        case .disabled:
            Text(language.text("已关闭", "Disabled")).foregroundStyle(.secondary)
        case .needsSetup:
            Text(language.text("待配置", "Needs setup")).foregroundStyle(.orange)
        case .pendingVerification:
            Text(language.text("已配置待验证", "Pending verification")).foregroundStyle(.blue)
        case .ready:
            Text(language.text("已验证", "Verified")).foregroundStyle(.green)
        case .unavailable:
            Text(language.text("不可用", "Unavailable")).foregroundStyle(.red)
        }
    }
}
