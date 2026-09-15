import SwiftUI

struct CodexDeviceLoginSheet: ViewModifier {
    @ObservedObject var store: UsageStore
    let language: WidgetLanguage

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { store.deviceLogin != nil }, set: { if !$0 { store.dismissDeviceLogin() } })) {
            if let presentation = store.deviceLogin {
                CodexDeviceLoginView(
                    presentation: presentation, language: language, isBusy: store.isLoggingIn,
                    copy: store.copyDeviceCode, reopen: store.reopenDeviceAuthPage, copyURL: store.copyDeviceAuthURL,
                    retry: store.regenerateDeviceCode, verify: store.retryDeviceLoginVerification,
                    cancel: store.cancelLogin, close: store.dismissDeviceLogin
                )
                .frame(width: 520, height: 660)
                .interactiveDismissDisabled(store.isLoggingIn)
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                            Text(language.text("正在授权：", "Account: ") + presentation.targetName)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    phaseContent(now: context.date)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var title: String {
        switch presentation.phase {
        case .preparing: return language.text("正在准备登录", "Preparing sign-in")
        case .waiting: return language.text("请在 Chrome 完成授权", "Authorize in Chrome")
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
        case .preparing:
            progress(language.text("正在确认该账号没有运行中的任务，并生成授权代码…", "Checking that this account has no running tasks, then generating a code…"))
            cancelButton
        case .waiting(let authorization, let browser):
            if authorization.isValid(at: now) {
                waiting(authorization, browser: browser, now: now)
            } else {
                Text(language.text("旧代码已失效。正在结束本次授权，随后可以生成新代码。", "The old code has expired. Finishing this authorization before a new code can be generated."))
                Button(language.text("重新生成新代码", "Generate a new code"), action: retry)
                    .buttonStyle(.borderedProminent).disabled(isBusy)
                cancelButton
            }
        case .cancelling:
            progress(language.text("正在清理本次授权，请稍等…", "Finishing this authorization. Please wait…"))
        case .verifying:
            progress(language.text("正在确认账号身份和额度，请不要关闭 AiGoodBro。", "Checking account identity and limits. Please keep AiGoodBro open."))
        case .completed:
            Text(language.text("已确认是「\(presentation.targetName)」，额度读取正常。", "Confirmed “\(presentation.targetName)”. Limits were read successfully."))
            Button(language.text("完成", "Done"), action: close).buttonStyle(.borderedProminent).disabled(isBusy)
        case .quotaPending:
            Text(language.text("额度暂未读到。点击“继续等待”会重新读取额度，无需重复网页授权。", "Limits are not yet available. Continue waiting to check again; web authorization is already complete."))
            Button(language.text("继续等待", "Continue waiting"), action: verify).buttonStyle(.borderedProminent).disabled(isBusy)
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
            if failure == .verification || failure == .save {
                Button(language.text("重新验证", "Verify again"), action: verify).buttonStyle(.borderedProminent).disabled(isBusy)
            } else {
                retryButton
            }
            closeButton
        }
    }

    private func waiting(_ authorization: CodexDeviceAuthorization, browser: CodexDeviceBrowserState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                step(1, language.text("看一下 Chrome 右上角，确认登录的是这个账号", "Check the account in the top-right corner of Chrome"))
                step(2, language.text("点击“复制授权代码”", "Click “Copy authorization code”"))
                step(3, language.text("回到 Chrome，在输入框粘贴代码", "Return to Chrome and paste the code into the input box"))
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

            if browser == .unavailable {
                Text(
                    language.text(
                        "未能自动打开 Chrome。你也可以复制官方网址，在浏览器打开后输入代码。", "Chrome could not open automatically. You can copy the official URL, open it in a browser, and enter the code.")
                )
                .font(.callout).foregroundStyle(.secondary)
                Button(language.text("打开 Chrome", "Open Chrome"), action: reopen).buttonStyle(.borderedProminent)
                copyButton(now: now).buttonStyle(.bordered)
                Text(authorization.url.absoluteString).font(.caption).textSelection(.enabled)
                Button(language.text("复制官方网址", "Copy official URL"), action: copyURL).buttonStyle(.bordered)
            } else {
                copyButton(now: now).buttonStyle(.borderedProminent)
                Button(language.text("重新打开 Chrome", "Reopen Chrome"), action: reopen).buttonStyle(.bordered).disabled(browser == .opening)
            }
            Text(language.text("完成网页操作后不用再点其他按钮，AiGoodBro 会自动继续。", "After completing the web page, AiGoodBro continues automatically."))
                .font(.caption).foregroundStyle(.secondary)
            cancelButton
        }
    }

    private func copyButton(now: Date) -> some View {
        Button(action: copy) {
            Text(
                (presentation.copiedUntil ?? .distantPast) > now
                    ? language.text("已复制，可以去 Chrome 粘贴了", "Copied. Paste it in Chrome")
                    : language.text("复制授权代码", "Copy authorization code")
            )
            .fixedSize(horizontal: false, vertical: true)
        }
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

    private var cancelButton: some View { Button(language.text("取消登录", "Cancel sign-in"), action: cancel).buttonStyle(.bordered) }
    private var closeButton: some View { Button(language.text("关闭", "Close"), action: close).buttonStyle(.bordered).disabled(isBusy) }
    private var retryButton: some View { Button(language.text("重新生成新代码", "Generate a new code"), action: retry).buttonStyle(.borderedProminent).disabled(isBusy) }
}
