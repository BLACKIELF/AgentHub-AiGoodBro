import Foundation
import Darwin

final class FixtureLeaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [String: String] = [:]
    private var denied = Set<String>()
    func acquire(_ profile: String, request: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = request + ":" + profile
        guard !denied.contains(key), owners[profile] == nil else { return false }
        owners[profile] = request
        return true
    }
    func owns(_ profile: String, request: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return owners[profile] == request
    }
    func release(_ profile: String, request: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owners[profile] == request else { return false }
        owners.removeValue(forKey: profile)
        return true
    }
    func resolve(_ profile: String, request: String) -> String {
        lock.lock(); defer { lock.unlock() }
        denied.insert(request + ":" + profile)
        if owners[profile] == request {
            owners.removeValue(forKey: profile)
            return "abandoned"
        }
        return "not_reserved"
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return owners.count }
}

@main struct BridgeFixture {
    private static func blockForLateReply() {
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 26)
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let environment = ProcessInfo.processInfo.environment
        let socket = environment["FIXTURE_SOCKET"]!
        let mode = environment["FIXTURE_MODE"]!
        let owners = FixtureLeaseBox()
        var acquisitions = 0
        var releases = 0
        func emit(_ value: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
        let bridge = try LocalProxyBridge(path: socket, resolve: { request in
            guard request.schemaVersion == 1, request.runID == "cross-language", request.key == String(repeating: "k", count: 32),
                request.command == "acquire_resolve", request.leaseID == nil, UUID(uuidString: request.requestID) != nil,
                ["A", "B"].contains(request.profileID)
            else { return .failure(.identity) }
            let resolution = owners.resolve(request.profileID, request: request.requestID)
            print("{\"event\":\"bridge\",\"command\":\"acquire_resolve\",\"profileID\":\"\(request.profileID)\"}")
            return LocalProxyReply(ok: true, resolution: resolution)
        }, rollback: { request in
            let result = owners.resolve(request.profileID, request: request.requestID)
            print("{\"event\":\"rollback\",\"resolution\":\"\(result)\"}")
        }, onRollbackFailure: { _ in
            print("{\"event\":\"rollback_failed\"}")
        }) { request in
            guard request.schemaVersion == 1, request.runID == "cross-language", request.key == String(repeating: "k", count: 32), UUID(uuidString: request.requestID) != nil else {
                return .failure(.identity)
            }
            emit(["event":"bridge", "command":request.command, "profileID":request.profileID])
            switch request.command {
            case "order":
                return LocalProxyReply(ok: true, order: ["A", "B"])
            case "acquire":
                if mode == "deny" || !owners.acquire(request.profileID, request: request.requestID) { return .failure(.busy) }
                acquisitions += 1
                if mode == "late" { blockForLateReply() }
                if mode == "writefail" { try? await Task.sleep(nanoseconds: 500_000_000) }
                if mode == "pressure" && request.profileID != "maintenance" {
                    let gate = URL(fileURLWithPath: socket).deletingLastPathComponent().appendingPathComponent("release-gate")
                    while !FileManager.default.fileExists(atPath: gate.path) {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                guard owners.owns(request.profileID, request: request.requestID) else { return .failure(.busy) }
                return LocalProxyReply(ok:true, leaseID:"lease-" + request.profileID,
                    accessToken:"fixture-" + request.profileID, accountID:"fixture-account-" + request.profileID,
                    expiresAt:Int64(Date().timeIntervalSince1970) + 3600)
            case "heartbeat":
                return LocalProxyReply(ok:owners.owns(request.profileID, request: request.requestID))
            case "release":
                guard request.leaseID == "lease-" + request.profileID,
                    owners.release(request.profileID, request: request.requestID) else { return .failure(.identity) }
                releases += 1
                return LocalProxyReply(ok:true)
            default: return .failure(.unavailable)
            }
        }
        emit(["event":"ready"])
        _ = await Task.detached { FileHandle.standardInput.readDataToEndOfFile() }.value
        bridge.stop()
        emit(["event":"stopped", "acquired":acquisitions, "released":releases, "held":owners.count])
        try await Task.sleep(nanoseconds:100_000_000)
    }
}
