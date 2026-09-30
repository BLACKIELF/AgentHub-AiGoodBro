import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskWorkbenchView: View {
    @ObservedObject var model: TaskWorkbenchStore
    var onRefresh: () -> Void
    @Environment(\.widgetLanguage) private var language
    @State private var selectedID: String?
    @State private var selectedProject: String = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("项目工作台", "Project workbench")).font(.headline)
                    Text(language.text("执行状态和成果状态分开核对", "Track execution and outcome separately"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(language.text("刷新", "Refresh")) { onRefresh(); model.rebuild() }
            }
            if let status = message ?? model.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let presentation = model.presentation {
                HStack(spacing: 12) {
                    Text(language.text("运行中 \(presentation.overview.runningCount)", "\(presentation.overview.runningCount) running"))
                    Text(language.text("需关注 \(presentation.items.filter(\.needsAttention).count)", "\(presentation.items.filter(\.needsAttention).count) need attention"))
                    Spacer()
                    Text(presentation.checkedAt, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
                if presentation.overview.dataState != .available {
                    Text(language.text("连接或数据待更新，旧记录不能证明任务仍在运行。", "Connection or data needs updating; old records do not prove current activity."))
                        .font(.caption).foregroundStyle(.orange)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ScrollView { projectList(presentation) }.frame(width: 190, height: 360)
                        taskArea(presentation).frame(minWidth: 380)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(language.text("项目", "Project"), selection: $selectedProject) {
                            Text(language.text("所有项目", "All projects")).tag("")
                            ForEach(presentation.projects) { project in Text(projectTitle(project.name)).tag(project.name) }
                        }.pickerStyle(.menu)
                        taskArea(presentation)
                    }
                }
                Text(language.text("展示现有任务记录，每分钟合并一次。暂缓或取消只改变后续安排，不会终止正在执行的任务。", "Existing task records are merged once per minute. Deferring or cancelling follow-up work does not stop a running turn."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(language.text("正在整理现有记录…", "Preparing existing records…"))
                    .font(.callout).foregroundStyle(.secondary).padding(20)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func taskArea(_ presentation: TaskWorkbenchPresentation) -> some View {
        let items = presentation.items.filter { selectedProject.isEmpty || $0.project == selectedProject }
        return VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text(language.text("暂无现有任务记录", "No existing task records"))
                    .font(.callout).foregroundStyle(.secondary).padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) { ForEach(items) { item in taskRow(item) } }
                }.frame(minHeight: 140, maxHeight: 300)
                if let selected = items.first(where: { $0.id == selectedID }) ?? items.first { detail(selected) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func actionButtons(_ item: TaskWorkbenchItem) -> some View {
        Button(language.text("打开原聊天", "Open original chat")) { openOriginal(item) }
            .disabled(item.task.runtimeScope != .codex || item.task.threadID.flatMap(CodexSessionLink.url(threadID:)) == nil)
        Button(language.text("用原聊天盘点", "Inventory in original chat")) { model.inventory(item) }
            .disabled(model.inventoryInFlight || item.task.runtimeScope != .codex || item.task.threadID == nil || item.annotation.decision != .none)
        if model.inventoryInFlight { ProgressView().controlSize(.small) }
        Button(language.text("导入盘点结果", "Import inventory")) { importInventory(item) }
            .disabled(item.task.runtimeScope != .codex || item.task.threadID == nil)
    }

    private func projectList(_ presentation: TaskWorkbenchPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { selectedProject = ""; selectedID = nil } label: {
                HStack { Text(language.text("所有项目", "All projects")); Spacer(); Text("\(presentation.items.count)") }
            }.buttonStyle(.plain).padding(9)
                .background(selectedProject.isEmpty ? Color.blue.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
            ForEach(presentation.projects) { project in
                Button { selectedProject = project.name; selectedID = nil } label: {
                    HStack(alignment: .top) {
                        Text(projectTitle(project.name)).lineLimit(2)
                        Spacer(minLength: 4); Text("\(project.items.count)").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding(9)
                    .background(selectedProject == project.name ? Color.blue.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
                    .help(project.name)
            }
        }.font(.caption)
    }

    private func taskRow(_ item: TaskWorkbenchItem) -> some View {
        Button { selectedID = item.id } label: {
            HStack(spacing: 8) {
                Circle().fill(TaskStatusCopy.color(item.task.state)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.task.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(executionLabel(item.task.state))
                        Text("·")
                        Text(item.outcome.label(language))
                        if item.annotation.decision != .none {
                            Text("·"); Text(item.annotation.decision.label(language))
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedID == item.id ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }

    private func detail(_ item: TaskWorkbenchItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(item.task.title).font(.callout.weight(.semibold)).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack { actionButtons(item) }
                VStack(alignment: .leading, spacing: 8) { actionButtons(item) }
            }.font(.caption)
            Picker(language.text("后续安排", "Follow-up decision"), selection: Binding(
                get: { item.annotation.decision }, set: { model.setDecision($0, for: item) })) {
                ForEach(TaskManualDecision.allCases, id: \.self) { decision in
                    Text(decision.label(language)).tag(decision)
                }
            }.pickerStyle(.menu).font(.caption)
            if let inventory = item.annotation.inventory {
                if item.inventoryIsStale {
                    Text(language.text("聊天已有更新，以下旧盘点需要重新核对。", "The chat has changed; this older inventory needs verification."))
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(language.text("剩余事项", "Remaining work")).font(.caption.weight(.semibold))
                if inventory.remaining.isEmpty {
                    Text(language.text("未列出剩余事项；仍需核对验收证据。", "No remaining work listed; acceptance still needs verification."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(inventory.remaining.enumerated()), id: \.offset) { _, text in
                        Text("• " + text).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(language.text("下一步：", "Next: ") + inventory.nextStep)
                    .font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !inventory.evidence.isEmpty {
                    Text(inventory.evidence).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                ForEach(inventory.artifacts) { artifact in
                    if let url = artifact.url {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label(artifact.title, systemImage: "doc.text")
                        }.font(.caption).buttonStyle(.link)
                    }
                }
                Text(language.text("盘点时间：", "Inventory checked: ") + inventory.checkedAt.formatted())
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(language.text("尚无语义盘点。运行轮次结束不代表成果已完成。", "No semantic inventory yet. A finished turn does not prove task completion."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(language.text("查看盘点请求", "Review inventory request")) {
                Text(item.task.threadID.map(TaskWorkbenchStore.prompt(threadID:)) ?? "")
                    .font(.caption2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.font(.caption)
            Text(language.text("盘点会向所选原聊天提交一次请求，沿用它的模型和权限；结果不明不会自动重发。", "Inventory submits one request to the selected original chat, using its model and permissions. Uncertain requests are never automatically retried."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func projectTitle(_ value: String) -> String {
        value.hasPrefix("/") ? URL(fileURLWithPath: value).lastPathComponent : value
    }
    private func executionLabel(_ state: TaskOverviewItemState) -> String {
        state == .completed ? language.text("本轮已结束", "Turn ended") : TaskStatusCopy.label(state, language)
    }
    private func openOriginal(_ item: TaskWorkbenchItem) {
        guard item.task.runtimeScope == .codex, let id = item.task.threadID,
            let url = CodexSessionLink.url(threadID: id) else { return }
        if !NSWorkspace.shared.open(url) { message = language.text("无法打开原聊天，请确认 Codex 已安装。", "Unable to open the chat. Check that Codex is installed.") }
    }
    private func importInventory(_ item: TaskWorkbenchItem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 24 * 1024,
            let data = try? Data(contentsOf: url) else { return }
        model.importInventory(data: data, for: item)
    }
}
