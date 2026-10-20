import Foundation

/// Counts from two comparable official snapshots, including a verified zero change.
/// This does not identify why a count changed or when a card was used or granted.
struct CodexResetCreditComparison: Equatable {
    let previousAvailable: Int
    let available: Int
    let previousObservedAt: Date
    let observedAt: Date

    var delta: Int { available - previousAvailable }

    func isValid(at now: Date) -> Bool {
        previousAvailable >= 0 && available >= 0
            && previousObservedAt.timeIntervalSince1970.isFinite
            && observedAt.timeIntervalSince1970.isFinite
            && previousObservedAt < observedAt && observedAt <= now
    }
}

enum CodexQuotaEvent: Equatable {
    case quotaReset(fiveHour: Bool, sevenDay: Bool)
    case resetCreditsAdded(added: Int, available: Int)
    case resetCreditsChanged(previous: Int, available: Int, previousObservedAt: Date, observedAt: Date)
    case resetCreditsExpiring(batches: [CodexResetCreditExpiryBatch], observedAt: Date)
}

/// Compares fresh official observations only. Startup and missing fields establish
/// a baseline; a clock reaching zero or a local reset-counter edit is not an event.
struct CodexQuotaEventTracker {
    struct Observation {
        let capturedAt: Date
        let limitID: String?
        let fiveHour: RateWindow?
        let sevenDay: RateWindow?
        let resetCredits: Int?
    }

    private var baselines: [String: Observation] = [:]

    mutating func reset() {
        baselines.removeAll()
    }

    mutating func observe(
        _ current: Observation,
        verifiedAccountID: String,
        now: Date = Date()
    ) -> [CodexQuotaEvent] {
        let age = now.timeIntervalSince(current.capturedAt)
        guard !verifiedAccountID.isEmpty, age >= -5, age <= 60 else { return [] }
        let previous = baselines[verifiedAccountID]
        if let previous, current.capturedAt <= previous.capturedAt { return [] }
        baselines = baselines.filter { now.timeIntervalSince($0.value.capturedAt) <= 45 * 60 }
        // Keep observation state bounded without persisting account identifiers.
        if baselines.count >= 128, baselines[verifiedAccountID] == nil,
            let oldest = baselines.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key
        {
            baselines.removeValue(forKey: oldest)
        }
        baselines[verifiedAccountID] = current
        let currentLimitID = current.limitID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousLimitID = previous?.limitID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let previous,
            current.capturedAt.timeIntervalSince(previous.capturedAt) <= 45 * 60,
            let currentLimitID,
            !currentLimitID.isEmpty,
            previousLimitID == currentLimitID
        else { return [] }

        var events: [CodexQuotaEvent] = []
        let fiveHour = Self.didReset(previous.fiveHour, current.fiveHour, now: now)
        let sevenDay = Self.didReset(previous.sevenDay, current.sevenDay, now: now)
        if fiveHour || sevenDay {
            events.append(.quotaReset(fiveHour: fiveHour, sevenDay: sevenDay))
        }
        if let before = previous.resetCredits, let after = current.resetCredits,
            before >= 0, after > before
        {
            events.append(.resetCreditsAdded(added: after - before, available: after))
        }
        return events
    }

    private static func didReset(_ previous: RateWindow?, _ current: RateWindow?, now: Date) -> Bool {
        guard let previous, let current,
            previous.usedPercent.isFinite, current.usedPercent.isFinite,
            (0...100).contains(previous.usedPercent), (0...100).contains(current.usedPercent),
            previous.windowDurationMins == current.windowDurationMins,
            let previousReset = previous.resetsAt
        else { return false }

        // A later official window confirms rollover even if new work has already
        // consumed more than the old window. Merely passing the old deadline does not.
        if let currentReset = current.resetsAt,
            previousReset <= now, currentReset > now,
            currentReset.timeIntervalSince(previousReset) > 120
        {
            return true
        }
        // Early quota restoration requires a meaningful observed drop. Unknown
        // windows never count as fully restored quota.
        return previous.usedPercent >= 1
            && ((current.usedPercent < 0.5 && previousReset <= now)
                || current.usedPercent + 8 <= previous.usedPercent)
    }
}

enum CodexQuotaEventTrackerSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        let now = Date(timeIntervalSince1970: 100_000)
        func window(_ used: Double, _ resetOffset: TimeInterval = 600) -> RateWindow {
            RateWindow(usedPercent: used, windowDurationMins: 300, resetsAt: now.addingTimeInterval(resetOffset))
        }
        func observation(
            _ offset: TimeInterval,
            _ quota: RateWindow?,
            _ credits: Int?,
            limit: String? = "codex"
        ) -> CodexQuotaEventTracker.Observation {
            .init(capturedAt: now.addingTimeInterval(offset), limitID: limit, fiveHour: quota, sevenDay: nil, resetCredits: credits)
        }
        var tracker = CodexQuotaEventTracker()
        expect(tracker.observe(observation(-10, window(80), 1), verifiedAccountID: "account-a", now: now).isEmpty, "startup notified")
        let restored = observation(-5, window(0), 3)
        expect(
            tracker.observe(restored, verifiedAccountID: "account-a", now: now) == [
                .quotaReset(fiveHour: true, sevenDay: false), .resetCreditsAdded(added: 2, available: 3),
            ], "restoration or credit increase missing")
        expect(tracker.observe(restored, verifiedAccountID: "account-a", now: now).isEmpty, "same identity notified twice")
        expect(tracker.observe(observation(-8, window(80), 1), verifiedAccountID: "account-a", now: now).isEmpty, "out-of-order result accepted")
        expect(tracker.observe(observation(-1, window(0), 3), verifiedAccountID: "account-a", now: now).isEmpty, "unchanged refresh notified")
        expect(tracker.observe(observation(0, window(0), 3), verifiedAccountID: "account-b", now: now).isEmpty, "identity change reused baseline")

        tracker.reset()
        _ = tracker.observe(observation(-10, window(10, -1), nil), verifiedAccountID: "account-a", now: now)
        expect(tracker.observe(observation(-5, window(10, -1), 2), verifiedAccountID: "account-a", now: now).isEmpty, "deadline or unknown credit treated as event")
        expect(
            tracker.observe(observation(-1, window(30, 18_000), 2), verifiedAccountID: "account-a", now: now) == [.quotaReset(fiveHour: true, sevenDay: false)],
            "official new window missed")

        tracker.reset()
        _ = tracker.observe(observation(-10, window(80), 2), verifiedAccountID: "account-a", now: now)
        expect(tracker.observe(observation(-5, nil, nil), verifiedAccountID: "account-a", now: now).isEmpty, "missing fields treated as reset")
        expect(tracker.observe(observation(-1, window(0), 3), verifiedAccountID: "account-a", now: now).isEmpty, "field recovery treated as grant")
        expect(tracker.observe(observation(0, window(0), 4, limit: "different"), verifiedAccountID: "account-a", now: now).isEmpty, "different limit bucket compared")
        expect(tracker.observe(observation(-120, window(0), 9), verifiedAccountID: "account-c", now: now).isEmpty, "stale observation accepted")
        expect(tracker.observe(observation(20, window(0), 9), verifiedAccountID: "account-c", now: now).isEmpty, "future observation accepted")
        expect(tracker.observe(observation(0, window(0), 9), verifiedAccountID: "", now: now).isEmpty, "unknown identity accepted")

        tracker.reset()
        _ = tracker.observe(observation(-10, window(80), 1, limit: nil), verifiedAccountID: "account-a", now: now)
        expect(
            tracker.observe(
                observation(-5, window(0), 2, limit: nil),
                verifiedAccountID: "account-a",
                now: now
            ).isEmpty,
            "missing limit identity was treated as one authoritative quota bucket"
        )
        if failures.isEmpty { print("Quota event tracker self-test passed") }
        failures.forEach { print("Quota event tracker self-test failed: \($0)") }
        return failures.isEmpty
    }
}
