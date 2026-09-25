import Combine
import Darwin
import Foundation

/// Public, third-party announcements. These never mutate account quota or
/// account-bound official reset history, and never redeem a reset credit.
struct PublicResetAnnouncement: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case regular, banked }
    struct Source: Codable, Equatable {
        let type: String
        let author: String?
        let url: URL?
    }
    let id: String
    let resetType: Kind
    let announcedAt: Date
    let text: String
    let source: Source

    enum CodingKeys: String, CodingKey {
        case id, text, source
        case resetType = "reset_type"
        case announcedAt = "announced_at"
    }

    func isValid(now: Date) -> Bool {
        let safeID = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard (1...64).contains(id.count), id.unicodeScalars.allSatisfy(safeID.contains),
            !text.isEmpty, text.utf8.count <= 16_384, announcedAt.timeIntervalSince1970.isFinite,
            announcedAt <= now.addingTimeInterval(300), announcedAt.timeIntervalSince1970 > 1_700_000_000
        else { return false }
        switch source.type {
        case "x_post":
            guard source.author == "thsottiaux", let url = source.url,
                let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return false }
            return parts.scheme == "https" && parts.host == "x.com" && parts.user == nil && parts.password == nil
                && parts.port == nil && parts.query == nil && parts.fragment == nil
                && parts.path == "/thsottiaux/status/\(id)" && id.allSatisfy(\.isNumber)
        case "observed":
            guard source.author == nil && id.hasPrefix("observed-") else { return false }
            guard let url = source.url else { return true }
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                parts.scheme == "https", parts.host == "x.com", parts.user == nil, parts.password == nil,
                parts.port == nil, parts.query == nil, parts.fragment == nil,
                parts.path.hasPrefix("/thsottiaux/status/")
            else { return false }
            let postID = String(parts.path.dropFirst("/thsottiaux/status/".count))
            return (1...64).contains(postID.count) && postID.allSatisfy(\.isNumber)
        default: return false
        }
    }

    func title(_ language: WidgetLanguage = .storedOrAutomatic()) -> String {
        PublicResetTranslationModel.isForecast(text)
            ? language.text("重置预告 · 尚未确认", "Reset forecast · unconfirmed")
            : language.text("额度重置公告", "Quota reset announcement")
    }

    /// A public claim never confirms this account's balance or completion.
    func meaning(_ language: WidgetLanguage = .storedOrAutomatic()) -> String {
        let claim =
            PublicResetTranslationModel.isForecast(text)
            ? language.text("公开重置预告，尚未确认完成。", "Public reset forecast; completion is unconfirmed. ")
            : language.text("公开重置公告；公告类型本身不证明已完成或已到账。", "Public reset announcement; its type does not confirm completion or receipt. ")
        return claim + language.text("请到账号页核对官方额度与可用重置卡。", "Verify official quota and available reset credits on the Accounts page.")
    }

    func summary(_ language: WidgetLanguage = .storedOrAutomatic()) -> String {
        let sourceLabel =
            source.type == "observed"
            ? language.text("网友看到", "Spotted by users")
            : language.text("公开帖文", "Public post")
        return "\(sourceLabel) · \(language.dateTime(announcedAt))\n\(meaning(language))"
    }
}

struct PublicResetPage: Decodable {
    struct Pagination: Decodable {
        let hasMore: Bool
        let nextCursor: String?
        enum CodingKeys: String, CodingKey {
            case hasMore = "has_more"
            case nextCursor = "next_cursor"
        }
    }
    struct Meta: Decodable {
        let apiVersion: String
        let generatedAt: Date
        enum CodingKeys: String, CodingKey {
            case apiVersion = "api_version"
            case generatedAt = "generated_at"
        }
    }
    let data: [PublicResetAnnouncement]
    let pagination: Pagination
    let meta: Meta

    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 512 * 1024 else { throw PublicResetFailure.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { input in
            let value = try input.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw PublicResetFailure.invalidResponse }
            return date
        }
        let page = try decoder.decode(Self.self, from: data)
        guard page.meta.apiVersion == "v1", page.data.count <= 100,
            abs(page.meta.generatedAt.timeIntervalSince(now)) <= 86_400,
            Set(page.data.map(\.id)).count == page.data.count,
            page.data.allSatisfy({ $0.isValid(now: now) })
        else { throw PublicResetFailure.invalidResponse }
        return page
    }
}

enum PublicResetFailure: LocalizedError {
    case invalidResponse, unavailable, historyGap, localState, queueFull
    case retryLater(Int)
    var errorDescription: String? {
        let language = WidgetLanguage.storedOrAutomatic()
        switch self {
        case .invalidResponse: return language.text("公告数据无法验证，未更新推送记录", "Announcement data could not be verified; delivery records were preserved.")
        case .unavailable: return language.text("公告服务暂不可用，将稍后重试", "Announcement service is unavailable; retrying later.")
        case .historyGap: return language.text("公告历史存在缺口，已暂停推送；请核对来源", "Announcement history has a gap. Delivery is paused; verify the source.")
        case .localState: return language.text("公告推送记录无法保存或读取，已暂停推送", "Announcement delivery state could not be saved or read; delivery is paused.")
        case .queueFull:
            return language.text(
                "公告队列已满，先处理已保存的待发公告；新公告将在后续检查时补入", "The announcement queue is full. Saved deliveries will drain first; new announcements will be retried on a later check.")
        case .retryLater(let seconds): return language.text("公告服务限流，\(seconds) 秒后再检查", "Announcement service rate limited this request; retry in \(seconds) seconds.")
        }
    }
}

final class PublicResetRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

struct PublicResetClient {
    static let siteURL = URL(string: "https://codex-resets.com/")!
    static let endpoint = URL(string: "https://codex-resets.com/api/v1/resets?limit=100&order=desc")!

    static func requestURL(cursor: String? = nil) throws -> URL {
        guard let cursor else { return endpoint }
        guard !cursor.isEmpty, cursor.utf8.count <= 2048, !cursor.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PublicResetFailure.invalidResponse
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "cursor", value: cursor)]
        guard let url = components.url else { throw PublicResetFailure.invalidResponse }
        return url
    }

    func fetch(cursor: String? = nil, timeout: TimeInterval = 20) async throws -> PublicResetPage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = min(20, max(1, timeout))
        configuration.timeoutIntervalForResource = min(25, max(1, timeout))
        let guardDelegate = PublicResetRedirectGuard()
        let session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // A manual refresh must revalidate with the origin, not only bypass
        // URLSession's local cache. The endpoint is public and contains no
        // credentials, so a conditional/no-store request is safe here.
        var request = URLRequest(
            url: try Self.requestURL(cursor: cursor),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("CodexAccountManagerNext/1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PublicResetFailure.invalidResponse }
        if http.statusCode == 429 {
            let delay = min(86_400, max(300, Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900))
            throw PublicResetFailure.retryLater(delay)
        }
        guard http.statusCode == 200, http.mimeType == "application/json",
            response.expectedContentLength <= 512 * 1024
        else { throw PublicResetFailure.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512 * 1024 else { throw PublicResetFailure.invalidResponse }
            data.append(byte)
        }
        return try PublicResetPage.decode(data)
    }
}

/// Uses only the documented opaque cursor, on the fixed allowlisted endpoint.
/// Recovery is bounded to 500 records / 30 seconds and never invents a payload.
enum PublicResetHistoryRecovery {
    struct Checkpoint: Codable {
        let cursor: String
        let oldestDate: Date?
        let recentCursors: [String]

        var isValid: Bool {
            (try? PublicResetClient.requestURL(cursor: cursor)) != nil
                && recentCursors.count <= 16
                && recentCursors.allSatisfy { (try? PublicResetClient.requestURL(cursor: $0)) != nil }
                && oldestDate.map { $0.timeIntervalSince1970.isFinite } != false
        }
    }

