import Darwin
import Foundation

// Executed only by scripts/test-dispatch-participation.py, with generated
// identities and homes beneath its temporary directory. Never reads live state.
private enum DispatchTestFailure: Error { case assertion, injected }

private func require(_ condition: @autoclosure () throws -> Bool) throws {
    guard try condition() else { throw DispatchTestFailure.assertion }
}

private func expectError(_ expected: DispatchParticipationError, _ action: () throws -> Void) throws {
    do {
        try action()
        throw DispatchTestFailure.assertion
    } catch let error as DispatchParticipationError {
        try require(error.errorDescription == expected.errorDescription)
    }
}

private func json(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func object(_ url: URL) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw DispatchTestFailure.assertion
    }
    return value
}

private func mutate(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
    var value = try object(url)
    change(&value)
    try json(value).write(to: url)
}

private final class DispatchFixture {
    let root: URL
    let paths: DispatchParticipationPaths
    let identity: DispatchParticipationSync.Identity
    var sync: DispatchParticipationSync { DispatchParticipationSync(paths: paths) }
    var urls: [URL] { [paths.snapshot, paths.hubConfig, paths.codes] }

    init(catalogExists: Bool = true) throws {
        guard let testRoot = ProcessInfo.processInfo.environment["CAMNEXT_DISPATCH_TEST_ROOT"] else {
            throw DispatchTestFailure.assertion
        }
        root = URL(fileURLWithPath: testRoot).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent(DispatchParticipationPaths.supportDirectoryName, isDirectory: true)
        let hub = root.appendingPathComponent("hub", isDirectory: true)
        paths = DispatchParticipationPaths(
            snapshot: support.appendingPathComponent(DispatchParticipationPaths.snapshotFileName),
            hubConfig: hub.appendingPathComponent(DispatchParticipationPaths.hubConfigFileName),
            codes: support.appendingPathComponent(DispatchParticipationPaths.codesFileName)
        )
        identity = .init(
            profileID: "profile-primary", homePath: root.appendingPathComponent("primary-home").path,
            email: "fixture-primary", accountID: "account-primary")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        let profiles: [[String: Any]] = [
            [
                "id": identity.profileID, "codexHomePath": identity.homePath,
                "lastSnapshot": ["email": " Fixture-Primary ", "accountID": identity.accountID],
                "automaticSwitchParticipation": false,
                "futureProfileField": ["retained": true],
            ],
            [
                "id": "system", "codexHomePath": root.appendingPathComponent("system-home").path,
                "isSystemProfile": true,
                "lastSnapshot": ["email": "fixture-primary", "accountID": identity.accountID],
                "automaticSwitchParticipation": false,
            ],
            [
                "id": "profile-other", "codexHomePath": root.appendingPathComponent("other-home").path,
                "lastSnapshot": ["email": "fixture-other", "accountID": "account-other"],
                "automaticSwitchParticipation": true,
            ],
        ]
        try json(["schemaVersion": 1, "profiles": profiles, "futureSnapshotField": ["retained": [1, 2, 3]]])
            .write(to: paths.snapshot)
        try json([
            "accounts": [
                ["alias": "fixture-primary", "home": identity.homePath, "futureHubField": ["retained": true]],
                ["alias": "fixture-other", "home": profiles[2]["codexHomePath"]!, "dispatchDisabled": false],
            ],
            "projects": [
                "demo": root.appendingPathComponent("project").path,
                "demo-alias": root.appendingPathComponent("project").path,
                "other": root.appendingPathComponent("other-project").path,
            ],
            "futureRootField": "retained",
        ]).write(to: paths.hubConfig)
        if catalogExists {
            try json([
                "schemaVersion": 1,
                "accounts": [
                    ["code": "C", "alias": "fixture-other", "profileId": "profile-other", "futureEntryField": true]
                ], "futureCatalogField": ["retained": true],
            ]).write(to: paths.codes)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func contents() throws -> [Data?] {
        try urls.map { FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil }
    }

    func checkState(enabled: Bool, code: String?) throws {
        let profiles = try object(paths.snapshot)["profiles"] as! [[String: Any]]
        try require(profiles[0]["automaticSwitchParticipation"] as? Bool == enabled)
        try require(profiles[1]["automaticSwitchParticipation"] as? Bool == enabled)
        try require(profiles[2]["automaticSwitchParticipation"] as? Bool == true)
        let accounts = try object(paths.hubConfig)["accounts"] as! [[String: Any]]
        try require(accounts[0]["dispatchDisabled"] as? Bool == !enabled)
        try require(accounts[1]["dispatchDisabled"] as? Bool == false)
        let entries = try DispatchParticipationSync.validatedEntries(object(paths.codes))
        let matched = entries.filter { $0["alias"] as? String == "fixture-primary" }
        try require(matched.count == (code == nil ? 0 : 1))
        if let code {
            try require(matched[0]["code"] as? String == code)
            try require(matched[0]["profileId"] as? String == identity.profileID)
            try require(matched[0]["email"] == nil)
            try require(matched[0]["priority"] as? Int != nil)
            try require(matched[0]["active"] as? Bool == enabled)
        }
    }

    func checkBackups(_ originals: [Data?]) throws {
        let directory = paths.snapshot.deletingLastPathComponent()
            .appendingPathComponent(DispatchParticipationPaths.backupDirectoryName)
        let runs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try require(runs.count == 1)
        let names = ["snapshot.json", "hub-config.json", "dispatch-codes.json"]
        for index in names.indices {
            let backup = runs[0].appendingPathComponent(names[index])
            if let original = originals[index] {
                try require(Data(contentsOf: backup) == original)
                let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
                try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            } else {
                try require(!FileManager.default.fileExists(atPath: backup.path))
            }
        }
        let manifest = try object(runs[0].appendingPathComponent("manifest.json"))
        try require(manifest["codesOriginallyMissing"] as? Bool == (originals[2] == nil))
        let attributes = try FileManager.default.attributesOfItem(atPath: runs[0].path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    func checkNoTemporaryFiles() throws {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw DispatchTestFailure.assertion
        }
        for case let url as URL in files {
            try require(!url.lastPathComponent.hasPrefix(".camnext-dispatch-"))
        }
    }

    func temporaryFiles(suffix: String) throws -> [URL] {
        let directory = paths.snapshot.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".camnext-dispatch-") && $0.lastPathComponent.hasSuffix(suffix) }
    }
}

private var passed = 0
private func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passed += 1
        print("PASS: \(name)")
    } catch {
        // Error descriptions and fixture data may contain paths; emit the fixed test label only.
        print("FAIL: \(name)")
        exit(1)
    }
}

