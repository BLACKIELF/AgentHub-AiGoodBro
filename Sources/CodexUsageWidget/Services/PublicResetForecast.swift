import Combine
import Foundation

/// A scheduled public reset claim from the tracker banner. This is deliberately
/// not a `PublicResetAnnouncement`: forecasts use a separate delivery ledger
/// and never enter completed history, history counts, or account quota state.
struct PublicResetForecast: Codable, Equatable, Identifiable {
    enum Phase: Equatable { case scheduled, awaitingConfirmation }

    let id: String
    let latestBy: Date?
    let announcedAt: Date
    let sourceURL: URL
    let fetchedAt: Date

    var phase: Phase {
        phase(at: Date())
    }

    func phase(at now: Date) -> Phase {
        guard let latestBy, latestBy > now else { return .awaitingConfirmation }
        return .scheduled
    }

    func isValid(referenceDate: Date) -> Bool {
        guard Self.validSourceURL(sourceURL, expectedID: id),
            announcedAt.timeIntervalSince1970.isFinite,
            fetchedAt.timeIntervalSince1970.isFinite,
            announcedAt > Date(timeIntervalSince1970: 1_700_000_000),
            announcedAt <= fetchedAt.addingTimeInterval(300),
            announcedAt >= fetchedAt.addingTimeInterval(-90 * 24 * 60 * 60)
        else { return false }
        guard let latestBy else { return true }
        return latestBy.timeIntervalSince1970.isFinite
            && latestBy >= announcedAt.addingTimeInterval(-300)
            && latestBy <= fetchedAt.addingTimeInterval(14 * 24 * 60 * 60)
            && latestBy <= referenceDate.addingTimeInterval(14 * 24 * 60 * 60)
    }

    func isRetainableCache(at now: Date) -> Bool {
        isValid(referenceDate: now)
            && fetchedAt <= now.addingTimeInterval(300)
            && fetchedAt >= now.addingTimeInterval(-72 * 60 * 60)
    }

    static func validSourceURL(_ url: URL, expectedID: String? = nil) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "https", parts.host == "x.com", parts.user == nil, parts.password == nil,
            parts.port == nil, parts.query == nil, parts.fragment == nil
        else { return false }
        let prefix = "/thsottiaux/status/"
        guard parts.path.hasPrefix(prefix) else { return false }
        let id = String(parts.path.dropFirst(prefix.count))
        return (1...20).contains(id.count) && id.allSatisfy(\.isNumber)
            && (expectedID == nil || expectedID == id)
    }

    static func sourcePostDate(for id: String) -> Date? {
        guard id.allSatisfy(\.isNumber), let snowflake = UInt64(id) else { return nil }
        let twitterEpochMilliseconds: UInt64 = 1_288_834_974_657
        let milliseconds = (snowflake >> 22) + twitterEpochMilliseconds
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        return date.timeIntervalSince1970.isFinite ? date : nil
    }

    static func sourcePostID(at date: Date) -> String? {
        let milliseconds = date.timeIntervalSince1970 * 1000
        let twitterEpochMilliseconds: Double = 1_288_834_974_657
        guard milliseconds.isFinite, milliseconds >= twitterEpochMilliseconds,
            milliseconds < Double(UInt64.max)
        else { return nil }
        return String((UInt64(milliseconds) - UInt64(twitterEpochMilliseconds)) << 22)
    }
}

/// An unsourced watch displayed by the third-party tracker. It is not a
/// forecast, an official announcement, or eligible for notification delivery.
struct PublicResetSiteWatch: Equatable {
    let latestBy: Date
    let fetchedAt: Date

    func isValid(at now: Date) -> Bool {
        fetchedAt.timeIntervalSince1970.isFinite && latestBy.timeIntervalSince1970.isFinite
            && fetchedAt <= now.addingTimeInterval(300)
            && fetchedAt >= now.addingTimeInterval(-300)
            && latestBy >= fetchedAt.addingTimeInterval(-72 * 60 * 60)
            && latestBy <= fetchedAt.addingTimeInterval(14 * 24 * 60 * 60)
    }
}

enum PublicResetForecastPageState: Equatable {
    case forecast(PublicResetForecast)
    case siteWatch(PublicResetSiteWatch)
    case none(fetchedAt: Date)
}

enum PublicResetForecastFailure: LocalizedError {
    case invalidResponse, unavailable, cacheWriteFailed
    case retryLater(Int)

