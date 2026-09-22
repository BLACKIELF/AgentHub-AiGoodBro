import Combine
import Foundation

/// A scheduled public reset claim from the tracker banner. This is deliberately
/// not a `PublicResetAnnouncement`: forecasts never enter delivery ledgers,
/// notification queues, historical counts, or account quota state.
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
}

enum PublicResetForecastPageState: Equatable {
    case forecast(PublicResetForecast)
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
        guard links.count == 1, let sourceURL = links.first,
            let id = sourceURL.pathComponents.last,
            let announcedAt = dateFromXPostID(id)
        else { throw PublicResetForecastFailure.invalidResponse }

        let latestBy: Date?
        let deadlineAttribute = role == "scheduled-reset" ? "data-scheduled-for" : "data-expires-at"
        if let rawDeadline = attributes[deadlineAttribute] {
            guard !rawDeadline.isEmpty, let parsed = parseISO8601(rawDeadline) else {
                throw PublicResetForecastFailure.invalidResponse
            }
            latestBy = parsed
        } else if role == "reset-watch" {
            latestBy = nil
        } else {
            throw PublicResetForecastFailure.invalidResponse
        }
        let forecast = PublicResetForecast(
            id: id, latestBy: latestBy, announcedAt: announcedAt,
            sourceURL: sourceURL, fetchedAt: fetchedAt)
        guard forecast.isValid(referenceDate: fetchedAt) else {
            throw PublicResetForecastFailure.invalidResponse
        }
        return .forecast(forecast)
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
        guard let snowflake = UInt64(value) else { return nil }
        let twitterEpochMilliseconds: UInt64 = 1_288_834_974_657
        let milliseconds = (snowflake >> 22) + twitterEpochMilliseconds
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        return date.timeIntervalSince1970.isFinite ? date : nil
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

