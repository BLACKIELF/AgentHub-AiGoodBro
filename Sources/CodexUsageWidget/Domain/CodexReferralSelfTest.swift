import Foundation

@MainActor
enum CodexReferralSelfTest {
    private final class Transport: TokenMonitorHTTPTransport {
        var requests: [URLRequest] = []
        var replies: [Result<TokenMonitorHTTPResponse, Error>]
        init(_ replies: [Result<TokenMonitorHTTPResponse, Error>]) { self.replies = replies }
        func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> TokenMonitorHTTPResponse {
            requests.append(request)
            guard maximumResponseBytes == 1_048_576, !replies.isEmpty else { throw CodexReferralFailure.network }
            return try replies.removeFirst().get()
        }
        var postCount: Int { requests.filter { $0.httpMethod == "POST" }.count }
    }

    private static func response(_ object: [String: Any], status: Int = 200) -> Result<TokenMonitorHTTPResponse, Error> {
        .success(TokenMonitorHTTPResponse(statusCode: status, body: try! JSONSerialization.data(withJSONObject: object)))
    }

    private static func offer(amount: Double = 500, send: Int? = 5, reward: Int? = 5, shouldShow: Bool = true) -> [String: Any] {
        var result: [String: Any] = [
            "should_show": shouldShow, "offer_id": "credits_500", "requires_explicit_confirmation": true,
            "grants": [["recipient": "referrer", "grant_type": "personal_credits", "amount": amount]],
            "rules": ["Complete the official requirements."],
        ]
        if let send { result["remaining_send_capacity"] = send }
        if let reward { result["remaining_reward_capacity"] = reward }
        return result
    }

