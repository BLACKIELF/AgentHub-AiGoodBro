import Foundation

/// Shared editorial content only. No install detection, credentials or network access.
struct RecommendationCatalog: Decodable, Equatable, Sendable {
    struct Text: Decodable, Equatable, Sendable {
        let zh: String
        let en: String
    }

    struct Entry: Decodable, Equatable, Sendable {
        let id: String
        let kind: String
        let title: Text
        let purpose: Text
        let summary: Text
        let symbol: String
        let icon: String
        let skillDirectory: String?
        let skillNames: [String]
        let appBundleIDs: [String]
        let sourceURL: String
        let sourceLabel: String
        let category: String
        let tags: [String]
        let updatedAt: String
        let verification: String
        let prerequisites: [String]
        let steps: [String]
        let copyText: String
    }

    enum Failure: Error { case unavailable, invalid }
    static let expectedIDs = ["oracle", "handoff", "jev-use", "quicktoggle", "rea", "aihot"]
    private static let directories: [String?] = ["oracle", "handoff", "jev-cu", nil, "reverse-engineer-anything", nil]
    private static let aliases = [["oracle"], ["handoffskill", "handoff"], ["jev-use", "jev-cu"], [], ["reverse-engineer-anything"], []]
    static let empty = Self(schemaVersion: 1, revision: "", updatedAt: "", items: [])
    static let bundled = (try? load()) ?? .empty

    let schemaVersion: Int
    let revision: String
    let updatedAt: String
    let items: [Entry]

    func entry(_ id: String) -> Entry? { items.first { $0.id == id } }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let root = bundle.resourceURL else { throw Failure.unavailable }
        return try load(url: root.appendingPathComponent("SkillLibrary/catalog.json"))
    }

    static func load(url: URL) throws -> Self {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 262_144,
            let text = String(data: data, encoding: .utf8), !text.contains("/Users/")
        else { throw Failure.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1,
            value.revision.range(of: #"^\d{4}v[1-9]\d*$"#, options: .regularExpression) != nil,
            validDate(value.updatedAt), value.items.map(\.id) == expectedIDs
        else { throw Failure.invalid }
        for (index, entry) in value.items.enumerated() {
            guard entry.kind == (["quicktoggle", "aihot"].contains(entry.id) ? "app" : "skill"),
                entry.skillDirectory == directories[index], entry.skillNames == aliases[index],
                entry.appBundleIDs == (entry.id == "quicktoggle" ? ["com.quicktoggle.app"] : []),
                [entry.title, entry.purpose, entry.summary].allSatisfy({ nonempty($0.zh) && nonempty($0.en) }),
                [entry.symbol, entry.icon, entry.sourceLabel, entry.category, entry.verification, entry.copyText].allSatisfy(nonempty),
                [entry.tags, entry.prerequisites, entry.steps].allSatisfy({ !$0.isEmpty && $0.allSatisfy(nonempty) }),
                validDate(entry.updatedAt), let url = URLComponents(string: entry.sourceURL),
                url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil
            else { throw Failure.invalid }
        }
        return value
    }

    private static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }
}
