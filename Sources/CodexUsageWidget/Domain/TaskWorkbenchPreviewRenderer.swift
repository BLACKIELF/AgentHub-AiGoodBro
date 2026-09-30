import AppKit
import SwiftUI

/// Offscreen production components with synthetic public task metadata only.
@MainActor enum TaskWorkbenchPreviewRenderer {
    static func render(to directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: 1_790_756_000)
            let states: [TaskOverviewItemState] = [.completed, .completed, .waitingInput, .running, .failed, .completed]
            let titles = ["轻量调用候选 · 等待验收", "教材章节 · 还有未完成内容", "截图工具 · 等待实体热键验证", "微信机器人 · 正在处理", "原任务需要确认", "PR 审查 · 已手动取消"]
            let tasks = titles.enumerated().map { index, title in
                TaskOverviewItem(
                    id: "codex:00000000-0000-4000-8000-00000000000\(index)", title: title,
                    state: states[index], updatedAt: now, runtimeScope: .codex,
                    threadID: "00000000-0000-4000-8000-00000000000\(index)")
            }
            var notes: [String: TaskWorkbenchAnnotation] = [:]
            for (index, task) in tasks.enumerated() {
                let inventory = TaskWorkbenchInventory(
                    threadID: task.threadID!, project: index < 2 ? "学习与创作" : "AiGoodBro",
                    outcome: index == 1 ? .incomplete : .awaitingAcceptance,
                    remaining: index == 1 ? ["完成第三章正文", "核对引用与配图"] : ["完成用户验收", "核对真实使用效果"],
                    nextStep: "打开原聊天，核对已交付成果与剩余验证。", artifacts: [TaskWorkbenchArtifact(title: "已有候选说明", reference: "/Synthetic/Projects/result.md")],
                    evidence: "合成证据：自动测试已通过，真实使用和人工验收仍未确认。", checkedAt: now, sourceTurnID: nil)
                notes[task.id] = TaskWorkbenchAnnotation(
                    inventory: inventory,
                    decision: index == 5 ? .cancelled : .none, decisionAt: index == 5 ? now : nil)
            }
            let overview = TaskOverviewPresentation(
                dataState: .available, runtimeStatuses: [], items: tasks,
                totalItemCount: tasks.count, needsAttentionCount: 2, runningCount: 1, recentlyEndedCount: 3)
            let presentation = TaskWorkbenchPresentation.make(overview: overview, projectNames: [:], annotations: notes, now: now)
            var sizes: [[String: Any]] = []
            for dark in [false, true] {
                for width: CGFloat in [320, 600, 900] {
                    let model = TaskWorkbenchStore.preview(presentation)
                    let view = VStack(alignment: .leading, spacing: 0) {
                        Text("合成预览 · 未连接账号、未发起模型请求").font(.caption2).foregroundStyle(.secondary).padding(12)
                        TaskWorkbenchView(model: model, onRefresh: {})
                        Spacer(minLength: 0)
                    }.frame(width: width, height: 1120).background(dark ? Color.black.opacity(0.92) : Color.white)
                        .environment(\.widgetLanguage, .zh).environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.controlActiveState, .active)
                    let name = "workbench-\(Int(width))-\(dark ? "dark" : "light").png"
                    try capture(view, size: NSSize(width: width, height: 1120), to: directory.appendingPathComponent(name))
                    sizes.append(["file": name, "width": Int(width), "height": 1120, "syntheticOnly": true])
                    model.stop()
                }
                let model = TaskOverviewPanelViewModel(language: .zh)
                model.presentation = overview
                model.workbench = presentation
                let panel = TaskOverviewPanelView(model: model, onClose: {}, onOpenTask: { _ in }, onOpenWorkspace: {})
                    .environment(\.widgetLanguage, .zh).environment(\.colorScheme, dark ? .dark : .light)
                let name = "workbench-panel-\(dark ? "dark" : "light").png"
                try capture(panel, size: TaskOverviewPanelController.compactSize, to: directory.appendingPathComponent(name))
                sizes.append([
                    "file": name, "width": Int(TaskOverviewPanelController.compactSize.width), "height": Int(TaskOverviewPanelController.compactSize.height), "syntheticOnly": true,
                ])
            }
            let receipt = try JSONSerialization.data(
                withJSONObject: ["schemaVersion": 1, "syntheticOnly": true, "realModelInference": false, "renders": sizes], options: [.prettyPrinted, .sortedKeys])
            try receipt.write(to: directory.appendingPathComponent("render-receipt.json"), options: .atomic)
            print("workbench production-component previews rendered: 6 responsive views and 2 attention panels; synthetic only")
            return true
        } catch {
            print("workbench preview render failed")
            return false
        }
    }

    private static func capture<Content: View>(_ content: Content, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TaskWorkbenchInventory.Failure.unavailable }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw TaskWorkbenchInventory.Failure.unavailable }
        try data.write(to: url, options: .atomic)
        window.contentView = nil
        window.close()
    }
}
