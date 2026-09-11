import AppKit
import SwiftUI

struct LocalCLIWorkspaceView: View {
    @ObservedObject var model: LocalCLIAccountStore
    @ObservedObject var settings: AppSettings
    let kind: LocalCLIKind
    let language: WidgetLanguage
    var onlyProfileID: String? = nil
    var showsAccounts = true
    var embeddedLayout: AccountWorkspaceLayout? = nil
    var onOpenDetails: (() -> Void)? = nil
    @State private var editing: LocalCLIProfile?
    @State private var nameDraft = ""
    @State private var addingGrok = false
    @State private var newAccountName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if onlyProfileID == nil {
                HStack(spacing: 12) {
                    LocalCLIIcon(kind: kind).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.displayName).font(.title2.weight(.semibold))
                        Text(language.text("账号与额度", "Accounts and limits")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if kind == .grok {
                        Button {
                            newAccountName = language.text("Grok 账号 \(model.profiles(for: kind).count + 1)", "Grok account \(model.profiles(for: kind).count + 1)")
                            addingGrok = true
                        } label: {
                            Label(language.text("新增账号并登录", "Add account and sign in"), systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.signingIn.isEmpty)
                    }
                    if kind.supportsLinkedEnvironments {
                        Button {
                            linkAccount()
                        } label: {
                            Label(language.text("关联已有配置", "Link existing configuration"), systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text(workspaceSummary)
                    .font(.callout).foregroundStyle(.secondary)
            }
            if showsAccounts {
                ForEach(orderedWorkspaceProfiles) { profile in accountCard(profile) }
            }
            if onlyProfileID == nil, let message = model.message {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, onlyProfileID == nil ? 8 : 0)
        .sheet(isPresented: $addingGrok) {
            VStack(alignment: .leading, spacing: 16) {
                Text(language.text("添加 Grok 账号", "Add a Grok account")).font(.headline)
                Text(language.text("填写便于区分的名称，然后在官方浏览器页面完成登录。", "Choose a name, then complete sign-in in the official browser page."))
                    .font(.callout).foregroundStyle(.secondary)
                TextField(language.text("账号名称", "Account name"), text: $newAccountName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(language.text("取消", "Cancel")) { addingGrok = false }
                    Button(language.text("继续登录", "Continue to sign in")) {
                        if let profile = model.createGrokAccount(name: newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            addingGrok = false
                            model.signIn(profile)
                        }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(newAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(24).frame(width: 400)
        }
        .sheet(item: $editing) { profile in
            VStack(alignment: .leading, spacing: 16) {
                Text(language.text("账号名称", "Account name")).font(.headline)
                TextField(language.text("例如：工作账号", "For example: Work"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(language.text("取消", "Cancel")) { editing = nil }
                    Button(language.text("保存", "Save")) {
                        model.rename(profile, name: nameDraft)
                        editing = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 360)
        }
    }

    /// The same pin and expiry rule is used in a provider's own account view.
    private var orderedWorkspaceProfiles: [LocalCLIProfile] {
        let profiles = model.profiles(for: kind).filter { onlyProfileID == nil || $0.id == onlyProfileID }
        let now = Date()
        let expiring = Set(
            profiles.filter { profile in
                ResetCardPresentation.isExpiringSoon(
                    model.quotas[profile.id]?.resetCards,
                    now: now,
                    evidenceFresh: !model.stale.contains(profile.id) && ResetCardPresentation.isFresh(model.quotas[profile.id]?.fetchedAt, now: now))
            }.map(\.id))
        let pinned = profiles.first {
            ResetCardPresentation.localKey(kind: kind.rawValue, profileID: $0.id) == settings.pinnedAccountKey
        }?.id
        var byID: [String: LocalCLIProfile] = [:]
        for profile in profiles { byID[profile.id] = profile }
        return ResetCardPresentation.prioritizedOrder(profiles.map(\.id), expiring: expiring, pinnedAccountID: pinned)
            .compactMap { byID[$0] }
    }

    @ViewBuilder private func accountCard(_ profile: LocalCLIProfile) -> some View {
        if let layout = embeddedLayout {
            embeddedAccount(profile, layout: layout)
        } else {
            fullAccountCard(profile)
        }
    }

    private func embeddedAccount(_ profile: LocalCLIProfile, layout: AccountWorkspaceLayout) -> some View {
        let result = model.quotas[profile.id]
        let fresh = !model.stale.contains(profile.id) && ResetCardPresentation.isFresh(result?.fetchedAt, now: Date())
        let expiring = ResetCardPresentation.isExpiringSoon(result?.resetCards, now: Date(), evidenceFresh: fresh)
        let arrangement = layout == .cards ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return arrangement {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    LocalCLIIcon(kind: kind).frame(width: 20, height: 20)
                    Text(profile.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(kind.displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let plan = result?.planLabel { Text(plan).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if layout == .rows {
                    if kind == .grok, result?.resetCards == nil, let officialUsageURL {
                        grokResetLookupLink(destination: officialUsageURL)
                            .font(.caption2)
                    } else if kind == .grok, let summary = ResetCardPresentation.summaryText(result?.resetCards, now: Date(), timeZone: .current, language: language) {
                        Label(summary, systemImage: "creditcard").font(.caption2).foregroundStyle(expiring ? FixedVisualPalette.statusDanger : Color.secondary).lineLimit(2)
                    }
                    if expiring {
                        Text(ResetCardPresentation.expiringLabelText(language: language)).font(.caption2.weight(.semibold)).foregroundStyle(FixedVisualPalette.statusDanger)
                    }
                }
                if let result {
                    Text(fresh ? result.sourceLabel : language.text("上次快照 · 请刷新", "Previous snapshot · Refresh needed"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                modelAvailabilitySummary(for: profile)
            }.frame(minWidth: layout == .rows ? 170 : nil, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if let result, !result.windows.isEmpty {
                    if layout == .cards {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(result.windows.prefix(2)) { window in
                                embeddedQuotaWindow(window, layout: layout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        ForEach(result.windows.prefix(2)) { window in
                            embeddedQuotaWindow(window, layout: layout)
                        }
                    }
                } else if let balance = result?.balance {
                    Text(language.text("余额 ", "Balance ") + balance.formatted()).font(.callout.monospacedDigit())
                } else {
                    Text(statusText(result)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(width: layout == .rows ? 168 : nil)
            // Mirrors ProfileRow's Spacer: the quota block absorbs the row height
            // AccountCardGridLayout proposes so every card in a row shares one height
            // and footer controls share one baseline.
            // maxWidth 弹性仅限 cards；rows 必须保持 168 固定列，
            // 否则会与头部列分摊剩余宽度，额度列起点左移、与 ProfileRow 列不对齐。
            .frame(maxWidth: layout == .cards ? .infinity : nil, maxHeight: layout == .cards ? .infinity : nil, alignment: .topLeading)
            VStack(alignment: .leading, spacing: layout == .cards ? 5 : 6) {
                if layout == .cards { Divider().opacity(0.4) }
                if layout == .cards {
                    // Codex's compact execution-preference row occupies the
                    // first footer slot even when a local provider has no
                    // equivalent control. Keeping it empty preserves the
                    // first action baseline without changing functionality.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: AccountCardFooterSlots.preferenceRow)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    Button {
                        model.refresh(profile)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.refreshing.contains(profile.id)).help(language.text("刷新额度", "Refresh limits"))
                    if model.canOpen(profile) {
                        Button {
                            openNative(profile)
                        } label: {
                            Label("CLI", systemImage: "terminal").frame(maxWidth: .infinity)
                        }
                    }
                    Button(language.text("详情", "Details")) { onOpenDetails?() }
                    Menu {
                        let key = ResetCardPresentation.localKey(kind: kind.rawValue, profileID: profile.id)
                        Button(settings.pinnedAccountKey == key ? language.text("取消置顶", "Unpin") : language.text("固定第一位", "Pin first")) {
                            settings.pinnedAccountKey = settings.pinnedAccountKey == key ? nil : key
                        }
                        Button(language.text("重命名", "Rename")) {
                            nameDraft = profile.displayName
                            editing = profile
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).frame(width: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: layout == .cards ? AccountCardFooterSlots.firstActionRow : nil, alignment: .leading)
                if layout == .cards {
                    // Codex keeps dispatch participation in a secondary row;
                    // local cards do not have that control, but the slot stays
                    // present so provider cards share the same footer geometry.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: AccountCardFooterSlots.secondaryRow)
                        .accessibilityHidden(true)
                }
                if layout == .cards {
                    // Keep refresh progress beside the timestamp slot. This
                    // avoids moving the action baseline while the read runs,
                    // and the minimum still expands for real content.
                    HStack(spacing: 6) {
                        if model.refreshing.contains(profile.id) { ProgressView().controlSize(.small) }
                        if let date = result?.fetchedAt {
                            Text(date, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: AccountCardFooterSlots.timestamp, alignment: .leading)
                } else {
                    if model.refreshing.contains(profile.id) { ProgressView().controlSize(.small) }
                    if let date = result?.fetchedAt { Text(date, style: .time).font(.caption2).foregroundStyle(.secondary) }
                }
                if layout == .cards {
                    // 共同页脚槽位：镜像 ProfileRow 的 officialResetSummary 沉底区，
                    // 重置卡/到期警示信息保留但不占头部槽位. The minimum
                    // allows the parent's official-link/reset additions to grow.
                    Group {
                        if kind == .grok, result?.resetCards == nil, let officialUsageURL {
                            grokResetLookupLink(destination: officialUsageURL)
                                .font(.caption2)
                        } else if kind == .grok, let summary = ResetCardPresentation.summaryText(result?.resetCards, now: Date(), timeZone: .current, language: language) {
                            Label(summary, systemImage: "creditcard")
                                .font(.caption2)
                                .foregroundStyle(expiring ? FixedVisualPalette.statusDanger : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if expiring {
                            Text(ResetCardPresentation.expiringLabelText(language: language))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: AccountCardFooterSlots.resetSummary, alignment: .topLeading)
                }
            }
            .frame(width: layout == .rows ? 290 : nil)
            .frame(maxWidth: layout == .cards ? .infinity : nil, alignment: .leading)
        }
        .padding(.horizontal, layout == .cards ? 10 : 12)
        .padding(.vertical, 10)
        .cardBackground(cornerRadius: layout == .cards ? 14 : 12)
        .overlay {
            if expiring {
                RoundedRectangle(cornerRadius: layout == .cards ? 14 : 12)
                    .strokeBorder(FixedVisualPalette.statusDanger, lineWidth: 1.5).allowsHitTesting(false)
            }
        }
    }

    /// Same slot anatomy as ProfileRow.quotaWindow: label left, large percent on a
    /// shared first-text-baseline, track, then the reset date as the caption line.
    private func embeddedQuotaWindow(_ window: LocalCLIQuotaWindow, layout: AccountWorkspaceLayout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(QuotaAvailabilityPresentation.percentText(100 - window.usedPercent))
                    .font(layout == .cards ? .system(size: 23, weight: .semibold, design: .rounded).monospacedDigit() : .subheadline.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: layout == .cards ? 28 : nil, alignment: .bottom)
            }
            QuotaProgressTrack(percent: 100 - window.usedPercent)
            if let date = window.resetsAt {
                Text(language.dateTime(date)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func fullAccountCard(_ profile: LocalCLIProfile) -> some View {
        let result = model.quotas[profile.id]
        let isStale = model.stale.contains(profile.id) || !ResetCardPresentation.isFresh(result?.fetchedAt, now: Date())
        let expiringSoon = ResetCardPresentation.isExpiringSoon(
            result?.resetCards,
            now: Date(),
            evidenceFresh: !isStale)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                LocalCLIIcon(kind: kind).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(profile.displayName).font(.headline).lineLimit(2)
                        if profile.isDefault {
                            Text(language.text("默认环境", "Default")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let identity = result?.maskedIdentity { Text(identity).font(.caption).foregroundStyle(.secondary) }
                    if let plan = result?.planLabel { Text(plan).font(.caption).foregroundStyle(.secondary) }
                    modelAvailabilitySummary(for: profile)
                }
                Spacer()
                if model.refreshing.contains(profile.id) { ProgressView().controlSize(.small) }
                Button {
                    model.refresh(profile)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(language.text("刷新账号与额度", "Refresh account and limits"))
                .accessibilityLabel(language.text("刷新账号与额度", "Refresh account and limits"))
                .disabled(model.refreshing.contains(profile.id))
                Menu {
                    let key = ResetCardPresentation.localKey(kind: kind.rawValue, profileID: profile.id)
                    Button(settings.pinnedAccountKey == key ? language.text("取消置顶", "Unpin") : language.text("固定第一位", "Pin first")) {
                        settings.pinnedAccountKey = settings.pinnedAccountKey == key ? nil : key
                    }
                    Button(language.text("重命名", "Rename")) {
                        nameDraft = profile.displayName
                        editing = profile
                    }
                    if !profile.isDefault {
                        Button(language.text("取消关联", "Unlink")) { model.unlink(profile) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }.menuStyle(.borderlessButton).frame(width: 20)
            }
            if model.canSignIn(profile) || model.canOpen(profile) {
                HStack(spacing: 12) {
                    if model.canSignIn(profile) {
                        Button {
                            model.signIn(profile)
                        } label: {
                            Label(signInTitle(result), systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.signingIn.isEmpty)
                    }
                    if model.canOpen(profile) {
                        Button {
                            openNative(profile)
                        } label: {
                            Label(openTitle, systemImage: profile.kind == .trae ? "macwindow" : "terminal")
                        }.buttonStyle(.bordered).disabled(model.signingIn.contains(profile.id))
                    }
                    if model.signingIn.contains(profile.id) { ProgressView().controlSize(.small) }
                }
                if let message = model.loginMessages[profile.id] {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } else if profile.kind == .zcode, !profile.isDefault {
                Label(
                    language.text(
                        "此链接环境仅用于额度读取；隔离启动尚未验证，不会借用默认 ZCode 身份。",
                        "This linked environment is quota-only. Isolated launch is not verified and will not borrow the default ZCode identity."),
                    systemImage: "lock.shield"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let result, !result.windows.isEmpty {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(result.windows.prefix(4)) { window in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(window.label).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int((100 - window.usedPercent).rounded()))%")
                                    .font(.system(.headline, design: .rounded).monospacedDigit())
                            }
                            ProgressView(value: 100 - window.usedPercent, total: 100)
                                .tint(isStale ? .secondary : .accentColor)
                            if let reset = window.resetsAt {
                                Text(reset, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }
                Text(language.text("剩余额度", "Remaining limits")).font(.caption2).foregroundStyle(.secondary)
            } else if result?.balance == nil {
                Label(statusText(result), systemImage: "gauge.with.dots.needle.33percent")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if kind == .grok, result?.resetCards == nil, let officialUsageURL {
                grokResetLookupLink(destination: officialUsageURL)
                    .font(.caption)
            } else if kind == .grok,
                let summary = ResetCardPresentation.summaryText(
                    result?.resetCards, now: Date(), timeZone: TimeZone.current, language: language)
            {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard")
                    Text(summary)
                    if expiringSoon {
                        Text(ResetCardPresentation.expiringLabelText(language: language))
                            .fontWeight(.semibold)
                            .foregroundStyle(FixedVisualPalette.statusDanger)
                    }
                }
                .font(.caption)
                .foregroundStyle(expiringSoon ? Color.primary : Color.secondary)
            }
            if let result, result.windows.count > 4 {
                DisclosureGroup(language.text("更多额度（\(result.windows.count - 4)）", "More limits (\(result.windows.count - 4))")) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(result.windows.dropFirst(4))) { window in
                                HStack {
                                    Text(window.label).lineLimit(2)
                                    Spacer()
                                    Text("\(Int((100 - window.usedPercent).rounded()))%")
                                        .monospacedDigit()
                                    if let reset = window.resetsAt {
                                        Text(reset, style: .relative).foregroundStyle(.secondary)
                                    }
                                }.font(.caption)
                            }
                        }.padding(.top, 6)
                    }.frame(height: min(CGFloat(result.windows.count - 4) * 44 + 8, 180))
                }.font(.caption)
            }
            if result?.state == .unsupported, let officialUsageURL {
                Link(language.text("打开官方用量页", "Open official usage page"), destination: officialUsageURL)
                    .font(.caption)
            }
            if let balance = result?.balance {
                HStack {
                    Text(language.text("余额", "Balance")).foregroundStyle(.secondary)
                    Text(balance, format: .number.precision(.fractionLength(0...4)))
                    if let currency = result?.balanceCurrency { Text(currency).foregroundStyle(.secondary) }
                }.font(.callout)
            }
            if let result {
                HStack(spacing: 6) {
                    if isStale {
                        Image(systemName: "clock.badge.exclamationmark")
                        Text(
                            model.stale.contains(profile.id)
                                ? language.text("刷新失败 · 上次快照", "Refresh failed · Previous snapshot")
                                : language.text("上次快照 · 请刷新", "Previous snapshot · Refresh needed"))
                    } else {
                        Text(result.sourceLabel)
                    }
                    Spacer()
                    Text(result.fetchedAt, style: .time)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if model.sharesQuota(profile) {
                Label(language.text("与另一关联账号共用额度", "Shares limits with another linked account"), systemImage: "link")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .sectionBackground()
        .overlay(
            expiringSoon
                ? RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(FixedVisualPalette.statusDanger, lineWidth: 2)
                    .allowsHitTesting(false)
                : nil
        )
    }

    private func statusText(_ result: LocalCLIQuotaResult?) -> String {
        guard let result else { return language.text("点击刷新，读取已登录账号的额度", "Refresh to read limits for the signed-in account") }
        switch result.state {
        case .available:
            return language.text(
                "当前额度配置已验证 · 官方接口暂未返回用量百分比",
                "The current quota configuration was verified, but the official endpoint returned no usage percentage.")
        case .needsLogin: return language.text("请先在对应 CLI 中完成登录", "Sign in using this CLI first")
        case .unsupported:
            if result.messageCode == "local_cli_opencode_go_not_connected" {
                return language.text(
                    "未连接 OpenCode Go 额度；其他服务商登录状态不受此结论影响",
                    "OpenCode Go quota is not connected. This does not describe other provider sign-ins.")
            }
            return language.text("该账号的额度接口暂未接通", "The quota interface for this account is not available yet")
        case .rateLimited: return language.text("服务商暂时限流，请稍后刷新", "The provider is rate limiting requests. Refresh later")
        case .unavailable: return language.text("暂未读到额度，请稍后刷新", "Limits could not be read. Refresh later")
        }
    }

    private func modelAvailabilitySummary(for profile: LocalCLIProfile) -> some View {
        LocalCLIModelAvailabilityView(
            snapshot: LocalCLIModelAvailabilityStore.load(
                root: URL(fileURLWithPath: profile.configDirectory, isDirectory: true),
                now: Date()
            ),
            language: language,
            provider: kind,
            initiallyExpanded: false,
            compactLabel: true
        )
        .font(.caption2)
    }

    private func grokResetLookupLink(destination: URL) -> some View {
        Link(destination: destination) {
            Label(language.text("在官网查看重置卡", "View reset cards on the official site"), systemImage: "arrow.up.right.square")
        }
        .help(language.text("在 Grok 官网核对对应账号的可用重置和到期时间。", "Check available resets and expiry for the matching account on Grok."))
    }

    private var officialUsageURL: URL? {
        switch kind {
        case .grok: return URL(string: "https://grok.com/?_s=usage")
        case .mimo: return URL(string: "https://platform.xiaomimimo.com/token-plan")
        case .zcode: return URL(string: "https://zcode.z.ai")
        default: return nil
        }
    }

    private func linkAccount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = kind.defaultConfigDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
        panel.title = language.text("选择已登录账号的 CLI 配置目录", "Choose a signed-in CLI configuration directory")
        panel.message = language.text("请选择已登录 CLI 的配置文件夹，无需查找应用。", "Select the signed-in CLI configuration folder. You do not need to find an application.")
        panel.prompt = language.text("关联", "Link")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let count = model.profiles(for: kind).count + 1
        model.link(kind: kind, directory: directory, name: language.text("账号 \(count)", "Account \(count)"))
    }

    private func openNative(_ profile: LocalCLIProfile) {
        if profile.kind == .trae {
            model.openCLI(
                profile,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = language.text(
            "选择 \(profile.kind.displayName) 的工作文件夹",
            "Choose a working folder for \(profile.kind.displayName)")
        panel.prompt = language.text("打开 CLI", "Open CLI")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        model.openCLI(profile, workingDirectory: directory)
    }

    private var workspaceSummary: String {
        switch kind {
        case .grok:
            language.text(
                "本机登录会自动显示。新增账号会打开 Grok 官方 OAuth，每个账号使用独立环境。",
                "The local sign-in appears automatically. Add an account to open official Grok OAuth in its own environment.")
        case .openCode:
            language.text(
                "登录与启动使用官方 opencode，并按 XDG 数据目录隔离。模型需在 CLI 中按“服务商/模型”选择；OpenCode Go 只代表其中一种额度。",
                "Sign-in and launch use the official opencode with isolated XDG data. Choose models as provider/model in the CLI; OpenCode Go is only one quota source.")
        case .workBuddy:
            language.text(
                "使用 WorkBuddy 内置 CLI。打开后选择账号可用的模型。",
                "Uses WorkBuddy's bundled CLI. Choose an available model after opening it.")
        case .zcode:
            language.text(
                "默认环境可打开官方 ZCode 登录与 TUI。链接环境仅展示额度；CLI 与桌面模型配置彼此独立，登录成功不等于指定模型可用。",
                "The default environment can open official ZCode sign-in and TUI. Linked environments are quota-only. CLI and desktop model settings are separate, and sign-in does not prove a requested model is available."
            )
        case .trae:
            language.text(
                "仅打开已安装的 TRAE SOLO 个人版桌面。独立 traecli 属于企业产品，本页不把它显示为个人版登录、执行或额度能力。",
                "Only the installed TRAE SOLO personal desktop is opened. Standalone traecli is an enterprise product and is not presented here as personal sign-in, execution, or quota support."
            )
        case .claudeCode, .kimi, .mimo, .gemini:
            language.text(
                "本机登录会自动显示；已有其他独立环境时，可关联该 CLI 的配置目录。",
                "The local sign-in appears automatically. Link a CLI configuration directory for another existing environment.")
        }
    }

    private func signInTitle(_ result: LocalCLIQuotaResult?) -> String {
        if result?.state == .available {
            return language.text("重新登录", "Sign in again")
        }
        return language.text("登录 \(kind.displayName)", "Sign in to \(kind.displayName)")
    }

    private var openTitle: String {
        kind == .trae
            ? language.text("打开 TRAE SOLO", "Open TRAE SOLO")
            : language.text("打开 \(kind.displayName) CLI", "Open \(kind.displayName) CLI")
    }
}

/// Small monochrome marks designed for the CLI selector; text supplies the name.
///
/// Visual-weight contract: every mark is constrained to one shared content box
/// (size * 0.78) so rendered bounds match at any frame size. SF Symbols use
/// resizable + scaledToFit inside that box (brand aspect ratio preserved);
/// text glyphs are sized so cap height ≈ the content box (~1.05× size), so
/// letters never render smaller than symbol marks.
struct LocalCLIIcon: View {
    let kind: LocalCLIKind
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let box = size * 0.78
            ZStack {
                switch kind {
                case .claudeCode:
                    ForEach(0..<12) { index in
                        Capsule().frame(width: size * 0.088, height: box)
                            .rotationEffect(.degrees(Double(index) * 15))
                    }
                case .grok:
                    Circle().trim(from: 0.08, to: 0.86).stroke(lineWidth: size * 0.10)
                        .padding(size * 0.11).rotationEffect(.degrees(-30))
                    Capsule().frame(width: size * 0.10, height: size * 1.04).rotationEffect(.degrees(39))
                case .openCode:
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .resizable().scaledToFit()
                        .frame(width: box, height: box)
                case .trae:
                    Text("T").font(.system(size: size * 1.05, weight: .black, design: .rounded))
                case .workBuddy:
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .resizable().scaledToFit()
                        .frame(width: box, height: box)
                case .kimi: Text("K").font(.system(size: size * 1.05, weight: .black, design: .rounded))
                case .mimo:
                    RoundedRectangle(cornerRadius: size * 0.24).stroke(lineWidth: size * 0.085).padding(size * 0.11)
                    Text("mi").font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                case .zcode: Text("Z").font(.system(size: size * 1.05, weight: .black, design: .monospaced))
                case .gemini:
                    Image(systemName: "sparkle")
                        .resizable().scaledToFit()
                        .frame(width: box, height: box)
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.accessibilityHidden(true)
    }
}
