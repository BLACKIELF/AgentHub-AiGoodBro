import SwiftUI

/// The home view keeps account facts and frequent actions together. The
/// provider workspace still owns the complete model, dispatch and login UI.
@MainActor
struct HomeCodexAccountSummary: View {
    let profile: CodexProfile
    let allProfiles: [CodexProfile]
    let displayNumber: Int
    let layout: AccountWorkspaceLayout
    let loginEligibility: HomeLoginEligibility
    let isCurrentCodexAccount: Bool
    let isMonitoring: Bool
    let fiveHourRemaining: Double?
    let fiveHourReset: Date?
    let sevenDayRemaining: Double?
    let sevenDayReset: Date?
    let creditBalance: CreditBalancePresentation
    let resetCardCount: Int?
    let canSwitchDesktop: Bool
    let onSwitchDesktop: () -> Void
    let currentDate: Date
    let isRefreshing: Bool
    let canCopyTerminalCommand: Bool
    let canOpenTerminal: Bool
    let onRefresh: () -> Void
    let onOpenTerminal: () -> Void
    let onCopyTerminalCommand: () -> Void
    let onManage: () -> Void
    var allowsResetCreditAction = false
    var hubAccountAlias: String? = nil
    var referralAccount: (() throws -> CodexReferralAccount)? = nil
    var resetCreditExpiries: [Date] = []
    var resetCardsExpiring = false
    var resetCreditsFetchedAt: Date? = nil
    var resetCreditsReadSucceeded = false
    var onOpenResetAutoSettings: (() -> Void)? = nil

    @Environment(\.widgetLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.visualTokens) private var visualTokens
    @Environment(\.workspacePreviewDate) private var previewDate

    @State private var isShowingDetails = false

