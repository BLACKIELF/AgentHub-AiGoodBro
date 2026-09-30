import SwiftUI

struct LocalProxyQueueView: View {
    @ObservedObject var model: LocalProxyQueueStore
    let language: WidgetLanguage
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var primaryFloorText = ""
    @State private var secondaryFloorText = ""
    @State private var creditFloorDraftsInitialized = false
    @State private var confirmingStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(language.text("反代模式", "Reverse proxy mode"), systemImage: "network")
                    .font(.headline)
                Spacer()
                Text(phaseTitle).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Button(language.text("关闭", "Close")) {
                    if let onClose { onClose() } else { dismiss() }
                }
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
            creditSettings
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
                .padding(8)
                .background(WorkspaceGlassSurface(cornerRadius: 10))
            }

            HStack {
                Text(language.text("代理账号队列", "Proxy account queue")).font(.headline)
                Spacer()
                Button {
                    model.refreshStatus()
                    model.flushDisplayRows()
                } label: {
                    Label(language.text("刷新额度", "Refresh limits"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            Text(
                language.text(
                    "编号与主页一致；优先账号先调用，同组按队列顺序。参与和优先开关仅用于反代。",
                    "Account numbers match Home. Priority accounts run first, then queue order. These switches apply only to the proxy."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            Text(language.text(
                "请求状态为最近快照，约每分钟更新；手动刷新可立即查看已收集数据。",
                "Request activity is a recent snapshot, updated about once a minute. Refresh to view collected data now."
            ))
            .font(.caption).foregroundStyle(.secondary)
            if model.phase == .running && model.membershipChangeWaiting {
                Text(language.text(
                    "参与开关可随时调整，新请求生效；已开始的请求继续完成。",
                    "Participation changes apply to new requests; requests already started continue to completion."
                ))
                .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.displayRows.isEmpty {
                        Text(language.text("暂无可加入的账号。请先在账号管理中添加账号。", "No accounts are available. Add an account in account management first."))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                    ForEach(Array(model.displayRows.enumerated()), id: \.element.id) { index, row in
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
                    "排序和优先标记可随时调整，新请求立即采用；正在处理的请求保持不变。关闭此面板不会停止代理。",
                    "Order and priority can change while running. New requests use the new order; active requests stay unchanged. Closing this panel keeps the proxy running."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(
            minWidth: LocalProxyQueueWindowController.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: LocalProxyQueueWindowController.minimumContentSize.height,
            maxHeight: .infinity
        )
        .background(WorkspaceGlassBackdrop())
        .buttonStyle(WorkspaceActionButtonStyle())
        .accessibilityIdentifier("next.local-proxy.panel")
        .alert(language.text("停止反代？", "Stop the proxy?"), isPresented: $confirmingStop) {
            Button(language.text("取消", "Cancel"), role: .cancel) {}
            Button(language.text("停止反代", "Stop proxy"), role: .destructive) { disableProxy() }
        } message: {
            Text(language.text(
                "所有接入反代的对话都会断开，正在执行的任务可能中断。",
                "All conversations connected to the proxy will disconnect, and active tasks may be interrupted."
            ))
        }
        .onAppear {
            guard !creditFloorDraftsInitialized else { return }
            primaryFloorText = String(model.creditPrimaryFloor)
            secondaryFloorText = String(model.creditSecondaryFloor)
            creditFloorDraftsInitialized = true
        }
    }

    private var parsedCreditFloors: (primary: Int, secondary: Int)? {
        guard let primary = Int(primaryFloorText), let secondary = Int(secondaryFloorText),
            LocalProxyPreferences.validCreditFloors(primary: primary, secondary: secondary)
        else { return nil }
        return (primary, secondary)
    }
    private var creditFloorsChanged: Bool {
        primaryFloorText != String(model.creditPrimaryFloor) || secondaryFloorText != String(model.creditSecondaryFloor)
    }
    private var creditSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle(
                    language.text("点数接续", "Credit fallback"),
                    isOn: Binding(
                        get: { model.creditFallbackEnabled }, set: { model.setCreditFallback($0) }
                    )
                )
                .toggleStyle(WorkspaceCheckboxStyle()).disabled(!model.canEdit)
                Text(language.text("第一档保留", "First floor"))
                TextField("2000", text: $primaryFloorText)
                    .frame(width: 64)
                    .accessibilityLabel(language.text("第一档保留点数", "First retained credit floor"))
                    .accessibilityIdentifier("next.local-proxy.credit-primary")
                Text(language.text("第二档保留", "Second floor"))
                TextField("1500", text: $secondaryFloorText)
                    .frame(width: 64)
                    .accessibilityLabel(language.text("第二档保留点数", "Second retained credit floor"))
                    .accessibilityIdentifier("next.local-proxy.credit-secondary")
                Text(language.text("点", "points")).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(language.text("保存底线", "Save floors")) {
                    if let floors = parsedCreditFloors { model.setCreditFloors(primary: floors.primary, secondary: floors.secondary) }
                }
                .disabled(!model.canEdit || !creditFloorsChanged || parsedCreditFloors == nil)
                .accessibilityIdentifier("next.local-proxy.credit-save")
            }
            .disabled(!model.canEdit)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            Text(
                language.text(
                    "先用完所有参与账号的订阅额度，再逐档使用点数；桌面账号在这两个阶段各自最后。忙碌或额度未知不会转用点数。单次结算可能越过底线。",
                    "Use all enrolled subscription quota before credit tiers; Desktop is last in each phase. Busy or unknown quota never enables credits. One settlement may cross a floor."
                )
            ).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if parsedCreditFloors == nil && creditFloorsChanged {
                Text(language.text("请输入整数：第一档高于第二档，第二档不小于 0。", "Use whole points: first floor above second; second at least 0."))
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(8)
        .background(WorkspaceGlassSurface(cornerRadius: 10))
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
            .buttonStyle(WorkspaceActionButtonStyle(prominent: true))
            .disabled(!model.canStart || creditFloorsChanged)
            .accessibilityIdentifier("next.local-proxy.start")
            Button(language.text("关闭反代", "Disable reverse proxy")) {
                if model.requiresStopConfirmation { confirmingStop = true }
                else { disableProxy() }
            }
            .disabled((!model.canStop && !model.isEnabled) || model.phase == .stopping)
            .accessibilityIdentifier("next.local-proxy.stop")
        }
        .padding(8)
        .background(WorkspaceGlassSurface(cornerRadius: 10))
    }

    private func disableProxy() {
        Task {
            await model.stop()
            if model.canEdit { model.setOptIn(false) }
        }
    }

    private func accountRow(_ row: LocalProxyQueueRow, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(row.accountNumber.map { String(format: "%02d", $0) } ?? "—").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(row.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if row.isDesktopAccount {
                        Image(systemName: "macwindow").font(.system(size: 9)).foregroundStyle(.secondary)
                            .help(language.text("桌面账号 · 最后使用", "Desktop account · Last resort"))
                            .accessibilityLabel(language.text("桌面账号 · 最后使用", "Desktop account · Last resort"))
                    }
                    if row.isCurrent {
                        Label(language.text("快照有请求", "Active in snapshot"), systemImage: "circle.fill")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(.green)
                            .help(language.text("最近活动快照", "Recent activity snapshot"))
                            .accessibilityLabel(language.text("最近活动快照", "Recent activity snapshot"))
                    }
                    if row.snapshotStale {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .help(language.text("上次快照 · 待刷新", "Last snapshot · refresh needed"))
                            .accessibilityLabel(language.text("上次快照 · 待刷新", "Last snapshot · refresh needed"))
                    }
                }
                HStack(spacing: 5) {
                    if let balance = row.creditBalance { CreditBalanceView(presentation: balance, compact: true) }
                    Text("·")
                    Text(
                        row.resetCardCount.map { language.text("重置卡 \($0)", "\($0) reset cards") }
                            ?? language.text("重置卡 —", "Reset cards —"))
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                if let deadline = row.cooldownUntil {
                    HStack(spacing: 4) {
                        Text(language.text("冷却至", "Cooldown until"))
                        Text(deadline, style: .time)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 100, maxWidth: 225, alignment: .leading)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 5) {
                ForEach(row.windows) { window in
                    CompactQuotaView(
                        title: window.id, remaining: window.remaining, reset: window.resetsAt,
                        paletteRole: window.id == "5h" ? .primary : .secondary,
                        constrainedByWeekly: window.constrainedByWeekly
                    )
                    .frame(minWidth: 100, alignment: .leading)
                }
            }
            .frame(minWidth: 100, maxWidth: 248)
            .environment(\.widgetLanguage, language)
            .help(row.quotaText ?? "")
            Spacer(minLength: 0)
            Text(stateTitle(row)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).frame(width: 48)
            VStack(alignment: .leading, spacing: 5) {
                Toggle(
                    language.text("参与", "Use"),
                    isOn: Binding(
                        get: { row.isEnabled }, set: {
                            model.setAccountEnabled(id: row.id, enabled: $0)
                            model.flushDisplayRows()
                        }
                    )
                )
                .disabled(!model.canToggleAccount(id: row.id))
                .accessibilityLabel(language.text("\(accountTitle(row)) 参与调用", "Use \(accountTitle(row)) for proxy requests"))
                Toggle(
                    language.text("优先", "Priority"),
                    isOn: Binding(
                        get: { row.isPriority }, set: {
                            model.setAccountPriority(id: row.id, priority: $0)
                            model.flushDisplayRows()
                        }
                    )
                )
                .disabled(!model.canReorder || !row.isEnabled)
                .accessibilityLabel(language.text("\(accountTitle(row)) 优先调用", "Prioritize \(accountTitle(row)) for proxy requests"))
            }
            .toggleStyle(WorkspaceCheckboxStyle())
            .controlSize(.small)
            .font(.caption)
            VStack(spacing: 3) {
                Button {
                    model.moveAccount(id: row.id, by: -1)
                    model.flushDisplayRows()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!model.canMoveAccount(id: row.id, by: -1))
                .accessibilityLabel(language.text("上移 \(accountTitle(row))", "Move \(accountTitle(row)) up"))
                Button {
                    model.moveAccount(id: row.id, by: 1)
                    model.flushDisplayRows()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!model.canMoveAccount(id: row.id, by: 1))
                .accessibilityLabel(language.text("下移 \(accountTitle(row))", "Move \(accountTitle(row)) down"))
            }
            .buttonStyle(WorkspaceActionButtonStyle(compact: true))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(WorkspaceGlassSurface(cornerRadius: 8))
        .accessibilityIdentifier("next.local-proxy.account-\(row.id)")
    }

    private func accountTitle(_ row: LocalProxyQueueRow) -> String {
        (row.accountNumber.map { String(format: "%02d", $0) + " · " } ?? "") + row.label
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
        if row.isCurrent && !row.isEnabled { return language.text("完成后退出", "Finishing request") }
        if row.isCurrent { return language.text("快照有请求", "Active in snapshot") }
        if !row.isEnabled { return language.text("未参与", "Not participating") }
        if let deadline = row.cooldownUntil, deadline > Date() { return language.text("冷却中", "Cooling down") }
        switch row.state {
        case "current": return language.text("快照有请求", "Active in snapshot")
        case "ready": return language.text("可用", "Ready")
        case "quota": return language.text("额度不足", "Limit reached")
        case "subscription_pending": return language.text("订阅额度优先", "Subscription first")
        case "login_expired": return language.text("登录已失效", "Sign-in expired")
        case "temporary_error": return language.text("暂时异常", "Temporary error")
        case "busy": return language.text("账号忙碌", "Account busy")
        case "credentials_busy": return language.text("凭据读取中", "Credentials busy")
        default: return language.text("额度未知", "Limits unknown")
        }
    }
}
