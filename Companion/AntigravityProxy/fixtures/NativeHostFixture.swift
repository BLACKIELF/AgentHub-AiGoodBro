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
    func read(_ account: String) throws -> Data? { reads += 1; return data[account] }
    func save(_ value: Data, account: String) throws {
        if rejectWrites { throw AntigravityProxyFailure.keychain }
        writes += 1
        data[account] = value
    }
    func remove(_ account: String) throws { data[account] = nil }
}

@main
@MainActor
struct NativeHostFixture {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("helper and fixture directory required") }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        try await multiProvider(helper: helper, root: root)
        for scenario in ["provider-credential-add", "provider-prefix-add", "provider-label-add"] {
            let (store, credentials, _) = await start(helper: helper, root: root, scenario: scenario)
            let before = credentials.data, writes = credentials.writes
            await store.addAccount(provider: .antigravity)
            await eventually("rejected add did not finish: \(scenario)") { !store.signInPending }
            require(store.accounts.isEmpty && credentials.data == before && credentials.writes == writes, "wrong-provider add reached Keychain: \(scenario)")
            await stop(store)
        }
        for scenario in ["provider-credential-refresh", "provider-label-refresh", "keychain-failure"] {
            let (store, credentials, _) = await start(helper: helper, root: root, scenario: scenario)
            await add(.antigravity, to: store, count: 1)
            let before = credentials.data, writes = credentials.writes
            credentials.rejectWrites = scenario == "keychain-failure"
            store.refreshStatus()
            await eventually("refresh rejection was not acknowledged: \(scenario)") { store.issue != nil }
            require(credentials.data == before && credentials.writes == writes && store.accounts.count == 1,
                    "rejected refresh changed credentials: \(scenario)")
            await stop(store)
        }
        let (cancelled, cancelCredentials, _) = await start(helper: helper, root: root, scenario: "cancel-late")
        let cancelBefore = cancelCredentials.data, cancelWrites = cancelCredentials.writes
        await cancelled.addAccount(provider: .kimi)
        require(cancelled.signInPending, "authorization was not pending before cancellation")
        cancelled.cancelSignIn()
        await eventually("late cancelled authorization was not exercised") { cancelled.issue != nil }
        require(!cancelled.signInPending && cancelled.accounts.isEmpty && cancelCredentials.data == cancelBefore && cancelCredentials.writes == cancelWrites,
                "late cancelled authorization reached Keychain")
        await stop(cancelled)

        let (revoked, revokeCredentials, _) = await start(helper: helper, root: root, scenario: "revocation-late")
        await add(.xai, to: revoked, count: 1)
        let revokeWrites = revokeCredentials.writes
        revoked.removeAccount(revoked.accounts[0].id)
        await eventually("late revoked refresh was not exercised") { revoked.issue != nil }
        require(revoked.accounts.isEmpty && revokeCredentials.data.count == 1 && revokeCredentials.writes == revokeWrites,
                "late refresh resurrected revoked account")
        await stop(revoked)

        let (crossed, crossCredentials, _) = await start(helper: helper, root: root, scenario: "cross-catalog")
        await add(.antigravity, to: crossed, count: 1)
        await add(.claude, to: crossed, count: 2)
        let crossBefore = crossCredentials.data
        crossed.refreshStatus()
        await eventually("foreign catalog did not fail closed") { crossed.phase == .failed }
        require(crossed.models(for: .antigravity).isEmpty && crossed.models(for: .claude).isEmpty && crossCredentials.data == crossBefore,
                "foreign model catalog was exposed or changed credentials")
        await stop(crossed)
        try await invalidMetadata(helper: helper, root: root)
        authorizationTargets()
        print("PASS: four-provider private pipe, isolated catalogs, provider/prefix rejection, Keychain failure, cancelled/revoked late events, OAuth URL matrix, bounded termination")
    }

    static func start(helper: URL, root: URL, scenario: String) async -> (AntigravityProxyStore, MemoryCredentials, URL) {
        let directory = root.appendingPathComponent(scenario, isDirectory: true)
        let credentials = MemoryCredentials()
        let store = AntigravityProxyStore(supportDirectory: directory, helperURL: helper, credentialStore: credentials)
        require(credentials.reads == 0 && store.phase == .stopped, "init read credentials or launched")
        await store.start()
        require(store.phase == .running && store.port == 18081 && credentials.reads == 1,
                "start did not bind private helper: \(scenario)")
        require(Set(store.availableProviders) == Set(AntigravityProxyProvider.allCases), "ready omitted registered providers")
        return (store, credentials, directory)
    }

    static func add(_ provider: AntigravityProxyProvider, to store: AntigravityProxyStore, count: Int) async {
        await store.addAccount(provider: provider)
        await eventually("account was not committed: \(provider.rawValue)") { store.accounts.count == count && !store.signInPending }
        require(store.issue == nil && store.accounts.contains { $0.provider == provider }, "account crossed provider boundary")
    }

    static func stop(_ store: AntigravityProxyStore) async {
        await store.finishForTermination()
        require(store.canFinishTermination && store.clientKey == nil && store.endpoint == nil && store.availableProviders.isEmpty,
                "termination left a process, client key or advertised endpoint")
    }

    static func multiProvider(helper: URL, root: URL) async throws {
        let (store, credentials, directory) = await start(helper: helper, root: root, scenario: "valid-multi")
        for (index, provider) in AntigravityProxyProvider.allCases.enumerated() {
            await add(provider, to: store, count: index + 1)
            require(store.endpoint(for: provider)?.absoluteString == "http://127.0.0.1:18081/providers/\(provider.rawValue)",
                    "provider endpoint was not isolated")
            require(Set(store.models(for: provider)) == Set(["shared-fixture", "\(provider.rawValue)-fixture"]),
                    "provider catalog leaked a foreign model")
        }
        require(Set(store.models) == Set(store.models(for: .antigravity)), "legacy models mixed provider catalogs")
        require(credentials.data.count == 5, "credentials were not isolated from client key")
        let file = directory.appendingPathComponent("accounts-v1.json")
        let persisted = try String(contentsOf: file, encoding: .utf8)
        require(!persisted.contains("synthetic-access") && !persisted.contains("synthetic-refresh") && !persisted.contains("projectID"),
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

    static func invalidMetadata(helper: URL, root: URL) async throws {
        for scenario in ["bad-json", "bad-provider-prefix"] {
            let directory = root.appendingPathComponent(scenario, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var bytes = Data("not-valid-json".utf8)
            if scenario == "bad-provider-prefix" {
                let invalid = AntigravityProxyAccount(id: "ag-" + String(repeating: "a", count: 32), provider: .claude,
                    maskedIdentity: "f***@e***", generation: String(repeating: "b", count: 32), enabled: true,
                    concurrencyLimit: 1, inFlight: 0, state: .checking, models: [])
                require(!invalid.hasValidIdentity, "provider prefix was accepted")
                bytes = try JSONEncoder().encode([invalid])
            }
            try bytes.write(to: directory.appendingPathComponent("accounts-v1.json"))
            let credentials = MemoryCredentials()
            let store = AntigravityProxyStore(supportDirectory: directory, helperURL: helper, credentialStore: credentials)
            await store.start()
            require(store.phase == .failed && credentials.reads == 0 && credentials.writes == 0,
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
            for invalid in [text.replacingOccurrences(of: host, with: "example.test"), text.replacingOccurrences(of: "https://", with: "http://"),
                            text.replacingOccurrences(of: "S256", with: "plain"), text + "&state=duplicate", text + "#fragment"] {
                require(AntigravityProxyStore.validatedAuthorizationURL(invalid, provider: provider) == nil, "invalid OAuth target accepted")
            }
        }
        require(AntigravityProxyStore.validatedAuthorizationURL(google, provider: .claude) == nil, "Google URL accepted for Claude")
        let code = "FIXT-1234"
        for (provider, hosts, path) in [(AntigravityProxyProvider.kimi, ["www.kimi.com", "kimi.com"], "/code/authorize_device"),
                                       (.xai, ["accounts.x.ai", "auth.x.ai"], "/oauth2/device")] {
            for host in hosts {
                let text = "https://\(host)\(path)?user_code=\(code)"
                require(AntigravityProxyStore.validatedAuthorizationURL(text, provider: provider, userCode: code) != nil, "valid device target rejected")
                require(AntigravityProxyStore.validatedAuthorizationURL(text, provider: provider) == nil, "device URL without visible code accepted")
                require(AntigravityProxyStore.validatedAuthorizationURL(text, provider: provider, userCode: "OTHER") == nil, "mismatched device code accepted")
                for invalid in [text.replacingOccurrences(of: host, with: "example.test"), text.replacingOccurrences(of: "https://", with: "http://"),
                                text.replacingOccurrences(of: host, with: host + ":443"), text.replacingOccurrences(of: path, with: "/other"),
                                text.replacingOccurrences(of: host, with: "user@" + host), text + "&user_code=\(code)", text + "&extra=value", text + "#fragment"] {
                    require(AntigravityProxyStore.validatedAuthorizationURL(invalid, provider: provider, userCode: code) == nil, "invalid device target accepted")
                }
            }
        }
    }

    static func eventually(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        require(false, message)
    }
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
}
