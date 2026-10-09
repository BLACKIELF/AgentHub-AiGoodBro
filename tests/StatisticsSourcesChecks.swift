import Foundation

let catalog = try StatisticsClientCatalog.load(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let suite = "statistics-source-fixture-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let selected = catalog.enabledIDs(defaults: defaults)
precondition(catalog.clients.count == 35 && selected.count == 34)
precondition(selected.contains("mimo") && !selected.contains("qodercn"))
precondition(Set(["muse", "fx", "mcode"]).isSubset(of: selected))
let home = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
let profiles = [
    LocalCLIProfile(id: "default", kind: .claudeCode, displayName: "Default", configDirectory: home.appendingPathComponent(".claude").path, isDefault: true),
    LocalCLIProfile(id: "linked", kind: .claudeCode, displayName: "Linked", configDirectory: home.appendingPathComponent("linked").path, isDefault: false),
    LocalCLIProfile(id: "custom", kind: .mimo, displayName: "Custom", configDirectory: home.appendingPathComponent("custom").path, isDefault: false),
]
let sources = try StatisticsSources.make(catalog: catalog, enabledIDs: selected, userHome: home,
    systemCodexHome: home.appendingPathComponent(".codex"), localProfiles: profiles)
precondition(sources.count == 35)
precondition(sources.filter { $0.pathRole == .userHome }.count == 33)
precondition(sources.allSatisfy { $0.accountId == nil && $0.authority == .upstream })
precondition(sources.filter { $0.providerId == "codex" }.count == 1)
precondition(sources.contains { $0.id == "local-linked" && $0.pathRole == .logRoot })
precondition(!sources.contains { $0.id == "local-default" || $0.id == "local-custom" })
StatisticsSources.saveSelection(["claude", "not-in-catalog"], catalog: catalog, defaults: defaults)
precondition(catalog.enabledIDs(defaults: defaults) == ["claude"])
let filtered = try StatisticsSources.make(catalog: catalog, enabledIDs: catalog.enabledIDs(defaults: defaults),
    userHome: home, systemCodexHome: home.appendingPathComponent(".codex"), localProfiles: profiles)
precondition(filtered.count == 2 && filtered.allSatisfy { $0.providerId == "claude" })
StatisticsSources.saveSelection([], catalog: catalog, defaults: defaults)
precondition(catalog.enabledIDs(defaults: defaults).isEmpty)
print("PASS: pinned catalog, 34 defaults, explicit shared home, no assumed account ownership, linked roots, selection persistence")
