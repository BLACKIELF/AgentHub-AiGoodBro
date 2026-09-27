import Foundation

/// Ports token-monitor's live-rate counter semantics. The denominator is
/// tokScale's measured model duration, never wall time between app refreshes.
/// One successful response advances one local-device baseline.
final class TokenMonitorEdgeDockRateTracker {
    static let activeInterval: TimeInterval = 8
    static let retentionInterval: TimeInterval = 180

    private struct Counters: Equatable {
        let timedTokens: Int64
        let timedOutputTokens: Int64
        let timedDurationMs: Int64
    }

    private struct Context: Equatable {
        let day: String
        let timezone: String
        let sources: [String]
    }

    private var baseline: Counters?
    private var context: Context?
    private var lastSpeed: Double?
    private var lastBurn: Double?
    private var lastSampledAt: Date?

    func reset() {
        baseline = nil
        context = nil
        lastSpeed = nil
        lastBurn = nil
        lastSampledAt = nil
    }

    @discardableResult
    func observe(response: TokenMonitorResponse?, now: Date = Date()) -> TokenMonitorEdgeDockRateSample? {
        guard let response, response.status != .error,
            let counters = Self.counters(in: response),
            let context = Self.context(for: response)
        else {
            reset()
            return nil
        }
        guard self.context == context, let previous = baseline else {
            self.context = context
            baseline = counters
            lastSpeed = nil
            lastBurn = nil
            lastSampledAt = nil
            return nil
        }
        baseline = counters
        let (tokens, tokensOverflow) = counters.timedTokens.subtractingReportingOverflow(previous.timedTokens)
        let (output, outputOverflow) = counters.timedOutputTokens.subtractingReportingOverflow(previous.timedOutputTokens)
        let (duration, durationOverflow) = counters.timedDurationMs.subtractingReportingOverflow(previous.timedDurationMs)
        guard !tokensOverflow, !outputOverflow, !durationOverflow,
            tokens >= 0, output >= 0, duration >= 0
        else {
            lastSpeed = nil
            lastBurn = nil
            lastSampledAt = nil
            return nil
        }
        // Equal/limits-only pushes retain the prior sample. A zero-duration
        // increment carries no performance denominator and cannot produce one.
        if duration > 0 {
            lastSpeed = Self.rate(Double(output) * 1_000 / Double(duration))
            lastBurn = Self.rate(Double(tokens) * 60_000 / Double(duration))
            lastSampledAt = now
        }
        return current(now: now)
    }

    func current(now: Date = Date()) -> TokenMonitorEdgeDockRateSample? {
        guard let speed = lastSpeed, let burn = lastBurn, let sampledAt = lastSampledAt else { return nil }
        let age = now.timeIntervalSince(sampledAt)
        guard age.isFinite, age >= 0, age < Self.retentionInterval else { return nil }
        let isIdle = age >= Self.activeInterval
        return TokenMonitorEdgeDockRateSample(
            speed: speed, burn: burn, sampledAt: sampledAt,
            expiresAt: sampledAt.addingTimeInterval(isIdle ? Self.retentionInterval : Self.activeInterval),
            isIdle: isIdle
        )
    }

    func nextExpiryAt(now: Date = Date()) -> Date? { current(now: now)?.expiresAt }

    private static func rate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(1e12, value)
    }

    private static func counters(in response: TokenMonitorResponse) -> Counters? {
        let period = response.payload["aggregate"]?["today"]
        if case .some(.bool(false)) = period?["capabilities"]?["throughput"] { return nil }
        guard let timedTokens = TokenMonitorDashboardSnapshot.integer(period?["timedTokens"]),
            let timedOutputTokens = TokenMonitorDashboardSnapshot.integer(period?["timedOutputTokens"]),
            let timedDurationMs = TokenMonitorDashboardSnapshot.integer(period?["timedDurationMs"]),
            timedOutputTokens <= timedTokens
        else { return nil }
        return Counters(
            timedTokens: timedTokens,
            timedOutputTokens: timedOutputTokens,
            timedDurationMs: timedDurationMs
        )
    }

    private static func context(for response: TokenMonitorResponse) -> Context? {
        guard let collectedAt = TokenMonitorResponse.timestamp(response.collectedAt),
            let timezone = TimeZone(identifier: response.timezone)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return Context(
            day: formatter.string(from: collectedAt), timezone: response.timezone,
            sources: response.sources.filter { $0.status != .excluded }
                .map { "\($0.id):\($0.providerId):\($0.status.rawValue)" }.sorted()
        )
    }
}
