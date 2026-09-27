import Foundation

/// Forecast deliveries have their own durable phases, separate from completed
/// reset announcements. The source post ID may later appear in both stages.
struct PublicResetForecastDeliveryLedger: Codable, Equatable {
    enum Phase: String, Codable { case baseline, pending, sending, sent, uncertain }

    var schemaVersion = 1
    var initialized = false
    var records: [String: Phase] = [:]
    var observedDates: [String: Date] = [:]
    var newestObservedAt: Date?
    var retiredThrough: Date?

    var isValid: Bool {
        schemaVersion == 1
            && records.count <= 500
            && observedDates.count <= 500
            && records.keys.allSatisfy(Self.validID)
            && observedDates.allSatisfy { records[$0.key] != nil && $0.value.timeIntervalSince1970.isFinite }
            && newestObservedAt?.timeIntervalSince1970.isFinite != false
            && retiredThrough?.timeIntervalSince1970.isFinite != false
    }

    /// First valid observation establishes a baseline. Later newer source posts
    /// enter pending; nil forecasts initialize an empty baseline without using
    /// a fetch timestamp as a publication date.
    mutating func observe(
        _ state: PublicResetForecastPageState, now: Date = Date()
    ) throws -> PublicResetForecast? {
        guard now.timeIntervalSince1970.isFinite else { throw PublicResetFailure.localState }
        guard case .forecast(let forecast) = state else {
            initialized = true
            return nil
        }
        guard forecast.isValid(referenceDate: now) else { throw PublicResetForecastFailure.invalidResponse }

        if let phase = records[forecast.id] {
            return phase == .pending ? forecast : nil
        }
        if retiredThrough.map({ forecast.announcedAt <= $0 }) == true {
            initialized = true
            return nil
        }

        let shouldDeliver = initialized && (newestObservedAt.map { forecast.announcedAt > $0 } ?? true)
        try record(forecast, phase: shouldDeliver ? .pending : .baseline)
        initialized = true
        newestObservedAt = max(newestObservedAt ?? forecast.announcedAt, forecast.announcedAt)
        return shouldDeliver ? forecast : nil
    }

    /// The explicit CLI may send a current baseline once, but never replays a
    /// sent, interrupted, uncertain, or retired forecast.
    mutating func reserveAuthorizedDelivery(_ forecast: PublicResetForecast, now: Date = Date()) throws {
        guard forecast.isValid(referenceDate: now) else { throw PublicResetFailure.localState }
        let existing = records[forecast.id]
        let isNewer = newestObservedAt.map { forecast.announcedAt > $0 } ?? true
        guard existing == nil ? isNewer : (existing == .baseline || existing == .pending),
            retiredThrough.map({ forecast.announcedAt > $0 }) ?? true
        else { throw PublicResetFailure.localState }
        try record(forecast, phase: .sending)
        initialized = true
        newestObservedAt = max(newestObservedAt ?? forecast.announcedAt, forecast.announcedAt)
    }

    mutating func recoverInterruptedSends() {
        for id in records.keys where records[id] == .sending { records[id] = .uncertain }
    }

    mutating func setPhase(_ phase: Phase, for id: String) throws {
        guard records[id] != nil else { throw PublicResetFailure.localState }
        records[id] = phase
    }

    private mutating func record(_ forecast: PublicResetForecast, phase: Phase) throws {
        guard Self.validID(forecast.id) else { throw PublicResetFailure.localState }
        if records[forecast.id] == nil, records.count >= 500 {
            let terminal = records.keys.filter { id in
                guard let phase = records[id] else { return false }
                return [.baseline, .sent].contains(phase) && observedDates[id] != nil
            }.sorted { observedDates[$0]! < observedDates[$1]! }
            for id in terminal where records.count >= 500 {
                let date = observedDates.removeValue(forKey: id)!
                retiredThrough = max(retiredThrough ?? date, date)
                records.removeValue(forKey: id)
            }
        }
        guard records[forecast.id] != nil || records.count < 500 else { throw PublicResetFailure.queueFull }
        records[forecast.id] = phase
        observedDates[forecast.id] = forecast.announcedAt
    }

    private static func validID(_ id: String) -> Bool {
        (1...20).contains(id.count) && id.allSatisfy(\.isNumber) && UInt64(id) != nil
    }
}

/// The CLI compares the source's publication timestamps. In particular, a
/// forecast's fetchedAt is never considered when deciding which message is newer.
enum PublicResetMessageCandidate: Equatable {
    case forecast(PublicResetForecast)
    case completed(PublicResetAnnouncement)

    var publishedAt: Date {
        switch self {
        case .forecast(let forecast): forecast.announcedAt
        case .completed(let announcement): announcement.announcedAt
        }
    }

    var id: String {
        switch self {
        case .forecast(let forecast): forecast.id
        case .completed(let announcement): announcement.id
        }
    }

    static func latest(
        completed: [PublicResetAnnouncement], forecast: PublicResetForecastPageState, now: Date
    ) -> Self? {
        var candidates = completed.filter { $0.isValid(now: now) }.map(Self.completed)
        if case .forecast(let value) = forecast, value.isValid(referenceDate: now) {
            candidates.append(.forecast(value))
        }
        return candidates.max { left, right in
            if left.publishedAt != right.publishedAt { return left.publishedAt < right.publishedAt }
            // Stable tie break: compare X snowflakes when both IDs are numeric,
            // then prefer a completed row only for an exact unresolved tie.
            if let leftID = UInt64(left.id), let rightID = UInt64(right.id), leftID != rightID {
                return leftID < rightID
            }
            if case .forecast = left, case .completed = right { return true }
            return false
        }
    }
}
