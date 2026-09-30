import SwiftUI

struct MessageChannelsSettingsView: View {
    @ObservedObject var controller: MessageChannelsController
    @Environment(\.widgetLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    var recentOutcomes: [PublicResetChannelResult] = []
    @State private var telegramToken = ""
    @State private var telegramTarget = ""
    @State private var weChatKey = ""
    @State private var personalPairingCode = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.text("微信与其他通知", "WeChat and other notifications")).font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(language.text("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .fixedSize()
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("通知渠道", "Notification channels")).font(.headline)
                channelStatus("Telegram", phase: controller.telegramPhase)
                channelStatus(language.text("个人微信", "Personal WeChat"), phase: controller.personalWeChatPhase)
                channelStatus(language.text("企业微信群机器人", "WeCom group bot"), phase: controller.weChatPhase)
                ForEach(Array(recentOutcomes.enumerated()), id: \.offset) { _, outcome in
                    HStack {
                        Text(outcome.summary(language))
                        Spacer()
                        Text(outcome.checkedAt, style: .time)
                    }.font(.caption).accessibilityElement(children: .combine)
                }
                Text(
                    language.text(
                        "渠道已接受仅表示 API 接受请求，不代表收件人已收到或已读。保存配置后，请主动发送测试消息。",
                        "Channel accepted means the API accepted the request; receipt and reading are unconfirmed. Send a test explicitly after saving.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 10)
            MessageChannelsView(
                telegramPhase: controller.telegramPhase,
                weChatCapabilities: WeChatChannelCapabilities.all(workGroupBotPhase: controller.weChatPhase,
                    personalPhase: controller.personalWeChatPhase),
                telegramEnabled: Binding(get: { controller.telegramEnabled }, set: { controller.setEnabled($0, for: .telegram) }),
                telegramTokenDraft: $telegramToken,
                telegramTargetDraft: $telegramTarget,
                weChatEnabled: Binding(get: { controller.weChatEnabled }, set: { controller.setEnabled($0, for: .weChat) }),
                weChatKeyDraft: $weChatKey,
                weChatMessageOptions: Binding(get: { controller.weChatMessageOptions },
                    set: { controller.setWeChatMessageOptions($0) }),
                personalWeChatEnabled: Binding(get: { controller.personalWeChatEnabled }, set: { controller.setEnabled($0, for: .personalWeChat) }),
                personalPairingCode: $personalPairingCode,
                personalWeChatConnected: controller.personalWeChatConnected,
                personalWeChatHasContext: controller.personalWeChatHasContext,
                personalLoginInProgress: controller.personalLoginInProgress,
                personalLoginQRCode: controller.personalLoginQRCode,
                personalLoginNeedsCode: controller.personalLoginNeedsCode,
                onSaveTelegram: {
                    let submittedToken = telegramToken
                    let submittedTarget = telegramTarget
                    controller.save(secret: submittedToken, target: submittedTarget, for: .telegram) { saved in
                        if saved, telegramToken == submittedToken, telegramTarget == submittedTarget {
                            telegramToken = ""
                            telegramTarget = ""
                        }
                    }
                },
                onTestTelegram: { controller.sendTest(.telegram) },
                onSaveWeChat: {
                    let submittedKey = weChatKey
                    controller.save(secret: submittedKey, target: nil, for: .weChat) { saved in
                        if saved, weChatKey == submittedKey { weChatKey = "" }
                    }
                },
                onTestWeChat: { controller.sendTest(.weChat) },
                onConnectPersonalWeChat: { controller.connectPersonalWeChat() },
                onCancelPersonalWeChat: { controller.cancelPersonalWeChatLogin() },
                onSubmitPersonalWeChatCode: { controller.submitPersonalWeChatCode($0) },
                onTestPersonalWeChat: { controller.sendTest(.personalWeChat) },
                onOpenHelp: { NSWorkspace.shared.open($0) },
                actionInFlight: controller.actionInFlight,
                statusText: controller.statusText,
                personalChatEnabled: Binding(get: { controller.personalChatEnabled }, set: { controller.setPersonalChatEnabled($0) }),
                personalChatThreadID: Binding(get: { controller.personalChatThreadID }, set: { controller.setPersonalChatThread($0) }),
                personalChatTargets: controller.personalChatTargets,
                personalBotIsReplying: controller.personalBotIsReplying,
                onRefreshPersonalChatTargets: { controller.refreshPersonalChatTargets() },
                onOpenPersonalChat: {
                    if let url = CodexSessionLink.url(threadID: controller.personalChatThreadID) { NSWorkspace.shared.open(url) }
                }
            )
        }
        .frame(minWidth: 320, idealWidth: 580, maxWidth: 580, minHeight: 280, idealHeight: 680, maxHeight: 680)
        .onDisappear {
            telegramToken = ""
            telegramTarget = ""
            weChatKey = ""
            personalPairingCode = ""
            controller.cancelPersonalWeChatLogin()
        }
    }
    private func channelStatus(_ title: String, phase: MessageChannelPhase) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(phaseLabel(phase)).foregroundStyle(.secondary)
        }.font(.caption).accessibilityElement(children: .combine)
    }

    private func phaseLabel(_ phase: MessageChannelPhase) -> String {
        switch phase {
        case .disabled: return language.text("已关闭", "Disabled")
        case .needsSetup: return language.text("未配置", "Unconfigured")
        case .pendingVerification: return language.text("已配置，待测试或核验", "Configured · test or verification needed")
        case .ready: return language.text("渠道已接受", "Channel accepted")
        case .unavailable: return language.text("需要处理", "Needs attention")
        }
    }

}