    static func run() async -> Bool {
        var failures: [String] = []
        func expect(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        func eligibility(_ object: [String: Any]) throws -> CodexReferralEligibility {
            try JSONDecoder().decode(CodexReferralEligibility.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = CodexProfile(
            id: "referral-fixture", name: "Referral fixture", codexHomePath: NSTemporaryDirectory(), isSystemProfile: false, createdAt: now,
            lastSnapshot: CodexAccountSnapshot(
                accountType: "chatgpt", planType: "plus", email: "sender@example.invalid", accountID: "fixture-account",
                limitId: nil, limitName: nil, fiveHour: nil, sevenDay: nil, monthly: nil, fetchedAt: now, appServerVersion: nil))
        let account = CodexReferralAccount(profile: profile, credentialHome: profile.codexHomeURL)
        let accounts: [String: Any] = [
            "accounts": [
                ["id": "other-fixture", "structure": "workspace"], ["id": "fixture-account", "structure": "personal"],
            ]
        ]
        let credential = CodexReferralCredentialReader.Value(token: "synthetic-referral-fixture", accountID: "fixture-account", data: Data("fixture".utf8))
        let read: CodexReferralClient.CredentialRead = { _, expected in
            guard expected == nil || expected == credential.data else { throw CodexReferralFailure.identityChanged }
            return credential
        }
        do {
            for amount in [250.0, 500, 1000, 750, 0] {
                expect(try eligibility(offer(amount: amount)).creditAmount == amount, "grant amount \(amount)")
            }
            for (name, amount) in [("credits_250", 250.0), ("credits_500", 500.0), ("credits_1000", 1000.0)] {
                expect(try eligibility(["should_show": true, "offer_id": name]).creditAmount == amount, "legacy \(name)")
            }
            expect(try eligibility(["should_show": true, "offer_id": "new_offer"]).creditAmount == nil, "unknown offer stays unknown")
            expect(
                try CodexReferralPresentation.reward(eligibility(["should_show": true, "offer_id": "none"]), language: .zh) == "当前无邀请点数奖励",
                "explicit no reward is distinct from unknown")
            expect(
                try eligibility(["should_show": true, "offer_id": "credits_1000", "grants": [["recipient": "invitee", "grant_type": "personal_credits", "amount": 250]]])
                    .creditAmount == nil, "invitee reward is not inviter reward")
            expect(
                try eligibility(["should_show": true, "grants": [["recipient": "referrer", "grant_type": "rate_limit_reset", "amount": 1]]]).creditAmount == nil,
                "reset reward is not credits")
            expect(try !eligibility(offer(send: nil)).canInvite, "missing send capacity blocks")
            expect(try !eligibility(offer(reward: nil)).canInvite, "missing reward capacity blocks")
            expect(try eligibility(offer(send: 4, reward: 2)).invitationCapacity == 2, "bounded capacity")
            expect(try !eligibility(offer(shouldShow: false)).canInvite, "ineligible account blocks")
            expect(CodexReferralPresentation.email(" friend@example.invalid ") == "friend@example.invalid", "trim recipient")
            for value in ["", "a@b", "a@example.invalid\nb@example.invalid", "a@example.invalid,b@example.invalid", "a@example.invalid\r\nX: injected"] {
                expect(CodexReferralPresentation.email(value) == nil, "invalid recipient rejected")
            }
            expect(!CodexReferralPresentation.publicText("account sender@example.invalid").contains("sender@example.invalid"), "public text masks emails")
            let context = try CodexReferralContext.parse(JSONSerialization.data(withJSONObject: accounts), accountID: credential.accountID)
            expect(context.programID == "codex_referral_consumer", "matches selected account structure")
            let initial = CodexReferralReview(context: context, eligibility: try eligibility(offer()), checkedAt: now)
            let transport = Transport([response(accounts), response(offer()), response(["invites": [["referral_id": "fixture-referral", "email": "friend@example.invalid"]]])])
            let client = CodexReferralClient(transport: transport, readCredential: read, validateNetwork: { nil })
            try await client.send(account, reviewed: initial, email: "friend@example.invalid", consent: true, language: .zh, currentAccount: { account })
            expect(transport.requests.count == 3 && transport.postCount == 1, "one send after fresh official checks")
            let post = transport.requests.last!
            let body = try JSONSerialization.jsonObject(with: post.httpBody!) as! [String: Any]
            expect(post.url?.absoluteString == "https://chatgpt.com/backend-api/referrals/invite", "allowlisted send URL")
            expect(body["program_id"] as? String == context.programID && body["entrypoint"] as? String == "persistent", "bound program and entrypoint")
            expect(body["emails"] as? [String] == ["friend@example.invalid"], "one user-entered recipient")
            expect(post.value(forHTTPHeaderField: "ChatGPT-Account-Id") == credential.accountID, "bound account header")
            expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "OpenAI-Internal-Referral-Eligibility-Preview") == nil }, "no eligibility preview override")

            func blocked(
                _ name: String, expected: CodexReferralFailure, replies: [Result<TokenMonitorHTTPResponse, Error>], consent: Bool = true, email: String = "friend@example.invalid",
                resolve: @escaping @MainActor () throws -> CodexReferralAccount = { account }
            ) async {
                let transport = Transport(replies)
                let client = CodexReferralClient(transport: transport, readCredential: read, validateNetwork: { nil })
                do {
                    try await client.send(account, reviewed: initial, email: email, consent: consent, language: .en, currentAccount: resolve)
                    failures.append(name + " unexpectedly succeeded")
                } catch { expect(error as? CodexReferralFailure == expected, name + " result") }
                expect(transport.postCount == 0, name + " no POST")
            }
            await blocked("invalid email", expected: .invalidEmail, replies: [], email: "invalid")
            await blocked("no consent", expected: .consentRequired, replies: [], consent: false)
            await blocked("offer changed", expected: .offerChanged, replies: [response(accounts), response(offer(amount: 250))])
            await blocked("capacity exhausted", expected: .capacityReached, replies: [response(accounts), response(offer(send: 0))])
            await blocked(
                "profile changed", expected: .identityChanged, replies: [response(accounts), response(offer())],
                resolve: {
                    CodexReferralAccount(profile: profile, credentialHome: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("changed-fixture"))
                })
            for (name, reply, expected) in [
                ("timeout", Result<TokenMonitorHTTPResponse, Error>.failure(CodexReferralFailure.network), CodexReferralFailure.deliveryUncertain),
                ("redirect", response([:], status: 307), .deliveryUncertain),
                ("server error", response([:], status: 503), .deliveryUncertain),
                ("empty acknowledgement", response(["invites": []]), .deliveryUncertain),
                ("malformed acknowledgement", response(["invites": [[:]]]), .deliveryUncertain),
                ("wrong recipient", response(["invites": [["referral_id": "fixture", "email": "other@example.invalid"]]]), .deliveryUncertain),
                ("expired session", response([:], status: 401), .loginRequired),
                ("limit", response([:], status: 429), .rateLimited),
                ("existing invitation", response([:], status: 409), .alreadyInvited),
            ] {
                let transport = Transport([response(accounts), response(offer()), reply])
                let client = CodexReferralClient(transport: transport, readCredential: read, validateNetwork: { nil })
                do {
                    try await client.send(account, reviewed: initial, email: "friend@example.invalid", consent: true, language: .zh, currentAccount: { account })
                    failures.append(name + " unexpectedly succeeded")
                } catch { expect(error as? CodexReferralFailure == expected, name + " result") }
                expect(transport.postCount == 1 && transport.requests.count == 3, name + " never replays")
            }
            let tracking = Transport([response(["items": [["referral_id": "fixture", "email": "friend@example.invalid"]]])])
            expect(
                try await CodexReferralClient(transport: tracking, readCredential: read, validateNetwork: { nil })
                    .recorded(account, context: context, email: "friend@example.invalid", language: .zh), "read-only reconciliation")
            expect(tracking.postCount == 0 && tracking.requests.first?.url?.path == "/backend-api/referrals/invite/tracking", "tracking does not resend")

            func finish(_ controller: CodexInviteController) async {
                let deadline = Date().addingTimeInterval(2)
                while controller.isBusy, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
                expect(!controller.isBusy, "controller fixture completes")
            }
            var routeReads = 0
            let beforeDispatch = Transport([response(accounts), response(offer()), response(accounts), response(offer())])
            let beforeClient = CodexReferralClient(
                transport: beforeDispatch, readCredential: read,
                validateNetwork: {
                    routeReads += 1
                    if routeReads == 5 { throw LocalProxyNetworkSettings.Failure.unavailable }
                    return nil
                })
            let beforeController = CodexInviteController(client: beforeClient)
            beforeController.load(account: account, resolve: { account }, language: .en)
            await finish(beforeController)
            beforeController.email = "friend@example.invalid"
            beforeController.send(account: account, resolve: { account }, consent: true, language: .en)
            await finish(beforeController)
            expect(beforeDispatch.requests.count == 4 && beforeDispatch.postCount == 0, "preflight failure never dispatches")
            expect(beforeController.uncertainEmail == nil && beforeController.notice == CodexReferralFailure.network.message(.en), "preflight failure stays retryable")
            let afterDispatch = Transport([response(accounts), response(offer()), response(accounts), response(offer()), .failure(CodexReferralFailure.network)])
            let afterController = CodexInviteController(client: CodexReferralClient(transport: afterDispatch, readCredential: read, validateNetwork: { nil }))
            afterController.load(account: account, resolve: { account }, language: .en)
            await finish(afterController)
            afterController.email = "friend@example.invalid"
            afterController.send(account: account, resolve: { account }, consent: true, language: .en)
            await finish(afterController)
            expect(afterDispatch.postCount == 1 && afterController.uncertainEmail != nil, "post-dispatch failure remains uncertain")

            func token(_ claims: [String: Any]) throws -> String {
                let bytes = try JSONSerialization.data(withJSONObject: claims)
                let payload = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return "fixture." + payload + ".fixture"
            }
            let identity: [String: Any] = ["email": "sender@example.invalid", "https://api.openai.com/auth": ["chatgpt_account_id": "fixture-account"]]
            var accessClaims = identity
            accessClaims["exp"] = now.timeIntervalSince1970 + 3_600
            let valid = try JSONSerialization.data(withJSONObject: [
                "tokens": [
                    "account_id": "fixture-account", "access_token": try token(accessClaims), "id_token": try token(identity),
                ]
            ])
            expect(try CodexReferralCredentialReader.validate(valid, profile: profile, now: now).accountID == "fixture-account", "valid recorded identity")
            var changed = profile
            changed.lastSnapshot = nil
            do {
                _ = try CodexReferralCredentialReader.validate(valid, profile: changed, now: now)
                failures.append("missing recorded identity accepted")
            } catch { expect(error as? CodexReferralFailure == .identityChanged, "missing recorded identity blocks") }
            accessClaims["exp"] = now.timeIntervalSince1970 - 1
            let expired = try JSONSerialization.data(withJSONObject: [
                "tokens": [
                    "account_id": "fixture-account", "access_token": try token(accessClaims), "id_token": try token(identity),
                ]
            ])
            do {
                _ = try CodexReferralCredentialReader.validate(expired, profile: profile, now: now)
                failures.append("expired session accepted")
            } catch { expect(error as? CodexReferralFailure == .loginRequired, "expired session blocks") }

            let frames = ["cards": CGRect(x: 0, y: 0, width: 300, height: 120), "announcements": CGRect(x: 312, y: 0, width: 300, height: 180)]
            expect(HomeResetMessageOrder.dropTarget(source: "cards", at: CGPoint(x: 400, y: 60), frames: frames) == "announcements", "drop over other block swaps")
            expect(HomeResetMessageOrder.dropTarget(source: "cards", at: CGPoint(x: 100, y: 60), frames: frames) == nil, "same block does not swap")
            expect(HomeResetMessageOrder.dropTarget(source: "cards", at: CGPoint(x: 305, y: 60), frames: frames) == nil, "drop in gap does not swap")
            expect(HomeResetMessageOrder.dropTarget(source: "external", at: CGPoint(x: 400, y: 60), frames: frames) == nil, "external drag rejected")
            expect(HomeResetMessageOrder.dropTarget(source: "cards", at: CGPoint(x: CGFloat.nan, y: 60), frames: frames) == nil, "invalid point rejected")
            let stacked = ["cards": CGRect(x: 0, y: 0, width: 300, height: 120), "announcements": CGRect(x: 0, y: 132, width: 300, height: 180)]
            expect(HomeResetMessageOrder.dropTarget(source: "cards", at: CGPoint(x: 100, y: 180), frames: stacked) == "announcements", "stacked blocks use same drop rules")
            expect(HomeResetMessageOrder.cardsFirst.swapped.blocks == ["announcements", "cards"], "both layouts use saved order")
            let suite = "AiGoodBro.ReferralSelfTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(HomeResetMessageOrder.announcementsFirst.rawValue, forKey: HomeResetMessageOrder.storageKey)
            expect(
                HomeResetMessageOrder(rawValue: UserDefaults(suiteName: suite)!.string(forKey: HomeResetMessageOrder.storageKey) ?? "") == .announcementsFirst, "layout persists")
        } catch { failures.append("fixture setup or success path failed") }
        failures.forEach { print("Referral self-test FAILED: \($0)") }
        print(
            failures.isEmpty
                ? "Referral self-test passed: rewards, consent, identity, bounded single send, unknown delivery, reconciliation and saved reset layout"
                : "Referral self-test failed")
        return failures.isEmpty
    }
}
