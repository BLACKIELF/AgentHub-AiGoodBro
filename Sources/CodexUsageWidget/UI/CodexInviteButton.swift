import SwiftUI

@MainActor
final class CodexInviteController: ObservableObject {
    @Published var email = ""
    @Published private(set) var review: CodexReferralReview?
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var notice: String?
    @Published private(set) var uncertainEmail: String?
    private var boundAccount: CodexReferralAccount?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private let previewOnly: Bool
    private let client: CodexReferralClient

    init(previewReview: CodexReferralReview? = nil, client: CodexReferralClient = CodexReferralClient()) {
        previewOnly = previewReview != nil
        review = previewReview
        self.client = client
    }

    var isBusy: Bool { isLoading || isSending }
    var allowsSending: Bool { !previewOnly }

    func load(account: CodexReferralAccount, resolve: @escaping () throws -> CodexReferralAccount, language: WidgetLanguage) {
        guard !previewOnly, !isBusy else { return }
        if boundAccount?.matches(account) != true {
            email = ""
            uncertainEmail = nil
            notice = nil
        }
        boundAccount = account
        review = nil
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
                notice = (error as? CodexReferralFailure ?? .network).message(language)
            }
        }
    }

    func send(account: CodexReferralAccount, resolve: @escaping () throws -> CodexReferralAccount, consent: Bool, language: WidgetLanguage) {
        guard !previewOnly, !isBusy, uncertainEmail == nil, let review, let recipient = CodexReferralPresentation.email(email) else { return }
        isSending = true
        notice = nil
        Task {
            defer { isSending = false }
            do {
                guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                try await client.send(account, reviewed: review, email: recipient, consent: consent, language: language, currentAccount: resolve)
                email = ""
                notice = language.text("邀请已发送。奖励将在好友完成官方条件后发放。", "Invitation sent. Rewards follow after the recipient completes the official requirements.")
            } catch {
                // The client maps every failure after POST dispatch to an
                // explicit delivery result. Other errors belong to preflight.
                let failure = error as? CodexReferralFailure ?? .network
                if failure == .deliveryUncertain { uncertainEmail = recipient }
                if failure != .deliveryUncertain { self.review = nil }
                notice = failure.message(language)
            }
        }
    }

    func checkRecord(account: CodexReferralAccount, resolve: @escaping () throws -> CodexReferralAccount, language: WidgetLanguage) {
        guard !previewOnly, !isBusy, let recipient = uncertainEmail, let review else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                let exists = try await client.recorded(account, context: review.context, email: recipient, language: language)
                guard try resolve().matches(account) else { throw CodexReferralFailure.identityChanged }
                if exists {
                    uncertainEmail = nil
                    email = ""
                    notice = language.text("官方已记录这条邀请。奖励是否到账以官方结果为准。", "The official service has recorded this invitation. Reward crediting remains subject to its requirements.")
                } else {
                    notice = language.text("暂未核实到这条邀请，发送结果仍未知；请稍后再核对。", "This invitation could not be verified yet. Delivery remains unknown; check again later.")
                }
            } catch { notice = (error as? CodexReferralFailure ?? .network).message(language) }
        }
    }

    func close() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration = UUID()
        isLoading = false
    }
}

struct CodexInviteButton: View {
    let accountLabel: String
    var resolveAccount: (() throws -> CodexReferralAccount)?
    @Environment(\.widgetLanguage) private var language
    @State private var account: CodexReferralAccount?
    @State private var reviewedAccountLabel = ""
    @State private var beginError: String?
    @StateObject private var controller = CodexInviteController()

