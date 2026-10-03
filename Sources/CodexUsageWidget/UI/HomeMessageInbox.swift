import SwiftUI

/// Public announcement links are opened only after their first URL passes the
/// service allowlist. The homepage history itself stays inline in the main
/// workspace and never creates a floating message window.
enum HomeMessageLinkPolicy {
    static let allowedHosts: Set<String> = ["x.com", "codex-resets.com"]

    static func allowedURL(_ url: URL?) -> URL? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        guard parts.query == nil, parts.fragment == nil, (parts.queryItems ?? []).isEmpty else { return nil }
        guard let host = parts.host, allowedHosts.contains(host.lowercased()) else { return nil }
        return url
    }

    static func selfTest() -> Bool {
        let good = URL(string: "https://x.com/thsottiaux/status/101")
        let badHost = URL(string: "https://x.com.attacker.invalid/thsottiaux/status/101")
        let userinfo = URL(string: "https://user:pass@x.com/thsottiaux/status/101")
        let http = URL(string: "http://x.com/thsottiaux/status/101")
        let query = URL(string: "https://x.com/thsottiaux/status/101?q=1")
        guard allowedURL(good) == good,
            allowedURL(URL(string: "https://codex-resets.com/")) != nil,
            allowedURL(badHost) == nil,
            allowedURL(userinfo) == nil,
            allowedURL(http) == nil,
            allowedURL(query) == nil
        else { return false }
        return true
    }
}

@MainActor
final class HomeMessageInboxStore: ObservableObject {
    static let shared = HomeMessageInboxStore()
    static let seenKey = "AiGoodBro.messageInbox.seenIDs"
    /// Only entries actually displayed by an inline history surface may be
    /// marked seen; older items remain unread until explicitly shown.
    static let visibleAnnouncementLimit = 3
    @Published private(set) var seenIDs: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.seenKey) ?? []
        seenIDs = Set(stored.filter { (1...64).contains($0.count) })
    }

    func unreadCount(in announcements: [PublicResetAnnouncement]) -> Int {
        announcements.filter { !seenIDs.contains($0.id) }.count
    }

    func markSeen(_ announcements: [PublicResetAnnouncement]) {
        let next = seenIDs.union(announcements.map(\.id))
        guard next != seenIDs else { return }
        seenIDs = next
        defaults.set(Array(next).sorted(), forKey: Self.seenKey)
    }

    /// The only production mark-read action: entries displayed by the inline
    /// surface, never a background fetch, are marked seen.
    func markVisibleSeen(in announcements: [PublicResetAnnouncement]) {
        markSeen(Array(announcements.prefix(Self.visibleAnnouncementLimit)))
    }

    @MainActor
    static func visibleLimitSelfTest(now: Date) -> Bool {
        let suiteName = "AiGoodBro.messageInbox.selftest." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HomeMessageInboxStore(defaults: defaults)
        let items = (1...4).map { index in
            PublicResetAnnouncement(
                id: "inbox-limit-selftest-\(index)", resetType: .regular, announcedAt: now,
                text: "synthetic", source: .init(type: "observed", author: nil, url: nil))
        }
        store.markVisibleSeen(in: items)
        guard store.unreadCount(in: items) == 1 else { return false }
        store.markSeen(items)
        guard store.unreadCount(in: items) == 0 else { return false }
        return true
    }
}
