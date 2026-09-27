import Foundation

enum QuotaProviderWiringSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        expect(QuotaProviderID.allCases.count == 24, "catalog has 24 providers")
        expect(QuotaProviderCatalog.all.count == 24, "descriptor list has 24 rows")
        expect(Set(QuotaProviderCatalog.all.map(\.id)).count == 24, "provider IDs are unique")
        expect(QuotaProviderCatalog.all.filter(\.usesExistingProduction).map(\.id) == [.codex], "only Codex is existing-production")
        expect(QuotaProviderCatalog.all.filter { $0.integration == .upstreamReuse }.count == 23, "23 providers reuse upstream")

        let empty = QuotaProviderProjector.project(QuotaProviderFeed())
        expect(empty.count == 24, "empty feed still emits 24 rows")
        expect(empty.allSatisfy { $0.status == .notConfigured }, "missing config is notConfigured")
        expect(empty.allSatisfy { $0.windows.allSatisfy { $0.remainingPercent == nil } }, "missing config does not paint 0%")
        expect(empty.contains { $0.provider.id == .codex && $0.provider.usesExistingProduction }, "Codex row stays on the original reader")

        var connected = QuotaProviderFeed()
        connected.codexConnected = true
        connected.codexWindows = [
            QuotaProviderWindow(kind: "session", remainingPercent: 42),
            QuotaProviderWindow(kind: "weekly", remainingPercent: 0),
        ]
        let codexRows = QuotaProviderProjector.project(connected)
        let codex = codexRows.first { $0.provider.id == .codex }
        expect(codex?.status == .ok, "connected Codex uses existing production")
        expect(codex?.windows.contains { $0.kind == "weekly" && $0.remainingPercent == 0 } == true, "real zero stays 0")
        expect(codex?.windows.contains { $0.kind == "session" && $0.remainingPercent == 42 } == true, "Codex remaining percent is official")
        expect(codexRows.filter { $0.provider.id != .codex }.allSatisfy { $0.status == .notConfigured }, "non-Codex stay pending without config")

        var local = QuotaProviderFeed()
        local.hostAccounts = [
            QuotaProviderHostAccount(
                workspaceKindID: "claudeCode",
                available: true,
                windows: [QuotaProviderWindow(kind: "session", remainingPercent: 17)]
            ),
            QuotaProviderHostAccount(
                workspaceKindID: "zcode",
                available: false,
                windows: [QuotaProviderWindow(kind: "billing", remainingPercent: 99)]
            ),
        ]
        let mapped = QuotaProviderProjector.project(local)
        expect(mapped.first { $0.provider.id == .claude }?.status == .ok, "claudeCode maps to claude")
        expect(mapped.first { $0.provider.id == .claude }?.windows.first?.remainingPercent == 17, "official local quota is used")
        expect(mapped.first { $0.provider.id == .zai }?.status == .notConfigured, "unavailable host quota does not fake a balance")
        expect(!mapped.contains { $0.provider.id.rawValue == "gemini" }, "gemini is not a catalog provider")

        var stale = local
        stale.hostAccounts[0].stale = true
        let staleRow = QuotaProviderProjector.project(stale).first { $0.provider.id == .claude }
        expect(staleRow?.status == .unavailable, "failed refresh does not present old local quota as connected")
        expect(staleRow?.windows.isEmpty == true, "old local quota is not presented as current percentage")
        stale.hostAccounts.append(
            QuotaProviderHostAccount(workspaceKindID: "claudeCode", available: true, windows: [QuotaProviderWindow(kind: "session", remainingPercent: 53)]))
        let freshRow = QuotaProviderProjector.project(stale).first { $0.provider.id == .claude }
        expect(freshRow?.status == .ok && freshRow?.windows.first?.remainingPercent == 53, "fresh account precedes a stale account for the same provider")

        var probe = QuotaProviderFeed()
        probe.probeByProvider = [
            "cursor": QuotaProviderProbeStatus(status: .notConfigured, source: "web"),
            "codex": QuotaProviderProbeStatus(status: .ok, source: "oauth"),
        ]
        probe.codexConnected = false
        let probed = QuotaProviderProjector.project(probe)
        expect(probed.first { $0.provider.id == .cursor }?.status == .notConfigured, "empty-config probe is 待配置")
        expect(probed.first { $0.provider.id == .codex }?.status == .notConfigured, "Codex ignores upstream probe when production is disconnected")
        expect(probed.first { $0.provider.id == .codex }?.source == "existing-production", "Codex source stays existing-production")

        let summed = probed.compactMap { $0.windows.compactMap(\.remainingPercent).reduce(0, +) }.reduce(0, +)
        expect(summed == 0, "pending rows never contribute a summed remaining percent")

        let fixture = Data(
            """
            {"providers":[{"provider":"deepseek","statuses":[{"status":"notConfigured","source":"api"}]}]}
            """.utf8)
        let decoded = try? QuotaProviderProbeDecoder.decode(fixture)
        expect(decoded?["deepseek"]?.status == .notConfigured, "probe JSON decoder maps notConfigured")

        expect(WorkspaceProviderIDMapping.catalogProviderID(forWorkspaceKindID: "claudeCode") == "claude", "claudeCode → claude")
        expect(WorkspaceProviderIDMapping.catalogProviderID(forWorkspaceKindID: "openCode") == "opencode", "openCode → opencode")
        expect(WorkspaceProviderIDMapping.catalogProviderID(forWorkspaceKindID: "workBuddy") == "workbuddy", "workBuddy → workbuddy")
        expect(WorkspaceProviderIDMapping.catalogProviderID(forWorkspaceKindID: "zcode") == "zai", "zcode → zai")
        expect(WorkspaceProviderIDMapping.catalogProviderID(forWorkspaceKindID: "gemini") == nil, "gemini has no catalog quota")
        expect(WorkspaceProviderIDMapping.workspaceKindID(forCatalogProviderID: "  ZAI ") == "zcode", "reverse mapping trims")
        expect(WorkspaceProviderIDMapping.workspaceKindID(forCatalogProviderID: "cursor") == nil, "cursor has no workspace dispatch")
        expect(WorkspaceProviderIDMapping.catalogProviderID(forWorkspaceKindID: "ClaudeCode") == nil, "workspace IDs are exact camelCase")

        if failures.isEmpty {
            print("quota provider wiring self-test passed")
            return true
        }
        failures.forEach { print("quota provider wiring self-test failed: \($0)") }
        return false
    }
}