    var body: some View {
        Group {
            if layout == .cards {
                card
            } else {
                ViewThatFits(in: .horizontal) {
                    wideRow.frame(minWidth: 640)
                    narrowRow
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: layout == .cards ? .infinity : nil, alignment: .topLeading)
        .background {
            if layout == .cards {
                WorkspaceGlassSurface(selected: isCurrentCodexAccount)
            } else {
                Color.primary.opacity(displayNumber.isMultiple(of: 2) ? 0.025 : 0)
            }
        }
        .overlay(alignment: .bottom) {
            if layout == .rows {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-codex-account-\(profile.id)")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            identity
            if layout == .cards {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        balanceSummary
                        frequentActions
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        balanceSummary
                        HStack {
                            frequentActions
                            Spacer(minLength: 0)
                        }
                    }
                }
            } else {
                balanceSummary
            }
            resetExpiryNotice
            quotas
            quotaFreshness
        }
    }

    private var quotas: some View {
        HStack(alignment: .top, spacing: 10) {
            quotaWindow(
                language.text("5h", "5h"), remaining: fiveHourRemaining, reset: fiveHourReset,
                constrainedByWeekly: QuotaAvailabilityPresentation.isWeeklyExhausted(sevenDayRemaining))
            quotaWindow(language.text("7d", "7d"), remaining: sevenDayRemaining, reset: sevenDayReset, paletteRole: .secondary)
        }
    }

    private var balanceSummary: some View {
        HStack(spacing: 6) {
            Text(AccountDisplay.planLabel(profile, empty: "—"))
                .font(.system(size: 9)).lineLimit(1)
                .help(accountHelp)
            Text("·")
            CreditBalanceView(presentation: creditBalance, compact: true)
            Text("·")
            ResetCardExpiryFactsView(
                count: resetCardCount, expiries: resetCreditExpiries,
                fetchedAt: resetCreditsFetchedAt, readSucceeded: resetCreditsReadSucceeded,
                now: currentDate, expiring: resetCardsExpiring, onOpenAutoSettings: onOpenResetAutoSettings)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var wideRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                identity
                balanceSummary
                resetExpiryNotice
            }
            .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                quotas
                quotaFreshness
            }.frame(minWidth: 320, maxWidth: 360)
        }
    }

    @ViewBuilder private var resetExpiryNotice: some View {
        if resetCardsExpiring, let expiry = ResetCardPresentation.orderedExpiries(resetCreditExpiries, now: currentDate).first {
            Label(language.text("重置卡 48 小时内到期 · ", "Reset card expires within 48h · ") + language.dateTime(expiry), systemImage: "clock.badge.exclamationmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var listIdentity: some View {
        HStack(spacing: 7) {
            Text(String(format: "%02d", displayNumber))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            StoredCodexAvatar(profile: profile, slot: .compactRow)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    headerActions
                    Text(AccountDisplay.planLabel(profile, empty: "—"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PaletteControlForeground())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(visualTokens.accent.primary.color.opacity(0.12), in: Capsule())
                        .lineLimit(1)
                }
                .help(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                HStack(spacing: 4) {
                    Circle()
                        .fill(
                            isCurrentCodexAccount && loginEligibility == .loggedIn
                                ? FixedVisualPalette.statusSuccessForeground(colorScheme) : Color.secondary
                        )
                        .frame(width: 5, height: 5)
                    Text(accountStatus).lineLimit(1)
                    if snapshotHealth == .failed || snapshotHealth == .stale {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
                            .help(language.text("显示上次额度快照", "Showing last usage snapshot"))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(
                    isCurrentCodexAccount && loginEligibility == .loggedIn
                        ? FixedVisualPalette.statusSuccessForeground(colorScheme) : Color.secondary
                )
                .help(
                    profile.lastSnapshot.map {
                        language.text("额度更新于 ", "Usage updated ") + language.dateTime($0.fetchedAt)
                    } ?? "")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            language.text("第 \(displayNumber) 位，", "Position \(displayNumber), ")
                + AccountDisplay.profileName(profile, allProfiles: allProfiles))
    }

    private var listMembership: some View {
        Group {
            if let until = profile.officialProfile?.subscriptionActiveUntil {
                Text(until > currentDate ? shortDate(until) : language.text("待核实", "Verify expiry"))
                    .foregroundStyle(until > currentDate ? Color.secondary : FixedVisualPalette.statusWarningForeground(colorScheme))
                    .help(
                        until > currentDate
                            ? fullBeijingDateTime(until)
                            : language.text("原记录至 ", "Recorded until ") + fullBeijingDateTime(until)
                                + language.text(" · 待核实", " · verify"))
            } else {
                Text(language.text("未提供", "Unknown")).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var compactCreditText: String {
        switch creditBalance.value {
        case .unavailable: return "—"
        case .unlimited: return language.text("无限", "Unlimited")
        case .reported(let raw):
            let normalized = raw.replacingOccurrences(of: ",", with: "")
            guard let decimal = Decimal(string: normalized) else {
                return CreditBalanceNumberText.compact(raw, locale: language.locale)
            }
            if decimal > 0 && decimal < Decimal(string: "0.005")! { return "<0.01" }
            let formatter = NumberFormatter()
            formatter.locale = language.locale
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 0
            return formatter.string(from: NSDecimalNumber(decimal: decimal))
                ?? CreditBalanceNumberText.compact(raw, locale: language.locale)
        }
    }

    private var narrowRow: some View {
        card
    }

    private var identity: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", displayNumber))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            StoredCodexAvatar(profile: profile, slot: .compactRow)
            Text(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .help(accountHelp)
            ResetCreditButton(
                profile: profile, selectedProfileID: profile.id,
                hubAccountAlias: hubAccountAlias, onConfirmedResult: onRefresh,
                displayNumber: displayNumber, compact: true
            )
            .fixedSize()
            .disabled(!allowsResetCreditAction)
            CodexInviteButton(
                accountLabel: String(format: "%02d · ", displayNumber) + AccountDisplay.profileName(profile, allProfiles: allProfiles),
                resolveAccount: referralAccount
            )
            .fixedSize()
            if loginEligibility != .loggedIn {
                HomeCodexLoginStatusIndicator(
                    eligibility: loginEligibility,
                    status: accountStatus,
                    warningColor: FixedVisualPalette.statusWarningForeground(colorScheme)
                )
            } else if snapshotHealth == .failed || snapshotHealth == .stale {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary).font(.system(size: 10))
                    .help(language.text("显示上次额度快照", "Showing last usage snapshot"))
                    .accessibilityLabel(language.text("显示上次额度快照", "Showing last usage snapshot"))
            }
            Spacer(minLength: 0)
            if layout == .cards { moreActions } else { headerActions }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            language.text("第 \(displayNumber) 位，", "Position \(displayNumber), ")
                + AccountDisplay.profileName(profile, allProfiles: allProfiles)
        )
    }

    private var status: some View {
        HStack(spacing: 4) {
            Circle().fill(
                isCurrentCodexAccount && loginEligibility == .loggedIn
                    ? FixedVisualPalette.statusSuccessForeground(colorScheme) : Color.secondary
            )
            .frame(width: 5, height: 5)
            Text(accountStatus)
            if profile.lastQuotaReadFailureAt != nil && loginEligibility != .temporarilyUnavailable {
                Text(language.text("· 读取失败，显示上次快照", "· Last snapshot; refresh failed"))
            } else if let fetchedAt = profile.lastSnapshot?.fetchedAt,
                currentDate.timeIntervalSince(fetchedAt) > 1_800
            {
                Text(language.text("· 上次快照", "· Last snapshot"))
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(profile.lastSnapshot.map { language.text("额度更新于 ", "Usage updated ") + language.dateTime($0.fetchedAt) } ?? "")
    }

    private var membership: some View {
        Group {
            if let until = profile.officialProfile?.subscriptionActiveUntil {
                let date = shortDate(until)
                Text(
                    until > currentDate
                        ? language.text("到期 \(date)", "Expires \(date)")
                        : language.text("到期 待核实", "Expiry unverified")
                )
                .foregroundStyle(until > currentDate ? Color.secondary : FixedVisualPalette.statusWarningForeground(colorScheme))
                .help((until > currentDate ? "" : language.text("原记录至 ", "Recorded until ")) + fullBeijingDateTime(until))
            } else {
                Text(language.text("到期 未提供", "Expiry unknown")).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private var accountStatus: String {
        switch loginEligibility {
        case .notLoggedIn: return language.text("待登录", "Sign-in needed")
        case .needsLogin: return language.text("需要重新登录", "Sign in again")
        case .temporarilyUnavailable: return language.text("读取失败 · 上次快照", "Last snapshot · refresh failed")
        case .loggedIn:
            return isCurrentCodexAccount
                ? language.text("当前 Codex", "Current Codex")
                : isMonitoring
                    ? language.text("正在监控", "Monitoring")
                    : language.text("已保存账号", "Saved account")
        }
    }

    private var snapshotHealth: AccountSnapshotHealth {
        AccountSnapshotHealth.classify(
            snapshotAt: profile.lastSnapshot?.fetchedAt,
            lastFailureAt: profile.lastQuotaReadFailureAt, now: previewDate ?? currentDate)
    }

    private var quotaFreshness: some View {
        Text(snapshotHealth.updatedLabel(snapshotAt: profile.lastSnapshot?.fetchedAt, now: previewDate ?? currentDate, language: language))
            .font(.system(size: 9))
            .foregroundStyle(
                snapshotHealth == .failed || snapshotHealth == .stale
                    ? FixedVisualPalette.statusWarningForeground(colorScheme) : Color.secondary
            )
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(profile.lastSnapshot.map { language.text("额度更新于 ", "Usage updated ") + language.dateTime($0.fetchedAt) } ?? "")
    }

    private var accountHelp: String {
        var lines = [
            AccountDisplay.profileName(profile, allProfiles: allProfiles),
            AccountDisplay.planLabel(profile, empty: "—"), accountStatus,
        ]
        if let until = profile.officialProfile?.subscriptionActiveUntil {
            lines.append(
                language.text("到期 ", "Expires ") + fullBeijingDateTime(until)
                    + (until > currentDate ? "" : language.text(" · 待核实", " · verify")))
        }
        if let fetchedAt = profile.lastSnapshot?.fetchedAt {
            lines.append(language.text("额度更新于 ", "Usage updated ") + language.dateTime(fetchedAt))
        }
        return lines.joined(separator: "\n")
    }

    private func quotaWindow(
        _ title: String, remaining: Double?, reset: Date?, constrainedByWeekly: Bool = false,
        paletteRole: QuotaPaletteRole = .primary
    ) -> some View {
        CompactQuotaView(
            title: title, remaining: remaining, reset: reset, paletteRole: paletteRole,
            constrainedByWeekly: constrainedByWeekly, horizontalDetails: true,
            isWeeklyOnlyPro: title == "5h" && QuotaAvailabilityPresentation.weeklyOnlyPro(profile, now: previewDate ?? currentDate)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerActions: some View {
        HStack(spacing: 2) {
            frequentActions
            moreActions
        }
        .fixedSize()
    }

    private var frequentActions: some View {
        HStack(spacing: 2) {
            Button(action: onRefresh) {
                Image(systemName: isRefreshing ? "hourglass" : "arrow.clockwise").frame(width: 24, height: 26)
            }
            .disabled(isRefreshing)
            .help(language.text("刷新此账号", "Refresh account"))
            .accessibilityLabel(language.text("刷新此账号", "Refresh account"))
            Button(action: onOpenTerminal) {
                Image(systemName: "terminal").frame(width: 24, height: 26)
            }
            .disabled(!canOpenTerminal)
            .help(language.text("在终端中使用", "Open in Terminal"))
            .accessibilityLabel(language.text("在终端中使用", "Open in Terminal"))
            Button(action: onCopyTerminalCommand) {
                Image(systemName: "doc.on.doc").frame(width: 24, height: 26)
            }
            .disabled(!canCopyTerminalCommand)
            .help(language.text("复制 CLI 调用命令", "Copy CLI command"))
            .accessibilityLabel(language.text("复制 CLI 调用命令", "Copy CLI command"))
            Button(action: onSwitchDesktop) {
                Image(systemName: "macwindow").frame(width: 24, height: 26)
                    .foregroundStyle(isCurrentCodexAccount ? FixedVisualPalette.statusSuccessForeground(colorScheme) : Color.secondary)
            }
            .disabled(!canSwitchDesktop)
            .help(isCurrentCodexAccount ? language.text("当前桌面账号", "Current Desktop account") : language.text("切换到桌面", "Switch Desktop"))
            .accessibilityLabel(isCurrentCodexAccount ? language.text("当前桌面账号", "Current Desktop account") : language.text("切换到桌面", "Switch Desktop"))
        }
        .font(.system(size: 11)).foregroundStyle(.primary).buttonStyle(WorkspaceQuietButtonStyle())
        .fixedSize()
    }

    private var moreActions: some View {
        HStack(spacing: 2) {
            Button {
                isShowingDetails = true
            } label: {
                Image(systemName: "info.circle").frame(width: 24, height: 26)
            }
            .help(language.text("账号资料与暖号详情", "Account and warm-up details"))
            .accessibilityLabel(language.text("账号资料与暖号详情", "Account and warm-up details"))
            .popover(isPresented: $isShowingDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(AccountDisplay.profileName(profile, allProfiles: allProfiles)).font(.headline)
                        Spacer()
                        Button {
                            isShowingDetails = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(language.text("关闭账号信息", "Close account information"))
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            AccountInformationView(profile: profile, accountNumber: displayNumber, now: previewDate ?? currentDate)
                            CreditBalanceView(presentation: creditBalance)
                        }
                    }.frame(maxHeight: 480)
                }.padding(16).frame(width: 430)
            }
            Menu {
                Button(language.text("刷新额度", "Refresh limits"), action: onRefresh).disabled(isRefreshing)
                Button(language.text("在终端中使用", "Open in Terminal"), action: onOpenTerminal).disabled(!canOpenTerminal)
                Button(language.text("复制 CLI 调用命令", "Copy CLI command"), action: onCopyTerminalCommand).disabled(!canCopyTerminalCommand)
                Button(language.text("打开完整管理", "Open full management"), action: onManage)
                Divider()
                Text(accountStatus)
                if let until = profile.officialProfile?.subscriptionActiveUntil {
                    Text(language.text("到期 ", "Expires ") + fullBeijingDateTime(until))
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel(language.text("更多账号操作", "More account actions"))
            .font(.system(size: 11)).foregroundStyle(.primary).buttonStyle(WorkspaceQuietButtonStyle())
            .fixedSize()
        }
        .foregroundStyle(.primary).tint(.primary).buttonStyle(WorkspaceQuietButtonStyle())
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func countdown(deadline: Date) -> some View {
        if let previewDate {
            Text(compactCountdown(deadline: deadline, now: previewDate)).monospacedDigit()
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(compactCountdown(deadline: deadline, now: context.date)).monospacedDigit()
            }
        }
    }
    private func fullBeijingDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date) + language.text(" · 北京时间", " · Beijing time")
    }

    private func compactCountdown(deadline: Date, now: Date) -> String {
        ResetCountdownPresentation.label(deadline: deadline, now: now, kind: .accountWindow, language: language)
            .replacingOccurrences(of: "重置还有 ", with: "还有 ")
            .replacingOccurrences(of: "Resets in ", with: "in ")
    }
}

@MainActor
private struct HomeCodexLoginStatusIndicator: View {
    let eligibility: HomeLoginEligibility
    let status: String
    let warningColor: Color

    @Environment(\.widgetLanguage) private var language
    @State private var triggerHovered = false
    @State private var popoverHovered = false
    @State private var hoverPopoverPresented = false
    @State private var isPinned = false
    @State private var hoverTask: Task<Void, Never>?

    private var isPresented: Bool { hoverPopoverPresented || isPinned }

    var body: some View {
        Button {
            isPinned.toggle()
        } label: {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(warningColor)
                .font(.system(size: 10))
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { updateHover($0, onPopover: false) }
        .popover(
            isPresented: Binding(
                get: { isPresented },
                set: { if !$0 { dismissPopover() } }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            popoverContent
                .onHover { updateHover($0, onPopover: true) }
        }
        .accessibilityLabel(status)
        .accessibilityHint(
            language.text(
                "按空格或回车查看状态原因、额度影响和处理方法。",
                "Press Space or Return for the status reason, quota impact, and next steps."
            )
        )
        .onDisappear { hoverTask?.cancel() }
    }

    private var popoverContent: some View {
        let copy = statusCopy
        return VStack(alignment: .leading, spacing: 9) {
            Text(copy.title)
                .font(.system(size: 12, weight: .semibold))
            detail(language.text("原因", "Reason"), copy.reason)
            detail(language.text("额度影响", "Quota impact"), copy.impact)
            detail(language.text("处理方法", "What to do"), copy.action)
        }
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }

    private func detail(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCopy: (title: String, reason: String, impact: String, action: String) {
        switch eligibility {
        case .notLoggedIn:
            return (
                language.text("账号尚未登录", "Account not signed in"),
                language.text(
                    "此卡片当前无法独立读取额度，可能与账号关联或登录状态有关。",
                    "This card cannot read quota independently right now; its account link or sign-in state may be the cause."
                ),
                language.text(
                    "不会生成新的额度快照；已保存的快照仍会显示，可能已过期。",
                    "No new quota snapshot can be created. A saved snapshot may remain visible and may be outdated."
                ),
                language.text(
                    "点卡片右侧「⋯」→「打开完整管理」，检查此账号的关联和登录状态，按页面提示处理后刷新额度。",
                    "Choose ⋯ → Open full management on the card and check this account's link and sign-in status. Follow the on-screen guidance, then refresh limits."
                )
            )
        case .needsLogin:
            return (
                language.text("需要重新登录", "Sign in again"),
                language.text(
                    "Codex 已判定此账号的登录凭据失效，需要重新授权。",
                    "Codex has rejected this account's sign-in credentials; authorization is required again."
                ),
                language.text(
                    "卡片保留显示上次额度快照；刷新无法更新额度，直到重新登录成功。",
                    "The last saved quota snapshot remains visible. Refresh cannot update quota until sign-in succeeds."
                ),
                language.text(
                    "点卡片右侧「⋯」→「打开完整管理」，在原账号行选择「重新登录」或按提示「设置独立 CLI」；完成后刷新额度。",
                    "Choose ⋯ → Open full management on the card, then choose Sign In Again or follow Set Up Isolated CLI on the original row. After signing in, refresh limits."
                )
            )
        case .temporarilyUnavailable:
            return (
                language.text("额度暂时不可用", "Quota temporarily unavailable"),
                language.text(
                    "账号身份仍可识别，但最近一次额度读取失败。",
                    "The account is still recognized, but its latest quota read failed."
                ),
                language.text(
                    "卡片继续显示上次额度快照，数据可能已过期。",
                    "The card continues to show the last quota snapshot, which may be outdated."
                ),
                language.text(
                    "先点卡片上的刷新额度重试；若持续失败，点右侧「⋯」→「打开完整管理」查看此账号状态。",
                    "Choose Refresh limits on the card to retry. If it keeps failing, use ⋯ → Open full management to check this account's status."
                )
            )
        case .loggedIn:
            return (
                language.text("账号状态正常", "Account is available"),
                "", "", ""
            )
        }
    }

    private func updateHover(_ hovering: Bool, onPopover: Bool) {
        if onPopover {
            popoverHovered = hovering
        } else {
            triggerHovered = hovering
        }

        let shouldPresent = triggerHovered || popoverHovered
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            let delay: UInt64 = shouldPresent ? 140_000_000 : 240_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            hoverPopoverPresented = shouldPresent
        }
    }

    private func dismissPopover() {
        hoverTask?.cancel()
        triggerHovered = false
        popoverHovered = false
        hoverPopoverPresented = false
        isPinned = false
    }
}

private extension View {
    func homeSummaryAction() -> some View {
        self
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7).allowsHitTesting(false))
    }
}

/// Shared facts preserve every reported date without treating missing dates as inferred cards.
struct ResetCardExpiryFactsView: View {
    let count: Int?
    let expiries: [Date]
    let fetchedAt: Date?
    let readSucceeded: Bool
    let now: Date
    let expiring: Bool
    var onOpenAutoSettings: (() -> Void)? = nil
    @Environment(\.widgetLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let disclosure = ResetCardPresentation.expiryDisclosure(
            count: count, expiries: expiries, fetchedAt: fetchedAt,
            readSucceeded: readSucceeded, now: now, language: language)
        if let onOpenAutoSettings {
            Button(action: onOpenAutoSettings) {
                HStack(spacing: 5) {
                    facts(disclosure)
                    Image(systemName: "info.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(disclosure.tooltip + "\n" + language.text("点击设置此账号的到期自动使用；不会立即使用重置卡。", "Open this account’s use-before-expiry settings. No reset card is used by opening it."))
            .accessibilityLabel(
                (count.flatMap { $0 >= 0 ? $0 : nil }.map { language.text("重置卡 \($0)", "\($0) reset cards") }
                    ?? language.text("重置卡数量未知", "Reset-card count unknown"))
                    + " · " + language.text("到期自动使用设置", "Use-before-expiry settings")
            )
            .accessibilityValue(disclosure.tooltip)
            .accessibilityIdentifier("next.reset-credit-auto.account-entry")
        } else {
            HStack(spacing: 5) { facts(disclosure) }
        }
    }
    @ViewBuilder private func facts(_ disclosure: ResetCardPresentation.ExpiryDisclosure) -> some View {
        Text(count.flatMap { $0 >= 0 ? $0 : nil }.map { language.text("重置卡 \($0)", "\($0) reset cards") } ?? language.text("重置卡 —", "Reset cards —"))
            .monospacedDigit().fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(expiring ? FixedVisualPalette.statusWarningForeground(colorScheme) : Color.secondary)
            .help(disclosure.tooltip)
        if let text = disclosure.inlineText {
            Text(text).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.tail).help(disclosure.tooltip)
        }
    }
}
