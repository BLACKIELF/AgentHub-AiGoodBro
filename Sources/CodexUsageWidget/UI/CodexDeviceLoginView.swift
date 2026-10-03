import SwiftUI

private struct CodexDeviceLoginHostKey: EnvironmentKey {
    static let defaultValue = CodexDeviceLoginHost.workbench
}

extension EnvironmentValues {
    var codexDeviceLoginHost: CodexDeviceLoginHost {
        get { self[CodexDeviceLoginHostKey.self] }
        set { self[CodexDeviceLoginHostKey.self] = newValue }
    }
}

struct CodexDeviceLoginSheet: ViewModifier {
    @ObservedObject var store: UsageStore
    let language: WidgetLanguage
    var host: CodexDeviceLoginHost = .workbench
    var isEnabled: Bool = true

    func body(content: Content) -> some View {
        content
            .onChange(of: isEnabled) { enabled in
                if !enabled { store.migrateDeviceLoginHostIfNeeded(from: host) }
            }
            .sheet(
                isPresented: Binding(
                    get: { isEnabled && store.deviceLogin != nil && store.deviceLoginHost == host },
                    set: { if !$0 { store.handleDeviceLoginSheetDismiss(from: host) } }
                )
            ) {
                if let presentation = store.deviceLogin {
                    CodexDeviceLoginView(
                        presentation: presentation, language: language, isBusy: store.isLoggingIn,
                        copy: store.copyDeviceCode, reopen: store.reopenDeviceAuthPage, copyURL: store.copyDeviceAuthURL,
                        retry: store.regenerateDeviceCode, verify: store.retryDeviceLoginVerification,
                        cancel: store.cancelLogin, close: store.dismissDeviceLogin,
                        chooseBrowser: store.confirmDeviceBrowserChoice,
                        revealExisting: store.revealDeviceLoginExistingAccount
                    )
                    .frame(minWidth: 420, idealWidth: 520, maxWidth: 560, minHeight: 520, idealHeight: 660, maxHeight: 760)
                    .interactiveDismissDisabled(store.isLoggingIn || store.deviceLogin?.phase.canDismiss == false)
                }
            }
    }
}