    var errorDescription: String? {
        let language = WidgetLanguage.storedOrAutomatic()
        switch self {
        case .invalidResponse:
            return language.text("公开预告页面无法验证；未覆盖已有预告缓存", "The public forecast page could not be verified; the existing forecast cache was preserved.")
        case .cacheWriteFailed:
            return language.text("暂时无法保存预告；本次更新未应用", "The forecast could not be saved; this update was not applied.")
        case .unavailable:
            return language.text("公开预告暂时无法获取；历史记录仍可单独刷新", "The public forecast is temporarily unavailable; history can still refresh independently.")
        case .retryLater(let seconds):
            return language.text("公开预告服务限流，请在 \(seconds) 秒后重试", "The public forecast source is rate limited; retry in \(seconds) seconds.")
        }
    }
}

/// Parses only the tracker page's maintained server-rendered forecast
/// attributes. It does not execute scripts or interpret arbitrary page code.
enum PublicResetForecastParser {
    static let maximumPayloadBytes = 1024 * 1024

    static func parse(_ data: Data, fetchedAt: Date) throws -> PublicResetForecastPageState {
        guard data.count <= maximumPayloadBytes, let html = String(data: data, encoding: .utf8),
            !html.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw PublicResetForecastFailure.invalidResponse }

        let lower = html.lowercased()
        // Absence is authoritative only for a recognizable tracker document.
        guard lower.contains("<html"), lower.contains("codex-resets"), lower.contains("hero-figure") else {
            throw PublicResetForecastFailure.invalidResponse
        }

        let watchPattern = #"<([A-Za-z][A-Za-z0-9:-]*)\b[^>]{0,8192}\bdata-role\s*=\s*(['\"])(?:scheduled-reset|reset-watch)\2[^>]*>"#
        let matches = try regex(watchPattern).matches(in: html, range: fullRange(html))
        guard matches.count <= 1 else { throw PublicResetForecastFailure.invalidResponse }
        guard let match = matches.first else {
            // A changed banner is not evidence that a forecast was withdrawn.
            // Only the known, empty pending container may clear a saved forecast.
            let emptyPending = #"<div\b[^>]{0,8192}\bdata-role\s*=\s*(['\"])pending-reset\1[^>]*>\s*</div>"#
            guard try regex(emptyPending).numberOfMatches(in: html, range: fullRange(html)) == 1 else {
                throw PublicResetForecastFailure.invalidResponse
            }
            return .none(fetchedAt: fetchedAt)
        }

        guard let tagRange = Range(match.range(at: 1), in: html),
            let startRange = Range(match.range, in: html)
        else { throw PublicResetForecastFailure.invalidResponse }
        let tagName = String(html[tagRange])
        let startTag = String(html[startRange])
        let attributes = try parsedAttributes(startTag)
        guard let role = attributes["data-role"], ["scheduled-reset", "reset-watch"].contains(role) else {
            throw PublicResetForecastFailure.invalidResponse
        }

        let afterStart = startRange.upperBound..<html.endIndex
        guard
            let closing = html.range(
                of: "</\(tagName)>", options: [.caseInsensitive], range: afterStart),
            html.distance(from: startRange.lowerBound, to: closing.upperBound) <= 64 * 1024
        else { throw PublicResetForecastFailure.invalidResponse }
        let watchHTML = String(html[startRange.lowerBound..<closing.upperBound])
        let links = try sourceLinks(in: watchHTML)
        let latestBy: Date?
        let deadlineAttribute = role == "scheduled-reset" ? "data-scheduled-for" : "data-expires-at"
        if let rawDeadline = attributes[deadlineAttribute] {
            if role == "scheduled-reset", rawDeadline.isEmpty {
                latestBy = nil
            } else {
                guard !rawDeadline.isEmpty, let parsed = parseISO8601(rawDeadline) else {
                    throw PublicResetForecastFailure.invalidResponse
                }
                latestBy = parsed
            }
        } else if role == "reset-watch" {
            latestBy = nil
        } else {
            throw PublicResetForecastFailure.invalidResponse
        }
        if links.isEmpty, role == "reset-watch", tagName.lowercased() == "section",
            let latestBy,
            // An unlinked rumor is displayed only when the known site marker is
            // present and there is no other link masquerading as a source.
            try hasRumorMarker(in: watchHTML),
            try regex(#"<a\b[^>]{0,8192}>"#).numberOfMatches(in: watchHTML, range: fullRange(watchHTML)) == 0
        {
            let watch = PublicResetSiteWatch(latestBy: latestBy, fetchedAt: fetchedAt)
            guard watch.isValid(at: fetchedAt) else { throw PublicResetForecastFailure.invalidResponse }
            return .siteWatch(watch)
        }
        guard links.count == 1, let sourceURL = links.first,
            let id = sourceURL.pathComponents.last,
            let announcedAt = dateFromXPostID(id)
        else { throw PublicResetForecastFailure.invalidResponse }
        let forecast = PublicResetForecast(
            id: id, latestBy: latestBy, announcedAt: announcedAt,
            sourceURL: sourceURL, fetchedAt: fetchedAt)
        guard forecast.isValid(referenceDate: fetchedAt) else {
            throw PublicResetForecastFailure.invalidResponse
        }
        return .forecast(forecast)
    }

