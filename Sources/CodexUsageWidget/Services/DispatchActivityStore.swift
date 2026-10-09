import CryptoKit
import Darwin
import Foundation

/// Versioned local contract shared with next_dispatch_activity.py. Existing
/// unregistered CLI processes are not adopted, stopped, or declared idle here.
struct DispatchActivityStore {
    private static let proxyRunLock = NSLock()
    private static var closedProxyRuns = Set<String>()
    static let stateName = "dispatch-activity-v1.json"
    static let lockName = ".dispatch-activity.lock"
    static let issueName = "operations-issues-v1.jsonl"
    static let activeStates: Set<String> = ["preparing", "starting", "running", "cancel_requested", "uncertain"]
    static let terminalStates: Set<String> = ["awaiting_acceptance", "accepted", "rejected", "failed", "cancelled"]
    static let live = DispatchActivityStore(directory: DispatchParticipationPaths.supportDirectory())
    let directory: URL

    struct Lease: Decodable {
        let leaseId: String
        let ownerThreadId: String
        let taskId: String
        let accountKey: String
        let aliasKey: String
        let projectKey: String
        let code: String?
        let route: String
        let state: String
        let createdAt: Double
        let updatedAt: Double
        let heartbeatDueAt: Double
        var proxyRunID: String? = nil
        var proxyRequestID: String? = nil
        var proxyProfileKey: String? = nil
        var pid: Int? = nil

        var occupied: Bool { DispatchActivityStore.activeStates.contains(state) }

        func effectiveState(now: Date = Date()) -> String {
            if occupied, heartbeatDueAt < now.timeIntervalSince1970 || updatedAt > now.timeIntervalSince1970 + 5 {
                return "uncertain"
            }
            return state
        }

        func taskStatus(now: Date = Date()) -> HubAccountTaskStatus {
            let phase: HubAccountTaskPhase
            if ["warmup", "maintenance"].contains(route), ["preparing", "starting", "running"].contains(effectiveState(now: now)) {
                return HubAccountTaskStatus(phase: .maintenance, updatedAt: Date(timeIntervalSince1970: updatedAt))
            }
            switch effectiveState(now: now) {
            case "preparing", "starting": phase = .starting
            case "running": phase = .running
            case "cancel_requested": phase = .cancelRequested
            case "uncertain": phase = .uncertain
            case "awaiting_acceptance": phase = .awaitingAcceptance
            case "accepted": phase = .succeeded
            case "failed", "rejected": phase = .failed
            case "cancelled": phase = .cancelled
            default: phase = .unavailable
            }
            return HubAccountTaskStatus(phase: phase, updatedAt: Date(timeIntervalSince1970: updatedAt))
        }
    }

    struct ProxyAcquireKey: Decodable {
        let runID: String
        let requestID: String
        let profileKey: String
        let ownerPID: Int
        let wasReserved: Bool
        let abandoned: Bool
        let requestTime: Int64?
    }

    struct Snapshot: Decodable {
        let schemaVersion: Int
        let leases: [Lease]
        var proxyAcquireKeys: [ProxyAcquireKey]? = nil
        var proxyRequestHighwater: [String: Int64]? = nil

