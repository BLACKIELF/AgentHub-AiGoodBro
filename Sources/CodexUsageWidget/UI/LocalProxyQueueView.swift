import SwiftUI

struct LocalProxyQueueView: View {
    @ObservedObject var model: LocalProxyQueueStore
    let language: WidgetLanguage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(language.text("反代模式", "Reverse proxy mode"), systemImage: "network")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(phaseTitle).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Button(language.text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(
                language.text(
                    "供连接到本地代理的新任务使用；当前桌面任务不会自动改走代理。",
                    "For new tasks connected to the local proxy. Current desktop tasks are not redirected automatically."
                )
            )
            .font(.callout).foregroundStyle(.secondary)

            controls
            if let endpoint = model.endpoint {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text("本地连接地址", "Local endpoint")).font(.caption).foregroundStyle(.secondary)
                        Text(endpoint).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    Button(language.text("复制连接配置", "Copy connection config")) { model.copyConnectionDetails() }
                        .help(language.text("复制本地地址和访问密钥", "Copy the local endpoint and access key"))
                    if model.desktopAvailable {
                        Button(language.text("接入桌面", "Connect Desktop")) { model.connectDesktop() }
                            .help(language.text("先退出 Codex，再从这里重新打开；任务使用各自选择的模型。", "Quit Codex, then reopen it here. Each task keeps its selected model."))
                    }
                }
                .padding(12)
                .background(WorkspaceGlassSurface(cornerRadius: 10))
            }

            HStack {
                Text(language.text("代理账号队列", "Proxy account queue")).font(.headline)
                Spacer()
                Button {
                    model.refreshStatus()
                } label: {
                    Label(language.text("刷新额度", "Refresh limits"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            Text(
                language.text(
                    "优先调用的账号排在前面，同组按队列顺序使用额度。这里的参与与优先设置仅用于反代。",
                    "Priority accounts are used first, then queue order within each group. These participation and priority settings apply only to the proxy."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.rows.isEmpty {
                        Text(language.text("暂无可加入的账号。请先在账号管理中添加账号。", "No accounts are available. Add an account in account management first."))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        accountRow(row, index: index)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let issue = model.issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("next.local-proxy.issue")
            }
            Text(
                language.text(
                    "仅正在处理请求的账号会被占用，原有派单设置保持不变。停止代理后可调整队列；关闭此面板不会停止代理。",
                    "Only accounts handling active requests are occupied. Existing dispatch settings stay unchanged. Stop the proxy to edit the queue; closing this panel keeps it running."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 740, height: 680)
        .background(WorkspaceGlassBackdrop())
        .accessibilityIdentifier("next.local-proxy.panel")
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Text(language.text("按账号队列依次调用", "Use accounts in queue order"))
                .font(.callout)
            Spacer()
            if model.phase == .starting || model.phase == .stopping {
                ProgressView().controlSize(.small)
            }
            Button(language.text("开启反代模式", "Enable reverse proxy")) {
                model.setOptIn(true)
                Task { await model.start() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStart)
            .accessibilityIdentifier("next.local-proxy.start")
            Button(language.text("关闭反代", "Disable reverse proxy")) {
                Task {
                    await model.stop()
                    if model.canEdit { model.setOptIn(false) }
                }
            }
            .disabled((!model.canStop && !model.isEnabled) || model.phase == .stopping)
            .accessibilityIdentifier("next.local-proxy.stop")
        }
        .padding(12)
        .background(WorkspaceGlassSurface(cornerRadius: 10))
    }

    private func accountRow(_ row: LocalProxyQueueRow, index: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(row.label).font(.callout.weight(.medium)).lineLimit(1)
                    if row.isCurrent {
                        Label(language.text("当前请求", "Current request"), systemImage: "bolt.fill")
                            .font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
                Text(row.quotaText ?? language.text("额度未知", "Limits unknown"))
                    .font(.caption).foregroundStyle(.secondary)
                if let deadline = row.cooldownUntil {
                    HStack(spacing: 4) {
                        Text(language.text("冷却至", "Cooldown until"))
                        Text(deadline, style: .time)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(stateTitle(row)).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Toggle(
                    language.text("参与调用", "Participate"),
                    isOn: Binding(
                        get: { row.isEnabled }, set: { model.setAccountEnabled(id: row.id, enabled: $0) }
                    )
                )
                .accessibilityLabel(language.text("\(row.label) 参与调用", "Use \(row.label) for proxy requests"))
                Toggle(
                    language.text("优先调用", "Priority"),
                    isOn: Binding(
                        get: { row.isPriority }, set: { model.setAccountPriority(id: row.id, priority: $0) }
                    )
                )
                .disabled(!row.isEnabled)
                .accessibilityLabel(language.text("\(row.label) 优先调用", "Prioritize \(row.label) for proxy requests"))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption)
            .disabled(!model.canEdit)
            VStack(spacing: 3) {
                Button {
                    model.moveAccount(id: row.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!model.canEdit || index == 0)
                .accessibilityLabel(language.text("上移 \(row.label)", "Move \(row.label) up"))
                Button {
                    model.moveAccount(id: row.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!model.canEdit || index == model.rows.count - 1)
                .accessibilityLabel(language.text("下移 \(row.label)", "Move \(row.label) down"))
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(WorkspaceGlassSurface(cornerRadius: 10))
    }

    private var phaseTitle: String {
        switch model.phase {
        case .stopped: return language.text("已停止", "Stopped")
        case .starting: return language.text("正在启动", "Starting")
        case .running: return language.text("运行中", "Running")
        case .stopping: return language.text("正在停止", "Stopping")
        case .failed: return language.text("需要处理", "Needs attention")
        }
    }

    private func stateTitle(_ row: LocalProxyQueueRow) -> String {
        if row.isCurrent { return language.text("请求中", "Handling request") }
        if !row.isEnabled { return language.text("未参与", "Not participating") }
        if let deadline = row.cooldownUntil, deadline > Date() { return language.text("冷却中", "Cooling down") }
        switch row.state {
        case "current": return language.text("请求中", "Handling request")
        case "ready": return language.text("可用", "Ready")
        case "quota": return language.text("额度不足", "Limit reached")
        case "login_expired": return language.text("登录已失效", "Sign-in expired")
        case "temporary_error": return language.text("暂时异常", "Temporary error")
        case "busy": return language.text("账号忙碌", "Account busy")
        case "credentials_busy": return language.text("凭据读取中", "Credentials busy")
        default: return language.text("额度未知", "Limits unknown")
        }
    }
}
