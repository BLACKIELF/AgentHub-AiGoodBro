import SwiftUI

/// Evidence shown here comes only from the selected profile's quota snapshot.
struct AccountRecoveryGuide: View {
    @ObservedObject var store: UsageStore
    let language: WidgetLanguage
    @State private var selectedID = ""
    @State private var confirmingLogin = false
    @State private var loginFeedback: String?
    @Environment(\.codexDeviceLoginHost) private var loginHost

    private var candidates: [CodexProfile] { store.profiles.filter { Self.isIsolated($0) } }
    private var selected: CodexProfile? { candidates.first { $0.id == selectedID } }

    static func isIsolated(_ profile: CodexProfile) -> Bool {
        guard !profile.isSystemProfile, profile.codexHomePath.hasPrefix("/") else { return false }
        let target = profile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
        let system = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").resolvingSymlinksInPath().standardizedFileURL
        return target != system
    }

    static func quotaVerified(_ profile: CodexProfile, now: Date = Date()) -> Bool {
        guard let snapshot = profile.lastSnapshot, snapshot.quotaReadSucceeded == true,
            profile.lastQuotaReadFailureAt == nil, profile.lastQuotaReadFailureReason == nil,
            ResetCardPresentation.isFresh(snapshot.fetchedAt, now: now)
        else { return false }
        return snapshot.fiveHour != nil || snapshot.sevenDay != nil || snapshot.monthly != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(language.text("独立账号登录与恢复", "Isolated account recovery"), systemImage: "person.badge.key")
                .font(.headline)
            Picker(language.text("目标账号", "Target account"), selection: $selectedID) {
                Text(language.text("先选择要恢复的账号", "Choose an account first")).tag("")
                ForEach(candidates) { profile in
                    Text(AccountDisplay.profileName(profile) + " · " + String(profile.id.prefix(8))).tag(profile.id)
                }
            }.disabled(store.isLoggingIn)
            if let profile = selected {
                Text(language.text("独立资料 ", "Isolated profile ") + String(profile.id.prefix(8)))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Label(
                    Self.quotaVerified(profile) ? language.text("当前额度快照已验证", "Current quota snapshot verified") : language.text("额度恢复尚未确认", "Quota recovery not confirmed"),
                    systemImage: Self.quotaVerified(profile) ? "checkmark.circle" : "clock"
                )
                .font(.subheadline)
                if let date = profile.lastSnapshot?.fetchedAt {
                    Text(language.text("快照时间：", "Snapshot: ") + language.dateTime(date)).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = store.canLoginProfile(profile.id) {
                    Text(reason.message(language)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(language.text("登录这个账号", "Sign in to this account")) { confirmingLogin = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isPreview || store.canLoginProfile(profile.id) != nil)
                    Button(language.text("检查额度", "Check limits")) { store.refreshProfile(profile.id) }
                        .disabled(store.isPreview || store.isLoggingIn || store.refreshingProfileIDs.contains(profile.id))
                }
                if let loginFeedback {
                    Text(loginFeedback).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let message = store.accountManagerMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(
                    language.text(
                        "仅列出独立账号；不会跟随当前监控对象自动选择。新账号请先在账号区添加。",
                        "Only isolated profiles are listed. The monitored account is never selected automatically. Add new accounts in the account area first.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(language.text("登录成功后，为什么还要检查？", "Why check after signing in?")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        language.text(
                            "① 网页授权通过 → ② 官方登录进程完成 → ③ 同一独立账号可识别 → ④ 新额度快照成功。前一步成功不代替后一步。",
                            "① Browser approval → ② Official login finishes → ③ The same isolated account is recognized → ④ Fresh quota succeeds. Each stage needs its own evidence."
                        ))
                    Text(
                        language.text(
                            "登录后额度仍失败：先检查额度，不要反复重新登录。忙碌或占用待核实时等待原任务；不会自动清理租约或结束进程。",
                            "If quota still fails, check limits before signing in again. Wait for busy or unverified reservations; leases and processes are never cleared automatically."
                        ))
                    Text(
                        language.text(
                            "若需设备授权，请在官方登录界面核对目标身份并亲自完成。设备码不应复制到聊天、回执或截图。",
                            "For device authorization, verify the target identity and complete the official flow yourself. Do not copy device codes into chats, receipts or screenshots."
                        ))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.caption)
        }
        .padding(16).sectionBackground()
        .confirmationDialog(language.text("确认独立账号", "Confirm isolated account"), isPresented: $confirmingLogin, titleVisibility: .visible) {
            if let profile = selected {
                Button(language.text("继续登录", "Continue sign-in")) {
                    guard !store.isPreview, Self.isIsolated(profile), candidates.contains(where: { $0.id == profile.id }) else { return }
                    switch store.loginProfile(profile.id, host: loginHost) {
                    case .accepted:
                        loginFeedback = nil
                    case .blocked(let reason):
                        loginFeedback = reason.message(language)
                    }
                }
            }
        } message: {
            if let profile = selected {
                Text(
                    AccountDisplay.profileName(profile) + "\n" + profile.id + "\n"
                        + language.text("仅此独立账号。先检查占用；浏览器中请再次确认身份。", "Only this isolated account. Occupancy is checked first; verify identity again in the browser."))
            }
        }
    }
}