        func latest(forAlias alias: String?, accountKey: String? = nil) -> Lease? {
            let key = alias.map { DispatchActivityStore.hash($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            return leases.filter {
                ($0.aliasKey == key || $0.accountKey == accountKey) && (!["warmup", "maintenance"].contains($0.route) || $0.occupied)
            }.max { a, b in
                a.occupied == b.occupied ? a.updatedAt < b.updatedAt : !a.occupied
            }
        }

        func blocks(accountKey: String) -> Bool {
            leases.contains { $0.accountKey == accountKey && $0.occupied }
        }
    }

    enum Failure: Error { case invalidState, busy, unavailable, deadline, acquireAbandoned }

    /// A stopped run cannot admit a detached reservation even if an earlier
    /// task resumes after the next bridge has been created in this process.
    static func closeProxyRun(_ runID: String) {
        proxyRunLock.lock()
        closedProxyRuns.insert(runID)
        proxyRunLock.unlock()
    }

    private static func requestTime(_ requestID: String) -> Int64? {
        guard let uuid = UUID(uuidString: requestID)?.uuidString.lowercased(), uuid[uuid.index(uuid.startIndex, offsetBy: 14)] == "7" else { return nil }
        return Int64(String(uuid.prefix(8)) + String(uuid.dropFirst(9).prefix(4)), radix: 16)
    }

    private static func checkRequestTime(_ requestID: String, runID: String, highwater: inout [String: Int64], now: Date, enforced: Bool) throws -> Int64? {
        let value = requestTime(requestID)
        if enforced {
            guard let value else { throw Failure.deadline }
            let current = Int64(now.timeIntervalSince1970 * 1000)
            guard value >= current - 120_000, value <= current + 30_000,
                value >= (highwater[runID] ?? value) - 120_000
            else { throw Failure.deadline }
        }
        if let value { highwater[runID] = max(highwater[runID] ?? value, value) }
        return value
    }

    private static func pruneProxyKeys(_ keys: inout [[String: Any]], highwater: [String: Int64]) {
        // A request older than the per-run high-water window is rejected even
        // if the wall clock moves backward. Legacy UUIDv4 keys have no safe
        // time proof and remain until their owning run is retired.
        keys.removeAll { key in
            guard let run = key["runID"] as? String, let time = key["requestTime"] as? Int64,
                let latest = highwater[run]
            else { return false }
            return time < latest - 150_000
        }
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func stateData() throws -> Data? {
        try DispatchParticipationSync.readBoundedRegularFile(
            directory.appendingPathComponent(Self.stateName), maximumBytes: 2 * 1024 * 1024, allowMissing: true)
    }

    func read() throws -> Snapshot {
        guard let data = try stateData() else { return Snapshot(schemaVersion: 1, leases: []) }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> Snapshot {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        let keys = snapshot.proxyAcquireKeys ?? []
        let highwater = snapshot.proxyRequestHighwater ?? [:]
        guard snapshot.schemaVersion == 1, snapshot.leases.count <= 2000, keys.count <= 10000,
            Set(keys.map { "\($0.runID):\($0.requestID):\($0.profileKey)" }).count == keys.count,
            keys.allSatisfy({ key in
                UUID(uuidString: key.runID) != nil && UUID(uuidString: key.requestID) != nil
                    && key.profileKey.count == 64 && key.profileKey.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                    && key.ownerPID > 1 && (key.requestTime == nil || key.requestTime! > 0)
            }),
            highwater.count <= 10000,
            highwater.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 }),
            Set(snapshot.leases.map(\.leaseId)).count == snapshot.leases.count,
            snapshot.leases.allSatisfy({ lease in
                [lease.accountKey, lease.aliasKey, lease.projectKey].allSatisfy {
                    $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                }
                    && !lease.leaseId.isEmpty && !lease.ownerThreadId.isEmpty && !lease.taskId.isEmpty
                    && lease.createdAt.isFinite && lease.updatedAt.isFinite && lease.heartbeatDueAt.isFinite
                    && (activeStates.contains(lease.state) || terminalStates.contains(lease.state))
            })
        else { throw Failure.invalidState }
        return snapshot
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw Failure.unavailable }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw Failure.unavailable }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.unavailable }
        let fd = Darwin.open(directory.appendingPathComponent(Self.lockName).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0
        else { throw Failure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw (errno == EWOULDBLOCK || errno == EAGAIN) ? Failure.busy : Failure.unavailable
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func mutate(onCommit: (() -> Void)? = nil, _ action: (inout [[String: Any]]) throws -> Void) throws {
        try mutateProxy(onCommit: onCommit) { records, _, _ in try action(&records) }
    }

    private func mutateProxy(onCommit: (() -> Void)? = nil, _ action: (inout [[String: Any]], inout [[String: Any]], inout [String: Int64]) throws -> Void) throws {
        try withLock {
            var object: [String: Any]
            if let data = try stateData() {
                _ = try Self.decode(data)
                guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidState }
                object = decoded
            } else {
                object = ["schemaVersion": 1, "leases": [[String: Any]]()]
            }
            guard var records = object["leases"] as? [[String: Any]] else { throw Failure.invalidState }
            var keys = object["proxyAcquireKeys"] as? [[String: Any]] ?? []
            var highwater = object["proxyRequestHighwater"] as? [String: Int64] ?? [:]
            try action(&records, &keys, &highwater)
            object["leases"] = records
            object["proxyAcquireKeys"] = keys
            object["proxyRequestHighwater"] = highwater
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            _ = try Self.decode(data)
            guard data.count <= 2 * 1024 * 1024 else { throw Failure.invalidState }
            let temporary = directory.appendingPathComponent(".dispatch-activity-\(UUID().uuidString)")
            let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.unavailable }
            defer {
                Darwin.close(fd)
                try? FileManager.default.removeItem(at: temporary)
            }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == data.count, fsync(fd) == 0,
                rename(temporary.path, directory.appendingPathComponent(Self.stateName).path) == 0
            else { throw Failure.unavailable }
            // Publish local admission fences only after the durable swap, while
            // competing registry admissions still cannot acquire the file lock.
            onCommit?()
        }
    }

