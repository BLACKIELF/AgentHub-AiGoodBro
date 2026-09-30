import Foundation

enum TaskOverviewDataState: Equatable {
    case available
    case stale
    case disconnected
    case noData
}

enum TaskOverviewItemState: Equatable {
    case waitingInput
    case pendingApproval
    case failed
    case blocked
    case running
    case pending
    case recentlyActive
    case completed
    case interrupted
    case disconnected
    case unknown
    case archived
}

struct TaskOverviewItem: Identifiable, Equatable {
    let id: String
    let title: String
    let state: TaskOverviewItemState
    let updatedAt: Date?
    let runtimeScope: RuntimeScope
    let threadID: String?
}

struct TaskOverviewRuntimeStatus: Identifiable, Equatable {
    let scope: RuntimeScope
    let dataState: TaskOverviewDataState

    var id: String { scope.runtimeId }
}

struct TaskOverviewPresentation: Equatable {
    static let maximumItemCount = 6

    let dataState: TaskOverviewDataState
    let runtimeStatuses: [TaskOverviewRuntimeStatus]
    let items: [TaskOverviewItem]
    let totalItemCount: Int
    let needsAttentionCount: Int
    let runningCount: Int
    let recentlyEndedCount: Int

    var isTruncated: Bool { totalItemCount > items.count }
}

enum TaskOverviewPanelOpenAction: Equatable {
    case create
    case reuse
}

struct TaskOverviewPanelLifecycle: Equatable {
    private(set) var hasWindow = false
    private(set) var isObserving = false

    mutating func beginShowing() -> TaskOverviewPanelOpenAction {
        guard !hasWindow else { return .reuse }
        hasWindow = true
        isObserving = true
        return .create
    }

    mutating func finishClosing() {
        hasWindow = false
        isObserving = false
    }
}

enum TaskOverviewPresentationBuilder {
    static let titleMaximumLength = 48
    static let liveSnapshotMaximumAge = CodexAutomaticSwitchPolicy.taskSnapshotMaximumAge

    static func make(
        runtimeSnapshots: [RuntimeUsageSnapshot],
        codexLiveTasks: CodexTaskLiveSnapshot,
        now: Date = Date(),
        maximumItems: Int = TaskOverviewPresentation.maximumItemCount,
        includeAllExisting: Bool = false
    ) -> TaskOverviewPresentation {
        let liveIsFresh = isFresh(codexLiveTasks, now: now)
        var runtimeStatuses = runtimeSnapshots.map { runtime in
            TaskOverviewRuntimeStatus(
                scope: runtime.scope,
                dataState: dataState(
                    for: runtime,
                    codexLiveTasks: codexLiveTasks,
                    liveIsFresh: liveIsFresh
                )
            )
        }

        if includeAllExisting, !runtimeStatuses.contains(where: { $0.scope == .codex }) {
            runtimeStatuses.append(TaskOverviewRuntimeStatus(scope: .codex,
                dataState: codexLiveTasks.connectionMode == .disconnected ? .disconnected : liveIsFresh ? .available : .stale))
        }
        var candidates: [String: TaskOverviewItem] = [:]
        for runtime in runtimeSnapshots {
            guard let taskBoard = runtime.snapshot.taskBoard else { continue }
            for task in taskBoard.columns.flatMap(\.items) where task.kind != .scheduled {
                let key = itemKey(scope: runtime.scope, threadID: task.threadID, fallbackID: task.id)
                candidates[key] = makeItem(
                    task,
                    scope: runtime.scope,
                    allowRealtime: runtime.scope == .codex && liveIsFresh
                )
            }
        }

        if includeAllExisting || runtimeSnapshots.contains(where: { $0.scope == .codex }) {
            for record in codexLiveTasks.records.values {
                let key = itemKey(scope: .codex, threadID: record.threadID, fallbackID: record.threadID)
                guard includeAllExisting || candidates[key] != nil || shouldIncludeLiveOnly(record, now: now) else { continue }
                let fallback = candidates[key]
                let state: TaskOverviewItemState
                if liveIsFresh {
                    state = itemState(for: record.state, isRealtime: record.isRealtime)
                } else if codexLiveTasks.connectionMode == .disconnected,
                    record.state == .disconnected || record.state == .running || record.state == .waitingInput
                {
                    state = .disconnected
                } else {
                    state = fallback?.state ?? .unknown
                }
                candidates[key] = TaskOverviewItem(
                    id: key,
                    title: boundedTitle(record.name ?? fallback?.title),
                    state: state,
                    updatedAt: record.updatedAt ?? fallback?.updatedAt,
                    runtimeScope: .codex,
                    threadID: record.threadID
                )
            }
        }

        let allItems = candidates.values.sorted(by: isOrderedBefore)
        let visibleItems = Array(allItems.prefix(max(0, min(1000, maximumItems))))
        return TaskOverviewPresentation(
            dataState: aggregateDataState(runtimeStatuses),
            runtimeStatuses: runtimeStatuses,
            items: visibleItems,
            totalItemCount: allItems.count,
            needsAttentionCount: allItems.filter { item in
                switch item.state {
                case .waitingInput, .pendingApproval, .failed, .blocked:
                    return true
                default:
                    return false
                }
            }.count,
            runningCount: allItems.filter { $0.state == .running }.count,
            recentlyEndedCount: allItems.filter {
                $0.state == .completed || $0.state == .interrupted
            }.count
        )
    }