test("enable, preserve unknown fields, then disable and re-enable") {
    let f = try DispatchFixture()
    let originals = try f.contents()
    let result = try f.sync.setParticipation(true, identity: f.identity)
    try require(result == Data(contentsOf: f.paths.snapshot))
    try f.checkState(enabled: true, code: "D")
    try f.checkBackups(originals)
    let next = try object(f.paths.snapshot)
    let profiles = next["profiles"] as! [[String: Any]]
    try require(next["schemaVersion"] as? Int == 1)
    try require((next["futureSnapshotField"] as? NSDictionary) == ["retained": [1, 2, 3]] as NSDictionary)
    try require((profiles[0]["futureProfileField"] as? NSDictionary) == ["retained": true] as NSDictionary)
    let hub = try object(f.paths.hubConfig)
    try require(hub["futureRootField"] as? String == "retained")
    try require(((hub["accounts"] as! [[String: Any]])[0]["futureHubField"] as? NSDictionary) == ["retained": true] as NSDictionary)
    let catalog = try object(f.paths.codes)
    try require((catalog["futureCatalogField"] as? NSDictionary) == ["retained": true] as NSDictionary)
    try require((catalog["accounts"] as! [[String: Any]])[0]["futureEntryField"] as? Bool == true)
    _ = try f.sync.setParticipation(true, identity: f.identity)
    try f.checkState(enabled: true, code: "D")
    _ = try f.sync.setParticipation(false, identity: f.identity)
    try f.checkState(enabled: false, code: "D")
    _ = try f.sync.setParticipation(true, identity: f.identity)
    try f.checkState(enabled: true, code: "D")
    try f.checkNoTemporaryFiles()
}

test("missing catalog creates a preflight-compatible root and starts at A") {
    let f = try DispatchFixture(catalogExists: false)
    let originals = try f.contents()
    _ = try f.sync.setParticipation(false, identity: f.identity)
    try f.checkState(enabled: false, code: nil)
    try f.checkBackups(originals)
    let catalog = try object(f.paths.codes)
    try require(catalog["snapshotMaxAgeSeconds"] as? Int == 45)
    let minimums = catalog["minimumRemainingPercent"] as? [String: Any]
    try require(minimums?["fiveHour"] as? Int == 0)
    try require(minimums?["sevenDay"] as? Int == 0)
    let projects = catalog["hubProjects"] as? [String: String]
    try require(projects?["demo"] != nil && projects?["demo-alias"] == nil && projects?["other"] != nil)
    try require(catalog["centralAliases"] as? [String] != nil)
    _ = try f.sync.setParticipation(true, identity: f.identity)
    try f.checkState(enabled: true, code: "A")
    let entries = try DispatchParticipationSync.validatedEntries(object(f.paths.codes))
    try require(entries[0]["priority"] as? Int == 1)
}

test("an existing dispatch letter survives disable and re-enable behind later letters") {
    let f = try DispatchFixture()
    try mutate(f.paths.codes) { catalog in
        catalog["accounts"] = [
            ["code": "A", "alias": "fixture-a", "profileId": "profile-a", "priority": 1],
            ["code": "B", "alias": "fixture-primary", "profileId": "profile-primary", "priority": 1],
            ["code": "C", "alias": "fixture-c", "profileId": "profile-c", "priority": 1],
            ["code": "D", "alias": "fixture-d", "profileId": "profile-d", "priority": 2],
            ["code": "F", "alias": "fixture-f", "profileId": "profile-f", "priority": 4],
        ]
    }
    _ = try f.sync.setParticipation(true, identity: f.identity)
    try f.checkState(enabled: true, code: "B")
    _ = try f.sync.setParticipation(false, identity: f.identity)
    try f.checkState(enabled: false, code: "B")
    _ = try f.sync.setParticipation(true, identity: f.identity)
    try f.checkState(enabled: true, code: "B")
}

test("a legacy catalog gains integer priorities without changing existing values") {
    let f = try DispatchFixture()
    _ = try f.sync.setParticipation(true, identity: f.identity)
    let entries = try DispatchParticipationSync.validatedEntries(object(f.paths.codes))
    let other = entries.first { $0["alias"] as? String == "fixture-other" }
    let primary = entries.first { $0["alias"] as? String == "fixture-primary" }
    try require(other?["priority"] as? Int == 1)
    try require(primary?["priority"] as? Int == 2)
}

test("a maximum legacy priority remains finite when a new account is added") {
    let f = try DispatchFixture()
    try mutate(f.paths.codes) { catalog in
        var entries = catalog["accounts"] as! [[String: Any]]
        entries[0]["priority"] = Int.max
        catalog["accounts"] = entries
    }
    _ = try f.sync.setParticipation(true, identity: f.identity)
    let entries = try DispatchParticipationSync.validatedEntries(object(f.paths.codes))
    let primary = entries.first { $0["alias"] as? String == "fixture-primary" }
    try require(primary?["priority"] as? Int == Int.max)
}

for invalidCatalogField in ["priority", "active"] {
    test("invalid catalog \(invalidCatalogField) type rejects every write") {
        let f = try DispatchFixture()
        try mutate(f.paths.codes) { catalog in
            var entries = catalog["accounts"] as! [[String: Any]]
            entries[0][invalidCatalogField] = "invalid"
            catalog["accounts"] = entries
        }
        let originals = try f.contents()
        try expectError(.invalidCodes) { _ = try f.sync.setParticipation(true, identity: f.identity) }
        try require(f.contents() == originals)
    }
}

