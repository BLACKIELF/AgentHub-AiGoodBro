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
    @State private var showsCustomLead = false
    @State private var customLeadDraft = ""

    static func summary(profiles: [CodexProfile], preferences: CodexResetCreditAutoPreferences, language: WidgetLanguage) -> String {
        let count = Set(
            profiles.compactMap { profile -> String? in
                guard let account = profile.lastSnapshot?.accountID,
                    preferences.permits(profileID: profile.id, accountID: account)
                else { return nil }
                return account
            }
        ).count
        return count == 0
            ? language.text("未开启", "Not enabled")
            : language.text("已开启 \(count) 个账号", count == 1 ? "1 account enabled" : "\(count) accounts enabled")
    }

    private var summary: String {
        Self.summary(profiles: profiles, preferences: preferences, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.blue)
                    .frame(width: 42, height: 42)
                    .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                Text(language.text("到期自动使用", "Use before expiry"))
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                preferences.automaticallyEnrollNewAccounts
                    ? language.text(
                        "新账号默认开启，身份与额度核验成功后生效；保留旧账号的关闭选择。应用须保持运行，仅空闲时尝试；结果不确定时暂停并提示核对。",
                        "New accounts default on after identity and limits verification. Existing off choices are kept. Keep the app running; only idle accounts are eligible, and uncertain results pause for review."
                    )
                    : language.text(
                        "保存的自动设置无法安全读取，默认开启已暂停。请逐个核对并选择账号；身份、额度及空闲检查仍须通过。",
                        "Saved automation settings could not be safely read, so default enrollment is paused. Review and select accounts individually; identity, limits and idle checks still apply."
                    )
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("提前使用时间", "Redeem before expiry"))
                        .font(.system(size: 13, weight: .medium))
                    Text(language.text("默认 30 分钟 · 所有已开启账号共用", "Default: 30 min · Shared by enabled accounts"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(CodexResetCreditAutoPreferences.leadPresets, id: \.self) { minutes in
                        Button {
                            preferences.leadMinutes = minutes
                            showsCustomLead = false
                        } label: {
                            if minutes == preferences.leadMinutes {
                                Label(leadTitle(minutes), systemImage: "checkmark")
                            } else {
                                Text(leadTitle(minutes))
                            }
                        }
                    }
                    Divider()
                    Button(language.text("自定义…", "Custom…")) {
                        customLeadDraft = String(preferences.leadMinutes)
                        showsCustomLead = true
                    }
                } label: {
                    Text(leadTitle(preferences.leadMinutes))
                        .monospacedDigit()
                }
                .fixedSize()
                .disabled(isPreview)
                .accessibilityLabel(language.text("到期前使用的分钟数", "Minutes before expiry"))
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            if showsCustomLead {
                let minutes = Int(customLeadDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                HStack {
                    TextField(language.text("分钟（3–1440）", "Minutes (3–1440)"), text: $customLeadDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(language.text("应用", "Apply")) {
                        guard let minutes, CodexResetCreditAutoPreferences.customLeadRange.contains(minutes) else { return }
                        preferences.leadMinutes = minutes
                        showsCustomLead = false
                    }
                    .disabled(minutes.map(CodexResetCreditAutoPreferences.customLeadRange.contains) != true)
                    Button(language.text("取消", "Cancel")) { showsCustomLead = false }
                }
                .disabled(isPreview)
            }
            if let status, !status.isEmpty {
                Label(status, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(WorkspaceStatusForeground.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text("选择账号", "Choose accounts"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if profiles.isEmpty {
                                Text(language.text("添加并登录 Codex 账号后，可在这里逐个开启。", "Add and sign in to Codex accounts to enable them here."))
                                    .font(.caption).foregroundStyle(.secondary).padding(12)
                            }
                            ForEach(profiles) { profile in
                                accountRow(profile)
                                    .padding(12)
                                    .background(
                                        focusedProfileID == profile.id ? Color.accentColor.opacity(0.08) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(focusedProfileID == profile.id ? Color.accentColor.opacity(0.20) : Color.clear, lineWidth: 1)
                                    }
                                    .id(profile.id)
                                if profile.id != profiles.last?.id {
                                    Divider().padding(.horizontal, 12)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(3)
                    }
                    .onAppear {
                        if let focusedProfileID { proxy.scrollTo(focusedProfileID, anchor: .center) }
                    }
                    .onChange(of: focusedProfileID) { value in
                        if let value { proxy.scrollTo(value, anchor: .center) }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button(language.text("全部关闭", "Turn all off")) {
                    guard !isPreview else { return }
                    preferences.disableAll(profileIDs: Set(profiles.map(\.id)))
                }
                .disabled(isPreview || (preferences.authorizedAccounts.isEmpty && !profiles.contains(where: isSelected)))
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(language.text("完成", "Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(24)
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 560, minHeight: 440, idealHeight: 600, maxHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, language.locale)
        .accessibilityIdentifier("next.reset-credit-auto.settings")
    }

    private func leadTitle(_ minutes: Int) -> String {
        if minutes >= 60 && minutes.isMultiple(of: 60) {
            return language.text("\(minutes / 60) 小时", "\(minutes / 60) h")
        }
        return language.text("\(minutes) 分钟", "\(minutes) min")
    }

    private func isEnabled(_ profile: CodexProfile) -> Bool {
        preferences.permits(profileID: profile.id, accountID: profile.lastSnapshot?.accountID ?? "")
    }

    private func isSelected(_ profile: CodexProfile) -> Bool {
        isEnabled(profile)
            || (preferences.shouldEnroll(profileID: profile.id)
                && (profile.lastSnapshot?.accountType == nil || profile.lastSnapshot?.accountType?.lowercased() == "chatgpt"))
    }

    private func blockedReason(_ profile: CodexProfile) -> String? {
        if let type = profile.lastSnapshot?.accountType, type.lowercased() != "chatgpt" {
            return language.text("此账号类型不支持重置卡；仅支持 ChatGPT 登录账号。", "This account type does not support reset cards; a ChatGPT sign-in is required.")
        }
        guard let account = profile.lastSnapshot?.accountID, !account.isEmpty else {
            return language.text("缺少已核验身份，请先登录并刷新额度。", "Verified identity is missing. Sign in and refresh limits first.")
        }
        guard profiles.first(where: \.isSystemProfile)?.lastSnapshot?.accountID?.isEmpty == false else {
            return language.text("当前桌面身份尚未核验，请先刷新当前账号。", "The Desktop identity is not verified. Refresh the current account first.")
        }
        if profile.lastQuotaReadFailureAt != nil || profile.lastSnapshot?.quotaReadSucceeded != true {
            return language.text("额度读取失败或未完成，请刷新成功后再开启。", "The limits read failed or is incomplete. Refresh successfully before enabling.")
        }
        if profile.isSystemProfile {
            let desktopHome = profile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
            let hasIndependentMirror = profiles.contains {
                !$0.isSystemProfile && $0.lastSnapshot?.accountID == account
                    && $0.lastSnapshot?.quotaReadSucceeded == true && $0.lastQuotaReadFailureAt == nil
                    && $0.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL != desktopHome
            }
            if !hasIndependentMirror {
                return language.text(
                    "需同账号的独立凭据入口，请先添加该账号并成功刷新额度。",
                    "An independent sign-in for this account is required. Add it and refresh limits successfully first.")
            }
        }
        return nil
    }

    private func expiryStatus(_ profile: CodexProfile, now: Date) -> String {
        let snapshot = profile.lastSnapshot
        let dates = snapshot?.resetCreditExpiries ?? []
        guard let expiry = ResetCardPresentation.orderedExpiries(dates, now: now).first,
            expiry > now
        else {
            if snapshot?.availableResetCredits == 0, dates.isEmpty {
                return language.text("当前记录无可用重置卡", "No available cards in the current record")
            }
            return language.text("当前记录没有未来的卡片到期时间", "No future card expiry in the current record")
        }
        let time = ResetCardPresentation.expiryText(expiry, timeZone: .current, language: language)
        let expiryText = language.text("记录最早到期：\(time)", "Earliest recorded expiry: \(time)")
        let window =
            preferences.isWithinExpiryWindow(expiry, now: now)
            ? language.text("已进入临期窗口 · 执行前仍需核验", "In the expiry window · verification required before use")
            : language.text("尚未进入临期窗口", "Outside the expiry window")
        return expiryText + " · " + window
    }

    private func accountRow(_ profile: CodexProfile) -> some View {
        let enabled = isSelected(profile)
        let authorized = isEnabled(profile)
        let reason = blockedReason(profile)
        let hasInactiveAuthorization = preferences.authorizedAccounts[profile.id] != nil && !authorized
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(
                isOn: Binding(
                    get: { isSelected(profile) },
                    set: { value in
                        guard !isPreview else { return }
                        if !value {
                            preferences.setEnabled(false, profileID: profile.id)
                        } else if blockedReason(profile) == nil, let account = profile.lastSnapshot?.accountID, !account.isEmpty {
                            preferences.setEnabled(true, profileID: profile.id, accountID: account)
                        }
                    }
                )
            ) {
                HStack(spacing: 8) {
                    Text(AccountDisplay.numberedName(profile, allProfiles: profiles))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if focusedProfileID == profile.id {
                        Text(language.text("当前查看", "Viewing"))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                            .fixedSize()
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isPreview || (!enabled && reason != nil))
            if enabled && !authorized {
                Text(language.text("默认开启待核验，尚不会使用重置卡。", "Default on, awaiting verification. Reset cards will not be used yet."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let account = profile.lastSnapshot?.accountID,
                profiles.contains(where: { $0.id != profile.id && $0.lastSnapshot?.accountID == account })
            {
                Text(
                    language.text(
                        "同账号各入口共用卡池，只使用一次；每个开关独立授权。",
                        "Entries for this account share one card pool and redeem once; each switch is authorized separately.")
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let reason {
                Text(enabled ? language.text("已暂停 · ", "Paused · ") + reason : reason)
                    .font(.system(size: 11))
                    .foregroundStyle(enabled ? AnyShapeStyle(WorkspaceStatusForeground.warning) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if authorized && reason == nil {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(expiryStatus(profile, now: context.date))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if hasInactiveAuthorization {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(language.text("原身份授权已失效，当前身份未开启。", "The previous identity authorization is inactive; this identity is not enabled."))
                        .font(.system(size: 11)).foregroundStyle(WorkspaceStatusForeground.warning)
                    Button(language.text("清除", "Clear")) {
                        guard !isPreview else { return }
                        preferences.setEnabled(false, profileID: profile.id)
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
            focusedPreview, size: CGSize(width: 500, height: 640), scheme: .dark,
            to: directory.appendingPathComponent("zh-dark-account-entry-focused.png"))
        for language in WidgetLanguage.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for enabled in [false, true] {
                    var preferences = CodexResetCreditAutoPreferences()
                    preferences.disableAll(profileIDs: Set(profiles.map(\.id)))
                    if enabled { preferences.setEnabled(true, profileID: "ready", accountID: "synthetic-ready") }
                    let view = ResetCreditAutoSettingsView(
                        profiles: profiles, preferences: .constant(preferences), status: nil, language: language, isPreview: true)
                    let name = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(enabled ? "enabled" : "off").png"
                    try WorkspacePreviewRenderer.renderView(view, size: CGSize(width: 500, height: 600), scheme: scheme, to: directory.appendingPathComponent(name))
                }
                for scenario in ["desktop-only", "mirror-only", "shared-pool", "desktop-missing-entry", "desktop-running"] {
                    var preferences = CodexResetCreditAutoPreferences()
                    preferences.disableAll(profileIDs: Set(profiles.map(\.id)))
                    if scenario != "mirror-only" {
                        preferences.setEnabled(true, profileID: "desktop", accountID: "synthetic-desktop")
                    }
                    if scenario == "mirror-only" || scenario == "shared-pool" {
                        preferences.setEnabled(true, profileID: "mirror", accountID: "synthetic-desktop")
                    }
                    let shownProfiles = scenario == "desktop-missing-entry" ? profiles.filter { $0.id != "mirror" } : profiles
                    let status =
                        scenario == "desktop-running"
                        ? "Desktop · 自动使用已暂停：当前桌面任务正在运行或空闲状态尚未核实。" : nil
                    let view = ResetCreditAutoSettingsView(
                        profiles: shownProfiles, preferences: .constant(preferences), status: status, language: language,
                        isPreview: true, focusedProfileID: scenario == "mirror-only" ? "mirror" : "desktop")
                    let name = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(scenario).png"
                    try WorkspacePreviewRenderer.renderView(view, size: CGSize(width: 500, height: 600), scheme: scheme, to: directory.appendingPathComponent(name))
                }
            }
        }
    }
}
