import Combine
import Foundation

// This fixture substitutes the existing path helper and all Keychain calls.
struct DispatchParticipationPaths {
    static func supportDirectory() -> URL { URL(fileURLWithPath: "/private/tmp/unused-antigravity-fixture") }
}

final class MemoryCredentials: AntigravityProxyCredentialStore {
    var data: [String: Data] = [:]
    var reads = 0
    var writes = 0
    var rejectWrites = false
    var rejectRemovals = false
    var dropWrites = false
    func read(_ account: String) throws -> Data? {
        reads += 1
        return data[account]
    }
    func save(_ value: Data, account: String) throws {
        if rejectWrites { throw AntigravityProxyFailure.keychain }
        writes += 1
        if dropWrites { return }
        data[account] = value
    }
    func remove(_ account: String) throws {
        if rejectRemovals { throw AntigravityProxyFailure.keychain }
        data[account] = nil
    }
}

@main
@MainActor
struct NativeHostFixture {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("helper and fixture directory required") }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        try modelDetailValidation()
        try await modelDetailSnapshots(helper: helper, root: root)
        try await largeModelSnapshot(helper: helper, root: root)
        try await multiProvider(helper: helper, root: root)
        try await snapshotUpdates(helper: helper, root: root)
        try await sameProviderAccounts(helper: helper, root: root)
        try await pendingRefreshRecovery(helper: helper, root: root)
        let (removal, removalCredentials, removalDirectory) = await start(helper: helper, root: root, scenario: "removal-retry")
        await add(.claude, to: removal, count: 1)
        let removalID = removal.accounts[0].id
        let beforeRemoval = removalCredentials.data
        removalCredentials.rejectRemovals = true
        removal.removeAccount(removalID)
        require(
            removal.issue != nil && removal.accounts.count == 1 && removalCredentials.data == beforeRemoval,
            "failed secret deletion lost the retryable account")
        let persistedRemoval = try JSONDecoder().decode(
            [AntigravityProxyAccount].self,
            from: Data(contentsOf: removalDirectory.appendingPathComponent("accounts-v1.json")))
        require(persistedRemoval.map(\.id) == [removalID], "failed deletion lost persisted retry identity")
        removalCredentials.rejectRemovals = false
        removal.removeAccount(removalID)
        require(
            removal.issue == nil && removal.accounts.isEmpty && removalCredentials.data.count == 1,
            "retry did not delete the account credential")
        await stop(removal)
        for scenario in ["provider-credential-add", "provider-prefix-add", "provider-label-add"] {
            let (store, credentials, _) = await start(helper: helper, root: root, scenario: scenario)
            let before = credentials.data
            let writes = credentials.writes
            await store.addAccount(provider: .antigravity)
            await eventually("rejected add did not finish: \(scenario)") { !store.signInPending }
            require(store.accounts.isEmpty && credentials.data == before && credentials.writes == writes, "wrong-provider add reached Keychain: \(scenario)")
            await stop(store)
        }
        for scenario in ["provider-credential-refresh", "provider-label-refresh", "keychain-failure"] {
            let (store, credentials, _) = await start(helper: helper, root: root, scenario: scenario)
            await add(.antigravity, to: store, count: 1)
            let before = credentials.data
            let writes = credentials.writes
            credentials.rejectWrites = scenario == "keychain-failure"
            store.refreshStatus()
            await eventually("refresh rejection was not acknowledged: \(scenario)") { store.issue != nil }
            require(
                credentials.data == before && credentials.writes == writes && store.accounts.count == 1,
                "rejected refresh changed credentials: \(scenario)")
            await stop(store)
        }
        let (failedAdd, failedCredentials, _) = await start(helper: helper, root: root, scenario: "keychain-add-failure")
        failedCredentials.rejectWrites = true
        await failedAdd.addAccount(provider: .antigravity)
        await eventually("failed add did not end") { !failedAdd.signInPending }
        require(
            failedAdd.accounts.isEmpty && failedAdd.issue?.contains("钥匙串") == true,
            "add Keychain failure was overwritten by generic OAuth result")
        await stop(failedAdd)
        let (cancelled, cancelCredentials, _) = await start(helper: helper, root: root, scenario: "cancel-late")
        let cancelBefore = cancelCredentials.data
        let cancelWrites = cancelCredentials.writes
        await cancelled.addAccount(provider: .kimi)
        require(cancelled.signInPending, "authorization was not pending before cancellation")
        cancelled.cancelSignIn()
        require(cancelled.signInPending, "cancel unlocked before the helper terminal result")
        await cancelled.addAccount(provider: .kimi)
        require(cancelled.signInPending, "retry bypassed the old helper cancellation")
        await eventually("late cancelled authorization was not exercised") { !cancelled.signInPending }
        require(
            !cancelled.signInPending && cancelled.accounts.isEmpty && cancelCredentials.data == cancelBefore && cancelCredentials.writes == cancelWrites,
            "late cancelled authorization reached Keychain")
        await stop(cancelled)

        let (revoked, revokeCredentials, _) = await start(helper: helper, root: root, scenario: "revocation-late")
        await add(.xai, to: revoked, count: 1)
        let revokeWrites = revokeCredentials.writes
        revoked.removeAccount(revoked.accounts[0].id)
        await eventually("late revoked refresh was not exercised") { revoked.issue != nil }
        require(
            revoked.accounts.isEmpty && revokeCredentials.data.count == 1 && revokeCredentials.writes == revokeWrites,
            "late refresh resurrected revoked account")
        await stop(revoked)

        let (crossed, crossCredentials, _) = await start(helper: helper, root: root, scenario: "cross-catalog")
        await add(.antigravity, to: crossed, count: 1)
        await add(.claude, to: crossed, count: 2)
        let crossBefore = crossCredentials.data
        crossed.refreshStatus()
        await eventually("foreign catalog did not fail closed") { crossed.phase == .failed }
        require(
            crossed.models(for: .antigravity).isEmpty && crossed.models(for: .claude).isEmpty && crossCredentials.data == crossBefore,
            "foreign model catalog was exposed or changed credentials")
        await stop(crossed)
        try await invalidMetadata(helper: helper, root: root)
        authorizationTargets()
        print(
            "PASS: four-provider private pipe, isolated catalogs, provider/prefix rejection, Keychain failure, cancelled/revoked late events, OAuth URL matrix, bounded termination"
        )
    }

    static func start(helper: URL, root: URL, scenario: String) async -> (AntigravityProxyStore, MemoryCredentials, URL) {
        let directory = root.appendingPathComponent(scenario, isDirectory: true)
        let credentials = MemoryCredentials()
        let store = AntigravityProxyStore(supportDirectory: directory, helperURL: helper, credentialStore: credentials)
        require(credentials.reads == 0 && store.phase == .stopped, "init read credentials or launched")
        await store.start()
        require(
            store.phase == .running && store.port == 18081 && credentials.reads == 1,
            "start did not bind private helper: \(scenario)")
        require(Set(store.availableProviders) == Set(AntigravityProxyProvider.allCases), "ready omitted registered providers")
        return (store, credentials, directory)
    }

    static func pendingRefreshRecovery(helper: URL, root: URL) async throws {
        let original = AntigravityProxyCredential(
            provider: .xai, accountID: "xai-9a267f1b514e28a8722e1514725495bf", generation: String(repeating: "b", count: 32),
            maskedIdentity: "f***@例***", accessToken: "synthetic-active-access", refreshToken: "synthetic-active-refresh",
            projectID: "", expiresAt: 1_800_000_000, accountSubject: "fixture-account")
        let candidate = AntigravityProxyCredential(
            provider: original.provider, accountID: original.accountID, generation: original.generation,
            maskedIdentity: original.maskedIdentity, accessToken: "synthetic-pending-access", refreshToken: "synthetic-pending-refresh",
            projectID: "", expiresAt: 4_102_444_800, accountSubject: original.accountSubject)
        require(original.fingerprint == "0043118735138636d00aec427c6234cfae627da7b470fbbd089c90c65d9dfe88", "native/Go UTF-8 credential digest differs")
        let key = "account.\(original.accountID).\(original.generation)"
        let pendingKey = "account.\(original.accountID).\(original.generation).pending-refresh"
        let pending = AntigravityProxyPendingRefresh(baseFingerprint: original.fingerprint, credential: candidate)
        let originalData = try JSONEncoder().encode(original)
        func seed(_ scenario: String, pendingData: Data? = nil) throws -> (AntigravityProxyStore, MemoryCredentials, URL) {
            let directory = root.appendingPathComponent(scenario, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode([original.account]).write(to: directory.appendingPathComponent("accounts-v1.json"))
            let vault = MemoryCredentials()
            vault.data = [key: originalData, "client-key": Data("synthetic-private-client-key-for-pending-fixture".utf8)]
            vault.data[pendingKey] = pendingData
            return (AntigravityProxyStore(supportDirectory: directory, helperURL: helper, credentialStore: vault), vault, directory)
        }
        func stage(_ store: AntigravityProxyStore, _ number: Int, accepted: Bool) async {
            store.refreshStatus()
            await eventually("pending write ACK did not return") { store.accounts.first?.lastError == "fixture_stage_\(number)_\(accepted)" }
        }
        func decoded(_ vault: MemoryCredentials) throws -> AntigravityProxyCredential {
            try JSONDecoder().decode(AntigravityProxyCredential.self, from: vault.data[key]!)
        }

        let (first, vault, directory) = try seed("pending-refresh-valid")
        await first.start()
        require(first.phase == .running, "pending fixture did not start")
        await stage(first, 0, accepted: true)
        require(try decoded(vault) == original, "pending candidate overwrote the legacy active key")
        require(
            try JSONDecoder().decode(AntigravityProxyPendingRefresh.self, from: vault.data[pendingKey]!) == pending,
            "pending candidate did not persist separately with its old-active digest")
        await stop(first)
        let resumed = AntigravityProxyStore(supportDirectory: directory, helperURL: helper, credentialStore: vault)
        await resumed.start()
        await eventually("pending restart did not bootstrap candidate") { resumed.accounts.first?.lastError == "fixture_bootstrap_pending" }
        await stage(resumed, 0, accepted: true)
        await stage(resumed, 1, accepted: true)
        require(try decoded(vault) == candidate && vault.data[pendingKey] != nil, "active promotion was not durable before cleanup")
        await stage(resumed, 2, accepted: true)
        require(try decoded(vault) == candidate && vault.data[pendingKey] == nil, "pending cleanup changed active credentials")
        await stop(resumed)

        for scenario in ["wrong-base", "wrong-generation", "no-stage", "oversize"] {
            let (store, vault, _) = try seed("pending-refresh-" + scenario)
            await store.start()
            await stage(store, scenario == "no-stage" ? 1 : 0, accepted: false)
            require(vault.data[key] == originalData && vault.data[pendingKey] == nil, "invalid pending write reached Keychain: \(scenario)")
            await stop(store)
        }

        let (failed, failedVault, failedDirectory) = try seed("pending-refresh-ack-failures")
        await failed.start()
        failedVault.dropWrites = true
        await stage(failed, 0, accepted: false)
        require(failedVault.data[pendingKey] == nil && failedVault.data[key] == originalData, "unreadable stage ACK changed active credentials")
        failedVault.dropWrites = false
        await stage(failed, 0, accepted: true)
        failedVault.rejectWrites = true
        await stage(failed, 1, accepted: false)
        require(failedVault.data[key] == originalData && failedVault.data[pendingKey] != nil, "failed active ACK lost pending recovery")
        failedVault.rejectWrites = false
        await stage(failed, 1, accepted: true)
        failedVault.rejectRemovals = true
        await stage(failed, 2, accepted: false)
        require(try decoded(failedVault) == candidate && failedVault.data[pendingKey] != nil, "cleanup failure changed the verified active item")
        await stop(failed)
        let alreadyPromoted = AntigravityProxyStore(supportDirectory: failedDirectory, helperURL: helper, credentialStore: failedVault)
        await alreadyPromoted.start()
        await eventually("committed promotion was not recognized on restart") { alreadyPromoted.accounts.first?.lastError == "fixture_bootstrap_promoted" }
        require(try decoded(failedVault) == candidate, "restart restored an older active credential")
        await stop(alreadyPromoted)

        for (name, data) in [
            ("corrupt", Data("{".utf8)), ("oversized-record", Data(repeating: 120, count: 65_537)),
            ("stale-record", try JSONEncoder().encode(AntigravityProxyPendingRefresh(baseFingerprint: String(repeating: "0", count: 64), credential: candidate))),
        ] {
            let (store, vault, _) = try seed("pending-refresh-" + name, pendingData: data)
            let before = vault.data
            await store.start()
            require(store.phase == .failed && vault.data == before, "invalid pending bootstrap was used or silently deleted")
            await stop(store)
        }

        let (changed, changedVault, _) = try seed("pending-refresh-active-cas")
        await changed.start()
        await stage(changed, 0, accepted: true)
        var independent = original
        independent.idToken = "synthetic-independent-active-generation"
        let independentData = try JSONEncoder().encode(independent)
        changedVault.data[key] = independentData
        await stage(changed, 1, accepted: false)
        require(changedVault.data[key] == independentData && changedVault.data[pendingKey] != nil, "stale pending overwrote newer active credentials")
        await stop(changed)

        let (removed, removedVault, _) = try seed("pending-refresh-revocation")
        await removed.start()
        await stage(removed, 0, accepted: true)
        removed.removeAccount(original.accountID)
        await eventually("late pending write was not exercised") { removed.issue != nil }
        require(
            removed.accounts.isEmpty && removedVault.data[key] == nil && removedVault.data[pendingKey] == nil,
            "late pending write resurrected a removed generation")
        await stop(removed)
        print("PASS: pending refresh private IPC, old-version key isolation, restart/promotion recovery, ACK failures, CAS, bounds and revocation")
    }

    static func add(_ provider: AntigravityProxyProvider, to store: AntigravityProxyStore, count: Int) async {
        await store.addAccount(provider: provider)
        await eventually("account was not committed: \(provider.rawValue)") { store.accounts.count == count && !store.signInPending }
        require(store.issue == nil && store.accounts.contains { $0.provider == provider }, "account crossed provider boundary")
    }

    static func stop(_ store: AntigravityProxyStore) async {
        await store.finishForTermination()
        require(
            store.canFinishTermination && store.clientKey == nil && store.endpoint == nil && store.availableProviders.isEmpty,
            "termination left a process, client key or advertised endpoint")
    }

    static func multiProvider(helper: URL, root: URL) async throws {
        let (store, credentials, directory) = await start(helper: helper, root: root, scenario: "valid-multi")
        for (index, provider) in AntigravityProxyProvider.allCases.enumerated() {
            await add(provider, to: store, count: index + 1)
            require(
                store.endpoint(for: provider)?.absoluteString == "http://127.0.0.1:18081/providers/\(provider.rawValue)",
                "provider endpoint was not isolated")
            require(
                Set(store.models(for: provider)) == Set(["shared-fixture", "\(provider.rawValue)-fixture"]),
                "provider catalog leaked a foreign model")
        }
        require(Set(store.models) == Set(store.models(for: .antigravity)), "legacy models mixed provider catalogs")
        require(credentials.data.count == 5, "credentials were not isolated from client key")
        let file = directory.appendingPathComponent("accounts-v1.json")
        let persisted = try String(contentsOf: file, encoding: .utf8)
        require(
            !persisted.contains("synthetic-access") && !persisted.contains("synthetic-refresh") && !persisted.contains("projectID"),
            "credential persisted in metadata")
        let readsBeforeReopen = credentials.reads
        let reopened = AntigravityProxyStore(supportDirectory: directory, helperURL: helper, credentialStore: credentials)
        require(reopened.accounts.count == 4 && credentials.reads == readsBeforeReopen, "metadata reopen read Keychain")
        let claude = store.accounts.first { $0.provider == .claude }!
        store.setEnabled(claude.id, enabled: false)
        await eventually("disabled provider catalog was not removed") { store.models(for: .claude).isEmpty }
        require(store.models(for: .antigravity).contains("antigravity-fixture"), "disabling one provider affected another")
        let disabled = try JSONDecoder().decode([AntigravityProxyAccount].self, from: Data(contentsOf: file))
        require(disabled.first { $0.id == claude.id }?.enabled == false, "participation was not durable")
        await stop(store)
    }

    static func snapshotUpdates(helper: URL, root: URL) async throws {
        let (store, credentials, directory) = await start(helper: helper, root: root, scenario: "snapshot-updates")
        for (index, provider) in AntigravityProxyProvider.allCases.enumerated() {
            await add(provider, to: store, count: index + 1)
        }
        var accountUpdates = 0
        var legacyUpdates = 0
        var publications = 0
        var acknowledgements = 0
        let accountsSubscription = store.$accounts.dropFirst().sink { _ in accountUpdates += 1 }
        let modelsSubscription = store.$models.dropFirst().sink { _ in legacyUpdates += 1 }
        let changesSubscription = store.objectWillChange.sink { publications += 1 }
        let acknowledgementSubscription = store.$issue.dropFirst().sink { _ in acknowledgements += 1 }
        let previousAccounts = store.accounts
        let previousModels = store.models
        let credentialReads = credentials.reads
        let credentialWrites = credentials.writes
        let file = directory.appendingPathComponent("accounts-v1.json")
        let originalMetadata = try Data(contentsOf: file)
        let originalModified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        store.refreshStatus()
        await eventually("stable snapshots did not complete") { acknowledgements == 1 }
        require(
            accountUpdates == 0 && legacyUpdates == 0 && publications == 1,
            "unchanged snapshots published redundant account/model changes")
        require(store.accounts == previousAccounts && store.models == previousModels, "stable snapshot changed values")
        require(try Data(contentsOf: file) == originalMetadata, "stable snapshot changed stored metadata")
        require(
            try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalModified,
            "stable snapshot rewrote identical metadata")

        store.refreshStatus()
        await eventually("Claude-only catalog update did not complete") { acknowledgements == 2 }
        require(
            store.models(for: .claude) == ["claude-fixture"] && store.models == previousModels,
            "non-Antigravity catalog change was lost")
        require(
            accountUpdates == 0 && legacyUpdates == 0 && publications == 3,
            "non-Antigravity catalog must publish once without unrelated updates")

        store.refreshStatus()
        await eventually("busy update did not complete") { acknowledgements == 3 }
        require(
            store.accounts.first { $0.provider == .claude }?.inFlight == 1 && store.hasActiveRequests,
            "request activity stopped updating")
        require(accountUpdates == 1 && legacyUpdates == 0 && publications == 5, "busy state must publish once")

        store.refreshStatus()
        await eventually("cooldown update did not complete") { acknowledgements == 4 }
        let stored = try JSONDecoder().decode([AntigravityProxyAccount].self, from: Data(contentsOf: file))
        require(stored.first { $0.provider == .claude }?.cooldownEpoch == 4_102_444_800, "cooldown persistence changed")
        require(accountUpdates == 2 && legacyUpdates == 0 && publications == 7, "cooldown must publish once")
        require(credentials.reads == credentialReads && credentials.writes == credentialWrites, "snapshots accessed credentials")
        withExtendedLifetime([accountsSubscription, modelsSubscription, changesSubscription, acknowledgementSubscription]) {}
        await stop(store)
        print("PASS: repeated snapshots publish no redundant updates; other-provider models, activity and durable cooldown still update")
    }

    static func modelDetailValidation() throws {
        let legacy = AntigravityProxyAccount(
            id: "ag-" + String(repeating: "a", count: 32), maskedIdentity: "f***@e***",
            generation: String(repeating: "b", count: 32), enabled: true,
            concurrencyLimit: 1, inFlight: 0, state: .ready, models: ["fixture"])
        let oldBytes = try JSONEncoder().encode(legacy)
        let old = try JSONDecoder().decode(AntigravityProxyAccount.self, from: oldBytes)
        require(old.hasValidIdentity && old.modelDetails == nil && old.sharedWindows == nil, "legacy record is incompatible")
        var valid = legacy
        valid.modelDetails = [.init(id: "fixture", displayName: "Fixture", remainingFraction: 0), .init(id: "unknown", displayName: "Unknown")]
        valid.modelDetailsUpdatedAt = 1_800_000_000
        valid.sharedWindows = [.init(id: "pool", pool: "Shared", label: "5-hour", remainingFraction: 0, windowSeconds: 18_000)]
        require(valid.hasValidIdentity, "known zero or unknown rejected")
        for fraction in [-1.0, 1.1, Double.nan, Double.infinity] {
            var bad = valid
            bad.modelDetails![0].remainingFraction = fraction
            require(!bad.hasValidIdentity, "invalid numeric quota accepted")
        }
        for name in ["bad\nname", "\u{202E}hidden", String(repeating: "x", count: 161), " padded "] {
            var bad = valid
            bad.modelDetails![0].displayName = name
            require(!bad.hasValidIdentity, "unsafe display name accepted")
        }
        for id in ["fixture\n", "fixture/alias", "", String(repeating: "x", count: 129)] {
            var bad = valid
            bad.modelDetails![0].id = id
            require(!bad.hasValidIdentity, "invalid model ID accepted")
            bad = valid
            bad.models = [id]
            require(!bad.hasValidIdentity, "invalid admitted model ID accepted")
            bad = valid
            bad.sharedWindows![0].modelIDs = [id]
            require(!bad.hasValidIdentity, "invalid shared model ID accepted")
        }
        var duplicate = valid
        duplicate.modelDetails![1].id = "fixture"
        require(!duplicate.hasValidIdentity, "duplicate model detail accepted")
        var tooMany = valid
        tooMany.modelDetails = (0..<513).map { .init(id: "model-\($0)", displayName: "Fixture") }
        require(!tooMany.hasValidIdentity, "unbounded model details accepted")
        var badTime = valid
        badTime.modelDetailsUpdatedAt = -1
        require(!badTime.hasValidIdentity, "invalid observed timestamp accepted")
        var badAmount = valid
        badAmount.sharedWindows![0].remainingAmount = 2
        badAmount.sharedWindows![0].totalAmount = 1
        require(!badAmount.hasValidIdentity, "overstated quota count accepted")
        var badMembers = valid
        badMembers.sharedWindows![0].modelIDs = ["fixture", "fixture"]
        require(!badMembers.hasValidIdentity, "duplicate shared membership accepted")
        var badIssue = valid
        badIssue.quotaIssue = "raw provider failure"
        require(!badIssue.hasValidIdentity, "unbounded quota error accepted")
        print("PASS: model quota DTO supports legacy, zero and unknown while rejecting invalid numbers, labels, duplicates and bounds")
    }

    static func modelDetailSnapshots(helper: URL, root: URL) async throws {
        let (store, credentials, directory) = await start(helper: helper, root: root, scenario: "model-details")
        await add(.antigravity, to: store, count: 1)
        guard let first = store.accounts.first, let details = first.modelDetails else { fatalError("model details missing") }
        require(
            details.count == 4 && details[1].remainingFraction == 0 && details[2].remainingFraction == nil,
            "known zero and unknown quota were conflated")
        require(details[3].resetsAt! < Date() && details[3].remainingFraction == nil, "expired quota became fresh")
        require(!store.models(for: .antigravity).contains("exhausted-fixture"), "display detail changed launch admission")
        require(first.sharedWindows?.first?.windowSeconds == 18_000, "shared quota dropped in IPC")
        let file = directory.appendingPathComponent("accounts-v1.json")
        let saved = try Data(contentsOf: file)
        let savedText = String(decoding: saved, as: UTF8.self)
        require(
            !savedText.contains("modelDetails") && !savedText.contains("sharedWindows") && !savedText.contains("quotaIssue"),
            "runtime quota persisted with authorization records")
        var accountUpdates = 0
        var acknowledgements = 0
        let accountObserver = store.$accounts.dropFirst().sink { _ in accountUpdates += 1 }
        let ackObserver = store.$issue.dropFirst().sink { _ in acknowledgements += 1 }
        let reads = credentials.reads
        let writes = credentials.writes
        store.refreshStatus()
        await eventually("identical detail snapshots not acknowledged") { acknowledgements == 1 }
        require(accountUpdates == 0, "identical detail snapshots repeatedly published")
        store.refreshStatus()
        await eventually("quota-only update not acknowledged") { acknowledgements == 2 }
        require(
            accountUpdates == 1 && store.accounts[0].modelDetails?[0].remainingFraction == 0.2,
            "quota-only change was lost or overpublished")
        store.refreshStatus()
        await eventually("summary failure not acknowledged") { acknowledgements == 3 }
        require(
            accountUpdates == 2 && store.accounts[0].sharedWindows == nil && store.accounts[0].quotaIssue == "summary_unavailable"
                && store.accounts[0].modelDetails?[0].remainingFraction == 0.1 && Set(store.models) == Set(first.models),
            "summary failure removed model observations or retained old shared quota")
        require(
            try Data(contentsOf: file) == saved && credentials.reads == reads && credentials.writes == writes,
            "quota snapshot changed records or accessed credentials")
        // Even an old record containing runtime observations is cleared on read.
        try JSONEncoder().encode([first]).write(to: file)
        let reopened = AntigravityProxyStore(supportDirectory: directory, helperURL: helper, credentialStore: credentials)
        require(
            reopened.accounts[0].modelDetails == nil && reopened.accounts[0].sharedWindows == nil
                && reopened.accounts[0].modelDetailsUpdatedAt == nil, "reopen trusted persisted live quota")
        withExtendedLifetime([accountObserver, ackObserver]) {}
        await stop(store)
        require(
            store.accounts.allSatisfy { $0.modelDetails == nil && $0.modelDetailsUpdatedAt == nil && $0.sharedWindows == nil && $0.quotaIssue == nil },
            "stopped pool kept live quota observations")
        for scenario in ["fraction", "name", "duplicate", "time", "window"] {
            let (invalid, vault, _) = await start(helper: helper, root: root, scenario: "model-details-invalid-" + scenario)
            await add(.antigravity, to: invalid, count: 1)
            let before = vault.data
            let reads = vault.reads
            let writes = vault.writes
            invalid.refreshStatus()
            await eventually("invalid quota IPC was accepted: \(scenario)") { invalid.phase == .failed }
            require(
                vault.data == before && vault.reads == reads && vault.writes == writes,
                "invalid quota changed credentials")
            await stop(invalid)
        }
        print("PASS: real IPC preserves model/shared quotas, publishes quota-only changes once, rejects invalid input, and clears runtime observations")
    }

    static func largeModelSnapshot(helper: URL, root: URL) async throws {
        let directory = root.appendingPathComponent("large-model-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let vault = MemoryCredentials()
        var records: [AntigravityProxyAccount] = []
        for index in 1...100 {
            let id = "ag-" + String(format: "%032x", index)
            let credential = AntigravityProxyCredential(
                accountID: id, generation: String(repeating: "b", count: 32),
                maskedIdentity: "f***@e***", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                projectID: "synthetic-project", expiresAt: 4_102_444_800)
            records.append(credential.account)
            vault.data["account.\(id).\(credential.generation)"] = try JSONEncoder().encode(credential)
        }
        let file = directory.appendingPathComponent("accounts-v1.json")
        let metadata = try JSONEncoder().encode(records)
        try metadata.write(to: file)
        let store = AntigravityProxyStore(supportDirectory: directory, helperURL: helper, credentialStore: vault)
        var completePublications = 0
        var partialPublication = false
        let observer = store.$accounts.dropFirst().sink { rows in
            if rows.contains(where: { $0.modelDetails != nil }) {
                completePublications += 1
                if rows.count != 100 || !rows.allSatisfy({ $0.models.count == 512 && $0.modelDetails?.count == 512 && $0.sharedWindows?.count == 3 }) {
                    partialPublication = true
                }
            }
        }
        await store.start()
        await eventually("large snapshot did not arrive", attempts: 1_000) { store.accounts.last?.modelDetails?.count == 512 || store.phase == .failed }
        require(
            store.phase == .running && store.accounts.count == 100 && completePublications == 1 && !partialPublication,
            "large snapshot stopped the helper or partially published")
        for (index, account) in store.accounts.enumerated() {
            require(
                account.id == records[index].id && account.modelDetails?.first?.remainingFraction == Double(index + 1) / 100,
                "large snapshot crossed account quota identities")
            require(account.sharedWindows?.allSatisfy { $0.modelIDs?.count == 512 } == true, "large snapshot truncated memberships")
        }
        require(store.models.count == 512, "large snapshot truncated launch catalog")
        let reads = vault.reads
        let writes = vault.writes
        var acknowledgements = 0
        let acknowledgement = store.$issue.dropFirst().sink { _ in acknowledgements += 1 }
        store.refreshStatus()
        await eventually("large repeated snapshot did not complete", attempts: 1_000) { acknowledgements == 1 || store.phase == .failed }
        require(
            store.phase == .running && completePublications == 1 && !partialPublication,
            "large repeated snapshot republished or failed")
        store.refreshStatus()
        await eventually("oversized frame did not stop helper", attempts: 1_000) { store.phase == .failed }
        require(
            completePublications == 1 && !partialPublication && store.accounts.count == 100 && store.models.isEmpty,
            "oversized snapshot published partial or empty account state")
        let finalMetadata = try Data(contentsOf: file)
        require(
            vault.reads == reads && vault.writes == writes && finalMetadata == metadata,
            "large/oversized snapshot accessed credentials or persisted runtime quota")
        withExtendedLifetime([observer, acknowledgement]) {}
        await stop(store)
        let (reported, reportedVault, _) = await start(helper: helper, root: root, scenario: "oversized-snapshot-error")
        let original = reportedVault.data
        reported.refreshStatus()
        await eventually("helper oversize error did not fail closed") { reported.phase == .failed }
        require(reportedVault.data == original, "helper oversize error changed credentials")
        await stop(reported)
        print("PASS: real pipe preserves 100 accounts x 512 models and shared windows, deduplicates repeats, and stops oversized frames without partial publication")
    }

    static func sameProviderAccounts(helper: URL, root: URL) async throws {
        let (store, credentials, directory) = await start(helper: helper, root: root, scenario: "multi-same-provider")
        await add(.antigravity, to: store, count: 1)
        let firstID = store.completedSignInAccountID
        await add(.antigravity, to: store, count: 2)
        let secondID = store.completedSignInAccountID
        require(firstID != nil && secondID != nil && firstID != secondID, "second Antigravity account did not get a distinct success receipt")
        await store.addAccount(provider: .antigravity)
        await eventually("duplicate did not end") { !store.signInPending }
        require(
            store.accounts.count == 2 && store.issue?.contains("已在") == true && store.completedSignInAccountID == nil,
            "duplicate Antigravity login was mistaken for a new account")
        require(credentials.data.count == 3, "second account did not use a separate Keychain item")
        let saved = try JSONDecoder().decode([AntigravityProxyAccount].self, from: Data(contentsOf: directory.appendingPathComponent("accounts-v1.json")))
        require(Set(saved.map(\.id)) == Set(store.accounts.map(\.id)), "both Antigravity accounts were not durably saved")
        await stop(store)
    }

    static func invalidMetadata(helper: URL, root: URL) async throws {
        for scenario in ["bad-json", "bad-provider-prefix"] {
            let directory = root.appendingPathComponent(scenario, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var bytes = Data("not-valid-json".utf8)
            if scenario == "bad-provider-prefix" {
                let invalid = AntigravityProxyAccount(
                    id: "ag-" + String(repeating: "a", count: 32), provider: .claude,
                    maskedIdentity: "f***@e***", generation: String(repeating: "b", count: 32), enabled: true,
                    concurrencyLimit: 1, inFlight: 0, state: .checking, models: [])
                require(!invalid.hasValidIdentity, "provider prefix was accepted")
                bytes = try JSONEncoder().encode([invalid])
            }
            try bytes.write(to: directory.appendingPathComponent("accounts-v1.json"))
            let credentials = MemoryCredentials()
            let store = AntigravityProxyStore(supportDirectory: directory, helperURL: helper, credentialStore: credentials)
            await store.start()
            require(
                store.phase == .failed && credentials.reads == 0 && credentials.writes == 0,
                "invalid metadata accessed credentials: \(scenario)")
            await stop(store)
        }
    }

    static func authorizationTargets() {
        let nonce = String(repeating: "a", count: 43)
        let query = "response_type=code&code_challenge_method=S256&code_challenge=\(nonce)&state=\(nonce)&redirect_uri="
        let google = "https://accounts.google.com/o/oauth2/v2/auth?" + query + "http%3A%2F%2F127.0.0.1%3A12345%2Foauth-callback"
        let claude = "https://claude.ai/oauth/authorize?" + query + "http%3A%2F%2Flocalhost%3A54545%2Fcallback"
        for (provider, text, host) in [(AntigravityProxyProvider.antigravity, google, "accounts.google.com"), (.claude, claude, "claude.ai")] {
            require(AntigravityProxyStore.validatedAuthorizationURL(text, provider: provider) != nil, "valid OAuth target rejected")
            for invalid in [
                text.replacingOccurrences(of: host, with: "example.test"), text.replacingOccurrences(of: "https://", with: "http://"),
                text.replacingOccurrences(of: "S256", with: "plain"), text + "&state=duplicate", text + "#fragment",
            ] {
                require(AntigravityProxyStore.validatedAuthorizationURL(invalid, provider: provider) == nil, "invalid OAuth target accepted")
            }
        }
        require(AntigravityProxyStore.validatedAuthorizationURL(google, provider: .claude) == nil, "Google URL accepted for Claude")
        let code = "FIXT-1234"
        for (provider, hosts, path) in [
            (AntigravityProxyProvider.kimi, ["www.kimi.com", "kimi.com"], "/code/authorize_device"),
            (.xai, ["accounts.x.ai", "auth.x.ai"], "/oauth2/device"),
        ] {
            for host in hosts {
                let text = "https://\(host)\(path)?user_code=\(code)"
                require(AntigravityProxyStore.validatedAuthorizationURL(text, provider: provider, userCode: code) != nil, "valid device target rejected")
                require(AntigravityProxyStore.validatedAuthorizationURL(text, provider: provider) == nil, "device URL without visible code accepted")
                require(AntigravityProxyStore.validatedAuthorizationURL(text, provider: provider, userCode: "OTHER") == nil, "mismatched device code accepted")
                for invalid in [
                    text.replacingOccurrences(of: host, with: "example.test"), text.replacingOccurrences(of: "https://", with: "http://"),
                    text.replacingOccurrences(of: host, with: host + ":443"), text.replacingOccurrences(of: path, with: "/other"),
                    text.replacingOccurrences(of: host, with: "user@" + host), text + "&user_code=\(code)", text + "&extra=value", text + "#fragment",
                ] {
                    require(AntigravityProxyStore.validatedAuthorizationURL(invalid, provider: provider, userCode: code) == nil, "invalid device target accepted")
                }
            }
        }
    }

    static func eventually(_ message: String, attempts: Int = 100, _ predicate: () -> Bool) async {
        for _ in 0..<attempts {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        require(false, message)
    }
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
}
