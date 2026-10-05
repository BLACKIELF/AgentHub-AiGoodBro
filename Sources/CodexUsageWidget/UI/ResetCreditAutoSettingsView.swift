import SwiftUI

/// Only edits explicit authorization. Opening this view never starts an attempt.
struct ResetCreditAutoSettingsView: View {
    let profiles: [CodexProfile]
    @Binding var preferences: CodexResetCreditAutoPreferences
    let status: String?
    let language: WidgetLanguage
    let isPreview: Bool
    var focusedProfileID: String? = nil
    var onDone: () -> Void = {}

    static func summary(profiles: [CodexProfile], preferences: CodexResetCreditAutoPreferences, language: WidgetLanguage) -> String {
        let count = profiles.filter {
            preferences.permits(profileID: $0.id, accountID: $0.lastSnapshot?.accountID ?? "")
        }.count
        return count == 0
            ? language.text("未开启", "Not enabled")
            : language.text("已开启 \(count) 个账号", "Enabled for \(count) accounts")
    }

    private var summary: String {
        Self.summary(profiles: profiles, preferences: preferences, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2).foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("重置卡到期自动使用", "Use reset cards before expiry"))
                        .font(.headline)
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(
                language.text(
                    "默认关闭，请逐个选择账号。应用须保持运行，仅空闲且身份核验通过时尝试使用即将过期的卡；结果不确定时暂停，需人工核对。",
                    "Off by default. Choose accounts individually and keep the app running. Expiring cards are used only when idle and identity is verified; uncertain results pause for manual review."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Stepper(value: $preferences.leadMinutes, in: 1...1440) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("到期前 \(preferences.leadMinutes) 分钟", "\(preferences.leadMinutes) minutes before expiry"))
                    Text(language.text("默认 30 分钟，可选 1–1440 分钟", "Default: 30 minutes · Range: 1–1440"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(isPreview)
            if let status, !status.isEmpty {
                Label(status, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(WorkspaceStatusForeground.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if profiles.isEmpty {
                            Text(language.text("添加并登录 Codex 账号后，可在这里逐个开启。", "Add and sign in to Codex accounts to enable them here."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(profiles) { profile in
                            accountRow(profile)
                                .padding(6)
                                .background(
                                    focusedProfileID == profile.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .id(profile.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .onAppear {
                    if let focusedProfileID { proxy.scrollTo(focusedProfileID, anchor: .center) }
                }
                .onChange(of: focusedProfileID) { value in
                    if let value { proxy.scrollTo(value, anchor: .center) }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button(language.text("全部关闭", "Turn all off")) {
                    guard !isPreview else { return }
                    preferences.authorizedAccounts.removeAll()
                }
                .disabled(isPreview || preferences.authorizedAccounts.isEmpty)
                .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Button(language.text("完成", "Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 480, maxWidth: 560, minHeight: 420, idealHeight: 580, maxHeight: 720)
        .environment(\.locale, language.locale)
        .accessibilityIdentifier("next.reset-credit-auto.settings")
    }

    private func isEnabled(_ profile: CodexProfile) -> Bool {
        preferences.permits(profileID: profile.id, accountID: profile.lastSnapshot?.accountID ?? "")
    }

    private func blockedReason(_ profile: CodexProfile) -> String? {
        if profile.isSystemProfile {
            return language.text("当前桌面账号需手动确认，不能自动使用。", "The current Desktop account requires manual confirmation.")
        }
        if let type = profile.lastSnapshot?.accountType, type.lowercased() != "chatgpt" {
            return language.text("此账号类型不支持重置卡；仅支持 ChatGPT 登录账号。", "This account type does not support reset cards; a ChatGPT sign-in is required.")
        }
        guard let account = profile.lastSnapshot?.accountID, !account.isEmpty else {
            return language.text("缺少已核验身份，请先登录并刷新额度。", "Verified identity is missing. Sign in and refresh limits first.")
        }
        guard let systemID = profiles.first(where: \.isSystemProfile)?.lastSnapshot?.accountID, !systemID.isEmpty else {
            return language.text("当前桌面身份尚未核验，请先刷新当前账号。", "The Desktop identity is not verified. Refresh the current account first.")
        }
        if account == systemID {
            return language.text("此账号是当前桌面身份的镜像，需手动确认。", "This account mirrors the current Desktop identity and requires manual confirmation.")
        }
        if profile.lastQuotaReadFailureAt != nil || profile.lastSnapshot?.quotaReadSucceeded != true {
            return language.text("额度读取失败或未完成，请刷新成功后再开启。", "The limits read failed or is incomplete. Refresh successfully before enabling.")
        }
        return nil
    }

    private func accountRow(_ profile: CodexProfile) -> some View {
        let enabled = isEnabled(profile)
        let reason = blockedReason(profile)
        let hasInactiveAuthorization = preferences.authorizedAccounts[profile.id] != nil && !enabled
        return VStack(alignment: .leading, spacing: 4) {
            if focusedProfileID == profile.id {
                Label(language.text("当前选择的账号", "Selected account"), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.primary)
            }
            Toggle(
                isOn: Binding(
                    get: { isEnabled(profile) },
                    set: { value in
                        guard !isPreview else { return }
                        if !value {
                            preferences.authorizedAccounts[profile.id] = nil
                        } else if blockedReason(profile) == nil, let account = profile.lastSnapshot?.accountID, !account.isEmpty {
                            preferences.authorizedAccounts[profile.id] = DispatchActivityStore.hash(account)
                        }
                    }
                )
            ) {
                Text(AccountDisplay.numberedName(profile, allProfiles: profiles))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isPreview || (!enabled && reason != nil))
            if let reason {
                Text(enabled ? language.text("已暂停 · ", "Paused · ") + reason : reason)
                    .font(.caption).foregroundStyle(WorkspaceStatusForeground.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasInactiveAuthorization {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(language.text("原身份授权已失效，当前身份未开启。", "The previous identity authorization is inactive; this identity is not enabled."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(language.text("清除", "Clear")) {
                        guard !isPreview else { return }
                        preferences.authorizedAccounts[profile.id] = nil
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .foregroundStyle(PaletteControlForeground()).disabled(isPreview)
                }
            }
        }
    }
}

/// Offscreen native fixtures: constant bindings, no store, defaults, or controller.
@MainActor
enum ResetCreditAutoSettingsPreviewFixture {
    static func render(to directory: URL) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func profile(_ id: String, name: String, account: String?, system: Bool = false, type: String = "chatgpt", failed: Bool = false) -> CodexProfile {
            CodexProfile(
                id: id, name: name, remark: name, codexHomePath: "/synthetic-reset-preview/\(id)", isSystemProfile: system, createdAt: now,
                lastSnapshot: CodexAccountSnapshot(
                    accountType: type, planType: "plus", email: nil, accountID: account,
                    limitId: "codex", limitName: "Codex", fiveHour: nil, sevenDay: nil, monthly: nil,
                    fetchedAt: now, appServerVersion: nil, quotaReadSucceeded: !failed),
                lastQuotaReadFailureAt: failed ? now : nil)
        }
        let profiles = [
            profile("desktop", name: "Desktop", account: "synthetic-desktop", system: true),
            profile("ready", name: "Codex 02", account: "synthetic-ready"),
            profile("mirror", name: "Codex 03", account: "synthetic-desktop"),
            profile("missing", name: "Codex 04", account: nil),
            profile("unsupported", name: "API", account: nil, type: "apiKey"),
            profile("failed", name: "Codex 06", account: "synthetic-failed", failed: true),
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let focusedPreview = VStack(alignment: .leading, spacing: 8) {
            ResetCardExpiryFactsView(
                count: 2, expiries: [now.addingTimeInterval(1800), now.addingTimeInterval(3600)],
                fetchedAt: now, readSucceeded: true, now: now, expiring: true,
                onOpenAutoSettings: {}
            )
            .font(.system(size: 10))
            .environment(\.widgetLanguage, WidgetLanguage.zh)
            .padding(.horizontal, 20)
            ResetCreditAutoSettingsView(
                profiles: profiles, preferences: .constant(.init()), status: nil, language: .zh,
                isPreview: true, focusedProfileID: "ready")
        }
        try WorkspacePreviewRenderer.renderView(
            focusedPreview, size: CGSize(width: 440, height: 650), scheme: .dark,
            to: directory.appendingPathComponent("zh-dark-account-entry-focused.png"))
        for language in WidgetLanguage.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for enabled in [false, true] {
                    var preferences = CodexResetCreditAutoPreferences()
                    if enabled { preferences.authorizedAccounts["ready"] = DispatchActivityStore.hash("synthetic-ready") }
                    let view = ResetCreditAutoSettingsView(
                        profiles: profiles, preferences: .constant(preferences), status: nil, language: language, isPreview: true)
                    let name = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(enabled ? "enabled" : "off").png"
                    try WorkspacePreviewRenderer.renderView(view, size: CGSize(width: 440, height: 620), scheme: scheme, to: directory.appendingPathComponent(name))
                }
            }
        }
    }
}
