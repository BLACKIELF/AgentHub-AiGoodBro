import Foundation

enum TaskSourceKind: String, Equatable {
    case codexThread
    case codexAutomation
    case claudeTask
}

enum TaskDisplayState: String, Equatable {
    case recentlyActive
    case continueLater
    case scheduled
    case archived
    case running
    case pending
    case failed
    case blocked
    case completed
    case unknown
}

enum TaskStateBasis: String, Equatable {
    case activityWindow
    case archive
    case scheduleConfig
    case explicit
}

struct TaskClassification: Equatable {
    let columnKind: TaskColumnKind
    let displayState: TaskDisplayState
}

enum TaskSourceClassifier {
    static func codexThread(updatedAt: Date?, now: Date) -> TaskClassification {
        let kind = TaskActivityClassifier.column(updatedAt: updatedAt, now: now)
        return TaskClassification(
            columnKind: kind,
            displayState: kind == .active ? .recentlyActive : .continueLater
        )
    }

    static func claudeTask(rawStatus: String?) -> TaskClassification {
        switch rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "in_progress", "active", "running":
            return TaskClassification(columnKind: .active, displayState: .running)
        case "pending":
            return TaskClassification(columnKind: .pending, displayState: .pending)
        case "failed", "error":
            return TaskClassification(columnKind: .pending, displayState: .failed)
        case "blocked":
            return TaskClassification(columnKind: .pending, displayState: .blocked)
        case "scheduled":
            return TaskClassification(columnKind: .scheduled, displayState: .scheduled)
        case "completed", "done", "success":
            return TaskClassification(columnKind: .done, displayState: .completed)
        default:
            return TaskClassification(columnKind: .pending, displayState: .unknown)
        }
    }
}

struct TaskSchedulePresentation: Equatable {
    let summary: String
    let nextRunAt: Date?
}

enum TaskScheduleParser {
    static func presentation(rrule: String?, now: Date) -> TaskSchedulePresentation {
        guard let rrule = rrule?.trimmingCharacters(in: .whitespacesAndNewlines), !rrule.isEmpty else {
            return TaskSchedulePresentation(summary: "", nextRunAt: nil)
        }

        let parsed = ParsedRule(rrule)
        return TaskSchedulePresentation(
            summary: parsed.summary,
            nextRunAt: parsed.nextRunAt(after: now)
        )
    }

    private struct ParsedRule {
        let fields: [String: String]
        let timeZone: TimeZone?
        let startDate: Date?
        let hour: Int?
        let minute: Int?
        let weekdays: [Int]

        init(_ rawRule: String) {
            let lines =
                rawRule
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            let startLine = lines.first { $0.uppercased().hasPrefix("DTSTART") }
            let ruleLine =
                lines.first { $0.uppercased().hasPrefix("RRULE:") }
                ?? lines.first { $0.uppercased().contains("FREQ=") }
                ?? rawRule
            let ruleBody =
                ruleLine.uppercased().hasPrefix("RRULE:")
                ? String(ruleLine.dropFirst("RRULE:".count))
                : ruleLine

            var parsedFields: [String: String] = [:]
            for component in ruleBody.split(separator: ";") {
                let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                parsedFields[pair[0].uppercased()] = pair[1].uppercased()
            }
            fields = parsedFields

            let startParts = Self.parseStartLine(startLine)
            timeZone = startParts.timeZone
            startDate = startParts.date

            let explicitHour = parsedFields["BYHOUR"].flatMap(Int.init)
            let explicitMinute = parsedFields["BYMINUTE"].flatMap(Int.init)
            if explicitHour != nil, explicitMinute != nil {
                hour = explicitHour
                minute = explicitMinute
            } else if let startDate, let timeZone {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                let components = calendar.dateComponents([.hour, .minute], from: startDate)
                hour = components.hour
                minute = components.minute
            } else {
                hour = nil
                minute = nil
            }

            weekdays = (parsedFields["BYDAY"] ?? "")
                .split(separator: ",")
                .compactMap { Self.weekdayNumber(String($0)) }
        }