test("shared snapshot lock provides bounded reads and compare-and-swap writes") {
    let f = try DispatchFixture()
    let original = try DispatchParticipationSync.readSnapshot(at: f.paths.snapshot)
    try require(original != nil)
    try DispatchParticipationSync.withSnapshotLock(at: f.paths.snapshot) {
        try expectError(.busy) {
            _ = try DispatchParticipationSync.withSnapshotLock(at: f.paths.snapshot) { () }
        }
        try expectError(.concurrentChange) {
            try DispatchParticipationSync.writeSnapshot(original!, at: f.paths.snapshot, replacing: Data())
        }
        try DispatchParticipationSync.writeSnapshot(original!, at: f.paths.snapshot, replacing: original)
        try require(try DispatchParticipationSync.readSnapshot(at: f.paths.snapshot) == original)
    }
    try require(try DispatchParticipationSync.readSnapshot(at: f.root.appendingPathComponent("missing.json")) == nil)
}

test("system mirror uses the managed profile from the matching hub home") {
    let f = try DispatchFixture()
    let identity = DispatchParticipationSync.Identity(
        profileID: "system",
        homePath: f.root.appendingPathComponent("system-home").path,
        email: "FIXTURE-PRIMARY",
        accountID: f.identity.accountID
    )
    _ = try f.sync.setParticipation(true, identity: identity)
    try f.checkState(enabled: true, code: "D")
}

test("existing code and entry extensions survive a profile mapping repair") {
    let f = try DispatchFixture()
    try mutate(f.paths.codes) { catalog in
        var entries = catalog["accounts"] as! [[String: Any]]
        entries.append(["code": "A", "alias": "fixture-primary", "profileId": "system", "futureEntryField": true])
        catalog["accounts"] = entries
    }
    _ = try f.sync.setParticipation(true, identity: f.identity)
    try f.checkState(enabled: true, code: "A")
    try require((object(f.paths.codes)["accounts"] as! [[String: Any]])[1]["futureEntryField"] as? Bool == true)
}

test("priority opts into all three sources; removing it preserves participation and code") {
    let f = try DispatchFixture()
    _ = try f.sync.apply(.priority(true), identity: f.identity)
    try f.checkState(enabled: true, code: "D")
    var profiles = try object(f.paths.snapshot)["profiles"] as! [[String: Any]]
    try require(profiles[0]["prioritizeDispatch"] as? Bool == true)
    try require(profiles[1]["prioritizeDispatch"] as? Bool == true)
    try require(profiles[2]["prioritizeDispatch"] == nil)
    _ = try f.sync.apply(.priority(false), identity: f.identity)
    try f.checkState(enabled: true, code: "D")
    profiles = try object(f.paths.snapshot)["profiles"] as! [[String: Any]]
    try require(profiles[0]["prioritizeDispatch"] as? Bool == false)
    try require(profiles[1]["prioritizeDispatch"] as? Bool == false)
}

test("removing priority from an excluded account does not opt it into dispatch") {
    let f = try DispatchFixture()
    _ = try f.sync.apply(.priority(false), identity: f.identity)
    try f.checkState(enabled: false, code: nil)
}

test("disabling participation clears priority across account mirrors") {
    let f = try DispatchFixture()
    _ = try f.sync.apply(.priority(true), identity: f.identity)
    _ = try f.sync.setParticipation(false, identity: f.identity)
    try f.checkState(enabled: false, code: "D")
    let profiles = try object(f.paths.snapshot)["profiles"] as! [[String: Any]]
    try require(profiles[0]["prioritizeDispatch"] as? Bool == false)
    try require(profiles[1]["prioritizeDispatch"] as? Bool == false)
}

for enabled in [false, true] {
    for index in 0..<3 {
        test("priority change rollback after rename \(index), enabled=\(enabled)") {
            let f = try DispatchFixture()
            if !enabled { _ = try f.sync.apply(.priority(true), identity: f.identity) }
            let originals = try f.contents()
            var sync = f.sync
            sync.checkpoint = {
                if case .afterReplace(let value) = $0, value == index {
                    throw DispatchTestFailure.injected
                }
            }
            try expectError(.rolledBack) { _ = try sync.apply(.priority(enabled), identity: f.identity) }
            try require(f.contents() == originals)
            try f.checkNoTemporaryFiles()
        }
    }
}

for field in ["automaticSwitchParticipation", "prioritizeDispatch"] {
    test("invalid saved dispatch flag fails closed: \(field)") {
        let f = try DispatchFixture()
        try mutate(f.paths.snapshot) { snapshot in
            var profiles = snapshot["profiles"] as! [[String: Any]]
            profiles[0][field] = 1
            snapshot["profiles"] = profiles
        }
        let originals = try f.contents()
        try expectError(.invalidSnapshot) { _ = try f.sync.apply(.priority(true), identity: f.identity) }
        try require(f.contents() == originals)
    }
}

for field in ["automaticSwitchParticipation", "prioritizeDispatch"] {
    test("mixed account mirror state fails closed: \(field)") {
        let f = try DispatchFixture()
        try mutate(f.paths.snapshot) { snapshot in
            var profiles = snapshot["profiles"] as! [[String: Any]]
            profiles[1][field] = true
            profiles[0][field] = false
            snapshot["profiles"] = profiles
        }
        let originals = try f.contents()
        try expectError(.invalidSnapshot) {
            _ = try f.sync.apply(.priority(false), identity: f.identity)
        }
        try require(f.contents() == originals)
    }
}

