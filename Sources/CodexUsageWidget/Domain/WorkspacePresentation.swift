import Foundation

/// Effective availability for display only. Never rewrite the official snapshot.
enum QuotaAvailabilityPresentation {
    static func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let bounded = max(0, min(100, value))
        if bounded > 0, bounded < 1 { return "<1%" }
        return "\(Int(bounded.rounded()))%"
    }

    static func isWeeklyExhausted(_ sevenDayRemaining: Double?) -> Bool {
        guard let sevenDayRemaining, sevenDayRemaining.isFinite else { return false }
        return sevenDayRemaining <= 0
    }

    static func fiveHourRemaining(_ fiveHour: Double?, sevenDay: Double?) -> Double? {
        if isWeeklyExhausted(sevenDay) { return 0 }
        return fiveHour
    }

    /// A missing official short window stays unknown, including weekly-only Pro.
    static func reportedFiveHourRemaining(_ fiveHour: Double?, sevenDay: Double?) -> Double? {
        guard let fiveHour else { return nil }
        return fiveHourRemaining(fiveHour, sevenDay: sevenDay)
    }

    static func fiveHourWindow(_ fiveHour: RateWindow?, sevenDay: RateWindow?) -> RateWindow? {
        guard isWeeklyExhausted(sevenDay?.remainingPercent) else { return fiveHour }
        return RateWindow(
            usedPercent: 100,
            windowDurationMins: fiveHour?.windowDurationMins ?? 300,
            resetsAt: fiveHour?.resetsAt
        )
    }

    static func selfTest() -> Bool {
        let fiveHour = RateWindow(usedPercent: 18, windowDurationMins: 300, resetsAt: nil)
        let exhausted = RateWindow(usedPercent: 100, windowDurationMins: 10_080, resetsAt: nil)
        return fiveHourRemaining(82, sevenDay: 0) == 0
            && fiveHourRemaining(nil, sevenDay: 0) == 0
            && fiveHourRemaining(82, sevenDay: nil) == 82
            && fiveHourRemaining(nil, sevenDay: 83) == nil
            && fiveHourRemaining(82, sevenDay: 0.1) == 82
            && fiveHourRemaining(82, sevenDay: .nan) == 82
            && reportedFiveHourRemaining(56, sevenDay: 0) == 0
            && reportedFiveHourRemaining(nil, sevenDay: 0) == nil
            && reportedFiveHourRemaining(56, sevenDay: 20) == 56
            && fiveHourWindow(fiveHour, sevenDay: exhausted)?.remainingPercent == 0
            && fiveHourWindow(nil, sevenDay: exhausted)?.remainingPercent == 0
            && fiveHourWindow(nil, sevenDay: nil) == nil
            && fiveHour.remainingPercent == 82
            && percentText(nil) == "—"
            && percentText(.nan) == "—"
            && percentText(0) == "0%"
            && percentText(0.1) == "<1%"
    }
}

/// Presentation only: never changes identity, scheduling eligibility or account leases.
struct WorkspacePresentation {
    let accountCount: Int
    let managedAccountCount: Int
    let focusedProfile: CodexProfile?
    private let selectedProfile: CodexProfile?

    var isSingleAccount: Bool { accountCount <= 1 }

    var quotaProfile: CodexProfile? { usesFocusedQuota ? focusedProfile : selectedProfile }

    private var usesFocusedQuota: Bool {
        isSingleAccount && focusedProfile != nil
            && focusedProfile?.recordedAccountKey != selectedProfile?.recordedAccountKey
    }

    init(profiles: [CodexProfile], selectedProfileID: String?) {
        let managed = profiles.filter { !$0.isSystemProfile }
        // An unverified system placeholder is not a second account. Unknown managed
        // profiles remain separate until the existing identity logic can match them.
        let represented = profiles.filter { !$0.isSystemProfile || $0.lastSnapshot != nil || managed.isEmpty }
        accountCount = CodexProfile.groupsByRecordedAccount(represented).count
        managedAccountCount = CodexProfile.groupsByRecordedAccount(managed).count
        let selected = profiles.first { $0.id == selectedProfileID }
        selectedProfile = selected
        if let selected, !selected.isSystemProfile {
            focusedProfile = selected
        } else if let selected {
            focusedProfile =
                managed.first { $0.recordedAccountKey == selected.recordedAccountKey }
                ?? (selected.isSystemProfile && selected.lastSnapshot == nil ? managed.first : nil)
                ?? selected
        } else {
            focusedProfile = managed.first ?? profiles.first
        }
    }

