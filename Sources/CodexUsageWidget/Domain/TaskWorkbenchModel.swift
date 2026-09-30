import Foundation

enum TaskOutcome: String, Codable, CaseIterable {
    case unknown, incomplete, candidate, awaitingAcceptance, complete
    func label(_ language: WidgetLanguage) -> String {
        switch self {
        case .unknown: return language.text("成果待核对", "Outcome unverified")
        case .incomplete: return language.text("未完成", "Incomplete")
        case .candidate: return language.text("已有候选", "Candidate ready")
        case .awaitingAcceptance: return language.text("待验收", "Awaiting acceptance")
        case .complete: return language.text("已完成", "Complete")
        }
    }
}

enum TaskManualDecision: String, Codable, CaseIterable {
    case none, paused, cancelled, completed
    func label(_ language: WidgetLanguage) -> String {
        switch self {
        case .none: return language.text("继续关注", "Keep tracking")
        case .paused: return language.text("暂缓", "Deferred")
        case .cancelled: return language.text("取消后续工作", "Cancel follow-up work")
        case .completed: return language.text("确认完成", "Confirm complete")
        }
    }
}

struct TaskWorkbenchArtifact: Codable, Equatable, Identifiable {
    let title: String
    let reference: String
    var id: String { reference }
    var url: URL? {
        // Displayable documents only; never launch an executable or a custom scheme.
        if reference.hasPrefix("/") {
            let allowed = ["md", "txt", "pdf", "png", "jpg", "jpeg", "webp", "svg", "html", "json", "csv", "xlsx", "pptx", "docx", "mp4", "mov"]
            let value = URL(fileURLWithPath: reference)
            guard !["auth.json", "credentials.json", "secrets.json"].contains(value.lastPathComponent.lowercased()) else { return nil }
            return allowed.contains(value.pathExtension.lowercased()) ? value : nil
        }
        guard let value = URL(string: reference), value.scheme == "https", value.host != nil,
            value.user == nil, value.password == nil else { return nil }
        return value
    }
}

/// Bounded semantic inventory, separate from execution evidence. The model
/// cannot change manual decisions or prove acceptance by saying "completed".
struct TaskWorkbenchInventory: Codable, Equatable {
    let threadID: String
    let project: String
    let outcome: TaskOutcome
    let remaining: [String]
    let nextStep: String
    let artifacts: [TaskWorkbenchArtifact]
    let evidence: String
    let checkedAt: Date
    let sourceTurnID: String?

