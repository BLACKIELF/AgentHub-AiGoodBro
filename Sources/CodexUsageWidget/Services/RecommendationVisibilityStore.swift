import AppKit
import Combine
import Darwin
import Foundation

/// Local installation presence only. This does not establish MCP, model or API readiness.
@MainActor final class RecommendationVisibilityStore: ObservableObject {
    enum DetectionState: String, Codable, Sendable { case installed, notInstalled, unknown }

    struct Probe: Equatable, Sendable {
        let id: String
        var skillNames: [String] = []
        var appBundleIDs: [String] = []
    }

    typealias SkillDetector = @Sendable (Probe, [URL]) -> DetectionState
    typealias AppFinder = @MainActor (String) -> Bool
    static let shared = RecommendationVisibilityStore()
    static let storageKey = "CodexManagerNext.recommendations.visibility.v1"

    @Published private(set) var states: [String: DetectionState] = [:]
    @Published private(set) var hiddenIDs: Set<String> = []
    @Published private(set) var isInspecting = false
    var detectedInstalledIDs: Set<String> { Set(states.filter { $0.value == .installed }.map(\.key)) }

    private struct Receipt: Codable {
        var schemaVersion = 1
        var hiddenIDs: Set<String>
        var states: [String: DetectionState]
        var eventID: String?
    }

    private static let initialEvent = "initial-feature-check"
    private let defaults: UserDefaults?
    private let roots: [URL]
    private let detector: SkillDetector
    private let appFinder: AppFinder
    private let allowsInspection: Bool
    private var lastEventID: String?
    private var activeEventID: String?
    private var generation: UInt64 = 0

    init(
        defaults: UserDefaults? = .standard,
        skillRoots: [URL]? = nil,
        detector: @escaping SkillDetector = { probe, roots in RecommendationVisibilityStore.detectSkill(probe, roots) },
        appFinder: @escaping AppFinder = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        allowsInspection: Bool = true
    ) {
        self.defaults = defaults
        self.allowsInspection = allowsInspection
        self.detector = detector
        self.appFinder = appFinder
        if let skillRoots {
            roots = skillRoots
        } else if allowsInspection {
            let home = FileManager.default.homeDirectoryForCurrentUser
            roots = [home.appendingPathComponent(".codex/skills"), home.appendingPathComponent(".agents/skills")]
        } else {
            roots = []
        }
        if let data = defaults?.data(forKey: Self.storageKey), data.count <= 65_536,
            let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.schemaVersion == 1
        {
            hiddenIDs = Set(receipt.hiddenIDs.filter(Self.validID))
            states = receipt.states.filter { Self.validID($0.key) }
            lastEventID = receipt.eventID
        }
    }

    /// A preview neither touches standard defaults nor probes the user's machine.
    static func preview(states: [String: DetectionState] = [:], hiddenIDs: Set<String> = []) -> RecommendationVisibilityStore {
        let store = RecommendationVisibilityStore(defaults: nil, skillRoots: [], allowsInspection: false)
        store.states = states
        store.hiddenIDs = hiddenIDs
        return store
    }

    func visible(_ id: String) -> Bool { !hiddenIDs.contains(id) && states[id] != .installed }

    func hide(_ id: String) {
        guard Self.validID(id) else { return }
        hiddenIDs.insert(id)
        save()
    }

    func restoreHidden() {
        hiddenIDs.removeAll()
        save()
    }

    /// Call with InstallationOnboardingState.presentationEventID, not a late receipt's ID.
    func inspectIfNeeded(eventID: String?, probes: [Probe]) async {
        guard allowsInspection else { return }
        let event = eventID ?? Self.initialEvent
        guard event != lastEventID, event != activeEventID else { return }
        await inspect(eventID: event, probes: probes)
    }

    func recheck(probes: [Probe]) async {
        guard allowsInspection else { return }
        await inspect(eventID: activeEventID ?? lastEventID ?? Self.initialEvent, probes: probes)
    }

    private func inspect(eventID: String, probes: [Probe]) async {
        generation &+= 1
        let ticket = generation
        activeEventID = eventID
        isInspecting = true
        var unique: [String: Probe] = [:]
        for probe in probes where Self.validID(probe.id) { unique[probe.id] = probe }
        let inputs = unique.values.sorted { $0.id < $1.id }
        let detector = self.detector
        let roots = self.roots
        let results = await Task.detached(priority: .utility) {
            inputs.map { ($0.id, detector($0, roots)) }
        }.value
        guard ticket == generation else { return }
        guard !Task.isCancelled else {
            activeEventID = nil
            isInspecting = false
            return
        }
        var next = states
        for (id, skillState) in results {
            guard let probe = unique[id] else { continue }
            let foundApp = probe.appBundleIDs.contains { appFinder($0) }
            let result: DetectionState
            if foundApp || skillState == .installed {
                result = .installed
            } else if skillState == .unknown {
                result = .unknown
            } else {
                result = probe.skillNames.isEmpty && probe.appBundleIDs.isEmpty ? .unknown : .notInstalled
            }
            next[id] = result
        }
        states = next
        lastEventID = eventID
        activeEventID = nil
        isInspecting = false
        // A hide/restore operation during the background read remains authoritative.
        save()
    }

    private func save() {
        guard let defaults,
            let data = try? JSONEncoder().encode(Receipt(hiddenIDs: hiddenIDs, states: states, eventID: lastEventID))
        else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    nonisolated private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
    }

    nonisolated private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }

    nonisolated static func detectSkill(_ probe: Probe, _ roots: [URL]) -> DetectionState {
        guard !probe.skillNames.isEmpty else { return .notInstalled }
        guard probe.skillNames.allSatisfy(validName), !roots.isEmpty else { return .unknown }
        var uncertain = false
        let allowedRoots = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        for root in roots {
            for name in probe.skillNames {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                let resolved = directory.resolvingSymlinksInPath().standardizedFileURL.path
                guard allowedRoots.contains(where: { resolved.hasPrefix($0 + "/") }) else {
                    uncertain = true
                    continue
                }
                let path = directory.appendingPathComponent("SKILL.md").path
                let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else {
                    if errno != ENOENT || FileManager.default.fileExists(atPath: directory.path) { uncertain = true }
                    continue
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                    info.st_mode & 0o444 != 0, info.st_size > 0, info.st_size <= 262_144,
                    let data = try? handle.read(upToCount: 262_145), data.count <= 262_144,
                    let text = String(data: data, encoding: .utf8), let declared = frontmatterName(text)
                else {
                    uncertain = true
                    continue
                }
                if probe.skillNames.contains(declared) { return .installed }
                uncertain = true
            }
        }
        return uncertain ? .unknown : .notInstalled
    }

    nonisolated private static func frontmatterName(_ text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"), end <= 200 else { return nil }
        let names = lines[1..<end].filter { $0.hasPrefix("name:") }
        guard names.count == 1 else { return nil }
        var name = names[0].dropFirst(5).trimmingCharacters(in: .whitespaces)
        if (name.hasPrefix("\"") && name.hasSuffix("\"")) || (name.hasPrefix("'") && name.hasSuffix("'")) {
            name = String(name.dropFirst().dropLast())
        }
        return validName(name) ? name : nil
    }
}
