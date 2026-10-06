import AppKit
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
                        help: language.text("查看更新并下载", "View and download update"),
                        tint: FixedVisualPalette.statusInfo
                    ) {
                        updateStore.showUpdateDetails()
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
                ? language.text("未找到匹配架构安装包，可查看更新详情", "No matching DMG; view update details")
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

struct AppUpdateDetailView: View {
    @ObservedObject var store: AppUpdateStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var downloader: AppUpdateDownloader
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var language: WidgetLanguage { settings.language }
    private var release: GitHubReleaseInfo? { store.result.latestRelease }
    private var downloadState: AppUpdateDownloadState {
        guard let release, let asset = store.result.preferredAsset else { return .idle }
        return downloader.downloadIdentity == AppUpdateDownloadPolicy.identity(release: release, asset: asset) ? downloader.state : .idle
    }
    private var availabilityError: String? {
        guard let release, let asset = store.result.preferredAsset else {
            return language.text("此版本尚未提供适合当前 Mac 的安装包。", "This release has no package for this Mac.")
        }
        do {
            _ = try AppUpdateDownloadPolicy.plan(release: release, asset: asset, currentVersion: store.result.currentVersion)
            return nil
        } catch { return localized(error.localizedDescription) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 5) {
                    Text(language.text("AiGoodBro 有更新", "An AiGoodBro update is available"))
                        .font(.system(size: 21, weight: .semibold))
                    Text(language.text("看看新变化，再下载新版安装包。", "See what's new, then download the update."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if release?.prerelease == true {
                    Text("BETA").font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.blue.opacity(0.12), in: Capsule()).foregroundStyle(.blue)
                }
            }
            HStack(spacing: 10) {
                versionBadge(label: language.text("当前版本", "Current"), version: store.result.currentVersion, highlighted: false)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                versionBadge(label: language.text("新版本", "New"), version: release?.versionLabel ?? "—", highlighted: true)
                Spacer()
                if let date = release?.publishedAt {
                    Text(date, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(language.text("更新内容", "What's new"), systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(language.text("发布页面", "Release page")) {
                        guard let release, AppUpdateDownloadPolicy.trustedReleaseURL(release.htmlURL, tag: release.tagName) else { return }
                        NSWorkspace.shared.open(release.htmlURL)
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }
                Divider()
                ScrollView {
                    Text(
                        release?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            ? release!.body : language.text("发布者尚未填写更新说明。", "The publisher has not added release notes.")
                    )
                    .font(.system(size: 13)).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
            .background(Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.65 : 0.85), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))

            downloadStatus
            HStack(spacing: 10) {
                if downloadState.isBusy {
                    Button(language.text("取消下载", "Cancel download")) { downloader.cancel() }
                } else if case .downloaded(let url) = downloadState {
                    Button(language.text("在 Finder 显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else {
                    Button(language.text("忽略此版本", "Skip this version")) {
                        store.skipCurrentAvailableVersion()
                        onClose()
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(language.text("稍后", "Later"), action: onClose).keyboardShortcut(.cancelAction)
                primaryButton
            }
            .controlSize(.large)
        }
        .padding(26)
        .frame(minWidth: 550, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .preferredColorScheme(settings.themeMode.preferredColorScheme)
    }

    private func versionBadge(label: String, version: String, highlighted: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(version).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 7)
        .background(highlighted ? Color.blue.opacity(0.10) : Color.primary.opacity(0.05), in: Capsule())
    }

    @ViewBuilder private var downloadStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch downloadState {
            case .preparing:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(language.text("正在准备下载…", "Preparing download…"))
                }
            case .downloading(let received, let total):
                HStack {
                    Text(language.text("正在下载安装包", "Downloading package"))
                    Spacer()
                    Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .monospacedDigit()
                }
                ProgressView(value: Double(received), total: Double(total))
            case .verifying:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(language.text("正在验证安装包…", "Verifying package…"))
                }
            case .downloaded:
                Label(language.text("下载完成，SHA256 与大小校验通过。", "Download complete. SHA256 and size verified."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(language.text("已保存到「下载 / AiGoodBro Updates」。打开后按安装提示更新。", "Saved in Downloads / AiGoodBro Updates. Open the package to update."))
                    .foregroundStyle(.secondary)
            case .failed(let error):
                Label(localized(error), systemImage: "exclamationmark.circle").foregroundStyle(.red)
            case .cancelled:
                Text(language.text("下载已取消，可以重新下载。", "Download cancelled. You can try again.")).foregroundStyle(.secondary)
            case .idle:
                if downloader.state.isBusy {
                    Text(language.text("另一个版本正在下载，请等待完成或取消。", "Another version is downloading. Wait or cancel it.")).foregroundStyle(.secondary)
                } else if let error = availabilityError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                } else if let asset = store.result.preferredAsset {
                    Text(
                        language.text(
                            "安装包 \(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)) · 下载后验证 SHA256",
                            "\(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)) package · SHA256 verified after download")
                    ).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11)).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }

    @ViewBuilder private var primaryButton: some View {
        if case .downloaded = downloadState {
            Button(language.text("打开安装包", "Open package")) {
                guard let release, let asset = store.result.preferredAsset else { return }
                downloader.openDownloadedPackage(release: release, asset: asset)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            Button(downloadButtonTitle) {
                guard let release, let asset = store.result.preferredAsset else { return }
                downloader.start(release: release, asset: asset, currentVersion: store.result.currentVersion)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(downloader.state.isBusy || availabilityError != nil)
        }
    }

    private var downloadButtonTitle: String {
        switch downloadState {
        case .failed, .cancelled: return language.text("重新下载", "Try again")
        case .preparing, .downloading, .verifying: return language.text("下载中…", "Downloading…")
        default: return language.text("下载更新", "Download update")
        }
    }

    private func localized(_ message: String) -> String {
        let parts = message.components(separatedBy: " / ")
        return parts.count == 2 ? language.text(parts[0], parts[1]) : message
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
