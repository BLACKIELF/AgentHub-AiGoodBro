import AppKit
import SwiftUI

extension AntigravityProxyProvider {
    static func local(_ kind: LocalCLIKind) -> Self? {
        switch kind {
        case .antigravity: .antigravity
        case .claudeCode: .claude
        case .kimi: .kimi
        case .grok: .xai
        default: nil
        }
    }
    var title: String {
        switch self {
        case .antigravity: "Antigravity"
        case .claude: "Claude"
        case .kimi: "Kimi"
        case .xai: "Grok"
        }
    }
}

/// All supported providers share the same controls; availability comes from
/// the running helper, never from quota-only local account detection.
struct ProviderAccountPoolView: View {
    @ObservedObject var pool: AntigravityProxyStore
    @ObservedObject var settings: AppSettings
    let provider: AntigravityProxyProvider
    let isPreview: Bool
    @Binding var addingAccount: Bool
    @Environment(\.accountCardDensity) private var density
    @State private var detail: AntigravityProxyAccount?
    @State private var removing: AntigravityProxyAccount?
    @State private var confirmingStop = false
    @State private var localIssue: String?
    private var language: WidgetLanguage { settings.language }
    private var accounts: [AntigravityProxyAccount] { isPreview ? [] : pool.accounts.filter { $0.provider == provider } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(language.text("网页授权账号池", "Authorized account pool"), systemImage: "person.2")
                    .font(.headline)
                Spacer()
                if pool.phase == .running {
                    Button {
                        pool.refreshStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(language.text("刷新账号池", "Refresh pool"))
                    Button(language.text("停止反代", "Stop proxy")) { confirmingStop = true }
                } else {
                    Button(language.text("开启反代", "Start proxy")) { Task { await start() } }
                        .disabled(!pool.canStart)
                }
            }
            if let endpoint = pool.endpoint(for: provider), pool.phase == .running {
                HStack {
                    Text(endpoint.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button(language.text("复制连接配置", "Copy connection config")) { copyConnection(endpoint) }
                    Menu(language.text("接入 Codex CLI", "Connect Codex CLI")) {
                        ForEach(pool.models(for: provider), id: \.self) { model in
                            Button(model) { launchCodex(model: model) }
                        }
                    }.disabled(pool.models(for: provider).isEmpty)
                    if provider != .antigravity {
                        Menu(language.text("接入 \(provider.title) CLI", "Connect \(provider.title) CLI")) {
                            ForEach(pool.models(for: provider), id: \.self) { model in
                                Button(model) { launchCodex(model: model, native: true) }
                            }
                        }.disabled(pool.models(for: provider).isEmpty)
                    }
                    if provider == .antigravity {
                        Button(language.text("接入 agy CLI", "Connect agy CLI")) { launchAgy() }
                            .disabled(accounts.filter { $0.enabled && $0.state == .ready }.isEmpty)
                    }
                }
            }
            if accounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        language.text(
                            "添加账号后，通过官方网页完成授权。每个账号独立保存，可分别参与反代。",
                            "Add an account and authorize on the official website. Each account is saved separately and can join the proxy pool.")
                    )
                    .foregroundStyle(.secondary)
                    Button(language.text("添加 \(provider.title) 账号", "Add \(provider.title) account")) { addingAccount = true }
                        .buttonStyle(.borderedProminent)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(WorkspaceGlassSurface(cornerRadius: 16))
            } else if settings.accountWorkspaceLayout == .cards {
                AccountCardGridLayout(minimumWidth: density.minimumWidth) {
                    ForEach(accounts) { accountCard($0) }
                }
            } else {
                ForEach(accounts) { accountCard($0) }
            }
            if provider == .antigravity {
                Text(
                    language.text(
                        "客户端接入目前支持 agy CLI；反重力桌面版的自定义入口尚未验证。", "Client integration currently supports agy CLI; the Antigravity desktop custom endpoint is not yet verified.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = localIssue ?? pool.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }
        .disabled(isPreview)
        .sheet(isPresented: $addingAccount) { authorizationSheet }
        .sheet(item: $detail) { account in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(account.maskedIdentity).font(.headline)
                    Spacer()
                    Button(language.text("关闭", "Close")) { detail = nil }
                }
                Text(stateTitle(account.state))
                Text(language.text("并发 \(account.inFlight)/\(account.concurrencyLimit)", "Concurrency \(account.inFlight)/\(account.concurrencyLimit)"))
                if let until = account.cooldownUntil { Text(until, style: .relative) }
                Text(language.text("模型目录", "Model catalog")).font(.headline)
                if account.models.isEmpty { Text(language.text("尚未确认模型目录", "Model catalog not confirmed")) }
                ScrollView { Text(account.models.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 300)
            }.padding(24).frame(width: 480)
        }
        .alert(language.text("移除这个授权账号？", "Remove this authorized account?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(language.text("取消", "Cancel"), role: .cancel) { removing = nil }
            Button(language.text("移除", "Remove"), role: .destructive) {
                if let account = removing { pool.removeAccount(account.id) }
                removing = nil
            }
        } message: {
            Text(language.text("将停止此账号的新请求，并移除 AiGoodBro 保存的授权。", "Stop new requests for this account and remove its saved AiGoodBro authorization."))
        }
        .alert(language.text("停止多平台反代？", "Stop the provider proxy?"), isPresented: $confirmingStop) {
            Button(language.text("取消", "Cancel"), role: .cancel) {}
            Button(language.text("停止", "Stop"), role: .destructive) { pool.stop() }
        } message: {
            Text(language.text("已接入此服务的客户端会断开，正在执行的任务可能中断。", "Connected clients will disconnect and active tasks may be interrupted."))
        }
    }

    private func accountCard(_ account: AntigravityProxyAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.crop.circle").font(.title2)
                Text(account.maskedIdentity).font(.headline).lineLimit(1).help(account.maskedIdentity)
                Spacer()
                Button {
                    detail = account
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(language.text("账号详情", "Account details"))
                Menu {
                    Button(language.text("移除账号", "Remove account"), role: .destructive) { removing = account }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).frame(width: 24)
            }
            HStack {
                Label(
                    pool.phase == .running ? stateTitle(account.state) : language.text("反代未开启", "Proxy stopped"),
                    systemImage: account.state == .ready && pool.phase == .running ? "checkmark.circle" : "circle.dotted"
                )
                .foregroundStyle(account.state == .ready && pool.phase == .running ? Color.green : Color.secondary)
                Spacer()
                Toggle(language.text("参与反代", "Use in proxy"), isOn: Binding(get: { account.enabled }, set: { pool.setEnabled(account.id, enabled: $0) }))
                    .toggleStyle(.switch).controlSize(.small)
            }.font(.caption)
            Text(
                language.text(
                    "已确认模型 \(account.models.count) · 并发 \(account.inFlight)/\(account.concurrencyLimit)",
                    "Confirmed models \(account.models.count) · Concurrency \(account.inFlight)/\(account.concurrencyLimit)")
            )
            .font(.caption).foregroundStyle(.secondary)
        }.padding(density == .compact ? 12 : 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceGlassSurface(cornerRadius: 16))
    }

    private var authorizationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("添加 \(provider.title) 账号", "Add \(provider.title) account")).font(.headline)
            Text(
                language.text(
                    "1. 打开官方授权页面\n2. 选择账号并授权\n3. 返回后自动保存到钥匙串，加入账号池",
                    "1. Open the official authorization page\n2. Select an account and authorize\n3. Return to save in Keychain and join the pool")
            )
            .font(.callout)
            if let code = pool.authorizationUserCode {
                Text(language.text("授权码：\(code)", "Authorization code: \(code)"))
                    .font(.title3.monospaced()).textSelection(.enabled)
            }
            if pool.signInPending { ProgressView(language.text("等待网页授权…", "Waiting for authorization…")) }
            if let issue = localIssue ?? pool.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(language.text("取消", "Cancel")) {
                    pool.cancelSignIn()
                    addingAccount = false
                }
                Spacer()
                Button(language.text("打开网页授权", "Authorize in browser")) {
                    Task {
                        await start()
                        if pool.phase == .running { await pool.addAccount(provider: provider) }
                    }
                }.buttonStyle(.borderedProminent).disabled(pool.signInPending || pool.phase == .starting)
            }
        }.padding(24).frame(width: 440)
            .onDisappear { if pool.signInPending { pool.cancelSignIn() } }
            .onChange(of: pool.signInPending) { pending in if !pending && pool.issue == nil && !accounts.isEmpty { addingAccount = false } }
    }

    private func start() async {
        guard !isPreview else { return }
        localIssue = nil
        if pool.phase == .running { return }
        do { await pool.start(networkProxy: try LocalProxyNetworkSettings.load() ?? "") } catch {
            localIssue = language.text("系统代理不可用，请检查网络设置后重试。", "System proxy unavailable. Check network settings and retry.")
        }
    }

    private func copyConnection(_ endpoint: URL) {
        guard let key = pool.clientKey else { return }
        let value =
            provider == .antigravity
            ? "GOOGLE_GEMINI_BASE_URL=\(endpoint.absoluteString)\nGEMINI_API_KEY=\(key)"
            : "OPENAI_BASE_URL=\(endpoint.absoluteString)/v1\nOPENAI_API_KEY=\(key)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func launchAgy() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = language.text("打开 CLI", "Open CLI")
        guard picker.runModal() == .OK, let directory = picker.url else { return }
        Task {
            do { try await ProviderProxyClientLauncher.launchAgy(workingDirectory: directory) } catch {
                localIssue = language.text("未能启动 agy CLI，请确认已安装官方 CLI 且反代可用。", "Could not start agy CLI. Check its installation and proxy availability.")
            }
        }
    }

    private func launchCodex(model: String, native: Bool = false) {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = language.text("打开 CLI", "Open CLI")
        guard picker.runModal() == .OK, let directory = picker.url else { return }
        Task {
            do {
                if native {
                    try await ProviderProxyClientLauncher.launchNative(provider: provider, model: model, workingDirectory: directory)
                } else {
                    try await ProviderProxyClientLauncher.launchCodex(provider: provider, model: model, workingDirectory: directory)
                }
            } catch { localIssue = language.text("未能启动 CLI，请确认安装与账号池状态。", "Could not start CLI. Check its installation and the account pool.") }
        }
    }

    private func stateTitle(_ state: AntigravityProxyAccountState) -> String {
        switch state {
        case .checking: language.text("待核验", "Checking")
        case .ready: language.text("可用", "Ready")
        case .busy: language.text("使用中", "In use")
        case .cooling: language.text("冷却中", "Cooling down")
        case .disabled: language.text("未参与", "Disabled")
        case .reauthRequired: language.text("需要重新授权", "Sign-in required")
        }
    }
}
