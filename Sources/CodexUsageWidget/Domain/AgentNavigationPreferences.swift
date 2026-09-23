import Foundation

/// F23 top Agent navigation. Empty `orderedVisibleProviderIDs` is a valid user
/// choice and must not be treated as missing configuration.
struct AgentNavigationState: Codable, Equatable {
    static let storageKey = "AiGoodBro.agentNavigation.v1"
    static let backupKey = "AiGoodBro.agentNavigation.v1.backup"
    static let schemaVersion = 1

    var schemaVersion = AgentNavigationState.schemaVersion
    var initialized = false
    var customized = false
    var orderedVisibleProviderIDs: [String] = []

    static func load(_ data: Data?, backupRaw: inout Data?) -> Self {
        guard let data else { return Self() }
        if let value = try? JSONDecoder().decode(Self.self, from: data) {
            return value.normalized()
        }
        backupRaw = data
        return Self()
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    func normalized() -> Self {
        var copy = self
        copy.schemaVersion = Self.schemaVersion
        var seen = Set<String>()
        var ordered: [String] = []
        for id in copy.orderedVisibleProviderIDs {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != AgentNavCatalog.homeID else { continue }
            if seen.insert(trimmed).inserted { ordered.append(trimmed) }
        }
        copy.orderedVisibleProviderIDs = ordered
        return copy
    }

    mutating func bootstrapIfNeeded(existingUser: Bool, currentVisible: [String]) {
        guard !initialized else { return }
        initialized = true
        guard !customized, orderedVisibleProviderIDs.isEmpty else { return }
        customized = true
        orderedVisibleProviderIDs = existingUser ? dedupe(currentVisible) : []
    }

    mutating func add(_ id: String) -> Bool {
        guard AgentNavCatalog.isAddable(id) else { return false }
        guard !orderedVisibleProviderIDs.contains(id) else { return false }
        customized = true
        initialized = true
        orderedVisibleProviderIDs.append(id)
        return true
    }

    mutating func remove(_ id: String) -> String? {
        guard let index = orderedVisibleProviderIDs.firstIndex(of: id) else { return nil }
        customized = true
        orderedVisibleProviderIDs.remove(at: index)
        return id
    }

    mutating func move(_ id: String, by offset: Int) {
        guard let index = orderedVisibleProviderIDs.firstIndex(of: id) else { return }
        let target = index + offset
        guard orderedVisibleProviderIDs.indices.contains(target) else { return }
        customized = true
        orderedVisibleProviderIDs.remove(at: index)
        orderedVisibleProviderIDs.insert(id, at: target)
    }

    mutating func move(id: String, before target: String?) {
        guard let from = orderedVisibleProviderIDs.firstIndex(of: id) else { return }
        customized = true
        orderedVisibleProviderIDs.remove(at: from)
        if let target, let to = orderedVisibleProviderIDs.firstIndex(of: target) {
            orderedVisibleProviderIDs.insert(id, at: to)
        } else {
            orderedVisibleProviderIDs.append(id)
        }
    }

    mutating func restoreDefault(currentVisible: [String]) {
        customized = true
        initialized = true
        orderedVisibleProviderIDs = dedupe(currentVisible)
    }

    func renderableIDs() -> [String] {
        orderedVisibleProviderIDs.filter { AgentNavCatalog.isRenderable($0) }
    }

    func unknownIDs() -> [String] {
        orderedVisibleProviderIDs.filter { !AgentNavCatalog.isRenderable($0) }
    }

    private func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted && $0 != AgentNavCatalog.homeID }
    }
}

// Older records may omit flags. Presence of the selection (including []) is
// explicit configuration; bootstrap must not replace it with detected providers.
extension AgentNavigationState {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.schemaVersion
        orderedVisibleProviderIDs = try values.decodeIfPresent([String].self, forKey: .orderedVisibleProviderIDs) ?? []
        let hasSelection = values.contains(.orderedVisibleProviderIDs)
        initialized = try values.decodeIfPresent(Bool.self, forKey: .initialized) ?? hasSelection
        customized = try values.decodeIfPresent(Bool.self, forKey: .customized) ?? hasSelection
    }
}

enum AgentNavCatalog {
    static let homeID = "home"
    static let addID = "add"
    static let manageID = "manage"
    static let moreID = "more"
    static let codexID = "codex"

    static let workspaceProviders: [AgentNavProvider] = {
        [AgentNavProvider(id: codexID, displayName: "Codex", localKind: nil, addable: true)]
            + LocalCLIKind.allCases.map { AgentNavProvider(id: $0.rawValue, displayName: $0.displayName, localKind: $0, addable: true) }
    }()

    /// Upstream quota providers that are not yet first-class workspace Agents.
    static let upcomingProviders: [AgentNavProvider] = [
        "cursor", "copilot", "zed", "commandcode", "kiro", "qoder",
        "deepseek", "openrouter", "minimax", "volcengine", "ollama", "alibaba", "thirdparty", "zaiteam",
    ].map { AgentNavProvider(id: $0, displayName: $0, localKind: nil, addable: false) }

    static var allProviders: [AgentNavProvider] { workspaceProviders + upcomingProviders }

    static func provider(id: String) -> AgentNavProvider? {
        allProviders.first { $0.id == id }
    }

    static func isRenderable(_ id: String) -> Bool {
        workspaceProviders.contains { $0.id == id }
    }

    static func isAddable(_ id: String) -> Bool {
        provider(id: id)?.addable == true
    }

    static func displayName(_ id: String) -> String {
        provider(id: id)?.displayName ?? id
    }

    static func localKind(_ id: String) -> LocalCLIKind? {
        provider(id: id)?.localKind
    }
}

struct AgentNavProvider: Identifiable, Hashable {
    let id: String
    let displayName: String
    let localKind: LocalCLIKind?
    let addable: Bool
}

struct AgentNavigationOverflow {
    var visibleIDs: [String]
    var overflowIDs: [String]
    var showsMore: Bool

    static func layout(
        orderedIDs: [String],
        availableWidth: Double,
        homeWidth: Double = 88,
        trailingChromeWidth: Double = 196,
        moreWidth: Double = 92,
        itemWidth: (String) -> Double = { 28 + Double($0.count) * 8 }
    ) -> Self {
        let ids = orderedIDs.filter { AgentNavCatalog.isRenderable($0) }
        let usable = max(0, availableWidth - homeWidth - trailingChromeWidth)
        func fits(_ subset: [String], reserveMore: Bool) -> Bool {
            let extra = reserveMore ? moreWidth : 0
            let items = subset.reduce(0.0) { $0 + itemWidth($1) + 6 }
            return items + extra <= usable || subset.isEmpty
        }
        if fits(ids, reserveMore: false) {
            return AgentNavigationOverflow(visibleIDs: ids, overflowIDs: [], showsMore: false)
        }
        var visible: [String] = []
        for id in ids {
            let candidate = visible + [id]
            if fits(candidate, reserveMore: true) {
                visible = candidate
            } else {
                break
            }
        }
        let overflow = Array(ids.dropFirst(visible.count))
        return AgentNavigationOverflow(visibleIDs: visible, overflowIDs: overflow, showsMore: !overflow.isEmpty)
    }
}