    private static func makeItem(
        _ task: TaskItem,
        scope: RuntimeScope,
        allowRealtime: Bool
    ) -> TaskOverviewItem {
        TaskOverviewItem(
            id: itemKey(scope: scope, threadID: task.threadID, fallbackID: task.id),
            title: boundedTitle(task.title),
            state: itemState(for: task, allowRealtime: allowRealtime),
            updatedAt: task.updatedAt,
            runtimeScope: scope,
            threadID: task.threadID
        )
    }

    private static func itemState(
        for task: TaskItem,
        allowRealtime: Bool
    ) -> TaskOverviewItemState {
        let rawStatus = task.rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if rawStatus.contains("approval") { return .pendingApproval }
        if rawStatus == "blocked" || task.displayState == .blocked { return .blocked }
        if rawStatus == "failed" || rawStatus == "error" || task.displayState == .failed {
            return .failed
        }
        // kind == .done is column membership only (archived threads are filed there
        // too); archive inference alone never proves completion. Evidence priority:
        // failure/blocked > explicit runner completion > live turn completion >
        // archive inference > activity-window fallbacks.
        if hasExplicitCompletionEvidence(rawStatus: rawStatus, task: task) { return .completed }
        switch task.runtimeState {
        case .completed:
            return .completed
        case .waitingInput where task.isRealtime && allowRealtime:
            return .waitingInput
        case .running where task.isRealtime && allowRealtime:
            return .running
        case .failed:
            return .failed
        case .interrupted:
            return .interrupted
        case .disconnected:
            return .disconnected
        case .recorded, .idle, .running, .waitingInput:
            break
        }
        if task.displayState == .archived || task.stateBasis == .archive { return .archived }
        switch task.displayState {
        case .recentlyActive:
            return .recentlyActive
        case .unknown:
            return .unknown
        default:
            return .pending
        }
    }

    private static func hasExplicitCompletionEvidence(
        rawStatus: String,
        task: TaskItem
    ) -> Bool {
        if task.displayState == .completed { return true }
        return rawStatus == "completed" || rawStatus == "done" || rawStatus == "success"
    }

    private static func itemState(
        for state: TaskRuntimeState,
        isRealtime: Bool
    ) -> TaskOverviewItemState {
        switch state {
        case .waitingInput where isRealtime:
            return .waitingInput
        case .running where isRealtime:
            return .running
        case .failed:
            return .failed
        case .completed:
            return .completed
        case .interrupted:
            return .interrupted
        case .disconnected:
            return .disconnected
        case .recorded:
            return .unknown
        case .idle, .running, .waitingInput:
            return .pending
        }
    }

    private static func dataState(
        for runtime: RuntimeUsageSnapshot,
        codexLiveTasks: CodexTaskLiveSnapshot,
        liveIsFresh: Bool
    ) -> TaskOverviewDataState {
        switch runtime.status {
        case .unavailable:
            return .disconnected
        case .stale, .snapshotNeeded:
            return .stale
        case .available, .localOnly:
            break
        }
        if runtime.scope == .codex {
            if codexLiveTasks.connectionMode == .disconnected { return .disconnected }
            if !liveIsFresh { return .stale }
            if runtime.snapshot.taskBoard == nil && codexLiveTasks.records.isEmpty { return .noData }
            return .available
        }
        return runtime.snapshot.taskBoard == nil ? .noData : .available
    }

    private static func aggregateDataState(
        _ runtimeStatuses: [TaskOverviewRuntimeStatus]
    ) -> TaskOverviewDataState {
        if runtimeStatuses.contains(where: { $0.dataState == .available }) { return .available }
        if runtimeStatuses.contains(where: { $0.dataState == .stale }) { return .stale }
        if runtimeStatuses.contains(where: { $0.dataState == .disconnected }) { return .disconnected }
        return .noData
    }

    private static func isFresh(_ snapshot: CodexTaskLiveSnapshot, now: Date) -> Bool {
        guard snapshot.connectionMode != .disconnected else { return false }
        let age = now.timeIntervalSince(snapshot.refreshedAt)
        return age >= -5 && age <= liveSnapshotMaximumAge
    }

    private static func shouldIncludeLiveOnly(_ record: TaskLiveRecord, now: Date) -> Bool {
        guard let updatedAt = record.updatedAt,
            Calendar.current.isDate(updatedAt, inSameDayAs: now)
        else { return false }
        switch record.state {
        case .running, .waitingInput, .failed, .completed, .interrupted:
            return true
        case .recorded, .idle, .disconnected:
            return false
        }
    }

    private static func isOrderedBefore(_ lhs: TaskOverviewItem, _ rhs: TaskOverviewItem) -> Bool {
        let leftPriority = priority(lhs.state)
        let rightPriority = priority(rhs.state)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        switch (lhs.updatedAt, rhs.updatedAt) {
        case (let left?, let right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
    }

    private static func priority(_ state: TaskOverviewItemState) -> Int {
        switch state {
        case .waitingInput: return 0
        case .pendingApproval: return 1
        case .failed: return 2
        case .blocked: return 3
        case .running: return 4
        case .pending: return 5
        case .disconnected: return 6
        case .unknown: return 7
        case .recentlyActive: return 8
        case .completed: return 9
        case .interrupted: return 10
        case .archived: return 11
        }
    }

    private static func itemKey(scope: RuntimeScope, threadID: String?, fallbackID: String) -> String {
        "\(scope.runtimeId):\(threadID ?? fallbackID)"
    }

    private static func boundedTitle(_ rawValue: String?) -> String {
        let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let singleLine = raw.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let fallback = singleLine.isEmpty ? "Untitled" : singleLine
        guard fallback.count > titleMaximumLength else { return fallback }
        return String(fallback.prefix(titleMaximumLength - 3)) + "..."
    }
}
