import Darwin
import Foundation

/// Exact production runner and controller; only Reader/Hub inputs use synthetic data.
@MainActor final class AutomaticFallbackRunner {
    var hasStarted = true
    var resetCreditAutoDesktopVerified = true
    var resetCreditAutoIdentityRetryAt: Date?
    var identityRefreshCancellation: UUID?
    var isPreview = false
    func synchronizeMonitorWithCurrentCodex(announce: Bool) {}
    var resetCreditAutoTask: Task<Void, Never>?
    var isLaunchingCodex = false
    var isLoggingIn = false
    var isAccountSwitchTransactionActive = false
    var profiles: [CodexProfile] = []
    var resetCreditAutoPreferences = CodexResetCreditAutoPreferences()
    var aliases: [String: String] = [:]
    var resetCreditAutoAdmission: CodexResetCreditAutoAdmission?
    var resetCreditAutoIdentity: (profileID: String, accountID: String, home: URL)?
    var resetCreditAutoOriginIdentity: (profileID: String, accountID: String, home: URL)?
    var resetCreditAutoDesktopAccountID: String?
    // EXTRACTED_TASK_PROPERTY
    var resetCreditAutoStatus: String?
    let resetCreditAutoController: CodexResetCreditController
    let autoStore: CodexResetCreditAutoStateStore
    let pendingStore: ResetCreditPendingAttemptStore
    let activityStore: DispatchActivityStore
    var reviewed: [String] = []
    var consumed: [String] = []
    var refreshes: [String] = []
    var reviewReader: ((CodexProfile, String) async -> Result<CodexResetCreditReview, CodexResetCreditFailure>)?
    var consumeReader: ((CodexProfile, CodexResetCreditReview, String, CodexResetCreditAutoAdmission) async -> Result<CodexResetCreditConsumeOutcome, CodexResetCreditFailure>)?
    var hubAvailability: ((String, String) async -> Bool)? = { _, _ in true }
    init(_ directory: URL) {
        autoStore = .init(url: directory.appendingPathComponent("auto.json"))
        pendingStore = .init(url: directory.appendingPathComponent("pending.json"))
        activityStore = .init(directory: directory.appendingPathComponent("activity"))
        resetCreditAutoController = .init(activityStore: activityStore, pendingStore: pendingStore)
    }
    func accountTaskAlias(for profile: CodexProfile) -> String? { aliases[profile.id] }
    func refreshProfile(_ id: String) { refreshes.append(id) }
    // EXTRACTED_RUNNER
}

