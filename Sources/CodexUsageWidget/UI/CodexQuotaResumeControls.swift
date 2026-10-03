import SwiftUI

struct CodexQuotaResumeControls: View {
    @ObservedObject var store: UsageStore
    private var language: WidgetLanguage { WidgetLanguage.storedOrAutomatic() }

    var body: some View {
        if store.pauseDesktopTasksAtOnePercent || !store.quotaResume.pending.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SettingsToggleRow(
                    title: language.text("换号成功后自动继续原任务", "Continue original tasks after switching"),
                    detail: language.text(
                        "核实新账号后，在原对话中续做；已完成或已经继续的任务会跳过。关闭此项可手动继续。",
                        "After verifying the new account, continue in the same conversations. Finished or already continued tasks are skipped. Turn this off to continue manually.")
                ) {
                    SettingsSwitchToggle(
                        isOn: Binding(
                            get: { store.resumeDesktopTasksAfterSwitch },
                            set: { store.setResumeDesktopTasksAfterSwitch($0) })
                    )
                    .disabled(!store.pauseDesktopTasksAtOnePercent || store.pausedAutomationFeatures.contains(.lowQuota))
                    .accessibilityIdentifier("next.accounts.resumeAfterSwitch")
                }
                if !store.quotaResume.pending.isEmpty {
                    HStack {
                        Text(language.text("待续做：\(store.quotaResume.pending.count) 个任务", "Pending: \(store.quotaResume.pending.count) tasks"))
                        Spacer()
                        Button(language.text("继续原任务", "Continue tasks")) { store.resumePausedDesktopTasks() }
                            .disabled(store.quotaResume.isResuming || store.isLaunchingCodex)
                            .accessibilityIdentifier("next.accounts.resumePausedTasks")
                        Button(language.text("清除续做记录", "Clear continuation record")) { store.discardQuotaResumePlan() }
                            .disabled(store.quotaResume.isResuming || store.isLaunchingCodex)
                    }
                    .font(.system(size: settingsRowDetailFontSize))
                }
                if let message = store.quotaResume.message {
                    Text(message).font(.system(size: settingsRowDetailFontSize)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
