import Foundation

enum TokenMonitorHostSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        func accepts(_ json: String) -> Bool { (try? TokenMonitorHostRequest.decode(Data(json.utf8))) != nil }
        expect(TokenMonitorDesktopController.validatedTotalCostUSD(19755.13) == 19755.13, "desktop cumulative cost stays exact")
        expect(TokenMonitorDesktopController.validatedTotalCostUSD(0) == 0, "recorded desktop zero cost is retained")
        for value: Double? in [nil, -.infinity, .infinity, .nan, -1] {
            expect(TokenMonitorDesktopController.validatedTotalCostUSD(value) == nil, "missing or invalid desktop cost stays unavailable")
        }
        let key = "sha256:b064f8f87a3fa626af7a4e92491a833119e18fdc9a7729ed1cfd16d8c328f751"
        // Expected bytes were produced by the pinned upstream codexAuthIdentity.
        expect(TokenMonitorHostIdentity.accountKey(email: " Fixture@Example.com ", accountID: "Workspace-A") == key, "upstream composite identity hash parity")
        expect(TokenMonitorHostIdentity.accountKey(email: "fixture@example.com", accountID: nil) == nil, "email-only identity cannot select a Desktop account")
        expect(TokenMonitorHostIdentity.accountKey(email: "fixture@example.com\0", accountID: "Workspace-A") == nil, "delimiter injection rejected")
        expect(TokenMonitorHostIdentity.accountKey(email: "fixture@example.com", accountID: "Workspace-B") != key, "same member in another workspace stays distinct")
        expect(accepts(#"{"id":"test-1","cmd":"openWorkbench"}"#), "native workspace entry allowed")
        expect(accepts(#"{"id":"dock","cmd":"openEdgeDockSettings"}"#), "native edge dock settings entry allowed")
        expect(
            accepts("{\"id\":\"test-2\",\"cmd\":\"switchCodexAccount\",\"vendorAccountId\":\"fixture\",\"recordedAccountKey\":\"\(key)\"}"),
            "switch requires vendor ID and hashed composite identity")
        for invalid in [
            #"{"id":"test","cmd":"exec","path":"/bin/sh"}"#,
            #"{"id":"test","cmd":"openAccounts","path":"/tmp/auth.json"}"#,
            #"{"id":"test","cmd":"switchCodexAccount","vendorAccountId":"fixture","recordedAccountKey":"fixture@example.com"}"#,
            #"{"id":"test","cmd":"switchCodexAccount","vendorAccountId":"fixture"}"#,
            #"{"id":"../other","cmd":"quitHost"}"#,
            String(repeating: " ", count: 4097),
        ] { expect(!accepts(invalid), "malformed/extra/credential-bearing IPC is rejected") }

        func profile(_ id: String, workspace: String = "workspace-a", system: Bool = false) -> CodexProfile {
            CodexProfile(
                id: id, name: "Fixture", codexHomePath: "/nonexistent/aigoodbro-fixture", isSystemProfile: system, createdAt: .distantPast,
                lastSnapshot: CodexAccountSnapshot(
                    accountType: "chatgpt", planType: "plus", email: "fixture@example.com", accountID: workspace,
                    limitId: nil, limitName: nil, fiveHour: nil, sevenDay: nil, monthly: nil, fetchedAt: .distantPast, appServerVersion: nil))
        }
        expect(
            TokenMonitorHostIdentity.uniqueProfile(for: key, profiles: [profile("system", system: true), profile("target"), profile("other", workspace: "workspace-b")])?.id
                == "target", "only one exact managed profile matches")
        expect(TokenMonitorHostIdentity.uniqueProfile(for: key, profiles: [profile("one"), profile("two")]) == nil, "ambiguous managed profiles fail closed")
        expect(TokenMonitorHostIdentity.uniqueProfile(for: key, profiles: [profile("system", system: true)]) == nil, "system profile is never inferred as a managed target")
        if failures.isEmpty { print("Token Monitor host contract self-test passed") } else { failures.forEach { print("FAIL: \($0)") } }
        return failures.isEmpty
    }
}