    private static func hasRumorMarker(in html: String) throws -> Bool {
        let matches = try regex(#"<p\b[^>]{0,8192}>"#).matches(in: html, range: fullRange(html))
        var count = 0
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let attributes = try parsedAttributes(String(html[range]))
            if attributes["class"]?.split(whereSeparator: \.isWhitespace).contains("watch-rumor") == true {
                count += 1
            }
        }
        return count == 1
    }

    private static func sourceLinks(in html: String) throws -> Set<URL> {
        let anchorPattern = #"<a\b[^>]{0,8192}>"#
        let matches = try regex(anchorPattern).matches(in: html, range: fullRange(html))
        var result = Set<URL>()
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let attributes = try parsedAttributes(String(html[range]))
            guard let href = attributes["href"], !href.contains("&"), let url = URL(string: href) else { continue }
            if PublicResetForecast.validSourceURL(url) { result.insert(url) }
        }
        return result
    }

    private static func parsedAttributes(_ tag: String) throws -> [String: String] {
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(['\"])(.*?)\2"#
        let matches = try regex(pattern, dotMatchesLineSeparators: true).matches(in: tag, range: fullRange(tag))
        var attributes: [String: String] = [:]
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: tag),
                let valueRange = Range(match.range(at: 3), in: tag)
            else { throw PublicResetForecastFailure.invalidResponse }
            let name = tag[nameRange].lowercased()
            guard attributes[name] == nil else { throw PublicResetForecastFailure.invalidResponse }
            attributes[name] = String(tag[valueRange])
        }
        return attributes
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func dateFromXPostID(_ value: String) -> Date? {
        PublicResetForecast.sourcePostDate(for: value)
    }

    private static func regex(_ pattern: String, dotMatchesLineSeparators: Bool = false) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(
                pattern: pattern,
                options: dotMatchesLineSeparators ? [.dotMatchesLineSeparators] : [])
        } catch {
            throw PublicResetForecastFailure.invalidResponse
        }
    }

    private static func fullRange(_ value: String) -> NSRange {
        NSRange(value.startIndex..<value.endIndex, in: value)
    }
}

struct PublicResetForecastClient {
    // The root redirects by locale; use the observed canonical page while
    // retaining the no-redirect boundary for the public data request.
    static let endpoint = URL(string: "https://codex-resets.com/zh-CN")!

    func fetch(timeout: TimeInterval = 20) async throws -> PublicResetForecastPageState {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = min(20, max(1, timeout))
        configuration.timeoutIntervalForResource = min(25, max(1, timeout))
        let guardDelegate = PublicResetRedirectGuard()
        let session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("CodexAccountManagerNext/1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PublicResetForecastFailure.invalidResponse }
        if http.statusCode == 429 {
            let delay = min(86_400, max(300, Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900))
            throw PublicResetForecastFailure.retryLater(delay)
        }
        guard http.statusCode == 200, http.mimeType?.lowercased() == "text/html",
            http.url == Self.endpoint,
            response.expectedContentLength < 0 || response.expectedContentLength <= Int64(PublicResetForecastParser.maximumPayloadBytes)
        else { throw PublicResetForecastFailure.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < PublicResetForecastParser.maximumPayloadBytes else {
                throw PublicResetForecastFailure.invalidResponse
            }
            data.append(byte)
        }
        return try PublicResetForecastParser.parse(data, fetchedAt: Date())
    }
}

private struct PublicResetForecastCache: Codable {
    var schemaVersion = 1
    let checkedAt: Date
    let forecast: PublicResetForecast?

    static func decode(_ data: Data, now: Date) throws -> Self {
        guard data.count <= 64 * 1024 else { throw PublicResetForecastFailure.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.checkedAt.timeIntervalSince1970.isFinite,
            value.checkedAt <= now.addingTimeInterval(300),
            value.checkedAt >= now.addingTimeInterval(-72 * 60 * 60),
            value.forecast?.isRetainableCache(at: now) != false
        else { throw PublicResetForecastFailure.invalidResponse }
        return value
    }
}

/// Independent forecast state. A forecast failure never changes history state,
/// and a successful no-forecast response replaces the cache with a tombstone.
@MainActor
final class PublicResetForecastStore: ObservableObject {
    static let shared = PublicResetForecastStore()

