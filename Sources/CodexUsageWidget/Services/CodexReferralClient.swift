import CFNetwork
import Darwin
import Foundation

/// A referral belongs to this recorded account and its read-only session.
/// No credential refresh, account switch, recipient persistence or automatic send.
struct CodexReferralAccount: Identifiable {
    let profile: CodexProfile
    let credentialHome: URL
    var id: String { profile.id }

    func matches(_ other: Self) -> Bool {
        id == other.id && profile.recordedAccountKey == other.profile.recordedAccountKey
            && profile.lastSnapshot?.accountID == other.profile.lastSnapshot?.accountID
            && credentialHome.standardizedFileURL == other.credentialHome.standardizedFileURL
    }
}

struct CodexReferralContext: Equatable {
    let programID: String
    let entrypoint = "persistent"

    static func parse(_ data: Data, accountID: String) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accounts = object["accounts"] as? [[String: Any]],
            let account = accounts.first(where: { $0["id"] as? String == accountID })
        else { throw CodexReferralFailure.invalidResponse }
        switch (account["structure"] as? String)?.lowercased() {
        case "personal": return Self(programID: "codex_referral_consumer")
        case "workspace": return Self(programID: "codex_referral_workspace")
        default: throw CodexReferralFailure.unavailable
        }
    }
}

struct CodexReferralEligibility: Decodable, Equatable {
    struct Grant: Decodable, Equatable {
        let recipient: String
        let grantType: String
        let amount: Double?
        enum CodingKeys: String, CodingKey {
            case recipient, amount
            case grantType = "grant_type"
        }
    }

    let shouldShow: Bool
    let offerID: String?
    let title: String?
    let description: String?
    let rules: [String]
    let grants: [Grant]
    let remainingSendCapacity: Int?
    let remainingRewardCapacity: Int?
    let requiresExplicitConfirmation: Bool

    enum CodingKeys: String, CodingKey {
        case title, description, rules, grants
        case shouldShow = "should_show"
        case offerID = "offer_id"
        case remainingSendCapacity = "remaining_send_capacity"
        case remainingRewardCapacity = "remaining_reward_capacity"
        case requiresExplicitConfirmation = "requires_explicit_confirmation"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shouldShow = try values.decode(Bool.self, forKey: .shouldShow)
        offerID = try values.decodeIfPresent(String.self, forKey: .offerID)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        rules = try values.decodeIfPresent([String].self, forKey: .rules) ?? []
        grants = try values.decodeIfPresent([Grant].self, forKey: .grants) ?? []
        remainingSendCapacity = try values.decodeIfPresent(Int.self, forKey: .remainingSendCapacity)
        remainingRewardCapacity = try values.decodeIfPresent(Int.self, forKey: .remainingRewardCapacity)
        requiresExplicitConfirmation = try values.decodeIfPresent(Bool.self, forKey: .requiresExplicitConfirmation) ?? true
        guard rules.count <= 30, grants.count <= 30,
            grants.allSatisfy({ $0.amount == nil || ($0.amount!.isFinite && $0.amount! >= 0) }),
            remainingSendCapacity.map({ $0 >= 0 }) ?? true,
            remainingRewardCapacity.map({ $0 >= 0 }) ?? true
        else { throw CodexReferralFailure.invalidResponse }
    }

    var creditAmount: Double? {
        let creditGrants = grants.filter {
            $0.recipient == "referrer" && ["personal_credits", "workspace_credits"].contains($0.grantType)
        }
        if let amount = creditGrants.compactMap(\.amount).first(where: { $0 > 0 }) { return amount }
        if let amount = creditGrants.compactMap(\.amount).first { return amount }
        // The official client supports these older offers only when grants are absent.
        guard grants.isEmpty else { return nil }
        return ["credits_250": 250.0, "credits_500": 500.0, "credits_1000": 1000.0][offerID ?? ""]
    }

    var invitationCapacity: Int {
        var limit = min(5, remainingSendCapacity ?? 0)
        if !grants.isEmpty || (offerID != nil && offerID != "none") {
            limit = min(limit, remainingRewardCapacity ?? 0)
        }
        return max(0, limit)
    }

    var canInvite: Bool { shouldShow && invitationCapacity > 0 }

