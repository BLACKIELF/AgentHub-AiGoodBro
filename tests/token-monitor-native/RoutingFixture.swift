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
    static func response(_ request: TokenMonitorRequest, reset: Bool = false, completeCredits: Bool = false, plan: String? = nil, weeklyOnly: Bool = false,
                         resetDates: Bool = true) throws -> TokenMonitorResponse {
        var provider: [String: TokenMonitorJSON] = ["provider": .string("codex"), "status": .string("ok"), "windows": .array([.object(["kind": .string("session"), "limitId": .string("codex"), "windowMinutes": .number(300), "usedPercent": .number(0)])])]
        if let plan { provider["planType"] = .string(plan) }
        if weeklyOnly {
            provider["windows"] = .array([.object([
                "kind": .string("weekly"), "limitId": .string("codex"),
                "windowMinutes": .number(10080), "usedPercent": .number(0)])])
        }
        if reset {
            var summary: [String: TokenMonitorJSON] = ["availableCount": .number(2)]
            if resetDates { summary["expirations"] = .array([.string("2026-12-01T01:00:00Z"), .string("2026-11-20T02:30:00.000Z")]) }
            provider["resetCredits"] = .object(summary)
        }
        if completeCredits { provider["credits"] = .object([
            "hasCredits": .bool(true), "unlimited": .bool(false), "balance": .string("2240.36")]) }
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
        Harness.events = []; Harness.http = { try response($0, reset: true, plan: "prolite", weeklyOnly: true) }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.quotaReadSucceeded && result.account?.planType == "prolite"
            && result.fiveHourQuota == nil && result.sevenDayQuota?.usedPercent == 0
            && Harness.events == ["http", "rpc"], "weekly-only Pro 5x keeps fresh machine plan while backfilling balance")
        Harness.events = []; Harness.http = { try response($0, plan: "prolite", weeklyOnly: true) }
        Harness.rpc = {
            var value = CodexUsageReader.AppServerSnapshot()
            value.account = AccountInfo(type: "chatgpt", planType: nil, emailPresent: true, email: "synthetic-identity")
            return value
        }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.account?.planType == "prolite" && Harness.events == ["http", "rpc"],
            "same-identity auxiliary response missing plan cannot erase fresh engine plan")
        Harness.rpc = { .init() }
        Harness.events = []; Harness.http = { try response($0, reset: true) }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.credits?.resetCredits == 2 && result.credits?.resetCreditExpiries?.count == 2
            && result.credits?.balance == nil && Harness.events == ["http", "rpc"], "reset count and dates cannot mask a missing balance")
        Harness.events = []; Harness.http = { try response($0, reset: true, completeCredits: true) }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.credits?.balance == "2240.36" && result.credits?.resetCreditDetails == nil
            && result.credits?.resetCreditExpiries?.count == 2 && Harness.events == ["http"],
            "complete HTTP credit and expiry evidence avoids unnecessary RPC and synthetic card IDs")
        Harness.events = []; Harness.http = { try response($0, reset: true) }
        Harness.rpc = {
            var value = CodexUsageReader.AppServerSnapshot()
            value.account = AccountInfo(type: "chatgpt", planType: nil, emailPresent: true, email: "synthetic-identity")
            value.quotaReadSucceeded = true
            value.credits = CreditsInfo(hasCredits: true, unlimited: false, balance: "2240.36", resetCredits: nil, resetCreditDetails: nil)
            return value
        }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.credits?.balance == "2240.36" && result.credits?.resetCredits == 2
            && result.credits?.resetCreditExpiries?.count == 2 && result.auxiliaryReadStatus == .legacyRPC
            && Harness.events == ["http", "rpc"], "same-identity RPC supplements balance without losing HTTP expiry dates")
        let validRPC = Harness.rpc
        Harness.events = []; Harness.rpc = {
            var value = validRPC()
            value.credits = CreditsInfo(hasCredits: true, unlimited: false, balance: "2240.36", resetCredits: 2, resetCreditDetails: [])
            return value
        }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.credits?.resetCreditExpiries?.count == 2 && result.credits?.resetCreditDetails?.isEmpty == true,
            "RPC with no detailed card dates retains same-count engine display dates without inventing identities")
        Harness.events = []; Harness.rpc = {
            var value = validRPC()
            value.account = AccountInfo(type: "chatgpt", planType: nil, emailPresent: true, email: "synthetic-other")
            return value
        }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.quotaReadSucceeded && result.credits?.balance == nil && result.credits?.resetCreditExpiries?.count == 2,
            "another account's RPC balance is never merged into HTTP quota")
        Harness.events = []; Harness.rpc = { var value = validRPC(); value.quotaReadSucceeded = false; return value }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.credits?.balance == nil && result.credits?.resetCredits == 2,
            "unconfirmed RPC quota cannot publish a spendable balance")
        Harness.events = []; Harness.rpc = {
            var value = validRPC()
            value.credits = CreditsInfo(hasCredits: true, unlimited: false, balance: "2240.36", resetCredits: 1, resetCreditDetails: nil)
            return value
        }
        result = reader.readQuotaSnapshot(context: context, quotaOnly: true, messages: &messages, managedProfile: profile)
        try check(result.credits?.resetCredits == 1 && result.credits?.resetCreditExpiries == nil,
            "changed card count invalidates earlier unbound expiry dates")
        try resetCreditBackfillRoutes(reader: reader, context: context, profile: profile)
        Harness.rpc = { .init() }
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

    static func resetCreditBackfillRoutes(reader: CodexUsageReader, context: RuntimeLoadContext, profile: CodexProfile) throws {
        let previousHTTP = Harness.http
        let previousRPC = Harness.rpc
        defer { Harness.http = previousHTTP; Harness.rpc = previousRPC }
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let card: [String: Any] = [
            "id": "synthetic-reset-card", "status": "available", "resetType": "codexRateLimits",
            "expiresAt": Int64(expiry.timeIntervalSince1970),
        ]
        func rpc(_ summary: [String: Any]?, accountID: Any? = "synthetic-account", email: String = "synthetic-identity",
                 hasLimits: Bool = true) -> CodexUsageReader.AppServerSnapshot {
            var payload: [String: Any] = [:]
            payload["accountId"] = accountID
            payload["rateLimitResetCredits"] = summary
            if hasLimits {
                payload["rateLimits"] = [
                    "limitId": "codex", "primary": ["usedPercent": 20, "windowDurationMins": 120],
                    "credits": ["hasCredits": true, "unlimited": true, "balance": "99999"],
                ] as [String: Any]
            }
            var snapshot = CodexUsageReader.AppServerSnapshot()
            reader.parseRateLimits(payload, into: &snapshot)
            snapshot.account = .init(type: "chatgpt", planType: nil, emailPresent: true, email: email)
            return snapshot
        }
        func read(quotaOnly: Bool = true) -> CodexUsageReader.AppServerSnapshot {
            var messages: [String] = []
            return reader.readQuotaSnapshot(context: context, quotaOnly: quotaOnly, messages: &messages, managedProfile: profile)
        }
        Harness.http = { try response($0, reset: true, completeCredits: true, resetDates: false) }
        Harness.rpc = { rpc(["availableCount": 1, "credits": [card]]) }
        let current = read()
        try check(current.credits?.resetCredits == 1 && current.credits?.resetCreditExpiries == [expiry]
            && current.credits?.balance == "2240.36" && current.credits?.unlimited == false
            && current.quotaReadSucceeded && current.fiveHourQuota?.usedPercent == 0
            && current.quotaProvenance == "engine" && current.auxiliaryReadStatus == .upstreamResetCredits,
            "actual route supplements same-account cards despite unknown RPC quota without replacing balance or engine quota")
        Harness.rpc = { rpc(["availableCount": 1, "credits": [card]], hasLimits: false) }
        try check(read().credits?.resetCreditExpiries == [expiry], "card-only RPC response can supplement bound engine quota")
        for accountID in [nil, NSNull(), "", "other-account"] as [Any?] {
            Harness.rpc = { rpc(["availableCount": 1, "credits": [card]], accountID: accountID) }
            let value = read()
            try check(value.credits?.resetCredits == 2 && value.credits?.resetCreditExpiries == nil
                && value.credits?.balance == "2240.36", "missing or wrong RPC account ID cannot enter reset-only route")
        }
        Harness.rpc = { rpc(["availableCount": 1, "credits": [card]], email: "other-identity") }
        try check(read().credits?.resetCreditExpiries == nil, "exact RPC account ID cannot bypass account-read email matching")
        var malformed = card
        malformed["expiresAt"] = "not-an-epoch"
        Harness.rpc = { rpc(["availableCount": 1, "credits": [malformed]]) }
        try check(read().credits?.resetCredits == 2 && read().credits?.resetCreditExpiries == nil,
            "malformed RPC reset dates preserve count-only engine evidence")
        Harness.rpc = { .init() }
        try check(read().credits?.resetCredits == 2 && read().credits?.resetCreditExpiries == nil,
            "RPC failure or timeout without a parsed response cannot manufacture reset evidence")
        Harness.rpc = { rpc(nil) }
        try check(read().credits?.resetCredits == 2 && read().credits?.resetCreditExpiries == nil,
            "unknown RPC reset summary cannot replace known engine count")
        Harness.rpc = { rpc(["availableCount": 0, "credits": NSNull()]) }
        let zero = read()
        try check(zero.credits?.resetCredits == 0 && zero.credits?.resetCreditExpiries == [] && zero.credits?.balance == "2240.36",
            "verified zero cards clear dates without losing spendable balance")
        Harness.http = { try response($0, reset: true, completeCredits: true) }
        Harness.rpc = { rpc(["availableCount": 2, "credits": NSNull()]) }
        try check(read(quotaOnly: false).credits?.resetCreditExpiries?.count == 2,
            "same-count null RPC details preserve independently reported dates")
        Harness.rpc = { rpc(["availableCount": 1, "credits": NSNull()]) }
        try check(read(quotaOnly: false).credits?.resetCreditExpiries == nil,
            "changed-count null RPC details clear earlier dates")
        Harness.rpc = { rpc(["availableCount": 2, "credits": []]) }
        try check(read(quotaOnly: false).credits?.resetCreditExpiries == [],
            "explicit empty RPC details cannot revive old dates on the reset-only route")
    }
}
