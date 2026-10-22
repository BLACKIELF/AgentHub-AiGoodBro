import Foundation

extension LocalProxyHostFixtures {
    @MainActor static func networkSettingsFixtures() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checks += 1
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = CodexProfile(id: "network-fixture", lastSnapshot: .init(fetchedAt: Date(), fiveHour: .init(usedPercent: 10, resetsAt: Date().addingTimeInterval(3600)), sevenDay: .init(usedPercent: 10, resetsAt: Date().addingTimeInterval(86400))))
        let usage = UsageStore([profile]); usage.isPreview = false
        let legacy = LocalProxyPreferences()
        expect(legacy.effectiveListenPort == 18080 && legacy.effectiveClientKeyMode == .persistent && legacy.validNetworkSettings, "legacy defaults are fixed port and persistent key")
        let store = LocalProxyQueueStore(usageStore: usage)
        expect(!store.setNetworkSettings(port: 80, mode: .persistent, egress: .init()), "privileged port rejected")
        var bad = LocalProxyEgressSettings(); bad.mihomoAPI = "http://example.invalid:9097"
        expect(!store.setNetworkSettings(port: 18080, mode: .persistent, egress: bad), "remote management endpoint rejected")
        bad.mihomoAPI = "http://127.0.0.1:9097/evil"
        expect(!bad.isValid, "management path rejected")
        expect(store.setNetworkSettings(port: 18080, mode: .persistent, egress: .init()), "valid settings saved")
        let helper = "#!/bin/sh\nIFS= read -r startup || exit 1\nprintf '%s\\n' '{\"event\":\"ready\",\"port\":18080}'\nIFS= read -r stop\nexit 0\n"
        try Data(helper.utf8).write(to: LocalProxyFixtureRuntime.helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: LocalProxyFixtureRuntime.helper.path)
        store.setOptIn(true); store.setAccountEnabled(id: profile.id, enabled: true)
        var firstKey: String?
        var firstEndpoint: String?
        for _ in 0..<3 {
            let run = LocalProxyQueueStore(usageStore: usage)
            await run.start()
            expect(run.phase == .running, "synthetic helper started")
            if firstKey == nil { firstKey = run.clientKey; firstEndpoint = run.endpoint }
            expect(run.clientKey == firstKey && run.endpoint == firstEndpoint, "key and endpoint stable across store reload and helper restart")
            expect(!run.setNetworkSettings(port: 18082, mode: .perRun, egress: .init()), "running settings cannot mutate")
            await run.stop()
            expect(run.canFinishTermination, "helper fully stopped")
        }
        let reloaded = LocalProxyQueueStore(usageStore: usage)
        expect(reloaded.preferences.persistentClientKey == firstKey, "persistent key survives disk reload")
        expect(reloaded.setNetworkSettings(port: 0, mode: .perRun, egress: .init()), "legacy random mode remains available")
        await reloaded.start(); let temporaryKey = reloaded.clientKey; await reloaded.stop()
        await reloaded.start()
        expect(reloaded.clientKey != temporaryKey && reloaded.preferences.persistentClientKey == firstKey, "per-run changes without destroying saved persistent key")
        await reloaded.stop()
        let saved = try Data(contentsOf: root.appendingPathComponent("local-proxy-queue-v1.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("local-proxy-queue-v1.json.blocked"), withIntermediateDirectories: false)
        LocalProxyFixtureRuntime.failPreferenceRename = true
        expect(!reloaded.setNetworkSettings(port: 18083, mode: .persistent, egress: .init()), "failed atomic save reports failure")
        LocalProxyFixtureRuntime.failPreferenceRename = false
        let afterFailure = try Data(contentsOf: root.appendingPathComponent("local-proxy-queue-v1.json"))
        expect(afterFailure == saved, "failed save preserves prior bytes")
        var invalid = LocalProxyPreferences(); invalid.persistentClientKey = "malformed"
        expect(!invalid.validNetworkSettings, "malformed persistent key rejected rather than silently regenerated")
        let preferencesURL = root.appendingPathComponent("local-proxy-queue-v1.json")
        let persisted = try JSONDecoder().decode(LocalProxyPreferences.self, from: Data(contentsOf: preferencesURL))
        expect(persisted.persistentClientKey == nil && persisted.egress?.mihomoSecret == "", "disk preferences contain no secrets")
        expect(persisted.secretsReference != nil, "disk preferences reference Keychain")
        var old = persisted
        old.secretsReference = nil
        old.persistentClientKey = firstKey
        old.egress?.mihomoSecret = "fixture-controller-secret"
        try JSONEncoder().encode(old).write(to: preferencesURL)
        let migrated = LocalProxyQueueStore(usageStore: usage)
        expect(!migrated.preferencesBlocked && migrated.preferences.persistentClientKey == firstKey, "legacy key migrates without rotation")
        expect(migrated.egressSettings.mihomoSecret == "fixture-controller-secret", "controller secret migrates")
        let redactedData = try Data(contentsOf: preferencesURL)
        let redacted = String(decoding: redactedData, as: UTF8.self)
        expect(!redacted.contains("fixture-controller-secret") && !redacted.contains(firstKey!), "migration removes plaintext credentials")
        let migratedReference = migrated.preferences.secretsReference!
        LocalProxyPreferenceSecrets.items.removeValue(forKey: migratedReference)
        let missing = LocalProxyQueueStore(usageStore: usage)
        expect(missing.preferencesBlocked, "missing Keychain reference fails closed")
        try JSONEncoder().encode(old).write(to: preferencesURL)
        LocalProxyPreferenceSecrets.failSave = true
        let failedMigration = LocalProxyQueueStore(usageStore: usage)
        expect(failedMigration.preferencesBlocked, "failed Keychain migration blocks proxy")
        let retained = try JSONDecoder().decode(LocalProxyPreferences.self, from: Data(contentsOf: preferencesURL))
        expect(retained.persistentClientKey == firstKey && retained.secretsReference == nil, "failed migration preserves recoverable old state")
        LocalProxyPreferenceSecrets.failSave = false
        print("PASS: \(checks) network settings checks; synthetic helper only, no real accounts or network")
    }
}