@MainActor
func runAutomaticFallbackTests() async throws {
    func review(_ profile: CodexProfile, _ account: String) -> CodexResetCreditReview {
        .init(
            profileID: profile.id, accountID: account, accountRemark: "Synthetic", card: .init(creditID: "synthetic-card", expiresAt: Date().addingTimeInterval(600)),
            observedAt: Date(), quotaFingerprint: DispatchActivityStore.hash("official"))
    }
    func make(_ name: String) throws -> AutomaticFallbackRunner {
        let v = AutomaticFallbackRunner(try ResetCreditAutoTests.root(name))
        v.profiles = [
            .init(id: "system", lastSnapshot: .init(accountID: "desktop"), isSystemProfile: true),
            .init(id: "first", lastSnapshot: .init(accountID: "same", resetCreditExpiries: [Date().addingTimeInterval(600)])),
            .init(id: "second", lastSnapshot: .init(accountID: "same", resetCreditExpiries: [Date().addingTimeInterval(600)])),
        ]
        v.aliases = ["first": "first-alias", "second": "second-alias"]
        v.resetCreditAutoPreferences.authorizedAccounts = ["first": DispatchActivityStore.hash("same"), "second": DispatchActivityStore.hash("same")]
        v.reviewReader = { [weak v] profile, account in
            v?.reviewed.append(profile.id)
            let response: [String: Any] = [
                "accountId": profile.id == "first" ? "different-actual-identity" : account,
                "rateLimitResetCredits": [
                    "availableCount": 1,
                    "credits": [
                        ["id": "synthetic-card", "resetType": "codexRateLimits", "status": "available", "expiresAt": Int(Date().addingTimeInterval(600).timeIntervalSince1970)]
                    ],
                ],
            ]
            switch FallbackVerifier(expectedAccountID: account).verifiedCard(from: response, verificationDate: Date()) {
            case .failure(let failure): return .failure(failure)
            case .success(let card):
                return .success(
                    .init(
                        profileID: profile.id, accountID: account, accountRemark: "Synthetic", card: card, observedAt: Date(),
                        quotaFingerprint: DispatchActivityStore.hash("official")))
            }
        }
        v.consumeReader = { [weak v] profile, _, _, gate in
            gate.admit {
                v?.consumed.append(profile.id)
                return true
            } ? .success(.reset) : .failure(.requestNotSent)
        }
        return v
    }
    func run(_ v: AutomaticFallbackRunner) async {
        v.checkResetCreditAuto()
        await v.resetCreditAutoTask?.value
    }
    let fallback = try make("fallback-success")
    await run(fallback)
    let firstRoundReviewed = fallback.reviewed
    await run(fallback)
    ResetCreditAutoTests.expect(
        firstRoundReviewed == ["first", "second"] && fallback.consumed == ["second"] && fallback.refreshes == ["second"],
        "same-account identityChanged review falls back to healthy profile exactly once")
    ResetCreditAutoTests.expect(
        try fallback.pendingStore.pendingAttempt() == nil
            && (fallback.consumed.isEmpty
                || !fallback.autoStore.mayAttempt(accountID: "same", cardID: "synthetic-card", fingerprint: DispatchActivityStore.hash("official"), now: Date())),
        "successful fallback leaves terminal journal and no pending")

    let pending = try make("fallback-pending")
    _ = try pending.pendingStore.loadOrCreate(for: review(pending.profiles[1], "same"))
    await run(pending)
    ResetCreditAutoTests.expect(pending.reviewed.isEmpty && pending.consumed.isEmpty, "shared pending blocks profile fallback before review")

    let malformed = try make("fallback-malformed")
    try Data("{broken".utf8).write(to: malformed.autoStore.url)
    chmod(malformed.autoStore.url.path, 0o600)
    await run(malformed)
    ResetCreditAutoTests.expect(malformed.reviewed.isEmpty && malformed.consumed.isEmpty, "unreadable automatic journal blocks profile fallback before review")

    let cancellation = try make("fallback-cancellation")
    let original = cancellation.reviewReader!
    cancellation.reviewReader = { profile, account in
        let result = await original(profile, account)
        cancellation.resetCreditAutoAdmission?.cancel()
        return result
    }
    await run(cancellation)
    ResetCreditAutoTests.expect(cancellation.reviewed == ["first"] && cancellation.consumed.isEmpty, "review cancellation blocks fallback even for identityChanged")

    let unknown = try make("fallback-unknown")
    unknown.reviewReader = { profile, account in
        unknown.reviewed.append(profile.id)
        return .success(review(profile, account))
    }
    unknown.consumeReader = { profile, _, _, gate in
        _ = gate.admit {
            unknown.consumed.append(profile.id)
            return true
        }
        return .failure(.outcomeUnknown)
    }
    await run(unknown)
    ResetCreditAutoTests.expect(unknown.reviewed == ["first"] && unknown.consumed == ["first"], "unknown consume outcome blocks same-account fallback")
    let restarted = try make("fallback-unknown")
    restarted.profiles.removeAll { $0.id == "first" }
    await run(restarted)
    ResetCreditAutoTests.expect(
        try restarted.reviewed.isEmpty && restarted.consumed.isEmpty && restarted.autoStore.requiresReconciliation(accountID: "same"),
        "unknown durable journal blocks alternate profile after restart")

    let noCredit = try make("fallback-no-credit")
    noCredit.reviewReader = { profile, _ in
        noCredit.reviewed.append(profile.id)
        return .failure(.noAvailableCredit)
    }
    await run(noCredit)
    ResetCreditAutoTests.expect(noCredit.reviewed == ["first"] && noCredit.consumed.isEmpty, "credit availability failure never permits fallback")

    let busy = try make("fallback-busy")
    busy.reviewReader = { profile, account in
        busy.reviewed.append(profile.id)
        return .success(review(profile, account))
    }
    busy.hubAvailability = { _, _ in false }
    await run(busy)
    ResetCreditAutoTests.expect(busy.reviewed == ["first"] && busy.consumed.isEmpty, "Hub activity blocks same-account fallback")

    let leased = try make("fallback-local-lease")
    leased.reviewReader = { profile, account in
        leased.reviewed.append(profile.id)
        return .success(review(profile, account))
    }
    let lease = try leased.activityStore.reserveMaintenance(account: leased.profiles[1].recordedAccountKey, alias: "first-alias")
    await run(leased)
    ResetCreditAutoTests.expect(leased.reviewed == ["first"] && leased.consumed.isEmpty, "local maintenance lease blocks same-account fallback")
    try leased.activityStore.finishMaintenance(lease, succeeded: false)

    let terminal = try make("fallback-terminal-failure")
    terminal.reviewReader = { profile, account in
        terminal.reviewed.append(profile.id)
        return .success(review(profile, account))
    }
    terminal.consumeReader = { profile, _, _, _ in
        terminal.consumed.append(profile.id)
        try? Data("{broken".utf8).write(to: terminal.autoStore.url)
        return .success(.reset)
    }
    await run(terminal)
    ResetCreditAutoTests.expect(
        try terminal.reviewed == ["first"] && terminal.consumed == ["first"] && terminal.refreshes.isEmpty && terminal.pendingStore.pendingAttempt() != nil,
        "terminal journal failure retains pending and blocks fallback")

    func desktop(_ name: String) throws -> AutomaticFallbackRunner {
        let value = try make(name)
        value.profiles[0].lastSnapshot?.resetCreditExpiries = [Date().addingTimeInterval(600)]
        value.profiles[1].lastSnapshot?.accountID = "desktop"
        value.profiles.removeAll { $0.id == "second" }
        value.resetCreditAutoPreferences.authorizedAccounts = ["system": DispatchActivityStore.hash("desktop")]
        value.reviewReader = { profile, account in
            value.reviewed.append(profile.id)
            return .success(review(profile, account))
        }
        return value
    }
    let desktopSuccess = try desktop("desktop-success")
    await run(desktopSuccess)
    ResetCreditAutoTests.expect(
        desktopSuccess.reviewed == ["first"] && desktopSuccess.consumed == ["first"] && desktopSuccess.refreshes == ["first"],
        "real controller redeems desktop consent through independently signed-in mirror")
    let desktopShared = try desktop("desktop-shared")
    desktopShared.resetCreditAutoPreferences.authorizedAccounts["first"] = DispatchActivityStore.hash("desktop")
    await run(desktopShared)
    ResetCreditAutoTests.expect(desktopShared.reviewed == ["first"] && desktopShared.consumed == ["first"], "real controller deduplicates desktop and mirror shared pool")

    let changes: [(String, (AutomaticFallbackRunner) -> Void)] = [
        ("login", { $0.isLoggingIn = true }),
        ("launch", { $0.isLaunchingCodex = true }),
        ("switch", { $0.isAccountSwitchTransactionActive = true }),
        ("stop", { $0.hasStarted = false }),
        ("desktop identity", { $0.profiles[0].lastSnapshot?.accountID = "different" }),
        ("origin authorization", { $0.resetCreditAutoPreferences.authorizedAccounts = [:] }),
        ("executor identity", { $0.profiles[1].lastSnapshot?.accountID = "different" }),
        ("executor removal", { $0.profiles.removeAll { $0.id == "first" } }),
        ("executor path", { $0.profiles[1].homeOverride = URL(fileURLWithPath: "/synthetic-changed-path") }),
        ("executor global path", { $0.profiles[1].homeOverride = $0.profiles[0].codexHomeURL }),
        ("executor alias", { $0.aliases["first"] = "changed-alias" }),
        ("quota failure", { $0.profiles[1].lastQuotaReadFailureAt = Date() }),
        ("desktop active task", {
            $0.codexLiveTasks = .init(connectionMode: .sharedDaemon, records: ["task": .init(threadID: "task", name: nil, state: .running, updatedAt: Date(), turnID: "turn", connectionMode: .sharedDaemon)], refreshedAt: Date())
        }),
        ("desktop stale task evidence", { $0.codexLiveTasks = .init(connectionMode: .sharedDaemon, records: [:], refreshedAt: Date().addingTimeInterval(-60)) })
    ]
    for stage in ["review", "Hub"] {
        for (index, change) in changes.enumerated() {
            let value = try desktop("desktop-\(stage)-\(index)")
            if stage == "review" {
                value.reviewReader = { profile, account in
                    value.reviewed.append(profile.id)
                    await Task.yield()
                    change.1(value)
                    return .success(review(profile, account))
                }
            } else {
                value.hubAvailability = { _, _ in
                    await Task.yield()
                    change.1(value)
                    return true
                }
            }
            await run(value)
            ResetCreditAutoTests.expect(
                try value.reviewed == ["first"] && value.consumed.isEmpty && value.pendingStore.pendingAttempt() == nil
                    && value.refreshes.isEmpty && !value.resetCreditAutoController.isWorking,
                "real controller \(stage) suspension rechecks \(change.0) before consume")
        }
    }
}
