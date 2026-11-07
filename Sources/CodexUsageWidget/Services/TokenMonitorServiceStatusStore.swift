import Foundation

enum TokenMonitorServiceHealth: String, Codable, Sendable {
    case operational
    case degraded
    case outage
    case unknown
}

enum TokenMonitorServiceStatusIndicator: String, Codable, Sendable {
    case none
    case minor
    case major
    case critical
    case unknown
}

enum TokenMonitorServiceStatusProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case openAI = "openai"
    case cursor
    case factory
    case kimi
    case copilot = "github"
    case devin
    case minimax
    case minimaxInternational = "minimax-intl"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .cursor: "Cursor"
        case .factory: "Factory Droid"
        case .kimi: "Kimi"
        case .copilot: "Copilot"
        case .devin: "Devin"
        case .minimax: "MiniMax (China)"
        case .minimaxInternational: "MiniMax (International)"
        }
    }
    var pageURL: URL {
        let address: String
        switch self {
        case .claude: address = "https://status.claude.com"
        case .openAI: address = "https://status.openai.com"
        case .cursor: address = "https://status.cursor.com"
        case .factory: address = "https://status.factory.ai"
        case .kimi: address = "https://status.moonshot.cn"
        case .copilot: address = "https://www.githubstatus.com"
        case .devin: address = "https://www.devinstatus.com"
        case .minimax: address = "https://status.minimaxi.com"
        case .minimaxInternational: address = "https://status.minimax.io"
        }
        return URL(string: address)!
    }

    // GitHub's page also covers unrelated services. Follow the upstream
    // Copilot scope instead of claiming a GitHub Actions incident affects Code.
    var componentIDs: Set<String> {
        self == .copilot ? ["pjmpxvq2cmr2", "cnnb39dkkk82"] : []
    }
}

struct TokenMonitorServiceComponentIssue: Decodable, Equatable, Identifiable, Sendable {
    var id: String { name + ":" + status }
    let name: String
    let status: String
}

struct TokenMonitorServiceStatusEntry: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let pageURL: String
    let state: TokenMonitorServiceHealth
    let indicator: TokenMonitorServiceStatusIndicator
    let description: String
    let checkedAt: Date
    let updatedAt: Date?
    let componentIssues: [TokenMonitorServiceComponentIssue]
    let incidentTitle: String?
    let incidentCount: Int
    let maintenanceCount: Int
    let error: String?
    let isStale: Bool

    func localizedError(_ language: WidgetLanguage) -> String? {
        guard error != nil else { return nil }
        return isStale
            ? language.text("无法刷新；仍显示上次成功读取的状态。", "Could not refresh; showing the last successful status.")
            : language.text("暂时无法读取官方服务状态。", "Official service status is temporarily unavailable.")
    }
}

