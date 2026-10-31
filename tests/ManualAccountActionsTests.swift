import Darwin
import Foundation

@main
struct ManualAccountActionsTests {
    @MainActor static var failures = 0
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL") \(name)")
    }
    static func root(_ name: String) throws -> URL {
        let result = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RESET_AUTO_TEST_ROOT"]!).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return result
    }
    @MainActor static func settled(_ controller: CodexResetCreditController) async {
        for _ in 0..<300 where controller.isWorking { try? await Task.sleep(nanoseconds: 5_000_000) }
        expect(!controller.isWorking, "bounded controller completion")
    }
    @MainActor static func confirmations(_ controller: CodexResetCreditController, _ profile: CodexProfile) async {
        controller.beginReview(profile: profile, selectedProfileID: profile.id)
        await settled(controller)
        expect(
            {
                if case .reviewing = controller.step { return true }
                return false
            }(), "first confirmation requires reviewed account and card")
        controller.confirmReviewed(profile: profile, selectedProfileID: profile.id)
        expect(
            {
                if case .consumption = controller.step { return true }
                return false
            }(), "second confirmation stays explicit")
    }
    static func credential(account: String = "synthetic-account", email: String = "sender@example.invalid", expiry: Date = Date().addingTimeInterval(3600)) throws -> Data {
        func jwt(_ claims: [String: Any]) throws -> String {
            let body = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "synthetic.\(body).signature"
        }
        return try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "account_id": account, "access_token": jwt(["exp": expiry.timeIntervalSince1970, "account_id": account, "email": email]),
                "id_token": jwt(["email": email, "account_id": account]),
            ]
        ])
    }
    static func consumeStarted() -> Bool { ManualReaderFixture.started.wait(timeout: .now()) == .success }
    @MainActor static func main() async throws {
        let profile = CodexProfile(id: "synthetic-profile", lastSnapshot: .init(accountID: "synthetic-account"))
        var refreshed = 0
        var events: [CodexResetCreditController.ManualResetConfirmation] = []
        func stores(_ name: String) throws -> (CodexResetCreditController, ResetCreditPendingAttemptStore, DispatchActivityStore) {
            let path = try root(name)
            let pending = ResetCreditPendingAttemptStore(url: path.appendingPathComponent("pending.json"))
            let activity = DispatchActivityStore(directory: path.appendingPathComponent("activity"))
            return (CodexResetCreditController(activityStore: activity, pendingStore: pending), pending, activity)
        }
        let (busy, pending, activity) = try stores("busy")
        _ = try activity.reserveProxy(
            account: profile.recordedAccountKey, alias: "synthetic-alias", runID: UUID().uuidString, requestID: UUID().uuidString, profileID: profile.id, childPID: getpid())
        let registry = activity.directory.appendingPathComponent(DispatchActivityStore.stateName)
        let originalRegistry = try Data(contentsOf: registry)
        ManualReaderFixture.reset()
        busy.confirmConsumption(
            profile: profile, selectedProfileID: profile.id, hubAccountAlias: "synthetic-alias", onConfirmedResult: { refreshed += 1 },
            onManualResetConfirmed: { events.append($0) })
        expect(ManualReaderFixture.keys.isEmpty && refreshed == 0 && events.isEmpty, "no consume without both confirmations")
        await confirmations(busy, profile)
        busy.confirmConsumption(
            profile: profile, selectedProfileID: profile.id, hubAccountAlias: "synthetic-alias", onConfirmedResult: { refreshed += 1 },
            onManualResetConfirmed: { events.append($0) })
        busy.confirmConsumption(
            profile: profile, selectedProfileID: profile.id, hubAccountAlias: "synthetic-alias", onConfirmedResult: { refreshed += 1 },
            onManualResetConfirmed: { events.append($0) })
        await settled(busy)
        expect(ManualReaderFixture.keys.count == 1 && refreshed == 1 && events.count == 1, "active proxy permits one manual consume and one event despite double click")
        expect(try Data(contentsOf: registry) == originalRegistry, "manual consume neither reserves nor finishes another task lease")
        expect(try pending.pendingAttempt() == nil, "confirmed manual reset clears pending attempt")
        expect(
            events.first?.eventID == "manual-reset-" + DispatchActivityStore.hash(ManualReaderFixture.keys[0])
                && events.first?.accountKey == DispatchActivityStore.hash("synthetic-account") && events.first?.profileID == profile.id,
            "success event is bound to hashed attempt and account")
        expect(busy.notice?.isError == false, "official reset acknowledgement displays confirmed success")
        let automatic = CodexResetCreditAutoStateStore(url: try root("busy").appendingPathComponent("automatic.json"))
        var autoConsumes = 0
        let now = Date()
        let review = CodexResetCreditReview(
            profileID: profile.id, accountID: "synthetic-account", accountRemark: "fixture", card: .init(creditID: "auto-card", expiresAt: now.addingTimeInterval(600)),
            observedAt: now, quotaFingerprint: DispatchActivityStore.hash("quota"))
        await busy.runAutomatic(
            profile: profile, accountID: "synthetic-account", hubAccountAlias: "synthetic-alias", lead: 1800, quotaFingerprint: review.quotaFingerprint!, admission: .init(),
            autoStore: automatic, reviewReader: { _, _ in .success(review) },
            consumeReader: { _, _, _, _ in
                autoConsumes += 1
                return .success(.reset)
            }, hubAvailability: { _, _ in true }, onConfirmedResult: {})
        expect(try autoConsumes == 0 && (Data(contentsOf: registry)) == originalRegistry, "automatic consumption still blocked by active proxy lease")
        for outcome in [CodexResetCreditConsumeOutcome.nothingToReset, .noCredit, .alreadyRedeemed] {
            let (controller, journal, _) = try stores(outcome.rawValue)
            ManualReaderFixture.reset()
            ManualReaderFixture.outcome = .success(outcome)
            let before = events.count
            await confirmations(controller, profile)
            controller.confirmConsumption(
                profile: profile, selectedProfileID: profile.id, hubAccountAlias: "busy-hub", onConfirmedResult: { refreshed += 1 }, onManualResetConfirmed: { events.append($0) })
            await settled(controller)
            expect(
                try events.count == before && controller.notice?.isError == true && (journal.pendingAttempt()) == nil,
                "\(outcome.rawValue) refreshes but never emits manual success")
        }
        let (unknown, unknownPending, _) = try stores("unknown")
        ManualReaderFixture.reset()
        ManualReaderFixture.outcome = .failure(.outcomeUnknown)
        await confirmations(unknown, profile)
        let beforeUnknown = events.count
        unknown.confirmConsumption(
            profile: profile, selectedProfileID: profile.id, hubAccountAlias: "busy-hub", onConfirmedResult: { refreshed += 1 }, onManualResetConfirmed: { events.append($0) })
        await settled(unknown)
        let attempt = try unknownPending.pendingAttempt()
        expect(attempt != nil && events.count == beforeUnknown, "unknown result preserves pending and produces no success event")
        let firstKey = ManualReaderFixture.keys[0]
        var changed = profile
        changed.lastSnapshot?.accountID = "changed-account"
        unknown.beginReview(profile: changed, selectedProfileID: changed.id)
        expect(
            try unknown.step == .idle && (unknownPending.pendingAttempt()) == attempt && ManualReaderFixture.keys.count == 1,
            "unknown request cannot be retried under another identity")
        ManualReaderFixture.cardID = "changed-card"
        unknown.beginReview(profile: profile, selectedProfileID: profile.id)
        await settled(unknown)
        expect(try unknown.step == .idle && (unknownPending.pendingAttempt()) == attempt, "unknown request cannot be retried with a different card")
        ManualReaderFixture.cardID = "synthetic-card"
        ManualReaderFixture.outcome = .success(.reset)
        await confirmations(unknown, profile)
        unknown.confirmConsumption(profile: profile, selectedProfileID: profile.id, hubAccountAlias: nil, onConfirmedResult: {}, onManualResetConfirmed: { events.append($0) })
        await settled(unknown)
        expect(
            ManualReaderFixture.keys == [firstKey, firstKey] && events.count == beforeUnknown + 1 && events.last?.eventID == "manual-reset-" + DispatchActivityStore.hash(firstKey),
            "explicit retry reuses exact idempotency key and stable success event ID")
        let (changedController, _, _) = try stores("selection")
        ManualReaderFixture.reset()
        await confirmations(changedController, profile)
        changedController.confirmConsumption(profile: changed, selectedProfileID: changed.id, hubAccountAlias: nil, onConfirmedResult: {})
        expect(ManualReaderFixture.keys.isEmpty, "identity change after confirmations prevents consume")
        let (stale, _, _) = try stores("stale")
        ManualReaderFixture.reviewedAt = Date().addingTimeInterval(-121)
        stale.beginReview(profile: profile, selectedProfileID: profile.id)
        await settled(stale)
        stale.confirmReviewed(profile: profile, selectedProfileID: profile.id)
        expect(stale.step == .idle && ManualReaderFixture.keys.isEmpty, "expired review cannot pass first confirmation")
        let (cancelled, cancelledPending, _) = try stores("cancel-before-send")
        ManualReaderFixture.reset()
        await confirmations(cancelled, profile)
        cancelled.confirmConsumption(profile: profile, selectedProfileID: profile.id, hubAccountAlias: nil, onConfirmedResult: {})
        cancelled.cancel()
        await settled(cancelled)
        expect(try ManualReaderFixture.keys.isEmpty && (cancelledPending.pendingAttempt()) == nil, "cancel before asynchronous dispatch clears only new unsent attempt")
        let (disappeared, _, _) = try stores("confirmed-after-disappear")
        ManualReaderFixture.reset()
        ManualReaderFixture.pause = DispatchSemaphore(value: 0)
        await confirmations(disappeared, profile)
        let beforeDisappear = events.count
        disappeared.confirmConsumption(profile: profile, selectedProfileID: profile.id, hubAccountAlias: nil, onConfirmedResult: {}, onManualResetConfirmed: { events.append($0) })
        for _ in 0..<300 {
            if consumeStarted() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        disappeared.cancel()
        ManualReaderFixture.pause?.signal()
        await settled(disappeared)
        expect(events.count == beforeDisappear + 1, "acknowledged redemption still emits once after UI disappears")
        var system = profile
        system.isSystemProfile = true
        BoundedLocalProcess.calls = 0
        let manualGate = processGate(profile: system, selectedCard: review.card, admission: nil)
        expect(
            {
                if case .success = manualGate { return true }
                return false
            }() && BoundedLocalProcess.calls == 0, "manual system-home reset ignores unrelated Codex process inventory")
        let autoGate = processGate(profile: system, selectedCard: review.card, admission: .init())
        expect(
            {
                if case .failure(.ambiguousProcessState) = autoGate { return true }
                return false
            }() && BoundedLocalProcess.calls == 1, "automatic system-home reset retains conservative process gate")
        let resolver = ReferralResolver()
        resolver.profiles = [profile]
        let home = try root("referral").resolvingSymlinksInPath()
        resolver.profileStore.homes[profile.id] = home
        for mask in 0..<8 {
            resolver.isLoggingIn = mask & 1 != 0
            resolver.isLaunchingCodex = mask & 2 != 0
            resolver.isAccountSwitchTransactionActive = mask & 4 != 0
            expect(try resolver.referralAccount(for: profile.id).profile.id == profile.id, "referral resolves exact profile with unrelated task flags \(mask)")
        }
        let bound = try resolver.referralAccount(for: profile.id)
        resolver.profileStore.homes[profile.id] = try root("different-home")
        expect(try !bound.matches(resolver.referralAccount(for: profile.id)), "referral rejects changed effective credential home")
        resolver.profileStore.homes[profile.id] = home
        resolver.profiles = [changed]
        expect(try !bound.matches(resolver.referralAccount(for: profile.id)), "referral rejects changed recorded identity")
        resolver.isPreview = true
        do {
            _ = try resolver.referralAccount(for: profile.id)
            expect(false, "preview blocked")
        } catch { expect(true, "preview blocked") }
        resolver.isPreview = false
        do {
            _ = try resolver.referralAccount(for: "missing")
            expect(false, "missing profile blocked")
        } catch { expect(true, "missing profile blocked") }
        let auth = home.appendingPathComponent("auth.json")
        let good = try credential()
        try good.write(to: auth)
        chmod(auth.path, 0o600)
        expect(
            try CodexReferralCredentialReader.readSnapshot(home: home, profile: profile, now: Date()).accountID == "synthetic-account",
            "real snapshot validator accepts stable exact synthetic identity")
        let rotated = try credential(expiry: Date().addingTimeInterval(7200))
        try rotated.write(to: auth)
        expect(
            try CodexReferralCredentialReader.readSnapshot(home: home, profile: profile, now: Date(), expectedData: good).accountID == "synthetic-account",
            "same identity token rotation remains usable during tasks")
        try credential(account: "different-account").write(to: auth)
        do {
            _ = try CodexReferralCredentialReader.readSnapshot(home: home, profile: profile, now: Date(), expectedData: good)
            expect(false, "actual identity switch rejected")
        } catch { expect(true, "actual identity switch rejected") }
        try credential(expiry: Date().addingTimeInterval(30)).write(to: auth)
        do {
            _ = try CodexReferralCredentialReader.readSnapshot(home: home, profile: profile, now: Date())
            expect(false, "expiring token rejected")
        } catch { expect(true, "expiring token rejected") }
        print("manual account actions: \(checks) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
