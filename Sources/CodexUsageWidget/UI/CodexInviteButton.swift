import SwiftUI

@MainActor
final class CodexInviteController: ObservableObject {
    @Published var email = ""
    @Published private(set) var review: CodexReferralReview?
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var notice: String?
    @Published private(set) var uncertainEmail: String?
    @Published private(set) var batchResult: CodexReferralBatchResult?
    @Published private(set) var records: [CodexReferralRecord] = []
    @Published private(set) var historyLoaded = false
    @Published private(set) var isHistoryLoading = false
    @Published private(set) var historyNotice: String?
    @Published private(set) var historyCursor: String?
    @Published private(set) var historyPeriod: CodexReferralPeriod = .past90Days
    @Published private(set) var isConfirming = false
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = UUID()
    private var seenCursors = Set<String>()
    private var unresolvedEmails: [String] = []
    private var boundAccount: CodexReferralAccount?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var confirmationTask: Task<Void, Never>?
    private var confirmationGeneration = UUID()
    private let previewOnly: Bool
    private let client: CodexReferralClient

    init(
        previewReview: CodexReferralReview? = nil, previewRecords: [CodexReferralRecord]? = nil, previewBatch: CodexReferralBatchResult? = nil, previewConfirming: Bool = false,
        client: CodexReferralClient = CodexReferralClient()
    ) {
        previewOnly = previewReview != nil
        review = previewReview
        records = previewRecords ?? []
        historyLoaded = previewRecords != nil
        batchResult = previewBatch
        isConfirming = previewOnly && previewConfirming
        self.client = client
    }

    var isBusy: Bool { isLoading || isSending || isConfirming }
    var allowsSending: Bool { !previewOnly }

