import SwiftUI

struct LocalProxyQueueView: View {
    @ObservedObject var model: LocalProxyQueueStore
    let language: WidgetLanguage
    var onClose: (() -> Void)? = nil
    var isCurrentPresentation: () -> Bool = { true }
    var previewExpandedRules = false
    @Environment(\.dismiss) private var dismiss
    @State private var portText = "18080"
    @State private var keyMode = LocalProxyClientKeyMode.persistent
    @State private var networkDraft = LocalProxyEgressSettings()
    @State private var whitelistText = ""
    @State private var networkSaved = false
    @State private var primaryFloorText = ""
    @State private var secondaryFloorText = ""
    @State private var creditFloorDraftsInitialized = false
    @State private var confirmingStop = false
    @State private var advancedExpanded = false
    @State private var showingPanelInfo = false
    @State private var confirmingLegacyCooldown = false
    @State private var legacyCooldownAccountID: String?
    @State private var legacyCooldownAccountTitle = ""
    @State private var preparingLegacyCooldownID: String?
    @FocusState private var focusedCreditFloor: CreditFloor?

    private enum CreditFloor: Hashable { case primary, secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerBar
            proxyToolbar
            advancedRules
            if !model.selfCheck.steps.isEmpty { selfCheckResults }
            if ["dead", "all_dead", "unavailable"].contains(model.egressState) {
                Label(
                    language.text(
                        "出口连接异常，请检查节点或控制 API；看门狗仅在当前节点不可达时切换。", "Egress is unavailable. Check the node and control API; failover only occurs when the current node is unreachable."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(.red)
            }
            queueHeader
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

            if let failure = model.preferencesFailure {
                Label(
                    failure == .save
                        ? language.text(
                            "刚才的规则未保存，仍使用原规则，新请求暂不可用。请检查本地偏好目录权限或磁盘空间；修复并等待已有任务结束后，正常退出并重新打开应用。",
                            "The rule change was not saved; previous rules remain and new requests are blocked. Check local preferences folder permissions or disk space. After fixing them and waiting for active tasks to finish, quit normally and reopen the app."
                        )
                        : language.text(
                            "反代偏好读取失败，已暂停新请求。请检查偏好文件及目录权限；修复并等待已有任务结束后，正常退出并重新打开应用。",
                            "Proxy preferences could not be read; new requests are blocked. Check the preferences file and folder permissions. After fixing them and waiting for active tasks to finish, quit normally and reopen the app."
                        ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout).foregroundStyle(WorkspaceStatusForeground.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let issue = model.visibleIssue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(WorkspaceStatusForeground.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("next.local-proxy.issue")
            }
        }
        .padding(16)
        .frame(
            minWidth: LocalProxyQueueWindowController.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: LocalProxyQueueWindowController.minimumContentSize.height,
            maxHeight: .infinity
        )
        .background {
            // The proxy window uses a transparent full-size titlebar; extend
            // the backdrop under it so the outer edge reads as one surface.
            WorkspaceGlassBackdrop().ignoresSafeArea()
        }
        .buttonStyle(WorkspaceActionButtonStyle(prominent: true))
        .accessibilityIdentifier("next.local-proxy.panel")
        .alert(language.text("停止反代？", "Stop the proxy?"), isPresented: $confirmingStop) {
            Button(language.text("取消", "Cancel"), role: .cancel) {}
            Button(language.text("停止反代", "Stop proxy"), role: .destructive) { disableProxy() }
        } message: {
            Text(
                language.text(
                    "所有接入反代的对话都会断开，正在执行的任务可能中断。",
                    "All conversations connected to the proxy will disconnect, and active tasks may be interrupted."
                ))
        }
        .onAppear {
            guard !creditFloorDraftsInitialized else { return }
            portText = String(model.listenPort)
            keyMode = model.clientKeyMode
            networkDraft = model.egressSettings
            whitelistText = model.egressSettings.whitelist.joined(separator: "\n")
            primaryFloorText = String(model.creditPrimaryFloor)
            secondaryFloorText = String(model.creditSecondaryFloor)
            creditFloorDraftsInitialized = true
        }
        .alert(language.text("清理旧版冷却？", "Clear legacy cooldown?"), isPresented: $confirmingLegacyCooldown) {
            Button(language.text("取消", "Cancel"), role: .cancel) {
                model.cancelLegacyCooldownRecovery()
                legacyCooldownAccountID = nil
            }
            Button(language.text("备份并清理", "Back up and clear")) {
                if let id = legacyCooldownAccountID {
                    _ = model.recoverLegacyCooldown(for: id)
                }
                legacyCooldownAccountID = nil
            }
        } message: {
            Text(
                language.text(
                    "将先备份，再清理 \(legacyCooldownAccountTitle) 来源不明的旧版冷却记录。其他账号、已知限制和账号规则保持不变。完成后需重新开启反代重试，新收到的限制仍正常生效。",
                    "Back up and clear legacy cooldown records with unknown causes for \(legacyCooldownAccountTitle). Other accounts, known restrictions and account rules stay unchanged. Restart the proxy to retry afterward; new restrictions still apply."
                ))
        }
        .onDisappear {
            cancelLegacyCooldownRecovery()
        }
    }

    private func cancelLegacyCooldownRecovery() {
        if isCurrentPresentation() { model.cancelLegacyCooldownRecovery() }
        confirmingLegacyCooldown = false
        legacyCooldownAccountID = nil
        legacyCooldownAccountTitle = ""
        preparingLegacyCooldownID = nil
    }

    private func endpointLabel(_ endpoint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(language.text("本地连接地址", "Local endpoint")).font(.caption).foregroundStyle(.secondary)
            Text(endpoint).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).help(endpoint)
        }
    }

    private var connectionActions: some View {
        HStack(spacing: 8) {
            Button(language.text("自检", "Self-check")) { model.runSelfCheck() }
                .disabled(model.selfCheck.isRunning).accessibilityIdentifier("next.local-proxy.self-check")
            Button(language.text("复制连接配置", "Copy connection config")) { model.copyConnectionDetails() }
                .help(language.text("复制本地地址和访问密钥", "Copy the local endpoint and access key"))
            if model.desktopAvailable {
                Button(language.text("接入桌面", "Connect Desktop")) { model.connectDesktop() }
                    .help(language.text("先退出 Codex，再从这里重新打开；任务使用各自选择的模型。", "Quit Codex, then reopen it here. Each task keeps its selected model."))
            }
        }.fixedSize()
    }

    private var selfCheckResults: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(model.selfCheck.steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.passed == true ? "checkmark.circle.fill" : step.passed == false ? "xmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(step.passed == true ? Color.green : step.passed == false ? Color.red : Color.secondary)
                    Text(step.title).fontWeight(.medium).frame(width: 72, alignment: .leading)
                    Text(step.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.font(.caption).padding(8).background(WorkspaceGlassSurface(cornerRadius: 10))
    }

    private var networkSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.text("监听端口", "Listen port"))
                TextField("18080", text: $portText).frame(width: 80)
                Text(language.text("0 为随机端口", "0 uses a random port")).foregroundStyle(.secondary)
                Picker(language.text("访问密钥", "Access key"), selection: $keyMode) {
                    Text(language.text("持久保存", "Persistent")).tag(LocalProxyClientKeyMode.persistent)
                    Text(language.text("每次生成", "Per run")).tag(LocalProxyClientKeyMode.perRun)
                }.frame(width: 190)
            }
            Toggle(language.text("出口看门狗（仅当前节点不可达时切换）", "Egress watchdog (only switch an unreachable node)"), isOn: $networkDraft.enabled)
            HStack {
                TextField(language.text("控制 API", "Control API"), text: $networkDraft.mihomoAPI)
                SecureField(language.text("控制密钥", "Control secret"), text: $networkDraft.mihomoSecret)
                TextField(language.text("分组", "Group"), text: $networkDraft.group).frame(width: 110)
            }
            HStack(alignment: .top) {
                Text(language.text("候选节点（每行一个）", "Candidate nodes (one per line)"))
                TextEditor(text: $whitelistText).font(.caption.monospaced()).frame(height: 60)
                VStack {
                    Button(language.text("读取日本节点", "Find Japanese nodes")) {
                        Task {
                            if let nodes = await model.discoverEgressNodes(settings: networkDraft) { whitelistText = nodes.joined(separator: "\n") }
                        }
                    }.disabled(model.discoveringNodes)
                    Button(language.text("保存连接设置", "Save connection")) {
                        guard let port = Int(portText) else { return }
                        var draft = networkDraft
                        draft.whitelist = whitelistText.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        networkSaved = model.setNetworkSettings(port: port, mode: keyMode, egress: draft)
                    }
                }
            }
            if !model.canEdit { Text(language.text("停止反代后可修改连接设置", "Stop the proxy to edit connection settings")).foregroundStyle(.secondary) }
            if networkSaved { Text(language.text("连接设置已保存", "Connection settings saved")).foregroundStyle(.green) }
            if Int(portText).map({ $0 == 0 || (1024...65535).contains($0) }) != true {
                Text(language.text("端口须为 0 或 1024–65535", "Use port 0 or 1024–65535")).foregroundStyle(.red)
            }
        }.font(.caption).controlSize(.small).textFieldStyle(.roundedBorder)
            .disabled(!model.canEdit).padding(8).background(WorkspaceGlassSurface(cornerRadius: 10))
            .onChange(of: portText) { _ in networkSaved = false }
            .onChange(of: keyMode) { _ in networkSaved = false }
            .onChange(of: networkDraft) { _ in networkSaved = false }
            .onChange(of: whitelistText) { _ in networkSaved = false }
    }

    private var parsedCreditFloors: (primary: Int, secondary: Int)? {
        guard let primary = Int(primaryFloorText), let secondary = Int(secondaryFloorText),
            LocalProxyPreferences.validCreditFloors(primary: primary, secondary: secondary)
        else { return nil }
        return (primary, secondary)
    }
    private var creditFloorsChanged: Bool {
        guard let floors = parsedCreditFloors else {
            return primaryFloorText != String(model.creditPrimaryFloor) || secondaryFloorText != String(model.creditSecondaryFloor)
        }
        return floors.primary != model.creditPrimaryFloor || floors.secondary != model.creditSecondaryFloor
    }
    private var creditSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    creditFallbackToggle
                    creditFloorFields
                    Spacer(minLength: 0)
                    saveCreditFloorsButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        creditFallbackToggle
                        Spacer()
                        saveCreditFloorsButton
                    }
                    creditFloorFields
                }
            }
            .disabled(!model.canEditPolicy)
            .controlSize(.small)
            Text(
                language.text(
                    "先用订阅额度，再按各账号授权逐档用点数。下方可为每个账号设置上限和底线；单次结算可能越过底线。",
                    "Subscriptions first, then credits from authorized accounts. Set individual limits below. A single settlement may cross a credit floor."
                )
            ).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if parsedCreditFloors == nil && creditFloorsChanged {
                Text(language.text("请输入整数：第一档高于第二档，第二档不小于 0。", "Use whole points: first floor above second; second at least 0."))
                    .foregroundStyle(WorkspaceStatusForeground.warning)
            }
        }
        .font(.caption)
        .padding(8)
        .background(WorkspaceGlassSurface(cornerRadius: 10))
    }

    private var creditFallbackToggle: some View {
        Toggle(
            language.text("允许点数接续", "Enable credit fallback"),
            isOn: Binding(
                get: { model.creditFallbackEnabled }, set: { model.setCreditFallback($0) }
            )
        )
        .toggleStyle(WorkspaceCheckboxStyle()).disabled(!model.canEditPolicy)
        .fixedSize()
    }

    private var creditFloorFields: some View {
        HStack(spacing: 10) {
            creditFloorField(.primary, title: language.text("默认第一档", "Default first floor"), text: $primaryFloorText)
            creditFloorField(.secondary, title: language.text("默认第二档", "Default second floor"), text: $secondaryFloorText)
            Text(language.text("点", "points")).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func creditFloorField(_ floor: CreditFloor, title: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title)
            TextField(floor == .primary ? "2000" : "1500", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(width: 84, height: 30)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(focusedCreditFloor == floor ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: 1)
                }
                .focused($focusedCreditFloor, equals: floor)
                .onSubmit(saveCreditFloors)
                .accessibilityLabel(language.text(title + "点数", title + " points"))
                .accessibilityIdentifier(floor == .primary ? "next.local-proxy.credit-primary" : "next.local-proxy.credit-secondary")
        }
    }

    private var saveCreditFloorsButton: some View {
        Button(language.text("保存底线", "Save floors")) {
            saveCreditFloors()
        }
        .disabled(!model.canEditPolicy || !creditFloorsChanged || parsedCreditFloors == nil)
        .accessibilityIdentifier("next.local-proxy.credit-save")
        .fixedSize()
    }

    private func saveCreditFloors() {
        guard model.canEditPolicy, creditFloorsChanged, let floors = parsedCreditFloors else { return }
        model.setCreditFloors(primary: floors.primary, secondary: floors.secondary)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Label(language.text("反代模式", "Reverse proxy mode"), systemImage: "network")
                .font(.headline)
            Circle().fill(phaseColor).frame(width: 8, height: 8)
            Text(phaseTitle).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Button {
                showingPanelInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(language.text("面板说明", "Panel info"))
            .popover(isPresented: $showingPanelInfo) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        language.text(
                            "供连接到本地代理的新任务使用；当前桌面任务不会自动改走代理。",
                            "For new tasks connected to the local proxy. Current desktop tasks are not redirected automatically."
                        )
                    )
                    Text(
                        language.text(
                            "先用订阅额度，再用点数。Pro20x 默认最后使用，可随时调整；优先、最后使用与排序对新请求生效，开关与账号页同步。",
                            "Subscriptions precede credits. Pro20x defaults to Use last and can be changed. Priority, Use last and order apply to new requests and sync with the account page."
                        )
                    )
                    Text(
                        language.text(
                            "状态约每分钟更新；刷新可立即查看已收集快照。",
                            "Request activity is a recent snapshot, updated about once a minute. Refresh to view collected data now."
                        )
                    )
                    Text(
                        language.text(
                            "优先与排序用于新请求；取消参与也拦截等待与重试。已接入的响应继续完成，关闭面板不会停止代理。",
                            "Priority and order apply to new requests. Disabling participation also blocks waiting requests and retries. Admitted responses finish; closing this panel keeps the proxy running."
                        )
                    )
                }
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 320)
            }
            Spacer()
            Button(language.text("关闭面板", "Close panel")) {
                cancelLegacyCooldownRecovery()
                if let onClose { onClose() } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var proxyToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                runActions
                Spacer(minLength: 0)
                if let endpoint = model.endpoint {
                    endpointLabel(endpoint)
                    connectionActions
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                runActions
                if let endpoint = model.endpoint {
                    HStack(spacing: 12) {
                        endpointLabel(endpoint)
                        Spacer(minLength: 0)
                        connectionActions
                    }
                }
            }
        }
        .padding(8)
        .background(WorkspaceGlassSurface(cornerRadius: 10))
    }

    private var advancedRules: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                networkSettings
                creditSettings
                LocalProxyPlusLimitEditor(
                    language: language, accountCount: model.plusPolicyTargetCount,
                    savedLimit: model.uniformPlusFiveHourUsedLimit,
                    enabled: model.canEditPolicy, canApply: model.canApplyPlusFiveHourUsedLimit,
                    message: model.plusPolicyMessage,
                    save: { model.setPlusFiveHourUsedLimit($0) })
            }.padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(language.text("高级规则（连接 · 网络 · 额度）", "Advanced rules (connection · network · limits)")).font(.callout)
                if creditFloorsChanged {
                    Text(language.text("未保存", "Unsaved")).font(.caption).foregroundStyle(WorkspaceStatusForeground.warning)
                }
            }
        }
    }

    private var queueHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language.text("代理账号队列", "Proxy account queue")).font(.headline)
                Text(language.text("共 \(model.displayRows.count) 个账号", "\(model.displayRows.count) accounts"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshStatus(displayFreshResultsImmediately: true)
                    model.flushDisplayRows()
                } label: {
                    Label(language.text("刷新额度", "Refresh limits"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            if model.phase == .running && model.membershipChangeWaiting {
                Text(
                    language.text(
                        "取消参与后不再接收新的调用，等待与重试也会跳过；已接入的响应继续完成。",
                        "Disabling participation skips new admissions, including waiting requests and retries. Admitted responses continue to completion."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var runActions: some View {
        HStack(spacing: 8) {
            if model.phase == .starting || model.phase == .stopping {
                ProgressView().controlSize(.small)
            }
            Button(language.text("开启反代", "Start proxy")) {
                model.setOptIn(true)
                Task { await model.start() }
            }
            .buttonStyle(WorkspaceActionButtonStyle(prominent: true))
            .disabled(!model.canStart || creditFloorsChanged)
            .accessibilityIdentifier("next.local-proxy.start")
            Button(language.text("停止反代", "Stop proxy")) {
                if model.requiresStopConfirmation { confirmingStop = true } else { disableProxy() }
            }
            .disabled((!model.canStop && !model.isEnabled) || model.phase == .stopping)
            .accessibilityIdentifier("next.local-proxy.stop")
        }
        .fixedSize()
    }

    private func disableProxy() {
        Task {
            await model.stop()
            if model.canEdit { model.setOptIn(false) }
        }
    }

    private func accountRow(_ row: LocalProxyQueueRow, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(rowStatusColor(row)).frame(width: 8, height: 8)
                    .help(stateTitle(row) + (row.quotaText.map { " · \($0)" } ?? ""))
                Text(row.accountNumber.map { String(format: "%02d", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(row.label).font(.callout.weight(.semibold)).lineLimit(1)
                if row.isDesktopAccount {
                    Image(systemName: "macwindow").foregroundStyle(.secondary)
                        .help(language.text("桌面账号 · 所在分组最后使用", "Desktop account · Last within its group"))
                }
                Text(stateTitle(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let pausedAt = row.resetPausedAt, !row.isEnabled {
                    Text(language.text("已暂停新任务", "Paused")).font(.caption).foregroundStyle(WorkspaceStatusForeground.warning)
                        .help(language.dateTime(pausedAt))
                }
                if row.snapshotStale {
                    Label(language.text("上次快照", "Last snapshot"), systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(language.text("上次快照 · 待刷新", "Last snapshot · refresh needed"))
                }
                Spacer(minLength: 0)
                Toggle(
                    language.text("参与", "Use"),
                    isOn: Binding(
                        get: { row.isEnabled },
                        set: {
                            model.setAccountEnabled(id: row.id, enabled: $0)
                            model.flushDisplayRows()
                        }
                    )
                )
                .disabled(!model.canToggleAccount(id: row.id))
                .accessibilityLabel(language.text("\(accountTitle(row)) 参与调用", "Use \(accountTitle(row)) for proxy requests"))
                orderMenu(row)
            }
            .font(.caption).toggleStyle(WorkspaceCheckboxStyle()).controlSize(.small)
            LocalProxyAccountPolicyEditor(
                row: row, language: language, enabled: model.canEditPolicy(for: row.id),
                globalCreditsEnabled: model.creditFallbackEnabled,
                defaultPrimary: model.creditPrimaryFloor, defaultSecondary: model.creditSecondaryFloor,
                initiallyExpanded: previewExpandedRules,
                quotaContent: quotaGroup(row), resetAction: resetCreditAction(row),
                accessory: resetStopControl(row),
                save: { model.setAccountPolicy(id: row.id, policy: $0) }
            )
            .environment(\.widgetLanguage, language)
            if let deadline = row.cooldownUntil, deadline > Date() {
                HStack(spacing: 4) {
                    Text(language.text("冷却至", "Cooldown until"))
                    Text(deadline, style: .time)
                    if row.cooldownKind == "egress" {
                        Text(row.probeState == "probing" ? language.text("探测恢复中", "Probing recovery") : language.text("出口异常 · 等待探测", "Egress issue · Awaiting probe"))
                        Button(language.text("立即探测", "Probe now")) { model.probeNow(profileID: row.id) }
                            .disabled(model.phase != .running || row.probeState == "probing")
                            .accessibilityIdentifier("next.local-proxy.probe-\(row.id)")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if model.legacyCooldownRecoveryIDs.contains(row.id) {
                HStack(spacing: 8) {
                    Button {
                        preparingLegacyCooldownID = row.id
                        model.prepareLegacyCooldownRecovery(for: row.id) { prepared in
                            preparingLegacyCooldownID = nil
                            guard prepared else { return }
                            legacyCooldownAccountID = row.id
                            legacyCooldownAccountTitle = accountTitle(row)
                            confirmingLegacyCooldown = true
                        }
                    } label: {
                        Label(language.text("清理旧版冷却…", "Clear legacy cooldown…"), systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    .disabled(!model.canRecoverLegacyCooldown(for: row.id))
                    .help(language.text("停止反代后，核验此账号的最新订阅额度，确认后先备份再清理。", "Stop the proxy, verify this account’s latest subscription quota, then confirm to back up and clear."))
                    .accessibilityIdentifier("next.local-proxy.legacy-cooldown-\(row.id)")
                    if preparingLegacyCooldownID == row.id {
                        ProgressView().controlSize(.small)
                        Text(language.text("正在核验额度…", "Verifying quota…"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(language.text("取消", "Cancel")) {
                            model.cancelLegacyCooldownRecovery()
                            preparingLegacyCooldownID = nil
                        }.controlSize(.small)
                    }
                    if !model.canEdit {
                        Text(language.text("请先停止反代", "Stop the proxy first"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            if model.hasStaleRunningBinding(for: row.id) {
                Text(
                    language.text(
                        "此账号登录身份与反代启动时不同；关闭反代后可保存规则，重新开启后用于新请求。",
                        "This account's sign-in changed since proxy startup. Stop the proxy to save rules, then restart it for new requests."
                    )
                )
                .font(.caption).foregroundStyle(WorkspaceStatusForeground.warning)
            }
        }
        .padding(10)
        .background(WorkspaceGlassSurface(cornerRadius: 10))
        .accessibilityIdentifier("next.local-proxy.account-\(row.id)")
    }

    private func quotaGroup(_ row: LocalProxyQueueRow) -> some View {
        HStack(spacing: 14) {
            ForEach(row.windows) { window in
                CompactQuotaView(
                    title: window.id, remaining: window.remaining, reset: window.resetsAt,
                    paletteRole: window.id == "5h" ? .primary : .secondary,
                    constrainedByWeekly: window.constrainedByWeekly, horizontalDetails: true,
                    isWeeklyOnlyPro: window.isWeeklyOnlyPro
                )
                .frame(minWidth: 125, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .help(row.quotaText ?? "")
    }

    @ViewBuilder
    private func resetCreditAction(_ row: LocalProxyQueueRow) -> some View {
        if let target = model.resetCreditTarget(for: row.id) {
            ResetCreditButton(
                profile: target.profile, selectedProfileID: target.selectedProfileID,
                hubAccountAlias: target.hubAccountAlias,
                onConfirmedResult: { model.refreshAfterResetCredit(target) }, displayNumber: row.accountNumber,
                prominent: true
            ).accessibilityIdentifier("next.local-proxy.reset-card-\(row.id)")
        } else {
            Text(row.resetCardCount.map { language.text("重置卡 \($0)", "\($0) reset cards") } ?? language.text("重置卡 —", "Reset cards —"))
                .font(.caption).foregroundStyle(.secondary)
        }
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

    private var phaseColor: Color {
        switch model.phase {
        case .running: return FixedVisualPalette.statusSuccess
        case .starting, .stopping: return FixedVisualPalette.statusWarning
        case .failed: return FixedVisualPalette.statusDanger
        case .stopped: return FixedVisualPalette.statusNeutral
        }
    }

    private func rowStatusColor(_ row: LocalProxyQueueRow) -> Color {
        if !row.isEnabled { return FixedVisualPalette.statusNeutral }
        if row.state == "login_expired" { return FixedVisualPalette.statusDanger }
        if row.state == "quota" || row.state == "usage_limit" { return FixedVisualPalette.statusWarning }
        if let deadline = row.cooldownUntil, deadline > Date() { return FixedVisualPalette.statusWarning }
        if row.state == "temporary_error" { return FixedVisualPalette.statusWarning }
        if row.isCurrent || row.state == "current" || row.state == "ready" { return FixedVisualPalette.statusSuccess }
        return Color.secondary
    }

    private func orderMenu(_ row: LocalProxyQueueRow) -> some View {
        Menu {
            Toggle(
                language.text("优先", "Priority"),
                isOn: Binding(
                    get: { row.isPriority },
                    set: {
                        model.setAccountPriority(id: row.id, priority: $0)
                        model.flushDisplayRows()
                    }
                )
            )
            .disabled(!model.canReorder)
            .accessibilityLabel(language.text("\(accountTitle(row)) 优先调用", "Prioritize \(accountTitle(row)) for proxy requests"))
            Toggle(
                language.text("最后使用", "Use last"),
                isOn: Binding(
                    get: { row.isLast },
                    set: {
                        model.setAccountLast(id: row.id, last: $0)
                        model.flushDisplayRows()
                    }
                )
            )
            .disabled(!model.canSetAccountLast(id: row.id))
            .accessibilityLabel(language.text("\(accountTitle(row)) 最后使用", "Use \(accountTitle(row)) last"))
            Divider()
            Button(language.text("上移", "Move up")) {
                model.moveAccount(id: row.id, by: -1)
                model.flushDisplayRows()
            }
            .disabled(!model.canMoveAccount(id: row.id, by: -1))
            Button(language.text("下移", "Move down")) {
                model.moveAccount(id: row.id, by: 1)
                model.flushDisplayRows()
            }
            .disabled(!model.canMoveAccount(id: row.id, by: 1))
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(language.text("排序与使用顺序；优先和最后使用互斥", "Order and usage; Priority and Use last are mutually exclusive"))
        .accessibilityLabel(language.text("\(accountTitle(row)) 排序", "Order \(accountTitle(row))"))
    }

    private func resetStopControl(_ row: LocalProxyQueueRow) -> some View {
        HStack(spacing: 8) {
            Toggle(
                language.text("额度恢复后暂停", "Pause after quota reset"),
                isOn: Binding(
                    get: { row.pausesAfterReset },
                    set: {
                        model.setResetStop(id: row.id, enabled: $0)
                        model.flushDisplayRows()
                    })
            )
            .disabled(!model.canSetResetStop(id: row.id))
            .toggleStyle(WorkspaceCheckboxStyle())
            .help(
                language.text(
                    "检测到此账号真实的 5 小时或 7 天额度恢复（含自然重置）后，停止接新任务；当前回复继续完成。预告、倒计时归零不触发。重新勾选参与即可继续。",
                    "After verified 5-hour or 7-day quota recovery, including a natural reset, stop new tasks and let admitted responses finish. Forecasts and countdowns do not trigger this. Re-enable Use to resume."
                )
            )
            .accessibilityIdentifier("next.local-proxy.pause-after-reset-\(row.id)")
            if let pausedAt = row.resetPausedAt, !row.isEnabled {
                Text(language.text("额度已恢复 · 已暂停新任务", "Quota reset · new tasks paused"))
                    .foregroundStyle(.secondary)
                    .help(language.dateTime(pausedAt))
            }
            Spacer(minLength: 0)
        }
        .font(.caption).controlSize(.small)
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
        case "usage_limit": return language.text("已达自定上限", "Custom limit reached")
        case "subscription_pending": return language.text("订阅额度优先", "Subscription first")
        case "login_expired": return language.text("登录已失效", "Sign-in expired")
        case "temporary_error": return language.text("暂时异常", "Temporary error")
        case "busy": return language.text("上次请求忙碌", "Last request busy")
        case "credentials_busy": return language.text("上次凭据读取忙碌", "Last credential read busy")
        default: return language.text("额度未知", "Limits unknown")
        }
    }
}

private struct LocalProxyPlusLimitEditor: View {
    let language: WidgetLanguage
    let accountCount: Int
    let savedLimit: Double?
    let enabled: Bool
    let canApply: Bool
    let message: String?
    let save: (Double) -> Bool
    @State private var limit = ""
    @State private var savedValue: Double?
    @State private var initialized = false
    @State private var saveFailed = false

    private var value: Double? {
        guard let number = Double(limit.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite,
            (0...100).contains(number)
        else { return nil }
        return number
    }
    private func text(_ number: Double?) -> String {
        guard let number else { return "" }
        return number.rounded() == number ? String(Int(number)) : String(number)
    }
    private var dirty: Bool { initialized && limit != text(savedValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalProxyPolicyFieldsLayout(trailingAction: true) {
                limitField
                applyButton
            }
            Text(
                language.text(
                    "当前 \(accountCount) 个 Plus（含未参与）；Pro 等其他及未知套餐规则不变。",
                    "\(accountCount) current Plus accounts, including non-participants; Pro, other and unknown plans remain unchanged.")
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(
                language.text(
                    "仅设 5 小时已用上限，仍可单独调整；低于 100% 达限停新请求，100% 保留原点数接续规则。",
                    "Set only the 5h used limit; individual overrides remain. Below 100%, stop new requests at the limit; at 100%, existing credit fallback remains.")
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if savedLimit == nil && !dirty {
                Text(language.text("没有已核实的 Plus 账号，或 Plus 上限不同。", "No verified Plus accounts, or Plus limits differ.")).foregroundStyle(.secondary)
            }
            if dirty && value == nil {
                Text(language.text("请输入 0–100 的已用百分比，可用小数。", "Enter a used percentage from 0 to 100; decimals are allowed."))
                    .foregroundStyle(WorkspaceStatusForeground.warning)
            }
            if enabled && accountCount > 0 && !canApply {
                Text(language.text("有 Plus 账号身份或运行绑定待核实，全部规则暂不能修改。", "A Plus account identity or running binding needs verification; no rules can be changed."))
                    .foregroundStyle(WorkspaceStatusForeground.warning)
            }
            if let message {
                if saveFailed { Text(message).foregroundStyle(WorkspaceStatusForeground.warning) } else { Text(message).foregroundStyle(.secondary) }
            }
        }
        .font(.caption).controlSize(.small).padding(8)
        .background(WorkspaceGlassSurface(cornerRadius: 10))
        .help(
            language.text(
                "填写已用百分比，不是剩余额度。仅修改上限，不改变参与、顺序或点数授权。低于 100% 达到上限时点数不能绕过；100% 保留原点数接续规则。已接入响应继续完成。",
                "Enter used percent, not remaining quota. Only limits change; participation, order and credit permission remain. Credits cannot bypass a reached limit below 100%; at 100%, existing credit fallback rules remain. Admitted responses finish."
            )
        )
        .onAppear {
            guard !initialized else { return }
            savedValue = savedLimit
            limit = text(savedLimit)
            initialized = true
        }
        .onChange(of: savedLimit) { updated in
            let preserveDraft = dirty
            savedValue = updated
            if !preserveDraft { limit = text(updated) }
        }
    }

    private var limitField: some View {
        HStack(spacing: 6) {
            Text(language.text("Plus 5h 已用上限", "Plus 5h used limit"))
            TextField("0–100", text: $limit).textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .padding(.horizontal, 8).frame(width: 76, height: 30)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1) }
                .accessibilityLabel(language.text("Plus 账号 5 小时已用百分比上限", "Maximum 5h used percentage for Plus accounts"))
                .accessibilityIdentifier("next.local-proxy.uniform-used-limit")
                .disabled(!enabled)
            Text("%")
            if dirty { Text(language.text("未保存", "Unsaved")).foregroundStyle(WorkspaceStatusForeground.warning) }
        }
    }
    private var applyButton: some View {
        Button(language.text("应用到 Plus 账号", "Apply to Plus accounts")) {
            guard let value else { return }
            if save(value) {
                savedValue = value
                limit = text(value)
                saveFailed = false
            } else {
                saveFailed = true
            }
        }
        .disabled(!canApply || value == nil || !dirty)
        .accessibilityIdentifier("next.local-proxy.uniform-used-apply")
    }
}

private struct LocalProxyAccountPolicyEditor<QuotaContent: View, ResetAction: View, Accessory: View>: View {
    let row: LocalProxyQueueRow
    let language: WidgetLanguage
    let enabled: Bool
    let globalCreditsEnabled: Bool
    let defaultPrimary: Int
    let defaultSecondary: Int
    var initiallyExpanded = false
    let quotaContent: QuotaContent
    let resetAction: ResetAction
    let accessory: Accessory
    let save: (LocalProxyAccountPolicy) -> Bool
    @State private var limit = ""
    @State private var allowsCredits = true
    @State private var usesDefaults = true
    @State private var primary = ""
    @State private var secondary = ""
    @State private var initialized = false
    @State private var savedPolicy: LocalProxyAccountPolicy?
    @State private var savedDefaultPrimary: Int?
    @State private var savedDefaultSecondary: Int?
    @State private var expanded = false
    @State private var saveFailed = false

    private struct SavedState: Equatable {
        var policy: LocalProxyAccountPolicy
        let defaultPrimary: Int
        let defaultSecondary: Int
    }
    private var savedState: SavedState {
        var policy = row.policy
        if row.usesDefaultCreditFloors {
            policy.creditPrimaryFloor = nil
            policy.creditSecondaryFloor = nil
        }
        return SavedState(policy: policy, defaultPrimary: defaultPrimary, defaultSecondary: defaultSecondary)
    }
    private var dirty: Bool { initialized && policy != savedPolicy }
    private var policy: LocalProxyAccountPolicy? {
        guard let value = Double(limit.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var candidate = savedPolicy ?? savedState.policy
        candidate.fiveHourUsedLimit = value
        candidate.allowsCredits = allowsCredits
        candidate.creditPrimaryFloor = usesDefaults ? nil : Int(primary)
        candidate.creditSecondaryFloor = usesDefaults ? nil : Int(secondary)
        guard candidate.isValid, usesDefaults || (candidate.creditPrimaryFloor != nil && candidate.creditSecondaryFloor != nil) else { return nil }
        return candidate
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LocalProxyAccountSummaryLayout {
                quotaContent.fixedSize(horizontal: true, vertical: false)
                policySummary
                VStack(alignment: .trailing, spacing: 6) {
                    resetAction
                    disclosureAction
                }.fixedSize()
            }
            if expanded {
                Divider()
                accessory
                LocalProxyPolicyFieldsLayout(trailingAction: true) {
                    limitFields
                    allowCreditsToggle
                    saveButton
                }
                LocalProxyPolicyFieldsLayout {
                    defaultsToggle
                    creditFloors
                }
                if dirty && policy == nil {
                    Text(language.text("上限为 0–100%；底线须为整数，第一档高于第二档，第二档不小于 0。", "Use a limit of 0–100%. Floors must be whole points: first above second, second at least 0."))
                        .foregroundStyle(WorkspaceStatusForeground.warning).fixedSize(horizontal: false, vertical: true)
                }
                if saveFailed {
                    Text(language.text("规则未保存，草稿已保留。请查看面板中的故障提示。", "Rules were not saved; your draft is retained. Check the panel warning."))
                        .foregroundStyle(WorkspaceStatusForeground.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption).controlSize(.small)
        .onAppear {
            if !initialized {
                resetDrafts(to: savedState)
                expanded = initiallyExpanded
                initialized = true
            }
        }
        .onChange(of: savedState) { value in
            // SwiftUI may retain a callback with the previous row. Use the delivered snapshot.
            let preserveDraft = dirty
            let previous = savedPolicy ?? value.policy
            let limitEdited = Double(limit.trimmingCharacters(in: .whitespacesAndNewlines)) != previous.fiveHourUsedLimit
            let creditsEdited = allowsCredits != previous.allowsCredits
            let defaultsEdited = usesDefaults != (previous.creditPrimaryFloor == nil)
            let primaryEdited = !usesDefaults && (defaultsEdited || Int(primary) != (previous.creditPrimaryFloor ?? savedDefaultPrimary))
            let secondaryEdited = !usesDefaults && (defaultsEdited || Int(secondary) != (previous.creditSecondaryFloor ?? savedDefaultSecondary))
            savedPolicy = value.policy
            if !preserveDraft {
                resetDrafts(to: value)
            } else {
                if !limitEdited { limit = limitText(value.policy.fiveHourUsedLimit) }
                if !creditsEdited { allowsCredits = value.policy.allowsCredits }
                if !defaultsEdited { usesDefaults = value.policy.creditPrimaryFloor == nil }
                if !primaryEdited { primary = String(value.policy.creditPrimaryFloor ?? value.defaultPrimary) }
                if !secondaryEdited { secondary = String(value.policy.creditSecondaryFloor ?? value.defaultSecondary) }
                savedDefaultPrimary = value.defaultPrimary
                savedDefaultSecondary = value.defaultSecondary
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("\(row.label) 的反代规则", "Proxy rules for \(row.label)"))
    }

    private var policySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            LocalProxyInlineInfoLayout {
                Text(summary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).help(summary)
                currentCreditBalance
            }
            if allowsCredits && !globalCreditsEnabled {
                Text(language.text("点数总开关未开启，此账号当前仅用订阅额度。", "Credit fallback is off above. This account currently uses subscription quota only."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var disclosureAction: some View {
        HStack(spacing: 6) {
            if dirty {
                Text(language.text("未保存", "Unsaved")).foregroundStyle(WorkspaceStatusForeground.warning)
            }
            Button {
                expanded.toggle()
            } label: {
                Label(language.text("规则", "Rules"), systemImage: expanded ? "chevron.up" : "chevron.down")
            }
            .accessibilityIdentifier("next.local-proxy.rules-\(row.id)")
            .help(language.text("展开或收起编辑；未保存草稿会保留。", "Expand or collapse editing; unsaved drafts are retained."))
        }.fixedSize()
    }

    @ViewBuilder
    private var currentCreditBalance: some View {
        if let balance = row.creditBalance {
            CreditBalanceView(
                presentation: balance, compact: true,
                title: language.text("现有点数", "Available credits")
            )
            .accessibilityIdentifier("next.local-proxy.credit-balance-\(row.id)")
        }
    }

    private var summary: String {
        let saved = row.policy
        let savedLimit = saved.fiveHourUsedLimit
        let limit = savedLimit.rounded() == savedLimit ? String(Int(savedLimit)) : String(savedLimit)
        let credits = saved.allowsCredits ? language.text("允许点数", "Credits allowed") : language.text("仅订阅", "Subscription only")
        let floors = "\(saved.creditPrimaryFloor ?? defaultPrimary) / \(saved.creditSecondaryFloor ?? defaultSecondary)"
        return language.text("5h 已用上限 \(limit)% · \(credits) · 保留 \(floors) 点", "5h used limit \(limit)% · \(credits) · Keep \(floors) points")
    }

    private var limitFields: some View {
        HStack(spacing: 6) {
            Text(language.text("5h 已用上限", "5h used limit"))
            field("0–100", text: $limit, label: language.text("5h 已用百分比上限", "Maximum 5h used percent"))
                .help(
                    language.text(
                        "低于 100% 时，到达上限便停止此账号，点数不会绕过上限。100% 时可按授权接续点数。",
                        "Below 100%, this account stops at the limit, including credits. At 100%, authorized credit fallback remains available."))
            Text("%")
        }.fixedSize().disabled(!enabled)
    }

    private var allowCreditsToggle: some View {
        Toggle(language.text("允许使用点数", "Allow credits"), isOn: $allowsCredits)
            .toggleStyle(WorkspaceCheckboxStyle()).fixedSize().disabled(!enabled)
            .help(language.text("取消后，此账号订阅额度耗尽就停止参与，不使用点数余额。", "When off, this account stops after its subscription quota is exhausted, without using credits."))
    }

    private var saveButton: some View {
        Button(language.text("保存规则", "Save rules")) {
            guard let policy else { return }
            if save(policy) {
                savedPolicy = policy
                saveFailed = false
            } else {
                saveFailed = true
                expanded = true
            }
        }.disabled(!enabled || !dirty || policy == nil).fixedSize()
    }

    private var defaultsToggle: some View {
        Toggle(language.text("沿用默认点数底线", "Use default credit floors"), isOn: $usesDefaults)
            .toggleStyle(WorkspaceCheckboxStyle()).fixedSize().disabled(!enabled)
    }
    private var creditFloors: some View {
        HStack(spacing: 6) {
            Text(language.text("保留", "Keep"))
            if usesDefaults {
                Text("\(defaultPrimary) / \(defaultSecondary)").monospacedDigit().foregroundStyle(.secondary)
            } else {
                field("2000", text: $primary, label: language.text("第一档保留点数", "First credit floor"))
                Text("/")
                field("1500", text: $secondary, label: language.text("第二档保留点数", "Second credit floor"))
            }
            Text(language.text("点（第一档 / 第二档）", "points (first / second)"))
                .foregroundStyle(.secondary)
        }.fixedSize().disabled(!enabled)
    }
    private func field(_ placeholder: String, text: Binding<String>, label: String) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.primary).padding(.horizontal, 8).frame(width: 64, height: 30)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1) }
            .accessibilityLabel(label)
    }
    private func resetDrafts(to value: SavedState) {
        let savedLimit = value.policy.fiveHourUsedLimit
        limit = limitText(savedLimit)
        allowsCredits = value.policy.allowsCredits
        usesDefaults = value.policy.creditPrimaryFloor == nil
        primary = String(value.policy.creditPrimaryFloor ?? value.defaultPrimary)
        secondary = String(value.policy.creditSecondaryFloor ?? value.defaultSecondary)
        savedPolicy = value.policy
        savedDefaultPrimary = value.defaultPrimary
        savedDefaultSecondary = value.defaultSecondary
    }
    private func limitText(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(value) }
}

/// Keep one native control per binding while changing their positions on resize.
private struct LocalProxyPolicyFieldsLayout: Layout {
    var trailingAction = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth =
            subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            + CGFloat(max(0, subviews.count - 1)) * 10
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: .init(width: frame.width, height: frame.height))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let inlineWidth = sizes.map(\.width).reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * 10
        if inlineWidth <= width {
            let height = sizes.map(\.height).max() ?? 0
            var offset: CGFloat = 0
            return sizes.enumerated().map { index, size in
                let x = trailingAction && index == sizes.count - 1 ? width - size.width : offset
                offset += size.width + 10
                return CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            }
        }
        if trailingAction, sizes.count == 3, sizes[0].width + 10 + sizes[2].width <= width {
            let height = max(sizes[0].height, sizes[2].height)
            return [
                CGRect(x: 0, y: (height - sizes[0].height) / 2, width: sizes[0].width, height: sizes[0].height),
                CGRect(x: 0, y: height + 8, width: sizes[1].width, height: sizes[1].height),
                CGRect(x: width - sizes[2].width, y: (height - sizes[2].height) / 2, width: sizes[2].width, height: sizes[2].height),
            ]
        }
        var offset: CGFloat = 0
        return sizes.enumerated().map { index, size in
            let x = trailingAction && index == sizes.count - 1 ? max(0, width - size.width) : 0
            let frame = CGRect(x: x, y: offset, width: size.width, height: size.height)
            offset += size.height + 6
            return frame
        }
    }
}

/// Reposition the same children so resizing retains reset-card confirmation and balance-popover state.
private struct LocalProxyAccountSummaryLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 760
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: .init(width: frame.width, height: frame.height))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 3 else { return [] }
        let quota = subviews[0].sizeThatFits(.unspecified)
        let actions = subviews[2].sizeThatFits(.unspecified)
        let besideQuota = width - quota.width - 14
        if besideQuota >= 180 {
            let summaryWidth = besideQuota - actions.width - 12
            if summaryWidth >= 180 {
                let summary = subviews[1].sizeThatFits(.init(width: summaryWidth, height: nil))
                let height = max(quota.height, summary.height, actions.height)
                return [
                    CGRect(x: 0, y: (height - quota.height) / 2, width: quota.width, height: quota.height),
                    CGRect(x: quota.width + 14, y: (height - summary.height) / 2, width: summaryWidth, height: summary.height),
                    CGRect(x: width - actions.width, y: (height - actions.height) / 2, width: actions.width, height: actions.height),
                ]
            }
            let summary = subviews[1].sizeThatFits(.init(width: besideQuota, height: nil))
            let informationHeight = summary.height + 6 + actions.height
            let height = max(quota.height, informationHeight)
            let informationY = (height - informationHeight) / 2
            return [
                CGRect(x: 0, y: (height - quota.height) / 2, width: quota.width, height: quota.height),
                CGRect(x: quota.width + 14, y: informationY, width: besideQuota, height: summary.height),
                CGRect(x: width - actions.width, y: informationY + summary.height + 6, width: actions.width, height: actions.height),
            ]
        }
        let summaryWidth = width - actions.width - 12
        let horizontal = summaryWidth >= 180
        let summary = subviews[1].sizeThatFits(.init(width: horizontal ? summaryWidth : width, height: nil))
        let informationY = quota.height + 8
        return [
            CGRect(x: 0, y: 0, width: quota.width, height: quota.height),
            CGRect(x: 0, y: informationY, width: horizontal ? summaryWidth : width, height: summary.height),
            CGRect(
                x: width - actions.width, y: horizontal ? informationY : informationY + summary.height + 6,
                width: actions.width, height: actions.height),
        ]
    }
}

private struct LocalProxyInlineInfoLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth =
            subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            + CGFloat(max(0, subviews.count - 1)) * 8
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: .init(width: frame.width, height: frame.height))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let horizontal = ideal.map(\.width).reduce(0, +) + CGFloat(max(0, ideal.count - 1)) * 8 <= width
        let sizes = horizontal ? ideal : subviews.map { $0.sizeThatFits(.init(width: width, height: nil)) }
        var offset: CGFloat = 0
        return sizes.map { size in
            let frame = CGRect(
                x: horizontal ? offset : 0, y: horizontal ? 0 : offset,
                width: horizontal ? size.width : width, height: size.height)
            offset += (horizontal ? size.width + 8 : size.height + 4)
            return frame
        }
    }
}
