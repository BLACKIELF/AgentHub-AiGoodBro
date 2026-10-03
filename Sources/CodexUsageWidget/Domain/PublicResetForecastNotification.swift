import Foundation

/// The public, allowlisted projection used for a pending reset forecast card.
/// It carries the source post time and link, never fetched-at time or page text.
struct PublicResetForecastNotification: Equatable {
    let id: String
    let announcedAt: Date
    let latestBy: Date?
    let sourceURL: URL

    init(_ forecast: PublicResetForecast, referenceDate: Date = Date()) throws {
        guard forecast.isValid(referenceDate: referenceDate),
            Self.matchesSourcePostTime(id: forecast.id, date: forecast.announcedAt),
            Self.validLatestBy(forecast.latestBy, announcedAt: forecast.announcedAt, now: referenceDate)
        else { throw FeishuWebhookError.invalidNotification }
        id = forecast.id
        announcedAt = forecast.announcedAt
        latestBy = forecast.latestBy
        sourceURL = forecast.sourceURL
    }

    func isValid(now: Date = Date()) -> Bool {
        PublicResetForecast.validSourceURL(sourceURL, expectedID: id)
            && Self.matchesSourcePostTime(id: id, date: announcedAt)
            && announcedAt.timeIntervalSince1970.isFinite
            && announcedAt > Date(timeIntervalSince1970: 1_700_000_000)
            && announcedAt <= now.addingTimeInterval(300)
            && announcedAt >= now.addingTimeInterval(-90 * 24 * 60 * 60)
            && Self.validLatestBy(latestBy, announcedAt: announcedAt, now: now)
    }

    private static func validLatestBy(_ date: Date?, announcedAt: Date, now: Date) -> Bool {
        guard let date else { return true }
        return date.timeIntervalSince1970.isFinite
            && date >= announcedAt.addingTimeInterval(-300)
            && date <= now.addingTimeInterval(14 * 24 * 60 * 60)
    }

    private static func matchesSourcePostTime(id: String, date: Date) -> Bool {
        guard let postDate = PublicResetForecast.sourcePostDate(for: id) else { return false }
        return abs(postDate.timeIntervalSince(date)) < 0.001
    }
}
