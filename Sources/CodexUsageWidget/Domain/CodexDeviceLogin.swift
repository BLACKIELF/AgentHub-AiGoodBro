import Foundation

/// Ephemeral only: never encode a device authorization or include it in diagnostics.
struct CodexDeviceAuthorization: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let code: String
    let url: URL
    let expiresAt: Date
    var description: String { "[device authorization redacted]" }
    var debugDescription: String { description }
    func isValid(at date: Date = Date()) -> Bool { date < expiresAt }
}

enum CodexDeviceBrowserChoice: Equatable {
    case dedicatedChrome
    case systemDefault
}

enum CodexDeviceBrowserState: Equatable { case opening, opened, unavailable }

enum CodexDeviceLoginIdentityCaption {
    static func text(_ language: WidgetLanguage) -> String {
        language.text("目标账号：", "Target account: ")
    }
}

enum CodexDeviceLoginHost: Equatable {
    case workbench
    case setupGuide
    case menu
}

enum CodexLoginStartResult: Equatable {
    case accepted(UUID)
    case blocked(CodexLoginBlockReason)
}

enum CodexLoginBlockReason: Equatable {
    case preview
    case shuttingDown
    case loginInProgress
    case launchingCodex
    case switchInProgress
    case warmingUp
    case readingAccounts
    case busy
    case systemProfile
    case profileMissing
    case cliUnavailable
    case mappingUnconfirmed

    var presentsPanel: Bool {
        switch self {
        case .cliUnavailable, .mappingUnconfirmed, .systemProfile: return true
        default: return false
        }
    }

    var loginFailure: CodexDeviceLoginFailure {
        switch self {
        case .cliUnavailable: return .cliUnavailable
        case .mappingUnconfirmed: return .mappingUnconfirmed
        case .systemProfile: return .systemProfile
        case .busy, .warmingUp, .readingAccounts, .loginInProgress, .launchingCodex, .switchInProgress:
            return .busy
        case .preview, .shuttingDown, .profileMissing:
            return .unavailable
        }
    }

    func message(_ language: WidgetLanguage) -> String {
        switch self {
        case .preview:
            return language.text("预览不会启动真实授权。", "Preview does not start a real authorization.")
        case .shuttingDown:
            return language.text("应用正在退出，已停止开始新的授权。", "The app is quitting. A new authorization was not started.")
        case .loginInProgress:
            return language.text("已有授权正在进行。请先完成或关闭当前登录面板。", "An authorization is already in progress. Finish or close the current sign-in panel first.")
        case .launchingCodex:
            return language.text("正在切换 Desktop 账号。完成后再添加或重新登录。", "Desktop is switching accounts. Add or sign in again after it finishes.")
        case .switchInProgress:
            return language.text("账号切换尚未完成。完成后再添加或重新登录。", "An account switch is still finishing. Add or sign in again after it completes.")
        case .warmingUp:
            return language.text("账号暖号正在执行；完成后再添加或重新登录。", "Wait for the current warm-up to finish before adding an account or signing in again.")
        case .readingAccounts:
            return language.text("账号数据仍在读取；完成后再添加或重新登录。", "Wait for account data to finish loading before adding an account or signing in again.")
        case .busy:
            return CodexDeviceLoginFailure.busy.message(language)
        case .systemProfile:
            return CodexDeviceLoginFailure.systemProfile.message(language)
        case .profileMissing:
            return language.text("找不到这张账号卡。请刷新列表后再试。", "This account card was not found. Refresh the list and try again.")
        case .cliUnavailable:
            return CodexDeviceLoginFailure.cliUnavailable.message(language)
        case .mappingUnconfirmed:
            return CodexDeviceLoginFailure.mappingUnconfirmed.message(language)
        }
    }
}

enum CodexDeviceCopyKind: Equatable { case code, url }

enum CodexDeviceCopyFeedback: Equatable {
    case codeCopied
    case urlCopied
    case failed

    static func from(wrote: Bool, kind: CodexDeviceCopyKind) -> CodexDeviceCopyFeedback {
        guard wrote else { return .failed }
        return kind == .code ? .codeCopied : .urlCopied
    }