    var body: some View {
        Button {
            do {
                reviewedAccountLabel = accountLabel
                account = try resolveAccount?()
            } catch { beginError = (error as? CodexReferralFailure ?? .unavailable).message(language) }
        } label: {
            Label(language.text("邀请", "Invite"), systemImage: "person.badge.plus")
                .lineLimit(1)
        }
        .buttonStyle(WorkspaceActionButtonStyle(compact: true))
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
    @State private var consent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label(language.text("邀请好友", "Invite a friend"), systemImage: "person.badge.plus")
                    .font(.title2.weight(.semibold))
                Text(accountLabel).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if controller.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(language.text("读取官方邀请信息…", "Reading official referral information…"))
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    if let review = controller.review {
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
                                    "剩余发送名额：\(capacity(review.eligibility.remainingSendCapacity)) · 奖励名额：\(capacity(review.eligibility.remainingRewardCapacity))",
                                    "Send capacity: \(capacity(review.eligibility.remainingSendCapacity)) · Reward capacity: \(capacity(review.eligibility.remainingRewardCapacity))"
                                )
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Text(language.text("核对于 ", "Checked ") + language.dateTime(review.checkedAt))
                                .font(.caption2).foregroundStyle(.secondary)
                            ForEach(Array(review.eligibility.rules.enumerated()), id: \.offset) { _, rule in
                                Text("• " + CodexReferralPresentation.publicText(rule))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 12))
                    } else if !controller.isLoading {
                        Text(language.text("邀请点数尚未核实", "Invitation credits are unverified"))
                            .font(.headline).accessibilityIdentifier("codex.invite.reward")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(language.text("好友邮箱", "Friend's email")).font(.callout.weight(.medium))
                        TextField(language.text("填写邀请邮箱", "Enter recipient email"), text: $controller.email)
                            .textFieldStyle(.roundedBorder)
                            .disabled(controller.isSending || controller.uncertainEmail != nil)
                            .accessibilityIdentifier("codex.invite.email")
                        if !controller.email.isEmpty, CodexReferralPresentation.email(controller.email) == nil {
                            Text(CodexReferralFailure.invalidEmail.message(language)).font(.caption).foregroundStyle(.secondary)
                        }
                        if controller.review?.eligibility.requiresExplicitConfirmation == true {
                            Toggle(language.text("我已征得好友同意发送邀请", "I have the recipient's consent to send this invitation"), isOn: $consent)
                                .font(.caption).toggleStyle(.checkbox).disabled(controller.isBusy)
                        }
                    }
                    if let notice = controller.notice {
                        Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("codex.invite.result")
                    }
                    if controller.uncertainEmail != nil {
                        Button(language.text("核对邀请记录", "Check invitation records")) {
                            controller.checkRecord(account: account, resolve: resolveAccount, language: language)
                        }
                        .disabled(controller.isBusy || controller.review == nil)
                    }
                    Link(
                        language.text("官方邀请规则", "Official referral rules"),
                        destination: URL(string: "https://help.openai.com/en/articles/20001271-chatgpt-desktop-referral-promotions")!
                    )
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 380)
            HStack(spacing: 10) {
                Button(language.text("刷新邀请信息", "Refresh offer")) {
                    consent = false
                    controller.load(account: account, resolve: resolveAccount, language: language)
                }
                .disabled(controller.isBusy)
                Spacer()
                Button(language.text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(controller.isSending)
                Button {
                    controller.send(account: account, resolve: resolveAccount, consent: consent, language: language)
                } label: {
                    HStack(spacing: 5) {
                        if controller.isSending { ProgressView().controlSize(.small) }
                        Text(language.text("发送邀请", "Send invitation"))
                    }
                }
                .disabled(!canSend)
                .accessibilityIdentifier("codex.invite.send")
            }
        }
        .padding(22).frame(width: 520)
        .interactiveDismissDisabled(controller.isSending)
        .onAppear { controller.load(account: account, resolve: resolveAccount, language: language) }
        .onChange(of: controller.email) { _ in consent = false }
    }

    private var canSend: Bool {
        guard controller.allowsSending, !controller.isBusy, controller.uncertainEmail == nil, let eligibility = controller.review?.eligibility else { return false }
        return eligibility.canInvite && CodexReferralPresentation.email(controller.email) != nil
            && (!eligibility.requiresExplicitConfirmation || consent)
    }

    private func capacity(_ value: Int?) -> String {
        value.map(String.init) ?? language.text("未提供", "Not provided")
    }
}
