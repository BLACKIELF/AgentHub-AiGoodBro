import Darwin
import Foundation

@main struct LocalProxyHostFixtures {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
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
        expect(store.rows.first?.isEnabled == true, "new independent queue participation default")
        expect(store.rows.first?.quotaText == "Remaining: 5h 99.0% · Weekly 99.0%", "verified remaining quota labels omit unreported monthly window")
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
        let request = UUID().uuidString
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
        let denied = await lifecycle.handle(
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire", requestID: UUID().uuidString, profileID: profile.id, leaseID: nil))
        expect(denied.error == "unavailable" && lifecycle.leases.isEmpty, "failed Hub releases preparation before credentials")
        let held = try activity.reserveProxy(
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
        desktopOrdering.leases[held] = lifecycle.leases[held]
        let orderRequest = LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "order", requestID: request, profileID: profile.id, leaseID: nil)
        let registryBeforeOrdering = try Data(contentsOf: root.appendingPathComponent("dispatch-activity-v1.json"))
        let refreshesBeforeOrdering = desktopOrderUsage.refreshCount
        expect(desktopOrdering.canReorder && !desktopOrdering.canEdit, "running lease permits order edits only")
        expect(!desktopOrdering.canMoveAccount(id: profile.id, by: -1), "Desktop cannot move ahead of other accounts")
        expect(!desktopOrdering.canMoveAccount(id: "third", by: -1), "first row cannot move above the queue")
        expect(!desktopOrdering.canMoveAccount(id: "third", by: 2), "only adjacent moves are accepted")
        desktopOrdering.moveAccount(id: "second", by: -1)
        let moved = await desktopOrdering.handle(orderRequest)
        expect(moved.ok && moved.order == ["second", "third", profile.id], "running order request returns current manual order")
        expect(moved.accessToken == nil && moved.accountID == nil && moved.leaseID == nil, "order reply contains no credentials or reservation")
        desktopOrdering.setAccountPriority(id: "third", priority: true)
        let prioritized = await desktopOrdering.handle(orderRequest)
        expect(prioritized.order == ["third", "second", profile.id], "live priority takes effect on next order query")
        expect(!desktopOrdering.canMoveAccount(id: "second", by: -1), "arrows cannot silently cross priority tiers")
        desktopOrdering.setAccountEnabled(id: "second", enabled: false)
        expect(desktopOrdering.rows.first(where: { $0.id == "second" })?.isEnabled == true, "running membership stays fixed")
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
        let missingOrder = await desktopOrdering.handle(orderRequest)
        expect(!missingOrder.ok && missingOrder.order == nil, "missing registered row cannot silently change membership")
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

        let uncertainChild = Process()
        uncertainChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        uncertainChild.arguments = ["30"]
        try uncertainChild.run()
        let uncertainStore = LocalProxyQueueStore(usageStore: isolatedUsage)
        uncertainStore.process = uncertainChild
        uncertainStore.phase = .running
        uncertainStore.runID = run
        let uncertainLease = try activity.reserveProxy(
            account: "fixture-account", alias: "fixture-alias", runID: run, requestID: request, profileID: profile.id, childPID: uncertainChild.processIdentifier)
        uncertainStore.leases[uncertainLease] = LocalProxyQueueStore.Lease(id: uncertainLease, profileID: profile.id, requestID: request, runID: run)
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
        // Exercise the actual host admission, lease and post-request refresh path.
        var creditProfile = profile
        creditProfile.lastSnapshot?.fiveHour?.usedPercent = 100
        creditProfile.lastSnapshot?.creditBalance = "2500"
        creditProfile.lastSnapshot?.creditBalanceUnlimited = false
        creditProfile.lastSnapshot?.fetchedAt = Date()
        let creditUsage = UsageStore([creditProfile, systemProfile])
        creditUsage.isPreview = false
        let creditStore = LocalProxyQueueStore(usageStore: creditUsage)
        creditStore.setCreditFallback(true)
        creditStore.setCreditFloors(primary: 2400, secondary: 1800)
        let creditChild = Process()
        creditChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        creditChild.arguments = ["30"]
        try creditChild.run()
        defer { if creditChild.isRunning { creditChild.terminate() } }
        creditStore.process = creditChild
        creditStore.phase = .running
        creditStore.runID = run
        creditStore.controlKey = "fixture-credit-key"
        creditStore.activeIDs = [profile.id]
        HubConsoleModel.fixtureAvailability = .idle
        func creditRequest(_ command: String, requestID: String, leaseID: String? = nil) -> LocalProxyRequest {
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-credit-key", command: command, requestID: requestID, profileID: profile.id, leaseID: leaseID)
        }
        // A remaining subscription blocks credits even when that account is
        // occupied elsewhere or is the Desktop's independently managed copy.
        var subscriptionPeer = CodexProfile(id: "subscription-peer", lastSnapshot: otherSnapshot)
        subscriptionPeer.lastSnapshot?.fetchedAt = Date()
        creditUsage.profiles.append(subscriptionPeer)
        creditStore.activeIDs.insert(subscriptionPeer.id)
        let peerRequestID = UUID().uuidString
        let peerLease = try activity.reserveProxy(
            account: subscriptionPeer.recordedAccountKey, alias: "subscription-peer", runID: run, requestID: peerRequestID,
            profileID: subscriptionPeer.id, childPID: creditChild.processIdentifier)
        let beforePoolGate = try Data(contentsOf: root.appendingPathComponent("dispatch-activity-v1.json"))
        let pendingSubscription = await creditStore.handle(creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(pendingSubscription.error == "subscription_pending" && creditStore.leases.isEmpty, "busy Desktop subscription cannot be skipped for points")
        try expect(Data(contentsOf: root.appendingPathComponent("dispatch-activity-v1.json")) == beforePoolGate, "pool gate fails before reserving a paid account")
        creditUsage.profiles[2].lastSnapshot?.fetchedAt = Date().addingTimeInterval(-121)
        let unknownSubscription = await creditStore.handle(creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(
            unknownSubscription.error == "quota_unknown" && creditStore.leases.isEmpty && creditUsage.refreshCount > 0, "unknown subscription blocks points and requests refresh")
        // Excluding the peer restores the original one-account fixture scope.
        creditStore.activeIDs.remove(subscriptionPeer.id)
        creditUsage.profiles.removeLast()
        try activity.updateProxy(peerLease, runID: run, requestID: peerRequestID, profileID: subscriptionPeer.id, state: "accepted")
        let firstCreditRequest = UUID().uuidString
        let firstCredit = await creditStore.handle(creditRequest("acquire_credit_primary", requestID: firstCreditRequest))
        expect(firstCredit.ok && firstCredit.leaseID != nil, "host admits balance above configured primary floor")
        let firstRelease = await creditStore.handle(creditRequest("release", requestID: firstCreditRequest, leaseID: firstCredit.leaseID))
        expect(firstRelease.ok && creditUsage.refreshCount > 0, "paid completion requests official balance refresh")
        let staleCredit = await creditStore.handle(creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(staleCredit.error == "quota_unknown" && creditStore.leases.isEmpty, "previous balance cannot authorize a second paid request")
        creditUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        creditUsage.profiles[0].lastSnapshot?.creditBalance = "2400"
        let primaryAtFloor = await creditStore.handle(creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(primaryAtFloor.error == "quota", "host rejects equality at configured first floor")
        let secondCreditRequest = UUID().uuidString
        let secondCredit = await creditStore.handle(creditRequest("acquire_credit_secondary", requestID: secondCreditRequest))
        expect(secondCredit.ok, "host admits second tier after fresh balance")
        _ = await creditStore.handle(creditRequest("release", requestID: secondCreditRequest, leaseID: secondCredit.leaseID))
        creditUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        creditUsage.profiles[0].lastSnapshot?.creditBalance = "1800"
        let secondaryAtFloor = await creditStore.handle(creditRequest("acquire_credit_secondary", requestID: UUID().uuidString))
        expect(secondaryAtFloor.error == "quota" && creditStore.leases.isEmpty, "host stops admission at configured lower floor")
        let wrongPass = await creditStore.handle(creditRequest("acquire_desktop_credit_secondary", requestID: UUID().uuidString))
        expect(wrongPass.error == "identity", "Desktop tier cannot admit another identity")
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