    func sameOffer(as other: Self) -> Bool {
        shouldShow == other.shouldShow && offerID == other.offerID && grants == other.grants
            && requiresExplicitConfirmation == other.requiresExplicitConfirmation
            && title == other.title && description == other.description && rules == other.rules
    }
}

struct CodexReferralReview {
    let context: CodexReferralContext
    let eligibility: CodexReferralEligibility
    let checkedAt: Date
}

enum CodexReferralFailure: Error, Equatable {
    case identityChanged, loginRequired, credentialsBusy, unavailable, invalidResponse
    case invalidEmail, consentRequired, capacityReached, offerChanged, alreadyInvited, permissionDenied, rateLimited
    case network, deliveryUncertain

    func message(_ language: WidgetLanguage) -> String {
        switch self {
        case .identityChanged:
            return language.text("账号或登录状态已改变，请关闭后重新打开邀请窗口。", "The account or session changed. Close and reopen the invitation window.")
        case .loginRequired:
            return language.text("此账号需要重新登录后才能读取或发送邀请。", "Sign in to this account again to read or send invitations.")
        case .credentialsBusy:
            return language.text("登录凭据正在更新，请稍后重试。", "Sign-in credentials are updating. Try again shortly.")
        case .unavailable:
            return language.text("官方暂未提供此账号的邀请活动。", "No referral offer is currently available for this account.")
        case .invalidResponse:
            return language.text("官方邀请信息未能核实，请刷新后重试。", "The official referral information could not be verified. Refresh and try again.")
        case .invalidEmail:
            return language.text("请检查邀请邮箱格式，每次最多 5 个。", "Check the recipient email addresses. Send up to 5 at a time.")
        case .consentRequired:
            return language.text("发送前请确认已征得好友同意。", "Confirm the recipient's consent before sending.")
        case .capacityReached:
            return language.text("可用邀请名额不足，请刷新后减少收件人数。", "Not enough invitation capacity. Refresh and reduce the number of recipients.")
        case .offerChanged:
            return language.text("官方活动内容已更新，请刷新并重新核对后发送。", "The official offer changed. Refresh and review it before sending.")
        case .alreadyInvited:
            return language.text("官方已存在此邮箱的邀请记录。", "An invitation for this address already exists in the official records.")
        case .permissionDenied:
            return language.text("官方未允许此账号发送邀请。", "The official service did not permit this account to send invitations.")
        case .rateLimited:
            return language.text("官方邀请频率已达限制，请稍后再试。", "The official invitation rate limit was reached. Try again later.")
        case .network:
            return language.text("邀请信息读取失败，请检查网络后刷新。", "Referral information could not be read. Check your connection and refresh.")
        case .deliveryUncertain:
            return language.text("发送结果未确认，请先核对邀请记录，避免重复发送。", "Delivery is unconfirmed. Check the invitation records before sending again.")
        }
    }
}

