import Foundation

@main
struct WeChatBotTests {
    @MainActor static func main() async throws {
        var failures: [String] = []
        func expect(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("wechat-bot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = WeChatBotEventLedger(directory: directory)
        let now = Date()
        let event = try ledger.claim(owner: "synthetic-owner", messageID: "one", receivedAt: now)!
        expect(try ledger.claim(owner: "synthetic-owner", messageID: "one", receivedAt: now) == nil, "same-process duplicate")
        expect(try WeChatBotEventLedger(directory: directory).claim(owner: "synthetic-owner", messageID: "one", receivedAt: now) == nil, "restart duplicate")
        let thread = UUID().uuidString
        let turn = UUID().uuidString
        try ledger.mark(event, phase: .submitted, threadID: thread, turnID: turn)
        try ledger.mark(event, phase: .replyAttempted)
        try ledger.mark(event, phase: .uncertain)
        expect(try ledger.claim(owner: "synthetic-owner", messageID: "one", receivedAt: now) == nil, "uncertain never replay")
        do { _ = try ledger.claim(owner: "synthetic-owner", messageID: "old", receivedAt: now.addingTimeInterval(-121)); failures.append("stale claim") } catch {}
        let saved = try String(contentsOf: directory.appendingPathComponent("events-v1.json"), encoding: .utf8)
        expect(!saved.contains("synthetic-owner") && !saved.contains("one"), "no owner or raw message persisted")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("events-v1.json").path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private journal")
        var idle: [String: Any] = ["id": thread, "hostId": "local", "resumeState": "resumed", "requests": [Any](), "threadRuntimeStatus": ["type": "idle"]]
        expect(WeChatCodexConversation.isIdle(idle, threadID: thread), "fresh idle")
        var blocked = idle
        blocked["requests"] = [["id": "approval"]]
        expect(!WeChatCodexConversation.isIdle(blocked, threadID: thread), "pending request blocks")
        blocked = idle; blocked["threadGoal"] = ["status": "paused"]
        expect(!WeChatCodexConversation.isIdle(blocked, threadID: thread), "paused goal blocks")
        blocked = idle; blocked["hostId"] = "remote"
        expect(!WeChatCodexConversation.isIdle(blocked, threadID: thread), "wrong owner host")
        blocked = idle; blocked.removeValue(forKey: "requests")
        expect(!WeChatCodexConversation.isIdle(blocked, threadID: thread), "missing request state")
        let items: [[String: Any]] = [
            ["type": "agentMessage", "phase": "final_answer", "text": "public final"],
            ["type": "agentMessage", "phase": "commentary", "text": "partial secret"],
            ["type": "reasoning", "text": "private reasoning"],
            ["type": "commandExecution", "text": "tool secret"]]
        var complete = idle
        complete["turns"] = [["id": turn, "status": "completed", "items": items],
                             ["id": UUID().uuidString, "status": "completed", "items": [["type": "agentMessage", "phase": "final_answer", "text": "other turn"]]]]
        expect(WeChatCodexConversation.outcome(complete, turnID: turn) == .reply("public final"), "only matched final public message")
        expect(WeChatCodexConversation.outcome(complete, turnID: UUID().uuidString) == nil, "unmatched final ignored")
        var starts = 0
        var snapshots = 0
        let connection = WeChatCodexConversationConnection(owner: { _ in "synthetic-client" }, snapshot: { _, _ in
            snapshots += 1; return snapshots == 1 ? idle : complete
        }, start: { requestedThread, owner, eventID, text, admission in
            starts += 1
            if requestedThread != thread || owner != "synthetic-client" || eventID != event || text != "synthetic instruction" || !admission.isActive { return nil }
            return turn
        }, close: {})
        let relay = WeChatCodexConversation(connection: connection, pollIntervalNanoseconds: 1_000_000, timeout: 1)
        var submitted = 0
        let result = await relay.reply(threadID: thread, eventID: event, text: "synthetic instruction", shouldContinue: { true }, onSubmitted: { id in submitted += 1; return id == turn })
        expect(result == .reply("public final") && starts == 1 && submitted == 1, "single submission exact final")
        let ambiguous = WeChatCodexConversation(connection: .init(owner: { _ in "synthetic-client" }, snapshot: { _, _ in idle }, start: { _, _, _, _, _ in starts += 1; return nil }, close: {}), pollIntervalNanoseconds: 1_000_000, timeout: 1)
        let before = starts
        let uncertain = await ambiguous.reply(threadID: thread, eventID: UUID(), text: "synthetic instruction", shouldContinue: { true }, onSubmitted: { _ in true })
        expect(uncertain == .uncertain && starts == before + 1, "lost response no retry")
        let cancelled = await relay.reply(threadID: thread, eventID: UUID(), text: "synthetic instruction", shouldContinue: { false }, onSubmitted: { _ in true })
        expect(cancelled == .cancelled && starts == before + 1, "disabled admission no start")
        let busy = WeChatCodexConversation(connection: .init(owner: { _ in "synthetic-client" }, snapshot: { _, _ in blocked }, start: { _, _, _, _, _ in starts += 1; return turn }, close: {}))
        let busyResult = await busy.reply(threadID: thread, eventID: UUID(), text: "synthetic instruction", shouldContinue: { true }, onSubmitted: { _ in true })
        expect(busyResult == .busy && starts == before + 1, "unsafe snapshot no start")
        // Invalidate while owner discovery is in flight: no instruction is sent.
        var allowed = true
        let delayed = WeChatCodexConversation(connection: .init(owner: { _ in Thread.sleep(forTimeInterval: 0.05); return "synthetic-client" }, snapshot: { _, _ in idle }, start: { _, _, _, _, _ in starts += 1; return turn }, close: {}))
        let task = Task { @MainActor in await delayed.reply(threadID: thread, eventID: UUID(), text: "synthetic instruction", shouldContinue: { allowed }, onSubmitted: { _ in true }) }
        try await Task.sleep(nanoseconds: 5_000_000)
        let overlapping = await relay.reply(threadID: thread, eventID: UUID(), text: "synthetic instruction", shouldContinue: { true }, onSubmitted: { _ in true })
        expect(overlapping == .busy && starts == before + 1, "one local writer per original chat across features")
        allowed = false; task.cancel()
        expect(await task.value == .cancelled && starts == before + 1, "cancel during preflight no start")
        idle["threadGoalResumeConfirmation"] = true
        expect(!WeChatCodexConversation.isIdle(idle, threadID: thread), "human resume confirmation blocks")
        if failures.isEmpty { print("PASS WeChat bot: journal, privacy, owner admission, exact final, cancellation and no replay") }
        else { failures.forEach { print("FAIL " + $0) }; exit(1) }
    }
}