    struct Result {
        let page: PublicResetPage
        let recoveredRows: [PublicResetAnnouncement]
        let checkpoint: Checkpoint?
        let failure: PublicResetFailure?
    }

    static func recover(
        first: PublicResetPage, ledgers: [PublicResetDeliveryLedger],
        fetch: (String, TimeInterval) async throws -> PublicResetPage = { cursor, timeout in
            try await PublicResetClient().fetch(cursor: cursor, timeout: timeout)
        }
    ) async -> Result {
        let firstIDs = Set(first.data.map(\.id))
        let needingRecovery = ledgers.filter {
            !$0.missingPayloadIDs.isSubset(of: firstIDs)
                || ($0.initialized && !$0.records.isEmpty && first.pagination.hasMore && Set($0.records.keys).isDisjoint(with: firstIDs))
        }
        let known = needingRecovery.filter { $0.initialized && !$0.records.isEmpty }.map { Set($0.records.keys) }
        let missing = needingRecovery.reduce(into: Set<String>()) { $0.formUnion($1.missingPayloadIDs) }
        // A newly participating ledger starts at the head; otherwise continue
        // the shallowest saved cursor so neither channel skips its old records.
        let saved =
            needingRecovery.contains(where: { $0.historyCheckpoint == nil })
            ? nil
            : needingRecovery.compactMap(\.historyCheckpoint).max {
                ($0.oldestDate ?? .distantFuture) < ($1.oldestDate ?? .distantFuture)
            }
        var rows = first.data
        var ids = Set(rows.map(\.id))
        var last = first
        var cursor = saved?.cursor ?? first.pagination.nextCursor
        var oldestDate = saved?.oldestDate ?? rows.map(\.announcedAt).min()
        var recentCursors = saved?.recentCursors ?? []
        var checkpoint = saved
        var failure: PublicResetFailure?
        let deadline = Date().addingTimeInterval(30)
        for _ in 0..<4 where !needingRecovery.isEmpty {
            guard !missing.isSubset(of: ids) || known.contains(where: { $0.isDisjoint(with: ids) }) else {
                checkpoint = nil
                break
            }
            guard !Task.isCancelled, let nextCursor = cursor, Date() < deadline else { break }
            guard !recentCursors.contains(nextCursor) else {
                failure = .invalidResponse
                checkpoint = nil
                break
            }
            do {
                let next = try await fetch(nextCursor, deadline.timeIntervalSinceNow)
                guard next.data.count <= 100, rows.count + next.data.count <= 500,
                    Set(next.data.map(\.id)).count == next.data.count,
                    Set(next.data.map(\.id)).isDisjoint(with: ids),
                    next.data.allSatisfy({ $0.isValid(now: Date()) }),
                    next.data.map(\.announcedAt).max().map({ newest in oldestDate.map { newest <= $0 } ?? true }) ?? true
                else { throw PublicResetFailure.invalidResponse }
                rows.append(contentsOf: next.data)
                ids.formUnion(next.data.map(\.id))
                last = next
                oldestDate = next.data.map(\.announcedAt).min() ?? oldestDate
                recentCursors.append(nextCursor)
                recentCursors = Array(recentCursors.suffix(16))
                cursor = next.pagination.hasMore ? next.pagination.nextCursor : nil
                checkpoint = cursor.map { Checkpoint(cursor: $0, oldestDate: oldestDate, recentCursors: recentCursors) }
            } catch {
                failure = (error as? PublicResetFailure) ?? .unavailable
                // Keep every already validated page and retry the failing cursor.
                checkpoint = Checkpoint(cursor: nextCursor, oldestDate: oldestDate, recentCursors: recentCursors)
                break
            }
        }
        if needingRecovery.isEmpty { checkpoint = nil }
        // Resumed pages are only used to hydrate existing IDs. They are not a
        // continuous history from today's first page; never silently skip that gap.
        let admission = saved == nil ? PublicResetPage(data: rows, pagination: last.pagination, meta: first.meta) : first
        return Result(page: admission, recoveredRows: rows, checkpoint: checkpoint, failure: failure)
    }
}

struct PublicResetDeliveryLedger: Codable {
    enum Phase: String, Codable { case baseline, pending, sending, sent, uncertain }
    var schemaVersion = 1
    var initialized = false
    var records: [String: Phase] = [:]
    var newestObservedAt: Date?
    var retiredThrough: Date?
    var observedDates: [String: Date]?
    // Only public identifiers, dates, types and source links are persisted;
    // the original announcement text is replaced by a fixed marker.
    var payloads: [String: PublicResetAnnouncement]?
    var historyCheckpoint: PublicResetHistoryRecovery.Checkpoint?

    /// Explicit one-shot delivery shares the automatic ledger and never replays
    /// a sent, interrupted, uncertain or retired announcement.
    mutating func reserveAuthorizedDelivery(_ event: PublicResetAnnouncement) throws {
        guard event.isValid(now: Date()),
            records[event.id] == nil || records[event.id] == .baseline || records[event.id] == .pending,
            retiredThrough.map({ event.announcedAt > $0 }) ?? true,
            records[event.id] != nil || records.count < 500
        else { throw PublicResetFailure.localState }
        records[event.id] = .sending
        if observedDates == nil { observedDates = [:] }
        observedDates?[event.id] = event.announcedAt
        if payloads == nil { payloads = [:] }
        payloads?[event.id] = PublicResetAnnouncement(
            id: event.id, resetType: event.resetType, announcedAt: event.announcedAt,
            text: "public-announcement", source: event.source)
    }

    mutating func recoverInterruptedSends() {
        for id in records.keys where records[id] == .sending { records[id] = .uncertain }
    }

    mutating func observe(_ page: PublicResetPage) throws {
        // Recover durable old IDs before admitting new ones. A full queue must
        // not discard payload recovery and keep every existing delivery stuck.
        hydrate(page.data)
        let ids = Set(page.data.map(\.id))
        if initialized, page.pagination.hasMore, ids.isDisjoint(with: Set(records.keys)) {
            throw PublicResetFailure.historyGap
        }
        var next = self
        var dates = observedDates ?? [:]
        var queued = payloads ?? [:]
        for event in page.data {
            if next.records[event.id] == nil {
                if let retiredThrough, event.announcedAt <= retiredThrough { continue }
                let historical = newestObservedAt.map { event.announcedAt < $0 } ?? false
                next.records[event.id] = initialized && !historical ? .pending : .baseline
            }
            dates[event.id] = event.announcedAt
            if [.pending, .sending, .uncertain].contains(next.records[event.id]) {
                queued[event.id] = PublicResetAnnouncement(
                    id: event.id, resetType: event.resetType,
                    announcedAt: event.announcedAt, text: "public-announcement", source: event.source)
            }
        }
        if let newest = page.data.map(\.announcedAt).max() {
            next.newestObservedAt = max(newestObservedAt ?? newest, newest)
        }
        next.initialized = true
        // Keep IDs across short/empty pages. Compact only at the explicit
        // bound, with a durable time watermark so retired IDs cannot resend.
        let completed = next.records.keys.filter {
            [.baseline, .sent].contains(next.records[$0]) && dates[$0] != nil
        }.sorted { dates[$0]! < dates[$1]! }
        for id in completed where next.records.count > 500 {
            let date = dates.removeValue(forKey: id)!
            next.retiredThrough = max(next.retiredThrough ?? date, date)
            next.records.removeValue(forKey: id)
        }
        guard next.records.count <= 500 else { throw PublicResetFailure.queueFull }
        next.observedDates = dates.filter { next.records[$0.key] != nil }
        next.payloads = queued.filter { [.pending, .sending, .uncertain].contains(next.records[$0.key]) }
        self = next
    }

