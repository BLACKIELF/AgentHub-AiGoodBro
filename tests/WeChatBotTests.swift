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
        expect(try ledger.reserveConversation(owner: "synthetic-owner") == .create, "first message reserves one creation")
        expect(try WeChatBotEventLedger(directory: directory).reserveConversation(owner: "synthetic-owner") == .uncertain, "restart never repeats ambiguous creation")
        try ledger.bindConversation(owner: "synthetic-owner", threadID: thread)
        expect(try WeChatBotEventLedger(directory: directory).reserveConversation(owner: "synthetic-owner") == .bound(thread), "restart reuses exact dedicated chat")
        expect(try ledger.conversationID(owner: "synthetic-other") == nil, "pairing owner isolation")
        expect(try ledger.reserveConversation(owner: "synthetic-other") == .create, "different owner gets own binding")
        try ledger.releaseUnsentConversation(owner: "synthetic-other")
        expect(try ledger.reserveConversation(owner: "synthetic-other") == .create, "definitely unsent creation can recover")
        do { try ledger.bindConversation(owner: "synthetic-owner", threadID: UUID().uuidString); failures.append("rebind protection") } catch {}
        do { try ledger.releaseUnsentConversation(owner: "synthetic-owner"); failures.append("bound conversation removal") } catch {}
        let bindingFile = directory.appendingPathComponent("conversations-v1.json")
        let bindingText = try String(contentsOf: bindingFile, encoding: .utf8)
        expect(!bindingText.contains("synthetic-owner") && !bindingText.contains("synthetic-other"), "binding contains no raw recipient")
        let bindingAttributes = try FileManager.default.attributesOfItem(atPath: bindingFile.path)
        expect((bindingAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "binding file is private")
        try ledger.mark(event, phase: .submitted, threadID: thread, turnID: turn)
        try ledger.mark(event, phase: .replyAttempted)
        try ledger.mark(event, phase: .uncertain)
        expect(try ledger.claim(owner: "synthetic-owner", messageID: "one", receivedAt: now) == nil, "uncertain never replay")
        do { _ = try ledger.claim(owner: "synthetic-owner", messageID: "old", receivedAt: now.addingTimeInterval(-121)); failures.append("stale claim") } catch {}
        let saved = try String(contentsOf: directory.appendingPathComponent("events-v1.json"), encoding: .utf8)
        expect(!saved.contains("synthetic-owner") && !saved.contains("one"), "no owner or raw message persisted")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("events-v1.json").path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private journal")
        let capacityDirectory = directory.appendingPathComponent("capacity")
        let capacity = WeChatBotEventLedger(directory: capacityDirectory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<512 {
            let time = start.addingTimeInterval(Double(i))
            let id = try capacity.claim(owner: "synthetic-capacity", messageID: "id-\(i)", receivedAt: time, now: time)!
            try capacity.mark(id, phase: .replyAttempted)
            try capacity.mark(id, phase: .accepted)
        }
        let current = start.addingTimeInterval(700)
        let restarted = WeChatBotEventLedger(directory: capacityDirectory)
        expect(try restarted.claim(owner: "synthetic-capacity", messageID: "fresh", receivedAt: current, now: current) != nil, "accepted records roll without capacity rejection")
        expect(try restarted.claim(owner: "synthetic-capacity", messageID: "replay-mutated-id", receivedAt: start.addingTimeInterval(500), now: start.addingTimeInterval(500)) == nil, "watermark blocks clock rollback and mutated ID replay")
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: capacityDirectory.appendingPathComponent("events-v1.json"))) as! [String: Any]
        expect(envelope["version"] as? Int == 2 && envelope["rejectedThrough"] != nil, "atomic journal envelope retains watermark")
        let mixedDirectory = directory.appendingPathComponent("mixed")
        let mixed = WeChatBotEventLedger(directory: mixedDirectory)
        let retained = try mixed.claim(owner: "synthetic-mixed", messageID: "pending", receivedAt: start, now: start)!
        let doneTime = start.addingTimeInterval(1)
        let done = try mixed.claim(owner: "synthetic-mixed", messageID: "done", receivedAt: doneTime, now: doneTime)!
        try mixed.mark(done, phase: .replyAttempted); try mixed.mark(done, phase: .accepted)
        _ = try mixed.claim(owner: "synthetic-mixed", messageID: "new", receivedAt: current, now: current)
        try mixed.mark(retained, phase: .uncertain)
        expect(try mixed.claim(owner: "synthetic-mixed", messageID: "pending", receivedAt: start, now: start) == nil, "watermark crossing does not erase unresolved ID")
        expect(try WeChatBotEventLedger(directory: mixedDirectory).claim(owner: "synthetic-mixed", messageID: "done", receivedAt: doneTime, now: doneTime) == nil, "restart rollback cannot replay compacted ID")
        let boundaryDirectory = directory.appendingPathComponent("boundary")
        let boundary = WeChatBotEventLedger(directory: boundaryDirectory)
        let accepted = try boundary.claim(owner: "synthetic-boundary", messageID: "accepted", receivedAt: start, now: start)!
        try boundary.mark(accepted, phase: .replyAttempted); try boundary.mark(accepted, phase: .accepted)
        let at125 = start.addingTimeInterval(125)
        _ = try boundary.claim(owner: "synthetic-boundary", messageID: "at125", receivedAt: at125, now: at125)
        var boundaryData = try JSONSerialization.jsonObject(with: Data(contentsOf: boundaryDirectory.appendingPathComponent("events-v1.json"))) as! [String: Any]
        expect((boundaryData["entries"] as? [[String: Any]])?.count == 2, "accepted exact125s is retained")
        let at126 = start.addingTimeInterval(126)
        _ = try boundary.claim(owner: "synthetic-boundary", messageID: "at126", receivedAt: at126, now: at126)
        boundaryData = try JSONSerialization.jsonObject(with: Data(contentsOf: boundaryDirectory.appendingPathComponent("events-v1.json"))) as! [String: Any]
        expect((boundaryData["entries"] as? [[String: Any]])?.count == 2, "accepted beyond125s is compacted")
        expect(try boundary.claim(owner: "synthetic-boundary", messageID: "at-watermark", receivedAt: start, now: start) == nil, "exact watermark boundary refuses new claim")
        let pendingDirectory = directory.appendingPathComponent("pending")
        let pending = WeChatBotEventLedger(directory: pendingDirectory)
        for i in 0..<512 { _ = try pending.claim(owner: "synthetic-pending", messageID: "pending-\(i)", receivedAt: start, now: start) }
        do { _ = try pending.claim(owner: "synthetic-pending", messageID: "overflow", receivedAt: current, now: current); failures.append("unresolved capacity must fail closed") } catch WeChatBotEventLedger.Failure.capacity {}
        expect(try pending.claim(owner: "synthetic-pending", messageID: "pending-0", receivedAt: current, now: current) == nil, "unresolved duplicates stay protected")
        let migrationDirectory = directory.appendingPathComponent("legacy")
        let migration = WeChatBotEventLedger(directory: migrationDirectory)
        _ = try migration.claim(owner: "synthetic-legacy", messageID: "original", receivedAt: start, now: start)
        let legacyURL = migrationDirectory.appendingPathComponent("events-v1.json")
        let originalEnvelope = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as! [String: Any]
        try JSONSerialization.data(withJSONObject: originalEnvelope["entries"]!).write(to: legacyURL)
        expect(try migration.claim(owner: "synthetic-legacy", messageID: "original", receivedAt: start, now: start) == nil, "legacy array duplicate preserved")
        _ = try migration.claim(owner: "synthetic-legacy", messageID: "new", receivedAt: start, now: start)
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as! [String: Any]
        expect(migrated["version"] as? Int == 2, "legacy array migrates on first write")
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
        var opened = 0
        var recoverySnapshots = 0
        var recoveryStarts = 0
        let recovered = WeChatCodexConversation(connection: .init(owner: { _ in opened == 0 ? nil : "synthetic-client" }, snapshot: { _, _ in
            recoverySnapshots += 1; return recoverySnapshots == 1 ? idle : complete
        }, start: { _, _, _, _, _ in recoveryStarts += 1; return turn }, close: {}), pollIntervalNanoseconds: 1_000_000, timeout: 1)
        let recoveredResult = await recovered.reply(threadID: thread, eventID: UUID(), text: "synthetic instruction", shouldContinue: { true }, openDedicatedThread: { opened += 1; return true }, onSubmitted: { $0 == turn })
        expect(recoveredResult == .reply("public final") && opened == 1 && recoveryStarts == 1, "dedicated chat opens then verifies owner before one submission")
        let absentOwner = WeChatCodexConversation(connection: .init(owner: { _ in nil }, snapshot: { _, _ in idle }, start: { _, _, _, _, _ in recoveryStarts += 1; return turn }, close: {}))
        let manualResult = await absentOwner.reply(threadID: thread, eventID: UUID(), text: "synthetic instruction", shouldContinue: { true }, onSubmitted: { _ in true })
        expect(manualResult == .unavailable && recoveryStarts == 1, "manual chat does not silently create or open a different chat")
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
