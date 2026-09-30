import SwiftUI

struct FeishuMessageOptionsView: View {
    @Binding var options: FeishuMessageOptions
    let disabled: Bool
    @Environment(\.widgetLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text("消息字段", "Message fields"))
                .font(.subheadline.weight(.semibold))

            Picker(language.text("消息密度", "Message density"), selection: Binding(
                get: { options.contentPreset },
                set: { options.applyContentPreset($0) }
            )) {
                Text(language.text("紧凑", "Compact")).tag(FeishuMessageOptions.ContentPreset.compact)
                Text(language.text("详细", "Detailed")).tag(FeishuMessageOptions.ContentPreset.detailed)
                Text(language.text("自定义", "Custom")).tag(FeishuMessageOptions.ContentPreset.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(.blue)

            Toggle(language.text("Agent 名称（固定为 Codex）", "Agent name (always Codex)"), isOn: $options.includesAgentName)
            Toggle(language.text("账号备注名", "Account label"), isOn: $options.includesAccountLabel)
            Toggle(language.text("5 小时与 7 天额度", "5-hour and 7-day quotas"), isOn: $options.includesQuotas)
            Toggle(language.text("额度重置时间", "Quota reset times"), isOn: $options.includesResetTimes)
            Toggle(language.text("可用 Reset 卡", "Available reset credits"), isOn: $options.includesResetCredits)

            Text(language.text("额度窗口提醒", "Quota-window alerts"))
                .font(.caption)
            Toggle(language.text("5 小时窗口重置", "5-hour window reset"), isOn: $options.notifiesFiveHourReset)
            Toggle(language.text("7 天窗口重置", "7-day window reset"), isOn: $options.notifiesSevenDayReset)

            if options.includesResetCredits {
                Text(language.text("到期详情", "Expiry details"))
                    .font(.caption)
                Picker(language.text("到期详情", "Expiry details"), selection: $options.resetExpiryDetail) {
                    Text(language.text("最近一次", "Nearest")).tag(FeishuMessageOptions.ResetExpiryDetail.nearest)
                    Text(language.text("全部", "All")).tag(FeishuMessageOptions.ResetExpiryDetail.all)
                    Text(language.text("不显示", "Hide")).tag(FeishuMessageOptions.ResetExpiryDetail.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Text(
                language.text(
                    "默认显示账号备注、额度与重置时间，以及可用 Reset 卡和最近到期时间。",
                    "By default, cards show the account label, quotas and reset times, plus available resets and the nearest expiry."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .tint(.blue)
        .disabled(disabled)
    }
}
