import Foundation
import Darwin

enum FixtureProbe {
    static var results: [Int32] = [ESRCH, ESRCH]
    static var count = 0
    static var failRegistrySave = false
    static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
        count += 1
        let result = results.isEmpty ? ESRCH : results.removeFirst()
        if result == 0 { return 0 }
        errno = result
        return -1
    }
}

enum FixtureError: Error { case failed(String) }
func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw FixtureError.failed(message) }
}

@main struct Fixture {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let activity = DispatchActivityStore(directory: root)
        let stateURL = root.appendingPathComponent(DispatchActivityStore.stateName)
        let account = "synthetic-account", alias = "synthetic-alias", id = UUID().uuidString.lowercased()
        let start = Date(timeIntervalSince1970: 1001), now = Date(timeIntervalSince1970: 2000)
        let request = CodexWarmUpRequest(id: id, accountID: "synthetic-account-id", startedAt: start,
            limitID: "limit", fiveHourResetAt: Date(timeIntervalSince1970: 3000),
            sevenDayResetAt: Date(timeIntervalSince1970: 5000), source: "automatic")
        let profile = CodexProfile(id: "fixture", recordedAccountKey: account, warmUpRequest: request,
            lastSnapshot: FixtureSnapshot(accountID: request.accountID), lastWarmUpAt: start)
        let base: [String: Any] = [
            "leaseId": id, "ownerThreadId": "next-2147483646", "taskId": "warmup-\(id)",
            "accountKey": DispatchActivityStore.hash(account), "aliasKey": DispatchActivityStore.hash(alias),
            "projectKey": DispatchActivityStore.hash("warmup:\(DispatchActivityStore.hash(account))"),
            "route": "warmup", "state": "preparing", "createdAt": 1000.0,
            "updatedAt": 1000.0, "heartbeatDueAt": 1600.0,
        ]
        func write(_ row: [String: Any]) throws {
            let extra: [String: Any] = ["leaseId": "unrelated", "ownerThreadId": "external-owner", "taskId": "external-task",
                "accountKey": DispatchActivityStore.hash("other"), "aliasKey": DispatchActivityStore.hash("other"),
                "projectKey": DispatchActivityStore.hash("other"), "route": "direct", "state": "running",
                "createdAt": 1000.0, "updatedAt": 1000.0, "heartbeatDueAt": 1600.0]
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "leases": [row, extra]]).write(to: stateURL)
            FixtureProbe.count = 0; FixtureProbe.results = [ESRCH, ESRCH]
        }
        func recover(_ profiles: CodexProfileStore, at date: Date? = nil) throws -> Bool {
            try activity.finishInterruptedWarmUp(id: id, account: account, alias: alias, requestStartedAt: start, now: date ?? now) {
                // The shared activity lock remains held through the profile save.
                try profiles.recordInterruptedWarmUp(request: request, for: profile.id, expectedAccountKey: account, at: date ?? now)
            }
        }
        var passed = 0
        for marker in [false, true] {
            var row = base
            if marker { row["warmUpTransport"] = "native-ephemeral-http-v1" }
            try write(row)
            let profiles = CodexProfileStore([profile])
            profiles.onSave = {
                let fd = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR)
                defer { Darwin.close(fd) }
                try expect(flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK, "registry lock spans profile save")
                try expect(activity.read().leases.first?.state == "preparing", "profile saved before lease ends")
            }
            try expect(recover(profiles), "legacy and marked dead owner recover")
            try expect(profiles.state.profiles[0].lastWarmUpFailureReason == "interrupted", "ambiguous outcome saved")
            try expect(profiles.state.profiles[0].warmUpRequest == request, "quota-window ticket preserved")
            try expect(activity.read().leases[0].state == "failed", "lease ended after profile save")
            try expect(activity.read().leases[1].state == "running", "unrelated activity retained")
            try expect(!recover(profiles), "terminal lease cannot recover twice")
            let reserved = try activity.reserveProxy(account: account, alias: alias, runID: UUID().uuidString,
                requestID: UUID().uuidString, profileID: "fixture", childPID: getpid())
            try expect(!reserved.isEmpty, "subscription proxy becomes admissible after recovery")
            passed += 1
        }
        let cases: [(String, Any)] = [
            ("ownerThreadId", "next-\(getpid())"), ("ownerThreadId", "next-00012"), ("ownerThreadId", "external-owner"),
            ("route", "proxy"), ("state", "running"), ("state", "uncertain"), ("state", "cancel_requested"),
            ("taskId", "mismatch"), ("accountKey", DispatchActivityStore.hash("wrong")),
            ("aliasKey", DispatchActivityStore.hash("wrong")), ("projectKey", DispatchActivityStore.hash("wrong")),
            ("pid", 99), ("childPID", Int(getpid())), ("childPID", "unknown"), ("childPIDBirth", "unknown"),
            ("processGroupID", Int(getpid())), ("processGroupBirth", "unknown"),
            ("runnerPID", Int(getpid())), ("runnerPIDBirth", "unknown"), ("hubTaskId", "unknown"), ("exitCode", 0), ("futureEvidence", "unknown"),
            ("proxyRunID", UUID().uuidString), ("proxyRequestID", UUID().uuidString),
            ("proxyProfileKey", DispatchActivityStore.hash("wrong")), ("warmUpTransport", "unknown"),
            ("updatedAt", 1002.0), ("createdAt", 1002.0), ("createdAt", 0.0), ("heartbeatDueAt", 999.0),
        ]
        for (key, value) in cases {
            var row = base; row[key] = value; try write(row)
            let profiles = CodexProfileStore([profile])
            try expect(!recover(profiles) && profiles.saveCount == 0, "invalid tuple retains \(key)")
            try expect(activity.read().leases[0].occupied, "invalid tuple still occupied")
            passed += 1
        }
        for evidence in [Int32(0), EPERM, EINVAL] {
            try write(base); FixtureProbe.results = [evidence]
            let profiles = CodexProfileStore([profile])
            try expect(!recover(profiles) && profiles.saveCount == 0, "alive reused or unknown PID blocked")
            passed += 1
        }
        var foreign = base
        foreign["leaseId"] = "non-native-request"; foreign["taskId"] = "warmup-non-native-request"
        try write(foreign)
        var foreignSaved = false
        try expect(!activity.finishInterruptedWarmUp(id: "non-native-request", account: account, alias: alias,
            requestStartedAt: start, now: now) { foreignSaved = true }, "non-UUID native request blocked")
        try expect(!foreignSaved && activity.read().leases[0].occupied, "foreign protocol never saved or released")
        passed += 1
        for time in [1500.0, 1600.0, 900.0] {
            try write(base); let profiles = CodexProfileStore([profile])
            try expect(!recover(profiles, at: Date(timeIntervalSince1970: time)), "unexpired/future lease blocked")
            passed += 1
        }
        for change in 0..<6 {
            try write(base); var invalid = profile
            switch change {
            case 0: invalid.warmUpRequest = nil
            case 1: invalid.recordedAccountKey = "wrong"
            case 2: invalid.lastSnapshot = FixtureSnapshot(accountID: "wrong")
            case 3: invalid.identityMatches = false
            case 4: invalid.lastWarmUpSucceeded = true
            default: invalid.lastWarmUpFailureReason = "stream-incomplete"
            }
            let profiles = CodexProfileStore([invalid]); let before = try Data(contentsOf: stateURL)
            do { _ = try recover(profiles); throw FixtureError.failed("profile CAS accepted mismatch") }
            catch CodexProfileStore.WarmUpStateError.unverifiedIdentityOrState {}
            try expect(Data(contentsOf: stateURL) == before, "failed profile CAS keeps registry bytes")
            passed += 1
        }
        try write(base)
        let fail = CodexProfileStore([profile]); fail.failSave = true
        let before = try Data(contentsOf: stateURL)
        do { _ = try recover(fail); throw FixtureError.failed("write failure accepted") }
        catch CodexProfileStore.WarmUpStateError.unverifiedIdentityOrState {}
        try expect(Data(contentsOf: stateURL) == before && fail.state.profiles[0].lastWarmUpFailureReason == "pending", "profile write failure retains both states")
        passed += 1
        try write(base)
        let partial = CodexProfileStore([profile]); FixtureProbe.failRegistrySave = true
        let original = try Data(contentsOf: stateURL)
        do { _ = try recover(partial); throw FixtureError.failed("registry save failure accepted") }
        catch DispatchActivityStore.Failure.unavailable {}
        try expect(Data(contentsOf: stateURL) == original, "registry failure retains occupied bytes")
        try expect(partial.state.profiles[0].lastWarmUpFailureReason == "interrupted", "profile partial commit retained")
        FixtureProbe.failRegistrySave = false
        try expect(recover(partial) && partial.saveCount == 1, "registry retry does not duplicate attempt")
        passed += 1
        try write(base)
        let reuse = CodexProfileStore([profile]); FixtureProbe.results = [ESRCH, 0]
        try expect(!recover(reuse) && activity.read().leases[0].occupied, "PID reuse after save blocks lease release")
        try expect(reuse.state.profiles[0].lastWarmUpFailureReason == "interrupted", "partial commit preserves ambiguous profile")
        FixtureProbe.results = [ESRCH, ESRCH]
        try expect(recover(reuse) && reuse.saveCount == 1, "idempotent profile result resumes lease finish")
        passed += 1
        print("Warm-up orphan recovery fixture passed: \(passed) cases")
    }
}