/// This is the production panel. Preview callers supply synthetic state and inert actions.
struct CodexDeviceLoginView: View {
    let presentation: CodexDeviceLoginPresentation
    let language: WidgetLanguage
    let isBusy: Bool
    var copy: () -> Void = {}
    var reopen: () -> Void = {}
    var copyURL: () -> Void = {}
    var retry: () -> Void = {}
    var verify: () -> Void = {}
    var cancel: () -> Void = {}
    var close: () -> Void = {}
    var chooseBrowser: (CodexDeviceBrowserChoice) -> Void = { _ in }
    var revealExisting: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                            Text(identityCaption)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    if let notice = presentation.notice, !notice.isEmpty {
                        Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    phaseContent(now: context.date)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var identityCaption: String {
        CodexDeviceLoginIdentityCaption.text(language) + presentation.targetName
    }

    private var title: String {
        switch presentation.phase {
        case .choosingBrowser: return language.text("选择这次登录使用的浏览器", "Choose a browser for this sign-in")
        case .preparing: return language.text("正在准备登录", "Preparing sign-in")
        case .waiting: return language.text("请在浏览器完成授权", "Authorize in the browser")
        case .cancelling: return language.text("正在结束本次授权", "Ending this authorization")
        case .verifying: return language.text("正在验证登录结果", "Verifying sign-in")
        case .completed: return language.text("登录完成", "Sign-in complete")
        case .quotaPending: return language.text("账号身份已确认", "Account identity confirmed")
        case .expired: return language.text("授权代码已过期", "Authorization code expired")
        case .cancelled: return language.text("登录已取消", "Sign-in cancelled")
        case .failed: return language.text("登录还未完成", "Sign-in is incomplete")
        }
    }

    private var symbol: String {
        switch presentation.phase {
        case .completed: return "checkmark.circle.fill"
        case .failed, .expired: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        default: return "person.badge.key"
        }
    }

    @ViewBuilder private func phaseContent(now: Date) -> some View {
        switch presentation.phase {
        case .choosingBrowser:
            Text(language.text("先选择浏览器，再开始官方设备代码授权。网页打开不等于登录成功。", "Choose a browser before starting official device authorization. Opening a page is not a successful sign-in."))
                .fixedSize(horizontal: false, vertical: true)
            panelButton(language.text("账号专属 Chrome（推荐）", "Dedicated Chrome (recommended)"), prominent: true) {
                chooseBrowser(.dedicatedChrome)
            }
            .accessibilityHint(language.text("使用这个账号的隔离 Chrome 目录", "Uses this account’s isolated Chrome directory"))
            panelButton(language.text("系统默认浏览器", "System default browser")) {
                chooseBrowser(.systemDefault)
            }
            .accessibilityHint(language.text("用系统默认浏览器打开官方网址", "Opens the official URL in the system default browser"))
            closeButton
        case .preparing:
            progress(language.text("正在确认该账号没有运行中的任务，并生成授权代码…", "Checking that this account has no running tasks, then generating a code…"))
            cancelButton
        case .waiting(let authorization, let browser):
            if authorization.isValid(at: now) {
                waiting(authorization, browser: browser, now: now)
            } else {
                Text(language.text("旧代码已失效。正在结束本次授权，随后可以生成新代码。", "The old code has expired. Finishing this authorization before a new code can be generated."))
                retryButton
                cancelButton
            }
        case .cancelling:
            progress(language.text("正在清理本次授权，请稍等…", "Finishing this authorization. Please wait…"))
        case .verifying:
            progress(language.text("正在确认账号身份和额度，请不要关闭 AiGoodBro。", "Checking account identity and limits. Please keep AiGoodBro open."))
        case .completed:
            Text(language.text("已确认是「\(presentation.targetName)」，额度读取正常。", "Confirmed “\(presentation.targetName)”. Limits were read successfully."))
            panelButton(language.text("完成", "Done"), prominent: true, action: close).disabled(isBusy)
        case .quotaPending:
            Text(language.text("额度暂未读到。点击“继续等待”会重新读取额度，无需重复网页授权。", "Limits are not yet available. Continue waiting to check again; web authorization is already complete."))
            panelButton(language.text("继续等待", "Continue waiting"), prominent: true, action: verify).disabled(isBusy)
            closeButton
        case .expired:
            Text(language.text("原账号没有变化。请生成新代码，再按步骤完成授权。", "The original account is unchanged. Generate a new code and follow the steps again."))
            retryButton
            closeButton
        case .cancelled:
            Text(language.text("原账号没有变化。", "The original account is unchanged."))
            closeButton
        case .failed(let failure):
            Text(failure.message(language)).fixedSize(horizontal: false, vertical: true)
            if failure == .accountAlreadyExists {
                panelButton(language.text("查看已有账号", "View existing account"), prominent: true, action: revealExisting)
                    .disabled(presentation.existingProfileID == nil)
            } else if failure == .verification {
                panelButton(language.text("重新验证", "Verify again"), prominent: true, action: verify).disabled(isBusy)
            } else if failure == .save {
                if presentation.profileID.isEmpty {
                    retryButton
                } else {
                    panelButton(language.text("重新验证", "Verify again"), prominent: true, action: verify).disabled(isBusy)
                }
            } else if failure == .cliUnavailable || failure == .mappingUnconfirmed || failure == .systemProfile {
                EmptyView()
            } else {
                retryButton
            }
            closeButton
        }
    }

    private func waiting(_ authorization: CodexDeviceAuthorization, browser: CodexDeviceBrowserState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(browserStatusText(browser)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                step(1, language.text("确认浏览器里登录的是这个账号", "Confirm the browser is signed in to this account"))
                step(2, language.text("点击“复制授权代码”", "Click “Copy authorization code”"))
                step(3, language.text("回到浏览器，在输入框粘贴代码", "Return to the browser and paste the code into the input box"))
                step(4, language.text("点击网页上的“继续”", "Click “Continue” on the web page"))
                step(5, language.text("回到 AiGoodBro，等待自动验证", "Return to AiGoodBro and wait for automatic verification"))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(language.text("授权代码", "Authorization code")).font(.caption).foregroundStyle(.secondary)
                Text(authorization.code)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .minimumScaleFactor(0.55).lineLimit(1).textSelection(.enabled)
                    .accessibilityLabel(language.text("授权代码：", "Authorization code: ") + authorization.code.map(String.init).joined(separator: " "))
                let remaining = max(0, Int(authorization.expiresAt.timeIntervalSince(now)))
                Text(language.text("代码将在 ", "Code expires in ") + String(format: "%02d:%02d", remaining / 60, remaining % 60) + language.text(" 后失效", ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

            if let feedback = presentation.copyFeedback, (presentation.copyFeedbackUntil ?? .distantPast) > now {
                Text(feedback.message(language)).font(.callout).foregroundStyle(feedback == .failed ? Color.orange : Color.secondary)
            }

            HStack(spacing: 10) {
                copyButton(now: now)
                panelButton(
                    browser == .opening
                        ? language.text("正在请求打开…", "Requesting open…")
                        : language.text("重新打开网页", "Reopen page"),
                    prominent: false, action: reopen
                )
                .disabled(browser == .opening)
                .accessibilityLabel(language.text("重新打开官方授权网页", "Reopen the official authorization page"))
            }
            Text(authorization.url.absoluteString).font(.caption).textSelection(.enabled)
            panelButton(language.text("复制官方网址", "Copy official URL"), action: copyURL)
            Text(
                language.text(
                    "完成网页操作后不用再点其他按钮，AiGoodBro 会自动继续。打开网页还不等于授权完成。",
                    "After completing the web page, AiGoodBro continues automatically. Opening the page is not a completed authorization.")
            )
            .font(.caption).foregroundStyle(.secondary)
            cancelButton
        }
    }

    private func browserStatusText(_ browser: CodexDeviceBrowserState) -> String {
        switch browser {
        case .opening:
            return language.text("正在请求打开浏览器…", "Requesting to open the browser…")
        case .opened:
            return language.text(
                "已请求打开浏览器。若页面没有出现，请复制官方网址后手动打开。", "A request to open the browser was sent. If the page does not appear, copy the official URL and open it yourself.")
        case .unavailable:
            return language.text("未能自动打开浏览器。请复制官方网址，在浏览器打开后输入代码。", "The browser could not be opened automatically. Copy the official URL, open it, and enter the code.")
        }
    }

    private func copyButton(now: Date) -> some View {
        let copied = presentation.copyFeedback == .codeCopied && (presentation.copyFeedbackUntil ?? .distantPast) > now
        return panelButton(
            copied
                ? language.text("已复制授权代码", "Authorization code copied")
                : language.text("复制授权代码", "Copy authorization code"),
            prominent: true, action: copy
        )
        .keyboardShortcut("c", modifiers: [.command, .shift])
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(number)).font(.caption.bold()).frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.13), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func progress(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView().controlSize(.small)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cancelButton: some View {
        panelButton(language.text("取消登录", "Cancel sign-in"), action: cancel)
            .keyboardShortcut(.cancelAction)
    }

    private var closeButton: some View {
        panelButton(language.text("关闭", "Close"), action: close).disabled(isBusy)
    }

    private var retryButton: some View {
        panelButton(language.text("重新生成新代码", "Generate a new code"), prominent: true, action: retry).disabled(isBusy)
    }

    @ViewBuilder
    private func panelButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        let label = Text(title)
            .frame(minWidth: 132, minHeight: 28)
            .fixedSize(horizontal: false, vertical: true)
        if prominent {
            Button(action: action) { label }.buttonStyle(.borderedProminent).controlSize(.regular)
        } else {
            Button(action: action) { label }.buttonStyle(.bordered).controlSize(.regular)
        }
    }
}
