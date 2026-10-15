import Foundation

private final class ControlledDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let releaseFirst = DispatchSemaphore(value: 0)
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    func detect(_ probe: RecommendationVisibilityStore.Probe, _ roots: [URL]) -> RecommendationVisibilityStore.DetectionState {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        if call == 1 {
            _ = releaseFirst.wait(timeout: .now() + 5)
            return .installed
        }
        return .notInstalled
    }
}

@main enum RecommendationVisibilityFixture {
    typealias Store = RecommendationVisibilityStore
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: Bool, _ name: String) {
        checks += 1
        precondition(value, name)
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("recommendation-fixture-" + UUID().uuidString)
        let roots = [root.appendingPathComponent("codex-skills"), root.appendingPathComponent("agents-skills")]
        for value in roots { try fm.createDirectory(at: value, withIntermediateDirectories: true) }
        let suite = "CodexManagerNext.recommendation-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        func write(_ name: String, _ text: String, at index: Int = 0) throws -> URL {
            let directory = roots[index].appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("SKILL.md")
            try Data(text.utf8).write(to: url)
            return url
        }
        let oracle = Store.Probe(id: "oracle", skillNames: ["oracle"])
        let handoff = Store.Probe(id: "handoff", skillNames: ["handoff", "handoffskill"])
        let jev = Store.Probe(id: "jev", skillNames: ["jev-cu", "jev-use"])
        let rea = Store.Probe(id: "rea", skillNames: ["reverse-engineer-anything"])
        let quick = Store.Probe(id: "quickToggle", appBundleIDs: ["com.quicktoggle.app"])
        expect(Store.detectSkill(oracle, roots) == .notInstalled, "absent is not installed")
        let oracleFile = try write("oracle", "---\nname: oracle\n---\nSkill content")
        expect(Store.detectSkill(oracle, roots) == .installed, "readable exact frontmatter")
        _ = try write("handoffskill", "---\nname: 'handoffskill'\n---\n", at: 1)
        expect(Store.detectSkill(handoff, roots) == .installed, "alias in agents root")
        _ = try write("jev-use", "---\r\nname: \"jev-use\"\r\n---\r\n")
        expect(Store.detectSkill(jev, roots) == .installed, "quoted alias and CRLF")
        _ = try write("reverse-engineer-anything", "name: reverse-engineer-anything\n")
        expect(Store.detectSkill(rea, roots) == .unknown, "no frontmatter is unknown")
        _ = try write("reverse-engineer-anything", "---\nname: wrong-name\n---\n")
        expect(Store.detectSkill(rea, roots) == .unknown, "wrong declared name")
        _ = try write("reverse-engineer-anything", "---\nname: reverse-engineer-anything\nname: reverse-engineer-anything\n---\n")
        expect(Store.detectSkill(rea, roots) == .unknown, "duplicate name rejected")
        let reaFile = try write("reverse-engineer-anything", "---\nname: reverse-engineer-anything\n---\n")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: reaFile.path)
        expect(Store.detectSkill(rea, roots) == .unknown, "unreadable is unknown")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reaFile.path)
        try fm.removeItem(at: reaFile)
        expect(Store.detectSkill(rea, roots) == .unknown, "directory alone not installed")
        expect(Store.detectSkill(.init(id: "bad", skillNames: ["../oracle"]), roots) == .unknown, "path traversal blocked")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("---\nname: external\n---\n".utf8).write(to: outside.appendingPathComponent("SKILL.md"))
        try fm.createSymbolicLink(at: roots[0].appendingPathComponent("external"), withDestinationURL: outside)
        expect(Store.detectSkill(.init(id: "external", skillNames: ["external"]), roots) == .unknown, "external alias not read")
        try fm.createSymbolicLink(at: roots[0].appendingPathComponent("handoff"), withDestinationURL: roots[1].appendingPathComponent("handoffskill"))
        expect(Store.detectSkill(handoff, roots) == .installed, "symlink within allowed skill roots")

        var appQueries = 0
        var appInstalled = false
        let finder: Store.AppFinder = { id in
            appQueries += 1
            return appInstalled && id == "com.quicktoggle.app"
        }
        let store = Store(defaults: defaults, skillRoots: roots, appFinder: finder)
        let probes = [oracle, handoff, rea, quick]
        await store.inspectIfNeeded(eventID: "install-a", probes: probes)
        expect(appQueries == 1, "first installation queried once")
        expect(!store.visible("oracle") && !store.visible("handoff"), "installed skills hidden")
        expect(store.visible("rea") && store.states["rea"] == .unknown, "unknown remains visible")
        expect(store.visible("quickToggle"), "missing app visible")
        await store.inspectIfNeeded(eventID: "install-a", probes: probes)
        expect(appQueries == 1, "same event not rescanned")
        store.hide("quickToggle")
        expect(!store.visible("quickToggle"), "camelcase recommendation hide")
        let reload = Store(defaults: defaults, skillRoots: roots, appFinder: finder)
        expect(!reload.visible("quickToggle") && !reload.visible("oracle"), "hidden and installation cache persisted")
        await reload.inspectIfNeeded(eventID: "install-a", probes: probes)
        expect(appQueries == 1, "restart same event not rescanned")
        await reload.inspectIfNeeded(eventID: "install-b", probes: probes)
        expect(appQueries == 2 && !reload.visible("quickToggle"), "reinstall once and hidden retained")
        reload.restoreHidden()
        expect(reload.visible("quickToggle") && !reload.visible("oracle"), "restore affects user hides only")
        appInstalled = true
        try fm.removeItem(at: oracleFile.deletingLastPathComponent())
        await reload.recheck(probes: probes)
        expect(reload.visible("oracle") && reload.states["oracle"] == .notInstalled, "manual uninstall update")
        expect(!reload.visible("quickToggle") && reload.states["quickToggle"] == .installed, "manual app install update")
        appInstalled = false
        await reload.recheck(probes: probes)
        expect(reload.visible("quickToggle"), "manual app uninstall update")
        let preview = Store.preview(states: ["oracle": .installed])
        await preview.inspectIfNeeded(eventID: "preview", probes: probes)
        await preview.recheck(probes: probes)
        expect(!preview.visible("oracle") && preview.states.count == 1, "preview never detects")

        var firstQueries = 0
        let introduction = Store(
            defaults: nil, skillRoots: [],
            appFinder: { _ in
                firstQueries += 1
                return false
            })
        await introduction.inspectIfNeeded(eventID: nil, probes: [quick])
        await introduction.inspectIfNeeded(eventID: nil, probes: [quick])
        expect(firstQueries == 1, "first feature introduction once without identity")
        await introduction.inspectIfNeeded(eventID: "late-identity", probes: [quick])
        await introduction.inspectIfNeeded(eventID: "late-identity", probes: [quick])
        expect(firstQueries == 2, "stable event survives receipt enrichment without another check")
        await introduction.inspectIfNeeded(eventID: "next-install", probes: [quick])
        expect(firstQueries == 3, "later installation inspected")

        let controlled = ControlledDetector()
        let racing = Store(defaults: nil, skillRoots: [], detector: { controlled.detect($0, $1) }, appFinder: { _ in false })
        let old = Task { await racing.inspectIfNeeded(eventID: "old", probes: [oracle]) }
        while controlled.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        await racing.inspectIfNeeded(eventID: "old", probes: [oracle])
        expect(controlled.count == 1, "concurrent same event coalesced")
        racing.hide("oracle")
        await racing.inspectIfNeeded(eventID: "new", probes: [oracle])
        controlled.releaseFirst.signal()
        await old.value
        expect(racing.states["oracle"] == .notInstalled, "old generation cannot overwrite new result")
        expect(!racing.visible("oracle") && !racing.isInspecting, "concurrent user hide retained")
        racing.restoreHidden()
        expect(racing.visible("oracle"), "restore after pending detection")

        let cancelledDetector = ControlledDetector()
        let cancelled = Store(defaults: nil, skillRoots: [], detector: { cancelledDetector.detect($0, $1) }, appFinder: { _ in false })
        let pending = Task { await cancelled.inspectIfNeeded(eventID: "cancelled", probes: [oracle]) }
        while cancelledDetector.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        pending.cancel()
        cancelledDetector.releaseFirst.signal()
        await pending.value
        expect(cancelled.states.isEmpty && !cancelled.isInspecting, "cancelled detection cannot publish or mark completed")
        await cancelled.inspectIfNeeded(eventID: "cancelled", probes: [oracle])
        expect(cancelledDetector.count == 2 && cancelled.states["oracle"] == .notInstalled, "cancelled event can retry")
        print("PASS recommendation visibility: \(checks) assertions; isolated files, defaults and app lookup")
    }
}
