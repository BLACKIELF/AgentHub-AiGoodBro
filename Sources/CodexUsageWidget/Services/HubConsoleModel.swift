import Foundation

struct HubTask: Decodable, Equatable {
    let accountAlias: String?
    let state: String
    let createdAt: Date
    let updatedAt: Date
    var approvalExpiresAt: Date? = nil
    var approvalExpired: Bool? = nil

    private static let accountBusyStates: Set<String> = [
        "awaiting_approval", "approved", "queued", "starting", "running", "cancel_requested", "uncertain",
    ]

    static func blocksAccountWarmUp(state: String) -> Bool {
        accountBusyStates.contains(state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var blocksAccountWarmUp: Bool {
        Self.blocksAccountWarmUp(state: state)
    }
}

struct HubOverview: Decodable {
    let tasks: [HubTask]?
}

enum HubWarmUpAvailability: Equatable {
    case idle
    case busy
    case unavailable

    static func resolve(for accountAlias: String, overview: HubOverview, now: Date = Date()) -> Self {
        let alias = HubAccountTaskStatusResolver.canonicalAlias(accountAlias)
        guard !alias.isEmpty, let tasks = overview.tasks else { return .unavailable }
        let status = HubAccountTaskStatusResolver.status(
            for: HubAccountTaskStatusResolver.latestTasksByAlias(tasks, now: now)[alias], now: now)
        return status.blocksLocalCLI ? .busy : .idle
    }
}

enum HubConnectionState: Equatable {
    case loading
    case online
    case offline
}

enum HubAccountTaskPhase: Equatable {
    case idle
    case awaitingApproval
    case starting
    case running
    case maintenance
    case awaitingAcceptance
    case cancelRequested
    case uncertain
    case succeeded
    case failed
    case cancelled
    case unavailable

    func label(_ language: WidgetLanguage) -> String {
        switch self {
        case .idle: return language.text("未运行", "Idle")
        case .awaitingApproval: return language.text("待批准", "Awaiting approval")
        case .starting: return language.text("在线·准备中", "Online · preparing")
        case .running: return language.text("在线·运行中", "Online · running")
        case .maintenance: return language.text("在线·维护中", "Online · maintenance")
        case .awaitingAcceptance: return language.text("已结束·待验收", "Finished · awaiting review")
        case .cancelRequested: return language.text("正在请求取消", "Cancelling")
        case .uncertain, .unavailable: return language.text("状态待确认", "Unverified")
        case .succeeded: return language.text("任务成功", "Completed")
        case .failed: return language.text("任务失败", "Failed")
        case .cancelled: return language.text("任务已取消", "Cancelled")
        }
    }
}

enum HubCLIBlockDetail: Equatable {
    case missingMapping
    case hubOffline
    case staleOverview
    case activeTask(HubAccountTaskPhase)
}

struct HubAccountTaskStatus: Equatable {
    let phase: HubAccountTaskPhase
    let updatedAt: Date?
    let blockDetail: HubCLIBlockDetail?

    init(phase: HubAccountTaskPhase, updatedAt: Date?, blockDetail: HubCLIBlockDetail? = nil) {
        self.phase = phase
        self.updatedAt = updatedAt
        if let blockDetail {
            self.blockDetail = blockDetail
        } else {
            self.blockDetail = Self.inferredDetail(phase: phase)
        }
    }

    var localizedLabel: String {
        label(.zh)
    }

    func label(_ language: WidgetLanguage) -> String {
        phase.label(language)
    }

    /// Presentation-only. Does not change `blocksLocalCLI`.
    func blockingReason(_ language: WidgetLanguage) -> String? {
        guard blocksLocalCLI else { return nil }
        switch blockDetail ?? .hubOffline {
        case .missingMapping:
            return language.text(
                "缺少可信账号映射，暂不能执行。请确认该账号已关联 Hub。",
                "No trusted account mapping. Confirm this account is linked to Hub before starting.")
        case .hubOffline:
            return language.text("Hub 概览未连接，暂不能执行。请稍后刷新。", "Hub overview is disconnected. Refresh before starting.")
        case .staleOverview:
            return language.text("Hub 概览不新鲜，暂不能执行。请刷新后再试。", "Hub overview is stale. Refresh before starting.")
        case .activeTask(.maintenance):
            return language.text("账号正在维护中，暂不能执行。", "This account is in maintenance. CLI launch stays blocked.")
        case .activeTask(.uncertain):
            return language.text("调度状态尚未确认，暂不能执行。", "Dispatch status is unverified. CLI launch stays blocked.")
        case .activeTask(let activePhase):
            return language.text(
                "同账号有活跃任务（\(activePhase.label(language))），暂不能执行。",
                "This account has an active task (\(activePhase.label(language))). CLI launch stays blocked.")
        }
    }

    private static func inferredDetail(phase: HubAccountTaskPhase) -> HubCLIBlockDetail? {
        switch phase {
        case .unavailable:
            return .hubOffline
        case .awaitingApproval, .starting, .running, .maintenance, .cancelRequested, .uncertain:
            return .activeTask(phase)
        case .idle, .awaitingAcceptance, .succeeded, .failed, .cancelled:
            return nil
        }
    }

    /// Hub 明确报告的占用状态。连接不可用另由 `blocksLocalCLI` fail-closed。
    var isBusy: Bool {
        switch phase {
        case .awaitingApproval, .starting, .running, .maintenance, .cancelRequested, .uncertain:
            return true
        case .idle, .succeeded, .failed, .cancelled, .unavailable, .awaitingAcceptance:
            return false
        }
    }

    /// 可信映射和新鲜概览存在，且同别名没有活跃任务时才开放 CLI。
    var blocksLocalCLI: Bool {
        isBusy || phase == .unavailable
    }
}

enum HubAccountTaskStatusResolver {
    static let terminalFeedbackTTL: TimeInterval = 2 * 60
    static let overviewFreshnessTTL: TimeInterval = 30
    static let maximumFutureClockSkew: TimeInterval = 5

    static func canonicalAlias(_ alias: String) -> String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func latestTasksByAlias(_ tasks: [HubTask], now: Date = Date()) -> [String: HubTask] {
        var result: [String: HubTask] = [:]
        for task in tasks {
            guard let rawAlias = task.accountAlias else { continue }
            let alias = canonicalAlias(rawAlias)
            guard !alias.isEmpty else { continue }
            if let current = result[alias] {
                let taskIsBusy = status(for: task, now: now).isBusy
                let currentIsBusy = status(for: current, now: now).isBusy
                if taskIsBusy != currentIsBusy {
                    if taskIsBusy { result[alias] = task }
                } else if task.createdAt > current.createdAt
                    || (task.createdAt == current.createdAt && task.updatedAt > current.updatedAt)
                {
                    result[alias] = task
                }
            } else {
                result[alias] = task
            }
        }
        return result
    }

    static func status(for task: HubTask?, now: Date) -> HubAccountTaskStatus {
        guard let task else {
            return HubAccountTaskStatus(phase: .idle, updatedAt: nil)
        }

        let rawState = task.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let signedAge = now.timeIntervalSince(task.updatedAt)
        guard signedAge >= -maximumFutureClockSkew else {
            return HubAccountTaskStatus(phase: .uncertain, updatedAt: task.updatedAt)
        }
        let age = max(0, signedAge)
        switch rawState {
        case "awaiting_approval":
            if task.approvalExpired == true
                || task.approvalExpiresAt.map({ $0 <= now }) == true
            {
                return HubAccountTaskStatus(phase: .idle, updatedAt: nil)
            }
            return activeStatus(.awaitingApproval, task: task)
        case "approved", "queued", "starting":
            return activeStatus(.starting, task: task)
        case "running":
            return activeStatus(.running, task: task)
        case "cancel_requested":
            return activeStatus(.cancelRequested, task: task)
        case "uncertain":
            return HubAccountTaskStatus(phase: .uncertain, updatedAt: task.updatedAt)
        case "succeeded", "completed", "success":
            return terminalStatus(.succeeded, task: task, age: age)
        case "failed", "error", "blocked_configuration":
            return terminalStatus(.failed, task: task, age: age)
        case "cancelled", "canceled":
            return terminalStatus(.cancelled, task: task, age: age)
        default:
            return HubAccountTaskStatus(phase: .uncertain, updatedAt: task.updatedAt)
        }
    }

    static func status(
        forAccountAlias accountAlias: String?,
        tasksByAlias: [String: HubTask],
        connectionState: HubConnectionState,
        lastSuccessfulRefreshAt: Date?,
        now: Date
    ) -> HubAccountTaskStatus {
        guard let accountAlias, !canonicalAlias(accountAlias).isEmpty else {
            return HubAccountTaskStatus(phase: .unavailable, updatedAt: nil, blockDetail: .missingMapping)
        }
        guard connectionState == .online, let lastSuccessfulRefreshAt else {
            return HubAccountTaskStatus(phase: .unavailable, updatedAt: nil, blockDetail: .hubOffline)
        }
        guard (-maximumFutureClockSkew...overviewFreshnessTTL).contains(now.timeIntervalSince(lastSuccessfulRefreshAt))
        else {
            return HubAccountTaskStatus(phase: .unavailable, updatedAt: nil, blockDetail: .staleOverview)
        }
        return status(for: tasksByAlias[canonicalAlias(accountAlias)], now: now)
    }

    private static func activeStatus(
        _ phase: HubAccountTaskPhase,
        task: HubTask
    ) -> HubAccountTaskStatus {
        return HubAccountTaskStatus(phase: phase, updatedAt: task.updatedAt)
    }

    private static func terminalStatus(
        _ phase: HubAccountTaskPhase,
        task: HubTask,
        age: TimeInterval
    ) -> HubAccountTaskStatus {
        guard age <= terminalFeedbackTTL else {
            return HubAccountTaskStatus(phase: .idle, updatedAt: nil)
        }
        return HubAccountTaskStatus(phase: phase, updatedAt: task.updatedAt)
    }
}

@MainActor
final class HubAccountTaskStatusModel: ObservableObject {
    static let pollingInterval: TimeInterval = 10

    @Published private(set) var connectionState: HubConnectionState = .loading
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastSuccessfulRefreshAt: Date?

    private var tasksByAlias: [String: HubTask] = [:]
    private var localActivity = DispatchActivityStore.Snapshot(schemaVersion: 1, leases: [])
    private var localActivityAvailable = true
    private var pollingTask: Task<Void, Never>?

    deinit {
        pollingTask?.cancel()
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.pollingInterval * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func restartPolling() {
        stopPolling()
        startPolling()
    }

    func status(forAccountAlias accountAlias: String?, accountKey: String? = nil, now: Date = Date()) -> HubAccountTaskStatus {
        guard localActivityAvailable else { return HubAccountTaskStatus(phase: .unavailable, updatedAt: nil) }
        let local = localActivity.latest(forAlias: accountAlias, accountKey: accountKey)
        if let local, local.occupied { return local.taskStatus(now: now) }
        let hub = HubAccountTaskStatusResolver.status(
            forAccountAlias: accountAlias,
            tasksByAlias: tasksByAlias,
            connectionState: connectionState,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            now: now
        )
        if hub.blocksLocalCLI { return hub }
        return local?.taskStatus(now: now) ?? hub
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            localActivity = try DispatchActivityStore.live.read()
            localActivityAvailable = true
        } catch {
            localActivityAvailable = false
        }
        do {
            let overview = try await HubConsoleModel.fetchInspectionOverview()
            guard !Task.isCancelled else { return }
            guard let tasks = overview.tasks else {
                // A successful HTTP response without task evidence is still unverified.
                tasksByAlias = [:]
                connectionState = .offline
                return
            }
            tasksByAlias = HubAccountTaskStatusResolver.latestTasksByAlias(tasks)
            lastSuccessfulRefreshAt = Date()
            connectionState = .online
        } catch {
            guard !Task.isCancelled else { return }
            tasksByAlias = [:]
            connectionState = .offline
        }
    }
}

enum HubConsoleModel {
    private static let overviewURL = URL(string: "http://127.0.0.1:8787/api/overview")!

    static func warmUpAvailability(for accountAlias: String, excludingLocalLease: String? = nil) async -> HubWarmUpAvailability {
        let alias = HubAccountTaskStatusResolver.canonicalAlias(accountAlias)
        guard !alias.isEmpty else { return .unavailable }
        do {
            let local = try DispatchActivityStore.live.read()
            let aliasKey = DispatchActivityStore.hash(alias)
            if local.leases.contains(where: { $0.aliasKey == aliasKey && $0.occupied && $0.leaseId != excludingLocalLease }) {
                return .busy
            }
            let overview = try await fetchInspectionOverview()
            return HubWarmUpAvailability.resolve(for: alias, overview: overview)
        } catch {
            return .unavailable
        }
    }

    static func fetchInspectionOverview() async throws -> HubOverview {
        var request = URLRequest(url: overviewURL, timeoutInterval: 6)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else { throw URLError(.badServerResponse) }
        return try makeDecoder().decode(HubOverview.self, from: data)
    }

    /// `JSONDecoder` is mutable and not safe to share across concurrent refresh requests.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = HubDateParsing.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "无法解析 Hub 时间"
                )
            }
            return date
        }
        return decoder
    }
}

