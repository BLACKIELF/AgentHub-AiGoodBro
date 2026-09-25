import Combine
import Foundation

/// Maintainer-authored public text, separate from quota evidence and reset credits.
struct PublisherMessage: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let publishedAt: Date
    let expiresAt: Date
    let url: URL?

    func isActive(at now: Date) -> Bool { publishedAt <= now && now < expiresAt }

    static func allowedURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "https", parts.user == nil, parts.password == nil,
            parts.port == nil, parts.query == nil, parts.fragment == nil
        else { return false }
        return parts.host == "aigoodbro.com"
            || (parts.host == "github.com" && parts.path.hasPrefix("/BLACKIELF/"))
    }
}

struct PublisherMessageFeed: Decodable {
    let version: Int
    let messages: [PublisherMessage]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw PublicResetFailure.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let feed = try decoder.decode(Self.self, from: data)
        let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard feed.version == 1, feed.messages.count <= 50,
            Set(feed.messages.map(\.id)).count == feed.messages.count,
            feed.messages.allSatisfy({ item in
                (1...64).contains(item.id.utf8.count) && item.id.unicodeScalars.allSatisfy(idCharacters.contains)
                    && !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.title.utf8.count <= 240
                    && !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.body.utf8.count <= 2_000
                    && item.publishedAt.timeIntervalSince1970.isFinite && item.expiresAt.timeIntervalSince1970.isFinite
                    && item.publishedAt < item.expiresAt && item.expiresAt.timeIntervalSince(item.publishedAt) <= 90 * 86_400
                    && (item.url.map(PublisherMessage.allowedURL) ?? true)
            })
        else { throw PublicResetFailure.invalidResponse }
        return feed
    }

    func visible(at now: Date) -> [PublisherMessage] {
        Array(
            messages.filter { $0.isActive(at: now) }.sorted {
                $0.publishedAt == $1.publishedAt ? $0.id < $1.id : $0.publishedAt > $1.publishedAt
            }.prefix(3))
    }
}

/// Save the observation BEFORE notification submission. Uncertain submissions
/// are not retried, avoiding repeated notifications after crashes or relaunches.
struct PublisherMessageLedger: Codable {
    var baselineAt: Date?
    var seenIDs: [String] = []

    static func record(
        _ feed: PublisherMessageFeed, now: Date, notificationsEnabled: Bool, at url: URL
    ) throws -> PublisherMessage? {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return try DispatchParticipationSync.withSnapshotLock(at: url) {
            let previous = try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: 64 * 1024, allowMissing: true)
            var ledger = try previous.map { try JSONDecoder().decode(Self.self, from: $0) } ?? .init()
            guard ledger.seenIDs.count <= 500, ledger.seenIDs.allSatisfy({ (1...64).contains($0.utf8.count) }),
                ledger.baselineAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
            else { throw PublicResetFailure.localState }
            let candidate = ledger.observe(feed, now: now, notificationsEnabled: notificationsEnabled)
            let data = try JSONEncoder().encode(ledger)
            guard data.count <= 64 * 1024 else { throw PublicResetFailure.localState }
            try DispatchParticipationSync.writeSnapshot(data, at: url, replacing: previous)
            return candidate
        }
    }

    mutating func observe(_ feed: PublisherMessageFeed, now: Date, notificationsEnabled: Bool) -> PublisherMessage? {
        let wasInitialized = baselineAt != nil
        let eligible = feed.visible(at: now).filter {
            !seenIDs.contains($0.id) && $0.publishedAt > (baselineAt ?? now)
        }
        let observed = feed.messages.filter { $0.publishedAt <= now }.map(\.id)
        seenIDs = Array((seenIDs + observed.filter { !seenIDs.contains($0) }).suffix(500))
        // Time watermark also prevents pruned old history from being re-notified.
        let latestObserved = feed.messages.filter { $0.publishedAt <= now }.map(\.publishedAt).max()
        baselineAt = max(baselineAt ?? now, latestObserved ?? (baselineAt ?? now))
        return wasInitialized && notificationsEnabled ? eligible.first : nil
    }
}

