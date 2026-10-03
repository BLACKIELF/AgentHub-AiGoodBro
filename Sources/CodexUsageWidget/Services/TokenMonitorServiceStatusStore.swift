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

    var id: String { rawValue }
    var label: String { self == .claude ? "Claude" : "OpenAI" }
    var pageURL: URL {
        switch self {
        case .claude: URL(string: "https://status.claude.com")!
        case .openAI: URL(string: "https://status.openai.com")!
        }
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
                let page = try? JSONDecoder().decode(StatuspageSummary.self, from: response.body)
            else {
                return failed(provider: provider, checkedAt: checkedAt, staleValue: staleValue)
            }
            return summarize(provider: provider, payload: page, checkedAt: checkedAt)
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

    private static func summarize(
        provider: TokenMonitorServiceStatusProvider,
        payload: StatuspageSummary,
        checkedAt: Date
    ) -> TokenMonitorServiceStatusEntry {
        let raw = payload.status?.indicator?.lowercased() ?? "unknown"
        let indicator = TokenMonitorServiceStatusIndicator(rawValue: raw) ?? .unknown
        let state: TokenMonitorServiceHealth
        switch indicator {
        case .none: state = .operational
        case .minor: state = .degraded
        case .major, .critical: state = .outage
        case .unknown: state = .unknown
        }
        let components = (payload.components ?? []).compactMap { component -> TokenMonitorServiceComponentIssue? in
            let status = component.status?.lowercased() ?? "unknown"
            guard status != "operational", status != "under_maintenance" else { return nil }
            return TokenMonitorServiceComponentIssue(
                name: String((component.name ?? "Unknown").prefix(120)),
                status: String(status.prefix(40)))
        }
        let incidents = (payload.incidents ?? []).filter {
            !["resolved", "completed", "postmortem"].contains(($0.status ?? "").lowercased())
        }
        let maintenances = (payload.scheduledMaintenances ?? []).filter {
            !["completed", "canceled"].contains(($0.status ?? "").lowercased())
        }
        return TokenMonitorServiceStatusEntry(
            id: provider.id, label: provider.label, pageURL: provider.pageURL.absoluteString,
            state: state, indicator: indicator,
            description: String((payload.status?.description ?? "Unknown").prefix(160)),
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
        let name: String?
        let status: String?
    }
    struct Incident: Decodable {
        let name: String?
        let status: String?
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
