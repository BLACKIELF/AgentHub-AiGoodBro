import SwiftUI

@MainActor
struct NextSetupGuideView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var localAccounts: LocalCLIAccountStore
    var openAutomation: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var webhookDraft = ""
    @State private var confirmsCompanionInstall = false
    @StateObject private var runtime: NextRuntimeSetupModel

    init(
        store: UsageStore, settings: AppSettings, localAccounts: LocalCLIAccountStore? = nil, openAutomation: @escaping () -> Void,
        runtime: NextRuntimeSetupModel = NextRuntimeSetupModel()
    ) {
        self.store = store
        self.settings = settings
        self.localAccounts = localAccounts ?? LocalCLIAccountStore()
        self.openAutomation = openAutomation
        _runtime = StateObject(wrappedValue: runtime)
    }

    private var language: WidgetLanguage { settings.language }
    private var step: NextSetupStep { settings.setupProgress.step }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        pageContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                }
                Divider()
                footer
            }
        }
        .frame(width: 900, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(language.text("安装配套调用工具？", "Install companion tools?"), isPresented: $confirmsCompanionInstall, titleVisibility: .visible) {
            Button(language.text("安装并检查", "Install and check")) { runtime.installTools() }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                language.text(
                    "将写入 ~/.codex/skills/multi-agent-management 的受管文件，并更新应用 Support 目录的运行时链接；已有受管文件会先备份。保留 Skill 非受管文档，不改系统 auth.json/config.toml。请先确认没有使用该运行器的在途任务；本向导不会代为结束任务。",
                    "Writes managed files under ~/.codex/skills/multi-agent-management and updates the runtime link in application support. Existing managed files are backed up; unmanaged Skill text and system auth.json/config.toml are preserved. Ensure no tasks are using this runner; this guide does not stop tasks."
                ))
        }
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
        .environment(\.codexDeviceLoginHost, .setupGuide)
        .modifier(CodexDeviceLoginSheet(store: store, language: language, host: .setupGuide))
        .onAppear {
            if !store.isPreview { store.refreshLocalNotificationAuthorization() }
            if step == .runtime { runtime.refresh() }
        }
        .onDisappear {
            if settings.onboarding.shouldPresent { settings.onboarding.skip() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshLocalNotificationAuthorization()
            if step == .runtime { runtime.refresh() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text("AiGoodBro")
                } icon: {
                    AHBrandSymbol(size: 24)
                }.font(.headline)
                    .foregroundStyle(.secondary)
                Text(language.text("使用引导", "Getting started")).font(.title2.weight(.semibold))
            }
            VStack(spacing: 8) {
                ForEach(NextSetupStep.allCases) { item in
                    Button {
                        go(to: item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .frame(width: 20)
                            Text(item.title(language)).font(.subheadline.weight(item == step ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(item == step ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .background(item == step ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(item == step ? language.text("当前步骤", "Current step") : "")
                }
            }
            Spacer()
            Text(language.text("随时跳过，之后可从工作台继续。", "Skip anytime and return from your workspace."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(step.index + 1) / \(NextSetupStep.allCases.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel(language.text("第 \(step.index + 1) 步，共 \(NextSetupStep.allCases.count) 步", "Step \(step.index + 1) of \(NextSetupStep.allCases.count)"))
        }
        .padding(22)
        .frame(width: 205)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch step {
        case .runtime: runtimePage
        case .accounts: SetupAccountsView(store: store, localAccounts: localAccounts, language: language)
        case .features: featuresPage
        case .notifications: notificationsPage
        case .ready: readyPage
        }
    }

    private var runtimePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(
                language.text("准备工具与配套 Skill", "Tools & companion Skill"),
                language.text("优先复用已安装的工具。缺少时按需安装，回到这里会自动重新检查。", "Use the tools already on your Mac. Install missing tools when needed; Next checks again when you return."))
            VStack(spacing: 12) {
                ForEach(["codex", "python", "hub"], id: \.self) { id in
                    let component = runtime.report?.components.first { $0.id == id }
                    HStack(spacing: 10) {
                        Image(systemName: component?.state == "ready" ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(component?.state == "ready" ? Color.green : Color.secondary)
                        Text(id == "codex" ? "Codex CLI" : id == "python" ? "Python" : language.text("本机调度组件", "Local dispatch component"))
                        Spacer()
                        Text(componentStatus(id: id, component: component))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if id != "hub" {
                            Menu(language.text(component?.state == "ready" ? "管理" : "安装", component?.state == "ready" ? "Manage" : "Install")) {
                                Button(language.text("打开官方安装指南", "Open official installation guide")) {
                                    NSWorkspace.shared.open(id == "python" ? NextRuntimeEnvironment.pythonInstallationURL : NextRuntimeEnvironment.codexInstallationURL)
                                }
                                if id == "codex" {
                                    Button(language.text("复制官方安装命令", "Copy official install command")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(NextRuntimeEnvironment.codexInstallCommand, forType: .string)
                                    }
                                }
                                Button(language.text("选择已安装的程序…", "Choose an installed executable…")) { runtime.chooseExecutable(for: id) }
                            }.fixedSize().disabled(runtime.isBusy)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(language.text("配套调用 Skill", "Companion Skill"), systemImage: "shippingbox")
                    Spacer()
                    Text(runtime.report?.skill == "ready" ? language.text("已匹配随包工具", "Bundled tools match") : language.text("待安装或更新", "Install or update needed"))
                        .foregroundStyle(.secondary)
                }.font(.subheadline.weight(.medium))
                Text(
                    language.text(
                        "随应用提供 multi-agent-management、调用入口与运行器；检测到已有版本时由现有安装器备份受管文件并更新。安装完成后重新检查，不以按钮点击判成功。",
                        "The app includes multi-agent-management, launchers and runner files. The existing installer backs up managed files before updating. Recheck after installation; clicking the button is not success."
                    )
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12).sectionBackground()
            if runtime.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(language.text("正在验证组件…", "Checking components…")).font(.caption)
                }
            }
            if runtime.failed {
                Text(runtime.failureMessage(language))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if runtime.selectionFailed {
                Text(
                    language.text(
                        "所选程序未通过版本或能力检查，已保留原有选择。请从官方安装入口准备后重试。",
                        "The selected executable did not pass the version or capability check. Your previous choice is preserved. Install from the official source and try again.")
                )
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(language.text("重新检查", "Check again")) { runtime.refresh() }.disabled(runtime.isBusy)
                Spacer()
                Button(runtime.report?.skill == "ready" ? language.text("配套工具已安装", "Companion tools installed") : language.text("安装配套调用工具", "Install companion tools")) {
                    confirmsCompanionInstall = true
                }
                .disabled(!runtime.toolsReady || runtime.isBusy || runtime.report?.skill == "ready")
            }
            Text(
                language.text(
                    "Codex CLI 用于账号命令；Python 3.9+ 只用于配套 Skill。Python 未安装时，基础账号管理仍可使用。",
                    "Codex CLI runs account commands. Python 3.9+ is only required for the companion Skill; basic account management works without it.")
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(
                language.text(
                    "“可执行”只代表本机程序与能力检查通过，不代表已登录。账号身份、额度新鲜度、服务连通和任务审批会在实际调度时分别校验。",
                    "Executable means only that the local program and required capabilities passed. Sign-in, account identity, fresh limits, service connectivity, and task approval are checked separately when dispatching."
                )
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(language.text("本机任务调度", "Local task dispatch")).font(.subheadline.weight(.semibold))
                    Text(hubSetupStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(language.text("选择工作目录并启用", "Choose workspace and enable")) { runtime.chooseProjectAndSetUpHub() }
                    .disabled(!runtime.canSetUpHub || store.profiles.filter { !$0.isSystemProfile }.isEmpty)
            }
            Text(
                language.text(
                    "先在工作台添加账号，再启用调度。账号登录、macOS 通知和飞书连接由后续步骤引导完成；已有服务与个人配置会保留。",
                    "Add an account in the workspace before enabling dispatch. The next steps cover sign-in and alerts. Existing services and personal settings are preserved.")
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(
                language.text(
                    "首次调度先用配套入口生成 plan；启动中断时按原预约查看 status，再用 result 收取并校验结果。服务不会跳过审批。",
                    "For the first dispatch, create a plan with the companion entry point. If interrupted, check status using the original lease, then collect and verify it with result. Service approval is never skipped."
                )
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func componentStatus(id: String, component: NextRuntimeSetupModel.Component?) -> String {
        guard let component else { return language.text("待检查", "Not checked") }
        if component.state == "incompatible" { return language.text("需升级", "Update needed") }
        guard component.state == "ready" else { return language.text("未找到", "Not found") }
        let prefix = id == "hub" ? language.text("组件可用", "Bundled") : language.text("可执行", "Executable")
        return component.version.isEmpty ? prefix : "\(prefix) · \(component.version)"
    }

    private var hubSetupStatus: String {
        guard let component = runtime.report?.components.first(where: { $0.id == "hub" }) else {
            return language.text("尚未检查随包调度组件。", "The bundled dispatch component has not been checked yet.")
        }
        guard component.state == "ready" else {
            return language.text("随包调度组件缺失或损坏。请重新获取正式 Next 安装包。", "The bundled dispatch component is missing or damaged. Reinstall Next from an official package.")
        }
        switch runtime.report?.hub {
        case "ready": return language.text("已验证现有本机服务连通且版本匹配", "Existing local service is reachable and its version matches")
        case "existing_stopped": return language.text("发现现有配置，服务未运行。请从原部署入口恢复。", "Existing configuration found; the service is stopped. Restore it from its original deployment.")
        case "setup_incomplete":
            return language.text(
                "上次启用已写入配置但未确认服务健康。请先核实现有服务，不要重复启动。",
                "The previous setup wrote configuration but did not confirm service health. Verify the existing service; do not start another one.")
        case "port_conflict": return language.text("服务地址已被占用或无法验证。请先检查现有服务。", "The service address is occupied or could not be verified. Check the existing service first.")
        default: return language.text("组件已随包提供，启用后仅在本机运行，任务仍需批准。", "Included with Next. Enable it for local use; tasks still require approval.")
        }
    }

    private var accountsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                language.text("先看额度，再开始任务", "Check limits, then start work"),
                language.text("把账号的额度、任务和日常维护放在同一个工作台。", "Keep account limits, task status and daily maintenance together.")
            )
            AccountRecoveryGuide(store: store, language: language)
            Divider()
            Label(
                language.text(
                    "当前已管理 \(store.profiles.filter { !$0.isSystemProfile }.count) 个独立账号",
                    "\(store.profiles.filter { !$0.isSystemProfile }.count) isolated accounts currently managed"),
                systemImage: "person.crop.circle.badge.checkmark"
            )
            .font(.subheadline.weight(.medium))
            Text(language.text("添加或重新登录账号，都可以在工作台的账号区完成。", "Add accounts or sign in again from the account area in your workspace."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(
                language.text("按需设置自动维护", "Set up automatic maintenance"),
                language.text("已保存的选择会保留。暖号会发送最小请求，消耗少量额度。", "Saved choices are kept. Warm-up sends a minimal request and uses a small amount of quota.")
            )
            HStack {
                Text(language.text("\(store.enabledSetupFeatureCount) / 7 项已开启", "\(store.enabledSetupFeatureCount) of 7 enabled"))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button(language.text("全部开启", "Enable all")) { store.enableAllSetupFeatures() }
                    .disabled(store.enabledSetupFeatureCount == 7 || !store.pausedAutomationFeatures.isEmpty)
            }
            VStack(spacing: 0) {
                feature(
                    language.text("5 小时暖号", "Five-hour warm-up"), symbol: "bolt", value: store.warmUpSelection.fiveHour, paused: .fiveHour, action: store.setWarmUpFiveHourEnabled)
                Divider()
                feature(
                    language.text("7 天暖号", "Weekly warm-up"), symbol: "calendar", value: store.warmUpSelection.sevenDay, paused: .sevenDay, action: store.setWarmUpSevenDayEnabled)
                Divider()
                feature(
                    language.text("低额度提醒与账号推荐", "Low-limit alerts and suggestions"), symbol: "battery.25", value: store.automaticAccountSwitchEnabled, paused: .lowQuota,
                    action: store.setAutomaticAccountSwitchEnabled)
                Divider()
                feature(language.text("macOS 系统通知", "macOS notifications"), symbol: "bell", value: store.localNotificationsEnabled, paused: .localNotification) {
                    store.setLocalNotificationsEnabled($0, requestAuthorization: false)
                }
                Divider()
                feature(
                    language.text("飞书通知", "Feishu notifications"), symbol: "paperplane", value: store.feishuNotificationsEnabled, paused: .feishu,
                    action: store.setFeishuNotificationsEnabled)
                Divider()
                feature(
                    language.text("额度重置提醒", "Limit reset alerts"), symbol: "arrow.clockwise", value: store.feishuQuotaResetEnabled, paused: .feishu,
                    action: store.setFeishuQuotaResetEnabled)
                Divider()
                feature(
                    language.text("获得 Reset 卡提醒", "New reset credit alerts"), symbol: "ticket", value: store.feishuResetCreditEnabled, paused: .feishu,
                    action: store.setFeishuResetCreditEnabled)
            }
            Text(language.text("通知授权与飞书连接在下一步完成。Reset 卡始终由你手动使用。", "Set up notification permission and Feishu next. Reset credits are always used manually."))
                .font(.caption).foregroundStyle(.secondary)
            if !store.pausedAutomationFeatures.isEmpty {
                Label(language.text("维护期间部分功能暂停，原设置已保留。", "Some features are paused for maintenance. Saved choices are preserved."), systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var notificationsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                language.text("让提醒到达你", "Put alerts within reach"),
                language.text("功能开关和通知权限分开管理。你可以现在设置，也可以稍后继续。", "Feature switches and notification permissions are separate. Set them up now or come back later."))
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    connectionTitle(
                        "macOS", symbol: "bell.badge", status: localStatus,
                        ready: store.localNotificationsEnabled && store.localNotificationAuthorizationReady)
                    Text(language.text("在电脑上接收额度不足和重置消息，无需配置飞书。", "Receive low-limit alerts and reset news on this Mac. Feishu setup is optional."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let message = store.localNotificationMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(
                            store.localNotificationUsesSystemSettings
                                ? language.text("打开通知设置", "Open notification settings") : language.text("允许系统通知", "Allow notifications")
                        ) { store.configureLocalNotifications() }
                        .disabled(store.isRequestingLocalNotificationPermission || store.pausedAutomationFeatures.contains(.localNotification))
                        if store.isRequestingLocalNotificationPermission { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    connectionTitle(
                        language.text("飞书", "Feishu"), symbol: "paperplane", status: feishuStatus,
                        ready: store.feishuNotificationsEnabled && store.feishuWebhookConfigured)
                    Text(
                        language.text(
                            "接收低额度、额度重置和 Reset 卡提醒。先在飞书群添加自定义机器人，再保存机器人地址。",
                            "Receive low-limit, reset and new-credit alerts. Add a custom bot to a Feishu group, then save its webhook.")
                    )
                    .font(.subheadline).foregroundStyle(.secondary)
                    if store.feishuNeedsAuthorization {
                        Button(language.text("授权连接", "Authorize connection"), action: store.authorizeFeishuConnection)
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isUpdatingFeishuConnection)
                    } else if !store.feishuWebhookConfigured {
                        SecureField(language.text("飞书机器人 Webhook 地址", "Feishu bot webhook URL"), text: $webhookDraft)
                            .textFieldStyle(.roundedBorder)
                        Button(language.text("保存并连接", "Save and connect")) {
                            let submitted = webhookDraft
                            store.saveFeishuWebhook(submitted) { saved in
                                if saved, webhookDraft == submitted { webhookDraft = "" }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isUpdatingFeishuConnection)
                    }
                    if store.isUpdatingFeishuConnection { ProgressView().controlSize(.small) }
                    Text(
                        language.text(
                            "密码只在 macOS 系统弹窗中输入。如有“始终允许”，选择后可记住授权；升级后可能需重新授权。后台检查不会弹窗。",
                            "Enter your password only in the macOS dialog. Choose Always Allow, if offered, to remember access. Updates may require authorization again. Background checks stay silent."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if let message = store.feishuNotificationMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(language.text("更多飞书设置", "More Feishu settings"), action: openAutomation)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    private var readyPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                language.text("查看设置，开始使用", "Review your setup"),
                language.text("登录是否完成以工具清单中的结果为准；未完成的工具和通知设置可以继续补齐。", "Check the tool checklist for sign-in results. Finish any pending tools or notification setup when ready."))
            Button(language.text("查看登录清单", "Review sign-in checklist")) { go(to: .accounts) }
            VStack(alignment: .leading, spacing: 16) {
                connectionTitle(
                    language.text("日常功能", "Daily features"), symbol: "switch.2",
                    status: language.text("\(store.enabledSetupFeatureCount) / 7 已开启", "\(store.enabledSetupFeatureCount) / 7 enabled"), ready: store.enabledSetupFeatureCount == 7)
                Divider()
                connectionTitle(
                    language.text("系统通知", "System notifications"), symbol: "bell", status: localStatus,
                    ready: store.localNotificationsEnabled && store.localNotificationAuthorizationReady)
                Divider()
                connectionTitle(
                    language.text("飞书通知", "Feishu notifications"), symbol: "paperplane", status: feishuStatus,
                    ready: store.feishuNotificationsEnabled && store.feishuWebhookConfigured)
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            instruction(
                "→", title: language.text("从一次新任务开始", "Start with your next task"),
                detail: language.text(
                    "回到工作台，确认独立账号已登录、额度为新鲜读取且当前空闲。配套调度先生成 plan，启动后仍需批准；中断时沿用原任务查看 status/result。",
                    "Return to the workspace and confirm the isolated account is signed in, limits are fresh, and it is idle. Companion dispatch starts with a plan and still requires approval; after interruption, use the original task for status/result."
                ))
            Text(language.text("“使用引导”入口一直保留；自动化中心可以随时调整全部开关。", "Getting started stays available. Adjust feature switches anytime in Automation."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var localStatus: String {
        if store.pausedAutomationFeatures.contains(.localNotification) { return language.text("维护暂停", "Paused") }
        if !store.localNotificationsEnabled { return language.text("已关闭", "Off") }
        return store.localNotificationAuthorizationReady ? language.text("已就绪", "Ready") : language.text("待系统授权", "Permission needed")
    }

    private var feishuStatus: String {
        if store.isUpdatingFeishuConnection { return language.text("正在连接", "Connecting") }
        if store.pausedAutomationFeatures.contains(.feishu) { return language.text("维护暂停", "Paused") }
        if !store.feishuNotificationsEnabled { return language.text("已关闭", "Off") }
        if store.feishuNeedsAuthorization { return language.text("待系统授权", "Permission needed") }
        return store.feishuWebhookConfigured ? language.text("已连接", "Connected") : language.text("待配置", "Setup needed")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(language.text("以后再说", "Not now")) {
                if store.isLoggingIn, store.deviceLogin?.phase.canCancelAuthorization == true {
                    store.cancelLogin()
                }
                store.migrateDeviceLoginHostIfNeeded(from: .setupGuide)
                settings.setupProgress.dismissed = true
                if settings.onboarding.shouldPresent { settings.onboarding.skip() }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(store.isLoggingIn && store.deviceLogin?.phase.canCancelAuthorization == false)
            Spacer()
            if step != NextSetupStep.allCases.first {
                Button(language.text("上一步", "Back")) { go(to: step.previous) }
            }
            Button(step == .ready ? language.text("开始使用", "Open workspace") : language.text("下一步", "Continue")) {
                if step == .ready {
                    settings.setupProgress.completed = true
                    settings.onboarding.finish(.completed)
                    dismiss()
                } else {
                    go(to: step.next)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func go(to step: NextSetupStep) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { settings.setupProgress.step = step }
        if step == .notifications { store.refreshLocalNotificationAuthorization() }
        if step == .runtime { runtime.refresh() }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 23, weight: .semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                .frame(width: 27, height: 27)
                .background(Color.accentColor.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func feature(_ title: String, symbol: String, value: Bool, paused: PausedAutomationFeature, action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.subheadline)
            Spacer(minLength: 12)
            Toggle(title, isOn: Binding(get: { value }, set: action))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 9)
        .disabled(store.pausedAutomationFeatures.contains(paused))
    }

    private func connectionTitle(_ title: String, symbol: String, status: String, ready: Bool) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(status).font(.caption.weight(.medium)).foregroundStyle(ready ? Color.green : Color.secondary)
        }
    }
}
