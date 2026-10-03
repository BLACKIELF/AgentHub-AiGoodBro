import Foundation

/// 24 token-monitor quota providers. Codex stays on the existing production
/// reader; the other 23 reuse upstream adapters. Missing config is
/// `notConfigured` / 「待配置」, never 0% and never a fabricated balance.
enum QuotaProviderID: String, CaseIterable, Identifiable, Codable {
    case claude, codex, opencode, cursor, antigravity, kimi, grok, copilot, zed
    case commandcode, mimo, zai, zaiteam, kiro, workbuddy, qoder, deepseek
    case openrouter, minimax, volcengine, ollama, trae, alibaba, thirdparty

    var id: String { rawValue }
}

enum QuotaProviderIntegration: String, Codable {
    case existingProduction
    case upstreamReuse
}

enum QuotaProviderStatus: String, Codable {
    case ok, disabled, notConfigured, unauthorized, rateLimited, sourceRateLimited, unavailable, error

    static func parse(_ raw: String?) -> Self {
        QuotaProviderStatus(rawValue: raw ?? "") ?? .error
    }

    func presentation(_ language: WidgetLanguage) -> String {
        switch self {
        case .ok: return language.text("已连接", "Connected")
        case .disabled: return language.text("已关闭", "Disabled")
        case .notConfigured: return language.text("待配置", "Needs setup")
        case .unauthorized: return language.text("未授权", "Unauthorized")
        case .rateLimited, .sourceRateLimited: return language.text("频率受限", "Rate limited")
        case .unavailable: return language.text("暂不可用", "Unavailable")
        case .error: return language.text("读取失败", "Read failed")
        }
    }
}

struct QuotaProviderDescriptor: Identifiable, Equatable {
    let id: QuotaProviderID
    let label: String
    let settingsLabel: String
    let integration: QuotaProviderIntegration
    let channel: String
    let configRequirement: String
    let windowKinds: [String]

    var usesExistingProduction: Bool { integration == .existingProduction }
}

enum QuotaProviderCatalog {
    static let pinnedCommit = "2f60827e3028d283969dd74cde5b3f5664220442"