    func quotaSummary(monitored: UsageSnapshot) -> (fiveHour: RateWindow?, sevenDay: RateWindow?, readSucceeded: Bool) {
        guard usesFocusedQuota, let profile = quotaProfile else {
            return (
                QuotaAvailabilityPresentation.fiveHourWindow(monitored.fiveHourQuota, sevenDay: monitored.sevenDayQuota),
                monitored.sevenDayQuota, monitored.quotaReadSucceeded
            )
        }
        func window(_ snapshot: CodexQuotaWindowSnapshot?) -> RateWindow? {
            snapshot.map { RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt) }
        }
        return (
            QuotaAvailabilityPresentation.fiveHourWindow(window(profile.lastSnapshot?.fiveHour), sevenDay: window(profile.lastSnapshot?.sevenDay)),
            window(profile.lastSnapshot?.sevenDay),
            profile.lastSnapshot != nil && profile.lastQuotaReadFailureAt == nil
        )
    }

    static func selfTest() -> Bool {
        func profile(
            _ id: String, system: Bool = false, email: String? = nil,
            fetchedAt: Date = Date(timeIntervalSince1970: 0), lastFailureAt: Date? = nil
        ) -> CodexProfile {
            CodexProfile(
                id: id, name: id, codexHomePath: "/preview/\(id)", isSystemProfile: system,
                createdAt: Date(timeIntervalSince1970: 0),
                lastSnapshot: email.map {
                    CodexAccountSnapshot(
                        accountType: "chatgpt", planType: "plus", email: $0, limitId: nil,
                        limitName: nil, fiveHour: nil, sevenDay: nil, monthly: nil,
                        fetchedAt: fetchedAt, appServerVersion: nil
                    )
                },
                lastQuotaReadFailureAt: lastFailureAt
            )
        }
        let system = profile("system", system: true)
        let managed = profile("managed", email: "demo@example.invalid")
        let sameSystem = profile("system", system: true, email: "DEMO@example.invalid")
        let duplicate = profile("duplicate", email: "demo@example.invalid")
        let other = profile("other", email: "other@example.invalid")
        let empty = Self(profiles: [], selectedProfileID: nil)
        let systemOnly = Self(profiles: [system], selectedProfileID: "system")
        let single = Self(profiles: [system, managed], selectedProfileID: "system")
        let duplicates = Self(profiles: [sameSystem, managed, duplicate], selectedProfileID: "system")
        let selectedDuplicate = Self(profiles: [sameSystem, managed, duplicate], selectedProfileID: "duplicate")
        let multi = Self(profiles: [sameSystem, managed, other], selectedProfileID: "other")
        let unknown = Self(profiles: [system, profile("a"), profile("b")], selectedProfileID: nil)
        let now = Date(timeIntervalSince1970: 100_000)
        let freshSystem = profile("system", system: true, email: "demo@example.invalid", fetchedAt: now)
        let failedManaged = profile(
            "managed", email: "demo@example.invalid", fetchedAt: now.addingTimeInterval(-3_600), lastFailureAt: now
        )
        let monitoredSystem = Self(profiles: [freshSystem, failedManaged], selectedProfileID: "system")
        let monitoredManaged = Self(profiles: [freshSystem, failedManaged], selectedProfileID: "managed")
        let freshQuota = UsageSnapshot(
            refreshedAt: now, account: nil, limitId: nil, limitName: nil, quotaReadSucceeded: true,
            fiveHourQuota: RateWindow(usedPercent: 17, windowDurationMins: 300, resetsAt: nil),
            sevenDayQuota: nil, monthlyQuota: nil, credits: nil, cloudLifetimeTokens: nil,
            local: nil, taskBoard: nil, messages: []
        )
        func health(_ presentation: Self) -> AccountSnapshotHealth {
            AccountSnapshotHealth.classify(
                snapshotAt: presentation.quotaProfile?.lastSnapshot?.fetchedAt,
                lastFailureAt: presentation.quotaProfile?.lastQuotaReadFailureAt,
                now: now
            )
        }
        guard empty.isSingleAccount, empty.focusedProfile == nil,
            empty.quotaProfile == nil,
            systemOnly.isSingleAccount, systemOnly.managedAccountCount == 0,
            single.accountCount == 1, single.focusedProfile?.id == "managed",
            single.quotaProfile?.id == "managed",
            duplicates.accountCount == 1, duplicates.managedAccountCount == 1,
            duplicates.focusedProfile?.id == "managed",
            selectedDuplicate.focusedProfile?.id == "duplicate",
            selectedDuplicate.quotaProfile?.id == "duplicate",
            multi.accountCount == 2, multi.focusedProfile?.id == "other",
            multi.quotaProfile?.id == "other",
            monitoredSystem.focusedProfile?.id == "managed",
            monitoredSystem.quotaProfile?.id == "system", health(monitoredSystem) == .current,
            monitoredSystem.quotaSummary(monitored: freshQuota).readSucceeded,
            monitoredSystem.quotaSummary(monitored: freshQuota).fiveHour?.usedPercent == 17,
            monitoredManaged.quotaProfile?.id == "managed", health(monitoredManaged) == .failed,
            single.quotaSummary(monitored: .empty).readSucceeded,
            !systemOnly.quotaSummary(monitored: .empty).readSucceeded,
            AccountSnapshotHealth.selfTest(),
            QuotaAvailabilityPresentation.selfTest(),
            !unknown.isSingleAccount
        else {
            print("workspace presentation self-test failed")
            return false
        }
        print("workspace presentation self-test passed")
        return true
    }
}