    func validated(expectedThreadID: String? = nil) throws -> Self {
        guard UUID(uuidString: threadID) != nil,
            expectedThreadID == nil || expectedThreadID == threadID,
            Self.safeText(project, limit: 160), Self.safeText(nextStep, limit: 800),
            Self.safeText(evidence, limit: 1600), remaining.count <= 8,
            remaining.allSatisfy({ Self.safeText($0, limit: 800) }),
            artifacts.count <= 8, Set(artifacts.map(\.reference)).count == artifacts.count,
            artifacts.allSatisfy({ Self.safeText($0.title, limit: 160)
                && Self.safeText($0.reference, limit: 2048) && $0.url != nil }),
            checkedAt.timeIntervalSince1970.isFinite,
            sourceTurnID.map({ UUID(uuidString: $0) != nil }) ?? true else { throw Failure.invalid }
        return self
    }
    enum Failure: Error { case invalid, unavailable, capacity }
    static func safeText(_ text: String, limit: Int) -> Bool {
        text.utf8.count <= limit && text.unicodeScalars.allSatisfy { $0.value >= 32 || $0 == "\n" || $0 == "\t" }
            && text.range(of: #"(?i)(Bearer\s+[A-Za-z0-9._-]{16,}|sk-[A-Za-z0-9_-]{16,}|(?:api[_ -]?key|access[_ -]?token|bot[_ -]?token|password)\s*[:=]\s*[A-Za-z0-9._-]{12,})"#, options: .regularExpression) == nil
    }
    static func parse(_ text: String, threadID: String, sourceTurnID: String?, now: Date = Date()) throws -> Self {
        guard text.utf8.count <= 24 * 1024, let data = text.data(using: .utf8),
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let declared = value["threadID"] as? String, declared == threadID,
            let project = value["project"] as? String,
            let raw = value["outcome"] as? String, let outcome = TaskOutcome(rawValue: raw),
            let remaining = value["remaining"] as? [String],
            let next = value["nextStep"] as? String,
            let evidence = value["evidence"] as? String,
            let rows = value["artifacts"] as? [[String: String]],
            rows.allSatisfy({ $0["title"] != nil && $0["reference"] != nil }) else { throw Failure.invalid }
        return try Self(threadID: declared, project: project,
            outcome: outcome == .complete ? .awaitingAcceptance : outcome,
            remaining: remaining, nextStep: next,
            artifacts: rows.map { TaskWorkbenchArtifact(title: $0["title"]!, reference: $0["reference"]!) },
            evidence: evidence, checkedAt: now, sourceTurnID: sourceTurnID).validated(expectedThreadID: threadID)
    }
}

struct TaskWorkbenchAnnotation: Codable, Equatable {
    var inventory: TaskWorkbenchInventory?
    var decision: TaskManualDecision = .none
    var decisionAt: Date?
}

struct TaskWorkbenchItem: Identifiable, Equatable {
    let task: TaskOverviewItem
    let project: String
    let annotation: TaskWorkbenchAnnotation
    var id: String { task.id }
    var inventoryIsStale: Bool {
        guard let checked = annotation.inventory?.checkedAt, let updated = task.updatedAt else { return false }
        return updated > checked
    }
    var outcome: TaskOutcome {
        if annotation.decision == .completed { return .complete }
        if inventoryIsStale { return .unknown }
        let value = annotation.inventory?.outcome ?? .unknown
        return value == .complete ? .awaitingAcceptance : value
    }
    var needsAttention: Bool {
        guard annotation.decision == .none, outcome != .complete else { return false }
        return inventoryIsStale || [.waitingInput, .pendingApproval, .failed, .blocked, .interrupted].contains(task.state)
            || [.incomplete, .candidate, .awaitingAcceptance].contains(outcome)
    }
}

struct TaskWorkbenchProject: Identifiable, Equatable {
    let name: String
    let items: [TaskWorkbenchItem]
    var id: String { name }
}

struct TaskWorkbenchPresentation: Equatable {
    let overview: TaskOverviewPresentation
    let projects: [TaskWorkbenchProject]
    let checkedAt: Date
    var items: [TaskWorkbenchItem] { projects.flatMap(\.items) }
    var attention: [TaskWorkbenchItem] {
        let rows = items.filter(\.needsAttention).sorted {
            func rank(_ item: TaskWorkbenchItem) -> Int {
                switch item.task.state {
                case .pendingApproval, .waitingInput: return 0
                case .failed, .blocked, .interrupted: return 1
                default: return 2
                }
            }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.task.updatedAt != $1.task.updatedAt { return ($0.task.updatedAt ?? .distantPast) > ($1.task.updatedAt ?? .distantPast) }
            return $0.id < $1.id
        }
        return Array(rows.prefix(3))
    }

    static func make(overview: TaskOverviewPresentation, projectNames: [String: String],
                     annotations: [String: TaskWorkbenchAnnotation], now: Date) -> Self {
        let rows = overview.items.map { task in
            let note = annotations[task.id] ?? TaskWorkbenchAnnotation()
            let project = note.inventory?.project.trimmingCharacters(in: .whitespacesAndNewlines)
            return TaskWorkbenchItem(task: task,
                project: project?.isEmpty == false ? project! : projectNames[task.id] ?? "未归类",
                annotation: note)
        }
        let grouped = Dictionary(grouping: rows, by: \.project)
        let projects = grouped.keys.sorted().map { TaskWorkbenchProject(name: $0, items: grouped[$0]!) }
        return Self(overview: overview, projects: projects, checkedAt: now)
    }
}
