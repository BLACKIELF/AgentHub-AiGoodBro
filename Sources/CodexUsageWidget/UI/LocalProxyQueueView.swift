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
    @FocusState private var focusedCreditFloor: CreditFloor?

    private enum CreditFloor: Hashable { case primary, secondary }

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
                    model.refreshStatus(displayFreshResultsImmediately: true)
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
            Text(
                language.text(
                    "请求状态为最近快照，约每分钟更新；手动刷新可立即查看已收集数据。",
                    "Request activity is a recent snapshot, updated about once a minute. Refresh to view collected data now."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            if model.phase == .running && model.membershipChangeWaiting {
                Text(
                    language.text(
                        "参与开关可随时调整，新请求生效；已开始的请求继续完成。",
                        "Participation changes apply to new requests; requests already started continue to completion."
                    )
                )
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
                    .font(.callout).foregroundStyle(WorkspaceStatusForeground.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("next.local-proxy.issue")
            }
            Text(
                language.text(
                    "运行中可保存规则，新请求采用新规则，已开始的请求继续完成。关闭此面板不会停止代理。",
                    "Rules can be saved while running. New requests use them; active requests finish. Closing this panel keeps the proxy running."
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
        .background {
            // The proxy window uses a transparent full-size titlebar; extend
            // the backdrop under it so the outer edge reads as one surface.
            WorkspaceGlassBackdrop().ignoresSafeArea()
        }
        .buttonStyle(WorkspaceActionButtonStyle())
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
                if model.requiresStopConfirmation { confirmingStop = true } else { disableProxy() }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(row.accountNumber.map { String(format: "%02d", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(row.label).font(.callout.weight(.semibold)).lineLimit(1)
                if row.isDesktopAccount {
                    Image(systemName: "macwindow").foregroundStyle(.secondary)
                        .help(language.text("桌面账号 · 同阶段最后使用", "Desktop account · Last within each stage"))
                }
                Text(stateTitle(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if row.snapshotStale {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
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
                .disabled(!model.canReorder || !row.isEnabled)
                .accessibilityLabel(language.text("\(accountTitle(row)) 优先调用", "Prioritize \(accountTitle(row)) for proxy requests"))
                HStack(spacing: 2) {
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
                }.buttonStyle(WorkspaceActionButtonStyle(compact: true))
            }
            .font(.caption).toggleStyle(WorkspaceCheckboxStyle()).controlSize(.small)
            HStack(spacing: 14) {
                ForEach(row.windows) { window in
                    CompactQuotaView(
                        title: window.id, remaining: window.remaining, reset: window.resetsAt,
                        paletteRole: window.id == "5h" ? .primary : .secondary,
                        constrainedByWeekly: window.constrainedByWeekly, horizontalDetails: true
                    ).frame(minWidth: 125, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .trailing, spacing: 4) {
                    if let balance = row.creditBalance { CreditBalanceView(presentation: balance, compact: true) }
                    if let target = model.resetCreditTarget(for: row.id) {
                        ResetCreditButton(
                            profile: target.profile, selectedProfileID: target.selectedProfileID,
                            hubAccountAlias: target.hubAccountAlias,
                            onConfirmedResult: { model.refreshAfterResetCredit(target) }, displayNumber: row.accountNumber
                        ).accessibilityIdentifier("next.local-proxy.reset-card-\(row.id)")
                    } else {
                        Text(row.resetCardCount.map { language.text("重置卡 \($0)", "\($0) reset cards") } ?? language.text("重置卡 —", "Reset cards —"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.fixedSize()
            }.environment(\.widgetLanguage, language).help(row.quotaText ?? "")
            if let deadline = row.cooldownUntil, deadline > Date() {
                HStack(spacing: 4) {
                    Text(language.text("冷却至", "Cooldown until"))
                    Text(deadline, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            LocalProxyAccountPolicyEditor(
                row: row, language: language, enabled: model.canEditPolicy(for: row.id),
                globalCreditsEnabled: model.creditFallbackEnabled,
                defaultPrimary: model.creditPrimaryFloor, defaultSecondary: model.creditSecondaryFloor,
                save: { model.setAccountPolicy(id: row.id, policy: $0) }
            )
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
        case "usage_limit": return language.text("已达自定上限", "Custom limit reached")
        case "subscription_pending": return language.text("订阅额度优先", "Subscription first")
        case "login_expired": return language.text("登录已失效", "Sign-in expired")
        case "temporary_error": return language.text("暂时异常", "Temporary error")
        case "busy": return language.text("账号忙碌", "Account busy")
        case "credentials_busy": return language.text("凭据读取中", "Credentials busy")
        default: return language.text("额度未知", "Limits unknown")
        }
    }
}

private struct LocalProxyAccountPolicyEditor: View {
    let row: LocalProxyQueueRow
    let language: WidgetLanguage
    let enabled: Bool
    let globalCreditsEnabled: Bool
    let defaultPrimary: Int
    let defaultSecondary: Int
    let save: (LocalProxyAccountPolicy) -> Bool
    @State private var limit = ""
    @State private var allowsCredits = true
    @State private var usesDefaults = true
    @State private var primary = ""
    @State private var secondary = ""
    @State private var initialized = false
    @State private var dirty = false

    private var policy: LocalProxyAccountPolicy? {
        guard let value = Double(limit.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let candidate = LocalProxyAccountPolicy(
            fiveHourUsedLimit: value, allowsCredits: allowsCredits,
            creditPrimaryFloor: usesDefaults ? nil : Int(primary), creditSecondaryFloor: usesDefaults ? nil : Int(secondary)
        )
        guard candidate.isValid, usesDefaults || (candidate.creditPrimaryFloor != nil && candidate.creditSecondaryFloor != nil) else { return nil }
        return candidate
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(language.text("5 小时已用上限", "5h used limit"))
                field("100", text: $limit, label: language.text("5 小时已用百分比上限", "Maximum 5h used percent"))
                    .help(
                        language.text(
                            "低于 100% 时，到达上限便停止此账号，点数不会绕过上限。100% 时可按授权接续点数。",
                            "Below 100%, this account stops at the limit, including credits. At 100%, authorized credit fallback remains available."))
                Text("%")
                Toggle(language.text("允许使用点数", "Allow credits"), isOn: $allowsCredits)
                    .toggleStyle(WorkspaceCheckboxStyle())
                    .help(language.text("取消后，此账号订阅额度耗尽就停止参与，不使用点数余额。", "When off, this account stops after its subscription quota is exhausted, without using credits."))
                Spacer(minLength: 0)
                if dirty { Text(language.text("未保存", "Unsaved")).foregroundStyle(.secondary) }
                Button(language.text("保存规则", "Save rules")) {
                    if let policy, save(policy) { dirty = false }
                }.disabled(!dirty || policy == nil)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    defaultsToggle
                    creditFloors
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    defaultsToggle
                    creditFloors
                }
            }
            if dirty && policy == nil {
                Text(language.text("上限为 0–100%；点数底线须为整数，第一档高于第二档，第二档不小于 0。", "Use a limit of 0–100%. Credit floors must be whole points: first above second, second at least 0."))
                    .foregroundStyle(WorkspaceStatusForeground.warning).fixedSize(horizontal: false, vertical: true)
            } else if allowsCredits && !globalCreditsEnabled {
                Text(language.text("点数总开关未开启，此账号当前仅用订阅额度。", "Credit fallback is off above. This account currently uses subscription quota only."))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption).controlSize(.small).disabled(!enabled)
        .onAppear {
            if !initialized {
                resetDrafts()
                initialized = true
            }
        }
        .onChange(of: row.policy) { _ in if !dirty { resetDrafts() } }
        .onChange(of: row.usesDefaultCreditFloors) { _ in if !dirty { resetDrafts() } }
        .onChange(of: limit) { _ in markDirty() }
        .onChange(of: allowsCredits) { _ in markDirty() }
        .onChange(of: usesDefaults) { _ in markDirty() }
        .onChange(of: primary) { _ in markDirty() }
        .onChange(of: secondary) { _ in markDirty() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("\(row.label) 的反代规则", "Proxy rules for \(row.label)"))
    }
    private var defaultsToggle: some View {
        Toggle(language.text("沿用默认点数底线", "Use default credit floors"), isOn: $usesDefaults)
            .toggleStyle(WorkspaceCheckboxStyle()).fixedSize()
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
        }.fixedSize()
    }
    private func field(_ placeholder: String, text: Binding<String>, label: String) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced)).frame(width: 64)
            .accessibilityLabel(label)
    }
    private func resetDrafts() {
        let savedLimit = row.policy.fiveHourUsedLimit
        limit = savedLimit.rounded() == savedLimit ? String(Int(savedLimit)) : String(savedLimit)
        allowsCredits = row.policy.allowsCredits
        usesDefaults = row.usesDefaultCreditFloors
        primary = String(row.policy.creditPrimaryFloor ?? defaultPrimary)
        secondary = String(row.policy.creditSecondaryFloor ?? defaultSecondary)
        dirty = false
    }
    private func markDirty() {
        guard initialized else { return }
        var saved = row.policy
        if row.usesDefaultCreditFloors {
            saved.creditPrimaryFloor = nil
            saved.creditSecondaryFloor = nil
        }
        dirty = policy != saved
    }
}
