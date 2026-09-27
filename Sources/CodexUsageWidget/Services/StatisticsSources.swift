import Foundation

/// Data-only projection of the pinned upstream catalog; no credentials are read here.
struct StatisticsClientCatalog: Decodable {
    struct Client: Decodable, Identifiable {
        let id: String
        let label: String
        let defaultTracked: Bool
    }

    let schemaVersion: Int
    let upstreamCommit: String
    let clients: [Client]

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let root = bundle.resourceURL else { throw TokenMonitorFailure.missingBundle }
        return try load(url: root.appendingPathComponent("TokenMonitorEngine/client-catalog.json"))
    }

    static func load(url: URL) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.schemaVersion == 1,
            catalog.upstreamCommit == "dcccfb01557e2786888fd5479552f392ac6c0d32",
            !catalog.clients.isEmpty,
            Set(catalog.clients.map(\.id)).count == catalog.clients.count,
            catalog.clients.allSatisfy({ TokenMonitorSource.safeID($0.id) })
        else { throw TokenMonitorFailure.invalidResponse }
        return catalog
    }

    func enabledIDs(defaults: UserDefaults = .standard) -> Set<String> {
        let known = Set(clients.map(\.id))
        if let saved = defaults.stringArray(forKey: StatisticsSources.selectionKey) {
            return Set(saved).intersection(known)
        }
        return Set(clients.filter(\.defaultTracked).map(\.id))
    }
}

enum StatisticsSources {
    static let selectionKey = "CodexManagerNext.statisticsClientIDs"
    static let selectionChanged = Notification.Name("CodexManagerNext.statisticsClientSelectionChanged")

    static func saveSelection(_ ids: Set<String>, catalog: StatisticsClientCatalog, defaults: UserDefaults = .standard) {
        defaults.set(catalog.clients.map(\.id).filter(ids.contains), forKey: selectionKey)
        NotificationCenter.default.post(name: selectionChanged, object: nil)
    }

    /// Each source explicitly authorizes an upstream layout. The engine deduplicates actual scan roots.
    /// The current login is not evidence of ownership of every historical session in that directory.
    static func make(
        catalog: StatisticsClientCatalog,
        enabledIDs: Set<String>,
        userHome: URL,
        systemCodexHome: URL?,
        localProfiles: [LocalCLIProfile]
    ) throws -> [TokenMonitorSource] {
        var sources = catalog.clients.filter { enabledIDs.contains($0.id) && $0.id != "codex" }.map {
            TokenMonitorSource(
                id: "default-" + $0.id, providerId: $0.id, kind: .agentLogs,
                canonicalPath: userHome.path, pathRole: .userHome, toolId: $0.id)
        }
        if enabledIDs.contains("codex"), let systemCodexHome {
            sources.append(
                TokenMonitorSource(
                    id: "system-history", providerId: "codex", kind: .managedAccount,
                    canonicalPath: systemCodexHome.path, pathRole: .codexHome, toolId: "codex"))
        }
        for profile in localProfiles where !profile.isDefault {
            let provider: String
            let subdirectory: String
            switch profile.kind {
            case .claudeCode:
                provider = "claude"
                subdirectory = "projects"
            case .grok:
                provider = "grok"
                subdirectory = "sessions"
            default: continue
            }
            guard enabledIDs.contains(provider) else { continue }
            sources.append(
                TokenMonitorSource(
                    id: "local-" + profile.id, providerId: provider, kind: .agentLogs,
                    canonicalPath: URL(fileURLWithPath: profile.configDirectory).appendingPathComponent(subdirectory).path,
                    pathRole: .logRoot, toolId: provider))
        }
        return try TokenMonitorSource.validated(sources)
    }
}
