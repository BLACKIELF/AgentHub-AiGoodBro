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
    let currentDate: Date
    let isRefreshing: Bool
    let canCopyTerminalCommand: Bool
    let canOpenTerminal: Bool
    let onRefresh: () -> Void
    let onOpenTerminal: () -> Void
    let onCopyTerminalCommand: () -> Void
    let onManage: () -> Void

    @Environment(\.widgetLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.visualTokens) private var visualTokens
    @Environment(\.workspacePreviewDate) private var previewDate
    @State private var showingListBalanceDetails = false

    var body: some View {
        Group {
            if layout == .cards {
                card
            } else {
                ViewThatFits(in: .horizontal) {
                    wideRow.frame(minWidth: 1_190)
                    narrowRow
                }
            }
        }
        .padding(.horizontal, layout == .cards ? 15 : 14)
        .padding(.vertical, layout == .cards ? 14 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 10) {
            identity
            HStack(spacing: 5) {
                status
                Spacer(minLength: 3)
                membership
            }
            .font(.system(size: 11))
            CreditBalanceView(presentation: creditBalance, compact: true)
                .font(.system(size: 11))
            Divider().opacity(0.55)
            HStack(alignment: .top, spacing: 15) {
                quotaWindow(
                    language.text("5 小时剩余", "5h left"), remaining: fiveHourRemaining, reset: fiveHourReset,
                    constrainedByWeekly: QuotaAvailabilityPresentation.isWeeklyExhausted(sevenDayRemaining))
                quotaWindow(
                    language.text("7 天剩余", "7d left"), remaining: sevenDayRemaining, reset: sevenDayReset,
                    paletteRole: .secondary)
            }
            Divider().opacity(0.65)
            actions
        }
    }

    private var wideRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            if displayNumber == 1 {
                HStack(spacing: 12) {
                    Text(language.text("账号", "Account")).frame(width: 230, alignment: .leading)
                    Text(language.text("会员到期", "Membership")).frame(width: 108, alignment: .leading)
                    Text(language.text("美元 / 点数", "USD / credits")).frame(width: 130, alignment: .leading)
                    Text(language.text("5 小时剩余 · 重置时间", "5h left · reset time"))
                        .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
                    Text(language.text("7 天剩余 · 重置时间", "7d left · reset time"))
                        .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
                    Text(language.text("操作", "Actions")).frame(width: 150, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                Divider().opacity(0.5)
            }
            HStack(alignment: .center, spacing: 12) {
                listIdentity.frame(width: 230, alignment: .leading)
                listMembership.frame(width: 108, alignment: .leading)
                listBalance.frame(width: 130, alignment: .leading)
                listQuota(
                    remaining: fiveHourRemaining, reset: fiveHourReset,
                    constrainedByWeekly: QuotaAvailabilityPresentation.isWeeklyExhausted(sevenDayRemaining)
                )
                .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
                listQuota(remaining: sevenDayRemaining, reset: sevenDayReset, paletteRole: .secondary)
                    .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
                listActions.frame(width: 150, alignment: .trailing)
            }
            .frame(minHeight: 43)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text(AccountDisplay.planLabel(profile, empty: "—"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tint)
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
                                ? FixedVisualPalette.statusSuccess : Color.secondary
                        )
                        .frame(width: 5, height: 5)
                    Text(accountStatus).lineLimit(1)
                    if profile.lastQuotaReadFailureAt != nil
                        || profile.lastSnapshot.map({ currentDate.timeIntervalSince($0.fetchedAt) > 1_800 }) == true
                    {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
                            .help(language.text("显示上次额度快照", "Showing last usage snapshot"))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(
                    isCurrentCodexAccount && loginEligibility == .loggedIn
                        ? FixedVisualPalette.statusSuccess : Color.secondary
                )
                .help(
                    profile.lastSnapshot.map {
                        language.text("额度更新于 ", "Usage updated ") + language.dateTime($0.fetchedAt)
                    } ?? "")
            }
        }
        .accessibilityElement(children: .combine)
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

    private var listBalance: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("美元 —", "USD —"))
                Text(language.text("点数 ", "Credits ") + compactCreditText)
                    .monospacedDigit()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                showingListBalanceDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("余额说明", "Balance details"))
            .popover(isPresented: $showingListBalanceDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(creditBalance.primaryText(language))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .textSelection(.enabled)
                    Text(language.text("美元余额未提供，不从点数推算。", "USD balance is not provided and is not inferred from credits."))
                    Text(creditBalance.sourceText(language))
                    if let snapshotAt = creditBalance.snapshotAt {
                        Text(language.text("快照时间：", "Snapshot: ") + language.dateTime(snapshotAt))
                    }
                    Text(creditBalance.explanation(language))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .padding(14)
                .frame(width: 268, alignment: .leading)
                .background(.background)
            }
        }
        .help(creditBalance.sourceText(language) + "\n" + creditBalance.explanation(language))
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

    private func listQuota(
        remaining: Double?, reset: Date?, constrainedByWeekly: Bool = false,
        paletteRole: QuotaPaletteRole = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(QuotaAvailabilityPresentation.percentText(remaining))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(remaining == nil ? Color.secondary : Color.primary)
                    .frame(width: 51, alignment: .leading)
                if remaining != nil {
                    QuotaProgressTrack(percent: remaining, paletteRole: paletteRole)
                        .frame(maxWidth: .infinity).frame(height: 5)
                } else {
                    Text(language.text("官方未提供", "Not provided"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(reset.map(shortDateTime) ?? language.text("重置时间 —", "Reset time —"))
                if let reset {
                    countdown(deadline: reset)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            if constrainedByWeekly {
                Text(language.text("受 7 天额度限制", "Limited by 7-day quota"))
                    .font(.system(size: 10))
                    .foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
            }
        }
        .help(
            (reset.map(fullBeijingDateTime) ?? language.text("官方未提供重置时间", "Official reset time unavailable"))
                + (constrainedByWeekly ? language.text(" · 受 7 天额度限制", " · Limited by 7-day quota") : ""))
    }

    private var listActions: some View {
        HStack(spacing: 5) {
            Button(action: onRefresh) {
                Image(systemName: isRefreshing ? "hourglass" : "arrow.clockwise")
                    .frame(width: 27, height: 26)
            }
            .disabled(isRefreshing)
            .accessibilityLabel(language.text("刷新此账号额度", "Refresh account usage"))
            .homeSummaryAction()
            HStack(spacing: 0) {
                Button(action: onOpenTerminal) {
                    Image(systemName: "terminal").frame(width: 29, height: 26)
                }
                .disabled(!canOpenTerminal)
                .accessibilityLabel(language.text("在终端中使用此账号", "Open account in Terminal"))
                Rectangle().fill(visualTokens.selection.stroke.color).frame(width: 1, height: 12)
                Menu {
                    Button(language.text("复制 CLI 调用命令", "Copy CLI command"), action: onCopyTerminalCommand)
                        .disabled(!canCopyTerminalCommand)
                    Button(language.text("打开完整管理", "Open full management"), action: onManage)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9)).frame(width: 18, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel(language.text("更多终端操作", "More Terminal actions"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(visualTokens.selection.foreground.color)
            .background(visualTokens.selection.fill.color, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(visualTokens.selection.stroke.color, lineWidth: 0.7).allowsHitTesting(false))
            Button(action: onManage) {
                Text(language.text("管理 ›", "Manage ›"))
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 60, height: 26)
            }
            .accessibilityLabel(language.text("打开此账号的完整管理", "Open full account management"))
            .homeSummaryAction()
        }
        .buttonStyle(.plain)
    }

    private var narrowRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                identity
                Spacer(minLength: 4)
                membership.font(.system(size: 11))
            }
            HStack(spacing: 12) {
                status.font(.system(size: 10))
                CreditBalanceView(presentation: creditBalance, compact: true)
                    .font(.system(size: 10)).frame(maxWidth: 230)
                Spacer(minLength: 0)
                actions
            }
            HStack(alignment: .top, spacing: 16) {
                quotaWindow(
                    language.text("5 小时剩余", "5h left"), remaining: fiveHourRemaining, reset: fiveHourReset,
                    constrainedByWeekly: QuotaAvailabilityPresentation.isWeeklyExhausted(sevenDayRemaining))
                quotaWindow(
                    language.text("7 天剩余", "7d left"), remaining: sevenDayRemaining, reset: sevenDayReset,
                    paletteRole: .secondary)
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", displayNumber))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            StoredCodexAvatar(profile: profile, slot: .compactRow)
            Text(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .help(AccountDisplay.profileName(profile, allProfiles: allProfiles))
            Spacer(minLength: 0)
            Text(AccountDisplay.planLabel(profile, empty: "—"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(visualTokens.selection.foreground.color)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(visualTokens.selection.fill.color, in: RoundedRectangle(cornerRadius: 5))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            language.text("第 \(displayNumber) 位，", "Position \(displayNumber), ")
                + AccountDisplay.profileName(profile, allProfiles: allProfiles)
        )
    }

    private var status: some View {
        HStack(spacing: 4) {
            Circle().fill(
                isCurrentCodexAccount && loginEligibility == .loggedIn
                    ? FixedVisualPalette.statusSuccess : Color.secondary
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

    private func quotaWindow(
        _ title: String, remaining: Double?, reset: Date?, constrainedByWeekly: Bool = false,
        paletteRole: QuotaPaletteRole = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 2)
                Text(QuotaAvailabilityPresentation.percentText(remaining))
                    .font(.system(size: layout == .cards ? 21 : 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(remaining == nil ? Color.secondary : Color.primary)
            }
            if remaining != nil {
                QuotaProgressTrack(percent: remaining, paletteRole: paletteRole)
                    .frame(height: 5).padding(.vertical, 3)
            } else {
                Color.clear.frame(height: 11)
            }
            Text(
                reset.map { language.text("重置 ", "Resets ") + shortDateTime($0) }
                    ?? language.text("重置时间 —", "Reset time —")
            )
            .help(reset.map(fullBeijingDateTime) ?? "")
            if let reset {
                countdown(deadline: reset)
            } else {
                Text(
                    remaining == nil
                        ? language.text("官方未提供", "Not provided")
                        : language.text("倒计时 —", "Countdown —"))
            }
            if constrainedByWeekly {
                Text(language.text("受 7 天额度限制", "Limited by 7-day quota"))
                    .foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(action: onRefresh) {
                Image(systemName: isRefreshing ? "hourglass" : "arrow.clockwise")
                    .frame(width: 28, height: 27)
            }
            .disabled(isRefreshing)
            .accessibilityLabel(language.text("刷新此账号额度", "Refresh account usage"))
            .homeSummaryAction()
            HStack(spacing: 0) {
                Button(action: onOpenTerminal) {
                    Image(systemName: "terminal").frame(width: 32, height: 27)
                }
                .disabled(!canOpenTerminal)
                .accessibilityLabel(language.text("在终端中使用此账号", "Open account in Terminal"))
                Rectangle().fill(visualTokens.selection.stroke.color).frame(width: 1, height: 12)
                Menu {
                    Button(language.text("复制 CLI 调用命令", "Copy CLI command"), action: onCopyTerminalCommand)
                        .disabled(!canCopyTerminalCommand)
                    Button(language.text("打开完整管理", "Open full management"), action: onManage)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9)).frame(width: 21, height: 27)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel(language.text("更多终端操作", "More Terminal actions"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(visualTokens.selection.foreground.color)
            .background(visualTokens.selection.fill.color, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(visualTokens.selection.stroke.color, lineWidth: 0.7).allowsHitTesting(false))
            Spacer(minLength: 0)
            Button(action: onManage) {
                Text(language.text("管理 ›", "Manage ›"))
                    .font(.system(size: 11, weight: .medium))
                    .frame(height: 27).padding(.horizontal, 7)
            }
            .accessibilityLabel(language.text("打开此账号的完整管理", "Open full account management"))
            .buttonStyle(.plain)
        }
        .buttonStyle(.plain)
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

private extension View {
    func homeSummaryAction() -> some View {
        self
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7).allowsHitTesting(false))
    }
}
