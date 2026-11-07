import Darwin
import Foundation

extension LocalProxyHostFixtures {
    @MainActor static func plusPolicyFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("QUOTA_POLICY_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("local-proxy-queue-v1.json")
        let now = Date()
        let five = CodexQuotaWindowSnapshot(usedPercent: 30, resetsAt: now.addingTimeInterval(3600))
        let weekly = CodexQuotaWindowSnapshot(usedPercent: 37.25, resetsAt: now.addingTimeInterval(86400))
        func profile(_ id: String, plan: String?, multiplier: Int? = nil) -> CodexProfile {
            var result = CodexProfile(id: id, lastSnapshot: .init(planType: plan, creditBalance: "5000", creditBalanceUnlimited: false,
                accountID: id + "-account", email: id + "@example.invalid", fetchedAt: now,
                fiveHour: ["pro", "prolite"].contains(plan ?? "") ? nil : five, sevenDay: weekly))
            result.proTierMultiplier = multiplier
            return result
        }
        let plus = profile("batch-plus", plan: "plus")
        let otherPlus = profile("batch-other-plus", plan: "plus", multiplier: 25)
        let pro5 = profile("batch-pro-5x", plan: "pro", multiplier: 5)
        let pro10 = profile("batch-pro-10x", plan: "pro", multiplier: 10)
        let pro25 = profile("batch-pro-25x", plan: "pro", multiplier: 25)
        let proLite = profile("batch-prolite", plan: "prolite")
        let proProfiles = [pro5, pro10, pro25, proLite]
        let targets = [plus, otherPlus] + proProfiles
        let unknown = profile("unknown-named-pro-25x", plan: nil, multiplier: 25)
        let free = profile("free-named-plus", plan: "free", multiplier: 10)
        let team = profile("team-named-pro", plan: "team")
        let skipped = [unknown, free, team]
        var system = profile("batch-system", plan: "pro", multiplier: 25)
        system.isSystemProfile = true
        let usage = UsageStore(targets + skipped + [system])
        usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage)
        try expect(store.quotaPolicyTargetCount == 6 && store.uniformQuotaRemainingReserve == 0,
            "default Plus5h and Pro5x/10x/25x/prolite7d share remaining0; other, unknown and system are excluded")
        try expect(store.setAccountPolicy(id: pro5.id, policy: .init(sevenDayUsedLimit: 100))
            && store.uniformQuotaRemainingReserve == 0, "explicit weekly100 and missing weekly key show the same default remaining0")
        store.setAccountEnabled(id: otherPlus.id, enabled: false)
        store.setAccountEnabled(id: pro5.id, enabled: false)
        store.setAccountPriority(id: plus.id, priority: true)
        store.setAccountLast(id: pro5.id, last: true)
        store.setCreditFallback(true)
        try expect(store.setCreditFloors(primary: 2600, secondary: 1600), "synthetic credit floors persist")
        let oldPlus = LocalProxyAccountPolicy(fiveHourUsedLimit: 70, sevenDayUsedLimit: 23, allowsCredits: false,
            creditPrimaryFloor: 1300, creditSecondaryFloor: 300)
        try expect(store.setAccountPolicy(id: otherPlus.id, policy: oldPlus), "Plus fixture has independent weekly and credit settings")
        for (index, candidate) in (proProfiles + skipped).enumerated() {
            let old = LocalProxyAccountPolicy(fiveHourUsedLimit: 65 + Double(index), sevenDayUsedLimit: index == 0 ? 20 : nil,
                allowsCredits: index.isMultiple(of: 2), creditPrimaryFloor: 1800 + index, creditSecondaryFloor: 500 + index)
            try expect(store.setAccountPolicy(id: candidate.id, policy: old), "independent existing policy fixture persists")
        }
        let previous = store.preferences
        let order = store.rows.map(\.id), revision = store.policyRevision
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let skippedBytes = try Dictionary(uniqueKeysWithValues: skipped.map { ($0.id, try encoder.encode(previous.policy(for: $0.id))) })
        try expect(store.uniformQuotaRemainingReserve == nil, "mixed comparison includes the applicable weekly window of every Pro tier")
        try expect(store.setQuotaRemainingReserve(20), "one batch applies remaining20 to Plus5h and every Pro7d including non-participants")
        let bytes = try Data(contentsOf: file)
        let disk = try JSONDecoder().decode(LocalProxyPreferences.self, from: bytes)
        try expect(store.policyRevision == revision + 1 && store.uniformQuotaRemainingReserve == 20,
            "single commit publishes the shared remaining20 value")
        for candidate in targets {
            let old = previous.policy(for: candidate.id), saved = disk.policy(for: candidate.id)
            try expect((candidate.isProPlan ? saved.effectiveSevenDayUsedLimit : saved.fiveHourUsedLimit) == 80,
                "\(candidate.id) persists used80 in its applicable window")
            try expect((candidate.isProPlan ? saved.fiveHourUsedLimit == old.fiveHourUsedLimit : saved.sevenDayUsedLimit == old.sevenDayUsedLimit)
                && saved.allowsCredits == old.allowsCredits && saved.creditPrimaryFloor == old.creditPrimaryFloor
                && saved.creditSecondaryFloor == old.creditSecondaryFloor,
                "\(candidate.id) keeps its other quota window and credit permissions/floors")
        }
        try expect(disk.enabledIDs == previous.enabledIDs && disk.order == previous.order && disk.priorityIDs == previous.priorityIDs
            && disk.lastIDs == previous.lastIDs && disk.lastOverrides == previous.lastOverrides
            && disk.creditFallback == previous.creditFallback && disk.creditPrimaryFloor == previous.creditPrimaryFloor
            && disk.creditSecondaryFloor == previous.creditSecondaryFloor && store.rows.map(\.id) == order,
            "mixed batch preserves participation, order, priority, last flags, global credit switch and floors")
        try expect(try skipped.allSatisfy { try encoder.encode(disk.policy(for: $0.id)) == skippedBytes[$0.id] }
            && disk.accountPolicies?[system.id] == nil, "unknown/free/team policies remain byte-identical and system is untouched")
        try expect(store.quotaPolicyMessage?.contains("20% remaining-quota reserve for 6 Plus / Pro accounts: Plus 5h, Pro 7d") == true,
            "success message reports the one remaining percentage and both correct windows")
        let reload = LocalProxyQueueStore(usageStore: usage)
        try expect(reload.quotaPolicyTargetCount == 6 && reload.uniformQuotaRemainingReserve == 20,
            "production Store reloads the shared remaining percentage across both plan families")
        for original in targets {
            var candidate = original
            let policy = reload.preferences.policy(for: candidate.id)
            func setUsed(_ used: Double) {
                if candidate.isProPlan { candidate.lastSnapshot?.sevenDay?.usedPercent = used }
                else { candidate.lastSnapshot?.fiveHour?.usedPercent = used }
            }
            setUsed(79.99)
            try expect(LocalProxyAdmission.quota(candidate, now: now, policy: policy) == nil,
                "\(candidate.id) permits new subscription requests above remaining20")
            for used in [80.0, 100] {
                setUsed(used)
                try expect(LocalProxyAdmission.quota(candidate, now: now, policy: policy) == .usageLimit
                    && LocalProxyAdmission.quota(candidate, now: now, creditFloor: 0, allowPaidCredits: true, policy: policy) == .usageLimit,
                    "\(candidate.id) stops at/below remaining20 and credits cannot bypass the reserve")
            }
        }
        let legacy = try JSONDecoder().decode(LocalProxyAccountPolicy.self, from: Data(#"{"fiveHourUsedLimit":80.1,"allowsCredits":true}"#.utf8))
        try expect(legacy.fiveHourUsedLimit == 80.1 && legacy.sevenDayUsedLimit == nil
            && legacy.remainingReserve(isProPlan: false) == 19.9 && legacy.remainingReserve(isProPlan: true) == 0,
            "legacy policy JSON retains exact used cutoff and defaults weekly reserve to zero")
        try expect(try JSONDecoder().decode(LocalProxyAccountPolicy.self, from: encoder.encode(legacy)) == legacy,
            "legacy optional weekly nil survives a Codable round trip")
        for value in [Double.nan, .infinity, -.infinity, -0.1, 100.1] {
            try expect(!LocalProxyAccountPolicy(sevenDayUsedLimit: value).isValid && !reload.setQuotaRemainingReserve(value),
                "invalid remaining input is rejected without clamping or partial mutation")
        }
        try expect(try Data(contentsOf: file) == bytes && reload.uniformQuotaRemainingReserve == 20,
            "invalid batch attempts preserve the whole mixed batch on disk")
        for remaining in [20.1, 0, 100] {
            try expect(reload.setQuotaRemainingReserve(remaining) && reload.uniformQuotaRemainingReserve == remaining,
                "shared remaining\(remaining) persists for all targets")
            let fresh = LocalProxyQueueStore(usageStore: usage)
            for original in targets {
                var candidate = original
                var policy = fresh.preferences.policy(for: candidate.id)
                policy.allowsCredits = true
                try expect(policy.remainingReserve(isProPlan: candidate.isProPlan) == remaining,
                    "\(candidate.id) reloads its applicable remaining\(remaining) window")
                if remaining == 0 {
                    if candidate.isProPlan { candidate.lastSnapshot?.sevenDay?.usedPercent = 100 }
                    else { candidate.lastSnapshot?.fiveHour?.usedPercent = 100 }
                    try expect(LocalProxyAdmission.quota(candidate, now: now, policy: policy) == .quota
                        && LocalProxyAdmission.quota(candidate, now: now, creditFloor: 0, allowPaidCredits: true, policy: policy) == nil,
                        "\(candidate.id) remaining0 retains official exhaustion and authorized credit fallback")
                } else if remaining == 100 {
                    if candidate.isProPlan { candidate.lastSnapshot?.sevenDay?.usedPercent = 0 }
                    else { candidate.lastSnapshot?.fiveHour?.usedPercent = 0 }
                    try expect(LocalProxyAdmission.quota(candidate, now: now, policy: policy) == .usageLimit,
                        "\(candidate.id) remaining100 admits no new requests even at used0")
                }
                candidate.lastSnapshot?.sevenDay = nil
                try expect(LocalProxyAdmission.quota(candidate, now: now, policy: policy) == .quotaUnknown,
                    "\(candidate.id) missing evidence stays unknown before the quota reserve")
            }
        }
        try expect(reload.setQuotaRemainingReserve(37.25), "a decimal shared reserve saves once across plans")
        var override = reload.preferences.policy(for: pro10.id)
        override.sevenDayUsedLimit = 70
        try expect(reload.setAccountPolicy(id: pro10.id, policy: override) && reload.uniformQuotaRemainingReserve == nil
            && reload.preferences.policy(for: plus.id).fiveHourUsedLimit == 62.75,
            "one Pro weekly override makes the top field mixed without changing its Plus peers")
        let noTargetsUsage = UsageStore(skipped + [system])
        noTargetsUsage.isPreview = false
        let noTargets = LocalProxyQueueStore(usageStore: noTargetsUsage)
        try expect(noTargets.quotaPolicyTargetCount == 0 && noTargets.uniformQuotaRemainingReserve == nil
            && !noTargets.setQuotaRemainingReserve(20) && noTargets.quotaPolicyMessage?.contains("No verified Plus or Pro accounts") == true,
            "names and multipliers cannot promote unknown/free/team/system into a target")
        var hardLimitedPro = pro5
        hardLimitedPro.lastSnapshot?.fiveHour = .init(usedPercent: 100, resetsAt: now.addingTimeInterval(3600))
        try expect(LocalProxyAdmission.quota(hardLimitedPro, now: now, creditFloor: 0, allowPaidCredits: true,
            policy: .init(sevenDayUsedLimit: 100)) == .quota, "weekly reserve zero cannot bypass an official extra hard limit")

        try expect(reload.setQuotaRemainingReserve(70), "prepare persisted used30 mixed runtime admission fixture")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["45"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        reload.process = child
        reload.phase = .running
        reload.runID = UUID().uuidString
        reload.controlKey = "batch-fixture-key"
        reload.registeredPool = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, LocalProxyQueueStore.PoolBinding(
            home: $0.codexHomeURL, account: $0.recordedAccountKey, accountID: $0.lastSnapshot!.accountID!)) })
        reload.activeIDs = Set(targets.map(\.id))
        reload.preferences.enabledIDs = Set(targets.map(\.id))
        let registry = root.appendingPathComponent(DispatchActivityStore.stateName)
        for candidate in targets {
            func request(_ command: String, id: String) -> LocalProxyRequest {
                .init(schemaVersion: 1, runID: reload.runID!, key: reload.controlKey!, command: command, requestID: id,
                      profileID: command == "order_end" ? "" : candidate.id, leaseID: nil)
            }
            let evidence = await reload.handle(request("quota_recovery", id: UUID().uuidString))
            try expect(evidence.error == "usage_limit" && evidence.quotaObservedAt == nil,
                "\(candidate.id) running recovery observes its persisted quota-window reserve")
            let before = try? Data(contentsOf: registry), id = UUID().uuidString
            let ordered = await reload.handle(request("order", id: id))
            try expect(ordered.ok, "mixed reserve does not remove order membership")
            let result = await reload.handle(request("acquire", id: id))
            try expect(result.error == "usage_limit" && result.accessToken == nil && result.leaseID == nil
                && reload.leases.isEmpty && (try? Data(contentsOf: registry)) == before,
                "\(candidate.id) running acquire denies before credentials or reservation")
            _ = await reload.handle(request("order_end", id: id))
        }
        usage.profiles[targets.count].lastSnapshot?.accountID = "changed-skipped-unknown"
        try expect(reload.setQuotaRemainingReserve(70), "a skipped unknown account binding cannot block the verified mixed batch")
        usage.profiles[targets.count] = unknown
        let committed = try Data(contentsOf: file), committedPolicies = reload.preferences.accountPolicies
        for index in [0, 2, 4] {
            let original = usage.profiles[index]
            usage.profiles[index].lastSnapshot?.accountID = "changed-target"
            try expect(!reload.setQuotaRemainingReserve(20) && reload.preferences.accountPolicies == committedPolicies
                && Data(contentsOf: file) == committed && reload.quotaPolicyMessage?.contains("No rules changed") == true,
                "stale target identity \(original.id) rejects the whole mixed batch without partial updates")
            usage.profiles[index] = original
        }
        let failed = LocalProxyQueueStore(usageStore: usage), failedRevision = failed.policyRevision
        let blocked = URL(fileURLWithPath: file.path + ".blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: blocked) }
        LocalProxyFixtureRuntime.failPreferenceRename = true
        let saved = failed.setQuotaRemainingReserve(20)
        LocalProxyFixtureRuntime.failPreferenceRename = false
        try expect(!saved && failed.policyRevision == failedRevision && failed.preferencesFailure == .save
            && failed.preferences.accountPolicies == committedPolicies && Data(contentsOf: file) == committed,
            "atomic write refusal rolls back every Plus/Pro window and preserves skipped policies")
        try expect(LocalProxyQueueStore(usageStore: usage).uniformQuotaRemainingReserve == 70,
            "fresh Store sees no partial mixed batch after save refusal")
        print("PASS: \(checks) mixed Plus/Pro remaining-quota checks; production save/reload/recovery/acquire with isolated data")
    }

    @MainActor static func quotaAdmissionBudgetFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("QUOTA_BUDGET_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date(), window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(86400))
        let profile = CodexProfile(id: "budget-profile", lastSnapshot: .init(planType: "plus",
            accountID: "budget-account", email: "budget@example.invalid", fetchedAt: now.addingTimeInterval(-121), fiveHour: window, sevenDay: window))
        let system = CodexProfile(id: "budget-system", isSystemProfile: true, lastSnapshot: .init(planType: "plus",
            accountID: "budget-system-account", email: "budget-system@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        let healthyProfile = CodexProfile(id: "budget-healthy", lastSnapshot: .init(planType: "plus",
            accountID: "budget-healthy-account", email: "budget-healthy@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        func auth(account: String, email: String) throws -> Data {
            func jwt(_ claims: [String: Any]) throws -> String {
                "fixture." + (try JSONSerialization.data(withJSONObject: claims)).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
            }
            return try JSONSerialization.data(withJSONObject: ["tokens": [
                "access_token": try jwt(["exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970 - 60, "account_id": account]),
                "id_token": try jwt(["email": email, "account_id": account]), "account_id": account]])
        }
        for (candidate, data) in [(profile, try auth(account: "budget-account", email: "budget@example.invalid")),
                                  (healthyProfile, try auth(account: "budget-healthy-account", email: "budget-healthy@example.invalid")),
                                  (system, try auth(account: "budget-system-account", email: "budget-system@example.invalid"))] {
            try FileManager.default.createDirectory(at: candidate.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = candidate.codexHomeURL.appendingPathComponent("auth.json")
            try data.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let usage = UsageStore([profile, healthyProfile, system]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["45"]; try child.run()
        defer { if child.isRunning { child.terminate() } }
        let run = UUID().uuidString, key = "budget-fixture-key"
        store.process = child; store.phase = .running; store.runID = run; store.controlKey = key
        store.registeredPool = Dictionary(uniqueKeysWithValues: [profile, healthyProfile].map { ($0.id,
            LocalProxyQueueStore.PoolBinding(home: $0.codexHomeURL, account: $0.recordedAccountKey, accountID: $0.lastSnapshot!.accountID!)) })
        store.activeIDs = [profile.id, healthyProfile.id]; store.preferences.enabledIDs = [profile.id, healthyProfile.id]
        HubConsoleModel.fixtureAvailability = .idle
        func request(id: String, age: TimeInterval = 0, target: String? = nil) -> LocalProxyRequest {
            .init(schemaVersion: 1, runID: run, key: key, command: "acquire", requestID: id, profileID: target ?? profile.id, leaseID: nil,
                  receivedAt: ProcessInfo.processInfo.systemUptime - age)
        }
        usage.onRefresh = { _ in Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_400_000_000)
            usage.profiles[0].lastSnapshot?.fetchedAt = Date()
        } }
        let successfulID = controlFixtureRequestID(), start = ProcessInfo.processInfo.systemUptime
        let success = await fixtureHandle(store, request(id: successfulID))
        try expect(success.ok && success.leaseID != nil && ProcessInfo.processInfo.systemUptime - start >= 3.3,
            "same request waits beyond the old 3s cutoff for a valid fresh snapshot")
        _ = await store.handle(.init(schemaVersion: 1, runID: run, key: key, command: "release",
            requestID: successfulID, profileID: profile.id, leaseID: success.leaseID))
        usage.onRefresh = nil
        usage.profiles[0].lastSnapshot?.fetchedAt = Date().addingTimeInterval(-121)
        let registry = root.appendingPathComponent(DispatchActivityStore.stateName), before = try Data(contentsOf: registry)
        let deadline = await fixtureHandle(store, request(id: controlFixtureRequestID(), age: 18.1))
        try expect(deadline.error == "admission_deadline" && deadline.leaseID == nil && store.leases.isEmpty
            && Data(contentsOf: registry) == before, "expired remaining budget denies before reservation")
        let cancelledTask = Task { @MainActor in await fixtureHandle(store, request(id: controlFixtureRequestID())) }
        try await Task.sleep(nanoseconds: 150_000_000); cancelledTask.cancel()
        let cancelled = await cancelledTask.value
        try expect(cancelled.error == "stopping" && cancelled.accessToken == nil && store.leases.isEmpty
            && Data(contentsOf: registry) == before, "cancellation while refreshing denies without credentials or a lease")
        var refreshTask: Task<Void, Never>?
        usage.onRefresh = { _ in refreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            usage.profiles[0].lastSnapshot?.fetchedAt = Date()
        } }
        let revokedTask = Task { @MainActor in await fixtureHandle(store, request(id: controlFixtureRequestID())) }
        try await Task.sleep(nanoseconds: 50_000_000)
        store.setAccountPolicy(id: profile.id, policy: .init(fiveHourUsedLimit: 100))
        let revoked = await revokedTask.value
        await refreshTask?.value
        try expect(revoked.error == "policy_changed" && revoked.accessToken == nil && store.leases.isEmpty
            && Data(contentsOf: registry) == before, "policy revision change during refresh still revokes the old request")
        usage.onRefresh = nil
        try expect(LocalProxyAdmission.quota(profile, now: now) == .quotaUnknown, "120s freshness remains enforced")
        usage.profiles[0] = profile
        usage.onRefresh = { _ in Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            usage.profiles[0].lastQuotaReadFailureAt = Date()
        } }
        let failedStart = ProcessInfo.processInfo.systemUptime
        let failed = await fixtureHandle(store, request(id: controlFixtureRequestID()))
        try expect(failed.error == "quota_unknown" && ProcessInfo.processInfo.systemUptime - failedStart < 1,
            "known refresh failure returns quota_unknown early for the next account")
        usage.profiles[0] = profile
        usage.onRefresh = nil
        let slowStart = ProcessInfo.processInfo.systemUptime
        let slowID = controlFixtureRequestID()
        let slow = await fixtureHandle(store, request(id: slowID))
        try expect(slow.error == "quota_unknown" && ProcessInfo.processInfo.systemUptime - slowStart < 7,
            "slow first account keeps a bounded refresh budget and returns retryable selection refusal")
        let healthyID = slowID
        let healthy = await fixtureHandle(store, request(id: healthyID, target: healthyProfile.id))
        try expect(healthy.ok && healthy.leaseID != nil, "next healthy candidate has an admission opportunity after slow refusal")
        _ = await store.handle(.init(schemaVersion: 1, runID: run, key: key, command: "release",
            requestID: healthyID, profileID: healthyProfile.id, leaseID: healthy.leaseID))
        print("PASS: \(checks) quota admission budget checks; synthetic refresh and credentials only")
    }
}


private enum LocalProxyControlFixtureFailure: Error { case check(String), socket }

private final class LocalProxyControlFixtureResult: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var bytes: Data?
    func complete(_ value: Data?) {
        lock.lock(); bytes = value; lock.unlock()
        done.signal()
    }
    func value() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
}

extension LocalProxyHostFixtures {
    @MainActor static func postReserveContentionFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("POST_RESERVE_CONTENTION_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try expect(root.path.contains("aigoodbro-proxy-host-fixture-"), "post-reserve fixture uses an isolated support root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date(), window = CodexQuotaWindowSnapshot(usedPercent: 10, resetsAt: now.addingTimeInterval(3600))
        let profile = CodexProfile(id: "post-reserve-profile", lastSnapshot: CodexAccountSnapshot(planType: "plus",
            accountID: "post-reserve-account", email: "post-reserve@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        let system = CodexProfile(id: "post-reserve-system", isSystemProfile: true, lastSnapshot: CodexAccountSnapshot(planType: "plus",
            accountID: "post-reserve-central", email: "post-reserve-central@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        func jwt(_ claims: [String: Any]) throws -> String {
            let bytes = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "fixture.\(bytes).fixture"
        }
        for candidate in [profile, system] {
            try FileManager.default.createDirectory(at: candidate.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let account = candidate.lastSnapshot!.accountID!, email = candidate.lastSnapshot!.email!
            let access = try jwt(["exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970 - 300, "account_id": account])
            let identity = try jwt(["email": email, "account_id": account])
            let bytes = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "id_token": identity, "account_id": account]])
            let path = candidate.codexHomeURL.appendingPathComponent("auth.json")
            try bytes.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        let usage = UsageStore([profile, system]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), activity = DispatchActivityStore.live
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try await Task.detached { try child.run() }.value
        defer {
            LocalProxyFixtureRuntime.afterRunning = nil; LocalProxyFixtureRuntime.failActivityCommit = false
            HubConsoleModel.fixtureOnWarmUp = nil; HubConsoleModel.fixtureAvailability = .unavailable
            if child.isRunning { child.terminate() }
            store.process = nil
        }
        let run = UUID().uuidString, key = "post-reserve-fixture-key"
        store.process = child; store.phase = .running; store.runID = run; store.controlKey = key
        store.registeredPool = [profile.id: .init(home: profile.codexHomeURL, account: profile.recordedAccountKey,
            accountID: profile.lastSnapshot!.accountID!)]
        store.activeIDs = [profile.id]; store.preferences.enabledIDs = [profile.id]
        HubConsoleModel.fixtureAvailability = .idle
        let descriptor = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw LocalProxyControlFixtureFailure.socket }
        defer { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        let selected = ProcessInfo.processInfo.environment["PROXY_POST_RESERVE_SCENARIO"]
        let scenarios = ["write-recovers", "write-expires", "read-recovers", "read-expires", "read-revoked", "rollback-unknown"]
        guard selected == nil || scenarios.contains(selected!) else { throw LocalProxyControlFixtureFailure.check("unknown post-reserve scenario") }
        for scenario in scenarios where selected == nil || selected == scenario {
            let requestID = controlFixtureRequestID(), expires = scenario.hasSuffix("expires") || scenario == "rollback-unknown"
            var request = LocalProxyRequest(schemaVersion: 1, runID: run, key: key, command: "acquire", requestID: requestID, profileID: profile.id, leaseID: nil)
            request.receivedAt = ProcessInfo.processInfo.systemUptime - (expires ? 17.2 : 16)
            let ordered = await store.handle(.init(schemaVersion: 1, runID: run, key: key, command: "order", requestID: requestID, profileID: profile.id, leaseID: nil))
            try expect(ordered.ok && ordered.order == [profile.id], "\(scenario) starts with a valid membership snapshot")
            var held = false
            let unlocked = DispatchSemaphore(value: 0)
            func hold() {
                held = flock(descriptor, LOCK_EX | LOCK_NB) == 0
                guard held else { unlocked.signal(); return }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (expires ? 1.3 : 0.2)) {
                    if scenario == "rollback-unknown" { LocalProxyFixtureRuntime.failActivityCommit = true }
                    _ = flock(descriptor, LOCK_UN)
                    unlocked.signal()
                }
                if scenario == "read-revoked" {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        store.setAccountEnabled(id: profile.id, enabled: false)
                    }
                }
            }
            if scenario.hasPrefix("read-") { LocalProxyFixtureRuntime.afterRunning = hold }
            else { HubConsoleModel.fixtureOnWarmUp = hold }
            let reply = await store.handle(request)
            LocalProxyFixtureRuntime.afterRunning = nil; HubConsoleModel.fixtureOnWarmUp = nil
            let didUnlock = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: unlocked.wait(timeout: .now() + 2) == .success)
                }
            }
            LocalProxyFixtureRuntime.failActivityCommit = false
            print("POST_RESERVE_OBSERVED \(scenario): ok=\(reply.ok), error=\(reply.error ?? "none"), resolution=\(reply.resolution ?? "none"), owned=\(store.leases.count)")
            try expect(held && didUnlock, "\(scenario) actually contends and releases the registry lock")
            if scenario.hasSuffix("recovers") {
                try expect(reply.ok && reply.leaseID != nil && store.leases[reply.leaseID!]?.isAdmitted == true,
                    "\(scenario) resumes the exact reserved tuple after lock release")
                let released = LocalProxyQueueStore.maintainLease(.init(schemaVersion: 1, runID: run, key: key, command: "release",
                    requestID: requestID, profileID: profile.id, leaseID: reply.leaseID), run: run, key: key, permittedProfiles: [profile.id])
                try expect(released.ok, "\(scenario) releases the committed lease")
                store.completeLeaseRelease(.init(schemaVersion: 1, runID: run, key: key, command: "release", requestID: requestID, profileID: profile.id, leaseID: reply.leaseID))
            } else if scenario == "rollback-unknown" {
                try expect(!reply.ok && reply.error == "admission_unknown" && reply.resolution == nil && reply.accessToken == nil && !store.leases.isEmpty,
                    "failed rollback retains ownership and never claims transient recovery")
                _ = try activity.abandonProxy(runID: run, requestID: requestID, profileID: profile.id, enforceFreshness: true)
                store.forgetAbandoned(request)
            } else {
                let expected = scenario == "read-revoked" ? "not_participating" : "busy"
                try expect(!reply.ok && reply.error == expected && reply.accessToken == nil && store.leases.isEmpty
                    && (scenario == "read-revoked" || reply.resolution == "abandoned"),
                    "\(scenario) denies credentials only after durable rollback")
                try expect(try activity.isProxyAcquireAbandoned(runID: run, requestID: requestID, profileID: profile.id),
                    "\(scenario) keeps its exact tuple denied")
            }
            try expect(try activity.read().leases.filter(\.occupied).isEmpty && store.leases.isEmpty,
                "\(scenario) leaves no synthetic active reservation")
            _ = await store.handle(.init(schemaVersion: 1, runID: run, key: key, command: "order_end", requestID: requestID, profileID: "", leaseID: nil))
            if scenario == "read-revoked" { store.setAccountEnabled(id: profile.id, enabled: true) }
        }
        print("PASS: \(checks) post-reserve contention checks; synthetic credentials and sleeping child only")
    }

    @MainActor static func transientRefreshFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("TRANSIENT_REFRESH_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try expect(root.path.contains("aigoodbro-proxy-host-fixture-"), "transient refresh uses an isolated support root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date(), until = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 3600)
        let window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(7200))
        let profile = CodexProfile(id: "transient-refresh-profile", lastSnapshot: CodexAccountSnapshot(planType: "plus",
            accountID: "transient-refresh-account", email: "transient-refresh@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        let usage = UsageStore([profile]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), run = UUID().uuidString
        store.runID = run; store.activeIDs = [profile.id]; store.preferences.enabledIDs = [profile.id]
        let stateDirectory = root.appendingPathComponent("LocalProxy", isDirectory: true)
        try LocalProxyQueueStore.prepareStateDirectory(stateDirectory)
        let persistentCooldown = stateDirectory.appendingPathComponent("cooldown.json")
        let persistentBytes = Data("synthetic cooldown preservation sentinel".utf8)
        try persistentBytes.write(to: persistentCooldown)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistentCooldown.path)
        func event(_ state: String, deadline: Date? = nil) throws {
            var value: [String: Any] = ["event": "account", "profileID": profile.id, "state": state]
            if let deadline { value["cooldownUntil"] = deadline.timeIntervalSince1970 }
            store.consume(try JSONSerialization.data(withJSONObject: value), run: run)
            store.flushDisplayRows()
        }
        for state in ["busy", "credentials_busy", "temporary_error"] {
            let expectedState = state == "temporary_error" ? "ready" : state
            let expectedAccountState: String? = state == "temporary_error" ? nil : state
            try event(state)
            store.refreshStatus(displayFreshResultsImmediately: true); store.flushDisplayRows()
            print("TRANSIENT_REFRESH_OBSERVED \(state): \(store.displayRows.first?.state ?? "missing")")
            try expect(store.accountStates[profile.id] == expectedAccountState && store.displayRows.first?.state == expectedState,
                "manual refresh projects \(state) as \(expectedState)")
            try event(state)
            store.refreshStatus(); store.flushDisplayRows()
            try expect(store.accountStates[profile.id] == expectedAccountState && store.displayRows.first?.state == expectedState,
                "periodic refresh projects \(state) as \(expectedState)")
            try event(state)
            store.policyChanged()
            try expect(store.accountStates[profile.id] == expectedAccountState && store.displayRows.first?.state == expectedState,
                "policy save projects \(state) as \(expectedState)")
            try event(state, deadline: until)
            store.refreshStatus(); store.policyChanged(); store.flushDisplayRows()
            try expect(store.accountStates[profile.id] == state && store.displayRows.first?.state == state && store.cooldowns[profile.id] == until,
                "live helper cooldown keeps \(state) and its exact deadline")
            store.cooldowns[profile.id] = now.addingTimeInterval(-1)
            store.refreshStatus(); store.flushDisplayRows()
            try expect(store.accountStates[profile.id] == expectedAccountState && store.displayRows.first?.state == expectedState,
                "expired helper cooldown projects \(state) as \(expectedState)")
        }
        try event("temporary_error")
        usage.profiles[0].lastQuotaReadFailureAt = Date()
        store.refreshStatus(); store.flushDisplayRows()
        try expect(store.displayRows.first?.state == "quota_unknown", "cleared transient state still honors failed official quota evidence")
        usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.fetchedAt = now.addingTimeInterval(-121)
        try event("temporary_error")
        store.refreshStatus(); store.flushDisplayRows()
        try expect(store.displayRows.first?.state == "quota_unknown", "cleared transient state still honors stale official quota evidence")
        usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 100
        try event("temporary_error")
        store.refreshStatus(); store.flushDisplayRows()
        try expect(store.displayRows.first?.state == "quota", "cleared transient state cannot hide exhausted subscription")
        usage.profiles[0] = profile
        try event("login_expired")
        store.refreshStatus(); store.policyChanged()
        try expect(store.displayRows.first?.state == "login_expired", "quota refresh retains actual sign-in failure")
        try expect(try Data(contentsOf: persistentCooldown) == persistentBytes,
            "transient display recovery preserves helper cooldown bytes")
        print("PASS: \(checks) transient refresh checks; synthetic events and quota snapshots only")
    }

    @MainActor static func registryContentionFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("REGISTRY_CONTENTION_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let snapshot = CodexAccountSnapshot(fetchedAt: Date(),
            fiveHour: .init(usedPercent: 10, resetsAt: Date().addingTimeInterval(3600)),
            sevenDay: .init(usedPercent: 10, resetsAt: Date().addingTimeInterval(86400)))
        let profile = CodexProfile(id: "contention-profile", lastSnapshot: snapshot)
        var system = CodexProfile(id: "contention-system", lastSnapshot: snapshot)
        system.isSystemProfile = true
        system.lastSnapshot?.email = "system@example.invalid"
        system.lastSnapshot?.accountID = "system-fixture-account"
        let usage = UsageStore([profile, system]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), activity = DispatchActivityStore.live
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try await Task.detached { try child.run() }.value
        defer { if child.isRunning { child.terminate() }; store.process = nil }
        let run = UUID().uuidString, key = "contention-fixture-key"
        store.process = child; store.phase = .running; store.runID = run; store.controlKey = key
        store.registeredPool = [profile.id: .init(home: profile.codexHomeURL, account: profile.recordedAccountKey,
            accountID: profile.lastSnapshot!.accountID!)]
        store.activeIDs = [profile.id]
        func request(_ id: String, key: String = "contention-fixture-key") -> LocalProxyRequest {
            .init(schemaVersion: 1, runID: run, key: key, command: "acquire", requestID: id, profileID: profile.id, leaseID: nil)
        }
        func handle(_ input: LocalProxyRequest) async -> LocalProxyReply {
            if store.membershipSnapshots[input.requestID] == nil {
                _ = await store.handle(.init(schemaVersion: 1, runID: run, key: key, command: "order",
                    requestID: input.requestID, profileID: profile.id, leaseID: nil))
            }
            return await store.handle(input)
        }
        let state = root.appendingPathComponent(DispatchActivityStore.stateName)
        let lock = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { throw LocalProxyControlFixtureFailure.socket }
        defer { _ = flock(lock, LOCK_UN); Darwin.close(lock) }
        try expect(flock(lock, LOCK_EX | LOCK_NB) == 0, "unrelated registry writer owns the lock")
        let id = controlFixtureRequestID(), before = try? Data(contentsOf: state)
        let ordered = await store.handle(.init(schemaVersion: 1, runID: run, key: key, command: "order",
            requestID: id, profileID: profile.id, leaseID: nil))
        try expect(ordered.ok, "read-only order snapshot works while registry writer holds the lock")
        let refused = await store.handle(request(id))
        try expect(refused.error == "control_busy" && !refused.ok && refused.leaseID == nil && refused.accessToken == nil,
            "registry lock contention is not account occupancy")
        try expect((try? Data(contentsOf: state)) == before && store.leases.isEmpty,
            "pre-reservation lock refusal changes no registry bytes or lease")
        let unauthorized = await store.handle(request(controlFixtureRequestID(), key: "wrong-fixture-key"))
        try expect(unauthorized.error == "identity", "contention does not relax bridge authentication")
        _ = flock(lock, LOCK_UN)
        HubConsoleModel.fixtureAvailability = .busy
        let retried = await store.handle(request(id))
        try expect(retried.error == "busy" && retried.resolution == "abandoned",
            "same safely refused tuple can reserve after unlock and preserves real warm-up occupancy")
        try expect(try activity.isProxyAcquireAbandoned(runID: run, requestID: id, profileID: profile.id),
            "post-reservation rollback retains its durable deny marker")
        let repeatDenied = await store.handle(request(id))
        try expect(repeatDenied.error == "acquire_abandoned" && repeatDenied.resolution == "abandoned",
            "rolled-back tuple cannot be replayed as safe lock contention")
        let holder = controlFixtureRequestID()
        let lease = try activity.reserveProxy(account: profile.recordedAccountKey, alias: "fixture-alias", runID: run,
            requestID: holder, profileID: profile.id, childPID: child.processIdentifier, enforceFreshness: true)
        // The account cap admits 10 concurrent conversations; fill the remaining
        // slots so the next acquire hits the real per-account limit.
        var slotHolders: [(lease: String, request: String)] = []
        for _ in 1..<DispatchActivityStore.proxyMaxConcurrentPerAccount {
            let slotRequest = controlFixtureRequestID()
            let slotLease = try activity.reserveProxy(account: profile.recordedAccountKey, alias: "fixture-alias", runID: run,
                requestID: slotRequest, profileID: profile.id, childPID: child.processIdentifier)
            slotHolders.append((slotLease, slotRequest))
        }
        let whileOccupied = await handle(request(controlFixtureRequestID()))
        try expect(whileOccupied.error == "busy" && whileOccupied.resolution == nil && whileOccupied.leaseID == nil,
            "account at the concurrency cap still returns account busy before reservation")
        try activity.updateProxy(lease, runID: run, requestID: holder, profileID: profile.id, state: "accepted")
        for slot in slotHolders {
            try activity.updateProxy(slot.lease, runID: run, requestID: slot.request, profileID: profile.id, state: "accepted")
        }
        let duplicate = await handle(request(holder))
        try expect(duplicate.error == "busy" && duplicate.resolution == nil,
            "duplicate reserved tuple is not safely retryable even after completion")
        try expect(try activity.read().leases.filter(\.occupied).isEmpty && store.leases.isEmpty,
            "contention and rollback leave no orphan active lease")
        print("PASS: registry contention production host fixture (\(checks) checks)")
    }

    private static func occupyControlFixtureWorker(_ release: DispatchSemaphore) {
        _ = release.wait(timeout: .now() + 10)
    }

    @MainActor static func controlRecoveryFixtures() async throws {
        try await controlProgressFixtures()
        try await quotaRecoveryFixtures()
    }

    private static func controlFixtureRequestID() -> String {
        let time = String(format: "%012llx", UInt64(Date().timeIntervalSince1970 * 1000))
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(time.prefix(8))-\(time.suffix(4))-7\(random.prefix(3))-a\(random.dropFirst(3).prefix(3))-\(random.dropFirst(6).prefix(12))"
    }

    /// Synchronous clients run on GCD so the test itself does not need the
    /// cooperative executor whose unavailable worker it is reproducing.
    private static func controlFixtureRPC(path: String, run: String, command: String, requestID: String, leaseID: String? = nil, abandonReply: Bool = false) -> Data? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var object: [String: Any] = ["schemaVersion": 1, "runID": run, "key": "control-fixture-key", "command": command,
            "requestID": requestID, "profileID": "control-fixture-profile"]
        if let leaseID { object["leaseID"] = leaseID }
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        line.append(10)
        let written = line.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        guard written == line.count else { return nil }
        if abandonReply { _ = Darwin.shutdown(fd, SHUT_RDWR); return nil }
        var received = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while received.count <= 65536 {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            received.append(contentsOf: buffer.prefix(count))
            if received.last == 10 { return received }
        }
        return nil
    }

    @MainActor static func controlProgressFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("CONTROL_PROGRESS_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sockets = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agb-control-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: sockets) }
        let path = sockets.appendingPathComponent("control.sock").path
        let activity = DispatchActivityStore.live, run = UUID().uuidString
        let profileID = "control-fixture-profile", key = "control-fixture-key"
        let maintenanceRequest = controlFixtureRequestID()
        let lease = try activity.reserveProxy(account: "control-fixture-account", alias: "control-fixture-alias", runID: run,
            requestID: maintenanceRequest, profileID: profileID, childPID: getpid(), enforceFreshness: true)
        let bridge = try LocalProxyBridge(path: path, resolve: { request in
            guard request.runID == run, request.key == key, request.command == "acquire_resolve", request.profileID == profileID,
                request.leaseID == nil else { return .failure(.identity) }
            do {
                let resolution = try activity.abandonProxy(runID: run, requestID: request.requestID, profileID: profileID, enforceFreshness: true)
                return LocalProxyReply(ok: true, resolution: resolution.rawValue)
            } catch DispatchActivityStore.Failure.busy { return .failure(.controlBusy) } catch { return .failure(.admissionUnknown) }
        }, maintenance: { request in
            LocalProxyQueueStore.maintainLease(request, run: run, key: key, permittedProfiles: [profileID], activity: activity)
        }, handler: { _ in .failure(.admissionDeadline) })
        defer { bridge.stop(); localProxyReleaseFence.clear(runID: run) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blockedWorker = Task.detached(priority: .userInitiated) {
            entered.signal()
            Self.occupyControlFixtureWorker(release)
        }
        defer { release.signal() }
        try expect(entered.wait(timeout: .now() + 2) == .success, "synthetic helper read occupies cooperative worker")
        func rpc(_ command: String, _ requestID: String, leaseID: String? = nil) throws -> [String: Any] {
            let result = LocalProxyControlFixtureResult()
            DispatchQueue.global(qos: .userInitiated).async {
                result.complete(Self.controlFixtureRPC(path: path, run: run, command: command, requestID: requestID, leaseID: leaseID))
            }
            // Deliberately occupy MainActor too. Resolver and maintenance ACKs
            // must need neither UI progress nor a cooperative worker.
            try expect(result.done.wait(timeout: .now() + 2) == .success, "\(command) returns while MainActor is occupied")
            if result.value() == nil, command == "acquire_resolve", checks == 2,
                ProcessInfo.processInfo.environment["PROXY_CONTROL_EXPECT_STALL"] == "1"
            {
                print("CONTROL_NEGATIVE_REPRODUCED: acquire_resolve stalled while cooperative worker was occupied")
                bridge.stop()
                try? FileManager.default.removeItem(at: sockets)
                exit(42)
            }
            guard let bytes = result.value(), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { throw LocalProxyControlFixtureFailure.check("\(command) timed out with cooperative worker occupied") }
            return object
        }
        let late = controlFixtureRequestID()
        let resolved = try rpc("acquire_resolve", late)
        try expect(resolved["ok"] as? Bool == true && resolved["resolution"] as? String == "not_reserved",
            "unstarted acquire resolves without cooperative or UI progress")
        do {
            _ = try activity.reserveProxy(account: "late-fixture", alias: "late-fixture", runID: run, requestID: late,
                profileID: profileID, childPID: getpid(), enforceFreshness: true)
            throw LocalProxyControlFixtureFailure.check("late acquire crossed durable deny marker")
        } catch DispatchActivityStore.Failure.acquireAbandoned {
            try expect(true, "not_reserved installs durable denial before a late acquire")
        }
        let lockFD = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR)
        guard lockFD >= 0 else { throw LocalProxyControlFixtureFailure.socket }
        defer { Darwin.close(lockFD) }
        try expect(flock(lockFD, LOCK_EX | LOCK_NB) == 0, "synthetic registry writer owns file lock")
        let contended = controlFixtureRequestID(), before = try Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))
        let busy = try rpc("acquire_resolve", contended)
        try expect(busy["error"] as? String == "control_busy" && busy["ok"] as? Bool == false,
            "registry contention replies explicitly instead of waiting behind the lock")
        try expect(try Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName)) == before,
            "refused resolver leaves registry bytes intact")
        _ = flock(lockFD, LOCK_UN)
        let retried = try rpc("acquire_resolve", contended)
        try expect(retried["resolution"] as? String == "not_reserved", "authoritatively refused resolver can retry after contention")
        let heartbeat = try rpc("heartbeat", maintenanceRequest, leaseID: lease)
        try expect(heartbeat["ok"] as? Bool == true, "heartbeat commits while cooperative worker is occupied")
        let released = try rpc("release", maintenanceRequest, leaseID: lease)
        try expect(released["ok"] as? Bool == true && localProxyReleaseFence.contains(runID: run, profileID: profileID),
            "release commits durable terminal row and fence before UI cleanup")
        let unsafe = try rpc("acquire_resolve", maintenanceRequest)
        try expect(unsafe["ok"] as? Bool == false && unsafe["error"] as? String == "admission_unknown",
            "terminal accepted lease stays unknown and cannot become a safe no-reservation result")
        release.signal()
        await blockedWorker.value
        let pipe = Pipe()
        let idleRead = Task.detached { await LocalProxyQueueStore.readHelperOutput(pipe.fileHandleForReading) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let executorProgress = DispatchSemaphore(value: 0)
        Task.detached { executorProgress.signal() }
        try expect(executorProgress.wait(timeout: .now() + 1) == .success,
            "idle helper output read suspends without consuming the cooperative worker")
        let line = Data("fixture-ready\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: line)
        let delivered = await idleRead.value
        try expect(delivered == line, "output reader delivers available bytes before EOF")
        try pipe.fileHandleForWriting.close(); try pipe.fileHandleForReading.close()
        for _ in 0..<10 {
            let bytes: Data? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.controlFixtureRPC(path: path, run: run, command: "order", requestID: UUID().uuidString))
                }
            }
            let object = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard object?["error"] as? String == "admission_deadline" else { throw LocalProxyControlFixtureFailure.check("asynchronous handler reply lost") }
        }
        try expect(true, "ordinary handler replies transfer descriptor ownership and release all eight slots")
        let rolledBack = DispatchSemaphore(value: 0)
        let rollbackPath = sockets.appendingPathComponent("rollback.sock").path
        let rollbackBridge = try LocalProxyBridge(path: rollbackPath, rollback: { _ in rolledBack.signal() }, handler: { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return LocalProxyReply(ok: true, leaseID: UUID().uuidString)
        })
        defer { rollbackBridge.stop() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Self.controlFixtureRPC(path: rollbackPath, run: run, command: "acquire", requestID: UUID().uuidString, abandonReply: true)
                continuation.resume()
            }
        }
        // The transferred reply still awaits its MainActor handler. Suspend
        // this actor while GCD observes rollback; blocking it after an assumed
        // scheduling delay would prevent the very reply being tested.
        let didRollBack = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: rolledBack.wait(timeout: .now() + 1) == .success)
            }
        }
        try expect(didRollBack, "failed acquired-lease reply still runs rollback after descriptor transfer")
        print("PASS: \(checks) control progress checks; synthetic socket, registry and worker only")
    }

    @MainActor static func quotaRecoveryFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("QUOTA_RECOVERY_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date(), window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: Date().addingTimeInterval(3600))
        let profile = CodexProfile(id: "recovery-fixture", lastSnapshot: CodexAccountSnapshot(planType: "plus", creditBalance: "3000", creditBalanceUnlimited: false,
            accountID: "recovery-fixture-account", email: "recovery-fixture@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        var system = profile; system = CodexProfile(id: "recovery-system", isSystemProfile: true, lastSnapshot: system.lastSnapshot)
        let usage = UsageStore([profile, system]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let run = UUID().uuidString, key = "recovery-fixture-key"
        store.process = child; store.phase = .running; store.runID = run; store.controlKey = key
        store.registeredPool = [profile.id: LocalProxyQueueStore.PoolBinding(home: profile.codexHomeURL,
            account: profile.recordedAccountKey, accountID: profile.lastSnapshot!.accountID!)]
        store.activeIDs = [profile.id]; store.preferences.enabledIDs = [profile.id]
        let request = LocalProxyRequest(schemaVersion: 1, runID: run, key: key, command: "quota_recovery",
            requestID: UUID().uuidString, profileID: profile.id, leaseID: nil)
        func recovered() async -> LocalProxyReply { await store.handle(request) }
        func reject(_ expected: LocalProxyFailure, _ label: String) async throws {
            let reply = await recovered()
            try expect(!reply.ok && reply.error == expected.rawValue && reply.quotaObservedAt == nil
                && reply.accessToken == nil && reply.accountID == nil && reply.leaseID == nil, label)
        }
        let beforeRegistry = try? Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))
        let fresh = await recovered()
        try expect(fresh.ok && fresh.quotaObservedAt == now.timeIntervalSince1970, "fresh subscription evidence returns exact observation timestamp")
        try expect(fresh.accessToken == nil && fresh.accountID == nil && fresh.leaseID == nil && fresh.expiresAt == nil,
            "quota recovery never returns credentials or ownership")
        try expect(store.leases.isEmpty && store.membershipSnapshots.isEmpty && usage.refreshCount == 0
            && (try? Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))) == beforeRegistry,
            "read-only recovery creates no lease, order, registry write or quota refresh")
        store.activeIDs = []; try await reject(.notParticipating, "live membership removal denies recovery"); store.activeIDs = [profile.id]
        store.preferences.enabledIDs = []; try await reject(.notParticipating, "persisted opt-out denies recovery"); store.preferences.enabledIDs = [profile.id]
        usage.profiles[0].lastSnapshot?.fetchedAt = now.addingTimeInterval(-121)
        try await reject(.quotaUnknown, "stale quota cannot clear cooldown"); usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.fetchedAt = now.addingTimeInterval(30)
        try await reject(.quotaUnknown, "future-dated observation cannot clear cooldown"); usage.profiles[0] = profile
        usage.profiles[0].lastQuotaReadFailureAt = now
        try await reject(.quotaUnknown, "last failed refresh fences the previous observation"); usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.quotaReadSucceeded = false
        try await reject(.quotaUnknown, "failed quota evidence denies recovery"); usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.accountID = "changed-fixture-account"
        try await reject(.identity, "registered identity change denies recovery"); usage.profiles[0] = profile
        usage.profiles[0].lastSnapshot?.email = "changed-fixture@example.invalid"
        try await reject(.identity, "registered account change denies recovery"); usage.profiles[0] = profile
        store.creditFallbackEnabled = true
        usage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 100
        try await reject(.quota, "available paid credits cannot masquerade as subscription recovery"); usage.profiles[0] = profile
        store.preferences.accountPolicies = [profile.id: LocalProxyAccountPolicy(fiveHourUsedLimit: 10)]
        try await reject(.usageLimit, "per-account subscription limit still gates recovery"); store.preferences.accountPolicies = nil
        store.finishing = true; try await reject(.stopping, "finishing run denies recovery"); store.finishing = false
        let invalid = await store.handle(LocalProxyRequest(schemaVersion: 1, runID: run, key: key, command: "quota_recovery",
            requestID: UUID().uuidString, profileID: profile.id, leaseID: UUID().uuidString))
        try expect(invalid.error == "identity" && invalid.quotaObservedAt == nil, "lease-bearing quota evidence command is invalid")
        print("PASS: \(checks) quota recovery host checks; synthetic Plus profile only")
        try await policySaveAdmissionFixtures()
    }

    /// Compose the production preference writer, reload and request handler.
    /// The UsageStore input and sleeping child are isolated fixture peripherals;
    /// no credential file, actual helper or provider is needed for a denied request.
    @MainActor static func policySaveAdmissionFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("POLICY_SAVE_ADMISSION_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let preferenceURL = root.appendingPathComponent("local-proxy-queue-v1.json")
        let previous = FileManager.default.fileExists(atPath: preferenceURL.path) ? try Data(contentsOf: preferenceURL) : nil
        // Production saves rotate secret references. Restore the paired fixture
        // Keychain state with the JSON so later stores never see a stale reference.
        let previousSecrets = LocalProxyPreferenceSecrets.items
        defer {
            LocalProxyFixtureRuntime.failPreferenceRename = false
            LocalProxyPreferenceSecrets.items = previousSecrets
            if let previous { try? DispatchParticipationSync.writePrivateProxyPreferences(previous, at: preferenceURL) }
            else { try? FileManager.default.removeItem(at: preferenceURL) }
        }
        let now = Date(), window = CodexQuotaWindowSnapshot(usedPercent: 30, resetsAt: now.addingTimeInterval(3600))
        let profile = CodexProfile(id: "policy-save-fixture", lastSnapshot: CodexAccountSnapshot(planType: "plus",
            accountID: "policy-save-account", email: "policy-save@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        var centralSnapshot = profile.lastSnapshot!
        centralSnapshot.accountID = "policy-save-central-account"; centralSnapshot.email = "policy-save-central@example.invalid"
        let system = CodexProfile(id: "policy-save-central", isSystemProfile: true, lastSnapshot: centralSnapshot)
        let usage = UsageStore([profile, system]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        func activate(_ candidate: LocalProxyQueueStore) {
            candidate.process = child; candidate.phase = .running; candidate.runID = UUID().uuidString
            candidate.controlKey = "policy-save-fixture-key"
            candidate.registeredPool = [profile.id: LocalProxyQueueStore.PoolBinding(home: profile.codexHomeURL,
                account: profile.recordedAccountKey, accountID: profile.lastSnapshot!.accountID!)]
            candidate.activeIDs = candidate.preferences.enabledIDs.intersection([profile.id])
        }
        func request(_ candidate: LocalProxyQueueStore, _ command: String, id: String = UUID().uuidString) -> LocalProxyRequest {
            LocalProxyRequest(schemaVersion: 1, runID: candidate.runID!, key: candidate.controlKey!, command: command,
                requestID: id, profileID: command == "order_end" ? "" : profile.id, leaseID: nil)
        }
        activate(store)
        let defaultEvidence = await store.handle(request(store, "quota_recovery"))
        try expect(defaultEvidence.ok && store.rows.first?.policy.fiveHourUsedLimit == 100,
            "default 100 limit accepts the same fresh 30 percent quota evidence")
        let limit = LocalProxyAccountPolicy(fiveHourUsedLimit: 30)
        try expect(store.canEditPolicy(for: profile.id) && store.setAccountPolicy(id: profile.id, policy: limit),
            "running production Store saves the selected 30 percent limit")
        let savedBytes = try Data(contentsOf: preferenceURL)
        let saved = try JSONDecoder().decode(LocalProxyPreferences.self, from: savedBytes)
        try expect(saved.accountPolicies?[profile.id] == limit && saved.enabledIDs.contains(profile.id),
            "production atomic JSON commit contains 30 and retains participation")
        try expect(store.rows.first?.policy.fiveHourUsedLimit == 30 && store.rows.first?.state == "usage_limit"
            && store.displayRows.first?.policy.fiveHourUsedLimit == 30 && store.displayRows.first?.state == "usage_limit",
            "successful save immediately publishes 30 and the native usage limit state")
        let registryURL = root.appendingPathComponent(DispatchActivityStore.stateName)
        func denied(_ candidate: LocalProxyQueueStore, _ label: String) async throws {
            let beforeRegistry = try? Data(contentsOf: registryURL), id = UUID().uuidString
            let ordered = await candidate.handle(request(candidate, "order", id: id))
            try expect(ordered.ok && ordered.order == [profile.id], "\(label): production order creates a valid membership snapshot")
            let reply = await candidate.handle(request(candidate, "acquire", id: id))
            try expect(!reply.ok && reply.error == "usage_limit" && reply.accessToken == nil
                && reply.accountID == nil && reply.leaseID == nil && reply.expiresAt == nil,
                "\(label): production acquire denies with usage_limit before credentials")
            try expect(candidate.leases.isEmpty && (try? Data(contentsOf: registryURL)) == beforeRegistry,
                "\(label): denied admission leaves the isolated registry unchanged")
            let ended = await candidate.handle(request(candidate, "order_end", id: id))
            try expect(ended.ok && candidate.membershipSnapshots.isEmpty, "\(label): order cleanup retires only its fixture snapshot")
        }
        try await denied(store, "next request at exactly 30")
        let reloadedUsage = UsageStore([profile, system]); reloadedUsage.isPreview = false
        let reloaded = LocalProxyQueueStore(usageStore: reloadedUsage)
        try expect(reloaded.preferencesFailure == nil && reloaded.rows.first?.policy.fiveHourUsedLimit == 30
            && reloaded.displayRows.first?.policy.fiveHourUsedLimit == 30,
            "a new production Store reloads 30 from the committed JSON")
        activate(reloaded)
        try await denied(reloaded, "reloaded request at exactly 30")
        reloadedUsage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 29.99
        reloadedUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        let belowLimit = await reloaded.handle(request(reloaded, "quota_recovery"))
        try expect(belowLimit.ok, "saved 30 limit still accepts fresh subscription evidence below 30")
        var refreshedProfiles = reloadedUsage.profiles
        refreshedProfiles[0].lastSnapshot?.fiveHour?.usedPercent = 31
        refreshedProfiles[0].lastSnapshot?.fetchedAt = Date()
        reloadedUsage.profiles = refreshedProfiles
        // Await the real Combine observation; do not hide a missing observer by
        // explicitly calling rebuildRows after the external profile update.
        for _ in 0..<100 {
            if reloaded.rows.first?.windows.first(where: { $0.id == "5h" })?.remaining == 69 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        reloaded.flushDisplayRows()
        try expect(reloaded.rows.first?.windows.first(where: { $0.id == "5h" })?.remaining == 69
            && reloaded.rows.first?.state == "usage_limit" && reloaded.displayRows.first?.policy.fiveHourUsedLimit == 30,
            "external quota observation refreshes rows without resetting the saved policy")
        try await denied(reloaded, "externally refreshed request above 30")
        reloadedUsage.onRefresh = { _ in
            reloadedUsage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 40
            reloadedUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        }
        reloaded.refreshStatus(displayFreshResultsImmediately: true); reloaded.flushDisplayRows()
        reloadedUsage.onRefresh = nil
        try expect(reloadedUsage.refreshCount == 1 && reloaded.displayRows.first?.windows.first(where: { $0.id == "5h" })?.remaining == 60
            && reloaded.displayRows.first?.policy.fiveHourUsedLimit == 30 && reloaded.displayRows.first?.state == "usage_limit"
            && Data(contentsOf: preferenceURL) == savedBytes,
            "explicit quota refresh preserves 30, its usage limit state and committed bytes")
        try await denied(reloaded, "request after explicit refresh")
        let failedSave = LocalProxyQueueStore(usageStore: reloadedUsage), revision = failedSave.policyRevision
        let blockedDestination = URL(fileURLWithPath: preferenceURL.path + ".blocked")
        let needsBlockedDestination = !FileManager.default.fileExists(atPath: blockedDestination.path)
        if needsBlockedDestination {
            try FileManager.default.createDirectory(at: blockedDestination, withIntermediateDirectories: false)
        }
        defer { if needsBlockedDestination { try? FileManager.default.removeItem(at: blockedDestination) } }
        LocalProxyFixtureRuntime.failPreferenceRename = true
        let accepted = failedSave.setAccountPolicy(id: profile.id, policy: LocalProxyAccountPolicy())
        LocalProxyFixtureRuntime.failPreferenceRename = false
        try expect(!accepted && failedSave.preferencesFailure == .save && failedSave.policyRevision == revision
            && failedSave.preferences.policy(for: profile.id).fiveHourUsedLimit == 30
            && failedSave.displayRows.first?.policy.fiveHourUsedLimit == 30 && Data(contentsOf: preferenceURL) == savedBytes,
            "failed replacement of 30 rolls policy and published rows back while preserving disk")
        let afterFailure = LocalProxyQueueStore(usageStore: reloadedUsage)
        try expect(afterFailure.preferencesFailure == nil && afterFailure.rows.first?.policy.fiveHourUsedLimit == 30,
            "another Store still reloads 30 after the refused save")
        try expect(!FileManager.default.fileExists(atPath: profile.codexHomeURL.path),
            "save, reload, refresh and denied admission create no credential home")
        print("PASS: \(checks) policy save and admission checks; production Store and isolated quota inputs only")
    }

    @MainActor static func cooldownRefreshFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw LocalProxyControlFixtureFailure.check(label) }
            checks += 1
            print("COOLDOWN_REFRESH_CHECK \(checks): \(label)")
        }
        let now = Date(), until = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 3600)
        let window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(7200))
        let profile = CodexProfile(id: "cooldown-refresh-fixture", lastSnapshot: CodexAccountSnapshot(planType: "plus",
            accountID: "cooldown-refresh-account", email: "cooldown-refresh@example.invalid", fetchedAt: now.addingTimeInterval(-2), fiveHour: window, sevenDay: window))
        let usage = UsageStore([profile]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage), run = UUID().uuidString
        store.runID = run; store.activeIDs = [profile.id]; store.preferences.enabledIDs = [profile.id]
        func event(_ state: String, until: Date? = nil) throws {
            var object: [String: Any] = ["event": "account", "profileID": profile.id, "state": state]
            if let until { object["cooldownUntil"] = until.timeIntervalSince1970 }
            store.consume(try JSONSerialization.data(withJSONObject: object), run: run)
            store.flushDisplayRows()
        }
        func held() -> Bool {
            store.accountStates[profile.id] == "quota" && store.rows.first?.state == "quota"
                && store.displayRows.first?.state == "quota" && store.displayRows.first?.cooldownUntil == until
        }
        try event("quota", until: until)
        try expect(held(), "helper cooldown event establishes quota state and exact expiry")
        store.refreshStatus(displayFreshResultsImmediately: true); store.flushDisplayRows()
        if store.rows.first?.state == "ready", ProcessInfo.processInfo.environment["PROXY_COOLDOWN_EXPECT_FALSE_READY"] == "1" {
            print("COOLDOWN_NEGATIVE_REPRODUCED: refresh falsely reports ready during live helper cooldown")
            exit(43)
        }
        try expect(held(), "manual refresh never reports ready during live helper cooldown")
        usage.profiles[0].lastSnapshot?.fetchedAt = now.addingTimeInterval(-1)
        usage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 10
        store.rebuildRows(); store.flushDisplayRows()
        try expect(held() && store.displayRows.first?.windows.first?.remaining == 90,
            "fresh recovered quota updates remaining amount while helper cooldown stays visible")
        store.refreshStatus(); store.flushDisplayRows()
        try expect(held() && usage.refreshCount == 2, "periodic refresh preserves helper cooldown without an extra refresh")
        let revision = store.policyRevision
        store.policyChanged()
        try expect(held() && store.policyRevision == revision + 1, "policy change preserves helper cooldown")
        try event("ready")
        try expect(store.rows.first?.state == "ready" && store.displayRows.first?.state == "ready"
            && store.cooldowns[profile.id] == nil && store.displayRows.first?.cooldownUntil == nil,
            "explicit helper ready clears quota state and cooldown together")
        for state in ["quota", "usage_limit", "subscription_pending", "quota_unknown"] {
            try event(state)
            store.refreshStatus(); store.flushDisplayRows()
            try expect(store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
                "refresh clears \(state) admission error without a live cooldown")
            try event(state)
            store.policyChanged()
            try expect(store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
                "policy change clears \(state) admission error without a live cooldown")
        }
        try event("quota", until: until)
        store.cooldowns[profile.id] = now.addingTimeInterval(-1)
        store.refreshStatus(); store.flushDisplayRows()
        try expect(store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
            "expired helper cooldown does not retain quota state on refresh")
        try event("quota", until: until)
        store.cooldowns[profile.id] = now.addingTimeInterval(-1)
        store.policyChanged()
        try expect(store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
            "expired helper cooldown does not retain quota state on policy change")
        try event("quota", until: now.addingTimeInterval(9 * 86400))
        store.refreshStatus(); store.flushDisplayRows()
        try expect(store.cooldowns[profile.id] == nil && store.accountStates[profile.id] == nil && store.displayRows.first?.state == "ready",
            "invalid helper cooldown cannot pin quota state")
        try event("login_expired")
        store.refreshStatus(); store.policyChanged()
        try expect(store.displayRows.first?.state == "login_expired", "refresh and policy edits preserve unrelated helper failures")
        print("PASS: \(checks) cooldown refresh host checks; synthetic helper events only")
    }
}
