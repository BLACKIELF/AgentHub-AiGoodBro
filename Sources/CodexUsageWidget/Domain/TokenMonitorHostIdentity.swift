import CryptoKit
import Foundation

enum TokenMonitorHostIdentity {
    /// Matches upstream providers/codex/auth.js. Both identity components are
    /// required here: a workspace can have multiple members and vice versa.
    static func accountKey(email: String?, accountID: String?) -> String? {
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !email.isEmpty, !accountID.isEmpty, !email.contains("\0"), !accountID.contains("\0") else { return nil }
        let seed = Data("codex\0\(email)\0\(accountID)\0".utf8)
        return "sha256:" + SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined()
    }

    static func uniqueProfile(for key: String, profiles: [CodexProfile]) -> CodexProfile? {
        let candidates = profiles.filter {
            !$0.isSystemProfile && accountKey(email: $0.lastSnapshot?.email, accountID: $0.lastSnapshot?.accountID) == key
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

enum TokenMonitorWorkspaceNavigation {
    static let notification = Notification.Name("AiGoodBro.TokenMonitor.openWorkspace")
}

/// Sent only over the private host socket; never included in logs, receipts or
/// telemetry. The existing credential directory remains owned by AiGoodBro.
struct TokenMonitorManagedCodexAccount: Encodable, Sendable {
    let id: String
    let accountKey: String
    let workspaceAccountId: String
    let homePath: String
    let alias: String
    let enabled: Bool
}
