import SwiftUI

/// All rows use recorded provider evidence. Local labels and model preferences
/// are identified separately; missing provider fields are not inferred.
struct AccountInformationView: View {
    let profile: CodexProfile
    let accountNumber: Int
    var now = Date()
    @Environment(\.widgetLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(language.text("重置卡到期", "Reset-card expiry")) {
                let snapshot = profile.lastSnapshot
                let fresh = Self.hasFreshQuota(profile, now: now) && ResetCardPresentation.isFresh(snapshot?.fetchedAt, now: now)
                row(language.text("可用重置卡", "Available reset cards"), snapshot?.availableResetCredits.map(String.init) ?? "—")
                let expiries = ResetCardPresentation.orderedExpiries(snapshot?.resetCreditExpiries ?? [], now: now)
                if expiries.isEmpty {
                    Text(language.text("官方未提供到期日期", "Expiry dates not reported")).foregroundStyle(.secondary)
                }
                ForEach(Array(expiries.enumerated()), id: \.offset) { index, expiry in
                    let soon =
                        fresh && (snapshot?.availableResetCredits ?? 0) > 0 && expiry > now
                        && expiry.timeIntervalSince(now) <= ResetCardPresentation.expiringWindow
                    HStack(alignment: .firstTextBaseline) {
                        Text(language.text("第 \(index + 1) 张", "Card \(index + 1)"))
                        Spacer()
                        Text(date(expiry)).monospacedDigit()
                        if soon { Text(language.text("48 小时内", "Within 48h")).fontWeight(.bold) }
                        if expiry <= now { Text(language.text("已过记录日期", "Past recorded date")) }
                    }
                    .foregroundStyle(soon ? FixedVisualPalette.statusWarningForeground(colorScheme) : Color.primary)
                    .padding(6)
                    .background(soon ? FixedVisualPalette.statusWarning.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                if !fresh {
                    Text(language.text("上次记录，待刷新核实", "Last recorded; refresh to verify"))
                        .foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
                }
            }
            section(language.text("账号资料", "Account information")) {
                row(language.text("显示名称", "Display name"), safe(profile.officialProfile?.displayName))
                row(language.text("用户名", "Username"), safe(profile.officialProfile?.username))
                row(language.text("登录邮箱", "Sign-in email"), safe(profile.lastSnapshot?.email ?? profile.officialProfile?.accountEmail))
                row(language.text("账号 ID", "Account ID"), Self.maskedID(profile.lastSnapshot?.accountID))
                row(language.text("账号类型", "Account type"), accountType)
                row(language.text("当前套餐", "Current plan"), AccountDisplay.planLabel(profile))
                if profile.resolvedPlanType == "pro", profile.displayedProTierMultiplier != nil {
                    Text(language.text("Pro 倍率为本机手动标记。", "The Pro multiplier is a local manual label."))
                        .foregroundStyle(.secondary)
                }
                row(language.text("会员日期（登录记录）", "Subscription date (sign-in record)"), date(profile.officialProfile?.subscriptionActiveUntil))
                if let expiry = profile.officialProfile?.subscriptionActiveUntil, expiry < now {
                    Text(language.text("记录日期已过，不能据此判断当前订阅已失效。", "The recorded date has passed; it does not establish current subscription status."))
                        .foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
                }
            }
            section(language.text("官方额度", "Reported allowance")) {
                if !Self.hasFreshQuota(profile, now: now) {
                    Text(language.text("额度记录待刷新，以下保留上次读取时间。", "Allowance needs a refresh; the last read time is retained below."))
                        .foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
                }
                window(language.text("5 小时", "5 hours"), profile.lastSnapshot?.fiveHour)
                window(language.text("7 天", "7 days"), profile.lastSnapshot?.sevenDay)
                if profile.lastSnapshot?.monthly != nil { window(language.text("月额度", "Monthly"), profile.lastSnapshot?.monthly) }
                row(language.text("额度更新", "Allowance updated"), date(profile.lastSnapshot?.fetchedAt))
                Text(language.text("未提供的窗口显示 —；不代表额度为零或无限。", "An unreported window is —, not zero or unlimited."))
                    .foregroundStyle(.secondary)
            }
            section(language.text("官方使用统计", "Reported usage statistics")) {
                row(language.text("累计 Token", "Lifetime tokens"), count(profile.officialProfile?.lifetimeTokens))
                row(language.text("单日峰值 Token", "Peak daily tokens"), count(profile.officialProfile?.peakDailyTokens))
                row(language.text("统计截至", "Statistics as of"), date(profile.officialProfile?.statsAsOf))
                row(language.text("资料更新", "Profile fetched"), date(profile.officialProfile?.fetchedAt))
            }
            section(language.text("暖号记录", "Warm-up history")) {
                row(language.text("最近暖号", "Last warm-up"), date(profile.lastWarmUpAt))
                row(
                    language.text("最近结果", "Last result"),
                    profile.lastWarmUpSucceeded.map { $0 ? language.text("成功", "Succeeded") : language.text("未成功", "Not successful") } ?? "—")
                ForEach(Array((profile.warmUpHistory ?? []).sorted { $0.at > $1.at }.enumerated()), id: \.offset) { _, attempt in
                    row(date(attempt.at), attempt.succeeded ? language.text("成功", "Succeeded") : language.text("失败", "Failed"))
                    if !attempt.succeeded, let reason = UsageStore.warmUpFailureDetail(attempt.failureReason, language: language) {
                        Text(reason).foregroundStyle(FixedVisualPalette.statusWarningForeground(colorScheme))
                    }
                }
                Text(language.text("暖号成功表示最小请求完成；额度以官方刷新结果为准。", "Success means the minimal request completed; allowance comes from the provider refresh."))
                    .foregroundStyle(.secondary)
            }
            section(language.text("本机设置", "Local settings")) {
                row(language.text("账号编号", "Account number"), String(format: "%02d", accountNumber))
                row(language.text("加入本机", "Added locally"), date(profile.createdAt))
                row(language.text("后续任务模型", "Model for future tasks"), profile.effectiveExecutionPreference.model.displayName)
                row(language.text("思考强度", "Reasoning effort"), profile.effectiveExecutionPreference.reasoningEffort.displayName)
                row(language.text("参与调度", "Dispatch participation"), profile.participatesInAutomaticSwitch ? language.text("开启", "On") : language.text("关闭", "Off"))
                if let browser = profile.chromeProfile { row(language.text("专用浏览器", "Dedicated browser"), safe(browser.displayName)) }
            }
        }
        .font(.caption)
    }

    private var accountType: String {
        switch profile.lastSnapshot?.accountType?.lowercased() {
        case "chatgpt": return language.text("ChatGPT 订阅", "ChatGPT subscription")
        case "apikey", "api_key": return "API"
        default: return safe(profile.lastSnapshot?.accountType)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(.secondary).frame(width: 142, alignment: .leading)
            Text(value).foregroundStyle(.primary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func window(_ title: String, _ value: CodexQuotaWindowSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            let current = Self.shouldShowQuota(value, profile: profile, now: now)
            let pair = LocalCLIQuotaWindowDetails.percentages(usedPercent: current ? (value?.usedPercent ?? .nan) : .nan, language: language)
            row(title, language.text("已用 \(pair.used) · 剩余 \(pair.remaining)", "Used \(pair.used) · Left \(pair.remaining)"))
            if let reset = value?.resetsAt, reset <= now {
                Text(language.text("该窗口已到重置时间，等待官方更新", "This window reached its reset time; awaiting provider data"))
                    .foregroundStyle(.secondary)
            }
            if value != nil { row(language.text("重置时间", "Resets"), date(value?.resetsAt)) }
        }
    }

    private func safe(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "—" }
        let cleaned = String(value.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(160))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "—" : AccountDisplay.masked(cleaned)
    }

    static func hasFreshQuota(_ profile: CodexProfile, now: Date) -> Bool {
        guard let snapshot = profile.lastSnapshot, snapshot.quotaReadSucceeded == true,
            (profile.lastQuotaReadFailureAt ?? .distantPast) < snapshot.fetchedAt
        else { return false }
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        return age >= -5 && age <= 15 * 60
    }

    static func shouldShowQuota(_ window: CodexQuotaWindowSnapshot?, profile: CodexProfile, now: Date) -> Bool {
        guard let window, hasFreshQuota(profile, now: now) else { return false }
        return window.resetsAt.map { $0 > now } ?? true
    }

    static func maskedID(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        guard value.count > 8 else { return "••••" }
        return String(value.prefix(4)) + "…" + String(value.suffix(4))
    }

    private func count(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        return value.formatted(.number.locale(language.locale))
    }

    private func date(_ value: Date?) -> String {
        guard let value, value.timeIntervalSince1970.isFinite else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: value) + language.text(" 北京时间", " UTC+8")
    }
}