enum CodexReferralPresentation {
    static func email(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 254,
            value.range(of: #"^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$"#, options: .regularExpression) != nil,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    static func publicText(_ text: String) -> String {
        String(text.prefix(2_048)).replacingOccurrences(
            of: #"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+"#, with: "•••", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func reward(_ eligibility: CodexReferralEligibility, language: WidgetLanguage) -> String {
        guard eligibility.shouldShow else { return language.text("暂未开放邀请奖励", "Referral rewards are not available now") }
        guard let amount = eligibility.creditAmount else {
            if eligibility.offerID == "none", eligibility.grants.isEmpty {
                return language.text("当前无邀请点数奖励", "No invitation credit reward for this account now")
            }
            return language.text("官方未显示邀请点数", "The official offer does not show invitation credits")
        }
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        let value = formatter.string(from: NSNumber(value: amount)) ?? String(amount)
        return language.text("每次符合条件的邀请：\(value) 点", "\(value) credits per qualifying invitation")
    }
}

enum CodexReferralCredentialReader {
    struct Value {
        let token: String
        let accountID: String
        let data: Data
    }

    static func read(_ account: CodexReferralAccount, now: Date = Date(), expectedData: Data? = nil) throws -> Value {
        let home = account.credentialHome.standardizedFileURL
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let system = userHome.appendingPathComponent(".codex", isDirectory: true).standardizedFileURL
        let root = userHome.appendingPathComponent(".codex-account-manager-next/profiles", isDirectory: true).standardizedFileURL
        let managedHome = account.profile.codexHomeURL.standardizedFileURL
        guard home.isFileURL, home.path == CodexCredentialTransaction.canonical(home).path,
            home == managedHome || home == system,
            home == system || home.deletingLastPathComponent() == root,
            account.profile.isSystemProfile ? managedHome == system : managedHome.deletingLastPathComponent() == root
        else { throw CodexReferralFailure.identityChanged }
        return try readSnapshot(home: home, profile: account.profile, now: now, expectedData: expectedData)
    }

    // Writers atomically replace auth.json. A bounded, stable file snapshot is
    // sufficient for this read-only operation; waiting on the global quota lock
    // couples unrelated accounts and can block the invitation UI for seconds.
    static func readSnapshot(home: URL, profile: CodexProfile, now: Date, expectedData: Data? = nil) throws -> Value {
        var info = stat()
        let file = home.appendingPathComponent("auth.json")
        var before = stat()
        guard lstat(home.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
            lstat(file.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
            let data = try CodexCredentialTransaction.read(file)
        else { throw CodexReferralFailure.identityChanged }
        let result = try validate(data, profile: profile, now: now)
        // A normal refresh may rotate token bytes while keeping the same
        // recorded identity. A different account must still fail closed.
        if let expectedData {
            guard
                CodexOfficialProfileReader.credentialIdentity(fromAuthData: expectedData)
                    == CodexOfficialProfileReader.credentialIdentity(fromAuthData: data)
            else { throw CodexReferralFailure.identityChanged }
        }
        var after = stat()
        guard lstat(file.path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            try CodexCredentialTransaction.read(file) == data,
            home.isFileURL, CodexCredentialTransaction.canonical(home).path == home.path
        else { throw CodexReferralFailure.credentialsBusy }
        return result
    }

    static func validate(_ data: Data, profile: CodexProfile, now: Date) throws -> Value {
        guard let expectedID = profile.lastSnapshot?.accountID, !expectedID.isEmpty,
            expectedID.utf8.count <= 256, !expectedID.contains("\n"), !expectedID.contains("\r"),
            let expectedEmail = profile.lastSnapshot?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !expectedEmail.isEmpty,
            let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: data),
            identity.accountID == expectedID, identity.email == expectedEmail,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any], let token = tokens["access_token"] as? String,
            !token.isEmpty, token.utf8.count <= 32_768, !token.contains("\n"), !token.contains("\r")
        else { throw CodexReferralFailure.identityChanged }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw CodexReferralFailure.loginRequired }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
            let claims = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let expiry = claims["exp"] as? Double, expiry.isFinite, expiry > now.timeIntervalSince1970 + 60
        else { throw CodexReferralFailure.loginRequired }
        return Value(token: token, accountID: identity.accountID, data: data)
    }
}

final class CodexReferralClient {
    typealias CredentialRead = (CodexReferralAccount, Data?) throws -> CodexReferralCredentialReader.Value
    private let transport: TokenMonitorHTTPTransport?
    private let readCredential: CredentialRead
    private let validateNetwork: () throws -> String?

    init(
        transport: TokenMonitorHTTPTransport? = nil,
        readCredential: @escaping CredentialRead = { try CodexReferralCredentialReader.read($0, expectedData: $1) },
        validateNetwork: @escaping () throws -> String? = { try LocalProxyNetworkSettings.load() }
    ) {
        self.transport = transport
        self.readCredential = readCredential
        self.validateNetwork = validateNetwork
    }

    func load(_ account: CodexReferralAccount, language: WidgetLanguage) async throws -> CodexReferralReview {
        let (review, _) = try await loadBound(account, language: language)
        return review
    }

    private func loadBound(_ account: CodexReferralAccount, language: WidgetLanguage) async throws -> (CodexReferralReview, CodexReferralCredentialReader.Value) {
        var credential = try readCredential(account, nil)
        let accounts = try await get("/wham/accounts/check", credential: credential, language: language)
        let context = try CodexReferralContext.parse(accounts, accountID: credential.accountID)
        credential = try readCredential(account, credential.data)
        let data = try await get(
            "/referrals/invite/eligibility", query: ["program_id": context.programID, "entrypoint": context.entrypoint],
            credential: credential, language: language)
        credential = try readCredential(account, credential.data)
        guard let eligibility = try? JSONDecoder().decode(CodexReferralEligibility.self, from: data) else {
            throw CodexReferralFailure.invalidResponse
        }
        return (CodexReferralReview(context: context, eligibility: eligibility, checkedAt: Date()), credential)
    }

    func send(
        _ account: CodexReferralAccount, reviewed: CodexReferralReview, email: String, consent: Bool, language: WidgetLanguage,
        currentAccount: @escaping @MainActor () throws -> CodexReferralAccount
    ) async throws {
        guard let recipient = CodexReferralPresentation.email(email) else { throw CodexReferralFailure.invalidEmail }
        let result = try await sendBatch(account, reviewed: reviewed, emails: [recipient], consent: consent, language: language, currentAccount: currentAccount)
        guard result.sent.count == 1, result.failed.isEmpty, result.uncertain.isEmpty else { throw CodexReferralFailure.deliveryUncertain }
    }

    func sendBatch(
        _ account: CodexReferralAccount, reviewed: CodexReferralReview, emails: [String], consent: Bool, language: WidgetLanguage,
        currentAccount: @escaping @MainActor () throws -> CodexReferralAccount
    ) async throws -> CodexReferralBatchResult {
        guard !emails.isEmpty, emails.count <= 5, emails.allSatisfy({ CodexReferralPresentation.email($0) == $0 }),
            Set(emails.map { $0.lowercased() }).count == emails.count
        else { throw CodexReferralFailure.invalidEmail }
        guard reviewed.eligibility.canInvite else { throw CodexReferralFailure.capacityReached }
        guard emails.count <= reviewed.eligibility.invitationCapacity else { throw CodexReferralFailure.capacityReached }
        guard !reviewed.eligibility.requiresExplicitConfirmation || consent else { throw CodexReferralFailure.consentRequired }
        let (fresh, loadedCredential) = try await loadBound(account, language: language)
        guard fresh.context == reviewed.context, fresh.eligibility.sameOffer(as: reviewed.eligibility) else {
            throw CodexReferralFailure.offerChanged
        }
        guard fresh.eligibility.canInvite, emails.count <= fresh.eligibility.invitationCapacity else { throw CodexReferralFailure.capacityReached }
        guard try await currentAccount().matches(account) else { throw CodexReferralFailure.identityChanged }
        let credential = try readCredential(account, loadedCredential.data)
        var request = try request("/referrals/invite", credential: credential, language: language)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "program_id": fresh.context.programID, "entrypoint": fresh.context.entrypoint, "emails": emails,
        ])
        // The transport never retries. A timeout, redirect or malformed success
        // after this dispatch is an unknown result, never permission to replay.
        let route = try validateNetwork()
        let response: TokenMonitorHTTPResponse
        do { response = try await send(request, route: route) } catch { throw CodexReferralFailure.deliveryUncertain }
        if response.statusCode >= 500 || (300..<400).contains(response.statusCode) {
            throw CodexReferralFailure.deliveryUncertain
        }
        let result: CodexReferralBatchResult
        if [400, 422].contains(response.statusCode), let rejected = try CodexReferralBatchResult.parseRejection(response.body, recipients: emails) {
            result = rejected
        } else {
            try checkStatus(response)
            do { result = try CodexReferralBatchResult.parse(response.body, recipients: emails) } catch { throw CodexReferralFailure.deliveryUncertain }
        }
        do {
            guard try await currentAccount().matches(account) else { throw CodexReferralFailure.identityChanged }
            _ = try readCredential(account, credential.data)
        } catch { throw CodexReferralFailure.deliveryUncertain }
        // A recorded invitation is the server acknowledgement. It is not proof
        // that the recipient qualified or that a reward was credited.
        return result
    }

