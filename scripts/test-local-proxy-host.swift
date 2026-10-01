import Darwin
import Foundation

@MainActor private func fixtureHandle(_ store: LocalProxyQueueStore, _ request: LocalProxyRequest) async -> LocalProxyReply {
    if request.command.hasPrefix("acquire") && store.membershipSnapshots[request.requestID] == nil {
        let ordered = await store.handle(LocalProxyRequest(
            schemaVersion: request.schemaVersion, runID: request.runID, key: request.key,
            command: "order", requestID: request.requestID,
            profileID: store.registeredPool.keys.sorted().first ?? request.profileID, leaseID: nil))
        precondition(ordered.ok, "fixture requires a host order snapshot before acquire")
    }
    return await store.handle(request)
}

@main struct LocalProxyHostFixtures {
    private static func waitForReserve(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 10) == .success
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        let traceChecks = ProcessInfo.processInfo.environment["PROXY_FIXTURE_TRACE"] == "1"
        func fixtureUUIDv7(at date: Date = Date()) -> String {
            let time = String(format: "%012llx", UInt64(date.timeIntervalSince1970 * 1000))
            let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return "\(time.prefix(8))-\(time.suffix(4))-7\(random.prefix(3))-a\(random.dropFirst(3).prefix(3))-\(random.dropFirst(6).prefix(12))"
        }
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
            if traceChecks { print("PROXY_HOST_CHECK \(checks + 1): \(label)") }
            let result = try value()
            precondition(result, label)
            checks += 1
        }
        try expect(LocalProxyNetworkSettings.resolve([:]) == nil, "system direct/off stays direct")
        let https: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897]
        try expect(LocalProxyNetworkSettings.resolve(https) == "http://127.0.0.1:7897", "system HTTPS maps to HTTP CONNECT")
        try expect(LocalProxyNetworkSettings.resolve(["SOCKSEnable": 1, "SOCKSProxy": "::1", "SOCKSPort": 1080]) == "socks5://[::1]:1080", "system SOCKS normalizes IPv6")
        var both = https
        both["SOCKSEnable"] = 1
        both["SOCKSProxy"] = "127.0.0.1"
        both["SOCKSPort"] = 1080
        try expect(LocalProxyNetworkSettings.resolve(both) == "http://127.0.0.1:7897", "HTTPS takes priority over SOCKS")
        var excepted = https
        excepted["ExceptionsList"] = ["chatgpt.com"]
        try expect(LocalProxyNetworkSettings.resolve(excepted) == nil, "system target bypass exception preserved")
        for invalid: [String: Any] in [
            ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 0],
            ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 65536],
            ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 1.5],
            ["HTTPSEnable": 1, "HTTPSProxy": "user:password@127.0.0.1", "HTTPSPort": 7897],
            ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897, "HTTPSProxyAuthenticated": 1],
            ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897, "HTTPSProxyUsername": "fixture"],
            ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.invalid/proxy.pac"],
            ["ProxyAutoDiscoveryEnable": 1],
        ] {
            do {
                _ = try LocalProxyNetworkSettings.resolve(invalid)
                preconditionFailure("invalid system proxy accepted")
            } catch { checks += 1 }
        }
        expect(LocalProxyNetworkSettings.message(.automaticProxyUnsupported, language: .fixture).contains("PAC/WPAD"), "unsupported automatic proxy has clear safe issue")
        let now = Date()
        let window = CodexQuotaWindowSnapshot(usedPercent: 1, resetsAt: now.addingTimeInterval(3600))
        let snapshot = CodexAccountSnapshot(fetchedAt: now, fiveHour: window, sevenDay: window)
        let profile = CodexProfile(id: "fixture-profile", lastSnapshot: snapshot)
        expect(LocalProxyAdmission.quota(profile, now: now) == nil, "fresh quota")
        expect(LocalProxyAdmission.quota(profile, now: now.addingTimeInterval(121)) == .quotaUnknown, "stale quota")
        var missing = profile
        missing.lastSnapshot?.sevenDay = nil
        expect(LocalProxyAdmission.quota(missing, now: now) == .quotaUnknown, "missing window")
        var failed = profile
        failed.lastQuotaReadFailureAt = now
        expect(LocalProxyAdmission.quota(failed, now: now) == .quotaUnknown, "failed refresh invalidates old quota")
        var spent = profile
        spent.lastSnapshot?.fiveHour?.usedPercent = 100
        expect(LocalProxyAdmission.quota(spent, now: now) == .quota, "exhausted subscription")
        var weeklyOnly = profile
        weeklyOnly.lastSnapshot?.fiveHour = nil
        weeklyOnly.lastSnapshot?.planType = "pro"
        expect(LocalProxyAdmission.quota(weeklyOnly, now: now) == .quotaUnknown, "weekly-only with unknown credits fails closed")
        weeklyOnly.lastSnapshot?.creditBalance = "0"
        weeklyOnly.lastSnapshot?.creditBalanceUnlimited = false
        expect(LocalProxyAdmission.quota(weeklyOnly, now: now) == nil, "official weekly-only Pro without paid fallback")
        weeklyOnly.lastSnapshot?.creditBalance = "10"
        expect(LocalProxyAdmission.quota(weeklyOnly, now: now) == .quotaUnknown, "weekly-only credits cannot authorize fallback")
        expect(LocalProxyAdmission.quota(weeklyOnly, now: now, allowPaidCredits: true) == nil, "explicit credit policy admits valid Pro weekly subscription")
        var paid = spent
        paid.lastSnapshot?.creditBalanceUnlimited = false
        for (balance, floor, allowed) in [
            ("2000.01", 2000, true), ("2000", 2000, false), ("1999", 2000, false), ("1999", 1500, true), ("1500", 1500, false), ("1499", 1500, false), ("NaN", 1500, false),
            ("2,100", 2000, false),
        ] {
            paid.lastSnapshot?.creditBalance = balance
            expect((LocalProxyAdmission.quota(paid, now: now, creditFloor: floor, allowPaidCredits: true) == nil) == allowed, "credit tier boundary and malformed value")
            expect(LocalProxyAdmission.quota(paid, now: now, creditFloor: floor) != nil, "credits require explicit opt-in")
        }
        paid.lastSnapshot?.creditBalance = "2500"
        expect(
            LocalProxyAdmission.quota(paid, now: now.addingTimeInterval(121), creditFloor: 2000, allowPaidCredits: true) == .quotaUnknown, "old balance never authorizes spending")
        paid.lastSnapshot?.creditBalanceUnlimited = true
        expect(LocalProxyAdmission.quota(paid, now: now, creditFloor: 2000, allowPaidCredits: true) != nil, "unbounded balance cannot promise a retained floor")
        var poolSpent = profile
        poolSpent.lastSnapshot?.fiveHour?.usedPercent = 100
        var poolOtherSnapshot = snapshot
        poolOtherSnapshot.accountID = "pool-other"
        poolOtherSnapshot.email = "pool-other@example.invalid"
        var poolOther = CodexProfile(id: "pool-other", lastSnapshot: poolOtherSnapshot)
        let poolIDs: Set<String> = [poolSpent.id, poolOther.id]
        expect(LocalProxyAdmission.creditPool([poolSpent, poolOther], activeIDs: poolIDs, now: now) == .subscriptionPending, "other subscription blocks all paid admission")
        poolOther.lastSnapshot?.fiveHour?.usedPercent = 100
        expect(LocalProxyAdmission.creditPool([poolSpent, poolOther], activeIDs: poolIDs, now: now) == nil, "all fresh exhausted subscriptions allow credit tiers")
        poolOther.lastSnapshot?.fetchedAt = now.addingTimeInterval(-121)
        expect(LocalProxyAdmission.creditPool([poolSpent, poolOther], activeIDs: poolIDs, now: now) == .quotaUnknown, "stale pool member cannot trigger credits")
        poolOther.lastSnapshot?.fetchedAt = now
        poolOther.lastQuotaReadFailureAt = now
        expect(LocalProxyAdmission.creditPool([poolSpent, poolOther], activeIDs: poolIDs, now: now) == .quotaUnknown, "failed quota refresh blocks credits")
        poolOther.lastQuotaReadFailureAt = nil
        poolOther.lastSnapshot?.fiveHour?.usedPercent = 0
        expect(
            LocalProxyAdmission.creditPool([poolSpent, poolOther], activeIDs: poolIDs, now: now) == .subscriptionPending, "reset subscription takes priority over credits again")
        expect(LocalProxyAdmission.creditPool([poolSpent, poolOther], activeIDs: [poolSpent.id], now: now) == nil, "excluded accounts do not gate enrolled credits")
        poolOther.lastSnapshot?.fiveHour = nil
        poolOther.lastSnapshot?.planType = "pro"
        expect(
            LocalProxyAdmission.creditPool([poolSpent, poolOther], activeIDs: poolIDs, now: now) == .subscriptionPending, "Pro reported weekly subscription remains ahead of points"
        )
        poolOther.lastSnapshot?.sevenDay?.usedPercent = 100
        expect(LocalProxyAdmission.creditPool([poolSpent, poolOther], activeIDs: poolIDs, now: now) == nil, "exhausted weekly-only Pro satisfies subscription gate")
        expect(LocalProxyAdmission.creditPool([poolSpent], activeIDs: poolIDs, now: now) == .identity, "missing enrolled account blocks credits")
        expect(LocalProxyAdmission.creditPool([poolSpent, poolOther, poolOther], activeIDs: poolIDs, now: now) == .identity, "duplicate identity blocks pool gate")
        expect(
            LocalProxyAdmission.creditPool([poolSpent], activeIDs: [poolSpent.id], refreshAfter: [poolSpent.id: now], now: now) == .quotaUnknown,
            "unsettled pool member cannot authorize credits")
        expect(LocalProxyAdmission.creditPool([poolSpent], activeIDs: [], now: now) == .identity, "empty pool cannot authorize credits")
        let preferences = LocalProxyPreferences()
        expect(!preferences.isEnabled && preferences.enabledIDs.isEmpty, "module inert default")
        expect(preferences.creditFloors.primary == 2000 && preferences.creditFloors.secondary == 1500, "legacy preferences retain default floors")
        expect(!LocalProxyPreferences.validCreditFloors(primary: 1500, secondary: 2000), "reversed tiers rejected")
        expect(!LocalProxyPreferences.validCreditFloors(primary: 2000, secondary: -1), "negative floor rejected")
        let usage = UsageStore([profile])
        let store = LocalProxyQueueStore(usageStore: usage)
        expect(store.phase == .stopped && !store.isEnabled && store.endpoint == nil, "construction inert")
        expect(!store.requiresStopConfirmation, "stopped proxy does not need interruption consent")
        expect(usage.refreshCount == 0 && !store.canStart, "preview never refreshes or launches")
        let previewResetTarget = store.resetCreditTarget(for: profile.id)!
        expect(previewResetTarget.profile.id == profile.id && previewResetTarget.selectedProfileID == nil && previewResetTarget.hubAccountAlias == nil, "preview reset-card entry has no actionable identity")
        store.refreshAfterResetCredit(previewResetTarget)
        expect(usage.refreshCount == 0, "preview reset-card result never refreshes")
        expect(store.resetCreditTarget(for: "missing") == nil, "reset-card entry rejects a stale queue identity")
        var duplicateResetProfile = profile
        duplicateResetProfile.lastSnapshot?.accountID = "duplicate-reset-account"
        duplicateResetProfile.lastSnapshot?.email = "duplicate-reset@example.invalid"
        let duplicateResetStore = LocalProxyQueueStore(usageStore: UsageStore([profile, duplicateResetProfile]))
        expect(duplicateResetStore.resetCreditTarget(for: profile.id) == nil, "reset-card entry rejects duplicate profile IDs")
        expect(store.rows.first?.isEnabled == true, "new independent queue participation default")
        expect(store.rows.first?.quotaText == "Remaining: 5h 99.0% · Weekly 99.0%", "verified remaining quota labels omit unreported monthly window")
        var weeklyExhausted = profile
        weeklyExhausted.lastSnapshot?.fiveHour?.usedPercent = 44
        weeklyExhausted.lastSnapshot?.sevenDay?.usedPercent = 100
        let quotaPresentationUsage = UsageStore([weeklyExhausted])
        let quotaPresentation = LocalProxyQueueStore(usageStore: quotaPresentationUsage)
        expect(quotaPresentation.rows.first?.windows.first?.remaining == 0, "weekly exhaustion makes the proxy match Home's effective five-hour availability")
        expect(quotaPresentation.rows.first?.windows.first?.constrainedByWeekly == true, "proxy explains the weekly constraint")
        expect(quotaPresentation.rows.first?.quotaText?.contains("5h 0.0%") == true, "proxy tooltip uses the same effective availability")
        expect(quotaPresentationUsage.profiles.first?.lastSnapshot?.fiveHour?.usedPercent == 44, "display projection does not rewrite official quota")
        weeklyExhausted.lastSnapshot?.fiveHour = nil
        quotaPresentationUsage.profiles = [weeklyExhausted]
        quotaPresentation.rebuildRows()
        expect(quotaPresentation.rows.first?.windows.first?.remaining == nil, "unreported short window stays unknown when weekly quota is exhausted")
        weeklyExhausted.lastSnapshot?.fiveHour = window
        weeklyExhausted.lastSnapshot?.sevenDay = window
        quotaPresentationUsage.profiles = [weeklyExhausted]
        quotaPresentation.rebuildRows()
        expect(quotaPresentation.rows.first?.windows.first?.remaining == 99, "quota recovery restores reported short-window availability")
        expect(quotaPresentation.rows.first?.windows.first?.constrainedByWeekly == false, "quota recovery clears the constraint")
        await quotaPresentation.finishForTermination()
        var central = profile
        central = CodexProfile(id: "central", isSystemProfile: true, lastSnapshot: snapshot)
        let duplicateStore = LocalProxyQueueStore(usageStore: UsageStore([profile, central]))
        expect(
            duplicateStore.rows.count == 1 && duplicateStore.rows.first?.isDesktopAccount == true && duplicateStore.rows.first?.isEnabled == false,
            "managed Desktop identity appears as opt-in last resort")
        await store.finishForTermination()
        expect(store.canFinishTermination, "inert shutdown safe")

        let liveFixtureUsage = UsageStore([profile])
        liveFixtureUsage.isPreview = false
        let editable = LocalProxyQueueStore(usageStore: liveFixtureUsage)
        expect(!editable.isEnabled && editable.phase == .stopped && liveFixtureUsage.refreshCount == 0, "nonpreview init inert")
        editable.setOptIn(true)
        editable.setCreditFallback(true)
        expect(editable.setCreditFloors(primary: 2400, secondary: 1800), "custom credit floors save")
        expect(!editable.setCreditFloors(primary: 1800, secondary: 2400), "invalid edit does not replace saved policy")
        editable.setAccountPriority(id: profile.id, priority: true)
        editable.setAccountEnabled(id: profile.id, enabled: false)
        let reloaded = LocalProxyQueueStore(usageStore: liveFixtureUsage)
        expect(reloaded.creditFallbackEnabled && reloaded.creditPrimaryFloor == 2400 && reloaded.creditSecondaryFloor == 1800, "credit policy persists across reload")
        paid.lastSnapshot?.creditBalanceUnlimited = false
        paid.lastSnapshot?.creditBalance = "2399"
        expect(LocalProxyAdmission.quota(paid, now: now, creditFloor: reloaded.creditPrimaryFloor, allowPaidCredits: true) == .quota, "custom first floor enforced")
        expect(LocalProxyAdmission.quota(paid, now: now, creditFloor: reloaded.creditSecondaryFloor, allowPaidCredits: true) == nil, "custom second floor enforced")
        expect(reloaded.isEnabled && reloaded.rows.first?.isEnabled == false && reloaded.rows.first?.isPriority == true, "independent queue preferences persisted")
        expect(liveFixtureUsage.profiles == [profile] && !profile.isDispatchPriorityEnabled, "dispatch profile source unchanged")
        expect(reloaded.phase == .stopped && reloaded.endpoint == nil, "saved opt-in never auto-starts")
        let resetTarget = editable.resetCreditTarget(for: profile.id)!
        expect(resetTarget.selectedProfileID == profile.id && resetTarget.hubAccountAlias == "fixture-alias", "queue reset-card entry binds only its current profile and alias")
        let beforeResetPreferences = editable.preferences
        var resetRefreshIDs: [Set<String>] = []
        liveFixtureUsage.onRefresh = { resetRefreshIDs.append($0) }
        editable.refreshAfterResetCredit(resetTarget)
        expect(resetRefreshIDs == [[profile.id]], "confirmed reset-card result refreshes only the target account")
        var resetRefreshedProfile = profile
        resetRefreshedProfile.lastSnapshot?.fetchedAt = now.addingTimeInterval(1)
        resetRefreshedProfile.lastSnapshot?.fiveHour?.usedPercent = 30
        liveFixtureUsage.profiles = [resetRefreshedProfile]
        editable.rebuildRows()
        expect(editable.displayRows.first?.windows.first?.remaining == 70 && editable.resetCreditRefreshTarget == nil, "reset-card quota result publishes immediately instead of waiting for the routine snapshot interval")
        expect(
            editable.preferences.order == beforeResetPreferences.order && editable.preferences.enabledIDs == beforeResetPreferences.enabledIDs
                && editable.preferences.priorityIDs == beforeResetPreferences.priorityIDs
                && editable.preferences.creditPrimaryFloor == beforeResetPreferences.creditPrimaryFloor
                && editable.preferences.creditSecondaryFloor == beforeResetPreferences.creditSecondaryFloor,
            "reset-card result preserves queue membership, ordering, priority and credit floors")
        resetRefreshedProfile.lastSnapshot?.accountID = "identity-changed"
        liveFixtureUsage.profiles = [resetRefreshedProfile]
        editable.refreshAfterResetCredit(resetTarget)
        expect(resetRefreshIDs.count == 1, "changed account identity rejects a stale reset-card callback")
        liveFixtureUsage.profiles = [profile]
        editable.finishing = true
        editable.refreshAfterResetCredit(resetTarget)
        expect(resetRefreshIDs.count == 1, "terminating proxy rejects a stale reset-card callback")
        editable.finishing = false
        liveFixtureUsage.onRefresh = nil
        editable.rebuildRows()
        var secondSnapshot = snapshot
        secondSnapshot.accountID = "second-account"
        secondSnapshot.email = "second@example.invalid"
        var thirdSnapshot = snapshot
        thirdSnapshot.accountID = "third-account"
        thirdSnapshot.email = "third@example.invalid"
        let orderUsage = UsageStore([profile, CodexProfile(id: "second", lastSnapshot: secondSnapshot), CodexProfile(id: "third", lastSnapshot: thirdSnapshot)])
        orderUsage.isPreview = false
        let ordering = LocalProxyQueueStore(usageStore: orderUsage)
        ordering.setAccountPriority(id: profile.id, priority: false)
        ordering.setAccountPriority(id: "second", priority: true)
        ordering.setAccountPriority(id: "third", priority: true)
        ordering.moveAccount(id: "third", by: -1)
        let orderingReloaded = LocalProxyQueueStore(usageStore: orderUsage)
        expect(orderingReloaded.rows.map(\.id) == ["third", "second", profile.id], "same-priority manual order persists")
        expect(orderUsage.profiles.allSatisfy { !$0.isDispatchPriorityEnabled }, "proxy priority never writes old dispatch priority")
        let desktopOrderUsage = UsageStore(orderUsage.profiles + [central])
        desktopOrderUsage.isPreview = false
        let desktopOrdering = LocalProxyQueueStore(usageStore: desktopOrderUsage)
        desktopOrdering.setAccountPriority(id: profile.id, priority: true)
        desktopOrdering.setAccountEnabled(id: profile.id, enabled: true)
        expect(desktopOrdering.rows.last?.id == profile.id, "current Desktop is last even with priority")
        let root = DispatchParticipationPaths.supportDirectory()
        let activity = DispatchActivityStore(directory: root)
        let run = UUID().uuidString
        var request = UUID().uuidString
        let id = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run, requestID: request, profileID: profile.id, childPID: getpid())
        func pythonInterop(_ mode: String, lease: String) throws -> [String: Any] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROXY_FIXTURE_PYTHON"]!)
            child.arguments = [ProcessInfo.processInfo.environment["PROXY_FIXTURE_INTEROP"]!, mode, lease]
            let output = Pipe()
            child.standardOutput = output
            try child.run()
            child.waitUntilExit()
            expect(child.terminationStatus == 0, "Python registry interop stage")
            let result = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
            expect(result["ok"] as? Bool == true, "Python registry stage result")
            checks += result["checks"] as? Int ?? 0
            return result
        }
        try activity.updateProxy(id, runID: run, requestID: request, profileID: profile.id, state: "running")
        let pythonHeld = try pythonInterop("native-active", lease: id)["leaseID"] as! String
        try expect(try activity.read().proxyAcquireKeys?.contains {
            $0.runID == run && $0.requestID == request && $0.wasReserved && !$0.abandoned
        } == true, "other lease writer preserves persisted proxy request fence")
        do {
            _ = try activity.reserveProxy(account: "python-held", alias: "independent-alias", runID: run, requestID: UUID().uuidString, profileID: profile.id, childPID: getpid())
            preconditionFailure("native proxy ignored Python reservation")
        } catch DispatchActivityStore.Failure.busy { checks += 1 }
        do {
            try activity.updateProxy(pythonHeld, runID: run, requestID: request, profileID: profile.id, state: "accepted")
            preconditionFailure("native proxy released Python lease")
        } catch { checks += 1 }
        _ = try pythonInterop("release-python", lease: pythonHeld)
        // Native heartbeat still binds after Python has atomically rewritten the shared JSON.
        try activity.updateProxy(id, runID: run, requestID: request, profileID: profile.id, state: "running")
        let reserved = try activity.read()
        expect(reserved.leases.first?.route == "proxy" && reserved.leases.first?.occupied == true, "proxy shared reservation")
        do {
            _ = try activity.reserveWarmUp(account: "fixture-account", alias: "other")
            preconditionFailure("overlap")
        } catch DispatchActivityStore.Failure.busy { checks += 1 }
        do {
            try activity.updateProxy(id, runID: UUID().uuidString, requestID: request, profileID: profile.id, state: "accepted")
            preconditionFailure("foreign run")
        } catch { checks += 1 }
        do {
            try activity.updateProxy(id, runID: run, requestID: UUID().uuidString, profileID: profile.id, state: "accepted")
            preconditionFailure("foreign request")
        } catch { checks += 1 }
        try activity.updateProxy(id, runID: run, requestID: request, profileID: profile.id, state: "uncertain")
        _ = try pythonInterop("native-uncertain", lease: id)
        try activity.finishStoppedProxyRuns()
        let uncertain = try activity.read()
        expect(uncertain.leases.first?.occupied == true, "uncertainty retains lease for live owner")
        try activity.updateProxy(id, runID: run, requestID: request, profileID: profile.id, state: "accepted")
        let released = try activity.read()
        expect(released.leases.first?.occupied == false, "bound release")
        _ = try pythonInterop("native-released", lease: id)
        let tombstoneRequest = UUID().uuidString
        let tombstone = try activity.abandonProxy(runID: run, requestID: tombstoneRequest, profileID: profile.id)
        expect(tombstone == .notReserved, "resolve before reserve durably denies late acquire")
        do {
            _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run, requestID: tombstoneRequest, profileID: profile.id, childPID: getpid())
            preconditionFailure("late reserve crossed tombstone")
        } catch DispatchActivityStore.Failure.busy { checks += 1 }
        let reservedRequest = UUID().uuidString
        let reservedID = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run, requestID: reservedRequest, profileID: profile.id, childPID: getpid())
        do {
            _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run, requestID: reservedRequest, profileID: profile.id, childPID: getpid())
            preconditionFailure("duplicate acquire reserved again")
        } catch DispatchActivityStore.Failure.busy { checks += 1 }
        try expect(try activity.abandonProxy(runID: run, requestID: reservedRequest, profileID: profile.id) == .abandoned,
            "resolve cancels existing reservation")
        try expect(try activity.abandonProxy(runID: run, requestID: reservedRequest, profileID: profile.id) == .abandoned,
            "resolve is idempotent")
        try expect(try activity.read().leases.first(where: { $0.leaseId == reservedID })?.state == "cancelled", "resolve leaves no active lease")
        do {
            _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run, requestID: reservedRequest, profileID: profile.id, childPID: getpid())
            preconditionFailure("resolved acquire replayed")
        } catch DispatchActivityStore.Failure.busy { checks += 1 }
        let oldRequest = fixtureUUIDv7(at: Date().addingTimeInterval(-200))
        _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run,
            requestID: oldRequest, profileID: profile.id, childPID: getpid())
        _ = try activity.abandonProxy(runID: run, requestID: oldRequest, profileID: profile.id)
        let freshRequest = fixtureUUIDv7()
        _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run,
            requestID: freshRequest, profileID: profile.id, childPID: getpid(),
            admissionDeadline: ProcessInfo.processInfo.systemUptime + 5, enforceFreshness: true)
        _ = try activity.abandonProxy(runID: run, requestID: freshRequest, profileID: profile.id, enforceFreshness: true)
        try expect(try activity.read().proxyAcquireKeys?.contains(where: { $0.requestID == oldRequest }) == false,
            "high-water safely prunes keys outside the accepted time window")
        do {
            _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run,
                requestID: oldRequest, profileID: profile.id, childPID: getpid(),
                admissionDeadline: ProcessInfo.processInfo.systemUptime + 5, enforceFreshness: true)
            preconditionFailure("pruned old request replayed")
        } catch DispatchActivityStore.Failure.deadline { checks += 1 }
        let retiredRun = UUID().uuidString
        let retiredRequest = UUID().uuidString
        let retiredLease = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: retiredRun,
            requestID: retiredRequest, profileID: profile.id, childPID: getpid())
        DispatchActivityStore.closeProxyRun(retiredRun)
        try activity.finishStoppedProxyRuns(retiringCurrentRun: true)
        try expect(try activity.read().leases.first(where: { $0.leaseId == retiredLease })?.state == "cancelled",
            "retired run cancels reservation absent from the in-memory lease map")
        do {
            _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: retiredRun,
                requestID: UUID().uuidString, profileID: profile.id, childPID: getpid())
            preconditionFailure("detached old run reserved after retirement")
        } catch DispatchActivityStore.Failure.deadline { checks += 1 }
        let longRun = UUID().uuidString
        let longStart = Date().addingTimeInterval(-1000)
        for index in 0..<1000 {
            let moment = longStart.addingTimeInterval(Double(index))
            let key = fixtureUUIDv7(at: moment)
            _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: longRun,
                requestID: key, profileID: profile.id, childPID: getpid(),
                admissionDeadline: ProcessInfo.processInfo.systemUptime + 5, enforceFreshness: true, now: moment)
            _ = try activity.abandonProxy(runID: longRun, requestID: key, profileID: profile.id,
                enforceFreshness: true, now: moment)
        }
        let longKeys = try activity.read().proxyAcquireKeys?.filter { $0.runID == longRun } ?? []
        expect(longKeys.count <= 151, "one thousand requests retain only the safe replay window")
        let stateBytes = try Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName)).count
        expect(stateBytes < 200_000, "long-running run stays well below the shared registry limit")

        // A disposable sleep process supplies lifecycle evidence, never an app or proxy helper.
        var otherSnapshot = snapshot
        otherSnapshot.email = "central@example.invalid"
        otherSnapshot.accountID = "central-account"
        let isolatedUsage = UsageStore([profile, CodexProfile(id: "system", isSystemProfile: true, lastSnapshot: otherSnapshot)])
        isolatedUsage.isPreview = false
        let lifecycle = LocalProxyQueueStore(usageStore: isolatedUsage)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        lifecycle.process = child
        lifecycle.phase = .running
        lifecycle.runID = run
        lifecycle.controlKey = "fixture-secret"
        lifecycle.activeIDs = [profile.id]
        lifecycle.registeredPool[profile.id] = LocalProxyQueueStore.PoolBinding(
            home: profile.codexHomeURL, account: profile.recordedAccountKey, accountID: profile.lastSnapshot!.accountID!)
        var queuedRequest = LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire", requestID: UUID().uuidString, profileID: profile.id, leaseID: nil)
        queuedRequest.receivedAt = ProcessInfo.processInfo.systemUptime - 30
        let beforeQueued = try activity.read().leases.filter(\.occupied).count
        let queuedReply = await fixtureHandle(lifecycle, queuedRequest)
        expect(queuedReply.error == "admission_deadline" && lifecycle.leases.isEmpty,
            "main actor delay expires before any reservation")
        try expect(try activity.read().leases.filter(\.occupied).count == beforeQueued,
            "expired queued acquire does not write a lease")
        let denied = await fixtureHandle(lifecycle,
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire", requestID: UUID().uuidString, profileID: profile.id, leaseID: nil))
        expect(denied.error == "unavailable" && lifecycle.leases.isEmpty, "failed Hub releases preparation before credentials")
        let stageMismatch = await fixtureHandle(lifecycle,
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire_desktop", requestID: UUID().uuidString, profileID: profile.id, leaseID: nil))
        expect(stageMismatch.error == "stage_not_applicable" && lifecycle.leases.isEmpty, "other identity stage is silently inapplicable")
        let invalidIdentity = await fixtureHandle(lifecycle,
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire", requestID: UUID().uuidString, profileID: "unknown", leaseID: nil))
        expect(invalidIdentity.error == "identity" && lifecycle.leases.isEmpty, "actual identity mismatch still rejects admission")
        HubConsoleModel.fixtureAvailability = .busy
        var warmUpEntered = false
        HubConsoleModel.fixtureOnWarmUp = { warmUpEntered = true; Thread.sleep(forTimeInterval: 1.2) }
        var lateRequest = LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire", requestID: fixtureUUIDv7(), profileID: profile.id, leaseID: nil)
        lateRequest.receivedAt = ProcessInfo.processInfo.systemUptime - 17
        let lateReply = await fixtureHandle(lifecycle, lateRequest)
        HubConsoleModel.fixtureOnWarmUp = nil
        expect(warmUpEntered && lateReply.error == "admission_deadline" && lifecycle.leases.isEmpty,
            "deadline after reserve cancels exact lease")
        try expect(try activity.read().leases.filter { $0.taskId == "proxy-\(run)-\(lateRequest.requestID)" && $0.occupied }.isEmpty,
            "late host reply has no orphan reservation")

        let raceRun = UUID().uuidString
        let raceRequest = LocalProxyRequest(schemaVersion: 1, runID: raceRun, key: "fixture-secret",
            command: "acquire", requestID: fixtureUUIDv7(), profileID: profile.id, leaseID: nil)
        let reserveEntered = DispatchSemaphore(value: 0)
        let resumeReserve = DispatchSemaphore(value: 0)
        LocalProxyFixtureRuntime.afterReserve = {
            reserveEntered.signal()
            _ = resumeReserve.wait(timeout: .now() + 10)
        }
        lifecycle.runID = raceRun
        let pendingOldRun = Task { await fixtureHandle(lifecycle, raceRequest) }
        let didReserve = await Task.detached { Self.waitForReserve(reserveEntered) }.value
        expect(didReserve, "old run commits reservation before main actor resumes")
        expect(lifecycle.canToggleAccount(id: profile.id), "in-flight reserve does not lock future participation")
        lifecycle.setAccountEnabled(id: profile.id, enabled: false)
        expect(!lifecycle.activeIDs.contains(profile.id)
            && lifecycle.membershipSnapshots[raceRequest.requestID]?.order.contains(profile.id) == true,
            "leaving removes future participation while preserving the in-flight reservation snapshot")
        try expect(try activity.read().leases.contains { $0.taskId == "proxy-\(raceRun)-\(raceRequest.requestID)" && $0.occupied },
            "race fixture observes committed old-run lease")
        DispatchActivityStore.closeProxyRun(raceRun)
        try activity.finishStoppedProxyRuns(retiringCurrentRun: true)
        lifecycle.runID = UUID().uuidString
        resumeReserve.signal()
        let oldRunReply = await pendingOldRun.value
        LocalProxyFixtureRuntime.afterReserve = nil
        lifecycle.runID = run
        lifecycle.setAccountEnabled(id: profile.id, enabled: true)
        expect(oldRunReply.error == "stopping" && lifecycle.leases.values.allSatisfy { $0.runID != raceRun },
            "detached old-run result cannot enter a new run's memory table")
        try expect(try activity.read().leases.filter { $0.taskId == "proxy-\(raceRun)-\(raceRequest.requestID)" && $0.occupied }.isEmpty,
            "late old-run result leaves no active disk reservation")

        let activityPath = root.appendingPathComponent("dispatch-activity-v1.json")
        let activityBeforeRollback = try Data(contentsOf: activityPath)
        HubConsoleModel.fixtureAvailability = .busy
        HubConsoleModel.fixtureOnWarmUp = {
            try? Data("fixture-corrupt".utf8).write(to: activityPath, options: .atomic)
        }
        let unknownRollback = await fixtureHandle(lifecycle,
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire", requestID: UUID().uuidString, profileID: profile.id, leaseID: nil))
        HubConsoleModel.fixtureOnWarmUp = nil
        HubConsoleModel.fixtureAvailability = .unavailable
        try activityBeforeRollback.write(to: activityPath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activityPath.path)
        expect(unknownRollback.error == "admission_unknown" && !lifecycle.leases.isEmpty, "failed reservation rollback reports unknown and retains lease")
        if let retained = lifecycle.leases.values.first {
            lifecycle.leases.removeValue(forKey: retained.id)
        }
        request = UUID().uuidString
        var held = try activity.reserveProxy(
            account: "fixture-account", alias: "fixture-alias", runID: run, requestID: request, profileID: profile.id, childPID: child.processIdentifier)
        lifecycle.leases[held] = LocalProxyQueueStore.Lease(id: held, profileID: profile.id, requestID: request, runID: run)
        let contentionFD = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR | O_CLOEXEC)
        expect(contentionFD >= 0 && flock(contentionFD, LOCK_EX | LOCK_NB) == 0, "fixture owns independent registry lock")
        let beforeContention = try Data(contentsOf: activityPath)
        for command in ["heartbeat", "release"] {
            let reply = await fixtureHandle(lifecycle, LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: command, requestID: request, profileID: profile.id, leaseID: held))
            expect(reply.error == "control_busy" && !reply.ok && lifecycle.leases[held] != nil, "lock contention reports no mutation without forgetting ownership")
        }
        let afterContention = try Data(contentsOf: activityPath)
        expect(afterContention == beforeContention, "rejected maintenance did not mutate the registry")
        _ = flock(contentionFD, LOCK_UN)
        Darwin.close(contentionFD)
        let recoveredHeartbeat = await fixtureHandle(lifecycle, LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "heartbeat", requestID: request, profileID: profile.id, leaseID: held))
        expect(recoveredHeartbeat.ok && lifecycle.phase == .running, "heartbeat recovers after lock contention without stopping the proxy")
        lifecycle.accountStates[profile.id] = "current"
        lifecycle.rebuildRows()
        expect(lifecycle.rows.first(where: { $0.id == profile.id })?.isCurrent == false, "preparation alone is not an admitted request")
        expect(lifecycle.rows.first(where: { $0.id == profile.id })?.activeRequestCount == 0, "unadmitted reservations do not count as active requests")
        lifecycle.leases[held]?.isAdmitted = true
        let competingBusyEvent = try JSONSerialization.data(withJSONObject: ["event": "account", "profileID": profile.id, "state": "busy"])
        lifecycle.consume(competingBusyEvent, run: run)
        expect(lifecycle.rows.first(where: { $0.id == profile.id })?.isCurrent == true, "a waiting request cannot hide the admitted request")
        expect(lifecycle.rows.first(where: { $0.id == profile.id })?.activeRequestCount == 1, "hover count is backed by the admitted lease despite competing busy events")
        lifecycle.setAccountEnabled(id: profile.id, enabled: false)
        expect(lifecycle.rows.first(where: { $0.id == profile.id })?.isEnabled == false
            && lifecycle.rows.first(where: { $0.id == profile.id })?.isCurrent == true,
            "a removed account still displays its admitted request until completion")
        let drainingHeartbeat = await fixtureHandle(lifecycle, LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "heartbeat", requestID: request, profileID: profile.id, leaseID: held))
        expect(drainingHeartbeat.ok && lifecycle.leases[held] != nil && child.isRunning,
            "an excluded account retains its owned heartbeat without restarting the service")
        let releasedCurrent = await fixtureHandle(lifecycle, LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "release", requestID: request, profileID: profile.id, leaseID: held))
        expect(releasedCurrent.ok && lifecycle.rows.first(where: { $0.id == profile.id })?.isCurrent == false, "released account is no longer shown as requesting")
        expect(lifecycle.rows.first(where: { $0.id == profile.id })?.activeRequestCount == 0, "release immediately removes the live hover request count")
        lifecycle.setAccountEnabled(id: profile.id, enabled: true)
        let lateCurrentEvent = try JSONSerialization.data(withJSONObject: ["event": "account", "profileID": profile.id, "state": "current"])
        lifecycle.consume(lateCurrentEvent, run: run)
        expect(lifecycle.rows.first(where: { $0.id == profile.id })?.isCurrent == false, "late helper event cannot resurrect a released request")
        request = UUID().uuidString
        held = try activity.reserveProxy(
            account: "fixture-account", alias: "fixture-alias", runID: run, requestID: request, profileID: profile.id, childPID: child.processIdentifier)
        lifecycle.leases[held] = LocalProxyQueueStore.Lease(id: held, profileID: profile.id, requestID: request, runID: run)
        // Reuse only the fixture child: live queue edits must neither stop it nor touch its lease.
        desktopOrdering.setAccountPriority(id: "second", priority: false)
        desktopOrdering.setAccountPriority(id: "third", priority: false)
        desktopOrdering.process = child
        desktopOrdering.phase = .running
        desktopOrdering.runID = run
        desktopOrdering.controlKey = "fixture-secret"
        desktopOrdering.activeIDs = [profile.id, "second", "third"]
        desktopOrdering.registeredPool = Dictionary(uniqueKeysWithValues: desktopOrderUsage.profiles
            .filter { !$0.isSystemProfile }.map { ($0.id, LocalProxyQueueStore.PoolBinding(
                home: $0.codexHomeURL, account: $0.recordedAccountKey, accountID: $0.lastSnapshot!.accountID!)) })
        desktopOrdering.leases[held] = lifecycle.leases[held]
        let orderRequest = LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "order", requestID: request, profileID: profile.id, leaseID: nil)
        let registryBeforeOrdering = try Data(contentsOf: root.appendingPathComponent("dispatch-activity-v1.json"))
        let refreshesBeforeOrdering = desktopOrderUsage.refreshCount
        expect(desktopOrdering.canReorder && !desktopOrdering.canEdit, "running lease permits queue edits but not service policy edits")
        expect(!desktopOrdering.canMoveAccount(id: profile.id, by: -1), "Desktop cannot move ahead of other accounts")
        expect(!desktopOrdering.canMoveAccount(id: "third", by: -1), "first row cannot move above the queue")
        expect(!desktopOrdering.canMoveAccount(id: "third", by: 2), "only adjacent moves are accepted")
        desktopOrdering.moveAccount(id: "second", by: -1)
        let moved = await desktopOrdering.handle(orderRequest)
        expect(moved.ok && moved.order == ["second", "third", profile.id], "running order request returns current manual order")
        expect(moved.accessToken == nil && moved.accountID == nil && moved.leaseID == nil, "order reply contains no credentials or reservation")
        desktopOrdering.setAccountPriority(id: "third", priority: true)
        let priorityRequest = LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret",
            command: "order", requestID: UUID().uuidString, profileID: profile.id, leaseID: nil)
        let prioritized = await desktopOrdering.handle(priorityRequest)
        expect(prioritized.order == ["third", "second", profile.id], "live priority takes effect on next order query")
        expect(!desktopOrdering.canMoveAccount(id: "second", by: -1), "arrows cannot silently cross priority tiers")
        desktopOrdering.setAccountEnabled(id: "second", enabled: false)
        expect(desktopOrdering.rows.first(where: { $0.id == "second" })?.isEnabled == false,
            "one active account cannot lock an unrelated account's participation")
        let orderAfterRemoval = await desktopOrdering.handle(priorityRequest)
        expect(orderAfterRemoval.order == prioritized.order,
            "participation edits preserve an existing request's order")
        expect(!desktopOrdering.setCreditFloors(primary: 2500, secondary: 1800), "running financial policy stays fixed")
        let liveOrderingReloaded = LocalProxyQueueStore(usageStore: desktopOrderUsage)
        expect(liveOrderingReloaded.rows.map(\.id) == prioritized.order, "live order and priority survive preference reload")
        expect(liveOrderingReloaded.rows.first?.isPriority == true, "live priority persists")
        for invalid in [
            LocalProxyRequest(schemaVersion: 1, runID: "foreign", key: "fixture-secret", command: "order", requestID: request, profileID: profile.id, leaseID: nil),
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "wrong", command: "order", requestID: request, profileID: profile.id, leaseID: nil),
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "order", requestID: "invalid", profileID: profile.id, leaseID: nil),
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "order", requestID: request, profileID: "foreign", leaseID: nil),
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "order", requestID: request, profileID: profile.id, leaseID: held),
        ] {
            let reply = await desktopOrdering.handle(invalid)
            expect(!reply.ok && reply.order == nil, "forged order query fails closed")
        }
        desktopOrdering.activeIDs.insert("missing")
        let missingRequest = LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret",
            command: "order", requestID: UUID().uuidString, profileID: profile.id, leaseID: nil)
        let missingOrder = await desktopOrdering.handle(missingRequest)
        expect(missingOrder.ok && missingOrder.order?.contains("missing") == false,
            "unregistered account cannot enter new request order")
        desktopOrdering.activeIDs.remove("missing")
        desktopOrdering.phase = .stopping
        let stoppingOrder = await desktopOrdering.handle(orderRequest)
        expect(!desktopOrdering.canReorder && !stoppingOrder.ok, "stopping disables order edits and queries")
        desktopOrdering.phase = .running
        desktopOrdering.finishing = true
        expect(!desktopOrdering.canReorder, "termination disables live edits")
        desktopOrdering.finishing = false
        desktopOrdering.preferencesBlocked = true
        let blockedOrder = await desktopOrdering.handle(orderRequest)
        expect(!desktopOrdering.canReorder && !blockedOrder.ok, "failed preference persistence blocks new order admission")
        desktopOrdering.preferencesBlocked = false
        try expect(Data(contentsOf: root.appendingPathComponent("dispatch-activity-v1.json")) == registryBeforeOrdering, "live edits and order queries do not mutate active leases")
        expect(
            desktopOrderUsage.refreshCount == refreshesBeforeOrdering && child.isRunning && desktopOrdering.leases.count == 1,
            "live edits neither refresh credentials nor stop the active child")
        desktopOrdering.leases = [:]
        desktopOrdering.process = nil
        desktopOrdering.phase = .stopped
        lifecycle.cleanupConfirmedExit()
        expect(!lifecycle.leases.isEmpty && !lifecycle.canFinishTermination, "running child cannot release leases")
        expect(lifecycle.requiresStopConfirmation, "running proxy requires interruption consent")
        child.terminate()
        child.waitUntilExit()
        lifecycle.childExited(child)
        expect(lifecycle.leases.isEmpty && lifecycle.canFinishTermination, "confirmed child exit releases only owned leases")
        expect(!lifecycle.requiresStopConfirmation, "confirmed exit clears interruption consent")

        // A busy proxy accepts membership changes for subsequent requests;
        // existing order snapshots and leases remain independently valid.
        let memberA = CodexProfile(id: "member-a", lastSnapshot: snapshot)
        let memberB = CodexProfile(id: "member-b", lastSnapshot: secondSnapshot)
        let memberUsage = UsageStore([memberA, memberB, central])
        memberUsage.isPreview = false
        let membershipStore = LocalProxyQueueStore(usageStore: memberUsage)
        let membershipChild = Process()
        membershipChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        membershipChild.arguments = ["30"]
        try membershipChild.run()
        defer { if membershipChild.isRunning { membershipChild.terminate() } }
        membershipStore.process = membershipChild
        membershipStore.phase = .running
        membershipStore.runID = run
        membershipStore.controlKey = "fixture-secret"
        membershipStore.registeredPool = Dictionary(uniqueKeysWithValues: [memberA, memberB].map {
            ($0.id, LocalProxyQueueStore.PoolBinding(home: $0.codexHomeURL,
                account: $0.recordedAccountKey, accountID: $0.lastSnapshot!.accountID!))
        })
        membershipStore.activeIDs = [memberA.id, memberB.id]
        expect(membershipStore.canToggleAccount(id: memberA.id), "idle live proxy permits existing verified member edits")
        func memberRequest(_ command: String, id: String, profileID: String? = nil) -> LocalProxyRequest {
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: command,
                requestID: id, profileID: profileID ?? memberA.id, leaseID: nil)
        }
        let firstMemberRequest = UUID().uuidString
        let initialMembers = await membershipStore.handle(memberRequest("order", id: firstMemberRequest))
        expect(initialMembers.ok && Set(initialMembers.order ?? []) == [memberA.id, memberB.id] && membershipStore.membershipChangeWaiting,
            "new request freezes verified participants independently of queue edits")
        expect(membershipStore.canToggleAccount(id: memberA.id), "in-flight request permits future membership removal")
        membershipStore.setAccountEnabled(id: memberA.id, enabled: false)
        expect(!membershipStore.activeIDs.contains(memberA.id) && membershipChild.isRunning,
            "member leaves new requests without stopping the helper")
        let nextMemberRequest = UUID().uuidString
        let nextMembers = await membershipStore.handle(memberRequest("order", id: nextMemberRequest))
        expect(nextMembers.order == [memberB.id], "overlapping new request excludes the removed member")
        _ = await membershipStore.handle(memberRequest("order_end", id: nextMemberRequest, profileID: ""))
        membershipStore.setAccountPriority(id: memberB.id, priority: true)
        let frozenMembers = await membershipStore.handle(memberRequest("order", id: firstMemberRequest))
        expect(frozenMembers.order == initialMembers.order, "same request retains members and priority captured before the edit")
        let ended = await membershipStore.handle(memberRequest("order_end", id: firstMemberRequest, profileID: ""))
        expect(ended.ok && !membershipStore.membershipChangeWaiting && membershipStore.canToggleAccount(id: memberA.id),
            "completed request releases its snapshot without stopping child")
        membershipStore.setAccountEnabled(id: memberA.id, enabled: false)
        membershipStore.setAccountEnabled(id: memberB.id, enabled: false)
        expect(membershipStore.activeIDs.isEmpty && membershipChild.isRunning,
            "last participant may leave an idle running proxy")
        let emptyRequestID = UUID().uuidString
        let emptyMembers = await membershipStore.handle(memberRequest("order", id: emptyRequestID))
        expect(emptyMembers.ok && emptyMembers.order?.isEmpty == true,
            "empty membership is an explicit successful order snapshot")
        membershipStore.setAccountEnabled(id: memberB.id, enabled: true)
        expect(membershipStore.activeIDs == [memberB.id], "empty in-flight snapshot does not block adding a verified member")
        let stillEmpty = await membershipStore.handle(memberRequest("order", id: emptyRequestID))
        expect(stillEmpty.order?.isEmpty == true, "adding a member cannot mutate an already empty request snapshot")
        _ = await membershipStore.handle(memberRequest("order_end", id: emptyRequestID, profileID: ""))
        membershipStore.setAccountEnabled(id: "foreign", enabled: true)
        expect(membershipStore.activeIDs == [memberB.id] && !membershipStore.canToggleAccount(id: "foreign"),
            "unknown ID cannot enter the registered pool")
        memberUsage.profiles[0].lastSnapshot?.accountID = "changed-identity"
        membershipStore.setAccountEnabled(id: memberA.id, enabled: true)
        expect(!membershipStore.activeIDs.contains(memberA.id), "changed binding cannot be reintroduced")
        memberUsage.profiles[0].lastSnapshot?.accountID = snapshot.accountID
        membershipStore.setAccountEnabled(id: memberB.id, enabled: true)
        let addedRequestID = UUID().uuidString
        let addedMembers = await membershipStore.handle(memberRequest("order", id: addedRequestID))
        expect(addedMembers.order == [memberB.id], "re-added pool member enters only the next request")
        _ = await membershipStore.handle(memberRequest("order_end", id: addedRequestID, profileID: ""))
        membershipStore.setAccountEnabled(id: memberA.id, enabled: true)
        expect(membershipStore.activeIDs == [memberA.id, memberB.id], "valid former member can rejoin after request")
        for _ in 0..<5_000 {
            let id = fixtureUUIDv7()
            let order = await membershipStore.handle(memberRequest("order", id: id))
            guard order.ok && order.order?.isEmpty == false else { preconditionFailure("long run order rejected") }
            let end = await membershipStore.handle(memberRequest("order_end", id: id, profileID: ""))
            guard end.ok else { preconditionFailure("long run completion rejected") }
        }
        expect(membershipStore.membershipSnapshots.isEmpty && membershipStore.canToggleAccount(id: memberA.id),
            "completed long-run requests never exhaust the snapshot limit")
        membershipChild.terminate()
        membershipChild.waitUntilExit()
        membershipStore.process = nil
        membershipStore.phase = .stopped

        let uncertainChild = Process()
        uncertainChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        uncertainChild.arguments = ["30"]
        try uncertainChild.run()
        let uncertainStore = LocalProxyQueueStore(usageStore: isolatedUsage)
        let uncertainRun = UUID().uuidString
        let uncertainRequest = UUID().uuidString
        uncertainStore.process = uncertainChild
        uncertainStore.phase = .running
        uncertainStore.runID = uncertainRun
        let uncertainLease = try activity.reserveProxy(
            account: "fixture-account", alias: "fixture-alias", runID: uncertainRun, requestID: uncertainRequest, profileID: profile.id, childPID: uncertainChild.processIdentifier)
        uncertainStore.leases[uncertainLease] = LocalProxyQueueStore.Lease(id: uncertainLease, profileID: profile.id, requestID: uncertainRequest, runID: uncertainRun)
        LocalProxyFixtureRuntime.allowStopSignals = false
        await uncertainStore.stop()
        expect(uncertainStore.phase == .failed && !uncertainStore.leases.isEmpty && !uncertainStore.canFinishTermination, "unconfirmed stop retains lease and blocks quit")
        expect(uncertainStore.requiresStopConfirmation, "uncertain lease still requires interruption consent")
        LocalProxyFixtureRuntime.allowStopSignals = true
        uncertainChild.terminate()
        uncertainChild.waitUntilExit()
        uncertainStore.childExited(uncertainChild)
        expect(uncertainStore.canFinishTermination, "later confirmed exit resolves uncertainty")

        let helperScript = "#!/bin/sh\nIFS= read -r startup || exit 1\nprintf '%s\\n' '{\"event\":\"ready\",\"port\":54876}'\nIFS= read -r stop\nexit 0\n"
        try Data(helperScript.utf8).write(to: LocalProxyFixtureRuntime.helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: LocalProxyFixtureRuntime.helper.path)
        let resourceHelper = URL(string: "fixture-helper", relativeTo: root.appendingPathComponent("", isDirectory: true))!
        try LocalProxyQueueStore.validateHelperLocation(resourceHelper)
        expect(true, "base-relative executable URL is valid")
        let linkedHelper = root.appendingPathComponent("linked-helper")
        try FileManager.default.createSymbolicLink(at: linkedHelper, withDestinationURL: LocalProxyFixtureRuntime.helper)
        do {
            try LocalProxyQueueStore.validateHelperLocation(linkedHelper)
            preconditionFailure("linked executable accepted")
        } catch { checks += 1 }
        let stateDirectory = root.appendingPathComponent("LocalProxy")
        try LocalProxyQueueStore.prepareStateDirectory(stateDirectory)
        try LocalProxyQueueStore.prepareStateDirectory(stateDirectory)
        expect(true, "preexisting private state directory is reusable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stateDirectory.path)
        do {
            try LocalProxyQueueStore.prepareStateDirectory(stateDirectory)
            preconditionFailure("public state directory accepted")
        } catch { checks += 1 }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        let linkedState = root.appendingPathComponent("linked-state")
        try FileManager.default.createSymbolicLink(at: linkedState, withDestinationURL: stateDirectory)
        do {
            try LocalProxyQueueStore.prepareStateDirectory(linkedState)
            preconditionFailure("linked state directory accepted")
        } catch { checks += 1 }
        let runtimeStore = LocalProxyQueueStore(usageStore: isolatedUsage)
        runtimeStore.setAccountEnabled(id: profile.id, enabled: true)
        runtimeStore.setOptIn(true)
        await runtimeStore.start()
        expect(runtimeStore.phase == .running && runtimeStore.endpoint == "http://127.0.0.1:54876/v1", "explicit start accepts validated readiness")
        let connectionURL = runtimeStore.desktopConnection!
        let connectionAttributes = try FileManager.default.attributesOfItem(atPath: connectionURL.path)
        expect((connectionAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "desktop connection is private")
        let connection = try JSONSerialization.jsonObject(with: Data(contentsOf: connectionURL)) as! [String: Any]
        expect(connection["clientKey"] as? String == runtimeStore.clientKey && runtimeStore.desktopAvailable, "desktop receives only per-run key")
        await runtimeStore.stop()
        expect(!FileManager.default.fileExists(atPath: connectionURL.path) && !runtimeStore.desktopAvailable, "stopping removes desktop connection")
        expect(runtimeStore.canFinishTermination, "first helper stopped")
        let issueLogURL = root.appendingPathComponent("operations-issues-v1.jsonl")
        let requestedStopIssues = try String(contentsOf: issueLogURL, encoding: .utf8)
        expect(requestedStopIssues.contains("\"phase\":\"requested_stop\""), "confirmed requested stop records a fixed diagnostic")
        await runtimeStore.start()
        expect(runtimeStore.phase == .running && runtimeStore.endpoint != nil, "start stop start reuses state directory")
        let activeRun = runtimeStore.runID!
        let runtimeLease = try activity.reserveProxy(
            account: "fixture-account", alias: "fixture-alias", runID: activeRun, requestID: request, profileID: profile.id, childPID: runtimeStore.process!.processIdentifier)
        runtimeStore.leases[runtimeLease] = LocalProxyQueueStore.Lease(id: runtimeLease, profileID: profile.id, requestID: request, runID: activeRun)
        runtimeStore.consume(Data("{\"event\":\"error\",\"errorCode\":\"lease_acquire_unknown\"}".utf8), run: activeRun)
        for _ in 0..<100 {
            if runtimeStore.canFinishTermination { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        expect(runtimeStore.canFinishTermination && runtimeStore.endpoint == nil, "unknown acquisition stops child before release")
        expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("LocalProxy").path), "cooldowns directory survives stop")
        let issueLog = try String(contentsOf: issueLogURL, encoding: .utf8)
        expect(issueLog.contains("\"phase\":\"control_failure\""), "confirmed control failure records separately")
        expect(issueLog.contains("\"phase\":\"unexpected_exit\""), "unrequested child exit records separately")
        expect(!issueLog.contains("fixture-secret") && !issueLog.contains("/Users/"), "proxy diagnostics contain no control key or path")

        func jwt(_ claims: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: claims)
            return "fixture." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                + ".fixture"
        }
        func auth(expiry: Double, issued: Double, account: String = "account-fixture", email: String = "fixture@example.invalid") throws -> Data {
            let access = try jwt(["exp": expiry, "iat": issued, "account_id": account])
            let id = try jwt(["email": email, "account_id": account])
            return try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "id_token": id, "account_id": account]])
        }
        let identity = CodexCredentialIdentity(email: "central@example.invalid", accountID: "central-account")
        let valid = try auth(expiry: now.timeIntervalSince1970 + 3600, issued: now.timeIntervalSince1970 - 300)
        let admitted = try LocalProxyCredentialReader.validate(data: valid, profile: profile, centralIdentity: identity, now: now)
        expect(admitted.accountID == "account-fixture", "validated auth tuple")
        let encoded = try JSONEncoder().encode(LocalProxyReply(ok: true, accessToken: admitted.token, accountID: admitted.accountID, expiresAt: Int64(admitted.expiresAt)))
        expect(!String(decoding: encoded, as: UTF8.self).contains("refresh_token") && !String(decoding: encoded, as: UTF8.self).contains("id_token"), "access only reply")
        for data in [
            try auth(expiry: now.timeIntervalSince1970 - 1, issued: now.timeIntervalSince1970 - 300),
            try auth(expiry: now.timeIntervalSince1970 + 3600, issued: now.timeIntervalSince1970 + 1),
            try auth(expiry: now.timeIntervalSince1970 + 3600, issued: now.timeIntervalSince1970 - 300, account: "wrong-account"),
        ] {
            do {
                _ = try LocalProxyCredentialReader.validate(data: data, profile: profile, centralIdentity: identity, now: now)
                preconditionFailure("invalid auth")
            } catch { checks += 1 }
        }
        do {
            _ = try LocalProxyCredentialReader.validate(
                data: valid, profile: profile, centralIdentity: CodexCredentialIdentity(email: "fixture@example.invalid", accountID: "account-fixture"), now: now)
            preconditionFailure("central excluded")
        } catch { checks += 1 }
        let sameIdentity = CodexCredentialIdentity(email: "fixture@example.invalid", accountID: "account-fixture")
        let desktopCredential = try LocalProxyCredentialReader.validate(data: valid, profile: profile, centralIdentity: sameIdentity, now: now, allowDesktopAccount: true)
        expect(desktopCredential.accountID == "account-fixture", "explicit Desktop fallback allows validated managed credentials")
        do {
            _ = try LocalProxyCredentialReader.validate(data: valid, profile: profile, centralIdentity: identity, now: now, allowDesktopAccount: true)
            preconditionFailure("Desktop admission ignored a changed live Desktop identity")
        } catch { checks += 1 }
        let systemProfile = CodexProfile(id: "system", isSystemProfile: true, lastSnapshot: otherSnapshot)
        for candidate in [profile, systemProfile] {
            try FileManager.default.createDirectory(at: candidate.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let centralAuth = try auth(expiry: now.timeIntervalSince1970 + 3600, issued: now.timeIntervalSince1970 - 300, account: "central-account", email: "central@example.invalid")
        let profileFile = profile.codexHomeURL.appendingPathComponent("auth.json")
        let centralFile = systemProfile.codexHomeURL.appendingPathComponent("auth.json")
        try valid.write(to: profileFile)
        try centralAuth.write(to: centralFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: centralFile.path)
        let bounded = try LocalProxyCredentialReader.read(profile: profile, system: systemProfile, now: now)
        expect(bounded.accountID == "account-fixture", "owned bounded snapshot under gates")
        var desktopManaged = profile
        desktopManaged.lastSnapshot = systemProfile.lastSnapshot
        desktopManaged.lastSnapshot?.fetchedAt = now
        let expiredDesktopCopy = try auth(expiry: now.timeIntervalSince1970 - 60, issued: now.timeIntervalSince1970 - 3600, account: "central-account", email: "central@example.invalid")
        try expiredDesktopCopy.write(to: profileFile)
        let currentDesktopCredential = try LocalProxyCredentialReader.read(profile: desktopManaged, system: systemProfile, now: now, allowDesktopAccount: true)
        let centralObject = try JSONSerialization.jsonObject(with: centralAuth) as! [String: Any]
        expect(currentDesktopCredential.token == (centralObject["tokens"] as! [String: Any])["access_token"] as? String,
            "Desktop pass uses current same-identity session despite expired managed copy")
        try expect(Data(contentsOf: profileFile) == expiredDesktopCopy && Data(contentsOf: centralFile) == centralAuth,
            "Desktop admission writes neither managed nor system credentials")
        try valid.write(to: profileFile)
        do {
            _ = try LocalProxyCredentialReader.read(profile: desktopManaged, system: systemProfile, now: now, allowDesktopAccount: true)
            preconditionFailure("Desktop pass ignored changed managed identity")
        } catch LocalProxyFailure.identity { checks += 1 }
        // Exercise the actual host admission, lease and post-request refresh path.
        var creditProfile = profile
        creditProfile.lastSnapshot?.fiveHour?.usedPercent = 100
        creditProfile.lastSnapshot?.creditBalance = "2500"
        creditProfile.lastSnapshot?.creditBalanceUnlimited = false
        creditProfile.lastSnapshot?.fetchedAt = Date()
        let creditUsage = UsageStore([creditProfile, systemProfile])
        creditUsage.isPreview = false
        let creditStore = LocalProxyQueueStore(usageStore: creditUsage)
        let creditRun = UUID().uuidString
        creditStore.setCreditFallback(true)
        creditStore.setCreditFloors(primary: 2400, secondary: 1800)
        let creditChild = Process()
        creditChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        creditChild.arguments = ["30"]
        try creditChild.run()
        defer { if creditChild.isRunning { creditChild.terminate() } }
        creditStore.process = creditChild
        creditStore.phase = .running
        creditStore.runID = creditRun
        creditStore.controlKey = "fixture-credit-key"
        creditStore.activeIDs = [profile.id]
        creditStore.registeredPool[profile.id] = LocalProxyQueueStore.PoolBinding(
            home: creditProfile.codexHomeURL, account: creditProfile.recordedAccountKey,
            accountID: creditProfile.lastSnapshot!.accountID!)
        HubConsoleModel.fixtureAvailability = .idle
        func creditRequest(_ command: String, requestID: String, leaseID: String? = nil) -> LocalProxyRequest {
            LocalProxyRequest(schemaVersion: 1, runID: creditRun, key: "fixture-credit-key", command: command, requestID: requestID, profileID: profile.id, leaseID: leaseID)
        }
        // A remaining subscription blocks credits even when that account is
        // occupied elsewhere or is the Desktop's independently managed copy.
        var subscriptionPeer = CodexProfile(id: "subscription-peer", lastSnapshot: otherSnapshot)
        subscriptionPeer.lastSnapshot?.fetchedAt = Date()
        creditUsage.profiles.append(subscriptionPeer)
        creditStore.activeIDs.insert(subscriptionPeer.id)
        creditStore.registeredPool[subscriptionPeer.id] = LocalProxyQueueStore.PoolBinding(
            home: subscriptionPeer.codexHomeURL, account: subscriptionPeer.recordedAccountKey,
            accountID: subscriptionPeer.lastSnapshot!.accountID!)
        creditStore.rebuildRows()
        let peerRequestID = UUID().uuidString
        let peerLease = try activity.reserveProxy(
            account: subscriptionPeer.recordedAccountKey, alias: "subscription-peer", runID: creditRun, requestID: peerRequestID,
            profileID: subscriptionPeer.id, childPID: creditChild.processIdentifier)
        let beforePoolGate = try Data(contentsOf: root.appendingPathComponent("dispatch-activity-v1.json"))
        let pendingSubscription = await fixtureHandle(creditStore, creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(pendingSubscription.error == "subscription_pending" && creditStore.leases.isEmpty, "busy Desktop subscription cannot be skipped for points")
        try expect(Data(contentsOf: root.appendingPathComponent("dispatch-activity-v1.json")) == beforePoolGate, "pool gate fails before reserving a paid account")
        creditUsage.profiles[2].lastSnapshot?.fetchedAt = Date().addingTimeInterval(-121)
        let unknownSubscription = await fixtureHandle(creditStore, creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(
            unknownSubscription.error == "quota_unknown" && creditStore.leases.isEmpty && creditUsage.refreshCount > 0, "unknown subscription blocks points and requests refresh")
        creditUsage.onRefresh = { ids in
            expect(ids == creditStore.activeIDs, "paid refresh observes every frozen pool member")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000)
                creditUsage.profiles[2].lastSnapshot?.fetchedAt = Date()
            }
        }
        let refreshedSubscription = await fixtureHandle(creditStore, creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(refreshedSubscription.error == "subscription_pending" && creditStore.leases.isEmpty,
            "same request waits for refreshed peer and still preserves subscription-before-credits")
        creditUsage.onRefresh = nil
        // Excluding the peer restores the original one-account fixture scope.
        creditStore.activeIDs.remove(subscriptionPeer.id)
        creditUsage.profiles.removeLast()
        creditStore.rebuildRows()
        try activity.updateProxy(peerLease, runID: creditRun, requestID: peerRequestID, profileID: subscriptionPeer.id, state: "accepted")
        creditUsage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 1
        creditUsage.profiles[0].lastSnapshot?.fetchedAt = Date().addingTimeInterval(-121)
        creditUsage.onRefresh = { ids in
            expect(ids == [profile.id], "subscription refresh touches only requested account")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000)
                creditUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
            }
        }
        let refreshedID = UUID().uuidString
        let refreshedAdmission = await fixtureHandle(creditStore, creditRequest("acquire", requestID: refreshedID))
        expect(refreshedAdmission.ok && refreshedAdmission.leaseID != nil, "stale subscription refresh admits the same request after fresh validation")
        creditUsage.onRefresh = nil
        _ = await fixtureHandle(creditStore, creditRequest("release", requestID: refreshedID, leaseID: refreshedAdmission.leaseID))
        creditUsage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 100
        creditUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        let resolvedAfterUpdate = fixtureUUIDv7()
        var resolvedRequest = creditRequest("acquire_credit_primary", requestID: resolvedAfterUpdate)
        resolvedRequest.receivedAt = ProcessInfo.processInfo.systemUptime
        let runningEntered = DispatchSemaphore(value: 0)
        let resumeRunning = DispatchSemaphore(value: 0)
        LocalProxyFixtureRuntime.afterRunning = {
            runningEntered.signal()
            _ = resumeRunning.wait(timeout: .now() + 10)
        }
        let pendingResolved = Task { await fixtureHandle(creditStore, resolvedRequest) }
        let didUpdate = await Task.detached { Self.waitForReserve(runningEntered) }.value
        expect(didUpdate, "running registry update commits before main actor resumes")
        try expect(try activity.abandonProxy(runID: creditRun, requestID: resolvedAfterUpdate,
            profileID: profile.id, enforceFreshness: true) == .abandoned,
            "off-main resolver cancels exact running lease")
        resumeRunning.signal()
        let resolvedReply = await pendingResolved.value
        LocalProxyFixtureRuntime.afterRunning = nil
        expect(!resolvedReply.ok && resolvedReply.accessToken == nil && creditStore.leases.isEmpty,
            "disk-cancelled lease cannot return credentials before MainActor forget callback")
        let firstCreditRequest = UUID().uuidString
        let firstCredit = await fixtureHandle(creditStore, creditRequest("acquire_credit_primary", requestID: firstCreditRequest))
        expect(firstCredit.ok && firstCredit.leaseID != nil, "host admits balance above configured primary floor")
        let firstRelease = await fixtureHandle(creditStore, creditRequest("release", requestID: firstCreditRequest, leaseID: firstCredit.leaseID))
        expect(firstRelease.ok && creditUsage.refreshCount > 0, "paid completion requests official balance refresh")
        let staleCredit = await fixtureHandle(creditStore, creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(staleCredit.error == "quota_unknown" && creditStore.leases.isEmpty, "previous balance cannot authorize a second paid request")
        creditUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        creditUsage.profiles[0].lastSnapshot?.creditBalance = "2400"
        let primaryAtFloor = await fixtureHandle(creditStore, creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(primaryAtFloor.error == "quota", "host rejects equality at configured first floor")
        let secondCreditRequest = UUID().uuidString
        let secondCredit = await fixtureHandle(creditStore, creditRequest("acquire_credit_secondary", requestID: secondCreditRequest))
        expect(secondCredit.ok, "host admits second tier after fresh balance")
        _ = await fixtureHandle(creditStore, creditRequest("release", requestID: secondCreditRequest, leaseID: secondCredit.leaseID))
        creditUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        creditUsage.profiles[0].lastSnapshot?.creditBalance = "1800"
        let secondaryAtFloor = await fixtureHandle(creditStore, creditRequest("acquire_credit_secondary", requestID: UUID().uuidString))
        expect(secondaryAtFloor.error == "quota" && creditStore.leases.isEmpty, "host stops admission at configured lower floor")
        let wrongPass = await fixtureHandle(creditStore, creditRequest("acquire_desktop_credit_secondary", requestID: UUID().uuidString))
        expect(wrongPass.error == "stage_not_applicable", "other identity stage is silently inapplicable")
        expect(!creditStore.setCreditFloors(primary: 100, secondary: 0), "running policy cannot change mid-request")
        creditChild.terminate()
        creditChild.waitUntilExit()
        creditStore.childExited(creditChild)
        HubConsoleModel.fixtureAvailability = .unavailable
        let refreshStarted = DispatchSemaphore(value: 0)
        let refreshFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            CodexCredentialAccessGate.lock.lock()
            refreshStarted.signal()
            Thread.sleep(forTimeInterval: 2.25)
            CodexCredentialAccessGate.lock.unlock()
            refreshFinished.signal()
        }
        expect(refreshStarted.wait(timeout: .now() + 2) == .success, "fixture quota refresh holds credential gate")
        let afterRefresh = try LocalProxyCredentialReader.read(profile: profile, system: systemProfile, now: now)
        expect(afterRefresh.accountID == "account-fixture", "read waits beyond old two-second refresh contention")
        expect(refreshFinished.wait(timeout: .now() + 1) == .success, "fixture refresh releases gate")
        let longRefreshStarted = DispatchSemaphore(value: 0)
        let releaseLongRefresh = DispatchSemaphore(value: 0)
        let longRefreshFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            CodexCredentialAccessGate.lock.lock()
            longRefreshStarted.signal()
            _ = releaseLongRefresh.wait(timeout: .now() + 16)
            CodexCredentialAccessGate.lock.unlock()
            longRefreshFinished.signal()
        }
        expect(longRefreshStarted.wait(timeout: .now() + 2) == .success, "fixture long refresh holds gate")
        let gateWaitStart = ProcessInfo.processInfo.systemUptime
        do {
            _ = try LocalProxyCredentialReader.read(profile: profile, system: systemProfile, now: now)
            preconditionFailure("indefinite credential gate was admitted")
        } catch LocalProxyFailure.credentialsBusy { checks += 1 }
        releaseLongRefresh.signal()
        expect(ProcessInfo.processInfo.systemUptime - gateWaitStart < 14, "credential contention stays within bridge deadline")
        expect(longRefreshFinished.wait(timeout: .now() + 1) == .success, "timed-out credential read releases all held gates")
        try FileManager.default.removeItem(at: profileFile)
        try FileManager.default.createSymbolicLink(at: profileFile, withDestinationURL: centralFile)
        do {
            _ = try LocalProxyCredentialReader.read(profile: profile, system: systemProfile, now: now)
            preconditionFailure("symlink credentials")
        } catch { checks += 1 }
        print("PASS: \(checks) local proxy host synthetic checks; no live profiles, network or app launch")
    }
}