for missing in [false, true] {
    for stage in ["backup", "before-rename", "after-rename"] {
        for index in 0..<3 {
            test("\(stage) failure at \(index), catalog missing=\(missing)") {
                let f = try DispatchFixture(catalogExists: !missing)
                let originals = try f.contents()
                var sync = f.sync
                sync.checkpoint = { point in
                    switch point {
                    case .beforeBackup(let value) where stage == "backup" && value == index,
                        .beforeReplace(let value) where stage == "before-rename" && value == index,
                        .afterReplace(let value) where stage == "after-rename" && value == index:
                        throw DispatchTestFailure.injected
                    default: break
                    }
                }
                let expected: DispatchParticipationError =
                    stage == "backup" || (stage == "before-rename" && index == 0)
                    ? .writeFailed : .rolledBack
                try expectError(expected) { _ = try sync.setParticipation(true, identity: f.identity) }
                try require(f.contents() == originals)
                if stage != "backup" { try f.checkBackups(originals) }
                try f.checkNoTemporaryFiles()
            }
        }
    }
}

test("disable rollback restores removed code byte-for-byte") {
    let f = try DispatchFixture()
    _ = try f.sync.setParticipation(true, identity: f.identity)
    let originals = try f.contents()
    var sync = f.sync
    sync.checkpoint = { if case .afterReplace(2) = $0 { throw DispatchTestFailure.injected } }
    try expectError(.rolledBack) { _ = try sync.setParticipation(false, identity: f.identity) }
    try require(f.contents() == originals)
}

test("concurrent edit before the first rename is preserved") {
    let f = try DispatchFixture()
    let originals = try f.contents()
    var sync = f.sync
    sync.checkpoint = { if case .beforeReplace(0) = $0 { try mutate(f.paths.hubConfig) { $0["externalEdit"] = true } } }
    try expectError(.concurrentChange) { _ = try sync.setParticipation(true, identity: f.identity) }
    let after = try f.contents()
    try require(after[0] == originals[0] && after[2] == originals[2])
    try require(object(f.paths.hubConfig)["externalEdit"] as? Bool == true)
}

test("concurrent edit after the outer preflight is preserved by the helper check") {
    let f = try DispatchFixture()
    let originals = try f.contents()
    var sync = f.sync
    sync.checkpoint = {
        if case .afterPreflight(0) = $0 {
            try mutate(f.paths.snapshot) { $0["externalEdit"] = true }
        }
    }
    try expectError(.concurrentChange) {
        _ = try sync.setParticipation(true, identity: f.identity)
    }
    let after = try f.contents()
    try require(after[1] == originals[1] && after[2] == originals[2])
    try require(object(f.paths.snapshot)["externalEdit"] as? Bool == true)
}

test("concurrent edit after the helper final read and before swap is restored") {
    let f = try DispatchFixture()
    let originals = try f.contents()
    var sync = f.sync
    sync.checkpoint = {
        if case .beforeAtomicSwap(0) = $0 {
            try mutate(f.paths.snapshot) { $0["externalFinalReadEdit"] = true }
        }
    }
    try expectError(.concurrentChange) {
        _ = try sync.setParticipation(true, identity: f.identity)
    }
    let after = try f.contents()
    try require(after[1] == originals[1] && after[2] == originals[2])
    try require(object(f.paths.snapshot)["externalFinalReadEdit"] as? Bool == true)
    try f.checkNoTemporaryFiles()
}

test("mismatch restore preserves a second writer found in the recovery file") {
    let f = try DispatchFixture()
    let firstWriter = try json(["writer": "first"])
    let secondWriter = try json(["writer": "second"])
    var sync = f.sync
    sync.checkpoint = {
        switch $0 {
        case .beforeAtomicSwap(0):
            try firstWriter.write(to: f.paths.snapshot)
        case .beforeMismatchRestore(0):
            try secondWriter.write(to: f.paths.snapshot)
        default:
            break
        }
    }
    try expectError(.rollbackFailed) {
        _ = try sync.setParticipation(true, identity: f.identity)
    }
    try require(try Data(contentsOf: f.paths.snapshot) == firstWriter)
    let recovery = try f.temporaryFiles(suffix: ".tmp")
    try require(recovery.count == 1 && (try Data(contentsOf: recovery[0])) == secondWriter)
}

test("mismatch restore rechecks ownership before temporary cleanup") {
    let f = try DispatchFixture()
    let displacedWriter = try json(["writer": "displaced"])
    let recoveryWriter = try json(["writer": "recovery"])
    var sync = f.sync
    sync.checkpoint = {
        switch $0 {
        case .beforeAtomicSwap(0):
            try displacedWriter.write(to: f.paths.snapshot)
        case .afterMismatchRestore(0):
            let recovery = try f.temporaryFiles(suffix: ".tmp")
            try require(recovery.count == 1)
            try recoveryWriter.write(to: recovery[0])
        default:
            break
        }
    }
    try expectError(.rollbackFailed) {
        _ = try sync.setParticipation(true, identity: f.identity)
    }
    try require(try Data(contentsOf: f.paths.snapshot) == displacedWriter)
    let recovery = try f.temporaryFiles(suffix: ".tmp")
    try require(recovery.count == 1 && (try Data(contentsOf: recovery[0])) == recoveryWriter)
}

test("concurrent edit after the first rename rolls back only our snapshot") {
    let f = try DispatchFixture()
    let originals = try f.contents()
    var sync = f.sync
    sync.checkpoint = { if case .afterReplace(0) = $0 { try mutate(f.paths.hubConfig) { $0["externalEdit"] = true } } }
    try expectError(.rolledBack) { _ = try sync.setParticipation(true, identity: f.identity) }
    let after = try f.contents()
    try require(after[0] == originals[0] && after[2] == originals[2])
    try require(object(f.paths.hubConfig)["externalEdit"] as? Bool == true)
}

test("rollback does not overwrite another writer's edit to a replaced file") {
    let f = try DispatchFixture()
    let originals = try f.contents()
    var sync = f.sync
    sync.checkpoint = { if case .afterReplace(1) = $0 { try mutate(f.paths.hubConfig) { $0["externalEdit"] = true } } }
    try expectError(.rollbackFailed) { _ = try sync.setParticipation(true, identity: f.identity) }
    let after = try f.contents()
    try require(after[0] == originals[0] && after[2] == originals[2])
    try require(object(f.paths.hubConfig)["externalEdit"] as? Bool == true)
    try f.checkBackups(originals)
}

