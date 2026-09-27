import Foundation

final class TokenMonitorCancellation: @unchecked Sendable {
    var isCancelled = false
    func cancel() { isCancelled = true }
}
struct TokenMonitorEngine {
    static let maximumOutputBytes = 16_777_216
    static let maximumInputBytes = 1_048_576
    func collect(request: TokenMonitorRequest, cancellation: TokenMonitorCancellation) throws -> TokenMonitorResponse {
        Harness.events.append("http")
        return try Harness.http(request)
    }
}
struct Statistics { var resolvedIdentifier = "UTC" }
struct RuntimeLoadContext {
    var homeDirectory: URL
    var codexHomeDirectory: URL
    var cacheDirectory: URL
    var statistics = Statistics()
    var quotaCancellation: TokenMonitorCancellation? = nil
}
struct Identity { var email = "synthetic-identity"; var accountID = "synthetic-account" }
struct CodexProfile {
    var id = "card-a"
    var isSystemProfile = false
    var codexHomeURL: URL
    func matchesRecordedCredential(_ identity: Identity) -> Bool { identity.accountID == "synthetic-account" }
    func matchesRecordedAccount(email: String?) -> Bool { email == "synthetic-identity" }
}
enum CodexCredentialAccessGate {
    static let gate = NSRecursiveLock()
    static func homeLock(forHomePath: String) -> NSRecursiveLock { gate }
}
enum CodexOfficialProfileReader {
    static func credentialIdentity(codexHomeURL: URL) -> Identity? { Harness.identity }
}
enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int) throws -> Data? {
        let data = try Data(contentsOf: url)
        return data.count <= maximumBytes ? data : nil
    }
}
struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ first: String, _ second: String) -> String { second }
}
final class SyntheticProfileStore {
    var calls = 0
    var received: [String] = []
    var expected: [String] = []
    var fail = false
    var profiles = ["a", "b"]
    func reorderProfiles(_ ids: [String], expectedCurrentOrder: [String]) throws {
        calls += 1; received = ids; expected = expectedCurrentOrder
        if fail { throw TokenMonitorFailure.invalidRequest }
        profiles = ids
    }
}
enum Harness {
    static var events = [String]()
    static var identity: Identity? = Identity()
    static var http: (TokenMonitorRequest) throws -> TokenMonitorResponse = { _ in throw TokenMonitorFailure.engineError }
    static var rpc: () -> CodexUsageReader.AppServerSnapshot = { .init() }
}
@main struct RoutingFixture {
    static func check(_ value: Bool, _ name: String) throws {
        if !value { print("FAIL " + name); throw TokenMonitorFailure.invalidResponse }
        print("PASS " + name)
    }
    static func response(_ request: TokenMonitorRequest, reset: Bool = false) throws -> TokenMonitorResponse {
        var provider: [String: TokenMonitorJSON] = ["provider": .string("codex"), "status": .string("ok"), "windows": .array([.object(["kind": .string("session"), "limitId": .string("codex"), "windowMinutes": .number(300), "usedPercent": .number(0)])])]
        if reset { provider["resetCredits"] = .object(["availableCount": .number(2)]) }
        let value = TokenMonitorResponse(schemaVersion: 1, requestId: request.requestId,
            engine: .init(repository: "Javis603/token-monitor", commit: TokenMonitorResponse.commit, version: "fixture"),
            collectedAt: "2026-09-13T00:00:00Z", timezone: "UTC", status: .ok,
            sources: [.init(id: "card-a", providerId: "codex", status: .ok, coverage: .known)],
            payload: .object(["limits": .object(["targets": .array([.object(["sourceId": .string("card-a"), "providerId": .string("codex"), "accountId": .string("card-a"), "snapshot": .object(["providers": .array([.object(provider)])])])])])]),
            coverage: .init(entries: [], days: [], cost: .unknown), errors: [])
        return try TokenMonitorResponse.decode(JSONEncoder().encode(value), request: request)
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("f2-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("auth.json")
        try Data("synthetic-inert-fixture".utf8).write(to: auth)
        let context = RuntimeLoadContext(homeDirectory: root.appendingPathComponent("user"), codexHomeDirectory: root, cacheDirectory: root)
        let profile = CodexProfile(codexHomeURL: root)
        let reader = CodexUsageReader()
        var messages = [String]()
        Harness.http = { try response($0) }
        var result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.quotaReadSucceeded && result.fiveHourQuota?.usedPercent == 0 && Harness.events == ["http", "rpc"]
            && result.auxiliaryReadStatus == .unavailable && messages.contains("auxiliary_unavailable"), "extracted route HTTP success RPC failure preserves quota")
        Harness.events = []; Harness.http = { try response($0, reset: true) }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.credits?.resetCredits == 2 && Harness.events == ["http"], "HTTP reset evidence avoids unconditional RPC")
        Harness.events = []; messages = []
        result = reader.readQuotaSnapshot(context: context, quotaOnly: false, messages: &messages, managedProfile: profile)
        try check(result.quotaReadSucceeded && result.credits?.resetCredits == 2
            && result.cloudLifetimeTokens == nil && messages.contains("auxiliary_unavailable")
            && Harness.events == ["http", "rpc"], "HTTP reset success full-load cloud auxiliary failure remains explicit")
        Harness.events = []; Harness.http = { _ in throw TokenMonitorFailure.engineError }
        Harness.rpc = {
            var value = CodexUsageReader.AppServerSnapshot()
            value.account = AccountInfo(type: "chatgpt", planType: nil, emailPresent: true, email: "synthetic-identity")
            value.quotaReadSucceeded = true
            return value
        }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.quotaReadSucceeded && result.engineFailureCode == .engineError
            && result.quotaProvenance == "same_home_rpc_fallback" && Harness.events == ["http", "rpc"], "engine failure explicit same-home RPC fallback reason")
        Harness.events = []
        _ = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages)
        try check(Harness.events == ["rpc"], "missing managed context preserves old login RPC route")
        let systemHome = context.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: systemHome, withIntermediateDirectories: true)
        let systemContext = RuntimeLoadContext(
            homeDirectory: context.homeDirectory, codexHomeDirectory: systemHome, cacheDirectory: root)
        var systemProfile = CodexProfile(codexHomeURL: systemHome)
        systemProfile.isSystemProfile = true
        Harness.events = []; messages = []
        _ = reader.readQuotaSnapshot(
            context: systemContext, quotaOnly: true, messages: &messages, managedProfile: systemProfile)
        try check(Harness.events == ["rpc"] && !messages.contains(TokenMonitorFailure.invalidSource.rawValue),
            "explicit system profile uses original system-home RPC route")
        Harness.events = []; messages = []
        _ = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: systemProfile)
        try check(Harness.events.isEmpty && messages.contains(TokenMonitorFailure.invalidSource.rawValue),
            "system profile cannot route an unrelated managed home to RPC")
        Harness.events = []
        _ = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, refreshingMembershipFor: profile, managedProfile: profile)
        try check(Harness.events == ["membership"], "membership preserves explicit refresh route")
        Harness.events = []; Harness.http = { request in
            try Data("synthetic-changed".utf8).write(to: auth)
            return try response(request)
        }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(!result.quotaReadSucceeded && Harness.events == ["http"], "auth-content mutation blocks result and fallback")
        Harness.events = []; Harness.http = { request in Harness.identity = Identity(email: "synthetic-other", accountID: "other"); return try response(request) }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(!result.quotaReadSucceeded && Harness.events == ["http"], "identity mutation blocks result and fallback")
        Harness.identity = Identity(); Harness.events = []
        let cancellation = TokenMonitorCancellation(); cancellation.cancel()
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile, cancellation: cancellation)
        try check(!result.quotaReadSucceeded && Harness.events.isEmpty, "cancelled route performs no transport")
        var cancelledContext = context
        let contextCancellation = TokenMonitorCancellation(); contextCancellation.cancel()
        cancelledContext.quotaCancellation = contextCancellation
        Harness.events = []
        result = reader.readQuotaSnapshot(context: cancelledContext, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(!result.quotaReadSucceeded && Harness.events.isEmpty,
            "managed context cancellation performs no transport")
        Harness.events = []
        var wrong = profile; wrong.codexHomeURL = root.appendingPathComponent("other")
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: wrong)
        try check(!result.quotaReadSucceeded && Harness.events.isEmpty, "wrong managed home performs no transport")
        Harness.events = []
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            CodexCredentialAccessGate.gate.lock(); entered.signal()
            release.wait(); CodexCredentialAccessGate.gate.unlock(); finished.signal()
        }
        entered.wait()
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages,
            requestTimeout: 0.05, managedProfile: profile)
        release.signal(); finished.wait()
        try check(!result.quotaReadSucceeded && Harness.events.isEmpty && messages.contains("timed_out"),
            "canonical home lock acquisition respects total deadline")
        let midCancellation = TokenMonitorCancellation()
        Harness.http = { request in midCancellation.cancel(); return try response(request) }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages,
            managedProfile: profile, cancellation: midCancellation)
        try check(!result.quotaReadSucceeded && Harness.events == ["http"], "cancellation after HTTP blocks publish and RPC")
        let lateContextCancellation = TokenMonitorCancellation()
        var lateContext = context
        lateContext.quotaCancellation = lateContextCancellation
        Harness.events = []; messages = []
        Harness.http = { request in lateContextCancellation.cancel(); return try response(request) }
        result = reader.readQuotaSnapshot(context: lateContext, quotaOnly: true, messages: &messages,
            managedProfile: profile)
        try check(!result.quotaReadSucceeded && Harness.events == ["http"]
            && messages.contains(TokenMonitorFailure.cancelled.rawValue),
            "managed context cancellation after HTTP blocks publish and RPC")
        let store = UsageStore()
        try check(store.reorderProfiles(["b", "a"], expectedCurrentOrder: ["a", "b"])
            && store.profileStore.calls == 1 && store.profiles == ["b", "a"]
            && store.profileStore.expected == ["a", "b"] && store.accountManagerMessage == "Account order saved.", "atomic wrapper forwards expected sequence exactly once and publishes success")
        store.profileStore.fail = true
        try check(!store.reorderProfiles(["a", "b"], expectedCurrentOrder: ["b", "a"])
            && store.profileStore.calls == 2 && store.profiles == ["b", "a"], "atomic wrapper error returns false without published mutation")
        store.engineCancellation = TokenMonitorCancellation()
        store.engineQuotaCancellation = TokenMonitorCancellation()
        let usageCancellation = store.engineCancellation!
        let quotaCancellation = store.engineQuotaCancellation!
        store.cancelStatisticsEngine()
        try check(usageCancellation.isCancelled && !quotaCancellation.isCancelled,
            "extracted statistics cancellation leaves independent quota batch alive")
        print("PASS all extracted routing fixtures")
    }
}