    func check() {
        guard !checking else { return }
        let language = WidgetLanguage.storedOrAutomatic()
        guard Date() >= retryNotBefore else {
            let seconds = max(1, Int(ceil(retryNotBefore.timeIntervalSinceNow)))
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
        let fetchedAt: Date
        switch state {
        case .forecast(let forecast):
            guard forecast.isRetainableCache(at: now) else { throw PublicResetForecastFailure.invalidResponse }
            next = forecast
            fetchedAt = forecast.fetchedAt
        case .none(let date):
            next = nil
            fetchedAt = date
        }
        guard fetchedAt.timeIntervalSince1970.isFinite,
            fetchedAt <= now.addingTimeInterval(300), fetchedAt >= now.addingTimeInterval(-300)
        else { throw PublicResetForecastFailure.invalidResponse }
        do { try save(PublicResetForecastCache(checkedAt: fetchedAt, forecast: next)) } catch { throw PublicResetForecastFailure.cacheWriteFailed }
        forecast = next
        checkedAt = fetchedAt
        isShowingCache = false
        let language = WidgetLanguage.storedOrAutomatic()
        status = next == nil ? language.text("当前没有待确认的重置预告", "There is no pending reset forecast") : nil
    }

    private func retainFreshCacheOrClear(now: Date) {
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
        else { return false }
        let postID = xPostID(for: announcedAt)
        func page(watch: String) -> Data {
            Data("<html><head><title>Codex-Resets</title></head><body><div class=\"hero-figure\" data-datetime=\"2026-09-12T08:09:00Z\"></div>\(watch)</body></html>".utf8)
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
            else { return false }

            let scheduledHTML = page(
                watch: """
                    <div data-role="pending-reset"><section data-role="scheduled-reset"
                      data-scheduled-key="[&quot;fixture&quot;]" data-scheduled-for="2026-09-23T06:59:00.000Z">
                      <h2>已安排重置</h2><div><a href="https://x.com/thsottiaux/status/\(postID)">查看公告</a></div>
                    </section></div>
                    """)
            guard case .forecast(let scheduled) = try PublicResetForecastParser.parse(scheduledHTML, fetchedAt: fetchedAt),
                scheduled.latestBy == deadline, scheduled.id == postID
            else { return false }

            guard case .none = try PublicResetForecastParser.parse(page(watch: "<div data-role=\"pending-reset\"> </div>"), fetchedAt: fetchedAt) else {
                return false
            }

            let malformed = [
                page(watch: ""),
                page(watch: "<div data-role=\"pending-reset\"><section data-role=\"new-format\">待重置</section></div>"),
                page(watch: "<section data-role=\"scheduled-reset\"><a href=\"https://x.com/thsottiaux/status/\(postID)\">x</a></section>"),
                page(watch: "<section data-role=\"reset-watch\" data-expires-at=\"not-a-date\"><a href=\"https://x.com/thsottiaux/status/\(postID)\">x</a></section>"),
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
                    return false
                } catch PublicResetForecastFailure.invalidResponse {} catch { return false }
            }
            let oversized = Data(repeating: 0x20, count: PublicResetForecastParser.maximumPayloadBytes + 1)
            do {
                _ = try PublicResetForecastParser.parse(oversized, fetchedAt: fetchedAt)
                return false
            } catch PublicResetForecastFailure.invalidResponse {} catch { return false }

            let source = URL(string: "https://x.com/thsottiaux/status/\(postID)")!
            let cached = PublicResetForecast(
                id: postID, latestBy: deadline, announcedAt: announcedAt,
                sourceURL: source, fetchedAt: fetchedAt)
            guard cached.isRetainableCache(at: fetchedAt.addingTimeInterval(71 * 60 * 60)),
                !cached.isRetainableCache(at: fetchedAt.addingTimeInterval(73 * 60 * 60))
            else { return false }
            let beijing = PublicResetAnnouncementPresentation.forecastTime(deadline, language: .zh)
            guard beijing.contains("2026年9月23日"), beijing.contains("14:59"),
                beijing.contains("北京时间"),
                PublicResetAnnouncementPresentation.forecastCountdown(cached, now: fetchedAt, language: .zh).contains("最晚还有"),
                PublicResetAnnouncementPresentation.forecastCountdown(
                    cached, now: deadline.addingTimeInterval(1), language: .zh
                ).contains("等待来源确认")
            else { return false }
            let cacheData = try JSONEncoder().encode(PublicResetForecastCache(checkedAt: fetchedAt, forecast: cached))
            guard try PublicResetForecastCache.decode(cacheData, now: fetchedAt.addingTimeInterval(60 * 60)).forecast == cached else {
                return false
            }
            do {
                _ = try PublicResetForecastCache.decode(cacheData, now: fetchedAt.addingTimeInterval(73 * 60 * 60))
                return false
            } catch {}

            let historical = PublicResetAnnouncement(
                id: "101", resetType: .regular, announcedAt: fetchedAt.addingTimeInterval(-86_400),
                text: "completed fixture",
                source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/101")))
            let unchangedHistory = [historical]
            _ = try PublicResetForecastParser.parse(futureHTML, fetchedAt: fetchedAt)
            guard unchangedHistory == [historical], cached.phase(at: deadline.addingTimeInterval(1)) == .awaitingConfirmation else {
                return false
            }
            return true
        } catch {
            return false
        }
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
            do {
                try failing.applyPage(.none(fetchedAt: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
                return false
            } catch PublicResetForecastFailure.cacheWriteFailed {} catch { return false }
            guard failing.forecast == forecast, failing.checkedAt == now, failing.isShowingCache else { return false }
            let restarted = PublicResetForecastStore(supportDirectory: root)
            guard restarted.forecast == failing.forecast, restarted.isShowingCache else { return false }
            try restarted.applyPage(.none(fetchedAt: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
            let withdrawn = PublicResetForecastStore(supportDirectory: root)
            return withdrawn.forecast == nil && withdrawn.checkedAt == now.addingTimeInterval(1)
        } catch { return false }
    }

    private static func xPostID(for date: Date) -> String {
        let twitterEpochMilliseconds: UInt64 = 1_288_834_974_657
        let milliseconds = UInt64(date.timeIntervalSince1970 * 1000)
        return String((milliseconds - twitterEpochMilliseconds) << 22)
    }
}