    func load(account: CodexReferralAccount, resolve: @escaping () throws -> CodexReferralAccount, language: WidgetLanguage) {
        guard !previewOnly, !isBusy else { return }
        if boundAccount?.matches(account) != true {
            email = ""
            uncertainEmail = nil
            notice = nil
            batchResult = nil
            unresolvedEmails = []
            records = []
            historyLoaded = false
            historyCursor = nil
            historyNotice = nil
            seenCursors = []
            historyTask?.cancel()
            historyGeneration = UUID()
            isHistoryLoading = false
            review = nil
        }
        boundAccount = account
        isLoading = true
        let generation = UUID()
        loadGeneration = generation
        loadTask = Task {
            defer { if loadGeneration == generation { isLoading = false } }
            do {
                guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                let result = try await client.load(account, language: language)
                guard !Task.isCancelled, loadGeneration == generation else { return }
                guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                review = result
                if uncertainEmail == nil { notice = nil }
            } catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                if error as? CodexReferralFailure == .identityChanged {
                    review = nil
                    records = []
                    historyLoaded = false
                    historyCursor = nil
                }
                notice = (error as? CodexReferralFailure ?? .network).message(language)
            }
        }
    }

    func send(account: CodexReferralAccount, resolve: @escaping () throws -> CodexReferralAccount, consent: Bool, language: WidgetLanguage) {
        let recipients = CodexReferralRecipients.parse(email)
        guard !previewOnly, !isBusy, uncertainEmail == nil, let review,
            recipients.canSend(capacity: review.eligibility.invitationCapacity)
        else { return }
        isSending = true
        notice = nil
        batchResult = nil
        Task {
            var refreshOffer = false
            defer {
                isSending = false
                if refreshOffer { load(account: account, resolve: resolve, language: language) }
            }
            do {
                guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                let result = try await client.sendBatch(
                    account, reviewed: review, emails: recipients.emails, consent: consent, language: language, currentAccount: resolve)
                batchResult = result
                unresolvedEmails = result.uncertain
                uncertainEmail = result.uncertain.first
                email = (result.failed + result.uncertain).joined(separator: "\n")
                historyLoaded = false
                notice = language.text("邀请结果已返回。奖励需好友完成官方条件后发放。", "Invitation results received. Rewards require the official qualifying actions.")
                refreshOffer = true
                // Read-only refresh; never replay a sent or uncertain batch.
                loadHistory(account: account, resolve: resolve, period: .past90Days, language: language)
            } catch {
                let failure = error as? CodexReferralFailure ?? .network
                if failure == .deliveryUncertain {
                    unresolvedEmails = recipients.emails
                    uncertainEmail = recipients.emails.first
                    batchResult = CodexReferralBatchResult(sent: [], failed: [], uncertain: recipients.emails)
                }
                // Retain the last verified offer while showing a read/preflight
                // error. Every send still reloads and verifies the current offer.
                notice = failure.message(language)
            }
        }
    }

    func checkRecord(account: CodexReferralAccount, resolve: @escaping () throws -> CodexReferralAccount, language: WidgetLanguage) {
        guard !previewOnly, !isBusy, !unresolvedEmails.isEmpty, let review else { return }
        isConfirming = true
        let generation = UUID()
        confirmationGeneration = generation
        let recipients = unresolvedEmails
        confirmationTask = Task {
            defer { if confirmationGeneration == generation { isConfirming = false } }
            do {
                guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                var remaining: [String] = []
                var confirmed: [String] = []
                for recipient in recipients {
                    let exists = try await client.recorded(account, context: review.context, email: recipient, language: language)
                    guard !Task.isCancelled, confirmationGeneration == generation else { return }
                    guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                    if exists { confirmed.append(recipient) } else { remaining.append(recipient) }
                }
                unresolvedEmails = remaining
                uncertainEmail = remaining.first
                batchResult = CodexReferralBatchResult(
                    sent: (batchResult?.sent ?? []) + confirmed, failed: batchResult?.failed ?? [], uncertain: remaining)
                email = ((batchResult?.failed ?? []) + remaining).joined(separator: "\n")
                notice =
                    remaining.isEmpty
                    ? language.text("官方已记录这些邀请。可在邀请记录中查看接受状态。", "These invitations are recorded. View their acceptance status in invitation history.")
                    : language.text("部分结果仍未确认，请稍后核对；已发送的邀请不会重复发送。", "Some results remain unconfirmed. Check later; sent invitations will not be replayed.")
                loadHistory(account: account, resolve: resolve, period: .past90Days, language: language)
            } catch {
                guard !Task.isCancelled, confirmationGeneration == generation else { return }
                notice = (error as? CodexReferralFailure ?? .network).message(language)
            }
        }
    }

    func loadHistory(
        account: CodexReferralAccount, resolve: @escaping () throws -> CodexReferralAccount,
        period: CodexReferralPeriod, more: Bool = false, language: WidgetLanguage
    ) {
        guard !previewOnly else { return }
        if more && (isHistoryLoading || historyCursor == nil || records.count >= 1000) { return }
        historyTask?.cancel()
        let generation = UUID()
        historyGeneration = generation
        let cursor = more ? historyCursor : nil
        if period != historyPeriod {
            records = []
            historyLoaded = false
            historyCursor = nil
            seenCursors = []
        }
        if !more { seenCursors = [] }
        historyPeriod = period
        historyNotice = nil
        isHistoryLoading = true
        historyTask = Task {
            defer { if historyGeneration == generation { isHistoryLoading = false } }
            do {
                guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                let page = try await client.historyPage(account, context: review?.context, period: period, cursor: cursor, language: language)
                guard !Task.isCancelled, historyGeneration == generation else { return }
                guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                if let next = page.cursor, seenCursors.contains(next) { throw CodexReferralFailure.invalidResponse }
                var byID = Dictionary(uniqueKeysWithValues: (more ? records : []).map { ($0.id, $0) })
                var order = more ? records.map(\.id) : []
                for item in page.items {
                    if byID[item.id] == nil { order.append(item.id) }
                    byID[item.id] = item
                }
                records = order.prefix(1000).compactMap { byID[$0] }
                historyLoaded = true
                historyCursor = records.count < 1000 ? page.cursor : nil
                if let next = page.cursor { seenCursors.insert(next) }
                if records.count >= 1000, page.cursor != nil {
                    historyNotice = language.text("已显示前 1,000 条，可选择本月缩小范围。", "Showing the first 1,000 invitations. Choose this month to narrow the range.")
                }
            } catch {
                guard !Task.isCancelled, historyGeneration == generation else { return }
                if error as? CodexReferralFailure == .identityChanged {
                    records = []
                    historyLoaded = false
                    historyCursor = nil
                }
                historyNotice = (error as? CodexReferralFailure ?? .network).message(language)
            }
        }
    }

    func close() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration = UUID()
        isLoading = false
        historyTask?.cancel()
        historyTask = nil
        historyGeneration = UUID()
        isHistoryLoading = false
        confirmationTask?.cancel()
        confirmationTask = nil
        confirmationGeneration = UUID()
        isConfirming = false
    }
}