enum HubWarmUpGateSelfTest {
    static func run() -> Bool {
        guard DispatchActivityStoreSelfTest.run() else { return false }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var failures: [String] = []

        func task(
            alias: String? = "account-a",
            state: String,
            createdAt: Date? = nil,
            updatedAt: Date? = nil,
            approvalExpiresAt: Date? = nil,
            approvalExpired: Bool? = nil
        ) -> HubTask {
            HubTask(
                accountAlias: alias,
                state: state,
                createdAt: createdAt ?? now.addingTimeInterval(-20),
                updatedAt: updatedAt ?? now.addingTimeInterval(-10),
                approvalExpiresAt: approvalExpiresAt,
                approvalExpired: approvalExpired
            )
        }

        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }

        expect(
            HubWarmUpAvailability.resolve(for: "account-a", overview: HubOverview(tasks: nil), now: now) == .unavailable,
            "missing task evidence blocks warm-up")
        expect(
            HubWarmUpAvailability.resolve(for: "account-a", overview: HubOverview(tasks: []), now: now) == .idle,
            "explicitly empty task list allows idle maintenance")
        expect(
            HubWarmUpAvailability.resolve(for: "account-a", overview: HubOverview(tasks: [task(state: "running")]), now: now) == .busy,
            "active task blocks maintenance")