        var summary: String {
            let frequency = fields["FREQ"] ?? ""
            let interval = fields["INTERVAL"].flatMap(Int.init) ?? 1
            let time = hour.flatMap { hour in
                minute.map { String(format: "%02d:%02d", hour, $0) }
            }

            switch frequency {
            case "DAILY":
                return ["每天", time].compactMap { $0 }.joined(separator: " ")
            case "WEEKLY":
                let dayText: String
                if weekdays == [2, 3, 4, 5, 6] {
                    dayText = "工作日"
                } else if weekdays.isEmpty {
                    dayText = "每周"
                } else {
                    dayText = "每周" + weekdays.compactMap(Self.chineseWeekday).joined()
                }
                return [dayText, time].compactMap { $0 }.joined(separator: " ")
            case "HOURLY":
                return interval == 1 ? "每小时" : "每 \(interval) 小时"
            case "MINUTELY":
                return interval == 1 ? "每分钟" : "每 \(interval) 分钟"
            default:
                return time ?? "定时"
            }
        }

        func nextRunAt(after now: Date) -> Date? {
            guard fields["INTERVAL"].flatMap(Int.init) ?? 1 == 1,
                let timeZone,
                let hour,
                let minute,
                (0...23).contains(hour),
                (0...59).contains(minute)
            else { return nil }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let lowerBound = startDate.map { max(now, $0.addingTimeInterval(-1)) } ?? now

            switch fields["FREQ"] {
            case "DAILY":
                return calendar.nextDate(
                    after: lowerBound,
                    matching: DateComponents(hour: hour, minute: minute, second: 0),
                    matchingPolicy: .nextTime,
                    direction: .forward
                )
            case "WEEKLY":
                let effectiveWeekdays: [Int]
                if !weekdays.isEmpty {
                    effectiveWeekdays = weekdays
                } else if let startDate {
                    effectiveWeekdays = [calendar.component(.weekday, from: startDate)]
                } else {
                    return nil
                }
                return effectiveWeekdays.compactMap { weekday in
                    var components = DateComponents()
                    components.weekday = weekday
                    components.hour = hour
                    components.minute = minute
                    components.second = 0
                    return calendar.nextDate(
                        after: lowerBound,
                        matching: components,
                        matchingPolicy: .nextTime,
                        direction: .forward
                    )
                }.min()
            default:
                return nil
            }
        }

        private static func parseStartLine(_ line: String?) -> (timeZone: TimeZone?, date: Date?) {
            guard let line,
                let separator = line.lastIndex(of: ":")
            else { return (nil, nil) }
            let prefix = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard let zoneRange = prefix.range(of: "TZID=", options: .caseInsensitive) else {
                return (nil, nil)
            }
            let identifier = String(prefix[zoneRange.upperBound...])
            guard let timeZone = TimeZone(identifier: identifier) else { return (nil, nil) }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = value.count == 13 ? "yyyyMMdd'T'HHmm" : "yyyyMMdd'T'HHmmss"
            return (timeZone, formatter.date(from: value))
        }

        private static func weekdayNumber(_ value: String) -> Int? {
            switch value.uppercased() {
            case "SU": return 1
            case "MO": return 2
            case "TU": return 3
            case "WE": return 4
            case "TH": return 5
            case "FR": return 6
            case "SA": return 7
            default: return nil
            }
        }

        private static func chineseWeekday(_ value: Int) -> String? {
            switch value {
            case 1: return "日"
            case 2: return "一"
            case 3: return "二"
            case 4: return "三"
            case 5: return "四"
            case 6: return "五"
            case 7: return "六"
            default: return nil
            }
        }
    }
}

enum TaskRuntimeState: String, Equatable {
    case recorded
    case idle
    case running
    case waitingInput
    case failed
    case completed
    case interrupted
    case disconnected