test("rollback failure retains recoverable originals") {
    let f = try DispatchFixture()
    let originals = try f.contents()
    var sync = f.sync
    sync.checkpoint = {
        switch $0 {
        case .afterReplace(1), .beforeRollback(0): throw DispatchTestFailure.injected
        default: break
        }
    }
    try expectError(.rollbackFailed) { _ = try sync.setParticipation(true, identity: f.identity) }
    let after = try f.contents()
    try require(after[0] != originals[0] && after[1] == originals[1] && after[2] == originals[2])
    try f.checkBackups(originals)
}

test("unreadable displaced removal data is retained when restore is occupied") {
    let f = try DispatchFixture(catalogExists: false)
    let originals = try f.contents()
    let competingWriter = try json(["writer": "competing"])
    var createdCodes: Data?
    var sync = f.sync
    sync.checkpoint = {
        switch $0 {
        case .afterReplace(2):
            createdCodes = try Data(contentsOf: f.paths.codes)
            throw DispatchTestFailure.injected
        case .afterRemovalMove(2):
            let recovery = try f.temporaryFiles(suffix: ".remove")
            try require(recovery.count == 1)
            try require(Darwin.chmod(recovery[0].path, 0) == 0)
            try competingWriter.write(to: f.paths.codes)
        default:
            break
        }
    }
    try expectError(.rollbackFailed) {
        _ = try sync.setParticipation(true, identity: f.identity)
    }
    let recovery = try f.temporaryFiles(suffix: ".remove")
    try require(recovery.count == 1)
    try require(Darwin.chmod(recovery[0].path, 0o600) == 0)
    try require(createdCodes != nil && (try Data(contentsOf: recovery[0])) == createdCodes)
    try require(try Data(contentsOf: f.paths.codes) == competingWriter)
    let after = try f.contents()
    try require(after[0] == originals[0] && after[1] == originals[1])
}

for index in 0..<3 {
    test("malformed JSON source \(index) prevents every target write") {
        let f = try DispatchFixture()
        try Data("{".utf8).write(to: f.urls[index])
        let originals = try f.contents()
        try expectError([.invalidSnapshot, .invalidHub, .invalidCodes][index]) {
            _ = try f.sync.setParticipation(true, identity: f.identity)
        }
        try require(f.contents() == originals)
    }
}

for field in ["code", "alias", "profileId"] {
    test("duplicate catalog \(field) fails closed") {
        let f = try DispatchFixture()
        try mutate(f.paths.codes) { catalog in
            let first = (catalog["accounts"] as! [[String: Any]])[0]
            var second: [String: Any] = ["code": "A", "alias": "fixture-primary", "profileId": "profile-primary"]
            second[field] = first[field]
            catalog["accounts"] = [first, second]
        }
        let originals = try f.contents()
        try expectError(.invalidCodes) { _ = try f.sync.setParticipation(true, identity: f.identity) }
        try require(f.contents() == originals)
    }
}

for field in ["alias", "profileId"] {
    test("oversized catalog \(field) fails closed") {
        let f = try DispatchFixture()
        try mutate(f.paths.codes) { catalog in
            var entries = catalog["accounts"] as! [[String: Any]]
            entries[0][field] = String(repeating: "x", count: DispatchParticipationSync.maximumCatalogFieldBytes + 1)
            catalog["accounts"] = entries
        }
        let originals = try f.contents()
        try expectError(.invalidCodes) {
            _ = try f.sync.setParticipation(true, identity: f.identity)
        }
        try require(f.contents() == originals)
    }
}

test("conflicting alias and profile mapping fails closed") {
    let f = try DispatchFixture()
    try mutate(f.paths.codes) { $0["accounts"] = [["code": "A", "alias": "fixture-primary", "profileId": "profile-other"]] }
    let originals = try f.contents()
    try expectError(.ambiguousAccount) { _ = try f.sync.setParticipation(true, identity: f.identity) }
    try require(f.contents() == originals)
}

test("multiple hub homes for one account fail closed") {
    let f = try DispatchFixture()
    try mutate(f.paths.hubConfig) { hub in
        var accounts = hub["accounts"] as! [[String: Any]]
        accounts.append(["alias": "fixture-mirror", "home": f.root.appendingPathComponent("system-home").path])
        hub["accounts"] = accounts
    }
    let originals = try f.contents()
    try expectError(.ambiguousAccount) { _ = try f.sync.setParticipation(true, identity: f.identity) }
    try require(f.contents() == originals)
}

test("excluding one identity disables all of its validated hub homes") {
    let f = try DispatchFixture()
    _ = try f.sync.setParticipation(true, identity: f.identity)
    try mutate(f.paths.hubConfig) { hub in
        var accounts = hub["accounts"] as! [[String: Any]]
        accounts.append(["alias": "fixture-mirror", "home": f.root.appendingPathComponent("system-home").path, "dispatchDisabled": false])
        hub["accounts"] = accounts
    }
    _ = try f.sync.setParticipation(false, identity: f.identity)
    let accounts = try object(f.paths.hubConfig)["accounts"] as! [[String: Any]]
    try require(accounts[0]["dispatchDisabled"] as? Bool == true)
    try require(accounts[2]["dispatchDisabled"] as? Bool == true)
    try require(accounts[1]["dispatchDisabled"] as? Bool == false)
    let profiles = try object(f.paths.snapshot)["profiles"] as! [[String: Any]]
    try require(profiles[0]["automaticSwitchParticipation"] as? Bool == false)
    try require(profiles[1]["automaticSwitchParticipation"] as? Bool == false)
    try require(profiles[2]["automaticSwitchParticipation"] as? Bool == true)
    let catalog = try object(f.paths.codes)["accounts"] as! [[String: Any]]
    try require(catalog.first { $0["profileId"] as? String == f.identity.profileID }?["active"] as? Bool == false)
}

