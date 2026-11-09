#!/usr/bin/env python3
"""Execute production refresh actions and compare full task projections offline."""

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/CodexUsageWidget"


def braced(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    index = opening + 1
    while depth:
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
        index += 1
    return text[start:index], text[opening + 1:index - 1]


def read(relative):
    return (SOURCE / relative).read_text()


def compile_run(directory, name, contents, files=()):
    source = directory / (name + ".swift")
    source.write_text(contents)
    binary = directory / name
    subprocess.run(["swiftc", "-O", "-parse-as-library", *map(str, files), str(source), "-o", str(binary)],
                   cwd=ROOT, check=True, timeout=90)
    subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=30)


def refresh_fixture():
    _, action = braced(read("UI/TaskWorkbenchView.swift"), 'Button(language.text("刷新", "Refresh"))')
    production_view = read("UI/CodexAccountManagerView.swift")
    production_call = production_view[production_view.index("TaskWorkbenchView(model: store.taskWorkbench") :]
    _, callback = braced(production_call, "onRefresh:")
    method, _ = braced(read("Services/UsageStore.swift"), "@MainActor func refreshTaskWorkbench()")
    return """
import Foundation
import Darwin
@MainActor final class TaskClient {
    var requests = 0
    func refreshThreads() { requests += 1 }
}
@MainActor final class Workbench {
    var rebuilds = 0
    func rebuild() { rebuilds += 1 }
}
@MainActor final class Store {
    let taskClient = TaskClient()
    let taskWorkbench = Workbench()
""" + method + """
}
@main enum RefreshActionFixture {
    @MainActor static func main() {
        let store = Store()
        let model = store.taskWorkbench
        let onRefresh = { """ + callback + """ }
        let action = { """ + action + """ }
        action()
        guard store.taskClient.requests == 1 && model.rebuilds == 1 else {
            print("refresh-action failed: requests=\\(store.taskClient.requests), rebuilds=\\(model.rebuilds)")
            exit(1)
        }
        print("refresh-action passed: requests=1 rebuilds=1; real button/callback/store action bodies")
    }
}
"""


