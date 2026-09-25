import Foundation

/// The eight-account design-review data, shared by the isolated interactive
/// preview and the production-view screenshot renderer. All paths stay below
/// the caller's temporary root; no real account state is consulted.
@MainActor
enum DesignHomePreviewFixture {
    private struct PersistedState: Encodable {
        let schemaVersion = 1
        let profiles: [CodexProfile]
        let selectedMonitorProfileID: String
        let selectedLaunchProfileID: String
        let resetBackfillCheckedAt: Date
    }

    private struct Account {
        let id: String
        let name: String
        let plan: String
        let proMultiplier: Int?
        let creditBalance: String?
        let membershipUntil: Date?
        let membershipNeedsVerification: Bool
        let fiveHourRemaining: Double?
        let fiveHourReset: Date?
        let sevenDayRemaining: Double
        let sevenDayReset: Date
    }

    static let referenceDate = beijingDate(day: 23, hour: 3)

    private static func beijingDate(day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(
            from: DateComponents(
                year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    static func configure(_ settings: AppSettings) {
        settings.onboarding.skip()
        settings.language = .zh
        settings.themeMode = .dark
        _ = settings.selectPalette("codexu.liquid-keycap")
        settings.workspaceDisplayMode = .simple
        settings.simpleWorkspacePreset = .accountCards
        settings.accountWorkspaceLayout = .cards
        settings.pinnedAccountKey = nil
        settings.agentNavigation = AgentNavigationState(
            initialized: true, customized: true,
            orderedVisibleProviderIDs: [
                AgentNavCatalog.codexID, LocalCLIKind.kimi.rawValue,
                LocalCLIKind.workBuddy.rawValue, LocalCLIKind.trae.rawValue,
                LocalCLIKind.openCode.rawValue, LocalCLIKind.grok.rawValue,
                LocalCLIKind.gemini.rawValue, LocalCLIKind.mimo.rawValue,
                LocalCLIKind.claudeCode.rawValue, LocalCLIKind.zcode.rawValue,
            ])
    }

    static func makeStore(root: URL) -> UsageStore {
        // Dates and percentages mirror docs/ui-preview-0923v7/index.html
        // (its internal label is 0923v8). A nil window stays unknown.
        let accounts: [Account] = [
            Account(
                id: "pro20x", name: "pro20x", plan: "pro", proMultiplier: 20,
                creditBalance: "499.96", membershipUntil: beijingDate(day: 25), membershipNeedsVerification: false,
                fiveHourRemaining: nil, fiveHourReset: nil,
                sevenDayRemaining: 62, sevenDayReset: beijingDate(day: 26, hour: 20, minute: 51)),
            Account(
                id: "pro5x", name: "pro5x", plan: "pro", proMultiplier: 5,
                creditBalance: nil, membershipUntil: beijingDate(day: 30), membershipNeedsVerification: false,
                fiveHourRemaining: nil, fiveHourReset: nil,
                sevenDayRemaining: 98, sevenDayReset: beijingDate(day: 28, hour: 16, minute: 36)),
            Account(
                id: "work", name: "工作号", plan: "plus", proMultiplier: nil,
                creditBalance: "0", membershipUntil: nil, membershipNeedsVerification: false,
                fiveHourRemaining: 100, fiveHourReset: beijingDate(day: 23, hour: 6),
                sevenDayRemaining: 32, sevenDayReset: beijingDate(day: 27, hour: 13, minute: 29)),
            Account(
                id: "collaboration", name: "协作号", plan: "plus", proMultiplier: nil,
                creditBalance: "0", membershipUntil: beijingDate(day: 26), membershipNeedsVerification: false,
                fiveHourRemaining: 95, fiveHourReset: beijingDate(day: 23, hour: 5, minute: 3),
                sevenDayRemaining: 82, sevenDayReset: beijingDate(day: 28, hour: 8, minute: 9)),
            Account(
                id: "daily", name: "日常号", plan: "plus", proMultiplier: nil,
                creditBalance: "0", membershipUntil: beijingDate(day: 21), membershipNeedsVerification: true,
                fiveHourRemaining: 100, fiveHourReset: beijingDate(day: 23, hour: 6),
                sevenDayRemaining: 20, sevenDayReset: beijingDate(day: 27, hour: 2, minute: 6)),
            Account(
                id: "america", name: "美国号", plan: "plus", proMultiplier: nil,
                creditBalance: "0", membershipUntil: beijingDate(day: 21), membershipNeedsVerification: true,
                fiveHourRemaining: 100, fiveHourReset: beijingDate(day: 23, hour: 6),
                sevenDayRemaining: 45, sevenDayReset: beijingDate(day: 28, hour: 7, minute: 18)),
            Account(
                id: "personal", name: "个人号", plan: "plus", proMultiplier: nil,
                creditBalance: "0", membershipUntil: nil, membershipNeedsVerification: false,
                fiveHourRemaining: 98, fiveHourReset: beijingDate(day: 23, hour: 5, minute: 30),
                sevenDayRemaining: 16, sevenDayReset: beijingDate(day: 24, hour: 11, minute: 3)),
            Account(
                id: "mgr", name: "MGR", plan: "plus", proMultiplier: nil,
                creditBalance: "2646.31", membershipUntil: beijingDate(day: 30), membershipNeedsVerification: false,
                fiveHourRemaining: 100, fiveHourReset: beijingDate(day: 23, hour: 6),
                sevenDayRemaining: 35, sevenDayReset: beijingDate(day: 25, hour: 15, minute: 6)),
        ]

        func quota(_ remaining: Double?, reset: Date?, minutes: Int) -> CodexQuotaWindowSnapshot? {
            guard let remaining else { return nil }
            return CodexQuotaWindowSnapshot(
                RateWindow(
                    usedPercent: 100 - remaining, windowDurationMins: minutes, resetsAt: reset))
        }

        let profiles = accounts.map { account in
            let snapshot = CodexAccountSnapshot(
                accountType: "chatgpt", planType: account.plan,
                email: account.id == "pro20x" ? "pro20x@example.invalid" : nil,
                accountID: "synthetic-design-\(account.id)",
                limitId: "codex", limitName: "Codex",
                fiveHour: quota(account.fiveHourRemaining, reset: account.fiveHourReset, minutes: 300),
                sevenDay: quota(account.sevenDayRemaining, reset: account.sevenDayReset, minutes: 10_080),
                monthly: nil, availableResetCredits: nil, resetCreditExpiries: nil,
                creditBalance: account.creditBalance, creditBalanceUnlimited: false,
                fetchedAt: referenceDate, appServerVersion: nil)
            var profile = CodexProfile(
                id: "design-\(account.id)", name: account.name, remark: account.name,
                codexHomePath: root.appendingPathComponent("home/profiles/\(account.id)").path,
                isSystemProfile: false, createdAt: referenceDate,
                lastSnapshot: snapshot,
                officialProfile: CodexOfficialProfileSnapshot(
                    accountEmail: nil, displayName: nil, username: nil,
                    lifetimeTokens: nil, peakDailyTokens: nil, planType: account.plan,
                    subscriptionActiveUntil: account.membershipUntil,
                    statsAsOf: referenceDate, fetchedAt: referenceDate),
                proTierMultiplier: account.proMultiplier,
                executionPreference: .defaultValue)
            if account.membershipNeedsVerification {
                profile.lastMembershipRefreshSucceeded = false
            }
            return profile
        }

        // The system profile is hidden by the real home view. Linking it to
        // pro20x marks that visible account as the currently active Codex one.
        let first = profiles[0]
        let currentSystem = CodexProfile(
            id: "design-current-system", name: "当前 Codex",
            codexHomePath: root.appendingPathComponent("home/.codex").path,
            isSystemProfile: true, createdAt: referenceDate,
            lastSnapshot: first.lastSnapshot,
            officialProfile: first.officialProfile)
        let persistedProfiles = profiles + [currentSystem]
        let support = root.appendingPathComponent("support")
            .appendingPathComponent(DispatchParticipationPaths.supportDirectoryName)
        do {
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let state = PersistedState(
                profiles: persistedProfiles,
                selectedMonitorProfileID: first.id,
                selectedLaunchProfileID: first.id,
                resetBackfillCheckedAt: referenceDate)
            try JSONEncoder().encode(state).write(
                to: support.appendingPathComponent(DispatchParticipationPaths.snapshotFileName),
                options: .atomic)
        } catch {
            preconditionFailure("Could not create isolated design fixture")
        }

        let selected = first.lastSnapshot!
        let store = UsageStore(
            previewProfiles: persistedProfiles,
            snapshot: UsageSnapshot(
                refreshedAt: referenceDate,
                account: AccountInfo(type: "chatgpt", planType: "pro", emailPresent: false),
                limitId: "codex", limitName: "Codex", quotaReadSucceeded: true,
                fiveHourQuota: nil,
                sevenDayQuota: selected.sevenDay.map {
                    RateWindow(
                        usedPercent: $0.usedPercent,
                        windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt)
                },
                monthlyQuota: nil,
                credits: CreditsInfo(
                    hasCredits: true, unlimited: false, balance: "499.96",
                    resetCredits: nil, resetCreditDetails: []),
                cloudLifetimeTokens: nil, local: nil, taskBoard: nil, messages: []),
            isolatedRoot: root)
        store.publicResetAnnouncements.seedPreviewLatest(
            PublicResetAnnouncement(
                id: "synthetic-design-reset-announcement",
                resetType: .regular,
                announcedAt: referenceDate.addingTimeInterval(-3_600),
                text: "合成预告：预计 2026 年 9 月 23 日 15:00 前重置；请以账号实际额度为准。",
                source: .init(type: "observed", author: nil, url: nil)),
            checkedAt: referenceDate)
        return store
    }

    static func makeLocalCLIStore(root: URL) -> LocalCLIAccountStore {
        let kinds: [LocalCLIKind] = [.claudeCode, .kimi, .grok, .gemini]
        let profiles = kinds.map { kind in
            LocalCLIProfile(
                id: "design-local-\(kind.rawValue)", kind: kind,
                displayName: kind.displayName,
                configDirectory: root.appendingPathComponent("local-cli/\(kind.rawValue)").path,
                isDefault: true)
        }
        // No fabricated use/remaining/reset data for providers without an
        // official response in this illustrative fixture.
        return LocalCLIAccountStore.preview(profiles: profiles, quotas: [:], root: root)
    }
}