test("mismatched account ID in an email mirror fails closed") {
    let f = try DispatchFixture()
    try mutate(f.paths.snapshot) { snapshot in
        var profiles = snapshot["profiles"] as! [[String: Any]]
        var mirror = profiles[1]["lastSnapshot"] as! [String: Any]
        mirror["accountID"] = "account-stale-mirror"
        profiles[1]["lastSnapshot"] = mirror
        snapshot["profiles"] = profiles
    }
    let originals = try f.contents()
    try expectError(.identityMismatch) {
        _ = try f.sync.setParticipation(true, identity: f.identity)
    }
    try require(f.contents() == originals)
}

test("missing hub account can opt out without creating or changing a Hub identity") {
    let f = try DispatchFixture()
    try mutate(f.paths.hubConfig) { hub in
        hub["accounts"] = (hub["accounts"] as! [[String: Any]]).filter { $0["alias"] as? String != "fixture-primary" }
    }
    try mutate(f.paths.snapshot) { snapshot in
        var profiles = snapshot["profiles"] as! [[String: Any]]
        for i in [0, 1] { profiles[i]["automaticSwitchParticipation"] = true; profiles[i]["prioritizeDispatch"] = true }
        snapshot["profiles"] = profiles
    }
    let hubBefore = try Data(contentsOf: f.paths.hubConfig)
    _ = try f.sync.setParticipation(false, identity: f.identity)
    let profiles = try object(f.paths.snapshot)["profiles"] as! [[String: Any]]
    try require(profiles[0]["automaticSwitchParticipation"] as? Bool == false)
    try require(profiles[1]["automaticSwitchParticipation"] as? Bool == false)
    try require(profiles[0]["prioritizeDispatch"] as? Bool == false)
    try require(profiles[2]["automaticSwitchParticipation"] as? Bool == true)
    try require(Data(contentsOf: f.paths.hubConfig) == hubBefore)
    try require((object(f.paths.codes)["accounts"] as! [[String: Any]]).count == 1)
}

test("an empty Hub catalog does not prevent opting out") {
    let f = try DispatchFixture(catalogExists: false)
    try mutate(f.paths.hubConfig) { $0["accounts"] = [[String: Any]]() }
    _ = try f.sync.setParticipation(false, identity: f.identity)
    let profiles = try object(f.paths.snapshot)["profiles"] as! [[String: Any]]
    try require(profiles[0]["automaticSwitchParticipation"] as? Bool == false)
    try require((object(f.paths.codes)["accounts"] as! [[String: Any]]).isEmpty)
}

test("missing hub account fails closed on opt-in") {
    let f = try DispatchFixture()
    try mutate(f.paths.hubConfig) { $0["accounts"] = [(($0["accounts"] as! [[String: Any]])[1])] }
    let originals = try f.contents()
    try expectError(.ambiguousAccount) { _ = try f.sync.setParticipation(true, identity: f.identity) }
    try require(f.contents() == originals)
}

for identityKind in ["email", "home", "account-id", "missing-email"] {
    test("stale or missing identity: \(identityKind)") {
        let f = try DispatchFixture()
        let identity = DispatchParticipationSync.Identity(
            profileID: f.identity.profileID,
            homePath: identityKind == "home" ? f.root.appendingPathComponent("changed-home").path : f.identity.homePath,
            email: identityKind == "missing-email" ? nil : identityKind == "email" ? "fixture-changed" : f.identity.email,
            accountID: identityKind == "account-id" ? "account-changed" : f.identity.accountID
        )
        let originals = try f.contents()
        try expectError(.identityMismatch) { _ = try f.sync.setParticipation(true, identity: identity) }
        try require(f.contents() == originals)
    }
}

test("snapshot validator rejects before any target write") {
    let f = try DispatchFixture()
    let originals = try f.contents()
    var validations = 0
    try expectError(.invalidSnapshot) {
        _ = try f.sync.setParticipation(true, identity: f.identity) { _ in
            validations += 1
            if validations == 2 { throw DispatchParticipationError.invalidSnapshot }
        }
    }
    try require(validations == 2 && f.contents() == originals)
}

test("non-boolean hub flag is rejected") {
    let f = try DispatchFixture()
    try mutate(f.paths.hubConfig) { hub in
        var accounts = hub["accounts"] as! [[String: Any]]
        accounts[0]["dispatchDisabled"] = 1
        hub["accounts"] = accounts
    }
    let originals = try f.contents()
    try expectError(.invalidHub) { _ = try f.sync.setParticipation(true, identity: f.identity) }
    try require(f.contents() == originals)
}

test("A-Z exhaustion prevents snapshot and hub updates") {
    let f = try DispatchFixture()
    try mutate(f.paths.codes) { $0["accounts"] = [["code": "Z", "alias": "fixture-other", "profileId": "profile-other"]] }
    let originals = try f.contents()
    try expectError(.codeExhausted) { _ = try f.sync.setParticipation(true, identity: f.identity) }
    try require(f.contents() == originals)
}

test("symlink target is rejected without modifying its destination") {
    let f = try DispatchFixture()
    let originals = try f.contents()
    let actual = f.root.appendingPathComponent("redirected.json")
    try FileManager.default.moveItem(at: f.paths.hubConfig, to: actual)
    try FileManager.default.createSymbolicLink(at: f.paths.hubConfig, withDestinationURL: actual)
    try expectError(.fileAccess) { _ = try f.sync.setParticipation(true, identity: f.identity) }
    try require(f.contents() == originals)
}

test("bounded configuration reader rejects a sparse oversized regular file") {
    let f = try DispatchFixture()
    let oversized = f.root.appendingPathComponent("oversized.json")
    try Data().write(to: oversized)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(DispatchParticipationSync.maximumConfigurationBytes + 1))
    try handle.close()
    try expectError(.fileAccess) {
        _ = try DispatchParticipationSync.readBoundedRegularFile(oversized)
    }
    try expectError(.fileAccess) {
        _ = try DispatchParticipationSync.readBoundedRegularFile(
            f.paths.snapshot,
            maximumBytes: 8
        )
    }
}

