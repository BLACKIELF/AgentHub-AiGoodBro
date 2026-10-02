import Foundation
import Darwin

struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ chinese: String, _ english: String) -> String { english }
}

private final class SyntheticTransport: LocalCLIQuotaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private let callback: @Sendable () async throws -> Void
    init(callback: @escaping @Sendable () async throws -> Void = {}) { self.callback = callback }
    private func capture(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        captured.append(request)
    }
    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        capture(request)
        try await callback()
        return LocalCLIHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{"access_token":"synthetic-new-access","refresh_token":"synthetic-new-refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8))
    }
}

private enum SyntheticFailure: Error { case assertion(String) }

@main
struct KimiRenewalFixture {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SyntheticFailure.assertion(message) }
    }
    private static func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    static func main() async throws {
        let baseline = CommandLine.arguments.contains("--baseline")
        guard let base = ProcessInfo.processInfo.environment["KIMI_FIXTURE_ROOT"] else {
            throw SyntheticFailure.assertion("explicit synthetic output directory required")
        }
        let root = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("synthetic-kimi-renewal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(#"{"access_token":"synthetic-old-access","refresh_token":"synthetic-old-refresh","user_id":"synthetic-user","retained":7}"#.utf8)
        let device = Data("synthetic-device\n".utf8)
        func setup(_ name: String) throws -> URL {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("credentials"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("oauth"), withIntermediateDirectories: true)
            try original.write(to: directory.appendingPathComponent("credentials/kimi-code.json"))
            try device.write(to: directory.appendingPathComponent("device_id"))
            return directory
        }
        do {
            let directory = try setup("synthetic-held")
            let lock = directory.appendingPathComponent("oauth/kimi-code.lock")
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            let transport = SyntheticTransport()
            var rejected = false
            do { try await LocalCLIQuotaRefresh.renewKimiCredential(directory: directory, transport: transport) }
            catch { rejected = true }
            let saved = try read(directory.appendingPathComponent("credentials/kimi-code.json"))
            try expect(rejected && transport.requests.isEmpty, "held lock blocks HTTP")
            try expect(saved == original && FileManager.default.fileExists(atPath: lock.path), "held lock and credentials preserved")
        }
        do {
            let directory = try setup("synthetic-replaced-lock")
            let lock = directory.appendingPathComponent("oauth/kimi-code.lock")
            let moved = directory.appendingPathComponent("oauth/synthetic-old-lock")
            let sentinel = Date(timeIntervalSince1970: 1_000_000)
            let transport = SyntheticTransport {
                try FileManager.default.moveItem(at: lock, to: moved)
                try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: lock.path)
                try await Task.sleep(nanoseconds: 1_200_000_000)
            }
            var rejected = false
            do { try await LocalCLIQuotaRefresh.renewKimiCredential(directory: directory, transport: transport) }
            catch { rejected = true }
            let saved = try read(directory.appendingPathComponent("credentials/kimi-code.json"))
            if baseline {
                try expect(!rejected && saved != original && !FileManager.default.fileExists(atPath: lock.path), "baseline lock-replacement defect must reproduce")
            } else {
                try expect(rejected && saved == original && transport.requests.count == 1, "lost lock rejects credential write")
                try expect(FileManager.default.fileExists(atPath: lock.path), "replacement lock preserved")
                let stamp = try FileManager.default.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date
                try expect(stamp == sentinel, "heartbeat does not stamp replacement lock")
            }
        }
        do {
            let directory = try setup("synthetic-device-change")
            let deviceFile = directory.appendingPathComponent("device_id")
            // Same trimmed ID, different bytes: reject even subtle concurrent edits.
            let changed = Data("synthetic-device".utf8)
            let transport = SyntheticTransport { try changed.write(to: deviceFile) }
            var rejected = false
            do { try await LocalCLIQuotaRefresh.renewKimiCredential(directory: directory, transport: transport) }
            catch { rejected = true }
            let saved = try read(directory.appendingPathComponent("credentials/kimi-code.json"))
            let persistedDevice = try read(deviceFile)
            try expect(persistedDevice == changed, "device change preserved")
            if baseline {
                try expect(!rejected && saved != original, "baseline device-change defect must reproduce")
            } else {
                try expect(rejected && saved == original && transport.requests.count == 1, "changed device rejects credential write")
            }
            try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("oauth/kimi-code.lock").path), "own lock released after device change")
        }
        do {
            let directory = try setup("synthetic-success")
            let ownedLock = directory.appendingPathComponent("oauth/kimi-code.lock")
            let sentinel = Date(timeIntervalSince1970: 1_000_000)
            let transport = SyntheticTransport {
                try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: ownedLock.path)
                try await Task.sleep(nanoseconds: 1_200_000_000)
                let heartbeatStamp = try FileManager.default.attributesOfItem(atPath: ownedLock.path)[.modificationDate] as? Date
                try expect(heartbeatStamp != nil && heartbeatStamp! > sentinel, "active lock heartbeat advances mtime")
            }
            try await LocalCLIQuotaRefresh.renewKimiCredential(directory: directory, transport: transport)
            let file = directory.appendingPathComponent("credentials/kimi-code.json")
            let saved = try JSONSerialization.jsonObject(with: read(file)) as! [String: Any]
            try expect(saved["access_token"] as? String == "synthetic-new-access" && saved["refresh_token"] as? String == "synthetic-new-refresh", "mock refresh persisted")
            try expect(saved["user_id"] as? String == "synthetic-user" && saved["retained"] as? Int == 7, "account and unknown fields preserved")
            let persistedDevice = try read(directory.appendingPathComponent("device_id"))
            try expect(persistedDevice == device && transport.requests.count == 1, "device retained and one HTTP request")
            try expect(transport.requests.first?.value(forHTTPHeaderField: "X-Msh-Device-Id") == "synthetic-device", "request uses original device")
            try expect(transport.requests.first?.url?.absoluteString == "https://auth.kimi.com/api/oauth/token", "fixed official endpoint")
            try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("oauth/kimi-code.lock").path), "own lock released on success")
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            try expect(permissions == 0o600, "credential permissions private")
        }
        print(baseline ? "PASS baseline defects reproduced with transport-only seam" : "PASS kimi-renewal candidate fixture (4 scenarios)")
    }
}