    @Published private(set) var forecast: PublicResetForecast?
    @Published private(set) var siteWatch: PublicResetSiteWatch?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var status: String?
    @Published private(set) var checking = false
    @Published private(set) var isShowingCache = false

    private let cacheURL: URL
    private let persistCache: (Data, URL) throws -> Void
    private let fetchForecast: () async throws -> PublicResetForecastPageState
    private var task: Task<Void, Never>?
    private var retryNotBefore = Date.distantPast

    init(
        supportDirectory: URL? = nil,
        persistCache: @escaping (Data, URL) throws -> Void = { try PrivateLocalFileStore.write($0, to: $1) },
        fetchForecast: @escaping () async throws -> PublicResetForecastPageState = {
            try await PublicResetForecastClient().fetch()
        }
    ) {
        let directory = supportDirectory ?? DispatchParticipationPaths.supportDirectory()
        cacheURL = directory.appendingPathComponent("public-reset-forecast-v1.json")
        self.fetchForecast = fetchForecast
        self.persistCache = persistCache
        if let data = try? DispatchParticipationSync.readBoundedRegularFile(
            cacheURL, maximumBytes: 64 * 1024, allowMissing: true),
            let cached = try? PublicResetForecastCache.decode(data, now: Date())
        {
            forecast = cached.forecast
            checkedAt = cached.checkedAt
            isShowingCache = cached.forecast != nil
        }
    }

    func check(
        now: Date = Date(),
        onSuccessfulFetch: (@MainActor (PublicResetForecastPageState) async -> Void)? = nil
    ) {
        // A rate-limit cooldown must not keep an expired forecast on screen.
        if forecast?.isRetainableCache(at: now) == false {
            forecast = nil
            isShowingCache = false
        }
        if let siteWatch, siteWatch.fetchedAt < now.addingTimeInterval(-60 * 60) {
            self.siteWatch = nil
        }
        guard !checking else { return }
        let language = WidgetLanguage.storedOrAutomatic()
        guard now >= retryNotBefore else {
            let seconds = max(1, Int(ceil(retryNotBefore.timeIntervalSince(now))))
            status = PublicResetForecastFailure.retryLater(seconds).localizedDescription
            return
        }
        checking = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                checking = false
                task = nil
            }
            do {
                let state = try await fetchForecast()
                guard !Task.isCancelled else { return }
                try applyPage(state, now: Date())
                guard !Task.isCancelled else { return }
                await onSuccessfulFetch?(state)
            } catch let failure as PublicResetForecastFailure {
                if case .retryLater(let seconds) = failure {
                    retryNotBefore = Date().addingTimeInterval(Double(seconds))
                }
                retainFreshCacheOrClear(now: Date())
                status = failure.localizedDescription + cacheSuffix(language: language)
            } catch {
                retainFreshCacheOrClear(now: Date())
                status = PublicResetForecastFailure.unavailable.localizedDescription + cacheSuffix(language: language)
            }
        }
    }

    /// Publish only after persistence succeeds, so a failed withdrawal cannot
    /// advance visible state while leaving a contradictory cache on disk.
    func applyPage(_ state: PublicResetForecastPageState, now: Date) throws {
        let next: PublicResetForecast?
        let nextWatch: PublicResetSiteWatch?
        let fetchedAt: Date
        switch state {
        case .forecast(let forecast):
            guard forecast.isRetainableCache(at: now) else { throw PublicResetForecastFailure.invalidResponse }
            next = forecast
            nextWatch = nil
            fetchedAt = forecast.fetchedAt
        case .siteWatch(let watch):
            guard watch.isValid(at: now) else { throw PublicResetForecastFailure.invalidResponse }
            next = nil
            nextWatch = watch
            fetchedAt = watch.fetchedAt
        case .none(let date):
            next = nil
            nextWatch = nil
            fetchedAt = date
        }
        guard fetchedAt.timeIntervalSince1970.isFinite,
            fetchedAt <= now.addingTimeInterval(300), fetchedAt >= now.addingTimeInterval(-300)
        else { throw PublicResetForecastFailure.invalidResponse }
        do { try save(PublicResetForecastCache(checkedAt: fetchedAt, forecast: next)) } catch { throw PublicResetForecastFailure.cacheWriteFailed }
        forecast = next
        siteWatch = nextWatch
        checkedAt = fetchedAt
        isShowingCache = false
        let language = WidgetLanguage.storedOrAutomatic()
        status = next == nil && nextWatch == nil
            ? language.text("当前没有待确认的重置预告", "There is no pending reset forecast") : nil
    }