    func message(_ language: WidgetLanguage) -> String {
        switch self {
        case .codeCopied:
            return language.text("授权代码已复制。", "Authorization code copied.")
        case .urlCopied:
            return language.text("官方网址已复制。", "Official URL copied.")
        case .failed:
            return language.text("无法写入剪贴板，请重试。", "Could not write to the clipboard. Try again.")
        }
    }
}

enum CodexDeviceLoginPhase: Equatable {
    case choosingBrowser
    case preparing
    case waiting(CodexDeviceAuthorization, CodexDeviceBrowserState)
    case cancelling
    case verifying
    case completed
    case quotaPending
    case expired
    case cancelled
    case failed(CodexDeviceLoginFailure)

    var authorization: CodexDeviceAuthorization? {
        if case .waiting(let authorization, _) = self { return authorization }
        return nil
    }

    var canDismiss: Bool {
        switch self {
        case .preparing, .waiting, .cancelling, .verifying: return false
        default: return true
        }
    }

    var canCancelAuthorization: Bool {
        switch self {
        case .preparing, .waiting: return true
        default: return false
        }
    }
}

enum CodexDeviceLoginFailure: Error, Equatable {
    case busy
    case unavailable
    case invalidResponse
    case identityMismatch
    case missingCredentials
    case verification
    case save
    case cliUnavailable
    case mappingUnconfirmed
    case systemProfile
    case accountAlreadyExists

    func message(_ language: WidgetLanguage) -> String {
        switch self {
        case .busy:
            return language.text("账号忙碌或状态未确认。请等任务结束后重试。", "This account is busy or unverified. Retry when its tasks have finished.")
        case .unavailable:
            return language.text("暂时无法完成授权。请检查网络，再重新生成代码。", "Authorization is unavailable. Check your connection, then generate a new code.")
        case .invalidResponse:
            return language.text(
                "未能读取有效的授权代码。请重新生成代码；若仍失败，请检查 Codex 更新。", "A valid authorization code could not be read. Generate a new code; if it fails again, check for a Codex update.")
        case .identityMismatch:
            return language.text(
                "浏览器登录的账号和这张账号卡不一致。原账号没有被覆盖，请切换到正确账号，再重新开始。",
                "The signed-in account does not match this card. Nothing was overwritten. Choose the correct account, then start again.")
        case .missingCredentials:
            return language.text("网页授权结束，但未收到有效的登录结果。请重新开始。", "Web authorization ended without a valid sign-in result. Please start again.")
        case .verification:
            return language.text("网页授权已结束，账号验证暂未完成。请重新检查身份和额度。", "Web authorization ended, but account verification is incomplete. Check identity and limits again.")
        case .save:
            return language.text("账号结果未能保存。请重新检查身份和额度。", "The account result could not be saved. Check identity and limits again.")
        case .cliUnavailable:
            return language.text("未找到 Codex CLI，无法开始设备授权。请安装官方 Codex 后再试。", "The Codex CLI was not found. Install official Codex, then try again.")
        case .mappingUnconfirmed:
            return language.text(
                "账号映射未确认，不能开始重新登录。请先检查该账号的独立资料和调度映射。", "Account mapping is unconfirmed. Check this isolated profile and its dispatch mapping before signing in again.")
        case .systemProfile:
            return language.text(
                "系统资料不能直接重新登录。请使用“设置独立 CLI”创建独立账号环境。", "The system profile cannot use isolated re-sign-in. Use “Set up isolated CLI” to create an isolated account.")
        case .accountAlreadyExists:
            return language.text("该账号已存在，请在原账号卡片重新登录。本次没有改动原账号。", "This account already exists. Sign in again from the original card. The original account was not changed.")
        }
    }
}

struct CodexDeviceLoginPresentation: Identifiable, Equatable {
    let id: UUID
    var profileID: String
    var targetName: String
    var phase: CodexDeviceLoginPhase
    var browserChoice: CodexDeviceBrowserChoice? = nil
    var copyFeedback: CodexDeviceCopyFeedback? = nil
    var copyFeedbackUntil: Date? = nil
    var notice: String? = nil
    var existingProfileID: String? = nil
}

