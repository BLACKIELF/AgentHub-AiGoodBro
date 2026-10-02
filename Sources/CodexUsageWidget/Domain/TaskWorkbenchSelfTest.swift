import Foundation

@MainActor
enum TaskWorkbenchSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        var checks = 0
        func expect(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures.append(name) }
        }
        let now = Date()
        let thread = UUID().uuidString
        func task(_ title: String, state: TaskOverviewItemState = .completed, id: String = UUID().uuidString) -> TaskOverviewItem {
            TaskOverviewItem(id: "codex:" + id, title: title, state: state, updatedAt: now, runtimeScope: .codex, threadID: id)
        }
        func inventory(_ id: String, outcome: TaskOutcome, remaining: [String] = []) -> TaskWorkbenchInventory {
            TaskWorkbenchInventory(
                threadID: id, project: "Synthetic project", outcome: outcome, remaining: remaining,
                nextStep: "Verify evidence", artifacts: [], evidence: "Synthetic evidence only", checkedAt: now, sourceTurnID: nil)
        }
        let call = task("Light call candidate", id: thread)
        let textbook = task("Textbook inventory")
        let screenshot = task("Capture requires physical validation")
        let review = task("PR review manually cancelled", state: .waitingInput)
        let overview = TaskOverviewPresentation(
            dataState: .available, runtimeStatuses: [],
            items: [call, textbook, screenshot, review], totalItemCount: 4, needsAttentionCount: 1, runningCount: 0, recentlyEndedCount: 3)
        let annotations: [String: TaskWorkbenchAnnotation] = [
            call.id: .init(inventory: inventory(thread, outcome: .awaitingAcceptance)),
            textbook.id: .init(inventory: inventory(textbook.threadID!, outcome: .incomplete, remaining: ["Finish chapter"])),
            screenshot.id: .init(inventory: inventory(screenshot.threadID!, outcome: .candidate, remaining: ["Physical hotkey validation"])),
            review.id: .init(inventory: nil, decision: .cancelled, decisionAt: now),
        ]
        let presentation = TaskWorkbenchPresentation.make(
            overview: overview,
            projectNames: [review.id: "PR review"], annotations: annotations, now: now)
        expect(presentation.items.first(where: { $0.id == call.id })?.outcome == .awaitingAcceptance, "turn completion is not acceptance")
        expect(presentation.items.first(where: { $0.id == textbook.id })?.outcome == .incomplete, "textbook unfinished")
        expect(presentation.items.first(where: { $0.id == screenshot.id })?.outcome == .candidate, "synthetic validation is not physical acceptance")
        expect(presentation.items.first(where: { $0.id == review.id })?.needsAttention == false, "manual cancellation overrides waiting state")
        expect(presentation.attention.count == 3 && !presentation.attention.contains(where: { $0.id == review.id }), "top three attention only")
        expect(presentation.projects.count == 2, "project grouping")
        expect(presentation.attentionCount == 3, "full attention count includes outcomes, excludes cancellation")
        expect(presentation.acceptanceCount == 2, "candidate and awaiting acceptance counted together")
        expect(presentation.filteredItems(filter: .attention).count == 3, "attention filter is not limited to the top-three panel")
        let extraWaiting = (0..<4).map { task("Additional attention \($0)", state: .waitingInput) }
        let fullOverview = TaskOverviewPresentation(
            dataState: .available, runtimeStatuses: [], items: overview.items + extraWaiting, totalItemCount: 8,
            needsAttentionCount: 5, runningCount: 0, recentlyEndedCount: 3)
        let fullPresentation = TaskWorkbenchPresentation.make(overview: fullOverview, projectNames: [:], annotations: annotations, now: now)
        expect(
            fullPresentation.filteredItems(filter: .attention).count == 7 && fullPresentation.attention.count == 3,
            "full attention view retains every item while the compact panel stays bounded")
        expect(presentation.filteredItems(filter: .deferred).map(\.id) == [review.id], "cancelled items remain searchable in their own filter")
        expect(presentation.filteredItems(query: "  TEXTBOOK  synthetic ").map(\.id) == [textbook.id], "case-insensitive multi-term metadata search")
        expect(presentation.filteredItems(project: "PR review", query: "textbook").isEmpty, "project and query must both match")
        expect(presentation.filteredItems(query: "Finish chapter").isEmpty, "search does not index inventory or transcript bodies")
        expect(presentation.filteredItems(query: " \n\t ").count == 4, "whitespace search retains all records")
        expect(presentation.filteredItems(query: "no matching task").isEmpty, "empty search result remains empty")
        expect(presentation.filteredItems(filter: .all).contains(where: { $0.id == review.id }), "all filter preserves manual decisions")
        let accented = task("Café Review", state: .running)
        let deferred = TaskWorkbenchItem(task: accented, project: "Project", annotation: .init(decision: .paused))
        expect(!deferred.needsAttention && deferred.attentionReason(.zh) == nil, "manual pause suppresses reminders")
        expect(TaskWorkbenchFilter.running.includes(deferred), "manual follow-up pause does not pretend the running turn stopped")
        expect(TaskWorkbenchFilter.deferred.includes(deferred), "paused work remains in deferred view")
        let waiting = TaskWorkbenchItem(task: review, project: "PR review", annotation: .init())
        expect(waiting.attentionReason(.zh) == "等待你补充信息", "waiting input has an actionable reason")
        expect(
            TaskWorkbenchItem(task: call, project: "Project", annotation: annotations[call.id]!).attentionReason(.en) == "Result ready for acceptance",
            "finished turn still needs acceptance")
        let accentOverview = TaskOverviewPresentation(
            dataState: .available, runtimeStatuses: [], items: [accented], totalItemCount: 1,
            needsAttentionCount: 0, runningCount: 1, recentlyEndedCount: 0)
        let accentPresentation = TaskWorkbenchPresentation.make(overview: accentOverview, projectNames: [:], annotations: [:], now: now)
        expect(accentPresentation.filteredItems(filter: .running, query: "CAFE").map(\.id) == [accented.id], "diacritic-insensitive search works with running filter")
        let old = TaskWorkbenchInventory(
            threadID: thread, project: "Synthetic project", outcome: .candidate,
            remaining: [], nextStep: "Refresh inventory", artifacts: [], evidence: "Old result",
            checkedAt: now.addingTimeInterval(-60), sourceTurnID: nil)
        let stale = TaskWorkbenchItem(task: call, project: "Synthetic project", annotation: .init(inventory: old))
        expect(stale.inventoryIsStale && stale.outcome == .unknown && stale.needsAttention, "newer chat invalidates old semantic outcome")
        let confirmed = TaskWorkbenchItem(
            task: call, project: "Synthetic project",
            annotation: .init(inventory: old, decision: .completed, decisionAt: now))
        expect(confirmed.outcome == .complete && !confirmed.needsAttention, "manual acceptance survives new runtime evidence")
        let withoutProof = TaskWorkbenchPresentation.make(overview: overview, projectNames: [:], annotations: [:], now: now)
        expect(withoutProof.items.allSatisfy { $0.outcome == .unknown }, "missing semantic proof remains unknown")
        let object: [String: Any] = [
            "threadID": thread, "project": "Synthetic project", "outcome": "complete", "remaining": [], "nextStep": "Human acceptance", "artifacts": [],
            "evidence": "Only candidate evidence",
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8)!
        expect((try? TaskWorkbenchInventory.parse(text, threadID: thread, sourceTurnID: nil))?.outcome == .awaitingAcceptance, "model cannot self-approve complete")
        expect((try? TaskWorkbenchInventory.parse(text, threadID: UUID().uuidString, sourceTurnID: nil)) == nil, "inventory bound to selected chat")
        expect(!TaskWorkbenchInventory.safeText("Bearer syntheticCredential1234567890", limit: 800), "obvious credentials rejected")
        expect(TaskWorkbenchArtifact(title: "Executable", reference: "/tmp/unsafe.sh").url == nil, "artifact cannot launch shell")
        expect(TaskWorkbenchArtifact(title: "Credential URL", reference: "https://name:pass@example.invalid/item").url == nil, "artifact excludes URL credentials")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("task-workbench-fixture-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("inventory-v1.json")
        let store = TaskWorkbenchStore(file: file)
        let row = TaskWorkbenchItem(task: call, project: "Synthetic project", annotation: .init())
        store.setDecision(.cancelled, for: row)
        store.importInventory(data: data, for: row)
        do {
            let saved = try JSONDecoder().decode([String: TaskWorkbenchAnnotation].self, from: Data(contentsOf: file))
            expect(saved[call.id]?.decision == .cancelled, "inventory import preserves cancellation")
            expect(saved[call.id]?.inventory?.outcome == .awaitingAcceptance, "bounded local inventory saved")
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            expect(permissions?.intValue == 0o600, "private inventory record")
            let restarted = TaskWorkbenchStore(file: file)
            expect(restarted.status == nil, "restart reads valid persisted record")
            restarted.stop()
        } catch { failures.append("local inventory persistence") }
        store.stop()
        if failures.isEmpty {
            print("task workbench self-test passed: \(checks) checks; outcomes, manual overrides, filters, metadata search, attention reasons, bounded import and persistence")
        } else {
            failures.forEach { print("task workbench self-test failed: " + $0) }
        }
        return failures.isEmpty
    }

    /// Synthetic metadata only. Measures local projection, not inference or network latency.
    static func measureMetadataSearch(filter: TaskWorkbenchFilter = .attention) -> [String: Double] {
        let now = Date(timeIntervalSince1970: 1_790_756_000)
        let tasks = (0..<1000).map { index in
            TaskOverviewItem(
                id: "benchmark-\(index)", title: "Synthetic review \(index)",
                state: index.isMultiple(of: 3) ? .waitingInput : .running,
                updatedAt: now, runtimeScope: .codex, threadID: nil)
        }
        let overview = TaskOverviewPresentation(
            dataState: .available, runtimeStatuses: [], items: tasks, totalItemCount: 1000,
            needsAttentionCount: 334, runningCount: 666, recentlyEndedCount: 0)
        let presentation = TaskWorkbenchPresentation.make(
            overview: overview, projectNames: [:], annotations: [:], now: now)
        var samples: [Double] = []
        var resultCount = 0
        for index in 0..<105 {
            let start = ProcessInfo.processInfo.systemUptime
            let matches = presentation.filteredItems(filter: filter, query: "synthetic review")
            resultCount = matches.count
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if index >= 5 { samples.append(elapsed) }
        }
        samples.sort()
        return [
            "rows": 1000, "measuredRuns": 100, "warmupRuns": 5,
            "resultRows": Double(resultCount), "medianMilliseconds": samples[50], "p95Milliseconds": samples[94],
        ]
    }
}
