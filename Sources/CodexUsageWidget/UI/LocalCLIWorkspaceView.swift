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
    var onOpenSetup: (() -> Void)? = nil
    @Environment(\.accountCardDensity) private var cardDensity
    @State private var preparationProfile: LocalCLIProfile?
    @State private var editing: LocalCLIProfile?
    @State private var nameDraft = ""
    @State private var nameSaveFailed = false
    @State private var addingGrok = false
    @State private var newAccountName = ""
    @State private var avatarEditor: AccountAvatarTarget?

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
                    AccountCardDensityPicker()
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
                DisclosureGroup(language.text("平台说明", "Provider details")) { Text(workspaceSummary) }
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
        .onAppear { model.checkLocalSignIns() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkLocalSignIns()
        }
        .sheet(item: $preparationProfile) { profile in
            let state = readiness(profile)
            VStack(alignment: .leading, spacing: 16) {
                Label(state.title(language), systemImage: state.symbol).font(.headline)
                Text(state.detail(language)).fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text(
                        "配套调用还需 Python 3.9+、匹配版本的 Skill 和可读能力报告。点击“准备依赖与 Skill”检查安装；能力报告仍需在实际调用前核对。",
                        "Companion dispatch also needs Python 3.9+, a matching Skill and a readable capability report. Use Tools & Skill setup to check installation. The capability report must still be checked before dispatch."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let onOpenSetup {
                        Button(language.text("准备依赖与 Skill", "Tools & Skill setup")) {
                            preparationProfile = nil
                            onOpenSetup()
                        }
                    }
                    if state == .needsLogin, model.canSignIn(profile) {
                        Button(language.text("登录", "Sign in")) {
                            model.signIn(profile)
                            preparationProfile = nil
                        }
                    }
                    Spacer()
                    Button(language.text("知道了", "Done")) { preparationProfile = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 420)
        }
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
        .sheet(item: $avatarEditor) { target in
            AccountAvatarEditor(
                target: target, language: language,
                initial: settings.accountAvatars.record(for: target.profileID),
                existingImage: settings.avatarImage(for: target.profileID),
                store: settings.avatarAssetStore,
                onSave: { record, _ in
                    settings.setAvatar(record, for: target.profileID)
                    avatarEditor = nil
                },
                onCancel: { avatarEditor = nil }
            )
        }
        .sheet(item: $editing) { profile in
            VStack(alignment: .leading, spacing: 16) {
                Text(language.text("账号名称", "Account name")).font(.headline)
                TextField(language.text("例如：工作账号", "For example: Work"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                if nameSaveFailed {
                    Text(model.message ?? language.text("名称未保存，请重试。", "Name was not saved. Try again."))
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button(language.text("取消", "Cancel")) { editing = nil }
                    Button(language.text("保存", "Save")) {
                        if model.rename(profile, name: nameDraft) { editing = nil } else { nameSaveFailed = true }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 360).onAppear { nameSaveFailed = false }
        }
    }

    /// Keep the saved order across refreshes, with only explicit pins first.
    private var orderedWorkspaceProfiles: [LocalCLIProfile] {
        let profiles = model.profiles(for: kind).filter { onlyProfileID == nil || $0.id == onlyProfileID }
        let pinned = profiles.first {
            ResetCardPresentation.localKey(kind: kind.rawValue, profileID: $0.id) == settings.pinnedAccountKey
        }?.id
        var byID: [String: LocalCLIProfile] = [:]
        for profile in profiles { byID[profile.id] = profile }
        return ResetCardPresentation.savedOrder(profiles.map(\.id), pinnedAccountID: pinned)
            .compactMap { byID[$0] }
    }

    private func profileAvatar(_ profile: LocalCLIProfile, slot: ProviderIconSlot) -> some View {
        let providerID = AgentNavCatalog.workspaceProviders.first(where: { $0.localKind == kind })?.id ?? kind.rawValue
        let target = AccountAvatarTarget(profileID: profile.id, providerID: providerID, displayName: profile.displayName)
        return AccountProfileAvatarView(settings: settings, target: target, slot: slot, onEdit: { avatarEditor = $0 })
    }

    private func moreMenuRequest(for profile: LocalCLIProfile, includeUnlink: Bool = false) -> AnchoredMenuRequest {
        var actions = [
            AnchoredMenuAction(id: "refresh", title: language.text("刷新额度", "Refresh limits")),
            AnchoredMenuAction(id: "prepare", title: language.text("调用准备", "Call preparation")),
            AnchoredMenuAction(
                id: "pin",
                title: settings.pinnedAccountKey == ResetCardPresentation.localKey(kind: kind.rawValue, profileID: profile.id)
                    ? language.text("取消置顶", "Unpin")
                    : language.text("固定第一位", "Pin first")
            ),
            AnchoredMenuAction(id: "rename", title: language.text("重命名", "Rename")),
        ]
        if model.canSignIn(profile) {
            actions.insert(
                AnchoredMenuAction(id: "signin", title: profile.kind == .openCode ? language.text("添加或更新服务商", "Add or update provider") : language.text("登录", "Sign in")), at: 1)
        }
        if includeUnlink {
            actions.append(AnchoredMenuAction(id: "unlink", title: language.text("取消关联", "Unlink"), destructive: true))
        }
        return AnchoredMenuRequest(ownerID: profile.id, actions: actions)
    }

    private func handleMoreMenu(_ actionID: String, profile: LocalCLIProfile) {
        switch actionID {
        case "refresh": model.refresh(profile)
        case "signin": model.signIn(profile, updateProvider: profile.kind == .openCode)
        case "prepare": preparationProfile = profile
        case "pin":
            let key = ResetCardPresentation.localKey(kind: kind.rawValue, profileID: profile.id)
            settings.pinnedAccountKey = settings.pinnedAccountKey == key ? nil : key
        case "rename":
            nameDraft = profile.displayName
            editing = profile
        case "unlink": model.unlink(profile)
        default: break
        }
    }

    @ViewBuilder private func accountCard(_ profile: LocalCLIProfile) -> some View {
        if let layout = embeddedLayout {
            embeddedAccount(profile, layout: layout)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                embeddedAccount(profile, layout: .rows)
                DisclosureGroup(language.text("更多账号信息", "More account information")) {
                    fullAccountCard(profile)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func embeddedAccount(_ profile: LocalCLIProfile, layout: AccountWorkspaceLayout) -> some View {
        let state = readiness(profile)
        let result = model.quotas[profile.id]
        let fresh = !model.stale.contains(profile.id) && ResetCardPresentation.isFresh(result?.fetchedAt, now: Date())
        let expiring = ResetCardPresentation.isExpiringSoon(result?.resetCards, now: Date(), evidenceFresh: fresh)
        let arrangement = layout == .cards ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return arrangement {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    profileAvatar(profile, slot: layout == .cards ? .card : .list)
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
            }.frame(minWidth: layout == .rows ? 170 : nil, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if model.hasConfiguredAuthentication(profile) {
                    Label(model.authenticationTitle(profile), systemImage: "checkmark.circle")
                        .font(.caption.weight(.medium)).foregroundStyle(.green)
                }
                Label(state.title(language), systemImage: state.symbol)
                    .font(.caption.weight(.medium)).foregroundStyle(state.color)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Text(language.text("周期额度与重置时间：暂不可确认", "Periodic limits and reset time: unavailable"))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(language.text("已用 / 剩余 / 重置时间：暂不可确认", "Used / remaining / reset time: unavailable"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: layout == .rows ? 168 : nil)
            .frame(maxWidth: layout == .cards ? .infinity : nil, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 10) {
                if layout == .cards { Divider() }
                HStack(spacing: 6) {
                    primaryAction(profile)
                    Button(language.text("详情", "Details")) {
                        if let onOpenDetails { onOpenDetails() } else { preparationProfile = profile }
                    }
                    AnchoredActionMenu(
                        request: moreMenuRequest(for: profile),
                        language: language,
                        onSelect: { handleMoreMenu($0, profile: profile) }
                    )
                    .frame(width: 28, height: 22)
                    .id(profile.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                DisclosureGroup(language.text("模型与来源", "Models & source")) {
                    VStack(alignment: .leading, spacing: 10) {
                        modelAvailabilitySummary(for: profile)
                        Button {
                            preparationProfile = profile
                        } label: {
                            Label(language.text("调用准备", "Call preparation"), systemImage: "checklist")
                        }.buttonStyle(.bordered).controlSize(.small)
                        if let date = result?.fetchedAt {
                            Text(language.text("更新于 ", "Updated ") + language.dateTime(date))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 8)
                }.font(.caption)
                if model.refreshing.contains(profile.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(language.text("正在刷新…", "Refreshing…")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if layout == .cards, kind == .grok {
                    if result?.resetCards == nil, let officialUsageURL {
                        grokResetLookupLink(destination: officialUsageURL).font(.caption2)
                    } else if let summary = ResetCardPresentation.summaryText(result?.resetCards, now: Date(), timeZone: .current, language: language) {
                        Label(summary, systemImage: "creditcard")
                            .font(.caption2).foregroundStyle(expiring ? FixedVisualPalette.statusDanger : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if expiring {
                        Text(ResetCardPresentation.expiringLabelText(language: language))
                            .font(.caption2.weight(.semibold)).foregroundStyle(FixedVisualPalette.statusDanger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(width: layout == .rows ? 290 : nil)
            .frame(maxWidth: layout == .cards ? .infinity : nil, alignment: .leading)
        }
        .padding(.horizontal, cardDensity.padding)
        .padding(.vertical, cardDensity.padding)
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
            LocalCLIQuotaWindowDetails(window: window, language: language)
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
                profileAvatar(profile, slot: .detail)
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
                AnchoredActionMenu(
                    request: moreMenuRequest(for: profile, includeUnlink: !profile.isDefault),
                    language: language,
                    onSelect: { handleMoreMenu($0, profile: profile) }
                )
                .frame(width: 28, height: 22)
                .id(profile.id)
            }
            if model.canSignIn(profile) || model.canOpen(profile) {
                HStack(spacing: 12) {
                    if model.canSignIn(profile) {
                        Button {
                            model.signIn(profile, updateProvider: profile.kind == .openCode)
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
                            Label(openTitle, systemImage: profile.kind.isDesktopApplication ? "macwindow" : "terminal")
                        }.buttonStyle(.bordered).disabled(model.signingIn.contains(profile.id))
                    }
                    if model.signingIn.contains(profile.id) { ProgressView().controlSize(.small) }
                }
                if let message = model.loginMessages[profile.id] {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } else if profile.kind.requiresDefaultEnvironmentForLaunch, !profile.isDefault {
                Label(
                    language.text(
                        "此关联环境用于读取额度；请在对应的官方 CLI 中登录。",
                        "This linked environment is for quota reads. Sign in through its matching official CLI."),
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
                            LocalCLIQuotaWindowDetails(window: window, language: language)
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
                                    LocalCLIQuotaWindowDetails(window: window, language: language)
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
        .padding(cardDensity.padding)
        .sectionBackground()
        .overlay(
            expiringSoon
                ? RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(FixedVisualPalette.statusDanger, lineWidth: 2)
                    .allowsHitTesting(false)
                : nil
        )
    }

    private func readiness(_ profile: LocalCLIProfile) -> LocalCLIReadiness {
        .resolve(
            installed: model.executable(for: profile) != nil, result: model.quotas[profile.id],
            stale: model.stale.contains(profile.id) || (model.quotas[profile.id].map { !ResetCardPresentation.isFresh($0.fetchedAt, now: Date()) } ?? false))
    }

    @ViewBuilder private func primaryAction(_ profile: LocalCLIProfile) -> some View {
        let state = readiness(profile)
        Button {
            if model.canOpen(profile) {
                openNative(profile)
            } else if state.isFailure || state == .notInstalled {
                preparationProfile = profile
            } else if state == .needsLogin {
                if model.canSignIn(profile) { model.signIn(profile) } else { preparationProfile = profile }
            } else {
                model.refresh(profile)
            }
        } label: {
            Label(
                model.canOpen(profile)
                    ? profile.kind.isDesktopApplication ? language.text("打开桌面版", "Open desktop app") : language.text("打开终端", "Open terminal")
                    : state.isFailure
                        ? language.text("查看原因", "Review cause")
                        : state == .needsLogin
                            ? language.text("登录", "Sign in")
                            : state == .notInstalled
                                ? language.text("准备", "Prepare")
                                : language.text("刷新", "Refresh"),
                systemImage: model.canOpen(profile)
                    ? profile.kind.isDesktopApplication ? "macwindow" : "terminal"
                    : state.isFailure ? "exclamationmark.circle" : state == .needsLogin ? "person.crop.circle" : "arrow.clockwise"
            ).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.signingIn.contains(profile.id))
    }

    private func statusText(_ result: LocalCLIQuotaResult?) -> String {
        guard let result else { return language.text("点击刷新，读取已登录账号的额度", "Refresh to read limits for the signed-in account") }
        switch result.state {
        case .available:
            return language.text(
                "当前额度配置已验证 · 官方接口暂未返回用量百分比",
                "The current quota configuration was verified, but the official endpoint returned no usage percentage.")
        case .needsLogin: return language.text("等待登录 · 点击登录继续", "Sign-in needed · Choose Sign in to continue")
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
        if profile.kind.isDesktopApplication {
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
                "ZCode 使用桌面版，在官方应用内登录。Coding Plan 配置的额度与桌面订阅分别显示，不据此判断桌面登录成功。",
                "ZCode opens its desktop app for sign-in. Coding Plan configuration quotas are separate from desktop subscription and sign-in status."
            )
        case .trae:
            language.text(
                "仅打开已安装的 TRAE SOLO 个人版桌面。独立 traecli 属于企业产品，本页不把它显示为个人版登录、执行或额度能力。",
                "Only the installed TRAE SOLO personal desktop is opened. Standalone traecli is an enterprise product and is not presented here as personal sign-in, execution, or quota support."
            )
        case .claudeCode:
            language.text(
                "默认环境使用 Claude Code 官方浏览器登录。订阅额度和本机 Token 记录分别显示；关联目录只读取额度。",
                "The default environment uses official Claude Code browser sign-in. Subscription limits and local Token records are separate; linked folders are read-only.")
        case .kimi:
            language.text(
                "登录和启动使用同一配置目录，完成 Kimi Code 浏览器授权后刷新对应额度。",
                "Sign-in and launch use the same configuration directory. Refresh matching limits after Kimi Code browser authorization.")
        case .gemini:
            language.text(
                "支持已配置的 Google 登录或 API Key。打开终端即可使用，/auth 可更换方式；API Key 不使用 Code Assist 订阅额度接口。",
                "Use the configured Google sign-in or API key. Open Terminal to continue, or /auth to change methods. API keys do not use the Code Assist subscription quota endpoint."
            )
        case .mimo:
            language.text(
                "本机登录会自动显示；已有其他独立环境时，可关联该 CLI 的配置目录。",
                "The local sign-in appears automatically. Link a CLI configuration directory for another existing environment.")
        }
    }

    private func signInTitle(_ result: LocalCLIQuotaResult?) -> String {
        if kind == .openCode { return language.text("添加或更新服务商", "Add or update provider") }
        if result?.state == .available {
            return language.text("重新登录", "Sign in again")
        }
        return language.text("登录 \(kind.displayName)", "Sign in to \(kind.displayName)")
    }

    private var openTitle: String {
        kind.isDesktopApplication
            ? language.text("打开 \(kind.displayName) 桌面版", "Open \(kind.displayName) desktop")
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
                    RuntimeLogoView(scope: .claudeCode, size: size)
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