    func historyPage(
        _ account: CodexReferralAccount, context: CodexReferralContext? = nil, period: CodexReferralPeriod, cursor: String? = nil, language: WidgetLanguage
    ) async throws -> CodexReferralPage {
        var credential = try readCredential(account, nil)
        let selectedContext: CodexReferralContext
        if let context {
            selectedContext = context
        } else {
            let data = try await get("/wham/accounts/check", credential: credential, language: language)
            selectedContext = try CodexReferralContext.parse(data, accountID: credential.accountID)
            credential = try readCredential(account, credential.data)
        }
        var query = ["program_id": selectedContext.programID, "period": period.rawValue, "limit": "100"]
        if let cursor {
            guard !cursor.isEmpty, cursor.utf8.count <= 2048 else { throw CodexReferralFailure.invalidResponse }
            query["cursor"] = cursor
        }
        let data = try await get("/referrals/invite/tracking", query: query, credential: credential, language: language)
        _ = try readCredential(account, credential.data)
        let page = try CodexReferralPage.parse(data)
        guard page.cursor == nil || page.cursor != cursor else { throw CodexReferralFailure.invalidResponse }
        return page
    }

    func recorded(_ account: CodexReferralAccount, context: CodexReferralContext, email: String, language: WidgetLanguage) async throws -> Bool {
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<3 {
            let page = try await historyPage(account, context: context, period: .past90Days, cursor: cursor, language: language)
            if page.items.contains(where: { $0.email?.lowercased() == email.lowercased() }) { return true }
            guard let next = page.cursor else { return false }
            guard seen.insert(next).inserted else { throw CodexReferralFailure.invalidResponse }
            cursor = next
        }
        return false
    }