    /// A proxy lease is bound to one run/request/profile, never a renewable account credential.
    func reserveProxy(
        account: String, alias: String, runID: String, requestID: String, profileID: String, childPID: pid_t, admissionDeadline: TimeInterval? = nil,
        enforceFreshness: Bool = false, now: Date = Date()
    ) throws -> String {
        guard UUID(uuidString: runID) != nil, UUID(uuidString: requestID) != nil, childPID > 1 else { throw Failure.invalidState }
        let id = UUID().uuidString.lowercased()
        let accountKey = Self.hash(account)
        let aliasKey = Self.hash(alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        Self.proxyRunLock.lock()
        defer { Self.proxyRunLock.unlock() }
        guard !Self.closedProxyRuns.contains(runID), admissionDeadline == nil || ProcessInfo.processInfo.systemUptime < admissionDeadline! else { throw Failure.deadline }
        try mutateProxy { records, keys, highwater in
            guard admissionDeadline == nil || ProcessInfo.processInfo.systemUptime < admissionDeadline! else { throw Failure.deadline }
            let requestTime = try Self.checkRequestTime(requestID, runID: runID, highwater: &highwater, now: now, enforced: enforceFreshness)
            let profileKey = Self.hash(profileID)
            if keys.contains(where: {
                $0["runID"] as? String == runID && $0["requestID"] as? String == requestID
                    && $0["profileKey"] as? String == profileKey && $0["abandoned"] as? Bool == true
                    && $0["ownerPID"] as? Int == Int(getpid())
            }) { throw Failure.acquireAbandoned }
            guard
                !keys.contains(where: {
                    $0["runID"] as? String == runID && $0["requestID"] as? String == requestID
                        && $0["profileKey"] as? String == profileKey
                }),
                !records.contains(where: {
                    $0["route"] as? String == "proxy" && $0["proxyRunID"] as? String == runID
                        && $0["proxyRequestID"] as? String == requestID && $0["proxyProfileKey"] as? String == profileKey
                })
            else { throw Failure.busy }
            guard
                !records.contains(where: {
                    Self.activeStates.contains($0["state"] as? String ?? "") && ($0["accountKey"] as? String == accountKey || $0["aliasKey"] as? String == aliasKey)
                })
            else { throw Failure.busy }
            records.append([
                "leaseId": id, "ownerThreadId": "next-\(getpid())", "taskId": "proxy-\(runID)-\(requestID)",
                "accountKey": accountKey, "aliasKey": aliasKey, "projectKey": Self.hash("proxy:" + profileID),
                "route": "proxy", "state": "preparing", "proxyRunID": runID, "proxyRequestID": requestID,
                "proxyProfileKey": Self.hash(profileID), "pid": Int(childPID),
                "createdAt": now.timeIntervalSince1970, "updatedAt": now.timeIntervalSince1970,
                "heartbeatDueAt": now.timeIntervalSince1970 + 60,
            ])
            var marker: [String: Any] = [
                "runID": runID, "requestID": requestID, "profileKey": profileKey,
                "ownerPID": Int(getpid()), "wasReserved": true, "abandoned": false,
            ]
            if let requestTime { marker["requestTime"] = requestTime }
            keys.append(marker)
            Self.pruneProxyKeys(&keys, highwater: highwater)
        }
        return id
    }

    enum ProxyResolution: String {
        case abandoned
        case notReserved = "not_reserved"
    }

    func isProxyAcquireAbandoned(runID: String, requestID: String, profileID: String) throws -> Bool {
        let profileKey = Self.hash(profileID)
        return try read().proxyAcquireKeys?.contains {
            $0.runID == runID && $0.requestID == requestID && $0.profileKey == profileKey
                && $0.ownerPID == Int(getpid()) && $0.abandoned
        } == true
    }

    /// A detached registry update can finish after an off-main resolver has
    /// cancelled the same request, before its MainActor cleanup runs.
    func isProxyLeaseActive(_ id: String, runID: String, requestID: String, profileID: String, childPID: pid_t, verifyAdmission: (() throws -> Void)? = nil) throws -> Bool {
        try withLock {
            let snapshot = try read()
            try verifyAdmission?()
            let profileKey = Self.hash(profileID)
            guard
                snapshot.proxyAcquireKeys?.contains(where: {
                    $0.runID == runID && $0.requestID == requestID && $0.profileKey == profileKey
                        && $0.ownerPID == Int(getpid()) && $0.wasReserved && !$0.abandoned
                }) == true
            else { return false }
            return snapshot.leases.contains {
                $0.leaseId == id && $0.ownerThreadId == "next-\(getpid())"
                    && $0.taskId == "proxy-\(runID)-\(requestID)" && $0.route == "proxy"
                    && $0.proxyRunID == runID && $0.proxyRequestID == requestID
                    && $0.proxyProfileKey == profileKey && $0.pid == Int(childPID)
                    && $0.state == "running"
            }
        }
    }

    /// The reservation and the deny marker share the same file lock. A late
    /// acquire can never pass after a successful no-reservation resolution.
    func abandonProxy(runID: String, requestID: String, profileID: String, enforceFreshness: Bool = false, now: Date = Date()) throws -> ProxyResolution {
        guard UUID(uuidString: runID) != nil, UUID(uuidString: requestID) != nil else { throw Failure.invalidState }
        let profileKey = Self.hash(profileID)
        var resolution: ProxyResolution = .notReserved
        try mutateProxy { records, keys, highwater in
            let requestTime = try Self.checkRequestTime(requestID, runID: runID, highwater: &highwater, now: now, enforced: enforceFreshness)
            let keyIndex = keys.firstIndex {
                $0["runID"] as? String == runID && $0["requestID"] as? String == requestID
                    && $0["profileKey"] as? String == profileKey
            }
            if let keyIndex, keys[keyIndex]["ownerPID"] as? Int != Int(getpid()) { throw Failure.invalidState }
            let matches = records.indices.filter {
                records[$0]["route"] as? String == "proxy" && records[$0]["proxyRunID"] as? String == runID
                    && records[$0]["proxyRequestID"] as? String == requestID && records[$0]["proxyProfileKey"] as? String == profileKey
            }
            guard matches.count <= 1 else { throw Failure.invalidState }
            if let index = matches.first {
                guard records[index]["ownerThreadId"] as? String == "next-\(getpid())",
                    records[index]["taskId"] as? String == "proxy-\(runID)-\(requestID)"
                else { throw Failure.invalidState }
                let state = records[index]["state"] as? String ?? ""
                if Self.activeStates.contains(state) {
                    records[index]["state"] = "cancelled"
                    records[index]["updatedAt"] = now.timeIntervalSince1970
                    records[index]["heartbeatDueAt"] = now.timeIntervalSince1970
                } else if state != "cancelled" {
                    // An accepted request may have reached the upstream. Its
                    // outcome cannot be made safe by writing a marker now.
                    throw Failure.invalidState
                }
                resolution = .abandoned
            } else if let keyIndex, keys[keyIndex]["wasReserved"] as? Bool == true {
                // A reserved lease vanished from bounded history. Do not claim
                // a successful rollback without evidence of its final state.
                throw Failure.invalidState
            }
            if let keyIndex {
                keys[keyIndex]["abandoned"] = true
                resolution = (keys[keyIndex]["wasReserved"] as? Bool == true) ? .abandoned : .notReserved
            } else {
                var marker: [String: Any] = [
                    "runID": runID, "requestID": requestID, "profileKey": profileKey,
                    "ownerPID": Int(getpid()), "wasReserved": resolution == .abandoned, "abandoned": true,
                ]
                if let requestTime { marker["requestTime"] = requestTime }
                keys.append(marker)
            }
            records = records.filter { Self.activeStates.contains($0["state"] as? String ?? "") } + Self.recentEndedRecords(records)
            Self.pruneProxyKeys(&keys, highwater: highwater)
        }
        return resolution
    }

    func updateProxy(
        _ id: String, runID: String, requestID: String, profileID: String, state: String,
        allowTerminalCleanup: Bool = false, now: Date = Date(), onCommit: (() -> Void)? = nil
    ) throws {
        guard ["running", "uncertain", "accepted", "cancelled"].contains(state),
            !allowTerminalCleanup || state == "cancelled"
        else { throw Failure.invalidState }
        try mutate(onCommit: onCommit) { records in
            guard
                let index = records.firstIndex(where: {
                    $0["leaseId"] as? String == id && $0["ownerThreadId"] as? String == "next-\(getpid())"
                        && $0["route"] as? String == "proxy" && $0["proxyRunID"] as? String == runID
                        && $0["proxyRequestID"] as? String == requestID && $0["proxyProfileKey"] as? String == Self.hash(profileID)
                })
            else { throw Failure.invalidState }
            let currentState = records[index]["state"] as? String ?? ""
            // A release can commit off-main before its UI cleanup runs. Once
            // the child is proven gone, retire that exact in-memory mirror
            // without changing its terminal outcome or reviving ownership.
            if allowTerminalCleanup, Self.terminalStates.contains(currentState) { return }
            guard Self.activeStates.contains(currentState) else { throw Failure.invalidState }
            records[index]["state"] = state
            records[index]["updatedAt"] = now.timeIntervalSince1970
            records[index]["heartbeatDueAt"] = now.timeIntervalSince1970 + (Self.activeStates.contains(state) ? 60 : 0)
            records = records.filter { Self.activeStates.contains($0["state"] as? String ?? "") } + Self.recentEndedRecords(records)
        }
    }

    /// Recovery requires both recorded owner and child PIDs to be proven gone.
    /// PID reuse or permission errors retain the uncertain reservation.
    func finishStoppedProxyRuns(retiringCurrentRun: Bool = false, now: Date = Date()) throws {
        Self.proxyRunLock.lock()
        defer { Self.proxyRunLock.unlock() }
        try mutateProxy { records, keys, highwater in
            for i in records.indices {
                guard records[i]["route"] as? String == "proxy",
                    Self.activeStates.contains(records[i]["state"] as? String ?? ""),
                    let owner = records[i]["ownerThreadId"] as? String, owner.hasPrefix("next-"),
                    let run = records[i]["proxyRunID"] as? String, UUID(uuidString: run) != nil,
                    let request = records[i]["proxyRequestID"] as? String, UUID(uuidString: request) != nil,
                    records[i]["taskId"] as? String == "proxy-\(run)-\(request)"
                else { continue }
                if owner == "next-\(getpid())" {
                    guard retiringCurrentRun, Self.closedProxyRuns.contains(run) else { continue }
                } else {
                    guard let parent = pid_t(owner.dropFirst(5)), parent > 1,
                        let child = records[i]["pid"] as? Int, child > 1, child <= Int(Int32.max),
                        kill(parent, 0) != 0, errno == ESRCH,
                        kill(pid_t(child), 0) != 0, errno == ESRCH
                    else { continue }
                }
                records[i]["state"] = "cancelled"
                records[i]["updatedAt"] = now.timeIntervalSince1970
                records[i]["heartbeatDueAt"] = now.timeIntervalSince1970
            }
            // Called before creating the next bridge. This process has no old
            // run to accept a replay; a dead owner has no socket at all.
            keys.removeAll { key in
                guard let owner = key["ownerPID"] as? Int, owner > 1 else { return false }
                if owner == Int(getpid()) {
                    return retiringCurrentRun && (key["runID"] as? String).map { Self.closedProxyRuns.contains($0) } == true
                }
                return kill(pid_t(owner), 0) != 0 && errno == ESRCH
            }
            for run in Array(highwater.keys) where !keys.contains(where: { $0["runID"] as? String == run }) {
                highwater.removeValue(forKey: run)
            }
        }
    }

    func reserveWarmUp(account: String, alias: String, now: Date = Date()) throws -> String {
        try reserveAccountActivity(account: account, alias: alias, route: "warmup", now: now)
    }

    /// Native warm-up uses an ephemeral, in-process URLSession, not a CLI child.
    /// An expired heartbeat is never enough: a live/reused/unknown owner keeps
    /// its reservation. Persist the ambiguous result before ending the lease.
    @discardableResult
    func finishInterruptedWarmUp(
        id: String, account: String, alias: String, requestStartedAt: Date,
        now: Date = Date(), persistInterruptedResult: () throws -> Void
    ) throws -> Bool {
        let accountKey = Self.hash(account)
        let aliasKey = Self.hash(alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        var recovered = false
        try mutate { records in
            guard let index = records.firstIndex(where: { $0["leaseId"] as? String == id }) else { return }
            let row = records[index]
            guard UUID(uuidString: id) != nil,
                Set(row.keys).isSubset(of: ["leaseId", "ownerThreadId", "taskId", "accountKey", "aliasKey", "projectKey", "route", "state", "createdAt", "updatedAt", "heartbeatDueAt", "warmUpTransport"]),
                row["route"] as? String == "warmup", row["state"] as? String == "preparing",
                row["taskId"] as? String == "warmup-\(id)",
                row["accountKey"] as? String == accountKey, row["aliasKey"] as? String == aliasKey,
                row["projectKey"] as? String == Self.hash("warmup:\(accountKey)"),
                row["pid"] == nil, row["childPID"] == nil, row["childPIDBirth"] == nil,
                row["processGroupID"] == nil, row["processGroupBirth"] == nil,
                row["proxyRunID"] == nil, row["proxyRequestID"] == nil, row["proxyProfileKey"] == nil,
                row["warmUpTransport"] == nil || row["warmUpTransport"] as? String == "native-ephemeral-http-v1",
                let owner = row["ownerThreadId"] as? String, owner.hasPrefix("next-"),
                let ownerPID = pid_t(owner.dropFirst(5)), owner == "next-\(ownerPID)", ownerPID > 1, ownerPID != getpid(),
                let created = row["createdAt"] as? Double, let updated = row["updatedAt"] as? Double,
                let due = row["heartbeatDueAt"] as? Double,
                [created, updated, due, requestStartedAt.timeIntervalSince1970, now.timeIntervalSince1970].allSatisfy({ $0.isFinite }),
                created > 0, updated == created, due == created + 600,
                requestStartedAt.timeIntervalSince1970 >= created, requestStartedAt.timeIntervalSince1970 <= due,
                now.timeIntervalSince1970 > due,
                kill(ownerPID, 0) != 0, errno == ESRCH
            else { return }
            // The profile lock is acquired only here; existing warm-up paths
            // release that lock before touching the activity registry.
            try persistInterruptedResult()
            // Recheck after the profile write; PID reuse must remain fail-closed.
            guard kill(ownerPID, 0) != 0, errno == ESRCH else { return }
            records[index]["state"] = "failed"
            records[index]["updatedAt"] = now.timeIntervalSince1970
            records[index]["heartbeatDueAt"] = now.timeIntervalSince1970
            recovered = true
        }
        return recovered
    }

    func reserveMaintenance(account: String, alias: String, now: Date = Date()) throws -> String {
        try reserveAccountActivity(account: account, alias: alias, route: "maintenance", now: now)
    }

    /// Source and target are reserved together, so a busy second account never
    /// leaves the first account with an orphaned preparation reservation.
    func reserveMaintenance(accounts: [(account: String, alias: String)], now: Date = Date()) throws -> [String] {
        let keys = accounts.map { (account: Self.hash($0.account), alias: Self.hash($0.alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())) }
        guard !keys.isEmpty, keys.count <= 2, Set(keys.map(\.account)).count == keys.count,
            Set(keys.map(\.alias)).count == keys.count
        else { throw Failure.invalidState }
        let ids = keys.map { _ in UUID().uuidString.lowercased() }
        try mutate { records in
            guard
                !records.contains(where: { row in
                    Self.activeStates.contains(row["state"] as? String ?? "")
                        && keys.contains { $0.account == row["accountKey"] as? String || $0.alias == row["aliasKey"] as? String }
                })
            else { throw Failure.busy }
            for (index, key) in keys.enumerated() {
                records.append([
                    "leaseId": ids[index], "ownerThreadId": "next-\(getpid())", "taskId": "desktop-switch-\(ids[index])",
                    "accountKey": key.account, "aliasKey": key.alias, "projectKey": Self.hash("maintenance:\(key.account)"),
                    "route": "maintenance", "state": "preparing", "createdAt": now.timeIntervalSince1970,
                    "updatedAt": now.timeIntervalSince1970, "heartbeatDueAt": now.timeIntervalSince1970 + 600,
                ])
            }
        }
        return ids
    }

    /// Called only after switch-journal recovery has completed. An expired
    /// heartbeat alone never releases another process's reservation.
    func finishRecoveredDesktopMaintenance(recoveryIsClear: Bool, now: Date = Date()) throws {
        guard recoveryIsClear else { return }
        try mutate { records in
            for index in records.indices {
                guard records[index]["route"] as? String == "maintenance",
                    let id = records[index]["leaseId"] as? String,
                    records[index]["taskId"] as? String == "desktop-switch-\(id)",
                    Self.activeStates.contains(records[index]["state"] as? String ?? ""),
                    let owner = records[index]["ownerThreadId"] as? String, owner.hasPrefix("next-"),
                    let pid = pid_t(owner.dropFirst(5)), pid > 1, pid != getpid(),
                    kill(pid, 0) != 0, errno == ESRCH
                else { continue }
                records[index]["state"] = "cancelled"
                records[index]["updatedAt"] = now.timeIntervalSince1970
                records[index]["heartbeatDueAt"] = now.timeIntervalSince1970
            }
        }
    }

    private func reserveAccountActivity(account: String, alias: String, route: String, now: Date) throws -> String {
        let accountKey = Self.hash(account)
        let aliasKey = Self.hash(alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let id = UUID().uuidString.lowercased()
        try mutate { records in
            guard
                !records.contains(where: {
                    (($0["accountKey"] as? String) == accountKey || ($0["aliasKey"] as? String) == aliasKey) && Self.activeStates.contains($0["state"] as? String ?? "")
                })
            else { throw Failure.busy }
            let current = now.timeIntervalSince1970
            let owner = "next-\(getpid())"
            records.append([
                "leaseId": id, "ownerThreadId": owner, "taskId": "\(route)-\(id)",
                "accountKey": accountKey, "aliasKey": aliasKey,
                "projectKey": Self.hash("\(route):\(accountKey)"), "route": route, "state": "preparing",
                "createdAt": current, "updatedAt": current, "heartbeatDueAt": current + 600,
            ])
            if route == "warmup" { records[records.count - 1]["warmUpTransport"] = "native-ephemeral-http-v1" }
        }
        return id
    }

    func reserveTerminal(account: String, alias: String, workingDirectory: URL, now: Date = Date()) throws -> String {
        let accountKey = Self.hash(account)
        let aliasKey = Self.hash(alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let projectKey = Self.hash(workingDirectory.resolvingSymlinksInPath().standardizedFileURL.path)
        let id = UUID().uuidString.lowercased()
        try mutate { records in
            guard
                !records.contains(where: {
                    Self.activeStates.contains($0["state"] as? String ?? "")
                        && (($0["accountKey"] as? String) == accountKey || ($0["aliasKey"] as? String) == aliasKey || ($0["projectKey"] as? String) == projectKey)
                })
            else { throw Failure.busy }
            let current = now.timeIntervalSince1970
            records.append([
                "leaseId": id, "ownerThreadId": "next-\(getpid())", "taskId": "terminal-\(id)",
                "accountKey": accountKey, "aliasKey": aliasKey, "projectKey": projectKey,
                "route": "terminal", "state": "preparing",
                "createdAt": current, "updatedAt": current, "heartbeatDueAt": current + 120,
            ])
        }
        return id
    }

    func updateTerminal(_ id: String, state: String, pid: pid_t? = nil, now: Date = Date()) throws {
        guard ["running", "uncertain", "cancelled", "failed", "awaiting_acceptance"].contains(state) else { throw Failure.invalidState }
        try mutate { records in
            guard
                let index = records.firstIndex(where: {
                    ($0["leaseId"] as? String) == id && ($0["ownerThreadId"] as? String) == "next-\(getpid())" && ($0["route"] as? String) == "terminal"
                }), Self.activeStates.contains(records[index]["state"] as? String ?? "")
            else { throw Failure.invalidState }
            records[index]["state"] = state
            records[index]["updatedAt"] = now.timeIntervalSince1970
            records[index]["heartbeatDueAt"] = now.timeIntervalSince1970 + (Self.activeStates.contains(state) ? 120 : 0)
            if let pid { records[index]["pid"] = Int(pid) }
            let active = records.filter { Self.activeStates.contains($0["state"] as? String ?? "") }
            let ended = Self.recentEndedRecords(records)
            records = active + ended
        }
    }

    /// Only Next-owned terminal receipts can be resumed, and only after the
    /// original app process has ended. Expired heartbeats never prove this.
    func resumeTerminal(_ lease: Lease, now: Date = Date()) throws {
        guard lease.route == "terminal", lease.taskId == "terminal-\(lease.leaseId)",
            lease.ownerThreadId.hasPrefix("next-"),
            let previousPID = pid_t(lease.ownerThreadId.dropFirst(5)), previousPID > 1,
            previousPID == getpid() || (kill(previousPID, 0) != 0 && errno == ESRCH)
        else { throw Failure.busy }
        try mutate { records in
            guard
                let index = records.firstIndex(where: {
                    ($0["leaseId"] as? String) == lease.leaseId && ($0["ownerThreadId"] as? String) == lease.ownerThreadId
                        && ($0["route"] as? String) == "terminal" && Self.activeStates.contains($0["state"] as? String ?? "")
                })
            else { throw Failure.invalidState }
            records[index]["ownerThreadId"] = "next-\(getpid())"
            records[index]["state"] = "uncertain"
            records[index]["updatedAt"] = now.timeIntervalSince1970
            records[index]["heartbeatDueAt"] = now.timeIntervalSince1970 + 120
        }
    }

    func finishWarmUp(_ id: String, succeeded: Bool, cancelled: Bool = false, now: Date = Date()) throws {
        try finishAccountActivity(id, route: "warmup", succeeded: succeeded, cancelled: cancelled, now: now)
    }

    func finishMaintenance(_ id: String, succeeded: Bool, now: Date = Date()) throws {
        try finishAccountActivity(id, route: "maintenance", succeeded: succeeded, cancelled: false, now: now)
    }

    private func finishAccountActivity(_ id: String, route: String, succeeded: Bool, cancelled: Bool, now: Date) throws {
        try mutate { records in
            guard
                let index = records.firstIndex(where: {
                    ($0["leaseId"] as? String) == id && ($0["ownerThreadId"] as? String) == "next-\(getpid())" && ($0["route"] as? String) == route
                })
            else { throw Failure.invalidState }
            records[index]["state"] = cancelled ? "cancelled" : (succeeded ? "accepted" : "failed")
            records[index]["updatedAt"] = now.timeIntervalSince1970
            records[index]["heartbeatDueAt"] = now.timeIntervalSince1970
            // Keep active records and bounded terminal history; this is status,
            // not the append-only incident journal.
            let active = records.filter { Self.activeStates.contains($0["state"] as? String ?? "") }
            let ended = Self.recentEndedRecords(records)
            records = active + ended
        }
    }

    /// A formerly active lease may be first in the array. Retain by completion
    /// time so the next write cannot evict a just-finished task before acceptance.
    static func recentEndedRecords(_ records: [[String: Any]]) -> [[String: Any]] {
        Array(
            records.filter { !activeStates.contains($0["state"] as? String ?? "") }
                .sorted {
                    let left = $0["updatedAt"] as? Double ?? 0
                    let right = $1["updatedAt"] as? Double ?? 0
                    return left == right
                        ? ($0["leaseId"] as? String ?? "") < ($1["leaseId"] as? String ?? "")
                        : left < right
                }.suffix(100))
    }

    /// Fixed application messages only. Raw errors, account names and paths never
    /// enter the shared journal; the Skill appends its observations to this file.
    func appendIssue(id: String, phase: String, summary: String, code: String? = nil, now: Date = Date()) throws {
        let identifier = #"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z"#
        let forbidden = #"(?i)(?:[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|(?:/Users/|/home/|/var/|~/|https?://)|(?:sk-|Bearer\s|access_token|refresh_token|webhook))"#
        guard [id, phase].allSatisfy({ $0.range(of: identifier, options: .regularExpression) != nil }),
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            summary.unicodeScalars.count <= 1200,
            summary.range(of: forbidden, options: .regularExpression) == nil,
            code == nil || (code!.utf8.count == 1 && code!.utf8.allSatisfy({ (65...90).contains($0) }))
        else { throw Failure.invalidState }
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let utc = date.string(from: now)
        date.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var object: [String: Any] = [
            "schemaVersion": 1, "issueId": id, "component": "next", "phase": phase,
            "recordedAt": utc, "dateShanghai": date.string(from: now), "summary": summary,
            "ownerThreadId": "next-\(getpid())",
        ]
        if let code, code.count == 1, code.utf8.allSatisfy({ (65...90).contains($0) }) { object["code"] = code }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        try withLock {
            let fd = Darwin.open(directory.appendingPathComponent(Self.issueName).path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0
            else { throw Failure.unavailable }
            guard data.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == data.count, fsync(fd) == 0 else {
                // Roll back this append while still holding the shared lock.
                // Failure remains visible even if storage cannot restore it.
                guard ftruncate(fd, info.st_size) == 0, fsync(fd) == 0 else { throw Failure.unavailable }
                throw Failure.unavailable
            }
        }
    }
}

enum DispatchActivityStoreSelfTest {
    static func run() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-activity-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DispatchActivityStore(directory: root)
        do {
            let oldRecords: [[String: Any]] = (0..<101).map {
                ["leaseId": "old-\($0)", "state": "accepted", "updatedAt": Double($0)]
            }
            let recent: [String: Any] = ["leaseId": "just-finished", "state": "awaiting_acceptance", "updatedAt": 500.0]
            let retained = DispatchActivityStore.recentEndedRecords([recent] + oldRecords)
            guard retained.count == 100,
                retained.last?["leaseId"] as? String == "just-finished",
                !retained.contains(where: { $0["leaseId"] as? String == "old-0" })
            else { return false }
            guard try store.read().leases.isEmpty else { return false }
            let id = try store.reserveWarmUp(account: "fixture-account", alias: "fixture-alias")
            let snapshot = try store.read()
            guard snapshot.blocks(accountKey: DispatchActivityStore.hash("fixture-account")),
                snapshot.latest(forAlias: "fixture-alias")?.taskStatus().phase == .maintenance,
                snapshot.latest(forAlias: nil, accountKey: DispatchActivityStore.hash("fixture-account"))?.taskStatus().phase == .maintenance,
                snapshot.latest(forAlias: nil, accountKey: DispatchActivityStore.hash("another-account")) == nil
            else { return false }
            do {
                _ = try store.reserveWarmUp(account: "fixture-account", alias: "other-alias")
                return false
            } catch DispatchActivityStore.Failure.busy {}
            guard snapshot.leases[0].effectiveState(now: Date().addingTimeInterval(601)) == "uncertain" else { return false }
            try store.finishWarmUp(id, succeeded: true)
            guard try !store.read().blocks(accountKey: DispatchActivityStore.hash("fixture-account")),
                try store.read().latest(forAlias: nil, accountKey: DispatchActivityStore.hash("fixture-account")) == nil
            else { return false }
            let cli = try store.reserveTerminal(account: "fixture-account", alias: "fixture-alias", workingDirectory: root)
            let beforeBatch = try store.read().leases.count
            do {
                _ = try store.reserveMaintenance(accounts: [("unused-account", "unused-alias"), ("fixture-account", "fixture-alias")])
                return false
            } catch DispatchActivityStore.Failure.busy {}
            guard try store.read().leases.count == beforeBatch else { return false }
            let pair = try store.reserveMaintenance(accounts: [("source-account", "source-alias"), ("target-account", "target-alias")])
            guard pair.count == 2, try store.read().blocks(accountKey: DispatchActivityStore.hash("source-account")),
                try store.read().blocks(accountKey: DispatchActivityStore.hash("target-account"))
            else { return false }
            for lease in pair { try store.finishMaintenance(lease, succeeded: false) }
            do {
                _ = try store.reserveWarmUp(account: "fixture-account", alias: "fixture-alias")
                return false
            } catch DispatchActivityStore.Failure.busy {}
            do {
                _ = try store.reserveTerminal(account: "another-account", alias: "another-alias", workingDirectory: root)
                return false
            } catch DispatchActivityStore.Failure.busy {}
            try store.updateTerminal(cli, state: "running", pid: getpid())
            guard try store.read().latest(forAlias: "fixture-alias")?.taskStatus().phase == .running else { return false }
            try store.updateTerminal(cli, state: "uncertain")
            guard try store.read().blocks(accountKey: DispatchActivityStore.hash("fixture-account")) else { return false }
            try store.updateTerminal(cli, state: "awaiting_acceptance")
            guard try !store.read().blocks(accountKey: DispatchActivityStore.hash("fixture-account")) else { return false }
            try store.appendIssue(id: "fixture-issue", phase: "observed", summary: "First observation")
            try store.appendIssue(id: "fixture-issue", phase: "verified", summary: "Second observation")
            let lines = try String(contentsOf: root.appendingPathComponent(DispatchActivityStore.issueName), encoding: .utf8).split(separator: "\n")
            guard lines.count == 2, lines.allSatisfy({ $0.contains("dateShanghai") }),
                !lines.contains(where: { $0.contains(root.path) || $0.contains("fixture-account") })
            else { return false }
            let stateURL = root.appendingPathComponent(DispatchActivityStore.stateName)
            try Data("{broken".utf8).write(to: stateURL)
            do {
                _ = try store.read()
                return false
            } catch {}
            print("Dispatch activity store self-test passed")
            return true
        } catch {
            print("Dispatch activity store self-test failed")
            return false
        }
    }
}