enum PublisherMessageSelfTest {
    static func run() -> Bool {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func message(_ id: String, seconds: TimeInterval) -> PublisherMessage {
            .init(
                id: id, title: "Synthetic notice", body: "Public fixture", publishedAt: now.addingTimeInterval(seconds),
                expiresAt: now.addingTimeInterval(seconds + 3_600), url: nil)
        }
        let historical = message("old", seconds: -60)
        let scheduled = message("scheduled", seconds: 60)
        let first = PublisherMessageFeed(version: 1, messages: [historical, scheduled])
        var ledger = PublisherMessageLedger()
        guard first.visible(at: now).map(\.id) == ["old"],
            ledger.observe(first, now: now, notificationsEnabled: true) == nil,
            ledger.observe(first, now: now.addingTimeInterval(61), notificationsEnabled: true)?.id == "scheduled",
            ledger.observe(first, now: now.addingTimeInterval(62), notificationsEnabled: true) == nil,
            first.visible(at: now.addingTimeInterval(4_000)).isEmpty
        else { return false }
        let later = PublisherMessageFeed(version: 1, messages: [message("new", seconds: 90)])
        guard ledger.observe(later, now: now.addingTimeInterval(91), notificationsEnabled: false) == nil,
            ledger.observe(later, now: now.addingTimeInterval(92), notificationsEnabled: true) == nil
        else { return false }
        let burst = PublisherMessageFeed(version: 1, messages: (1...5).map { message("burst-\($0)", seconds: Double(100 + $0)) })
        guard burst.visible(at: now.addingTimeInterval(110)).count == 3,
            ledger.observe(burst, now: now.addingTimeInterval(110), notificationsEnabled: true)?.id == "burst-5",
            !PublisherMessage.allowedURL(URL(string: "https://github.com.attacker.invalid/BLACKIELF/repo")!),
            !PublisherMessage.allowedURL(URL(string: "https://github.com/other/repo")!),
            !PublisherMessage.allowedURL(URL(string: "file:///tmp/test")!),
            PublisherMessage.allowedURL(URL(string: "https://github.com/BLACKIELF/QuickToggle/releases")!)
        else { return false }
        do {
            _ = try PublisherMessageFeed.decode(Data(#"{"version":1,"messages":[]}"#.utf8))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-message-test-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let state = root.appendingPathComponent("ledger.json")
            guard try PublisherMessageLedger.record(first, now: now, notificationsEnabled: true, at: state) == nil,
                try PublisherMessageLedger.record(first, now: now.addingTimeInterval(61), notificationsEnabled: true, at: state)?.id == "scheduled",
                try PublisherMessageLedger.record(first, now: now.addingTimeInterval(62), notificationsEnabled: true, at: state) == nil
            else { return false }
            let broken = Data("broken-ledger".utf8)
            try broken.write(to: state)
            do {
                _ = try PublisherMessageLedger.record(later, now: now.addingTimeInterval(91), notificationsEnabled: true, at: state)
                return false
            } catch {}
            guard try Data(contentsOf: state) == broken else { return false }
            let symlink = root.appendingPathComponent("linked.json")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: state)
            do {
                _ = try PublisherMessageLedger.record(first, now: now, notificationsEnabled: true, at: symlink)
                return false
            } catch {}
            let saved = try JSONEncoder().encode(ledger)
            var restored = try JSONDecoder().decode(PublisherMessageLedger.self, from: saved)
            guard restored.observe(burst, now: now.addingTimeInterval(111), notificationsEnabled: true) == nil else { return false }
            for invalid in [Data(#"{"version":2,"messages":[]}"#.utf8), Data(repeating: 32, count: 65 * 1024)] {
                do {
                    _ = try PublisherMessageFeed.decode(invalid)
                    return false
                } catch {}
            }
        } catch { return false }
        print("Publisher message self-test passed: baseline, schedule, expiry, disabled, latest-three, dedupe and URL boundaries")
        return true
    }
}

private final class PublisherMessageRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

final class PublisherMessageMonitor: ObservableObject {
    static let endpoint = URL(string: "https://raw.githubusercontent.com/BLACKIELF/AgentHub-AiGoodBro/main/Resources/AppMessages/messages-v1.json")!
    private static let cacheKey = "AiGoodBro.publisherMessages.cache.v1"
    @Published private(set) var messages: [PublisherMessage] = []
    @Published private(set) var checking = false
    @Published private(set) var status: String?
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "AiGoodBro.publisherMessages.notify") }
    }
    private let defaults: UserDefaults
    private let stateURL: URL
    private let preview: Bool
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = 0
    private var running = false
    private var notify: ((PublisherMessage, @escaping @MainActor () -> Bool) async -> Bool)?

    init(defaults: UserDefaults = .standard, stateURL: URL? = nil, preview: Bool = false) {
        self.defaults = defaults
        self.preview = preview
        self.stateURL =
            stateURL
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexAccountManagerNext/publisher-messages/ledger-v1.json")
        notificationsEnabled = defaults.bool(forKey: "AiGoodBro.publisherMessages.notify")
        if !preview, let cache = defaults.data(forKey: Self.cacheKey), let feed = try? PublisherMessageFeed.decode(cache) {
            messages = feed.visible(at: Date())
        }
    }

    @MainActor
    func start(notify: @escaping (PublisherMessage, @escaping @MainActor () -> Bool) async -> Bool) {
        guard !preview, !running else { return }
        running = true
        self.notify = notify
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer?.tolerance = 30
    }

    @MainActor
    func stop() {
        running = false
        generation += 1
        task?.cancel()
        task = nil
        checking = false
        timer?.invalidate()
        timer = nil
        notify = nil
    }

    @MainActor
    func refresh() {
        guard running, !checking else { return }
        checking = true
        let epoch = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == epoch {
                    checking = false
                    task = nil
                }
            }
            do {
                let data = try await Self.fetch()
                guard running, generation == epoch, !Task.isCancelled else { return }
                let feed = try PublisherMessageFeed.decode(data)
                let now = Date()
                messages = feed.visible(at: now)
                defaults.set(data, forKey: Self.cacheKey)
                let candidate = try PublisherMessageLedger.record(feed, now: now, notificationsEnabled: notificationsEnabled, at: stateURL)
                status = WidgetLanguage.storedOrAutomatic().text("消息已更新", "Messages updated")
                if let candidate, let notify {
                    let accepted = await notify(candidate) { [weak self] in
                        guard let self else { return false }
                        return self.running && self.generation == epoch && self.notificationsEnabled && candidate.isActive(at: Date())
                    }
                    guard generation == epoch, running else { return }
                    status =
                        accepted
                        ? WidgetLanguage.storedOrAutomatic().text("已提交到通知中心", "Submitted to Notification Center")
                        : WidgetLanguage.storedOrAutomatic().text("消息仅在应用内显示；检查系统通知设置", "Shown in the app only; check notification settings")
                }
            } catch {
                guard running, generation == epoch, !Task.isCancelled else { return }
                messages = messages.filter { $0.isActive(at: Date()) }
                status =
                    error is DispatchParticipationError
                        || (error as? PublicResetFailure).map({
                            if case .localState = $0 { return true }
                            return false
                        }) == true
                    ? WidgetLanguage.storedOrAutomatic().text("消息记录保存失败，已暂停通知", "Message state could not be saved; notifications paused")
                    : WidgetLanguage.storedOrAutomatic().text("公告源暂不可用，保留未过期消息", "Message source unavailable; keeping unexpired messages")
            }
        }
    }

    private static func fetch() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: PublisherMessageRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.url == endpoint, response.expectedContentLength <= 64 * 1024
        else { throw PublicResetFailure.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 64 * 1024 else { throw PublicResetFailure.invalidResponse }
            data.append(byte)
        }
        return data
    }
}