        let busyStates: [(String, HubAccountTaskPhase)] = [
            ("awaiting_approval", .awaitingApproval),
            ("approved", .starting),
            ("queued", .starting),
            ("starting", .starting),
            ("running", .running),
            ("cancel_requested", .cancelRequested),
            ("uncertain", .uncertain),
        ]
        for (rawState, expectedPhase) in busyStates {
            let status = HubAccountTaskStatusResolver.status(for: task(state: rawState), now: now)
            expect(HubTask.blocksAccountWarmUp(state: rawState), "busy predicate: \(rawState)")
            expect(status.phase == expectedPhase, "busy phase: \(rawState)")
            expect(status.blocksLocalCLI, "busy blocks local CLI: \(rawState)")
        }

        let unknown = HubAccountTaskStatusResolver.status(for: task(state: "future_state"), now: now)
        expect(unknown.phase == .uncertain && unknown.blocksLocalCLI, "unknown state fails closed")

        let expiredByDate = HubAccountTaskStatusResolver.status(
            for: task(state: "awaiting_approval", approvalExpiresAt: now.addingTimeInterval(-1)),
            now: now
        )
        let expiredByFlag = HubAccountTaskStatusResolver.status(
            for: task(state: "awaiting_approval", approvalExpired: true),
            now: now
        )
        expect(expiredByDate.phase == .idle && !expiredByDate.blocksLocalCLI, "expired approval date is idle")
        expect(expiredByFlag.phase == .idle && !expiredByFlag.blocksLocalCLI, "expired approval flag is idle")