    private func get(
        _ path: String, query: [String: String] = [:], credential: CodexReferralCredentialReader.Value, language: WidgetLanguage
    ) async throws -> Data {
        let route = try validateNetwork()
        let response: TokenMonitorHTTPResponse
        do { response = try await send(try request(path, query: query, credential: credential, language: language), route: route) } catch { throw CodexReferralFailure.network }
        try checkStatus(response)
        return response.body
    }

    private func request(
        _ path: String, query: [String: String] = [:], credential: CodexReferralCredentialReader.Value, language: WidgetLanguage
    ) throws -> URLRequest {
        guard ["/wham/accounts/check", "/referrals/invite/eligibility", "/referrals/invite", "/referrals/invite/tracking"].contains(path) else {
            throw CodexReferralFailure.invalidResponse
        }
        var url = URLComponents(string: "https://chatgpt.com/backend-api" + path)!
        if !query.isEmpty { url.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
        request.setValue(language.rawValue, forHTTPHeaderField: "OAI-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest, route: String?) async throws -> TokenMonitorHTTPResponse {
        if let transport { return try await transport.send(request, maximumResponseBytes: 1_048_576) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        if let route, let url = URL(string: route), let host = url.host, let port = url.port {
            if url.scheme == "socks5" {
                configuration.connectionProxyDictionary = [
                    kCFNetworkProxiesSOCKSEnable as String: 1, kCFNetworkProxiesSOCKSProxy as String: host, kCFNetworkProxiesSOCKSPort as String: port,
                ]
            } else {
                configuration.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: host, kCFNetworkProxiesHTTPSPort as String: port,
                ]
            }
        }
        return try await TokenMonitorURLSessionTransport(configuration: configuration).send(request, maximumResponseBytes: 1_048_576)
    }

    private func checkStatus(_ response: TokenMonitorHTTPResponse) throws {
        if (200..<300).contains(response.statusCode) { return }
        switch response.statusCode {
        case 401: throw CodexReferralFailure.loginRequired
        case 403: throw CodexReferralFailure.permissionDenied
        case 409: throw CodexReferralFailure.alreadyInvited
        case 429: throw CodexReferralFailure.rateLimited
        case 400, 422:
            if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] {
                let detail = object["detail"]
                let message = (detail as? String) ?? (detail as? [String: Any])?["message"] as? String ?? ""
                if message.range(of: "already", options: .caseInsensitive) != nil,
                    message.range(of: #"referral|invite"#, options: [.regularExpression, .caseInsensitive]) != nil
                {
                    throw CodexReferralFailure.alreadyInvited
                }
            }
            throw CodexReferralFailure.invalidEmail
        default: throw CodexReferralFailure.unavailable
        }
    }
}