    var missingPayloadIDs: Set<String> {
        Set(records.keys.filter { [.pending, .sending, .uncertain].contains(records[$0]) && payloads?[$0] == nil })
    }

    mutating func hydrate(_ events: [PublicResetAnnouncement]) {
        for event in events where [.pending, .sending, .uncertain].contains(records[event.id]) {
            if observedDates == nil { observedDates = [:] }
            if payloads == nil { payloads = [:] }
            observedDates?[event.id] = event.announcedAt
            payloads?[event.id] = PublicResetAnnouncement(
                id: event.id, resetType: event.resetType, announcedAt: event.announcedAt,
                text: "public-announcement", source: event.source)
        }
    }
}

private struct PublicResetDeliveryLock {
    let descriptor: Int32
    static func acquire(in directory: URL) throws -> Self? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw PublicResetFailure.localState }
        let fd = Darwin.open(
            directory.appendingPathComponent(".public-reset-delivery.lock").path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PublicResetFailure.localState }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0
        else {
            Darwin.close(fd)
            throw PublicResetFailure.localState
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return Self(descriptor: fd)
    }
    func release() {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

/// UI-facing state is published only from the MainActor-owned delivery path.
/// Network and history work still suspend through async URLSession calls, but
/// no continuation may publish into Combine/SwiftUI from a generic executor.
final class PublicResetAnnouncementMonitor: ObservableObject {
    enum LocalDelivery { case submitted, inAppOnly, retry }
    static let enabledKey = "CodexManagerNext.publicResetAnnouncements.enabled"
    @Published private(set) var enabled: Bool
    @Published private(set) var latest: PublicResetAnnouncement?
    /// Validated current API page only, not a complete historical archive.
    @Published private(set) var announcements: [PublicResetAnnouncement] = []
    /// Unknown before the first successful fetch; failures preserve the last page.
    @Published private(set) var announcementsHasMore: Bool?
    @Published private(set) var status: String?
    @Published private(set) var checking = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var uncertainDeliveryIDs: [String] = []
    @Published private(set) var needsNewBaseline = false
    @Published private(set) var missingDeliveryCount = 0
    @Published private(set) var needsLocalBaseline = false
    @Published private(set) var localStatus: String?
    @Published private(set) var channelResults: [MessageChannelKind: PublicResetChannelResult] = [:]
    private var onChannelResult: @MainActor (PublicResetChannelResult) -> Void = { _ in }
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var stopped = false
    private let fixtureScheduling: Bool
    private let fetchPage: () async throws -> PublicResetPage
    private var notBefore = Date.distantPast
    private var rebaseRequested = false
    private var localRebaseRequested = false
    private let preview: Bool
    private let stateURL: URL
    private let localStateURL: URL
    private var notifyLocally: (@MainActor (PublicResetAnnouncement) async -> LocalDelivery)?
    private var channelRevision: @MainActor (MessageChannelKind) -> UUID? = { _ in nil }
    private var sendChannel: (@MainActor (PublicResetAnnouncement, MessageChannelKind, UUID) async -> Result<MessageDeliveryOutcome, MessageChannelError>)?
    private var canSend: () -> Bool = { false }
    private var send: (@MainActor (PublicResetAnnouncement) async -> Result<Void, FeishuWebhookError>)?

    init(
        preview: Bool = false, supportDirectory: URL? = nil,
        fixtureScheduling: Bool = false,
        fetchPage: @escaping () async throws -> PublicResetPage = { try await PublicResetClient().fetch() }
    ) {
        self.fixtureScheduling = fixtureScheduling
        self.fetchPage = fetchPage
        self.preview = preview
        enabled = preview || NextFeatureDefaults.isEnabled(Self.enabledKey)
        let directory = supportDirectory ?? DispatchParticipationPaths.supportDirectory()
        stateURL = directory.appendingPathComponent("public-reset-delivery-v1.json")
        localStateURL = directory.appendingPathComponent("public-reset-local-v1.json")
    }

    /// Preview fixtures only. Does not start a check or change delivery ledgers.
    @MainActor
    func seedPreviewLatest(_ announcement: PublicResetAnnouncement?, checkedAt: Date?) {
        guard preview else { return }
        latest = announcement
        self.checkedAt = checkedAt
    }

    @MainActor
    func configure(
        notifyLocally: @escaping @MainActor (PublicResetAnnouncement) async -> LocalDelivery,
        canSend: @escaping () -> Bool,
        send: @escaping @MainActor (PublicResetAnnouncement) async -> Result<Void, FeishuWebhookError>,
        channelRevision: @escaping @MainActor (MessageChannelKind) -> UUID? = { _ in nil },
        sendChannel: (@MainActor (PublicResetAnnouncement, MessageChannelKind, UUID) async -> Result<MessageDeliveryOutcome, MessageChannelError>)? = nil,
        onChannelResult: @escaping @MainActor (PublicResetChannelResult) -> Void = { _ in }
    ) {
        invalidateLifecycle()
        stopped = false
        self.onChannelResult = onChannelResult
        self.channelRevision = channelRevision
        self.sendChannel = sendChannel
        self.canSend = canSend
        self.notifyLocally = notifyLocally
        self.send = send
        schedule()
    }

    @MainActor
    private func invalidateLifecycle() {
        generation += 1
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        checking = false
    }

    @MainActor
    private func isCurrent(_ epoch: UInt64) -> Bool {
        generation == epoch && !stopped && !Task.isCancelled
    }

    /// Capture at delivery entry, before a callback-based service suspends.
    /// Existing service admission callbacks execute on the main queue.
    @MainActor
    func deliveryAdmission() -> () -> Bool {
        let epoch = generation
        return { [weak self] in
            MainActor.assumeIsolated { self?.isCurrent(epoch) == true }
        }
    }

    @MainActor
    var lifecycleTask: Task<Void, Never>? { task }

    // Read-only fixture observation; no timing or production preference changes.
    @MainActor
    var lifecycleSnapshot: (epoch: UInt64, scheduled: Bool, active: Bool) {
        (generation, timer != nil, task != nil)
    }

    @MainActor
    func setEnabled(_ enabled: Bool) {
        guard !preview else { return }
        invalidateLifecycle()
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        schedule()
    }

    @MainActor
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard !preview || fixtureScheduling, enabled, !stopped else { return }
        check()
        let epoch = generation
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCurrent(epoch) else { return }
                self.check()
            }
        }
        timer?.tolerance = 30
    }

    @MainActor
    func stop() {
        invalidateLifecycle()
        stopped = true
    }

    private func load(at url: URL? = nil) throws -> PublicResetDeliveryLedger {
        let source = url ?? stateURL
        guard let data = try DispatchParticipationSync.readBoundedRegularFile(source, maximumBytes: 512 * 1024, allowMissing: true) else { return .init() }
        var ledger = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: data)
        guard ledger.schemaVersion == 1, ledger.records.count <= 500,
            (ledger.observedDates?.count ?? 0) <= 500, (ledger.payloads?.count ?? 0) <= 500,
            ledger.historyCheckpoint?.isValid != false,
            ledger.payloads?.allSatisfy({ $0.key == $0.value.id && $0.value.isValid(now: Date()) }) != false
        else { throw PublicResetFailure.localState }
        if source == localStateURL {
            for id in ledger.records.keys where ledger.records[id] == .sending { ledger.records[id] = .pending }
        } else {
            ledger.recoverInterruptedSends()
        }
        return ledger
    }

    @MainActor
    private func save(_ ledger: PublicResetDeliveryLedger, at url: URL? = nil, publish: Bool = true) throws {
        do {
            let data = try JSONEncoder().encode(ledger)
            guard data.count <= 512 * 1024 else { throw PublicResetFailure.localState }
            try PrivateLocalFileStore.write(data, to: url ?? stateURL)
        } catch { throw PublicResetFailure.localState }
        if url == nil, publish {
            uncertainDeliveryIDs = ledger.records.filter { $0.value == .uncertain }.map(\.key).sorted()
            missingDeliveryCount = ledger.missingPayloadIDs.count
        }
    }

    @MainActor
    private func writableFeishuLedger() -> PublicResetDeliveryLedger? {
        guard canSend(), let ledger = try? load() else { return nil }
        // A readable but unwritable optional ledger must not repeatedly pull
        // healthy native recovery back to its older checkpoint.
        do {
            try save(ledger)
            return ledger
        } catch { return nil }
    }

    /// The user has checked Feishu. An uncertain send is never retried automatically.
    @MainActor
    func resolveUncertainDelivery(id: String, received: Bool) {
        guard !preview, !checking else { return }
        do {
            guard let lock = try PublicResetDeliveryLock.acquire(in: stateURL.deletingLastPathComponent()) else { return }
            defer { lock.release() }
            var ledger = try load()
            guard ledger.records[id] == .uncertain else { return }
            ledger.records[id] = received ? .sent : .pending
            try save(ledger)
            status = WidgetLanguage.storedOrAutomatic().text(
                received ? "已按你的核实结果标记为收到" : "已按你的核实结果允许重试，将在下次检查时推送",
                received ? "Marked delivered based on your verification." : "Retry allowed based on your verification; delivery will resume on the next check.")
        } catch { status = PublicResetFailure.localState.localizedDescription }
    }

    @MainActor
    func establishNewBaseline(local: Bool = false) {
        guard enabled, !checking else { return }
        if local { localRebaseRequested = true } else { rebaseRequested = true }
        check()
    }

    @MainActor
    func check() {
        guard !preview || fixtureScheduling, !stopped, !checking else { return }
        // Forecast state is intentionally fetched and cached on its own path.
        // It never enters announcement delivery, and a failure here cannot
        // erase or block an otherwise valid historical feed refresh.
        if !preview { PublicResetForecastStore.shared.check() }
        let epoch = generation
        guard Date() >= notBefore else {
            status = PublicResetFailure.retryLater(max(1, Int(ceil(notBefore.timeIntervalSinceNow)))).localizedDescription
            return
        }
        checking = true
        localStatus = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == epoch {
                    checking = false
                    task = nil
                }
            }
            guard isCurrent(epoch) else { return }
            do {
                let page = try await fetchPage()
                guard isCurrent(epoch) else { return }
                announcements = page.data.sorted {
                    $0.announcedAt == $1.announcedAt ? $0.id < $1.id : $0.announcedAt < $1.announcedAt
                }
                announcementsHasMore = page.pagination.hasMore
                latest = page.data.max { $0.announcedAt < $1.announcedAt }
                checkedAt = Date()
                let language = WidgetLanguage.storedOrAutomatic()
                status = language.text("公告已更新；来源为第三方汇总，账号额度以官方刷新结果为准", "Announcements updated from a third-party feed. Account limits use official refresh results.")
                guard enabled else { return }
                let channelTasks = MessageChannelKind.allCases.map { kind in
                    Task { @MainActor in await self.deliverChannel(page, kind: kind, epoch: epoch) }
                }
                await withTaskCancellationHandler {
                    await self.deliverExistingChannels(page, language: language, epoch: epoch)
                    for task in channelTasks {
                        await task.value
                        if !self.isCurrent(epoch) { channelTasks.forEach { $0.cancel() } }
                    }
                } onCancel: {
                    channelTasks.forEach { $0.cancel() }
                }
            } catch let error as PublicResetFailure {
                guard isCurrent(epoch) else { return }
                if case .retryLater(let seconds) = error { notBefore = Date().addingTimeInterval(Double(seconds)) }
                status = error.localizedDescription
            } catch {
                if isCurrent(epoch) { status = PublicResetFailure.unavailable.localizedDescription }
            }
        }
    }

    /// Separate durable ledger and lock per optional channel. No historical fetch
    /// here: a feed gap fails closed without affecting the other delivery paths.
    @MainActor
    func deliverChannel(_ page: PublicResetPage, kind: MessageChannelKind) async {
        await deliverChannel(page, kind: kind, epoch: generation)
    }

    @MainActor
    private func deliverChannel(_ page: PublicResetPage, kind: MessageChannelKind, epoch: UInt64) async {
        guard enabled, isCurrent(epoch), let revision = channelRevision(kind), let sendChannel else { return }
        let directory = stateURL.deletingLastPathComponent().appendingPathComponent("public-reset-" + kind.rawValue)
        let url = directory.appendingPathComponent("delivery-v1.json")
        do {
            guard let lock = try PublicResetDeliveryLock.acquire(in: directory) else { return }
            // This invocation owns the descriptor, even after invalidation;
            // releasing it cannot clear another generation's task or lock.
            defer { lock.release() }
            var ledger = try load(at: url)
            try ledger.observe(page)
            // Only these channel queues retain the restricted public projection,
            // so a later short page cannot lose queued wording. Native/Feishu
            // ledger payloads and baseline/dedupe semantics remain unchanged.
            for event in page.data where ledger.records[event.id] == .pending {
                let context = try PublicResetContext(announcement: event)
                ledger.payloads?[event.id] = PublicResetAnnouncement(
                    id: event.id, resetType: event.resetType, announcedAt: event.announcedAt,
                    text: context.publicText.isEmpty ? "public-announcement" : context.publicText,
                    source: event.source)
            }
            try save(ledger, at: url)
            if ledger.records.values.contains(.uncertain) {
                publishChannelResult(.init(channel: kind, state: .uncertain, checkedAt: Date(), errorCategory: .interrupted), epoch: epoch, revision: revision)
            }
            let queue = (ledger.payloads ?? [:]).values.filter { ledger.records[$0.id] == .pending }
                .sorted { $0.announcedAt < $1.announcedAt }
            for event in queue.prefix(20) {
                guard enabled, isCurrent(epoch), channelRevision(kind) == revision else { return }
                ledger.records[event.id] = .sending
                try save(ledger, at: url)
                // Prefer validated current wording. Queued rows retain the
                // restricted projection; pre-context ledgers retain their placeholder.
                let announcement = page.data.first { $0.id == event.id && $0.isValid(now: Date()) } ?? event
                let result = await sendChannel(announcement, kind, revision)
                // Every non-acceptance is conservatively terminal for automatic
                // delivery, including duplicateSkipped and post-send cancellation.
                if enabled, isCurrent(epoch), channelRevision(kind) == revision,
                    case .success(.accepted) = result
                {
                    ledger.records[event.id] = .sent
                    ledger.payloads?.removeValue(forKey: event.id)
                } else {
                    ledger.records[event.id] = .uncertain
                }
                try save(ledger, at: url, publish: false)
                publishChannelResult(.delivery(result, channel: kind), epoch: epoch, revision: revision)
                guard isCurrent(epoch) else { return }
                if case .failure = result { return }
            }
        } catch {
            publishChannelResult(.init(channel: kind, state: .ledgerFailed, checkedAt: Date(), errorCategory: .ledger), epoch: epoch, revision: revision)
        }
    }

    @MainActor
    private func publishChannelResult(_ result: PublicResetChannelResult, epoch: UInt64, revision: UUID) {
        guard enabled, isCurrent(epoch), channelRevision(result.channel) == revision else { return }
        channelResults[result.channel] = result
        onChannelResult(result)
    }

    @MainActor
    private func deliverExistingChannels(_ page: PublicResetPage, language: WidgetLanguage, epoch: UInt64) async {
        guard isCurrent(epoch) else { return }
        do {
            guard let lock = try PublicResetDeliveryLock.acquire(in: stateURL.deletingLastPathComponent()) else {
                status = language.text("另一个 Next 实例正在处理公告，将稍后重试", "Another Next instance is processing announcements. Retrying later.")
                return
            }
            defer { lock.release() }
            // Native delivery is independent of Feishu configuration and
            // its recovery ledger. The public endpoint uses no model quota.
            var localLedger = try? load(at: localStateURL)
            var feishuLedger = writableFeishuLedger()
            if localRebaseRequested {
                localLedger?.initialized = false
                localLedger?.historyCheckpoint = nil
            }
            if rebaseRequested {
                feishuLedger?.initialized = false
                feishuLedger?.historyCheckpoint = nil
            }
            let recovered = await PublicResetHistoryRecovery.recover(
                first: page, ledgers: (localLedger.map { [$0] } ?? []) + (feishuLedger.map { [$0] } ?? []))
            guard isCurrent(epoch) else { return }
            if var ledger = localLedger {
                ledger.hydrate(recovered.recoveredRows)
                ledger.historyCheckpoint = recovered.checkpoint
                do {
                    try save(ledger, at: localStateURL)
                    localLedger = ledger
                } catch {
                    localLedger = nil
                    localStatus = PublicResetFailure.localState.localizedDescription
                }
            } else {
                localStatus = PublicResetFailure.localState.localizedDescription
            }
            if var ledger = feishuLedger {
                ledger.hydrate(recovered.recoveredRows)
                ledger.historyCheckpoint = recovered.checkpoint
                do {
                    try save(ledger)
                    feishuLedger = ledger
                } catch {
                    // A damaged optional Feishu ledger must not suppress
                    // otherwise healthy native updates.
                    feishuLedger = nil
                }
            }
            if case .retryLater(let seconds) = recovered.failure {
                notBefore = Date().addingTimeInterval(Double(seconds))
            }
            guard isCurrent(epoch) else { return }
            if let localLedger {
                do { try await deliverLocally(recovered.page, ledger: localLedger, epoch: epoch) } catch {
                    if isCurrent(epoch) { localStatus = PublicResetFailure.localState.localizedDescription }
                }
            }
            guard isCurrent(epoch) else { return }
            if localStatus == nil, let failure = recovered.failure { localStatus = failure.localizedDescription }
            guard canSend(), let send else {
                status = language.text("消息已更新，不消耗账号额度", "Updates checked. No account quota used.")
                return
            }
            guard var ledger = feishuLedger else { throw PublicResetFailure.localState }
            if rebaseRequested { ledger.initialized = false }
            let wasInitialized = ledger.initialized
            var observationFailure: PublicResetFailure?
            do {
                try ledger.observe(recovered.page)
                needsNewBaseline = false
            } catch let error as PublicResetFailure {
                guard isCurrent(epoch) else { return }
                // A full queue or feed gap must not prevent delivery of
                // already durable, independently verifiable announcements.
                switch error {
                case .queueFull, .historyGap:
                    observationFailure = error
                    needsNewBaseline = true
                default: throw error
                }
            }
            try save(ledger)
            if !wasInitialized, observationFailure == nil {
                rebaseRequested = false
                status = language.text("已开始接收重置消息", "Reset updates are on.")
                return
            }
            if ledger.records.values.contains(.uncertain) {
                status = language.text("有公告推送结果待核实，未自动重发；请检查飞书消息", "Some announcement deliveries are unverified and were not resent. Check Feishu.")
            }
            let queue = (ledger.payloads ?? [:]).values.filter { ledger.records[$0.id] == .pending }
                .sorted { $0.announcedAt < $1.announcedAt }
            for announcement in queue.prefix(20) {
                guard enabled, canSend(), isCurrent(epoch) else { return }
                ledger.records[announcement.id] = .sending
                try save(ledger)
                let result = await send(announcement)
                guard isCurrent(epoch) else {
                    ledger.records[announcement.id] = .uncertain
                    try save(ledger, publish: false)
                    return
                }
                switch result {
                case .success:
                    ledger.records[announcement.id] = .sent
                    ledger.payloads?.removeValue(forKey: announcement.id)
                    status = language.text("重置公告已提交给飞书机器人", "Reset announcement accepted by the Feishu bot.")
                case .failure(let error):
                    switch error {
                    case .transportFailed, .invalidResponse: ledger.records[announcement.id] = .uncertain
                    case .httpStatus(let code) where code >= 500: ledger.records[announcement.id] = .uncertain
                    default: ledger.records[announcement.id] = .pending
                    }
                    status = error.localizedDescription
                }
                try save(ledger)
                if case .failure = result { return }
                try await Task.sleep(nanoseconds: 250_000_000)
                guard isCurrent(epoch) else { return }
            }
            if let observationFailure { status = observationFailure.localizedDescription }
        } catch let error as PublicResetFailure {
            guard isCurrent(epoch) else { return }
            if case .retryLater(let seconds) = error { notBefore = Date().addingTimeInterval(Double(seconds)) }
            status = error.localizedDescription
        } catch {
            if isCurrent(epoch) { status = PublicResetFailure.unavailable.localizedDescription }
        }
    }

    /// Only the explicit CLI authorization path calls this. No app startup,
    /// account activity, preference changes or notification permission prompts.
    @MainActor
    func sendAuthorizedLatest() async -> Int32 {
        let epoch = generation
        guard isCurrent(epoch) else { return 6 }
        var announcementID = "none"
        do {
            let page = try await fetchPage()
            guard isCurrent(epoch) else { return 6 }
            guard let event = page.data.max(by: { $0.announcedAt < $1.announcedAt }) else {
                print("public-reset failure id=none reason=no-announcement")
                return 3
            }
            announcementID = event.id
            guard let lock = try PublicResetDeliveryLock.acquire(in: stateURL.deletingLastPathComponent()) else {
                print("public-reset failure id=\(announcementID) reason=delivery-busy")
                return 4
            }
            defer { lock.release() }
            var ledger = try load()
            // Persist the reservation before reading credentials or sending.
            // A crash or any failed result requires explicit human resolution.
            try ledger.reserveAuthorizedDelivery(event)
            try save(ledger)
            let service = FeishuWebhookService()
            let admission = deliveryAdmission()
            let result: Result<Void, FeishuWebhookError> = await withCheckedContinuation { continuation in
                service.sendPublicResetAnnouncement(event, shouldSend: admission) {
                    continuation.resume(returning: $0)
                }
            }
            guard isCurrent(epoch) else {
                ledger.records[event.id] = .uncertain
                try save(ledger, publish: false)
                return 6
            }
            switch result {
            case .success:
                ledger.records[event.id] = .sent
                ledger.payloads?.removeValue(forKey: event.id)
            case .failure:
                ledger.records[event.id] = .uncertain
            }
            do { try save(ledger) } catch {
                // The durable sending reservation prevents replay on restart.
                print("public-reset failure id=\(announcementID) reason=receipt-save-failed-delivery-unverified")
                return 5
            }
            switch result {
            case .success:
                print("public-reset success id=\(announcementID)")
                return 0
            case .failure(let error):
                print("public-reset failure id=\(announcementID) reason=\(error.localizedDescription)")
                return 6
            }
        } catch let error as PublicResetFailure {
            print("public-reset failure id=\(announcementID) reason=\(error.localizedDescription)")
            return 7
        } catch {
            // Never render raw URLSession or filesystem errors.
            print("public-reset failure id=\(announcementID) reason=source-or-ledger-unavailable")
            return 8
        }
    }

    @MainActor
    private func deliverLocally(_ page: PublicResetPage, ledger initialLedger: PublicResetDeliveryLedger, epoch requestedEpoch: UInt64? = nil) async throws {
        let epoch = requestedEpoch ?? generation
        guard isCurrent(epoch), let notifyLocally else { return }
        var ledger = initialLedger
        if localRebaseRequested { ledger.initialized = false }
        var observationFailure: PublicResetFailure?
        do {
            try ledger.observe(page)
            needsLocalBaseline = false
            localRebaseRequested = false
        } catch let error as PublicResetFailure {
            switch error {
            case .queueFull: observationFailure = error
            case .historyGap:
                observationFailure = error
                needsLocalBaseline = true
            default: throw error
            }
        }
        localStatus = observationFailure?.localizedDescription
        try save(ledger, at: localStateURL)
        let queue = (ledger.payloads ?? [:]).values.filter { ledger.records[$0.id] == .pending }
            .sorted { $0.announcedAt < $1.announcedAt }
        for announcement in queue.prefix(20) {
            guard enabled, isCurrent(epoch) else { return }
            ledger.records[announcement.id] = .sending
            try save(ledger, at: localStateURL)
            let result = await notifyLocally(announcement)
            guard isCurrent(epoch) else {
                ledger.records[announcement.id] = .uncertain
                try save(ledger, at: localStateURL, publish: false)
                return
            }
            switch result {
            case .submitted: ledger.records[announcement.id] = .sent
            case .inAppOnly: ledger.records[announcement.id] = .baseline
            case .retry: ledger.records[announcement.id] = .pending
            }
            if ledger.records[announcement.id] != .pending { ledger.payloads?.removeValue(forKey: announcement.id) }
            try save(ledger, at: localStateURL)
        }
    }
}

