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

enum CodexDeviceBrowserState: Equatable { case opening, opened, unavailable }

enum CodexDeviceLoginPhase: Equatable {
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
}

enum CodexDeviceLoginFailure: Error, Equatable {
    case busy, unavailable, invalidResponse, identityMismatch, missingCredentials, verification, save

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
                "Chrome 登录的账号和这张账号卡不一致。原账号没有被覆盖，请在 Chrome 切换到正确账号，再重新开始。",
                "The Chrome account does not match this card. Nothing was overwritten. Choose the correct account in Chrome, then start again.")
        case .missingCredentials:
            return language.text("网页授权结束，但未收到有效的登录结果。请重新开始。", "Web authorization ended without a valid sign-in result. Please start again.")
        case .verification:
            return language.text("网页授权已结束，账号验证暂未完成。请重新检查身份和额度。", "Web authorization ended, but account verification is incomplete. Check identity and limits again.")
        case .save:
            return language.text("账号结果未能保存。请重新检查身份和额度。", "The account result could not be saved. Check identity and limits again.")
        }
    }
}

struct CodexDeviceLoginPresentation: Identifiable, Equatable {
    let id: UUID
    let profileID: String
    let targetName: String
    var phase: CodexDeviceLoginPhase
    var copiedUntil: Date?
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
