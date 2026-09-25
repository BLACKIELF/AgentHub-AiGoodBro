import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

/// Reads only the already-running official desktop app, or an explicitly selected
/// legacy IDE cache. No OAuth flow, token refresh, browser storage, prompt or account
/// switch is performed. The local RPC shape is documented by CodexBar's Antigravity
/// provider; the legacy protobuf field map is corroborated by OpenCode Bar.
struct AntigravityCLIQuotaReader {
    struct Endpoint: Sendable {
        let pid: Int32
        let birthSeconds: UInt64
        let executable: String
        let port: Int
        let csrf: String
        var scheme = "https"
    }

    struct Cache: Sendable {
        let data: Data
        let modifiedAt: Date
    }

    typealias EndpointReader = () throws -> [Endpoint]
    typealias EndpointVerifier = (Endpoint) -> Bool
    typealias CacheReader = (URL) throws -> Cache?
    private enum Failure: Error { case invalid, identityChanged, unavailable }
    static let maximumBytes = 1_048_576
    private static let servicePath = "/exa.language_server_pb.LanguageServerService/"
    private let endpoints: EndpointReader
    private let verifier: EndpointVerifier
    private let cacheReader: CacheReader
    private let transport: any LocalCLIQuotaTransport

    init(
        transport: any LocalCLIQuotaTransport = AntigravityLoopbackTransport(),
        endpoints: @escaping EndpointReader = Self.discoverEndpoints,
        verifier: @escaping EndpointVerifier = Self.verifyEndpoint,
        cacheReader: @escaping CacheReader = Self.readCache
    ) {
        self.transport = transport
        self.endpoints = endpoints
        self.verifier = verifier
        self.cacheReader = cacheReader
    }

    func load(profile: LocalCLIProfile, now: Date = Date()) async -> LocalCLIQuotaResult {
        guard profile.kind == .antigravity else {
            return Self.result(state: .unsupported, at: now, code: "local_cli_adapter_not_owned")
        }
        let root = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
        let isShared =
            profile.isDefault && profile.id == "local-antigravity"
            && root.standardizedFileURL
                == LocalCLIKind.antigravity.defaultConfigDirectory(
                    home: FileManager.default.homeDirectoryForCurrentUser
                ).standardizedFileURL
        if isShared {
            var discoveredLiveEndpoint = false
            do {
                let liveEndpoints = try endpoints().prefix(6)
                discoveredLiveEndpoint = !liveEndpoints.isEmpty
                for endpoint in liveEndpoints {
                    try Task.checkCancellation()
                    do {
                        let status = try await request("GetUserStatus", endpoint: endpoint)
                        let identity = try Self.parseStatus(status, now: now)
                        guard let account = identity.identity else { continue }
                        var windows = identity.windows
                        if let summary = try? await request("RetrieveUserQuotaSummary", endpoint: endpoint),
                            let richer = try? Self.parseSummary(summary, now: now), !richer.isEmpty
                        {
                            windows = richer
                        }
                        try Task.checkCancellation()
                        // The user can switch accounts in Antigravity during a refresh.
                        // Never combine one account's identity with another's summary.
                        let after = try Self.parseStatus(
                            try await request("GetUserStatus", endpoint: endpoint), now: now)
                        guard after.identity?.lowercased() == account.lowercased() else {
                            throw Failure.identityChanged
                        }
                        return Self.result(
                            state: windows.isEmpty ? .unavailable : .available, at: now,
                            identity: account, plan: after.plan ?? identity.plan, windows: windows,
                            code: windows.isEmpty ? "local_cli_antigravity_no_quota" : nil)
                    } catch Failure.identityChanged {
                        return Self.result(state: .unavailable, at: now, code: "local_cli_antigravity_account_changed")
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                    }
                }
            } catch {
                if Task.isCancelled {
                    return Self.result(state: .unavailable, at: now, code: "local_cli_cancelled")
                }
                // Failure to inspect processes is not evidence that no live
                // account exists; do not substitute an unbound historical cache.
                return Self.result(state: .unavailable, at: now, code: "local_cli_antigravity_live_unavailable")
            }
            // A failed live read must not substitute a previous account's IDE
            // cache. Only the absence of a live endpoint permits history reads.
            if discoveredLiveEndpoint {
                return Self.result(state: .unavailable, at: now, code: "local_cli_antigravity_live_unavailable")
            }
        }
        do {
            try Task.checkCancellation()
            if let cached = try cacheReader(root) {
                return try Self.parseCache(cached, now: now)
            }
        } catch {
            return Self.result(state: .unavailable, at: now, code: "local_cli_antigravity_cache_unavailable")
        }
        return Self.result(
            state: .unavailable, at: now,
            code: isShared ? "local_cli_antigravity_open_app" : "local_cli_antigravity_linked_cache_only")
    }