    var columnKind: TaskColumnKind {
        switch self {
        case .running, .waitingInput:
            return .active
        case .completed:
            return .done
        case .recorded, .idle, .failed, .interrupted, .disconnected:
            return .pending
        }
    }
}

/// A small, main-thread-owned generation gate for asynchronous task
/// operations.  A completion may retain its captured state for a while after
/// cancellation; callers must check the generation before applying it.
struct TaskTransactionGeneration: Equatable {
    private(set) var value: UInt64 = 0

    @discardableResult
    mutating func begin() -> UInt64 {
        advance()
        return value
    }

    mutating func invalidate() {
        advance()
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == value
    }

    private mutating func advance() {
        value = value == UInt64.max ? 0 : value + 1
    }
}

enum TaskConnectionMode: String, Equatable {
    case disconnected
    case sharedDaemon
    case isolated
}

enum TaskActivityClassifier {
    static let activeWindow: TimeInterval = 2 * 60 * 60

    static func column(updatedAt: Date?, now: Date) -> TaskColumnKind {
        guard let updatedAt else { return .pending }
        return updatedAt >= now.addingTimeInterval(-activeWindow) ? .active : .pending
    }
}

enum TaskThreadVisibility {
    static func isSubagent(_ thread: [String: Any]) -> Bool {
        let directSource =
            (thread["threadSource"] as? String)
            ?? (thread["thread_source"] as? String)
        if directSource?.lowercased() == "subagent" { return true }

        if let source = thread["source"] as? String {
            return source.lowercased() == "subagent"
        }
        if let source = thread["source"] as? [String: Any] {
            return source.keys.contains { $0.lowercased() == "subagent" }
        }
        return false
    }
}

struct TaskLiveRecord: Equatable {
    let threadID: String
    let name: String?
    let state: TaskRuntimeState
    let updatedAt: Date?
    let turnID: String?
    let connectionMode: TaskConnectionMode

    var isRealtime: Bool {
        connectionMode != .disconnected && state != .recorded && state != .disconnected
    }
}

struct CodexTaskLiveSnapshot: Equatable {
    let connectionMode: TaskConnectionMode
    let records: [String: TaskLiveRecord]
    let refreshedAt: Date

    static let disconnected = CodexTaskLiveSnapshot(
        connectionMode: .disconnected,
        records: [:],
        refreshedAt: .distantPast
    )
}

struct TaskRuntimeReducer {
    private(set) var connectionMode: TaskConnectionMode = .disconnected
    private var records: [String: TaskLiveRecord] = [:]
    private var notificationGeneration: UInt64 = 0
    private var lastNotificationGenerationByThread: [String: UInt64] = [:]

    /// The boundary a `thread/list` request should capture before it is sent.
    /// Notifications accepted after this value are newer than that response's
    /// server snapshot and must win over it.
    var currentNotificationGeneration: UInt64 {
        notificationGeneration
    }

