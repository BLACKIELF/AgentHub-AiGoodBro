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

    @Environment(\.widgetLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.visualTokens) private var visualTokens
    @Environment(\.workspacePreviewDate) private var previewDate

    var body: some View {
        Group {
            if layout == .cards {
                card
            } else {
                ViewThatFits(in: .horizontal) {
                    wideRow.frame(minWidth: 620)
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
            quotas
            balanceSummary
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
            Text(
                resetCardCount.map { language.text("重置卡 \($0)", "\($0) reset cards") }
                    ?? language.text("重置卡 —", "Reset cards —")
            )
            .monospacedDigit().lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var wideRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                identity
                balanceSummary
            }
            .frame(minWidth: 235, maxWidth: .infinity, alignment: .leading)
            quotaWindow(
                "5h", remaining: fiveHourRemaining, reset: fiveHourReset,
                constrainedByWeekly: QuotaAvailabilityPresentation.isWeeklyExhausted(sevenDayRemaining))
            quotaWindow("7d", remaining: sevenDayRemaining, reset: sevenDayReset, paletteRole: .secondary)
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
            if loginEligibility != .loggedIn {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
                    .font(.system(size: 10))
                    .help(accountStatus).accessibilityLabel(accountStatus)
            } else if profile.lastQuotaReadFailureAt != nil
                || profile.lastSnapshot.map({ currentDate.timeIntervalSince($0.fetchedAt) > 1_800 }) == true
            {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary).font(.system(size: 10))
                    .help(language.text("显示上次额度快照", "Showing last usage snapshot"))
                    .accessibilityLabel(language.text("显示上次额度快照", "Showing last usage snapshot"))
            }
            Spacer(minLength: 0)
            headerActions
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
        CompactQuotaView(title: title, remaining: remaining, reset: reset, paletteRole: paletteRole, constrainedByWeekly: constrainedByWeekly)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerActions: some View {
        HStack(spacing: 2) {
            Button(action: onSwitchDesktop) {
                Image(systemName: "macwindow").frame(width: 26, height: 26)
                    .foregroundStyle(isCurrentCodexAccount ? FixedVisualPalette.statusSuccess : Color.secondary)
            }
            .disabled(!canSwitchDesktop)
            .help(isCurrentCodexAccount ? language.text("当前桌面账号", "Current Desktop account") : language.text("切换到桌面", "Switch Desktop"))
            .accessibilityLabel(isCurrentCodexAccount ? language.text("当前桌面账号", "Current Desktop account") : language.text("切换到桌面", "Switch Desktop"))
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
                Image(systemName: isRefreshing ? "hourglass" : "ellipsis").frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel(language.text("更多账号操作", "More account actions"))
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(WorkspaceQuietButtonStyle())
        .fixedSize()
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
