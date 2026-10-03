import SwiftUI

/// Explicit account control with two confirmations; no keyboard, menu, URL or CLI shortcut.
struct ResetCreditButton: View {
    @Environment(\.widgetLanguage) private var language
    let profile: CodexProfile
    let selectedProfileID: String?
    let hubAccountAlias: String?
    let onConfirmedResult: () -> Void
    var displayNumber: Int? = nil
    var compact = false

    @StateObject private var controller = CodexResetCreditController()

    var body: some View {
        Button {
            controller.beginReview(profile: profile, selectedProfileID: selectedProfileID)
        } label: {
            HStack(spacing: compact ? 4 : 6) {
                if controller.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                Text(compact ? language.text("重置卡", "Reset") : language.text("使用重置卡", "Use reset card"))
                    .lineLimit(1)
            }
        }
        .buttonStyle(WorkspaceActionButtonStyle(compact: compact))
        .disabled(!canBegin)
        .help(buttonHelp)
        .accessibilityLabel(buttonTitle)
        .alert(
            language.text("第一次确认：核对账号与重置卡", "Confirmation 1: verify account and reset card"),
            isPresented: reviewingBinding
        ) {
            Button(language.text("取消", "Cancel"), role: .cancel) { controller.cancel() }
                .keyboardShortcut(.cancelAction)
            Button(language.text("我已核对账号与卡片", "I verified the account and card")) {
                controller.confirmReviewed(profile: profile, selectedProfileID: selectedProfileID)
            }
        } message: {
            Text(reviewMessage)
        }
        .alert(
            language.text("第二次确认：使用一张重置卡", "Confirmation 2: consume one reset card"),
            isPresented: consumptionBinding
        ) {
            Button(language.text("取消", "Cancel"), role: .cancel) { controller.cancel() }
                .keyboardShortcut(.cancelAction)
            // Deliberately has no `.defaultAction` keyboard shortcut.
            Button(language.text("使用这张重置卡", "Consume this reset card"), role: .destructive) {
                controller.confirmConsumption(
                    profile: profile,
                    selectedProfileID: selectedProfileID,
                    hubAccountAlias: hubAccountAlias,
                    onConfirmedResult: onConfirmedResult
                )
            }
        } message: {
            Text(
                language.text(
                    "将为 \(accountLabel) 使用 1 张重置卡。\n符合条件的额度窗口将重置，每周额度的下次重置时间会改变。此操作无法撤销。",
                    "Use 1 reset card for \(accountLabel).\nEligible limit windows will reset, and the next weekly reset time will change. This cannot be undone."
                ))
        }
        .alert(item: $controller.notice) { notice in
            Alert(
                title: Text(notice.isError ? language.text("未确认重置", "Reset not confirmed") : language.text("重置结果", "Reset result")),
                message: Text(notice.message),
                dismissButton: .cancel(Text(language.text("关闭", "Close")))
            )
        }
        .onChange(of: selectedProfileID) { _ in
            controller.invalidateIfProfileChanged(profile: profile, selectedProfileID: selectedProfileID)
        }
        .onChange(of: profile.lastSnapshot?.accountID) { _ in
            controller.invalidateIfProfileChanged(profile: profile, selectedProfileID: selectedProfileID)
        }
        .onChange(of: profile.lastSnapshot?.resetCreditExpiries) { _ in
            controller.invalidateIfProfileChanged(profile: profile, selectedProfileID: selectedProfileID)
        }
        .onDisappear { controller.cancel() }
    }

    private var canBegin: Bool {
        selectedProfileID == profile.id
            && !controller.isWorking
            && controller.step == .idle
            && profile.lastSnapshot?.quotaReadSucceeded != false
            && (profile.lastSnapshot?.availableResetCredits ?? 0) > 0
    }

    private var buttonTitle: String {
        guard let count = profile.lastSnapshot?.availableResetCredits else {
            return language.text("重置卡状态不可用", "Reset cards unavailable")
        }
        guard count > 0 else { return language.text("没有可用重置卡", "No reset cards") }
        return language.text("使用重置卡", "Use reset card")
    }

    private var buttonHelp: String {
        canBegin
            ? language.text("为此账号使用一张重置卡，需要二次确认", "Use one reset card for this account after two confirmations")
            : language.text("官方确认有可用卡片后才能开始；状态未知时请刷新账号", "Requires an officially reported available card. Refresh the account if its status is unknown.")
    }

    private var accountLabel: String {
        let prefix = displayNumber.map { String(format: "%02d · ", $0) } ?? ""
        switch controller.step {
        case .reviewing(let review), .consumption(let review): return prefix + review.accountRemark
        case .idle: return prefix
        }
    }

    private var reviewMessage: String {
        guard case .reviewing(let review) = controller.step else { return "" }
        let expiry: String
        if let date = review.card.expiresAt {
            expiry = date.formatted(date: .abbreviated, time: .shortened)
        } else {
            expiry = language.text("无到期时间", "No expiry")
        }
        return language.text(
            "账号：\(accountLabel)\n卡片：1 张可用的 Codex 额度重置卡\n到期：\(expiry)",
            "Account: \(accountLabel)\nCard: 1 available Codex rate-limit reset card\nExpiry: \(expiry)"
        )
    }

    private var reviewingBinding: Binding<Bool> {
        Binding(
            get: {
                if case .reviewing = controller.step { return true }
                return false
            },
            set: { if !$0, case .reviewing = controller.step { controller.cancel() } }
        )
    }

    private var consumptionBinding: Binding<Bool> {
        Binding(
            get: {
                if case .consumption = controller.step { return true }
                return false
            },
            set: { if !$0, case .consumption = controller.step { controller.cancel() } }
        )
    }
}