        for terminalState in ["succeeded", "failed", "cancelled", "blocked_configuration"] {
            let recent = HubAccountTaskStatusResolver.status(for: task(state: terminalState), now: now)
            let expired = HubAccountTaskStatusResolver.status(
                for: task(
                    state: terminalState,
                    updatedAt: now.addingTimeInterval(-HubAccountTaskStatusResolver.terminalFeedbackTTL - 1)
                ),
                now: now
            )
            expect(!recent.blocksLocalCLI && recent.phase != .idle, "recent terminal feedback: \(terminalState)")
            expect(expired.phase == .idle && !expired.blocksLocalCLI, "expired terminal feedback: \(terminalState)")
        }

        let freshRefresh = now.addingTimeInterval(-1)
        let offline = HubAccountTaskStatusResolver.status(
            forAccountAlias: "account-a",
            tasksByAlias: [:],
            connectionState: .offline,
            lastSuccessfulRefreshAt: freshRefresh,
            now: now
        )
        let stale = HubAccountTaskStatusResolver.status(
            forAccountAlias: "account-a",
            tasksByAlias: [:],
            connectionState: .online,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-HubAccountTaskStatusResolver.overviewFreshnessTTL - 1),
            now: now
        )
        let missingAlias = HubAccountTaskStatusResolver.status(
            forAccountAlias: "  \n ",
            tasksByAlias: [:],
            connectionState: .online,
            lastSuccessfulRefreshAt: freshRefresh,
            now: now
        )
        for (name, status) in [("offline", offline), ("stale overview", stale), ("missing alias", missingAlias)] {
            expect(status.phase == .unavailable && status.blocksLocalCLI, "\(name) is unavailable")
        }

        let futureTask = HubAccountTaskStatusResolver.status(
            for: task(
                state: "succeeded",
                updatedAt: now.addingTimeInterval(HubAccountTaskStatusResolver.maximumFutureClockSkew + 1)
            ),
            now: now
        )
        let futureOverview = HubAccountTaskStatusResolver.status(
            forAccountAlias: "account-a",
            tasksByAlias: [:],
            connectionState: .online,
            lastSuccessfulRefreshAt: now.addingTimeInterval(HubAccountTaskStatusResolver.maximumFutureClockSkew + 1),
            now: now
        )
        expect(futureTask.phase == .uncertain && futureTask.blocksLocalCLI, "future task timestamp fails closed")
        expect(futureOverview.phase == .unavailable && futureOverview.blocksLocalCLI, "future overview timestamp fails closed")

        let olderBusy = task(
            alias: " Account-A ",
            state: "running",
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-5)
        )
        let newerTerminal = task(
            alias: "account-a",
            state: "succeeded",
            createdAt: now.addingTimeInterval(-20),
            updatedAt: now.addingTimeInterval(-1)
        )
        let latest = HubAccountTaskStatusResolver.latestTasksByAlias([olderBusy, newerTerminal], now: now)
        expect(latest["account-a"] == olderBusy, "busy task wins over newer terminal task")
        expect(HubAccountTaskStatusResolver.canonicalAlias("  AcCoUnT-A\n") == "account-a", "alias normalization")
        let normalizedStatus = HubAccountTaskStatusResolver.status(
            forAccountAlias: " ACCOUNT-A ",
            tasksByAlias: latest,
            connectionState: .online,
            lastSuccessfulRefreshAt: freshRefresh,
            now: now
        )
        expect(normalizedStatus.phase == .running && normalizedStatus.blocksLocalCLI, "normalized alias lookup")

        if failures.isEmpty {
            print("Hub warm-up gate self-test passed")
            return true
        }
        print("Hub warm-up gate self-test failed: \(failures.joined(separator: ", "))")
        return false
    }
}

private enum HubDateParsing {
    static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plainSecondsFormatter = ISO8601DateFormatter()

    static func parse(_ raw: String) -> Date? {
        fractionalSecondsFormatter.date(from: raw) ?? plainSecondsFormatter.date(from: raw)
    }
}
