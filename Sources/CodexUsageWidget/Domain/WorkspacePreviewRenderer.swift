import AppKit
import SwiftUI

/// Render the production SwiftUI views at 2x using synthetic accounts only.
enum WorkspacePreviewRenderer {
    private struct FixtureState: Encodable {
        let schemaVersion = 1
        let profiles: [CodexProfile]
        let selectedMonitorProfileID: String
        let selectedLaunchProfileID: String
        let resetBackfillCheckedAt: Date
    }

    private struct AcceptanceFixtures {
        let codex: UsageStore
        let localCLI: LocalCLIAccountStore
    }

    static func fixtureStore(accountCount: Int, root: URL, language: WidgetLanguage = .zh, includeQuotaEdgeCases: Bool = false) -> UsageStore {
        let now = Date()
        let fiveHour = RateWindow(usedPercent: 18, windowDurationMins: 300, resetsAt: now.addingTimeInterval(10_800))
        let sevenDay = RateWindow(usedPercent: 37, windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(259_200))
        let profiles = (0..<max(accountCount, 1)).map { index in
            let isPro = includeQuotaEdgeCases && index == 0
            let weeklyExhausted = includeQuotaEdgeCases && (index == 1 || index == 2)
            let profileFiveHour = includeQuotaEdgeCases && (index == 0 || index == 2) ? nil : CodexQuotaWindowSnapshot(fiveHour)
            let profileSevenDay = CodexQuotaWindowSnapshot(
                RateWindow(
                    usedPercent: weeklyExhausted ? 100 : isPro ? 17 : sevenDay.usedPercent,
                    windowDurationMins: 10_080,
                    resetsAt: includeQuotaEdgeCases ? now.addingTimeInterval(weeklyExhausted ? 172_800 : 432_000) : sevenDay.resetsAt
                ))
            return CodexProfile(
                id: accountCount == 0 ? "system" : "preview-\(index)",
                name: accountCount == 0 ? language.text("当前 Codex", "Current Codex") : language.text("合成账号 \(index + 1)", "Demo account \(index + 1)"),
                remark: accountCount == 0
                    ? language.text("当前 Codex", "Current Codex")
                    : includeQuotaEdgeCases
                        ? language.text("演示账号 \(index + 1)", "Demo account \(index + 1)")
                        : language.text("合成账号 \(index + 1) · 用于验证窄窗长备注省略时不溢出操作区", "Demo account \(index + 1) · A long label for narrow-window layout checks"),
                codexHomePath: root.appendingPathComponent(
                    accountCount == 0 ? "home/.codex" : "home/.codex-account-manager-next/profiles/preview-\(index)"
                ).path,
                isSystemProfile: accountCount == 0, createdAt: now,
                lastSnapshot: CodexAccountSnapshot(
                    accountType: "chatgpt", planType: isPro ? "pro" : "plus", email: nil,
                    accountID: "synthetic-preview-account-\(index)",
                    limitId: "codex", limitName: "Codex", fiveHour: profileFiveHour,
                    sevenDay: profileSevenDay, monthly: nil,
                    availableResetCredits: 2, resetCreditExpiries: [now.addingTimeInterval(864_000)],
                    fetchedAt: now, appServerVersion: nil
                ),
                officialProfile: CodexOfficialProfileSnapshot(
                    accountEmail: nil, displayName: nil, username: nil,
                    lifetimeTokens: 82_400_000, peakDailyTokens: nil, planType: isPro ? "pro" : "plus",
                    subscriptionActiveUntil: now.addingTimeInterval(1_814_400), statsAsOf: now, fetchedAt: now
                ),
                proTierMultiplier: isPro ? 20 : nil,
                executionPreference: accountCount == 0 ? nil : .defaultValue
            )
        }
        // Seed the real persistence path in the fixture sandbox, so drag/drop tests
        // exercise the same reorder/save/reload operation as the production app.
        let support = root.appendingPathComponent("support").appendingPathComponent(DispatchParticipationPaths.supportDirectoryName)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let selectedID = profiles[0].id
            let state = FixtureState(
                profiles: profiles, selectedMonitorProfileID: selectedID, selectedLaunchProfileID: selectedID, resetBackfillCheckedAt: now
            )
            try JSONEncoder().encode(state).write(to: support.appendingPathComponent(DispatchParticipationPaths.snapshotFileName), options: .atomic)
        } catch {
            preconditionFailure("Could not create isolated workspace fixtures")
        }
        return UsageStore(
            previewProfiles: profiles,
            snapshot: UsageSnapshot(
                refreshedAt: now, account: AccountInfo(type: "chatgpt", planType: profiles[0].lastSnapshot?.planType, emailPresent: false),
                limitId: "codex", limitName: "Codex", quotaReadSucceeded: true,
                fiveHourQuota: profiles[0].lastSnapshot?.fiveHour.map {
                    RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt)
                },
                sevenDayQuota: profiles[0].lastSnapshot?.sevenDay.map {
                    RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt)
                }, monthlyQuota: nil,
                credits: CreditsInfo(
                    hasCredits: false, unlimited: false, balance: nil, resetCredits: 2,
                    resetCreditDetails: [ResetCreditDetail(id: "demo-reset", expiresAt: now.addingTimeInterval(864_000))]),
                cloudLifetimeTokens: 82_400_000, local: nil, taskBoard: nil, messages: []
            ),
            isolatedRoot: root
        )
    }

    /// A compact cross-provider matrix that follows each production adapter's
    /// actual evidence contract. In particular, Grok reset-card data remains
    /// unknown, OpenCode uses only its Go quota windows, and WorkBuddy remains
    /// unsupported because no official quota interface has been confirmed.
    @MainActor private static func acceptanceFixtures(root: URL, language: WidgetLanguage) -> AcceptanceFixtures {
        let now = Date()
        func window(usedPercent: Double, minutes: Int, resetOffset: TimeInterval) -> CodexQuotaWindowSnapshot {
            CodexQuotaWindowSnapshot(
                RateWindow(
                    usedPercent: usedPercent,
                    windowDurationMins: minutes,
                    resetsAt: now.addingTimeInterval(resetOffset)))
        }
        func codexProfile(
            id: String,
            name: String,
            fiveHour: CodexQuotaWindowSnapshot?,
            sevenDay: CodexQuotaWindowSnapshot?,
            resetCredits: Int?,
            resetExpiries: [Date]?,
            quotaReadSucceeded: Bool
        ) -> CodexProfile {
            CodexProfile(
                id: id,
                name: name,
                remark: name,
                codexHomePath: root.appendingPathComponent("home/.codex-account-manager-next/profiles/\(id)").path,
                isSystemProfile: false,
                createdAt: now,
                lastSnapshot: CodexAccountSnapshot(
                    accountType: "chatgpt",
                    planType: "plus",
                    email: nil,
                    accountID: "synthetic-\(id)",
                    limitId: "codex",
                    limitName: "Codex",
                    fiveHour: fiveHour,
                    sevenDay: sevenDay,
                    monthly: nil,
                    availableResetCredits: resetCredits,
                    resetCreditExpiries: resetExpiries,
                    fetchedAt: now,
                    appServerVersion: nil,
                    quotaReadSucceeded: quotaReadSucceeded),
                officialProfile: CodexOfficialProfileSnapshot(
                    accountEmail: nil,
                    displayName: nil,
                    username: nil,
                    lifetimeTokens: 12_345_678,
                    peakDailyTokens: nil,
                    planType: "plus",
                    subscriptionActiveUntil: now.addingTimeInterval(21 * 86_400),
                    statsAsOf: now,
                    fetchedAt: now),
                executionPreference: .defaultValue)
        }

        var codexUnknown = codexProfile(
            id: "acceptance-codex-short",
            name: language.text("合成 Codex A", "Synthetic Codex A"),
            fiveHour: nil,
            sevenDay: nil,
            resetCredits: nil,
            resetExpiries: nil,
            quotaReadSucceeded: false)
        // Absence of a snapshot is the production representation for an account
        // whose quota and reset-credit evidence are both still unknown.
        codexUnknown.lastSnapshot = nil
        var codexProfiles = [
            codexUnknown,
            codexProfile(
                id: "acceptance-codex-long",
                name: language.text("很长的 Codex 预览账号名称用于检查省略与列对齐", "A very long Codex preview account name for truncation"),
                fiveHour: window(usedPercent: 100, minutes: 300, resetOffset: 3_600),
                sevenDay: window(usedPercent: 40, minutes: 10_080, resetOffset: 4 * 86_400),
                resetCredits: 2,
                resetExpiries: [now.addingTimeInterval(8 * 86_400)],
                quotaReadSucceeded: true),
            codexProfile(
                id: "acceptance-codex-expiring",
                name: language.text("到期预览", "Expiry preview"),
                fiveHour: window(usedPercent: 0, minutes: 300, resetOffset: 10_800),
                sevenDay: window(usedPercent: 0, minutes: 10_080, resetOffset: 6 * 86_400),
                resetCredits: 1,
                resetExpiries: [now.addingTimeInterval(24 * 3_600)],
                quotaReadSucceeded: true),
        ]
        for position in 4...8 {
            codexProfiles.append(
                codexProfile(
                    id: "acceptance-codex-\(position)",
                    name: language.text("演示账号 \(position)", "Demo account \(position)"),
                    fiveHour: window(usedPercent: Double(position * 9), minutes: 300, resetOffset: 7_200),
                    sevenDay: window(usedPercent: Double(position * 7), minutes: 10_080, resetOffset: 5 * 86_400),
                    resetCredits: 0,
                    resetExpiries: [],
                    quotaReadSucceeded: true))
        }

        do {
            let support = root.appendingPathComponent("support").appendingPathComponent(DispatchParticipationPaths.supportDirectoryName)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let state = FixtureState(
                profiles: codexProfiles,
                selectedMonitorProfileID: codexProfiles[0].id,
                selectedLaunchProfileID: codexProfiles[0].id,
                resetBackfillCheckedAt: now)
            try JSONEncoder().encode(state).write(
                to: support.appendingPathComponent(DispatchParticipationPaths.snapshotFileName),
                options: .atomic)
        } catch {
            preconditionFailure("Could not create isolated acceptance fixtures")
        }

        let selected = codexProfiles[0].lastSnapshot
        let codexStore = UsageStore(
            previewProfiles: codexProfiles,
            snapshot: UsageSnapshot(
                refreshedAt: now,
                account: AccountInfo(type: "chatgpt", planType: selected?.planType, emailPresent: false),
                limitId: "codex",
                limitName: "Codex",
                quotaReadSucceeded: selected?.quotaReadSucceeded == true,
                fiveHourQuota: selected?.fiveHour.map {
                    RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt)
                },
                sevenDayQuota: selected?.sevenDay.map {
                    RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt)
                },
                monthlyQuota: nil,
                credits: CreditsInfo(
                    hasCredits: false,
                    unlimited: false,
                    balance: nil,
                    resetCredits: selected?.availableResetCredits,
                    resetCreditDetails: selected?.resetCreditExpiries?.enumerated().map {
                        ResetCreditDetail(id: "acceptance-reset-\($0.offset)", expiresAt: $0.element)
                    }),
                cloudLifetimeTokens: 12_345_678,
                local: nil,
                taskBoard: nil,
                messages: []),
            isolatedRoot: root)

        func localProfile(_ id: String, kind: LocalCLIKind, name: String) -> LocalCLIProfile {
            LocalCLIProfile(
                id: id,
                kind: kind,
                displayName: name,
                configDirectory: root.appendingPathComponent("local-cli/\(id)").path,
                isDefault: id.hasSuffix("short"))
        }
        func quota(
            state: LocalCLIQuotaState,
            identity: String?,
            plan: String?,
            windows: [LocalCLIQuotaWindow],
            source: String,
            messageCode: String? = nil
        ) -> LocalCLIQuotaResult {
            LocalCLIQuotaResult(
                state: state,
                fetchedAt: now,
                maskedIdentity: identity,
                identityFingerprint: nil,
                planLabel: plan,
                windows: windows,
                balance: nil,
                balanceCurrency: nil,
                sourceLabel: source,
                messageCode: messageCode,
                resetCards: nil)
        }

        let grokShort = localProfile("acceptance-grok-short", kind: .grok, name: "G preview")
        let grokLong = localProfile(
            "acceptance-grok-long",
            kind: .grok,
            name: language.text("很长的 Grok 预览账号名称用于检查省略", "A very long Grok preview account name for truncation"))
        let openCodeShort = localProfile("acceptance-opencode-short", kind: .openCode, name: "O preview")
        let openCodeLong = localProfile(
            "acceptance-opencode-long",
            kind: .openCode,
            name: language.text("很长的 OpenCode 预览账号名称用于检查省略", "A very long OpenCode preview account name for truncation"))
        let workBuddyShort = localProfile("acceptance-workbuddy-short", kind: .workBuddy, name: "W preview")
        let workBuddyLong = localProfile(
            "acceptance-workbuddy-long",
            kind: .workBuddy,
            name: language.text("很长的 WorkBuddy 预览账号名称用于检查省略", "A very long WorkBuddy preview account name for truncation"))
        let localProfiles = [grokShort, grokLong, openCodeShort, openCodeLong, workBuddyShort, workBuddyLong]
        let localQuotas: [String: LocalCLIQuotaResult] = [
            grokShort.id: quota(
                state: .available,
                identity: "g***@example.invalid",
                plan: "Synthetic preview",
                windows: [
                    LocalCLIQuotaWindow(
                        id: "credits",
                        label: "Credits",
                        usedPercent: 100,
                        resetsAt: now.addingTimeInterval(2 * 86_400))
                ],
                source: "Grok CLI billing"),
            grokLong.id: quota(
                state: .available,
                identity: "l***@example.invalid",
                plan: "Synthetic preview",
                windows: [
                    LocalCLIQuotaWindow(
                        id: "credits",
                        label: "Credits",
                        usedPercent: 0,
                        resetsAt: now.addingTimeInterval(6 * 86_400))
                ],
                source: "Grok CLI billing"),
            openCodeShort.id: quota(
                state: .available,
                identity: "o***@example.invalid",
                plan: "OpenCode Go",
                windows: [
                    LocalCLIQuotaWindow(
                        id: "rolling",
                        label: "Rolling",
                        usedPercent: 100,
                        resetsAt: now.addingTimeInterval(7_200)),
                    LocalCLIQuotaWindow(
                        id: "weekly",
                        label: "7-day",
                        usedPercent: 0,
                        resetsAt: now.addingTimeInterval(5 * 86_400)),
                    LocalCLIQuotaWindow(
                        id: "monthly",
                        label: "Monthly",
                        usedPercent: 63,
                        resetsAt: now.addingTimeInterval(18 * 86_400)),
                ],
                source: "OpenCode Go API"),
            openCodeLong.id: quota(
                state: .unsupported,
                identity: nil,
                plan: nil,
                windows: [],
                source: "OpenCode Go API",
                messageCode: "local_cli_opencode_go_not_connected"),
            workBuddyShort.id: quota(
                state: .unsupported,
                identity: nil,
                plan: nil,
                windows: [],
                source: "WorkBuddy CLI",
                messageCode: "local_cli_unsupported"),
            workBuddyLong.id: quota(
                state: .unsupported,
                identity: nil,
                plan: nil,
                windows: [],
                source: "WorkBuddy CLI",
                messageCode: "local_cli_unsupported"),
        ]
        return AcceptanceFixtures(
            codex: codexStore,
            localCLI: LocalCLIAccountStore.preview(profiles: localProfiles, quotas: localQuotas, root: root))
    }

    @MainActor static func render(to directory: URL, language: WidgetLanguage = .zh) -> Bool {
        if CommandLine.arguments.contains("--preview-design-home-only") {
            return renderDesignHome(to: directory)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-ui-preview-\(UUID().uuidString)")
        let suiteName = "CodexManagerNext.workspace-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(
                defaults: defaults, paletteCatalog: catalog,
                previewAvatarRoot: root.appendingPathComponent("avatars"))
            settings.language = language
            settings.agentNavigation = AgentNavigationState(
                initialized: true, customized: true,
                orderedVisibleProviderIDs: [
                    AgentNavCatalog.codexID, LocalCLIKind.kimi.rawValue, LocalCLIKind.workBuddy.rawValue,
                    LocalCLIKind.trae.rawValue, LocalCLIKind.openCode.rawValue, LocalCLIKind.grok.rawValue,
                    LocalCLIKind.gemini.rawValue, LocalCLIKind.mimo.rawValue,
                    LocalCLIKind.claudeCode.rawValue, LocalCLIKind.zcode.rawValue,
                ])
            for scheme in [ColorScheme.dark, .light] {
                settings.themeMode = scheme == .dark ? .dark : .light
                let theme = scheme == .dark ? "dark" : "light"
                let tokens = catalog.resolve(id: settings.paletteID, appearance: scheme == .dark ? .dark : .light)
                for count in [0, 1, 3] {
                    let name = count == 0 ? "single-system" : count == 1 ? "single-account" : "multi-account"
                    let store = fixtureStore(accountCount: count, root: root.appendingPathComponent("\(theme)-\(count)"), language: language)
                    for width: CGFloat in [820, 980, 1280] {
                        let size = CGSize(width: width, height: 760)
                        let view = CodexAccountManagerView(store: store, settings: settings, paletteCatalog: catalog)
                            .frame(width: size.width, height: size.height)
                            .environment(\.colorScheme, scheme)
                        try renderView(view, size: size, scheme: scheme, to: directory.appendingPathComponent("\(name)-\(theme)-\(Int(width)).png"))
                    }
                    if count == 3 {
                        let view = CodexAccountManagerView(store: store, settings: settings, paletteCatalog: catalog)
                        let capture = try WorkspaceScreenshotExporter.render(view.screenshotContent, width: 980, scheme: scheme)
                        try capture.png.write(to: directory.appendingPathComponent("workspace-long-\(theme).png"), options: .atomic)
                    }
                    if count < 2 {
                        let updateStore = AppUpdateStore(settings: settings)
                        let menu = CodexAccountMenuView(
                            store: store, settings: settings, updateStore: updateStore, paletteCatalog: catalog,
                            openFullWindow: {}, openPaletteLibrary: {}, quit: {}
                        )
                        try renderView(menu, size: CodexAccountMenuView.preferredSize, scheme: scheme, to: directory.appendingPathComponent("\(name)-menu-\(theme).png"))
                    }
                }
                let nineAccountStore = fixtureStore(
                    accountCount: 9,
                    root: root.appendingPathComponent("\(theme)-9"), language: language,
                    includeQuotaEdgeCases: true
                )
                let nineAccountView = CodexAccountManagerView(
                    store: nineAccountStore,
                    settings: settings,
                    paletteCatalog: catalog
                )
                let nineAccountCapture = try WorkspaceScreenshotExporter.render(
                    nineAccountView.screenshotContent,
                    width: 980,
                    scheme: scheme
                )
                try nineAccountCapture.png.write(
                    to: directory.appendingPathComponent("workspace-nine-\(theme).png"),
                    options: .atomic
                )
                for size in [CGSize(width: 820, height: 600), CGSize(width: 980, height: 700), CGSize(width: 1280, height: 900)] {
                    try renderView(
                        nineAccountView.frame(width: size.width, height: size.height),
                        size: size,
                        scheme: scheme,
                        to: directory.appendingPathComponent("nine-accounts-\(theme)-\(Int(size.width))x\(Int(size.height)).png")
                    )
                }
                settings.accountWorkspaceLayout = .cards
                let cardCapture = try WorkspaceScreenshotExporter.render(nineAccountView.screenshotContent, width: 980, scheme: scheme)
                try cardCapture.png.write(to: directory.appendingPathComponent("workspace-nine-cards-\(theme).png"), options: .atomic)
                for size in [CGSize(width: 820, height: 600), CGSize(width: 980, height: 700), CGSize(width: 1280, height: 900)] {
                    try renderView(
                        nineAccountView.frame(width: size.width, height: size.height),
                        size: size,
                        scheme: scheme,
                        to: directory.appendingPathComponent("nine-cards-\(theme)-\(Int(size.width))x\(Int(size.height)).png")
                    )
                }
                settings.accountWorkspaceLayout = .rows
                let statusExample = Text(
                    WarmUpStatusText.attributed(language.text("5 小时已暂停 · 7 天额度不足 · 下次暖号 7 天 9月10日 09:30", "5h warm-up paused · weekly limit low · Next 7d warm-up Sep 10, 09:30"))
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(FixedVisualPalette.windowScrim(scheme, reduceTransparency: true))
                .environment(\.colorScheme, scheme)
                try renderView(statusExample, size: CGSize(width: 520, height: 56), scheme: scheme, to: directory.appendingPathComponent("warmup-status-\(theme).png"))
                let toolbar = TitlebarToolbarView(settings: settings, onOpenSettings: {}, onSaveScreenshot: {}, onOpenGuide: {})
                    .background(FixedVisualPalette.windowScrim(scheme))
                try renderView(toolbar, size: CGSize(width: 320, height: 44), scheme: scheme, to: directory.appendingPathComponent("toolbar-\(theme).png"))
                let editor = ExecutionPreferenceControl(
                    preference: .init(model: .astra, reasoningEffort: .max, serviceTier: .standard),
                    inlineEditor: true, onSave: { _, _ in .success(()) }
                )
                .environment(\.widgetLanguage, language)
                .environment(\.locale, language.locale)
                .environment(\.visualTokens, tokens)
                .environment(\.colorScheme, scheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FixedVisualPalette.windowScrim(scheme, reduceTransparency: true))
                try renderView(editor, size: CGSize(width: 400, height: 470), scheme: scheme, to: directory.appendingPathComponent("astra-model-\(theme).png"))

                let previousDisplayMode = settings.workspaceDisplayMode
                settings.workspaceDisplayMode = .professional
                for count in [1, 3] {
                    let name = count == 1 ? "professional-codex-single" : "professional-codex-multi"
                    let store = fixtureStore(
                        accountCount: count,
                        root: root.appendingPathComponent("\(theme)-pro-codex-\(count)"),
                        language: language
                    )
                    let view = CodexAccountManagerView(
                        store: store,
                        settings: settings,
                        paletteCatalog: catalog,
                        previewOpenCodexWorkspace: true
                    )
                    for width: CGFloat in [820, 980] {
                        try renderView(
                            view.frame(width: width, height: 760)
                                .environment(\.colorScheme, scheme),
                            size: CGSize(width: width, height: 760),
                            scheme: scheme,
                            to: directory.appendingPathComponent("\(name)-\(theme)-\(Int(width)).png")
                        )
                    }
                }
                settings.workspaceDisplayMode = previousDisplayMode

                let announcedStore = fixtureStore(
                    accountCount: 3,
                    root: root.appendingPathComponent("\(theme)-announced"),
                    language: language
                )
                let announcementID = "1234567890123456789"
                announcedStore.publicResetAnnouncements.seedPreviewLatest(
                    PublicResetAnnouncement(
                        id: announcementID,
                        resetType: .regular,
                        announcedAt: Date().addingTimeInterval(-7_200),
                        text: "Synthetic public reset window notice for layout preview.",
                        source: .init(
                            type: "x_post",
                            author: "thsottiaux",
                            url: URL(string: "https://x.com/thsottiaux/status/\(announcementID)")
                        )
                    ),
                    checkedAt: Date()
                )
                try renderView(
                    CodexAccountManagerView(store: announcedStore, settings: settings, paletteCatalog: catalog)
                        .frame(width: 980, height: 760),
                    size: CGSize(width: 980, height: 760),
                    scheme: scheme,
                    to: directory.appendingPathComponent("reset-banner-announced-\(theme).png")
                )
                try renderView(
                    CodexAccountManagerView(store: announcedStore, settings: settings, paletteCatalog: catalog)
                        .frame(width: 820, height: 760),
                    size: CGSize(width: 820, height: 760),
                    scheme: scheme,
                    to: directory.appendingPathComponent("reset-banner-announced-\(theme)-820.png")
                )

                // Cross-provider placement uses only labeled synthetic data.
                let fixtureRoot = root.appendingPathComponent("unified-\(theme)")
                let codex = fixtureStore(accountCount: 3, root: fixtureRoot, language: language, includeQuotaEdgeCases: true)
                let grok = LocalCLIProfile(
                    id: "fixture-grok", kind: .grok,
                    displayName: language.text("合成 Grok 账号", "Synthetic Grok account"),
                    configDirectory: fixtureRoot.path, isDefault: true)
                let providerNow = Date()
                let quota = LocalCLIQuotaResult(
                    state: .available, fetchedAt: providerNow, maskedIdentity: nil,
                    identityFingerprint: nil, planLabel: "Synthetic fixture",
                    windows: [
                        LocalCLIQuotaWindow(
                            id: "fixture-week",
                            label: language.text("每周", "Weekly"), usedPercent: 25, resetsAt: providerNow.addingTimeInterval(360000))
                    ],
                    balance: nil, balanceCurrency: nil, sourceLabel: language.text("合成数据", "Synthetic data"), messageCode: nil,
                    resetCards: nil)
                let local = LocalCLIAccountStore.preview(profiles: [grok], quotas: [grok.id: quota], root: fixtureRoot)
                settings.pinnedAccountKey = ResetCardPresentation.codexKey("preview-0")
                for layout in [AccountWorkspaceLayout.rows, .cards] {
                    settings.accountWorkspaceLayout = layout
                    let unified = CodexAccountManagerView(store: codex, settings: settings, paletteCatalog: catalog, localCLIAccounts: local)
                    try renderView(
                        unified, size: CGSize(width: 980, height: 1000), scheme: scheme,
                        to: directory.appendingPathComponent("unified-reset-fixture-\(layout.rawValue)-\(theme).png"))
                }
                settings.pinnedAccountKey = nil
                settings.accountWorkspaceLayout = .rows

                let acceptanceRoot = root.appendingPathComponent("acceptance-\(theme)")
                let acceptance = acceptanceFixtures(root: acceptanceRoot, language: language)
                settings.workspaceDisplayMode = .simple
                settings.simpleWorkspacePreset = .accountCards
                settings.pinnedAccountKey = nil
                for layout in [AccountWorkspaceLayout.rows, .cards] {
                    settings.accountWorkspaceLayout = layout
                    let matrix = CodexAccountManagerView(
                        store: acceptance.codex,
                        settings: settings,
                        paletteCatalog: catalog,
                        localCLIAccounts: acceptance.localCLI)
                    let narrowSize = CGSize(width: 720, height: 900)
                    try renderView(
                        matrix.frame(width: narrowSize.width, height: narrowSize.height),
                        size: narrowSize,
                        scheme: scheme,
                        to: directory.appendingPathComponent(
                            "acceptance-matrix-\(layout.rawValue)-\(theme)-720x900.png"))
                    let fullCapture = try WorkspaceScreenshotExporter.render(
                        matrix.screenshotContent,
                        width: 980,
                        scheme: scheme)
                    try fullCapture.png.write(
                        to: directory.appendingPathComponent(
                            "acceptance-matrix-\(layout.rawValue)-\(theme)-full.png"),
                        options: .atomic)
                    let wideCapture = try WorkspaceScreenshotExporter.render(
                        matrix.screenshotContent, width: 1280, scheme: scheme)
                    try wideCapture.png.write(
                        to: directory.appendingPathComponent(
                            "acceptance-matrix-\(layout.rawValue)-\(theme)-wide.png"),
                        options: .atomic)
                }

                for kind in [LocalCLIKind.grok, .openCode, .workBuddy] {
                    let provider = LocalCLIWorkspaceView(
                        model: acceptance.localCLI,
                        settings: settings,
                        kind: kind,
                        language: language
                    )
                    .padding(24)
                    .environment(\.widgetLanguage, language)
                    .environment(\.locale, language.locale)
                    .environment(\.visualTokens, tokens)
                    .environment(\.colorScheme, scheme)
                    .background(FixedVisualPalette.windowScrim(scheme, reduceTransparency: true))
                    try renderView(
                        provider,
                        size: CGSize(width: 760, height: 640),
                        scheme: scheme,
                        to: directory.appendingPathComponent(
                            "acceptance-provider-\(kind.rawValue)-\(theme)-760x640.png"))
                }
            }
            return true
        } catch {
            print("workspace preview render failed")
            return false
        }
    }

    /// A quick, focused visual check of the approved eight-account home design.
    /// Invoke through the existing --render-workspace-previews entry point with
    /// --preview-design-home-only; the full acceptance matrix remains unchanged.
    @MainActor static func renderDesignHome(to directory: URL) -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aigoodbro-design-home-\(UUID().uuidString)")
        let suite = "AiGoodBro.design-home-render.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(
                defaults: defaults, paletteCatalog: catalog,
                previewAvatarRoot: root.appendingPathComponent("avatars"))
            DesignHomePreviewFixture.configure(settings)
            let store = DesignHomePreviewFixture.makeStore(root: root)
            let local = DesignHomePreviewFixture.makeLocalCLIStore(root: root)
            let referenceDate = DesignHomePreviewFixture.referenceDate
            let forecastBy = referenceDate.addingTimeInterval(12 * 3_600)
            func renderViewport(
                layout: AccountWorkspaceLayout, scheme: ColorScheme,
                width: CGFloat, reduceTransparency: Bool = false,
                filename: String
            ) throws {
                settings.accountWorkspaceLayout = layout
                settings.themeMode = scheme == .dark ? .dark : .light
                let viewport = CodexAccountManagerView(
                    store: store, settings: settings,
                    paletteCatalog: catalog, localCLIAccounts: local,
                    previewReferenceDate: referenceDate, previewForecastBy: forecastBy
                )
                .defaultAppStorage(defaults)
                .environment(\.workspacePreviewDate, referenceDate)
                .environment(\.workspacePreviewForecastDeadline, forecastBy)
                .environment(\.workspacePreviewOpaqueSurface, reduceTransparency)
                .environment(\.colorScheme, scheme)
                .frame(width: width, height: 980)
                try renderView(
                    viewport, size: CGSize(width: width, height: 980), scheme: scheme,
                    to: directory.appendingPathComponent(filename))
            }
            for layout in [AccountWorkspaceLayout.cards, .rows] {
                settings.accountWorkspaceLayout = layout
                let view = CodexAccountManagerView(
                    store: store, settings: settings,
                    paletteCatalog: catalog, localCLIAccounts: local,
                    previewReferenceDate: referenceDate, previewForecastBy: forecastBy)
                let content = view.screenshotContent
                    .defaultAppStorage(defaults)
                    .environment(\.workspacePreviewDate, referenceDate)
                    .environment(\.workspacePreviewForecastDeadline, forecastBy)
                    .environment(\.colorScheme, ColorScheme.dark)
                let capture = try WorkspaceScreenshotExporter.render(
                    content, width: 1_440, scheme: .dark)
                try capture.png.write(
                    to: directory.appendingPathComponent(
                        "home-\(layout.rawValue)-dark-liquid-keycap-1440-full.png"),
                    options: .atomic)
                try renderViewport(
                    layout: layout, scheme: .dark, width: 1_440,
                    filename: "home-\(layout.rawValue)-dark-liquid-keycap-1440-viewport.png")
            }
            try renderViewport(
                layout: .cards, scheme: .dark, width: 820,
                filename: "home-cards-dark-liquid-keycap-820-viewport.png")
            try renderViewport(
                layout: .rows, scheme: .dark, width: 820,
                filename: "home-rows-dark-liquid-keycap-820-viewport.png")
            try renderViewport(
                layout: .cards, scheme: .light, width: 1_440,
                reduceTransparency: true,
                filename: "home-cards-light-liquid-keycap-1440-reduce-transparency-viewport.png")
            let note = """
                AiGoodBro 0923v8 design review, synthetic data only.
                Shared fixture: eight named accounts from docs/ui-preview-0923v7/index.html.
                Reference clock: 2026-09-23 03:00 Asia/Shanghai.
                Production CodexAccountManagerView: full-height 1440-point cards/rows,
                1440- and 820-point dark viewports, plus a light reduced-transparency viewport.
                """
            try note.write(
                to: directory.appendingPathComponent("README.txt"),
                atomically: true, encoding: .utf8)
            return true
        } catch {
            print("design-home preview render failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor static func renderWorkbench(to directory: URL) -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-fixture-\(UUID().uuidString)")
        let suite = "AiGoodBro.workbench-fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(defaults: defaults, paletteCatalog: catalog)
            settings.language = .zh
            settings.setupProgress.dismissed = true
            settings.workspaceDisplayMode = .simple
            settings.simpleWorkspacePreset = .accountCards
            settings.accountWorkspaceLayout = .cards
            let store = fixtureStore(accountCount: 1, root: root)
            let kinds: [LocalCLIKind] = [.claudeCode, .kimi, .openCode, .grok, .zcode]
            let names = ["合成 · 待登录", "合成 · 额度未接", "合成 · 待补文件", "合成 · 任务失败", "合成 · 预约结束"]
            let profiles = kinds.enumerated().map { index, kind in
                LocalCLIProfile(
                    id: "demo-\(kind.rawValue)", kind: kind, displayName: names[index],
                    configDirectory: root.appendingPathComponent("local/\(kind.rawValue)").path, isDefault: true)
            }
            var quotas: [String: LocalCLIQuotaResult] = [:]
            for (index, profile) in profiles.enumerated() {
                quotas[profile.id] = LocalCLIQuotaResult(
                    state: index == 0 ? .needsLogin : index == 1 ? .available : .unavailable,
                    fetchedAt: Date(), maskedIdentity: nil, identityFingerprint: nil, planLabel: "演示",
                    windows: [], balance: nil, balanceCurrency: nil, sourceLabel: "合成数据",
                    messageCode: index == 2 ? "capability_report_unavailable" : index == 3 ? "task_failed" : index == 4 ? "preparing_reservation_required" : nil)
            }
            let local = LocalCLIAccountStore.preview(profiles: profiles, quotas: quotas, root: root)
            for scheme in [ColorScheme.light, .dark] {
                settings.themeMode = scheme == .dark ? .dark : .light
                let theme = scheme == .dark ? "dark" : "light"
                for width: CGFloat in [820, 980, 1280] {
                    let view = CodexAccountManagerView(store: store, settings: settings, paletteCatalog: catalog, localCLIAccounts: local)
                    try renderView(
                        view.frame(width: width, height: 900), size: CGSize(width: width, height: 900), scheme: scheme,
                        to: directory.appendingPathComponent("workbench-\(theme)-\(Int(width)).png"))
                    if width == 980 {
                        let capture = try WorkspaceScreenshotExporter.render(view.screenshotContent, width: width, scheme: scheme)
                        try capture.png.write(to: directory.appendingPathComponent("workbench-\(theme)-full.png"))
                    }
                }
                settings.homeModuleArrangement.compact = ["usage", "monitor"]
                let editing = CodexAccountManagerView(
                    store: store, settings: settings, paletteCatalog: catalog,
                    localCLIAccounts: local, previewEditingModules: true)
                try renderView(
                    editing.frame(width: 1280, height: 1000), size: CGSize(width: 1280, height: 1000), scheme: scheme,
                    to: directory.appendingPathComponent("arrange-\(theme)-1280.png"))
                // Same persisted half-width preference collapses safely at 820.
                try renderView(
                    editing.frame(width: 820, height: 1100), size: CGSize(width: 820, height: 1100), scheme: scheme,
                    to: directory.appendingPathComponent("arrange-\(theme)-820.png"))
                settings.homeModuleArrangement = .init()
                let notices = VStack(alignment: .leading, spacing: 18) {
                    Text("合成数据 · 调用准备与失败文案").font(.title2.weight(.semibold))
                    ForEach(
                        Array(
                            [
                                LocalCLIReadiness.notInstalled, .needsLogin, .quotaDisconnected,
                                .inputFailure("capability_report_unavailable"), .inputFailure("capability_report_invalid"),
                                .inputFailure("invocation_file_unavailable"), .endedReservation, .taskFailed,
                            ].enumerated()), id: \.offset
                    ) { _, state in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(state.title(.zh), systemImage: state.symbol).foregroundStyle(state.color).font(.headline)
                            Text(state.detail(.zh)).font(.callout)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).sectionBackground()
                    }
                }.padding(24).frame(width: 820).background(FixedVisualPalette.windowScrim(scheme, reduceTransparency: true))
                try renderView(
                    notices, size: CGSize(width: 820, height: 1050), scheme: scheme,
                    to: directory.appendingPathComponent("preparation-\(theme).png"))
            }
            print("Workbench previews rendered: synthetic fixtures only; 820 / 980 / 1280; light / dark; arrangement and failure states")
            return true
        } catch {
            let category: String
            switch (error as? CocoaError)?.code {
            case .fileReadNoPermission, .fileWriteNoPermission: category = "permission-denied"
            case .fileWriteOutOfSpace: category = "disk-full"
            case .fileNoSuchFile, .fileReadNoSuchFile: category = "path-unavailable"
            default: category = "render-or-write-failed"
            }
            print("Workbench preview failed: \(category)")
            return false
        }
    }

    static func renderView<Content: View>(_ view: Content, size: CGSize, scheme: ColorScheme, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        // An unattached host rasterizes its SwiftUI layers at 1x. Attach to a
        // non-presented window so AppKit supplies the display's backing scale.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}