    mutating func replaceThreads(
        _ threads: [[String: Any]],
        connectionMode: TaskConnectionMode,
        requestGeneration: UInt64? = nil
    ) {
        self.connectionMode = connectionMode
        let requestBoundary = requestGeneration ?? notificationGeneration
        var nextRecords: [String: TaskLiveRecord] = [:]

        for thread in threads {
            guard let threadID = thread["id"] as? String else { continue }
            let previous = records[threadID]
            let state = Self.runtimeState(from: thread["status"] as? [String: Any])
            let updatedAt = Self.dateFromSeconds(thread["updatedAt"])
            let rawName = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName.flatMap { $0.isEmpty ? nil : $0 }

            if let previous,
                lastNotificationGenerationByThread[threadID].map({ $0 > requestBoundary }) == true
            {
                // A notification accepted after this request was emitted is
                // newer evidence than the list payload, even if the server's
                // updatedAt is older or absent.  Keep its state and turn
                // identity, while allowing the list to refresh a title.
                nextRecords[threadID] = TaskLiveRecord(
                    threadID: threadID,
                    name: name ?? previous.name,
                    state: previous.state,
                    updatedAt: previous.updatedAt,
                    turnID: previous.turnID,
                    connectionMode: connectionMode
                )
            } else {
                nextRecords[threadID] = TaskLiveRecord(
                    threadID: threadID,
                    name: name ?? previous?.name,
                    state: state,
                    updatedAt: updatedAt ?? previous?.updatedAt,
                    turnID: previous?.turnID,
                    connectionMode: connectionMode
                )
                // The list caught up with all notifications known when the
                // request was emitted.  Do not let this marker protect the
                // record forever.
                lastNotificationGenerationByThread.removeValue(forKey: threadID)
            }
        }

        // A bounded list can omit a thread that was changed after the request
        // was sent.  Retain that newer evidence for this response; if the next
        // request still omits it without another notification, it is dropped.
        for (threadID, previous) in records where nextRecords[threadID] == nil {
            guard lastNotificationGenerationByThread[threadID].map({ $0 > requestBoundary }) == true else {
                lastNotificationGenerationByThread.removeValue(forKey: threadID)
                continue
            }
            nextRecords[threadID] = TaskLiveRecord(
                threadID: previous.threadID,
                name: previous.name,
                state: previous.state,
                updatedAt: previous.updatedAt,
                turnID: previous.turnID,
                connectionMode: connectionMode
            )
        }

        records = nextRecords
    }

    @discardableResult
    mutating func applyNotification(method: String, params: [String: Any]) -> Bool {
        switch method {
        case "thread/status/changed":
            guard let threadID = params["threadId"] as? String else { return false }
            updateRecord(
                threadID: threadID,
                state: Self.runtimeState(from: params["status"] as? [String: Any]),
                updatedAt: Date()
            )
            return true

        case "turn/started":
            guard let threadID = params["threadId"] as? String else { return false }
            let turn = params["turn"] as? [String: Any]
            updateRecord(
                threadID: threadID,
                state: .running,
                updatedAt: Date(),
                turnID: turn?["id"] as? String
            )
            return true

        case "turn/completed":
            guard let threadID = params["threadId"] as? String,
                let turn = params["turn"] as? [String: Any]
            else { return false }
            let incomingTurnID = turn["id"] as? String
            if let previousTurnID = records[threadID]?.turnID,
                let incomingTurnID,
                incomingTurnID != previousTurnID
            {
                // A late completion from an older turn must not finish the
                // newer turn that is currently represented by this record.
                return false
            }
            let state = Self.turnState(turn["status"] as? String)
            if let previous = records[threadID],
                let incomingTurnID,
                previous.turnID == incomingTurnID,
                Self.isTerminal(previous.state),
                Self.isTerminal(state)
            {
                // Replayed terminal events are idempotent.  In particular,
                // do not refresh the activity timestamp or generation for a
                // duplicate completion that could race a list response.
                return false
            }
            updateRecord(
                threadID: threadID,
                state: state,
                updatedAt: Date(),
                turnID: incomingTurnID
            )
            return true

        case "item/completed":
            guard let threadID = params["threadId"] as? String,
                let item = params["item"] as? [String: Any]
            else { return false }
            let status = item["status"] as? String
            if status == "failed" {
                let incomingTurnID = Self.turnID(from: params, item: item)
                if let previous = records[threadID] {
                    if let previousTurnID = previous.turnID,
                        let incomingTurnID,
                        incomingTurnID != previousTurnID
                    {
                        return false
                    }
                    // An individual failed item does not prove that the
                    // current turn stopped.  Wait for its turn/completed
                    // event instead of downgrading a running turn.
                    guard previous.state != .running, previous.state != .waitingInput else {
                        return false
                    }
                }
                updateRecord(threadID: threadID, state: .failed, updatedAt: Date())
                return true
            }
            return false

        default:
            return false
        }
    }

