import Darwin
import Foundation

@main
struct ResetCreditAutoTests {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    @MainActor static func expect(_ ok: Bool, _ marker: String) {
        checks += 1
        print("\(ok ? "PASS" : "FAIL") \(marker)")
        fflush(stdout)
        if !ok { failures += 1 }
    }
    static func throwsError(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return false
        } catch { return true }
    }
    static func root(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RESET_AUTO_TEST_ROOT"]!).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func entry(
        _ account: String, _ card: String, phase: CodexResetCreditAutoStateStore.Entry.Phase = .prepared, expiry: Date = Date().addingTimeInterval(600),
        fingerprint: String = DispatchActivityStore.hash("quota-one")
    ) -> CodexResetCreditAutoStateStore.Entry {
        var value = CodexResetCreditAutoStateStore.Entry(
            accountHash: DispatchActivityStore.hash(account), cardHash: DispatchActivityStore.hash(card), phase: phase, outcome: nil, nextRetry: nil, quotaFingerprint: fingerprint)
        value.expiresAt = expiry
        return value
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--race-claim" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let ready = directory.appendingPathComponent("ready-" + CommandLine.arguments[3])
            try Data().write(to: ready)
            let start = directory.appendingPathComponent("start")
            for _ in 0..<500 where !FileManager.default.fileExists(atPath: start.path) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard FileManager.default.fileExists(atPath: start.path) else { exit(2) }
            let store = CodexResetCreditAutoStateStore(url: directory.appendingPathComponent("state.json"))
            do {
                print("CLAIM=\(try store.claim(entry("race-account", "race-card")) ? 1 : 0)")
            } catch DispatchParticipationError.busy {
                print("CLAIM=BUSY")
            }
            return
        }
        let now = Date()
        let admission = CodexResetCreditAutoAdmission()
        admission.cancel()
        var writes = 0
        expect(
            !admission.admit {
                writes += 1
                return true
            } && writes == 0, "revocation prevents consume write admission")
        expect(
            CodexResetCreditAutoPreferences().authorizedAccounts.isEmpty && CodexResetCreditAutoPreferences().leadSeconds == 1800, "automation defaults off with thirty minute lead"
        )
        var preferences = CodexResetCreditAutoPreferences()
        preferences.authorizedAccounts["p"] = DispatchActivityStore.hash("a")
        expect(preferences.permits(profileID: "p", accountID: "a") && !preferences.permits(profileID: "p", accountID: "other"), "authorization does not survive identity changes")

        let journalRoot = try root("journal")
        let journal = CodexResetCreditAutoStateStore(url: journalRoot.appendingPathComponent("state.json"))
        let prepared = entry("a", "c")
        let won = try journal.claim(prepared)
        expect(try won && !(CodexResetCreditAutoStateStore(url: journal.url).claim(entry("a", "c"))), "separate state instances cannot duplicate claim")
        var wrong = prepared
        wrong.phase = .completed
        wrong.attemptID = UUID()
        expect(throwsError { try journal.record(wrong) }, "wrong attempt cannot record terminal state")
        wrong = entry("a", "wrong-card", phase: .completed, expiry: prepared.expiresAt!)
        wrong.attemptID = prepared.attemptID
        expect(throwsError { try journal.record(wrong) }, "wrong card key cannot record terminal state")
        wrong = entry("wrong-account", "c", phase: .completed, expiry: prepared.expiresAt!)
        wrong.attemptID = prepared.attemptID
        expect(throwsError { try journal.record(wrong) }, "wrong account key cannot record terminal state")
        wrong = prepared
        wrong.phase = .completed
        wrong.expiresAt = prepared.expiresAt!.addingTimeInterval(1)
        expect(throwsError { try journal.record(wrong) }, "wrong expiry cannot record terminal state")
        expect(
            !(try journal.mayAttempt(accountID: "a", cardID: "other", fingerprint: DispatchActivityStore.hash("different"), now: now)), "prepared blocks other cards across restart"
        )
        var uncertain = prepared
        uncertain.phase = .uncertain
        uncertain.outcome = "unknown"
        try journal.record(uncertain)
        expect(
            !(try CodexResetCreditAutoStateStore(url: journal.url).mayAttempt(
                accountID: "a", cardID: "new", fingerprint: DispatchActivityStore.hash("different"), now: now.addingTimeInterval(900))),
            "unknown never retries after restart or cooldown")

        let cooldownRoot = try root("cooldown")
        let cooldown = CodexResetCreditAutoStateStore(url: cooldownRoot.appendingPathComponent("state.json"))
        var deferred = entry("b", "card")
        expect(try cooldown.claim(deferred), "first cooldown claim succeeds")
        deferred.phase = .deferred
        deferred.outcome = "nothingToReset"
        deferred.nextRetry = now.addingTimeInterval(60)
        try cooldown.record(deferred)
        expect(
            !(try cooldown.mayAttempt(accountID: "b", cardID: "card", fingerprint: DispatchActivityStore.hash("different"), now: now)),
            "nothing-to-reset cooldown blocks changed quota too early")
        expect(
            !(try cooldown.mayAttempt(accountID: "b", cardID: "card", fingerprint: deferred.quotaFingerprint, now: now.addingTimeInterval(61))),
            "unchanged quota blocks retry after cooldown")
        expect(
            try cooldown.mayAttempt(accountID: "b", cardID: "card", fingerprint: DispatchActivityStore.hash("different"), now: now.addingTimeInterval(61)),
            "changed quota permits retry after cooldown")

        let malformedRoot = try root("malformed")
        let malformed = CodexResetCreditAutoStateStore(url: malformedRoot.appendingPathComponent("state.json"))
        try Data("{broken".utf8).write(to: malformed.url)
        chmod(malformed.url.path, 0o600)
        expect(throwsError { _ = try malformed.claim(entry("m", "card")) }, "malformed journal fails closed")
        var invalid = entry("m", "invalid")
        invalid.expiresAt = nil
        expect(throwsError { _ = try malformed.claim(invalid) }, "missing expiry cannot be journaled")

        let boundsRoot = try root("bounds")
        let bounds = CodexResetCreditAutoStateStore(url: boundsRoot.appendingPathComponent("state.json"))
        var entries = (0..<3).map { entry("account-\($0)", "card", phase: .completed, expiry: now.addingTimeInterval(-10)) }
        func seed(_ values: [CodexResetCreditAutoStateStore.Entry], at url: URL? = nil) throws {
            struct Envelope: Encodable {
                let version = 1
                let entries: [CodexResetCreditAutoStateStore.Entry]
            }
            let target = url ?? bounds.url
            try JSONEncoder().encode(Envelope(entries: values)).write(to: target)
            chmod(target.path, 0o600)
        }
        try seed(entries)
        expect(try bounds.claim(entry("new", "fresh")), "expired terminal entries are cleaned before new admission")
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: bounds.url)) as! [String: Any]
        expect((disk["entries"] as? [Any])?.count == 1 && disk["rejectedThrough"] != nil, "cleanup retains expiry highwater instead of forgetting consumed cards")
        expect(!(try bounds.claim(entry("other", "expired", expiry: now.addingTimeInterval(-20)))), "expired or pruned date cannot be replayed")
        let watermarkRoot = try root("watermark")
        let watermark = CodexResetCreditAutoStateStore(url: watermarkRoot.appendingPathComponent("state.json"))
        let oldExpiry = now.addingTimeInterval(100)
        let oldTerminal = entry("watermark", "old", phase: .completed, expiry: oldExpiry)
        try seed([oldTerminal], at: watermark.url)
        _ = try watermark.claim(entry("watermark-cleanup", "fresh", expiry: now.addingTimeInterval(500)), now: now.addingTimeInterval(200))
        expect(!(try watermark.claim(entry("watermark-new", "new", expiry: now.addingTimeInterval(50)))), "clock rollback expiry below rejected watermark remains blocked")
        entries = (0..<256).map { entry("account-\($0)", "card", phase: .uncertain) }
        try seed(entries)
        expect(throwsError { _ = try bounds.claim(entry("overflow", "card")) }, "oversized unresolved journal fails closed rather than evicts")
        entries.append(entry("over", "card"))
        try seed(entries)
        expect(
            throwsError { _ = try bounds.mayAttempt(accountID: "new", cardID: "new", fingerprint: DispatchActivityStore.hash("f"), now: now) },
            "overbound persisted journal fails closed")

        try await controllerTests()
        await runAutomaticWiringTests()
        try await runAutomaticFallbackTests()
        runReaderAdmissionChecks()
        print("reset-credit auto host: \(checks) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor static func controllerTests() async throws {
        let fingerprint = DispatchActivityStore.hash("verified-quota")
        let profile = CodexProfile(id: "synthetic-profile", lastSnapshot: .init(accountID: "synthetic-account"))
        func review() -> CodexResetCreditReview {
            CodexResetCreditReview(
                profileID: profile.id, accountID: "synthetic-account", accountRemark: "Synthetic",
                card: .init(creditID: "synthetic-card", expiresAt: Date().addingTimeInterval(600)), observedAt: Date(), quotaFingerprint: fingerprint)
        }
        func stores(_ name: String) throws -> (CodexResetCreditController, ResetCreditPendingAttemptStore, CodexResetCreditAutoStateStore) {
            let directory = try root(name)
            let pending = ResetCreditPendingAttemptStore(url: directory.appendingPathComponent("pending.json"))
            let auto = CodexResetCreditAutoStateStore(url: directory.appendingPathComponent("auto.json"))
            return (CodexResetCreditController(activityStore: .init(directory: directory.appendingPathComponent("activity")), pendingStore: pending), pending, auto)
        }
        var reads = 0
        var consumes = 0
        var confirmed = 0
        var actualKey = ""
        let (controller, pending, auto) = try stores("controller-cancel")
        let cancelled = CodexResetCreditAutoAdmission()
        cancelled.cancel()
        await controller.runAutomatic(
            profile: profile, accountID: "synthetic-account", hubAccountAlias: "synthetic-alias", lead: 1800, quotaFingerprint: fingerprint, admission: cancelled, autoStore: auto,
            reviewReader: { _, _ in
                reads += 1
                return .success(review())
            },
            consumeReader: { _, _, _, _ in
                consumes += 1
                return .success(.reset)
            }, hubAvailability: { _, _ in true }, onConfirmedResult: { confirmed += 1 })
        expect(reads == 0 && consumes == 0 && confirmed == 0, "runAutomatic cancelled before review makes zero reader calls")
        let hubCancel = CodexResetCreditAutoAdmission()
        await controller.runAutomatic(
            profile: profile, accountID: "synthetic-account", hubAccountAlias: "synthetic-alias", lead: 1800, quotaFingerprint: fingerprint, admission: hubCancel, autoStore: auto,
            reviewReader: { _, _ in
                reads += 1
                return .success(review())
            },
            consumeReader: { _, _, _, _ in
                consumes += 1
                return .success(.reset)
            },
            hubAvailability: { _, _ in
                hubCancel.cancel()
                return true
            }, onConfirmedResult: { confirmed += 1 })
        expect(try reads == 1 && consumes == 0 && pending.pendingAttempt() == nil, "revocation during Hub check makes zero consume calls and no pending")
        let (unknownController, unknownPending, unknownAuto) = try stores("controller-unknown")
        await unknownController.runAutomatic(
            profile: profile, accountID: "synthetic-account", hubAccountAlias: "synthetic-alias", lead: 1800, quotaFingerprint: fingerprint, admission: .init(),
            autoStore: unknownAuto, reviewReader: { _, _ in .success(review()) },
            consumeReader: { _, _, key, admission in
                consumes += 1
                actualKey = key
                expect(admission.admit { true }, "injected consume reaches real admission gate")
                return .failure(.outcomeUnknown)
            }, hubAvailability: { _, _ in true }, onConfirmedResult: { confirmed += 1 })
        let unknownAttempt = try unknownPending.pendingAttempt()
        expect(
            UUID(uuidString: actualKey) != nil && unknownAttempt?.idempotencyKey == actualKey && confirmed == 0,
            "unknown consumes once with durable original key and retains pending")
        let restart = CodexResetCreditController(activityStore: .init(directory: try root("restart-activity")), pendingStore: .init(url: unknownPending.url))
        let before = consumes
        let readsBefore = reads
        await restart.runAutomatic(
            profile: profile, accountID: "synthetic-account", hubAccountAlias: "synthetic-alias", lead: 1800, quotaFingerprint: fingerprint, admission: .init(),
            autoStore: .init(url: unknownAuto.url),
            reviewReader: { _, _ in
                reads += 1
                return .success(review())
            },
            consumeReader: { _, _, _, _ in
                consumes += 1
                return .success(.reset)
            }, hubAvailability: { _, _ in true }, onConfirmedResult: { confirmed += 1 })
        expect(consumes == before && reads == readsBefore, "pending unknown restart stops before review and consume")
        if let unknownAttempt {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unknownAttempt)) as! [String: Any]
            json["idempotencyKey"] = UUID().uuidString.lowercased()
            let wrongKey = try JSONDecoder().decode(ResetCreditPendingAttempt.self, from: JSONSerialization.data(withJSONObject: json))
            expect(throwsError { try unknownPending.clear(expected: wrongKey) }, "wrong idempotency key cannot clear original pending")
        }
        if let unknownAttempt {
            try unknownPending.clear(expected: unknownAttempt)
            await restart.runAutomatic(
                profile: profile, accountID: "synthetic-account", hubAccountAlias: "synthetic-alias", lead: 1800, quotaFingerprint: fingerprint, admission: .init(),
                autoStore: .init(url: unknownAuto.url), reviewReader: { _, _ in .success(review()) },
                consumeReader: { _, _, _, _ in
                    consumes += 1
                    return .success(.reset)
                }, hubAvailability: { _, _ in true }, onConfirmedResult: { confirmed += 1 })
            expect(consumes == before, "uncertain auto journal still blocks if shared pending is reconciled")
        }
        let (successController, successPending, successAuto) = try stores("controller-success")
        await successController.runAutomatic(
            profile: profile, accountID: "synthetic-account", hubAccountAlias: "synthetic-alias", lead: 1800, quotaFingerprint: DispatchActivityStore.hash("external-fake"),
            admission: .init(),
            autoStore: successAuto, reviewReader: { _, _ in .success(review()) }, consumeReader: { _, _, _, _ in .success(.nothingToReset) }, hubAvailability: { _, _ in true },
            onConfirmedResult: { confirmed += 1 })
        expect(
            try confirmed == 1 && successPending.pendingAttempt() == nil && !successController.isWorking,
            "nothing-to-reset records deferred before clearing pending and refreshes once")
        expect(
            !(try successAuto.mayAttempt(accountID: "synthetic-account", cardID: "synthetic-card", fingerprint: fingerprint, now: Date().addingTimeInterval(120))),
            "controller nothing-to-reset uses verified quota fingerprint")
        let (recordFailController, recordFailPending, recordFailAuto) = try stores("controller-record-fail")
        await recordFailController.runAutomatic(
            profile: profile, accountID: "synthetic-account", hubAccountAlias: "synthetic-alias", lead: 1800, quotaFingerprint: fingerprint, admission: .init(),
            autoStore: recordFailAuto, reviewReader: { _, _ in .success(review()) },
            consumeReader: { _, _, _, _ in
                try? Data("{broken".utf8).write(to: recordFailAuto.url)
                return .success(.reset)
            }, hubAvailability: { _, _ in true }, onConfirmedResult: { confirmed += 1 })
        expect(
            try recordFailPending.pendingAttempt() != nil && !recordFailController.isWorking && confirmed == 1,
            "terminal journal write failure retains pending and does not claim refresh")
        let (writeController, writePending, writeAuto) = try stores("controller-write-revocation")
        var writes = 0
        await writeController.runAutomatic(
            profile: profile, accountID: "synthetic-account", hubAccountAlias: "synthetic-alias", lead: 1800, quotaFingerprint: fingerprint, admission: .init(),
            autoStore: writeAuto, reviewReader: { _, _ in .success(review()) },
            consumeReader: { _, _, _, admission in
                admission.cancel()
                let sent = admission.admit {
                    writes += 1
                    return true
                }
                return sent ? .success(.reset) : .failure(.requestNotSent)
            }, hubAvailability: { _, _ in true }, onConfirmedResult: { confirmed += 1 })
        expect(try writes == 0 && writePending.pendingAttempt() == nil && confirmed == 1, "cancel at consume admission sends zero writes and preserves unconfirmed status")
        expect(
            try writeAuto.mayAttempt(accountID: "synthetic-account", cardID: "synthetic-card", fingerprint: fingerprint, now: Date().addingTimeInterval(120)),
            "known not-sent permits same-fingerprint retry only after cooldown")
    }
}