enum AccountSnapshotHealth: Equatable {
    case current, missing, failed, stale

    static func classify(snapshotAt: Date?, lastFailureAt: Date?, now: Date = Date()) -> Self {
        if let lastFailureAt, lastFailureAt >= (snapshotAt ?? .distantPast) { return .failed }
        guard let snapshotAt else { return .missing }
        return (-30...1_800).contains(now.timeIntervalSince(snapshotAt)) ? .current : .stale
    }

    var notice: String? {
        notice(.zh)
    }

    func notice(_ language: WidgetLanguage) -> String? {
        switch self {
        case .current: return nil
        case .missing: return language.text("等待额度", "Waiting for limits")
        case .failed: return language.text("刷新失败", "Refresh failed")
        case .stale: return language.text("快照过期", "Stale snapshot")
        }
    }

    func updatedLabel(snapshotAt: Date?, now: Date, language: WidgetLanguage) -> String {
        guard let snapshotAt else {
            return self == .failed
                ? language.text("读取失败 · 尚无额度快照", "Refresh failed · no quota snapshot")
                : language.text("尚无额度快照", "No quota snapshot")
        }
        let age = now.timeIntervalSince(snapshotAt)
        guard age.isFinite, age >= -30, let minutes = Int(exactly: floor(max(0, age) / 60)) else {
            return language.text("快照时间异常 · 请刷新", "Invalid snapshot time · refresh")
        }
        let elapsed: String
        if minutes == 0 {
            elapsed = language.text("刚刚", "just now")
        } else if minutes < 60 {
            elapsed = language.text("\(minutes) 分钟前", "\(minutes)m ago")
        } else if minutes < 24 * 60 {
            elapsed = language.text("\(minutes / 60) 小时前", "\(minutes / 60)h ago")
        } else {
            elapsed = language.text("\(minutes / (24 * 60)) 天前", "\(minutes / (24 * 60))d ago")
        }
        switch self {
        case .current: return language.text("额度更新 · ", "Quota updated · ") + elapsed
        case .failed: return language.text("刷新失败 · 上次快照 ", "Refresh failed · snapshot ") + elapsed
        case .stale: return language.text("上次快照 ", "Snapshot ") + elapsed + language.text(" · 请刷新", " · refresh")
        case .missing: return language.text("尚无额度快照", "No quota snapshot")
        }
    }

    static func selfTest() -> Bool {
        let now = Date(timeIntervalSince1970: 100_000)
        return classify(snapshotAt: nil, lastFailureAt: nil, now: now) == .missing
            && classify(snapshotAt: now, lastFailureAt: nil, now: now) == .current
            && classify(snapshotAt: now.addingTimeInterval(-1_801), lastFailureAt: nil, now: now) == .stale
            && classify(snapshotAt: now.addingTimeInterval(31), lastFailureAt: nil, now: now) == .stale
            && classify(snapshotAt: now.addingTimeInterval(-10), lastFailureAt: now, now: now) == .failed
            && classify(snapshotAt: now, lastFailureAt: now.addingTimeInterval(-10), now: now) == .current
            && Self.current.updatedLabel(snapshotAt: now.addingTimeInterval(-120), now: now, language: .zh) == "额度更新 · 2 分钟前"
            && Self.stale.updatedLabel(snapshotAt: now.addingTimeInterval(-3_600), now: now, language: .en) == "Snapshot 1h ago · refresh"
            && Self.failed.updatedLabel(snapshotAt: nil, now: now, language: .zh) == "读取失败 · 尚无额度快照"
            && Self.stale.updatedLabel(snapshotAt: now.addingTimeInterval(31), now: now, language: .zh) == "快照时间异常 · 请刷新"
            && Self.stale.updatedLabel(snapshotAt: Date(timeIntervalSince1970: -.greatestFiniteMagnitude), now: now, language: .en) == "Invalid snapshot time · refresh"
    }
}