    mutating func disconnect() {
        connectionMode = .disconnected
        lastNotificationGenerationByThread.removeAll()
        records = records.mapValues { record in
            let disconnectedState: TaskRuntimeState
            switch record.state {
            case .running, .waitingInput:
                disconnectedState = .disconnected
            default:
                disconnectedState = record.state
            }
            return TaskLiveRecord(
                threadID: record.threadID,
                name: record.name,
                state: disconnectedState,
                updatedAt: record.updatedAt,
                turnID: record.turnID,
                connectionMode: .disconnected
            )
        }
    }

    func snapshot(at date: Date = Date()) -> CodexTaskLiveSnapshot {
        CodexTaskLiveSnapshot(
            connectionMode: connectionMode,
            records: records,
            refreshedAt: date
        )
    }

    private mutating func updateRecord(
        threadID: String,
        state: TaskRuntimeState,
        updatedAt: Date?,
        turnID: String? = nil
    ) {
        notificationGeneration = notificationGeneration == UInt64.max ? 0 : notificationGeneration + 1
        lastNotificationGenerationByThread[threadID] = notificationGeneration
        let previous = records[threadID]
        records[threadID] = TaskLiveRecord(
            threadID: threadID,
            name: previous?.name,
            state: state,
            updatedAt: updatedAt ?? previous?.updatedAt,
            turnID: turnID ?? previous?.turnID,
            connectionMode: connectionMode
        )
    }

    private static func runtimeState(from status: [String: Any]?) -> TaskRuntimeState {
        guard let type = status?["type"] as? String else { return .recorded }
        switch type {
        case "active":
            let flags = status?["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnUserInput") { return .waitingInput }
            return .running
        case "idle":
            return .idle
        case "notLoaded":
            return .idle
        case "systemError":
            // A daemon/system error is not a verified terminal turn failure.
            return .recorded
        default:
            return .recorded
        }
    }

    private static func turnState(_ status: String?) -> TaskRuntimeState {
        switch status {
        case "completed":
            return .completed
        case "interrupted":
            return .interrupted
        case "failed":
            return .failed
        case "inProgress":
            return .running
        default:
            return .recorded
        }
    }

    private static func turnID(from params: [String: Any], item: [String: Any]) -> String? {
        (params["turnId"] as? String)
            ?? (params["turnID"] as? String)
            ?? (item["turnId"] as? String)
            ?? (item["turnID"] as? String)
    }

    private static func isTerminal(_ state: TaskRuntimeState) -> Bool {
        switch state {
        case .completed, .failed, .interrupted:
            return true
        case .recorded, .idle, .running, .waitingInput, .disconnected:
            return false
        }
    }

    private static func dateFromSeconds(_ value: Any?) -> Date? {
        if let value = value as? Int { return Date(timeIntervalSince1970: TimeInterval(value)) }
        if let value = value as? Int64 { return Date(timeIntervalSince1970: TimeInterval(value)) }
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        return nil
    }

}

enum TaskAttentionKind: Int, Equatable {
    case userInput = 0
    case failure = 1
    case dataIssue = 2
    case update = 3
}

struct TaskAttentionItem: Identifiable, Equatable {
    let id: String
    let kind: TaskAttentionKind
    let runtimeScope: RuntimeScope?
    let threadID: String?
    let title: String
    let since: Date?
}

struct TaskFocusRequest: Equatable {
    let id: UUID
    let runtimeScope: RuntimeScope
    let threadID: String?
}

enum TaskAttentionSelector {
    static func highestPriority(_ items: [TaskAttentionItem]) -> TaskAttentionItem? {
        items.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            switch (lhs.since, rhs.since) {
            case (let left?, let right?) where left != right:
                return left < right
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                return lhs.id < rhs.id
            }
        }.first
    }
}