test("process lock rejects reentrant synchronization") {
    let f = try DispatchFixture()
    var sync = f.sync
    sync.checkpoint = {
        if case .beforeBackup(0) = $0 {
            try expectError(.busy) { _ = try f.sync.setParticipation(false, identity: f.identity) }
        }
    }
    _ = try sync.setParticipation(true, identity: f.identity)
    try f.checkState(enabled: true, code: "D")
}

test("file lock rejects another synchronization owner") {
    let f = try DispatchFixture()
    let lock = f.paths.snapshot.deletingLastPathComponent().appendingPathComponent(DispatchParticipationPaths.lockFileName)
    let descriptor = lock.path.withCString { Darwin.open($0, O_RDWR | O_CREAT, 0o600) }
    try require(descriptor >= 0)
    defer { Darwin.close(descriptor) }
    try require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    defer { flock(descriptor, LOCK_UN) }
    let originals = try f.contents()
    try expectError(.busy) { _ = try f.sync.setParticipation(true, identity: f.identity) }
    try require(f.contents() == originals)
}

test("centralized paths resolve build sibling and explicit override without probing files") {
    let f = try DispatchFixture()
    let bundle = f.root.appendingPathComponent("next/build/CodexAccountManagerNext.app")
    let derived = try DispatchParticipationPaths.live(snapshot: f.paths.snapshot, bundleURL: bundle, environment: [:])
    try require(
        derived.hubConfig
            == f.root.appendingPathComponent(DispatchParticipationPaths.hubCheckoutName)
            .appendingPathComponent(DispatchParticipationPaths.hubConfigFileName))
    try require(derived.codes == f.paths.codes)
    let installed = f.root.appendingPathComponent("Applications/CodexAccountManagerNext.app")
    let override = try DispatchParticipationPaths.live(
        snapshot: f.paths.snapshot, bundleURL: installed,
        environment: [DispatchParticipationPaths.hubConfigEnvironmentKey: f.paths.hubConfig.path])
    try require(override.hubConfig == f.paths.hubConfig)
    try expectError(.hubLocation) {
        _ = try DispatchParticipationPaths.live(snapshot: f.paths.snapshot, bundleURL: installed, environment: [:], launchAgentURL: nil)
    }
    try expectError(.hubLocation) {
        _ = try DispatchParticipationPaths.live(
            snapshot: f.paths.snapshot, bundleURL: bundle,
            environment: [DispatchParticipationPaths.hubConfigEnvironmentKey: "relative/config.json"])
    }
}

test("installed app discovers only its existing named Hub service") {
    let f = try DispatchFixture()
    let installed = f.root.appendingPathComponent("Applications/CodexAccountManagerNext.app")
    let plist = f.root.appendingPathComponent("fixture-hub.plist")
    let data = try PropertyListSerialization.data(fromPropertyList: [
        "Label": "com.agenthub.arc-hub", "WorkingDirectory": f.paths.hubConfig.deletingLastPathComponent().path
    ], format: .xml, options: 0)
    try data.write(to: plist)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
    let discovered = try DispatchParticipationPaths.live(snapshot: f.paths.snapshot, bundleURL: installed, environment: [:], launchAgentURL: plist)
    try require(discovered.hubConfig == f.paths.hubConfig)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: plist.path)
    try expectError(.hubLocation) {
        _ = try DispatchParticipationPaths.live(snapshot: f.paths.snapshot, bundleURL: installed, environment: [:], launchAgentURL: plist)
    }
}


private func fixtureLaunchAgent(_ f: DispatchFixture, arguments: Any) throws -> URL {
    let plist = f.root.appendingPathComponent("literal-hub.plist")
    let data = try PropertyListSerialization.data(fromPropertyList: [
        "Label": "com.agenthub.arc-hub",
        "WorkingDirectory": f.root.appendingPathComponent("unrelated-directory").path,
        "ProgramArguments": arguments
    ], format: .xml, options: 0)
    try data.write(to: plist)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
    return plist
}

private func resolveFixtureLaunchAgent(_ f: DispatchFixture, _ plist: URL) throws -> URL {
    try DispatchParticipationPaths.live(
        snapshot: f.paths.snapshot,
        bundleURL: f.root.appendingPathComponent("Applications/Next.app"),
        environment: [:], launchAgentURL: plist
    ).hubConfig
}

for wrapped in [false, true] {
    for spaced in [false, true] {
        test("literal config takes precedence over unrelated WorkingDirectory: wrapper=\(wrapped), spaces=\(spaced)") {
            let f = try DispatchFixture()
            let binary = f.root.appendingPathComponent(spaced ? "Hub Tools/hub binary" : "hub-binary").path
            let config = f.root.appendingPathComponent(spaced ? "Hub Data/config file.json" : "explicit.json")
            let arguments = wrapped
                ? ["/bin/bash", "-c", "exec '\(binary)' --config '\(config.path)'"]
                : [binary, "--config", config.path]
            let plist = try fixtureLaunchAgent(f, arguments: arguments)
            let before = try f.contents()
            try require(try resolveFixtureLaunchAgent(f, plist) == config)
            try require(f.contents() == before)
        }
    }
}

for spaced in [false, true] {
    test("deployed double-quoted exec wrapper resolves literal config: spaces=\(spaced)") {
        let f = try DispatchFixture()
        let binary = f.root.appendingPathComponent(spaced ? "Hub Tools/hub binary" : "hub-binary").path
        let config = f.root.appendingPathComponent(spaced ? "Hub Data/config file.json" : "explicit.json")
        let command = "exec \"\(binary)\" --config \"\(config.path)\""
        let plist = try fixtureLaunchAgent(f, arguments: ["/bin/bash", "-c", command])
        try require(try resolveFixtureLaunchAgent(f, plist) == config)
    }
}

test("explicit config requires no WorkingDirectory and direct argv without config retains fallback") {
    let f = try DispatchFixture()
    let plist = try fixtureLaunchAgent(f, arguments: ["/fixture/hub", "--config", "/fixture/config.json"])
    var value = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
    value.removeValue(forKey: "WorkingDirectory")
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: plist)
    try require(try resolveFixtureLaunchAgent(f, plist).path == "/fixture/config.json")
    let fallback = try fixtureLaunchAgent(f, arguments: ["/fixture/hub", "--verbose"])
    try require(try resolveFixtureLaunchAgent(f, fallback) == f.root.appendingPathComponent("unrelated-directory/config.json"))
}

