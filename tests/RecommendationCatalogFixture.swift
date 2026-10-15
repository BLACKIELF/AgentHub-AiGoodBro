import AppKit
import SwiftUI

// Narrow dependencies for compiling the production shelf without app/account services.
enum WidgetLanguage {
    case zh, en
    static func storedOrAutomatic() -> Self { .zh }
    func text(_ zh: String, _ en: String) -> String { self == .zh ? zh : en }
}
struct PaletteControlForeground: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { .primary }
}
enum HomeSection {
    case recommendations
    var storageKey: String { "RecommendationCatalogFixture.expanded" }
}
struct HomeSectionToggle: View {
    let title: String
    let systemImage: String
    let language: WidgetLanguage
    @Binding var isExpanded: Bool
    var body: some View { Text(title) }
}

@main
enum RecommendationCatalogFixture {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        let catalog = try RecommendationCatalog.load()
        expect(catalog.schemaVersion == 1 && catalog.revision == "1014v1", "versioned catalogue")
        expect(catalog.items.map(\.id) == ["oracle", "handoff", "jev-use", "quicktoggle", "rea", "aihot"], "shared order")
        expect(BundledSkill.selfTest(), "production shelf bundle and links")
        expect(BundledSkill.jev.title(.en) == "Jev · Computer use", "English title uses catalogue")
        expect(BundledSkill.jev.summary(.zh).contains("界面文字"), "Jev actual UI behavior")
        expect(BundledSkill.jev.directory()?.lastPathComponent == "jev-cu", "Jev ID differs from skill directory")
        expect(BundledSkill.rea.directory()?.lastPathComponent == "reverse-engineer-anything", "REA directory maps correctly")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-package-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let package = temporary.appendingPathComponent("PackageFixture.bundle", isDirectory: true)
        let files = package.appendingPathComponent("Contents/Resources/SkillLibrary/jev-cu", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": "invalid.catalog.fixture", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: package.appendingPathComponent("Contents/Info.plist"))
        let temporaryBundle = Bundle(url: package)!
        let skillFile = files.appendingPathComponent("SKILL.md")
        let instructions = files.appendingPathComponent("安装说明.md")
        try Data("name: jev-cu\n".utf8).write(to: skillFile)
        expect(BundledSkill.jev.directory(in: temporaryBundle) == nil, "missing instructions close install entry")
        try Data("Reuse runner.\n".utf8).write(to: instructions)
        expect(BundledSkill.jev.directory(in: temporaryBundle)?.lastPathComponent == "jev-cu", "two readable files allow install entry")
        for file in [skillFile, instructions] {
            let content = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            expect(BundledSkill.jev.directory(in: temporaryBundle) == nil, "directory cannot be a required file")
            try FileManager.default.removeItem(at: file)
            try Data().write(to: file)
            expect(BundledSkill.jev.directory(in: temporaryBundle) == nil, "empty required file closes install entry")
            try content.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            expect(BundledSkill.jev.directory(in: temporaryBundle) == nil, "unreadable required file closes install entry")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        expect(!catalog.items.contains { $0.id == "typesafe-ai" }, "TypeSafe recommendation removed")
        expect(BundledSkill.jev.prompt?.contains("runner") == true && BundledSkill.jev.prompt?.contains("{{REPO_DIR}}") == true, "Jev install retains runner requirement")
        expect(BundledSkill.rea.prompt?.contains("不写 MCP") == true, "REA instruction does not install engine or registration")
        expect(BundledSkill.aihot.title(.zh) == "AIHOT · 热点日报", "AIHOT Chinese title")
        expect(BundledSkill.aihot.title(.en) == "AIHOT · News digests", "AIHOT English title")
        expect(BundledSkill.aihot.prompt == nil && BundledSkill.aihot.directory() == nil, "AIHOT cannot offer a bundled Skill or install prompt")
        expect(BundledSkill.aihot.projectURL?.absoluteString == "https://github.com/KKKKhazix/AIHOT", "AIHOT routes to its own official project")
        expect(BundledRecommendationFilter.apps.items == [.quickToggle, .aihot], "apps include AIHOT and preserve QuickToggle")
        expect(BundledRecommendationFilter.skills.items.count == 4 && !BundledRecommendationFilter.skills.items.contains(.aihot), "AIHOT is not a Skill")
        let probes = BundledSkill.installationProbes
        expect(probes.map(\.id) == catalog.items.map(\.id), "installation probes share stable IDs")
        expect(probes[1].skillNames == ["handoffskill", "handoff"], "handoff aliases")
        expect(probes[2].skillNames == ["jev-use", "jev-cu"], "Jev legacy alias")
        expect(probes[3].appBundleIDs == ["com.quicktoggle.app"], "QuickToggle exact app identity")
        expect(probes[4].skillNames == ["reverse-engineer-anything"], "REA alias")
        expect(probes[5].id == "aihot" && probes[5].skillNames.isEmpty && probes[5].appBundleIDs.isEmpty, "AIHOT has no invented installation identity")

        let suite = "CodexManagerNext.aihot-recommendation-fixture." + UUID().uuidString
        let isolatedDefaults = UserDefaults(suiteName: suite)!
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        let aihotState = RecommendationVisibilityStore(
            defaults: isolatedDefaults, skillRoots: [], detector: { _, _ in .notInstalled },
            appFinder: { _ in preconditionFailure("A web project must not query app bundle IDs") })
        await aihotState.recheck(probes: [probes[5]])
        expect(aihotState.visible("aihot") && aihotState.states["aihot"] == .unknown, "no installation identity never claims installed or absent")
        aihotState.hide("aihot")
        expect(!aihotState.visible("aihot"), "AIHOT hide applies immediately")
        let hiddenReload = RecommendationVisibilityStore(defaults: isolatedDefaults, skillRoots: [], allowsInspection: false)
        expect(!hiddenReload.visible("aihot"), "AIHOT hide persists across reload")
        hiddenReload.restoreHidden()
        let restoredReload = RecommendationVisibilityStore(defaults: isolatedDefaults, skillRoots: [], allowsInspection: false)
        expect(restoredReload.visible("aihot"), "AIHOT restore persists across reload")

        let state = RecommendationVisibilityStore.preview(states: ["oracle": .installed], hiddenIDs: ["rea"])
        expect(!state.visible("oracle") && !state.visible("rea") && state.visible("jev-use"), "installed and hidden excluded")
        state.hide("quicktoggle")
        expect(!state.visible("quicktoggle"), "stable app ID hides")
        state.restoreHidden()
        expect(state.visible("rea") && state.visible("quicktoggle") && !state.visible("oracle"), "restore never revives installed")
        await state.recheck(probes: probes)
        expect(state.states == ["oracle": .installed], "preview recheck never probes machine")
        _ = HomeSkillShelf(language: .zh, visibility: state)
        _ = HomeSkillShelf(language: .en, visibility: .preview())

        let root = Bundle.main.resourceURL!
        let bytes = try Data(contentsOf: root.appendingPathComponent("SkillLibrary/catalog.json"))
        let original = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        func rejected(_ mutate: (inout [String: Any]) -> Void) throws -> Bool {
            var changed = original
            mutate(&changed)
            let data = try JSONSerialization.data(withJSONObject: changed)
            do {
                _ = try RecommendationCatalog.decode(data)
                return false
            } catch { return true }
        }
        expect(try rejected { $0["schemaVersion"] = 2 }, "reject unsupported schema")
        expect(
            try rejected {
                var items = $0["items"] as! [[String: Any]]
                items.swapAt(0, 1)
                $0["items"] = items
            }, "reject drifting order")
        expect(
            try rejected {
                var items = $0["items"] as! [[String: Any]]
                items[2]["skillDirectory"] = "../typesafe-ai"
                $0["items"] = items
            }, "reject path traversal and wrong directory")
        expect(
            try rejected {
                var items = $0["items"] as! [[String: Any]]
                items[3]["appBundleIDs"] = ["com.other.app"]
                $0["items"] = items
            }, "reject different app identity")
        expect(
            try rejected {
                var items = $0["items"] as! [[String: Any]]
                items[5]["kind"] = "skill"
                $0["items"] = items
            }, "reject AIHOT disguised as a Skill")
        expect(
            try rejected {
                var items = $0["items"] as! [[String: Any]]
                items[5]["appBundleIDs"] = ["com.quicktoggle.app"]
                $0["items"] = items
            }, "reject an invented AIHOT app identity")
        expect(
            try rejected {
                var items = $0["items"] as! [[String: Any]]
                items[0]["title"] = ["zh": "Oracle", "en": ""]
                $0["items"] = items
            }, "reject missing translation")
        expect(
            try rejected {
                var items = $0["items"] as! [[String: Any]]
                items[0]["sourceURL"] = "https://user:password@example.invalid/"
                $0["items"] = items
            }, "reject credential-bearing URL")
        expect(try rejected { $0["updatedAt"] = "2026-02-31" }, "reject invalid editorial date")
        print("PASS recommendation catalogue and shelf: \(checks) assertions; temporary bundle and preview state only")
    }
}
