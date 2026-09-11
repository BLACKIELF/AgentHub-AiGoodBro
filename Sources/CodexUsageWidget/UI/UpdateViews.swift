import SwiftUI

private let updateControlCornerRadius: CGFloat = 8

struct AppUpdateSettingsRows: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updateStore: AppUpdateStore
    let language: WidgetLanguage

    var body: some View {
        SettingsToggleRow(
            title: language.text("自动检查更新", "Check automatically"),
            detail: language.text("每天最多读取一次 GitHub Release，包含 beta 版本", "Daily GitHub Releases check, including beta")
        ) {
            SettingsSwitchToggle(isOn: $settings.automaticUpdateChecksEnabled)
        }

        SettingsBaseRow(
            title: language.text("更新检查", "Update check"),
            detail: settingsStatusDetail
        ) {
            HStack(spacing: 8) {
                UpdateIconButton(
                    systemName: updateStore.isChecking ? "hourglass" : "arrow.clockwise",
                    help: language.text("检查更新", "Check for updates"),
                    isDisabled: updateStore.isChecking
                ) {
                    updateStore.checkNow()
                }

                if updateStore.result.status == .updateAvailable {
                    UpdateIconButton(
                        systemName: "arrow.down.circle.fill",
                        help: language.text("下载新版", "Download update"),
                        tint: FixedVisualPalette.statusInfo
                    ) {
                        updateStore.openPreferredUpdateURL()
                    }

                    UpdateIconButton(
                        systemName: "eye.slash",
                        help: language.text("忽略此版本", "Skip this version")
                    ) {
                        updateStore.skipCurrentAvailableVersion()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var settingsStatusDetail: String {
        switch updateStore.result.status {
        case .updateAvailable:
            let version = updateStore.result.latestVersionLabel ?? "--"
            let asset =
                updateStore.result.preferredAsset == nil
                ? language.text("未找到匹配架构安装包，将打开 Release 页面", "No matching DMG; opens release page")
                : language.text("已匹配当前 Mac 的 DMG", "Matched a DMG for this Mac")
            return language.text("发现 \(version) · \(asset)", "\(version) available · \(asset)")
        case .checking:
            return language.text("正在读取 GitHub Release", "Reading GitHub Releases")
        case .upToDate:
            return language.text("当前版本 \(updateStore.result.currentVersion) 已是最新", "Current \(updateStore.result.currentVersion) is up to date")
        case .failed:
            return updateStore.result.errorMessage ?? language.text("暂时无法检查更新", "Unable to check right now")
        case .disabled:
            return language.text("自动检查已关闭，仍可手动检查", "Automatic checks are off; manual checks still work")
        case .idle:
            return language.text("默认接收 beta 版本", "Beta releases are included")
        }
    }
}

private struct UpdateIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    let systemName: String
    let help: String
    var tint: Color?
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: updateControlCornerRadius, style: .continuous)
                        .fill(isHovering ? FixedVisualPalette.controlSelectedFill(colorScheme) : FixedVisualPalette.controlFill(colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: updateControlCornerRadius, style: .continuous)
                                .strokeBorder(FixedVisualPalette.controlStroke(colorScheme), lineWidth: 0.8)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return Color.secondary.opacity(0.55)
        }
        return tint ?? Color.secondary
    }
}