let invalidHubArguments: [[String]] = [
    [], ["relative-hub", "--config", "/fixture/config.json"],
    ["/fixture/hub", "--config"], ["/fixture/hub", "--config", ""],
    ["/fixture/hub", "--config", "relative/config.json"],
    ["/fixture/hub", "--config", "/fixture/a", "--config", "/fixture/a"],
    ["/fixture/hub", "--config=/fixture/a"],
    ["/fixture/hub", "--config", "/fixture/a", "--config=/fixture/b"],
    ["/fixture/hub", "--", "--config", "/fixture/a"],
    ["/fixture/hub", "--config", "/fixture/$HOME/config"],
    ["/fixture/hub", "--config", "/fixture/$(id)/config"],
    ["/fixture/hub", "--config", "/fixture/`id`/config"],
    ["/fixture/hub", "--config", "/fixture/a", ";", "other"],
    ["/bin/bash", "-c"],
    ["/bin/bash", "-lc", "exec '/fixture/hub' --config '/fixture/a'"],
    ["/bin/zsh", "-c", "exec '/fixture/hub' --config '/fixture/a'"],
    ["/bin/bash", "-c", "exec '/fixture/hub' --config '/fixture/a'", "extra"]
]
for (index, arguments) in invalidHubArguments.enumerated() {
    test("invalid direct or wrapper arguments reject fallback: \(index)") {
        let f = try DispatchFixture()
        let plist = try fixtureLaunchAgent(f, arguments: arguments)
        try expectError(.hubLocation) { _ = try resolveFixtureLaunchAgent(f, plist) }
    }
}

let invalidHubCommands = [
    "exec '/fixture/hub' --config 'relative/config.json'",
    "exec '/fixture/hub' --config '/fixture/a",
    "exec '/fixture/hub --config '/fixture/a'",
    "exec '/fixture/hub' --config",
    "exec '/fixture/hub' --config '/fixture/a' --config '/fixture/b'",
    "exec '/fixture/hub' --config '/fixture/$HOME/a'",
    "exec '/fixture/hub' --config '/fixture/$(id)/a'",
    "exec '/fixture/hub' --config '/fixture/`id`/a'",
    "exec '/fixture/hub' --config '/fixture/a'; other",
    "exec '/fixture/hub' --config '/fixture/a' && other",
    "exec '/fixture/hub' --config '/fixture/a' | other",
    "exec '/fixture/hub' --config '/fixture/a' > /fixture/out",
    "exec '/fixture/hub' --config '/fixture/a' &",
    "exec '/fixture/hub' --config '/fixture/a'\nother",
    "exec '/fixture/hub' --config '/fixture/a'\n",
    "exec '/fixture/hub' --config '/fixture/\\a'",
    "exec '/fixture/hub' --config '/fixture/*.json'",
    "exec '/fixture/hub' --config '/fixture/a' # comment",
    "exec /fixture/hub --config /fixture/a",
    "exec \"/fixture/hub\" --config \"/fixture/$HOME/a\"",
    "exec \"/fixture/hub\" --config \"/fixture/$(id)/a\"",
    "exec \"/fixture/hub\" --config \"/fixture/a\"; other",
    "exec \"/fixture/hub\" --config '/fixture/a\"",
    "exec '/bin/bash' --config '/fixture/a'"
]
for (index, command) in invalidHubCommands.enumerated() {
    test("nonliteral shell command rejects fallback: \(index)") {
        let f = try DispatchFixture()
        let plist = try fixtureLaunchAgent(f, arguments: ["/bin/bash", "-c", command])
        try expectError(.hubLocation) { _ = try resolveFixtureLaunchAgent(f, plist) }
    }
}

test("malformed ProgramArguments rejects fallback") {
    let f = try DispatchFixture()
    let plist = try fixtureLaunchAgent(f, arguments: "--config /fixture/a")
    try expectError(.hubLocation) { _ = try resolveFixtureLaunchAgent(f, plist) }
}

for mode in [0o620, 0o602] {
    test("explicit arguments do not bypass writable LaunchAgent rejection: \(mode)") {
        let f = try DispatchFixture()
        let plist = try fixtureLaunchAgent(f, arguments: ["/fixture/hub", "--config", "/fixture/a"])
        try require(Darwin.chmod(plist.path, mode_t(mode)) == 0)
        try expectError(.hubLocation) { _ = try resolveFixtureLaunchAgent(f, plist) }
    }
}

test("explicit arguments do not bypass symlink or nonregular LaunchAgent rejection") {
    let f = try DispatchFixture()
    let plist = try fixtureLaunchAgent(f, arguments: ["/fixture/hub", "--config", "/fixture/a"])
    let link = f.root.appendingPathComponent("linked-hub.plist")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plist)
    try expectError(.hubLocation) { _ = try resolveFixtureLaunchAgent(f, link) }
    try expectError(.hubLocation) { _ = try resolveFixtureLaunchAgent(f, f.root) }
}


// Changing a fixture's owner requires root. Never read an unrelated system file
// or change process identity merely to exercise this unchanged ownership guard.
if geteuid() == 0 {
    test("explicit arguments do not bypass unowned LaunchAgent rejection") {
        let f = try DispatchFixture()
        let plist = try fixtureLaunchAgent(f, arguments: ["/fixture/hub", "--config", "/fixture/a"])
        try require(Darwin.chown(plist.path, 1, gid_t.max) == 0)
        defer { _ = Darwin.chown(plist.path, 0, gid_t.max) }
        try expectError(.hubLocation) { _ = try resolveFixtureLaunchAgent(f, plist) }
    }
} else {
    print("SKIP: unowned LaunchAgent fixture requires root; ownership guard unchanged.")
}

print("All \(passed) dispatch participation tests passed (temporary fixtures only).")
