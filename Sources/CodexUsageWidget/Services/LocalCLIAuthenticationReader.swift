import Foundation
import Security

/// Local configuration evidence only. It never sends inference requests, changes
/// credentials, or treats unavailable subscription quota as a failed sign-in.
enum LocalCLIAuthentication: Equatable {
    case unknown, oauth, apiKey
    case providers(Int)

    var isConfigured: Bool { self != .unknown }
    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .unknown: return language.text("登录配置待检测", "Check sign-in configuration")
        case .oauth: return language.text("已保存登录凭据", "Sign-in credentials saved")
        case .apiKey: return language.text("已配置 API Key", "API key configured")
        case .providers(let count): return language.text("已配置 \(count) 个服务商", "\(count) providers configured")
        }
    }
}

struct LocalCLIAuthenticationReader {
    var fileReader: (URL) -> Data? = {
        try? DispatchParticipationSync.readBoundedRegularFile($0, maximumBytes: 1024 * 1024, allowMissing: true)
    }
    var keychainReader: (String, String?) -> Data? = Self.keychainData

    func read(_ profile: LocalCLIProfile) -> LocalCLIAuthentication {
        let root = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
        let usesSystemKeychain =
            profile.isDefault
            && root.standardizedFileURL == profile.kind.defaultConfigDirectory(home: FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
        func object(_ path: String) -> [String: Any] {
            guard let data = fileReader(root.appendingPathComponent(path)),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return value
        }
        switch profile.kind {
        case .gemini:
            let settings = object("settings.json")
            let auth = (settings["security"] as? [String: Any])?["auth"] as? [String: Any]
            switch auth?["selectedType"] as? String {
            case "gemini-api-key":
                let env = fileReader(root.appendingPathComponent(".env")).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if Self.hasEnvironmentValue(env, names: ["GEMINI_API_KEY", "GOOGLE_API_KEY"])
                    || (usesSystemKeychain && keychainReader("gemini-cli-api-key", "default-api-key") != nil)
                {
                    return .apiKey
                }
            case "oauth-personal", nil:
                let credentials = object("oauth_creds.json")
                if Self.nonempty(credentials["refresh_token"]) || Self.nonempty(credentials["access_token"]) { return .oauth }
            default: break
            }
        case .openCode, .mimo:
            let entries = object("auth.json")
            let configured = entries.values.filter { raw in
                guard let entry = raw as? [String: Any] else { return false }
                switch entry["type"] as? String {
                case "api": return Self.nonempty(entry["key"])
                case "oauth": return Self.nonempty(entry["refresh"]) || Self.nonempty(entry["access"])
                default: return false
                }
            }.count
            if configured > 0 { return .providers(configured) }
        case .kimi:
            let credentials = object("credentials/kimi-code.json")
            if Self.nonempty(credentials["refresh_token"]) || Self.nonempty(credentials["access_token"]) { return .oauth }
        case .grok:
            let auth = object("auth.json")
            if auth.contains(where: { key, value in
                (key.hasPrefix("https://auth.x.ai::") || key == "https://accounts.x.ai/sign-in")
                    && Self.nonempty((value as? [String: Any])?["key"])
            }) {
                return .oauth
            }
        case .claudeCode:
            var credentials = object(".credentials.json")
            if credentials.isEmpty, usesSystemKeychain,
                let data = keychainReader("Claude Code-credentials", nil),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                credentials = value
            }
            if let oauth = credentials["claudeAiOauth"] as? [String: Any],
                Self.nonempty(oauth["refreshToken"]) || Self.nonempty(oauth["accessToken"])
            {
                return .oauth
            }
            let env = object("settings.json")["env"] as? [String: Any] ?? [:]
            if Self.nonempty(env["ANTHROPIC_API_KEY"]) || Self.nonempty(env["ANTHROPIC_AUTH_TOKEN"]) { return .apiKey }
        case .workBuddy, .zcode, .trae, .antigravity: break
        }
        return .unknown
    }

    static func hasEnvironmentValue(_ text: String, names: Set<String>) -> Bool {
        text.split(separator: "\n").contains { line in
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("export ") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equal = value.firstIndex(of: "="), names.contains(String(value[..<equal]).trimmingCharacters(in: .whitespaces)) else { return false }
            let content = value[value.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            return !content.isEmpty && !content.hasPrefix("#") && content != "\"\"" && content != "''"
        }
    }

    private static func nonempty(_ value: Any?) -> Bool {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func keychainData(service: String, account: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, !data.isEmpty, data.count <= 1024 * 1024
        else { return nil }
        return data
    }
}