@MainActor
final class TokenMonitorServiceStatusStore: ObservableObject {
    @Published private(set) var entries: [TokenMonitorServiceStatusProvider: TokenMonitorServiceStatusEntry]
    var providers: [TokenMonitorServiceStatusEntry] {
        TokenMonitorServiceStatusProvider.allCases.compactMap { entries[$0] }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var error: String?

    func localizedError(_ language: WidgetLanguage) -> String? {
        guard error != nil else { return nil }
        return language.text("部分官方服务状态暂时无法读取。", "Some official service statuses are temporarily unavailable.")
    }

    private let transport: TokenMonitorHTTPTransport
    private let previewOnly: Bool
    private var cacheExpiresAt: Date?

    nonisolated init(
        transport: TokenMonitorHTTPTransport = TokenMonitorURLSessionTransport(),
        previewOnly: Bool = false,
        previewEntries: [TokenMonitorServiceStatusProvider: TokenMonitorServiceStatusEntry] = [:]
    ) {
        self.transport = transport
        self.previewOnly = previewOnly
        _entries = Published(initialValue: previewEntries)
    }

    func refresh(force: Bool = false, now: Date = Date()) async {
        guard !previewOnly else { return }
        if !force, let cacheExpiresAt, now < cacheExpiresAt { return }
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        let previous = entries
        let checkedAt = now
        let results = await withTaskGroup(
            of: (TokenMonitorServiceStatusProvider, TokenMonitorServiceStatusEntry).self,
            returning: [TokenMonitorServiceStatusProvider: TokenMonitorServiceStatusEntry].self
        ) { group in
            for provider in TokenMonitorServiceStatusProvider.allCases {
                group.addTask { [transport] in
                    let entry = await Self.fetch(
                        provider: provider, checkedAt: checkedAt, transport: transport, staleValue: previous[provider])
                    return (provider, entry)
                }
            }
            var collected: [TokenMonitorServiceStatusProvider: TokenMonitorServiceStatusEntry] = [:]
            for await (provider, entry) in group { collected[provider] = entry }
            return collected
        }
        guard !Task.isCancelled else { return }
        entries = results
        lastChecked = checkedAt
        let failed = results.values.contains { $0.error != nil }
        error = failed ? "Some official service status pages could not be checked." : nil
        cacheExpiresAt = checkedAt.addingTimeInterval(failed ? 10 : 60)
    }

    private static func fetch(
        provider: TokenMonitorServiceStatusProvider,
        checkedAt: Date,
        transport: TokenMonitorHTTPTransport,
        staleValue: TokenMonitorServiceStatusEntry?
    ) async -> TokenMonitorServiceStatusEntry {
        var request = URLRequest(url: endpoint(provider.pageURL, path: "api/v2/summary.json"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AiGoodBro Token status check", forHTTPHeaderField: "User-Agent")
        do {
            let response = try await transport.send(request, maximumResponseBytes: 524_288)
            guard response.statusCode == 200,
                let entry = summarize(provider: provider, data: response.body, checkedAt: checkedAt)
            else {
                return failed(provider: provider, checkedAt: checkedAt, staleValue: staleValue)
            }
            return entry
        } catch is CancellationError {
            return staleValue ?? failed(provider: provider, checkedAt: checkedAt, staleValue: nil)
        } catch {
            return failed(provider: provider, checkedAt: checkedAt, staleValue: staleValue)
        }
    }

    private static func endpoint(_ base: URL, path: String) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = "/" + path
        return parts.url!
    }

    private static func failed(
        provider: TokenMonitorServiceStatusProvider,
        checkedAt: Date,
        staleValue: TokenMonitorServiceStatusEntry?
    ) -> TokenMonitorServiceStatusEntry {
        if let staleValue {
            return TokenMonitorServiceStatusEntry(
                id: staleValue.id, label: staleValue.label, pageURL: staleValue.pageURL,
                state: staleValue.state, indicator: staleValue.indicator,
                description: staleValue.description, checkedAt: checkedAt,
                updatedAt: staleValue.updatedAt, componentIssues: staleValue.componentIssues,
                incidentTitle: staleValue.incidentTitle, incidentCount: staleValue.incidentCount,
                maintenanceCount: staleValue.maintenanceCount,
                error: "Could not refresh this service status.", isStale: true)
        }
        return TokenMonitorServiceStatusEntry(
            id: provider.id, label: provider.label, pageURL: provider.pageURL.absoluteString,
            state: .unknown, indicator: .unknown, description: "Unable to check status",
            checkedAt: checkedAt, updatedAt: nil, componentIssues: [], incidentTitle: nil,
            incidentCount: 0, maintenanceCount: 0,
            error: "Could not check this service status.", isStale: false)
    }

    /// Pure parser shared with offline service-status fixtures.
    static func summarize(provider: TokenMonitorServiceStatusProvider, data: Data, checkedAt: Date) -> TokenMonitorServiceStatusEntry? {
        guard let payload = try? JSONDecoder().decode(StatuspageSummary.self, from: data) else { return nil }
        let scope = provider.componentIDs
        if !scope.isEmpty {
            let components = (payload.components ?? []).filter { scope.contains($0.id ?? "") }
            guard scope.isSubset(of: Set(components.compactMap(\.id))) else { return nil }
        }
        return summarize(provider: provider, payload: payload, checkedAt: checkedAt)
    }

    private static func summarize(
        provider: TokenMonitorServiceStatusProvider,
        payload: StatuspageSummary,
        checkedAt: Date
    ) -> TokenMonitorServiceStatusEntry {
        let scope = provider.componentIDs
        let sourceComponents = (payload.components ?? []).filter { scope.isEmpty || scope.contains($0.id ?? "") }
        let incidents = (payload.incidents ?? []).filter {
            let status = ($0.status ?? "").lowercased()
            return !status.isEmpty && !["resolved", "completed", "postmortem"].contains(status)
                && (scope.isEmpty || ($0.components ?? []).contains { scope.contains($0.id ?? "") })
        }
        let maintenances = (payload.scheduledMaintenances ?? []).filter {
            let status = ($0.status ?? "").lowercased()
            return !status.isEmpty && !["completed", "canceled"].contains(status)
                && (scope.isEmpty || ($0.components ?? []).contains { scope.contains($0.id ?? "") })
        }
        let indicator: TokenMonitorServiceStatusIndicator
        if scope.isEmpty {
            indicator = TokenMonitorServiceStatusIndicator(rawValue: payload.status?.indicator?.lowercased() ?? "unknown") ?? .unknown
        } else {
            var ranks = sourceComponents.map { component -> Int in
                switch component.status?.lowercased() {
                case "operational", "under_maintenance": return 0
                case "major_outage": return 3
                case "partial_outage": return 2
                default: return 1
                }
            }
            ranks += incidents.map { incident -> Int in
                switch incident.impact?.lowercased() {
                case "none": return 0
                case "critical": return 3
                case "major": return 2
                default: return 1
                }
            }
            indicator = [.none, .minor, .major, .critical][ranks.max() ?? 0]
        }
        let state: TokenMonitorServiceHealth
        switch indicator {
        case .none: state = .operational
        case .minor: state = .degraded
        case .major, .critical: state = .outage
        case .unknown: state = .unknown
        }
        let components = sourceComponents.compactMap { component -> TokenMonitorServiceComponentIssue? in
            let status = component.status?.lowercased() ?? "unknown"
            guard status != "operational", status != "under_maintenance" else { return nil }
            return TokenMonitorServiceComponentIssue(
                name: String((component.name ?? "Unknown").prefix(120)),
                status: String(status.prefix(40)))
        }
        return TokenMonitorServiceStatusEntry(
            id: provider.id, label: provider.label, pageURL: provider.pageURL.absoluteString,
            state: state, indicator: indicator,
            description: scope.isEmpty
                ? String((payload.status?.description ?? "Unknown").prefix(160))
                : indicator == .none ? "All Systems Operational" : indicator == .minor ? "Degraded Performance" : "Service Outage",
            checkedAt: checkedAt,
            updatedAt: TokenMonitorResponse.timestamp(payload.page?.updatedAt ?? payload.status?.updatedAt ?? ""),
            componentIssues: Array(components.prefix(32)),
            incidentTitle: incidents.first?.name.map { String($0.prefix(160)) },
            incidentCount: min(incidents.count, 100), maintenanceCount: min(maintenances.count, 100),
            error: nil, isStale: false)
    }
}

private struct StatuspageSummary: Decodable {
    struct Status: Decodable {
        let indicator: String?
        let description: String?
        let updatedAt: String?
        enum CodingKeys: String, CodingKey {
            case indicator, description
            case updatedAt = "updated_at"
        }
    }
    struct Page: Decodable {
        let updatedAt: String?
        enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
    }
    struct Component: Decodable {
        let id: String?
        let name: String?
        let status: String?
    }
    struct Incident: Decodable {
        let name: String?
        let status: String?
        let impact: String?
        let components: [Component]?
    }
    let status: Status?
    let page: Page?
    let components: [Component]?
    let incidents: [Incident]?
    let scheduledMaintenances: [Incident]?
    enum CodingKeys: String, CodingKey {
        case status, page, components, incidents
        case scheduledMaintenances = "scheduled_maintenances"
    }
}