    static let all: [QuotaProviderDescriptor] = [
        .init(
            id: .claude, label: "Claude", settingsLabel: "Claude Code", integration: .upstreamReuse, channel: "oauth-or-cli", configRequirement: "Claude credentials or Claude CLI",
            windowKinds: ["billing", "session", "weekly"]),
        .init(
            id: .codex, label: "Codex", settingsLabel: "Codex", integration: .existingProduction, channel: "oauth-or-cli", configRequirement: "Existing Codex production reader",
            windowKinds: ["session", "daily", "weekly"]),
        .init(
            id: .opencode, label: "OpenCode", settingsLabel: "OpenCode", integration: .upstreamReuse, channel: "local", configRequirement: "Local OpenCode collector data",
            windowKinds: ["session", "weekly"]),
        .init(
            id: .cursor, label: "Cursor", settingsLabel: "Cursor", integration: .upstreamReuse, channel: "web", configRequirement: "Cursor web session cookie",
            windowKinds: ["billing", "weekly"]),
        .init(
            id: .antigravity, label: "Antigravity", settingsLabel: "Antigravity", integration: .upstreamReuse, channel: "rpc", configRequirement: "Antigravity local RPC/OAuth",
            windowKinds: ["weekly"]),
        .init(
            id: .kimi, label: "Kimi", settingsLabel: "Kimi", integration: .upstreamReuse, channel: "api", configRequirement: "Kimi API key",
            windowKinds: ["billing", "session", "weekly"]),
        .init(id: .grok, label: "Grok", settingsLabel: "Grok", integration: .upstreamReuse, channel: "web", configRequirement: "Grok web session", windowKinds: ["billing"]),
        .init(
            id: .copilot, label: "GitHub Copilot", settingsLabel: "GitHub Copilot", integration: .upstreamReuse, channel: "api",
            configRequirement: "GitHub Copilot OAuth/API token", windowKinds: ["billing"]),
        .init(id: .zed, label: "Zed", settingsLabel: "Zed", integration: .upstreamReuse, channel: "web", configRequirement: "Zed web cookie", windowKinds: ["billing"]),
        .init(
            id: .commandcode, label: "Command Code", settingsLabel: "Command Code", integration: .upstreamReuse, channel: "web",
            configRequirement: "Command Code web session cookie", windowKinds: ["billing"]),
        .init(id: .mimo, label: "MiMo", settingsLabel: "MiMo", integration: .upstreamReuse, channel: "web", configRequirement: "MiMo web cookie header", windowKinds: ["billing"]),
        .init(
            id: .zai, label: "GLM", settingsLabel: "Z.ai / GLM", integration: .upstreamReuse, channel: "api", configRequirement: "ZAI/GLM API key",
            windowKinds: ["billing", "session", "weekly"]),
        .init(
            id: .zaiteam, label: "GLM Team", settingsLabel: "Z.ai Team", integration: .upstreamReuse, channel: "api", configRequirement: "ZAI Team API key + org/project",
            windowKinds: ["billing", "session", "weekly"]),
        .init(
            id: .kiro, label: "Kiro", settingsLabel: "Kiro", integration: .upstreamReuse, channel: "cli", configRequirement: "Kiro CLI installed and signed in",
            windowKinds: ["billing"]),
        .init(
            id: .workbuddy, label: "WorkBuddy", settingsLabel: "WorkBuddy", integration: .upstreamReuse, channel: "api", configRequirement: "WorkBuddy token or local app",
            windowKinds: ["billing"]),
        .init(
            id: .qoder, label: "Qoder", settingsLabel: "Qoder", integration: .upstreamReuse, channel: "web", configRequirement: "Qoder web session cookie", windowKinds: ["billing"]
        ),
        .init(
            id: .deepseek, label: "DeepSeek", settingsLabel: "DeepSeek", integration: .upstreamReuse, channel: "api", configRequirement: "DeepSeek API key",
            windowKinds: ["billing"]),
        .init(
            id: .openrouter, label: "OpenRouter", settingsLabel: "OpenRouter", integration: .upstreamReuse, channel: "api", configRequirement: "OpenRouter API key",
            windowKinds: ["billing"]),
        .init(
            id: .minimax, label: "Minimax", settingsLabel: "Minimax", integration: .upstreamReuse, channel: "api", configRequirement: "Minimax API key",
            windowKinds: ["billing", "session", "weekly"]),
        .init(
            id: .volcengine, label: "Volcengine", settingsLabel: "Volcengine", integration: .upstreamReuse, channel: "api", configRequirement: "Volcengine credentials",
            windowKinds: ["billing", "session", "weekly"]),
        .init(
            id: .ollama, label: "Ollama", settingsLabel: "Ollama", integration: .upstreamReuse, channel: "web", configRequirement: "Ollama web cookie header",
            windowKinds: ["session", "weekly"]),
        .init(id: .trae, label: "Trae CN", settingsLabel: "Trae CN", integration: .upstreamReuse, channel: "api", configRequirement: "Trae CN API token", windowKinds: ["billing"]),
        .init(
            id: .alibaba, label: "Alibaba Cloud", settingsLabel: "Alibaba Cloud", integration: .upstreamReuse, channel: "web", configRequirement: "Alibaba Cloud web cookie",
            windowKinds: ["billing", "session", "weekly"]),
        .init(
            id: .thirdparty, label: "Third-party APIs", settingsLabel: "Third-party APIs", integration: .upstreamReuse, channel: "api",
            configRequirement: "OpenAI-compatible API key + base URL", windowKinds: ["billing"]),
    ]

    static func descriptor(for id: QuotaProviderID) -> QuotaProviderDescriptor {
        all.first { $0.id == id }!
    }
}

struct QuotaProviderWindow: Identifiable, Equatable {
    let kind: String
    let remainingPercent: Double?

    var id: String { kind }
}

struct QuotaProviderRow: Identifiable, Equatable {
    let provider: QuotaProviderDescriptor
    let status: QuotaProviderStatus
    let source: String?
    let windows: [QuotaProviderWindow]
    let evidenceTier: String

    var id: String { provider.id.rawValue }

    func presentation(_ language: WidgetLanguage) -> String {
        status.presentation(language)
    }

    var paintsZeroTrack: Bool {
        windows.contains { $0.remainingPercent == 0 }
    }
}

struct QuotaProviderProbeStatus: Equatable {
    let status: QuotaProviderStatus
    let source: String?
}

struct QuotaProviderHostAccount: Equatable {
    let workspaceKindID: String
    let available: Bool
    let windows: [QuotaProviderWindow]
    var stale: Bool = false
}

struct QuotaProviderFeed: Equatable {
    var codexConnected: Bool = false
    var codexWindows: [QuotaProviderWindow] = []
    var hostAccounts: [QuotaProviderHostAccount] = []
    var probeByProvider: [String: QuotaProviderProbeStatus] = [:]
}

