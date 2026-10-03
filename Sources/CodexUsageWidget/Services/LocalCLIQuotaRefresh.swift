import CoreFoundation
import Darwin
import Foundation

/// Renew the selected CLI's existing session without opening a terminal or
/// starting an inference request. Never initiates login or changes providers.
actor LocalCLIQuotaRefresh {
    static let shared = LocalCLIQuotaRefresh()
    private var active: [String: Task<Bool, Never>] = [:]

    func refresh(_ profile: LocalCLIProfile) async -> Bool {
        let key = profile.kind.rawValue + ":" + profile.configDirectory
        if let task = active[key] { return await task.value }
        let task = Task { await Self.renew(profile) }
        active[key] = task
        let result = await task.value
        active.removeValue(forKey: key)
        return result
    }

    private static func renew(_ profile: LocalCLIProfile) async -> Bool {
        do {
            switch profile.kind {
            case .kimi:
                try await renewKimi(directory: URL(fileURLWithPath: profile.configDirectory))
            case .grok:
                try await renewGrok(profile)
            default: return false
            }
            return true
        } catch { return false }
    }

    private enum Failure: Error { case invalid, busy, changed }
    private static let maximumBytes = 1_048_576

    private static func read(_ url: URL) throws -> Data {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
            let bytes = try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: maximumBytes, allowMissing: true)
        else { throw Failure.invalid }
        return bytes
    }

    private static func secret(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 32_768,
            !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return text
    }

    static func kimiRefreshRequest(refreshToken: String, deviceID: String) throws -> URLRequest {
        guard secret(refreshToken) != nil, secret(deviceID) != nil else { throw Failure.invalid }
        var request = URLRequest(url: URL(string: "https://auth.kimi.com/api/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("kimi_code_cli", forHTTPHeaderField: "X-Msh-Platform")
        request.setValue(deviceID, forHTTPHeaderField: "X-Msh-Device-Id")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let fields = [
            ("client_id", "17e5f671-d194-4dfb-9706-5516cb48c098"),
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
        ]
        request.httpBody = fields.map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").data(using: .utf8)
        return request
    }

    static func renewedKimiCredential(_ original: Data, response: Data, now: Date) throws -> Data {
        guard var stored = try JSONSerialization.jsonObject(with: original) as? [String: Any],
            let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any],
            let access = secret(reply["access_token"]), let refresh = secret(reply["refresh_token"]),
            let lifetime = Self.duration(reply["expires_in"])
        else { throw Failure.invalid }
        let type = (reply["token_type"] as? String) ?? "Bearer"
        guard type.lowercased() == "bearer" else { throw Failure.invalid }
        stored["access_token"] = access
        stored["refresh_token"] = refresh
        stored["expires_at"] = now.timeIntervalSince1970 + lifetime
        stored["expires_in"] = lifetime
        stored["token_type"] = type
        if let scope = reply["scope"] as? String { stored["scope"] = scope }
        return try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])
    }

    private static func duration(_ value: Any?) -> Double? {
        let number: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            number = n.doubleValue
        } else if let text = value as? String {
            number = Double(text)
        } else {
            number = nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }

    private static func renewKimi(directory: URL) async throws {
        try await renewKimiCredential(directory: directory, transport: LocalCLIURLSessionTransport())
    }

    static func renewKimiCredential(directory: URL, transport: any LocalCLIQuotaTransport) async throws {
        let file = directory.appendingPathComponent("credentials/kimi-code.json")
        let original = try read(file)
        let deviceFile = directory.appendingPathComponent("device_id")
        let deviceBytes = try read(deviceFile)
        guard let stored = try JSONSerialization.jsonObject(with: original) as? [String: Any],
            let token = secret(stored["refresh_token"]),
            let device = String(data: deviceBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw Failure.invalid }
        // Same proper-lockfile directory used by official Kimi Code. Updating
        // its mtime prevents another CLI process treating an active refresh as
        // stale while the HTTP request is in flight.
        let lockParent = directory.appendingPathComponent("oauth", isDirectory: true)
        guard lockParent.standardizedFileURL == lockParent.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.invalid }
        try FileManager.default.createDirectory(at: lockParent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = lockParent.appendingPathComponent("kimi-code.lock", isDirectory: true)
        guard mkdir(lock.path, 0o700) == 0 else { throw Failure.busy }
        var metadata = stat()
        guard lstat(lock.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == getuid()
        else { throw Failure.invalid }
        func sameLock() -> Bool {
            var current = stat()
            return lstat(lock.path, &current) == 0 && current.st_ino == metadata.st_ino && current.st_dev == metadata.st_dev
        }
        // Keep the owned inode open so replacement cannot reuse its identity;
        // stamp the descriptor, never a replacement at the same path.
        let descriptor = open(lock.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if sameLock() { _ = rmdir(lock.path) }
            throw Failure.invalid
        }
        defer { close(descriptor) }
        defer { if sameLock() { _ = rmdir(lock.path) } }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == metadata.st_ino,
            opened.st_dev == metadata.st_dev, sameLock()
        else { throw Failure.changed }
        let queue = DispatchQueue(label: "AiGoodBro.kimi-refresh-lock")
        let heartbeat = DispatchSource.makeTimerSource(queue: queue)
        heartbeat.schedule(deadline: .now() + 1, repeating: 1)
        heartbeat.setEventHandler { if sameLock() { _ = futimes(descriptor, nil) } }
        heartbeat.resume()
        defer {
            heartbeat.cancel()
            queue.sync {}
        }
        guard sameLock(), try read(file) == original, try read(deviceFile) == deviceBytes else { throw Failure.changed }
        let request = try kimiRefreshRequest(refreshToken: token, deviceID: device)
        let response = try await transport.response(for: request)
        guard response.statusCode == 200, response.data.count <= maximumBytes else { throw Failure.invalid }
        let updated = try renewedKimiCredential(original, response: response.data, now: Date())
        guard sameLock(), try read(deviceFile) == deviceBytes else { throw Failure.changed }
        try replaceCredential(file, expected: original, updated: updated)
    }

    static func replaceCredential(_ file: URL, expected: Data, updated: Data) throws {
        guard updated.count <= maximumBytes, try read(file) == expected else { throw Failure.changed }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".aigoodbro-refresh-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.invalid }
        defer {
            close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        try updated.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.invalid }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, try read(file) == expected,
            rename(temporary.path, file.path) == 0
        else { throw Failure.changed }
    }

    static func grokRefreshRequest(_ entry: [String: Any], sessionKey: String) throws -> URLRequest {
        guard entry["oidc_issuer"] as? String == "https://auth.x.ai",
            let client = secret(entry["oidc_client_id"]), sessionKey == "https://auth.x.ai::" + client,
            let token = secret(entry["refresh_token"]), secret(entry["user_id"]) != nil
        else { throw Failure.invalid }
        var fields = [("client_id", client), ("grant_type", "refresh_token"), ("refresh_token", token)]
        for name in ["principal_type", "principal_id"] {
            if let value = entry[name], !(value is NSNull) {
                guard let text = secret(value) else { throw Failure.invalid }
                fields.append((name, text))
            }
        }
        var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = fields.map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").data(using: .utf8)
        return request
    }

    static func renewedGrokCredential(_ original: Data, sessionKey: String, response: Data, now: Date) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any],
            var entry = root[sessionKey] as? [String: Any],
            let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any],
            let access = secret(reply["access_token"]),
            ((reply["token_type"] as? String) ?? "Bearer").lowercased() == "bearer"
        else { throw Failure.invalid }
        let formatter = ISO8601DateFormatter()
        if let rawLifetime = reply["expires_in"], !(rawLifetime is NSNull) {
            guard let lifetime = duration(rawLifetime), lifetime.rounded() == lifetime else { throw Failure.invalid }
            entry["expires_at"] = formatter.string(from: now.addingTimeInterval(lifetime))
        } else {
            // OIDC expires_in is optional. Remove the previous token's expiry;
            // the official 30-day fallback starts at this issuance time.
            entry.removeValue(forKey: "expires_at")
        }
        if let refresh = reply["refresh_token"], !(refresh is NSNull) {
            guard let token = secret(refresh) else { throw Failure.invalid }
            entry["refresh_token"] = token
        }
        entry["key"] = access
        entry["create_time"] = formatter.string(from: now)
        root[sessionKey] = entry
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func renewGrok(_ profile: LocalCLIProfile) async throws {
        try await renewGrokCredential(directory: URL(fileURLWithPath: profile.configDirectory), transport: LocalCLIURLSessionTransport())
    }

    static func renewGrokCredential(directory: URL, transport: any LocalCLIQuotaTransport) async throws {
        let file = directory.appendingPathComponent("auth.json")
        let before = try read(file)
        // Use the official Grok lock inode and heartbeat. Never unlink/break a
        // lock or race the CLI for a rotating refresh token.
        let lockURL = directory.appendingPathComponent("auth.json.lock")
        guard lockURL.standardizedFileURL == lockURL.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.invalid }
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.invalid }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == getuid(), metadata.st_nlink == 1
        else { throw Failure.invalid }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { _ = flock(descriptor, LOCK_UN) }
        func sameLock() -> Bool {
            var current = stat()
            return lstat(lockURL.path, &current) == 0 && current.st_ino == metadata.st_ino && current.st_dev == metadata.st_dev
        }
        guard sameLock() else { throw Failure.changed }
        let queue = DispatchQueue(label: "AiGoodBro.grok-refresh-lock")
        let heartbeat = DispatchSource.makeTimerSource(queue: queue)
        let stamp = {
            let holder = Data("\(getpid()):\(Int(Date().timeIntervalSince1970))".utf8)
            _ = holder.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
            _ = ftruncate(descriptor, off_t(holder.count))
            _ = fsync(descriptor)
        }
        stamp()
        heartbeat.schedule(deadline: .now() + 5, repeating: 5)
        heartbeat.setEventHandler(handler: stamp)
        heartbeat.resume()
        defer {
            heartbeat.cancel()
            queue.sync {}
        }
        // Another process may already have renewed or switched the selection.
        // Let the caller reread rather than spending the old refresh token.
        guard try read(file) == before else { return }
        guard let root = try JSONSerialization.jsonObject(with: before) as? [String: Any] else { throw Failure.invalid }
        let sessions = root.filter { $0.key.hasPrefix("https://auth.x.ai::") || $0.key == "https://accounts.x.ai/sign-in" }
        guard sessions.count == 1, let selected = sessions.first, let entry = selected.value as? [String: Any] else { throw Failure.invalid }
        let request = try grokRefreshRequest(entry, sessionKey: selected.key)
        let response = try await transport.response(for: request)
        guard response.statusCode == 200, response.data.count <= maximumBytes else { throw Failure.invalid }
        let updated = try renewedGrokCredential(before, sessionKey: selected.key, response: response.data, now: Date())
        guard sameLock() else { throw Failure.changed }
        try replaceCredential(file, expected: before, updated: updated)
    }
}