    private func request(_ method: String, endpoint: Endpoint) async throws -> Data {
        try Task.checkCancellation()
        guard ["GetUserStatus", "RetrieveUserQuotaSummary"].contains(method),
            ["https", "http"].contains(endpoint.scheme),
            (1...65535).contains(endpoint.port), !endpoint.csrf.isEmpty, endpoint.csrf.utf8.count <= 512,
            !endpoint.csrf.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            verifier(endpoint),
            let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(Self.servicePath)\(method)")
        else { throw Failure.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let body: [String: Any] =
            method == "RetrieveUserQuotaSummary"
            ? ["forceRefresh": true]
            : ["metadata": ["ideName": "antigravity", "extensionName": "antigravity", "locale": "en"]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await transport.response(for: request)
        guard response.statusCode == 200, response.data.count <= Self.maximumBytes,
            verifier(endpoint)
        else { throw Failure.unavailable }
        return response.data
    }

    private struct Status {
        let identity: String?
        let plan: String?
        let windows: [LocalCLIQuotaWindow]
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.invalid }
        if let code = object["code"] {
            let accepted =
                (code as? String).map { ["ok", "success", "0"].contains($0.lowercased()) }
                ?? (number(code) == 0)
            guard accepted else { throw Failure.invalid }
        }
        return object
    }

    private static func parseStatus(_ data: Data, now: Date) throws -> Status {
        let object = try object(data)
        guard let status = object["userStatus"] as? [String: Any] else { throw Failure.invalid }
        let identity = LocalCLIQuotaPresentation.validIdentity(status["email"] as? String)
        let planInfo = (status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any] ?? [:]
        let tier = status["userTier"] as? [String: Any] ?? [:]
        let plan = ([tier["name"]] + ["planDisplayName", "displayName", "productName", "planName", "planShortName"].map { planInfo[$0] })
            .compactMap { LocalCLIQuotaPresentation.boundedLabel($0 as? String) }.first
        let models = (status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []
        guard models.count <= 256 else { throw Failure.invalid }
        var windows: [LocalCLIQuotaWindow] = []
        for (index, model) in models.enumerated() {
            guard let label = LocalCLIQuotaPresentation.boundedLabel(model["label"] as? String, maximumUTF8Bytes: 128),
                let quota = model["quotaInfo"] as? [String: Any],
                let remaining = fraction(quota["remainingFraction"])
            else { continue }
            let reset = date(quota["resetTime"])
            guard reset.map({ $0 > now }) ?? true else { continue }
            windows.append(LocalCLIQuotaWindow(id: "model-\(index)", label: label, usedPercent: (1 - remaining) * 100, resetsAt: reset))
        }
        return Status(identity: identity, plan: plan, windows: windows)
    }

    static func parseSummary(_ data: Data, now: Date) throws -> [LocalCLIQuotaWindow] {
        let object = try object(data)
        let payload = object["response"] as? [String: Any] ?? object["summary"] as? [String: Any] ?? object
        guard let groups = payload["groups"] as? [[String: Any]], groups.count <= 32 else { throw Failure.invalid }
        var windows: [LocalCLIQuotaWindow] = []
        for (groupIndex, group) in groups.enumerated() {
            let groupName = LocalCLIQuotaPresentation.boundedLabel((group["displayName"] ?? group["name"]) as? String) ?? "Quota"
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            guard buckets.count <= 32 else { throw Failure.invalid }
            for (bucketIndex, bucket) in buckets.enumerated() {
                guard bucket["disabled"] as? Bool != true else { continue }
                let remainingObject = bucket["remaining"] as? [String: Any] ?? [:]
                let raw =
                    bucket["remainingFraction"] ?? remainingObject["remainingFraction"]
                    ?? ((remainingObject["case"] as? String) == "remainingFraction" ? remainingObject["value"] : nil)
                guard let remaining = fraction(raw),
                    let name = LocalCLIQuotaPresentation.boundedLabel(
                        (bucket["displayName"] ?? bucket["name"] ?? bucket["bucketId"] ?? bucket["id"]) as? String)
                else { continue }
                let reset = date(bucket["resetTime"])
                guard reset.map({ $0 > now }) ?? true else { continue }
                windows.append(
                    LocalCLIQuotaWindow(
                        id: "group-\(groupIndex)-bucket-\(bucketIndex)",
                        label: String("\(groupName) · \(name)".prefix(100)),
                        usedPercent: (1 - remaining) * 100, resetsAt: reset))
            }
        }
        guard LocalCLIQuotaPresentation.validWindows(windows) else { throw Failure.invalid }
        return windows
    }

    private static func result(
        state: LocalCLIQuotaState, at: Date, identity: String? = nil, plan: String? = nil,
        windows: [LocalCLIQuotaWindow] = [], cached: Bool = false, code: String? = nil
    ) -> LocalCLIQuotaResult {
        let identity = LocalCLIQuotaPresentation.validIdentity(identity)
        return LocalCLIQuotaResult(
            state: state, fetchedAt: at, maskedIdentity: identity.map(LocalCLIQuotaPresentation.maskedIdentity),
            identityFingerprint: identity.map {
                SHA256.hash(data: Data("next-local-cli:v1:antigravity:\($0.lowercased())".utf8))
                    .map { String(format: "%02x", $0) }.joined()
            }, planLabel: plan, windows: windows, balance: nil, balanceCurrency: nil,
            sourceLabel: cached ? "Antigravity · cached IDE quota" : "Antigravity · official desktop quota", messageCode: code)
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func fraction(_ raw: Any?) -> Double? {
        guard let value = number(raw), (0...1).contains(value) else { return nil }
        return value
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let string = raw as? String, string.utf8.count <= 80 else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: string) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: string)
    }

    // Kernel identity prevents a shell command merely mentioning Antigravity,
    // another user's server, or a reused PID from receiving the CSRF token.
    private static func processIdentity(_ pid: Int32, verifySignature: Bool = false) -> (path: String, birth: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_uid == geteuid(), info.pbi_status != UInt32(SZOMB)
        else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        let executable = URL(fileURLWithPath: path)
        guard executable.lastPathComponent.hasPrefix("language_server"),
            path == executable.resolvingSymlinksInPath().path,
            let marker = path.range(of: "/Antigravity.app/Contents/")
        else { return nil }
        let root = URL(fileURLWithPath: String(path[..<marker.lowerBound]) + "/Antigravity.app", isDirectory: true)
        guard
            Bundle(url: root)?.bundleIdentifier == "com.google.antigravity",
            ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
                .contains(root.deletingLastPathComponent().path),
            !verifySignature || signedGoogleApplication(root)
        else { return nil }
        return (path, info.pbi_start_tvsec)
    }

    private static func signedGoogleApplication(_ root: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        // Google's installed Antigravity designated requirement, not merely a
        // spoofable Info.plist label, establishes the localhost credential sink.
        let rule = #"anchor apple generic and identifier "com.google.antigravity" and certificate leaf[subject.OU] = "EQHXZ8M8AV""#
        guard SecStaticCodeCreateWithPath(root as CFURL, [], &code) == errSecSuccess,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
            let code, let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func listeningPorts(_ pid: Int32) throws -> Set<Int> {
        let output = try BoundedLocalProcess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
            maximumOutputBytes: 64 * 1024, timeout: 2, allowedExitCodes: [0, 1])
        let text = String(data: output, encoding: .utf8) ?? ""
        return Set(
            text.split(separator: "\n").compactMap { line in
                guard line.hasPrefix("n127.0.0.1:") || line.hasPrefix("n*:") || line.hasPrefix("n[::1]:"),
                    let last = line.split(separator: ":").last, let port = Int(last), (1...65535).contains(port)
                else { return nil }
                return port
            })
    }

    static func csrfArgument(_ command: String) -> String? {
        flag("--csrf_token", in: command)
    }

    private static func flag(_ flag: String, in command: String) -> String? {
        guard
            let expression = try? NSRegularExpression(
                pattern: #"(?:^|\s)"# + NSRegularExpression.escapedPattern(for: flag) + #"(?:=|\s+)([A-Za-z0-9._-]{1,512})(?:\s|$)"#),
            let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
            let range = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[range])
    }

    private static func discoverEndpoints() throws -> [Endpoint] {
        let output = try BoundedLocalProcess.run(
            executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axww", "-o", "pid=,command="],
            maximumOutputBytes: 2 * maximumBytes, timeout: 2)
        guard let text = String(data: output, encoding: .utf8) else { return [] }
        var endpoints: [Endpoint] = []
        for line in text.split(separator: "\n") where line.contains("language_server") {
            let pieces = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard pieces.count == 2, let pid = Int32(pieces[0]), let identity = processIdentity(pid, verifySignature: true),
                let csrf = csrfArgument(String(pieces[1]))
            else { continue }
            let ports = try listeningPorts(pid)
            for port in ports.sorted().prefix(4) {
                endpoints.append(Endpoint(pid: pid, birthSeconds: identity.birth, executable: identity.path, port: port, csrf: csrf))
            }
            // Legacy extension HTTP is only eligible when this same verified
            // process owns the advertised port. Never trust a bare port flag.
            if let value = flag("--extension_server_port", in: String(pieces[1])), let port = Int(value), ports.contains(port) {
                let token = flag("--extension_server_csrf_token", in: String(pieces[1])) ?? csrf
                endpoints.append(Endpoint(pid: pid, birthSeconds: identity.birth, executable: identity.path, port: port, csrf: token, scheme: "http"))
            }
            if endpoints.count >= 6 { break }
        }
        return endpoints
    }

    private static func verifyEndpoint(_ endpoint: Endpoint) -> Bool {
        guard let identity = processIdentity(endpoint.pid), identity.path == endpoint.executable,
            identity.birth == endpoint.birthSeconds,
            (try? listeningPorts(endpoint.pid).contains(endpoint.port)) == true
        else { return false }
        return true
    }

    static func hasLinkedCache(at root: URL) -> Bool {
        cacheFile(root) != nil
    }

    private static func cacheFile(_ root: URL) -> URL? {
        let url = root.appendingPathComponent("User/globalStorage/state.vscdb")
        var info = stat()
        guard root.isFileURL, root.path.hasPrefix("/"), root.standardizedFileURL.path == root.path,
            url.resolvingSymlinksInPath().path == url.path,
            lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= 512 * 1024 * 1024
        else { return nil }
        // SQLite may read these companion files too; reject unexpected links.
        for suffix in ["-wal", "-shm"] {
            var sidecar = stat()
            let path = url.path + suffix
            if lstat(path, &sidecar) == 0 {
                guard sidecar.st_mode & S_IFMT == S_IFREG, sidecar.st_uid == geteuid(), sidecar.st_nlink == 1 else { return nil }
            } else if errno != ENOENT {
                return nil
            }
        }
        return url
    }

    private static func readCache(_ root: URL) throws -> Cache? {
        guard let file = cacheFile(root) else { return nil }
        let output = try BoundedLocalProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [
                "-readonly", "-json", file.path,
                "PRAGMA query_only=ON; SELECT CAST(value AS TEXT) AS auth FROM ItemTable WHERE key='antigravityAuthStatus' AND length(value)<=1048576 LIMIT 1;",
            ],
            maximumOutputBytes: 2 * maximumBytes, timeout: 3)
        guard !output.isEmpty else { return nil }
        guard let rows = try JSONSerialization.jsonObject(with: output) as? [[String: String]],
            let auth = rows.first?["auth"], auth.utf8.count <= maximumBytes
        else { return nil }
        let dates = [file, URL(fileURLWithPath: file.path + "-wal")].compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return Cache(data: Data(auth.utf8), modifiedAt: dates.max() ?? .distantPast)
    }

