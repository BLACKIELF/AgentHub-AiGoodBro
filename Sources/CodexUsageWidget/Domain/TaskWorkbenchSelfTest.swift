import Foundation

@MainActor
enum TaskWorkbenchSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        let now = Date()
        let thread = UUID().uuidString
        func task(_ title: String, state: TaskOverviewItemState = .completed, id: String = UUID().uuidString) -> TaskOverviewItem {
            TaskOverviewItem(id: "codex:" + id, title: title, state: state, updatedAt: now, runtimeScope: .codex, threadID: id)
        }
        func inventory(_ id: String, outcome: TaskOutcome, remaining: [String] = []) -> TaskWorkbenchInventory {
            TaskWorkbenchInventory(threadID: id, project: "Synthetic project", outcome: outcome, remaining: remaining,
                nextStep: "Verify evidence", artifacts: [], evidence: "Synthetic evidence only", checkedAt: now, sourceTurnID: nil)
        }
        let call = task("Light call candidate", id: thread)
        let textbook = task("Textbook inventory")
        let screenshot = task("Capture requires physical validation")
        let review = task("PR review manually cancelled", state: .waitingInput)
        let overview = TaskOverviewPresentation(dataState: .available, runtimeStatuses: [],
            items: [call, textbook, screenshot, review], totalItemCount: 4, needsAttentionCount: 1, runningCount: 0, recentlyEndedCount: 3)
        let annotations: [String: TaskWorkbenchAnnotation] = [
            call.id: .init(inventory: inventory(thread, outcome: .awaitingAcceptance)),
            textbook.id: .init(inventory: inventory(textbook.threadID!, outcome: .incomplete, remaining: ["Finish chapter"])),
            screenshot.id: .init(inventory: inventory(screenshot.threadID!, outcome: .candidate, remaining: ["Physical hotkey validation"])),
            review.id: .init(inventory: nil, decision: .cancelled, decisionAt: now)]
        let presentation = TaskWorkbenchPresentation.make(overview: overview,
            projectNames: [review.id: "PR review"], annotations: annotations, now: now)
        expect(presentation.items.first(where: { $0.id == call.id })?.outcome == .awaitingAcceptance, "turn completion is not acceptance")
        expect(presentation.items.first(where: { $0.id == textbook.id })?.outcome == .incomplete, "textbook unfinished")
        expect(presentation.items.first(where: { $0.id == screenshot.id })?.outcome == .candidate, "synthetic validation is not physical acceptance")
        expect(presentation.items.first(where: { $0.id == review.id })?.needsAttention == false, "manual cancellation overrides waiting state")
        expect(presentation.attention.count == 3 && !presentation.attention.contains(where: { $0.id == review.id }), "top three attention only")
        expect(presentation.projects.count == 2, "project grouping")
        let old = TaskWorkbenchInventory(threadID: thread, project: "Synthetic project", outcome: .candidate,
            remaining: [], nextStep: "Refresh inventory", artifacts: [], evidence: "Old result",
            checkedAt: now.addingTimeInterval(-60), sourceTurnID: nil)
        let stale = TaskWorkbenchItem(task: call, project: "Synthetic project", annotation: .init(inventory: old))
        expect(stale.inventoryIsStale && stale.outcome == .unknown && stale.needsAttention, "newer chat invalidates old semantic outcome")
        let confirmed = TaskWorkbenchItem(task: call, project: "Synthetic project",
            annotation: .init(inventory: old, decision: .completed, decisionAt: now))
        expect(confirmed.outcome == .complete && !confirmed.needsAttention, "manual acceptance survives new runtime evidence")
        let withoutProof = TaskWorkbenchPresentation.make(overview: overview, projectNames: [:], annotations: [:], now: now)
        expect(withoutProof.items.allSatisfy { $0.outcome == .unknown }, "missing semantic proof remains unknown")
        let object: [String: Any] = ["threadID": thread, "project": "Synthetic project", "outcome": "complete", "remaining": [], "nextStep": "Human acceptance", "artifacts": [], "evidence": "Only candidate evidence"]
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
        if failures.isEmpty { print("task workbench self-test passed: semantic outcomes, manual overrides, grouping, top-three attention, bounded import and persistence") }
        else { failures.forEach { print("task workbench self-test failed: " + $0) } }
        return failures.isEmpty
    }
}