struct CodexInviteButton: View {
    let accountLabel: String
    var resolveAccount: (() throws -> CodexReferralAccount)?
    var iconOnly = false
    @Environment(\.widgetLanguage) private var language
    @State private var account: CodexReferralAccount?
    @State private var reviewedAccountLabel = ""
    @State private var beginError: String?
    @StateObject private var controller = CodexInviteController()

    var body: some View {
        Group {
            if iconOnly {
                inviteControl.buttonStyle(WorkspaceQuietButtonStyle())
            } else {
                inviteControl.buttonStyle(WorkspaceActionButtonStyle(compact: true))
            }
        }
    }

    private var inviteControl: some View {
        Button {
            do {
                reviewedAccountLabel = accountLabel
                account = try resolveAccount?()
            } catch { beginError = (error as? CodexReferralFailure ?? .unavailable).message(language) }
        } label: {
            if iconOnly {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 26)
            } else {
                Label(language.text("邀请", "Invite"), systemImage: "person.badge.plus")
                    .lineLimit(1)
            }
        }
        .disabled(resolveAccount == nil)
        .help(language.text("查看此账号的邀请点数并邀请好友", "View this account's referral credits and invite a friend"))
        .accessibilityLabel(language.text("邀请好友：\(accountLabel)", "Invite a friend: \(accountLabel)"))
        .sheet(item: $account, onDismiss: { controller.close() }) { account in
            if let resolveAccount {
                CodexInviteSheet(account: account, accountLabel: reviewedAccountLabel, resolveAccount: resolveAccount, controller: controller)
                    .environment(\.widgetLanguage, language)
            }
        }
        .alert(
            language.text("邀请暂不可用", "Invitations unavailable"),
            isPresented: Binding(
                get: { beginError != nil }, set: { if !$0 { beginError = nil } }
            )
        ) {
            Button(language.text("关闭", "Close"), role: .cancel) { beginError = nil }
        } message: {
            Text(beginError ?? "")
        }
    }
}

