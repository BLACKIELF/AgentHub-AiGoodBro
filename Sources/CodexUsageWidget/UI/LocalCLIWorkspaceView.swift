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
    var compactHomeSummary = false
    var homeDisplayNumber: String? = nil
    var accountNumbers: [String: String] = [:]
    var onOpenDetails: (() -> Void)? = nil
    var onOpenSetup: (() -> Void)? = nil
    @Environment(\.accountCardDensity) private var cardDensity
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.visualTokens) private var visualTokens
    @State private var preparationProfile: LocalCLIProfile?
    @State private var editing: LocalCLIProfile?
    @State private var nameDraft = ""
    @State private var nameSaveFailed = false
    @State private var addingAccount = false
    @State private var newAccountName = ""
    @State private var accountAdditionMethod = AccountAdditionMethod.create
    @State private var newWorkBuddyEdition = WorkBuddyEdition.domestic
    @State private var linkedAccountDirectory: URL?
    @State private var avatarEditor: AccountAvatarTarget?
    @State private var showsClaudeSubscriptions = false
    @State private var linkConfigurationAfterClaude = false
    @State private var claudeDetailsProfile: LocalCLIProfile?

    private enum AccountAdditionMethod: String, CaseIterable, Identifiable {
        case create, link
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if onlyProfileID == nil {
                HStack(spacing: 12) {
                    LocalCLIIcon(kind: kind).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.displayName).font(.title2.weight(.semibold))
                        Text(language.text("\(model.profiles(for: kind).count) 个账号 · 账号与额度", "\(model.profiles(for: kind).count) accounts · Accounts and limits"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    AccountCardDensityPicker()
                    if kind == .claudeCode {
                        Picker(language.text("显示方式", "Layout"), selection: $settings.accountWorkspaceLayout) {
                            Text(language.text("卡片", "Cards")).tag(AccountWorkspaceLayout.cards)
                            Text(language.text("列表", "List")).tag(AccountWorkspaceLayout.rows)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .accessibilityLabel(language.text("显示方式", "Layout"))
                        .frame(width: 112)
                        Button { openClaudeSubscriptions() } label: {
                            Label(language.text("订阅账号", "Subscriptions"), systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(model.isPreview || !model.claudeSwitching.isEmpty || !model.signingIn.isEmpty)
                    }
                    Button {
                        for profile in model.profiles(for: kind) { model.refresh(profile) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(language.text("刷新额度", "Refresh limits"))
                    .accessibilityLabel(language.text("刷新额度", "Refresh limits"))
                    .disabled(model.isPreview || model.profiles(for: kind).isEmpty || model.profiles(for: kind).allSatisfy { model.refreshing.contains($0.id) })
                    Button {
                        if kind == .claudeCode {
                            openClaudeSubscriptions()
                            return
                        }
                        newAccountName = language.text(
                            "\(kind.displayName) 账号 \(model.profiles(for: kind).count + 1)", "\(kind.displayName) account \(model.profiles(for: kind).count + 1)")
                        linkedAccountDirectory = nil
                        newWorkBuddyEdition = model.workBuddyInstalled[.domestic] != nil ? .domestic : .international
                        accountAdditionMethod = model.canCreateAccount(kind: kind) ? .create : .link
                        addingAccount = true
                    } label: {
                        Label(language.text("添加账号", "Add account"), systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPreview || !model.signingIn.isEmpty)
                }
                DisclosureGroup(language.text("平台说明", "Provider details")) { Text(workspaceSummary) }
                    .font(.callout).foregroundStyle(.secondary)
            }
            if showsAccounts {
                if kind == .claudeCode, onlyProfileID == nil, (embeddedLayout ?? settings.accountWorkspaceLayout) == .cards {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardDensity.minimumWidth), alignment: .top)], alignment: .leading, spacing: 10) {
                        ForEach(orderedWorkspaceProfiles) { profile in accountCard(profile) }
                    }
                } else {
                    ForEach(orderedWorkspaceProfiles) { profile in accountCard(profile) }
                }
            }
            if onlyProfileID == nil, let message = model.message {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, onlyProfileID == nil ? 8 : 0)
        .onAppear { model.refreshIfNeeded(kind: kind) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshIfNeeded(kind: kind)
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
        .sheet(isPresented: $addingAccount) { addAccountSheet }
        .sheet(isPresented: $showsClaudeSubscriptions, onDismiss: {
            guard linkConfigurationAfterClaude else { return }
            linkConfigurationAfterClaude = false
            guard !model.isPreview else { return }
            newAccountName = language.text("Claude 账号", "Claude account")
            linkedAccountDirectory = nil
            accountAdditionMethod = .link
            addingAccount = true
        }) { claudeSubscriptionsSheet }
        .sheet(item: $claudeDetailsProfile) { profile in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(profile.displayName).font(.title3.weight(.semibold))
                    Spacer()
                    Button { claudeDetailsProfile = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(language.text("关闭", "Close"))
                }
                ScrollView { fullAccountCard(profile) }.frame(maxHeight: 520)
            }.padding(20).frame(width: 620)
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

    private var addAccountSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("添加 \(kind.displayName) 账号", "Add a \(kind.displayName) account")).font(.headline)
            if model.canCreateAccount(kind: kind) || kind.supportsLinkedEnvironments {
                TextField(language.text("账号名称，例如：工作账号", "Account name, for example: Work"), text: $newAccountName)
                    .textFieldStyle(.roundedBorder)
                if model.canCreateAccount(kind: kind), kind.supportsLinkedEnvironments {
                    Picker(language.text("添加方式", "Add method"), selection: $accountAdditionMethod) {
                        Text(language.text("新建并登录", "Create and sign in")).tag(AccountAdditionMethod.create)
                        Text(language.text("关联已有账号", "Link an existing account")).tag(AccountAdditionMethod.link)
                    }.pickerStyle(.segmented)
                }
                if accountAdditionMethod == .create, model.canCreateAccount(kind: kind) {
                    if kind == .workBuddy, model.workBuddyInstalled.count > 1 {
                        Picker(language.text("WorkBuddy 版本", "WorkBuddy edition"), selection: $newWorkBuddyEdition) {
                            Text(language.text("国内版", "China")).tag(WorkBuddyEdition.domestic)
                            Text(language.text("国际版", "International")).tag(WorkBuddyEdition.international)
                        }.pickerStyle(.segmented)
                    }
                    Text(
                        language.text(
                            "为这个账号建立独立配置，并打开官方登录流程。已有账号会保留，可分别查看额度与重命名。",
                            "Create a separate configuration and open the official sign-in flow. Existing accounts remain available with their own quota and name.")
                    )
                    .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(
                        kind.requiresDefaultEnvironmentForLaunch
                            ? language.text(
                                "选择另一个已登录账号的官方配置文件夹。关联后只读展示；不会替你切换官方工具的当前账号。",
                                "Select another signed-in account's official configuration folder. It will be read only; the official tool's current account will not be switched.")
                            : language.text(
                                "选择另一个已登录账号的配置文件夹，各账号分别保留、命名和刷新。",
                                "Select another signed-in account's configuration folder. Each account keeps its own name and refreshes separately.")
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Button {
                        chooseLinkedAccountDirectory()
                    } label: {
                        Label(
                            linkedAccountDirectory == nil
                                ? language.text("选择已登录的配置文件夹", "Choose a signed-in configuration folder")
                                : language.text("已选择配置文件夹 · 更换", "Configuration selected · Change"),
                            systemImage: linkedAccountDirectory == nil ? "folder" : "folder.badge.checkmark")
                    }.buttonStyle(.bordered)
                }
            } else {
                Text(
                    language.text(
                        "此桌面平台目前提供本机活动账号，尚无经过验证的独立账号配置。可先在官方应用中切换账号，再刷新这里的额度。",
                        "This desktop platform currently provides its active local account. Separate account configurations are not verified yet. Switch accounts in the official app, then refresh quota here."
                    )
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            if model.installed[kind] == nil {
                Text(language.text("请先安装官方工具，再添加或关联账号。", "Install the official tool before creating or linking an account."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(language.text("取消", "Cancel")) { addingAccount = false }.keyboardShortcut(.cancelAction)
                if accountAdditionMethod == .create, model.canCreateAccount(kind: kind) {
                    Button(language.text("创建并登录", "Create and sign in")) {
                        if let profile = model.createAccount(
                            kind: kind, name: trimmedNewAccountName,
                            workBuddyEdition: kind == .workBuddy ? newWorkBuddyEdition : nil)
                        {
                            addingAccount = false
                            model.signIn(profile)
                        }
                    }.keyboardShortcut(.defaultAction).disabled(trimmedNewAccountName.isEmpty || !model.signingIn.isEmpty)
                } else if kind.supportsLinkedEnvironments {
                    Button(language.text("添加关联账号", "Add linked account")) {
                        guard let directory = linkedAccountDirectory else { return }
                        let previousCount = model.profiles(for: kind).count
                        model.link(kind: kind, directory: directory, name: trimmedNewAccountName)
                        if model.profiles(for: kind).count > previousCount { addingAccount = false }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(trimmedNewAccountName.isEmpty || linkedAccountDirectory == nil || model.installed[kind] == nil)
                } else if let profile = model.profiles(for: kind).first(where: \.isDefault), model.canOpen(profile) {
                    Button(language.text("打开官方应用", "Open official app")) {
                        addingAccount = false
                        openNative(profile)
                    }.keyboardShortcut(.defaultAction)
                }
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 450)
    }

    private var trimmedNewAccountName: String {
        newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openClaudeSubscriptions() {
        guard !model.isPreview else { return }
        model.discoverClaudeSubscriptions()
        showsClaudeSubscriptions = true
    }

    private var claudeSubscriptionsSheet: some View {
        ClaudeSubscriptionSetupPanel(
            model: model, language: language,
            onLinkConfiguration: {
                linkConfigurationAfterClaude = true
                showsClaudeSubscriptions = false
            },
            onDone: { showsClaudeSubscriptions = false })
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
        if profile.kind == .claudeCode {
            actions.insert(AnchoredMenuAction(id: "claude-subscriptions", title: language.text("订阅账号", "Subscriptions")), at: 1)
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
        case "claude-subscriptions": openClaudeSubscriptions()
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
        if compactHomeSummary {
            let layout = embeddedLayout ?? .cards
            compactHomeAccount(profile, layout: layout)
        } else if isClaudeSubscriptionProfile(profile) {
            let layout = embeddedLayout ?? settings.accountWorkspaceLayout
            claudeSubscriptionAccount(profile, layout: layout)
        } else if kind == .claudeCode, embeddedLayout == nil, settings.accountWorkspaceLayout == .cards {
            embeddedAccount(profile, layout: .cards)
        } else if let layout = embeddedLayout {
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

    /// Uses the same numbered card/row, quota rings and compact actions as Codex.
    private func claudeSubscriptionAccount(
        _ profile: LocalCLIProfile,
        layout: AccountWorkspaceLayout
    ) -> some View {
        let result = model.quotas[profile.id]
        let active = model.claudeActiveProfileID == profile.id
        let isStale = quotaIsStale(profile)
        let arrangement = layout == .cards ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
        return arrangement {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(accountNumbers[profile.id] ?? homeDisplayNumber ?? workspaceDisplayNumber(profile))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    profileAvatar(profile, slot: layout == .cards ? .card : .list)
                    Text(profile.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(language.text("当前使用", "Active")) }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text(result?.planLabel ?? language.text("订阅方案待确认", "Plan not confirmed")).fontWeight(.medium)
                    if let identity = result?.maskedIdentity { Text(identity).lineLimit(1) }
                }.font(.caption2).foregroundStyle(.secondary)
                if layout == .cards { claudeCardControls(profile) }
                claudeSubscriptionCardStatus(profile, result: result, isStale: isStale, layout: layout)
            }.frame(minWidth: layout == .rows ? 200 : nil, maxWidth: .infinity, alignment: .leading)
            ClaudeSubscriptionQuotaView(
                result: result, isStale: isStale, language: language)
                .frame(width: layout == .rows ? 270 : nil)
                .frame(maxWidth: layout == .cards ? .infinity : nil, alignment: .leading)
            if layout == .cards { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 5) {
                if layout == .rows { claudeCardControls(profile) }
                HStack(spacing: 8) {
                    claudeSwitchButton(profile, compact: false)
                    if active, model.canOpen(profile) {
                        Button(openTitle) { openNative(profile) }.buttonStyle(.bordered)
                    }
                    if layout == .cards { Spacer(minLength: 0) }
                }.controlSize(.small)
                if profile.claudeSubscription == nil {
                    Text(language.text("先保存当前订阅，再启用账号切换", "Save the current subscription to enable switching"))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(layout == .cards ? 1 : nil)
                        .minimumScaleFactor(layout == .cards ? 0.8 : 1)
                }
            }.frame(width: layout == .rows ? 170 : nil, alignment: .leading)
        }
        .padding(.horizontal, cardDensity.padding)
        .padding(.vertical, cardDensity.verticalPadding)
        .cardBackground(cornerRadius: layout == .cards ? 14 : 12)
    }

    @ViewBuilder private func claudeSubscriptionCardStatus(
        _ profile: LocalCLIProfile,
        result: LocalCLIQuotaResult?,
        isStale: Bool,
        layout: AccountWorkspaceLayout
    ) -> some View {
        if isStale, result != nil {
            Text(language.text("上次快照 · 请刷新确认", "Previous snapshot · Refresh to confirm"))
                .font(.caption2).foregroundStyle(WorkspaceStatusForeground.warning)
                .lineLimit(layout == .cards ? 1 : nil)
                .minimumScaleFactor(layout == .cards ? 0.8 : 1)
                .frame(height: layout == .cards ? 14 : nil, alignment: .leading)
        } else if result?.state != .available {
            Label(readiness(profile).title(language), systemImage: readiness(profile).symbol)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(layout == .cards ? 1 : nil)
                .minimumScaleFactor(layout == .cards ? 0.8 : 1)
                .frame(height: layout == .cards ? 14 : nil, alignment: .leading)
        } else if layout == .cards {
            Color.clear.frame(height: 14).accessibilityHidden(true)
        }
    }

    private func claudeCardControls(_ profile: LocalCLIProfile) -> some View {
        HStack(spacing: 1) {
            Spacer(minLength: 0)
            Button { openClaudeCardDetails(profile) } label: {
                Image(systemName: "info.circle").frame(width: 26, height: 26)
            }
            .help(language.text("账号详情与模型额度", "Account details and model limits"))
            .accessibilityLabel(language.text("账号详情与模型额度", "Account details and model limits"))

            Button { openClaudeSubscriptions() } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26)
            }
            .help(language.text("管理订阅账号", "Manage subscriptions"))
            .accessibilityLabel(language.text("管理订阅账号", "Manage subscriptions"))

            Button { model.refresh(profile) } label: {
                Image(systemName: "arrow.clockwise").frame(width: 26, height: 26)
            }
            .disabled(model.refreshing.contains(profile.id))
            .help(language.text("刷新额度", "Refresh limits"))
            .accessibilityLabel(language.text("刷新额度", "Refresh limits"))

            Button { openNative(profile) } label: {
                Image(systemName: "terminal").frame(width: 26, height: 26)
            }
            .disabled(!model.canOpen(profile))
            .help(openTitle)
            .accessibilityLabel(openTitle)

            AnchoredActionMenu(
                request: moreMenuRequest(for: profile, includeUnlink: !profile.isDefault), language: language,
                onSelect: { handleMoreMenu($0, profile: profile) })
                .frame(width: 26, height: 26)
                .help(language.text("更多账号操作", "More account actions"))
                .accessibilityLabel(language.text("更多账号操作", "More account actions"))
                .id(profile.id)
        }
        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private func openClaudeCardDetails(_ profile: LocalCLIProfile) {
        if isClaudeSubscriptionProfile(profile) {
            claudeDetailsProfile = profile
        } else if let onOpenDetails {
            onOpenDetails()
        } else {
            preparationProfile = profile
        }
    }

    /// The home surface shows the account and provider's observed limits. Full
    /// authentication, model, source, and setup controls remain on its provider page.
    @ViewBuilder private func compactHomeAccount(
        _ profile: LocalCLIProfile,
        layout: AccountWorkspaceLayout
    ) -> some View {
        if layout == .rows {
            HStack(alignment: .center, spacing: 14) {
                compactHomeIdentity(profile, layout: layout)
                    .frame(minWidth: 150, maxWidth: 220, alignment: .leading)
                compactHomeQuota(profile, layout: layout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                compactHomeActions(profile, layout: layout)
            }
            .padding(8)
            .background { compactHomeSurface }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    compactHomeIdentity(profile, layout: layout)
                    compactHomeActions(profile, layout: layout)
                }
                compactHomeQuota(profile, layout: layout)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background { compactHomeSurface }
        }
    }

    private var compactHomeSurface: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                reduceTransparency
                    ? Color(nsColor: .controlBackgroundColor)
                    : colorScheme == .dark
                        ? Color(red: 0.135, green: 0.143, blue: 0.158)
                        : Color(red: 0.980, green: 0.982, blue: 0.990)
            )
            .overlay {
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(visualTokens.surfaceTint.color.color.opacity(visualTokens.surfaceTint.maximumOpacity))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(FixedVisualPalette.cardStroke(colorScheme, elevated: false), lineWidth: 0.7)
            }
    }

    private func numberedName(_ profile: LocalCLIProfile) -> String {
        let number = accountNumbers[profile.id] ?? homeDisplayNumber
        return number.map { $0 + " · " + profile.displayName } ?? profile.displayName
    }

    private func compactHomeIdentity(_ profile: LocalCLIProfile, layout: AccountWorkspaceLayout) -> some View {
        let result = model.quotas[profile.id]
        let state = readiness(profile)
        return HStack(alignment: .top, spacing: 8) {
            profileAvatar(profile, slot: .list)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(numberedName(profile))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if layout == .cards { Spacer(minLength: 0) }
                }
                HStack(spacing: 4) {
                    if let plan = result?.planLabel { Text(plan).foregroundStyle(.secondary) }
                    if state != .available { Text(state.title(language)).foregroundStyle(state.color) }
                }.font(.system(size: 10)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func compactHomeQuota(_ profile: LocalCLIProfile, layout: AccountWorkspaceLayout) -> some View {
        let result = model.quotas[profile.id]
        if isClaudeSubscriptionProfile(profile) {
            ClaudeSubscriptionQuotaView(
                result: result, isStale: quotaIsStale(profile), language: language,
                compact: true)
        } else if result?.state == .available, let windows = result?.windows, !windows.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ForEach(windows.prefix(2)) { window in
                    compactHomeQuotaWindow(window)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if windows.count > 2 {
                Text(language.text("另有 \(windows.count - 2) 项额度 · 管理中查看", "\(windows.count - 2) more limits · View in Manage"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let result, let amount = LocalCLIAccountPresentation.balanceText(kind: kind, result: result, language: language) {
                Text(LocalCLIAccountPresentation.balanceTitle(kind: kind, language: language) + " " + amount)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        } else if let result, let amount = LocalCLIAccountPresentation.balanceText(kind: kind, result: result, language: language) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalCLIAccountPresentation.balanceTitle(kind: kind, language: language) + " " + amount)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(language.text("周期已用 / 剩余：—", "Period used / remaining: —"))
                    .font(.caption2).foregroundStyle(.secondary)
                periodReset(result)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("已用 —  ·  剩余 —", "Used —  ·  Remaining —"))
                    .font(.caption2).foregroundStyle(.secondary)
                periodReset(result)
            }
        }
        if let explanation = LocalCLIAccountPresentation.quotaExplanation(kind: kind, result: result, language: language) {
            Text(explanation).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).help(explanation)
        }
    }

    private func compactHomeQuotaWindow(_ window: LocalCLIQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            CompactQuotaView(
                title: window.label, remaining: 100 - window.usedPercent,
                reset: window.resetsAt, isExpiry: window.isExpiry, horizontalDetails: compactHomeSummary)
            if let amount = window.tokenAmountText {
                Text(amount).font(.system(size: 10).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.85).help(amount)
            }
        }
    }

    private func compactHomeActions(_ profile: LocalCLIProfile, layout: AccountWorkspaceLayout) -> some View {
        HStack(spacing: 6) {
            if isClaudeSubscriptionProfile(profile) { claudeSwitchButton(profile, compact: true) }
            Button {
                model.refresh(profile)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(language.text("刷新额度", "Refresh limits"))
            .accessibilityLabel(language.text("刷新额度", "Refresh limits"))
            .disabled(model.refreshing.contains(profile.id))
            if model.canOpen(profile) {
                Button {
                    openNative(profile)
                } label: {
                    Image(systemName: profile.kind.isDesktopApplication ? "macwindow" : "terminal")
                }
                .help(openTitle)
                .accessibilityLabel(openTitle)
            }
            if let onOpenDetails {
                Button {
                    onOpenDetails()
                } label: {
                    Image(systemName: "ellipsis")
                }
                .help(language.text("打开完整账号管理", "Open full account management"))
                .accessibilityLabel(language.text("打开完整账号管理", "Open full account management"))
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize()
        .controlSize(.small)
    }

    private func embeddedAccount(
        _ profile: LocalCLIProfile,
        layout: AccountWorkspaceLayout
    ) -> some View {
        let state = readiness(profile)
        let result = model.quotas[profile.id]
        let fresh = !model.stale.contains(profile.id) && ResetCardPresentation.isFresh(result?.fetchedAt, now: Date())
        let expiring = ResetCardPresentation.isExpiringSoon(result?.resetCards, now: Date(), evidenceFresh: fresh)
        let compactClaudeCardHeader = layout == .cards && kind == .claudeCode
        let arrangement = layout == .cards ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return arrangement {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(workspaceDisplayNumber(profile)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    profileAvatar(profile, slot: layout == .cards ? .card : .list)
                    Text(profile.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if kind != .claudeCode {
                        Text(kind.displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if compactClaudeCardHeader {
                    HStack(spacing: 6) {
                        if let plan = result?.planLabel { Text(plan) }
                        Text(environmentLabel(profile))
                    }
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    if isClaudeSubscriptionProfile(profile) {
                        claudeSubscriptionStatus(profile)
                        if let identity = result?.maskedIdentity { Text(identity).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    } else {
                        Text(environmentLabel(profile)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let plan = result?.planLabel { Text(plan).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
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
                if let result, !compactClaudeCardHeader {
                    Text(fresh ? result.sourceLabel : language.text("上次快照 · 请刷新", "Previous snapshot · Refresh needed"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if compactClaudeCardHeader {
                    claudeCardControls(profile)
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
                if compactClaudeCardHeader, let result {
                    Text(result.sourceLabel)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if !fresh {
                        Text(language.text("上次快照 · 请刷新", "Previous snapshot · Refresh needed"))
                            .font(.caption2).foregroundStyle(WorkspaceStatusForeground.warning).lineLimit(1)
                    }
                }
                if let explanation = LocalCLIAccountPresentation.quotaExplanation(kind: kind, result: result, language: language) {
                    Text(explanation).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isClaudeSubscriptionProfile(profile) {
                    ClaudeSubscriptionQuotaView(result: result, isStale: quotaIsStale(profile), language: language)
                } else if let result, !result.windows.isEmpty {
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
                } else if let result, let amount = LocalCLIAccountPresentation.balanceText(kind: kind, result: result, language: language) {
                    Text(LocalCLIAccountPresentation.balanceTitle(kind: kind, language: language) + " " + amount)
                        .font(.callout.monospacedDigit())
                    Text(language.text("周期已用 / 剩余：暂不可确认", "Period used / remaining: unavailable"))
                        .font(.caption2).foregroundStyle(.secondary)
                    periodReset(result)
                } else {
                    Text(language.text("已用 / 剩余：暂不可确认", "Used / remaining: unavailable"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    periodReset(result)
                }
                if let result, !result.windows.isEmpty,
                    let amount = LocalCLIAccountPresentation.balanceText(kind: kind, result: result, language: language)
                {
                    Text(LocalCLIAccountPresentation.balanceTitle(kind: kind, language: language) + " " + amount)
                        .font(.caption.monospacedDigit())
                }
            }
            .frame(width: layout == .rows ? (kind == .claudeCode ? 270 : 168) : nil)
            .frame(maxWidth: layout == .cards ? .infinity : nil, alignment: .topLeading)
            if layout == .cards { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 6) {
                if layout == .rows, kind == .claudeCode {
                    claudeCardControls(profile)
                } else if layout != .cards || kind != .claudeCode {
                    if layout == .cards { Divider() }
                    HStack(spacing: 6) {
                        if isClaudeSubscriptionProfile(profile) { claudeSwitchButton(profile, compact: false) }
                        primaryAction(profile)
                        Button {
                            if let onOpenDetails { onOpenDetails() } else { preparationProfile = profile }
                        } label: {
                            Image(systemName: "info.circle").frame(width: 26, height: 26)
                        }
                        .help(language.text("查看账号详情", "View account details"))
                        .accessibilityLabel(language.text("查看账号详情", "View account details"))
                        AnchoredActionMenu(
                            request: moreMenuRequest(for: profile, includeUnlink: !profile.isDefault),
                            language: language,
                            onSelect: { handleMoreMenu($0, profile: profile) }
                        )
                        .frame(width: 28, height: 22)
                        .id(profile.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                DisclosureGroup(language.text("模型与来源", "Models & source")) {
                    VStack(alignment: .leading, spacing: 6) {
                        modelAvailabilitySummary(for: profile)
                        Button {
                            preparationProfile = profile
                        } label: {
                            Label(language.text("调用准备", "Call preparation"), systemImage: "checklist")
                        }.buttonStyle(.bordered).controlSize(.small)
                        if let date = result?.fetchedAt {
                            Text(
                                (result?.messageCode == "local_cli_antigravity_cached_quota"
                                    ? language.text("缓存文件更新于 ", "Cache file updated ") : language.text("更新于 ", "Updated "))
                                    + language.dateTime(date)
                            )
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 4)
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
        .padding(.vertical, cardDensity.verticalPadding)
        .cardBackground(cornerRadius: layout == .cards ? 14 : 12)
        .overlay {
            if expiring {
                RoundedRectangle(cornerRadius: layout == .cards ? 14 : 12)
                    .strokeBorder(FixedVisualPalette.statusDanger, lineWidth: 1.5).allowsHitTesting(false)
            }
        }
    }

    /// Keep the same short quota track and precise reset date as Home and Codex.
    private func embeddedQuotaWindow(_ window: LocalCLIQuotaWindow, layout: AccountWorkspaceLayout) -> some View {
        compactHomeQuotaWindow(window)
    }

    private func fullAccountCard(_ profile: LocalCLIProfile) -> some View {
        let result = model.quotas[profile.id]
        let isStale = model.stale.contains(profile.id) || !ResetCardPresentation.isFresh(result?.fetchedAt, now: Date())
        let expiringSoon = ResetCardPresentation.isExpiringSoon(
            result?.resetCards,
            now: Date(),
            evidenceFresh: !isStale)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                profileAvatar(profile, slot: .detail)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(numberedName(profile)).font(.headline).lineLimit(2)
                        Text(environmentLabel(profile)).font(.caption2).foregroundStyle(.secondary)
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
                        "此关联配置用于读取额度；请在对应的官方工具中登录。",
                        "This linked configuration is for quota reads. Sign in through its matching official tool."),
                    systemImage: "lock.shield"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if isClaudeSubscriptionProfile(profile) {
                ClaudeSubscriptionQuotaView(result: result, isStale: isStale, language: language)
            } else if let result, !result.windows.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(result.windows.prefix(4)) { window in
                        embeddedQuotaWindow(window, layout: .cards)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            if let result, let amount = LocalCLIAccountPresentation.balanceText(kind: kind, result: result, language: language) {
                HStack {
                    Text(LocalCLIAccountPresentation.balanceTitle(kind: kind, language: language)).foregroundStyle(.secondary)
                    Text(amount).monospacedDigit()
                }.font(.callout)
            }
            if result?.windows.isEmpty != false { periodReset(result) }
            if let result, !result.windows.isEmpty || result.balance != nil,
                let explanation = LocalCLIAccountPresentation.quotaExplanation(kind: kind, result: result, language: language)
            {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    if result.messageCode == "local_cli_antigravity_cached_quota" {
                        Text(language.text("缓存文件更新于", "Cache file updated"))
                    }
                    Text(result.fetchedAt, style: .time)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if model.sharesQuota(profile) {
                Label(language.text("与另一关联账号共用额度", "Shares limits with another linked account"), systemImage: "link")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, cardDensity.padding)
        .padding(.vertical, cardDensity.verticalPadding)
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

    private func quotaIsStale(_ profile: LocalCLIProfile) -> Bool {
        model.stale.contains(profile.id) || !ResetCardPresentation.isFresh(model.quotas[profile.id]?.fetchedAt, now: Date())
    }

    private func isClaudeSubscriptionProfile(_ profile: LocalCLIProfile) -> Bool {
        let result = model.quotas[profile.id]
        return kind == .claudeCode && (profile.claudeSubscription != nil || (result?.state == .available && result?.sourceLabel == "Anthropic OAuth usage"))
    }

    private func claudeSubscriptionStatus(_ profile: LocalCLIProfile) -> some View {
        let active = model.claudeActiveProfileID == profile.id
        return Label(
            active ? language.text("当前使用", "Active") : language.text("订阅账号", "Subscription account"),
            systemImage: active ? "checkmark.circle.fill" : "person.crop.circle")
        .font(.caption2.weight(.medium))
        .foregroundStyle(active ? FixedVisualPalette.statusSuccess : Color.secondary)
    }

    private func claudeSwitchButton(_ profile: LocalCLIProfile, compact: Bool) -> some View {
        let active = model.claudeActiveProfileID == profile.id
        let switching = model.claudeSwitching.contains(profile.id)
        let needsSaving = profile.claudeSubscription == nil
        return Button {
            if needsSaving { openClaudeSubscriptions() }
            else { Task { @MainActor in _ = await model.switchClaudeSubscription(profile) } }
        } label: {
            if switching { ProgressView().controlSize(.small) }
            else {
                if compact {
                    Image(systemName: needsSaving ? "person.crop.circle.badge.plus" : active ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                } else {
                    Label(needsSaving ? language.text("保存订阅", "Save subscription") : active ? language.text("当前使用", "Active") : language.text("切换", "Switch"), systemImage: active ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                }
            }
        }
        .buttonStyle(.bordered)
        .disabled(active || (!needsSaving && !model.canSwitchClaudeSubscription(profile)) || !model.claudeSwitching.isEmpty || !model.signingIn.isEmpty)
        .help(active ? language.text("当前正在使用此 Claude 订阅", "This Claude subscription is active") : language.text("切换 Claude 订阅账号", "Switch Claude subscription account"))
        .accessibilityIdentifier("claude-subscription-switch")
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
        if let explanation = LocalCLIAccountPresentation.quotaExplanation(kind: kind, result: result, language: language) { return explanation }
        switch result.state {
        case .available:
            return language.text(
                "当前额度配置已验证 · 官方接口暂未返回用量百分比",
                "The current quota configuration was verified, but the official endpoint returned no usage percentage.")
        case .needsLogin:
            return kind.isDesktopApplication
                ? language.text("等待登录 · 请在官方桌面应用中登录后刷新", "Sign-in needed · Sign in through the official desktop app, then refresh")
                : language.text("等待登录 · 点击登录继续", "Sign-in needed · Choose Sign in to continue")
        case .unsupported:
            return language.text("该账号的额度接口暂未接通", "The quota interface for this account is not available yet")
        case .rateLimited: return language.text("服务商暂时限流，请稍后刷新", "The provider is rate limiting requests. Refresh later")
        case .unavailable: return language.text("暂未读到额度，请稍后刷新", "Limits could not be read. Refresh later")
        }
    }

    private func periodReset(_ result: LocalCLIQuotaResult?) -> some View {
        Text(
            result?.periodResetsAt.map { language.text("重置：", "Resets: ") + language.dateTime($0) }
                ?? language.text("重置时间：暂不可确认", "Reset time: unavailable")
        )
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func workspaceDisplayNumber(_ profile: LocalCLIProfile) -> String {
        String(format: "%02d", (orderedWorkspaceProfiles.firstIndex(where: { $0.id == profile.id }) ?? 0) + 1)
    }

    private func environmentLabel(_ profile: LocalCLIProfile) -> String {
        if profile.isDefault { return language.text("本机默认", "Local default") }
        return profile.kind.requiresDefaultEnvironmentForLaunch
            ? language.text("关联配置 · 只读", "Linked configuration · Read only")
            : language.text("独立配置", "Separate configuration")
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

    private func chooseLinkedAccountDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = kind.defaultConfigDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
        panel.title = language.text("选择已登录账号的配置目录", "Choose a signed-in account configuration directory")
        panel.message = language.text("请选择官方工具已登录的配置文件夹，无需查找应用。", "Select the official tool's signed-in configuration folder. You do not need to find an application.")
        panel.prompt = language.text("选择", "Choose")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        linkedAccountDirectory = directory
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
                "分别查看 Claude 订阅的 5 小时、7 天与模型额度，保存当前订阅后可手动切换。登录使用官方流程；额度与本机 Token 统计分别计算。",
                "View each Claude subscription's 5-hour, weekly and model limits. Save the current subscription to switch manually. Sign-in uses the official flow; quota and local Token totals stay separate.")
        case .kimi:
            language.text(
                "登录和启动使用同一配置目录，完成 Kimi Code 浏览器授权后刷新对应额度。",
                "Sign-in and launch use the same configuration directory. Refresh matching limits after Kimi Code browser authorization.")
        case .gemini:
            language.text(
                "支持已配置的 Google 登录或 API Key。打开终端即可使用，/auth 可更换方式；API Key 不使用 Code Assist 订阅额度接口。",
                "Use the configured Google sign-in or API key. Open Terminal to continue, or /auth to change methods. API keys do not use the Code Assist subscription quota endpoint."
            )
        case .antigravity:
            language.text(
                "读取 Antigravity 官方桌面应用的活动账号和额度。在官方应用内登录或切换后刷新；关联配置只用于读取，不代替桌面账号切换。",
                "Reads the active account and quota from the official Antigravity desktop app. Sign in or switch accounts there, then refresh; linked configurations are read only and do not switch the desktop account."
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

/// Uses the production account store; signing in and saving remain separate actions.
@MainActor
struct ClaudeSubscriptionSetupPanel: View {
    @ObservedObject var model: LocalCLIAccountStore
    let language: WidgetLanguage
    var onLinkConfiguration: () -> Void = {}
    var onDone: () -> Void = {}
    @State private var subscriptionName = ""
    @State private var captureInProgress = false

    private var accountActionBusy: Bool {
        captureInProgress || !model.claudeSwitching.isEmpty || !model.signingIn.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LocalCLIIcon(kind: .claudeCode).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("添加 Claude 账号", "Add a Claude account"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(language.text("保存当前登录，随时手动切换。", "Save the current sign-in for manual switching."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onDone) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(language.text("关闭", "Close"))
            }
            VStack(alignment: .leading, spacing: 12) {
                Label(language.text("当前登录账号", "Current sign-in"), systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold))
                Text(language.text(
                    "先在 Claude Code 登录，再在这里保存当前账号；再次添加会更新由 AiGoodBro 保存的凭据。",
                    "Sign in to Claude Code, then save the current account here. Adding it again updates credentials saved by AiGoodBro."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    TextField(language.text("账号名称，例如：工作账号", "Account name, for example: Work"), text: $subscriptionName)
                        .textFieldStyle(.roundedBorder)
                    Button(action: saveCurrentSubscription) {
                        if captureInProgress { ProgressView().controlSize(.small) }
                        else { Text(language.text("添加当前登录账号", "Add signed-in account")) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .fixedSize()
                    .disabled(model.isPreview || accountActionBusy)
                }
                Text(language.text("添加后仍使用当前账号；以后可在账号卡片上手动切换。", "Adding keeps the current account active. Switch manually from its account card later."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).background { WorkspaceGlassSurface(cornerRadius: 12) }
            VStack(alignment: .leading, spacing: 10) {
                Text(language.text("登录或添加另一个账号", "Sign in or add another account"))
                    .font(.system(size: 12, weight: .semibold))
                Text(language.text(
                    "先保存要保留的当前账号，再在 Claude Code 登录另一个账号，回到这里添加。不要先 /logout，以免已保存的凭据失效。",
                    "Save the current account you want to keep, sign in to another account in Claude Code, then return here to add it. Do not use /logout first; it may invalidate saved credentials."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    guard !model.isPreview else { return }
                    model.startClaudeSubscriptionSignIn()
                } label: {
                    Label(language.text("打开 Claude Code 官方 CLI 登录", "Open Claude Code CLI sign-in"), systemImage: "terminal")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.isPreview || !model.canBeginClaudeSubscriptionSignIn || captureInProgress)
                if model.installed[.claudeCode] == nil {
                    Text(language.text("尚未发现 Claude Code 官方 CLI。", "The official Claude Code CLI was not found."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message = model.claudeSubscriptionSignInMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14).background { WorkspaceGlassSurface(cornerRadius: 12) }
            HStack(spacing: 10) {
                Text(language.text("已发现的订阅", "Discovered subscriptions"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    guard !model.isPreview else { return }
                    model.discoverClaudeSubscriptions()
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help(language.text("重新查找订阅", "Rescan subscriptions"))
                    .accessibilityLabel(language.text("重新查找订阅", "Rescan subscriptions"))
                    .disabled(model.isPreview || accountActionBusy)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.claudeSubscriptionCandidates.isEmpty {
                        Text(language.text("暂未发现其他已保存订阅。可在上方添加当前 Claude Code 登录账号。", "No other saved subscriptions were found. Add the current Claude Code sign-in above."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                    }
                    ForEach(model.claudeSubscriptionCandidates) { candidate in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                if let identity = candidate.maskedIdentity { Text(identity).font(.caption).foregroundStyle(.secondary) }
                                HStack(spacing: 6) {
                                    if let plan = candidate.planLabel { Text(plan) }
                                    Text(candidate.sourceLabel)
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(language.text("添加", "Add")) {
                                guard !model.isPreview else { return }
                                _ = model.importClaudeSubscription(candidateID: candidate.id, name: candidate.label)
                                model.discoverClaudeSubscriptions()
                            }
                            .controlSize(.small)
                            .disabled(model.isPreview || !candidate.canImport || accountActionBusy)
                        }
                        .padding(10).background { WorkspaceGlassSurface(cornerRadius: 10) }
                    }
                }
            }.frame(maxHeight: 150)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(language.text("关联配置文件夹…", "Link configuration folder…"), action: onLinkConfiguration)
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(model.isPreview || accountActionBusy)
                Spacer(minLength: 8)
                Button(language.text("完成", "Done"), action: onDone)
                    .controlSize(.small).keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 560)
        .disabled(model.isPreview)
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
        .accessibilityIdentifier("claude-subscription-setup-panel")
    }

    private func saveCurrentSubscription() {
        guard !model.isPreview, !accountActionBusy else { return }
        captureInProgress = true
        let draft = subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.isEmpty ? language.text("Claude 订阅", "Claude subscription") : draft
        Task { @MainActor in
            if await model.captureClaudeSubscription(name: name) != nil { subscriptionName = "" }
            captureInProgress = false
            model.discoverClaudeSubscriptions()
        }
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
                if let image = UpstreamProviderArtwork.image(for: kind.rawValue) {
                    UpstreamProviderIcon(image: image, size: box)
                } else {
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
                    case .antigravity:
                        Image(systemName: "a.circle")
                            .resizable().scaledToFit()
                            .frame(width: box, height: box)
                    }
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.accessibilityHidden(true)
    }
}
