import Foundation

struct WeChatCodexConversationTarget: Identifiable, Equatable {
    let id: String
    let title: String
}

final class WeChatCodexSendAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }
    func cancel() {
        lock.lock()
        enabled = false
        lock.unlock()
    }
}

/// Injectable owner operations keep all verification tests off real Codex
/// accounts. Production uses the existing native same-user IPC transport.
struct WeChatCodexConversationConnection {
    let owner: (String) throws -> String?
    let snapshot: (String, String) throws -> [String: Any]
    let start: (String, String, UUID, String, WeChatCodexSendAdmission) throws -> String?
    let close: () -> Void

    static func live() -> Self {
        let ipc = CodexDesktopIPC()
        return Self(
            owner: { try ipc.discoverOwner(conversationId: $0) },
            snapshot: { try ipc.snapshot(conversationId: $0, ownerClientId: $1) },
            start: { thread, owner, id, text, admission in
                let envelope = try ipc.request(
                    method: "thread-follower-start-turn",
                    params: [
                        "conversationId": thread,
                        "turnStart": [
                            "request": [
                                "threadId": thread, "clientUserMessageId": id.uuidString.lowercased(),
                                "input": [["type": "text", "text": text, "text_elements": []]],
                            ],
                            "context": ["inheritThreadSettings": true],
                        ],
                    ], targetClientId: owner, timeout: 15, shouldSend: { admission.isActive })
                let result = envelope["result"] as? [String: Any]
                let nested = result?["result"] as? [String: Any]
                return ((nested?["turn"] ?? result?["turn"]) as? [String: Any])?["id"] as? String
            },
            close: { ipc.close() })
    }
}

@MainActor
final class WeChatCodexConversation {
    enum Outcome: Equatable {
        case reply(String)
        case busy
        case unavailable
        case awaitingHuman
        case failed
        case interrupted
        case timedOut
        case uncertain
        case cancelled
    }
    private let connection: WeChatCodexConversationConnection
    private let pollInterval: UInt64
    private let timeout: TimeInterval
    private(set) var isRunning = false
    private static var activeThreads = Set<String>()

    init(
        connection: WeChatCodexConversationConnection = .live(),
        pollIntervalNanoseconds: UInt64 = 5_000_000_000, timeout: TimeInterval = 15 * 60
    ) {
        self.connection = connection
        self.pollInterval = pollIntervalNanoseconds
        self.timeout = timeout
    }

    /// The controller durably claims the incoming ID before calling this.
    /// One owner request is made; timeout/disconnect never creates another writer.
    func reply(
        threadID: String, eventID: UUID, text: String,
        shouldContinue: @escaping () -> Bool,
        onSubmitted: @escaping (String) -> Bool
    ) async -> Outcome {
        guard !isRunning, !Self.activeThreads.contains(threadID) else { return .busy }
        guard UUID(uuidString: threadID) != nil, !text.isEmpty, text.utf8.count <= 4096 else { return .unavailable }
        guard shouldContinue(), !Task.isCancelled else { return .cancelled }
        isRunning = true
        Self.activeThreads.insert(threadID)
        defer {
            isRunning = false
            Self.activeThreads.remove(threadID)
            connection.close()
        }
        let connection = self.connection
        let prepared = await Task.detached(priority: .utility) { () -> (String, [String: Any])? in
            guard let owner = try? connection.owner(threadID),
                let state = try? connection.snapshot(threadID, owner)
            else { return nil }
            return (owner, state)
        }.value
        guard shouldContinue(), !Task.isCancelled else { return .cancelled }
        guard let (owner, state) = prepared else { return .unavailable }
        guard Self.identityMatches(state, threadID: threadID) else { return .unavailable }
        guard Self.isIdle(state, threadID: threadID) else {
            return Self.isAwaitingHuman(state) ? .awaitingHuman : .busy
        }

        let admission = WeChatCodexSendAdmission()
        let started = await withTaskCancellationHandler(
            operation: {
                await Task.detached(priority: .userInitiated) {
                    guard admission.isActive else { return nil as String? }
                    return try? connection.start(threadID, owner, eventID, text, admission)
                }.value
            }, onCancel: { admission.cancel() })
        guard shouldContinue(), !Task.isCancelled else { return .cancelled }
        guard let turnID = started, UUID(uuidString: turnID) != nil else { return .uncertain }
        guard onSubmitted(turnID) else { return .uncertain }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard shouldContinue(), !Task.isCancelled else { return .cancelled }
            let next = await Task.detached(priority: .utility) {
                try? connection.snapshot(threadID, owner)
            }.value
            guard shouldContinue(), !Task.isCancelled else { return .cancelled }
            guard let next, Self.identityMatches(next, threadID: threadID) else { return .unavailable }
            if let outcome = Self.outcome(next, turnID: turnID) { return outcome }
            if Self.isAwaitingHuman(next) { return .awaitingHuman }
            do { try await Task.sleep(nanoseconds: pollInterval) } catch { return .cancelled }
        }
        return .timedOut
    }

    nonisolated static func identityMatches(_ state: [String: Any], threadID: String) -> Bool {
        state["id"] as? String == threadID && state["hostId"] as? String == "local"
    }

    nonisolated static func isIdle(_ state: [String: Any], threadID: String) -> Bool {
        guard identityMatches(state, threadID: threadID), state["resumeState"] as? String == "resumed",
            (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String == "idle",
            let requests = state["requests"] as? [Any], requests.isEmpty
        else { return false }
        if let value = state["threadGoal"], !(value is NSNull) {
            guard let goal = value as? [String: Any], let status = goal["status"] as? String,
                status == "active"
            else { return false }
        }
        if let confirmation = state["threadGoalResumeConfirmation"],
            !(confirmation is NSNull), confirmation as? Bool != false
        {
            return false
        }
        return true
    }

    nonisolated static func isAwaitingHuman(_ state: [String: Any]) -> Bool {
        let runtime = state["threadRuntimeStatus"] as? [String: Any]
        let flags = runtime?["activeFlags"] as? [String] ?? []
        return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
    }

    /// Only the exact returned turn's final public assistant items may leave
    /// the app. Tool output, reasoning, other turns and partial text are ignored.
    nonisolated static func outcome(_ state: [String: Any], turnID: String) -> Outcome? {
        let turn: [String: Any]?
        if let turns = state["turns"] as? [[String: Any]],
            let found = turns.first(where: { ($0["turnId"] ?? $0["id"]) as? String == turnID })
        {
            turn = found
        } else if let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any],
            let entities = history["entitiesByKey"] as? [String: [String: Any]]
        {
            let matches = entities.values.filter { ($0["turnId"] ?? $0["id"]) as? String == turnID }
            turn = matches.count == 1 ? matches.first : nil
        } else {
            turn = nil
        }
        guard let turn, let status = turn["status"] as? String else { return nil }
        switch status {
        case "failed": return .failed
        case "interrupted": return .interrupted
        case "completed":
            guard let items = turn["items"] as? [[String: Any]], items.count <= 4096 else { return .unavailable }
            let text = items.filter { $0["type"] as? String == "agentMessage" && $0["phase"] as? String == "final_answer" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .unavailable : .reply(text)
        default: return nil
        }
    }
}
