import Foundation

enum AccountTaskStatusSelfTest {
    static func run() -> Bool {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let task = { (alias: String, state: String, createdOffset: TimeInterval, updatedOffset: TimeInterval) in
            HubTask(
                accountAlias: alias,
                state: state,
                createdAt: now.addingTimeInterval(createdOffset),
                updatedAt: now.addingTimeInterval(updatedOffset)
            )
        }
        let stateMappingPassed = [
            ("awaiting_approval", "待批准"),
            ("starting", "在线·准备中"),
            ("running", "在线·运行中"),
            ("cancel_requested", "正在请求取消"),
            ("uncertain", "状态待确认"),
            ("succeeded", "任务成功"),
            ("failed", "任务失败"),
        ].allSatisfy { state, label in
            HubAccountTaskStatusResolver.status(
                for: task("alpha", state, -20, -10),
                now: now
            ).localizedLabel == label
        }
        let busyStates = ["awaiting_approval", "starting", "running", "cancel_requested", "uncertain"]
        let busyPassed = busyStates.allSatisfy {
            HubAccountTaskStatusResolver.status(
                for: task("alpha", $0, -20, -10),
                now: now
            ).isBusy
        }
        let freshTerminal = HubAccountTaskStatusResolver.status(
            for: task("alpha", "succeeded", -20, -119),
            now: now
        )
        let expiredTerminal = HubAccountTaskStatusResolver.status(
            for: task("alpha", "succeeded", -200, -121),
            now: now
        )
        let staleActive = HubAccountTaskStatusResolver.status(
            for: task("alpha", "running", -200, -121),
            now: now
        )
        let newestByAlias = HubAccountTaskStatusResolver.latestTasksByAlias(
            [
                task(" Alpha ", "running", -30, -2),
                task("alpha", "succeeded", -10, -3),
                task("beta", "starting", -5, -4),
            ], now: now)
        let expiredApproval = HubTask(
            accountAlias: "alpha",
            state: "awaiting_approval",
            createdAt: now.addingTimeInterval(-5),
            updatedAt: now.addingTimeInterval(-5),
            approvalExpiresAt: now.addingTimeInterval(-1),
            approvalExpired: true
        )
        let activeBeatsExpiredApproval = HubAccountTaskStatusResolver.latestTasksByAlias(
            [
                task("alpha", "running", -30, -20),
                expiredApproval,
            ], now: now)
        let newestTerminalByAlias = HubAccountTaskStatusResolver.latestTasksByAlias(
            [
                task("gamma", "failed", -20, -10),
                task("gamma", "succeeded", -5, -4),
            ], now: now)
        let offline = HubAccountTaskStatusResolver.status(
            forAccountAlias: "alpha",
            tasksByAlias: newestByAlias,
            connectionState: .offline,
            lastSuccessfulRefreshAt: now,
            now: now
        )
        let staleOverview = HubAccountTaskStatusResolver.status(
            forAccountAlias: "alpha",
            tasksByAlias: newestByAlias,
            connectionState: .online,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-31),
            now: now
        )
        let passed =
            stateMappingPassed
            && busyPassed
            && HubAccountTaskStatus(phase: .maintenance, updatedAt: now).blocksLocalCLI
            && !HubAccountTaskStatus(phase: .awaitingAcceptance, updatedAt: now).blocksLocalCLI
            && freshTerminal.phase == .succeeded
            && expiredTerminal.phase == .idle
            && staleActive.phase == .running
            && staleActive.blocksLocalCLI
            && HubAccountTaskStatusResolver.status(for: expiredApproval, now: now).phase == .idle
            && newestByAlias["alpha"]?.state == "running"
            && newestByAlias["beta"]?.state == "starting"
            && activeBeatsExpiredApproval["alpha"]?.state == "running"
            && newestTerminalByAlias["gamma"]?.state == "succeeded"
            && offline.localizedLabel == "状态待确认"
            && offline.blocksLocalCLI
            && offline.blockDetail == .hubOffline
            && staleOverview.phase == .unavailable
            && staleOverview.blocksLocalCLI
            && staleOverview.blockDetail == .staleOverview
            && HubAccountTaskStatusResolver.status(
                forAccountAlias: nil,
                tasksByAlias: newestByAlias,
                connectionState: .online,
                lastSuccessfulRefreshAt: now,
                now: now
            ).blockDetail == .missingMapping
            && HubAccountTaskStatus(phase: .running, updatedAt: now).blockingReason(.zh)?.contains("活跃任务") == true
            && HubAccountTaskStatus(phase: .idle, updatedAt: now).blockingReason(.zh) == nil
            && HubAccountTaskStatus(phase: .running, updatedAt: now).blocksLocalCLI
        print(passed ? "Account task status self-test passed" : "Account task status self-test failed")
        return passed
    }
}