extension TaskItem {
    func applying(_ record: TaskLiveRecord, now: Date) -> TaskItem {
        let presentation: TaskClassification
        if displayState == .archived {
            presentation = TaskClassification(columnKind: .done, displayState: .archived)
        } else {
            presentation = TaskSourceClassifier.codexThread(
                updatedAt: record.updatedAt ?? updatedAt,
                now: now
            )
        }
        return TaskItem(
            id: id,
            code: code,
            title: title,
            detail: detail,
            chip: chip,
            updatedAt: record.updatedAt ?? updatedAt,
            tokens: tokens,
            kind: presentation.columnKind,
            threadID: record.threadID,
            runtimeState: record.state,
            isRealtime: record.isRealtime,
            sourceKind: sourceKind,
            displayState: presentation.displayState,
            stateBasis: stateBasis,
            rawStatus: rawStatus,
            nextRunAt: nextRunAt,
            projectPath: projectPath
        )
    }
}

extension TaskBoard {
    func merging(_ live: CodexTaskLiveSnapshot, now: Date = Date()) -> TaskBoard {
        var itemsByThread: [String: TaskItem] = [:]
        var scheduledItems: [TaskItem] = []

        for column in columns {
            for item in column.items {
                if item.kind == .scheduled || item.threadID == nil {
                    scheduledItems.append(item)
                } else if let threadID = item.threadID {
                    itemsByThread[threadID] = item
                }
            }
        }

        for record in live.records.values where record.isRealtime {
            if let existing = itemsByThread[record.threadID] {
                itemsByThread[record.threadID] = existing.applying(record, now: now)
            } else if Calendar.current.isDate(record.updatedAt ?? now, inSameDayAs: now) {
                let compactID = record.threadID.replacingOccurrences(of: "-", with: "")
                let item = TaskItem(
                    id: "live-\(record.threadID)",
                    code: "COD-\(compactID.suffix(4).uppercased())",
                    title: record.name ?? "Codex task",
                    detail: "",
                    chip: "Live",
                    updatedAt: record.updatedAt,
                    tokens: nil,
                    kind: record.state.columnKind,
                    threadID: record.threadID,
                    runtimeState: record.state,
                    isRealtime: record.isRealtime,
                    sourceKind: .codexThread,
                    displayState: .recentlyActive,
                    stateBasis: .activityWindow
                )
                itemsByThread[record.threadID] = item
            }
        }

        let threadItems = Array(itemsByThread.values)
        func sorted(_ kind: TaskColumnKind) -> [TaskItem] {
            threadItems.filter { $0.kind == kind }.sorted { lhs, rhs in
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
        }

        let titles = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0.title) })
        let active = sorted(.active)
        let pending = sorted(.pending)
        let done = sorted(.done)
        let scheduled = scheduledItems.sorted { lhs, rhs in
            switch (lhs.nextRunAt, rhs.nextRunAt) {
            case (let left?, let right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.id < rhs.id
            }
        }

        return TaskBoard(
            refreshedAt: now,
            columns: [
                TaskColumn(id: .active, title: titles[.active] ?? "Active", count: active.count, items: active),
                TaskColumn(id: .pending, title: titles[.pending] ?? "Pending", count: pending.count, items: pending),
                TaskColumn(id: .scheduled, title: titles[.scheduled] ?? "Scheduled", count: scheduled.count, items: scheduled),
                TaskColumn(id: .done, title: titles[.done] ?? "Done", count: done.count, items: done),
            ])
    }

    func attentionItems(scope: RuntimeScope) -> [TaskAttentionItem] {
        columns.flatMap(\.items).compactMap { item in
            let kind: TaskAttentionKind
            switch item.runtimeState {
            case .waitingInput:
                return nil
            case .failed:
                kind = .failure
            default:
                return nil
            }
            return TaskAttentionItem(
                id: "\(scope.runtimeId)-\(item.id)-\(kind.rawValue)",
                kind: kind,
                runtimeScope: scope,
                threadID: item.threadID,
                title: item.title,
                since: item.updatedAt
            )
        }
    }
}
