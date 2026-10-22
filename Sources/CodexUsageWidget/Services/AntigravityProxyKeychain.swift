import Foundation
import LocalAuthentication
import Security

enum AntigravityProxyFailure: Error {
    case unavailable, keychain, invalidData, storage, connection
}

/// A dedicated namespace: never reads or changes Codex, Google, Antigravity IDE
/// or another AiGoodBro account's credentials. No security(1) argv secrets.
protocol AntigravityProxyCredentialStore {
    func read(_ account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func remove(_ account: String) throws
}

struct AntigravityProxyKeychain: AntigravityProxyCredentialStore {
    static let service = "com.aigoodbro.Next.AntigravityProxy.v1"

    func read(_ account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536 else {
            throw AntigravityProxyFailure.keychain
        }
        return data
    }

    func save(_ data: Data, account: String) throws {
        guard data.count <= 65_536 else { throw AntigravityProxyFailure.invalidData }
        let query = base(account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            insert[kSecAttrSynchronizable as String] = false
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw AntigravityProxyFailure.keychain }
        } else if status != errSecSuccess {
            throw AntigravityProxyFailure.keychain
        }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AntigravityProxyFailure.keychain }
    }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}
