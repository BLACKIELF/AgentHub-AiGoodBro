import CFNetwork
import Darwin
import Foundation

/// Read-only projection of the user's HTTPS route. Never evaluates PAC, reads
/// proxy credentials, inherits process proxy variables, or changes system settings.
enum LocalProxyNetworkSettings {
    enum Failure: Error { case unavailable, automaticProxyUnsupported, authenticatedProxyUnsupported, invalidProxy }
    private static let upstream = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    static func load() throws -> String? {
        guard let snapshot = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { throw Failure.unavailable }
        return try resolve(snapshot)
    }

    static func resolve(_ settings: [String: Any]) throws -> String? {
        if try enabled(kCFNetworkProxiesProxyAutoConfigEnable as String, in: settings)
            || enabled(kCFNetworkProxiesProxyAutoDiscoveryEnable as String, in: settings)
        {
            throw Failure.automaticProxyUnsupported
        }
        // Validate the selected manual setting before allowing CFNetwork to apply
        // destination exceptions. A malformed route never becomes silent direct.
        if try enabled(kCFNetworkProxiesHTTPSEnable as String, in: settings) {
            try rejectAuthentication(prefix: "HTTPS", in: settings)
            _ = try endpoint(scheme: "http", host: settings[kCFNetworkProxiesHTTPSProxy as String], port: settings[kCFNetworkProxiesHTTPSPort as String])
        } else if try enabled(kCFNetworkProxiesSOCKSEnable as String, in: settings) {
            try rejectAuthentication(prefix: "SOCKS", in: settings)
            _ = try endpoint(scheme: "socks5", host: settings[kCFNetworkProxiesSOCKSProxy as String], port: settings[kCFNetworkProxiesSOCKSPort as String])
        }
        let proxies = CFNetworkCopyProxiesForURL(upstream as CFURL, settings as CFDictionary).takeRetainedValue()
        guard let entries = proxies as? [[String: Any]], let selected = entries.first,
            let kind = selected[kCFProxyTypeKey as String] as? String
        else { throw Failure.unavailable }
        for key in [kCFProxyUsernameKey as String, kCFProxyPasswordKey as String] where selected[key] != nil {
            throw Failure.authenticatedProxyUnsupported
        }
        let scheme: String
        if kind == (kCFProxyTypeNone as String) { return nil }
        if kind == (kCFProxyTypeHTTP as String) || kind == (kCFProxyTypeHTTPS as String) {
            scheme = "http"
        } else if kind == (kCFProxyTypeSOCKS as String) {
            scheme = "socks5"
        } else if kind == (kCFProxyTypeAutoConfigurationURL as String) || kind == (kCFProxyTypeAutoConfigurationJavaScript as String) {
            throw Failure.automaticProxyUnsupported
        } else {
            throw Failure.invalidProxy
        }
        return try endpoint(scheme: scheme, host: selected[kCFProxyHostNameKey as String], port: selected[kCFProxyPortNumberKey as String])
    }

    private static func enabled(_ key: String, in settings: [String: Any]) throws -> Bool {
        guard let value = settings[key] else { return false }
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { throw Failure.invalidProxy }
        return number.doubleValue != 0
    }
    private static func rejectAuthentication(prefix: String, in settings: [String: Any]) throws {
        for (key, value) in settings where key.hasPrefix(prefix) {
            let name = key.lowercased()
            guard name.contains("user") || name.contains("password") || name.contains("authenticated") else { continue }
            if let number = value as? NSNumber, number.doubleValue == 0 { continue }
            if let text = value as? String, text.isEmpty { continue }
            throw Failure.authenticatedProxyUnsupported
        }
    }
    private static func endpoint(scheme: String, host rawHost: Any?, port rawPort: Any?) throws -> String {
        guard var host = rawHost as? String, !host.isEmpty, host.utf8.count <= 253,
            let port = rawPort as? NSNumber, CFGetTypeID(port) != CFBooleanGetTypeID(),
            port.doubleValue.isFinite, port.doubleValue.rounded(.towardZero) == port.doubleValue,
            (1...65535).contains(port.intValue)
        else { throw Failure.invalidProxy }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58].contains($0) }) else {
            throw Failure.invalidProxy
        }
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { throw Failure.invalidProxy }
            host = "[" + host + "]"
        } else {
            guard
                host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                    $0.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"#, options: .regularExpression) != nil
                })
            else { throw Failure.invalidProxy }
        }
        return scheme + "://" + host.lowercased() + ":" + String(port.intValue)
    }
    static func message(_ failure: Failure, language: WidgetLanguage) -> String {
        switch failure {
        case .automaticProxyUnsupported:
            return language.text(
                "系统正在使用自动代理（PAC/WPAD），反代暂不支持；请配置手动 HTTPS 或 SOCKS 代理后重试。", "System PAC/WPAD proxies are not supported. Configure a manual HTTPS or SOCKS proxy and retry.")
        case .authenticatedProxyUnsupported:
            return language.text("系统代理需要身份验证，反代暂不支持此代理。", "The system proxy requires authentication and is not supported.")
        case .invalidProxy:
            return language.text("系统代理地址或端口无效，反代未启动。", "The system proxy host or port is invalid. The proxy did not start.")
        case .unavailable:
            return language.text("无法读取系统代理设置，反代未启动。", "System proxy settings could not be read. The proxy did not start.")
        }
    }
}
