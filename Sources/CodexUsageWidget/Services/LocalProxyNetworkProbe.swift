import Foundation

/// Fixed official origin and explicit local destinations only. Response bodies
/// and bearer credentials never become user-visible diagnostics.
enum LocalProxyNetworkProbe {
    static func official(token: String, accountID: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        let response = try await TokenMonitorURLSessionTransport().send(request, maximumResponseBytes: 262144)
        if response.statusCode == 401 || response.statusCode == 403 { return "unauthorized" }
        guard response.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            object["rate_limit"] is [String: Any] || object["plan_type"] is String
        else { return "unreachable" }
        return "reachable"
    }

    static func models(endpoint: String, key: String) async throws -> Bool {
        guard let url = URL(string: endpoint + "/models"), url.scheme == "http", url.host == "127.0.0.1", url.path == "/v1/models", url.user == nil, url.query == nil else {
            return false
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let response = try await localTransport().send(request, maximumResponseBytes: 262144)
        guard response.statusCode == 200, let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            object["object"] as? String == "list", let models = object["data"] as? [[String: Any]], !models.isEmpty
        else { return false }
        return models.allSatisfy { ($0["id"] as? String)?.isEmpty == false }
    }

    static func selectorNodes(settings: LocalProxyEgressSettings) async throws -> [String] {
        guard settings.isValid, let url = URL(string: settings.mihomoAPI + "/proxies") else { throw LocalProxyFailure.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        if !settings.mihomoSecret.isEmpty { request.setValue("Bearer " + settings.mihomoSecret, forHTTPHeaderField: "Authorization") }
        let response = try await localTransport().send(request, maximumResponseBytes: 1_048_576)
        guard response.statusCode == 200, let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let proxies = object["proxies"] as? [String: Any], let group = proxies[settings.group] as? [String: Any],
            group["type"] as? String == "Selector", let members = group["all"] as? [String], members.count <= 10000
        else { throw LocalProxyFailure.unavailable }
        // mihomo AdapterType.String values: only leaf transports are candidates.
        let excludedTypes: Set<String> = [
            "Direct", "Reject", "RejectDrop", "Compatible", "Pass", "PassRule", "Rematch", "Dns", "Unknown",
            "Relay", "Selector", "Fallback", "URLTest", "LoadBalance",
        ]
        var seen: Set<String> = []
        return members.filter { name in
            guard !name.isEmpty, name.utf8.count <= 512, name.trimmingCharacters(in: .whitespacesAndNewlines) == name,
                !name.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }),
                !isHongKongNode(name), let node = proxies[name] as? [String: Any], node["all"] == nil,
                let type = node["type"] as? String, !type.isEmpty, !excludedTypes.contains(type)
            else { return false }
            return seen.insert(name).inserted
        }
    }

    static func isHongKongNode(_ name: String) -> Bool {
        if name.contains("香港") || name.contains("港区") || name.contains("港澳") || name.contains("🇭🇰") { return true }
        return name.range(
            of: #"hong[\s._-]*kong|(^|[^a-z])hkg?([0-9]+)?($|[^a-z])|(^|[\s\[（(【_./|·-])港([0-9]|$|[\s\]）)】_./|·-])"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func localTransport() -> TokenMonitorURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return TokenMonitorURLSessionTransport(configuration: configuration)
    }
}