struct CodexInviteSheet: View {
    let account: CodexReferralAccount
    let accountLabel: String
    let resolveAccount: () throws -> CodexReferralAccount
    @ObservedObject var controller: CodexInviteController
    @Environment(\.widgetLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var consent = false
    @State private var showingHistory: Bool
    @State private var showingPurchaseInfo = false

    init(
        account: CodexReferralAccount, accountLabel: String, resolveAccount: @escaping () throws -> CodexReferralAccount,
        controller: CodexInviteController, initialHistory: Bool = false
    ) {
        self.account = account
        self.accountLabel = accountLabel
        self.resolveAccount = resolveAccount
        self.controller = controller
        _showingHistory = State(initialValue: initialHistory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(language.text("邀请好友", "Invite friends"), systemImage: "person.badge.plus")
                        .font(.title2.weight(.semibold))
                    Text(accountLabel).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    Link(language.text("购买邀请点数", "Get invite points"), destination: purchaseURL)
                        .font(.callout)
                    Button {
                        showingPurchaseInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .help(language.text("联系客服有惊喜折扣", "Contact support for a special discount"))
                    .accessibilityLabel(language.text("联系客服有惊喜折扣", "Contact support for a special discount"))
                    .popover(isPresented: $showingPurchaseInfo) {
                        Text(language.text("联系客服有惊喜折扣", "Contact support for a special discount"))
                            .font(.callout).padding(16)
                    }
                }
            }
            Picker(language.text("邀请页面", "Invitation page"), selection: $showingHistory) {
                Text(language.text("发送邀请", "Invite friends")).tag(false)
                Text(language.text("邀请记录", "Invitation history")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: showingHistory) { history in
                if history && !controller.historyLoaded {
                    refreshHistory()
                }
            }
            if showingHistory { historyContent } else { invitationContent }
            Divider()
            HStack(spacing: 10) {
                Button(showingHistory ? language.text("刷新记录", "Refresh history") : language.text("刷新邀请信息", "Refresh offer")) {
                    if showingHistory {
                        refreshHistory()
                    } else {
                        consent = false
                        controller.load(account: account, resolve: resolveAccount, language: language)
                    }
                }
                .disabled(controller.isBusy || (showingHistory && controller.isHistoryLoading))
                Spacer()
                Button(language.text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(controller.isSending)
                if !showingHistory {
                    Button {
                        controller.send(account: account, resolve: resolveAccount, consent: consent, language: language)
                    } label: {
                        HStack(spacing: 5) {
                            if controller.isSending { ProgressView().controlSize(.small) }
                            Text(language.text("发送 \(recipients.emails.count) 封邀请", "Send \(recipients.emails.count) invitations"))
                        }
                    }
                    .buttonStyle(WorkspaceActionButtonStyle(prominent: true))
                    .disabled(!canSend).accessibilityIdentifier("codex.invite.send")
                }
            }
        }
        .padding(22).frame(width: 600, height: 660)
        .interactiveDismissDisabled(controller.isSending)
        .onAppear {
            controller.load(account: account, resolve: resolveAccount, language: language)
            if showingHistory && !controller.historyLoaded { refreshHistory() }
        }
        .onChange(of: controller.email) { _ in consent = false }
    }

    private var invitationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if controller.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(language.text("正在更新邀请信息…", "Updating invitation information…"))
                    }.font(.callout).foregroundStyle(.secondary)
                }
                if let review = controller.review {
                    offer(review)
                } else if !controller.isLoading {
                    Text(language.text("邀请信息尚未读取，请刷新重试。", "Invitation information has not loaded. Refresh to try again."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(language.text("好友邮箱", "Friends' email addresses")).font(.callout.weight(.semibold))
                        Spacer()
                        Text(language.text("已识别 \(recipients.emails.count) 个", "\(recipients.emails.count) addresses"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $controller.email)
                        .font(.body).scrollContentBackground(.hidden)
                        .padding(7).frame(height: 86)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.18)) }
                        .disabled(controller.isSending || controller.uncertainEmail != nil)
                        .accessibilityLabel(language.text("好友邮箱，可一次输入多个", "Recipient emails; multiple addresses supported"))
                        .accessibilityIdentifier("codex.invite.email")
                    Text(language.text("每行一个，或用逗号、分号、空格分隔；重复邮箱会自动合并。", "One per line, or separate with commas, semicolons or spaces. Duplicates are merged."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let validation = recipientValidation {
                        Text(validation).font(.caption).foregroundStyle(warningColor)
                    }
                    if controller.review?.eligibility.requiresExplicitConfirmation == true {
                        Toggle(language.text("我已征得以上好友同意发送邀请", "I have consent from all recipients"), isOn: $consent)
                            .font(.callout).toggleStyle(.checkbox).disabled(controller.isBusy)
                    }
                }
                if controller.isConfirming {
                    resultCard(
                        title: language.text("正在确认结果", "Confirming results"), detail: language.text("正在同步官方邀请记录…", "Syncing official invitation records…"), color: .accentColor,
                        progress: true)
                }
                if let result = controller.batchResult {
                    ForEach(result.sent, id: \.self) { email in
                        let accepted = controller.records.contains { $0.email?.lowercased() == email.lowercased() && $0.status == .redeemed }
                        resultCard(
                            title: accepted ? language.text("邀请已接受", "Invitation accepted") : language.text("邀请已发送", "Invitation sent"),
                            detail: email + "\n"
                                + (accepted
                                    ? language.text(
                                        "官方记录已确认接受，奖励到账以官方结果为准。", "Acceptance confirmed by the official record. Reward crediting is determined by the official service.")
                                    : language.text("等待好友接受并完成官方条件。", "Waiting for the recipient to accept and complete the official requirements.")),
                            color: accepted ? .green : .accentColor)
                    }
                    ForEach(result.uncertain, id: \.self) { email in
                        resultCard(
                            title: language.text("结果待确认", "Result unconfirmed"), detail: email + "\n" + language.text("请核对记录，避免重复发送。", "Check history before sending again."),
                            color: .accentColor)
                    }
                    ForEach(result.failed, id: \.self) { email in
                        resultCard(
                            title: language.text("未发送", "Not sent"),
                            detail: email + "\n" + language.text("官方未接受此邮箱，已保留在输入框。", "The official service did not accept this address. It remains in the input field."),
                            color: warningColor)
                    }
                }
                if let notice = controller.notice {
                    Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("codex.invite.result")
                }
                if controller.uncertainEmail != nil {
                    Button(language.text("核对邀请记录", "Check invitation records")) {
                        controller.checkRecord(account: account, resolve: resolveAccount, language: language)
                    }.disabled(controller.isBusy || controller.review == nil)
                }
                Link(
                    language.text("官方邀请规则", "Official referral rules"),
                    destination: URL(string: "https://help.openai.com/en/articles/20001271-chatgpt-desktop-referral-promotions")!
                )
                .font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(language.text("查看你的邀请", "Your invitations")).font(.headline)
                Spacer()
                Picker(
                    language.text("时间范围", "Period"),
                    selection: Binding(
                        get: { controller.historyPeriod },
                        set: { controller.loadHistory(account: account, resolve: resolveAccount, period: $0, language: language) }
                    )
                ) {
                    ForEach(CodexReferralPeriod.allCases) { period in Text(period.title(language)).tag(period) }
                }.labelsHidden().frame(width: 140)
            }
            if let message = controller.historyNotice {
                Text(message).font(.caption).foregroundStyle(warningColor).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(controller.records) { record in
                        HStack(spacing: 12) {
                            Text(record.email?.prefix(1).uppercased() ?? "?")
                                .font(.headline).frame(width: 36, height: 36)
                                .background(FixedVisualPalette.surfaceMutedFill, in: Circle())
                            Text(record.email ?? language.text("邮箱未提供", "Email unavailable"))
                                .font(.body).lineLimit(2).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(record.status.title(language))
                                .font(.callout.weight(.medium)).foregroundStyle(record.status == .redeemed ? Color.green : Color.secondary)
                                .fixedSize()
                        }.padding(.vertical, 13)
                        Divider()
                    }
                    if controller.isHistoryLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(language.text("正在读取邀请记录…", "Loading invitations…"))
                        }.font(.callout).padding(20)
                    } else if controller.historyLoaded && controller.records.isEmpty {
                        Label(language.text("此时间范围内暂无邀请", "No invitations in this period"), systemImage: "envelope")
                            .foregroundStyle(.secondary).padding(.vertical, 60)
                    }
                    if controller.historyCursor != nil {
                        Button(language.text("加载更多", "Load more")) {
                            controller.loadHistory(account: account, resolve: resolveAccount, period: controller.historyPeriod, more: true, language: language)
                        }.disabled(controller.isHistoryLoading).padding(16)
                    }
                }.padding(.trailing, 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(language.text("已加载 \(controller.records.count) 条 · 接受状态来自官方记录", "\(controller.records.count) loaded · Acceptance status from official records"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func offer(_ review: CodexReferralReview) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(CodexReferralPresentation.reward(review.eligibility, language: language))
                .font(.headline).accessibilityIdentifier("codex.invite.reward")
            if review.eligibility.creditAmount == nil, let title = review.eligibility.title, !title.isEmpty {
                Text(CodexReferralPresentation.publicText(title)).font(.callout)
            }
            if let text = review.eligibility.description, !text.isEmpty {
                Text(CodexReferralPresentation.publicText(text)).font(.callout)
            }
            Text(
                language.text(
                    "剩余发送 \(capacity(review.eligibility.remainingSendCapacity)) · 奖励名额 \(capacity(review.eligibility.remainingRewardCapacity)) · 本次最多 \(review.eligibility.invitationCapacity) 个",
                    "Send capacity \(capacity(review.eligibility.remainingSendCapacity)) · Reward capacity \(capacity(review.eligibility.remainingRewardCapacity)) · Up to \(review.eligibility.invitationCapacity) at once"
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(language.text("邀请条件与核对时间", "Requirements and last check")) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(review.eligibility.rules.enumerated()), id: \.offset) { _, rule in
                        Text("• " + CodexReferralPresentation.publicText(rule)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(language.text("核对于 ", "Checked ") + language.dateTime(review.checkedAt))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 5)
            }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func resultCard(title: String, detail: String, color: Color, progress: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if progress { ProgressView().controlSize(.small) } else { Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.3)) }
    }

    private var recipients: CodexReferralRecipients { .parse(controller.email) }
    private var canSend: Bool {
        guard controller.allowsSending, !controller.isBusy, controller.uncertainEmail == nil, let eligibility = controller.review?.eligibility else { return false }
        return eligibility.canInvite && recipients.canSend(capacity: eligibility.invitationCapacity)
            && (!eligibility.requiresExplicitConfirmation || consent)
    }
    private var recipientValidation: String? {
        if recipients.tooLong { return language.text("输入过长，请分批邀请。", "Input is too long. Split the addresses into batches.") }
        if recipients.invalidCount > 0 {
            return language.text("有 \(recipients.invalidCount) 个邮箱格式不正确，请修改后发送。", "\(recipients.invalidCount) addresses are invalid. Correct them before sending.")
        }
        if let limit = controller.review?.eligibility.invitationCapacity, recipients.emails.count > limit {
            return language.text("本次最多可发送 \(limit) 个，请减少邮箱数量。", "You can send up to \(limit) invitations at once. Remove extra addresses.")
        }
        if recipients.duplicateCount > 0 { return language.text("已合并 \(recipients.duplicateCount) 个重复邮箱。", "Merged \(recipients.duplicateCount) duplicate addresses.") }
        return nil
    }
    private var warningColor: Color { FixedVisualPalette.statusWarningForeground(scheme) }
    private var purchaseURL: URL {
        let fallback = URL(string: "https://aigoodbro.com")!
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AiGoodBroInvitePurchaseURL") as? String,
            let url = URL(string: value), url.scheme == "https", ["aigoodbro.com", "www.aigoodbro.com"].contains(url.host ?? "")
        else { return fallback }
        return url
    }
    private func refreshHistory() {
        controller.loadHistory(account: account, resolve: resolveAccount, period: controller.historyPeriod, language: language)
    }
    private func capacity(_ value: Int?) -> String { value.map(String.init) ?? language.text("未提供", "Not provided") }
}
