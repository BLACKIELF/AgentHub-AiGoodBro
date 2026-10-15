import Darwin
import Foundation

private final class NoticeFakeTransport {
    var sends = 0
    var next: CodexResetNoticeDeliveryReceipt = .accepted
    func send(_ delivery: CodexResetNoticeDelivery) -> CodexResetNoticeDeliveryReceipt {
        sends += 1
        return next
    }
}

@main
enum ResetNoticeFixture {
    static var checks = 0
    static var failures = 0
    static let now = Date(timeIntervalSinceReferenceDate: 810_000_000)
    static let account = CodexResetNoticeKey.hash("synthetic-account-a")
    static let revision = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL " + message) }
    }

    static func throwsError(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    static func card(_ id: String = "synthetic-card-a", _ seconds: TimeInterval?, at date: Date = now) -> CodexResetNoticeCard {
        CodexResetNoticeCard(cardID: id, expiresAt: seconds.map { date.addingTimeInterval($0) })!
    }

    static func observation(
        _ cards: [CodexResetNoticeCard]?, count: Int? = nil,
        at date: Date = now, verified: Bool = true, accountHash: String = account
    ) -> CodexResetNoticeObservation {
        .init(accountHash: accountHash, observedAt: date,
            availableCount: count ?? cards?.count, cards: cards, verificationSucceeded: verified)
    }

    static func evaluate(_ seconds: TimeInterval, at date: Date = now) -> CodexResetNoticeEvaluator.Evaluation {
        CodexResetNoticeEvaluator.evaluate(observation([card("boundary-card", seconds, at: date)], at: date), now: date)
    }

    static func snapshot(_ details: [ResetCreditDetail]?, count: Int?, succeeded: Bool = true) -> UsageSnapshot {
        .init(refreshedAt: now, account: nil, limitId: "codex", limitName: nil, quotaReadSucceeded: succeeded,
            fiveHourQuota: nil, sevenDayQuota: nil, monthlyQuota: nil,
            credits: .init(hasCredits: false, unlimited: false, balance: nil,
                resetCredits: count, resetCreditDetails: details),
            cloudLifetimeTokens: nil, local: nil, taskBoard: nil, messages: [])
    }

    static func store(_ name: String, root: URL) -> CodexResetNoticeDeliveryStore {
        .init(directory: root.appendingPathComponent(name))
    }

    static func main() throws {
        if CommandLine.arguments.count >= 3 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let raceStore = CodexResetNoticeDeliveryStore(directory: directory)
            let value = observation([card("race-card", 60)])
            if CommandLine.arguments[1] == "--race-prepare" {
                _ = try raceStore.observe(value, channels: [.local], now: now)
                return
            }
            if CommandLine.arguments[1] == "--race-reserve" {
                let ready = directory.appendingPathComponent("ready-" + CommandLine.arguments[3])
                try Data().write(to: ready)
                let start = directory.appendingPathComponent("start")
                for _ in 0..<500 where !FileManager.default.fileExists(atPath: start.path) { usleep(10_000) }
                guard FileManager.default.fileExists(atPath: start.path) else { exit(2) }
                let delivery = CodexResetNoticeDelivery(channel: .local,
                    candidate: .init(accountHash: account, observedAt: now, content: .expiry(cards: value.cards!)))
                do { print("RESERVED=\(try raceStore.reserve(delivery, revision: UUID(), now: now) == nil ? 0 : 1)") }
                catch CodexResetNoticeDeliveryStore.Failure.busy { print("RESERVED=BUSY") }
                return
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notice-ledger-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try evaluatorTests()
        try thresholdAndInvalidationTests(root: root)
        try deliveryTests(root: root)
        try changeTests(root: root)
        try retentionTests(root: root)
        try capacityTests(root: root)
        try integrityTests(root: root)
        print("reset-notice fixture: \(checks) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    static func evaluatorTests() throws {
        expect(evaluate(86_401).eligibleCards.isEmpty, "24h + 1s is outside")
        expect(evaluate(86_400).eligibleCards.count == 1, "24h is included")
        expect(evaluate(1).eligibleCards.count == 1, "1s is included")
        expect(evaluate(0).eligibleCards.isEmpty && evaluate(-1).eligibleCards.isEmpty, "expired is excluded")
        let complete = observation([card("one", 60), card("two", 60), card("three", 120)])
        let evaluation = CodexResetNoticeEvaluator.evaluate(complete, now: now)
        expect(evaluation.expiryBatches == [.init(expiresAt: now.addingTimeInterval(60), count: 2),
            .init(expiresAt: now.addingTimeInterval(120), count: 1)], "same account batches keep exact expiry and known count")
        let partial = CodexResetNoticeEvaluator.evaluate(observation([card("known", 60), card("unknown", nil)], count: 4), now: now)
        expect(partial.eligibleCards.count == 1 && partial.unknownExpiryCount == 3, "partial detail never turns whole count into expiring cards")
        expect(CodexResetNoticeEvaluator.evaluate(observation(nil, count: 4), now: now).eligibleCards.isEmpty, "engine/count only cannot infer dates or IDs")
        expect(!CodexResetNoticeEvaluator.evaluate(observation([card("duplicate", 60), card("duplicate", 120)]), now: now).verificationSucceeded, "duplicate backend ID invalidates contradictory rows")
        expect(!CodexResetNoticeEvaluator.evaluate(observation([card("overcount", 60)], count: 0), now: now).verificationSucceeded, "known cards cannot exceed count")
        expect(!CodexResetNoticeEvaluator.evaluate(complete, now: now.addingTimeInterval(-1)).verificationSucceeded, "future snapshot is excluded")
        expect(CodexResetNoticeEvaluator.evaluate(complete, now: now.addingTimeInterval(300)).verificationSucceeded, "freshness includes exact maximum age")
        expect(!CodexResetNoticeEvaluator.evaluate(complete, now: now.addingTimeInterval(301)).verificationSucceeded, "stale snapshot is excluded")
        expect(!CodexResetNoticeEvaluator.evaluate(observation(complete.cards, verified: false), now: now).verificationSucceeded, "failed identity/quota verification is excluded")
        expect(CodexResetNoticeCard(cardID: "\ninvalid", expiresAt: now) == nil, "invalid backend ID is not hashed into evidence")

        let details = [ResetCreditDetail(id: "official-card", expiresAt: now.addingTimeInterval(60))]
        let official = CodexResetNoticeObservation.official(accountID: "synthetic-official-account", snapshot: snapshot(details, count: 1), identityVerified: true)!
        expect(official.cards?.first?.cardHash == CodexResetNoticeKey.hash("official-card"), "fresh UsageSnapshot adapter uses backend ID")
        expect(CodexResetNoticeEvaluator.evaluate(official, now: now).eligibleCards.count == 1, "fresh official adapter is eligible")
        let identityFailure = CodexResetNoticeObservation.official(accountID: "synthetic-official-account", snapshot: snapshot(details, count: 1), identityVerified: false)!
        expect(!identityFailure.verificationSucceeded && identityFailure.cards == nil, "identity failure drops detail evidence")
        let quotaFailure = CodexResetNoticeObservation.official(accountID: "synthetic-official-account", snapshot: snapshot(details, count: 1, succeeded: false), identityVerified: true)!
        expect(!quotaFailure.verificationSucceeded && quotaFailure.availableCount == nil, "quota failure is not zero")
        let countOnly = CodexResetNoticeObservation.official(accountID: "synthetic-official-account", snapshot: snapshot(nil, count: 4), identityVerified: true)!
        expect(CodexResetNoticeEvaluator.evaluate(countOnly, now: now).eligibleCards.isEmpty, "official count without details is not inferred")

        let a = card("key-card", 60)
        let key = CodexResetNoticeKey.expiry(accountHash: account, cardHash: a.cardHash, expiresAt: a.expiresAt!, channel: .local)
        let tinyChange = a.expiresAt!.addingTimeInterval(0.000_001)
        expect(key != CodexResetNoticeKey.expiry(accountHash: account, cardHash: a.cardHash, expiresAt: tinyChange, channel: .local), "exact expiry precision is in stable key")
        expect(key != CodexResetNoticeKey.expiry(accountHash: account, cardHash: a.cardHash, expiresAt: a.expiresAt!, channel: .feishu), "each channel has an independent key")
        expect(key != CodexResetNoticeKey.expiry(accountHash: CodexResetNoticeKey.hash("other-account"), cardHash: a.cardHash, expiresAt: a.expiresAt!, channel: .local), "each account has an independent key")
        let decoded = try JSONDecoder().decode(CodexResetNoticeCard.self, from: JSONEncoder().encode(a))
        expect(decoded == a && CodexResetNoticeKey.expiry(accountHash: account, cardHash: decoded.cardHash, expiresAt: decoded.expiresAt!, channel: .local) == key, "date roundtrip preserves dedupe key")
        let first = CodexResetNoticeCandidate(accountHash: account, observedAt: now, content: .expiry(cards: complete.cards!))
        let second = CodexResetNoticeCandidate(accountHash: account, observedAt: now.addingTimeInterval(1), content: .expiry(cards: complete.cards!.reversed()))
        expect(CodexResetNoticeKey.batch(first, channel: .local) == CodexResetNoticeKey.batch(second, channel: .local), "summary key ignores ordering and check timestamp")
        print("PASS evaluator: boundaries, official ID, unknown details, freshness and exact stable keys")
    }

    static func thresholdAndInvalidationTests(root: URL) throws {
        let ledger = store("threshold", root: root)
        let value = observation([card("threshold-card", 86_401)])
        expect(try ledger.observe(value, channels: [.local], now: now).isEmpty, "first outside-window observation is baseline")
        expect(try ledger.read().records.values.first?.phase == .baseline, "baseline persists")
        let entered = try ledger.observe(value, channels: [.local], now: now.addingTimeInterval(1))
        expect(entered.count == 1, "timer crosses threshold with unchanged count and snapshot")
        expect(try ledger.read().records.values.first?.phase == .pending, "threshold transition persists pending")
        expect(try ledger.observe(value, channels: [.local], now: now.addingTimeInterval(301)).isEmpty, "timer cannot trust stale observation forever")
        expect(try ledger.reserve(entered[0], revision: revision, now: now.addingTimeInterval(301)) == nil, "reserve rechecks freshness")
        let late = store("late-start", root: root)
        expect(try late.observe(observation([card("late", 1)]), channels: [.local], now: now).count == 1, "first launch in window catches up")

        for mode in ["used", "extended", "failed", "missing", "expired"] {
            let itemStore = store(mode, root: root)
            let original = observation([card("invalidation-card", mode == "expired" ? 1 : 60)])
            let pending = try itemStore.observe(original, channels: [.local], now: now)[0]
            let time = now.addingTimeInterval(2)
            let replacement: CodexResetNoticeObservation
            switch mode {
            case "used": replacement = observation([], count: 0, at: time)
            case "extended": replacement = observation([card("invalidation-card", 172_800)], at: time)
            case "failed": replacement = observation(nil, at: time, verified: false)
            case "missing": replacement = observation(nil, count: 1, at: time)
            default: replacement = observation(original.cards, at: time)
            }
            expect(try itemStore.observe(replacement, channels: [.local], now: time).isEmpty, "latest " + mode + " suppresses pending expiry")
            expect(try itemStore.reserve(pending, revision: revision, now: time) == nil, "old candidate rejected after " + mode)
            expect(try itemStore.observe(original, channels: [.local], now: time).isEmpty, "older response cannot revive " + mode)
        }
        let conflict = store("equal-time-conflict", root: root)
        let one = observation([card("conflict-card", 60)])
        let old = try conflict.observe(one, channels: [.local], now: now)[0]
        expect(try conflict.observe(observation([], count: 0), channels: [.local], now: now).isEmpty, "conflicting equal-time observations fail closed")
        expect(try conflict.observe(one, channels: [.local], now: now).isEmpty, "equal-time success cannot revive conflicting identity")
        expect(try conflict.reserve(old, revision: revision, now: now) == nil, "conflict blocks already prepared candidate")
        expect(try conflict.observe(observation(one.cards, at: now.addingTimeInterval(1)), channels: [.local], now: now.addingTimeInterval(1)).count == 1, "newer success restores verified availability")
        let inFlight = store("admission-recheck", root: root)
        let prepared = try inFlight.observe(one, channels: [.local], now: now)[0]
        let reserved = try inFlight.reserve(prepared, revision: revision, now: now)!
        expect(try inFlight.isCurrent(reserved, now: now), "fresh reserved facts pass send boundary recheck")
        _ = try inFlight.observe(observation(nil, at: now.addingTimeInterval(1), verified: false), channels: [], now: now.addingTimeInterval(1))
        expect(try !inFlight.isCurrent(reserved, now: now.addingTimeInterval(1)), "verification failure during credential load revokes send admission")
        print("PASS invalidation: timer catch-up, used, expired, extended, failed, missing, old and conflicting observations")
    }

    static func deliveryTests(root: URL) throws {
        let ledger = store("delivery", root: root)
        let value = observation([card("card-one", 60), card("card-two", 60), card("card-three", 120)])
        let deliveries = try ledger.observe(value, channels: CodexResetNoticeChannel.allCases, now: now)
        expect(deliveries.count == 5 && deliveries.allSatisfy { $0.candidate.expiryBatches.count == 2 }, "one summary per enabled channel and account")
        let transport = NoticeFakeTransport()
        let local = deliveries.first { $0.channel == .local }!
        let claim = try ledger.reserve(local, revision: revision, now: now)!
        expect(try ledger.isCurrent(claim, now: now), "reserved candidate is current while sending")
        expect(try CodexResetNoticeDeliveryStore(url: ledger.url).reserve(local, revision: revision, now: now) == nil, "separate store instance cannot reserve same pending delivery")
        expect(try !ledger.record(claim, receipt: .accepted, currentRevision: UUID(), now: now), "late callback from changed credential revision is ignored")
        expect(try ledger.read().records[local.keys[0]]?.phase == .sending, "rejected callback does not pollute phase")
        expect(try ledger.record(claim, receipt: transport.send(local), currentRevision: revision, now: now), "accepted receipt persisted")
        expect(try !ledger.isCurrent(claim, now: now), "accepted attempt cannot admit another send")
        expect(try local.keys.allSatisfy { try ledger.read().records[$0]?.phase == .sent }, "all summary members marked API accepted")
        expect(try ledger.observe(value, channels: [.local], now: now).isEmpty, "refresh does not resend accepted notice")

        let feishu = deliveries.first { $0.channel == .feishu }!
        let first = try ledger.reserve(feishu, revision: revision, now: now)!
        expect(try ledger.record(first, receipt: .notSent, currentRevision: revision, now: now), "known admission failure remains retryable")
        expect(try ledger.read().records[feishu.keys[0]]?.phase == .pending, "known not sent restores pending")
        let second = try ledger.reserve(feishu, revision: revision, now: now)!
        expect(try !ledger.isCurrent(first, now: now), "old attempt cannot pass transport admission")
        expect(first.attemptID != second.attemptID, "retry has distinct reservation identity")
        expect(try !ledger.record(first, receipt: .accepted, currentRevision: revision, now: now), "old callback cannot accept new reservation")
        expect(try !ledger.markUncertain(first, now: now), "old attempt cannot close a later reservation")
        expect(try !ledger.releaseUnsent(first, now: now), "old attempt cannot release a later reservation")
        expect(try ledger.record(second, receipt: .rejected, currentRevision: revision, now: now), "explicit rejection remains retryable")
        expect(try !ledger.markUncertain(second, now: now), "pending failed attempt cannot become uncertain after proven failure")
        expect(try !ledger.releaseUnsent(second, now: now), "already pending attempt cannot be released again")
        let restart = CodexResetNoticeDeliveryStore(url: ledger.url)
        expect(try restart.observe(value, channels: [.feishu], now: now).count == 1, "pending failure survives restart")

        let telegram = deliveries.first { $0.channel == .telegram }!
        let unknown = try ledger.reserve(telegram, revision: revision, now: now)!
        expect(try ledger.record(unknown, receipt: .uncertain, currentRevision: revision, now: now), "ambiguous transport persists uncertain")
        expect(try restart.observe(value, channels: [.telegram], now: now).isEmpty, "uncertain never automatically retries across restart")
        let weChat = deliveries.first { $0.channel == .weChat }!
        _ = try ledger.reserve(weChat, revision: revision, now: now)!
        try restart.recoverInterruptedSends(now: now)
        expect(try weChat.keys.allSatisfy { try restart.read().records[$0]?.phase == .uncertain }, "crash during sending becomes uncertain")
        expect(try restart.observe(value, channels: [.weChat], now: now).isEmpty, "interrupted send never automatically retries")
        expect(try restart.observe(value, channels: [.personalWeChat], now: now).count == 1, "unattempted channel stays independently pending")
        let personal = try restart.observe(value, channels: [.personalWeChat], now: now)[0]
        let revoked = try restart.reserve(personal, revision: revision, now: now)!
        expect(try !restart.record(revoked, receipt: .accepted, currentRevision: UUID(), now: now), "revoked connection cannot mark accepted")
        expect(try restart.markUncertain(revoked, now: now), "revoked connection closes only original sending attempt")
        expect(try !restart.markUncertain(revoked, now: now), "uncertain attempt is terminal for repeated stale callbacks")
        expect(try restart.observe(value, channels: [.personalWeChat], now: now).isEmpty, "revoked in-flight send cannot restart automatically")
        expect(try !restart.markUncertain(claim, now: now), "accepted attempt cannot be overwritten uncertain")
        expect(try !restart.releaseUnsent(claim, now: now), "accepted attempt cannot be reset pending")
        expect(try !restart.releaseUnsent(revoked, now: now), "uncertain attempt cannot become a retry via releaseUnsent")
        expect(transport.sends == 1, "fake transport only and no retry of terminal channels")
        let json = String(data: try Data(contentsOf: ledger.url), encoding: .utf8)!
        expect(!json.contains("synthetic-account-a") && !json.contains("card-one") && !json.contains("card-two"), "ledger persists only hashes and structured facts")

        let accepted = MessageDeliveryOutcome.accepted(.init(acceptedAt: now, remoteMessageID: nil))
        expect(CodexResetNoticeDeliveryReceipt.messageChannel(.success(accepted)) == .accepted, "API accepted classifies accepted only")
        expect(CodexResetNoticeDeliveryReceipt.messageChannel(.success(.duplicateSkipped)) == .uncertain, "volatile duplicate is not a sent proof")
        for error in [MessageChannelError.missingCredential, .encodingFailed, .channelDisabled, .invalidStatus, .staleStatus] {
            expect(CodexResetNoticeDeliveryReceipt.messageChannel(.failure(error)) == .notSent, "proven admission failure is retryable")
        }
        for error in [MessageChannelError.transportFailed, .invalidResponse, .redirected, .cancelled, .httpStatus(500)] {
            expect(CodexResetNoticeDeliveryReceipt.messageChannel(.failure(error)) == .uncertain, "possibly sent outcome is uncertain")
        }
        expect(CodexResetNoticeDeliveryReceipt.messageChannel(.failure(.rateLimited(retryAfterSeconds: 60))) == .rejected, "explicit rate limit is retryable")
        expect(CodexResetNoticeDeliveryReceipt.messageChannel(.failure(.rejected(code: 1, description: nil))) == .rejected, "explicit validated rejection is retryable")
        print("PASS delivery: independent channels, stable claims, revisions, retries, uncertain recovery and safe receipts")

        let unsent = store("unsent-release", root: root)
        let staged = try unsent.observe(value, channels: [.local], now: now)[0]
        let reserved = try unsent.reserve(staged, revision: revision, now: now)!
        let wrongRevision = CodexResetNoticeReservation(delivery: staged,
            attemptID: reserved.attemptID, revision: UUID(), reservedAt: now)
        expect(try !unsent.releaseUnsent(wrongRevision, now: now), "wrong owned revision cannot release reservation")
        expect(try unsent.isCurrent(reserved, now: now), "wrong release leaves original sending")
        expect(try unsent.releaseUnsent(reserved, now: now), "zero-transport proof releases exact owned reservation")
        expect(try unsent.read().records[staged.keys[0]]?.phase == .pending, "released reservation persists retryable pending")
        let replacement = try unsent.reserve(staged, revision: UUID(), now: now)!
        expect(replacement.attemptID != reserved.attemptID, "rebind retry owns a new attempt")
        expect(try !unsent.releaseUnsent(reserved, now: now), "stale release cannot modify rebind attempt")
        expect(try unsent.isCurrent(replacement, now: now), "rebind attempt remains sending after stale release")
        print("PASS unsent release: only zero-transport owned attempt can return pending")
    }

    static func changeTests(root: URL) throws {
        let ledger = store("change", root: root)
        _ = try ledger.observe(observation(nil, count: 3), channels: [], now: now)
        let before = now.addingTimeInterval(-86_400)
        let pending = try ledger.enqueueChange(accountHash: account, previous: 1, available: 3,
            previousObservedAt: before, observedAt: now, channels: [.local], now: now)
        expect(pending.count == 1, "trusted long-gap increase enters same durable ledger")
        let first = try ledger.reserve(pending[0], revision: revision, now: now)!
        _ = try ledger.record(first, receipt: .notSent, currentRevision: revision, now: now)
        let later = now.addingTimeInterval(60)
        _ = try ledger.observe(observation(nil, count: 3, at: later), channels: [], now: later)
        let reboot = CodexResetNoticeDeliveryStore(url: ledger.url)
        let retry = try reboot.enqueueChange(accountHash: account, previous: 1, available: 3,
            previousObservedAt: before, observedAt: now, channels: [.local], createIfMissing: false, now: later)
        expect(retry.count == 1, "existing pending receipt retries after newer fresh same-count observation")
        let second = try reboot.reserve(retry[0], revision: revision, now: later)!
        _ = try reboot.record(second, receipt: .accepted, currentRevision: revision, now: later)
        expect(try reboot.enqueueChange(accountHash: account, previous: 1, available: 3,
            previousObservedAt: before, observedAt: now, channels: [.local], createIfMissing: false, now: later).isEmpty, "sent change is not retried after restart")
        let noFlood = store("old-receipt", root: root)
        _ = try noFlood.observe(observation(nil, count: 3, at: later), channels: [], now: later)
        expect(try noFlood.enqueueChange(accountHash: account, previous: 1, available: 3,
            previousObservedAt: before, observedAt: now, channels: [.local], createIfMissing: false, now: later).isEmpty,
            "upgrade cannot stage absent historical receipt")
        expect(try noFlood.read().records.isEmpty, "no-flood path makes no pending record")

        let decrease = store("decrease", root: root)
        _ = try decrease.observe(observation(nil, count: 0), channels: [], now: now)
        let down = try decrease.enqueueChange(accountHash: account, previous: 1, available: 0,
            previousObservedAt: before, observedAt: now, channels: [.local], now: now)
        expect(down.count == 1, "1 to 0 decrease uses same ledger without use inference")
        _ = try decrease.observe(observation(nil, count: 1, at: later), channels: [], now: later)
        expect(try decrease.reserve(down[0], revision: revision, now: later) == nil, "updated count blocks outdated pending change")
        expect(try decrease.enqueueChange(accountHash: account, previous: 1, available: 0,
            previousObservedAt: before, observedAt: now, channels: [.local], createIfMissing: false, now: later).isEmpty, "outdated pending change is not restored")
        _ = try decrease.observe(observation(nil, at: later.addingTimeInterval(1), verified: false), channels: [], now: later.addingTimeInterval(1))
        expect(try decrease.reserve(down[0], revision: revision, now: later.addingTimeInterval(1)) == nil, "latest verification failure blocks old receipt")
        expect(throwsError { _ = try decrease.enqueueChange(accountHash: account, previous: 0, available: 0,
            previousObservedAt: before, observedAt: now, channels: [.local], now: later) }, "zero delta cannot stage change")
        print("PASS changes: durable delta receipt, fresh retry, upgrade no-flood, zero/decrease and outdated suppression")
    }

    static func write(_ ledger: CodexResetNoticeDeliveryLedger, to store: CodexResetNoticeDeliveryStore) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(ledger)
        try bytes.write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
    }

    static func retentionTests(root: URL) throws {
        let ledger = store("retention", root: root)
        var initial = CodexResetNoticeDeliveryLedger()
        initial.accounts[account] = observation([], count: 0, at: now.addingTimeInterval(-20))
        let otherAccount = CodexResetNoticeKey.hash("other-retention-account")
        initial.accounts[otherAccount] = observation([], count: 0, at: now.addingTimeInterval(-20), accountHash: otherAccount)
        var keys: [String: String] = [:]
        for phase in [CodexResetNoticeDeliveryPhase.baseline, .pending, .sending, .sent, .uncertain] {
            let item = CodexResetNoticeCandidate.Content.expiry(cards: [card("old-" + phase.rawValue, -10)])
            let key = CodexResetNoticeKey.item(item, accountHash: account, channel: .local)
            keys[phase.rawValue] = key
            let attempted = phase == .sending || phase == .sent || phase == .uncertain
            initial.records[key] = .init(accountHash: account, channel: .local, item: item, phase: phase,
                observedAt: now.addingTimeInterval(-90_000), updatedAt: now.addingTimeInterval(-20),
                attemptID: attempted ? UUID() : nil, revision: attempted ? revision : nil)
        }
        let future = card("future-sent", 60)
        let futureItem = CodexResetNoticeCandidate.Content.expiry(cards: [future])
        let futureKey = CodexResetNoticeKey.item(futureItem, accountHash: account, channel: .local)
        initial.records[futureKey] = .init(accountHash: account, channel: .local, item: futureItem, phase: .sent,
            observedAt: now.addingTimeInterval(-20), updatedAt: now.addingTimeInterval(-20), attemptID: UUID(), revision: revision)
        let otherItem = CodexResetNoticeCandidate.Content.expiry(cards: [card("other-old-sent", -10)])
        let otherKey = CodexResetNoticeKey.item(otherItem, accountHash: otherAccount, channel: .local)
        initial.records[otherKey] = .init(accountHash: otherAccount, channel: .local, item: otherItem, phase: .sent,
            observedAt: now.addingTimeInterval(-90_000), updatedAt: now.addingTimeInterval(-20), attemptID: UUID(), revision: revision)
        for (index, phase) in [CodexResetNoticeDeliveryPhase.pending, .sending, .uncertain, .sent, .sent].enumerated() {
            let date = now.addingTimeInterval(-Double(index + 1))
            let item = CodexResetNoticeCandidate.Content.change(.init(
                previous: 0, available: 1, previousObservedAt: date.addingTimeInterval(-1), observedAt: date))
            let key = CodexResetNoticeKey.item(item, accountHash: account, channel: .local)
            keys["change-\(index)"] = key
            initial.records[key] = .init(accountHash: account, channel: .local, item: item, phase: phase,
                observedAt: date, updatedAt: date, attemptID: phase == .pending ? nil : UUID(), revision: phase == .pending ? nil : revision)
        }
        try write(initial, to: ledger)
        _ = try ledger.observe(observation([future]), channels: [.local], now: now)
        let retained = try ledger.read()
        expect(retained.records[keys["baseline"]!] == nil && retained.records[keys["sent"]!] == nil,
            "expiry baseline and sent history are removed after the account's durable observation crosses expiry")
        for phase in ["pending", "sending", "uncertain"] {
            expect(retained.records[keys[phase]!] == initial.records[keys[phase]!], "retention preserves full " + phase + " evidence")
        }
        expect(retained.records[futureKey] == initial.records[futureKey], "live sent expiry retains deduplication")
        expect(retained.records[otherKey] == initial.records[otherKey], "wall-clock passage alone cannot prune another account's expiry")
        for index in 0..<4 {
            expect(retained.records[keys["change-\(index)"]!] == initial.records[keys["change-\(index)"]!],
                "change compaction preserves pending, sending, uncertain and the latest accepted watermark")
        }
        expect(retained.records[keys["change-4"]!] == nil, "only superseded accepted change history is removed")
        let reboot = CodexResetNoticeDeliveryStore(url: ledger.url)
        let rollback = now.addingTimeInterval(-30)
        expect(try reboot.observe(observation([card("old-sent", -10)], at: rollback), channels: [.local], now: rollback).isEmpty,
            "clock rollback cannot revive expiry behind the durable account watermark")
        expect(try reboot.read().records[keys["sent"]!] == nil, "stale rollback response cannot recreate compacted sent history")
        expect(try reboot.observe(observation([future], at: now.addingTimeInterval(1)), channels: [.local], now: now.addingTimeInterval(1)).isEmpty,
            "retained live sent expiry is not sent again after restart")
        expect(try reboot.reserve(.init(channel: .local,
            candidate: .init(accountHash: account, observedAt: now.addingTimeInterval(-90_000), content: initial.records[keys["sent"]!]!.item)),
            revision: revision, now: now) == nil, "stale reservation cannot recreate compacted history")
        print("PASS retention: durable expiry boundary, clock rollback, active/uncertain preservation and restart deduplication")
    }

    static func capacityTests(root: URL) throws {
        for content in ["expiry", "change", "protected"] {
            let ledger = store("capacity-" + content, root: root)
            var initial = CodexResetNoticeDeliveryLedger()
            initial.accounts[account] = observation(nil, count: 2, at: now.addingTimeInterval(-1))
            for index in 0..<CodexResetNoticeDeliveryStore.maximumRecords {
                let observed = now.addingTimeInterval(-Double(index + 2))
                let item: CodexResetNoticeCandidate.Content = content != "change"
                    ? .expiry(cards: [card("capacity-\(index)", -1)])
                    : .change(.init(previous: 1, available: 2, previousObservedAt: observed.addingTimeInterval(-1), observedAt: observed))
                let key = CodexResetNoticeKey.item(item, accountHash: account, channel: .local)
                let phase: CodexResetNoticeDeliveryPhase = content == "protected"
                    ? [.pending, .sending, .uncertain][index % 3] : (content == "expiry" ? .baseline : .sent)
                let attempted = phase == .sending || phase == .sent || phase == .uncertain
                initial.records[key] = .init(accountHash: account, channel: .local, item: item,
                    phase: phase, observedAt: observed, updatedAt: observed,
                    attemptID: attempted ? revision : nil, revision: attempted ? revision : nil)
            }
            expect(initial.isValid, "full " + content + " fixture remains a valid bounded ledger")
            try write(initial, to: ledger)
            if content == "protected" {
                let before = try Data(contentsOf: ledger.url)
                do {
                    _ = try ledger.observe(observation([card("protected-new-card", 60)], count: 3), channels: [.local], now: now)
                    expect(false, "active and unconfirmed capacity must fail closed")
                } catch CodexResetNoticeDeliveryStore.Failure.capacity {
                    expect(true, "active and unconfirmed capacity fails closed")
                }
                expect(try Data(contentsOf: ledger.url) == before && ledger.read() == initial,
                    "capacity never removes pending/sending/uncertain evidence or partially writes the ledger")
                continue
            }
            _ = try ledger.observe(observation([card("next-capacity-card", 60)], count: 3), channels: [.local], now: now)
            let compacted = try ledger.read()
            expect(compacted.records.count == (content == "expiry" ? 1 : 2), "full " + content + " ledger compacts obsolete completed history before capacity rejection")
            let reboot = CodexResetNoticeDeliveryStore(url: ledger.url)
            let later = now.addingTimeInterval(1)
            _ = try reboot.observe(observation(nil, count: 2, at: later), channels: [], now: later)
            if content == "change" {
                let old = now.addingTimeInterval(-100)
                expect(try reboot.enqueueChange(accountHash: account, previous: 1, available: 2,
                    previousObservedAt: old.addingTimeInterval(-1), observedAt: old, channels: [.local], now: later).isEmpty,
                    "compacted sent change cannot be replayed when the account returns to its old count")
                let recent = now.addingTimeInterval(-2)
                expect(try reboot.enqueueChange(accountHash: account, previous: 1, available: 2,
                    previousObservedAt: recent.addingTimeInterval(-1), observedAt: recent, channels: [.local], now: later).isEmpty,
                    "latest retained sent change remains deduplicated")
                expect(try reboot.enqueueChange(accountHash: account, previous: 1, available: 2,
                    previousObservedAt: old.addingTimeInterval(-1), observedAt: old, channels: [.feishu], now: later).count == 1,
                    "sent change watermark is scoped to its own channel")
                let other = CodexResetNoticeKey.hash("other-capacity-account")
                _ = try reboot.observe(observation(nil, count: 2, at: later, accountHash: other), channels: [], now: later)
                expect(try reboot.enqueueChange(accountHash: other, previous: 1, available: 2,
                    previousObservedAt: old.addingTimeInterval(-1), observedAt: old, channels: [.local], now: later).count == 1,
                    "sent change watermark is scoped to its own account")
            }
            let next = try reboot.enqueueChange(accountHash: account, previous: 3, available: 2,
                previousObservedAt: now, observedAt: later, channels: [.local], now: later)
            expect(next.count == 1, "compaction leaves new count-change admission available")
            let reserved = try reboot.reserve(next[0], revision: revision, now: later)!
            _ = try reboot.record(reserved, receipt: .accepted, currentRevision: revision, now: later)
            expect(try reboot.enqueueChange(accountHash: account, previous: 3, available: 2,
                previousObservedAt: now, observedAt: later, channels: [.local], now: later).isEmpty,
                "newest sent change stays as the durable watermark")
        }
        print("PASS capacity: full expiry/change ledgers, persistent change watermarks and isolated account/channel history")
    }

    static func integrityTests(root: URL) throws {
        let malformed = store("malformed", root: root)
        _ = try malformed.observe(observation([card("safe", 60)]), channels: [.local], now: now)
        let invalid = Data("{broken".utf8)
        try invalid.write(to: malformed.url)
        expect(throwsError { _ = try malformed.read() }, "malformed ledger fails closed")
        expect(throwsError { _ = try malformed.observe(observation([card("safe", 60)]), channels: [.local], now: now) }, "malformed ledger is never reset for a retry")
        expect(try Data(contentsOf: malformed.url) == invalid, "malformed evidence is preserved")
        let valid = store("permissions", root: root)
        _ = try valid.observe(observation([card("private", 60)]), channels: [.local], now: now)
        let attributes = try FileManager.default.attributesOfItem(atPath: valid.url.path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "ledger is private")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: valid.directory.path)
        expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "ledger directory is private")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: valid.url.path)
        expect(throwsError { _ = try valid.read() }, "overexposed ledger fails closed")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: valid.url.path)
        let symbolic = store("symlink", root: root)
        try FileManager.default.createDirectory(at: symbolic.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: symbolic.url, withDestinationURL: valid.url)
        expect(throwsError { _ = try symbolic.read() }, "symlink ledger is not followed")
        let fifo = store("fifo", root: root)
        try FileManager.default.createDirectory(at: fifo.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        expect(mkfifo(fifo.url.path, 0o600) == 0, "fixture pipe created")
        expect(throwsError { _ = try fifo.read() }, "nonregular ledger fails closed without a blocking read")
        let hardlink = store("hardlink", root: root)
        try FileManager.default.createDirectory(at: hardlink.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.linkItem(at: valid.url, to: hardlink.url)
        expect(throwsError { _ = try hardlink.read() }, "shared hardlink ledger is not adopted")
        let invalidAge = CodexResetNoticeDeliveryStore(directory: root.appendingPathComponent("infinite-age"), maximumObservationAge: .infinity)
        expect(throwsError { _ = try invalidAge.observe(observation([card("age", 60)]), channels: [.local], now: now) }, "unbounded freshness is rejected")
        print("PASS integrity: malformed preservation, private files, symlink/hardlink and bounded freshness")
    }
}
