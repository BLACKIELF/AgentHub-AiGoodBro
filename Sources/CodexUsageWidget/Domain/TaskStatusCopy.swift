import SwiftUI

/// Shared task-state labels for the workspace and the overview panel.
enum TaskStatusCopy {
    static func label(_ state: TaskOverviewItemState, _ language: WidgetLanguage) -> String {
        switch state {
        case .waitingInput: return language.text("待你处理", "Needs action")
        case .pendingApproval: return language.text("待批准", "Awaiting approval")
        case .running: return language.text("运行中", "Running")
        case .failed: return language.text("失败", "Failed")
        case .blocked: return language.text("受阻", "Blocked")
        case .recentlyActive: return language.text("最近活跃，待核对", "Recently active; verify")
        case .completed: return language.text("已完成", "Completed")
        case .interrupted: return language.text("已中断", "Interrupted")
        case .archived: return language.text("已归档", "Archived")
        case .disconnected: return language.text("连接中断，回原任务核对", "Disconnected; verify original task")
        case .unknown: return language.text("状态未知，回原任务核对", "Unknown; verify original task")
        case .pending: return language.text("待继续", "Continue")
        }
    }

    static func color(_ state: TaskOverviewItemState) -> Color {
        switch state {
        case .waitingInput, .pendingApproval, .interrupted, .pending:
            return FixedVisualPalette.statusWarning
        case .failed, .blocked:
            return FixedVisualPalette.statusDanger
        case .running:
            return FixedVisualPalette.statusInfo
        case .completed:
            return FixedVisualPalette.statusSuccess
        case .recentlyActive:
            return .secondary
        case .disconnected, .unknown, .archived:
            return FixedVisualPalette.statusNeutral
        }
    }

    static func selfTest() -> Bool {
        let waiting = label(.waitingInput, .zh)
        let pending = label(.pending, .en)
        let disconnected = label(.disconnected, .zh)
        let passed =
            waiting == "待你处理"
            && pending == "Continue"
            && disconnected.contains("回原任务核对")
            && label(.pendingApproval, .zh) == "待批准"
            && label(.blocked, .en) == "Blocked"
        print(passed ? "Task status copy self-test passed" : "Task status copy self-test failed")
        return passed
    }
}