enum QuotaProviderProjector {
    /// Always emits 24 rows in catalog order. Local token totals are not accepted
    /// as official remaining percent. Unknown stays nil; real zero stays 0.
    static func project(_ feed: QuotaProviderFeed) -> [QuotaProviderRow] {
        QuotaProviderCatalog.all.map { descriptor in
            if descriptor.usesExistingProduction {
                return projectCodex(descriptor, feed: feed)
            }
            return projectUpstream(descriptor, feed: feed)
        }
    }

    private static func projectCodex(_ descriptor: QuotaProviderDescriptor, feed: QuotaProviderFeed) -> QuotaProviderRow {
        if feed.codexConnected {
            return QuotaProviderRow(
                provider: descriptor,
                status: .ok,
                source: "existing-production",
                windows: sanitized(feed.codexWindows),
                evidenceTier: "implemented"
            )
        }
        return notConfigured(descriptor, source: "existing-production", evidenceTier: "implemented")
    }

    private static func projectUpstream(_ descriptor: QuotaProviderDescriptor, feed: QuotaProviderFeed) -> QuotaProviderRow {
        if let host = hostMatch(descriptor, feed: feed), host.stale {
            return QuotaProviderRow(
                provider: descriptor, status: .unavailable, source: "host-official",
                windows: [], evidenceTier: "implemented")
        }
        if let host = hostMatch(descriptor, feed: feed), host.available {
            return QuotaProviderRow(
                provider: descriptor,
                status: .ok,
                source: "host-official",
                windows: sanitized(host.windows),
                evidenceTier: "implemented"
            )
        }
        if let probe = feed.probeByProvider[descriptor.id.rawValue] {
            if probe.status == .notConfigured {
                return notConfigured(descriptor, source: probe.source, evidenceTier: "fixture")
            }
            return QuotaProviderRow(
                provider: descriptor,
                status: probe.status,
                source: probe.source ?? "upstream-reuse",
                windows: [],
                evidenceTier: "fixture"
            )
        }
        return notConfigured(descriptor, source: "upstream-reuse", evidenceTier: "source")
    }

    private static func hostMatch(_ descriptor: QuotaProviderDescriptor, feed: QuotaProviderFeed) -> QuotaProviderHostAccount? {
        let matches = feed.hostAccounts.filter {
            WorkspaceProviderIDMapping.catalogProviderID(forWorkspaceKindID: $0.workspaceKindID) == descriptor.id.rawValue
        }
        return matches.first(where: { $0.available && !$0.stale }) ?? matches.first
    }

    private static func notConfigured(
        _ descriptor: QuotaProviderDescriptor,
        source: String?,
        evidenceTier: String
    ) -> QuotaProviderRow {
        QuotaProviderRow(
            provider: descriptor,
            status: .notConfigured,
            source: source,
            windows: descriptor.windowKinds.map { QuotaProviderWindow(kind: $0, remainingPercent: nil) },
            evidenceTier: evidenceTier
        )
    }

    private static func sanitized(_ windows: [QuotaProviderWindow]) -> [QuotaProviderWindow] {
        windows.map { window in
            let percent = window.remainingPercent.flatMap { value -> Double? in
                guard value.isFinite else { return nil }
                return max(0, min(100, value))
            }
            return QuotaProviderWindow(kind: window.kind, remainingPercent: percent)
        }
    }
}

enum QuotaProviderProbeDecoder {
    struct Envelope: Decodable {
        let providers: [Provider]
        struct Provider: Decodable {
            let provider: String
            let statuses: [Status]
            struct Status: Decodable {
                let status: String
                let source: String?
            }
        }
    }

    static func decode(_ data: Data) throws -> [String: QuotaProviderProbeStatus] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        var result: [String: QuotaProviderProbeStatus] = [:]
        for item in envelope.providers {
            let first = item.statuses.first
            result[item.provider] = QuotaProviderProbeStatus(
                status: QuotaProviderStatus.parse(first?.status),
                source: first?.source
            )
        }
        return result
    }
}

@MainActor
final class QuotaProviderStore: ObservableObject {
    @Published private(set) var rows: [QuotaProviderRow]
    @Published private(set) var lastFeed: QuotaProviderFeed

    init(feed: QuotaProviderFeed = QuotaProviderFeed()) {
        lastFeed = feed
        rows = QuotaProviderProjector.project(feed)
    }

    func update(_ feed: QuotaProviderFeed) {
        lastFeed = feed
        rows = QuotaProviderProjector.project(feed)
    }

    var connectedCount: Int { rows.filter { $0.status == .ok }.count }
    var pendingCount: Int { rows.filter { $0.status == .notConfigured }.count }
}