@MainActor
extension PublicResetAnnouncementMonitor {
    fileprivate static func optionalFeishuRecoverySelfTest(now: Date) async -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-public-optional-test-\(UUID().uuidString)")
        let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: root)
        defer {
            _ = Darwin.chflags(monitor.stateURL.path, 0)
            try? FileManager.default.removeItem(at: root)
        }
        monitor.canSend = { true }
        var submitted: [String] = []
        monitor.notifyLocally = { event in
            submitted.append(event.id)
            return .submitted
        }
        func page(_ number: Int) -> PublicResetPage {
            let id = number == 7 ? "1" : String(900 - number)
            let event = PublicResetAnnouncement(
                id: id, resetType: .regular,
                announcedAt: now.addingTimeInterval(-Double(number)), text: "fixture",
                source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/\(id)")))
            return PublicResetPage(
                data: [event], pagination: .init(hasMore: number < 7, nextCursor: number < 7 ? String(number + 1) : nil),
                meta: .init(apiVersion: "v1", generatedAt: now))
        }
        do {
            var native = PublicResetDeliveryLedger()
            native.initialized = true
            native.records["1"] = .pending
            try monitor.save(native, at: monitor.localStateURL)
            var optional = PublicResetDeliveryLedger()
            optional.initialized = true
            optional.records["2"] = .pending
            try monitor.save(optional)
            let originalOptionalBytes = try Data(contentsOf: monitor.stateURL)
            // A real filesystem failure: the optional file stays readable but
            // cannot be replaced. The native file in the same directory works.
            guard Darwin.chflags(monitor.stateURL.path, UInt32(UF_IMMUTABLE)) == 0 else { return false }
            guard try monitor.load().records["2"] == .pending else { return false }
            do {
                try monitor.save(optional)
                return false
            } catch {}
            var requested: [String] = []
            for _ in 0..<2 {
                native = try monitor.load(at: monitor.localStateURL)
                let optional = monitor.writableFeishuLedger()
                guard optional == nil else { return false }
                let result = await PublicResetHistoryRecovery.recover(
                    first: page(1), ledgers: [native] + (optional.map { [$0] } ?? [])
                ) { cursor, _ in
                    requested.append(cursor)
                    guard let number = Int(cursor), (2...7).contains(number) else { throw PublicResetFailure.invalidResponse }
                    return page(number)
                }
                native.hydrate(result.recoveredRows)
                native.historyCheckpoint = result.checkpoint
                try monitor.save(native, at: monitor.localStateURL)
                try await monitor.deliverLocally(result.page, ledger: native)
            }
            guard requested == ["2", "3", "4", "5", "6", "7"], submitted == ["1"],
                try monitor.load(at: monitor.localStateURL).records["1"] == .sent,
                try Data(contentsOf: monitor.stateURL) == originalOptionalBytes
            else { return false }
            print("Optional Feishu write-failure recovery self-test passed: native page 7 recovered; optional pending preserved")
            return true
        } catch { return false }
    }

    fileprivate static func deliverySelfTest(now: Date) async -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-public-local-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: root)
        var submitted: [String] = []
        monitor.notifyLocally = { event in
            submitted.append(event.id)
            return .submitted
        }
        func event(_ id: String, secondsAgo: Double) -> PublicResetAnnouncement {
            PublicResetAnnouncement(
                id: id, resetType: .regular, announcedAt: now.addingTimeInterval(-secondsAgo), text: "fixture",
                source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/\(id)")))
        }
        func page(_ events: [PublicResetAnnouncement]) -> PublicResetPage {
            PublicResetPage(data: events, pagination: .init(hasMore: true, nextCursor: "older"), meta: .init(apiVersion: "v1", generatedAt: now))
        }
        do {
            guard !monitor.canSend() else { return false }
            var old = PublicResetDeliveryLedger()
            old.initialized = true
            old.records = ["100": .baseline, "50": .uncertain]
            let first = page([event("200", secondsAgo: 60)])
            try await monitor.deliverLocally(first, ledger: old)
            guard monitor.needsLocalBaseline, monitor.localStatus != nil, submitted.isEmpty else { return false }
            monitor.status = "Updates checked"
            guard (monitor.localStatus ?? monitor.status) != monitor.status else { return false }
            monitor.establishNewBaseline(local: true)
            try await monitor.deliverLocally(first, ledger: monitor.load(at: monitor.localStateURL))
            let rebased = try monitor.load(at: monitor.localStateURL)
            guard !monitor.needsLocalBaseline, monitor.localStatus == nil, submitted.isEmpty,
                rebased.records["100"] == .baseline, rebased.records["50"] == .uncertain, rebased.records["200"] == .baseline
            else { return false }
            let next = page([event("300", secondsAgo: 30), event("200", secondsAgo: 60)])
            try await monitor.deliverLocally(next, ledger: rebased)
            try await monitor.deliverLocally(next, ledger: monitor.load(at: monitor.localStateURL))
            guard submitted == ["300"] else { return false }
            // Rebuilding cannot re-enable a saved-off channel or trigger I/O.
            monitor.enabled = false
            let before = try Data(contentsOf: monitor.localStateURL)
            monitor.establishNewBaseline(local: true)
            guard !monitor.enabled, !monitor.localRebaseRequested,
                try Data(contentsOf: monitor.localStateURL) == before
            else { return false }
            return true
        } catch { return false }
    }

    /// Read the same bounded feed page with delivery disabled; no ledger or network.
    fileprivate static func pagePublicationSelfTest(now: Date) async -> Bool {
        actor Replies {
            var count = 0
            let page: PublicResetPage
            init(page: PublicResetPage) { self.page = page }
            func next() throws -> PublicResetPage {
                count += 1
                if count == 2 { throw PublicResetFailure.unavailable }
                if count == 3 {
                    return PublicResetPage(data: [], pagination: .init(hasMore: false, nextCursor: nil), meta: page.meta)
                }
                return page
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-public-page-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let events = (100...152).map { index in
            PublicResetAnnouncement(
                id: String(index), resetType: .regular,
                announcedAt: now.addingTimeInterval(-600 + Double((index - 100) / 2)), text: "Synthetic page fixture",
                source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/\(index)")))
        }
        let page = PublicResetPage(
            data: Array(events.reversed()), pagination: .init(hasMore: true, nextCursor: "synthetic-older"), meta: .init(apiVersion: "v1", generatedAt: now))
        let replies = Replies(page: page)
        let monitor = PublicResetAnnouncementMonitor(
            preview: true, supportDirectory: root, fixtureScheduling: true, fetchPage: { try await replies.next() })
        monitor.enabled = false
        guard monitor.announcements.isEmpty, monitor.announcementsHasMore == nil else { return false }
        monitor.check()
        await monitor.lifecycleTask?.value
        guard monitor.announcements.map(\.id) == (100...152).map(String.init), monitor.announcementsHasMore == true else { return false }
        let originalCheck = monitor.checkedAt
        monitor.check()
        await monitor.lifecycleTask?.value
        guard monitor.announcements == events, monitor.announcementsHasMore == true, monitor.checkedAt == originalCheck else { return false }
        monitor.check()
        await monitor.lifecycleTask?.value
        let fetchCount = await replies.count
        return monitor.announcements.isEmpty && monitor.announcementsHasMore == false && fetchCount == 3
            && !FileManager.default.fileExists(atPath: root.path)
    }

    /// Invoke delivery from a detached task and verify that Combine receives
    /// the published state on the main thread after the async delivery work.
    /// This fails against an unisolated `deliverLocally` implementation.
    fileprivate static func mainActorDeliverySelfTest(now: Date) async -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-public-main-actor-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: root)
        monitor.notifyLocally = { _ in .submitted }
        var publishedOnMain = true
        var publicationCount = 0
        let subscription = monitor.$localStatus.sink { value in
            guard value != nil else { return }
            publicationCount += 1
            publishedOnMain = publishedOnMain && Thread.isMainThread
        }
        var ledger = PublicResetDeliveryLedger()
        ledger.initialized = true
        ledger.records["older"] = .pending
        let event = PublicResetAnnouncement(
            id: "101", resetType: .regular, announcedAt: now.addingTimeInterval(-60), text: "fixture",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/101")))
        let page = PublicResetPage(
            data: [event], pagination: .init(hasMore: true, nextCursor: "older"), meta: .init(apiVersion: "v1", generatedAt: now))
        let delivery = Task.detached { [ledger] () -> Bool in
            do {
                try await monitor.deliverLocally(page, ledger: ledger)
                return true
            } catch { return false }
        }
        let completed = await delivery.value
        withExtendedLifetime(subscription) {}
        return completed && publicationCount > 0 && publishedOnMain
    }
}

enum PublicResetAnnouncementSelfTest {
    static func run() -> Bool {
        guard HomeMessageLinkPolicy.selfTest() else { return false }
        guard PublicResetForecastSelfTest.run() else { return false }
        let now = Date()
        let date = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        func item(_ id: String) -> [String: Any] {
            [
                "id": id, "reset_type": "banked", "announced_at": date, "text": "Public fixture",
                "source": ["type": "x_post", "author": "thsottiaux", "url": "https://x.com/thsottiaux/status/\(id)"],
            ]
        }
        func page(_ rows: [[String: Any]], more: Bool = false) throws -> PublicResetPage {
            try PublicResetPage.decode(
                JSONSerialization.data(withJSONObject: [
                    "data": rows, "pagination": ["has_more": more, "next_cursor": NSNull()],
                    "meta": ["api_version": "v1", "generated_at": date],
                ]), now: now)
        }
        do {
            let initial = try page([item("101")])
            var ledger = PublicResetDeliveryLedger()
            try ledger.observe(initial)
            guard ledger.records["101"] == .baseline else { return false }
            let updated = try page([item("102"), item("101")])
            try ledger.observe(updated)
            guard ledger.records["102"] == .pending else { return false }
            ledger.records["102"] = .sending
            ledger = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: JSONEncoder().encode(ledger))
            ledger.recoverInterruptedSends()
            try ledger.observe(updated)
            guard ledger.records["102"] == .uncertain else { return false }
            ledger.records["102"] = .sent
            try ledger.observe(updated)
            guard ledger.records["102"] == .sent else { return false }
            try ledger.observe(page([item("101")]))
            try ledger.observe(updated)
            guard ledger.records["102"] == .sent else { return false }
            try ledger.observe(page([]))
            try ledger.observe(initial)
            guard ledger.records["101"] == .baseline else { return false }
            let olderDate = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
            var historical = item("99")
            historical["announced_at"] = olderDate
            try ledger.observe(page([historical, item("102")]))
            guard ledger.records["99"] == .baseline else { return false }
            var queued = PublicResetDeliveryLedger()
            try queued.observe(initial)
            try queued.observe(updated)
            try queued.observe(initial)
            guard queued.records["102"] == .pending, queued.payloads?["102"] != nil else { return false }
            var full = PublicResetDeliveryLedger()
            full.initialized = true
            full.observedDates = [:]
            for index in 1000..<1500 {
                full.records[String(index)] = .pending
                full.observedDates?[String(index)] = now.addingTimeInterval(-3600)
            }
            do {
                try full.observe(initial)
                return false
            } catch PublicResetFailure.queueFull {} catch { return false }
            guard full.records.count == 500, full.records["101"] == nil else { return false }
            do {
                try full.observe(page([item("1000"), item("101")]))
                return false
            } catch PublicResetFailure.queueFull {} catch { return false }
            guard full.payloads?["1000"] != nil, full.missingPayloadIDs.count == 499 else { return false }
            full.records["1000"] = .sent
            try full.observe(initial)
            guard full.records.count == 500, full.records["101"] == .pending else { return false }
            let lockRoot = FileManager.default.temporaryDirectory.appendingPathComponent("next-public-reset-lock-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: lockRoot) }
            guard let firstLock = try PublicResetDeliveryLock.acquire(in: lockRoot) else { return false }
            guard try PublicResetDeliveryLock.acquire(in: lockRoot) == nil else {
                firstLock.release()
                return false
            }
            firstLock.release()
            guard let nextLock = try PublicResetDeliveryLock.acquire(in: lockRoot) else { return false }
            nextLock.release()
            do {
                _ = try page([item("101"), item("101")])
                return false
            } catch {}
            do {
                try ledger.observe(page([item("999")], more: true))
                return false
            } catch {}
            var invalid = item("101")
            invalid["source"] = ["type": "x_post", "author": "thsottiaux", "url": "https://x.com.attacker.invalid/thsottiaux/status/101"]
            do {
                _ = try page([invalid])
                return false
            } catch {}
            invalid = item("101")
            invalid["announced_at"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
            do {
                _ = try page([invalid])
                return false
            } catch {}
            let authorizedEvent = initial.data[0]
            for phase in [PublicResetDeliveryLedger.Phase.sending, .sent, .uncertain] {
                var reserved = PublicResetDeliveryLedger()
                reserved.records[authorizedEvent.id] = phase
                do {
                    try reserved.reserveAuthorizedDelivery(authorizedEvent)
                    return false
                } catch PublicResetFailure.localState {}
            }
            for phase in [PublicResetDeliveryLedger.Phase.baseline, .pending] {
                var reserved = PublicResetDeliveryLedger()
                reserved.records[authorizedEvent.id] = phase
                try reserved.reserveAuthorizedDelivery(authorizedEvent)
                guard reserved.records[authorizedEvent.id] == .sending,
                    reserved.payloads?[authorizedEvent.id]?.text == "public-announcement"
                else { return false }
                reserved.recoverInterruptedSends()
                guard reserved.records[authorizedEvent.id] == .uncertain else { return false }
            }
            var retired = PublicResetDeliveryLedger()
            retired.retiredThrough = authorizedEvent.announcedAt
            do {
                try retired.reserveAuthorizedDelivery(authorizedEvent)
                return false
            } catch PublicResetFailure.localState {}
            let payload = try FeishuWebhookService.publicResetPayload(initial.data[0], language: .zh)
            guard let body = String(data: payload, encoding: .utf8),
                body.contains("额度重置公告"), body.contains("公告类型本身不证明已完成或已到账"), body.contains("请到账号页核对官方额度与可用重置卡"),
                !body.contains("发重置卡了"), body.contains("\"template\":\"purple\""),
                !body.contains("Public fixture"), !body.contains("官方公告"), !body.contains("Official announcement")
            else { return false }
            let regular = PublicResetAnnouncement(
                id: "103", resetType: .regular, announcedAt: now.addingTimeInterval(-30), text: "fixture",
                source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/103")))
            let regularPayload = try FeishuWebhookService.publicResetPayload(regular, language: .en)
            guard let regularBody = String(data: regularPayload, encoding: .utf8),
                regularBody.contains("Quota reset announcement"),
                regularBody.contains("does not confirm completion or receipt"), regularBody.contains("\"template\":\"turquoise\""),
                // \p{Han} also matches U+00B7 (its Script_Extensions include Han),
                // so assert on the ideograph blocks the copy could actually use.
                regularBody.range(of: "[\\x{3400}-\\x{9FFF}\\x{F900}-\\x{FAFF}]", options: .regularExpression) == nil
            else { return false }
            let result = HistoryTestResult()
            let completed = DispatchSemaphore(value: 0)
            Task.detached {
                let historyPassed = await historyRecoverySelfTest(now: now)
                let localPassed = await PublicResetAnnouncementMonitor.deliverySelfTest(now: now)
                let optionalPassed = await PublicResetAnnouncementMonitor.optionalFeishuRecoverySelfTest(now: now)
                let mainActorPassed = await PublicResetAnnouncementMonitor.mainActorDeliverySelfTest(now: now)
                let pagePublicationPassed = await PublicResetAnnouncementMonitor.pagePublicationSelfTest(now: now)
                let inboxPassed = await MainActor.run {
                    HomeMessageInboxStore.visibleLimitSelfTest(now: now)
                }
                result.set(historyPassed && localPassed && optionalPassed && mainActorPassed && pagePublicationPassed && inboxPassed)
                completed.signal()
            }
            // The self-test entry point runs on MainActor. Pump its run loop
            // while waiting so the actor-isolation regression can actually
            // execute; a blocking semaphore wait would deadlock MainActor.
            let deadline = Date().addingTimeInterval(5)
            while completed.wait(timeout: .now()) != .success, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            guard result.get() else { return false }
            let encodedURL = try PublicResetClient.requestURL(cursor: "opaque+/=cursor&x=y")
            guard encodedURL.host == "codex-resets.com",
                URLComponents(url: encodedURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value == "opaque+/=cursor&x=y"
            else { return false }
            print(
                "Public reset announcement self-test passed: default baseline, dedupe, interrupted send, full-queue hydration, bounded history recovery and MainActor publication")
            return true
        } catch {
            print("Public reset announcement self-test failed")
            return false
        }
    }
    private final class HistoryTestResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ next: Bool) {
            lock.lock()
            value = next
            lock.unlock()
        }
        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func historyRecoverySelfTest(now: Date) async -> Bool {
        func event(_ id: String, secondsAgo: Double) -> PublicResetAnnouncement {
            PublicResetAnnouncement(
                id: id, resetType: .regular, announcedAt: now.addingTimeInterval(-secondsAgo),
                text: "fixture", source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/\(id)")))
        }
        func page(_ events: [PublicResetAnnouncement], cursor: String?) -> PublicResetPage {
            PublicResetPage(
                data: events, pagination: .init(hasMore: cursor != nil, nextCursor: cursor),
                meta: .init(apiVersion: "v1", generatedAt: now))
        }
        do {
            let first = page([event("200", secondsAgo: 60)], cursor: "older")
            var old = PublicResetDeliveryLedger()
            old.initialized = true
            old.records["100"] = .pending
            var requests = 0
            let recovered = await PublicResetHistoryRecovery.recover(first: first, ledgers: [old]) { cursor, _ in
                requests += 1
                guard cursor == "older" else { throw PublicResetFailure.invalidResponse }
                return page([event("100", secondsAgo: 120)], cursor: nil)
            }
            try old.observe(recovered.page)
            guard requests == 1, old.payloads?["100"] != nil, old.records["100"] == .pending else { return false }
            _ = await PublicResetHistoryRecovery.recover(first: first, ledgers: []) { _, _ in
                requests += 1
                throw PublicResetFailure.invalidResponse
            }
            guard requests == 1 else { return false }
            var missing = PublicResetDeliveryLedger()
            missing.initialized = true
            missing.records["1"] = .pending
            requests = 0
            let bounded = await PublicResetHistoryRecovery.recover(first: first, ledgers: [missing]) { _, _ in
                requests += 1
                return page([event(String(200 - requests), secondsAgo: Double(60 + requests))], cursor: "page-\(requests)")
            }
            guard requests == 4, bounded.page.data.count == 5, bounded.checkpoint != nil else { return false }
            requests = 0
            _ = await PublicResetHistoryRecovery.recover(first: first, ledgers: [missing]) { _, _ in
                requests += 1
                return page([event("199", secondsAgo: 61)], cursor: "older")
            }
            guard requests == 1 else { return false }
            let duplicate = await PublicResetHistoryRecovery.recover(first: first, ledgers: [missing]) { _, _ in first }
            guard case .invalidResponse = duplicate.failure else { return false }

            // The third page fails; the verified second page survives a saved
            // ledger round trip, and the next run starts at the failing cursor.
            var partial = PublicResetDeliveryLedger()
            partial.initialized = true
            partial.records = ["200": .baseline, "100": .pending, "50": .pending]
            let interrupted = await PublicResetHistoryRecovery.recover(first: first, ledgers: [partial]) { cursor, _ in
                if cursor == "older" { return page([event("100", secondsAgo: 120)], cursor: "failing-page") }
                throw PublicResetFailure.unavailable
            }
            partial.hydrate(interrupted.recoveredRows)
            partial.historyCheckpoint = interrupted.checkpoint
            partial = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: JSONEncoder().encode(partial))
            guard partial.payloads?["100"] != nil, partial.historyCheckpoint?.cursor == "failing-page" else { return false }
            requests = 0
            let resumed = await PublicResetHistoryRecovery.recover(first: first, ledgers: [partial]) { cursor, _ in
                requests += 1
                guard cursor == "failing-page" else { throw PublicResetFailure.invalidResponse }
                return page([event("50", secondsAgo: 180)], cursor: nil)
            }
            partial.hydrate(resumed.recoveredRows)
            guard requests == 1, partial.missingPayloadIDs.isEmpty else { return false }

            // More than five pages require multiple rounds. Persist only the
            // cursor and recovered existing IDs, retaining the per-run bound.
            var distant = PublicResetDeliveryLedger()
            distant.initialized = true
            distant.records["1"] = .pending
            var seen: [String] = []
            for _ in 0..<2 {
                let batch = await PublicResetHistoryRecovery.recover(first: page([event("900", secondsAgo: 1)], cursor: "2"), ledgers: [distant]) { cursor, _ in
                    seen.append(cursor)
                    guard let number = Int(cursor), (2...7).contains(number) else { throw PublicResetFailure.invalidResponse }
                    return page([event(number == 7 ? "1" : String(900 - number), secondsAgo: Double(number))], cursor: number == 7 ? nil : String(number + 1))
                }
                distant.hydrate(batch.recoveredRows)
                distant.historyCheckpoint = batch.checkpoint
                distant = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: JSONEncoder().encode(distant))
            }
            guard seen == ["2", "3", "4", "5", "6", "7"], distant.payloads?["1"] != nil else { return false }
            return true
        } catch { return false }
    }

}