    private func retainFreshCacheOrClear(now: Date) {
        siteWatch = nil
        if forecast?.isRetainableCache(at: now) == true {
            isShowingCache = true
        } else {
            forecast = nil
            isShowingCache = false
        }
    }

    private func cacheSuffix(language: WidgetLanguage) -> String {
        guard isShowingCache, let checkedAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return language.text(
            "；继续显示 \(formatter.string(from: checkedAt)) 北京时间的已验证缓存",
            "; showing the validated cache from \(formatter.string(from: checkedAt)) Beijing time")
    }

    private func save(_ cache: PublicResetForecastCache) throws {
        let data = try JSONEncoder().encode(cache)
        guard data.count <= 64 * 1024 else { throw PublicResetForecastFailure.invalidResponse }
        try persistCache(data, cacheURL)
    }
}

enum PublicResetForecastSelfTest {
    static func run() -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let fetchedAt = formatter.date(from: "2026-09-22T10:00:00Z"),
            let announcedAt = formatter.date(from: "2026-09-22T05:00:00Z"),
            let deadline = formatter.date(from: "2026-09-23T06:59:00Z")
        else { return fail(#line) }
        let postID = xPostID(for: announcedAt)
        func page(watch: String) -> Data {
            Data("<html><head><title>Codex-Resets</title></head><body><div class=\"hero-figure\" data-datetime=\"2026-09-12T08:09:00Z\"></div>\(watch)</body></html>".utf8)
        }
        func makeForecast(announcedAt: Date, fetchedAt: Date, latestBy: Date? = nil) -> PublicResetForecast {
            let id = xPostID(for: announcedAt)
            return PublicResetForecast(
                id: id, latestBy: latestBy, announcedAt: announcedAt,
                sourceURL: URL(string: "https://x.com/thsottiaux/status/\(id)")!, fetchedAt: fetchedAt)
        }
        let futureHTML = page(
            watch: """
                <section data-role="reset-watch" data-expires-at="2026-09-23T06:59:00Z">
                  <a href="https://x.com/thsottiaux/status/\(postID)">source</a>
                </section>
                """)
        do {
            guard case .forecast(let future) = try PublicResetForecastParser.parse(futureHTML, fetchedAt: fetchedAt),
                future.latestBy == deadline, future.phase(at: fetchedAt) == .scheduled,
                future.phase(at: deadline.addingTimeInterval(1)) == .awaitingConfirmation,
                future.sourceURL.host == "x.com"
            else { return fail(#line) }

            let scheduledHTML = page(
                watch: """
                    <div data-role="pending-reset"><section data-role="scheduled-reset"
                      data-scheduled-key="[&quot;fixture&quot;]" data-scheduled-for="2026-09-23T06:59:00.000Z">
                      <h2>已安排重置</h2><div><a href="https://x.com/thsottiaux/status/\(postID)">查看公告</a></div>
                    </section></div>
                    """)
            guard case .forecast(let scheduled) = try PublicResetForecastParser.parse(scheduledHTML, fetchedAt: fetchedAt),
                scheduled.latestBy == deadline, scheduled.id == postID
            else { return fail(#line) }

            let scheduledTimeUnknownHTML = page(
                watch: "<section data-role=\"scheduled-reset\" data-scheduled-for=\"\"><a href=\"https://x.com/thsottiaux/status/\(postID)\">x</a></section>")
            guard
                case .forecast(let scheduledTimeUnknown) = try PublicResetForecastParser.parse(
                    scheduledTimeUnknownHTML, fetchedAt: fetchedAt
                ), scheduledTimeUnknown.latestBy == nil,
                scheduledTimeUnknown.phase(at: fetchedAt) == .awaitingConfirmation
            else { return fail(#line) }

            let resetWatchWithoutTimeHTML = page(
                watch: "<section data-role=\"reset-watch\"><a href=\"https://x.com/thsottiaux/status/\(postID)\">x</a></section>")
            guard
                case .forecast(let resetWatchWithoutTime) = try PublicResetForecastParser.parse(
                    resetWatchWithoutTimeHTML, fetchedAt: fetchedAt
                ), resetWatchWithoutTime.latestBy == nil
            else { return fail(#line) }

            let unsourcedHTML = page(
                watch: """
                    <section class="watch-card watch-card--strong" data-role="reset-watch" data-expires-at="2026-09-23T06:59:00Z">
                      <p class="watch-rumor">Synthetic site speculation only.</p>
                    </section><div data-role="pending-reset"></div>
                    """)
            guard case .siteWatch(let watch) = try PublicResetForecastParser.parse(unsourcedHTML, fetchedAt: fetchedAt),
                watch.latestBy == deadline, watch.fetchedAt == fetchedAt,
                PublicResetMessageCandidate.latest(completed: [], forecast: .siteWatch(watch), now: fetchedAt) == nil
            else { return fail(#line) }

            guard case .none = try PublicResetForecastParser.parse(page(watch: "<div data-role=\"pending-reset\"> </div>"), fetchedAt: fetchedAt) else {
                return fail(#line)
            }

            let malformed = [
                page(watch: ""),
                page(watch: "<div data-role=\"pending-reset\"><section data-role=\"new-format\">待重置</section></div>"),
                page(watch: "<section data-role=\"scheduled-reset\"><a href=\"https://x.com/thsottiaux/status/\(postID)\">x</a></section>"),
                page(watch: "<section data-role=\"scheduled-reset\" data-scheduled-for=\"not-a-date\"><a href=\"https://x.com/thsottiaux/status/\(postID)\">x</a></section>"),
                page(watch: "<section data-role=\"reset-watch\" data-expires-at=\"not-a-date\"><a href=\"https://x.com/thsottiaux/status/\(postID)\">x</a></section>"),
                page(watch: "<section data-role=\"reset-watch\" data-expires-at=\"2026-09-23T06:59:00Z\"><p>Rumor with no marker</p></section>"),
                page(watch: "<section data-role=\"reset-watch\" data-expires-at=\"2026-09-23T06:59:00Z\"><p class=\"not-watch-rumor\">False marker</p></section>"),
                page(watch: "<section data-role=\"scheduled-reset\" data-scheduled-for=\"2026-09-23T06:59:00Z\"><p class=\"watch-rumor\">Rumor</p></section>"),
                page(watch: "<section data-role=\"reset-watch\" data-expires-at=\"2026-10-23T06:59:00Z\"><p class=\"watch-rumor\">Far-future rumor</p></section>"),
                page(watch: "<section data-role=\"reset-watch\" data-expires-at=\"2026-09-23T06:59:00Z\"><p class=\"watch-rumor\">Link with no source</p><a href=\"https://example.invalid\">other</a></section>"),
                page(
                    watch:
                        "<section data-role=\"reset-watch\" data-expires-at=\"2026-09-23T06:59:00Z\"><a href=\"https://x.com.attacker.invalid/thsottiaux/status/\(postID)\">x</a></section>"
                ),
                page(
                    watch:
                        "<section data-role=\"reset-watch\"><a href=\"https://x.com/thsottiaux/status/\(postID)\">x</a></section><section data-role=\"reset-watch\"><a href=\"https://x.com/thsottiaux/status/\(postID)\">x</a></section>"
                ),
            ]
            for fixture in malformed {
                do {
                    _ = try PublicResetForecastParser.parse(fixture, fetchedAt: fetchedAt)
                    return fail(#line)
                } catch PublicResetForecastFailure.invalidResponse {} catch { return fail(#line) }
            }
            let oversized = Data(repeating: 0x20, count: PublicResetForecastParser.maximumPayloadBytes + 1)
            do {
                _ = try PublicResetForecastParser.parse(oversized, fetchedAt: fetchedAt)
                return fail(#line)
            } catch PublicResetForecastFailure.invalidResponse {} catch { return fail(#line) }

            let source = URL(string: "https://x.com/thsottiaux/status/\(postID)")!
            let cached = PublicResetForecast(
                id: postID, latestBy: deadline, announcedAt: announcedAt,
                sourceURL: source, fetchedAt: fetchedAt)
            guard cached.isRetainableCache(at: fetchedAt.addingTimeInterval(71 * 60 * 60)),
                !cached.isRetainableCache(at: fetchedAt.addingTimeInterval(73 * 60 * 60))
            else { return fail(#line) }
            let beijing = PublicResetAnnouncementPresentation.forecastTime(deadline, language: .zh)
            guard beijing.contains("2026年9月23日"), beijing.contains("14:59"),
                beijing.contains("北京时间"),
                PublicResetAnnouncementPresentation.forecastCountdown(cached, now: fetchedAt, language: .zh).contains("预计重置还有"),
                PublicResetAnnouncementPresentation.forecastCountdown(
                    cached, now: deadline.addingTimeInterval(1), language: .zh
                ).contains("等待来源确认")
            else { return fail(#line) }
            let cacheData = try JSONEncoder().encode(PublicResetForecastCache(checkedAt: fetchedAt, forecast: cached))
            guard try PublicResetForecastCache.decode(cacheData, now: fetchedAt.addingTimeInterval(60 * 60)).forecast == cached else {
                return fail(#line)
            }
            do {
                _ = try PublicResetForecastCache.decode(cacheData, now: fetchedAt.addingTimeInterval(73 * 60 * 60))
                return fail(#line)
            } catch {}

            let firstPost = makeForecast(
                announcedAt: fetchedAt.addingTimeInterval(-300), fetchedAt: fetchedAt, latestBy: nil)
            let laterPost = makeForecast(
                announcedAt: fetchedAt.addingTimeInterval(-60), fetchedAt: fetchedAt, latestBy: nil)
            var deliveryLedger = PublicResetForecastDeliveryLedger()
            guard try deliveryLedger.observe(.forecast(firstPost), now: fetchedAt) == nil,
                deliveryLedger.initialized, deliveryLedger.records[firstPost.id] == .baseline,
                try deliveryLedger.observe(.forecast(laterPost), now: fetchedAt) == laterPost,
                deliveryLedger.records[laterPost.id] == .pending
            else { return fail(#line) }

            var interrupted = deliveryLedger
            try interrupted.setPhase(.sending, for: laterPost.id)
            interrupted = try JSONDecoder().decode(
                PublicResetForecastDeliveryLedger.self, from: JSONEncoder().encode(interrupted))
            interrupted.recoverInterruptedSends()
            guard interrupted.records[laterPost.id] == .uncertain,
                try interrupted.observe(.forecast(laterPost), now: fetchedAt) == nil
            else { return fail(#line) }
            do {
                try interrupted.reserveAuthorizedDelivery(laterPost, now: fetchedAt)
                return fail(#line)
            } catch PublicResetFailure.localState {} catch { return fail(#line) }

            var restarted = deliveryLedger
            try restarted.setPhase(.sent, for: laterPost.id)
            restarted = try JSONDecoder().decode(
                PublicResetForecastDeliveryLedger.self, from: JSONEncoder().encode(restarted))
            guard try restarted.observe(.forecast(laterPost), now: fetchedAt) == nil,
                restarted.records[laterPost.id] == .sent
            else { return fail(#line) }

            var emptyBaseline = PublicResetForecastDeliveryLedger()
            guard try emptyBaseline.observe(.none(fetchedAt: fetchedAt), now: fetchedAt) == nil,
                try emptyBaseline.observe(.forecast(laterPost), now: fetchedAt) == laterPost
            else { return fail(#line) }

            let legacyLedgerJSON = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "initialized": true, "records": [postID: "sent"],
            ])
            let legacyLedger = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: legacyLedgerJSON)
            guard legacyLedger.records[postID] == .sent else { return fail(#line) }

            var completedStage = PublicResetDeliveryLedger()
            let samePostCompletion = PublicResetAnnouncement(
                id: laterPost.id, resetType: .regular, announcedAt: laterPost.announcedAt,
                text: "completion fixture",
                source: .init(type: "x_post", author: "thsottiaux", url: laterPost.sourceURL))
            try completedStage.reserveAuthorizedDelivery(samePostCompletion)
            guard completedStage.records[laterPost.id] == .sending,
                restarted.records[laterPost.id] == .sent
            else { return fail(#line) }

            let oldCompleted = PublicResetAnnouncement(
                id: "101", resetType: .regular, announcedAt: fetchedAt.addingTimeInterval(-600), text: "old fixture",
                source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/101")))
            let latestForecastCandidate = PublicResetMessageCandidate.latest(
                completed: [oldCompleted], forecast: .forecast(laterPost), now: fetchedAt)
            guard let latestForecastCandidate,
                case .forecast(let latestForecast) = latestForecastCandidate,
                latestForecast.id == laterPost.id
            else { return fail(#line) }
            let recentFetchOldPost = makeForecast(
                announcedAt: fetchedAt.addingTimeInterval(-1_200), fetchedAt: fetchedAt)
            let latestCompletedCandidate = PublicResetMessageCandidate.latest(
                completed: [oldCompleted], forecast: .forecast(recentFetchOldPost), now: fetchedAt)
            guard let latestCompletedCandidate,
                case .completed(let latestCompleted) = latestCompletedCandidate,
                latestCompleted.id == oldCompleted.id
            else { return fail(#line) }

            let forecastCard = try PublicResetForecastNotification(laterPost, referenceDate: fetchedAt)
            let forecastPayload = try FeishuWebhookService.publicResetForecastPayload(forecastCard, language: .zh)
            let forecastRoot = try JSONSerialization.jsonObject(with: forecastPayload) as? [String: Any]
            let forecastCardJSON = forecastRoot?["card"] as? [String: Any]
            let forecastTitleJSON = forecastCardJSON?["header"] as? [String: Any]
            let forecastTitle = (forecastTitleJSON?["title"] as? [String: Any])?["content"] as? String
            let forecastElements = (forecastCardJSON?["body"] as? [String: Any])?["elements"] as? [[String: Any]]
            let forecastText = forecastElements?.compactMap { $0["content"] as? String }.joined(separator: "\n")
            guard let forecastTitle, let forecastBody = forecastText,
                forecastTitle == "重置预告 · 待确认", forecastBody.contains("预计重置时间"),
                forecastBody.contains("待确认"), forecastBody.contains(forecastCard.sourceURL.absoluteString),
                forecastTitleJSON?["template"] as? String == "orange",
                forecastCardJSON?["schema"] as? String == "2.0",
                forecastBody.contains(PublicResetAnnouncementPresentation.compactEventTime(laterPost.announcedAt, language: .zh)),
                !forecastBody.contains(PublicResetAnnouncementPresentation.compactEventTime(laterPost.fetchedAt, language: .zh))
            else { return fail(#line) }

            let mismatchedDate = PublicResetForecast(
                id: laterPost.id, latestBy: nil, announcedAt: laterPost.announcedAt.addingTimeInterval(1),
                sourceURL: laterPost.sourceURL, fetchedAt: laterPost.fetchedAt)
            do {
                _ = try PublicResetForecastNotification(mismatchedDate, referenceDate: fetchedAt)
                return fail(#line)
            } catch FeishuWebhookError.invalidNotification {} catch { return fail(#line) }
            let hostileURL = PublicResetForecast(
                id: laterPost.id, latestBy: nil, announcedAt: laterPost.announcedAt,
                sourceURL: URL(string: "https://x.com.attacker.invalid/thsottiaux/status/\(laterPost.id)")!,
                fetchedAt: laterPost.fetchedAt)
            do {
                _ = try PublicResetForecastNotification(hostileURL, referenceDate: fetchedAt)
                return fail(#line)
            } catch FeishuWebhookError.invalidNotification {} catch { return fail(#line) }

            let historical = PublicResetAnnouncement(
                id: "101", resetType: .regular, announcedAt: fetchedAt.addingTimeInterval(-86_400),
                text: "completed fixture",
                source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/101")))
            let unchangedHistory = [historical]
            _ = try PublicResetForecastParser.parse(futureHTML, fetchedAt: fetchedAt)
            guard unchangedHistory == [historical], cached.phase(at: deadline.addingTimeInterval(1)) == .awaitingConfirmation else {
                return fail(#line)
            }
            return true
        } catch {
            return fail(#line)
        }
    }

    private static func fail(_ line: Int) -> Bool {
        print("Public reset forecast self-test failed at line \(line)")
        return false
    }

    @MainActor
    static func persistenceSelfTest() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forecast-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let announcedAt = now.addingTimeInterval(-60)
        let id = xPostID(for: announcedAt)
        let forecast = PublicResetForecast(
            id: id, latestBy: now.addingTimeInterval(3600), announcedAt: announcedAt,
            sourceURL: URL(string: "https://x.com/thsottiaux/status/\(id)")!, fetchedAt: now)
        do {
            let initial = PublicResetForecastStore(supportDirectory: root)
            try initial.applyPage(.forecast(forecast), now: now)
            let failing = PublicResetForecastStore(
                supportDirectory: root,
                persistCache: { _, _ in
                    throw CocoaError(.fileWriteNoPermission)
                })
            let watch = PublicResetSiteWatch(latestBy: now.addingTimeInterval(3600), fetchedAt: now.addingTimeInterval(1))
            do {
                try failing.applyPage(.siteWatch(watch), now: now.addingTimeInterval(1))
                return false
            } catch PublicResetForecastFailure.cacheWriteFailed {} catch { return false }
            guard failing.forecast == forecast, failing.siteWatch == nil,
                failing.checkedAt == now, failing.isShowingCache else { return false }
            let restarted = PublicResetForecastStore(supportDirectory: root)
            guard restarted.forecast == failing.forecast, restarted.isShowingCache else { return false }
            try restarted.applyPage(.siteWatch(watch), now: now.addingTimeInterval(1))
            guard restarted.forecast == nil, restarted.siteWatch == watch,
                restarted.checkedAt == watch.fetchedAt, !restarted.isShowingCache else { return false }
            let afterRestart = PublicResetForecastStore(supportDirectory: root)
            guard afterRestart.forecast == nil, afterRestart.siteWatch == nil,
                afterRestart.checkedAt == watch.fetchedAt else { return false }
            try restarted.applyPage(.none(fetchedAt: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))
            return restarted.siteWatch == nil && restarted.forecast == nil
                && restarted.checkedAt == now.addingTimeInterval(2)
        } catch { return false }
    }

    private static func xPostID(for date: Date) -> String {
        PublicResetForecast.sourcePostID(at: date)!
    }
}