def projection_fixture():
    blocks = []
    for filename, declarations in (
        ("Domain/AgentRuntime.swift", ("enum RuntimeScope:", "enum RuntimeMenuStatus:")),
        ("Domain/UsageModels.swift", ("enum TaskColumnKind:", "struct TaskItem:", "struct TaskColumn:", "struct TaskBoard:")),
        ("Domain/TaskRuntime.swift", ("enum TaskSourceKind:", "enum TaskDisplayState:", "enum TaskStateBasis:",
                                     "enum TaskRuntimeState:", "enum TaskConnectionMode:", "struct TaskLiveRecord:",
                                     "struct CodexTaskLiveSnapshot:")),
    ):
        text = read(filename)
        blocks.extend(braced(text, declaration)[0] for declaration in declarations)
    policy = read("Domain/AutomaticAccountSwitch.swift")
    age = next(line.strip() for line in policy.splitlines() if line.strip().startswith("static let taskSnapshotMaximumAge"))
    baseline = subprocess.check_output(["git", "show", "HEAD:Sources/CodexUsageWidget/Domain/TaskOverviewPresentation.swift"],
                                       cwd=ROOT, text=True)
    builder, _ = braced(baseline, "enum TaskOverviewPresentationBuilder")
    builder = builder.replace("enum TaskOverviewPresentationBuilder", "enum BaselineTaskOverviewPresentationBuilder", 1)
    return "import Foundation\nimport Darwin\n" + "\n".join(blocks) + "\n" + """
enum WidgetLanguage { case en; func text(_ zh: String, _ en: String) -> String { en } }
struct UsageSnapshot: Equatable {
    var taskBoard: TaskBoard?
    static let empty = UsageSnapshot()
    func replacingTaskBoard(_ board: TaskBoard?) -> Self { Self(taskBoard: board) }
}
struct RuntimeUsageSnapshot: Equatable {
    let scope: RuntimeScope
    let snapshot: UsageSnapshot
    let status: RuntimeMenuStatus
    let quotaSourceLabel: String
    let usageSourceLabel: String
}
enum CodexAutomaticSwitchPolicy {
""" + age + "\n}\n" + builder + "\n" + """
@main enum ProjectionFixture {
    static func main() {
        guard TaskOverviewPresentationSelfTest.run() else { exit(1) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        func item(_ index: Int, state: TaskRuntimeState = .recorded, display: TaskDisplayState = .continueLater,
                  status: String? = nil, kind: TaskColumnKind = .pending) -> TaskItem {
            TaskItem(id: "item-\\(index)", code: "fixture", title: "Synthetic \\(index)", detail: "fixture",
                     chip: "fixture", updatedAt: now.addingTimeInterval(-Double(index)), tokens: nil,
                     kind: kind, threadID: "item-\\(index)", runtimeState: state, isRealtime: true,
                     sourceKind: .codexThread, displayState: display, stateBasis: .explicit, rawStatus: status)
        }
        let rows = [item(0, state: .running), item(1, state: .waitingInput), item(2, status: "approval"),
                    item(3, state: .failed), item(4, status: "blocked"), item(5, state: .completed),
                    item(6, state: .interrupted), item(7, state: .disconnected), item(8, display: .unknown),
                    item(9, display: .archived), item(10, display: .recentlyActive), item(11),
                    item(12, kind: .scheduled), item(11, status: "success")]
        let board = TaskBoard(refreshedAt: now, columns: [.init(id: .pending, title: "Fixture", count: rows.count, items: rows)])
        var comparisons = 0
        for age in [-6.0, -5.0, 0.0, CodexAutomaticSwitchPolicy.taskSnapshotMaximumAge,
                    CodexAutomaticSwitchPolicy.taskSnapshotMaximumAge + 1] {
            for mode in [TaskConnectionMode.sharedDaemon, .isolated, .disconnected] {
                let records = ["live-only": TaskLiveRecord(threadID: "live-only", name: "Synthetic live", state: .running,
                              updatedAt: now, turnID: nil, connectionMode: mode),
                               "yesterday": TaskLiveRecord(threadID: "yesterday", name: "Synthetic old", state: .completed,
                              updatedAt: now.addingTimeInterval(-86_400), turnID: nil, connectionMode: mode)]
                let live = CodexTaskLiveSnapshot(connectionMode: mode, records: records, refreshedAt: now.addingTimeInterval(-age))
                for status in [RuntimeMenuStatus.available, .stale, .unavailable] {
                    let runtimes = [RuntimeUsageSnapshot(scope: .codex, snapshot: .empty.replacingTaskBoard(board),
                                   status: status, quotaSourceLabel: "fixture", usageSourceLabel: "fixture")]
                    for maximum in [-1, 0, 1, 6, 1000, 1001] {
                        for includeAll in [false, true] {
                            let expected = BaselineTaskOverviewPresentationBuilder.make(runtimeSnapshots: runtimes,
                                codexLiveTasks: live, now: now, maximumItems: maximum, includeAllExisting: includeAll)
                            let actual = TaskOverviewPresentationBuilder.make(runtimeSnapshots: runtimes,
                                codexLiveTasks: live, now: now, maximumItems: maximum, includeAllExisting: includeAll)
                            guard expected == actual else { print("projection differs at age/mode/status/limit boundary"); exit(1) }
                            comparisons += 1
                        }
                    }
                }
            }
        }
        let large = (0..<1005).map { item($0, state: $0.isMultiple(of: 3) ? .running : .completed) }
        let largeBoard = TaskBoard(refreshedAt: now, columns: [.init(id: .pending, title: "Fixture", count: large.count, items: large)])
        let runtimes = [RuntimeUsageSnapshot(scope: .codex, snapshot: .empty.replacingTaskBoard(largeBoard),
                       status: .available, quotaSourceLabel: "fixture", usageSourceLabel: "fixture")]
        let live = CodexTaskLiveSnapshot(connectionMode: .sharedDaemon, records: [:], refreshedAt: now)
        for maximum in [0, 6, 1000, 1001] {
            let expected = BaselineTaskOverviewPresentationBuilder.make(runtimeSnapshots: runtimes, codexLiveTasks: live,
                now: now, maximumItems: maximum, includeAllExisting: true)
            let actual = TaskOverviewPresentationBuilder.make(runtimeSnapshots: runtimes, codexLiveTasks: live,
                now: now, maximumItems: maximum, includeAllExisting: true)
            guard expected == actual else { print("large projection differs"); exit(1) }
            comparisons += 1
        }
        print("projection-equivalence passed: \\(comparisons) full-result comparisons, including 1000-row truncation")
    }
}
"""


def main():
    with tempfile.TemporaryDirectory(prefix="agb-task-projection-") as temporary:
        directory = Path(temporary)
        compile_run(directory, "refresh-action", refresh_fixture())
        compile_run(directory, "projection", projection_fixture(), (
            SOURCE / "Domain/TaskOverviewPresentation.swift",
            SOURCE / "Domain/TaskOverviewPresentationSelfTest.swift",
        ))


if __name__ == "__main__":
    main()