enum CodexAddedProfileResolution: Equatable {
    case continueIndependent
    case duplicateIndependent(existingID: String)
}

enum CodexAddedProfileMatcher {
    static func resolve(accountID: String, newProfileID: String, profiles: [CodexProfile]) -> CodexAddedProfileResolution {
        if let existing = profiles.first(where: {
            $0.id != newProfileID && !$0.isSystemProfile && $0.lastSnapshot?.accountID == accountID
        }) {
            return .duplicateIndependent(existingID: existing.id)
        }
        return .continueIndependent
    }
}

enum CodexDeviceBrowserRouting {
    static func launchPlan(
        choice: CodexDeviceBrowserChoice,
        profile: CodexProfile
    ) -> (binding: ChromeProfileBinding?, managedUserDataDirectory: URL?) {
        switch choice {
        case .dedicatedChrome:
            return (nil, profile.codexHomeURL.appendingPathComponent("chrome-session", isDirectory: true))
        case .systemDefault:
            return (nil, nil)
        }
    }
}

/// The selected CLI prints a contextual full-line code and a 15-minute lifetime.
/// Bound total bytes, not just the unfinished line. Raw output never leaves this parser.
struct CodexDeviceCodeParser {
    static let officialURL = URL(string: "https://auth.openai.com/codex/device")!
    static let maximumBytes = 64 * 1_024
    private var buffer = Data()
    private var receivedBytes = 0
    private var contextLines = 0
    private var code: String?
    private var foundURL = false
    private let startedAt: Date
    private var expiresAt: Date

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        expiresAt = startedAt.addingTimeInterval(15 * 60)
    }

    var authorization: CodexDeviceAuthorization? {
        guard let code, foundURL else { return nil }
        return CodexDeviceAuthorization(code: code, url: Self.officialURL, expiresAt: expiresAt)
    }

    mutating func consume(_ chunk: Data) throws {
        guard chunk.count <= Self.maximumBytes - receivedBytes else { throw CodexDeviceLoginFailure.invalidResponse }
        receivedBytes += chunk.count
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            parse(line)
        }
    }

    mutating func finish() {
        if !buffer.isEmpty { parse(buffer) }
        buffer.removeAll(keepingCapacity: false)
    }

    private mutating func parse(_ data: Data) {
        let line = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{001B}\\][^\u{0007}]*\u{0007}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let lower = line.lowercased()
        // Never accept a URL embedded in an error or an arbitrary redirect.
        if lower.contains("error") || lower.contains("failed") || lower.contains("invalid") {
            contextLines = 0
            return
        }
        if line == Self.officialURL.absoluteString || line == Self.officialURL.absoluteString + "/" {
            foundURL = true
            return
        }
        if lower.contains("one-time code") || lower.contains("device code") {
            contextLines = 3
        } else if contextLines > 0 {
            if line.range(of: "^[A-Z0-9]{2,12}(-[A-Z0-9]{2,12}){1,3}$", options: .regularExpression) != nil {
                if code == nil { code = line }
                contextLines = 0
            } else {
                contextLines -= 1
            }
        }
        if contextLines > 0,
            let expression = try? NSRegularExpression(pattern: "expires in ([0-9]{1,3}) (minute|second)s?"),
            let match = expression.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
            let valueRange = Range(match.range(at: 1), in: lower),
            let unitRange = Range(match.range(at: 2), in: lower),
            let value = Double(lower[valueRange]), value > 0
        {
            let seconds = value * (lower[unitRange] == "minute" ? 60 : 1)
            expiresAt = startedAt.addingTimeInterval(min(seconds, 15 * 60))
        }
    }
}

enum CodexDeviceLoginVerification {
    static func hasFreshQuota(_ snapshot: UsageSnapshot, since startedAt: Date) -> Bool {
        snapshot.quotaReadSucceeded && snapshot.refreshedAt >= startedAt
            && (snapshot.fiveHourQuota != nil || snapshot.sevenDayQuota != nil || snapshot.monthlyQuota != nil)
    }
}
