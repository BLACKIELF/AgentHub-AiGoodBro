import SwiftUI

/// All rows use recorded provider evidence. Local labels and model preferences
/// are identified separately; missing provider fields are not inferred.
struct AccountInformationView: View {
    let profile: CodexProfile
    let dispatchIdentity: DispatchCodeCatalog.DisplayState
    @Environment(\.widgetLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                if let expiry = profile.officialProfile?.subscriptionActiveUntil, expiry < Date() {
                    Text(language.text("记录日期已过，不能据此判断当前订阅已失效。", "The recorded date has passed; it does not establish current subscription status."))
                        .foregroundStyle(.orange)
                }
            }
            section(language.text("官方额度", "Reported allowance")) {
                if !Self.hasFreshQuota(profile, now: Date()) {
                    Text(language.text("额度记录待刷新，以下保留上次读取时间。", "Allowance needs a refresh; the last read time is retained below."))
                        .foregroundStyle(.orange)
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
            section(language.text("本机设置", "Local settings")) {
                row(language.text("调度编号", "Dispatch code"), dispatchIdentity.label(language))
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
            let current = Self.shouldShowQuota(value, profile: profile, now: Date())
            let pair = LocalCLIQuotaWindowDetails.percentages(usedPercent: current ? (value?.usedPercent ?? .nan) : .nan, language: language)
            row(title, language.text("已用 \(pair.used) · 剩余 \(pair.remaining)", "Used \(pair.used) · Left \(pair.remaining)"))
            if let reset = value?.resetsAt, reset <= Date() {
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
