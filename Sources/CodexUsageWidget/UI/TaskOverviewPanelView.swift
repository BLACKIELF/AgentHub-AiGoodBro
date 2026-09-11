import SwiftUI

struct TaskOverviewPanelView: View {
    @ObservedObject var model: TaskOverviewPanelViewModel
    let onClose: () -> Void
    let onOpenTask: (TaskOverviewItem) -> Void
    let onOpenWorkspace: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            content
            if model.isExpanded {
                Divider().opacity(0.45)
                workspaceButton
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .padding(1)
        .environment(\.locale, model.language.locale)
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.language.text("任务概览", "Task Overview"))
                    .font(.system(size: 13, weight: .semibold))
                if let presentation = model.presentation {
                    Text(summaryText(presentation))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.isExpanded.toggle()
            } label: {
                Image(systemName: model.isExpanded ? "chevron.up" : "chevron.down")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(model.language.text(model.isExpanded ? "收起" : "展开", model.isExpanded ? "Collapse" : "Expand"))
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(model.language.text("关闭（Esc）", "Close (Esc)"))
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    @ViewBuilder
    private var content: some View {
        if let presentation = model.presentation {
            if model.isExpanded {
                expandedContent(presentation)
            } else {
                compactContent(presentation)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.language.text("正在读取现有任务…", "Reading current tasks…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func compactContent(_ presentation: TaskOverviewPresentation) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                metric(
                    value: presentation.needsAttentionCount,
                    label: model.language.text("待处理", "Needs action"),
                    tint: .orange
                )
                metric(
                    value: presentation.runningCount,
                    label: model.language.text("运行中", "Running"),
                    tint: .blue
                )
                metric(
                    value: presentation.recentlyEndedCount,
                    label: model.language.text("最近结束", "Recently ended"),
                    tint: .green
                )
            }
            dataStateLine(presentation.dataState)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func expandedContent(_ presentation: TaskOverviewPresentation) -> some View {
        VStack(spacing: 0) {
            dataStateLine(presentation.dataState)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            if presentation.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: emptyIcon(for: presentation.dataState))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(emptyText(for: presentation.dataState))
                        .font(.callout.weight(.medium))
                    Text(model.language.text("概览不会创建或调度新任务。", "The overview never creates or schedules tasks."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(presentation.items) { item in
                            taskRow(item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metric(value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func taskRow(_ item: TaskOverviewItem) -> some View {
        Button {
            onOpenTask(item)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(stateColor(item.state))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        Text(stateLabel(item.state))
                        if let updatedAt = item.updatedAt {
                            Text("·")
                            Text(updatedAt, style: .relative)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(model.language.text("在工作台核对原任务", "Verify the original task in the workspace"))
    }

    private var workspaceButton: some View {
        Button(action: onOpenWorkspace) {
            HStack {
                Image(systemName: "rectangle.3.group")
                Text(model.language.text("打开工作台", "Open Workspace"))
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dataStateLine(_ state: TaskOverviewDataState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: dataStateIcon(state))
            Text(dataStateText(state))
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(state == .available ? Color.secondary : FixedVisualPalette.statusWarning)
        .lineLimit(1)
    }

    private func summaryText(_ presentation: TaskOverviewPresentation) -> String {
        model.language.text(
            "待处理 \(presentation.needsAttentionCount) · 运行 \(presentation.runningCount) · 结束 \(presentation.recentlyEndedCount)",
            "\(presentation.needsAttentionCount) action · \(presentation.runningCount) running · \(presentation.recentlyEndedCount) ended"
        )
    }

    private func stateLabel(_ state: TaskOverviewItemState) -> String {
        TaskStatusCopy.label(state, model.language)
    }

    private func stateColor(_ state: TaskOverviewItemState) -> Color {
        TaskStatusCopy.color(state)
    }

    private func dataStateText(_ state: TaskOverviewDataState) -> String {
        switch state {
        case .available: return model.language.text("来自现有任务数据", "Using current task data")
        case .stale: return model.language.text("实时状态已陈旧，请回原任务核对", "Live status is stale; verify the original task")
        case .disconnected: return model.language.text("实时状态未连接；历史记录仍可查看", "Live status disconnected; history remains available")
        case .noData: return model.language.text("暂无可展示任务", "No tasks to show")
        }
    }

    private func dataStateIcon(_ state: TaskOverviewDataState) -> String {
        switch state {
        case .available: return "checkmark.circle"
        case .stale: return "clock.badge.exclamationmark"
        case .disconnected: return "bolt.slash"
        case .noData: return "tray"
        }
    }

    private func emptyIcon(for state: TaskOverviewDataState) -> String {
        state == .disconnected ? "bolt.slash" : "checkmark.circle"
    }

    private func emptyText(for state: TaskOverviewDataState) -> String {
        switch state {
        case .disconnected: return model.language.text("实时任务尚未连接", "Live tasks are not connected")
        case .stale: return model.language.text("没有可确认的新鲜状态", "No fresh status is available")
        case .noData, .available: return model.language.text("当前没有待处理任务", "Nothing needs attention")
        }
    }
}
