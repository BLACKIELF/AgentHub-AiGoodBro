import Foundation

struct CodexAccountSnapshot {
    var email: String?
    var accountID: String?
}

struct CodexCredentialIdentity {
    let email: String
    let accountID: String
}

struct CodexProfile {
    let id: String
    let codexHomePath: String
    let isSystemProfile: Bool
    var lastSnapshot: CodexAccountSnapshot?
    var codexHomeURL: URL { URL(fileURLWithPath: codexHomePath) }

    func matchesRecordedCredential(_ identity: CodexCredentialIdentity) -> Bool {
        identity.email == lastSnapshot?.email && identity.accountID == lastSnapshot?.accountID
    }
}

enum AccountDisplay {
    static func profileName(_ profile: CodexProfile) -> String { "Synthetic account" }
}

@MainActor
enum CodexOfficialProfileReader {
    static var identities: [String: CodexCredentialIdentity] = [:]
    static func credentialIdentity(codexHomeURL: URL) -> CodexCredentialIdentity? { identities[codexHomeURL.path] }
}

@MainActor
final class HostSwitchStoreFixture {
    var profiles: [CodexProfile]
    var isLaunchingCodex = false
    var isLoggingIn = false
    var isAccountSwitchTransactionActive = false
    var desktopSwitchSucceeded = false
    var confirmsSwitch = true
    var launchedProfileIDs: [String] = []

    init(_ profiles: [CodexProfile]) { self.profiles = profiles }

    func launchCodex(with profileID: String) {
        launchedProfileIDs.append(profileID)
        guard confirmsSwitch, let target = profiles.first(where: { $0.id == profileID }),
            let systemIndex = profiles.firstIndex(where: \.isSystemProfile)
        else { return }
        profiles[systemIndex].lastSnapshot = target.lastSnapshot
        desktopSwitchSucceeded = true
    }

    // PRODUCTION_STORE_METHODS
}

@MainActor
final class HostSwitchAppFixture {
    let store: HostSwitchStoreFixture
    init(_ store: HostSwitchStoreFixture) { self.store = store }
    func showMainWindow() {}

    func handle(_ request: TokenMonitorHostRequest) async -> TokenMonitorHostReply {
        // PRODUCTION_HOST_SWITCH
    }
}

@main
struct TokenMonitorHostSwitchFixture {
    @MainActor static var assertions = 0
    @MainActor static var failures = 0

    @MainActor static func expect(_ passed: Bool, _ message: String) {
        assertions += 1
        if !passed {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    @MainActor static func profile(_ id: String, workspace: String, system: Bool = false) -> CodexProfile {
        let home = "/synthetic/host-switch/" + id
        CodexOfficialProfileReader.identities[home] = .init(email: "fixture@example.invalid", accountID: workspace)
        return CodexProfile(
            id: id, codexHomePath: home, isSystemProfile: system,
            lastSnapshot: .init(email: "fixture@example.invalid", accountID: workspace))
    }

    @MainActor static func main() async throws {
        let system = profile("system", workspace: "workspace-a", system: true)
        let first = profile("managed-a", workspace: "workspace-a")
        let second = profile("managed-b", workspace: "workspace-b")
        let key = TokenMonitorHostIdentity.accountKey(email: first.lastSnapshot?.email, accountID: first.lastSnapshot?.accountID)!
        func request(_ vendor: String, key: String = key) throws -> TokenMonitorHostRequest {
            try TokenMonitorHostRequest.decode(
                JSONSerialization.data(withJSONObject: ["id": "synthetic", "cmd": "switchCodexAccount", "vendorAccountId": vendor, "recordedAccountKey": key]))
        }

        let projection = HostSwitchStoreFixture([system, first, second]).tokenMonitorManagedCodexAccounts()
        expect(projection.count == 2, "system mirrors are excluded from the managed projection")
        expect(projection.first(where: { $0.accountKey == key })?.id == "aigoodbro-managed-a", "the host row ID is derived from the exact unique managed profile")
        for account in projection {
            let store = HostSwitchStoreFixture([system, first, second])
            let reply = await HostSwitchAppFixture(store).handle(try request(account.id, key: account.accountKey))
            expect(reply.ok && reply.accountId == account.id, "every real managed projection row keeps its protocol acknowledgment")
            expect(store.launchedProfileIDs == [String(account.id.dropFirst("aigoodbro-".count))], "a matching projected row selects its own profile")
        }

        for vendor in ["aigoodbro-managed-b", "aigoodbro-system", "aigoodbro-missing"] {
            let store = HostSwitchStoreFixture([system, first, second])
            let reply = await HostSwitchAppFixture(store).handle(try request(vendor))
            expect(!reply.ok && reply.accountId == nil && store.launchedProfileIDs.isEmpty, "mismatched reserved row \(vendor) is rejected before any switch action")
        }
        for vendor in ["codex-" + key.dropFirst("sha256:".count).prefix(12), "legacy-opaque-row"] {
            let store = HostSwitchStoreFixture([system, first, second])
            let reply = await HostSwitchAppFixture(store).handle(try request(vendor))
            expect(reply.ok && reply.accountId == vendor && store.launchedProfileIDs == [first.id], "legacy opaque aliases retain their correlation semantics")
        }

        let duplicate = profile("duplicate-a", workspace: "workspace-a")
        let ambiguous = HostSwitchStoreFixture([system, first, duplicate, second])
        expect(ambiguous.tokenMonitorManagedCodexAccounts().map(\.id) == ["aigoodbro-managed-b"], "duplicate managed identities remain excluded rather than choosing a mirror")
        let ambiguousReply = await HostSwitchAppFixture(ambiguous).handle(try request("aigoodbro-managed-a"))
        expect(!ambiguousReply.ok && ambiguous.launchedProfileIDs.isEmpty, "an ambiguous matching-looking row cannot switch")

        let failed = HostSwitchStoreFixture([system, first, second])
        failed.confirmsSwitch = false
        let failedReply = await HostSwitchAppFixture(failed).handle(try request("aigoodbro-managed-a"))
        expect(!failedReply.ok && failedReply.error == "switch-not-confirmed", "a matching row still requires the completed desktop identity confirmation")
        print("Token Monitor host switch: \(assertions) assertions, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
