import Foundation

/// The only task identity retained for an interrupted Desktop turn.
struct CodexPausedDesktopTurn: Codable, Equatable, Identifiable {
    let threadID: String
    let turnID: String

    var id: String { "\(threadID):\(turnID)" }

    var isValid: Bool {
        [threadID, turnID].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 128
                && $0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        }
    }
}
