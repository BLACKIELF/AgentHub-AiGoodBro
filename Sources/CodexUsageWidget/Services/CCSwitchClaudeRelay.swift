import CryptoKit
import Foundation

/// Reads the current Claude relay already configured by CC Switch. Its arbitrary
/// usage-script JavaScript is never evaluated; only the verified moylor endpoint
/// is supported. Database credentials stay in memory and never enter arguments.
enum CCSwitchClaudeRelay {
    struct Credential {
        let token: String
        let fingerprint: String
    }

    enum Failure: Error { case invalidConfiguration, invalidResponse }

    static func currentCredential(databaseURL: URL? = nil) throws -> Credential? {
        let database = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cc-switch/cc-switch.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let data = try BoundedLocalProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [
                // Background reads must not execute a user's sqlite3 init commands.
                "-init", "/dev/null", "-readonly", "-json", database.path,
                "PRAGMA query_only=ON; SELECT settings_config, meta FROM providers WHERE app_type='claude' AND is_current=1 LIMIT 2;",
            ],
            timeout: 3)
        guard !data.isEmpty else { return nil }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 1 else {
            throw Failure.invalidConfiguration
        }
        guard let row = rows.first else { return nil }
        return try credential(row)
    }

    static func credential(_ row: [String: Any]) throws -> Credential? {
        guard let configuration = row["settings_config"] as? String,
            let object = try JSONSerialization.jsonObject(with: Data(configuration.utf8)) as? [String: Any],
            let env = object["env"] as? [String: Any],
            let base = env["ANTHROPIC_BASE_URL"] as? String,
            let url = URLComponents(string: base)
        else { return nil }
        guard url.host?.lowercased() == "claude.moylor.com" else { return nil }
        guard url.scheme == "https", url.port == nil || url.port == 443,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            ["", "/", "/v1", "/v1/"].contains(url.path),
            let token = env["ANTHROPIC_AUTH_TOKEN"] as? String, !token.isEmpty, token.utf8.count <= 4096,
            token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            token.rangeOfCharacter(from: .controlCharacters) == nil,
            let metadata = row["meta"] as? String,
            let meta = try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any],
            let usage = meta["usage_script"] as? [String: Any], usage["enabled"] as? Bool == true
        else { throw Failure.invalidConfiguration }
        let fingerprint = SHA256.hash(data: Data(("claude-relay:moylor:" + token).utf8)).map { String(format: "%02x", $0) }.joined()
        return Credential(token: token, fingerprint: fingerprint)
    }

    static func balance(_ data: Data) throws -> (Double, String) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
        if object["is_active"] as? Bool == false || object["isValid"] as? Bool == false { throw Failure.invalidResponse }
        let quota = object["quota"] as? [String: Any]
        let raw = object["remaining"] ?? quota?["remaining"] ?? object["balance"]
        let value: Double?
        if let string = raw as? String {
            value = Double(string)
        } else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.doubleValue
        } else {
            value = nil
        }
        let unit = object["unit"] as? String ?? quota?["unit"] as? String ?? "USD"
        guard let value, value.isFinite, value >= 0, unit.uppercased() == "USD" else { throw Failure.invalidResponse }
        return (value, "USD")
    }

    static func selfTest() -> Bool {
        func row(_ base: String, token: String = "synthetic-token", enabled: Bool = true) -> [String: Any] {
            let settings = try! JSONSerialization.data(withJSONObject: ["env": ["ANTHROPIC_BASE_URL": base, "ANTHROPIC_AUTH_TOKEN": token]])
            let meta = try! JSONSerialization.data(withJSONObject: ["usage_script": ["enabled": enabled, "code": "throw new Error('must not execute')"]])
            return ["settings_config": String(decoding: settings, as: UTF8.self), "meta": String(decoding: meta, as: UTF8.self)]
        }
        do {
            guard let credential = try credential(row("https://claude.moylor.com")), credential.fingerprint.count == 64,
                try self.credential(row("https://example.invalid")) == nil,
                try balance(Data("{\"remaining\":46.72,\"unit\":\"USD\"}".utf8)).0 == 46.72,
                try balance(Data("{\"quota\":{\"remaining\":\"0\"}}".utf8)).0 == 0
            else { return false }
            for invalid in [
                row("http://claude.moylor.com"), row("https://claude.moylor.com?key=value"), row("https://claude.moylor.com", token: "bad\nheader"),
                row("https://claude.moylor.com", enabled: false),
            ] {
                do {
                    _ = try self.credential(invalid)
                    return false
                } catch {}
            }
            for invalid in ["{}", "{\"remaining\":true}", "{\"remaining\":-1}", "{\"remaining\":1,\"is_active\":false}", "{\"remaining\":1,\"unit\":\"tokens\"}"] {
                do {
                    _ = try balance(Data(invalid.utf8))
                    return false
                } catch {}
            }
            return true
        } catch { return false }
    }
}
