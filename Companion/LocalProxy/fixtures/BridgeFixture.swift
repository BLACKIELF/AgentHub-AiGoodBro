import Foundation
import Darwin

@main struct BridgeFixture {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let environment = ProcessInfo.processInfo.environment
        let socket = environment["FIXTURE_SOCKET"]!
        let mode = environment["FIXTURE_MODE"]!
        var owners: [String: String] = [:]
        var acquisitions = 0
        var releases = 0
        func emit(_ value: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
        let bridge = try LocalProxyBridge(path: socket) { request in
            guard request.schemaVersion == 1, request.runID == "cross-language", request.key == String(repeating: "k", count: 32), UUID(uuidString: request.requestID) != nil else {
                return .failure(.identity)
            }
            emit(["event":"bridge", "command":request.command, "profileID":request.profileID])
            switch request.command {
            case "acquire":
                if mode == "deny" || owners[request.profileID] != nil { return .failure(.busy) }
                owners[request.profileID] = request.requestID
                acquisitions += 1
                return LocalProxyReply(ok:true, leaseID:"lease-" + request.profileID,
                    accessToken:"fixture-" + request.profileID, accountID:"fixture-account-" + request.profileID,
                    expiresAt:Int64(Date().timeIntervalSince1970) + 3600)
            case "heartbeat":
                return LocalProxyReply(ok:owners[request.profileID] == request.requestID)
            case "release":
                guard owners[request.profileID] == request.requestID, request.leaseID == "lease-" + request.profileID else { return .failure(.identity) }
                owners.removeValue(forKey: request.profileID)
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