    static func parseCache(_ cache: Cache, now: Date) throws -> LocalCLIQuotaResult {
        let object = try object(cache.data)
        guard let base64 = object["userStatusProtoBinaryBase64"] as? String,
            let payload = Data(base64Encoded: base64), payload.count <= maximumBytes
        else { throw Failure.invalid }
        let root = try protobuf(payload)
        let embeddedIdentity = root[7]?.first?.bytes.flatMap { String(data: $0, encoding: .utf8) }
        guard let identity = LocalCLIQuotaPresentation.validIdentity(embeddedIdentity ?? object["email"] as? String)
        else { throw Failure.invalid }
        if let embeddedIdentity, let outer = object["email"] as? String,
            embeddedIdentity.lowercased() != outer.lowercased()
        {
            throw Failure.identityChanged
        }
        var windows: [LocalCLIQuotaWindow] = []
        for group in root[33] ?? [] {
            guard let bytes = group.bytes else { continue }
            for model in try protobuf(bytes)[1] ?? [] {
                guard let data = model.bytes else { continue }
                let fields = try protobuf(data)
                guard let rawLabel = fields[1]?.first?.bytes.flatMap({ String(data: $0, encoding: .utf8) }),
                    let label = LocalCLIQuotaPresentation.boundedLabel(rawLabel, maximumUTF8Bytes: 128),
                    let quotaData = fields[15]?.first?.bytes
                else { continue }
                let quota = try protobuf(quotaData)
                guard let raw = quota[1]?.first?.fraction, raw.isFinite, (0...1).contains(raw) else { continue }
                var reset: Date?
                if let timestamp = quota[2]?.first?.bytes {
                    let time = try protobuf(timestamp)
                    if let seconds = time[1]?.first?.integer, seconds <= 253_402_300_799 {
                        let nanos = time[2]?.first?.integer ?? 0
                        if nanos < 1_000_000_000 { reset = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9) }
                    }
                }
                // An old reset time does not establish that the bucket refilled.
                guard reset.map({ $0 > now }) ?? true else { continue }
                windows.append(LocalCLIQuotaWindow(id: "cache-model-\(windows.count)", label: label, usedPercent: (1 - raw) * 100, resetsAt: reset))
            }
        }
        guard LocalCLIQuotaPresentation.validWindows(windows), cache.modifiedAt <= now.addingTimeInterval(60) else { throw Failure.invalid }
        return result(
            // Cache-file mtime is not the official quota observation time. Keep
            // history visible but never let it prove fresh quota or sign-in.
            state: .unavailable, at: cache.modifiedAt,
            identity: identity, windows: windows, cached: true,
            code: "local_cli_antigravity_cached_quota")
    }

    private struct ProtoValue {
        let bytes: Data?
        let integer: UInt64?
        let fraction: Double?
    }

    private static func protobuf(_ data: Data) throws -> [Int: [ProtoValue]] {
        guard data.count <= maximumBytes else { throw Failure.invalid }
        let bytes = Array(data)
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw Failure.invalid }
                let byte = bytes[offset]
                offset += 1
                guard index != 9 || byte <= 1 else { throw Failure.invalid }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte < 128 { return value }
            }
            throw Failure.invalid
        }
        var fields: [Int: [ProtoValue]] = [:]
        var count = 0
        while offset < bytes.count {
            count += 1
            guard count <= 4096 else { throw Failure.invalid }
            let key = try varint()
            guard key >> 3 > 0, key >> 3 <= 0x1fff_ffff else { throw Failure.invalid }
            let field = Int(key >> 3)
            let value: ProtoValue
            switch key & 7 {
            case 0:
                let integer = try varint()
                value = ProtoValue(bytes: nil, integer: integer, fraction: Double(integer))
            case 1, 5:
                let length = key & 7 == 1 ? 8 : 4
                guard bytes.count - offset >= length else { throw Failure.invalid }
                var raw: UInt64 = 0
                for index in 0..<length { raw |= UInt64(bytes[offset + index]) << (8 * index) }
                offset += length
                value = ProtoValue(bytes: nil, integer: nil, fraction: length == 8 ? Double(bitPattern: raw) : Double(Float(bitPattern: UInt32(raw))))
            case 2:
                let rawLength = try varint()
                guard let length = Int(exactly: rawLength), length <= bytes.count - offset else { throw Failure.invalid }
                value = ProtoValue(bytes: Data(bytes[offset..<(offset + length)]), integer: nil, fraction: nil)
                offset += length
            default: throw Failure.invalid
            }
            fields[field, default: []].append(value)
        }
        return fields
    }
}

/// Self-signed TLS is accepted only for the fixed loopback endpoint whose owning
/// official process was checked before the request. It is never used by internet
/// quota adapters. Redirects and proxies are disabled; response size is bounded.
private struct AntigravityLoopbackTransport: LocalCLIQuotaTransport {
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        guard let url = request.url, ["https", "http"].contains(url.scheme ?? ""), url.host == "127.0.0.1", let port = url.port,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            ["GetUserStatus", "RetrieveUserQuotaSummary"].contains(url.lastPathComponent)
        else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        let delegate = AntigravityLoopbackDelegate(port: port)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
            response.expectedContentLength <= AntigravityCLIQuotaReader.maximumBytes
        else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < AntigravityCLIQuotaReader.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return LocalCLIHTTPResponse(statusCode: response.statusCode, headers: [:], data: data)
    }
}

private final class AntigravityLoopbackDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let port: Int
    init(port: Int) { self.port = port }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == port,
            task.currentRequest?.url?.host == "127.0.0.1", task.currentRequest?.url?.port == port,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
