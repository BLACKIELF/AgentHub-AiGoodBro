import Foundation

struct CodexResetCreditCard: Equatable {
    /// Backend-only identifier. UI and diagnostics must never render this value.
    let creditID: String
    let expiresAt: Date?
}

struct CodexResetCreditReview: Equatable {
    let profileID: String
    let accountID: String
    let accountRemark: String
    let card: CodexResetCreditCard
    let observedAt: Date
    var quotaFingerprint: String? = nil
}

enum CodexResetCreditConsumeOutcome: String, Equatable {
    case reset
    case nothingToReset
    case noCredit
    case alreadyRedeemed
}

enum CodexResetCreditFailure: LocalizedError, Equatable {
    case unsupportedCLI
    case invalidProfile
    case identityUnavailable
    case identityChanged
    case selectionChanged
    case creditAvailabilityUnavailable
    case noAvailableCredit
    case creditChanged
    case expiredChallenge
    case conflictingActivity
    case ambiguousProcessState
    case pendingAttemptRequiresReconciliation
    case requestNotSent
    case outcomeUnknown

    var errorDescription: String? {
        let language = WidgetLanguage.storedOrAutomatic()
        switch self {
        case .unsupportedCLI:
            return language.text("当前 Codex CLI 不支持安全兑换重置卡，请更新到 0.154.0 或更高版本。", "This Codex CLI cannot safely redeem reset cards. Update to 0.154.0 or newer.")
        case .invalidProfile:
            return language.text("所选账号环境无效，操作已停止。", "The selected account environment is invalid. The operation was stopped.")
        case .identityUnavailable:
            return language.text("无法确认所选账号身份，未使用重置卡。", "The selected account identity could not be verified. No reset card was used.")
        case .identityChanged:
            return language.text("账号身份已变化，未使用重置卡。", "The account identity changed. No reset card was used.")
        case .selectionChanged:
            return language.text("所选账号已变化，请重新开始确认。", "The selected account changed. Start the confirmations again.")
        case .creditAvailabilityUnavailable:
            return language.text("重置卡可用状态无法确认，未继续。", "Reset-card availability could not be verified. Nothing was changed.")
        case .noAvailableCredit:
            return language.text("当前没有可用的 Codex 重置卡。", "No Codex reset card is currently available.")
        case .creditChanged:
            return language.text("重置卡已变化或不再可用，请重新开始确认。", "The reset card changed or is no longer available. Start the confirmations again.")
        case .expiredChallenge:
            return language.text("确认已过期，请重新查看最新重置卡。", "The confirmation expired. Review the latest reset card again.")
        case .conflictingActivity:
            return language.text("该账号正在执行其他操作，未使用重置卡。", "Another operation is active for this account. No reset card was used.")
        case .ambiguousProcessState:
            return language.text("检测到无法归属的 Codex 进程，未使用重置卡。", "An unowned Codex process was detected. No reset card was used.")
        case .pendingAttemptRequiresReconciliation:
            return language.text(
                "上次重置结果未确认。只能用同一账号、卡片和密钥重试；若卡片已不可用，重新开始也无法解除阻塞。",
                "The previous reset result is unknown. Only the same account, card, and key can be retried; if that card is no longer available, starting again cannot clear the block."
            )
        case .requestNotSent:
            return language.text("重置请求未发送。", "The reset request was not sent.")
        case .outcomeUnknown:
            return language.text("无法确认重置请求的结果。可能已经使用了重置卡；请勿创建新的尝试。", "The reset request outcome is unknown. A card may have been used; do not create a new attempt.")
        }
    }
}

enum CodexResetCreditVersion {
    static func supports(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let candidates = rawValue.split { !$0.isNumber && $0 != "." }
        guard let version = candidates.first(where: { $0.contains(".") }) else { return false }
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
            let major = Int(components[0]),
            let minor = Int(components[1])
        else { return false }
        return major > 0 || minor >= 154
    }
}
